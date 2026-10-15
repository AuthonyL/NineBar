import Foundation

public enum HealthCheckErrorCategory: String, Codable, Hashable, Sendable {
    case emptyData = "empty_data"
    case invalidMinuteSeries = "invalid_minute_series"
    case invalidQuote = "invalid_quote"
    case invalidTimestamp = "invalid_timestamp"
    case malformedData = "malformed_data"
    case minuteSeriesCount = "minute_series_count"
    case quoteCount = "quote_count"
    case quoteUnavailable = "quote_unavailable"
    case sourceUnavailable = "source_unavailable"
    case stale = "stale"
    case staleData = "stale_data"
    case tradingDayUnavailable = "trading_day_unavailable"
}

public struct HealthCheckReport: Encodable, Equatable, Sendable {
    public let ok: Bool
    public let marketOpen: Bool
    public let quoteCount: Int
    public let minuteSeriesCount: Int
    public let latestAgeSeconds: Int?
    public let errors: [HealthCheckErrorCategory]

    public init(
        ok: Bool,
        marketOpen: Bool,
        quoteCount: Int,
        minuteSeriesCount: Int,
        latestAgeSeconds: Int?,
        errors: [HealthCheckErrorCategory]
    ) {
        self.ok = ok
        self.marketOpen = marketOpen
        self.quoteCount = quoteCount
        self.minuteSeriesCount = minuteSeriesCount
        self.latestAgeSeconds = latestAgeSeconds
        self.errors = errors
    }

    private enum CodingKeys: String, CodingKey {
        case ok
        case marketOpen
        case quoteCount
        case minuteSeriesCount
        case latestAgeSeconds
        case errors
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ok, forKey: .ok)
        try container.encode(marketOpen, forKey: .marketOpen)
        try container.encode(quoteCount, forKey: .quoteCount)
        try container.encode(minuteSeriesCount, forKey: .minuteSeriesCount)
        if let latestAgeSeconds {
            try container.encode(latestAgeSeconds, forKey: .latestAgeSeconds)
        } else {
            try container.encodeNil(forKey: .latestAgeSeconds)
        }
        try container.encode(errors, forKey: .errors)
    }
}

public struct HealthCheckRunner: Sendable {
    public static let shanghaiStock = Instrument(
        symbol: "600519",
        name: "",
        exchange: .shanghai,
        kind: .stock
    )
    public static let shenzhenETF = Instrument(
        symbol: "159915",
        name: "",
        exchange: .shenzhen,
        kind: .etf
    )

    private static let requiredInstruments = [shanghaiStock, shenzhenETF]
    private static let maximumPlausibleAge: TimeInterval = 10 * 366 * 24 * 60 * 60
    private static let maximumCollectionSkew: TimeInterval = 30

    private let marketData: any MarketDataSource
    private let clock: TradingSessionClock
    private let now: @Sendable () -> Date
    private let calendar: Calendar

