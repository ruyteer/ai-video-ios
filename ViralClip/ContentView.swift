import SwiftUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers

// App mínimo da Fase 1 (bootstrap): só prova que PhotosUI + AVFoundation
// básico funcionam de ponta a ponta num device real via CI + Sideloadly,
// ANTES de implementar o corte de verdade (ver PLANO.md seção 6, Fase 1).
// Nenhuma lógica de corte entra aqui ainda.
struct ContentView: View {
    @State private var selectedItem: PhotosPickerItem?
    @State private var videoInfo: String = "Nenhum vídeo selecionado."
    @State private var isLoading = false

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

            if isLoading {
                ProgressView()
            }

            Text(videoInfo)
                .font(.body)
                .multilineTextAlignment(.center)
                .padding()

            Spacer()
        }
        .padding()
        .onChange(of: selectedItem) { _, newItem in
            guard let newItem else { return }
            Task { await loadVideoInfo(from: newItem) }
        }
    }

    private func loadVideoInfo(from item: PhotosPickerItem) async {
        isLoading = true
        videoInfo = "Carregando..."
        defer { isLoading = false }

        do {
            guard let movie = try await item.loadTransferable(type: Movie.self) else {
                videoInfo = "Não foi possível carregar o vídeo selecionado."
                return
            }

            let asset = AVURLAsset(url: movie.url)
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)

            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                videoInfo = String(format: "Duração: %.1fs\n(sem trilha de vídeo)", seconds)
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

            videoInfo = String(
                format: "Duração: %.1fs\nResolução: %.0fx%.0f",
                seconds, width, height
            )

            // TODO: aqui é onde o corte de verdade vai entrar, depois que
            // EditorCore.SilenceDetection estiver mesclado e este bootstrap
            // validado via CI real: extrair PCM de `movie.url` (AVFoundation,
            // única parte que precisa tocar em AVAsset diretamente), passar
            // as amostras pra EditorCore.SilenceDetection.keepRanges (lógica
            // pura, já testada no Windows via `swift test`), montar a
            // AVMutableComposition com os trechos retornados e exportar via
            // AVAssetExportPresetPassthrough (ver PLANO.md seção 4). Não
            // implementado nesta tarefa — depende de uma API (extração de
            // PCM real) ainda não validada.
        } catch {
            videoInfo = "Erro ao ler o vídeo: \(error.localizedDescription)"
        }
    }
}

// PhotosPicker entrega o vídeo como dado transferível, não como URL direta —
// a URL original do picker some assim que a closure de importação termina,
// então copiamos pro diretório temporário do app pra ter uma URL estável
// que sobrevive o resto da função (e, mais tarde, o processamento do corte).
private struct Movie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return Movie(url: destination)
        }
    }
}

#Preview {
    ContentView()
}
