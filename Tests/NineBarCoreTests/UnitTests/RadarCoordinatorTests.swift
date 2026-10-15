import Testing
@testable import NineBarCore

@Suite("RadarCoordinatorTests")
struct RadarCoordinatorTests {
    @Test("stores a completed nine and persistently delivers each enabled alert once in ledger-before-send order")
    func completedNineIsStoredAndNotifiedOnce() async throws {
        let instrument = sh("600519")
        let source = FakeMarketDataSource(results: [instrument.id: .success(try topNineMinuteSeries())])
        let operations = OperationRecorder()
        let store = InMemoryRadarStore(recorder: operations)
        let notifications = RecordingNotificationSender(recorder: operations)
        let first = coordinator(
            watchlist: StubWatchlist(items: [instrument]),
            source: source,
            store: store,
            notifications: notifications
        )

        try await first.refreshNow()
        try await first.refreshNow()
        let restarted = coordinator(
            watchlist: StubWatchlist(items: [instrument]),
            source: source,
            store: store,
            notifications: notifications
        )
        try await restarted.refreshNow()

        #expect(await store.signals.count == 1)
        #expect(await notifications.level9.count == 1)
        let deliveredKeys = await notifications.events.map(\.key)
        let operationValues = await operations.snapshot()
        for key in deliveredKeys {
            let ledger = try #require(operationValues.firstIndex(of: "ledger:\(key)"))
            let send = try #require(operationValues.firstIndex(of: "send:\(key)"))
            #expect(ledger < send)
        }
    }

    @Test("isolates malformed instruments and keeps deterministic successful state")
    func oneMalformedInstrumentDoesNotStopOtherSymbols() async throws {
        let good = sz("300750")
        let bad = sh("600519")
        let source = FakeMarketDataSource(results: [
            bad.id: .failure(.malformedPayload),
            good.id: .success(try bottomEightSeries())
        ])
        let radar = makeCoordinator(source: source, watchlist: [good, bad])

        try await radar.refreshNow()
        let state = await radar.currentState()

        #expect(state.failures.map(\.instrumentID) == [bad.id])
        #expect(state.failures.allSatisfy { !$0.message.contains("http") && !$0.message.contains("{") })
        #expect(state.sequences.map(\.instrumentID) == [good.id])
        #expect(state.health == .healthy(radarNow))
    }

    @Test("a stale source neither stores nor advances confirmed state")
    func staleDataCannotAdvanceConfirmedCount() async throws {
        let source = try staleSeriesSource(age: 76)
        let store = InMemoryRadarStore()
        let notifications = RecordingNotificationSender()
        let radar = makeCoordinator(
            source: source,
            watchlist: [sh("600519")],
            store: store,
            notifications: notifications
        )

        try await radar.refreshNow()
        let state = await radar.currentState()

        #expect(state.health == .stale)
        #expect(state.sequences.filter { $0.phase == .confirmed }.isEmpty)
        #expect(await store.signals.isEmpty)
        #expect(await notifications.events.isEmpty)
    }

