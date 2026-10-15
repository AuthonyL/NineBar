import Foundation

public actor RadarCoordinator: RadarCoordinating {
    private let watchlistProvider: any WatchlistProviding
    private let marketData: any MarketDataSource
    private let barStore: any BarStoring
    private let signalStore: any SignalStoring
    private let notifications: any NotificationSending
    private var settings: RadarSettings
    private let pollingPolicy: PollingPolicy
    private let clock: TradingSessionClock
    private let aggregator: BarAggregator
    private let engine: NineCountEngine
    private let freshness = BarFreshness()
    private let notificationPolicy = NotificationPolicy()
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private let calendar: Calendar
    private let logger: (any DiagnosticLogging)?

    private var state = RadarState()
    private var stateContinuations: [UUID: AsyncStream<RadarState>.Continuation] = [:]
    private var activeWatchlist: [Instrument] = []
    private var latestSeriesByID: [String: MinuteSeries] = [:]
    private var runTask: (id: UUID, task: Task<Void, Never>)?
    private var cycleTask: (
        id: UUID,
        kind: CoordinatorCycleKind,
        settingsRevision: Int,
        task: Task<Void, Error>
    )?
    private var settingsRevision = 0
    private var lifecycleGeneration = 0
    private var suppressAlertsUntilFullRefreshCompletes = false
    private var isStopping = false
    private var lastAutomaticRetentionDay: Date?
    private var pendingAutomaticRetention: (day: Date, cutoff: Date)?
    private var resolvedClosedTradingDay: Date?

    public init(
        watchlist: any WatchlistProviding,
        marketData: any MarketDataSource,
        barStore: any BarStoring,
        signalStore: any SignalStoring,
        notifications: any NotificationSending,
        settings: RadarSettings = RadarSettings(),
        pollingPolicy: PollingPolicy = PollingPolicy(),
        clock: TradingSessionClock = TradingSessionClock(),
        logger: (any DiagnosticLogging)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.watchlistProvider = watchlist
        self.marketData = marketData
        self.barStore = barStore
        self.signalStore = signalStore
        self.notifications = notifications
        self.settings = settings
        self.pollingPolicy = pollingPolicy
        self.clock = clock
        self.aggregator = BarAggregator(clock: clock)
        self.engine = NineCountEngine(clock: clock)
        self.logger = logger
        self.now = now
        self.sleep = sleep

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        self.calendar = calendar
    }

    public func start() async {
        guard runTask == nil, !isStopping else { return }
        let id = UUID()
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.runPollingLoop()
        }
        runTask = (id, task)
    }

    public func stop() async {
        guard let running = runTask else { return }
        isStopping = true
        lifecycleGeneration &+= 1
        running.task.cancel()
        cycleTask?.task.cancel()
        await running.task.value
        if runTask?.id == running.id {
            runTask = nil
        }
        isStopping = false
    }

    public func refreshNow() async throws {
        try await runCycle(kind: .full, suppressDelivery: false)
    }

    public func refreshWatchlistNow() async throws {
        try await runCycle(
            kind: .full,
            suppressDelivery: false,
            forceNewCycle: true
        )
    }

    public func updateSettings(_ newSettings: RadarSettings) async {
        guard settings != newSettings else { return }
        settings = newSettings
        settingsRevision += 1
    }

    public func pruneHistory(keeping tradingDays: Int = 30) async throws -> Bool {
        let dates: [Date]
        do {
            dates = try await barStore.distinctTradingDates()
        } catch {
            if isCancellationError(error) {
                throw CancellationError()
            }
            await recordDiagnostic(component: .persistence, category: .storage)
            throw error
        }
        guard let cutoff = RetentionPolicy.cutoff(tradingDates: dates, keep: tradingDays) else {
            return false
        }
        do {
            try await barStore.prune(before: cutoff)
            try await signalStore.prune(before: cutoff)
            let history = try await signalStore.recent(limit: 100)
            publish(RadarState(
                health: state.health,
                watchlist: state.watchlist,
                sequences: state.sequences,
                history: history,
                failures: state.failures,
                updatedAt: now()
            ))
            return true
        } catch {
            if isCancellationError(error) {
                throw CancellationError()
            }
            await recordDiagnostic(component: .persistence, category: .storage)
            throw error
        }
    }

    public func states() async -> AsyncStream<RadarState> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            stateContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeStateContinuation(id) }
            }
            continuation.yield(state)
        }
    }

    public func currentState() async -> RadarState {
        state
    }

    public func recentBars(
        instrumentID: String,
        timeframe: Timeframe,
        limit: Int
    ) async throws -> [Bar] {
        guard limit > 0 else { return [] }
        let bars = try await barStore.load(
            instrumentID: instrumentID,
            timeframe: timeframe,
            from: .distantPast
        )
        return Array(bars.sorted(by: barAscending).suffix(limit))
    }

    private func refresh(suppressDelivery: Bool) async throws {
        try await runCycle(kind: .full, suppressDelivery: suppressDelivery)
    }

    private func runCycle(
        kind: CoordinatorCycleKind,
        suppressDelivery: Bool,
        forceNewCycle: Bool = false
    ) async throws {
        let requestLifecycleGeneration = lifecycleGeneration
        if suppressDelivery {
            suppressAlertsUntilFullRefreshCompletes = true
        }

        while let current = cycleTask {
            do {
                try await current.task.value
            } catch {
                if cycleTask?.id == current.id {
                    cycleTask = nil
                }
                if !(forceNewCycle && kind == .full) {
                    guard kind == .full, current.settingsRevision != settingsRevision else {
                        throw error
                    }
                }
            }
            if cycleTask?.id == current.id {
                cycleTask = nil
            }
            if kind == .quote || (!forceNewCycle
                && current.kind == .full
                && current.settingsRevision == settingsRevision) {
                return
            }

            if let activeCycle = cycleTask, activeCycle.id != current.id {
                continue
            }
            break
        }

        try Task.checkCancellation()
        guard !isStopping, lifecycleGeneration == requestLifecycleGeneration else {
            throw CancellationError()
        }

        let id = UUID()
        let cycleSettings = settings
        let cycleSettingsRevision = settingsRevision
        let task = Task<Void, Error> { [weak self] in
            guard let self else { return }
            switch kind {
            case .full:
                try await self.performFullRefresh(
                    suppressDelivery: suppressDelivery,
                    cycleSettings: cycleSettings
                )
            case .quote:
                try await self.performQuoteRefresh(cycleSettings: cycleSettings)
            }
        }
        cycleTask = (id, kind, cycleSettingsRevision, task)

        do {
            try await task.value
            if cycleTask?.id == id {
                cycleTask = nil
            }
            if kind == .full {
                suppressAlertsUntilFullRefreshCompletes = false
            }
        } catch {
            if cycleTask?.id == id {
                cycleTask = nil
            }
            throw error
        }
    }

    private func performFullRefresh(
        suppressDelivery: Bool,
        cycleSettings: RadarSettings
    ) async throws {
        try Task.checkCancellation()
        let cycleNow = now()
        let previousState = state
        let watchlist: [Instrument]

        do {
            watchlist = sortedUniqueInstruments(try await watchlistProvider.load())
            activeWatchlist = watchlist
        } catch {
            if isCancellationError(error) {
                throw CancellationError()
            }
            await recordDiagnostic(component: .watchlist, category: .unavailable)
            publish(RadarState(
                health: .unavailable("Watchlist unavailable"),
                watchlist: activeWatchlist,
                sequences: previousState.sequences,
                history: previousState.history,
                failures: [],
                updatedAt: cycleNow
            ))
            throw error
        }

        if watchlist.isEmpty {
            let history = try await signalStore.recent(limit: 100)
            publish(RadarState(
                health: .healthy(cycleNow),
                watchlist: [],
                sequences: [],
                history: history,
                failures: [],
                updatedAt: cycleNow
            ))
            return
        }

        let quotes: [Quote]
        do {
            quotes = try await marketData.fetchQuotes(for: watchlist)
        } catch {
            if isCancellationError(error) {
                throw CancellationError()
            }
            await recordDiagnostic(component: .marketData, category: .unavailable)
            quotes = []
        }
        let quotesByID = quotes.reduce(into: [String: Quote]()) { values, quote in
            if values[quote.instrumentID] == nil { values[quote.instrumentID] = quote }
        }
        let fetches = try await fetchMinuteSeries(
            for: watchlist,
            tradingDay: calendar.startOfDay(for: cycleNow)
        )
        try Task.checkCancellation()
        let successfulSeriesCount = fetches.reduce(into: 0) { count, fetch in
            if case .success = fetch.result { count += 1 }
        }
        let marketDataErrors = fetches.compactMap { fetch -> MarketDataError? in
            guard case .failure(.marketData(let error)) = fetch.result else { return nil }
            return error
        }
        // When every symbol says the requested date has no session, the market is closed for
        // that date (before the open, a weekend or a holiday) rather than the source failing.
        let noSessionToday = ActualSessionResolver.resolvesClosedDay(
            requiredSeriesCount: watchlist.count,
            successfulSeriesCount: successfulSeriesCount,
            errors: marketDataErrors
        )
        let resolvedClosedDay = clock.isContinuousTrading(cycleNow) && noSessionToday
        if resolvedClosedDay {
            resolvedClosedTradingDay = calendar.startOfDay(for: cycleNow)
        } else if clock.isContinuousTrading(cycleNow) {
            resolvedClosedTradingDay = nil
        }
        let watchlistIDs = Set(watchlist.map(\.id))
        latestSeriesByID = latestSeriesByID.filter { watchlistIDs.contains($0.key) }

        var failures: [InstrumentFailure] = []
        var enabledBars: [Bar] = []
        var scans: [InstrumentScan] = []
        var freshSeriesCount = 0
        var staleSeriesCount = 0
        var resolvedByID = Dictionary(uniqueKeysWithValues: watchlist.map { ($0.id, $0) })

        for fetch in fetches.sorted(by: { $0.instrument.id < $1.instrument.id }) {
            switch fetch.result {
            case .failure(let error):
                if case .cancelled = error {
                    throw CancellationError()
                }
                latestSeriesByID[fetch.instrument.id] = nil
                guard !noSessionToday else { continue }
                if case .marketData(.stalePayload) = error {
                    staleSeriesCount += 1
                }
                failures.append(InstrumentFailure(
                    instrumentID: fetch.instrument.id,
                    message: safeFailureMessage(error)
                ))
                await recordDiagnostic(
                    component: .marketData,
                    category: diagnosticCategory(for: error),
                    instrument: fetch.instrument
                )
            case .success(let series):
                guard series.instrument.id == fetch.instrument.id else {
                    latestSeriesByID[fetch.instrument.id] = nil
                    failures.append(InstrumentFailure(
                        instrumentID: fetch.instrument.id,
                        message: "Market data identity mismatch"
                    ))
                    continue
                }
                guard !freshness.isStale(series: series, now: cycleNow, clock: clock) else {
                    staleSeriesCount += 1
                    latestSeriesByID[fetch.instrument.id] = nil
                    failures.append(InstrumentFailure(
                        instrumentID: fetch.instrument.id,
                        message: "Market data is stale"
                    ))
                    continue
                }

                freshSeriesCount += 1
                latestSeriesByID[fetch.instrument.id] = series
                resolvedByID[fetch.instrument.id] = series.instrument
                let oneMinuteBars = aggregator.oneMinuteBars(from: series, now: cycleNow)
                let fiveMinuteBars = aggregator.fiveMinuteBars(from: oneMinuteBars)
                let liveOneMinuteBar = quotesByID[fetch.instrument.id].flatMap {
                    aggregator.liveCandidate(from: series, quote: $0)
                }

                for timeframe in cycleSettings.enabledTimeframes.sorted(by: { $0.rawValue < $1.rawValue }) {
                    let completedBars: [Bar]
                    let liveBar: Bar?
                    switch timeframe {
                    case .oneMinute:
                        completedBars = oneMinuteBars
                        liveBar = liveOneMinuteBar
                    case .fiveMinutes:
                        completedBars = fiveMinuteBars
                        liveBar = fiveMinuteLiveCandidate(
                            completedMinutes: oneMinuteBars,
                            liveMinute: liveOneMinuteBar,
                            clock: clock
                        )
                    }
                    enabledBars.append(contentsOf: completedBars)
                    scans.append(InstrumentScan(
                        instrument: series.instrument,
                        result: engine.scan(completedBars: completedBars, liveBar: liveBar)
                    ))
                }
            }
        }

        let sortedBars = enabledBars.sorted(by: barAscending)
        do {
            try await barStore.upsert(sortedBars)
        } catch {
            if isCancellationError(error) {
                throw CancellationError()
            }
            await recordDiagnostic(component: .persistence, category: .storage)
            throw error
        }

        var currentByID: [String: SequenceSnapshot] = [:]
        var notificationByID: [String: SequenceSnapshot] = [:]
        var completionIDs: Set<String> = []
        for scan in scans {
            for active in scan.result.active {
                currentByID[active.id] = active
                notificationByID[active.id] = active
            }
            for completion in scan.result.completions {
                do {
                    _ = try await signalStore.insertIfAbsent(completion)
                } catch {
                    if isCancellationError(error) {
                        throw CancellationError()
                    }
                    await recordDiagnostic(component: .persistence, category: .storage, instrument: scan.instrument)
                    throw error
                }
                let confirmed = confirmedSnapshot(from: completion)
                notificationByID[confirmed.id] = confirmed
                completionIDs.insert(confirmed.id)
            }
        }

        do {
            try await signalStore.updatePerformance(using: sortedBars)
        } catch {
            if isCancellationError(error) {
                throw CancellationError()
            }
            await recordDiagnostic(component: .persistence, category: .storage)
            throw error
        }
        try await enforceAutomaticRetentionIfNeeded(at: cycleNow)
        let currentSequences = currentByID.values
            .filter { (6...9).contains($0.count) }
            .sorted(by: sequenceAscending)
        let notificationSequences = notificationByID.values
            .filter { (6...9).contains($0.count) }
            .sorted(by: sequenceAscending)
        try await applyNotifications(
            previous: previousState.sequences,
            current: notificationSequences,
            completionIDs: completionIDs,
            instrumentsByID: resolvedByID,
            cycleNow: cycleNow,
            suppressDelivery: suppressDelivery,
            cycleSettings: cycleSettings
        )
        let history: [ConfirmedSignal]
        do {
            history = try await signalStore.recent(limit: 100)
        } catch {
            if isCancellationError(error) {
                throw CancellationError()
            }
            await recordDiagnostic(component: .persistence, category: .storage)
            throw error
        }
        let health: DataHealth
        if noSessionToday {
            health = .closed
        } else if freshSeriesCount > 0 {
            health = .healthy(cycleNow)
        } else if staleSeriesCount > 0 {
            health = .stale
        } else {
            health = .unavailable("Market data unavailable")
        }

        if noSessionToday {
            // Keep the names the last session's quotes resolved.
            for previous in previousState.watchlist where resolvedByID[previous.id] != nil {
                resolvedByID[previous.id] = previous
            }
        }

        publish(RadarState(
            health: health,
            watchlist: resolvedByID.values.sorted { $0.id < $1.id },
            // A closed market keeps showing the last session's sequences until the next one starts.
            sequences: noSessionToday ? previousState.sequences : currentSequences,
            history: history,
            failures: failures.sorted { $0.instrumentID < $1.instrumentID },
            updatedAt: cycleNow
        ))
    }

    private func fetchMinuteSeries(for instruments: [Instrument], tradingDay: Date) async throws -> [SeriesFetch] {
        let marketData = self.marketData
        let maximum = min(pollingPolicy.maxConcurrentSeriesRequests, instruments.count)

        return try await withThrowingTaskGroup(of: SeriesFetch.self, returning: [SeriesFetch].self) { group in
            var iterator = instruments.makeIterator()
            var results: [SeriesFetch] = []

            for _ in 0..<maximum {
                guard let instrument = iterator.next() else { break }
                group.addTask {
                    await SeriesFetch.fetch(instrument: instrument, tradingDay: tradingDay, from: marketData)
                }
            }

            while let result = try await group.next() {
                if case .failure(.cancelled) = result.result {
                    group.cancelAll()
                    throw CancellationError()
                }
                results.append(result)
                if let instrument = iterator.next() {
                    group.addTask {
                        await SeriesFetch.fetch(instrument: instrument, tradingDay: tradingDay, from: marketData)
                    }
                }
            }
            return results
        }
    }

    private func applyNotifications(
        previous: [SequenceSnapshot],
        current: [SequenceSnapshot],
        completionIDs: Set<String>,
        instrumentsByID: [String: Instrument],
        cycleNow: Date,
        suppressDelivery: Bool,
        cycleSettings: RadarSettings
    ) async throws {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })

        for sequence in current {
            let events = notificationPolicy.events(previous: previousByID[sequence.id], current: sequence)
            for event in events {
                guard notificationIsEnabled(event.level, settings: cycleSettings) else { continue }
                if event.level == .level9, !completionIDs.contains(sequence.id) {
                    continue
                }

                let isNew = try await signalStore.recordNotificationIfNew(
                    key: event.key,
                    createdAt: cycleNow
                )
                guard isNew,
                      !suppressDelivery,
                      !suppressAlertsUntilFullRefreshCompletes,
                      calendar.isDate(event.sequence.lastBarEnd, inSameDayAs: cycleNow),
                      !freshness.isStale(lastUpdate: event.sequence.lastBarEnd, now: cycleNow),
                      let instrument = instrumentsByID[event.sequence.instrumentID] else {
                    continue
                }
                let deliveryEvent = NotificationEvent(
                    level: event.level,
                    sequence: event.sequence,
                    playsSound: event.level == .level9 && cycleSettings.soundAtNine
                )
                do {
                    try await notifications.send(deliveryEvent, instrumentName: instrument.name)
                } catch {
                    if isCancellationError(error) {
                        throw CancellationError()
                    }
                    await recordDiagnostic(component: .notification, category: .permission, instrument: instrument)
                    throw error
                }
            }
        }
    }

    private func notificationIsEnabled(_ level: NotificationLevel, settings: RadarSettings) -> Bool {
        switch level {
        case .level8:
            settings.notifyAtEight
        case .level9:
            settings.notifyAtNine
        }
    }

    private func enforceAutomaticRetentionIfNeeded(at cycleNow: Date) async throws {
        let tradingDay = calendar.startOfDay(for: cycleNow)
        if let lastAutomaticRetentionDay,
           calendar.isDate(lastAutomaticRetentionDay, inSameDayAs: tradingDay) {
            return
        }

        let cutoff: Date
        if let pendingAutomaticRetention,
           calendar.isDate(pendingAutomaticRetention.day, inSameDayAs: tradingDay) {
            cutoff = pendingAutomaticRetention.cutoff
        } else {
            do {
                let dates = try await barStore.distinctTradingDates()
                guard let resolvedCutoff = RetentionPolicy.cutoff(tradingDates: dates, keep: 30) else {
                    pendingAutomaticRetention = nil
                    lastAutomaticRetentionDay = tradingDay
                    return
                }
                cutoff = resolvedCutoff
                pendingAutomaticRetention = (tradingDay, resolvedCutoff)
            } catch {
                if isCancellationError(error) {
                    throw CancellationError()
                }
                await recordDiagnostic(component: .persistence, category: .storage)
                return
            }
        }

        do {
            try await barStore.prune(before: cutoff)
            try await signalStore.prune(before: cutoff)
            pendingAutomaticRetention = nil
            lastAutomaticRetentionDay = tradingDay
        } catch {
            if isCancellationError(error) {
                throw CancellationError()
            }
            pendingAutomaticRetention = (tradingDay, cutoff)
            await recordDiagnostic(component: .persistence, category: .storage)
        }
    }

    private func runPollingLoop() async {
        var previousSleep: (startedAt: Date, requested: Duration)?
        var lastFinalizedMinute: Date?
        var lastWatchlistRefresh: Date?
        var isFirstTick = true

        while !Task.isCancelled {
            let tick = now()
            let isTrading = clock.isContinuousTrading(tick) && !isResolvedClosedTradingDay(at: tick)
            let wokeAfterGap = previousSleep.map {
                tick.timeIntervalSince($0.startedAt) > durationSeconds($0.requested) * 2
            } ?? false

            do {
                if isFirstTick || wokeAfterGap {
                    try await refresh(suppressDelivery: wokeAfterGap)
                    lastWatchlistRefresh = tick
                    lastFinalizedMinute = finalizableMinute(at: tick)
                    isFirstTick = false
                } else if isTrading {
                    let finalizable = finalizableMinute(at: tick)
                    let watchlistDue = lastWatchlistRefresh.map {
                        tick.timeIntervalSince($0) >= durationSeconds(pollingPolicy.watchlistInterval)
                    } ?? true
                    if finalizable != nil, finalizable != lastFinalizedMinute || watchlistDue {
                        try await refresh(suppressDelivery: false)
                        lastFinalizedMinute = finalizable
                        lastWatchlistRefresh = tick
                    } else {
                        try await runCycle(kind: .quote, suppressDelivery: false)
                    }
                } else if lastWatchlistRefresh.map({
                    tick.timeIntervalSince($0) >= durationSeconds(pollingPolicy.watchlistInterval)
                }) ?? true {
                    try await refresh(suppressDelivery: false)
                    lastWatchlistRefresh = tick
                }
            } catch is CancellationError {
                break
            } catch {
                // A later scheduled cycle retries global source or persistence failures.
            }

            let sleepStartedAt = now()
            let shouldPollFrequently = clock.isContinuousTrading(sleepStartedAt)
                && !isResolvedClosedTradingDay(at: sleepStartedAt)
            let requestedSleep = sleepDuration(after: sleepStartedAt, isTrading: shouldPollFrequently)
            previousSleep = (sleepStartedAt, requestedSleep)
            do {
                try await sleep(requestedSleep)
            } catch {
                break
            }
        }
    }

    private func performQuoteRefresh(cycleSettings: RadarSettings) async throws {
        guard !activeWatchlist.isEmpty, !latestSeriesByID.isEmpty else {
            return
        }
        let cycleNow = now()
        let quotes: [Quote]
        do {
            quotes = try await marketData.fetchQuotes(for: activeWatchlist)
        } catch {
            if isCancellationError(error) {
                throw CancellationError()
            }
            throw error
        }
        let quotesByID = quotes.reduce(into: [String: Quote]()) { values, quote in
            if values[quote.instrumentID] == nil { values[quote.instrumentID] = quote }
        }
        var currentByID: [String: SequenceSnapshot] = [:]
        var notificationByID: [String: SequenceSnapshot] = [:]
        var completionIDs: Set<String> = []

        for instrument in activeWatchlist.sorted(by: { $0.id < $1.id }) {
            guard let series = latestSeriesByID[instrument.id],
                  !freshness.isStale(series: series, now: cycleNow, clock: clock) else {
                continue
            }
            let oneMinuteBars = aggregator.oneMinuteBars(from: series, now: cycleNow)
            let liveOneMinuteBar = quotesByID[instrument.id].flatMap {
                aggregator.liveCandidate(from: series, quote: $0)
            }
            for timeframe in cycleSettings.enabledTimeframes.sorted(by: { $0.rawValue < $1.rawValue }) {
                let completedBars: [Bar]
                let liveBar: Bar?
                switch timeframe {
                case .oneMinute:
                    completedBars = oneMinuteBars
                    liveBar = liveOneMinuteBar
                case .fiveMinutes:
                    completedBars = aggregator.fiveMinuteBars(from: oneMinuteBars)
                    liveBar = fiveMinuteLiveCandidate(
                        completedMinutes: oneMinuteBars,
                        liveMinute: liveOneMinuteBar,
                        clock: clock
                    )
                }
                let scan = engine.scan(completedBars: completedBars, liveBar: liveBar)
                for active in scan.active {
                    currentByID[active.id] = active
                    notificationByID[active.id] = active
                }
                for completion in scan.completions {
                    let confirmed = confirmedSnapshot(from: completion)
                    notificationByID[confirmed.id] = confirmed
                    completionIDs.insert(confirmed.id)
                }
            }
        }

        let sequences = currentByID.values
            .filter { (6...9).contains($0.count) }
            .sorted(by: sequenceAscending)
        let notificationSequences = notificationByID.values
            .filter { (6...9).contains($0.count) }
            .sorted(by: sequenceAscending)
        let instrumentsByID = Dictionary(uniqueKeysWithValues: activeWatchlist.map { ($0.id, $0) })
        try await applyNotifications(
            previous: state.sequences,
            current: notificationSequences,
            completionIDs: completionIDs,
            instrumentsByID: instrumentsByID,
            cycleNow: cycleNow,
            suppressDelivery: false,
            cycleSettings: cycleSettings
        )
        publish(RadarState(
            health: .healthy(cycleNow),
            watchlist: state.watchlist,
            sequences: sequences,
            history: state.history,
            failures: state.failures,
            updatedAt: cycleNow
        ))
    }

    private func finalizableMinute(at date: Date) -> Date? {
        let second = calendar.component(.second, from: date)
        guard second >= Int(durationSeconds(pollingPolicy.minuteFinalizationDelay)) else {
            return nil
        }
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return calendar.date(from: components)
    }

    private func isResolvedClosedTradingDay(at date: Date) -> Bool {
        guard let resolvedClosedTradingDay else { return false }
        guard calendar.isDate(resolvedClosedTradingDay, inSameDayAs: date) else {
            self.resolvedClosedTradingDay = nil
            return false
        }
        return true
    }

    private func sleepDuration(after date: Date, isTrading: Bool) -> Duration {
        guard isTrading else { return pollingPolicy.offHoursInterval }
        let quoteSeconds = durationSeconds(pollingPolicy.quoteInterval)
        let delaySeconds = durationSeconds(pollingPolicy.minuteFinalizationDelay)
        let second = Double(calendar.component(.second, from: date))
        let untilFinalization = second < delaySeconds
            ? delaySeconds - second
            : 60 + delaySeconds - second
        let seconds = max(0.001, min(quoteSeconds, untilFinalization))
        return .milliseconds(Int64((seconds * 1_000).rounded(.up)))
    }

    private func publish(_ newState: RadarState) {
        state = newState
        for continuation in stateContinuations.values {
            continuation.yield(newState)
        }
    }

    private func removeStateContinuation(_ id: UUID) {
        stateContinuations[id] = nil
    }

    private func safeFailureMessage(_ error: SeriesFetchError) -> String {
        guard case .marketData(let marketDataError) = error else {
            return "Market data refresh failed"
        }
        switch marketDataError {
        case .invalidURL, .invalidResponse:
            return "Market data response is invalid"
        case .httpStatus:
            return "Market data service is unavailable"
        case .emptyPayload:
            return "Market data is empty"
        case .malformedPayload:
            return "Market data is malformed"
        case .stalePayload:
            return "Market data is stale"
        case .wrongTradingDayPayload:
            return "Market data is from another trading day"
        }
    }

    private func diagnosticCategory(for error: SeriesFetchError) -> DiagnosticErrorCategory {
        guard case .marketData(let marketDataError) = error else {
            return .unavailable
        }
        switch marketDataError {
        case .malformedPayload:
            return .malformedData
        case .invalidURL, .invalidResponse, .httpStatus, .emptyPayload, .stalePayload, .wrongTradingDayPayload:
            return .unavailable
        }
    }

    private func recordDiagnostic(
        component: DiagnosticComponent,
        category: DiagnosticErrorCategory,
        instrument: Instrument? = nil
    ) async {
        await logger?.record(
            timestamp: now(),
            component: component,
            errorCategory: category,
            instrument: instrument
        )
    }
}

