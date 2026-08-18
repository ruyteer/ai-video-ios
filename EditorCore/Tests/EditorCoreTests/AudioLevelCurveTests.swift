import Foundation
import Testing

@testable import EditorCore

private let sr = 44100.0

@Test("Entradas degeneradas devolvem lista vazia em vez de travar")
func degenerateInputsReturnEmptyLevels() {
    #expect(AudioLevelCurve.levels(samples: [], sampleRate: sr).isEmpty)
    #expect(AudioLevelCurve.levels(samples: [0.5, 0.5], sampleRate: 0).isEmpty)
    #expect(AudioLevelCurve.levels(samples: [0.5, 0.5], sampleRate: -1).isEmpty)
    #expect(AudioLevelCurve.levels(samples: [0.5, 0.5], sampleRate: sr, maxBuckets: 0).isEmpty)
}

@Test("Sinal constante gera curva com todos os valores praticamente iguais")
func constantSignalProducesFlatCurve() {
    let amplitude: Float = 0.5
    let samples = [Float](repeating: amplitude, count: Int(sr * 2))  // 2s

    let levels = AudioLevelCurve.levels(samples: samples, sampleRate: sr)

    #expect(!levels.isEmpty)
    let expectedDB = 20 * log10(Double(amplitude))
    for value in levels {
        #expect(abs(value - expectedDB) < 1e-6)
    }
}

@Test("Número de baldes nunca passa de maxBuckets")
func neverExceedsMaxBuckets() {
    let samples = [Float](repeating: 0.3, count: Int(sr * 10))  // 10s

    let levels = AudioLevelCurve.levels(samples: samples, sampleRate: sr, maxBuckets: 50)

    #expect(levels.count <= 50)
    #expect(!levels.isEmpty)
}

@Test("Áudio bem menor que maxBuckets ainda devolve pelo menos um valor, sem passar da contagem de amostras")
func tinyAudioStillProducesAtLeastOneValue() {
    let samples = [Float](repeating: 0.4, count: 10)

    let levels = AudioLevelCurve.levels(samples: samples, sampleRate: sr, maxBuckets: 200)

    #expect(levels.count >= 1)
    #expect(levels.count <= samples.count)
}
