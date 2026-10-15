import Testing
@testable import NineBarCore

@Suite("RadarPipelineTests")
struct RadarPipelineTests {
    @Test("full fixture produces only the planned persisted signals and fresh delivery")
    func fullFixtureProducesOnlyExpectedSignals() async throws {
        let harness = try RadarPipelineHarness(fixture: "full-trading-session.json")

        try await harness.runToEnd()

        #expect(await harness.signalKeys == [
            "sh.600519|1|bottom|1788228000",
            "sh.600519|5|top|1788242700"
        ])
        #expect(await harness.duplicateNotificationCount == 0)
        #expect(await harness.deliveredNotificationKeys == [
            "sh.600519|5|top|1788240000|9"
        ])
        #expect(await harness.oneMinuteBarCount == 78)
        #expect(await harness.fiveMinuteBarCount == 15)
        #expect(await harness.historyKeys == [
            "sh.600519|5|top|1788242700",
            "sh.600519|1|bottom|1788228000"
        ])
        #expect(await harness.notificationLedgerKeys == [
            "sh.600519|1|bottom|1788227460|9",
            "sh.600519|5|top|1788240000|9"
        ])
        #expect(await harness.projectSQLiteSidecars.isEmpty)
        try await harness.cleanup()
    }
}
