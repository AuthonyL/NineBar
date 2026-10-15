import SwiftUI
import NineBarCore

public struct SignalHistoryPresentation: Equatable, Sendable {
    public let identityText: String
    public let contextText: String
    public let confirmationText: String
    public let referencePriceText: String

    public init(
        identityText: String,
        contextText: String,
        confirmationText: String,
        referencePriceText: String
    ) {
        self.identityText = identityText
        self.contextText = contextText
        self.confirmationText = confirmationText
        self.referencePriceText = referencePriceText
    }
}

public struct WatchlistPresentation: Equatable, Identifiable, Sendable {
    public let id: String
    public let identityText: String
    public let statusText: String
    public let isMonitoring: Bool

    public init(id: String, identityText: String, statusText: String, isMonitoring: Bool = false) {
        self.id = id
        self.identityText = identityText
        self.statusText = statusText
        self.isMonitoring = isMonitoring
    }
}

public struct SignalRowPresentation: Equatable, Sendable {
    public let nameText: String
    public let symbolText: String
    public let positionText: String
    public let currentPriceText: String
    public let referencePriceText: String
    public let confirmationMarkText: String?

    public init(
        nameText: String,
        symbolText: String,
        positionText: String,
        currentPriceText: String,
        referencePriceText: String,
        confirmationMarkText: String?
    ) {
        self.nameText = nameText
        self.symbolText = symbolText
        self.positionText = positionText
        self.currentPriceText = currentPriceText
        self.referencePriceText = referencePriceText
        self.confirmationMarkText = confirmationMarkText
    }
}

@MainActor
public final class RadarViewModel: ObservableObject {
    @Published public private(set) var state: RadarState
    @Published public var directionFilter: SignalDirection?
    @Published public var timeframeFilter: Timeframe?
    @Published public private(set) var detailSequence: SequenceSnapshot?
    @Published public private(set) var detailBars: [Bar] = []
    @Published public private(set) var isDetailLoading = false
    @Published public private(set) var detailErrorMessage: String?
    @Published public private(set) var refreshErrorMessage: String?
    @Published public private(set) var settings: RadarSettings
    @Published public private(set) var settingsErrorMessage: String?
    @Published public private(set) var watchlistErrorMessage: String?
    @Published public private(set) var loginItemStatus: LoginItemStatus = .unavailable
    @Published public private(set) var notificationAuthorizationStatus: NotificationAuthorizationStatus = .unknown
    @Published public private(set) var storageUsageBytes: Int64 = 0
    @Published public private(set) var lastHealthyAt: Date?

    private let coordinator: any RadarCoordinating
    private let settingsStore: (any RadarSettingsStoring)?
    private let watchlistStore: (any WatchlistStoring)?
    private let loginItemManager: (any LoginItemManaging)?
    private let loginItemsSettingsOpener: (any LoginItemsSettingsOpening)?
    private let notificationService: (any NotificationSending & NotificationAuthorizationStatusProviding)?
    private let diagnosticReader: (any DiagnosticReading)?
    private let maintenance: (any StorageMaintaining)?
    private let appVersion: String
    private let macOSVersion: String
    private var stateTask: Task<Void, Never>?
    private var isStarting = false
    private var lifecycleID = UUID()
    private var configurationMutationTail: Task<Void, Never>?
    private var configurationMutationRevision = 0
    private var lastSavedWatchlistIDs: [String]?