    @Test("fresh transport receipt cannot hide frozen EastMoney minute progress")
    func adapterReceiptTimeCannotHideFrozenMinuteProgress() async throws {
        let instrument = sh("600519")
        let source = EastMoneyMarketDataSource(
            client: RoutingFixtureHTTPClient(
                minuteData: payload(#"{"rc":0,"data":{"name":"样例股票","preClose":10,"trends":["2026-09-01 09:30,10.00,10.00,10.00,10.00,100,1000","2026-09-01 09:31,10.00,10.01,10.03,9.99,1000,10010","2026-09-01 09:32,10.01,10.02,10.04,10.00,800,8016","2026-09-01 09:33,10.02,10.00,10.03,9.98,1200,12000"]}}"#),
                quoteData: payload(#"{"rc":0,"data":{"diff":[{"f2":10,"f5":100,"f6":1000,"f12":"600519","f13":1,"f14":"样例股票","f15":10.1,"f16":9.9,"f124":1788228005}]}}"#)
            ),
            now: { radarNow }
        )
        let store = InMemoryRadarStore()
        let notifications = RecordingNotificationSender()
        let radar = RadarCoordinator(
            watchlist: StubWatchlist(items: [instrument]),
            marketData: source,
            barStore: store,
            signalStore: store,
            notifications: notifications,
            settings: RadarSettings(enabledTimeframes: [.oneMinute]),
            now: { radarNow }
        )

        try await radar.refreshNow()

        #expect(await radar.currentState().health == .stale)
        #expect(await store.bars.isEmpty)
        #expect(await store.signals.isEmpty)
        #expect(await radar.currentState().sequences.isEmpty)
        #expect(await notifications.events.isEmpty)
    }

    @Test("an explicit stale-payload failure reports stale health")
    func stalePayloadErrorReportsStaleHealth() async throws {
        let instrument = sh("600519")
        let source = FakeMarketDataSource(results: [instrument.id: .failure(.stalePayload)])
        let radar = makeCoordinator(source: source, watchlist: [instrument])

        try await radar.refreshNow()

        #expect(await radar.currentState().health == .stale)
    }

    @Test("wrong-day payloads from every instrument resolve a closed session")
    func wrongTradingDayPayloadsResolveClosedSession() async throws {
        let instruments = [sh("600519"), sz("159915")]
        let source = FakeMarketDataSource(results: Dictionary(
            uniqueKeysWithValues: instruments.map {
                ($0.id, Result<MinuteSeries, MarketDataError>.failure(.wrongTradingDayPayload))
            }
        ))
        let radar = makeCoordinator(source: source, watchlist: instruments)

        try await radar.refreshNow()

        #expect(await radar.currentState().health == .closed)
        #expect(await radar.currentState().failures.isEmpty)
    }

    @Test("before the next open the market shows closed, keeps the last session and logs nothing")
    func beforeNextOpenShowsClosedAndKeepsLastSession() async throws {
        let instrument = sz("300750")
        let mutableNow = MutableRadarNow(radarNow)
        let logger = DiagnosticRecorder()
        let radar = RadarCoordinator(
            watchlist: StubWatchlist(items: [instrument]),
            marketData: SessionThenClosedMarketDataSource(
                sessionDay: radarNow,
                series: try bottomEightSeries(instrument: instrument)
            ),
            barStore: InMemoryRadarStore(),
            signalStore: InMemoryRadarStore(),
            notifications: RecordingNotificationSender(),
            settings: RadarSettings(enabledTimeframes: [.oneMinute]),
            logger: logger,
            now: { mutableNow.read() }
        )

        try await radar.refreshNow()
        let session = await radar.currentState()
        // 10:00:05 on 2026-09-01 to 07:50 the next morning, before the open.
        mutableNow.advance(by: 21 * 60 * 60 + 49 * 60 + 55)
        try await radar.refreshNow()
        let closed = await radar.currentState()

        #expect(!session.sequences.isEmpty)
        #expect(closed.health == .closed)
        #expect(closed.failures.isEmpty)
        #expect(closed.sequences == session.sequences)
        #expect(closed.watchlist == session.watchlist)
        #expect(await logger.recordedCategories().isEmpty)
    }

    @Test("a stale symbol remains an instrument failure when another symbol is fresh")
    func mixedFreshAndStaleSeriesRemainGloballyHealthy() async throws {
        let staleInstrument = sh("600519")
        let freshInstrument = sz("300750")
        let source = FakeMarketDataSource(results: [
            staleInstrument.id: .success(try topNineMinuteSeries(
                instrument: staleInstrument,
                receivedAt: radarNow.addingTimeInterval(-76)
            )),
            freshInstrument.id: .success(try bottomEightSeries(instrument: freshInstrument))
        ])
        let radar = makeCoordinator(
            source: source,
            watchlist: [staleInstrument, freshInstrument]
        )

        try await radar.refreshNow()
        let state = await radar.currentState()

        #expect(state.health == .healthy(radarNow))
        #expect(state.failures.map(\.instrumentID) == [staleInstrument.id])
        #expect(state.sequences.map(\.instrumentID) == [freshInstrument.id])
    }

    @Test("historical bootstrap stores completions and ledger keys without delivery")
    func historicalBootstrapStoresButDoesNotNotify() async throws {
        let store = InMemoryRadarStore()
        let notifications = RecordingNotificationSender()
        let source = try historicalTopNineSource(age: 3_600)
        let radar = RadarCoordinator(
            watchlist: StubWatchlist(items: [sh("600519")]),
            marketData: source,
            barStore: store,
            signalStore: store,
            notifications: notifications,
            settings: RadarSettings(enabledTimeframes: [.oneMinute]),
            now: { isoDate("2026-09-01T16:00:05+08:00") }
        )

        try await radar.refreshNow()

        let signal = try #require(await store.signals.first)
        #expect(await notifications.events.isEmpty)
        #expect(await store.notificationKeys.contains("\(signal.instrumentID)|1|top|\(Int(signal.sequenceStart.timeIntervalSince1970))|9"))
    }

    @Test("limits concurrent minute-series calls to four")
    func limitsConcurrentSeriesFetches() async throws {
        let instruments = [
            "600000", "600001", "600002", "600003", "600004",
            "600005", "600006", "600007", "600008"
        ].map(sh)
        var results: [String: Result<MinuteSeries, MarketDataError>] = [:]
        for instrument in instruments {
            results[instrument.id] = .success(try historicalTopNineSeries(instrument: instrument))
        }
        let source = FakeMarketDataSource(results: results, delay: .milliseconds(25))
        let radar = makeCoordinator(source: source, watchlist: instruments)

        try await radar.refreshNow()

        #expect(await source.seriesRequestCount == instruments.count)
        #expect(await source.maximumActiveSeriesRequests <= 4)
        #expect(await radar.currentState().watchlist.map(\.id) == instruments.map(\.id).sorted())
    }

    @Test("quote batch failure cannot block minute history")
    func quoteBatchFailureDoesNotBlockHistory() async throws {
        let instrument = sh("600519")
        let source = FakeMarketDataSource(
            results: [instrument.id: .success(try topNineMinuteSeries())],
            quoteResult: .failure(.httpStatus(503))
        )
        let store = InMemoryRadarStore()
        let radar = makeCoordinator(source: source, watchlist: [instrument], store: store)

        try await radar.refreshNow()

        #expect(await store.signals.count == 1)
        #expect(await source.seriesRequestCount == 1)
    }

    @Test("a watchlist load failure stays visible and keeps the last loaded symbols")
    func watchlistLoadFailureKeepsLastLoadedSymbols() async throws {
        let instrument = sh("600519")
        let watchlist = ScriptedWatchlist(responses: [
            .success([instrument]),
            .failure(.unreadable)
        ])
        let source = FakeMarketDataSource(results: [instrument.id: .success(try topNineMinuteSeries())])
        let store = InMemoryRadarStore()
        let radar = coordinator(
            watchlist: watchlist,
            source: source,
            store: store,
            notifications: RecordingNotificationSender(),
            settings: RadarSettings(enabledTimeframes: [.oneMinute])
        )

        try await radar.refreshNow()
        await #expect(throws: WatchlistStoreError.unreadable) {
            try await radar.refreshNow()
        }

        #expect(await watchlist.loadCount == 2)
        #expect(await radar.currentState().watchlist.map(\.id) == [instrument.id])
        #expect(await radar.currentState().health == .unavailable("Watchlist unavailable"))
    }

    @Test("notification settings suppress disabled levels")
    func notificationSettingsAreApplied() async throws {
        let instrument = sh("600519")
        let source = FakeMarketDataSource(results: [instrument.id: .success(try topNineMinuteSeries())])
        let store = InMemoryRadarStore()
        let notifications = RecordingNotificationSender()
        let radar = coordinator(
            watchlist: StubWatchlist(items: [instrument]),
            source: source,
            store: store,
            notifications: notifications,
            settings: RadarSettings(
                enabledTimeframes: [.oneMinute],
                notifyAtEight: false,
                notifyAtNine: false
            )
        )

        try await radar.refreshNow()

        #expect(await notifications.events.isEmpty)
        #expect(await store.notificationKeys.isEmpty)
    }

    @Test("the level-nine sound setting is carried to delivery")
    func levelNineSoundSettingIsApplied() async throws {
        let instrument = sh("600519")
        let source = FakeMarketDataSource(results: [instrument.id: .success(try topNineMinuteSeries())])
        let notifications = RecordingNotificationSender()
        let radar = coordinator(
            watchlist: StubWatchlist(items: [instrument]),
            source: source,
            store: InMemoryRadarStore(),
            notifications: notifications,
            settings: RadarSettings(
                enabledTimeframes: [.oneMinute],
                notifyAtEight: false,
                notifyAtNine: true,
                soundAtNine: false
            )
        )

        try await radar.refreshNow()

        let event = try #require(await notifications.level9.first)
        #expect(event.playsSound == false)
    }

    @Test("a completion is stored and notified even after its active sequence disappears")
    func completionPersistsAndNotifiesWithoutEnteringLiveState() async throws {
        let instrument = sh("600519")
        let source = FakeMarketDataSource(results: [
            instrument.id: .success(try topNineMinuteSeries(brokenAfterCompletion: true))
        ])
        let store = InMemoryRadarStore()
        let notifications = RecordingNotificationSender()
        let cycleNow = radarNow.addingTimeInterval(60)
        let radar = RadarCoordinator(
            watchlist: StubWatchlist(items: [instrument]),
            marketData: source,
            barStore: store,
            signalStore: store,
            notifications: notifications,
            settings: RadarSettings(enabledTimeframes: [.oneMinute]),
            now: { cycleNow }
        )

        try await radar.refreshNow()

        #expect(await store.signals.count == 1)
        #expect(await notifications.level9.count == 1)
        #expect(await radar.currentState().sequences.isEmpty)
    }

    @Test("after-nine active state keeps advancing past the frozen completion bar")
    func afterNineActiveStateIsNotOverwrittenByCompletion() async throws {
        let instrument = sh("600519")
        let source = FakeMarketDataSource(results: [
            instrument.id: .success(try continuedAfterTopNineSeries())
        ])
        let store = InMemoryRadarStore()
        let cycleNow = radarNow.addingTimeInterval(60)
        let radar = RadarCoordinator(
            watchlist: StubWatchlist(items: [instrument]),
            marketData: source,
            barStore: store,
            signalStore: store,
            notifications: RecordingNotificationSender(),
            settings: RadarSettings(enabledTimeframes: [.oneMinute]),
            now: { cycleNow }
        )

        try await radar.refreshNow()

        let sequence = try #require(await radar.currentState().sequences.first)
        let completion = try #require(await store.signals.first)
        #expect(sequence.phase == .confirmed)
        #expect(sequence.count == 9)
        #expect(sequence.lastBarEnd == isoDate("2026-09-01T10:01:00+08:00"))
        #expect(sequence.lastBarEnd > completion.lastBarEnd)
        #expect(sequence.lastClose == 113)
        #expect(completion.lastClose == 112)
    }

    @Test("a live candidate nine never confirms or emits level nine")
    func candidateNineNeverConfirms() async throws {
        let instrument = sh("600519")
        let quote = Quote(
            instrumentID: instrument.id,
            timestamp: isoDate("2026-09-01T09:59:30+08:00"),
            price: 112,
            high: 112.1,
            low: 111.9,
            volume: 100,
            amount: 11_200,
            sourceUpdatedAt: isoDate("2026-09-01T09:59:30+08:00")
        )
        let source = FakeMarketDataSource(
            results: [instrument.id: .success(try topEightSeries())],
            quoteResult: .success([quote])
        )
        let store = InMemoryRadarStore()
        let notifications = RecordingNotificationSender()
        let radar = makeCoordinator(
            source: source,
            watchlist: [instrument],
            store: store,
            notifications: notifications
        )

        try await radar.refreshNow()

        let sequence = try #require(await radar.currentState().sequences.first)
        #expect(sequence.count == 9)
        #expect(sequence.phase == .candidate)
        #expect(await store.signals.isEmpty)
        #expect(await notifications.level9.isEmpty)
    }

    @Test("full refresh builds five-minute candidate eight and nine without completing nine")
    func fullRefreshBuildsFiveMinuteLiveCandidates() async throws {
        for (completedGroups, partialMinutes, expectedCount) in [(11, 0, 8), (12, 0, 9), (12, 2, 9)] {
            let instrument = sh("600519")
            let fixture = try fiveMinuteCandidateFixture(
                completedGroupCount: completedGroups,
                completedMinutesInCurrentBucket: partialMinutes
            )
            let source = FakeMarketDataSource(
                results: [instrument.id: .success(fixture.series)],
                quoteResult: .success([fixture.quote])
            )
            let store = InMemoryRadarStore()
            let notifications = RecordingNotificationSender()
            let radar = RadarCoordinator(
                watchlist: StubWatchlist(items: [instrument]),
                marketData: source,
                barStore: store,
                signalStore: store,
                notifications: notifications,
                settings: RadarSettings(enabledTimeframes: [.fiveMinutes]),
                now: { fixture.now }
            )

            try await radar.refreshNow()

            let sequence = try #require(await radar.currentState().sequences.first)
            #expect(sequence.timeframe == .fiveMinutes)
            #expect(sequence.count == expectedCount)
            #expect(sequence.phase == .candidate)
            #expect(await store.signals.isEmpty)
            #expect(await notifications.events.map(\.level) == [.level8])
            #expect(await notifications.level9.isEmpty)
        }
    }

    @Test("ten-second quote refresh preserves a five-minute candidate nine")
    func quoteRefreshBuildsFiveMinuteLiveCandidate() async throws {
        let instrument = sh("600519")
        let fixture = try fiveMinuteCandidateFixture(completedGroupCount: 12)
        let source = FakeMarketDataSource(
            results: [instrument.id: .success(fixture.series)],
            quoteResult: .success([fixture.quote])
        )
        let clock = MutableRadarNow(fixture.now)
        let sleeper = AdvancingThenBlockingSleeper(clock: clock, advanceSeconds: 10)
        let store = InMemoryRadarStore()
        let radar = RadarCoordinator(
            watchlist: StubWatchlist(items: [instrument]),
            marketData: source,
            barStore: store,
            signalStore: store,
            notifications: RecordingNotificationSender(),
            settings: RadarSettings(enabledTimeframes: [.fiveMinutes], notifyAtEight: false),
            now: { clock.read() },
            sleep: { duration in try await sleeper.sleep(for: duration) }
        )

        await radar.start()
        try await eventually { await sleeper.calls == 2 }
        await radar.stop()

        let sequence = try #require(await radar.currentState().sequences.first)
        #expect(await source.quoteRequestCount == 2)
        #expect(sequence.timeframe == .fiveMinutes)
        #expect(sequence.count == 9)
        #expect(sequence.phase == .candidate)
        #expect(await store.signals.isEmpty)
    }

    @Test("quote refresh keeps a broken completed sequence out of live state")
    func quoteRefreshDoesNotRestoreHistoricalCompletionToLiveState() async throws {
        let instrument = sh("600519")
        let cycleNow = radarNow.addingTimeInterval(60)
        let series = try topNineMinuteSeries(brokenAfterCompletion: true)
        let source = FakeMarketDataSource(results: [instrument.id: .success(series)])
        let clock = MutableRadarNow(cycleNow)
        let sleeper = AdvancingThenBlockingSleeper(clock: clock, advanceSeconds: 10)
        let store = InMemoryRadarStore()
        let notifications = RecordingNotificationSender()
        let radar = RadarCoordinator(
            watchlist: StubWatchlist(items: [instrument]),
            marketData: source,
            barStore: store,
            signalStore: store,
            notifications: notifications,
            settings: RadarSettings(enabledTimeframes: [.oneMinute]),
            now: { clock.read() },
            sleep: { duration in try await sleeper.sleep(for: duration) }
        )

        await radar.start()
        try await eventually { await sleeper.calls == 2 }
        await radar.stop()

        #expect(await source.seriesRequestCount == 1)
        #expect(await store.signals.count == 1)
        #expect(await notifications.level9.count == 1)
        #expect(await radar.currentState().sequences.isEmpty)
    }

    @Test("state streams yield the current value and one immutable refresh update")
    func stateStreamPublishesCurrentAndRefreshedState() async throws {
        let instrument = sh("600519")
        let source = FakeMarketDataSource(results: [instrument.id: .success(try topNineMinuteSeries())])
        let radar = makeCoordinator(source: source, watchlist: [instrument])
        let stream = await radar.states()
        var iterator = stream.makeAsyncIterator()

        #expect(await iterator.next()?.health == .idle)
        try await radar.refreshNow()
        let update = await iterator.next()

        #expect(update?.health == .healthy(radarNow))
        #expect(update?.sequences.first?.phase == .confirmed)
    }

    @Test("identity mismatch clears a previously valid series before quote refresh")
    func identityMismatchClearsCachedSeriesBeforeQuoteCycle() async throws {
        let instrument = sh("600519")
        let valid = try topEightSeries(instrument: instrument)
        var mismatched = valid
        mismatched.instrument = sz("300750")
        let quote = Quote(
            instrumentID: instrument.id,
            timestamp: radarNow,
            price: 112,
            high: 112.1,
            low: 111.9,
            volume: 100,
            amount: 11_200,
            sourceUpdatedAt: radarNow
        )
        let source = SequencedMarketDataSource(
            series: [valid, mismatched],
            quotes: [quote]
        )
        let clock = MutableRadarNow(radarNow)
        let sleeper = AdvancingThenBlockingSleeper(clock: clock, advanceSeconds: 10)
        let store = InMemoryRadarStore()
        let radar = RadarCoordinator(
            watchlist: StubWatchlist(items: [instrument]),
            marketData: source,
            barStore: store,
            signalStore: store,
            notifications: RecordingNotificationSender(),
            settings: RadarSettings(enabledTimeframes: [.oneMinute], notifyAtEight: false),
            now: { clock.read() },
            sleep: { duration in try await sleeper.sleep(for: duration) }
        )

        try await radar.refreshNow()
        #expect(await radar.currentState().sequences.map(\.count) == [8])
        try await radar.refreshNow()
        #expect(await radar.currentState().failures.map(\.instrumentID) == [instrument.id])
        #expect(await radar.currentState().sequences.isEmpty)

        await radar.start()
        try await eventually { await sleeper.calls == 2 }
        await radar.stop()

        #expect(await source.quoteRequestCount == 3)
        #expect(await radar.currentState().sequences.isEmpty)
    }

    @Test("recent bars returns only the requested ascending suffix")
    func recentBarsReturnsAscendingSuffix() async throws {
        let store = InMemoryRadarStore()
        let instrument = sh("600519")
        let series = try topNineMinuteSeries()
        let bars = BarAggregator().oneMinuteBars(from: series, now: radarNow)
        try await store.upsert(Array(bars.reversed()))
        let source = FakeMarketDataSource(results: [:])
        let radar = makeCoordinator(source: source, watchlist: [], store: store)

        let recent = try await radar.recentBars(instrumentID: instrument.id, timeframe: .oneMinute, limit: 3)

        #expect(recent.map(\.start) == Array(bars.suffix(3)).map(\.start))
        #expect(try await radar.recentBars(instrumentID: instrument.id, timeframe: .oneMinute, limit: 0).isEmpty)
    }

    @Test("start is idempotent and stop cancels and awaits its owned polling task")
    func startAndStopOwnOneCancellableTask() async throws {
        let instrument = sh("600519")
        let source = FakeMarketDataSource(results: [instrument.id: .success(try topNineMinuteSeries())])
        let sleeper = BlockingPollingSleeper()
        let radar = RadarCoordinator(
            watchlist: StubWatchlist(items: [instrument]),
            marketData: source,
            barStore: InMemoryRadarStore(),
            signalStore: InMemoryRadarStore(),
            notifications: RecordingNotificationSender(),
            settings: RadarSettings(enabledTimeframes: [.oneMinute]),
            now: { radarNow },
            sleep: { duration in try await sleeper.sleep(for: duration) }
        )

        await radar.start()
        await radar.start()
        try await eventually { await sleeper.calls == 1 }
        await radar.stop()
        await radar.stop()

        #expect(await source.seriesRequestCount == 1)
        #expect(await sleeper.cancellations == 1)
    }

    @Test("a wake gap performs a same-day resync that ledgers but suppresses new alerts")
    func wakeGapResyncSuppressesAlerts() async throws {
        let instrument = sh("600519")
        let source = SequencedMarketDataSource(series: [
            try topEightSeries(instrument: instrument),
            try topNineMinuteSeries(instrument: instrument)
        ])
        let store = InMemoryRadarStore()
        let notifications = RecordingNotificationSender()
        let mutableNow = MutableRadarNow(radarNow)
        let sleeper = GapThenBlockingSleeper(clock: mutableNow)
        let radar = RadarCoordinator(
            watchlist: StubWatchlist(items: [instrument]),
            marketData: source,
            barStore: store,
            signalStore: store,
            notifications: notifications,
            settings: RadarSettings(enabledTimeframes: [.oneMinute]),
            now: { mutableNow.read() },
            sleep: { duration in try await sleeper.sleep(for: duration) }
        )

        await radar.start()
        try await eventually { await sleeper.calls == 2 }
        await radar.stop()

        #expect(await source.seriesRequestCount == 2)
        #expect(await notifications.level9.isEmpty)
        #expect(await store.notificationKeys.contains { $0.hasSuffix("|9") })
        #expect(await sleeper.cancellations == 1)
    }

    @Test("slow market work is not misclassified as a wake gap")
    func slowCycleWorkDoesNotTriggerWakeSuppression() async throws {
        let instrument = sh("600519")
        let mutableNow = MutableRadarNow(radarNow)
        let source = WorkAdvancingMarketDataSource(
            series: try topEightSeries(instrument: instrument),
            clock: mutableNow,
            workAdvanceSeconds: 25
        )
        let sleeper = AdvancingThenBlockingSleeper(clock: mutableNow, advanceSeconds: 10)
        let store = InMemoryRadarStore()
        let radar = RadarCoordinator(
            watchlist: StubWatchlist(items: [instrument]),
            marketData: source,
            barStore: store,
            signalStore: store,
            notifications: RecordingNotificationSender(),
            settings: RadarSettings(enabledTimeframes: [.oneMinute], notifyAtEight: false),
            now: { mutableNow.read() },
            sleep: { duration in try await sleeper.sleep(for: duration) }
        )

        await radar.start()
        try await eventually { await sleeper.calls == 2 }
        await radar.stop()

        #expect(await source.seriesRequestCount == 1)
        #expect(await source.quoteRequestCount == 2)
        #expect(await sleeper.cancellations == 1)
    }

    @Test("weekday holiday resolves the closed state and off-hours polling cadence")
    func weekdayHolidayUsesLowFrequencyFullChecks() async throws {
        let instruments = [
            sh("600519"),
            Instrument(symbol: "159915", name: "159915", exchange: .shenzhen, kind: .etf)
        ]
        let results: [String: Result<MinuteSeries, MarketDataError>] = Dictionary(
            uniqueKeysWithValues: instruments.map { ($0.id, Result.failure(.emptyPayload)) }
        )
        let source = FakeMarketDataSource(results: results)
        let sleeper = FirstSleepRecordingSleeper()
        let radar = RadarCoordinator(
            watchlist: StubWatchlist(items: instruments),
            marketData: source,
            barStore: InMemoryRadarStore(),
            signalStore: InMemoryRadarStore(),
            notifications: RecordingNotificationSender(),
            now: { radarNow },
            sleep: { duration in try await sleeper.sleep(for: duration) }
        )

        await radar.start()
        try await eventually { await sleeper.calls == 1 }
        await radar.stop()

        #expect(await radar.currentState().health == .closed)
        #expect(await sleeper.durations == [.seconds(60)])
        #expect(await source.seriesRequestCount == 2)
        #expect(await source.quoteRequestCount == 1)
    }

    @Test("partial and malformed current-day results remain unavailable instead of closed")
    func partialMalformedCurrentDayDoesNotMasqueradeAsHoliday() async throws {
        let empty = sh("600519")
        let malformed = Instrument(
            symbol: "159915",
            name: "159915",
            exchange: .shenzhen,
            kind: .etf
        )
        let source = FakeMarketDataSource(results: [
            empty.id: .failure(.emptyPayload),
            malformed.id: .failure(.malformedPayload)
        ])
        let radar = makeCoordinator(source: source, watchlist: [empty, malformed])

        try await radar.refreshNow()

        #expect(await radar.currentState().health == .unavailable("Market data unavailable"))
    }

    @Test("same-day frozen progress remains stale instead of closed")
    func frozenCurrentDayDoesNotMasqueradeAsHoliday() async throws {
        let instrument = sh("600519")
        let frozen = try radarMinuteSeries(
            instrument: instrument,
            start: isoDate("2026-09-01T09:30:00+08:00"),
            closes: [10, 10.1, 10.2],
            receivedAt: radarNow
        )
        let radar = makeCoordinator(
            source: FakeMarketDataSource(results: [instrument.id: .success(frozen)]),
            watchlist: [instrument]
        )

        try await radar.refreshNow()

        #expect(await radar.currentState().health == .stale)
    }

    @Test("resolved holiday expires and recovers on the next Shanghai date")
    func resolvedHolidayExpiresOnNextShanghaiDate() async throws {
        let instrument = sh("600519")
        let mutableNow = MutableRadarNow(radarNow)
        let nextDayNow = isoDate("2026-09-02T10:00:05+08:00")
        let nextDaySeries = try radarMinuteSeries(
            instrument: instrument,
            start: isoDate("2026-09-02T09:47:00+08:00"),
            closes: (0..<13).map { 100.0 + Double($0) },
            receivedAt: nextDayNow
        )
        let source = HolidayThenOpenMarketDataSource(
            holiday: radarNow,
            openSeries: nextDaySeries
        )
        let store = InMemoryRadarStore()
        let radar = RadarCoordinator(
            watchlist: StubWatchlist(items: [instrument]),
            marketData: source,
            barStore: store,
            signalStore: store,
            notifications: RecordingNotificationSender(),
            settings: RadarSettings(enabledTimeframes: [.oneMinute]),
            now: { mutableNow.read() }
        )

        try await radar.refreshNow()
        #expect(await radar.currentState().health == .closed)

        mutableNow.advance(by: 24 * 60 * 60)
        try await radar.refreshNow()

        #expect(await radar.currentState().health == .healthy(nextDayNow))
        #expect(await store.signals.count == 1)
    }

    @Test("history cleanup sends one retention cutoff to both repositories and refreshes state")
    func historyCleanupUsesOneSharedCutoffAndRefreshesState() async throws {
        let dates = retentionTestDates(count: 31)
        let barStore = PruneRecordingBarStore(dates: dates)
        let signalStore = PruneRecordingSignalStore()
        let radar = RadarCoordinator(
            watchlist: StubWatchlist(items: []),
            marketData: FakeMarketDataSource(results: [:]),
            barStore: barStore,
            signalStore: signalStore,
            notifications: RecordingNotificationSender(),
            now: { radarNow }
        )

        #expect(try await radar.pruneHistory(keeping: 30))

        let expected = try #require(RetentionPolicy.cutoff(tradingDates: dates, keep: 30))
        #expect(await barStore.prunedBefore() == [expected])
        #expect(await signalStore.prunedBefore() == [expected])
        #expect(await radar.currentState().updatedAt == radarNow)
    }

    @Test("history cleanup leaves both repositories untouched when thirty dates are retained")
    func historyCleanupSkipsRetentionAtThirtyDates() async throws {
        let barStore = PruneRecordingBarStore(dates: retentionTestDates(count: 30))
        let signalStore = PruneRecordingSignalStore()
        let radar = RadarCoordinator(
            watchlist: StubWatchlist(items: []),
            marketData: FakeMarketDataSource(results: [:]),
            barStore: barStore,
            signalStore: signalStore,
            notifications: RecordingNotificationSender(),
            now: { radarNow }
        )

        #expect(try await radar.pruneHistory(keeping: 30) == false)
        #expect(await barStore.prunedBefore().isEmpty)
        #expect(await signalStore.prunedBefore().isEmpty)
    }

    @Test("successful full refresh automatically prunes once per Shanghai trading day")
    func fullRefreshAutomaticallyPrunesRetentionOncePerDay() async throws {
        let instrument = sh("600519")
        let dates = retentionTestDates(count: 31)
        let cutoff = try #require(RetentionPolicy.cutoff(tradingDates: dates, keep: 30))
        let oldSignal = retentionSignal(end: dates[0].addingTimeInterval(10 * 60 * 60))
        let recentSignal = retentionSignal(end: dates[30].addingTimeInterval(10 * 60 * 60))
        let barStore = PruneRecordingBarStore(dates: dates)
        let signalStore = PruneRecordingSignalStore(signals: [oldSignal, recentSignal])
        let radar = RadarCoordinator(
            watchlist: StubWatchlist(items: [instrument]),
            marketData: FakeMarketDataSource(results: [
                instrument.id: .success(try topNineMinuteSeries(instrument: instrument))
            ]),
            barStore: barStore,
            signalStore: signalStore,
            notifications: RecordingNotificationSender(),
            settings: RadarSettings(enabledTimeframes: [.oneMinute]),
            now: { radarNow }
        )

        try await radar.refreshNow()
        try await radar.refreshNow()
        let history = await radar.currentState().history

        #expect(await barStore.prunedBefore() == [cutoff])
        #expect(await signalStore.prunedBefore() == [cutoff])
        #expect(!history.contains { $0.id == oldSignal.id })
        #expect(history.contains { $0.id == recentSignal.id })
    }

    @Test("automatic retention failure logs safely and retries the same cutoff")
    func automaticRetentionFailureRetriesLaterFullCycle() async throws {
        let instrument = sh("600519")
        let dates = retentionTestDates(count: 31)
        let cutoff = try #require(RetentionPolicy.cutoff(tradingDates: dates, keep: 30))
        let barStore = PruneRecordingBarStore(dates: dates)
        let signalStore = PruneRecordingSignalStore(pruneFailures: 1)
        let logger = DiagnosticRecorder()
        let radar = RadarCoordinator(
            watchlist: StubWatchlist(items: [instrument]),
            marketData: FakeMarketDataSource(results: [
                instrument.id: .success(try topNineMinuteSeries(instrument: instrument))
            ]),
            barStore: barStore,
            signalStore: signalStore,
            notifications: RecordingNotificationSender(),
            settings: RadarSettings(enabledTimeframes: [.oneMinute]),
            logger: logger,
            now: { radarNow }
        )

        try await radar.refreshNow()
        try await radar.refreshNow()

        #expect(await barStore.prunedBefore() == [cutoff, cutoff])
        #expect(await signalStore.prunedBefore() == [cutoff, cutoff])
        #expect(await logger.recordedCategories().contains(.storage))
        #expect(await radar.currentState().health == .healthy(radarNow))
    }

    @Test("runtime settings reconfigure the existing coordinator on its next full cycle")
    func runtimeSettingsChangeTheNextFullCycle() async throws {
        let instrument = sh("600519")
        let source = FakeMarketDataSource(results: [instrument.id: .success(try bottomEightSeries(instrument: instrument))])
        let radar = coordinator(
            watchlist: StubWatchlist(items: [instrument]),
            source: source,
            store: InMemoryRadarStore(),
            notifications: RecordingNotificationSender(),
            settings: RadarSettings(enabledTimeframes: [.oneMinute])
        )

        try await radar.refreshNow()
        #expect(await radar.currentState().sequences.map(\.timeframe) == [.oneMinute])

        await radar.updateSettings(RadarSettings(enabledTimeframes: [.fiveMinutes]))
        try await radar.refreshNow()

        #expect(await source.seriesRequestCount == 2)
        #expect(await radar.currentState().sequences.isEmpty)
    }

    @Test("an in-flight cycle keeps its original settings snapshot while the next settings value commits")
    func inFlightCycleKeepsItsSettingsSnapshot() async throws {
        let instrument = sh("600519")
        let watchlist = SuspendedWatchlist(items: [instrument])
        let source = FakeMarketDataSource(results: [instrument.id: .success(try bottomEightSeries(instrument: instrument))])
        let radar = RadarCoordinator(
            watchlist: watchlist,
            marketData: source,
            barStore: InMemoryRadarStore(),
            signalStore: InMemoryRadarStore(),
            notifications: RecordingNotificationSender(),
            settings: RadarSettings(enabledTimeframes: [.oneMinute]),
            now: { radarNow }
        )

        let refresh = Task { try await radar.refreshNow() }
        await watchlist.waitUntilFirstRequest()

        let updateFinished = AsyncCompletionMarker()
        let update = Task {
            await radar.updateSettings(RadarSettings(enabledTimeframes: [.fiveMinutes]))
            await updateFinished.finish()
        }
        for _ in 0..<10 { await Task.yield() }

        #expect(await updateFinished.isFinished())
        await watchlist.resume()
        try await refresh.value
        await update.value
        #expect(await radar.currentState().sequences.map(\.timeframe) == [.oneMinute])
    }

    @Test("a refresh requested after a settings update runs a new full cycle after the old snapshot finishes")
    func settingsRefreshRunsAfterAnOlderInFlightCycle() async throws {
        let instrument = sh("600519")
        let watchlist = SuspendedWatchlist(items: [instrument])
        let source = FakeMarketDataSource(results: [instrument.id: .success(try bottomEightSeries(instrument: instrument))])
        let radar = RadarCoordinator(
            watchlist: watchlist,
            marketData: source,
            barStore: InMemoryRadarStore(),
            signalStore: InMemoryRadarStore(),
            notifications: RecordingNotificationSender(),
            settings: RadarSettings(enabledTimeframes: [.oneMinute]),
            now: { radarNow }
        )

        let oldRefresh = Task { try await radar.refreshNow() }
        await watchlist.waitUntilFirstRequest()
        await radar.updateSettings(RadarSettings(enabledTimeframes: [.fiveMinutes]))
        let newRefresh = Task { try await radar.refreshNow() }

        await watchlist.resume()
        try await oldRefresh.value
        try await newRefresh.value

        #expect(await source.seriesRequestCount == 2)
        #expect(await radar.currentState().sequences.isEmpty)
    }

    @Test("an explicit watchlist refresh runs again after a same-settings full cycle")
    func explicitWatchlistRefreshDoesNotCoalesceWithAnOlderFullCycle() async throws {
        let instrument = sh("600519")
        let watchlist = SuspendedWatchlist(items: [instrument])
        let source = FakeMarketDataSource(
            results: [instrument.id: .success(try bottomEightSeries(instrument: instrument))]
        )
        let radar = RadarCoordinator(
            watchlist: watchlist,
            marketData: source,
            barStore: InMemoryRadarStore(),
            signalStore: InMemoryRadarStore(),
            notifications: RecordingNotificationSender(),
            settings: RadarSettings(enabledTimeframes: [.oneMinute]),
            now: { radarNow }
        )

        let olderRefresh = Task { try await radar.refreshNow() }
        await watchlist.waitUntilFirstRequest()
        let watchlistRefresh = Task { try await radar.refreshWatchlistNow() }

        await watchlist.resume()
        try await olderRefresh.value
        try await watchlistRefresh.value

        #expect(await watchlist.resolutionRequestCount() == 2)
        #expect(await source.seriesRequestCount == 2)
    }

    @Test("a cancelled explicit watchlist refresh cannot start after an older cycle finishes")
    func cancelledExplicitWatchlistRefreshDoesNotStartANewCycle() async throws {
        let instrument = sh("600519")
        let watchlist = SuspendedWatchlist(items: [instrument])
        let source = FakeMarketDataSource(
            results: [instrument.id: .success(try bottomEightSeries(instrument: instrument))]
        )
        let radar = RadarCoordinator(
            watchlist: watchlist,
            marketData: source,
            barStore: InMemoryRadarStore(),
            signalStore: InMemoryRadarStore(),
            notifications: RecordingNotificationSender(),
            settings: RadarSettings(enabledTimeframes: [.oneMinute]),
            now: { radarNow }
        )

        let olderRefresh = Task { try await radar.refreshNow() }
        await watchlist.waitUntilFirstRequest()
        let watchlistRefresh = Task { try await radar.refreshWatchlistNow() }
        watchlistRefresh.cancel()

        await watchlist.resume()
        try await olderRefresh.value
        await #expect(throws: CancellationError.self) {
            try await watchlistRefresh.value
        }

        #expect(await watchlist.resolutionRequestCount() == 1)
        #expect(await source.seriesRequestCount == 1)
    }

