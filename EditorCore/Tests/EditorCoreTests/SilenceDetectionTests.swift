import Foundation
import Testing

@testable import EditorCore

// MARK: - Geradores de sinal

private let sr = 44100.0

/// Onda quadrada de amplitude fixa: cada amostra ao quadrado vale `amplitude²`,
/// então o RMS de qualquer janela é exatamente `amplitude` — o que torna a
/// classificação silêncio/fala previsível na casa do dB, sem depender de fase.
private func signal(amplitude: Float, seconds: Double) -> [Float] {
    let count = Int((seconds * sr).rounded())
    return (0..<count).map { $0.isMultiple(of: 2) ? amplitude : -amplitude }
}

private let speech = signal(amplitude: 0.5, seconds: 1.0)  // ≈ -6 dBFS
private func silence(seconds: Double) -> [Float] { signal(amplitude: 0, seconds: seconds) }

private func isClose(_ a: Double, _ b: Double, tolerance: Double = 1e-9) -> Bool {
    abs(a - b) <= tolerance
}

/// Invariantes que valem pra QUALQUER saída: ordenada, sem sobreposição, sem
/// range degenerado, dentro dos limites do áudio e sem NaN/infinito.
private func expectWellFormed(_ ranges: [KeepRange], totalDuration: Double) {
    for range in ranges {
        #expect(range.start.isFinite && range.end.isFinite)
        #expect(range.start >= 0)
        #expect(range.end <= totalDuration + 1e-9)
        #expect(range.end > range.start)
    }
    for (previous, next) in zip(ranges, ranges.dropFirst()) {
        #expect(next.start > previous.end, "ranges adjacentes/sobrepostos deveriam ter sido mesclados")
    }
}

// MARK: - Casos

@Test("Áudio inteiramente silencioso não devolve nenhum trecho a manter")
func allSilenceProducesNoRanges() {
    #expect(SilenceDetection.keepRanges(samples: silence(seconds: 2.0), sampleRate: sr).isEmpty)
}

@Test("Áudio inteiramente falado devolve um único range cobrindo tudo, sem passar dos limites")
func allSpeechProducesSingleFullRange() {
    let samples = speech + speech
    let ranges = SilenceDetection.keepRanges(samples: samples, sampleRate: sr)

    #expect(ranges.count == 1)
    #expect(isClose(ranges[0].start, 0))
    #expect(isClose(ranges[0].end, 2.0))
    expectWellFormed(ranges, totalDuration: 2.0)
}

@Test("Silêncio mais curto que minSilenceDuration não gera corte")
func shortSilenceIsNotCut() {
    // 0.15 s de pausa, metade do minSilenceDuration default (0.3 s).
    let samples = speech + silence(seconds: 0.15) + speech
    let total = Double(samples.count) / sr

    let ranges = SilenceDetection.keepRanges(samples: samples, sampleRate: sr)

    #expect(ranges.count == 1)
    #expect(isClose(ranges[0].start, 0))
    #expect(isClose(ranges[0].end, total))
    expectWellFormed(ranges, totalDuration: total)
}

@Test("Silêncio mais longo que minSilenceDuration gera dois ranges com padding em cada borda")
func longSilenceSplitsIntoTwoRanges() {
    let samples = speech + silence(seconds: 1.0) + speech  // fala | silêncio | fala, 1 s cada
    let config = SilenceCutConfig()  // padding 0.08

    let ranges = SilenceDetection.keepRanges(samples: samples, sampleRate: sr, config: config)

    #expect(ranges.count == 2)
    #expect(isClose(ranges[0].start, 0.0))
    #expect(isClose(ranges[0].end, 1.0 + config.paddingDuration))
    #expect(isClose(ranges[1].start, 2.0 - config.paddingDuration))
    #expect(isClose(ranges[1].end, 3.0))
    expectWellFormed(ranges, totalDuration: 3.0)
}

@Test("Silêncio nas pontas é descartado, sobrando só a fala com padding")
func leadingAndTrailingSilenceIsTrimmed() {
    let samples = silence(seconds: 1.0) + speech + silence(seconds: 1.0)
    let config = SilenceCutConfig()

    let ranges = SilenceDetection.keepRanges(samples: samples, sampleRate: sr, config: config)

    #expect(ranges.count == 1)
    #expect(isClose(ranges[0].start, 1.0 - config.paddingDuration))
    #expect(isClose(ranges[0].end, 2.0 + config.paddingDuration))
    expectWellFormed(ranges, totalDuration: 3.0)
}

