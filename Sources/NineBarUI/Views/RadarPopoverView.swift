import AppKit
import SwiftUI
import NineBarCore

struct RadarPopoverNavigation: Equatable {
    private(set) var detailSequence: SequenceSnapshot?

    mutating func showDetail(_ sequence: SequenceSnapshot) {
        detailSequence = sequence
    }

    mutating func returnToRadar() {
        detailSequence = nil
    }
}

public struct RadarPopoverView: View {
    static let sequenceViewportHeight = SignalCardView.rowHeight * 8
        + SignalCardView.rowSpacing * 7

    @ObservedObject private var model: RadarViewModel
    private let backgroundIcon: NSImage?
    private let actions: RadarWindowActions
    @State private var navigation = RadarPopoverNavigation()
    @State private var showingHistory = false
    @State private var showingWatchlist = false
    @State private var showingOtherWatchlist = false

    public init(
        model: RadarViewModel,
        backgroundIcon: NSImage? = nil,
        actions: RadarWindowActions = RadarWindowActions()
    ) {
        self.model = model
        self.backgroundIcon = backgroundIcon
        self.actions = actions
    }

    public var body: some View {
        Group {
            if let sequence = navigation.detailSequence {
                SignalDetailView(
                    model: model,
                    sequence: sequence,
                    onReturn: { navigation.returnToRadar() }
                )
            } else {
                overview
            }
        }
        // Rebuild every child when the language changes, including views whose inputs did not.
        .id(model.settings.language)
    }

