import Foundation
@testable import NineBarCore

enum HealthSourceResult<Value: Sendable>: Sendable {
    case success(Value)
    case failure(MarketDataError)

    func get() throws -> Value {
        switch self {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }
}

actor HealthCheckMarketDataSource: MarketDataSource {
    private let quoteResult: HealthSourceResult<[Quote]>
    private let seriesByDay: [String: [String: HealthSourceResult<MinuteSeries>]]
    private(set) var requestedTradingDayLabels: [String] = []

    init(
        quoteResult: HealthSourceResult<[Quote]>,
        seriesByDay: [String: [String: HealthSourceResult<MinuteSeries>]]
    ) {
        self.quoteResult = quoteResult
        self.seriesByDay = seriesByDay
    }

    func fetchMinuteSeries(for instrument: Instrument, tradingDay: Date) async throws -> MinuteSeries {
        let label = healthTradingDayLabel(tradingDay)
        requestedTradingDayLabels.append(label)
        return try (seriesByDay[label]?[instrument.id] ?? .failure(.emptyPayload)).get()
    }

    func fetchQuotes(for instruments: [Instrument]) async throws -> [Quote] {
        try quoteResult.get()
    }
}

func healthyQuotes(now: Date, sourceUpdatedAt: Date? = nil) -> [Quote] {
    [HealthCheckRunner.shanghaiStock, HealthCheckRunner.shenzhenETF].enumerated().map { offset, instrument in
        let price = 100.0 + Double(offset)
        return Quote(
            instrumentID: instrument.id,
            timestamp: now,
            price: price,
            high: price + 0.2,
            low: price - 0.2,
            volume: 100,
            amount: price * 100,
            sourceUpdatedAt: sourceUpdatedAt ?? now.addingTimeInterval(-5)
        )
    }
}

func healthySeriesResults(
    tradingDay: String,
    latestTime: String,
    receivedAt: Date,
    openOffset: Double = -0.1
) -> [String: HealthSourceResult<MinuteSeries>] {
    Dictionary(uniqueKeysWithValues: [HealthCheckRunner.shanghaiStock, HealthCheckRunner.shenzhenETF].enumerated().map {
        offset, instrument in
        let resolved = Instrument(
            symbol: instrument.symbol,
            name: offset == 0 ? "贵州茅台" : "创业板ETF",
            exchange: instrument.exchange,
            kind: instrument.kind
        )
        let close = 100.0 + Double(offset)
        let point = MinutePoint(
            timestamp: isoDate("\(tradingDay)T\(latestTime):00+08:00"),
            open: close + openOffset,
            high: close + 0.2,
            low: close - 0.2,
            close: close,
            volume: 100,
            amount: close * 100,
            sourceUpdatedAt: receivedAt
        )
        return (
            instrument.id,
            .success(MinuteSeries(
                instrument: resolved,
                previousClose: close - 0.2,
                points: [point],
                receivedAt: receivedAt
            ))
        )
    })
}

func healthFailureResults(_ error: MarketDataError) -> [String: HealthSourceResult<MinuteSeries>] {
    Dictionary(uniqueKeysWithValues: [HealthCheckRunner.shanghaiStock, HealthCheckRunner.shenzhenETF].map {
        ($0.id, .failure(error))
    })
}

func encodedHealthReport(_ report: HealthCheckReport) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(report), as: UTF8.self)
}

func healthJSONKeys(_ json: String) throws -> [String] {
    guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
        return []
    }
    return object.keys.sorted()
}

private func healthTradingDayLabel(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}
