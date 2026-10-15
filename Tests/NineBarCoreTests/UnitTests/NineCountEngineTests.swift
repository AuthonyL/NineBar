import Testing
@testable import NineBarCore

@Suite("NineCountEngineTests")
struct NineCountEngineTests {
    private let engine = NineCountEngine()

    @Test("top nine compares each close with the close four bars earlier")
    func topNineUsesCloseFourBarsEarlier() {
        let closes = [10, 10, 10, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19].map(Double.init)

        let result = engine.scan(completedBars: bars(closes), liveBar: nil)

        #expect(result.active.count == 1)
        #expect(result.active.first?.direction == .top)
        #expect(result.active.first?.count == 9)
        #expect(result.active.first?.phase == .confirmed)
        #expect(result.completions.count == 1)
    }

    @Test("bottom nine is symmetric with top nine")
    func bottomNineUsesCloseFourBarsEarlier() {
        let closes = [20, 20, 20, 20, 19, 18, 17, 16, 15, 14, 13, 12, 11].map(Double.init)

        let result = engine.scan(completedBars: bars(closes), liveBar: nil)

        #expect(result.active.count == 1)
        #expect(result.active.first?.direction == .bottom)
        #expect(result.active.first?.count == 9)
        #expect(result.active.first?.phase == .confirmed)
        #expect(result.completions.count == 1)
    }

    @Test("candle color and adjacent movement do not affect the top count")
    func oppositeColorBarsStillCountForTop() {
        let closes = [100, 99, 98, 97, 101, 100, 102, 101, 103, 102, 104, 103, 105].map(Double.init)
        let opens = closes.enumerated().map { index, close in
            index.isMultiple(of: 2) ? close + 3 : close - 3
        }

        let result = engine.scan(completedBars: bars(closes, opens: opens), liveBar: nil)

        #expect(result.active.map(\.direction) == [.top])
        #expect(result.active.first?.count == 9)
    }

    @Test("candle color and adjacent movement do not affect the bottom count")
    func oppositeColorBarsStillCountForBottom() {
        let closes = [100, 101, 102, 103, 99, 100, 98, 99, 97, 98, 96, 97, 95].map(Double.init)
        let opens = closes.enumerated().map { index, close in
            index.isMultiple(of: 2) ? close - 3 : close + 3
        }

        let result = engine.scan(completedBars: bars(closes, opens: opens), liveBar: nil)

        #expect(result.active.map(\.direction) == [.bottom])
        #expect(result.active.first?.count == 9)
    }

    @Test("equality resets both directions")
    func equalityBreaksSequence() {
        let closes = [10, 10, 10, 10, 11, 12, 13, 14, 11].map(Double.init)

        let result = engine.scan(completedBars: bars(closes), liveBar: nil)

        #expect(result.active.isEmpty)
        #expect(result.completions.isEmpty)
    }

    @Test("bars after nine retain one capped nonoverlapping signal")
    func barsAfterNineDoNotStartOverlappingSignal() {
        let closes = ([10, 10, 10, 10] + Array(11...24)).map(Double.init)

        let result = engine.scan(completedBars: bars(closes), liveBar: nil)

        #expect(result.completions.count == 1)
        #expect(result.active.first?.count == 9)
        #expect(result.active.first?.phase == .confirmed)
        #expect(result.active.first?.lastClose == 24)
        #expect(result.active.first?.lastBarEnd == bars(closes).last?.end)
        #expect(result.completions.first?.lastClose == 19)
        #expect(result.completions.first?.lastBarEnd == bars(closes)[12].end)
    }

    @Test("a broken sequence can later produce a new completion")
    func separatedSequencesBothComplete() {
        let first = [10, 10, 10, 10] + Array(11...19)
        let breakAndWarmup = [1, 1, 1, 1]
        let second = Array(2...10)
        let closes = (first + breakAndWarmup + second).map(Double.init)

        let result = engine.scan(completedBars: bars(closes), liveBar: nil)

        #expect(result.completions.count == 2)
        #expect(result.completions.map(\.direction) == [.top, .top])
        #expect(result.completions.map(\.lastClose) == [19, 10])
        #expect(result.active.first?.count == 9)
    }

