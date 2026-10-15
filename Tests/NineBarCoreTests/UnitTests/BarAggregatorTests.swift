import Testing
@testable import NineBarCore

@Suite("BarAggregatorTests")
struct BarAggregatorTests {
    private let aggregator = BarAggregator(clock: TradingSessionClock())

    @Test("confirms only completed minute-bar starts in chronological order")
    func confirmsOnlyCompletedMinuteBarStartsInChronologicalOrder() throws {
        let series = try minuteSeries(
            times: ["09:32", "09:31", "09:30:30", "09:30"],
            sourceUpdates: ["09:41", "09:40", "09:42", "09:39"]
        )
        let expectedStarts = [try time("09:30"), try time("09:31")]
        let expectedInputTimestamps = [try time("09:32"), try time("09:31"), try time("09:30:30"), try time("09:30")]

        let bars = aggregator.oneMinuteBars(from: series, now: try time("09:32:00"))
        let expectedSourceUpdates = [try time("09:39"), try time("09:40")]

        #expect(bars.map(\.start) == expectedStarts)
        #expect(bars.allSatisfy { $0.isClosed })
        #expect(bars.map(\.sourceUpdatedAt) == expectedSourceUpdates)
        #expect(series.points.map(\.timestamp) == expectedInputTimestamps)
    }

    @Test("aggregates exactly five same-series closed trading minutes")
    func aggregatesExactlyFiveSameSeriesClosedTradingMinutes() throws {
        let minutes = try directMinuteBars(times: ["09:30", "09:31", "09:32", "09:33", "09:34", "09:35"])
        let expectedStart = try time("09:30")
        let expectedEnd = try time("09:35")
        let expectedUpdate = try time("09:44")

        let result = aggregator.fiveMinuteBars(from: minutes)

        #expect(result.count == 1)
        #expect(result[0].instrumentID == "sh.600519")
        #expect(result[0].timeframe == .fiveMinutes)
        #expect(result[0].start == expectedStart)
        #expect(result[0].end == expectedEnd)
        #expect(result[0].open == 10.0)
        #expect(result[0].high == 10.6)
        #expect(result[0].low == 9.7)
        #expect(result[0].close == 10.4)
        #expect(result[0].volume == 500)
        #expect(result[0].amount == 5_000)
        #expect(result[0].sourceUpdatedAt == expectedUpdate)
        #expect(result[0].isClosed)
    }

    @Test("rejects incomplete lunch-spanning duplicate mixed and open five-minute groups")
    func rejectsInvalidFiveMinuteGroups() throws {
        let lunch = try directMinuteBars(times: ["11:26", "11:27", "11:28", "11:29", "13:00"])
        let duplicate = try directMinuteBars(times: ["09:30", "09:31", "09:32", "09:33", "09:33"])
        let mixedInstrument = try directMinuteBars(
            times: ["09:35", "09:36", "09:37", "09:38", "09:39"],
            instrumentIDs: ["sh.600519", "sh.600519", "sh.600519", "sh.600519", "sz.000001"]
        )
        let open = try directMinuteBars(
            times: ["09:40", "09:41", "09:42", "09:43", "09:44"],
            isClosed: [true, true, true, true, false]
        )
        let offBoundary = try directMinuteBars(times: ["09:45:30", "09:46:30", "09:47:30", "09:48:30", "09:49:30"])

        #expect(aggregator.fiveMinuteBars(from: lunch).isEmpty)
        #expect(aggregator.fiveMinuteBars(from: duplicate).isEmpty)
        #expect(aggregator.fiveMinuteBars(from: mixedInstrument).isEmpty)
        #expect(aggregator.fiveMinuteBars(from: open).isEmpty)
        #expect(aggregator.fiveMinuteBars(from: offBoundary).isEmpty)
    }

    @Test("builds a current unconfirmed candidate only from fresh matching quote context")
    func buildsCurrentUnconfirmedCandidateFromFreshMatchingQuoteContext() throws {
        let series = try minuteSeries(times: ["09:30", "09:31", "09:32"])
        let quote = try quote(timestamp: "09:32:30", sourceUpdatedAt: "09:32:00")
        let expectedStart = try time("09:32")
        let expectedEnd = try time("09:33")
        let expectedUpdate = try time("09:32:00")

        let candidate = aggregator.liveCandidate(from: series, quote: quote)

        #expect(candidate?.timeframe == .oneMinute)
        #expect(candidate?.start == expectedStart)
        #expect(candidate?.end == expectedEnd)
        #expect(candidate?.open == 10.1)
        #expect(candidate?.high == 10.8)
        #expect(candidate?.low == 9.8)
        #expect(candidate?.close == 10.5)
        #expect(candidate?.volume == 500)
        #expect(candidate?.amount == 5_000)
        #expect(candidate?.sourceUpdatedAt == expectedUpdate)
        #expect(candidate?.isClosed == false)
    }

