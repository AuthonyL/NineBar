import Foundation

public struct BarFreshness: Sendable {
    public init() {}

    public func isStale(lastUpdate: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastUpdate) > 75
    }

    public func isStale(
        series: MinuteSeries,
        now: Date,
        clock: TradingSessionClock
    ) -> Bool {
        guard clock.isContinuousTrading(now) else { return false }
        guard let latestMinute = series.points.max(by: { $0.timestamp < $1.timestamp }) else {
            return true
        }
        let latestBarEnd = latestMinute.timestamp.addingTimeInterval(60)
        return isStale(lastUpdate: series.receivedAt, now: now)
            || isStale(lastUpdate: latestBarEnd, now: now)
    }
}
