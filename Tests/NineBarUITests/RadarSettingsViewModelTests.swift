import Testing
@testable import NineBarUI
import NineBarCore

@Suite("Radar settings view model")
@MainActor
struct RadarSettingsViewModelTests {
    @Test("pasted watchlist rows infer supported markets and preserve names")
    func pastedWatchlistRowsInferMarketAndKind() throws {
        let known = Instrument(
            symbol: "300750",
            name: "宁德时代",
            exchange: .shenzhen,
            kind: .stock
        )

        let parsed = try WatchlistTextParser.parse(
            "1\t300750\t宁德时代\t-1.50%\n513080 法国ETF华安\n159915",
            knownInstruments: [known]
        )

        #expect(parsed.map(\.id) == ["sz.300750", "sh.513080", "sz.159915"])
        #expect(parsed.map(\.name) == ["宁德时代", "法国ETF华安", "159915"])
        #expect(parsed.map(\.kind) == [.stock, .etf, .etf])
    }

    @Test("replacement rejects bonds B shares and unknown prefixes")
    func replacementRejectsUnsupportedSecurityCodes() {
        for code in ["110000", "200002", "900901", "123456", "999999"] {
            #expect(throws: WatchlistTextParser.ParseError.unsupportedCode(line: 1)) {
                try WatchlistTextParser.parse(code, knownInstruments: [])
            }
        }
    }

    @Test("replacing the watchlist saves only the pasted symbols and reloads the watchlist")
    func replacingWatchlistSavesReplacement() async {
        let watchlistStore = RecordingWatchlistStore()
        let settingsStore = RecordingSettingsStore()
        let coordinator = SettingsRecordingCoordinator()
        let model = RadarViewModel(
            coordinator: coordinator,
            initialState: RadarState(watchlist: [Instrument(
                symbol: "300750",
                name: "宁德时代",
                exchange: .shenzhen,
                kind: .stock
            )]),
            settingsStore: settingsStore,
            watchlistStore: watchlistStore
        )

        let saved = await model.replaceWatchlist(text: "300750\t宁德时代\n513080\t法国ETF华安")

        #expect(saved)
        #expect(await watchlistStore.latest().map(\.id) == ["sh.513080", "sz.300750"])
        #expect(await settingsStore.savedValues().isEmpty)
        #expect(await coordinator.appliedSettings().isEmpty)
        #expect(await coordinator.refreshCount() == 1)
    }

    @Test("an empty replacement clears the saved watchlist")
    func emptyReplacementClearsWatchlist() async {
        let watchlistStore = RecordingWatchlistStore(value: [Instrument(
            symbol: "600519",
            name: "贵州茅台",
            exchange: .shanghai,
            kind: .stock
        )])
        let coordinator = SettingsRecordingCoordinator()
        let model = RadarViewModel(
            coordinator: coordinator,
            initialState: RadarState(),
            watchlistStore: watchlistStore
        )

        let saved = await model.replaceWatchlist(text: " \n")

        #expect(saved)
        #expect(await watchlistStore.latest().isEmpty)
        #expect(model.watchlistErrorMessage == nil)
        #expect(await coordinator.refreshCount() == 1)
    }

    @Test("a storage failure keeps the saved watchlist and reports the error")
    func replacementStorageFailureKeepsSavedWatchlist() async {
        let existing = [Instrument(
            symbol: "300750",
            name: "宁德时代",
            exchange: .shenzhen,
            kind: .stock
        )]
        let watchlistStore = FailingWatchlistStore(value: existing)
        let coordinator = SettingsRecordingCoordinator()
        let model = RadarViewModel(
            coordinator: coordinator,
            initialState: RadarState(),
            watchlistStore: watchlistStore
        )

        let saved = await model.replaceWatchlist(text: "513080 法国ETF华安")

        #expect(!saved)
        #expect(await watchlistStore.latest() == existing)
        #expect(model.watchlistErrorMessage == "自选股列表保存失败")
        #expect(await coordinator.refreshCount() == 0)
    }

    @Test("a row without a code is rejected before anything is saved")
    func rowWithoutCodeIsRejected() async {
        let watchlistStore = RecordingWatchlistStore()
        let coordinator = SettingsRecordingCoordinator()
        let model = RadarViewModel(
            coordinator: coordinator,
            initialState: RadarState(),
            watchlistStore: watchlistStore
        )

        let saved = await model.replaceWatchlist(text: "600519\n贵州茅台")

        #expect(!saved)
        #expect(model.watchlistErrorMessage == "第2行没有六位证券代码")
        #expect(await watchlistStore.saveCount() == 0)
        #expect(await coordinator.refreshCount() == 0)
    }

    @Test("replacement errors follow the selected language")
    func replacementErrorsFollowLanguage() async {
        let model = RadarViewModel(
            coordinator: SettingsRecordingCoordinator(),
            initialState: RadarState(),
            watchlistStore: RecordingWatchlistStore()
        )

        let saved = await L10n.$scopedEnglish.withValue(true) {
            await model.replaceWatchlist(text: "110000")
        }

        #expect(!saved)
        #expect(model.watchlistErrorMessage == "Line 1 is not a supported Shanghai or Shenzhen A-share or ETF")
    }

    @Test("editing text comes from the saved list with names from the latest quotes")
    func editingTextUsesSavedListAndQuotedNames() async {
        let watchlistStore = RecordingWatchlistStore(value: [
            Instrument(symbol: "600519", name: "600519", exchange: .shanghai, kind: .stock),
            Instrument(symbol: "159915", name: "159915", exchange: .shenzhen, kind: .etf)
        ])
        let model = RadarViewModel(
            coordinator: SettingsRecordingCoordinator(),
            initialState: RadarState(watchlist: [
                Instrument(symbol: "600519", name: "贵州茅台", exchange: .shanghai, kind: .stock)
            ]),
            watchlistStore: watchlistStore
        )

        #expect(await model.watchlistEditingText() == "600519 贵州茅台\n159915 159915")
    }

    @Test("editing text before the first refresh still shows the saved list")
    func editingTextBeforeFirstRefreshShowsSavedList() async {
        let watchlistStore = RecordingWatchlistStore(value: [
            Instrument(symbol: "600519", name: "贵州茅台", exchange: .shanghai, kind: .stock)
        ])
        let model = RadarViewModel(
            coordinator: SettingsRecordingCoordinator(),
            initialState: RadarState(),
            watchlistStore: watchlistStore
        )

        #expect(await model.watchlistEditingText() == "600519 贵州茅台")
    }

    @Test("choosing a language saves it and reconfigures the coordinator")
    func choosingLanguageSavesIt() async {
        let settingsStore = RecordingSettingsStore()
        let coordinator = SettingsRecordingCoordinator()
        let model = RadarViewModel(
            coordinator: coordinator,
            initialState: RadarState(),
            settingsStore: settingsStore
        )

        // Chinese is the language the test runner already uses, so the app-wide switch is a no-op.
        await model.setLanguage(.simplifiedChinese)

        let expected = RadarSettings(language: .simplifiedChinese)
        #expect(model.settings == expected)
        #expect(await settingsStore.savedValues() == [expected])
        #expect(await coordinator.appliedSettings() == [expected])
        #expect(L10n.t("中", "en") == "中")
    }

    @Test("persisted settings reconfigure the existing coordinator before the UI changes")
    func persistedSettingsReconfigureTheExistingCoordinator() async {
        let settingsStore = RecordingSettingsStore()
        let coordinator = SettingsRecordingCoordinator()
        let model = RadarViewModel(
            coordinator: coordinator,
            initialState: RadarState(),
            settings: RadarSettings(),
            settingsStore: settingsStore
        )

        await model.setTimeframe(.oneMinute, enabled: false)

        #expect(model.settings.enabledTimeframes == [.fiveMinutes])
        #expect(await settingsStore.savedValues() == [RadarSettings(enabledTimeframes: [.fiveMinutes])])
        #expect(await coordinator.appliedSettings() == [RadarSettings(enabledTimeframes: [.fiveMinutes])])
    }

    @Test("failing settings persistence leaves the UI and coordinator unchanged")
    func failingSettingsPersistenceLeavesUIAndCoordinatorUnchanged() async {
        let settingsStore = RecordingSettingsStore(failure: .malformedDocument)
        let coordinator = SettingsRecordingCoordinator()
        let model = RadarViewModel(
            coordinator: coordinator,
            initialState: RadarState(),
            settings: RadarSettings(),
            settingsStore: settingsStore
        )

        await model.setNotificationAtEight(false)

        #expect(model.settings.notifyAtEight)
        #expect(model.settingsErrorMessage == "设置保存失败")
        #expect(await coordinator.appliedSettings().isEmpty)
    }

    @Test("a committed setting remains consistent across storage, UI, and runtime when its refresh fails")
    func committedSettingRemainsConsistentWhenRefreshFails() async {
        let settingsStore = RecordingSettingsStore()
        let coordinator = SettingsRecordingCoordinator(refreshFailure: true)
        let model = RadarViewModel(
            coordinator: coordinator,
            initialState: RadarState(),
            settings: RadarSettings(),
            settingsStore: settingsStore
        )

        await model.setNotificationAtEight(false)

        let expected = RadarSettings(notifyAtEight: false)
        #expect(model.settings == expected)
        #expect(await settingsStore.savedValues() == [expected])
        #expect(await coordinator.appliedSettings() == [expected])
        #expect(model.refreshErrorMessage == "数据源不可用")
        #expect(model.settingsErrorMessage == nil)
    }

    @Test("cleanup uses the coordinator result and refreshes state after a cutoff exists")
    func cleanupUsesCoordinatorAndRefreshesState() async {
        let coordinator = SettingsRecordingCoordinator(pruneResult: true)
        let model = RadarViewModel(
            coordinator: coordinator,
            initialState: RadarState(),
            settings: RadarSettings()
        )

        await model.clearExpiredHistory()

        #expect(await coordinator.pruneRequests() == [30])
        #expect(await coordinator.currentStateRequests() == 1)
    }

    @Test("diagnostic copy uses safe injected metadata and excludes unavailable source details")
    func diagnosticCopyContainsOnlySafeSummaryFields() async {
        let model = RadarViewModel(
            coordinator: SettingsRecordingCoordinator(),
            initialState: RadarState(
                health: .unavailable("https://unsafe.example/?cookie=secret"),
                watchlist: [Instrument(
                    symbol: "600519",
                    name: "样例股票",
                    exchange: .shanghai,
                    kind: .stock
                )]
            ),
            settings: RadarSettings(enabledTimeframes: [.fiveMinutes]),
            diagnosticReader: RecordingDiagnosticsReader(categories: [.network, .storage]),
            appVersion: "9.1.0",
            macOSVersion: "macOS-test"
        )

        let copy = await model.diagnosticCopy()

        #expect(copy.contains("版本：9.1.0"))
        #expect(copy.contains("macOS：macOS-test"))
        #expect(copy.contains("数据源：数据源不可用"))
        #expect(copy.contains("最近成功数据：无"))
        #expect(copy.contains("自选股：1"))
        #expect(copy.contains("监控周期：5分钟"))
        #expect(copy.contains("最近错误：网络异常、本地存储异常"))
        #expect(!copy.contains("https://"))
        #expect(!copy.contains("secret"))
    }

    @Test("settings mutations run in FIFO order and retain both successful toggles")
    func settingsMutationsRetainBothSuccessfulToggles() async {
        let settingsStore = SuspendingSettingsStore()
        let coordinator = SettingsRecordingCoordinator()
        let model = RadarViewModel(
            coordinator: coordinator,
            initialState: RadarState(),
            settings: RadarSettings(),
            settingsStore: settingsStore
        )

        let first = Task { await model.setNotificationAtEight(false) }
        await settingsStore.waitUntilFirstSave()
        let second = Task { await model.setSoundAtNine(false) }
        for _ in 0..<10 { await Task.yield() }

        #expect(await settingsStore.saveCount() == 1)
        await settingsStore.resumeFirstSave()
        await first.value
        await second.value

        let expected = RadarSettings(notifyAtEight: false, soundAtNine: false)
        #expect(model.settings == expected)
        #expect(await settingsStore.latest() == expected)
        #expect(await coordinator.appliedSettings().last == expected)
    }

    @Test("watchlist replacement and settings changes share one FIFO configuration queue")
    func watchlistReplacementAndSettingsChangesAreSerialized() async {
        let settingsStore = RecordingSettingsStore()
        let watchlistStore = SuspendingWatchlistStore()
        let coordinator = SettingsRecordingCoordinator()
        let model = RadarViewModel(
            coordinator: coordinator,
            initialState: RadarState(),
            settingsStore: settingsStore,
            watchlistStore: watchlistStore
        )

        let replacement = Task {
            await model.replaceWatchlist(text: "300750 宁德时代")
        }
        await watchlistStore.waitUntilFirstSave()
        let settingsChange = Task { await model.setNotificationAtEight(false) }
        for _ in 0..<10 { await Task.yield() }

        #expect(await settingsStore.savedValues().isEmpty)
        await watchlistStore.resumeFirstSave()
        #expect(await replacement.value)
        await settingsChange.value

        let expected = RadarSettings(notifyAtEight: false)
        #expect(model.settings == expected)
        #expect(await settingsStore.savedValues() == [expected])
        #expect(await coordinator.appliedSettings().last == expected)
        #expect(await watchlistStore.latest().map(\.id) == ["sz.300750"])
    }

    @Test("login control follows the actual disabled status and can enable a fresh saved preference")
    func loginControlUsesActualStatusAndCanEnableFreshPreference() async {
        let manager = ControlledLoginItemManager(status: .disabled)
        let settingsStore = RecordingSettingsStore()
        let model = RadarViewModel(
            coordinator: SettingsRecordingCoordinator(),
            initialState: RadarState(),
            settings: RadarSettings(startAtLogin: true),
            settingsStore: settingsStore,
            loginItemManager: manager
        )

        await model.prepareSettings()
        #expect(model.loginLaunchToggleIsOn == false)

        await model.setStartAtLogin(true)

        #expect(model.loginLaunchToggleIsOn)
        #expect(model.settings.startAtLogin)
        #expect(await manager.requests() == [true])
        #expect(await settingsStore.savedValues() == [RadarSettings(startAtLogin: true)])
    }

    @Test("login control treats system approval as enabled")
    func loginControlTreatsApprovalAsEnabled() async {
        let manager = ControlledLoginItemManager(status: .requiresApproval)
        let model = RadarViewModel(
            coordinator: SettingsRecordingCoordinator(),
            initialState: RadarState(),
            settings: RadarSettings(startAtLogin: false),
            loginItemManager: manager
        )

        await model.prepareSettings()

        #expect(model.loginLaunchToggleIsOn)
        #expect(model.loginItemStatus == .requiresApproval)
        #expect(model.settings.startAtLogin == false)
    }

    @Test("failed login registration and removal retain the prior preference and actual display")
    func failedLoginItemChangesRetainPriorPreferenceAndActualDisplay() async {
        let registration = ControlledLoginItemManager(status: .disabled, failingValues: [true])
        let registrationModel = RadarViewModel(
            coordinator: SettingsRecordingCoordinator(),
            initialState: RadarState(),
            settings: RadarSettings(startAtLogin: false),
            settingsStore: RecordingSettingsStore(),
            loginItemManager: registration
        )

        await registrationModel.setStartAtLogin(true)

        #expect(registrationModel.settings.startAtLogin == false)
        #expect(registrationModel.loginLaunchToggleIsOn == false)
        #expect(await registration.status() == .disabled)

        let removal = ControlledLoginItemManager(status: .enabled, failingValues: [false])
        let removalModel = RadarViewModel(
            coordinator: SettingsRecordingCoordinator(),
            initialState: RadarState(),
            settings: RadarSettings(startAtLogin: true),
            settingsStore: RecordingSettingsStore(),
            loginItemManager: removal
        )

        await removalModel.setStartAtLogin(false)

        #expect(removalModel.settings.startAtLogin)
        #expect(removalModel.loginLaunchToggleIsOn)
        #expect(await removal.status() == .enabled)
    }

    @Test("a login preference save failure restores the actual system login state")
    func loginPreferenceSaveFailureRestoresActualSystemState() async {
        let manager = ControlledLoginItemManager(status: .disabled)
        let model = RadarViewModel(
            coordinator: SettingsRecordingCoordinator(),
            initialState: RadarState(),
            settings: RadarSettings(startAtLogin: false),
            settingsStore: RecordingSettingsStore(failure: .malformedDocument),
            loginItemManager: manager
        )

        await model.setStartAtLogin(true)

        #expect(model.settings.startAtLogin == false)
        #expect(model.loginLaunchToggleIsOn == false)
        #expect(await manager.status() == .disabled)
        #expect(await manager.requests() == [true, false])
    }

    @Test("last healthy time remains in diagnostics after stale and unavailable refreshes")
    func lastHealthyTimeRemainsAfterDataHealthDegrades() async {
        let healthyAt = radarDate("10:10")
        let coordinator = StateSwitchingCoordinator(state: radarState(health: .healthy(healthyAt)))
        let model = RadarViewModel(
            coordinator: coordinator,
            initialState: radarState(health: .healthy(healthyAt)),
            settings: RadarSettings()
        )

        #expect(model.lastHealthyAt == healthyAt)
        await coordinator.setState(radarState(health: .stale))
        await model.refresh()
        #expect(model.lastHealthyAt == healthyAt)
        #expect((await model.diagnosticCopy()).contains("最近成功数据：2026-09-01 10:10:00"))

        await coordinator.setState(radarState(health: .unavailable("source down")))
        await model.refresh()
        #expect(model.lastHealthyAt == healthyAt)
        #expect((await model.diagnosticCopy()).contains("最近成功数据：2026-09-01 10:10:00"))
    }

    @Test("a healthy state stream update records the last healthy time")
    func healthyStateStreamUpdateRecordsLastHealthyTime() async {
        let healthyAt = radarDate("10:10")
        let coordinator = StateSwitchingCoordinator(state: radarState(health: .idle))
        let model = RadarViewModel(
            coordinator: coordinator,
            initialState: radarState(health: .idle),
            settings: RadarSettings()
        )

        await model.start()
        await coordinator.emit(radarState(health: .healthy(healthyAt)))
        for _ in 0..<20 where model.lastHealthyAt != healthyAt {
            await Task.yield()
        }

        #expect(model.lastHealthyAt == healthyAt)
        await model.stop()
    }
}

