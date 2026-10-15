import Foundation

public enum DataHealth: Equatable, Sendable {
    case idle
    /// No symbol has a session for the current Shanghai date: before the open, a weekend or a holiday.
    case closed
    case healthy(Date)
    case stale
    case unavailable(String)
}

public struct InstrumentFailure: Equatable, Sendable {
    public let instrumentID: String
    public let message: String

    public init(instrumentID: String, message: String) {
        self.instrumentID = instrumentID
        self.message = message
    }
}

public struct RadarState: Equatable, Sendable {
    public var health: DataHealth
    public var watchlist: [Instrument]
    public var sequences: [SequenceSnapshot]
    public var history: [ConfirmedSignal]
    public var failures: [InstrumentFailure]
    public var updatedAt: Date?

    public init(
        health: DataHealth = .idle,
        watchlist: [Instrument] = [],
        sequences: [SequenceSnapshot] = [],
        history: [ConfirmedSignal] = [],
        failures: [InstrumentFailure] = [],
        updatedAt: Date? = nil
    ) {
        self.health = health
        self.watchlist = watchlist
        self.sequences = sequences
        self.history = history
        self.failures = failures
        self.updatedAt = updatedAt
    }
}

public protocol RadarCoordinating: Sendable {
    func start() async
    func stop() async
    func refreshNow() async throws
    func refreshWatchlistNow() async throws
    func updateSettings(_ settings: RadarSettings) async
    func pruneHistory(keeping tradingDays: Int) async throws -> Bool
    func states() async -> AsyncStream<RadarState>
    func currentState() async -> RadarState
    func recentBars(instrumentID: String, timeframe: Timeframe, limit: Int) async throws -> [Bar]
}

public extension RadarCoordinating {
    func refreshWatchlistNow() async throws {
        try await refreshNow()
    }

    func updateSettings(_ settings: RadarSettings) async {}

    func pruneHistory(keeping tradingDays: Int) async throws -> Bool {
        false
    }
}
