import Foundation
@testable import NineBarCore

/// A watchlist file path in a fresh temporary directory. The directory itself is created only
/// when requested, so tests can check that saving creates it.
func temporaryWatchlistURL(createDirectory: Bool = true) throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("NineBarWatchlistTests-\(UUID().uuidString)", isDirectory: true)
    if createDirectory {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    return directory.appendingPathComponent("watchlist.json")
}

func writeWatchlistDocument(_ value: WatchlistDocument, to url: URL) throws {
    try JSONEncoder().encode(value).write(to: url, options: .atomic)
}

func watchlistSchemaVersion(at url: URL) throws -> Int? {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    return (object as? [String: Any])?["schemaVersion"] as? Int
}
