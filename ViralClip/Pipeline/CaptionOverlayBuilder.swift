import AVFoundation
import QuartzCore
import UIKit
import EditorCore

enum CaptionOverlayError: LocalizedError {
    case noVideoTrack

    var errorDescription: String? {
        "O vídeo não tem trilha de vídeo pra legendar."
    }
}

/// Monta a `AVVideoComposition` que queima a legenda no vídeo via Core
/// Animation (ver PLANO.md Fase 2/seção 3: legenda animada dirigida pelos
/// timestamps). Ao contrário do corte (Fase 1), isto SEMPRE precisa de
/// re-encode — passthrough não é compatível com uma videoComposition, já
/// que estamos de fato desenhando pixel em cima do vídeo (ver
/// `VideoExporter`, que pula o passthrough quando recebe uma
/// videoComposition).
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
        let transformed = naturalSize.applying(transform)
        let renderSize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
        let totalDuration = try await asset.load(.duration)
        let totalSeconds = CMTimeGetSeconds(totalDuration)

        // Usa o frame rate real do vídeo (ex: 60fps de gravação no iPhone)
        // em vez de fixar 30 — senão essa etapa reduziria a fluidez do
        // vídeo mesmo quando o corte (Fase 1, passthrough) preservou o
        // original intacto.
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        let frameRate = nominalFrameRate > 0 ? nominalFrameRate : 30

        let parentLayer = CALayer()
        let videoLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)
        videoLayer.frame = parentLayer.frame
        parentLayer.addSublayer(videoLayer)

        for cue in cues {
            parentLayer.addSublayer(
                makeCueLayer(cue: cue, renderSize: renderSize, position: settings.position, totalDuration: totalSeconds)
            )
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: Int32(frameRate.rounded()))
        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: totalDuration)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layerInstruction.setTransform(transform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        return videoComposition
    }

    // MARK: - Camada por cue

    private static func makeCueLayer(
        cue: CaptionCue,
        renderSize: CGSize,
        position: CaptionPosition,
        totalDuration: Double
    ) -> CATextLayer {
        let textLayer = CATextLayer()
        textLayer.string = cue.text
        textLayer.font = UIFont.boldSystemFont(ofSize: 1)  // tamanho real vem de fontSize abaixo
        textLayer.fontSize = renderSize.width * 0.07
        textLayer.alignmentMode = .center
        textLayer.isWrapped = true
        textLayer.truncationMode = .none
        textLayer.foregroundColor = UIColor.white.cgColor
        // `renderSize` aqui já é em pixels absolutos do vídeo, não em
        // "pontos" de tela — não existe retina nesse contexto de export
        // offline. `contentsScale` > 1 só faria cada camada de texto
        // guardar um bitmap maior (3 → 9x a área) sem ganho nenhum de
        // nitidez; num vídeo com muitos trechos de legenda isso foi a
        // causa mais provável de um jetsam kill por memória observado num
        // teste real (~3,4GB de RAM, processo morto por "per-process-limit").
        textLayer.contentsScale = 1
        // Sombra removida: CALayer.shadow* força uma passada extra de
        // renderização offscreen por camada, outro multiplicador de custo
        // nessa mesma combinação (AVVideoCompositionCoreAnimationTool é
        // conhecido por ser pesado em memória). Sem ela o texto branco
        // pode ficar menos legível sobre fundo claro — se isso for um
        // problema real depois de testar, a alternativa mais barata é uma
        // caixa de fundo semi-transparente atrás do texto em vez de sombra.

        let width = renderSize.width * 0.85
        let height = renderSize.height * 0.18
        let x = (renderSize.width - width) / 2
        let y: CGFloat
        switch position {
        case .centerLower:
            y = renderSize.height * 0.58
        case .bottomEdge:
            y = renderSize.height * 0.84
        }
        textLayer.frame = CGRect(x: x, y: y, width: width, height: height)

        // Invisível por padrão; só aparece na janela [cue.start, cue.end).
        // O padrão "AVCoreAnimationBeginTimeAtZero + tempo absoluto" é o
        // jeito documentado de ancorar uma CAAnimation num instante
        // específico da linha do tempo durante um export offline (não é
        // relativo a "agora", que não existe fora de reprodução ao vivo).
        textLayer.opacity = 0

        let show = CABasicAnimation(keyPath: "opacity")
        show.fromValue = 0
        show.toValue = 1
        show.duration = 0.01
        show.beginTime = AVCoreAnimationBeginTimeAtZero + cue.start
        show.fillMode = .forwards
        show.isRemovedOnCompletion = false

        let hide = CABasicAnimation(keyPath: "opacity")
        hide.fromValue = 1
        hide.toValue = 0
        hide.duration = 0.01
        hide.beginTime = AVCoreAnimationBeginTimeAtZero + cue.end
        hide.fillMode = .forwards
        hide.isRemovedOnCompletion = false

        let group = CAAnimationGroup()
        group.animations = [show, hide]
        // Precisa cobrir o vídeo inteiro, não só a janela do cue: com
        // isRemovedOnCompletion = false e fillMode = .forwards, a
        // apresentação some ao final da duração do grupo — se o grupo
        // acabasse logo depois do cue, o export poderia parar de avaliar
        // as animações antes do fim real do vídeo.
        group.duration = totalDuration + 1
        group.beginTime = AVCoreAnimationBeginTimeAtZero
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false

        textLayer.add(group, forKey: "visibility")
        return textLayer
    }
}