    @Test("a missing minute resets count and requires four fresh warmup bars")
    func missingMinuteResetsAndRequiresFreshWarmup() {
        let first = bars([10, 10, 10, 10, 11, 12, 13].map(Double.init))
        let second = bars([20, 20, 20, 20, 21].map(Double.init), startingAt: "2026-09-01T10:00:00+08:00")

        let result = engine.scan(completedBars: first + second, liveBar: nil)

        #expect(result.active.map(\.direction) == [.top])
        #expect(result.active.first?.count == 1)
        #expect(result.active.first?.sequenceStart == second[4].start)
    }

    @Test("the lunch boundary preserves a valid sequence")
    func lunchBoundaryIsConsecutiveTradingContext() {
        let starts = ["11:25", "11:26", "11:27", "11:28", "11:29", "13:00", "13:01", "13:02", "13:03", "13:04", "13:05", "13:06", "13:07"]
        let closes = [10, 10, 10, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19].map(Double.init)

        let result = engine.scan(completedBars: bars(closes, starts: starts), liveBar: nil)

        #expect(result.active.first?.count == 9)
        #expect(result.completions.count == 1)
    }

    @Test("top completion freezes the highest high from bars one through nine")
    func topExtremeUsesOnlyFirstNineSequenceBars() {
        let closes = ([10, 10, 10, 10] + Array(11...21)).map(Double.init)
        var highs = closes.map { $0 + 0.2 }
        highs[3] = 500
        highs[8] = 80
        highs[13] = 900

        let result = engine.scan(completedBars: bars(closes, highs: highs), liveBar: nil)

        #expect(result.completions.first?.extremePrice == 80)
        #expect(result.active.first?.extremePrice == 80)
    }

    @Test("bottom completion freezes the lowest low from bars one through nine")
    func bottomExtremeUsesOnlyFirstNineSequenceBars() {
        let closes = ([30, 30, 30, 30] + Array((19...29).reversed())).map(Double.init)
        var lows = closes.map { $0 - 0.2 }
        lows[2] = -500
        lows[8] = -20
        lows[13] = -900

        let result = engine.scan(completedBars: bars(closes, lows: lows), liveBar: nil)

        #expect(result.completions.first?.extremePrice == -20)
        #expect(result.active.first?.extremePrice == -20)
    }

    @Test("a live ninth bar is candidate-only and leaves completed input unchanged")
    func liveNinthBarCannotConfirm() {
        let completed = bars(([10, 10, 10, 10] + Array(11...18)).map(Double.init))
        let original = completed
        let live = replacing(completed.last!, startOffset: 60, close: 19, high: 30, low: 18.5, isClosed: false)

        let result = engine.scan(completedBars: completed, liveBar: live)

        #expect(result.active.map(\.direction) == [.top])
        #expect(result.active.first?.count == 9)
        #expect(result.active.first?.phase == .candidate)
        #expect(result.active.first?.lastBarEnd == live.end)
        #expect(result.active.first?.extremePrice == 30)
        #expect(result.completions.isEmpty)
        #expect(completed == original)
    }

    @Test("a live bottom ninth bar is candidate-only")
    func liveBottomNinthBarCannotConfirm() {
        let completed = bars(([20, 20, 20, 20] + Array((12...19).reversed())).map(Double.init))
        let live = replacing(completed.last!, startOffset: 60, close: 11, high: 11.5, low: 5, isClosed: false)

        let result = engine.scan(completedBars: completed, liveBar: live)

        #expect(result.active.map(\.direction) == [.bottom])
        #expect(result.active.first?.count == 9)
        #expect(result.active.first?.phase == .candidate)
        #expect(result.active.first?.extremePrice == 5)
        #expect(result.completions.isEmpty)
    }

    @Test("live continuation does not drift a confirmed completion")
    func liveContinuationDoesNotMutateConfirmedCompletion() {
        let completed = bars(([10, 10, 10, 10] + Array(11...19)).map(Double.init))
        let live = replacing(completed.last!, startOffset: 60, close: 20, high: 500, low: 19.5, isClosed: false)

        let result = engine.scan(completedBars: completed, liveBar: live)

        #expect(result.completions.count == 1)
        #expect(result.completions.first?.lastClose == 19)
        #expect(result.completions.first?.lastBarEnd == completed[12].end)
        #expect(result.completions.first?.extremePrice == 19.2)
        #expect(result.active.first?.phase == .candidate)
        #expect(result.active.first?.count == 9)
        #expect(result.active.first?.lastClose == 20)
        #expect(result.active.first?.lastBarEnd == live.end)
        #expect(result.active.first?.extremePrice == 19.2)
    }

