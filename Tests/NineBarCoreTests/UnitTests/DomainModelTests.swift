import Testing
@testable import NineBarCore

@Suite("DomainModelTests")
struct DomainModelTests {
    @Test("instrument identity uses exchange and symbol")
    func instrumentIDAndEastMoneySecID() {
        let item = Instrument(symbol: "600519", name: "贵州茅台", exchange: .shanghai, kind: .stock)

        #expect(item.id == "sh.600519")
        #expect(item.eastMoneySecID == "1.600519")
    }

    @Test("supported instrument prefixes distinguish A stocks ETFs bonds and B shares")
    func supportedInstrumentPrefixesAreClosedAndTyped() {
        let supported = [
            ("600000", "sh.600000", SecurityKind.stock),
            ("688999", "sh.688999", SecurityKind.stock),
            ("000001", "sz.000001", SecurityKind.stock),
            ("001200", "sz.001200", SecurityKind.stock),
            ("004999", "sz.004999", SecurityKind.stock),
            ("302000", "sz.302000", SecurityKind.stock),
            ("309799", "sz.309799", SecurityKind.stock),
            ("510050", "sh.510050", SecurityKind.etf),
            ("520500", "sh.520500", SecurityKind.etf),
            ("520999", "sh.520999", SecurityKind.etf),
            ("526000", "sh.526000", SecurityKind.etf),
            ("526999", "sh.526999", SecurityKind.etf),
            ("530000", "sh.530000", SecurityKind.etf),
            ("530999", "sh.530999", SecurityKind.etf),
            ("551000", "sh.551000", SecurityKind.etf),
            ("551999", "sh.551999", SecurityKind.etf),
            ("565000", "sh.565000", SecurityKind.etf),
            ("567999", "sh.567999", SecurityKind.etf),
            ("581000", "sh.581000", SecurityKind.etf),
            ("581999", "sh.581999", SecurityKind.etf),
            ("587000", "sh.587000", SecurityKind.etf),
            ("587999", "sh.587999", SecurityKind.etf),
            ("589000", "sh.589000", SecurityKind.etf),
            ("158000", "sz.158000", SecurityKind.etf),
            ("158999", "sz.158999", SecurityKind.etf),
            ("159899", "sz.159899", SecurityKind.etf),
            ("159901", "sz.159901", SecurityKind.etf),
            ("159915", "sz.159915", SecurityKind.etf),
            ("159999", "sz.159999", SecurityKind.etf)
        ]

        for (symbol, id, kind) in supported {
            let instrument = SupportedInstrumentClassifier.instrument(symbol: symbol, name: symbol)
            #expect(instrument?.id == id)
            #expect(instrument?.kind == kind)
        }
        for symbol in [
            "001000", "001001", "001199", "110000", "123456", "159900",
            "200002", "309800", "309999", "520000", "520499", "550000",
            "564999", "568000", "689009", "900901", "999999"
        ] {
            #expect(SupportedInstrumentClassifier.instrument(symbol: symbol, name: symbol) == nil)
        }
    }
}
