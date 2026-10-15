import Foundation

public struct EastMoneyMarketDataSource: MarketDataSource {
    private let client: any HTTPClient
    private let now: @Sendable () -> Date
    private let sessionClock: TradingSessionClock

    public init(
        client: any HTTPClient = URLSessionHTTPClient(),
        now: @escaping @Sendable () -> Date = { Date() },
        sessionClock: TradingSessionClock = TradingSessionClock()
    ) {
        self.client = client
        self.now = now
        self.sessionClock = sessionClock
    }

    public func fetchMinuteSeries(for instrument: Instrument, tradingDay: Date) async throws -> MinuteSeries {
        let (payload, http) = try await fetchMinutePayload(for: instrument)
        guard (200..<300).contains(http.statusCode) else {
            throw MarketDataError.httpStatus(http.statusCode)
        }
        let response = try decode(EastMoneyTrendsResponse.self, from: payload)

        guard response.rc == 0 else {
            throw MarketDataError.invalidResponse
        }
        guard let data = response.data else {
            throw MarketDataError.emptyPayload
        }
        guard let name = validName(data.name), let previousClose = validPositive(data.preClose) else {
            throw MarketDataError.malformedPayload
        }
        guard let trendRows = data.trends else {
            throw MarketDataError.emptyPayload
        }
        guard !trendRows.isEmpty else {
            throw MarketDataError.emptyPayload
        }

        let rowTimestamps = trendRows.map { row -> Date? in
            let timestampField = row.split(separator: ",", omittingEmptySubsequences: false).first
            return shanghaiMinuteDate(String(timestampField ?? ""))
        }
        guard rowTimestamps.allSatisfy({ $0 != nil }) else {
            throw MarketDataError.malformedPayload
        }
        let currentTradingDayRows = rowTimestamps.compactMap { $0 }.filter {
            isSameShanghaiDay($0, tradingDay)
        }.count
        if currentTradingDayRows == 0 {
            throw MarketDataError.wrongTradingDayPayload
        }
        guard currentTradingDayRows == trendRows.count else {
            throw MarketDataError.malformedPayload
        }

        var parsedPoints: [MinutePoint] = []
        var priorTimestamp: Date?
        let receivedAt = now()

        for (index, row) in trendRows.enumerated() {
            guard let closeMarker = rowTimestamps[index] else {
                throw MarketDataError.malformedPayload
            }
            if isOpeningSnapshot(closeMarker) {
                guard index == 0 else {
                    throw MarketDataError.malformedPayload
                }
                continue
            }
            guard sessionClock.isContinuousTrading(closeMarker) else {
                throw MarketDataError.malformedPayload
            }
            let timestamp = closeMarker.addingTimeInterval(-60)
            let point = try parseMinuteRow(
                row,
                timestamp: timestamp,
                tradingDay: tradingDay,
                receivedAt: receivedAt
            )
            if let priorTimestamp, point.timestamp <= priorTimestamp {
                throw MarketDataError.malformedPayload
            }
            parsedPoints.append(point)
            priorTimestamp = point.timestamp
        }
        guard !parsedPoints.isEmpty else {
            throw MarketDataError.emptyPayload
        }

        var updatedInstrument = instrument
        updatedInstrument.name = name
        return MinuteSeries(
            instrument: updatedInstrument,
            previousClose: previousClose,
            points: parsedPoints,
            receivedAt: receivedAt
        )
    }

    public func fetchQuotes(for instruments: [Instrument]) async throws -> [Quote] {
        guard !instruments.isEmpty else {
            return []
        }

        var requested: [String: Instrument] = [:]
        for instrument in instruments {
            guard requested[instrument.id] == nil else {
                throw MarketDataError.invalidResponse
            }
            requested[instrument.id] = instrument
        }

        let (payload, http) = try await fetchQuotePayload(for: instruments)
        guard (200..<300).contains(http.statusCode) else {
            throw MarketDataError.httpStatus(http.statusCode)
        }
        let response = try decode(EastMoneyQuotesResponse.self, from: payload)
        guard response.rc == nil || response.rc == 0 else {
            throw MarketDataError.invalidResponse
        }
        guard let rows = response.data?.diff else {
            throw MarketDataError.emptyPayload
        }
        guard rows.count == instruments.count else {
            throw MarketDataError.invalidResponse
        }

        var quotesByID: [String: Quote] = [:]
        for row in rows {
            let quote = try mapQuote(row, requested: requested)
            guard quotesByID[quote.instrumentID] == nil else {
                throw MarketDataError.invalidResponse
            }
            quotesByID[quote.instrumentID] = quote
        }

        guard quotesByID.count == instruments.count else {
            throw MarketDataError.invalidResponse
        }
        return try instruments.map { instrument in
            guard let quote = quotesByID[instrument.id] else {
                throw MarketDataError.invalidResponse
            }
            return quote
        }
    }

    private func fetchMinutePayload(for instrument: Instrument) async throws -> (Data, HTTPURLResponse) {
        do {
            let result = try await client.get(minuteHistoryURL(
                for: instrument,
                host: "push2his.eastmoney.com"
            ))
            guard (200..<300).contains(result.1.statusCode) else {
                return try await fetchDelayedMinutePayload(for: instrument)
            }
            return result
        } catch {
            if isCancellationError(error) {
                throw CancellationError()
            }
            guard shouldTryDelayedHost(after: error) else {
                throw error
            }
            return try await fetchDelayedMinutePayload(for: instrument)
        }
    }

    private func fetchDelayedMinutePayload(for instrument: Instrument) async throws -> (Data, HTTPURLResponse) {
        try await client.get(minuteHistoryURL(
            for: instrument,
            host: "push2delay.eastmoney.com"
        ))
    }

