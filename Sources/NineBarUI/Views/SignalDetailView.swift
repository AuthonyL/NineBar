import Foundation
import SwiftUI
import NineBarCore

public struct SignalDetailView: View {
    static var returnButtonTitle: String {
        L10n.t("返回九转雷达", "Back to NineBar")
    }

    @ObservedObject private var model: RadarViewModel
    private let sequence: SequenceSnapshot
    private let onReturn: () -> Void

    public init(
        model: RadarViewModel,
        sequence: SequenceSnapshot,
        onReturn: @escaping () -> Void
    ) {
        self.model = model
        self.sequence = sequence
        self.onReturn = onReturn
    }

    public var body: some View {
        let instrument = model.instrument(for: sequence)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Button {
                            onReturn()
                        } label: {
                            Label(Self.returnButtonTitle, systemImage: "chevron.left")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .keyboardShortcut(.cancelAction)
                        Spacer()
                    }

                    header(instrument: instrument)

                    if model.isDetailLoading {
                        ProgressView(L10n.t("载入最近K线", "Loading recent bars"))
                            .frame(maxWidth: .infinity, minHeight: 160)
                    } else if let error = model.detailErrorMessage {
                        ContentUnavailableView(L10n.t("数据源不可用", "Data source unavailable"), systemImage: "exclamationmark.triangle", description: Text(error))
                    } else {
                        MiniBarChart(bars: model.detailBars, sequence: sequence)
                    }

                    sequenceSummary
                    historySection
                }
                .padding(18)
            }
            .navigationTitle(L10n.t("\(instrument.name) 详情", "\(instrument.name) details"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("关闭", "Close")) { onReturn() }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 580)
        .task(id: sequence.id) {
            await model.select(sequence: sequence)
        }
        .onDisappear {
            model.dismissDetail()
        }
    }

    private func header(instrument: Instrument) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(instrument.name).font(.title3.weight(.semibold))
                Text("\(instrument.symbol) · \(SignalPricePresentation.directionWord(sequence.direction)) · "
                    + L10n.t("\(sequence.timeframe.rawValue)分钟", "\(sequence.timeframe.rawValue) min"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(phaseText)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(phaseColor.opacity(0.16))
                .foregroundStyle(phaseColor)
                .clipShape(Capsule())
        }
    }

    private var sequenceSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("序列信息", "Sequence")).font(.headline)
            LabeledContent(L10n.t("范围", "Range"), value: "\(date(sequence.sequenceStart)) – \(date(sequence.lastBarEnd))")
            LabeledContent(L10n.t("当前阶段", "Phase"), value: phaseText)
            LabeledContent(
                sequence.direction == .top
                    ? L10n.t("顶部参考价", "Top reference")
                    : L10n.t("底部参考价", "Bottom reference"),
                value: (sequence.direction == .top
                    ? L10n.t("第1–9根最高价", "Highest of bars 1–9")
                    : L10n.t("第1–9根最低价", "Lowest of bars 1–9")) + " \(price(sequence.extremePrice))"
            )
            LabeledContent(L10n.t("当前收盘价", "Last close"), value: price(sequence.lastClose))
        }
        .font(.subheadline)
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("匹配历史信号", "Matching history")).font(.headline)
            let history = model.history(for: sequence)
            if history.isEmpty {
                Text(L10n.t("暂无已确认历史信号", "No confirmed signals yet"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(history) { signal in
                    SignalHistoryRow(
                        signal: signal,
                        referencePriceText: model.historyPresentation(for: signal).referencePriceText
                    )
                }
            }
        }
    }

    private var phaseText: String {
        switch sequence.phase {
        case .candidate: L10n.t("候选", "Candidate")
        case .confirmed: L10n.t("已确认", "Confirmed")
        case .counting: L10n.t("计数中", "Counting")
        }
    }

    private var phaseColor: Color {
        switch sequence.phase {
        case .candidate: .orange
        case .confirmed: .purple
        case .counting: sequence.direction == .top ? .red : .green
        }
    }

    private func price(_ value: Double) -> String {
        SignalPricePresentation.valueText(value, kind: model.instrument(for: sequence).kind)
    }

    private func date(_ value: Date) -> String {
        Self.dateFormatter.string(from: value)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}

struct SignalHistoryRow: View {
    let signal: ConfirmedSignal
    let identityText: String?
    let contextText: String?
    let referencePriceText: String?

    init(
        signal: ConfirmedSignal,
        identityText: String? = nil,
        contextText: String? = nil,
        referencePriceText: String? = nil
    ) {
        self.signal = signal
        self.identityText = identityText
        self.contextText = contextText
        self.referencePriceText = referencePriceText ?? SignalPricePresentation.text(
            direction: signal.direction,
            value: signal.extremePrice
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let identityText {
                Text(identityText)
                    .font(.subheadline.weight(.semibold))
            }
            HStack {
                if let contextText {
                    Text(contextText)
                }
                Spacer()
                Text(Self.dateFormatter.string(from: signal.lastBarEnd))
            }
            .font(.subheadline.weight(.medium))
            if let referencePriceText {
                Text(referencePriceText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                returnValue(L10n.t("5分", "5m"), signal.return5m)
                returnValue(L10n.t("15分", "15m"), signal.return15m)
                returnValue(L10n.t("30分", "30m"), signal.return30m)
                returnValue(L10n.t("60分", "60m"), signal.return60m)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func returnValue(_ label: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(formattedReturn(value))
                .font(.caption.monospacedDigit())
                .foregroundStyle(returnColor(value))
        }
    }

    private func formattedReturn(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%+.2f%%", locale: Locale(identifier: "en_US_POSIX"), value * 100)
    }

    private func returnColor(_ value: Double?) -> Color {
        guard let value else { return .secondary }
        if value > 0 { return .red }
        if value < 0 { return .green }
        return .primary
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}
