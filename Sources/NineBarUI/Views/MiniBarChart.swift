import Foundation
import SwiftUI
import NineBarCore

public struct MiniBarChart: View {
    public let bars: [Bar]
    public let sequence: SequenceSnapshot

    public init(bars: [Bar], sequence: SequenceSnapshot) {
        self.bars = Array(bars.suffix(60))
        self.sequence = sequence
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Canvas { context, size in
                drawBars(in: context, size: size)
            }
            .frame(height: 160)
            .background(Color.primary.opacity(0.045))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                Text(sequence.phase == .candidate
                    ? L10n.t("候选第\(sequence.count)根，尚未收盘确认", "Candidate bar \(sequence.count), not closed yet")
                    : L10n.t("已确认第\(sequence.count)根", "Bar \(sequence.count) confirmed"))
                Spacer()
                Text(L10n.t("最近 \(bars.count) 根", "Last \(bars.count) bars"))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func drawBars(in context: GraphicsContext, size: CGSize) {
        guard !bars.isEmpty else {
            context.draw(
                Text(L10n.t("暂无可绘制K线", "No bars to draw")).font(.caption).foregroundStyle(.secondary),
                at: CGPoint(x: size.width / 2, y: size.height / 2)
            )
            return
        }

        let highest = bars.map(\.high).max() ?? 0
        let lowest = bars.map(\.low).min() ?? 0
        let padding = max((highest - lowest) * 0.08, 0.01)
        let upper = highest + padding
        let lower = lowest - padding
        let range = max(upper - lower, 0.01)
        let horizontalPadding: CGFloat = 6
        let usableWidth = max(size.width - horizontalPadding * 2, 1)
        let spacing = usableWidth / CGFloat(max(bars.count, 1))
        let bodyWidth = max(1, min(5, spacing * 0.62))
        let labels = MiniBarChartSequenceLabels.labels(for: bars, sequence: sequence)
        let labelsByBarStart = Dictionary(uniqueKeysWithValues: labels.map { ($0.barStart, $0.value) })

        func y(_ price: Double) -> CGFloat {
            let ratio = (upper - price) / range
            return max(3, min(size.height - 3, CGFloat(ratio) * (size.height - 6) + 3))
        }

        if sequence.sequenceStart <= sequence.lastBarEnd {
            let shadedBars = bars.filter { $0.end >= sequence.sequenceStart && $0.end <= sequence.lastBarEnd }
            if let first = shadedBars.first, let last = shadedBars.last,
               let firstIndex = bars.firstIndex(where: { $0.start == first.start }),
               let lastIndex = bars.firstIndex(where: { $0.start == last.start }) {
                let x = horizontalPadding + CGFloat(firstIndex) * spacing
                let width = CGFloat(lastIndex - firstIndex + 1) * spacing
                context.fill(
                    Path(CGRect(x: x, y: 0, width: width, height: size.height)),
                    with: .color(Color.accentColor.opacity(0.08))
                )
            }
        }

        for (index, bar) in bars.enumerated() {
            let x = horizontalPadding + (CGFloat(index) + 0.5) * spacing
            var stem = Path()
            stem.move(to: CGPoint(x: x, y: y(bar.high)))
            stem.addLine(to: CGPoint(x: x, y: y(bar.low)))
            context.stroke(stem, with: .color(Color.secondary.opacity(0.7)), lineWidth: 1)

            let openY = y(bar.open)
            let closeY = y(bar.close)
            let isRising = bar.close >= bar.open
            let body = CGRect(
                x: x - bodyWidth / 2,
                y: min(openY, closeY),
                width: bodyWidth,
                height: max(abs(closeY - openY), 1)
            )
            context.fill(
                Path(roundedRect: body, cornerRadius: 1),
                with: .color(isRising ? .red : .green)
            )

            if let label = labelsByBarStart[bar.start] {
                let labelY: CGFloat
                switch sequence.direction {
                case .top:
                    labelY = max(8, y(bar.high) - 9)
                case .bottom:
                    labelY = min(size.height - 8, y(bar.low) + 9)
                }
                context.draw(
                    Text("\(label)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(sequence.direction == .top ? .red : .green),
                    at: CGPoint(x: x, y: labelY)
                )
            }
        }
    }
}

public struct MiniBarChartSequenceLabel: Equatable, Sendable {
    public let barStart: Date
    public let value: Int

    public init(barStart: Date, value: Int) {
        self.barStart = barStart
        self.value = value
    }
}

public enum MiniBarChartSequenceLabels {
    public static func labels(
        for bars: [Bar],
        sequence: SequenceSnapshot,
        clock: TradingSessionClock = TradingSessionClock()
    ) -> [MiniBarChartSequenceLabel] {
        let maximumValue = min(max(sequence.count, 0), 9)
        guard maximumValue > 0,
              clock.isMinuteBarStart(sequence.sequenceStart),
              let sequenceIndex = clock.minuteIndex(sequence.sequenceStart) else {
            return []
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!

        return bars
            .filter {
                $0.isClosed
                    && $0.instrumentID == sequence.instrumentID
                    && $0.timeframe == sequence.timeframe
                    && $0.start >= sequence.sequenceStart
                    && $0.end <= sequence.lastBarEnd
                    && calendar.isDate($0.start, inSameDayAs: sequence.sequenceStart)
                    && clock.isMinuteBarStart($0.start)
            }
            .sorted { $0.start < $1.start }
            .compactMap { bar in
                guard let barIndex = clock.minuteIndex(bar.start) else { return nil }
                let offset = barIndex - sequenceIndex
                guard offset >= 0,
                      offset % sequence.timeframe.rawValue == 0 else {
                    return nil
                }

                let value = (offset / sequence.timeframe.rawValue) + 1
                guard value <= maximumValue else { return nil }
                return MiniBarChartSequenceLabel(barStart: bar.start, value: value)
            }
    }
}
