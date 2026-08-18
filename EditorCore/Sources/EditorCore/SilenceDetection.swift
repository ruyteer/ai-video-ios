import Foundation

/// Parâmetros do corte automático de silêncio.
public struct SilenceCutConfig: Sendable {
    /// Amostras com RMS abaixo disso (em dBFS, valor negativo) contam como silêncio.
    public var silenceThresholdDB: Float
    /// Silêncio mais curto que isso NÃO gera corte (evita cortar toda pausa
    /// natural da fala, só as pausas longas).
    public var minSilenceDuration: Double
    /// Margem mantida em cada borda de um trecho de fala, pra não cortar em
    /// cima da palavra (respiração/plosiva antes/depois do silêncio real).
    public var paddingDuration: Double

    /// O default de -35 dBFS fica entre a fala normal (tipicamente -25 a -12 dBFS
    /// em gravação de celular) e o ruído de ambiente de um cômodo fechado
    /// (tipicamente abaixo de -45 dBFS), com folga dos dois lados.
    public init(
        silenceThresholdDB: Float = -35,
        minSilenceDuration: Double = 0.3,
        paddingDuration: Double = 0.08
    ) {
        self.silenceThresholdDB = silenceThresholdDB
        self.minSilenceDuration = minSilenceDuration
        self.paddingDuration = paddingDuration
    }
}

/// Um trecho do vídeo original a MANTER, em segundos.
public struct KeepRange: Equatable, Sendable {
    public let start: Double  // segundos, relativo ao início do vídeo original
    public let end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    public var duration: Double { end - start }
}

public enum SilenceDetection {

    /// Janela de análise de 20 ms. Escolha: precisa ser longa o bastante pra o RMS
    /// ser estável na frequência fundamental da voz (~85–255 Hz ⇒ 20 ms cobre 2+
    /// ciclos mesmo na voz mais grave), e curta o bastante pra resolver o início e
    /// o fim de uma palavra sem borrar (a menor pausa que nos interessa, 0.3 s,
    /// ainda cabe em 15 janelas). Janelas sem sobreposição: o passo é o próprio
    /// tamanho da janela, porque a granularidade de 20 ms já é bem mais fina que
    /// o `minSilenceDuration` e sobreposição só custaria tempo sem mudar o corte.
    static let analysisWindowDuration: Double = 0.020

    /// Piso de RMS antes do log. Silêncio digital puro (amostras exatamente 0)
    /// daria `log10(0) = -infinito`, que envenena qualquer comparação seguinte
    /// com NaN. Com o piso, ele vira -200 dBFS: continua MUITO abaixo de qualquer
    /// limiar razoável (então é classificado como silêncio, que é o correto),
    /// mas é um número finito.
    static let rmsFloor: Double = 1e-10

    /// Devolve os trechos a MANTER (não os cortados), ordenados por tempo,
    /// sem sobreposição entre eles. Lista vazia = o áudio inteiro é silêncio.
    ///
    /// - Parameters:
    ///   - samples: amostras PCM mono, em ponto flutuante, faixa [-1, 1].
    ///   - sampleRate: taxa de amostragem em Hz (ex: 44100).
    public static func keepRanges(
        samples: [Float],
        sampleRate: Double,
        config: SilenceCutConfig = SilenceCutConfig()
    ) -> [KeepRange] {
        guard sampleRate > 0, sampleRate.isFinite, !samples.isEmpty else { return [] }

        let totalDuration = Double(samples.count) / sampleRate
        let windowSize = max(1, Int((sampleRate * analysisWindowDuration).rounded()))

        let cuts = silenceCuts(
            samples: samples,
            sampleRate: sampleRate,
            windowSize: windowSize,
            totalDuration: totalDuration,
            config: config
        )

        let speech = complement(of: cuts, over: totalDuration)
        return padAndMerge(speech, padding: config.paddingDuration, totalDuration: totalDuration)
    }

    // MARK: - Etapas