    @Test("stop prevents a queued explicit watchlist refresh from restarting after shutdown")
    func stopPreventsQueuedExplicitWatchlistRefresh() async throws {
        let instrument = sh("600519")
        let watchlist = SuspendedSecondWatchlist(items: [instrument])
        let source = FakeMarketDataSource(
            results: [instrument.id: .success(try bottomEightSeries(instrument: instrument))]
        )
        let sleeper = BlockingPollingSleeper()
        let radar = RadarCoordinator(
            watchlist: watchlist,
            marketData: source,
            barStore: InMemoryRadarStore(),
            signalStore: InMemoryRadarStore(),
            notifications: RecordingNotificationSender(),
            settings: RadarSettings(enabledTimeframes: [.oneMinute]),
            now: { radarNow },
            sleep: { duration in try await sleeper.sleep(for: duration) }
        )

        await radar.start()
        try await eventually { await sleeper.calls == 1 }
        let olderRefresh = Task { try await radar.refreshNow() }
        await watchlist.waitUntilSecondRequest()
        let watchlistRefresh = Task { try await radar.refreshWatchlistNow() }
        for _ in 0..<100 {
            await Task.yield()
        }

        await radar.stop()
        await watchlist.resumeSecondRequest()

        await #expect(throws: CancellationError.self) {
            try await olderRefresh.value
        }
        await #expect(throws: CancellationError.self) {
            try await watchlistRefresh.value
        }
        #expect(await watchlist.resolutionRequestCount() == 2)
        #expect(await sleeper.cancellations == 1)
    }

    @Test("an explicit watchlist refresh runs after an older same-settings cycle fails")
    func explicitWatchlistRefreshRetriesAfterAnOlderCycleFails() async throws {
        let instrument = sh("600519")
        let watchlist = SuspendedFailingFirstWatchlist(items: [instrument])
        let source = FakeMarketDataSource(
            results: [instrument.id: .success(try bottomEightSeries(instrument: instrument))]
        )
        let radar = RadarCoordinator(
            watchlist: watchlist,
            marketData: source,
            barStore: InMemoryRadarStore(),
            signalStore: InMemoryRadarStore(),
            notifications: RecordingNotificationSender(),
            settings: RadarSettings(enabledTimeframes: [.oneMinute]),
            now: { radarNow }
        )

        let olderRefresh = Task { try await radar.refreshNow() }
        await watchlist.waitUntilFirstRequest()
        let watchlistRefresh = Task { try await radar.refreshWatchlistNow() }

        await watchlist.resumeFirstFailure()
        await #expect(throws: WatchlistStoreError.unreadable) {
            try await olderRefresh.value
        }
        try await watchlistRefresh.value

        #expect(await watchlist.resolutionRequestCount() == 2)
        #expect(await source.seriesRequestCount == 1)
    }

    @Test("cancelling a watchlist refresh does not create a diagnostic entry")
    func cancellationDoesNotCreateDiagnosticEntry() async {
        let logger = DiagnosticRecorder()
        let radar = RadarCoordinator(
            watchlist: CancellingWatchlist(),
            marketData: FakeMarketDataSource(results: [:]),
            barStore: InMemoryRadarStore(),
            signalStore: InMemoryRadarStore(),
            notifications: RecordingNotificationSender(),
            logger: logger,
            now: { radarNow }
        )

        await #expect(throws: CancellationError.self) {
            try await radar.refreshNow()
        }

        #expect(await logger.recordedCategories().isEmpty)
    }

    @Test("a URL-session quote cancellation stops the cycle without diagnostics or unavailable state")
    func URLSessionQuoteCancellationStopsWithoutDiagnostics() async {
        let logger = DiagnosticRecorder()
        let radar = RadarCoordinator(
            watchlist: StubWatchlist(items: [sh("600519")]),
            marketData: URLCancellationMarketDataSource(boundary: .quote, shape: .nsError),
            barStore: InMemoryRadarStore(),
            signalStore: InMemoryRadarStore(),
            notifications: RecordingNotificationSender(),
            logger: logger,
            now: { radarNow }
        )

        await #expect(throws: CancellationError.self) {
            try await radar.refreshNow()
        }

        #expect(await logger.recordedCategories().isEmpty)
        #expect(await radar.currentState().health == .idle)
    }

    @Test("a URL-session minute-series cancellation stops the cycle without diagnostics or unavailable state")
    func URLSessionSeriesCancellationStopsWithoutDiagnostics() async {
        let logger = DiagnosticRecorder()
        let radar = RadarCoordinator(
            watchlist: StubWatchlist(items: [sh("600519")]),
            marketData: URLCancellationMarketDataSource(boundary: .series, shape: .urlError),
            barStore: InMemoryRadarStore(),
            signalStore: InMemoryRadarStore(),
            notifications: RecordingNotificationSender(),
            logger: logger,
            now: { radarNow }
        )

        await #expect(throws: CancellationError.self) {
            try await radar.refreshNow()
        }

        #expect(await logger.recordedCategories().isEmpty)
        #expect(await radar.currentState().health == .idle)
    }

    @Test("a cancelled minute-series request cancels active siblings and never starts queued instruments")
    func cancelledSeriesCancelsSiblingsAndStopsTheQueue() async throws {
        let cancelling = sh("600000")
        let sibling = sh("600001")
        let queued = sh("600002")
        let source = MultiSeriesCancellationMarketDataSource(
            cancellingInstrumentID: cancelling.id,
            siblingInstrumentID: sibling.id
        )
        let logger = DiagnosticRecorder()
        let radar = RadarCoordinator(
            watchlist: StubWatchlist(items: [cancelling, sibling, queued]),
            marketData: source,
            barStore: InMemoryRadarStore(),
            signalStore: InMemoryRadarStore(),
            notifications: RecordingNotificationSender(),
            pollingPolicy: PollingPolicy(maxConcurrentSeriesRequests: 2),
            logger: logger,
            now: { radarNow }
        )

        let refresh = Task { try await radar.refreshNow() }
        for _ in 0..<100 {
            if await source.requestCount(for: queued.id) > 0 {
                await source.releaseSiblingForTestCleanup()
                break
            }
            if await source.siblingWasCancelled() {
                break
            }
            await Task.yield()
        }
        await source.releaseSiblingForTestCleanup()

        await #expect(throws: CancellationError.self) { try await refresh.value }

        #expect(await source.requestCount(for: cancelling.id) == 1)
        #expect(await source.requestCount(for: sibling.id) == 1)
        #expect(await source.requestCount(for: queued.id) == 0)
        #expect(await source.siblingWasCancelled())
        #expect(await logger.recordedCategories().isEmpty)
        #expect(await radar.currentState().health == .idle)
    }

    @Test("re-enabling a level eight alert records a later transition instead of consuming the disabled key")
    func reenabledAlertRecordsLaterTransition() async throws {
        let instrument = sh("600519")
        let seven = try radarMinuteSeries(
            instrument: instrument,
            start: isoDate("2026-09-01T09:47:00+08:00"),
            closes: (0..<11).map { 100.0 + Double($0) },
            receivedAt: radarNow
        )
        let source = SequencedMarketDataSource(series: [seven, try topEightSeries(instrument: instrument)])
        let store = InMemoryRadarStore()
        let notifications = RecordingNotificationSender()
        let radar = coordinator(
            watchlist: StubWatchlist(items: [instrument]),
            source: source,
            store: store,
            notifications: notifications,
            settings: RadarSettings(enabledTimeframes: [.oneMinute], notifyAtEight: false)
        )

        try await radar.refreshNow()
        #expect(await store.notificationKeys.isEmpty)

        await radar.updateSettings(RadarSettings(enabledTimeframes: [.oneMinute], notifyAtEight: true))
        try await radar.refreshNow()

        #expect(await store.notificationKeys.count == 1)
        #expect(await notifications.events.map(\.level) == [.level8])
    }
}

private func coordinator(
    watchlist: any WatchlistProviding,
    source: any MarketDataSource,
    store: InMemoryRadarStore,
    notifications: RecordingNotificationSender,
    settings: RadarSettings = RadarSettings(enabledTimeframes: [.oneMinute])
) -> RadarCoordinator {
    RadarCoordinator(
        watchlist: watchlist,
        marketData: source,
        barStore: store,
        signalStore: store,
        notifications: notifications,
        settings: settings,
        now: { radarNow }
    )
}

private func eventually(
    attempts: Int = 100,
    condition: @escaping @Sendable () async -> Bool
) async throws {
    for _ in 0..<attempts {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Condition was not met before timeout")
}
