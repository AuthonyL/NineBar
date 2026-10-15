import Foundation
@testable import NineBarCore

func temporarySettingsURL() throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("NineBarSettingsTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("settings.json")
}

func writeTestText(_ value: String, to url: URL) throws {
    try Data(value.utf8).write(to: url, options: .atomic)
}

func readTestText(at url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
}

func readSettingsDocument(at url: URL) throws -> SettingsDocument {
    try JSONDecoder().decode(SettingsDocument.self, from: Data(contentsOf: url))
}

func temporaryLogDirectory() throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("NineBarLogsTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

func testDate(seconds: Int) -> Date {
    Date(timeIntervalSince1970: TimeInterval(seconds))
}

func testLogFiles(in directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("radar") }
}

func testLogLines(in file: URL) throws -> [String] {
    try String(contentsOf: file, encoding: .utf8)
        .split(separator: "\n")
        .map(String.init)
}

func testLogLineKeys(_ line: String) throws -> Set<String> {
    let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
    guard let values = object as? [String: Any] else {
        throw TestLogError.invalidObject
    }
    return Set(values.keys)
}

func testLogLineInstrumentID(_ line: String) throws -> String? {
    let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
    guard let values = object as? [String: Any] else {
        throw TestLogError.invalidObject
    }
    return values["instrumentID"] as? String
}

func retentionTestDates(count: Int) -> [Date] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let start = calendar.date(from: DateComponents(
        calendar: calendar,
        timeZone: calendar.timeZone,
        year: 2026,
        month: 7,
        day: 1
    ))!
    return (0..<count).compactMap {
        calendar.date(byAdding: .day, value: $0, to: start)
    }
}

private enum TestLogError: Error {
    case invalidObject
}

actor PruneRecordingBarStore: BarStoring {
    private let dates: [Date]
    private var cutoffs: [Date] = []

    init(dates: [Date]) {
        self.dates = dates
    }

    func upsert(_ bars: [Bar]) throws {}
    func load(instrumentID: String, timeframe: Timeframe, from: Date) throws -> [Bar] { [] }
    func distinctTradingDates() throws -> [Date] { dates }
    func prune(before cutoff: Date) throws { cutoffs.append(cutoff) }
    func prunedBefore() -> [Date] { cutoffs }
}

actor PruneRecordingSignalStore: SignalStoring {
    private var cutoffs: [Date] = []
    private var signals: [ConfirmedSignal]
    private var pruneFailures: Int

    init(signals: [ConfirmedSignal] = [], pruneFailures: Int = 0) {
        self.signals = signals
        self.pruneFailures = pruneFailures
    }

    func insertIfAbsent(_ signal: ConfirmedSignal) throws -> Bool {
        guard !signals.contains(where: { $0.id == signal.id }) else { return false }
        signals.append(signal)
        return true
    }
    func recordNotificationIfNew(key: String, createdAt: Date) throws -> Bool { false }
    func recent(limit: Int) throws -> [ConfirmedSignal] {
        Array(signals.sorted { $0.lastBarEnd > $1.lastBarEnd }.prefix(limit))
    }
    func updatePerformance(using bars: [Bar]) throws {}
    func prune(before cutoff: Date) throws {
        cutoffs.append(cutoff)
        if pruneFailures > 0 {
            pruneFailures -= 1
            throw RetentionProbeError.pruneFailed
        }
        signals.removeAll { $0.lastBarEnd < cutoff }
    }
    func prunedBefore() -> [Date] { cutoffs }
}

func retentionSignal(end: Date) -> ConfirmedSignal {
    ConfirmedSignal(
        instrumentID: "sh.600519",
        timeframe: .oneMinute,
        direction: .top,
        sequenceStart: end.addingTimeInterval(-8 * 60),
        lastBarEnd: end,
        lastClose: 10,
        extremePrice: 10.4,
        sourceUpdatedAt: end,
        return5m: nil,
        return15m: nil,
        return30m: nil,
        return60m: nil
    )
}

private enum RetentionProbeError: Error {
    case pruneFailed
}

actor SuspendedWatchlist: WatchlistProviding {
    private let items: [Instrument]
    private var requestCount = 0
    private var isReleased = false
    private var waiter: CheckedContinuation<Void, Never>?

    init(items: [Instrument]) {
        self.items = items
    }

    func load() async throws -> [Instrument] {
        requestCount += 1
        if !isReleased {
            await withCheckedContinuation { continuation in
                waiter = continuation
            }
        }
        return items
    }

    func waitUntilFirstRequest() async {
        while requestCount == 0 {
            await Task.yield()
        }
    }

    func resume() {
        isReleased = true
        waiter?.resume()
        waiter = nil
    }

    func resolutionRequestCount() -> Int {
        requestCount
    }
}