    private var overview: some View {
        ZStack(alignment: .bottomTrailing) {
            if let backgroundIcon {
                Image(nsImage: backgroundIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 160, height: 160)
                    .opacity(0.07)
                    .padding(.trailing, 8)
                    .padding(.bottom, 28)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            VStack(spacing: 12) {
                header
                RadarFilterBar(model: model)
                sequenceList
                otherWatchlistDisclosure
                footer
            }
        }
        .padding(14)
        .frame(width: 380)
        .sheet(isPresented: $showingHistory) {
            RadarHistoryView(model: model)
        }
        .sheet(isPresented: $showingWatchlist) {
            RadarWatchlistView(model: model, onEdit: actions.openWatchlistEditor)
        }
    }

    private var otherWatchlistDisclosure: some View {
        DisclosureGroup(
            isExpanded: $showingOtherWatchlist,
            content: {
                if model.otherWatchlistPresentations.isEmpty {
                    Text(L10n.t("当前信号列表已包含全部自选股", "Every watchlist symbol is already in the signal list"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.otherWatchlistPresentations) { item in
                                CompactWatchlistRow(item: item)
                            }
                        }
                    }
                    .frame(height: min(
                        CGFloat(model.otherWatchlistPresentations.count) * 34,
                        170
                    ))
                    .padding(.top, 4)
                }
            },
            label: {
                Text(L10n.t(
                    "其他自选股（\(model.otherWatchlistPresentations.count)）",
                    "Other symbols (\(model.otherWatchlistPresentations.count))"
                ))
                    .font(.subheadline.weight(.medium))
            }
        )
        .accessibilityHint(L10n.t(
            "展开或收起未显示在九转信号区的自选股",
            "Show or hide watchlist symbols that are not in the signal list"
        ))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: model.statusSymbol)
                .foregroundStyle(model.isPaused ? Color.orange : Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(healthText)
                    .font(.headline)
                Button(L10n.t(
                    "自选股 \(model.state.watchlist.count) 只",
                    "\(model.state.watchlist.count) symbols"
                )) {
                    showingWatchlist = true
                }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                    .accessibilityHint(L10n.t("查看当前监控列表", "Show the symbols being monitored"))
            }
            Spacer()
            Button(L10n.t("编辑自选", "Edit watchlist")) {
                actions.openWatchlistEditor()
            }
            .font(.caption)
            .buttonStyle(.borderless)
            .accessibilityHint(L10n.t("输入或粘贴要监控的证券代码", "Type or paste the codes to monitor"))
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(L10n.t("立即刷新", "Refresh now"))
        }
    }

    @ViewBuilder
    private var sequenceList: some View {
        if showsEmptyWatchlist {
            ContentUnavailableView {
                Label(L10n.t("还没有自选股", "No symbols yet"), systemImage: "list.bullet")
            } description: {
                Text(L10n.t(
                    "添加沪深 A 股或场内 ETF 代码后开始监控。",
                    "Add Shanghai or Shenzhen A-share or ETF codes to start monitoring."
                ))
            } actions: {
                Button(L10n.t("编辑自选", "Edit watchlist")) {
                    actions.openWatchlistEditor()
                }
            }
            .frame(maxWidth: .infinity, minHeight: 180)
        } else if model.visibleSequences.isEmpty {
            ContentUnavailableView(
                emptyTitle,
                systemImage: model.isPaused ? "exclamationmark.triangle" : "9.circle",
                description: Text(emptyDescription)
            )
            .frame(maxWidth: .infinity, minHeight: 180)
        } else {
            ScrollView {
                LazyVStack(spacing: SignalCardView.rowSpacing) {
                    ForEach(model.visibleSequences) { sequence in
                        Button {
                            navigation.showDetail(sequence)
                        } label: {
                            SignalCardView(
                                sequence: sequence,
                                presentation: model.signalRowPresentation(for: sequence)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: Self.sequenceViewportHeight)
        }
    }

    private var footer: some View {
        HStack {
            Button(L10n.t("历史", "History")) { showingHistory = true }
            Spacer()
            Button {
                actions.openSettings()
            } label: {
                Label(L10n.t("设置", "Settings"), systemImage: "gear")
            }
            Button(L10n.t("退出", "Quit")) {
                NSApplication.shared.terminate(nil)
            }
        }
        .font(.caption)
        .buttonStyle(.borderless)
    }

    /// Shown only after the first refresh, so the prompt does not flash while the saved list loads.
    private var showsEmptyWatchlist: Bool {
        model.state.watchlist.isEmpty && model.state.updatedAt != nil && !model.isPaused
    }

    private var healthText: String {
        switch model.state.health {
        case .healthy: L10n.t("数据正常", "Data OK")
        case .idle: L10n.t("等待数据", "Waiting for data")
        case .closed: L10n.t("休市中", "Market closed")
        case .stale: L10n.t("数据暂停", "Data paused")
        case .unavailable: L10n.t("数据源不可用", "Data source unavailable")
        }
    }

    private var emptyTitle: String {
        if model.isPaused {
            return L10n.t("数据源不可用", "Data source unavailable")
        }
        if model.state.health == .closed {
            return L10n.t("休市中", "Market closed")
        }
        return L10n.t("暂无6–9序列", "No 6–9 sequences")
    }

    private var emptyDescription: String {
        if model.isPaused {
            return L10n.t("恢复数据后会继续计算。", "Counting resumes when data is back.")
        }
        if model.state.health == .closed {
            return L10n.t("开盘后会自动开始计算。", "Counting starts when the market opens.")
        }
        return L10n.t("符合条件的九转序列会显示在这里。", "Sequences at counts 6–9 appear here.")
    }
}

struct RadarFilterBar: View {
    @ObservedObject var model: RadarViewModel

    var body: some View {
        HStack(spacing: 8) {
            // English option names are longer, and "Top / Bottom" and "1m / 5m" read clearly
            // without a prefix, so the prefixes are left out to keep the row within the popover.
            if !L10n.isEnglish {
                compactPickerLabel("方向")
            }
            Picker(L10n.t("方向", "Direction"), selection: directionFilterBinding) {
                Text(L10n.t("全部", "All")).tag("all")
                Text(L10n.t("顶部", "Top")).tag(SignalDirection.top.rawValue)
                Text(L10n.t("底部", "Bottom")).tag(SignalDirection.bottom.rawValue)
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            if !L10n.isEnglish {
                compactPickerLabel("周期")
            }
            Picker(L10n.t("周期", "Timeframe"), selection: timeframeFilterBinding) {
                Text(L10n.t("全部", "All")).tag("all")
                Text(L10n.t("1分", "1m")).tag("1")
                Text(L10n.t("5分", "5m")).tag("5")
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
        .frame(height: 32)
    }

    private func compactPickerLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .fixedSize()
    }

    private var directionFilterBinding: Binding<String> {
        Binding(
            get: { model.directionFilter?.rawValue ?? "all" },
            set: { model.directionFilter = SignalDirection(rawValue: $0) }
        )
    }

    private var timeframeFilterBinding: Binding<String> {
        Binding(
            get: { model.timeframeFilter.map { String($0.rawValue) } ?? "all" },
            set: { value in
                model.timeframeFilter = Int(value).flatMap(Timeframe.init(rawValue:))
            }
        )
    }
}

private struct CompactWatchlistRow: View {
    let item: WatchlistPresentation

    var body: some View {
        HStack(spacing: 8) {
            Text(item.identityText)
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(item.statusText)
                .font(.caption2)
                .foregroundStyle(item.isMonitoring ? Color.green : Color.secondary)
        }
        .frame(height: 34)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

private struct RadarHistoryView: View {
    @ObservedObject var model: RadarViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if model.state.history.isEmpty {
                    ContentUnavailableView(L10n.t("暂无历史信号", "No signal history"), systemImage: "clock")
                } else {
                    ForEach(model.state.history) { signal in
                        let presentation = model.historyPresentation(for: signal)
                        SignalHistoryRow(
                            signal: signal,
                            identityText: presentation.identityText,
                            contextText: presentation.contextText,
                            referencePriceText: presentation.referencePriceText
                        )
                            .listRowSeparator(.hidden)
                    }
                }
            }
            .navigationTitle(L10n.t("信号历史", "Signal history"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("关闭", "Close")) { dismiss() }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 380)
    }
}

private struct RadarWatchlistView: View {
    @ObservedObject var model: RadarViewModel
    let onEdit: @MainActor () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(model.watchlistPresentations) { item in
                HStack(alignment: .firstTextBaseline) {
                    Text(item.identityText)
                    Spacer()
                    Text(item.statusText)
                        .font(.caption)
                        .foregroundStyle(item.isMonitoring ? Color.green : Color.secondary)
                }
            }
            .navigationTitle(L10n.t(
                "自选股（\(model.watchlistPresentations.count)）",
                "Watchlist (\(model.watchlistPresentations.count))"
            ))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("关闭", "Close")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(L10n.t("编辑", "Edit")) {
                        dismiss()
                        onEdit()
                    }
                }
            }
        }
        .frame(minWidth: 440, minHeight: 420)
    }
}
