import AppKit
import SwiftUI
import NineBarCore
import NineBarUI

@main
struct NineBarApp: App {
    private static let menuBarIcon: NSImage = {
        guard
            let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
            let image = NSImage(contentsOf: url)
        else {
            return NSApplication.shared.applicationIconImage
        }
        return image
    }()

    @NSApplicationDelegateAdaptor(RadarAppDelegate.self) private var appDelegate
    @StateObject private var model: RadarViewModel

    init() {
        let environment = AppEnvironment.live()
        let model = environment.makeViewModel()
        _model = StateObject(wrappedValue: model)
        appDelegate.lifecycle = RadarApplicationLifecycle(model: model)
        appDelegate.model = model
        appDelegate.menuBarIcon = Self.menuBarIcon
    }

    var body: some Scene {
        // Settings and the watchlist editor open as AppKit windows from the status item popover
        // (RadarWindowPresenter), because SettingsLink cannot reach this scene from there. The
        // empty scene satisfies SwiftUI, and its menu command is removed so Command-comma does
        // not open a blank window.
        Settings { EmptyView() }
            .commands { CommandGroup(replacing: .appSettings) {} }
    }
}

@MainActor
private final class RadarAppDelegate: NSObject, NSApplicationDelegate {
    var lifecycle: RadarApplicationLifecycle?
    var model: RadarViewModel?
    var menuBarIcon: NSImage?
    private var statusItemController: RadarStatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        lifecycle?.applicationDidFinishLaunching()
        if let model, let menuBarIcon {
            statusItemController = RadarStatusItemController(
                model: model,
                sourceIcon: menuBarIcon
            )
        }
    }
}
