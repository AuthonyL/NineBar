public enum Exchange: String, Codable, Sendable, CaseIterable {
    case shanghai = "sh"
    case shenzhen = "sz"
}

public enum SecurityKind: String, Codable, Sendable {
    case stock
    case etf
}

public struct Instrument: Codable, Hashable, Identifiable, Sendable {
    public let symbol: String
    public var name: String
    public let exchange: Exchange
    public let kind: SecurityKind

    public init(symbol: String, name: String, exchange: Exchange, kind: SecurityKind) {
        self.symbol = symbol
        self.name = name
        self.exchange = exchange
        self.kind = kind
    }

    public var id: String {
        "\(exchange.rawValue).\(symbol)"
    }

    public var eastMoneySecID: String {
        "\(exchange == .shanghai ? 1 : 0).\(symbol)"
    }
}