    private func fetchQuotePayload(for instruments: [Instrument]) async throws -> (Data, HTTPURLResponse) {
        do {
            let result = try await client.get(quoteURL(
                for: instruments,
                host: "push2.eastmoney.com"
            ))
            guard (200..<300).contains(result.1.statusCode) else {
                return try await fetchDelayedQuotePayload(for: instruments)
            }
            return result
        } catch {
            if isCancellationError(error) {
                throw CancellationError()
            }
            guard shouldTryDelayedHost(after: error) else {
                throw error
            }
            return try await fetchDelayedQuotePayload(for: instruments)
        }
    }

    private func fetchDelayedQuotePayload(for instruments: [Instrument]) async throws -> (Data, HTTPURLResponse) {
        try await client.get(quoteURL(
            for: instruments,
            host: "push2delay.eastmoney.com"
        ))
    }

    private func shouldTryDelayedHost(after error: Error) -> Bool {
        if let error = error as? MarketDataError {
            if case .httpStatus = error { return true }
            return false
        }
        return error is URLError
    }

    private func minuteHistoryURL(for instrument: Instrument, host: String) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/api/qt/stock/trends2/get"
        components.queryItems = [
            URLQueryItem(name: "secid", value: instrument.eastMoneySecID),
            URLQueryItem(name: "ndays", value: "1"),
            URLQueryItem(name: "iscr", value: "0"),
            URLQueryItem(name: "fields1", value: "f1,f2,f3,f4,f5,f6,f7,f8,f9,f10,f11,f12,f13"),
            URLQueryItem(name: "fields2", value: "f51,f52,f53,f54,f55,f56,f57")
        ]
        guard let url = components.url else {
            throw MarketDataError.invalidURL
        }
        return url
    }

    private func quoteURL(for instruments: [Instrument], host: String) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/api/qt/ulist.np/get"
        components.queryItems = [
            URLQueryItem(name: "fltt", value: "2"),
            URLQueryItem(name: "secids", value: instruments.map(\.eastMoneySecID).joined(separator: ",")),
            URLQueryItem(name: "fields", value: "f2,f5,f6,f12,f13,f14,f15,f16,f124")
        ]
        guard let url = components.url else {
            throw MarketDataError.invalidURL
        }
        return url
    }

    private func parseMinuteRow(
        _ row: String,
        timestamp: Date,
        tradingDay: Date,
        receivedAt: Date
    ) throws -> MinutePoint {
        let fields = row.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count == 7,
              isSameShanghaiDay(timestamp, tradingDay),
              sessionClock.isMinuteBarStart(timestamp),
              let open = validPositive(Double(fields[1])),
              let close = validPositive(Double(fields[2])),
              let high = validPositive(Double(fields[3])),
              let low = validPositive(Double(fields[4])),
              let volume = validNonNegative(Double(fields[5])),
              let amount = validNonNegative(Double(fields[6])),
              high >= low,
              close >= low,
              close <= high,
              high.isFinite,
              low.isFinite,
              open.isFinite,
              open > 0 else {
            throw MarketDataError.malformedPayload
        }

        return MinutePoint(
            timestamp: timestamp,
            open: open,
            high: high,
            low: low,
            close: close,
            volume: volume,
            amount: amount,
            sourceUpdatedAt: receivedAt
        )
    }

    private func isOpeningSnapshot(_ timestamp: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let components = calendar.dateComponents([.hour, .minute], from: timestamp)
        return components.hour == 9 && components.minute == 30
    }

    private func mapQuote(_ row: EastMoneyQuoteRow, requested: [String: Instrument]) throws -> Quote {
        guard let symbol = row.symbol,
              let market = row.market,
              let exchange = exchange(forEastMoneyMarket: market),
              let instrument = requested["\(exchange.rawValue).\(symbol)"],
              validName(row.name) != nil,
              let price = validPositive(row.price),
              let sourceEpoch = validPositive(row.sourceEpoch) else {
            throw MarketDataError.invalidResponse
        }

        guard let high = quoteBoundary(row.high, fallback: price),
              let low = quoteBoundary(row.low, fallback: price) else {
            throw MarketDataError.malformedPayload
        }
        let volume = row.volume ?? 0
        let amount = row.amount ?? 0
        guard validNonNegative(volume) != nil,
              validNonNegative(amount) != nil,
              high >= low,
              price >= low,
              price <= high else {
            throw MarketDataError.malformedPayload
        }

        let sourceUpdatedAt = Date(timeIntervalSince1970: sourceEpoch)
        guard sourceUpdatedAt.timeIntervalSince1970.isFinite else {
            throw MarketDataError.malformedPayload
        }
        return Quote(
            instrumentID: instrument.id,
            timestamp: now(),
            price: price,
            high: high,
            low: low,
            volume: volume,
            amount: amount,
            sourceUpdatedAt: sourceUpdatedAt
        )
    }

    private func decode<T: Decodable>(_ type: T.Type, from payload: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: payload)
        } catch {
            throw MarketDataError.malformedPayload
        }
    }

    private func validName(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }

    private func validPositive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private func validNonNegative(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private func quoteBoundary(_ value: Double?, fallback price: Double) -> Double? {
        guard let value else { return price }
        if value == 0 { return price }
        return validPositive(value)
    }

    private func exchange(forEastMoneyMarket market: Int) -> Exchange? {
        switch market {
        case 1: .shanghai
        case 0: .shenzhen
        default: nil
        }
    }

    private func shanghaiMinuteDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)
    }

    private func isSameShanghaiDay(_ lhs: Date, _ rhs: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar.isDate(lhs, inSameDayAs: rhs)
    }
}
