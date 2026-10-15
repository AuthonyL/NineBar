import Testing
@testable import NineBarUI
import NineBarCore
import AppKit
import SwiftUI

@Suite("RadarViewModel projections")
@MainActor
struct RadarViewModelTests {
    @Test("menu bar label is one eighteen-point transparent foreground icon")
    func menuBarLabelUsesOnlyOneForegroundIcon() {
        let sourceIcon = NSImage(size: NSSize(width: 512, height: 512))
        let label = RadarMenuBarLabel(sourceIcon: sourceIcon)
        let hostingView = NSHostingView(rootView: label)
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let assetURL = projectRoot
            .appendingPathComponent("Resources")
            .appendingPathComponent("MenuBarIcon.png")

        hostingView.layoutSubtreeIfNeeded()

        #expect(hostingView.fittingSize == NSSize(width: 18, height: 18))
        #expect(sourceIcon.size == NSSize(width: 512, height: 512))

        guard
            let assetData = try? Data(contentsOf: assetURL),
            let representation = NSBitmapImageRep(data: assetData)
        else {
            Issue.record("MenuBarIcon.png must be a readable bitmap asset")
            return
        }
        #expect(representation.hasAlpha)
        #expect(representation.colorAt(x: 0, y: 0)?.alphaComponent == 0)
        let centerAlpha = representation.colorAt(
            x: representation.pixelsWide / 2,
            y: representation.pixelsHigh / 2
        )?.alphaComponent ?? 0
        #expect(centerAlpha > 0.9)
    }

    @Test("menu bar attention follows an active eight even when filters hide it")
    func menuBarAttentionIgnoresPopoverFilters() {
        let sequence = radarTop(
            8,
            phase: .counting,
            lastBarEnd: radarDate("10:05"),
            timeframe: .oneMinute
        )
        let model = RadarViewModel.preview(state: radarState(sequences: [sequence]))
        model.directionFilter = .bottom
        model.timeframeFilter = .fiveMinutes

        #expect(model.showsMenuBarAttentionDot)
        #expect(model.visibleSequences.isEmpty)
    }

    @Test("menu bar attention excludes lower counts and paused data")
    func menuBarAttentionRequiresCurrentEightOrNine() {
        let seven = RadarViewModel.preview(state: radarState(sequences: [
            radarTop(7, phase: .counting, lastBarEnd: radarDate("10:05"))
        ]))
        let pausedEight = RadarViewModel.preview(state: radarState(
            health: .stale,
            sequences: [radarTop(8, phase: .counting, lastBarEnd: radarDate("10:05"))]
        ))

        #expect(!seven.showsMenuBarAttentionDot)
        #expect(!pausedEight.showsMenuBarAttentionDot)
    }

    @Test("menu bar attention renders the reference pink dot without changing its size")
    func menuBarAttentionRendersInsideTheExistingLabelBounds() throws {
        let transparentIcon = NSImage(size: NSSize(width: 512, height: 512))
        let quietLabel = RadarMenuBarLabel(
            sourceIcon: transparentIcon,
            showsAttentionDot: false
        )
        let alertLabel = RadarMenuBarLabel(
            sourceIcon: transparentIcon,
            showsAttentionDot: true
        )
        let quietView = NSHostingView(rootView: quietLabel)
        let alertView = NSHostingView(rootView: alertLabel)

        quietView.layoutSubtreeIfNeeded()
        alertView.layoutSubtreeIfNeeded()

        #expect(quietView.fittingSize == NSSize(width: 18, height: 18))
        #expect(alertView.fittingSize == NSSize(width: 18, height: 18))
        #expect(visiblePixelCount(in: quietLabel) == 0)
        #expect(visiblePixelCount(in: alertLabel) > 0)
    }

