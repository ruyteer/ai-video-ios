import Foundation
import Testing

@testable import EditorCore

// MARK: - Geradores

/// `count` palavras de 0.2s cada, faladas de corrido (sem pausa alguma
/// entre elas) começando em `start`.
private func words(_ texts: [String], start: Double = 0, wordDuration: Double = 0.2, gap: Double = 0.0) -> [TranscriptWord] {
    var result: [TranscriptWord] = []
    var cursor = start
    for text in texts {
        result.append(TranscriptWord(text: text, start: cursor, end: cursor + wordDuration))
        cursor += wordDuration + gap
    }
    return result
}

private func isClose(_ a: Double, _ b: Double, tolerance: Double = 1e-9) -> Bool {
    abs(a - b) <= tolerance
}

// MARK: - wordByWord

@Test("wordByWord gera um cue por palavra, preservando texto e timing exatos")
func wordByWordProducesOneCuePerWord() {
    let input = words(["oi", "tudo", "bem"], gap: 0.5)
    let settings = CaptionSettings(revealStyle: .wordByWord, position: .centerLower)

    let cues = CaptionCueBuilder.cues(from: input, settings: settings)

    #expect(cues.count == 3)
    for (cue, word) in zip(cues, input) {
        #expect(cue.text == word.text)
        #expect(isClose(cue.start, word.start))
        #expect(isClose(cue.end, word.end))
    }
}

@Test("wordByWord descarta palavras com texto vazio ou duração não-positiva")
func wordByWordDropsDegenerateWords() {
    let input = [
        TranscriptWord(text: "oi", start: 0, end: 0.2),
        TranscriptWord(text: "   ", start: 0.2, end: 0.4),
        TranscriptWord(text: "vazia-mas-duracao-zero", start: 0.4, end: 0.4),
        TranscriptWord(text: "duracao-negativa", start: 0.6, end: 0.5),
        TranscriptWord(text: "tchau", start: 0.7, end: 0.9),
    ]
    let settings = CaptionSettings(revealStyle: .wordByWord, position: .centerLower)

    let cues = CaptionCueBuilder.cues(from: input, settings: settings)

    #expect(cues.map(\.text) == ["oi", "tchau"])
}

// MARK: - phraseBlock

@Test("phraseBlock junta palavras faladas de corrido num único cue")
func phraseBlockGroupsRunningSpeech() {
    let input = words(["isso", "é", "um", "teste"], gap: 0.05)  // gap curto, abaixo do threshold
    let settings = CaptionSettings(revealStyle: .phraseBlock, position: .bottomEdge)

    let cues = CaptionCueBuilder.cues(from: input, settings: settings)

    #expect(cues.count == 1)
    #expect(cues[0].text == "isso é um teste")
    #expect(isClose(cues[0].start, input.first!.start))
    #expect(isClose(cues[0].end, input.last!.end))
}

@Test("phraseBlock corta um novo cue numa pausa longa (fronteira de frase)")
func phraseBlockSplitsOnLongPause() {
    let firstPhrase = words(["primeira", "frase"], start: 0, gap: 0.05)
    // Claramente acima do phraseGapThreshold (0.5) — testar exatamente no
    // limiar seria frágil por imprecisão de soma de Double.
    let secondStart = firstPhrase.last!.end + 0.8
    let secondPhrase = words(["segunda", "frase"], start: secondStart, gap: 0.05)
    let settings = CaptionSettings(revealStyle: .phraseBlock, position: .centerLower)

    let cues = CaptionCueBuilder.cues(from: firstPhrase + secondPhrase, settings: settings)

    #expect(cues.count == 2)
    #expect(cues[0].text == "primeira frase")
    #expect(cues[1].text == "segunda frase")
}

@Test("phraseBlock NÃO corta numa pausa curta, só cadência normal da fala")
func phraseBlockDoesNotSplitOnShortPause() {
    let input = words(["a", "b", "c"], gap: 0.1)  // < phraseGapThreshold (0.5)
    let settings = CaptionSettings(revealStyle: .phraseBlock, position: .centerLower)

    let cues = CaptionCueBuilder.cues(from: input, settings: settings)

    #expect(cues.count == 1)
}

@Test("phraseBlock corta por duração máxima mesmo sem nenhuma pausa")
func phraseBlockSplitsOnMaxDurationWithoutPause() {
    // Cada palavra dura 1s, de corrido — a 4ª palavra ultrapassa os 3.5s
    // de teto antes de qualquer pausa acontecer.
    let input = words(["um", "dois", "tres", "quatro", "cinco"], wordDuration: 1.0, gap: 0.0)
    let settings = CaptionSettings(revealStyle: .phraseBlock, position: .centerLower)

    let cues = CaptionCueBuilder.cues(from: input, settings: settings)

    #expect(cues.count > 1, "deveria ter cortado antes de acumular 5s de fala corrida num só cue")
    for cue in cues {
        #expect(cue.duration <= 3.5 + 1e-9)
    }
}

@Test("phraseBlock corta por contagem máxima de palavras mesmo sem pausa nem estourar duração")
func phraseBlockSplitsOnMaxWordCount() {
    // Palavras curtas e rápidas, de corrido: nunca estoura os 3.5s, mas
    // passa de 6 palavras por bloco.
    let input = words(Array(repeating: "oi", count: 10), wordDuration: 0.1, gap: 0.0)
    let settings = CaptionSettings(revealStyle: .phraseBlock, position: .centerLower)

    let cues = CaptionCueBuilder.cues(from: input, settings: settings)

    #expect(cues.count == 2, "10 palavras com teto de 6 deveria virar 2 blocos (6 + 4)")
    #expect(cues[0].text.split(separator: " ").count == 6)
    #expect(cues[1].text.split(separator: " ").count == 4)
}

@Test("Lista vazia ou só com palavras degeneradas devolve nenhum cue")
func emptyOrDegenerateInputProducesNoCues() {
    let settings = CaptionSettings(revealStyle: .phraseBlock, position: .centerLower)
    #expect(CaptionCueBuilder.cues(from: [], settings: settings).isEmpty)

    let onlyDegenerate = [TranscriptWord(text: "", start: 0, end: 1)]
    #expect(CaptionCueBuilder.cues(from: onlyDegenerate, settings: settings).isEmpty)
}

@Test("Cues de phraseBlock saem ordenados e sem sobreposição")
func phraseBlockCuesStayOrderedAndDisjoint() {
    let firstPhrase = words(["a", "b"], start: 0, gap: 0.05)
    let secondStart = firstPhrase.last!.end + 0.6
    let secondPhrase = words(["c", "d"], start: secondStart, gap: 0.05)
    let settings = CaptionSettings(revealStyle: .phraseBlock, position: .centerLower)

    let cues = CaptionCueBuilder.cues(from: firstPhrase + secondPhrase, settings: settings)

    for (previous, next) in zip(cues, cues.dropFirst()) {
        #expect(next.start >= previous.end)
    }
}
