import SwiftUI
import AVFoundation
import Photos
import UIKit
import EditorCore

private enum PipelineState {
    case idle
    case loadingInfo(progress: Double)
    case ready(asset: AVAsset, info: String)
    case analyzingAudio
    /// Áudio já extraído, aguardando o usuário ajustar o limiar e confirmar
    /// o corte. `samples`/`sampleRate` ficam guardados aqui pra não precisar
    /// re-extrair o áudio toda vez que o slider muda — só o corte em si
    /// (`SilenceDetection.keepRanges`) é recalculado, e isso é rápido o
    /// bastante pra rodar a cada movimento do slider sem travar a UI.
    case configuringCut(asset: AVAsset, samples: [Float], sampleRate: Double, levels: [Double])
    case processing(step: String)
    case done(message: String)
    case failed(String)
}

// Fase 1 (PLANO.md seção 6): escolher vídeo → cortar silêncio
// (AVMutableComposition não-destrutiva) → exportar → salvar na galeria.
// O limiar de silêncio é ajustável pelo usuário antes do corte (ver
// LevelCurveChart) — vídeos com ruído de fundo alto podem precisar de um
// limiar diferente do -35dBFS default pra gerar corte nenhum.
struct ContentView: View {
    @State private var showingPicker = false
    @State private var state: PipelineState = .idle
    @State private var cutConfig = SilenceCutConfig()

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header

                pickerCard

                switch state {
                case .idle, .loadingInfo, .ready, .analyzingAudio, .processing:
                    statusCard
                case .configuringCut(let asset, let samples, let sampleRate, let levels):
                    cutConfigCard(asset: asset, samples: samples, sampleRate: sampleRate, levels: levels)
                case .done(let message):
                    resultCard(message: message, systemImage: "checkmark.circle.fill", tint: .green)
                case .failed(let message):
                    resultCard(message: message, systemImage: "exclamationmark.triangle.fill", tint: .red)
                    Button("Recomeçar", action: reset)
                        .buttonStyle(.bordered)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Seções

    private var header: some View {
        VStack(spacing: 4) {
            Text("ViralClip")
                .font(.largeTitle.bold())
            Text("Corte automático de silêncio")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    private var pickerCard: some View {
        VStack(spacing: 12) {
            Button {
                Task { await requestAccessAndShowPicker() }
            } label: {
                Label("Escolher vídeo", systemImage: "video.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .sheet(isPresented: $showingPicker) {
                PhotoLibraryPicker(isPresented: $showingPicker) { phAsset in
                    Task { await loadVideoInfo(from: phAsset) }
                }
            }

            if case .ready(let asset, _) = state {
                Button {
                    Task { await analyzeAudio(asset: asset) }
                } label: {
                    Label("Analisar áudio", systemImage: "waveform")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .cardStyle()
    }

    @ViewBuilder
    private var statusCard: some View {
        VStack(spacing: 10) {
            switch state {
            case .idle:
                Label("Nenhum vídeo selecionado", systemImage: "film")
                    .foregroundStyle(.secondary)
            case .loadingInfo(let progress):
                ProgressView(value: progress) {
                    Text("Carregando... \(Int(progress * 100))%")
                }
            case .ready(_, let info):
                Label(info, systemImage: "info.circle")
                    .multilineTextAlignment(.leading)
            case .analyzingAudio:
                ProgressView("Analisando áudio...")
            case .processing(let step):
                ProgressView(step)
            default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func cutConfigCard(asset: AVAsset, samples: [Float], sampleRate: Double, levels: [Double]) -> some View {
        let keepRanges = SilenceDetection.keepRanges(samples: samples, sampleRate: sampleRate, config: cutConfig)
        let totalDuration = Double(samples.count) / sampleRate
        let keptDuration = keepRanges.reduce(0) { $0 + $1.duration }
        let cutCount = max(0, keepRanges.count - 1)

        return VStack(alignment: .leading, spacing: 14) {
            Label("Ajustar corte", systemImage: "slider.horizontal.3")
                .font(.headline)

            LevelCurveChart(levels: levels, thresholdDB: Double(cutConfig.silenceThresholdDB))

            VStack(alignment: .leading, spacing: 6) {
                Text("Limiar de silêncio: \(Int(cutConfig.silenceThresholdDB)) dBFS")
                    .font(.subheadline)
                Slider(value: $cutConfig.silenceThresholdDB, in: -55...(-5), step: 1)
                Text("Barras cinza (abaixo da linha vermelha) viram corte. Vídeo com ruído de fundo alto pode precisar de um limiar menos negativo (mais à direita) pra gerar corte de verdade.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(
                keepRanges.isEmpty
                    ? "Com esse limiar, o áudio inteiro seria classificado como silêncio."
                    : String(
                        format: "%d corte%@ · sobra %.0fs de %.0fs originais",
                        cutCount, cutCount == 1 ? "" : "s", keptDuration, totalDuration
                    )
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Button {
                Task { await cutSilenceAndExport(asset: asset, samples: samples, sampleRate: sampleRate) }
            } label: {
                Label("Cortar e exportar", systemImage: "scissors")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(keepRanges.isEmpty)
        }
        .cardStyle()
    }

    private func resultCard(message: String, systemImage: String, tint: Color) -> some View {
        Label(message, systemImage: systemImage)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
    }

    private func reset() {
        cutConfig = SilenceCutConfig()
        state = .idle
    }

    // MARK: - Pipeline

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

    private func analyzeAudio(asset: AVAsset) async {
        state = .analyzingAudio
        do {
            let (samples, sampleRate) = try await AudioSampleExtractor.extractMonoPCM(from: asset)
            let levels = AudioLevelCurve.levels(samples: samples, sampleRate: sampleRate)
            cutConfig = SilenceCutConfig()
            state = .configuringCut(asset: asset, samples: samples, sampleRate: sampleRate, levels: levels)
        } catch {
            state = .failed("Erro ao analisar áudio: \(error.localizedDescription)")
        }
    }

    private func cutSilenceAndExport(asset: AVAsset, samples: [Float], sampleRate: Double) async {
        do {
            let keepRanges = SilenceDetection.keepRanges(samples: samples, sampleRate: sampleRate, config: cutConfig)
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
            try await VideoExporter.export(asset: composition, to: outputURL)

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

private struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private extension View {
    func cardStyle() -> some View { modifier(CardStyle()) }
}

#Preview {
    ContentView()
}
