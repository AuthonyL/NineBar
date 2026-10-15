import Foundation
@testable import NineBarCore

let radarNow = isoDate("2026-09-01T10:00:05+08:00")

struct StubWatchlist: WatchlistProviding {
    let items: [Instrument]

    func load() async throws -> [Instrument] {
        items
    }
}

actor ScriptedWatchlist: WatchlistProviding {
    enum Response: Sendable {
        case success([Instrument])
        case failure(WatchlistStoreError)
    }

    private var responses: [Response]
    private(set) var loadCount = 0

    init(responses: [Response]) {
        self.responses = responses
    }

    func load() async throws -> [Instrument] {
        loadCount += 1
        let response = responses.count > 1 ? responses.removeFirst() : responses[0]
        switch response {
        case .success(let items):
            return items
        case .failure(let error):
            throw error
        }
    }
}

actor OperationRecorder {
    private var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }

    func snapshot() -> [String] {
        values
    }
}

actor RecordingNotificationSender: NotificationSending {
    private(set) var events: [NotificationEvent] = []
    private let recorder: OperationRecorder?

    init(recorder: OperationRecorder? = nil) {
        self.recorder = recorder
    }

    var level9: [NotificationEvent] {
        events.filter { $0.level == .level9 }
    }

    func requestAuthorization() async throws -> Bool {
        true
    }

    func send(_ event: NotificationEvent, instrumentName: String) async throws {
        if let recorder {
            await recorder.append("send:\(event.key)")
        }
        events.append(event)
    }
}

actor FakeMarketDataSource: MarketDataSource {
    private let results: [String: Result<MinuteSeries, MarketDataError>]
    private let quoteResult: Result<[Quote], MarketDataError>
    private let delay: Duration
    private var activeSeriesRequests = 0
    private(set) var maximumActiveSeriesRequests = 0
    private(set) var seriesRequestCount = 0
    private(set) var quoteRequestCount = 0

    init(
        results: [String: Result<MinuteSeries, MarketDataError>],
        quoteResult: Result<[Quote], MarketDataError> = .success([]),
        delay: Duration = .zero
    ) {
        self.results = results
        self.quoteResult = quoteResult
        self.delay = delay
    }

    func fetchMinuteSeries(for instrument: Instrument, tradingDay: Date) async throws -> MinuteSeries {
        seriesRequestCount += 1
        activeSeriesRequests += 1
        maximumActiveSeriesRequests = max(maximumActiveSeriesRequests, activeSeriesRequests)
        defer { activeSeriesRequests -= 1 }

        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        switch results[instrument.id] ?? .failure(.emptyPayload) {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        }
    }

    func fetchQuotes(for instruments: [Instrument]) async throws -> [Quote] {
        quoteRequestCount += 1
        return try quoteResult.get()
    }
}

struct RoutingFixtureHTTPClient: HTTPClient {
    let minuteData: Data
    let quoteData: Data

    func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        let data = url.path.contains("trends2") ? minuteData : quoteData
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        )!
        return (data, response)
    }
}

actor SequencedMarketDataSource: MarketDataSource {
    private var series: [MinuteSeries]
    private let quotes: [Quote]
    private(set) var seriesRequestCount = 0
    private(set) var quoteRequestCount = 0

    init(series: [MinuteSeries], quotes: [Quote] = []) {
        self.series = series
        self.quotes = quotes
    }

    func fetchMinuteSeries(for instrument: Instrument, tradingDay: Date) async throws -> MinuteSeries {
        seriesRequestCount += 1
        guard !series.isEmpty else { throw MarketDataError.emptyPayload }
        return series.count > 1 ? series.removeFirst() : series[0]
    }

    func fetchQuotes(for instruments: [Instrument]) async throws -> [Quote] {
        quoteRequestCount += 1
        return quotes
    }
}

