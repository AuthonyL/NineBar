import Testing
@testable import NineBarCore

@Suite("BarRepositoryTests")
struct BarRepositoryTests {
    @Test("upsert replaces an existing bar and load returns matching bars in ascending order")
    func upsertReplacesAndLoadsAscending() async throws {
        let repository = try BarRepository(databaseURL: temporarySQLiteURL())
        let firstStartText = "2026-09-01T09:30:00+08:00"
        let secondStartText = "2026-09-01T09:31:00+08:00"
        let firstStart = isoDate(firstStartText)
        let secondStart = isoDate(secondStartText)
        let original = bar(start: firstStartText, close: 10.1, volume: 100)
        let replacement = bar(start: firstStartText, close: 10.8, volume: 250)

        try await repository.upsert([
            bar(instrumentID: "sh.600519", start: secondStartText, close: 10.9),
            original,
            bar(instrumentID: "sz.000001", start: firstStartText, close: 9.0),
            bar(instrumentID: "sh.600519", timeframe: .fiveMinutes, start: firstStartText, close: 11.0)
        ])
        try await repository.upsert([replacement])

        let loaded = try await repository.load(
            instrumentID: "sh.600519",
            timeframe: .oneMinute,
            from: firstStart
        )

        #expect(loaded.map(\.start) == [firstStart, secondStart])
        #expect(loaded[0].close == 10.8)
        #expect(loaded[0].volume == 250)
        #expect(loaded.allSatisfy { $0.isClosed })
    }

    @Test("load excludes bars before the requested start")
    func loadHonorsLowerBound() async throws {
        let repository = try BarRepository(databaseURL: temporarySQLiteURL())
        let firstStartText = "2026-09-01T09:30:00+08:00"
        let secondStartText = "2026-09-01T09:31:00+08:00"
        let secondStart = isoDate(secondStartText)
        try await repository.upsert([
            bar(start: firstStartText, close: 10.1),
            bar(start: secondStartText, close: 10.2)
        ])

        let loaded = try await repository.load(
            instrumentID: "sh.600519",
            timeframe: .oneMinute,
            from: secondStart
        )

        #expect(loaded.map(\.start) == [secondStart])
    }

    @Test("distinct trading dates return one Shanghai day for many intraday bars")
    func distinctTradingDatesAreUniqueAndShanghaiNormalized() async throws {
        let repository = try BarRepository(databaseURL: temporarySQLiteURL())
        try await repository.upsert([
            bar(start: "2026-08-28T09:30:00+08:00", close: 10),
            bar(start: "2026-08-28T14:59:00+08:00", close: 11),
            bar(start: "2026-09-01T09:30:00+08:00", close: 12),
            bar(start: "2026-09-01T14:59:00+08:00", close: 13)
        ])

        #expect(try await repository.distinctTradingDates() == [
            isoDate("2026-08-28T00:00:00+08:00"),
            isoDate("2026-09-01T00:00:00+08:00")
        ])
    }

}

private func bar(
    instrumentID: String = "sh.600519",
    timeframe: Timeframe = .oneMinute,
    start startText: String,
    close: Double,
    volume: Double = 100
) -> Bar {
    let start = isoDate(startText)
    let duration = Double(timeframe.rawValue * 60)
    return Bar(
        instrumentID: instrumentID,
        timeframe: timeframe,
        start: start,
        end: start.addingTimeInterval(duration),
        open: close - 0.1,
        high: close + 0.2,
        low: close - 0.2,
        close: close,
        volume: volume,
        amount: volume * close,
        sourceUpdatedAt: start.addingTimeInterval(duration),
        isClosed: true
    )
}
