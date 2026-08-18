import AVFoundation
import CoreImage
import UIKit
import EditorCore

enum CaptionOverlayError: LocalizedError {
    case noVideoTrack

    var errorDescription: String? {
        "O vídeo não tem trilha de vídeo pra legendar."
    }
}

/// Monta a `AVVideoComposition` que queima a legenda no vídeo (PLANO.md
/// Fase 2/seção 3: legenda animada dirigida pelos timestamps). Ao contrário
/// do corte (Fase 1), isto SEMPRE precisa de re-encode — passthrough não é
/// compatível com uma videoComposition (ver `VideoExporter`).
///
/// Usa `AVMutableVideoComposition(asset:applyingCIFiltersWithHandler:)` em
/// vez de `CATextLayer` + `AVVideoCompositionCoreAnimationTool`: a
/// primeira versão deste arquivo usava essa segunda abordagem e a legenda
/// simplesmente não aparecia no export — há casos bem documentados de
/// `AVVideoCompositionCoreAnimationTool` não avaliar corretamente
/// animações (principalmente aninhadas num `CAAnimationGroup`, mas o
/// problema persistiu mesmo depois de tirar o group) durante exportação
/// offline, mesmo funcionando ao vivo. O handler de CIFilters é o padrão
/// usado por apps de edição de vídeo pra esse tipo de overlay dependente de
/// tempo: pra cada frame, o handler recebe o instante exato
/// (`compositionTime`) e decide o que desenhar — sem nenhuma mágica de
/// timing de Core Animation no meio.
enum CaptionOverlayBuilder {
    static func build(
        asset: AVAsset,
        cues: [CaptionCue],
        settings: CaptionSettings
    ) async throws -> AVMutableVideoComposition {
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw CaptionOverlayError.noVideoTrack
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let renderSize = CGSize(width: abs(transformedRect.width), height: abs(transformedRect.height))

        // Uma imagem por cue, pré-renderizada UMA vez (não por frame) — o
        // handler abaixo só escolhe qual usar a cada frame, evitando
        // redesenhar o mesmo texto centenas/milhares de vezes ao longo do
        // vídeo. Cada imagem é do tamanho da CAIXA de texto, não do frame
        // inteiro, então o custo de memória escala com a quantidade de
        // cues, não com a resolução do vídeo — o mesmo tipo de descuido
        // que causou o jetsam kill por memória na versão com CATextLayer
        // (lá, cada camada guardava um bitmap do tamanho do texto; aqui é
        // a mesma ideia, só que como imagem simples em vez de CALayer).
        let sortedCues = cues.sorted { $0.start < $1.start }
        let overlays: [(cue: CaptionCue, image: CIImage)] = sortedCues.map { cue in
            (cue, CaptionOverlayRenderer.render(text: cue.text, position: settings.position, renderSize: renderSize))
        }

        let composition = AVMutableVideoComposition(asset: asset) { request in
            let time = CMTimeGetSeconds(request.compositionTime)
            guard let match = overlays.first(where: { time >= $0.cue.start && time < $0.cue.end }) else {
                request.finish(with: request.sourceImage, context: nil)
                return
            }
            request.finish(with: match.image.composited(over: request.sourceImage), context: nil)
        }
        // Redundante com o que o inicializador já infere do asset, mas
        // deixa explícito que o tamanho usado pra posicionar o texto
        // (acima) é exatamente o que vai valer no export — sem depender de
        // nenhum valor implícito coincidir por acaso.
        composition.renderSize = renderSize

        return composition
    }
}

/// Desenha o texto de um cue numa imagem pequena (só a caixa de legenda, não
/// o frame inteiro) usando UIKit normal (`UIGraphicsImageRenderer`,
/// coordenadas de cima pra baixo) e converte pra `CIImage` pra compor sobre
/// o frame de vídeo.
private enum CaptionOverlayRenderer {
    static func render(text: String, position: CaptionPosition, renderSize: CGSize) -> CIImage {
        let boxWidth = (renderSize.width * 0.85).rounded()
        let boxHeight = (renderSize.height * 0.2).rounded()
        let fontSize = renderSize.width * 0.065

        // scale = 1 é essencial aqui: sem isso, UIGraphicsImageRenderer usa
        // o scale da tela (2x/3x) e a imagem resultante teria dimensões em
        // PIXELS maiores que boxWidth/boxHeight (que já são pixels
        // absolutos do vídeo, não pontos de tela) — descasando com a
        // matemática de posicionamento abaixo, que assume 1:1.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: boxWidth, height: boxHeight), format: format)

        let uiImage = renderer.image { _ in
            let boxRect = CGRect(x: 0, y: 0, width: boxWidth, height: boxHeight)

            // Fundo semi-transparente pra legibilidade em vez de sombra:
            // mais barato de renderizar (sombra força uma passada extra
            // offscreen por camada/frame) e garante contraste mesmo sobre
            // fundo bem claro, o que uma sombra sutil não garantiria.
            let backgroundRect = boxRect.insetBy(dx: 0, dy: boxHeight * 0.15)
            UIBezierPath(roundedRect: backgroundRect, cornerRadius: 12).addClip()
            UIColor.black.withAlphaComponent(0.45).setFill()
            UIRectFill(backgroundRect)

            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: fontSize),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraphStyle,
            ]

            let textRect = boxRect.insetBy(dx: boxWidth * 0.04, dy: 0)
            (text as NSString).draw(
                with: textRect,
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: attributes,
                context: nil
            )
        }

        guard let ciImage = CIImage(image: uiImage) else {
            return CIImage.empty()
        }

        let fractionFromTop: CGFloat
        switch position {
        case .centerLower: fractionFromTop = 0.58
        case .bottomEdge: fractionFromTop = 0.80
        }

        let tx = (renderSize.width - boxWidth) / 2
        // CIImage usa eixo Y crescendo pra CIMA (origem no canto inferior
        // esquerdo) — o oposto da convenção do UIKit (topo-pra-baixo) usada
        // pra desenhar o texto acima. `fractionFromTop` é pensado de cima
        // pra baixo (0.58 = 58% descendo a partir do topo); convertendo pro
        // eixo de baixo-pra-cima do CIImage: a borda de CIMA da caixa deve
        // ficar em `(1 - fractionFromTop) * altura`, então a âncora do
        // translate (canto inferior esquerdo da caixa) fica esse valor
        // menos a própria altura da caixa.
        let ty = renderSize.height * (1 - fractionFromTop) - boxHeight

        return ciImage.transformed(by: CGAffineTransform(translationX: tx, y: ty))
    }
}
