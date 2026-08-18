import Foundation

/// Uma palavra transcrita com o intervalo de tempo em que foi falada,
/// relativo ao início do vídeo (já cortado — ver PLANO.md seção 3: a
/// transcrição roda DEPOIS do corte de silêncio). Vem do
/// `SFSpeechRecognizer` no lado `ViralClip`; este tipo em si não depende de
/// nenhum framework da Apple, só carrega o dado.
public struct TranscriptWord: Equatable, Sendable {
    public let text: String
    public let start: Double
    public let end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// Um trecho de legenda pronto pra exibir: texto + janela de tempo em que
/// deve estar na tela. `CaptionOverlayBuilder` (ViralClip) usa isso pra
/// gerar as camadas do Core Animation — nenhuma decisão de layout entra
/// aqui, só o quê mostrar e quando.
public struct CaptionCue: Equatable, Sendable {
    public let start: Double
    public let end: Double
    public let text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }

    public var duration: Double { end - start }
}

public enum CaptionCueBuilder {

    /// Teto de duração de um bloco de frase mesmo sem pausa nenhuma — sem
    /// isso, uma fala corrida e longa viraria um único cue gigante,
    /// ilegível na tela por tempo demais.
    static let maxPhraseDuration: Double = 3.5

    /// Teto de palavras por bloco de frase, pelo mesmo motivo do teto de
    /// duração — evita legenda com linha inteira de texto pequeno.
    static let maxPhraseWordCount = 6

    /// Pausa entre o fim de uma palavra e o início da próxima que conta
    /// como fronteira natural de frase (ex: fim de oração, respiração).
    /// Abaixo disso, a pausa é só cadência normal da fala, não corte de
    /// legenda.
    static let phraseGapThreshold: Double = 0.5

    /// Converte as palavras transcritas em cues prontos pra exibir, de
    /// acordo com o estilo escolhido pelo usuário.
    public static func cues(from words: [TranscriptWord], settings: CaptionSettings) -> [CaptionCue] {
        // Palavra com texto vazio (silêncio marcado como token pelo
        // reconhecedor) ou duração não-positiva (dado degenerado) não vira
        // cue — mostrar um cue de duração zero ou texto vazio não ajuda em
        // nada e só complica quem for renderizar isso depois.
        let validWords = words.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.end > $0.start
        }
        guard !validWords.isEmpty else { return [] }

        switch settings.revealStyle {
        case .wordByWord:
            return validWords.map { CaptionCue(start: $0.start, end: $0.end, text: $0.text) }
        case .phraseBlock:
            return phraseCues(from: validWords)
        }
    }

    // MARK: - phraseBlock

    private static func phraseCues(from words: [TranscriptWord]) -> [CaptionCue] {
        var cues: [CaptionCue] = []
        var current: [TranscriptWord] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined(separator: " ")
            cues.append(CaptionCue(start: first.start, end: last.end, text: text))
            current = []
        }

        for word in words {
            if let first = current.first, let last = current.last {
                let gap = word.start - last.end
                let wouldExceedDuration = (word.end - first.start) > maxPhraseDuration
                let wouldExceedCount = current.count >= maxPhraseWordCount
                if gap >= phraseGapThreshold || wouldExceedDuration || wouldExceedCount {
                    flush()
                }
            }
            current.append(word)
        }
        flush()

        return cues
    }
}