    @Test("menu bar attention is a four-point reference-pink bitmap dot without an outline")
    func menuBarAttentionIsPartOfTheStatusItemBitmap() throws {
        let transparentIcon = NSImage(size: NSSize(width: 512, height: 512))
        let quietIcon = RadarMenuBarIconRenderer.render(
            sourceIcon: transparentIcon,
            showsAttentionDot: false
        )
        let alertIcon = RadarMenuBarIconRenderer.render(
            sourceIcon: transparentIcon,
            showsAttentionDot: true
        )

        #expect(quietIcon.size == NSSize(width: 18, height: 18))
        #expect(alertIcon.size == NSSize(width: 18, height: 18))
        #expect(referencePinkPixelCount(in: quietIcon) == 0)
        #expect(referencePinkPixelCount(in: alertIcon) > 0)
        #expect(visiblePixelSize(in: alertIcon) == PixelSize(width: 4, height: 4))
    }

    @Test("status item bitmap follows live signal changes after launch")
    func statusItemBitmapObservesTheLiveModel() async throws {
        let transparentIcon = NSImage(size: NSSize(width: 512, height: 512))
        let coordinator = LiveStateCoordinator(initialState: radarState())
        let model = RadarViewModel(coordinator: coordinator, initialState: radarState())
        var renderedIcons: [NSImage] = []
        let binder = RadarMenuBarIconBinder(
            model: model,
            sourceIcon: transparentIcon,
            onUpdate: { image, _ in renderedIcons.append(image) }
        )

        await model.start()
        #expect(referencePinkPixelCount(in: renderedIcons.last!) == 0)

        await coordinator.emit(radarState(sequences: [
            radarBottom(8, phase: .counting, lastBarEnd: radarDate("10:05"))
        ]))
        try await uiEventually { await MainActor.run { model.showsMenuBarAttentionDot } }
        #expect(referencePinkPixelCount(in: renderedIcons.last!) > 0)

        await coordinator.emit(radarState(
            health: .stale,
            sequences: [radarBottom(8, phase: .counting, lastBarEnd: radarDate("10:06"))]
        ))
        try await uiEventually { await MainActor.run { !model.showsMenuBarAttentionDot } }
        #expect(referencePinkPixelCount(in: renderedIcons.last!) == 0)
        withExtendedLifetime(binder) {}
        await model.stop()
    }

    @Test("background watermark does not widen the radar popover")
    func backgroundWatermarkKeepsTheRadarPopoverCompact() {
        let sourceIcon = NSImage(size: NSSize(width: 512, height: 512))
        let model = RadarViewModel.preview(state: RadarState())
        let view = RadarPopoverView(model: model, backgroundIcon: sourceIcon)
        let hostingView = NSHostingView(rootView: view)

        hostingView.layoutSubtreeIfNeeded()

        #expect(hostingView.fittingSize.width == 380)
    }

    @Test("direction and timeframe filters fit one compact row in both languages", arguments: [false, true])
    func filtersFitOneCompactRow(english: Bool) {
        let model = RadarViewModel.preview(state: RadarState())
        // Measure the natural size: a fixed frame would hide content wider than the popover.
        let size = L10n.$scopedEnglish.withValue(english) {
            let hostingView = NSHostingView(rootView: RadarFilterBar(model: model))
            hostingView.layoutSubtreeIfNeeded()
            return hostingView.fittingSize
        }

        #expect(size.width <= 352, "filter bar is \(size.width) pt wide")
        #expect(size.height <= 34)
    }

    @Test("returning from detail restores the radar overview route")
    func returningFromDetailRestoresRadarOverviewRoute() {
        let sequence = radarTop(
            8,
            phase: .counting,
            lastBarEnd: radarDate("10:05")
        )
        var navigation = RadarPopoverNavigation()

        navigation.showDetail(sequence)
        #expect(navigation.detailSequence == sequence)

        navigation.returnToRadar()
        #expect(navigation.detailSequence == nil)
    }

    @Test("radar viewport fits eight complete single-line rows within a compact height")
    func radarViewportFitsEightCompleteRows() {
        let eightRows = SignalCardView.rowHeight * 8 + SignalCardView.rowSpacing * 7

        #expect(RadarPopoverView.sequenceViewportHeight == eightRows)
        #expect(RadarPopoverView.sequenceViewportHeight <= 250)
    }