actor RecordingSettingsStore: RadarSettingsStoring {
    private let failure: SettingsError?
    private var values: [RadarSettings] = []

    init(failure: SettingsError? = nil) {
        self.failure = failure
    }

    func load() async throws -> RadarSettings {
        RadarSettings()
    }

    func save(_ value: RadarSettings) async throws {
        if let failure { throw failure }
        values.append(value)
    }

    func savedValues() -> [RadarSettings] {
        values
    }
}

actor RecordingWatchlistStore: WatchlistStoring {
    private var value: [Instrument]
    private var saves = 0

    init(value: [Instrument] = []) {
        self.value = value
    }

    func load() async throws -> [Instrument] {
        value
    }

    func save(_ instruments: [Instrument]) async throws {
        saves += 1
        value = instruments
    }

    func latest() -> [Instrument] { value }

    func saveCount() -> Int { saves }
}

actor FailingWatchlistStore: WatchlistStoring {
    private let value: [Instrument]

    init(value: [Instrument]) {
        self.value = value
    }

    func load() async throws -> [Instrument] { value }

    func save(_ instruments: [Instrument]) async throws {
        throw ViewModelTestError.watchlistSaveFailed
    }

    func latest() -> [Instrument] { value }
}

actor SuspendingSettingsStore: RadarSettingsStoring {
    private var values: [RadarSettings] = []
    private var saves = 0
    private var firstSaveIsSuspended = true
    private var waiter: CheckedContinuation<Void, Never>?

    func load() async throws -> RadarSettings { RadarSettings() }

    func save(_ value: RadarSettings) async throws {
        saves += 1
        if firstSaveIsSuspended {
            firstSaveIsSuspended = false
            await withCheckedContinuation { continuation in
                waiter = continuation
            }
        }
        values.append(value)
    }

    func waitUntilFirstSave() async {
        while waiter == nil {
            await Task.yield()
        }
    }

    func resumeFirstSave() {
        waiter?.resume()
        waiter = nil
    }

    func saveCount() -> Int { saves }

    func latest() -> RadarSettings? { values.last }
}