    public init(
        coordinator: any RadarCoordinating,
        initialState: RadarState,
        settings: RadarSettings = RadarSettings(),
        settingsStore: (any RadarSettingsStoring)? = nil,
        watchlistStore: (any WatchlistStoring)? = nil,
        loginItemManager: (any LoginItemManaging)? = nil,
        loginItemsSettingsOpener: (any LoginItemsSettingsOpening)? = nil,
        notificationService: (any NotificationSending & NotificationAuthorizationStatusProviding)? = nil,
        diagnosticReader: (any DiagnosticReading)? = nil,
        maintenance: (any StorageMaintaining)? = nil,
        appVersion: String = "1.0",
        macOSVersion: String = ProcessInfo.processInfo.operatingSystemVersionString
    ) {
        self.coordinator = coordinator
        self.state = initialState
        self.settings = settings
        if case .healthy(let date) = initialState.health {
            self.lastHealthyAt = date
        } else {
            self.lastHealthyAt = nil
        }
        self.settingsStore = settingsStore
        self.watchlistStore = watchlistStore
        self.loginItemManager = loginItemManager
        self.loginItemsSettingsOpener = loginItemsSettingsOpener
        self.notificationService = notificationService
        self.diagnosticReader = diagnosticReader
        self.maintenance = maintenance
        self.appVersion = appVersion
        self.macOSVersion = macOSVersion
    }

    deinit {
        stateTask?.cancel()
        let coordinator = coordinator
        Task {
            await coordinator.stop()
        }
    }

    public var visibleSequences: [SequenceSnapshot] {
        state.sequences
            .filter { (6...9).contains($0.count) }
            .filter { directionFilter == nil || $0.direction == directionFilter }
            .filter { timeframeFilter == nil || $0.timeframe == timeframeFilter }
            .sorted(by: SequencePresentation.priority)
    }

    public var watchlistPresentations: [WatchlistPresentation] {
        let failedIDs = Set(state.failures.map(\.instrumentID))
        return state.watchlist.sorted { $0.id < $1.id }.map { instrument in
            let statusText: String
            var isMonitoring = false
            if failedIDs.contains(instrument.id) {
                statusText = L10n.t("分钟行情不可用", "Minute data unavailable")
            } else {
                switch state.health {
                case .healthy:
                    statusText = L10n.t("监控中", "Monitoring")
                    isMonitoring = true
                case .closed: statusText = L10n.t("休市中", "Market closed")
                case .stale: statusText = L10n.t("数据暂停", "Data paused")
                case .idle, .unavailable: statusText = L10n.t("等待数据", "Waiting for data")
                }
            }
            return WatchlistPresentation(
                id: instrument.id,
                identityText: "\(instrument.name) \(instrument.symbol)",
                statusText: statusText,
                isMonitoring: isMonitoring
            )
        }
    }

    public var otherWatchlistPresentations: [WatchlistPresentation] {
        let visibleIDs = Set(visibleSequences.map(\.instrumentID))
        return watchlistPresentations.filter { !visibleIDs.contains($0.id) }
    }