    @Test("compact signal row exposes one-line identity position and prices")
    func compactSignalRowExposesRequiredFields() {
        let sequence = radarTop(
            6,
            phase: .counting,
            lastBarEnd: radarDate("10:05"),
            timeframe: .fiveMinutes
        )
        let model = RadarViewModel.preview(state: radarState(sequences: [sequence]))

        let row = model.signalRowPresentation(for: sequence)

        #expect(row.nameText == "证券000001")
        #expect(row.symbolText == "000001")
        #expect(row.positionText == "顶6·5分")
        #expect(row.currentPriceText == "现10.00")
        #expect(row.referencePriceText == "九12.00")
        #expect(row.confirmationMarkText == nil)
    }

    @Test("compact signal row and status read in English when English is selected")
    func compactSignalRowInEnglish() {
        let sequence = radarTop(
            6,
            phase: .counting,
            lastBarEnd: radarDate("10:05"),
            timeframe: .fiveMinutes
        )
        let model = RadarViewModel.preview(state: radarState(sequences: [sequence]))

        L10n.$scopedEnglish.withValue(true) {
            let row = model.signalRowPresentation(for: sequence)
            #expect(row.positionText == "T6·5m")
            #expect(row.currentPriceText == "Px 10.00")
            #expect(row.referencePriceText == "9: 12.00")
            #expect(model.statusText == "T6")
        }
    }

    @Test("only confirmed signal rows retain a compact visual phase mark")
    func onlyConfirmedRowsShowAVisualPhaseMark() {
        let model = RadarViewModel.preview(state: radarState())
        let candidate = radarTop(8, phase: .candidate, lastBarEnd: radarDate("10:05"))
        let counting = radarTop(8, phase: .counting, lastBarEnd: radarDate("10:05"))
        let confirmed = radarTop(9, phase: .confirmed, lastBarEnd: radarDate("10:05"))

        #expect(model.signalRowPresentation(for: candidate).confirmationMarkText == nil)
        #expect(model.signalRowPresentation(for: counting).confirmationMarkText == nil)
        #expect(model.signalRowPresentation(for: confirmed).confirmationMarkText == "✓")
    }

    @Test("signal card stays within one row of the popover in both languages", arguments: [false, true])
    func signalCardUsesSingleLineHeight(english: Bool) {
        let sequence = radarTop(
            9,
            phase: .confirmed,
            lastBarEnd: radarDate("10:05"),
            timeframe: .fiveMinutes
        )
        let model = RadarViewModel.preview(state: radarState(sequences: [sequence]))
        let size = L10n.$scopedEnglish.withValue(english) {
            let hostingView = NSHostingView(rootView: SignalCardView(
                sequence: sequence,
                presentation: model.signalRowPresentation(for: sequence)
            ))
            hostingView.layoutSubtreeIfNeeded()
            return hostingView.fittingSize
        }

        #expect(size.height <= 28)
        #expect(size.width <= 352, "signal card is \(size.width) pt wide")
    }

