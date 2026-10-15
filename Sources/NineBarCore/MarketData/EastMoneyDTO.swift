import Foundation

struct EastMoneyTrendsResponse: Decodable {
    let rc: Int?
    let data: EastMoneyTrendsData?
}

struct EastMoneyTrendsData: Decodable {
    let name: String?
    let preClose: Double?
    let trends: [String]?
}

struct EastMoneyQuotesResponse: Decodable {
    let rc: Int?
    let data: EastMoneyQuotesData?
}

struct EastMoneyQuotesData: Decodable {
    let diff: [EastMoneyQuoteRow]?
}

struct EastMoneyQuoteRow: Decodable {
    let price: Double?
    let symbol: String?
    let market: Int?
    let name: String?
    let sourceEpoch: Double?
    let volume: Double?
    let amount: Double?
    let high: Double?
    let low: Double?

    enum CodingKeys: String, CodingKey {
        case price = "f2"
        case symbol = "f12"
        case market = "f13"
        case name = "f14"
        case sourceEpoch = "f124"
        case volume = "f5"
        case amount = "f6"
        case high = "f15"
        case low = "f16"
    }
}
