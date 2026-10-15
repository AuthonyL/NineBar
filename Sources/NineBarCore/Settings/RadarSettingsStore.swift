import Foundation

public struct SettingsDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public var settings: RadarSettings

    public init(schemaVersion: Int = Self.currentSchemaVersion, settings: RadarSettings) {
        self.schemaVersion = schemaVersion
        self.settings = settings
    }
}

public enum SettingsError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case malformedDocument
    case unreadable
}

public protocol RadarSettingsStoring: Sendable {
    func load() async throws -> RadarSettings
    func save(_ value: RadarSettings) async throws
}

public final class RadarSettingsStore: RadarSettingsStoring, @unchecked Sendable {
    public let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> RadarSettings {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return RadarSettings()
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw SettingsError.unreadable
        }

        let version: Int
        do {
            version = try JSONDecoder().decode(SettingsVersion.self, from: data).schemaVersion
        } catch {
            throw SettingsError.malformedDocument
        }
        guard (1...SettingsDocument.currentSchemaVersion).contains(version) else {
            throw SettingsError.unsupportedVersion(version)
        }

        let document: SettingsDocument
        do {
            document = try JSONDecoder().decode(SettingsDocument.self, from: data)
        } catch {
            throw SettingsError.malformedDocument
        }

        guard version < SettingsDocument.currentSchemaVersion else { return document.settings }

        do {
            try writeUnlocked(document.settings)
        } catch {
            throw SettingsError.unreadable
        }
        return document.settings
    }

    public func save(_ value: RadarSettings) throws {
        lock.lock()
        defer { lock.unlock() }
        do {
            try writeUnlocked(value)
        } catch {
            throw SettingsError.unreadable
        }
    }

    private func writeUnlocked(_ value: RadarSettings) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(SettingsDocument(settings: value))
        try data.write(to: fileURL, options: .atomic)
    }
}

private struct SettingsVersion: Decodable {
    let schemaVersion: Int
}
