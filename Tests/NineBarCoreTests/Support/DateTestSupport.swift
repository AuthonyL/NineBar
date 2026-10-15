import Foundation
@testable import NineBarCore

func shanghaiDate(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    _ hour: Int,
    _ minute: Int,
    _ second: Int = 0
) throws -> Date {
    var calendar = Calendar(identifier: .gregorian)
    guard let timeZone = TimeZone(identifier: "Asia/Shanghai") else {
        throw DateTestSupportError.missingShanghaiTimeZone
    }
    calendar.timeZone = timeZone
    guard let date = calendar.date(
        from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )
    ) else {
        throw DateTestSupportError.invalidDate
    }
    return date
}

private enum DateTestSupportError: Error {
    case missingShanghaiTimeZone
    case invalidDate
}

func isoDate(_ text: String) -> Date {
    let formatter = ISO8601DateFormatter()
    guard let date = formatter.date(from: text) else {
        fatalError("Invalid ISO-8601 test date: \(text)")
    }
    return date
}

func sh(_ symbol: String) -> Instrument {
    Instrument(symbol: symbol, name: symbol, exchange: .shanghai, kind: .stock)
}

func sz(_ symbol: String) -> Instrument {
    Instrument(symbol: symbol, name: symbol, exchange: .shenzhen, kind: .stock)
}

func shETF(_ symbol: String) -> Instrument {
    Instrument(symbol: symbol, name: symbol, exchange: .shanghai, kind: .etf)
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
    return url
}

func temporaryJSONURL() throws -> URL {
    try temporaryDirectory().appendingPathComponent("settings.json")
}

func temporarySQLiteURL() throws -> URL {
    try temporaryDirectory().appendingPathComponent("radar.sqlite")
}
