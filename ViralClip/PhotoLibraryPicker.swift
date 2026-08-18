import SwiftUI
import PhotosUI
import Photos

/// Substitui o `PhotosPicker` do SwiftUI, que por design de privacidade
/// SEMPRE copia o arquivo inteiro pra sandbox do app antes de liberar
/// qualquer acesso — é a causa mais provável do carregamento lento mesmo
/// depois de trocar copyItem por moveItem (o atraso acontece ANTES da nossa
/// closure rodar, no próprio mecanismo de transferência do picker).
///
/// Aqui devolvemos o `PHAsset` selecionado em vez de um arquivo copiado.
/// Com o `PHAsset`, `PhotoAssetLoader.loadAVAsset` pede o `AVAsset` direto
/// via `PHImageManager` — sem cópia forçada — que é como apps de edição de
/// vídeo de verdade abrem vídeo grande quase instantâneo. Custo real dessa
/// troca: precisa de permissão de acesso à biblioteca inteira (`.readWrite`
/// em vez de nenhuma permissão), não só ao que foi selecionado. Pro escopo
/// deste projeto (uso pessoal, só no aparelho do usuário — ver CLAUDE.md)
/// essa troca vale a pena.
struct PhotoLibraryPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var onPick: (PHAsset) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .videos
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        var parent: PhotoLibraryPicker

        init(parent: PhotoLibraryPicker) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            // Fechar via binding (não `picker.dismiss(...)`) é o jeito
            // documentado quando o picker está dentro de um `.sheet` do
            // SwiftUI — deixa o SwiftUI controlar a apresentação em vez de
            // dois mecanismos de dismiss brigarem entre si.
            defer { parent.isPresented = false }

            guard let identifier = results.first?.assetIdentifier else { return }
            let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
            guard let asset = fetchResult.firstObject else { return }
            parent.onPick(asset)
        }
    }
}
