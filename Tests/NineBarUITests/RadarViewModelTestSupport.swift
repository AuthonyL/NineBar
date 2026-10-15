import Foundation
import NineBarCore

@MainActor
func radarState(
    health: DataHealth = .healthy(radarDate("10:10")),
    sequences: [SequenceSnapshot] = []
) -> RadarState {
    let watchlist = sequences.map { sequence in
        Instrument(
            symbol: String(sequence.instrumentID.suffix(6)),
            name: "证券\(sequence.instrumentID.suffix(6))",
            exchange: .shanghai,
            kind: .stock
        )
    }
    return RadarState(health: health, watchlist: watchlist, sequences: sequences)
}

@MainActor
func radarTop(
    _ count: Int,
    phase: SequencePhase,
    lastBarEnd: Date,
    timeframe: Timeframe = .oneMinute,
    symbol: String = "000001"
) -> SequenceSnapshot {
    radarSequence(
        symbol: symbol,
        count: count,
        direction: .top,
        phase: phase,
        lastBarEnd: lastBarEnd,
        timeframe: timeframe
    )
}

@MainActor
func radarBottom(
    _ count: Int,
    phase: SequencePhase,
    lastBarEnd: Date,
    timeframe: Timeframe = .oneMinute,
    symbol: String = "000001"
) -> SequenceSnapshot {
    radarSequence(
        symbol: symbol,
        count: count,
        direction: .bottom,
        phase: phase,
        lastBarEnd: lastBarEnd,
        timeframe: timeframe
    )
}

@MainActor
private func radarSequence(
    symbol: String,
    count: Int,
    direction: SignalDirection,
    phase: SequencePhase,
    lastBarEnd: Date,
    timeframe: Timeframe
) -> SequenceSnapshot {
    SequenceSnapshot(
        instrumentID: "sh.\(symbol)",
        timeframe: timeframe,
        direction: direction,
        count: count,
        phase: phase,
        sequenceStart: radarDate("09:30"),
        lastBarEnd: lastBarEnd,
        extremePrice: direction == .top ? 12 : 8,
        lastClose: 10
    )
}

@MainActor
func radarDate(_ time: String) -> Date {
    let parts = time.split(separator: ":").compactMap { Int($0) }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar.date(from: DateComponents(
        calendar: calendar,
        timeZone: calendar.timeZone,
        year: 2026,
        month: 9,
        day: 1,
        hour: parts[0],
        minute: parts[1]
    ))!
}

actor StateStreamRecordingCoordinator: RadarCoordinating {
    private var streamRequests = 0
    private var startRequests = 0
    private let state = RadarState()

    func start() async {
        startRequests += 1
        try? await Task.sleep(for: .milliseconds(30))
    }

    func stop() {}

    func refreshNow() throws {}

    func states() -> AsyncStream<RadarState> {
        streamRequests += 1
        return AsyncStream { _ in }
    }

    func currentState() -> RadarState {
        state
    }

    func recentBars(instrumentID: String, timeframe: Timeframe, limit: Int) -> [Bar] {
        []
    }

    func streamRequestCount() -> Int {
        streamRequests
    }

    func startRequestCount() -> Int {
        startRequests
    }
}

actor LiveStateCoordinator: RadarCoordinating {
    private var state: RadarState
    private var continuations: [AsyncStream<RadarState>.Continuation] = []

    init(initialState: RadarState) {
        state = initialState
    }

    func start() {}
    func stop() {
        for continuation in continuations {
            continuation.finish()
        }
        continuations.removeAll()
    }
    func refreshNow() throws {}
    func states() -> AsyncStream<RadarState> {
        AsyncStream { continuation in
            continuations.append(continuation)
            continuation.yield(state)
        }
    }
    func currentState() -> RadarState { state }
    func recentBars(instrumentID: String, timeframe: Timeframe, limit: Int) -> [Bar] { [] }

    func emit(_ next: RadarState) {
        state = next
        for continuation in continuations {
            continuation.yield(next)
        }
    }
}

func chartBars(_ starts: [String], openAt: String? = nil) -> [Bar] {
    starts.enumerated().map { index, startText in
        let start = chartDate(startText)
        let close = 10 + Double(index) * 0.1
        return Bar(
            instrumentID: "sh.000001",
            timeframe: .oneMinute,
            start: start,
            end: start.addingTimeInterval(60),
            open: close - 0.05,
            high: close + 0.1,
            low: close - 0.1,
            close: close,
            volume: 100,
            amount: close * 100,
            sourceUpdatedAt: chartDate("10:00"),
            isClosed: startText != openAt
        )
    }
}

func chartSequence(
    count: Int,
    phase: SequencePhase,
    start: String,
    lastEnd: String
) -> SequenceSnapshot {
    SequenceSnapshot(
        instrumentID: "sh.000001",
        timeframe: .oneMinute,
        direction: .top,
        count: count,
        phase: phase,
        sequenceStart: chartDate(start),
        lastBarEnd: chartDate(lastEnd),
        extremePrice: 12,
        lastClose: 11
    )
}

func chartDate(_ time: String) -> Date {
    let parts = time.split(separator: ":").compactMap { Int($0) }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar.date(from: DateComponents(
        calendar: calendar,
        timeZone: calendar.timeZone,
        year: 2026,
        month: 9,
        day: 1,
        hour: parts[0],
        minute: parts[1]
    ))!
}
