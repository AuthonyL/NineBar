import AppKit
import Combine
import SwiftUI
import NineBarCore

@MainActor
public enum RadarMenuBarIconRenderer {
    public static func render(
        sourceIcon: NSImage,
        showsAttentionDot: Bool
    ) -> NSImage {
        let pointSize = RadarMenuBarLabel.pointSize
        return NSImage(
            size: NSSize(width: pointSize, height: pointSize),
            flipped: false
        ) { bounds in
            sourceIcon.draw(
                in: bounds,
                from: NSRect(origin: .zero, size: sourceIcon.size),
                operation: .sourceOver,
                fraction: 1
            )

            if showsAttentionDot {
                let diameter: CGFloat = 4
                let inset: CGFloat = 1
                let dotRect = NSRect(
                    x: bounds.maxX - diameter - inset,
                    y: bounds.maxY - diameter - inset,
                    width: diameter,
                    height: diameter
                )
                let dot = NSBezierPath(ovalIn: dotRect)
                NSColor(
                    calibratedRed: 247.0 / 255.0,
                    green: 144.0 / 255.0,
                    blue: 191.0 / 255.0,
                    alpha: 1
                ).setFill()
                dot.fill()
            }
            return true
        }
    }
}

@MainActor
public final class RadarMenuBarIconBinder {
    private var stateSubscription: AnyCancellable?

    public init(
        model: RadarViewModel,
        sourceIcon: NSImage,
        onUpdate: @escaping @MainActor (NSImage, Bool) -> Void
    ) {
        stateSubscription = model.$state
            .map { state in
                guard case .healthy = state.health else { return false }
                return state.sequences.contains { (8...9).contains($0.count) }
            }
            .removeDuplicates()
            .sink { showsAttentionDot in
                onUpdate(
                    RadarMenuBarIconRenderer.render(
                        sourceIcon: sourceIcon,
                        showsAttentionDot: showsAttentionDot
                    ),
                    showsAttentionDot
                )
            }
    }
}

@MainActor
public final class RadarStatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let windows: RadarWindowPresenter
    private var iconBinder: RadarMenuBarIconBinder?

    public init(model: RadarViewModel, sourceIcon: NSImage) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        popover = NSPopover()
        windows = RadarWindowPresenter(model: model)
        super.init()

        let actions = RadarWindowActions(
            openSettings: { [weak self] in
                self?.popover.performClose(nil)
                self?.windows.showSettings()
            },
            openWatchlistEditor: { [weak self] in
                self?.popover.performClose(nil)
                self?.windows.showWatchlistEditor()
            }
        )
        let hostingController = NSHostingController(
            rootView: RadarPopoverView(model: model, backgroundIcon: sourceIcon, actions: actions)
        )
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = hostingController

        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown

        iconBinder = RadarMenuBarIconBinder(
            model: model,
            sourceIcon: sourceIcon
        ) { [weak button] image, showsAttentionDot in
            button?.image = image
            button?.toolTip = showsAttentionDot
                ? L10n.t("九转雷达：有八转或九转信号", "NineBar: a sequence is at 8 or 9")
                : AppMetadata.displayName
            button?.setAccessibilityLabel(
                showsAttentionDot ? L10n.t("九转雷达，有八转或九转信号", "NineBar: a sequence is at 8 or 9") : AppMetadata.displayName
            )
        }
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(
                relativeTo: sender.bounds,
                of: sender,
                preferredEdge: .minY
            )
        }
    }
}

public struct RadarMenuBarLabel: View {
    public static let pointSize: CGFloat = 18

    private let icon: NSImage
    private let showsAttentionDot: Bool

    public init(sourceIcon: NSImage, showsAttentionDot: Bool = false) {
        icon = RadarMenuBarIconRenderer.render(
            sourceIcon: sourceIcon,
            showsAttentionDot: showsAttentionDot
        )
        self.showsAttentionDot = showsAttentionDot
    }

    public var body: some View {
        Image(nsImage: icon)
            .renderingMode(.original)
            .frame(width: Self.pointSize, height: Self.pointSize)
            .id(showsAttentionDot)
            .accessibilityLabel(
                showsAttentionDot ? L10n.t("九转雷达，有八转或九转信号", "NineBar: a sequence is at 8 or 9") : AppMetadata.displayName
            )
    }
}
