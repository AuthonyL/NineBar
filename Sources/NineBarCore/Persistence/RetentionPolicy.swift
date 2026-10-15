import Foundation

public enum RetentionPolicy {
    public static func cutoff(tradingDates: [Date], keep: Int = 30) -> Date? {
        guard keep > 0,
              let timeZone = TimeZone(identifier: "Asia/Shanghai") else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let dates = Set(tradingDates.map { calendar.startOfDay(for: $0) })
            .sorted(by: >)
        guard dates.count > keep else { return nil }
        return dates[keep - 1]
    }
}
