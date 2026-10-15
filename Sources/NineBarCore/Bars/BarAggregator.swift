import Foundation

public struct BarAggregator: Sendable {
    public let clock: TradingSessionClock

    private let calendar: Calendar

    public init(clock: TradingSessionClock = TradingSessionClock()) {
        self.clock = clock

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        self.calendar = calendar
    }

    public func oneMinuteBars(from series: MinuteSeries, now: Date) -> [Bar] {
        series.points.compactMap { point in
            let end = point.timestamp.addingTimeInterval(60)
            guard end <= now,
                  isMinuteStart(point.timestamp),
                  clock.isMinuteBarStart(point.timestamp),
                  validMinutePoint(point) else {
                return nil
            }

            return Bar(
                instrumentID: series.instrument.id,
                timeframe: .oneMinute,
                start: point.timestamp,
                end: end,
                open: point.open,
                high: point.high,
                low: point.low,
                close: point.close,
                volume: point.volume,
                amount: point.amount,
                sourceUpdatedAt: point.sourceUpdatedAt,
                isClosed: true
            )
        }
        .sorted { $0.start < $1.start }
    }

    public func fiveMinuteBars(from minutes: [Bar]) -> [Bar] {
        Dictionary(grouping: minutes.compactMap { bar -> (FiveMinuteKey, Bar)? in
            guard let bucket = clock.fiveMinuteBucket(bar.start),
                  let day = tradingDay(for: bar.start) else {
                return nil
            }
            return (FiveMinuteKey(instrumentID: bar.instrumentID, day: day, bucket: bucket), bar)
        }, by: \.0)
        .values
        .compactMap { group in
            let bars = group.map(\.1).sorted { $0.start < $1.start }
            guard bars.count == 5,
                  bars.allSatisfy({
                      $0.timeframe == .oneMinute &&
                      $0.isClosed &&
                      isMinuteStart($0.start) &&
                      clock.isMinuteBarStart($0.start)
                  }),
                  areConsecutiveTradingMinutes(bars) else {
                return nil
            }
            return aggregate(bars)
        }
        .sorted { $0.start < $1.start }
    }

    public func liveCandidate(from series: MinuteSeries, quote: Quote) -> Bar? {
        guard quote.instrumentID == series.instrument.id,
              validQuote(quote),
              !BarFreshness().isStale(lastUpdate: quote.sourceUpdatedAt, now: quote.timestamp),
              clock.isContinuousTrading(quote.timestamp),
              let start = minuteStart(containing: quote.timestamp),
              clock.isMinuteBarStart(start),
              let day = tradingDay(for: start) else {
            return nil
        }

        guard let previous = oneMinuteBars(from: series, now: quote.timestamp)
            .last(where: { tradingDay(for: $0.start) == day }) else {
            return nil
        }

        return Bar(
            instrumentID: series.instrument.id,
            timeframe: .oneMinute,
            start: start,
            end: start.addingTimeInterval(60),
            open: previous.close,
            high: quote.high,
            low: quote.low,
            close: quote.price,
            volume: quote.volume,
            amount: quote.amount,
            sourceUpdatedAt: quote.sourceUpdatedAt,
            isClosed: false
        )
    }

    private func isMinuteStart(_ date: Date) -> Bool {
        let components = calendar.dateComponents([.second, .nanosecond], from: date)
        return components.second == 0 && components.nanosecond == 0
    }

    private func validMinutePoint(_ point: MinutePoint) -> Bool {
        point.open.isFinite && point.open > 0
            && point.high.isFinite && point.high > 0
            && point.low.isFinite && point.low > 0
            && point.close.isFinite && point.close > 0
            && point.volume.isFinite && point.volume >= 0
            && point.amount.isFinite && point.amount >= 0
            && point.high >= point.low
            && point.close >= point.low
            && point.close <= point.high
    }

    private func validQuote(_ quote: Quote) -> Bool {
        quote.price.isFinite && quote.price > 0
            && quote.high.isFinite && quote.high > 0
            && quote.low.isFinite && quote.low > 0
            && quote.volume.isFinite && quote.volume >= 0
            && quote.amount.isFinite && quote.amount >= 0
            && quote.high >= quote.low
            && quote.price >= quote.low
            && quote.price <= quote.high
    }

    private func minuteStart(containing date: Date) -> Date? {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return calendar.date(from: components)
    }

    private func tradingDay(for date: Date) -> TradingDay? {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day else {
            return nil
        }
        return TradingDay(year: year, month: month, day: day)
    }

    private func areConsecutiveTradingMinutes(_ bars: [Bar]) -> Bool {
        guard let firstIndex = clock.minuteIndex(bars[0].start) else {
            return false
        }
        let session = firstIndex < 120 ? 0 : 1

        for pair in zip(bars, bars.dropFirst()) {
            guard let previousIndex = clock.minuteIndex(pair.0.start),
                  let nextIndex = clock.minuteIndex(pair.1.start),
                  (nextIndex < 120 ? 0 : 1) == session,
                  nextIndex == previousIndex + 1 else {
                return false
            }
        }
        return true
    }

    private func aggregate(_ bars: [Bar]) -> Bar {
        Bar(
            instrumentID: bars[0].instrumentID,
            timeframe: .fiveMinutes,
            start: bars[0].start,
            end: bars[4].end,
            open: bars[0].open,
            high: bars.map(\.high).max()!,
            low: bars.map(\.low).min()!,
            close: bars[4].close,
            volume: bars.map(\.volume).reduce(0, +),
            amount: bars.map(\.amount).reduce(0, +),
            sourceUpdatedAt: bars.map(\.sourceUpdatedAt).max()!,
            isClosed: true
        )
    }
}

private struct FiveMinuteKey: Hashable {
    let instrumentID: String
    let day: TradingDay
    let bucket: Int
}

private struct TradingDay: Hashable {
    let year: Int
    let month: Int
    let day: Int
}