actor SuspendedFailingFirstWatchlist: WatchlistProviding {
    private let items: [Instrument]
    private var requestCount = 0
    private var firstFailureWaiter: CheckedContinuation<Void, Never>?

    init(items: [Instrument]) {
        self.items = items
    }

    func load() async throws -> [Instrument] {
        requestCount += 1
        guard requestCount == 1 else { return items }
        await withCheckedContinuation { continuation in
            firstFailureWaiter = continuation
        }
        throw WatchlistStoreError.unreadable
    }

    func waitUntilFirstRequest() async {
        while requestCount == 0 {
            await Task.yield()
        }
    }

    func resumeFirstFailure() {
        firstFailureWaiter?.resume()
        firstFailureWaiter = nil
    }

    func resolutionRequestCount() -> Int {
        requestCount
    }
}

actor SuspendedSecondWatchlist: WatchlistProviding {
    private let items: [Instrument]
    private var requestCount = 0
    private var secondRequestWaiter: CheckedContinuation<Void, Never>?

    init(items: [Instrument]) {
        self.items = items
    }

    func load() async throws -> [Instrument] {
        requestCount += 1
        if requestCount == 2 {
            await withCheckedContinuation { continuation in
                secondRequestWaiter = continuation
            }
            try Task.checkCancellation()
        }
        return items
    }

    func waitUntilSecondRequest() async {
        while requestCount < 2 {
            await Task.yield()
        }
    }

    func resumeSecondRequest() {
        secondRequestWaiter?.resume()
        secondRequestWaiter = nil
    }

    func resolutionRequestCount() -> Int {
        requestCount
    }
}

struct CancellingWatchlist: WatchlistProviding {
    func load() async throws -> [Instrument] {
        throw CancellationError()
    }
}

actor DiagnosticRecorder: DiagnosticLogging {
    private var categories: [DiagnosticErrorCategory] = []

    func record(
        timestamp: Date,
        component: DiagnosticComponent,
        errorCategory: DiagnosticErrorCategory,
        instrument: Instrument?
    ) {
        categories.append(errorCategory)
    }

    func recordedCategories() -> [DiagnosticErrorCategory] {
        categories
    }
}

actor AsyncCompletionMarker {
    private var finished = false

    func finish() {
        finished = true
    }

    func isFinished() -> Bool {
        finished
    }
}

enum MarketDataCancellationBoundary: Sendable {
    case quote
    case series
}

actor URLCancellationMarketDataSource: MarketDataSource {
    private let boundary: MarketDataCancellationBoundary
    private let shape: URLCancellationErrorShape

    init(boundary: MarketDataCancellationBoundary, shape: URLCancellationErrorShape) {
        self.boundary = boundary
        self.shape = shape
    }

    func fetchMinuteSeries(for instrument: Instrument, tradingDay: Date) async throws -> MinuteSeries {
        if boundary == .series {
            try throwCancellation()
        }
        throw MarketDataError.emptyPayload
    }

    func fetchQuotes(for instruments: [Instrument]) async throws -> [Quote] {
        if boundary == .quote {
            try throwCancellation()
        }
        return []
    }

    private func throwCancellation() throws {
        switch shape {
        case .urlError:
            throw URLError(.cancelled)
        case .nsError:
            throw NSError(domain: NSURLErrorDomain, code: URLError.cancelled.rawValue)
        }
    }
}

actor MultiSeriesCancellationMarketDataSource: MarketDataSource {
    private let cancellingInstrumentID: String
    private let siblingInstrumentID: String
    private var requestCounts: [String: Int] = [:]
    private var siblingStarted = false
    private var siblingCancellationRequested = false
    private var siblingCancellationCount = 0
    private var siblingContinuation: CheckedContinuation<MinuteSeries, Error>?

    init(cancellingInstrumentID: String, siblingInstrumentID: String) {
        self.cancellingInstrumentID = cancellingInstrumentID
        self.siblingInstrumentID = siblingInstrumentID
    }

    func fetchMinuteSeries(for instrument: Instrument, tradingDay: Date) async throws -> MinuteSeries {
        requestCounts[instrument.id, default: 0] += 1
        if instrument.id == cancellingInstrumentID {
            while !siblingStarted {
                await Task.yield()
            }
            throw URLError(.cancelled)
        }
        if instrument.id == siblingInstrumentID {
            return try await waitForSiblingCancellation()
        }
        throw MarketDataError.emptyPayload
    }

    func fetchQuotes(for instruments: [Instrument]) async throws -> [Quote] {
        []
    }

    func requestCount(for instrumentID: String) -> Int {
        requestCounts[instrumentID, default: 0]
    }

    func siblingWasCancelled() -> Bool {
        siblingCancellationCount > 0
    }

    func releaseSiblingForTestCleanup() {
        siblingContinuation?.resume(throwing: MarketDataError.emptyPayload)
        siblingContinuation = nil
    }

    private func waitForSiblingCancellation() async throws -> MinuteSeries {
        siblingStarted = true
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MinuteSeries, Error>) in
                if siblingCancellationRequested {
                    continuation.resume(throwing: CancellationError())
                } else {
                    siblingContinuation = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelSibling() }
        }
    }

    private func cancelSibling() {
        siblingCancellationRequested = true
        siblingCancellationCount += 1
        siblingContinuation?.resume(throwing: CancellationError())
        siblingContinuation = nil
    }
}
