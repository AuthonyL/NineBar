import Testing
@testable import NineBarCore

@Suite("EastMoneyMarketDataSourceTests")
struct EastMoneyMarketDataSourceTests {
    @Test("minute requests fall back to the delayed EastMoney host after transport failure")
    func minuteRequestsFallBackAfterTransportFailure() async throws {
        let client = MinuteHostFallbackHTTPClient(data: try fixture("eastmoney-trends.json"))
        let source = EastMoneyMarketDataSource(
            client: client,
            now: { isoDate("2026-09-01T09:33:05+08:00") }
        )

        let series = try await source.fetchMinuteSeries(
            for: sh("600519"),
            tradingDay: isoDate("2026-09-01T00:00:00+08:00")
        )

        #expect(series.points.count == 3)
        #expect(await client.requestedHosts() == [
            "push2his.eastmoney.com",
            "push2delay.eastmoney.com"
        ])
    }

    @Test("quote requests ask EastMoney for decimal prices")
    func quoteRequestsAskForDecimalPrices() async throws {
        let client = URLRecordingHTTPClient(data: try fixture("eastmoney-quotes.json"))
        let source = EastMoneyMarketDataSource(client: client)

        _ = try await source.fetchQuotes(for: [sh("600519"), sz("300750")])

        #expect(await client.firstQueryValue(named: "fltt") == "2")
    }

    @Test("quote requests fall back to the delayed EastMoney host after transport failure")
    func quoteRequestsFallBackAfterTransportFailure() async throws {
        let client = QuoteHostFallbackHTTPClient(data: try fixture("eastmoney-quotes.json"))
        let source = EastMoneyMarketDataSource(client: client)

        let quotes = try await source.fetchQuotes(for: [sh("600519"), sz("300750")])

        #expect(quotes.map(\.price) == [1523.45, 235.60])
        #expect(await client.requestedHosts() == [
            "push2.eastmoney.com",
            "push2delay.eastmoney.com"
        ])
    }

    @Test("minute requests fall back after a retryable primary-host HTTP response")
    func minuteRequestsFallBackAfterHTTPFailure() async throws {
        let client = MinuteHostFallbackHTTPClient(
            data: try fixture("eastmoney-trends.json"),
            primaryStatusCode: 503
        )
        let source = EastMoneyMarketDataSource(client: client)

        let series = try await source.fetchMinuteSeries(
            for: sh("600519"),
            tradingDay: isoDate("2026-09-01T00:00:00+08:00")
        )

        #expect(series.points.count == 3)
        #expect(await client.requestedHosts() == [
            "push2his.eastmoney.com",
            "push2delay.eastmoney.com"
        ])
    }

    @Test("parses minute series using EastMoney OHLC fields")
    func parsesMinuteSeriesUsingEastMoneyOHLCFields() async throws {
        let client = FixtureHTTPClient(data: try fixture("eastmoney-trends.json"))
        let source = EastMoneyMarketDataSource(client: client, now: { isoDate("2026-09-01T09:33:05+08:00") })

        let series = try await source.fetchMinuteSeries(
            for: sh("600519"),
            tradingDay: isoDate("2026-09-01T00:00:00+08:00")
        )

        #expect(series.instrument.name == "样例股票")
        #expect(series.points.map(\.open) == [10.00, 10.01, 10.02])
        #expect(series.points.map(\.close) == [10.01, 10.02, 10.00])
    }

    @Test("parses the live EastMoney trend field order")
    func parsesLiveTrendFieldOrder() async throws {
        let source = EastMoneyMarketDataSource(
            client: FixtureHTTPClient(data: payload(
                #"{"rc":0,"data":{"name":"样例股票","preClose":10,"trends":["2026-09-01 09:30,9.95,9.95,9.95,9.95,100,995","2026-09-01 09:31,9.96,10.01,10.03,9.94,1000,10010"]}}"#
            ))
        )

        let point = try #require(await source.fetchMinuteSeries(
            for: sh("600519"),
            tradingDay: isoDate("2026-09-01T00:00:00+08:00")
        ).points.first)

        #expect(point.open == 9.96)
        #expect(point.close == 10.01)
        #expect(point.high == 10.03)
        #expect(point.low == 9.94)
        #expect(point.volume == 1000)
        #expect(point.amount == 10010)
    }

    @Test("normalizes EastMoney close markers into minute-bar starts and skips the opening snapshot")
    func normalizesLiveCloseMarkers() async throws {
        let source = EastMoneyMarketDataSource(
            client: FixtureHTTPClient(data: payload(
                #"{"rc":0,"data":{"name":"样例股票","preClose":10,"trends":["2026-09-01 09:30,9.95,9.95,9.95,9.95,100,995","2026-09-01 09:31,9.96,10.01,10.03,9.94,1000,10010","2026-09-01 11:30,10.01,10.02,10.04,10.00,800,8016","2026-09-01 13:01,10.02,10.03,10.05,10.01,900,9027","2026-09-01 15:00,10.03,10.04,10.06,10.02,1200,12048"]}}"#
            ))
        )

        let series = try await source.fetchMinuteSeries(
            for: sh("600519"),
            tradingDay: isoDate("2026-09-01T00:00:00+08:00")
        )

        #expect(series.points.map(\.timestamp) == [
            isoDate("2026-09-01T09:30:00+08:00"),
            isoDate("2026-09-01T11:29:00+08:00"),
            isoDate("2026-09-01T13:00:00+08:00"),
            isoDate("2026-09-01T14:59:00+08:00")
        ])
        #expect(series.points.map(\.open) == [9.96, 10.01, 10.02, 10.03])
    }

    @Test("rejects an empty successful payload")
    func rejectsEmptySuccessfulPayload() async {
        let source = EastMoneyMarketDataSource(
            client: FixtureHTTPClient(data: payload(#"{"rc":0,"data":null}"#))
        )

        await #expect(throws: MarketDataError.emptyPayload) {
            try await source.fetchMinuteSeries(
                for: sh("600519"),
                tradingDay: isoDate("2026-09-01T00:00:00+08:00")
            )
        }
    }

    @Test("rejects a minute row from another Shanghai trading day")
    func rejectsWrongTradingDay() async {
        let source = EastMoneyMarketDataSource(
            client: FixtureHTTPClient(data: payload(#"{"rc":0,"data":{"name":"样例股票","preClose":10,"trends":["2026-08-31 09:30,10.00,10.01,10.03,9.99,1000,10010"]}}"#))
        )

        await #expect(throws: MarketDataError.wrongTradingDayPayload) {
            try await source.fetchMinuteSeries(
                for: sh("600519"),
                tradingDay: isoDate("2026-09-01T00:00:00+08:00")
            )
        }
    }

    @Test("mixed current and wrong trading days are malformed, not a holiday absence")
    func rejectsMixedTradingDaysAsMalformed() async {
        let source = EastMoneyMarketDataSource(
            client: FixtureHTTPClient(data: payload(#"{"rc":0,"data":{"name":"样例股票","preClose":10,"trends":["2026-08-31 09:30,10.00,10.01,10.03,9.99,1000,10010","2026-09-01 09:31,10.01,10.02,10.04,10.00,800,8016"]}}"#))
        )

        await #expect(throws: MarketDataError.malformedPayload) {
            try await source.fetchMinuteSeries(
                for: sh("600519"),
                tradingDay: isoDate("2026-09-01T00:00:00+08:00")
            )
        }
    }

    @Test("rejects malformed minute values")
    func rejectsMalformedMinuteValues() async {
        let source = EastMoneyMarketDataSource(
            client: FixtureHTTPClient(data: payload(#"{"rc":0,"data":{"name":"样例股票","preClose":10,"trends":["2026-09-01 09:30,10.00,10.00,10.00,10.00,100,1000","2026-09-01 09:31,10.00,nan,10.03,9.99,1000,10010"]}}"#))
        )

        await #expect(throws: MarketDataError.malformedPayload) {
            try await source.fetchMinuteSeries(
                for: sh("600519"),
                tradingDay: isoDate("2026-09-01T00:00:00+08:00")
            )
        }
    }

    @Test("rejects minute closes outside their positive high-low range")
    func rejectsMinuteClosesOutsideRange() async {
        for row in [
            "2026-09-01 09:31,10.00,10.04,10.03,9.99,1000,10010",
            "2026-09-01 09:31,10.00,9.98,10.03,9.99,1000,10010"
        ] {
            let source = EastMoneyMarketDataSource(
                client: FixtureHTTPClient(data: payload(
                    #"{"rc":0,"data":{"name":"样例股票","preClose":10,"trends":["2026-09-01 09:30,10.00,10.00,10.00,10.00,100,1000","\#(row)"]}}"#
                ))
            )

            await #expect(throws: MarketDataError.malformedPayload) {
                try await source.fetchMinuteSeries(
                    for: sh("600519"),
                    tradingDay: isoDate("2026-09-01T00:00:00+08:00")
                )
            }
        }
    }

    @Test("allows a valid source open outside the previous-close range")
    func allowsValidSourceOpenOutsidePreviousCloseRange() async throws {
        let source = EastMoneyMarketDataSource(
            client: FixtureHTTPClient(data: payload(
                #"{"rc":0,"data":{"name":"样例股票","preClose":12,"trends":["2026-09-01 09:30,12,12,12,12,100,1200","2026-09-01 09:31,9.9,10,10.2,9.8,1000,10000"]}}"#
            ))
        )

        let point = try #require(await source.fetchMinuteSeries(
            for: sh("600519"),
            tradingDay: isoDate("2026-09-01T00:00:00+08:00")
        ).points.first)

        #expect(point.open == 9.9)
        #expect(point.close == 10)
    }

    @Test("maps quotes only when each requested exchange identity is returned")
    func mapsQuotesForRequestedExchangeIdentities() async throws {
        let source = EastMoneyMarketDataSource(
            client: FixtureHTTPClient(data: try fixture("eastmoney-quotes.json")),
            now: { isoDate("2026-09-01T09:33:05+08:00") }
        )

        let quotes = try await source.fetchQuotes(for: [sh("600519"), sz("300750")])

        #expect(quotes.map(\.instrumentID) == ["sh.600519", "sz.300750"])
        #expect(quotes.map(\.price) == [1523.45, 235.60])
        #expect(quotes.map(\.sourceUpdatedAt) == [
            sourceEpoch(1_788_226_385),
            sourceEpoch(1_788_226_385)
        ])
    }

    @Test("rejects quote rows with an unrequested exchange identity")
    func rejectsUnrequestedQuoteIdentity() async {
        let source = EastMoneyMarketDataSource(
            client: FixtureHTTPClient(data: payload(#"{"data":{"diff":[{"f2":10,"f12":"600519","f13":0,"f14":"错误市场","f124":1788226385}]}}"#))
        )

        await #expect(throws: MarketDataError.invalidResponse) {
            try await source.fetchQuotes(for: [sh("600519")])
        }
    }

    @Test("rejects a nonzero quote response code")
    func rejectsNonzeroQuoteResponseCode() async {
        let source = EastMoneyMarketDataSource(
            client: FixtureHTTPClient(data: payload(#"{"rc":1,"data":{"diff":[{"f2":10,"f12":"600519","f13":1,"f14":"样例股票","f124":1788226385}]}}"#))
        )

        await #expect(throws: MarketDataError.invalidResponse) {
            try await source.fetchQuotes(for: [sh("600519")])
        }
    }

    @Test("accepts optional zero quote high and low values")
    func acceptsOptionalZeroQuoteHighAndLowValues() async throws {
        let source = EastMoneyMarketDataSource(
            client: FixtureHTTPClient(data: payload(#"{"data":{"diff":[{"f2":10,"f5":1,"f6":2,"f12":"600519","f13":1,"f14":"样例股票","f15":0,"f16":0,"f124":1788226385}]}}"#))
        )

        let quote = try await source.fetchQuotes(for: [sh("600519")]).first

        #expect(quote?.price == 10)
        #expect(quote?.high == 10)
        #expect(quote?.low == 10)
    }

    @Test("rejects live prices outside positive quote ranges")
    func rejectsLivePricesOutsideQuoteRange() async {
        for json in [
            #"{"data":{"diff":[{"f2":10.2,"f12":"600519","f13":1,"f14":"样例股票","f15":10.1,"f16":9.9,"f124":1788226385}]}}"#,
            #"{"data":{"diff":[{"f2":9.8,"f12":"600519","f13":1,"f14":"样例股票","f15":10.1,"f16":9.9,"f124":1788226385}]}}"#
        ] {
            let source = EastMoneyMarketDataSource(
                client: FixtureHTTPClient(data: payload(json))
            )

            await #expect(throws: MarketDataError.malformedPayload) {
                try await source.fetchQuotes(for: [sh("600519")])
            }
        }
    }

    @Test("rejects duplicate quote requests without trapping")
    func rejectsDuplicateQuoteRequestsWithoutTrapping() async {
        let source = EastMoneyMarketDataSource(
            client: FixtureHTTPClient(data: payload(#"{"data":{"diff":[]}}"#))
        )
        let instrument = sh("600519")

        await #expect(throws: MarketDataError.invalidResponse) {
            try await source.fetchQuotes(for: [instrument, instrument])
        }
    }

    @Test("rejects non-success HTTP responses before parsing")
    func rejectsNonSuccessHTTPResponsesBeforeParsing() async throws {
        let payload = try fixture("eastmoney-trends.json")

        for statusCode in [429, 503] {
            let source = EastMoneyMarketDataSource(
                client: FixtureHTTPClient(data: payload, statusCode: statusCode)
            )

            await #expect(throws: MarketDataError.httpStatus(statusCode)) {
                try await source.fetchMinuteSeries(
                    for: sh("600519"),
                    tradingDay: isoDate("2026-09-01T00:00:00+08:00")
                )
            }
        }
    }

    @Test("retries transport failures with bounded delays")
    func retriesTransportFailuresWithBoundedDelays() async throws {
        let client = FailingThenSucceedingHTTPClient(failuresBeforeSuccess: 2)
        let sleeper = RecordingSleeper()
        let retrying = RetryingHTTPClient(client: client, sleeper: sleeper)

        _ = try await retrying.get(fixtureURL())

        #expect(await client.attempts == 3)
        #expect(await sleeper.durations == [.milliseconds(200), .milliseconds(800)])
    }

    @Test("retries throttled and server HTTP responses with bounded delays")
    func retriesThrottledAndServerHTTPResponsesWithBoundedDelays() async throws {
        let client = StatusSequenceHTTPClient(statusCodes: [429, 503, 200])
        let sleeper = RecordingSleeper()
        let retrying = RetryingHTTPClient(client: client, sleeper: sleeper)

        _ = try await retrying.get(fixtureURL())

        #expect(await client.attempts == 3)
        #expect(await sleeper.durations == [.milliseconds(200), .milliseconds(800)])
    }

    @Test("does not retry cancellation errors")
    func doesNotRetryCancellationErrors() async {
        let client = CancellationHTTPClient()
        let sleeper = RecordingSleeper()
        let retrying = RetryingHTTPClient(client: client, sleeper: sleeper)

        await #expect(throws: CancellationError.self) {
            try await retrying.get(fixtureURL())
        }

        #expect(await client.attempts == 1)
        #expect(await sleeper.durations.isEmpty)
    }

    @Test("normalizes URL-session cancellation without retrying or sleeping")
    func normalizesURLSessionCancellationWithoutRetrying() async {
        for shape in URLCancellationErrorShape.allCases {
            let client = URLCancellationHTTPClient(shape: shape)
            let sleeper = RecordingSleeper()
            let retrying = RetryingHTTPClient(client: client, sleeper: sleeper)

            await #expect(throws: CancellationError.self) {
                try await retrying.get(fixtureURL())
            }

            #expect(await client.attempts == 1)
            #expect(await sleeper.durations.isEmpty)
        }
    }

    @Test("does not retry non-transport errors")
    func doesNotRetryNonTransportErrors() async {
        let client = UnexpectedErrorHTTPClient()
        let sleeper = RecordingSleeper()
        let retrying = RetryingHTTPClient(client: client, sleeper: sleeper)

        await #expect(throws: TestHTTPClientError.unexpected) {
            try await retrying.get(fixtureURL())
        }

        #expect(await client.attempts == 1)
        #expect(await sleeper.durations.isEmpty)
    }
}