    @Test("watchlist rows expose sorted identities and per-symbol data status")
    func watchlistRowsExposeIdentityAndStatus() {
        let healthy = Instrument(
            symbol: "600519",
            name: "贵州茅台",
            exchange: .shanghai,
            kind: .stock
        )
        let failed = Instrument(
            symbol: "159915",
            name: "创业板ETF易方达",
            exchange: .shenzhen,
            kind: .etf
        )
        let state = RadarState(
            health: .unavailable("数据源不可用"),
            watchlist: [failed, healthy],
            failures: [InstrumentFailure(instrumentID: failed.id, message: "行情不可用")]
        )
        let model = RadarViewModel.preview(state: state)

        #expect(model.watchlistPresentations.map(\.identityText) == [
            "贵州茅台 600519",
            "创业板ETF易方达 159915"
        ])
        #expect(model.watchlistPresentations.map(\.statusText) == [
            "等待数据",
            "分钟行情不可用"
        ])
    }

    @Test("other watchlist rows exclude symbols already visible in the signal list")
    func otherWatchlistRowsExcludeVisibleSignals() {
        let visible = Instrument(
            symbol: "600519",
            name: "贵州茅台",
            exchange: .shanghai,
            kind: .stock
        )
        let countingBelowSix = Instrument(
            symbol: "300750",
            name: "宁德时代",
            exchange: .shenzhen,
            kind: .stock
        )
        let quiet = Instrument(
            symbol: "159915",
            name: "创业板ETF易方达",
            exchange: .shenzhen,
            kind: .etf
        )
        let visibleSequence = SequenceSnapshot(
            instrumentID: visible.id,
            timeframe: .fiveMinutes,
            direction: .top,
            count: 8,
            phase: .counting,
            sequenceStart: radarDate("09:30"),
            lastBarEnd: radarDate("10:05"),
            extremePrice: 12,
            lastClose: 10
        )
        let hiddenSequence = SequenceSnapshot(
            instrumentID: countingBelowSix.id,
            timeframe: .oneMinute,
            direction: .bottom,
            count: 5,
            phase: .counting,
            sequenceStart: radarDate("09:31"),
            lastBarEnd: radarDate("10:04"),
            extremePrice: 9,
            lastClose: 10
        )
        let model = RadarViewModel.preview(state: RadarState(
            health: .healthy(radarDate("10:10")),
            watchlist: [quiet, visible, countingBelowSix],
            sequences: [hiddenSequence, visibleSequence]
        ))

        #expect(model.otherWatchlistPresentations.map(\.identityText) == [
            "创业板ETF易方达 159915",
            "宁德时代 300750"
        ])
        #expect(model.otherWatchlistPresentations.map(\.statusText) == [
            "监控中",
            "监控中"
        ])
    }

    @Test("signal price labels distinguish top and bottom reference prices")
    func signalPriceLabelsDistinguishDirection() {
        let model = RadarViewModel.preview(state: radarState())
        let top = radarTop(8, phase: .counting, lastBarEnd: radarDate("10:05"))
        let bottom = radarBottom(8, phase: .counting, lastBarEnd: radarDate("10:05"))

        #expect(model.referencePriceText(for: top) == "顶部参考价 12.00")
        #expect(model.referencePriceText(for: bottom) == "底部参考价 8.00")
    }

    @Test("ETF signal reference prices retain three decimal places")
    func etfSignalReferencePricesRetainThreeDecimals() {
        let instrument = Instrument(
            symbol: "159915",
            name: "创业板ETF易方达",
            exchange: .shenzhen,
            kind: .etf
        )
        let sequence = SequenceSnapshot(
            instrumentID: instrument.id,
            timeframe: .oneMinute,
            direction: .bottom,
            count: 9,
            phase: .confirmed,
            sequenceStart: radarDate("09:30"),
            lastBarEnd: radarDate("10:05"),
            extremePrice: 3.411,
            lastClose: 3.412
        )
        let model = RadarViewModel.preview(state: RadarState(
            health: .healthy(radarDate("10:10")),
            watchlist: [instrument],
            sequences: [sequence]
        ))

        #expect(model.referencePriceText(for: sequence) == "底部参考价 3.411")
    }

    @Test("status prefers a confirmed ninth bar over a candidate eighth bar")
    func statusPrefersConfirmedNineThenCandidateEight() {
        let model = RadarViewModel.preview(state: radarState(
            sequences: [
                radarBottom(8, phase: .candidate, lastBarEnd: radarDate("10:05")),
                radarTop(9, phase: .confirmed, lastBarEnd: radarDate("10:04"))
            ]
        ))

        #expect(model.statusText == "顶9")
        #expect(model.visibleSequences.map(\.count) == [9, 8])
    }

    @Test("healthy state without a six-to-nine sequence shows icon only")
    func healthyWithoutSixShowsIconOnly() {
        let model = RadarViewModel.preview(state: radarState(
            sequences: [radarTop(5, phase: .counting, lastBarEnd: radarDate("10:05"))]
        ))

        #expect(model.statusText == "")
        #expect(model.statusSymbol == "9.circle")
    }

    @Test("stale health overrides the strongest signal")
    func staleStateOverridesSignalLabel() {
        let model = RadarViewModel.preview(state: radarState(
            health: .stale,
            sequences: [radarTop(9, phase: .confirmed, lastBarEnd: radarDate("10:05"))]
        ))

        #expect(model.statusText == "暂停")
        #expect(model.statusSymbol == "exclamationmark.triangle")
    }

    @Test("global history projection identifies name code direction and timeframe")
    func globalHistoryProjectionIncludesSignalIdentity() {
        let instrument = Instrument(
            symbol: "600519",
            name: "贵州茅台",
            exchange: .shanghai,
            kind: .stock
        )
        let signal = historySignal(
            instrumentID: instrument.id,
            timeframe: .fiveMinutes,
            direction: .top
        )
        let state = RadarState(
            health: .healthy(radarDate("10:10")),
            watchlist: [instrument],
            history: [signal]
        )
        let model = RadarViewModel.preview(state: state)

        #expect(model.historyPresentation(for: signal) == SignalHistoryPresentation(
            identityText: "贵州茅台 600519",
            contextText: "顶部 · 5分钟",
            confirmationText: "09-01 10:00",
            referencePriceText: "顶部参考价 10.40"
        ))

        let fallback = historySignal(
            instrumentID: "sz.159915",
            timeframe: .oneMinute,
            direction: .bottom
        )
        #expect(model.historyPresentation(for: fallback).identityText == "未知证券 159915")
        #expect(model.historyPresentation(for: fallback).contextText == "底部 · 1分钟")
        #expect(model.historyPresentation(for: fallback).referencePriceText == "底部参考价 10.40")
    }

    @Test("sorts confirmed nines, candidates, and counting sequences deterministically")
    func visibleSequencesUseSignalPriorityAndStableTieBreakers() {
        let model = RadarViewModel.preview(state: radarState(
            sequences: [
                radarBottom(8, phase: .counting, lastBarEnd: radarDate("10:09"), symbol: "000004"),
                radarTop(7, phase: .candidate, lastBarEnd: radarDate("10:07"), symbol: "000003"),
                radarBottom(9, phase: .confirmed, lastBarEnd: radarDate("10:06"), symbol: "000002"),
                radarTop(9, phase: .confirmed, lastBarEnd: radarDate("10:05"), symbol: "000001"),
                radarBottom(7, phase: .candidate, lastBarEnd: radarDate("10:08"), symbol: "000006"),
                radarTop(7, phase: .candidate, lastBarEnd: radarDate("10:08"), symbol: "000005")
            ]
        ))

        #expect(model.visibleSequences.map(\.instrumentID) == [
            "sh.000002", "sh.000001", "sh.000005", "sh.000006", "sh.000003", "sh.000004"
        ])
    }

    @Test("filters sequences by selected direction and timeframe")
    func visibleSequencesHonorFilters() {
        let model = RadarViewModel.preview(state: radarState(
            sequences: [
                radarTop(8, phase: .counting, lastBarEnd: radarDate("10:05"), timeframe: .oneMinute),
                radarBottom(9, phase: .confirmed, lastBarEnd: radarDate("10:06"), timeframe: .fiveMinutes)
            ]
        ))
        model.directionFilter = .bottom
        model.timeframeFilter = .fiveMinutes

        #expect(model.visibleSequences.map(\.instrumentID) == ["sh.000001"])
    }

    @Test("starting twice while setup is suspended keeps one state-stream consumer")
    func startKeepsOneStateStreamConsumer() async {
        let coordinator = StateStreamRecordingCoordinator()
        let model = RadarViewModel(coordinator: coordinator, initialState: radarState())

        let first = Task { await model.start() }
        await Task.yield()
        let second = Task { await model.start() }
        await first.value
        await second.value

        #expect(await coordinator.streamRequestCount() == 1)
        await model.stop()
    }

    @Test("application launch starts monitoring without presenting menu content")
    func applicationLaunchStartsOneStateStreamWithoutPopoverPresentation() async throws {
        let coordinator = StateStreamRecordingCoordinator()
        let model = RadarViewModel(coordinator: coordinator, initialState: radarState())
        let lifecycle = RadarApplicationLifecycle(model: model)

        lifecycle.applicationDidFinishLaunching()
        lifecycle.applicationDidFinishLaunching()

        try await uiEventually { await coordinator.streamRequestCount() == 1 }
        #expect(await coordinator.startRequestCount() == 1)
        await model.stop()
    }
}

