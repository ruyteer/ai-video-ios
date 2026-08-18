import SwiftUI
import AVFoundation
import Photos
import EditorCore

private enum PipelineState {
    case idle
    case loadingInfo(progress: Double)
    case ready(asset: AVAsset, info: String)
    case processing(step: String)
    /// Corte pronto e já exportado (sem legenda ainda) — `cutFileURL` é o
    /// arquivo intermediário no tmp, só existe até o usuário decidir salvar
    /// com ou sem legenda (ver `skipCaptionsAndSave`/`applyCaptions`).
    case cutReady(cutAsset: AVAsset, cutFileURL: URL)
    case done(message: String)
    case failed(String)
}

// Fase 1 (PLANO.md seção 6): escolher vídeo → cortar silêncio
// (AVMutableComposition não-destrutiva) → exportar. Fase 2: transcrever o
// corte (SFSpeechRecognizer, pt-BR) → escolher estilo/posição da legenda →
// queimar via Core Animation → exportar final → salvar na galeria.
struct ContentView: View {
    @State private var showingPicker = false
    @State private var state: PipelineState = .idle
    @State private var captionRevealStyle: CaptionRevealStyle = .wordByWord
    @State private var captionPosition: CaptionPosition = .centerLower
    // Erro específico da etapa de legenda: fica separado de `state` de
    // propósito. Se um erro aqui derrubasse `state` pra `.failed`, o corte
    // já pronto em `cutFileURL` ficaria inacessível e o usuário teria que
    // repetir a análise de áudio + export inteiros de novo só pra tentar a
    // legenda outra vez — em vez disso, o estado continua `.cutReady` e só
    // mostramos o erro ao lado do seletor de estilo, pra tentar de novo (ou
    // usar "Salvar sem legenda") sem perder o trabalho já feito.
    @State private var captionErrorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            Text("ViralClip")
                .font(.largeTitle.bold())

