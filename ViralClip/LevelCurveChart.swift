import SwiftUI

/// Visualização do nível de áudio (dBFS) do vídeo ao longo do tempo, com uma
/// linha marcando o limiar de silêncio atual — barras abaixo da linha são o
/// que seria cortado com esse limiar, coloridas diferente das que ficam.
/// Só visualização; a decisão de corte de verdade é sempre
/// `SilenceDetection.keepRanges` (EditorCore), não este gráfico.
struct LevelCurveChart: View {
    let levels: [Double]
    let thresholdDB: Double

    private let minDB: Double = -60
    private let maxDB: Double = 0

    private func normalized(_ db: Double) -> Double {
        guard db.isFinite else { return 0 }
        let clamped = min(max(db, minDB), maxDB)
        return (clamped - minDB) / (maxDB - minDB)
    }

    var body: some View {
        Canvas { context, size in
            guard !levels.isEmpty else { return }

            let barWidth = size.width / CGFloat(levels.count)
            for (index, db) in levels.enumerated() {
                let barHeight = size.height * CGFloat(normalized(db))
                let rect = CGRect(
                    x: CGFloat(index) * barWidth,
                    y: size.height - barHeight,
                    width: max(1, barWidth - 1),
                    height: barHeight
                )
                let isBelowThreshold = db < thresholdDB
                context.fill(
                    Path(rect),
                    with: .color(isBelowThreshold ? Color.gray.opacity(0.35) : Color.accentColor)
                )
            }

            let thresholdY = size.height * (1 - CGFloat(normalized(thresholdDB)))
            var line = Path()
            line.move(to: CGPoint(x: 0, y: thresholdY))
            line.addLine(to: CGPoint(x: size.width, y: thresholdY))
            context.stroke(line, with: .color(.red), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        }
        .frame(height: 90)
    }
}

#Preview {
    LevelCurveChart(
        levels: (0..<80).map { i in Double.random(in: -55...(-5)) + (i % 20 == 0 ? -15 : 0) },
        thresholdDB: -35
    )
    .padding()
}
