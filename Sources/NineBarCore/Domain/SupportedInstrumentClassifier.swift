public enum SupportedInstrumentClassifier {
    public static func instrument(symbol: String, name: String) -> Instrument? {
        guard symbol.utf8.count == 6,
              symbol.utf8.allSatisfy({ (48...57).contains($0) }) else {
            return nil
        }

        guard let code = Int(symbol) else { return nil }
        if shanghaiStockRanges.contains(where: { $0.contains(code) }) {
            return Instrument(symbol: symbol, name: name, exchange: .shanghai, kind: .stock)
        }
        if shenzhenStockRanges.contains(where: { $0.contains(code) }) {
            return Instrument(symbol: symbol, name: name, exchange: .shenzhen, kind: .stock)
        }
        if shanghaiETFRanges.contains(where: { $0.contains(code) }) {
            return Instrument(symbol: symbol, name: name, exchange: .shanghai, kind: .etf)
        }
        if shenzhenETFRanges.contains(where: { $0.contains(code) }) {
            return Instrument(symbol: symbol, name: name, exchange: .shenzhen, kind: .etf)
        }
        return nil
    }

    private static let shanghaiStockRanges: [ClosedRange<Int>] = [
        600_000...601_999,
        603_000...603_999,
        605_000...605_999,
        688_000...688_999
    ]
    private static let shenzhenStockRanges: [ClosedRange<Int>] = [
        1...999,
        1_200...4_999,
        300_000...309_799
    ]
    private static let shanghaiETFRanges: [ClosedRange<Int>] = [
        510_000...513_999,
        515_000...518_999,
        520_500...520_999,
        526_000...526_999,
        530_000...530_999,
        551_000...551_999,
        560_000...563_999,
        565_000...567_999,
        581_000...581_999,
        587_000...589_999
    ]
    private static let shenzhenETFRanges: [ClosedRange<Int>] = [
        158_000...159_899,
        159_901...159_999
    ]
}