actor WorkAdvancingMarketDataSource: MarketDataSource {
    private let series: MinuteSeries
    private let clock: MutableRadarNow
    private let workAdvanceSeconds: TimeInterval
    private(set) var seriesRequestCount = 0
    private(set) var quoteRequestCount = 0

    init(series: MinuteSeries, clock: MutableRadarNow, workAdvanceSeconds: TimeInterval) {
        self.series = series
        self.clock = clock
        self.workAdvanceSeconds = workAdvanceSeconds
    }

    func fetchMinuteSeries(for instrument: Instrument, tradingDay: Date) async throws -> MinuteSeries {
        seriesRequestCount += 1
        if seriesRequestCount == 1 {
            clock.advance(by: workAdvanceSeconds)
        }
        return series
    }

    func fetchQuotes(for instruments: [Instrument]) async throws -> [Quote] {
        quoteRequestCount += 1
        return []
    }
}

actor InMemoryRadarStore: BarStoring, SignalStoring {
    private(set) var bars: [Bar] = []
    private(set) var signals: [ConfirmedSignal] = []
    private(set) var notificationKeys: Set<String> = []
    private let recorder: OperationRecorder?

    init(recorder: OperationRecorder? = nil) {
        self.recorder = recorder
    }

    func upsert(_ newBars: [Bar]) async throws {
        for bar in newBars {
            if let index = bars.firstIndex(where: {
                $0.instrumentID == bar.instrumentID && $0.timeframe == bar.timeframe && $0.start == bar.start
            }) {
                bars[index] = bar
            } else {
                bars.append(bar)
            }
        }
    }

    func load(instrumentID: String, timeframe: Timeframe, from: Date) async throws -> [Bar] {
        bars
            .filter { $0.instrumentID == instrumentID && $0.timeframe == timeframe && $0.start >= from }
            .sorted { $0.start < $1.start }
    }

    func distinctTradingDates() async throws -> [Date] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return Set(bars.map { calendar.startOfDay(for: $0.start) }).sorted()
    }

    func prune(before: Date) async throws {
        bars.removeAll { $0.start < before }
        signals.removeAll { $0.lastBarEnd < before }
    }

    func insertIfAbsent(_ signal: ConfirmedSignal) async throws -> Bool {
        guard !signals.contains(where: { $0.id == signal.id }) else { return false }
        signals.append(signal)
        return true
    }

    func recordNotificationIfNew(key: String, createdAt: Date) async throws -> Bool {
        if let recorder {
            await recorder.append("ledger:\(key)")
        }
        return notificationKeys.insert(key).inserted
    }

    func recent(limit: Int) async throws -> [ConfirmedSignal] {
        guard limit > 0 else { return [] }
        return Array(signals.sorted {
            if $0.lastBarEnd == $1.lastBarEnd { return $0.id > $1.id }
            return $0.lastBarEnd > $1.lastBarEnd
        }.prefix(limit))
    }

    func updatePerformance(using newBars: [Bar]) async throws {
        for index in signals.indices {
            let signal = signals[index]
            let matching = newBars
                .filter { $0.isClosed && $0.instrumentID == signal.instrumentID && $0.timeframe == signal.timeframe }
                .sorted { $0.end < $1.end }
            let values = [5, 15, 30, 60].map { minutes -> Double? in
                let target = signal.lastBarEnd.addingTimeInterval(Double(minutes * 60))
                guard let bar = matching.first(where: { $0.end >= target }) else { return nil }
                return (bar.close / signal.lastClose) - 1
            }
            signals[index].return5m = values[0] ?? signal.return5m
            signals[index].return15m = values[1] ?? signal.return15m
            signals[index].return30m = values[2] ?? signal.return30m
            signals[index].return60m = values[3] ?? signal.return60m
        }
    }
}

actor BlockingPollingSleeper {
    private(set) var calls = 0
    private(set) var cancellations = 0

    func sleep(for duration: Duration) async throws {
        calls += 1
        do {
            try await Task.sleep(for: .seconds(3_600))
        } catch {
            cancellations += 1
            throw error
        }
    }
}

final class MutableRadarNow: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func read() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(seconds)
        lock.unlock()
    }
}