    @Test("rejects stale wrong-series contextless and out-of-session live candidates")
    func rejectsInvalidLiveCandidates() throws {
        let series = try minuteSeries(times: ["09:30", "09:31", "09:32"])
        let stale = try quote(timestamp: "09:32:30", sourceUpdatedAt: "09:31:14")
        let wrongInstrument = try quote(timestamp: "09:32:30", instrumentID: "sz.000001")
        let noCompletedContext = try minuteSeries(times: ["09:32"])
        let outsideSession = try quote(timestamp: "12:00:00", sourceUpdatedAt: "12:00:00")

        #expect(aggregator.liveCandidate(from: series, quote: stale) == nil)
        #expect(aggregator.liveCandidate(from: series, quote: wrongInstrument) == nil)
        #expect(aggregator.liveCandidate(from: noCompletedContext, quote: try quote(timestamp: "09:32:30")) == nil)
        #expect(aggregator.liveCandidate(from: series, quote: outsideSession) == nil)
    }

    @Test("invalid minute and live-price ranges cannot reach bar extremes")
    func rejectsInvalidRangesBeforeAggregationAndCandidateEvaluation() throws {
        let validSeries = try minuteSeries(times: ["09:30", "09:31", "09:32"])
        let invalidPoint = MinutePoint(
            timestamp: try time("09:31"),
            open: 10,
            high: 10.2,
            low: 9.8,
            close: 10.3,
            volume: 100,
            amount: 1_000,
            sourceUpdatedAt: try time("09:32")
        )
        let invalidSeries = MinuteSeries(
            instrument: validSeries.instrument,
            previousClose: validSeries.previousClose,
            points: [invalidPoint],
            receivedAt: try time("09:32")
        )
        let invalidQuote = Quote(
            instrumentID: validSeries.instrument.id,
            timestamp: try time("09:32:30"),
            price: 10.9,
            high: 10.8,
            low: 9.8,
            volume: 500,
            amount: 5_000,
            sourceUpdatedAt: try time("09:32:30")
        )

        #expect(aggregator.oneMinuteBars(from: invalidSeries, now: try time("09:33")).isEmpty)
        #expect(aggregator.liveCandidate(from: validSeries, quote: invalidQuote) == nil)
    }
}

private let time = { @Sendable (value: String) throws in
    let parts = value.split(separator: ":").compactMap { Int($0) }
    return try shanghaiDate(2026, 9, 1, parts[0], parts[1], parts.count == 3 ? parts[2] : 0)
}

private func minuteSeries(times: [String], sourceUpdates: [String]? = nil) throws -> MinuteSeries {
    let points = try times.enumerated().map { offset, text in
        let close = 10 + Double(offset) * 0.1
        return MinutePoint(
            timestamp: try time(text),
            open: close - 0.1,
            high: close + 0.2,
            low: close - 0.2,
            close: close,
            volume: 100,
            amount: 1_000,
            sourceUpdatedAt: try time(sourceUpdates?[offset] ?? "09:40")
        )
    }
    return MinuteSeries(instrument: sh("600519"), previousClose: 9.9, points: points, receivedAt: try time("09:45"))
}

private func directMinuteBars(
    times: [String],
    instrumentIDs: [String]? = nil,
    isClosed: [Bool]? = nil
) throws -> [Bar] {
    try times.enumerated().map { offset, text in
        let start = try time(text)
        return Bar(
            instrumentID: instrumentIDs?[offset] ?? "sh.600519",
            timeframe: .oneMinute,
            start: start,
            end: start.addingTimeInterval(60),
            open: offset == 0 ? 10.0 : 10.1,
            high: offset == 4 ? 10.6 : 10.3,
            low: offset == 2 ? 9.7 : 9.9,
            close: offset == 4 ? 10.4 : 10.1,
            volume: 100,
            amount: 1_000,
            sourceUpdatedAt: try time("09:\(40 + offset)"),
            isClosed: isClosed?[offset] ?? true
        )
    }
}

private func quote(
    timestamp: String,
    sourceUpdatedAt: String? = nil,
    instrumentID: String = "sh.600519"
) throws -> Quote {
    Quote(
        instrumentID: instrumentID,
        timestamp: try time(timestamp),
        price: 10.5,
        high: 10.8,
        low: 9.8,
        volume: 500,
        amount: 5_000,
        sourceUpdatedAt: try time(sourceUpdatedAt ?? timestamp)
    )
}