    /// Janelas de silêncio consecutivas agrupadas; só as que somam
    /// `minSilenceDuration` ou mais viram corte de verdade — pausa curta entre
    /// palavras é silêncio, mas não é corte.
    private static func silenceCuts(
        samples: [Float],
        sampleRate: Double,
        windowSize: Int,
        totalDuration: Double,
        config: SilenceCutConfig
    ) -> [(start: Double, end: Double)] {
        var cuts: [(start: Double, end: Double)] = []
        // Índice da primeira janela da sequência de silêncio em aberto, se houver.
        var runStart: Int?

        // A última janela pode ser parcial; o RMS usa só as amostras que existem.
        let windowCount = (samples.count + windowSize - 1) / windowSize

        func closeRun(endingBefore windowIndex: Int) {
            guard let first = runStart else { return }
            runStart = nil
            let start = min(Double(first * windowSize) / sampleRate, totalDuration)
            let end = min(Double(windowIndex * windowSize) / sampleRate, totalDuration)
            if end - start >= config.minSilenceDuration {
                cuts.append((start: start, end: end))
            }
        }

        for windowIndex in 0..<windowCount {
            let lower = windowIndex * windowSize
            let upper = min(lower + windowSize, samples.count)
            let isSilent = decibels(ofWindow: samples[lower..<upper]) < Double(config.silenceThresholdDB)

            if isSilent {
                if runStart == nil { runStart = windowIndex }
            } else {
                closeRun(endingBefore: windowIndex)
            }
        }
        closeRun(endingBefore: windowCount)

        return cuts
    }

    /// Complemento dos cortes sobre `[0, totalDuration]` = os trechos de fala.
    private static func complement(
        of cuts: [(start: Double, end: Double)],
        over totalDuration: Double
    ) -> [KeepRange] {
        var speech: [KeepRange] = []
        var cursor = 0.0
        for cut in cuts {
            if cut.start > cursor {
                speech.append(KeepRange(start: cursor, end: cut.start))
            }
            cursor = max(cursor, cut.end)
        }
        if cursor < totalDuration {
            speech.append(KeepRange(start: cursor, end: totalDuration))
        }
        return speech
    }

    /// Expande cada trecho pelo padding e funde o que passar a se tocar.
    ///
    /// O merge não é um caso raro: quando o silêncio cortado é pouco maior que
    /// `2 * paddingDuration`, as margens dos dois lados se encontram no meio dele.
    /// Devolver dois ranges que se tocam faria a composição no app inserir uma
    /// borda de corte sem nenhum frame descartado entre as duas partes.
    private static func padAndMerge(
        _ ranges: [KeepRange],
        padding: Double,
        totalDuration: Double
    ) -> [KeepRange] {
        let padding = max(0, padding)
        var merged: [KeepRange] = []

        for range in ranges {
            let start = max(0, range.start - padding)
            let end = min(totalDuration, range.end + padding)

            if let last = merged.last, start <= last.end {
                merged[merged.count - 1] = KeepRange(start: last.start, end: max(last.end, end))
            } else {
                merged.append(KeepRange(start: start, end: end))
            }
        }

        return merged
    }

    // MARK: - Matemática

    /// RMS da janela convertido pra dBFS. O acumulador é `Double` porque somar
    /// milhares de quadrados em `Float` acumula erro de arredondamento suficiente
    /// pra mover o resultado perto do limiar.
    static func decibels(ofWindow window: ArraySlice<Float>) -> Double {
        guard !window.isEmpty else { return 20 * log10(rmsFloor) }

        var sumOfSquares = 0.0
        for sample in window {
            let value = Double(sample)
            sumOfSquares += value * value
        }

        let rms = (sumOfSquares / Double(window.count)).squareRoot()
        // `max(rms, rmsFloor)` NÃO basta se `rms` for NaN (ex: um sample
        // corrompido vindo do AVAssetReader): a comparação do `max` do Swift
        // com NaN é sempre falsa e devolve o NaN mesmo, não o piso — e daí
        // `20*log10(NaN)` continua NaN, e `NaN < limiar` também é sempre
        // falso, então a janela seria classificada como FALA
        // silenciosamente, mesmo devendo ser tratada como o piso. Checar
        // `isFinite` explicitamente é o que faz o piso valer pra esse caso
        // também, não só pro silêncio digital puro que o motivou.
        let safeRMS = rms.isFinite ? max(rms, rmsFloor) : rmsFloor
        return 20 * log10(safeRMS)
    }
}