@Test("Padding que faz dois ranges se tocarem os funde num só")
func paddingMergesTouchingRanges() {
    // Pausa de 0.35 s: longa o bastante pra cortar (>= 0.3), mas menor que os
    // 0.4 s que os dois paddings de 0.2 s somam — as margens se encontram.
    let samples = speech + silence(seconds: 0.35) + speech
    let total = Double(samples.count) / sr
    let config = SilenceCutConfig(minSilenceDuration: 0.3, paddingDuration: 0.2)

    let ranges = SilenceDetection.keepRanges(samples: samples, sampleRate: sr, config: config)

    #expect(ranges.count == 1)
    #expect(isClose(ranges[0].start, 0))
    #expect(isClose(ranges[0].end, total))
    expectWellFormed(ranges, totalDuration: total)
}

@Test("Vários cortes seguidos saem ordenados e sem sobreposição")
func multipleCutsStayOrderedAndDisjoint() {
    let samples = speech + silence(seconds: 1.0) + speech + silence(seconds: 1.0) + speech
    let total = Double(samples.count) / sr

    let ranges = SilenceDetection.keepRanges(samples: samples, sampleRate: sr)

    #expect(ranges.count == 3)
    expectWellFormed(ranges, totalDuration: total)
}

@Test("O limiar de -35 dBFS separa fala fraca de ruído de ambiente")
func defaultThresholdSeparatesSpeechFromRoomTone() {
    // -35 dBFS corresponde a amplitude 10^(-35/20) ≈ 0.0178.
    let justAbove = signal(amplitude: 0.02, seconds: 1.0)   // ≈ -33.98 dBFS
    let justBelow = signal(amplitude: 0.015, seconds: 1.0)  // ≈ -36.48 dBFS

    let kept = SilenceDetection.keepRanges(samples: justAbove, sampleRate: sr)
    #expect(kept.count == 1)
    #expect(isClose(kept[0].start, 0))
    #expect(isClose(kept[0].end, 1.0))

    #expect(SilenceDetection.keepRanges(samples: justBelow, sampleRate: sr).isEmpty)
}

@Test("Silêncio digital puro não produz NaN nem -infinito no cálculo de dB")
func digitalSilenceDoesNotProduceNaNOrInfinity() {
    let zeros = [Float](repeating: 0, count: 882)
    let db = SilenceDetection.decibels(ofWindow: zeros[...])

    #expect(db.isFinite)
    #expect(!db.isNaN)
    #expect(db < -100, "silêncio digital tem que ficar MUITO abaixo de qualquer limiar razoável")

    // E a janela vazia (última janela parcial degenerada) também.
    #expect(SilenceDetection.decibels(ofWindow: [Float]()[...]).isFinite)
}

@Test("dBFS bate com a definição 20·log10(rms)")
func decibelsMatchesDefinition() {
    let half = [Float](repeating: 0.5, count: 100)
    #expect(isClose(SilenceDetection.decibels(ofWindow: half[...]), 20 * log10(0.5), tolerance: 1e-6))

    let unity = [Float](repeating: 1.0, count: 100)
    #expect(isClose(SilenceDetection.decibels(ofWindow: unity[...]), 0, tolerance: 1e-6))
}

@Test("Uma amostra NaN na janela cai no piso em vez de propagar NaN pra classificação")
func nanSampleFallsBackToFloorInsteadOfPoisoningComparison() {
    // `max(rms, rmsFloor)` sozinho NÃO barra NaN (a comparação do Swift com
    // NaN é sempre falsa) — sem o guard explícito de `isFinite`, isto
    // devolveria NaN, e `NaN < limiar` é sempre falso, classificando a janela
    // como fala mesmo devendo cair no piso de silêncio.
    var withNaN = [Float](repeating: 0, count: 100)
    withNaN[50] = Float.nan

    let db = SilenceDetection.decibels(ofWindow: withNaN[...])

    #expect(db.isFinite)
    #expect(db < -100, "amostra corrompida tem que cair no piso, não virar 'fala' por engano")
}

@Test("Entradas degeneradas devolvem lista vazia em vez de travar")
func degenerateInputsReturnEmpty() {
    #expect(SilenceDetection.keepRanges(samples: [], sampleRate: sr).isEmpty)
    #expect(SilenceDetection.keepRanges(samples: speech, sampleRate: 0).isEmpty)
    #expect(SilenceDetection.keepRanges(samples: speech, sampleRate: -44100).isEmpty)
}

@Test("Áudio mais curto que uma janela de análise ainda é classificado")
func audioShorterThanOneWindowIsStillClassified() {
    let tiny = signal(amplitude: 0.5, seconds: 0.005)  // 220 amostras, < 882
    let total = Double(tiny.count) / sr

    let ranges = SilenceDetection.keepRanges(samples: tiny, sampleRate: sr)

    #expect(ranges.count == 1)
    #expect(isClose(ranges[0].start, 0))
    #expect(isClose(ranges[0].end, total))
}