    public init(
        marketData: any MarketDataSource,
        clock: TradingSessionClock = TradingSessionClock(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.marketData = marketData
        self.clock = clock
        self.now = now

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        self.calendar = calendar
    }

    public static func live() -> HealthCheckRunner {
        HealthCheckRunner(
            marketData: EastMoneyMarketDataSource(
                client: RetryingHTTPClient(client: URLSessionHTTPClient())
            )
        )
    }

    public func run() async -> HealthCheckReport {
        let current = now()
        let nominalContinuousSession = clock.isContinuousTrading(current)
        var errors: Set<HealthCheckErrorCategory> = []
        var ages: [TimeInterval] = []

        let quoteCount = await validateQuotes(
            at: current,
            ages: &ages,
            errors: &errors
        )
        let minuteResolution = await resolveMinuteSeries(
            at: current,
            nominalContinuousSession: nominalContinuousSession,
            ages: &ages,
            errors: &errors
        )
        let marketOpen = minuteResolution.actualMarketOpen

        let oldestAge = ages.max()
        if marketOpen, let oldestAge, oldestAge > 75 {
            errors.insert(.stale)
        }
        let orderedErrors = errors.sorted { $0.rawValue < $1.rawValue }
        return HealthCheckReport(
            ok: quoteCount == Self.requiredInstruments.count
                && minuteResolution.count == Self.requiredInstruments.count
                && orderedErrors.isEmpty,
            marketOpen: marketOpen,
            quoteCount: quoteCount,
            minuteSeriesCount: minuteResolution.count,
            latestAgeSeconds: oldestAge.map { Int($0.rounded(.down)) },
            errors: orderedErrors
        )
    }

    private func validateQuotes(
        at current: Date,
        ages: inout [TimeInterval],
        errors: inout Set<HealthCheckErrorCategory>
    ) async -> Int {
        let quotes: [Quote]
        do {
            quotes = try await marketData.fetchQuotes(for: Self.requiredInstruments)
        } catch {
            errors.insert(category(for: error))
            errors.insert(.quoteUnavailable)
            return 0
        }

        let requiredIDs = Set(Self.requiredInstruments.map(\.id))
        var validIDs: Set<String> = []
        for quote in quotes {
            guard requiredIDs.contains(quote.instrumentID),
                  !validIDs.contains(quote.instrumentID),
                  quote.price.isFinite,
                  quote.price > 0 else {
                errors.insert(.invalidQuote)
                continue
            }
            validIDs.insert(quote.instrumentID)
            recordAge(of: quote.sourceUpdatedAt, at: current, ages: &ages, errors: &errors)
        }
        if validIDs.count != Self.requiredInstruments.count || quotes.count != Self.requiredInstruments.count {
            errors.insert(.quoteCount)
        }
        return validIDs.count
    }

    private func resolveMinuteSeries(
        at current: Date,
        nominalContinuousSession: Bool,
        ages: inout [TimeInterval],
        errors: inout Set<HealthCheckErrorCategory>
    ) async -> MinuteSeriesResolution {
        let today = calendar.startOfDay(for: current)
        let candidates = candidateTradingDays(at: current)
        var lastRecoverableCategory: HealthCheckErrorCategory?
        var todayWasRecoverablyMissing = false

        for candidate in candidates {
            var successes: [MinuteSeries] = []
            var failures: [MarketDataError] = []

            for instrument in Self.requiredInstruments {
                do {
                    successes.append(try await marketData.fetchMinuteSeries(
                        for: instrument,
                        tradingDay: candidate
                    ))
                } catch let error as MarketDataError {
                    failures.append(error)
                } catch {
                    errors.insert(.sourceUnavailable)
                }
            }

            if successes.isEmpty,
               failures.count == Self.requiredInstruments.count,
               failures.allSatisfy(ActualSessionResolver.isRecoverableMissingTradingDay) {
                lastRecoverableCategory = category(for: failures[0])
                if calendar.isDate(candidate, inSameDayAs: today) {
                    todayWasRecoverablyMissing = true
                }
                continue
            }

            for failure in failures {
                errors.insert(category(for: failure))
            }

            let validCount = validate(
                series: successes,
                tradingDay: candidate,
                at: current,
                ages: &ages,
                errors: &errors
            )
            if validCount != Self.requiredInstruments.count {
                errors.insert(.minuteSeriesCount)
            }
            let isToday = calendar.isDate(candidate, inSameDayAs: today)
            return MinuteSeriesResolution(
                count: validCount,
                resolvedTradingDay: validCount == Self.requiredInstruments.count ? candidate : nil,
                actualMarketOpen: nominalContinuousSession && isToday
            )
        }

        if let lastRecoverableCategory {
            errors.insert(lastRecoverableCategory)
        }
        errors.insert(.minuteSeriesCount)
        errors.insert(.tradingDayUnavailable)
        return MinuteSeriesResolution(
            count: 0,
            resolvedTradingDay: nil,
            actualMarketOpen: nominalContinuousSession && !todayWasRecoverablyMissing
        )
    }

    private func validate(
        series values: [MinuteSeries],
        tradingDay: Date,
        at current: Date,
        ages: inout [TimeInterval],
        errors: inout Set<HealthCheckErrorCategory>
    ) -> Int {
        let required = Dictionary(uniqueKeysWithValues: Self.requiredInstruments.map { ($0.id, $0) })
        var validIDs: Set<String> = []

        for series in values {
            guard let requested = required[series.instrument.id],
                  !validIDs.contains(series.instrument.id),
                  validName(series.instrument.name, symbol: requested.symbol),
                  series.previousClose.isFinite,
                  series.previousClose > 0,
                  !series.points.isEmpty,
                  validPoints(series.points, tradingDay: tradingDay) else {
                errors.insert(.invalidMinuteSeries)
                continue
            }
            validIDs.insert(series.instrument.id)
            if let latest = series.points.last {
                recordAge(of: latest.timestamp, at: current, ages: &ages, errors: &errors)
                recordAge(of: latest.sourceUpdatedAt, at: current, ages: &ages, errors: &errors)
            }
        }
        return validIDs.count
    }

    private func validPoints(_ points: [MinutePoint], tradingDay: Date) -> Bool {
        var previousTimestamp: Date?
        for point in points {
            guard calendar.isDate(point.timestamp, inSameDayAs: tradingDay),
                  clock.isMinuteBarStart(point.timestamp),
                  point.open.isFinite, point.open > 0,
                  point.high.isFinite, point.high > 0,
                  point.low.isFinite, point.low > 0,
                  point.close.isFinite, point.close > 0,
                  point.high >= point.low,
                  previousTimestamp.map({ point.timestamp > $0 }) ?? true else {
                return false
            }
            previousTimestamp = point.timestamp
        }
        return true
    }

    private func validName(_ name: String, symbol: String) -> Bool {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != symbol else { return false }
        return !["-", "--", "unknown", "未知"].contains(value.lowercased())
    }

    private func recordAge(
        of timestamp: Date,
        at current: Date,
        ages: inout [TimeInterval],
        errors: inout Set<HealthCheckErrorCategory>
    ) {
        let age = current.timeIntervalSince(timestamp)
        guard age.isFinite,
              age >= -Self.maximumCollectionSkew,
              age <= Self.maximumPlausibleAge else {
            errors.insert(.invalidTimestamp)
            return
        }
        ages.append(max(0, age))
    }

    private func candidateTradingDays(at current: Date) -> [Date] {
        let today = calendar.startOfDay(for: current)
        let minute = calendar.component(.hour, from: current) * 60
            + calendar.component(.minute, from: current)
        var cursor = today
        if calendar.isDateInWeekend(cursor) || minute < 570 {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }

        var candidates: [Date] = []
        while candidates.count < 10 {
            if !calendar.isDateInWeekend(cursor) {
                candidates.append(cursor)
            }
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        return candidates
    }

    private func category(for error: Error) -> HealthCheckErrorCategory {
        guard let error = error as? MarketDataError else {
            return .sourceUnavailable
        }
        switch error {
        case .emptyPayload:
            return .emptyData
        case .malformedPayload, .invalidResponse:
            return .malformedData
        case .stalePayload, .wrongTradingDayPayload:
            return .staleData
        case .invalidURL, .httpStatus:
            return .sourceUnavailable
        }
    }
}

private struct MinuteSeriesResolution {
    let count: Int
    let resolvedTradingDay: Date?
    let actualMarketOpen: Bool
}