private enum CoordinatorCycleKind: Sendable {
    case full
    case quote
}

private struct SeriesFetch: Sendable {
    let instrument: Instrument
    let result: Result<MinuteSeries, SeriesFetchError>

    static func fetch(
        instrument: Instrument,
        tradingDay: Date,
        from source: any MarketDataSource
    ) async -> SeriesFetch {
        do {
            return SeriesFetch(
                instrument: instrument,
                result: .success(try await source.fetchMinuteSeries(for: instrument, tradingDay: tradingDay))
            )
        } catch is CancellationError {
            return SeriesFetch(instrument: instrument, result: .failure(.cancelled))
        } catch {
            if isCancellationError(error) {
                return SeriesFetch(instrument: instrument, result: .failure(.cancelled))
            }
            if let marketDataError = error as? MarketDataError {
                return SeriesFetch(instrument: instrument, result: .failure(.marketData(marketDataError)))
            }
            return SeriesFetch(instrument: instrument, result: .failure(.other))
        }
    }
}

private enum SeriesFetchError: Error, Sendable {
    case cancelled
    case marketData(MarketDataError)
    case other
}

private struct InstrumentScan: Sendable {
    let instrument: Instrument
    let result: NineCountScanResult
}

private func confirmedSnapshot(from signal: ConfirmedSignal) -> SequenceSnapshot {
    SequenceSnapshot(
        instrumentID: signal.instrumentID,
        timeframe: signal.timeframe,
        direction: signal.direction,
        count: 9,
        phase: .confirmed,
        sequenceStart: signal.sequenceStart,
        lastBarEnd: signal.lastBarEnd,
        extremePrice: signal.extremePrice,
        lastClose: signal.lastClose
    )
}

