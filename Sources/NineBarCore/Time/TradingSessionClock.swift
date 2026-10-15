import Foundation

public struct TradingSessionClock: Sendable {
    private let calendar: Calendar

    public init() {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        self.calendar = value
    }

    public func isContinuousTrading(_ date: Date) -> Bool {
        guard !isWeekend(date) else { return false }
        let value = minuteOfDay(date)
        return (570...690).contains(value) || (780...900).contains(value)
    }

    public func isMinuteBarStart(_ date: Date) -> Bool {
        guard !isWeekend(date) else { return false }
        let value = minuteOfDay(date)
        return (570..<690).contains(value) || (780..<900).contains(value)
    }

    public func minuteIndex(_ date: Date) -> Int? {
        guard !isWeekend(date) else { return nil }
        let value = minuteOfDay(date)
        if (570...690).contains(value) {
            return value - 570
        }
        if (780...900).contains(value) {
            return 120 + value - 780
        }
        return nil
    }

    public func fiveMinuteBucket(_ date: Date) -> Int? {
        minuteIndex(date).map { $0 / 5 }
    }

    public func nextMinuteClose(after date: Date) -> Date? {
        guard isMinuteBarStart(date) else { return nil }
        return calendar.date(byAdding: .minute, value: 1, to: date)
    }

    public func areConsecutive(previousStart: Date, nextStart: Date, timeframe: Timeframe) -> Bool {
        expectedNextStart(after: previousStart, timeframe: timeframe) == nextStart
    }

    private func expectedNextStart(after date: Date, timeframe: Timeframe) -> Date? {
        guard isMinuteBarStart(date), let index = minuteIndex(date), index % timeframe.rawValue == 0 else {
            return nil
        }

        let nextIndex = index + timeframe.rawValue
        guard nextIndex < 240 else { return nil }

        let minuteOfDay = nextIndex < 120 ? 570 + nextIndex : 780 + nextIndex - 120
        return calendar.date(
            bySettingHour: minuteOfDay / 60,
            minute: minuteOfDay % 60,
            second: 0,
            of: date
        )
    }

    private func minuteOfDay(_ date: Date) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    private func isWeekend(_ date: Date) -> Bool {
        calendar.isDateInWeekend(date)
    }
}
