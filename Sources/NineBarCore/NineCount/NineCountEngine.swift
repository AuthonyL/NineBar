import Foundation

public struct NineCountScanResult: Equatable, Sendable {
    public let active: [SequenceSnapshot]
    public let completions: [ConfirmedSignal]

    public init(active: [SequenceSnapshot], completions: [ConfirmedSignal]) {
        self.active = active
        self.completions = completions
    }
}

public struct NineCountEngine: Sendable {
    public let clock: TradingSessionClock

    public init(clock: TradingSessionClock = TradingSessionClock()) {
        self.clock = clock
    }

    public func scan(completedBars: [Bar], liveBar: Bar?) -> NineCountScanResult {
        let bars = completedBars
            .filter(\.isClosed)
            .sorted { lhs, rhs in
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                if lhs.end != rhs.end { return lhs.end < rhs.end }
                if lhs.instrumentID != rhs.instrumentID { return lhs.instrumentID < rhs.instrumentID }
                return lhs.timeframe.rawValue < rhs.timeframe.rawValue
            }
        var top = Tracker(direction: .top)
        var bottom = Tracker(direction: .bottom)
        var completions: [ConfirmedSignal] = []
        var segmentStart = 0

        for index in bars.indices {
            let current = bars[index]
            if index > 0 && !isConsecutiveContext(previous: bars[index - 1], next: current) {
                top.reset()
                bottom.reset()
                segmentStart = index
            }

            guard index - segmentStart >= 4 else { continue }
            let reference = bars[index - 4]
            if let completion = top.advance(
                holds: current.close > reference.close,
                bar: current,
                confirmOnNine: true
            ) {
                completions.append(completion)
            }
            if let completion = bottom.advance(
                holds: current.close < reference.close,
                bar: current,
                confirmOnNine: true
            ) {
                completions.append(completion)
            }
        }

        guard let liveBar, isValid(liveBar: liveBar, after: bars) else {
            return NineCountScanResult(
                active: activeSnapshots(top: top, bottom: bottom, phase: nil),
                completions: completions
            )
        }

        let reference = bars[bars.count - 4]
        var projectedTop = top
        var projectedBottom = bottom
        _ = projectedTop.advance(
            holds: liveBar.close > reference.close,
            bar: liveBar,
            confirmOnNine: false
        )
        _ = projectedBottom.advance(
            holds: liveBar.close < reference.close,
            bar: liveBar,
            confirmOnNine: false
        )

        return NineCountScanResult(
            active: activeSnapshots(top: projectedTop, bottom: projectedBottom, phase: .candidate),
            completions: completions
        )
    }

    private func isConsecutiveContext(previous: Bar, next: Bar) -> Bool {
        previous.instrumentID == next.instrumentID
            && previous.timeframe == next.timeframe
            && clock.areConsecutive(
                previousStart: previous.start,
                nextStart: next.start,
                timeframe: previous.timeframe
            )
    }

    private func isValid(liveBar: Bar, after bars: [Bar]) -> Bool {
        guard !liveBar.isClosed, bars.count >= 4, let previous = bars.last,
              previous.instrumentID == liveBar.instrumentID,
              previous.timeframe == liveBar.timeframe,
              liveBar.end == liveBar.start.addingTimeInterval(Double(liveBar.timeframe.rawValue * 60)),
              clock.areConsecutive(
                  previousStart: previous.start,
                  nextStart: liveBar.start,
                  timeframe: liveBar.timeframe
              ) else {
            return false
        }

        let firstRequiredIndex = bars.count - 4
        guard firstRequiredIndex < bars.count - 1 else { return true }
        for index in (firstRequiredIndex + 1)..<bars.count {
            guard isConsecutiveContext(previous: bars[index - 1], next: bars[index]) else {
                return false
            }
        }
        return true
    }

    private func activeSnapshots(
        top: Tracker,
        bottom: Tracker,
        phase: SequencePhase?
    ) -> [SequenceSnapshot] {
        [top.snapshot(phase: phase), bottom.snapshot(phase: phase)].compactMap { $0 }
    }
}

private struct Tracker {
    let direction: SignalDirection
    private(set) var rawCount = 0
    private(set) var sequenceStart: Date?
    private(set) var extremePrice: Double?
    private(set) var lastBar: Bar?
    private(set) var emitted = false

    mutating func reset() {
        rawCount = 0
        sequenceStart = nil
        extremePrice = nil
        lastBar = nil
        emitted = false
    }

    mutating func advance(holds: Bool, bar: Bar, confirmOnNine: Bool) -> ConfirmedSignal? {
        guard holds else {
            reset()
            return nil
        }

        if rawCount == 0 {
            rawCount = 1
            sequenceStart = bar.start
            extremePrice = price(from: bar)
            lastBar = bar
        } else if rawCount < 9 {
            rawCount += 1
            extremePrice = updatedExtreme(with: bar)
            lastBar = bar
        } else {
            rawCount += 1
            lastBar = bar
        }

        guard rawCount == 9, !emitted, confirmOnNine,
              let sequenceStart, let extremePrice, let lastBar else {
            return nil
        }
        emitted = true
        return ConfirmedSignal(
            instrumentID: lastBar.instrumentID,
            timeframe: lastBar.timeframe,
            direction: direction,
            sequenceStart: sequenceStart,
            lastBarEnd: lastBar.end,
            lastClose: lastBar.close,
            extremePrice: extremePrice,
            sourceUpdatedAt: lastBar.sourceUpdatedAt,
            return5m: nil,
            return15m: nil,
            return30m: nil,
            return60m: nil
        )
    }

    func snapshot(phase override: SequencePhase?) -> SequenceSnapshot? {
        guard rawCount > 0, let sequenceStart, let extremePrice, let lastBar else {
            return nil
        }
        return SequenceSnapshot(
            instrumentID: lastBar.instrumentID,
            timeframe: lastBar.timeframe,
            direction: direction,
            count: min(rawCount, 9),
            phase: override ?? (emitted ? .confirmed : .counting),
            sequenceStart: sequenceStart,
            lastBarEnd: lastBar.end,
            extremePrice: extremePrice,
            lastClose: lastBar.close
        )
    }

    private func price(from bar: Bar) -> Double {
        direction == .top ? bar.high : bar.low
    }

    private func updatedExtreme(with bar: Bar) -> Double {
        guard let extremePrice else { return price(from: bar) }
        switch direction {
        case .top:
            return max(extremePrice, bar.high)
        case .bottom:
            return min(extremePrice, bar.low)
        }
    }
}
