import Foundation
@testable import NineBarCore

final class RadarPipelineHarness: @unchecked Sendable {
    private let scenario: FullTradingSessionScenario
    private let temporaryDirectoryURL: URL
    private let databaseURL: URL
    private let source: PipelineMarketDataSource
    private let notifications = RecordingNotificationSender()
    private let now = isoDate("2026-09-01T14:05:05+08:00")

    init(fixture name: String) throws {
        scenario = try JSONDecoder().decode(FullTradingSessionScenario.self, from: fixture(name))
        temporaryDirectoryURL = try temporaryDirectory()
        databaseURL = temporaryDirectoryURL.appendingPathComponent("pipeline.sqlite")
        source = PipelineMarketDataSource(
            series: try scenario.minuteSeries(receivedAt: now),
            quote: try scenario.liveQuote(now: now)
        )
    }

    func runToEnd() async throws {
        let firstBars = try BarRepository(databaseURL: databaseURL)
        let firstSignals = try SignalRepository(databaseURL: databaseURL)
        let first = makeCoordinator(barStore: firstBars, signalStore: firstSignals)
        try await first.refreshNow()
        try await first.refreshNow()

        let restartedBars = try BarRepository(databaseURL: databaseURL)
        let restartedSignals = try SignalRepository(databaseURL: databaseURL)
        let restarted = makeCoordinator(barStore: restartedBars, signalStore: restartedSignals)
        try await restarted.refreshNow()
    }

    var signalKeys: [String] {
        get async {
            guard let repository = try? SignalRepository(databaseURL: databaseURL),
                  let signals = try? await repository.recent(limit: 100) else {
                return []
            }
            return signals.map(\.id).sorted()
        }
    }

    var historyKeys: [String] {
        get async {
            guard let repository = try? SignalRepository(databaseURL: databaseURL),
                  let signals = try? await repository.recent(limit: 100) else {
                return []
            }
            return signals.map(\.id)
        }
    }

    var deliveredNotificationKeys: [String] {
        get async { await notifications.events.map(\.key) }
    }

    var duplicateNotificationCount: Int {
        get async {
            let keys = await notifications.events.map(\.key)
            return keys.count - Set(keys).count
        }
    }

    var oneMinuteBarCount: Int {
        get async { await barCount(timeframe: .oneMinute) }
    }

    var fiveMinuteBarCount: Int {
        get async { await barCount(timeframe: .fiveMinutes) }
    }

    var notificationLedgerKeys: [String] {
        get async {
            guard let database = try? SQLiteDatabase(url: databaseURL),
                  let keys = try? database.query(
                    "SELECT key FROM notification_events ORDER BY key ASC",
                    map: { try $0.text(0) }
                  ) else {
                return []
            }
            return keys
        }
    }

    var projectSQLiteSidecars: [String] {
        get async {
            let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                return ["enumeration-failed"]
            }
            return enumerator.compactMap { item -> String? in
                guard let url = item as? URL else { return nil }
                return url.lastPathComponent.hasSuffix("-wal") || url.lastPathComponent.hasSuffix("-shm")
                    ? url.path
                    : nil
            }.sorted()
        }
    }

    func cleanup() async throws {
        try FileManager.default.removeItem(at: temporaryDirectoryURL)
    }

    private func makeCoordinator(
        barStore: BarRepository,
        signalStore: SignalRepository
    ) -> RadarCoordinator {
        RadarCoordinator(
            watchlist: StubWatchlist(items: [scenario.instrument.value]),
            marketData: source,
            barStore: barStore,
            signalStore: signalStore,
            notifications: notifications,
            settings: RadarSettings(
                enabledTimeframes: [.oneMinute, .fiveMinutes],
                notifyAtEight: false,
                notifyAtNine: true
            ),
            now: { [now] in now }
        )
    }

    private func barCount(timeframe: Timeframe) async -> Int {
        guard let repository = try? BarRepository(databaseURL: databaseURL),
              let bars = try? await repository.load(
                instrumentID: scenario.instrument.value.id,
                timeframe: timeframe,
                from: .distantPast
              ) else {
            return 0
        }
        return bars.count
    }
}

private actor PipelineMarketDataSource: MarketDataSource {
    let series: MinuteSeries
    let quote: Quote

    init(series: MinuteSeries, quote: Quote) {
        self.series = series
        self.quote = quote
    }

    func fetchMinuteSeries(for instrument: Instrument, tradingDay: Date) async throws -> MinuteSeries {
        guard instrument.id == series.instrument.id else { throw MarketDataError.invalidResponse }
        return series
    }

    func fetchQuotes(for instruments: [Instrument]) async throws -> [Quote] {
        guard instruments.map(\.id) == [series.instrument.id] else {
            throw MarketDataError.invalidResponse
        }
        return [quote]
    }
}

private struct FullTradingSessionScenario: Decodable {
    let instrument: ScenarioInstrument
    let tradingDay: String
    let previousClose: Double
    let morning: Morning
    let afternoon: Afternoon

    struct ScenarioInstrument: Decodable {
        let symbol: String
        let name: String
        let exchange: Exchange
        let kind: SecurityKind

        var value: Instrument {
            Instrument(symbol: symbol, name: name, exchange: exchange, kind: kind)
        }
    }

    struct Morning: Decodable {
        let start: String
        let closes: [Double]
    }

    struct Afternoon: Decodable {
        let start: String
        let groupCount: Int
        let baseStart: Double
        let baseStep: Double
        let offsets: [Double]
    }

    func minuteSeries(receivedAt: Date) throws -> MinuteSeries {
        let morningStart = try scenarioDate(time: morning.start)
        let afternoonStart = try scenarioDate(time: afternoon.start)
        let afternoonCloses = (0..<afternoon.groupCount).flatMap { group in
            afternoon.offsets.map { afternoon.baseStart + Double(group) * afternoon.baseStep + $0 }
        }
        let timestampedCloses = morning.closes.enumerated().map {
            (morningStart.addingTimeInterval(Double($0.offset * 60)), $0.element)
        } + afternoonCloses.enumerated().map {
            (afternoonStart.addingTimeInterval(Double($0.offset * 60)), $0.element)
        }

        var priorClose = previousClose
        let points = timestampedCloses.map { timestamp, close -> MinutePoint in
            defer { priorClose = close }
            return MinutePoint(
                timestamp: timestamp,
                open: priorClose,
                high: close + 0.1,
                low: close - 0.1,
                close: close,
                volume: 100,
                amount: close * 100,
                sourceUpdatedAt: receivedAt
            )
        }
        return MinuteSeries(
            instrument: instrument.value,
            previousClose: previousClose,
            points: points,
            receivedAt: receivedAt
        )
    }

    func liveQuote(now: Date) throws -> Quote {
        let finalGroupBase = afternoon.baseStart + Double(afternoon.groupCount) * afternoon.baseStep
        let price = finalGroupBase + afternoon.offsets[0]
        return Quote(
            instrumentID: instrument.value.id,
            timestamp: now,
            price: price,
            high: price + 0.1,
            low: price - 0.1,
            volume: 100,
            amount: price * 100,
            sourceUpdatedAt: now
        )
    }

    private func scenarioDate(time: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        guard let date = formatter.date(from: "\(tradingDay) \(time)") else {
            throw PipelineFixtureError.invalidDate
        }
        return date
    }
}

private enum PipelineFixtureError: Error {
    case invalidDate
}
