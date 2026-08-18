import SwiftUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers
import EditorCore

private enum PipelineState {
    case idle
    case loadingInfo(progress: Double)
    case ready(asset: AVURLAsset, info: String)
    case processing(step: String)
    case done(message: String)
    case failed(String)
}

// Fase 1 (ver PLANO.md seção 6): escolher vídeo → cortar silêncio
// (AVMutableComposition não-destrutiva) → exportar → salvar na galeria.
// Sem legenda, transcrição ou zoom ainda — só o corte, de ponta a ponta.
struct ContentView: View {
    @State private var selectedItem: PhotosPickerItem?
    @State private var state: PipelineState = .idle
    // Precisa viver fora do enum de estado porque a observação KVO do
    // Progress atualiza esta referência de fora do fluxo normal de SwiftUI —
    // guardar só o valor (Double) no enum e a observação aqui evita recriar
    // o NSKeyValueObservation a cada re-render.
    @State private var loadProgressObservation: NSKeyValueObservation?

    var body: some View {
        VStack(spacing: 20) {
            Text("ViralClip")
                .font(.largeTitle.bold())

            PhotosPicker(
                selection: $selectedItem,
                matching: .videos,
                photoLibrary: .shared()
            ) {
                Label("Escolher vídeo", systemImage: "video.badge.plus")
            }
            .buttonStyle(.borderedProminent)

            statusView

            if case .ready(let asset, _) = state {
                Button {
                    Task { await cutSilenceAndExport(asset: asset) }
                } label: {
                    Label("Cortar silêncio e exportar", systemImage: "scissors")
                }
                .buttonStyle(.borderedProminent)
            }

            Spacer()
        }
        .padding()
        .onChange(of: selectedItem) { _, newItem in
            guard let newItem else { return }
            Task { await loadVideoInfo(from: newItem) }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch state {
        case .idle:
            Text("Nenhum vídeo selecionado.")
                .multilineTextAlignment(.center)
        case .loadingInfo(let progress):
            ProgressView(value: progress) {
                Text("Carregando... \(Int(progress * 100))%")
            }
        case .ready(_, let info):
            Text(info).multilineTextAlignment(.center)
        case .processing(let step):
            ProgressView(step)
        case .done(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .multilineTextAlignment(.center)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        }
    }

    private func loadVideoInfo(from item: PhotosPickerItem) async {
        state = .loadingInfo(progress: 0)

        do {
            // A variante com completionHandler (em vez do `loadTransferable`
            // async simples) é a única que devolve um `Progress` observável —
            // cobre tanto o download do iCloud (quando o original não está
            // no aparelho) quanto a cópia local, que é o que causava a
            // sensação de "travado" sem indicação nenhuma antes disso.
            let movie: Movie? = try await withCheckedThrowingContinuation { continuation in
                let progress = item.loadTransferable(type: Movie.self) { result in
                    continuation.resume(with: result)
                }
                loadProgressObservation = progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor in
                        state = .loadingInfo(progress: fraction)
                    }
                }
            }
            loadProgressObservation = nil

            guard let movie else {
                state = .failed("Não foi possível carregar o vídeo selecionado.")
                return
            }

            let asset = AVURLAsset(url: movie.url)
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)

            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                state = .failed("Vídeo sem trilha de vídeo.")
                return
            }

            // naturalSize sozinho ignora orientação (um vídeo gravado em pé
            // costuma reportar dimensões "deitadas" antes de aplicar o
            // preferredTransform) — aplicar o transform é o que dá a
            // resolução exibida de fato, igual o app de Fotos mostra.
            let naturalSize = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let transformedSize = naturalSize.applying(transform)
            let width = abs(transformedSize.width)
            let height = abs(transformedSize.height)

            let info = String(
                format: "Duração: %.1fs\nResolução: %.0fx%.0f",
                seconds, width, height
            )
            state = .ready(asset: asset, info: info)
        } catch {
            loadProgressObservation = nil
            state = .failed("Erro ao ler o vídeo: \(error.localizedDescription)")
        }
    }

    private func cutSilenceAndExport(asset: AVURLAsset) async {
        do {
            state = .processing(step: "Analisando áudio...")
            let (samples, sampleRate) = try await AudioSampleExtractor.extractMonoPCM(from: asset)
            let keepRanges = SilenceDetection.keepRanges(samples: samples, sampleRate: sampleRate)

            guard !keepRanges.isEmpty else {
                state = .failed("O áudio inteiro foi classificado como silêncio — nada a manter.")
                return
            }

            state = .processing(step: "Montando o corte...")
            let composition = try await CompositionBuilder.build(asset: asset, keepRanges: keepRanges)

            state = .processing(step: "Exportando...")
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mov")
            try await VideoExporter.export(composition: composition, to: outputURL)

            state = .processing(step: "Salvando na galeria...")
            try await PhotoLibrarySaver.saveVideo(at: outputURL)
            try? FileManager.default.removeItem(at: outputURL)

            let cutCount = keepRanges.count - 1
            state = .done(message: "Exportado e salvo na galeria (\(cutCount) corte\(cutCount == 1 ? "" : "s") de silêncio).")
        } catch {
            state = .failed("Erro ao processar: \(error.localizedDescription)")
        }
    }
}

// PhotosPicker entrega o vídeo como dado transferível, não como URL direta —
// a URL original do picker some assim que a closure de importação termina,
// então precisamos de uma URL estável que sobreviva o resto da função (e,
// mais tarde, o processamento do corte). `moveItem` em vez de `copyItem`:
// `received.file` já está numa área temporária que o sistema descarta
// depois da closure, então "tirar" o arquivo de lá com um move (troca de
// referência, sem reler/reescrever bytes — quase instantâneo dentro do
// mesmo volume, que é o caso normal aqui) é estritamente melhor que copiar
// e deixar o original ser descartado depois. Pra vídeo grande isso é a
// diferença entre a etapa de carregar ser proporcional ao tamanho do
// arquivo (copyItem) ou quase fixa (moveItem).
private struct Movie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension)
            try FileManager.default.moveItem(at: received.file, to: destination)
            return Movie(url: destination)
        }
    }
}

#Preview {
    ContentView()
}
