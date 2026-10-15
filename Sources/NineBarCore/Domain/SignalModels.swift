import Foundation

public enum SignalDirection: String, Codable, Sendable {
    case top
    case bottom
}

public enum SequencePhase: String, Codable, Sendable {
    case counting
    case candidate
    case confirmed
}

public struct SequenceSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let instrumentID: String
    public let timeframe: Timeframe
    public let direction: SignalDirection
    public let count: Int
    public let phase: SequencePhase
    public let sequenceStart: Date
    public let lastBarEnd: Date
    public let extremePrice: Double
    public let lastClose: Double

    public init(
        instrumentID: String,
        timeframe: Timeframe,
        direction: SignalDirection,
        count: Int,
        phase: SequencePhase,
        sequenceStart: Date,
        lastBarEnd: Date,
        extremePrice: Double,
        lastClose: Double
    ) {
        self.instrumentID = instrumentID
        self.timeframe = timeframe
        self.direction = direction
        self.count = count
        self.phase = phase
        self.sequenceStart = sequenceStart
        self.lastBarEnd = lastBarEnd
        self.extremePrice = extremePrice
        self.lastClose = lastClose
    }

    public var id: String {
        "\(instrumentID)|\(timeframe.rawValue)|\(direction.rawValue)|\(Int(sequenceStart.timeIntervalSince1970))"
    }
}

public struct ConfirmedSignal: Codable, Equatable, Identifiable, Sendable {
    public let instrumentID: String
    public let timeframe: Timeframe
    public let direction: SignalDirection
    public let sequenceStart: Date
    public let lastBarEnd: Date
    public let lastClose: Double
    public let extremePrice: Double
    public let sourceUpdatedAt: Date
    public var return5m: Double?
    public var return15m: Double?
    public var return30m: Double?
    public var return60m: Double?

    public init(
        instrumentID: String,
        timeframe: Timeframe,
        direction: SignalDirection,
        sequenceStart: Date,
        lastBarEnd: Date,
        lastClose: Double,
        extremePrice: Double,
        sourceUpdatedAt: Date,
        return5m: Double?,
        return15m: Double?,
        return30m: Double?,
        return60m: Double?
    ) {
        self.instrumentID = instrumentID
        self.timeframe = timeframe
        self.direction = direction
        self.sequenceStart = sequenceStart
        self.lastBarEnd = lastBarEnd
        self.lastClose = lastClose
        self.extremePrice = extremePrice
        self.sourceUpdatedAt = sourceUpdatedAt
        self.return5m = return5m
        self.return15m = return15m
        self.return30m = return30m
        self.return60m = return60m
    }

    public var id: String {
        "\(instrumentID)|\(timeframe.rawValue)|\(direction.rawValue)|\(Int(lastBarEnd.timeIntervalSince1970))"
    }
}