actor GapThenBlockingSleeper {
    private let clock: MutableRadarNow
    private(set) var calls = 0
    private(set) var cancellations = 0

    init(clock: MutableRadarNow) {
        self.clock = clock
    }

    func sleep(for duration: Duration) async throws {
        calls += 1
        if calls == 1 {
            clock.advance(by: 25)
            return
        }
        do {
            try await Task.sleep(for: .seconds(3_600))
        } catch {
            cancellations += 1
            throw error
        }
    }
}

actor AdvancingThenBlockingSleeper {
    private let clock: MutableRadarNow
    private let advanceSeconds: TimeInterval
    private(set) var calls = 0
    private(set) var cancellations = 0

    init(clock: MutableRadarNow, advanceSeconds: TimeInterval) {
        self.clock = clock
        self.advanceSeconds = advanceSeconds
    }

    func sleep(for duration: Duration) async throws {
        calls += 1
        if calls == 1 {
            clock.advance(by: advanceSeconds)
            return
        }
        do {
            try await Task.sleep(for: .seconds(3_600))
        } catch {
            cancellations += 1
            throw error
        }
    }
}

actor FirstSleepRecordingSleeper {
    private(set) var durations: [Duration] = []
    private(set) var calls = 0

    func sleep(for duration: Duration) async throws {
        calls += 1
        durations.append(duration)
        try await Task.sleep(for: .seconds(3_600))
    }
}

actor HolidayThenOpenMarketDataSource: MarketDataSource {
    private let holiday: Date
    private let openSeries: MinuteSeries
    private var calendar: Calendar

    init(holiday: Date, openSeries: MinuteSeries) {
        self.holiday = holiday
        self.openSeries = openSeries
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        self.calendar = calendar
    }

    func fetchMinuteSeries(for instrument: Instrument, tradingDay: Date) async throws -> MinuteSeries {
        if calendar.isDate(tradingDay, inSameDayAs: holiday) {
            throw MarketDataError.emptyPayload
        }
        return openSeries
    }

    func fetchQuotes(for instruments: [Instrument]) async throws -> [Quote] {
        []
    }
}

/// Serves one session's series on that Shanghai date and, like Eastmoney before the next open,
/// reports every other date as the wrong trading day.
actor SessionThenClosedMarketDataSource: MarketDataSource {
    private let sessionDay: Date
    private let series: MinuteSeries
    private let calendar: Calendar

    init(sessionDay: Date, series: MinuteSeries) {
        self.sessionDay = sessionDay
        self.series = series
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        self.calendar = calendar
    }

    func fetchMinuteSeries(for instrument: Instrument, tradingDay: Date) async throws -> MinuteSeries {
        guard calendar.isDate(tradingDay, inSameDayAs: sessionDay) else {
            throw MarketDataError.wrongTradingDayPayload
        }
        return series
    }

    func fetchQuotes(for instruments: [Instrument]) async throws -> [Quote] {
        []
    }
}

func topNineMinuteSeries(
    instrument: Instrument = sh("600519"),
    receivedAt: Date = radarNow,
    brokenAfterCompletion: Bool = false
) throws -> MinuteSeries {
    var closes = (0..<13).map { 100.0 + Double($0) }
    if brokenAfterCompletion {
        closes.append(50)
    }
    return try radarMinuteSeries(
        instrument: instrument,
        start: isoDate("2026-09-01T09:47:00+08:00"),
        closes: closes,
        receivedAt: receivedAt
    )
}

func continuedAfterTopNineSeries(instrument: Instrument = sh("600519")) throws -> MinuteSeries {
    try radarMinuteSeries(
        instrument: instrument,
        start: isoDate("2026-09-01T09:47:00+08:00"),
        closes: (0..<14).map { 100.0 + Double($0) },
        receivedAt: radarNow
    )
}