            Button {
                Task { await requestAccessAndShowPicker() }
            } label: {
                Label("Escolher vídeo", systemImage: "video.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .sheet(isPresented: $showingPicker) {
                PhotoLibraryPicker(isPresented: $showingPicker) { phAsset in
                    Task { await loadVideoInfo(from: phAsset) }
                }
            }

            statusView

            if case .ready(let asset, _) = state {
                Button {
                    Task { await cutSilenceAndExport(asset: asset) }
                } label: {
                    Label("Cortar silêncio e exportar", systemImage: "scissors")
                }
                .buttonStyle(.borderedProminent)
            }

            if case .cutReady(let cutAsset, let cutFileURL) = state {
                if let captionErrorMessage {
                    Label(captionErrorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                CaptionStylePickerView(
                    revealStyle: $captionRevealStyle,
                    position: $captionPosition,
                    onSkip: { Task { await skipCaptionsAndSave(cutFileURL: cutFileURL) } },
                    onApply: {
                        let settings = CaptionSettings(revealStyle: captionRevealStyle, position: captionPosition)
                        Task { await applyCaptions(cutAsset: cutAsset, cutFileURL: cutFileURL, settings: settings) }
                    }
                )
            }

            if case .failed = state {
                Button("Recomeçar", action: reset)
                    .buttonStyle(.bordered)
            }

            Spacer()
        }
        .padding()
    }

    private func reset() {
        captionErrorMessage = nil
        state = .idle
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
        case .cutReady:
            Text("Corte pronto. Escolha a legenda abaixo.")
                .multilineTextAlignment(.center)
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

    private func requestAccessAndShowPicker() async {
        // Precisa ter a permissão ANTES de abrir o picker: o coordinator do
        // PhotoLibraryPicker busca o PHAsset pelo identificador assim que o
        // usuário escolhe um vídeo, e essa busca só enxerga a biblioteca de
        // verdade se o app já estiver autorizado — pedir depois seria
        // tarde demais pra essa busca específica.
        do {
            try await PhotoAssetLoader.requestAuthorization()
            showingPicker = true
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func loadVideoInfo(from phAsset: PHAsset) async {
        state = .loadingInfo(progress: 0)

        do {
            let asset = try await PhotoAssetLoader.loadAVAsset(for: phAsset) { fraction in
                state = .loadingInfo(progress: fraction)
            }

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
            state = .failed("Erro ao ler o vídeo: \(error.localizedDescription)")
        }
    }

    private func cutSilenceAndExport(asset: AVAsset) async {
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

            state = .processing(step: "Exportando corte...")
            let cutURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mov")
            try await VideoExporter.export(asset: composition, to: cutURL)

            // Reabre o arquivo exportado como asset — é sobre ELE que a
            // transcrição e a legenda vão rodar depois (ver PLANO.md seção
            // 3: transcrição roda no vídeo JÁ cortado, não no original).
            state = .cutReady(cutAsset: AVURLAsset(url: cutURL), cutFileURL: cutURL)
        } catch {
            state = .failed("Erro ao processar: \(error.localizedDescription)")
        }
    }

    private func skipCaptionsAndSave(cutFileURL: URL) async {
        captionErrorMessage = nil
        do {
            state = .processing(step: "Salvando na galeria...")
            try await PhotoLibrarySaver.saveVideo(at: cutFileURL)
            try? FileManager.default.removeItem(at: cutFileURL)
            state = .done(message: "Corte exportado e salvo na galeria, sem legenda.")
        } catch {
            // Volta pro cutReady em vez de .failed: o corte continua no
            // mesmo cutFileURL, então dá pra tentar salvar de novo (ou
            // aplicar legenda) sem refazer o corte inteiro.
            captionErrorMessage = error.localizedDescription
            state = .cutReady(cutAsset: AVURLAsset(url: cutFileURL), cutFileURL: cutFileURL)
        }
    }

    private func applyCaptions(cutAsset: AVAsset, cutFileURL: URL, settings: CaptionSettings) async {
        captionErrorMessage = nil
        do {
            state = .processing(step: "Transcrevendo áudio...")
            let transcription = try await Transcriber.transcribe(url: cutFileURL)
            let cues = CaptionCueBuilder.cues(from: transcription.words, settings: settings)
            let serverNotice = transcription.wasOnDevice
                ? ""
                : " (transcrito via servidor da Apple — reconhecimento local indisponível neste aparelho agora)"

            guard !cues.isEmpty else {
                state = .processing(step: "Salvando na galeria...")
                try await PhotoLibrarySaver.saveVideo(at: cutFileURL)
                try? FileManager.default.removeItem(at: cutFileURL)
                state = .done(message: "Nenhuma fala reconhecida pra legendar — corte salvo sem legenda.")
                return
            }

            state = .processing(step: "Montando a legenda...")
            let videoComposition = try await CaptionOverlayBuilder.build(asset: cutAsset, cues: cues, settings: settings)

            state = .processing(step: "Exportando com legenda...")
            let finalURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mov")
            try await VideoExporter.export(asset: cutAsset, videoComposition: videoComposition, to: finalURL)

            state = .processing(step: "Salvando na galeria...")
            try await PhotoLibrarySaver.saveVideo(at: finalURL)
            try? FileManager.default.removeItem(at: finalURL)
            try? FileManager.default.removeItem(at: cutFileURL)

            state = .done(message: "Exportado com legenda e salvo na galeria (\(cues.count) trecho\(cues.count == 1 ? "" : "s"))\(serverNotice).")
        } catch {
            // Mesmo raciocínio do skipCaptionsAndSave: volta pro cutReady
            // (cutFileURL continua válido) em vez de matar o corte já
            // pronto por causa de um erro só na etapa de legenda.
            captionErrorMessage = error.localizedDescription
            state = .cutReady(cutAsset: cutAsset, cutFileURL: cutFileURL)
        }
    }
}

#Preview {
    ContentView()
}