    /// Reads the saved list rather than the last published state, so opening the editor before
    /// the first refresh finishes cannot save an empty list over the user's watchlist.
    public func watchlistEditingText() async -> String {
        let saved: [Instrument]
        if let watchlistStore, let stored = try? await watchlistStore.load() {
            saved = stored
        } else {
            saved = state.watchlist
        }
        let quotedNames = Dictionary(
            state.watchlist.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        return saved
            .sorted { $0.id < $1.id }
            .map { "\($0.symbol) \(quotedNames[$0.id] ?? $0.name)" }
            .joined(separator: "\n")
    }

    public var statusText: String {
        guard !isPaused else { return L10n.t("暂停", "Paused") }
        guard let sequence = visibleSequences.first else { return "" }
        return "\(SignalPricePresentation.directionMark(sequence.direction))\(sequence.count)"
    }

    public var statusSymbol: String {
        guard !isPaused else { return "exclamationmark.triangle" }
        guard let sequence = visibleSequences.first else { return "9.circle" }
        return sequence.direction == .top ? "arrow.up.circle" : "arrow.down.circle"
    }

    public var showsMenuBarAttentionDot: Bool {
        guard case .healthy = state.health else { return false }
        return state.sequences.contains { (8...9).contains($0.count) }
    }

    public var isPaused: Bool {
        switch state.health {
        case .stale, .unavailable:
            true
        case .idle, .closed, .healthy:
            false
        }
    }

    /// The stored preference records the most recently successful requested state.
    /// The control renders the current system state so a fresh saved preference can still enable it.
    public var loginLaunchToggleIsOn: Bool {
        switch loginItemStatus {
        case .enabled, .requiresApproval:
            true
        case .disabled, .unavailable:
            false
        }
    }

    public func start() async {
        guard stateTask == nil, !isStarting else { return }
        isStarting = true
        let startID = UUID()
        lifecycleID = startID
        defer { isStarting = false }

        await coordinator.start()
        guard lifecycleID == startID, stateTask == nil else { return }
        let stream = await coordinator.states()
        guard lifecycleID == startID, stateTask == nil else { return }
        stateTask = Task { [weak self] in
            for await next in stream {
                guard !Task.isCancelled else { break }
                self?.applyState(next)
            }
        }
    }

    public func stop() async {
        lifecycleID = UUID()
        isStarting = false
        let task = stateTask
        stateTask = nil
        task?.cancel()
        await task?.value
        await coordinator.stop()
    }

    public func refresh() async {
        refreshErrorMessage = nil
        do {
            try await coordinator.refreshNow()
            applyState(await coordinator.currentState())
        } catch is CancellationError {
            return
        } catch {
            var unavailableState = state
            unavailableState.health = .unavailable(Self.unavailableMessage)
            applyState(unavailableState)
            refreshErrorMessage = Self.unavailableMessage
        }
    }

    public func select(sequence: SequenceSnapshot) async {
        detailSequence = sequence
        detailBars = []
        detailErrorMessage = nil
        isDetailLoading = true
        defer { isDetailLoading = false }

        do {
            detailBars = try await coordinator.recentBars(
                instrumentID: sequence.instrumentID,
                timeframe: sequence.timeframe,
                limit: 60
            )
        } catch {
            detailErrorMessage = Self.unavailableMessage
        }
    }

    public func dismissDetail() {
        detailSequence = nil
        detailBars = []
        detailErrorMessage = nil
    }

    public func prepareSettings() async {
        await refreshLoginItemStatus()
        await refreshNotificationAuthorization()
        await refreshStorageUsage()
    }

    public func setTimeframe(_ timeframe: Timeframe, enabled: Bool) async {
        await enqueueSettingsMutation { model in
            var next = model.settings
            if enabled {
                next.enabledTimeframes.insert(timeframe)
            } else {
                next.enabledTimeframes.remove(timeframe)
            }
            guard !next.enabledTimeframes.isEmpty else {
                model.settingsErrorMessage = L10n.t("至少保留一个监控周期", "Keep at least one timeframe")
                return
            }
            await model.commitSettings(next)
        }
    }

    public func setNotificationAtEight(_ enabled: Bool) async {
        await enqueueSettingsMutation { model in
            var next = model.settings
            next.notifyAtEight = enabled
            await model.commitSettings(next)
        }
    }

    public func setNotificationAtNine(_ enabled: Bool) async {
        await enqueueSettingsMutation { model in
            var next = model.settings
            next.notifyAtNine = enabled
            await model.commitSettings(next)
        }
    }

    public func setSoundAtNine(_ enabled: Bool) async {
        await enqueueSettingsMutation { model in
            var next = model.settings
            next.soundAtNine = enabled
            await model.commitSettings(next)
        }
    }

    public func setLanguage(_ language: AppLanguage) async {
        await enqueueSettingsMutation { model in
            var next = model.settings
            next.language = language
            await model.commitSettings(next)
        }
    }

    public func setStartAtLogin(_ enabled: Bool) async {
        await enqueueSettingsMutation { model in
            await model.commitLoginItemPreference(enabled)
        }
    }

    public func refreshLoginItemStatus() async {
        await enqueueSettingsMutation { model in
            guard let loginItemManager = model.loginItemManager else { return }
            model.loginItemStatus = await loginItemManager.status()
        }
    }

    public func openLoginItemsSettings() async {
        guard let loginItemsSettingsOpener else {
            settingsErrorMessage = L10n.t("无法打开登录项设置", "Could not open Login Items settings")
            return
        }
        guard await loginItemsSettingsOpener.openLoginItemsSettings() else {
            settingsErrorMessage = L10n.t("无法打开登录项设置", "Could not open Login Items settings")
            return
        }
    }

    public func requestNotificationAuthorization() async {
        guard let notificationService else {
            settingsErrorMessage = L10n.t("系统通知权限不可用", "Notification permission unavailable")
            return
        }
        do {
            let granted = try await notificationService.requestAuthorization()
            notificationAuthorizationStatus = granted ? .granted : .denied
        } catch {
            settingsErrorMessage = L10n.t("系统通知权限不可用", "Notification permission unavailable")
        }
    }

    public func refreshNotificationAuthorization() async {
        guard let notificationService else { return }
        notificationAuthorizationStatus = await notificationService.authorizationStatus()
    }

    /// Replaces the whole watchlist with the pasted rows. An empty text clears the list.
    public func replaceWatchlist(text: String) async -> Bool {
        let instruments: [Instrument]
        do {
            instruments = try WatchlistTextParser.parse(text, knownInstruments: state.watchlist)
        } catch WatchlistTextParser.ParseError.missingCode(let line) {
            watchlistErrorMessage = L10n.t("第\(line)行没有六位证券代码", "Line \(line) has no six-digit code")
            return false
        } catch WatchlistTextParser.ParseError.unsupportedCode(let line) {
            watchlistErrorMessage = L10n.t(
                "第\(line)行不是支持的沪深A股或场内ETF",
                "Line \(line) is not a supported Shanghai or Shenzhen A-share or ETF"
            )
            return false
        } catch {
            watchlistErrorMessage = L10n.t("自选股内容无法识别", "Could not read the watchlist")
            return false
        }

        watchlistErrorMessage = nil
        await enqueueConfigurationMutation { model in
            await model.commitWatchlistReplacement(instruments)
        }
        let expectedIDs = instruments.map(\.id).sorted()
        return watchlistErrorMessage == nil && lastSavedWatchlistIDs == expectedIDs
    }

    public func clearExpiredHistory() async {
        settingsErrorMessage = nil
        do {
            let didPrune = try await coordinator.pruneHistory(keeping: 30)
            if didPrune {
                applyState(await coordinator.currentState())
            }
            await refreshStorageUsage()
        } catch {
            settingsErrorMessage = L10n.t("历史清理失败", "Could not clear history")
        }
    }

    public func refreshStorageUsage() async {
        guard let maintenance else { return }
        storageUsageBytes = await maintenance.storageUsageBytes()
    }

    public func diagnosticCopy() async -> String {
        let categories = await diagnosticReader?.recentErrorCategories() ?? []
        let dataHealth: String
        let lastDataTime: String
        let none = L10n.t("无", "None")
        switch state.health {
        case .idle:
            dataHealth = L10n.t("等待中", "Waiting")
            lastDataTime = none
        case .closed:
            dataHealth = L10n.t("休市", "Market closed")
            lastDataTime = lastHealthyAt.map(Self.diagnosticDateString) ?? none
        case .healthy(let date):
            dataHealth = L10n.t("正常", "OK")
            lastDataTime = Self.diagnosticDateString(date)
        case .stale:
            dataHealth = L10n.t("数据过期", "Stale")
            lastDataTime = lastHealthyAt.map(Self.diagnosticDateString) ?? none
        case .unavailable:
            dataHealth = L10n.t("数据源不可用", "Data source unavailable")
            lastDataTime = lastHealthyAt.map(Self.diagnosticDateString) ?? none
        }
        let separator = L10n.t("、", ", ")
        let periods = settings.enabledTimeframes
            .sorted { $0.rawValue < $1.rawValue }
            .map { L10n.t("\($0.rawValue)分钟", "\($0.rawValue) min") }
            .joined(separator: separator)
        let errors = categories.map(\.displayText).joined(separator: separator)
        return [
            L10n.t("版本：", "Version: ") + appVersion,
            L10n.t("macOS：", "macOS: ") + macOSVersion,
            L10n.t("数据源：", "Data source: ") + dataHealth,
            L10n.t("最近成功数据：", "Last good data: ") + lastDataTime,
            L10n.t("自选股：", "Watchlist: ") + "\(state.watchlist.count)",
            L10n.t("监控周期：", "Timeframes: ") + (periods.isEmpty ? none : periods),
            L10n.t("最近错误：", "Recent errors: ") + (errors.isEmpty ? none : errors)
        ].joined(separator: "\n")
    }

    public func instrument(for sequence: SequenceSnapshot) -> Instrument {
        if let instrument = state.watchlist.first(where: { $0.id == sequence.instrumentID }) {
            return instrument
        }

        let parts = sequence.instrumentID.split(separator: ".", maxSplits: 1).map(String.init)
        let exchange: Exchange = parts.first == Exchange.shenzhen.rawValue ? .shenzhen : .shanghai
        let symbol = parts.count == 2 ? parts[1] : sequence.instrumentID
        return Instrument(
            symbol: symbol,
            name: L10n.t("未知证券 \(symbol)", "Unknown \(symbol)"),
            exchange: exchange,
            kind: .stock
        )
    }

    public func signalRowPresentation(for sequence: SequenceSnapshot) -> SignalRowPresentation {
        let instrument = instrument(for: sequence)
        let direction = SignalPricePresentation.directionMark(sequence.direction)
        let currentPrice = SignalPricePresentation.valueText(sequence.lastClose, kind: instrument.kind)
        let referencePrice = SignalPricePresentation.valueText(sequence.extremePrice, kind: instrument.kind)
        return SignalRowPresentation(
            nameText: instrument.name,
            symbolText: instrument.symbol,
            positionText: "\(direction)\(sequence.count)·"
                + L10n.t("\(sequence.timeframe.rawValue)分", "\(sequence.timeframe.rawValue)m"),
            currentPriceText: L10n.t("现", "Px ") + currentPrice,
            referencePriceText: L10n.t("九", "9: ") + referencePrice,
            confirmationMarkText: sequence.phase == .confirmed ? "✓" : nil
        )
    }

    public func history(for sequence: SequenceSnapshot) -> [ConfirmedSignal] {
        state.history.filter {
            $0.instrumentID == sequence.instrumentID
                && $0.timeframe == sequence.timeframe
                && $0.direction == sequence.direction
        }
    }

    public func historyPresentation(for signal: ConfirmedSignal) -> SignalHistoryPresentation {
        let parts = signal.instrumentID.split(separator: ".", maxSplits: 1).map(String.init)
        let symbol = parts.count == 2 ? parts[1] : signal.instrumentID
        let identity: String
        let instrument = state.watchlist.first(where: { $0.id == signal.instrumentID })
        if let instrument {
            identity = "\(instrument.name) \(instrument.symbol)"
        } else {
            identity = L10n.t("未知证券 \(symbol)", "Unknown \(symbol)")
        }
        return SignalHistoryPresentation(
            identityText: identity,
            contextText: SignalPricePresentation.directionWord(signal.direction)
                + " · "
                + L10n.t("\(signal.timeframe.rawValue)分钟", "\(signal.timeframe.rawValue) min"),
            confirmationText: Self.historyDateFormatter.string(from: signal.lastBarEnd),
            referencePriceText: SignalPricePresentation.text(
                direction: signal.direction,
                value: signal.extremePrice,
                kind: instrument?.kind ?? .stock
            )
        )
    }

    public func referencePriceText(for sequence: SequenceSnapshot) -> String {
        SignalPricePresentation.text(
            direction: sequence.direction,
            value: sequence.extremePrice,
            kind: instrument(for: sequence).kind
        )
    }

    public static func preview(state: RadarState) -> RadarViewModel {
        RadarViewModel(
            coordinator: PreviewRadarCoordinator(state: state),
            initialState: state
        )
    }

    private static var unavailableMessage: String {
        L10n.t("数据源不可用", "Data source unavailable")
    }

    private func commitSettings(_ next: RadarSettings) async {
        guard next != settings else { return }
        settingsErrorMessage = nil
        if let settingsStore {
            do {
                try await settingsStore.save(next)
            } catch is CancellationError {
                return
            } catch {
                settingsErrorMessage = L10n.t("设置保存失败", "Could not save settings")
                return
            }
        }
        await coordinator.updateSettings(next)
        if next.language != settings.language {
            L10n.apply(next.language)
        }
        settings = next
        await refreshAfterCommittedConfiguration()
    }

    private func commitLoginItemPreference(_ enabled: Bool) async {
        guard let loginItemManager else {
            settingsErrorMessage = L10n.t("登录启动不可用", "Launch at login unavailable")
            return
        }

        let previousStatus = await loginItemManager.status()
        let restoreEnabled = Self.loginItemStatusIsOn(previousStatus)
        loginItemStatus = previousStatus
        do {
            try await loginItemManager.setEnabled(enabled)
        } catch is CancellationError {
            loginItemStatus = await loginItemManager.status()
            return
        } catch {
            loginItemStatus = await loginItemManager.status()
            settingsErrorMessage = L10n.t("登录启动设置失败", "Could not change launch at login")
            return
        }

        let actualStatus = await loginItemManager.status()
        guard Self.loginItemStatusMatches(actualStatus, requested: enabled) else {
            loginItemStatus = actualStatus
            settingsErrorMessage = L10n.t("登录启动设置失败", "Could not change launch at login")
            return
        }

        var next = settings
        next.startAtLogin = enabled
        if let settingsStore {
            do {
                try await settingsStore.save(next)
            } catch is CancellationError {
                await restoreLoginItemState(
                    loginItemManager,
                    enabled: restoreEnabled
                )
                return
            } catch {
                await restoreLoginItemState(
                    loginItemManager,
                    enabled: restoreEnabled
                )
                settingsErrorMessage = L10n.t("设置保存失败", "Could not save settings")
                return
            }
        }

        await coordinator.updateSettings(next)
        settings = next
        loginItemStatus = actualStatus
        settingsErrorMessage = nil
        await refreshAfterCommittedConfiguration()
    }

    private func commitWatchlistReplacement(_ instruments: [Instrument]) async {
        let saveFailed = L10n.t("自选股列表保存失败", "Could not save the watchlist")
        guard let watchlistStore else {
            watchlistErrorMessage = saveFailed
            return
        }
        let replacement = Dictionary(
            instruments.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted { $0.id < $1.id }
        do {
            try await watchlistStore.save(replacement)
        } catch is CancellationError {
            return
        } catch {
            watchlistErrorMessage = saveFailed
            return
        }
        lastSavedWatchlistIDs = replacement.map(\.id)
        watchlistErrorMessage = nil
        await refreshAfterCommittedConfiguration(forceWatchlistReload: true)
    }

    private func refreshAfterCommittedConfiguration(forceWatchlistReload: Bool = false) async {
        refreshErrorMessage = nil
        do {
            if forceWatchlistReload {
                try await coordinator.refreshWatchlistNow()
            } else {
                try await coordinator.refreshNow()
            }
            applyState(await coordinator.currentState())
        } catch is CancellationError {
            return
        } catch {
            var unavailableState = state
            unavailableState.health = .unavailable(Self.unavailableMessage)
            applyState(unavailableState)
            refreshErrorMessage = Self.unavailableMessage
        }
    }

    private func restoreLoginItemState(
        _ loginItemManager: any LoginItemManaging,
        enabled: Bool
    ) async {
        do {
            try await loginItemManager.setEnabled(enabled)
        } catch {
            // The following status read keeps the displayed state tied to the OS.
        }
        loginItemStatus = await loginItemManager.status()
    }

    private func enqueueSettingsMutation(
        _ operation: @escaping @MainActor (RadarViewModel) async -> Void
    ) async {
        await enqueueConfigurationMutation(operation)
    }

    private func enqueueConfigurationMutation(
        _ operation: @escaping @MainActor (RadarViewModel) async -> Void
    ) async {
        configurationMutationRevision += 1
        let revision = configurationMutationRevision
        let preceding = configurationMutationTail
        let task = Task { @MainActor [weak self] in
            await preceding?.value
            guard let self else { return }
            await operation(self)
        }
        configurationMutationTail = task
        await task.value
        if configurationMutationRevision == revision {
            configurationMutationTail = nil
        }
    }

    private func applyState(_ next: RadarState) {
        state = next
        if case .healthy(let date) = next.health {
            lastHealthyAt = date
        }
    }

    private static func loginItemStatusIsOn(_ status: LoginItemStatus) -> Bool {
        switch status {
        case .enabled, .requiresApproval:
            true
        case .disabled, .unavailable:
            false
        }
    }

    private static func loginItemStatusMatches(_ status: LoginItemStatus, requested: Bool) -> Bool {
        loginItemStatusIsOn(status) == requested
    }

    private static func diagnosticDateString(_ value: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: value)
    }

    private static let historyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}

enum SignalPricePresentation {
    static func text(
        direction: SignalDirection,
        value: Double,
        kind: SecurityKind = .stock
    ) -> String {
        let label = direction == .top
            ? L10n.t("顶部参考价", "Top reference")
            : L10n.t("底部参考价", "Bottom reference")
        return "\(label) \(valueText(value, kind: kind))"
    }

