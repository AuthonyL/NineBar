import Testing
@testable import NineBarCore

@Suite("BarFreshnessTests")
struct BarFreshnessTests {
    @Test("treats seventy-five seconds as fresh and older updates as stale")
    func treatsSeventyFiveSecondsAsFreshAndOlderUpdatesAsStale() {
        let now = isoDate("1970-01-01T00:16:40Z")

        #expect(!BarFreshness().isStale(lastUpdate: now.addingTimeInterval(-75), now: now))
        #expect(BarFreshness().isStale(lastUpdate: now.addingTimeInterval(-76), now: now))
    }

    @Test("does not mark future updates stale")
    func doesNotMarkFutureUpdatesStale() {
        let now = isoDate("1970-01-01T00:16:40Z")

        #expect(!BarFreshness().isStale(lastUpdate: now.addingTimeInterval(1), now: now))
    }

    @Test("open-session minute progress uses the completed bar end at the exact boundary")
    func minuteSeriesProgressUsesExactSeventyFiveSecondBoundary() {
        let freshness = BarFreshness()
        let receivedAt = isoDate("2026-09-01T10:00:15+08:00")
        let series = freshnessSeries(
            latestMinuteStart: "2026-09-01T09:58:00+08:00",
            receivedAt: "2026-09-01T10:00:15+08:00"
        )

        #expect(!freshness.isStale(
            series: series,
            now: receivedAt,
            clock: TradingSessionClock()
        ))
        #expect(freshness.isStale(
            series: series,
            now: receivedAt.addingTimeInterval(1),
            clock: TradingSessionClock()
        ))
    }

    @Test("completed sessions remain usable outside nominal continuous trading")
    func completedSessionIsNotRejectedOutsideTradingHours() {
        let series = freshnessSeries(
            latestMinuteStart: "2026-09-01T14:59:00+08:00",
            receivedAt: "2026-09-01T15:00:01+08:00"
        )

        #expect(!BarFreshness().isStale(
            series: series,
            now: isoDate("2026-09-01T16:30:00+08:00"),
            clock: TradingSessionClock()
        ))
    }
}

private func freshnessSeries(latestMinuteStart: String, receivedAt: String) -> MinuteSeries {
    let update = isoDate(receivedAt)
    return MinuteSeries(
        instrument: sh("600519"),
        previousClose: 10,
        points: [MinutePoint(
            timestamp: isoDate(latestMinuteStart),
            open: 10,
            high: 10.2,
            low: 9.8,
            close: 10.1,
            volume: 100,
            amount: 1_000,
            sourceUpdatedAt: update
        )],
        receivedAt: update
    )
}
