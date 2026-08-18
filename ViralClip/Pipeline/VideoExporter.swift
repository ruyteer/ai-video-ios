import AVFoundation

enum VideoExportError: Error {
    case sessionCreationFailed
    case cancelled
    case failed(String)
}

enum VideoExporter {
    /// Exporta a composição pro `outputURL`. Tenta o preset passthrough
    /// primeiro (remux puro, sem re-encode — o que torna o corte
    /// independente de resolução, ver PLANO.md seção 4); a precisão dele
    /// perto de bordas de GOP ainda não foi medida com vídeo real, então cai
    /// pro preset de maior qualidade (com re-encode) só quando passthrough
    /// nem está disponível pra essa composição — não é a mitigação completa
    /// do risco de precisão descrito no plano, só evita falhar quando
    /// passthrough não é oferecido.
    static func export(composition: AVMutableComposition, to outputURL: URL) async throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let compatiblePresets = AVAssetExportSession.exportPresets(compatibleWith: composition)
        let preset = compatiblePresets.contains(AVAssetExportPresetPassthrough)
            ? AVAssetExportPresetPassthrough
            : AVAssetExportPresetHighestQuality

        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw VideoExportError.sessionCreationFailed
        }
        session.outputURL = outputURL
        session.outputFileType = .mov

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.exportAsynchronously {
                switch session.status {
                case .completed:
                    continuation.resume(returning: ())
                case .cancelled:
                    continuation.resume(throwing: VideoExportError.cancelled)
                default:
                    continuation.resume(
                        throwing: VideoExportError.failed(
                            session.error?.localizedDescription ?? "status inesperado: \(session.status.rawValue)"
                        )
                    )
                }
            }
        }
    }
}