@MainActor
private func historySignal(
    instrumentID: String,
    timeframe: Timeframe,
    direction: SignalDirection
) -> ConfirmedSignal {
    let end = radarDate("10:00")
    return ConfirmedSignal(
        instrumentID: instrumentID,
        timeframe: timeframe,
        direction: direction,
        sequenceStart: radarDate("09:52"),
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

private func uiEventually(
    attempts: Int = 400,
    condition: @escaping @Sendable () async -> Bool
) async throws {
    for _ in 0..<attempts {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Condition was not met before timeout")
}

@MainActor
private func visiblePixelCount<V: View>(in view: V) -> Int {
    let renderer = ImageRenderer(content: view.frame(width: 18, height: 18))
    renderer.scale = 2
    guard
        let image = renderer.nsImage,
        let data = image.tiffRepresentation,
        let representation = NSBitmapImageRep(data: data)
    else {
        return 0
    }

    return visiblePixelCount(in: representation)
}

private func referencePinkPixelCount(in image: NSImage) -> Int {
    guard
        let data = image.tiffRepresentation,
        let representation = NSBitmapImageRep(data: data)
    else {
        return 0
    }
    return referencePinkPixelCount(in: representation)
}

private func referencePinkPixelCount(in representation: NSBitmapImageRep) -> Int {
    var count = 0
    for x in 0..<representation.pixelsWide {
        for y in 0..<representation.pixelsHigh {
            guard let color = representation.colorAt(x: x, y: y) else { continue }
            if abs(color.redComponent - 247.0 / 255.0) < 0.08,
               abs(color.greenComponent - 144.0 / 255.0) < 0.08,
               abs(color.blueComponent - 191.0 / 255.0) < 0.08,
               color.alphaComponent > 0.05 {
                count += 1
            }
        }
    }
    return count
}

private struct PixelSize: Equatable {
    let width: Int
    let height: Int
}

private func visiblePixelCount(in image: NSImage) -> Int {
    guard
        let data = image.tiffRepresentation,
        let representation = NSBitmapImageRep(data: data)
    else {
        return 0
    }

    return visiblePixelCount(in: representation)
}

private func visiblePixelCount(in representation: NSBitmapImageRep) -> Int {
    var count = 0
    for x in 0..<representation.pixelsWide {
        for y in 0..<representation.pixelsHigh {
            if (representation.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                count += 1
            }
        }
    }
    return count
}

private func visiblePixelSize(in image: NSImage) -> PixelSize? {
    guard
        let data = image.tiffRepresentation,
        let representation = NSBitmapImageRep(data: data)
    else {
        return nil
    }

    var minX = representation.pixelsWide
    var maxX = -1
    var minY = representation.pixelsHigh
    var maxY = -1
    for x in 0..<representation.pixelsWide {
        for y in 0..<representation.pixelsHigh {
            guard (representation.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 else {
                continue
            }
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
        }
    }

    guard maxX >= minX, maxY >= minY else { return nil }
    return PixelSize(width: maxX - minX + 1, height: maxY - minY + 1)
}
