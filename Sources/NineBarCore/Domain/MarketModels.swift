import Foundation

public enum Timeframe: Int, Codable, CaseIterable, Sendable {
    case oneMinute = 1
    case fiveMinutes = 5
}

public struct Quote: Codable, Equatable, Sendable {
    public let instrumentID: String
    public let timestamp: Date
    public let price: Double
    public let high: Double
    public let low: Double
    public let volume: Double
    public let amount: Double
    public let sourceUpdatedAt: Date

    public init(
        instrumentID: String,
        timestamp: Date,
        price: Double,
        high: Double,
        low: Double,
        volume: Double,
        amount: Double,
        sourceUpdatedAt: Date
    ) {
        self.instrumentID = instrumentID
        self.timestamp = timestamp
        self.price = price
        self.high = high
        self.low = low
        self.volume = volume
        self.amount = amount
        self.sourceUpdatedAt = sourceUpdatedAt
    }
}

public struct MinutePoint: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let open: Double
    public let high: Double
    public let low: Double
    public let close: Double
    public let volume: Double
    public let amount: Double
    public let sourceUpdatedAt: Date

    public init(
        timestamp: Date,
        open: Double,
        high: Double,
        low: Double,
        close: Double,
        volume: Double,
        amount: Double,
        sourceUpdatedAt: Date
    ) {
        self.timestamp = timestamp
        self.open = open
        self.high = high
        self.low = low
        self.close = close
        self.volume = volume
        self.amount = amount
        self.sourceUpdatedAt = sourceUpdatedAt
    }
}

public struct Bar: Codable, Equatable, Sendable {
    public let instrumentID: String
    public let timeframe: Timeframe
    public let start: Date
    public let end: Date
    public let open: Double
    public let high: Double
    public let low: Double
    public let close: Double
    public let volume: Double
    public let amount: Double
    public let sourceUpdatedAt: Date
    public let isClosed: Bool

    public init(
        instrumentID: String,
        timeframe: Timeframe,
        start: Date,
        end: Date,
        open: Double,
        high: Double,
        low: Double,
        close: Double,
        volume: Double,
        amount: Double,
        sourceUpdatedAt: Date,
        isClosed: Bool
    ) {
        self.instrumentID = instrumentID
        self.timeframe = timeframe
        self.start = start
        self.end = end
        self.open = open
        self.high = high
        self.low = low
        self.close = close
        self.volume = volume
        self.amount = amount
        self.sourceUpdatedAt = sourceUpdatedAt
        self.isClosed = isClosed
    }
}
