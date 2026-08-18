import AVFoundation

enum VideoExportError: LocalizedError {
    case sessionCreationFailed
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .sessionCreationFailed:
            return "Não foi possível preparar o export."
        case .cancelled:
            return "Export cancelado."
        case .failed(let reason):
            return "Falha ao exportar o vídeo: \(reason)"
        }
    }
}

enum VideoExporter {
    /// Exporta `asset` pro `outputURL`. Sem `videoComposition`, tenta o
    /// preset passthrough primeiro (remux puro, sem re-encode — o que torna
    /// o corte independente de resolução, ver PLANO.md seção 4); a precisão
    /// dele perto de bordas de GOP ainda não foi medida com vídeo real,
    /// então cai pro preset de maior qualidade (com re-encode) só quando
    /// passthrough nem está disponível pra esse asset — não é a mitigação
    /// completa do risco de precisão descrito no plano, só evita falhar
    /// quando passthrough não é oferecido.
    ///
    /// Com `videoComposition` (legenda queimada via Core Animation, ver
    /// `CaptionOverlayBuilder`), passthrough nem é tentado — é
    /// estruturalmente incompatível, porque passthrough significa "não
    /// tocar em pixel nenhum" e a legenda É pixel novo sendo desenhado.
    static func export(
        asset: AVAsset,
        videoComposition: AVVideoComposition? = nil,
        to outputURL: URL
    ) async throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let preset: String
        if videoComposition != nil {
            preset = AVAssetExportPresetHighestQuality
        } else {
            let compatiblePresets = AVAssetExportSession.exportPresets(compatibleWith: asset)
            preset = compatiblePresets.contains(AVAssetExportPresetPassthrough)
                ? AVAssetExportPresetPassthrough
                : AVAssetExportPresetHighestQuality
        }

        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw VideoExportError.sessionCreationFailed
        }
        session.outputURL = outputURL
        session.outputFileType = .mov
        session.videoComposition = videoComposition

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
