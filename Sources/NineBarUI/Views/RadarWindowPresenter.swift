import AppKit
import Combine
import SwiftUI
import NineBarCore

/// What the popover can open. The popover is hosted outside the app's SwiftUI scenes, where
/// `SettingsLink` and sheets are unreliable, so it asks for real windows instead.
public struct RadarWindowActions {
    public var openSettings: @MainActor () -> Void
    public var openWatchlistEditor: @MainActor () -> Void

    public init(
        openSettings: @escaping @MainActor () -> Void = {},
        openWatchlistEditor: @escaping @MainActor () -> Void = {}
    ) {
        self.openSettings = openSettings
        self.openWatchlistEditor = openWatchlistEditor
    }
}

/// Opens Settings and the watchlist editor as ordinary windows. NineBar has no Dock icon, so
/// each window also activates the app to come to the front and receive typing.
@MainActor
public final class RadarWindowPresenter {
    private let model: RadarViewModel
    private var settingsWindow: NSWindow?
    private var watchlistWindow: NSWindow?
    private var languageObservation: AnyCancellable?

    public init(model: RadarViewModel) {
        self.model = model
        languageObservation = model.$settings
            .map(\.language)
            .removeDuplicates()
            .sink { [weak self] _ in self?.updateTitles() }
    }

    public func showSettings() {
        settingsWindow = present(settingsWindow) { _ in
            SettingsView(model: model, onEditWatchlist: { [weak self] in
                self?.showWatchlistEditor()
            })
        }
        updateTitles()
    }

    public func showWatchlistEditor() {
        watchlistWindow = present(watchlistWindow) { window in
            WatchlistEditorView(model: model, onClose: { [weak window] in
                window?.close()
            })
        }
        updateTitles()
    }

    /// Brings an open window forward, or rebuilds a closed one so it starts from the saved state.
    private func present<Content: View>(
        _ existing: NSWindow?,
        content: (NSWindow) -> Content
    ) -> NSWindow {
        let window = existing ?? makeWindow()
        if !window.isVisible {
            window.contentViewController = NSHostingController(rootView: content(window))
            window.center()
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private func updateTitles() {
        settingsWindow?.title = L10n.t("九转雷达设置", "NineBar Settings")
        watchlistWindow?.title = L10n.t("编辑自选", "Edit watchlist")
    }
}