private func barAscending(_ lhs: Bar, _ rhs: Bar) -> Bool {
    if lhs.instrumentID != rhs.instrumentID { return lhs.instrumentID < rhs.instrumentID }
    if lhs.timeframe != rhs.timeframe { return lhs.timeframe.rawValue < rhs.timeframe.rawValue }
    if lhs.start != rhs.start { return lhs.start < rhs.start }
    return lhs.end < rhs.end
}

private func sequenceAscending(_ lhs: SequenceSnapshot, _ rhs: SequenceSnapshot) -> Bool {
    if lhs.instrumentID != rhs.instrumentID { return lhs.instrumentID < rhs.instrumentID }
    if lhs.timeframe != rhs.timeframe { return lhs.timeframe.rawValue < rhs.timeframe.rawValue }
    if lhs.direction != rhs.direction { return lhs.direction.rawValue < rhs.direction.rawValue }
    if lhs.sequenceStart != rhs.sequenceStart { return lhs.sequenceStart < rhs.sequenceStart }
    return lhs.lastBarEnd < rhs.lastBarEnd
}

private func fiveMinuteLiveCandidate(
    completedMinutes: [Bar],
    liveMinute: Bar?,
    clock: TradingSessionClock
) -> Bar? {
    guard let liveMinute,
          liveMinute.timeframe == .oneMinute,
          !liveMinute.isClosed,
          let minuteIndex = clock.minuteIndex(liveMinute.start) else {
        return nil
    }

    let minuteOffset = minuteIndex % Timeframe.fiveMinutes.rawValue
    let bucketStart = liveMinute.start.addingTimeInterval(Double(-minuteOffset * 60))
    let completed = completedMinutes
        .filter {
            $0.instrumentID == liveMinute.instrumentID
                && $0.timeframe == .oneMinute
                && $0.isClosed
                && $0.start >= bucketStart
                && $0.start < liveMinute.start
        }
        .sorted(by: { $0.start < $1.start })
    guard completed.count == minuteOffset else { return nil }

    for (offset, bar) in completed.enumerated() {
        guard bar.start == bucketStart.addingTimeInterval(Double(offset * 60)) else {
            return nil
        }
    }

    let parts = completed + [liveMinute]
    return Bar(
        instrumentID: liveMinute.instrumentID,
        timeframe: .fiveMinutes,
        start: bucketStart,
        end: bucketStart.addingTimeInterval(5 * 60),
        open: parts[0].open,
        high: parts.map(\.high).max()!,
        low: parts.map(\.low).min()!,
        close: liveMinute.close,
        volume: parts.map(\.volume).reduce(0, +),
        amount: parts.map(\.amount).reduce(0, +),
        sourceUpdatedAt: parts.map(\.sourceUpdatedAt).max()!,
        isClosed: false
    )
}

private func sortedUniqueInstruments(_ instruments: [Instrument]) -> [Instrument] {
    var valuesByID: [String: Instrument] = [:]
    for instrument in instruments where valuesByID[instrument.id] == nil {
        valuesByID[instrument.id] = instrument
    }
    return valuesByID.values.sorted { $0.id < $1.id }
}

private func durationSeconds(_ duration: Duration) -> TimeInterval {
    let components = duration.components
    return TimeInterval(components.seconds)
        + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
}
