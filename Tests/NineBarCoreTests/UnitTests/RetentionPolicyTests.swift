import Testing
@testable import NineBarCore

@Suite("RetentionPolicyTests")
struct RetentionPolicyTests {
    @Test("cutoff is nil until more than the requested distinct trading dates exist")
    func cutoffNeedsMoreThanKeepDates() throws {
        let start = try shanghaiDate(2026, 7, 1, 15, 0)
        let dates = (0..<30).map { start.addingTimeInterval(Double($0 * 2 * 24 * 60 * 60)) }
        #expect(RetentionPolicy.cutoff(tradingDates: dates, keep: 30) == nil)
        #expect(RetentionPolicy.cutoff(tradingDates: dates + dates, keep: 30) == nil)
    }

    @Test("cutoff uses Shanghai start of the thirtieth newest distinct stored date")
    func cutoffUsesDistinctShanghaiTradingDates() throws {
        let start = try shanghaiDate(2026, 7, 1, 15, 0)
        let dates = (0..<35).map { start.addingTimeInterval(Double($0 * 2 * 24 * 60 * 60)) }
        let expected = try shanghaiDate(2026, 7, 11, 0, 0)

        #expect(RetentionPolicy.cutoff(tradingDates: Array(dates.reversed()), keep: 30) == expected)
    }

    @Test("prune keeps exactly thirty newest noncontiguous dates in bars signals and notification ledger")
    func repositoriesKeepNewestThirtyDates() async throws {
        let start = try shanghaiDate(2026, 7, 1, 15, 0)
        let dates = (0..<35).map { start.addingTimeInterval(Double($0 * 2 * 24 * 60 * 60)) }
        let barRepository = try BarRepository(databaseURL: temporarySQLiteURL())
        let signalRepository = try SignalRepository(databaseURL: temporarySQLiteURL())

        for (index, date) in dates.enumerated() {
            let end = date.addingTimeInterval(10 * 60 * 60)
            try await barRepository.upsert([
                Bar(
                    instrumentID: "sh.\(600_000 + index)", timeframe: .oneMinute,
                    start: end, end: end.addingTimeInterval(60), open: 10, high: 10,
                    low: 10, close: 10, volume: 100, amount: 1_000,
                    sourceUpdatedAt: end.addingTimeInterval(60), isClosed: true
                )
            ])
            let signal = ConfirmedSignal(
                instrumentID: "sh.\(600_000 + index)", timeframe: .oneMinute, direction: .top,
                sequenceStart: end.addingTimeInterval(-8 * 60), lastBarEnd: end,
                lastClose: 10, extremePrice: 10.4, sourceUpdatedAt: end,
                return5m: nil, return15m: nil, return30m: nil, return60m: nil
            )
            _ = try await signalRepository.insertIfAbsent(signal)
            _ = try await signalRepository.recordNotificationIfNew(
                key: "\(signal.instrumentID)|1|top|\(Int(signal.sequenceStart.timeIntervalSince1970))|9",
                createdAt: end
            )
        }

        let storedTradingDates = try await barRepository.distinctTradingDates()
        let cutoff = try #require(RetentionPolicy.cutoff(tradingDates: storedTradingDates, keep: 30))
        try await barRepository.prune(before: cutoff)
        try await signalRepository.prune(before: cutoff)

        let remainingDates = try await barRepository.distinctTradingDates()
        #expect(remainingDates.count == 30)
        #expect(try await signalRepository.recent(limit: 100).count == 30)

        let oldestEnd = dates[0].addingTimeInterval(10 * 60 * 60)
        let newestEnd = dates[34].addingTimeInterval(10 * 60 * 60)
        #expect(try await signalRepository.recordNotificationIfNew(
            key: "sh.600000|1|top|\(Int(oldestEnd.addingTimeInterval(-8 * 60).timeIntervalSince1970))|9",
            createdAt: oldestEnd
        ))
        #expect(try await !signalRepository.recordNotificationIfNew(
            key: "sh.600034|1|top|\(Int(newestEnd.addingTimeInterval(-8 * 60).timeIntervalSince1970))|9",
            createdAt: newestEnd
        ))
    }
}
