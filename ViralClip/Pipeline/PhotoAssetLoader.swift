import Photos
import AVFoundation

enum PhotoAssetLoadError: LocalizedError {
    case notAuthorized
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Sem permissão pra acessar a galeria. Ative em Ajustes > ViralClip > Fotos (Acesso Total)."
        case .requestFailed(let reason):
            return "Falha ao carregar o vídeo da galeria: \(reason)"
        }
    }
}

enum PhotoAssetLoader {
    /// Pede acesso à biblioteca inteira (`.readWrite`), não só ao item
    /// selecionado — troca deliberada em relação ao `PhotosPicker` padrão
    /// (ver `PhotoLibraryPicker`): é o que permite `loadAVAsset` abaixo
    /// pegar o vídeo sem cópia forçada.
    static func requestAuthorization() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw PhotoAssetLoadError.notAuthorized
        }
    }

    /// Pede o `AVAsset` do PHAsset selecionado. Pra um vídeo já baixado no
    /// aparelho, o PhotosKit normalmente devolve isso quase na hora, sem
    /// duplicar o arquivo — bem diferente do `PhotosPicker`/`Transferable`,
    /// que sempre força uma cópia completa antes de liberar qualquer
    /// acesso. `isNetworkAccessAllowed = true` cobre o caso de vídeo só no
    /// iCloud (aí sim precisa baixar de rede, inevitável) — o
    /// `progressHandler` reporta esse download quando ele acontece.
    static func loadAVAsset(
        for asset: PHAsset,
        progressHandler: @escaping (Double) -> Void
    ) async throws -> AVAsset {
        let options = PHVideoRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.progressHandler = { fraction, _, _, _ in
            DispatchQueue.main.async { progressHandler(fraction) }
        }

        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                if let avAsset {
                    continuation.resume(returning: avAsset)
                    return
                }
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                if cancelled {
                    continuation.resume(throwing: PhotoAssetLoadError.requestFailed("Cancelado."))
                    return
                }
                let underlyingError = info?[PHImageErrorKey] as? Error
                continuation.resume(
                    throwing: PhotoAssetLoadError.requestFailed(underlyingError?.localizedDescription ?? "motivo desconhecido")
                )
            }
        }
    }
}
