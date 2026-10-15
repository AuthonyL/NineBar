import Testing
@testable import NineBarCore

@Suite("TradingSessionClockTests")
struct TradingSessionClockTests {
    private let clock = TradingSessionClock()

    @Test("lunch break is excluded from continuous trading")
    func lunchBreakIsNotTradingTime() throws {
        #expect(clock.isContinuousTrading(try shanghaiDate(2026, 9, 1, 11, 30)))
        #expect(!clock.isContinuousTrading(try shanghaiDate(2026, 9, 1, 11, 31)))
        #expect(clock.isContinuousTrading(try shanghaiDate(2026, 9, 1, 13, 0)))
    }

    @Test("five-minute bucket restarts at the lunch boundary")
    func fiveMinuteBucketDoesNotCrossLunch() throws {
        #expect(clock.minuteIndex(try shanghaiDate(2026, 9, 1, 13, 0)) == 120)
        #expect(clock.fiveMinuteBucket(try shanghaiDate(2026, 9, 1, 13, 0)) == 24)
        #expect(!clock.isMinuteBarStart(try shanghaiDate(2026, 9, 1, 11, 30)))
        #expect(!clock.isMinuteBarStart(try shanghaiDate(2026, 9, 1, 15, 0)))
    }

    @Test("only scheduled lunch transition makes minute bars consecutive")
    func consecutiveBarsAllowPlannedLunchButRejectMissingMinute() throws {
        #expect(
            clock.areConsecutive(
                previousStart: try shanghaiDate(2026, 9, 1, 11, 29),
                nextStart: try shanghaiDate(2026, 9, 1, 13, 0),
                timeframe: .oneMinute
            )
        )
        #expect(
            !clock.areConsecutive(
                previousStart: try shanghaiDate(2026, 9, 1, 10, 0),
                nextStart: try shanghaiDate(2026, 9, 1, 10, 2),
                timeframe: .oneMinute
            )
        )
    }
}
