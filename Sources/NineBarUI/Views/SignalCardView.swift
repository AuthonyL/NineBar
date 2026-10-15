import Foundation
import SwiftUI
import NineBarCore

public struct SignalCardView: View {
    static let rowHeight: CGFloat = 28
    static let rowSpacing: CGFloat = 3

    public let sequence: SequenceSnapshot
    public let presentation: SignalRowPresentation

    public init(sequence: SequenceSnapshot, presentation: SignalRowPresentation) {
        self.sequence = sequence
        self.presentation = presentation
    }

    public var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                Text(presentation.nameText)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(presentation.symbolText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .frame(width: 130, alignment: .leading)

            Text(presentation.positionText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(directionColor)
                .fixedSize()

            if let confirmationMarkText = presentation.confirmationMarkText {
                Text(confirmationMarkText)
                    .font(.caption2.bold())
                    .foregroundStyle(.purple)
                    .accessibilityHidden(true)
            }

            Spacer(minLength: 2)

            Text(presentation.currentPriceText)
                .foregroundStyle(.primary)
                .fixedSize()
            Text(presentation.referencePriceText)
                .foregroundStyle(.secondary)
                .fixedSize()

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .font(.caption2.monospacedDigit())
        .padding(.horizontal, 8)
        .frame(height: Self.rowHeight)
        .background(Color.primary.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(sequence.phase == .candidate ? directionColor.opacity(0.65) : Color.clear, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(presentation.nameText) \(presentation.positionText) \(presentation.currentPriceText) \(presentation.referencePriceText) \(phaseText)")
    }

    private var phaseText: String {
        switch sequence.phase {
        case .candidate: L10n.t("候选", "Candidate")
        case .confirmed: L10n.t("已确认", "Confirmed")
        case .counting: L10n.t("计数中", "Counting")
        }
    }

    private var directionColor: Color {
        sequence.direction == .top ? .red : .green
    }
}
