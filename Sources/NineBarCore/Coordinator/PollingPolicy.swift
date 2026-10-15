import Foundation

public struct PollingPolicy: Sendable {
    public let quoteInterval: Duration
    public let minuteFinalizationDelay: Duration
    public let offHoursInterval: Duration
    public let watchlistInterval: Duration
    public let maxConcurrentSeriesRequests: Int

    public init(
        quoteInterval: Duration = .seconds(10),
        minuteFinalizationDelay: Duration = .seconds(5),
        offHoursInterval: Duration = .seconds(60),
        watchlistInterval: Duration = .seconds(60),
        maxConcurrentSeriesRequests: Int = 4
    ) {
        self.quoteInterval = quoteInterval
        self.minuteFinalizationDelay = minuteFinalizationDelay
        self.offHoursInterval = offHoursInterval
        self.watchlistInterval = watchlistInterval
        self.maxConcurrentSeriesRequests = max(1, maxConcurrentSeriesRequests)
    }
}
