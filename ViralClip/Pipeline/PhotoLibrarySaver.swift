import Photos

enum PhotoLibrarySaveError: LocalizedError {
    case notAuthorized

    var errorDescription: String? {
        "Sem permissão pra salvar na galeria. Ative em Ajustes > ViralClip > Fotos."
    }
}

enum PhotoLibrarySaver {
    static func saveVideo(at url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw PhotoLibrarySaveError.notAuthorized
        }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }
}
