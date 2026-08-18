import AVFoundation

enum AudioSampleExtractionError: Error {
    case noAudioTrack
    case readerFailed(String)
}

/// Única parte do pipeline que toca em `AVAsset` pra extrair áudio — o
/// resultado (amostras + sampleRate) é passado pro `EditorCore.SilenceDetection`,
/// que é lógica pura e já testada no Windows (ver PLANO.md seção 4.1).
enum AudioSampleExtractor {

    /// Sample rate usado só pra análise de silêncio (não pro export final —
    /// o export usa o áudio original intacto via composição). RMS não precisa
    /// de fidelidade alta, então baixar a taxa de amostragem aqui mantém a
    /// leitura (e o loop de janelas do EditorCore) rápidos mesmo em vídeos
    /// longos, sem afetar a qualidade do corte.
    static let analysisSampleRate: Double = 16000

    static func extractMonoPCM(from asset: AVAsset) async throws -> (samples: [Float], sampleRate: Double) {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioSampleExtractionError.noAudioTrack
        }

        let reader = try AVAssetReader(asset: asset)

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: analysisSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            throw AudioSampleExtractionError.readerFailed("canAdd(output) retornou false")
        }
        reader.add(output)

        guard reader.startReading() else {
            throw AudioSampleExtractionError.readerFailed(
                reader.error?.localizedDescription ?? "startReading() falhou sem erro reportado"
            )
        }

        var samples: [Float] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            let floatCount = length / MemoryLayout<Float>.size
            guard floatCount > 0 else { continue }

            var chunk = [Float](repeating: 0, count: floatCount)
            let status = chunk.withUnsafeMutableBytes { rawBuffer -> OSStatus in
                CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: 0,
                    dataLength: length,
                    destination: rawBuffer.baseAddress!
                )
            }
            guard status == noErr else {
                throw AudioSampleExtractionError.readerFailed("CMBlockBufferCopyDataBytes falhou: \(status)")
            }
            samples.append(contentsOf: chunk)
        }

        // `.completed` é o único status de sucesso; `.reading` não deveria
        // sobrar aqui porque o `while` só sai quando `copyNextSampleBuffer`
        // devolve nil, o que o reader só faz ao terminar ou falhar.
        if reader.status == .failed {
            throw AudioSampleExtractionError.readerFailed(
                reader.error?.localizedDescription ?? "leitura terminou com status .failed"
            )
        }

        return (samples, analysisSampleRate)
    }
}