    @Test("invalid live bar contexts are ignored")
    func invalidLiveContextsAreIgnored() {
        let completed = bars([10, 10, 10, 10, 11].map(Double.init))
        let expected = engine.scan(completedBars: completed, liveBar: nil)
        let closed = replacing(completed.last!, startOffset: 60, close: 12, isClosed: true)
        let wrongInstrument = replacing(completed.last!, startOffset: 60, close: 12, instrumentID: "sz.000001", isClosed: false)
        let wrongTimeframe = replacing(completed.last!, startOffset: 60, close: 12, timeframe: .fiveMinutes, isClosed: false)
        let skipped = replacing(completed.last!, startOffset: 120, close: 12, isClosed: false)
        let malformedEnd = replacing(completed.last!, startOffset: 60, endOffset: 120, close: 12, isClosed: false)

        #expect(engine.scan(completedBars: completed, liveBar: closed) == expected)
        #expect(engine.scan(completedBars: completed, liveBar: wrongInstrument) == expected)
        #expect(engine.scan(completedBars: completed, liveBar: wrongTimeframe) == expected)
        #expect(engine.scan(completedBars: completed, liveBar: skipped) == expected)
        #expect(engine.scan(completedBars: completed, liveBar: malformedEnd) == expected)
    }

    @Test("scan is deterministic and ignores open bars in completed input")
    func scanIsDeterministicAndUsesOnlyClosedBars() {
        let closed = bars([10, 10, 10, 10, 11].map(Double.init))
        let open = replacing(closed.last!, startOffset: 60, close: 50, isClosed: false)
        let input = [open] + closed.reversed()

        let first = engine.scan(completedBars: Array(input), liveBar: nil)
        let second = engine.scan(completedBars: Array(input), liveBar: nil)

        #expect(first == second)
        #expect(first.active.first?.count == 1)
        #expect(first.active.first?.lastClose == 11)
    }
}

private func bars(
    _ closes: [Double],
    startingAt startText: String = "2026-09-01T09:30:00+08:00",
    starts: [String]? = nil,
    opens: [Double]? = nil,
    highs: [Double]? = nil,
    lows: [Double]? = nil
) -> [Bar] {
    let base = isoDate(startText)
    return closes.enumerated().map { index, close in
        let start = starts.map { isoDate("2026-09-01T\($0[index]):00+08:00") }
            ?? base.addingTimeInterval(Double(index) * 60)
        return Bar(
            instrumentID: "sh.600519",
            timeframe: .oneMinute,
            start: start,
            end: start.addingTimeInterval(60),
            open: opens?[index] ?? close,
            high: highs?[index] ?? close + 0.2,
            low: lows?[index] ?? close - 0.2,
            close: close,
            volume: 100,
            amount: close * 100,
            sourceUpdatedAt: start.addingTimeInterval(60),
            isClosed: true
        )
    }
}

private func replacing(
    _ bar: Bar,
    startOffset: Double,
    endOffset: Double? = nil,
    close: Double,
    high: Double? = nil,
    low: Double? = nil,
    instrumentID: String? = nil,
    timeframe: Timeframe? = nil,
    isClosed: Bool
) -> Bar {
    let start = bar.start.addingTimeInterval(startOffset)
    let selectedTimeframe = timeframe ?? bar.timeframe
    return Bar(
        instrumentID: instrumentID ?? bar.instrumentID,
        timeframe: selectedTimeframe,
        start: start,
        end: start.addingTimeInterval(endOffset ?? Double(selectedTimeframe.rawValue * 60)),
        open: close,
        high: high ?? close + 0.2,
        low: low ?? close - 0.2,
        close: close,
        volume: bar.volume,
        amount: close * 100,
        sourceUpdatedAt: start,
        isClosed: isClosed
    )
}
