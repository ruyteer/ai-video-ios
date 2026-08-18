import Foundation

/// Como a legenda revela o texto — decisão do usuário na UI, com exemplo
/// visual antes de escolher (ver PLANO.md Fase 2). Cada caso produz uma
/// granularidade de `CaptionCue` bem diferente (ver `CaptionCueBuilder`).
public enum CaptionRevealStyle: Sendable, Hashable {
    /// Uma palavra por vez, grande, sincronizada com a fala — estilo
    /// TikTok/CapCut "palavra flutuante".
    case wordByWord
    /// Frase/trecho inteiro de uma vez, como legenda de filme tradicional.
    case phraseBlock
}

/// Onde a legenda fica posicionada no frame. Só afeta o layout no
/// `CaptionOverlayBuilder` (ViralClip) — não influencia nenhuma lógica pura
/// aqui, é só dado carregado através do pipeline.
public enum CaptionPosition: Sendable, Hashable {
    case centerLower
    case bottomEdge
}

public struct CaptionSettings: Sendable {
    public var revealStyle: CaptionRevealStyle
    public var position: CaptionPosition

    public init(revealStyle: CaptionRevealStyle, position: CaptionPosition) {
        self.revealStyle = revealStyle
        self.position = position
    }
}
