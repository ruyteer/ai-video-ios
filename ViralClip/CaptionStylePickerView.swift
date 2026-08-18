import SwiftUI
import EditorCore

/// Tela de escolha de legenda — o usuário decide estilo e posição aqui,
/// com um exemplo visual (mockup estático, NÃO o vídeo de verdade) antes de
/// aplicar. Decisão explícita do usuário: nenhum estilo "melhor" default
/// escondido, ele vê e escolhe.
struct CaptionStylePickerView: View {
    @Binding var revealStyle: CaptionRevealStyle
    @Binding var position: CaptionPosition
    let onSkip: () -> Void
    let onApply: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Legenda (opcional)")
                .font(.headline)

            CaptionExampleView(revealStyle: revealStyle, position: position)
                .frame(width: 180, height: 320)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(.secondary, lineWidth: 1)
                )

            Picker("Estilo", selection: $revealStyle) {
                Text("Palavra por palavra").tag(CaptionRevealStyle.wordByWord)
                Text("Frase inteira").tag(CaptionRevealStyle.phraseBlock)
            }
            .pickerStyle(.segmented)

            Picker("Posição", selection: $position) {
                Text("Centro-baixo").tag(CaptionPosition.centerLower)
                Text("Borda inferior").tag(CaptionPosition.bottomEdge)
            }
            .pickerStyle(.segmented)

            HStack(spacing: 12) {
                Button("Salvar sem legenda", action: onSkip)
                    .buttonStyle(.bordered)
                Button("Aplicar legenda", action: onApply)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}

/// Mockup estático simulando como a legenda ficaria — não é o vídeo
/// selecionado, só um retângulo escuro no formato de tela vertical com o
/// texto de exemplo posicionado igual ficaria no export de verdade.
private struct CaptionExampleView: View {
    let revealStyle: CaptionRevealStyle
    let position: CaptionPosition

    private var exampleText: String {
        switch revealStyle {
        case .wordByWord: "EXEMPLO"
        case .phraseBlock: "Assim fica um trecho de legenda"
        }
    }

    private var exampleFont: Font {
        switch revealStyle {
        case .wordByWord: .title2.bold()
        case .phraseBlock: .subheadline.bold()
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black

                Text(exampleText)
                    .font(exampleFont)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .shadow(color: .black, radius: 4)
                    .padding(.horizontal, 12)
                    .position(
                        x: geo.size.width / 2,
                        y: position == .centerLower ? geo.size.height * 0.58 : geo.size.height * 0.84
                    )
            }
        }
    }
}

#Preview {
    CaptionStylePickerView(
        revealStyle: .constant(.wordByWord),
        position: .constant(.centerLower),
        onSkip: {},
        onApply: {}
    )
}
