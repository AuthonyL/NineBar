import Foundation
import NineBarCore
import NineBarUI

@MainActor
public final class AppEnvironment {
    private let coordinator: any RadarCoordinating
    private let initialState: RadarState
    private let settings: RadarSettings
    private let settingsStore: (any RadarSettingsStoring)?
    private let watchlistStore: (any WatchlistStoring)?
    private let loginItemManager: (any LoginItemManaging)?
    private let loginItemsSettingsOpener: (any LoginItemsSettingsOpening)?
    private let notificationService: (any NotificationSending & NotificationAuthorizationStatusProviding)?
    private let logger: (any DiagnosticReading)?
    private let maintenance: (any StorageMaintaining)?
    private var viewModel: RadarViewModel?

    private init(
        coordinator: any RadarCoordinating,
        initialState: RadarState = RadarState(),
        settings: RadarSettings = RadarSettings(),
        settingsStore: (any RadarSettingsStoring)? = nil,
        watchlistStore: (any WatchlistStoring)? = nil,
        loginItemManager: (any LoginItemManaging)? = nil,
        loginItemsSettingsOpener: (any LoginItemsSettingsOpening)? = nil,
        notificationService: (any NotificationSending & NotificationAuthorizationStatusProviding)? = nil,
        logger: (any DiagnosticReading)? = nil,
        maintenance: (any StorageMaintaining)? = nil
    ) {
        self.coordinator = coordinator
        self.initialState = initialState
        self.settings = settings
        self.settingsStore = settingsStore
        self.watchlistStore = watchlistStore
        self.loginItemManager = loginItemManager
        self.loginItemsSettingsOpener = loginItemsSettingsOpener
        self.notificationService = notificationService
        self.logger = logger
        self.maintenance = maintenance
    }

    public static func live() -> AppEnvironment {
        do {
            return try buildLive()
        } catch {
            let state = RadarState(health: .unavailable("Data source unavailable"))
            return AppEnvironment(
                coordinator: UnavailableRadarCoordinator(state: state),
                initialState: state
            )
        }
    }

    public func makeViewModel() -> RadarViewModel {
        if let viewModel {
            return viewModel
        }

        let viewModel = RadarViewModel(
            coordinator: coordinator,
            initialState: initialState,
            settings: settings,
            settingsStore: settingsStore,
            watchlistStore: watchlistStore,
            loginItemManager: loginItemManager,
            loginItemsSettingsOpener: loginItemsSettingsOpener,
            notificationService: notificationService,
            diagnosticReader: logger,
            maintenance: maintenance,
            appVersion: Self.appVersion
        )
        self.viewModel = viewModel
        return viewModel
    }

    private static func buildLive() throws -> AppEnvironment {
        let fileManager = FileManager.default
        let supportURL = try fileManager
            .url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            .appendingPathComponent("NineBar", isDirectory: true)
        try fileManager.createDirectory(at: supportURL, withIntermediateDirectories: true)

        let settingsStore = RadarSettingsStore(
            fileURL: supportURL.appendingPathComponent("settings.json")
        )
        let settings = try settingsStore.load()
        L10n.apply(settings.language)
        let watchlistStore = WatchlistStore(
            fileURL: supportURL.appendingPathComponent("watchlist.json"),
            starterInstruments: WatchlistStore.starterInstruments
        )
        let logger = RotatingLogger(directoryURL: supportURL.appendingPathComponent("logs", isDirectory: true))
        let notificationService = SystemNotificationService()
        let loginItemManager = SystemLoginItemManager()

        let databaseURL = supportURL.appendingPathComponent("NineBar.sqlite")
        let barStore = try BarRepository(databaseURL: databaseURL)
        let signalStore = try SignalRepository(databaseURL: databaseURL)
        let coordinator = RadarCoordinator(
            watchlist: watchlistStore,
            marketData: EastMoneyMarketDataSource(
                client: RetryingHTTPClient(client: URLSessionHTTPClient())
            ),
            barStore: barStore,
            signalStore: signalStore,
            notifications: notificationService,
            settings: settings,
            logger: logger
        )
        return AppEnvironment(
            coordinator: coordinator,
            settings: settings,
            settingsStore: settingsStore,
            watchlistStore: watchlistStore,
            loginItemManager: loginItemManager,
            loginItemsSettingsOpener: loginItemManager,
            notificationService: notificationService,
            logger: logger,
            maintenance: StorageMaintenanceService(databaseURL: databaseURL, logger: logger)
        )
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}

private struct AppEnvironmentUnavailableError: Error, Sendable {}

private actor UnavailableRadarCoordinator: RadarCoordinating {
    private let state: RadarState

    init(state: RadarState) {
        self.state = state
    }

    func start() {}

    func stop() {}

    func refreshNow() throws {
        throw AppEnvironmentUnavailableError()
    }

    func states() -> AsyncStream<RadarState> {
        AsyncStream { continuation in
            continuation.yield(state)
            continuation.finish()
        }
    }

    func currentState() -> RadarState {
        state
    }

    func recentBars(instrumentID: String, timeframe: Timeframe, limit: Int) -> [Bar] {
        []
    }
}