actor SuspendingWatchlistStore: WatchlistStoring {
    private var value: [Instrument] = []
    private var firstSaveIsSuspended = true
    private var waiter: CheckedContinuation<Void, Never>?

    func load() async throws -> [Instrument] { value }

    func save(_ instruments: [Instrument]) async throws {
        if firstSaveIsSuspended {
            firstSaveIsSuspended = false
            await withCheckedContinuation { continuation in
                waiter = continuation
            }
        }
        value = instruments
    }

    func waitUntilFirstSave() async {
        while waiter == nil {
            await Task.yield()
        }
    }

    func resumeFirstSave() {
        waiter?.resume()
        waiter = nil
    }

    func latest() -> [Instrument] { value }
}

actor ControlledLoginItemManager: LoginItemManaging {
    private var currentStatus: LoginItemStatus
    private let failingValues: Set<Bool>
    private var values: [Bool] = []

    init(status: LoginItemStatus, failingValues: Set<Bool> = []) {
        self.currentStatus = status
        self.failingValues = failingValues
    }

    func status() -> LoginItemStatus {
        currentStatus
    }

    func setEnabled(_ enabled: Bool) throws {
        values.append(enabled)
        guard !failingValues.contains(enabled) else {
            throw LoginItemError.unavailable
        }
        currentStatus = enabled ? .enabled : .disabled
    }

    func requests() -> [Bool] { values }
}

