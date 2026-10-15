import Foundation

public protocol WatchlistProviding: Sendable {
    func load() async throws -> [Instrument]
}

public protocol WatchlistStoring: WatchlistProviding {
    func save(_ instruments: [Instrument]) async throws
}

public struct WatchlistDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public var instruments: [Instrument]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        instruments: [Instrument]
    ) {
        self.schemaVersion = schemaVersion
        self.instruments = instruments
    }
}

public enum WatchlistStoreError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case malformedDocument
    case unreadable
}

/// The user's own watchlist. A missing file means a first launch, which shows the starter list
/// until the user saves their own; a saved empty list stays empty.
public actor WatchlistStore: WatchlistStoring {
    /// One broad, liquid ETF so a first launch has something to monitor: CSI 300 ETF (510300).
    public static let starterInstruments = [
        Instrument(symbol: "510300", name: "沪深300ETF", exchange: .shanghai, kind: .etf)
    ]

    public let fileURL: URL
    private let starterInstruments: [Instrument]

    public init(fileURL: URL, starterInstruments: [Instrument] = []) {
        self.fileURL = fileURL
        self.starterInstruments = starterInstruments
    }

    public init(filePath: String, starterInstruments: [Instrument] = []) {
        self.init(fileURL: URL(fileURLWithPath: filePath), starterInstruments: starterInstruments)
    }

    public func load() throws -> [Instrument] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return starterInstruments
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw WatchlistStoreError.unreadable
        }

        let version: Int
        do {
            version = try JSONDecoder().decode(WatchlistDocumentVersion.self, from: data)
                .schemaVersion
        } catch {
            throw WatchlistStoreError.malformedDocument
        }
        guard version == WatchlistDocument.currentSchemaVersion else {
            throw WatchlistStoreError.unsupportedVersion(version)
        }

        let document: WatchlistDocument
        do {
            document = try JSONDecoder().decode(WatchlistDocument.self, from: data)
        } catch {
            throw WatchlistStoreError.malformedDocument
        }
        let sanitized = Self.sanitized(document.instruments)
        if sanitized != document.instruments {
            do {
                try write(sanitized)
            } catch {
                throw WatchlistStoreError.unreadable
            }
        }
        return sanitized
    }

    public func save(_ instruments: [Instrument]) throws {
        do {
            try write(Self.sanitized(instruments))
        } catch {
            throw WatchlistStoreError.unreadable
        }
    }

    private func write(_ instruments: [Instrument]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(WatchlistDocument(instruments: instruments))
        try data.write(to: fileURL, options: .atomic)
    }

    /// Reclassifies each saved code, drops unsupported codes and keeps the first of any duplicates.
    private static func sanitized(_ instruments: [Instrument]) -> [Instrument] {
        var seenIDs: Set<String> = []
        return instruments.compactMap { saved -> Instrument? in
            guard let classified = SupportedInstrumentClassifier.instrument(
                symbol: saved.symbol,
                name: saved.name
            ), seenIDs.insert(classified.id).inserted else {
                return nil
            }
            return classified
        }
    }
}

private struct WatchlistDocumentVersion: Decodable {
    let schemaVersion: Int
}
