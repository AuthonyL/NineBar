import Testing
@testable import NineBarCore

@Suite("HealthCheckRunnerTests")
struct HealthCheckRunnerTests {
    @Test("healthy open market validates both live inputs and reports the oldest age")
    func healthyOpenMarket() async throws {
        let now = isoDate("2026-09-01T14:05:05+08:00")
        let source = HealthCheckMarketDataSource(
            quoteResult: .success(healthyQuotes(now: now)),
            seriesByDay: [
                "2026-09-01": healthySeriesResults(
                    tradingDay: "2026-09-01",
                    latestTime: "14:04",
                    receivedAt: now
                )
            ]
        )
        let runner = HealthCheckRunner(marketData: source, now: { now })

        let report = await runner.run()

        #expect(report == HealthCheckReport(
            ok: true,
            marketOpen: true,
            quoteCount: 2,
            minuteSeriesCount: 2,
            latestAgeSeconds: 65,
            errors: []
        ))
    }

    @Test("open market rejects data older than seventy-five seconds")
    func staleOpenMarket() async throws {
        let now = isoDate("2026-09-01T14:05:05+08:00")
        let source = HealthCheckMarketDataSource(
            quoteResult: .success(healthyQuotes(
                now: now,
                sourceUpdatedAt: now.addingTimeInterval(-76)
            )),
            seriesByDay: [
                "2026-09-01": healthySeriesResults(
                    tradingDay: "2026-09-01",
                    latestTime: "14:04",
                    receivedAt: now
                )
            ]
        )

        let report = await HealthCheckRunner(marketData: source, now: { now }).run()

        #expect(report.ok == false)
        #expect(report.marketOpen)
        #expect(report.latestAgeSeconds == 76)
        #expect(report.errors == [.stale])
        #expect(await source.requestedTradingDayLabels == ["2026-09-01", "2026-09-01"])
    }

    @Test("exactly seventy-five seconds remains fresh during open market")
    func exactFreshnessBoundaryIsAccepted() async throws {
        let now = isoDate("2026-09-01T14:05:05+08:00")
        let source = HealthCheckMarketDataSource(
            quoteResult: .success(healthyQuotes(
                now: now,
                sourceUpdatedAt: now.addingTimeInterval(-75)
            )),
            seriesByDay: [
                "2026-09-01": healthySeriesResults(
                    tradingDay: "2026-09-01",
                    latestTime: "14:04",
                    receivedAt: now
                )
            ]
        )

        let report = await HealthCheckRunner(marketData: source, now: { now }).run()

        #expect(report.ok)
        #expect(report.latestAgeSeconds == 75)
        #expect(report.errors.isEmpty)
    }

    @Test("accepts the bounded receipt-time skew introduced while a live check is running")
    func boundedReceiptTimeSkewIsAccepted() async throws {
        let now = isoDate("2026-09-01T14:05:05+08:00")
        let receivedAt = now.addingTimeInterval(5)
        let source = HealthCheckMarketDataSource(
            quoteResult: .success(healthyQuotes(now: now)),
            seriesByDay: [
                "2026-09-01": healthySeriesResults(
                    tradingDay: "2026-09-01",
                    latestTime: "14:04",
                    receivedAt: receivedAt
                )
            ]
        )

        let report = await HealthCheckRunner(marketData: source, now: { now }).run()

        #expect(report.ok)
        #expect(report.latestAgeSeconds == 65)
        #expect(report.errors.isEmpty)
    }

    @Test("outside hours tries today then resolves the prior actual trading day")
    func outsideHoursPriorTradingDay() async throws {
        let now = isoDate("2026-09-01T19:00:00+08:00")
        let source = HealthCheckMarketDataSource(
            quoteResult: .success(healthyQuotes(
                now: now,
                sourceUpdatedAt: isoDate("2026-08-31T15:00:00+08:00")
            )),
            seriesByDay: [
                "2026-09-01": healthFailureResults(.wrongTradingDayPayload),
                "2026-08-31": healthySeriesResults(
                    tradingDay: "2026-08-31",
                    latestTime: "14:59",
                    receivedAt: now
                )
            ]
        )

        let report = await HealthCheckRunner(marketData: source, now: { now }).run()

        #expect(report.ok)
        #expect(report.marketOpen == false)
        #expect(report.minuteSeriesCount == 2)
        #expect(await source.requestedTradingDayLabels == [
            "2026-09-01", "2026-09-01", "2026-08-31", "2026-08-31"
        ])
    }

    @Test("a nominal open-session holiday resolves the prior actual trading day as closed")
    func nominalSessionHolidayUsesPriorTradingDay() async throws {
        let now = isoDate("2026-09-01T14:05:05+08:00")
        let source = HealthCheckMarketDataSource(
            quoteResult: .success(healthyQuotes(now: now)),
            seriesByDay: [
                "2026-09-01": healthFailureResults(.wrongTradingDayPayload),
                "2026-08-31": healthySeriesResults(
                    tradingDay: "2026-08-31",
                    latestTime: "14:59",
                    receivedAt: now
                )
            ]
        )

        let report = await HealthCheckRunner(marketData: source, now: { now }).run()

        #expect(report.ok)
        #expect(report.marketOpen == false)
        #expect(report.minuteSeriesCount == 2)
        #expect(report.errors.isEmpty)
        #expect(await source.requestedTradingDayLabels == [
            "2026-09-01", "2026-09-01", "2026-08-31", "2026-08-31"
        ])
    }

    @Test("old-day success returned for today cannot pass as an open session")
    func oldDaySuccessCannotPassAsOpen() async throws {
        let now = isoDate("2026-09-01T14:05:05+08:00")
        let source = HealthCheckMarketDataSource(
            quoteResult: .success(healthyQuotes(now: now)),
            seriesByDay: [
                "2026-09-01": healthySeriesResults(
                    tradingDay: "2026-08-31",
                    latestTime: "14:59",
                    receivedAt: now
                )
            ]
        )

        let report = await HealthCheckRunner(marketData: source, now: { now }).run()

        #expect(report.ok == false)
        #expect(report.marketOpen)
        #expect(report.minuteSeriesCount == 0)
        #expect(report.errors == [.invalidMinuteSeries, .minuteSeriesCount])
        #expect(await source.requestedTradingDayLabels == ["2026-09-01", "2026-09-01"])
    }

    @Test("a source-derived prior close outside the minute range remains valid OHLC input")
    func derivedPriorCloseGapIsAccepted() async throws {
        let now = isoDate("2026-09-01T14:05:05+08:00")
        let source = HealthCheckMarketDataSource(
            quoteResult: .success(healthyQuotes(now: now)),
            seriesByDay: [
                "2026-09-01": healthySeriesResults(
                    tradingDay: "2026-09-01",
                    latestTime: "14:04",
                    receivedAt: now,
                    openOffset: 10
                )
            ]
        )

        let report = await HealthCheckRunner(marketData: source, now: { now }).run()

        #expect(report.ok)
        #expect(report.errors.isEmpty)
    }

    @Test("partial quote and series results fail closed without hiding their counts")
    func partialResultsFailClosed() async throws {
        let now = isoDate("2026-09-01T14:05:05+08:00")
        let quotes = Array(healthyQuotes(now: now).prefix(1))
        let series = healthySeriesResults(
            tradingDay: "2026-09-01",
            latestTime: "14:04",
            receivedAt: now
        )
        let source = HealthCheckMarketDataSource(
            quoteResult: .success(quotes),
            seriesByDay: [
                "2026-09-01": [
                    HealthCheckRunner.shanghaiStock.id: series[HealthCheckRunner.shanghaiStock.id]!,
                    HealthCheckRunner.shenzhenETF.id: .failure(.malformedPayload)
                ],
                "2026-08-31": healthySeriesResults(
                    tradingDay: "2026-08-31",
                    latestTime: "14:59",
                    receivedAt: now
                )
            ]
        )

        let report = await HealthCheckRunner(marketData: source, now: { now }).run()

        #expect(report.ok == false)
        #expect(report.quoteCount == 1)
        #expect(report.minuteSeriesCount == 1)
        #expect(report.errors == [.malformedData, .minuteSeriesCount, .quoteCount])
        #expect(report.marketOpen)
        #expect(await source.requestedTradingDayLabels == ["2026-09-01", "2026-09-01"])
    }

    @Test("production-source malformed errors map to a closed safe category")
    func malformedSourceValuesAreRejectedSafely() async throws {
        let now = isoDate("2026-09-01T14:05:05+08:00")
        let source = HealthCheckMarketDataSource(
            quoteResult: .failure(.malformedPayload),
            seriesByDay: ["2026-09-01": healthFailureResults(.malformedPayload)]
        )

        let report = await HealthCheckRunner(marketData: source, now: { now }).run()

        #expect(report.ok == false)
        #expect(report.quoteCount == 0)
        #expect(report.minuteSeriesCount == 0)
        #expect(report.latestAgeSeconds == nil)
        #expect(report.errors == [.malformedData, .minuteSeriesCount, .quoteUnavailable])
    }

    @Test("encoded report has only approved keys and cannot leak raw source details")
    func encodedReportIsSafe() throws {
        let report = HealthCheckReport(
            ok: false,
            marketOpen: false,
            quoteCount: 0,
            minuteSeriesCount: 0,
            latestAgeSeconds: nil,
            errors: [.sourceUnavailable]
        )

        let json = try encodedHealthReport(report)

        #expect(try healthJSONKeys(json) == [
            "errors", "latestAgeSeconds", "marketOpen", "minuteSeriesCount", "ok", "quoteCount"
        ])
        #expect(json.contains("\"latestAgeSeconds\":null"))
        #expect(!json.contains("http"))
        #expect(!json.contains("token"))
        #expect(!json.contains("600519"))
        #expect(!json.contains("159915"))
    }
}
