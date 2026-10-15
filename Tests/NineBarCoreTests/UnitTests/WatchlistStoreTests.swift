import Testing
@testable import NineBarCore

@Suite("WatchlistStoreTests")
struct WatchlistStoreTests {
    @Test("a missing file is a first launch and returns the starter list")
    func missingFileReturnsStarterList() async throws {
        let store = WatchlistStore(
            fileURL: try temporaryWatchlistURL(),
            starterInstruments: WatchlistStore.starterInstruments
        )

        #expect(try await store.load().map(\.id) == ["sh.510300"])
        #expect(try await WatchlistStore(fileURL: try temporaryWatchlistURL()).load().isEmpty)
    }

    @Test("the starter list contains only the CSI 300 ETF and is a supported code")
    func starterListIsCSI300ETF() {
        #expect(WatchlistStore.starterInstruments.map(\.id) == ["sh.510300"])
        #expect(WatchlistStore.starterInstruments.allSatisfy {
            SupportedInstrumentClassifier.instrument(symbol: $0.symbol, name: $0.name) == $0
        })
    }

    @Test("saves after creating the parent directory and loads the same symbols")
    func roundTripCreatesParentDirectory() async throws {
        let url = try temporaryWatchlistURL(createDirectory: false)
        let store = WatchlistStore(fileURL: url)
        let expected = [shETF("513500"), sh("600519")]

        try await store.save(expected)

        #expect(try await store.load() == expected)
        #expect(try watchlistSchemaVersion(at: url) == WatchlistDocument.currentSchemaVersion)
    }

    @Test("a saved empty list stays empty instead of returning the starter list")
    func savingEmptyListClears() async throws {
        let store = WatchlistStore(
            fileURL: try temporaryWatchlistURL(),
            starterInstruments: WatchlistStore.starterInstruments
        )
        try await store.save([sh("600519")])

        try await store.save([])

        #expect(try await store.load().isEmpty)
    }

    @Test("loading reclassifies saved codes, drops unsupported ones and rewrites the file")
    func loadSanitizesAndRewrites() async throws {
        let url = try temporaryWatchlistURL()
        let saved = WatchlistDocument(instruments: [
            Instrument(symbol: "600519", name: "贵州茅台", exchange: .shenzhen, kind: .etf),
            Instrument(symbol: "159915", name: "创业板ETF易方达", exchange: .shanghai, kind: .stock),
            Instrument(symbol: "110000", name: "无效债券", exchange: .shanghai, kind: .stock),
            Instrument(symbol: "600519", name: "重复", exchange: .shanghai, kind: .stock)
        ])
        try writeWatchlistDocument(saved, to: url)
        let store = WatchlistStore(fileURL: url)

        let loaded = try await store.load()

        #expect(loaded.map(\.id) == ["sh.600519", "sz.159915"])
        #expect(loaded.map(\.kind) == [.stock, .etf])
        #expect(loaded.map(\.name) == ["贵州茅台", "创业板ETF易方达"])
        #expect(try await WatchlistStore(fileURL: url).load() == loaded)
    }

    @Test("a future schema is rejected without changing the user file")
    func futureSchemaIsRejectedWithoutChangingTheFile() async throws {
        let url = try temporaryWatchlistURL()
        let original = "{\"schemaVersion\":2,\"instruments\":[]}"
        try writeTestText(original, to: url)
        let store = WatchlistStore(fileURL: url)

        await #expect(throws: WatchlistStoreError.unsupportedVersion(2)) {
            try await store.load()
        }
        #expect(try readTestText(at: url) == original)
    }

    @Test("malformed JSON throws a typed error and remains intact")
    func malformedJSONRemainsIntact() async throws {
        let url = try temporaryWatchlistURL()
        try writeTestText("not-json", to: url)
        let store = WatchlistStore(fileURL: url)

        await #expect(throws: WatchlistStoreError.malformedDocument) {
            try await store.load()
        }
        #expect(try readTestText(at: url) == "not-json")
    }

    private func sh(_ symbol: String) -> Instrument {
        Instrument(symbol: symbol, name: symbol, exchange: .shanghai, kind: .stock)
    }

    private func shETF(_ symbol: String) -> Instrument {
        Instrument(symbol: symbol, name: symbol, exchange: .shanghai, kind: .etf)
    }
}
