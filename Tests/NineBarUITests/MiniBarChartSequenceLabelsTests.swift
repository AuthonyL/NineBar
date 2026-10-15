import Testing
@testable import NineBarUI
import NineBarCore

@Suite("MiniBarChart sequence labels")
struct MiniBarChartSequenceLabelsTests {
    @Test("maps the complete confirmed sequence to labels one through nine")
    func mapsCompleteSequence() {
        let bars = chartBars(["09:30", "09:31", "09:32", "09:33", "09:34", "09:35", "09:36", "09:37", "09:38"])
        let sequence = chartSequence(count: 9, phase: .confirmed, start: "09:30", lastEnd: "09:39")

        let labels = MiniBarChartSequenceLabels.labels(for: bars, sequence: sequence)

        #expect(labels.map(\.value) == [1, 2, 3, 4, 5, 6, 7, 8, 9])
    }

    @Test("preserves original label numbers when the sequence start is outside recent bars")
    func preservesLabelsAfterChartTruncation() {
        let recentBars = chartBars(["09:33", "09:34", "09:35", "09:36", "09:37", "09:38"])
        let sequence = chartSequence(count: 9, phase: .confirmed, start: "09:30", lastEnd: "09:39")

        let labels = MiniBarChartSequenceLabels.labels(for: recentBars, sequence: sequence)

        #expect(labels.map(\.value) == [4, 5, 6, 7, 8, 9])
    }

    @Test("returns no labels for an empty chart")
    func returnsNoLabelsForEmptyBars() {
        let sequence = chartSequence(count: 9, phase: .confirmed, start: "09:30", lastEnd: "09:39")

        #expect(MiniBarChartSequenceLabels.labels(for: [], sequence: sequence).isEmpty)
    }

    @Test("does not fabricate a confirmed ninth label for an open candidate bar")
    func excludesOpenCandidateBar() {
        let bars = chartBars(
            ["09:30", "09:31", "09:32", "09:33", "09:34", "09:35", "09:36", "09:37", "09:38"],
            openAt: "09:38"
        )
        let sequence = chartSequence(count: 9, phase: .candidate, start: "09:30", lastEnd: "09:39")

        let labels = MiniBarChartSequenceLabels.labels(for: bars, sequence: sequence)

        #expect(labels.map(\.value) == [1, 2, 3, 4, 5, 6, 7, 8])
    }

    @Test("excludes bars outside the sequence boundary")
    func excludesBoundaryBars() {
        let bars = chartBars(["09:29", "09:30", "09:31", "09:32", "09:33", "09:34", "09:35", "09:36", "09:37", "09:38", "09:39"])
        let sequence = chartSequence(count: 9, phase: .confirmed, start: "09:30", lastEnd: "09:39")

        let labels = MiniBarChartSequenceLabels.labels(for: bars, sequence: sequence)

        #expect(labels.map(\.value) == [1, 2, 3, 4, 5, 6, 7, 8, 9])
    }
}