actor StateSwitchingCoordinator: RadarCoordinating {
    private var state: RadarState
    private var stateContinuations: [AsyncStream<RadarState>.Continuation] = []

    init(state: RadarState) {
        self.state = state
    }

    func start() {}
    func stop() {}
    func refreshNow() throws {}
    func states() -> AsyncStream<RadarState> {
        AsyncStream { continuation in
            stateContinuations.append(continuation)
            continuation.yield(state)
        }
    }
    func currentState() -> RadarState { state }
    func recentBars(instrumentID: String, timeframe: Timeframe, limit: Int) -> [Bar] { [] }

    func setState(_ state: RadarState) {
        self.state = state
    }

    func emit(_ state: RadarState) {
        self.state = state
        for continuation in stateContinuations {
            continuation.yield(state)
        }
    }
}

actor RecordingDiagnosticsReader: DiagnosticReading {
    private let categories: [DiagnosticErrorCategory]

    init(categories: [DiagnosticErrorCategory]) {
        self.categories = categories
    }

    func recentErrorCategories() -> [DiagnosticErrorCategory] {
        categories
    }
}

actor SettingsRecordingCoordinator: RadarCoordinating {
    private let pruneResult: Bool
    private let refreshFailure: Bool
    private var values: [RadarSettings] = []
    private var refreshes = 0
    private var pruneValues: [Int] = []
    private var currentStateCount = 0

    init(pruneResult: Bool = false, refreshFailure: Bool = false) {
        self.pruneResult = pruneResult
        self.refreshFailure = refreshFailure
    }

    func start() {}
    func stop() {}
    func refreshNow() throws {
        refreshes += 1
        if refreshFailure { throw ViewModelTestError.refreshFailed }
    }
    func states() -> AsyncStream<RadarState> { AsyncStream { $0.finish() } }
    func currentState() -> RadarState { currentStateCount += 1; return RadarState() }
    func recentBars(instrumentID: String, timeframe: Timeframe, limit: Int) -> [Bar] { [] }
    func updateSettings(_ settings: RadarSettings) { values.append(settings) }
    func pruneHistory(keeping tradingDays: Int) throws -> Bool { pruneValues.append(tradingDays); return pruneResult }
    func appliedSettings() -> [RadarSettings] { values }
    func refreshCount() -> Int { refreshes }
    func pruneRequests() -> [Int] { pruneValues }
    func currentStateRequests() -> Int { currentStateCount }
}

private enum ViewModelTestError: Error {
    case refreshFailed
    case watchlistSaveFailed
}
