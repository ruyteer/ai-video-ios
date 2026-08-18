import Foundation

/// Curva de nível (dBFS) do áudio ao longo do tempo — só pra o usuário
/// VISUALIZAR onde o vídeo tem ruído de fundo alto antes de escolher o
/// limiar de corte (ver `SilenceCutConfig.silenceThresholdDB`). Não decide
/// nada sozinha; quem decide o que é silêncio continua sendo
/// `SilenceDetection.keepRanges`, chamado de novo com o limiar escolhido.
public enum AudioLevelCurve {
    /// Um valor de dBFS por "balde" de tempo, de tamanho aproximadamente
    /// `bucketDuration`. Número de baldes é limitado por `maxBuckets`
    /// (default 200) pra manter o gráfico leve de desenhar/rolar
    /// independente da duração do vídeo — um vídeo de 10 minutos não
    /// precisa de 10 minutos de barras de 0,1s pra dar pra ver onde está o
    /// ruído.
    public static func levels(
        samples: [Float],
        sampleRate: Double,
        maxBuckets: Int = 200
    ) -> [Double] {
        guard sampleRate > 0, sampleRate.isFinite, !samples.isEmpty, maxBuckets > 0 else { return [] }

        let bucketSize = max(1, samples.count / maxBuckets)
        var result: [Double] = []
        var index = 0
        while index < samples.count {
            let upper = min(index + bucketSize, samples.count)
            result.append(SilenceDetection.decibels(ofWindow: samples[index..<upper]))
            index = upper
        }
        return result
    }
}