    /// One-character direction used in compact rows, e.g. 顶9 / T9.
    static func directionMark(_ direction: SignalDirection) -> String {
        direction == .top ? L10n.t("顶", "T") : L10n.t("底", "B")
    }

    static func directionWord(_ direction: SignalDirection) -> String {
        direction == .top ? L10n.t("顶部", "Top") : L10n.t("底部", "Bottom")
    }

    static func valueText(_ value: Double, kind: SecurityKind) -> String {
        let format = kind == .etf ? "%.3f" : "%.2f"
        return String(format: format, locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

public enum SequencePresentation {
    public static func priority(_ left: SequenceSnapshot, _ right: SequenceSnapshot) -> Bool {
        let leftRank = phaseRank(for: left)
        let rightRank = phaseRank(for: right)
        if leftRank != rightRank {
            return leftRank < rightRank
        }
        if left.count != right.count {
            return left.count > right.count
        }
        if left.lastBarEnd != right.lastBarEnd {
            return left.lastBarEnd > right.lastBarEnd
        }
        return left.id < right.id
    }

    private static func phaseRank(for sequence: SequenceSnapshot) -> Int {
        if sequence.phase == .confirmed && sequence.count == 9 {
            return 0
        }
        if sequence.phase == .candidate {
            return 1
        }
        return 2
    }
}

private actor PreviewRadarCoordinator: RadarCoordinating {
    private let state: RadarState

    init(state: RadarState) {
        self.state = state
    }

    func start() {}

    func stop() {}

    func refreshNow() throws {}

    func states() -> AsyncStream<RadarState> {
        AsyncStream { continuation in
            continuation.yield(state)
            continuation.finish()
        }
    }

    func currentState() -> RadarState {
        state
    }

    func recentBars(instrumentID: String, timeframe: Timeframe, limit: Int) throws -> [Bar] {
        []
    }
}
