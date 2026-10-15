import Foundation

public enum DiagnosticComponent: String, Codable, CaseIterable, Sendable {
    case coordinator
    case watchlist
    case marketData
    case persistence
    case notification
    case settings
}

public enum DiagnosticErrorCategory: String, Codable, CaseIterable, Sendable {
    case network
    case unavailable
    case malformedData
    case storage
    case permission
    case configuration
    case unknown

    public var displayText: String {
        switch self {
        case .network: L10n.t("网络异常", "Network error")
        case .unavailable: L10n.t("服务不可用", "Service unavailable")
        case .malformedData: L10n.t("数据格式异常", "Malformed data")
        case .storage: L10n.t("本地存储异常", "Local storage error")
        case .permission: L10n.t("系统权限异常", "System permission error")
        case .configuration: L10n.t("配置异常", "Configuration error")
        case .unknown: L10n.t("未知异常", "Unknown error")
        }
    }
}

public protocol DiagnosticLogging: Sendable {
    func record(
        timestamp: Date,
        component: DiagnosticComponent,
        errorCategory: DiagnosticErrorCategory,
        instrument: Instrument?
    ) async
}

public protocol DiagnosticReading: Sendable {
    func recentErrorCategories() async -> [DiagnosticErrorCategory]
}

public protocol StorageMaintaining: Sendable {
    func storageUsageBytes() async -> Int64
}

public actor RotatingLogger: DiagnosticLogging, DiagnosticReading, StorageMaintaining {
    private let directoryURL: URL
    private let maximumFileBytes: Int
    private let maximumFileCount: Int
    private let fileManager: FileManager

    public init(
        directoryURL: URL,
        maximumFileBytes: Int = 1_024 * 1_024,
        maximumFileCount: Int = 5,
        fileManager: FileManager = .default
    ) {
        precondition(maximumFileBytes > 0)
        precondition(maximumFileCount > 0)
        self.directoryURL = directoryURL
        self.maximumFileBytes = maximumFileBytes
        self.maximumFileCount = maximumFileCount
        self.fileManager = fileManager
    }

    public func log(
        timestamp: Date,
        component: DiagnosticComponent,
        errorCategory: DiagnosticErrorCategory,
        instrument: Instrument? = nil
    ) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let line = try encodedLine(
            timestamp: timestamp,
            component: component,
            errorCategory: errorCategory,
            instrument: instrument
        )
        let current = currentFileURL
        let existingSize = try fileSize(at: current)
        if existingSize > 0, existingSize + line.count > maximumFileBytes {
            try rotateFiles()
        }
        if !fileManager.fileExists(atPath: current.path) {
            fileManager.createFile(atPath: current.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: current)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    public func record(
        timestamp: Date,
        component: DiagnosticComponent,
        errorCategory: DiagnosticErrorCategory,
        instrument: Instrument?
    ) {
        try? log(
            timestamp: timestamp,
            component: component,
            errorCategory: errorCategory,
            instrument: instrument
        )
    }

    public func recentErrorCategories() -> [DiagnosticErrorCategory] {
        let entries = logFileURLsOldestFirst().flatMap { url -> [DiagnosticLogLine] in
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else {
                return []
            }
            return text.split(separator: "\n").compactMap {
                try? JSONDecoder().decode(DiagnosticLogLine.self, from: Data($0.utf8))
            }
        }
        return entries.suffix(5).reversed().map(\.errorCategory)
    }

    public func storageUsageBytes() -> Int64 {
        logFileURLsOldestFirst().reduce(0) { partial, url in
            partial + Int64((try? fileSize(at: url)) ?? 0)
        }
    }

    private var currentFileURL: URL {
        directoryURL.appendingPathComponent("radar.log")
    }

    private func rotatedFileURL(_ index: Int) -> URL {
        directoryURL.appendingPathComponent("radar.\(index).log")
    }

    private func encodedLine(
        timestamp: Date,
        component: DiagnosticComponent,
        errorCategory: DiagnosticErrorCategory,
        instrument: Instrument?
    ) throws -> Data {
        var data = try JSONEncoder().encode(DiagnosticLogLine(
            timestamp: timestamp.timeIntervalSince1970,
            component: component,
            errorCategory: errorCategory,
            instrumentID: instrument?.id
        ))
        data.append(0x0A)
        return data
    }

    private func rotateFiles() throws {
        if maximumFileCount == 1 {
            try? fileManager.removeItem(at: currentFileURL)
            return
        }

        try? fileManager.removeItem(at: rotatedFileURL(maximumFileCount - 1))
        if maximumFileCount > 2 {
            for index in stride(from: maximumFileCount - 2, through: 1, by: -1) {
                let source = rotatedFileURL(index)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                try fileManager.moveItem(at: source, to: rotatedFileURL(index + 1))
            }
        }
        guard fileManager.fileExists(atPath: currentFileURL.path) else { return }
        try fileManager.moveItem(at: currentFileURL, to: rotatedFileURL(1))
    }

    private func logFileURLsOldestFirst() -> [URL] {
        let rotated = (1..<maximumFileCount).reversed().map(rotatedFileURL)
        return (rotated + [currentFileURL]).filter { fileManager.fileExists(atPath: $0.path) }
    }

    private func fileSize(at url: URL) throws -> Int {
        guard fileManager.fileExists(atPath: url.path) else { return 0 }
        return (try fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    }
}

public actor StorageMaintenanceService: StorageMaintaining {
    private let databaseURL: URL
    private let logger: any StorageMaintaining
    private let fileManager: FileManager

    public init(
        databaseURL: URL,
        logger: any StorageMaintaining,
        fileManager: FileManager = .default
    ) {
        self.databaseURL = databaseURL
        self.logger = logger
        self.fileManager = fileManager
    }

    public func storageUsageBytes() async -> Int64 {
        let databaseFiles = [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm")
        ]
        let databaseBytes = databaseFiles.reduce(Int64(0)) { partial, url in
            let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            return partial + size
        }
        let logBytes = await logger.storageUsageBytes()
        return databaseBytes + logBytes
    }
}

private struct DiagnosticLogLine: Codable, Sendable {
    let timestamp: TimeInterval
    let component: DiagnosticComponent
    let errorCategory: DiagnosticErrorCategory
    let instrumentID: String?

    enum CodingKeys: String, CodingKey {
        case timestamp
        case component
        case errorCategory
        case instrumentID
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(component, forKey: .component)
        try container.encode(errorCategory, forKey: .errorCategory)
        try container.encodeIfPresent(instrumentID, forKey: .instrumentID)
    }
}
