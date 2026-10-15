import Foundation

public protocol MarketDataSource: Sendable {
    func fetchMinuteSeries(for instrument: Instrument, tradingDay: Date) async throws -> MinuteSeries
    func fetchQuotes(for instruments: [Instrument]) async throws -> [Quote]
}

public struct MinuteSeries: Equatable, Sendable {
    public var instrument: Instrument
    public let previousClose: Double
    public let points: [MinutePoint]
    public let receivedAt: Date

    public init(instrument: Instrument, previousClose: Double, points: [MinutePoint], receivedAt: Date) {
        self.instrument = instrument
        self.previousClose = previousClose
        self.points = points
        self.receivedAt = receivedAt
    }
}

public enum MarketDataError: Error, Equatable, Sendable {
    case invalidURL
    case invalidResponse
    case httpStatus(Int)
    case emptyPayload
    case malformedPayload
    case stalePayload
    case wrongTradingDayPayload
}