func bottomEightSeries(instrument: Instrument = sz("300750")) throws -> MinuteSeries {
    try radarMinuteSeries(
        instrument: instrument,
        start: isoDate("2026-09-01T09:47:00+08:00"),
        closes: (0..<12).map { 100.0 - Double($0) },
        receivedAt: radarNow
    )
}

func topEightSeries(instrument: Instrument = sh("600519")) throws -> MinuteSeries {
    try radarMinuteSeries(
        instrument: instrument,
        start: isoDate("2026-09-01T09:47:00+08:00"),
        closes: (0..<12).map { 100.0 + Double($0) },
        receivedAt: radarNow
    )
}

struct FiveMinuteCandidateFixture: Sendable {
    let series: MinuteSeries
    let quote: Quote
    let now: Date
}

func fiveMinuteCandidateFixture(
    completedGroupCount: Int,
    completedMinutesInCurrentBucket: Int = 0,
    instrument: Instrument = sh("600519")
) throws -> FiveMinuteCandidateFixture {
    let start = isoDate("2026-09-01T09:30:00+08:00")
    let pointCount = completedGroupCount * 5 + completedMinutesInCurrentBucket
    let now = start.addingTimeInterval(Double(pointCount * 60 + 5))
    let closes = (0..<pointCount).map { 100.0 + Double($0) * 0.1 }
    let series = try radarMinuteSeries(
        instrument: instrument,
        start: start,
        closes: closes,
        receivedAt: now
    )
    let lastClose = closes.last ?? 100
    let quote = Quote(
        instrumentID: instrument.id,
        timestamp: now,
        price: lastClose + 0.1,
        high: lastClose + 0.2,
        low: lastClose,
        volume: 100,
        amount: (lastClose + 0.1) * 100,
        sourceUpdatedAt: now
    )
    return FiveMinuteCandidateFixture(series: series, quote: quote, now: now)
}

func historicalTopNineSeries(instrument: Instrument = sh("600519")) throws -> MinuteSeries {
    try radarMinuteSeries(
        instrument: instrument,
        start: isoDate("2026-09-01T09:30:00+08:00"),
        closes: (0..<13).map { 100.0 + Double($0) },
        receivedAt: radarNow
    )
}

func staleSeriesSource(age: TimeInterval) throws -> FakeMarketDataSource {
    let instrument = sh("600519")
    return FakeMarketDataSource(results: [
        instrument.id: .success(try topNineMinuteSeries(instrument: instrument, receivedAt: radarNow.addingTimeInterval(-age)))
    ])
}

func historicalTopNineSource(age: TimeInterval) throws -> FakeMarketDataSource {
    let instrument = sh("600519")
    _ = age
    return FakeMarketDataSource(results: [
        instrument.id: .success(try historicalTopNineSeries(instrument: instrument))
    ])
}

func radarMinuteSeries(
    instrument: Instrument,
    start: Date,
    closes: [Double],
    receivedAt: Date
) throws -> MinuteSeries {
    let points = closes.enumerated().map { offset, close in
        MinutePoint(
            timestamp: start.addingTimeInterval(Double(offset * 60)),
            open: offset == 0 ? close : closes[offset - 1],
            high: close + 0.1,
            low: close - 0.1,
            close: close,
            volume: 100,
            amount: close * 100,
            sourceUpdatedAt: receivedAt
        )
    }
    return MinuteSeries(instrument: instrument, previousClose: closes.first ?? 1, points: points, receivedAt: receivedAt)
}

func makeCoordinator(
    source: FakeMarketDataSource,
    watchlist: [Instrument] = [sh("600519"), sz("300750")],
    store: InMemoryRadarStore = InMemoryRadarStore(),
    notifications: RecordingNotificationSender = RecordingNotificationSender(),
    settings: RadarSettings = RadarSettings(enabledTimeframes: [.oneMinute])
) -> RadarCoordinator {
    RadarCoordinator(
        watchlist: StubWatchlist(items: watchlist),
        marketData: source,
        barStore: store,
        signalStore: store,
        notifications: notifications,
        settings: settings,
        now: { radarNow }
    )
}
