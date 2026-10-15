import Foundation

public protocol SignalStoring: Sendable {
    func insertIfAbsent(_ signal: ConfirmedSignal) async throws -> Bool
    func recordNotificationIfNew(key: String, createdAt: Date) async throws -> Bool
    func recent(limit: Int) async throws -> [ConfirmedSignal]
    func updatePerformance(using bars: [Bar]) async throws
    func prune(before: Date) async throws
}

public actor SignalRepository: SignalStoring {
    private let database: SQLiteDatabase

    public init(databaseURL: URL) throws {
        let database = try SQLiteDatabase(url: databaseURL)
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS signals (
              id TEXT PRIMARY KEY,
              instrument_id TEXT NOT NULL,
              timeframe INTEGER NOT NULL,
              direction TEXT NOT NULL,
              sequence_start INTEGER NOT NULL,
              last_bar_end INTEGER NOT NULL,
              last_close REAL NOT NULL,
              extreme_price REAL NOT NULL,
              source_updated_at INTEGER NOT NULL,
              return_5m REAL,
              return_15m REAL,
              return_30m REAL,
              return_60m REAL,
              return_5m_bar_end INTEGER,
              return_15m_bar_end INTEGER,
              return_30m_bar_end INTEGER,
              return_60m_bar_end INTEGER
            )
            """
        )
        try Self.migratePerformanceProvenance(in: database)
        try database.execute(
            """
            CREATE INDEX IF NOT EXISTS signals_series_end_idx
            ON signals (instrument_id, timeframe, last_bar_end)
            """
        )
        try database.execute(
            """
            CREATE INDEX IF NOT EXISTS signals_recent_idx
            ON signals (last_bar_end DESC, id DESC)
            """
        )
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS notification_events (
              key TEXT PRIMARY KEY,
              created_at INTEGER NOT NULL
            )
            """
        )
        self.database = database
    }

    public func insertIfAbsent(_ signal: ConfirmedSignal) throws -> Bool {
        let inserted = try database.query(
            """
            INSERT OR IGNORE INTO signals
              (id, instrument_id, timeframe, direction, sequence_start, last_bar_end,
               last_close, extreme_price, source_updated_at, return_5m, return_15m,
               return_30m, return_60m)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            RETURNING id
            """,
            bindings: [
                .text(signal.id),
                .text(signal.instrumentID),
                .integer(Int64(signal.timeframe.rawValue)),
                .text(signal.direction.rawValue),
                .integer(sqliteEpoch(signal.sequenceStart)),
                .integer(sqliteEpoch(signal.lastBarEnd)),
                .real(signal.lastClose),
                .real(signal.extremePrice),
                .integer(sqliteEpoch(signal.sourceUpdatedAt)),
                sqliteValue(signal.return5m),
                sqliteValue(signal.return15m),
                sqliteValue(signal.return30m),
                sqliteValue(signal.return60m)
            ],
            map: { try $0.text(0) }
        )
        return !inserted.isEmpty
    }

    public func recordNotificationIfNew(key: String, createdAt: Date) throws -> Bool {
        let inserted = try database.query(
            """
            INSERT OR IGNORE INTO notification_events (key, created_at)
            VALUES (?, ?)
            RETURNING key
            """,
            bindings: [.text(key), .integer(sqliteEpoch(createdAt))],
            map: { try $0.text(0) }
        )
        return !inserted.isEmpty
    }

    public func recent(limit: Int) throws -> [ConfirmedSignal] {
        guard limit > 0 else { return [] }
        return try database.query(
            """
            SELECT instrument_id, timeframe, direction, sequence_start, last_bar_end,
                   last_close, extreme_price, source_updated_at, return_5m, return_15m,
                   return_30m, return_60m
            FROM signals
            ORDER BY last_bar_end DESC, id DESC
            LIMIT ?
            """,
            bindings: [.integer(Int64(limit))],
            map: decodeSignal
        )
    }

    public func updatePerformance(using bars: [Bar]) throws {
        let barsBySeries = Dictionary(grouping: bars.filter(\.isClosed)) {
            PerformanceSeriesKey(instrumentID: $0.instrumentID, timeframe: $0.timeframe)
        }.mapValues { values in
            values.sorted {
                if $0.end == $1.end { return $0.start < $1.start }
                return $0.end < $1.end
            }
        }
        guard !barsBySeries.isEmpty else { return }

        let ranges = barsBySeries.compactMap { key, values -> PerformanceSeriesRange? in
            guard let first = values.first, let last = values.last else { return nil }
            return PerformanceSeriesRange(
                key: key,
                minimumBarEnd: first.end,
                maximumBarEnd: last.end
            )
        }.sorted { lhs, rhs in
            if lhs.key.instrumentID != rhs.key.instrumentID {
                return lhs.key.instrumentID < rhs.key.instrumentID
            }
            return lhs.key.timeframe.rawValue < rhs.key.timeframe.rawValue
        }

        var signals: [PerformanceSignal] = []
        for start in stride(from: 0, to: ranges.count, by: Self.performanceQueryChunkSize) {
            let chunk = ranges[start..<min(start + Self.performanceQueryChunkSize, ranges.count)]
            let placeholders = Array(repeating: "(?, ?, ?, ?)", count: chunk.count)
                .joined(separator: ", ")
            var bindings: [SQLiteValue] = []
            for range in chunk {
                bindings.append(.text(range.key.instrumentID))
                bindings.append(.integer(Int64(range.key.timeframe.rawValue)))
                bindings.append(.integer(sqliteEpoch(range.minimumBarEnd)))
                bindings.append(.integer(sqliteEpoch(range.maximumBarEnd)))
            }
            signals.append(contentsOf: try database.query(
                """
                WITH affected(instrument_id, timeframe, minimum_bar_end, maximum_bar_end) AS (
                  VALUES \(placeholders)
                )
                SELECT s.instrument_id, s.timeframe, s.direction, s.sequence_start, s.last_bar_end,
                       s.last_close, s.extreme_price, s.source_updated_at, s.return_5m, s.return_15m,
                       s.return_30m, s.return_60m, s.return_5m_bar_end, s.return_15m_bar_end,
                       s.return_30m_bar_end, s.return_60m_bar_end
                FROM signals AS s
                JOIN affected AS a
                  ON a.instrument_id = s.instrument_id AND a.timeframe = s.timeframe
                WHERE (s.return_5m IS NULL AND s.return_5m_bar_end IS NULL
                         AND s.last_bar_end <= a.maximum_bar_end - 300)
                   OR (s.return_15m IS NULL AND s.return_15m_bar_end IS NULL
                         AND s.last_bar_end <= a.maximum_bar_end - 900)
                   OR (s.return_30m IS NULL AND s.return_30m_bar_end IS NULL
                         AND s.last_bar_end <= a.maximum_bar_end - 1800)
                   OR (s.return_60m IS NULL AND s.return_60m_bar_end IS NULL
                         AND s.last_bar_end <= a.maximum_bar_end - 3600)
                   OR (s.return_5m_bar_end IS NOT NULL
                         AND s.last_bar_end <= a.maximum_bar_end - 300
                         AND a.minimum_bar_end <= s.return_5m_bar_end)
                   OR (s.return_15m_bar_end IS NOT NULL
                         AND s.last_bar_end <= a.maximum_bar_end - 900
                         AND a.minimum_bar_end <= s.return_15m_bar_end)
                   OR (s.return_30m_bar_end IS NOT NULL
                         AND s.last_bar_end <= a.maximum_bar_end - 1800
                         AND a.minimum_bar_end <= s.return_30m_bar_end)
                   OR (s.return_60m_bar_end IS NOT NULL
                         AND s.last_bar_end <= a.maximum_bar_end - 3600
                         AND a.minimum_bar_end <= s.return_60m_bar_end)
                """,
                bindings: bindings,
                map: decodePerformanceSignal
            ))
        }

        try database.transaction {
            for storedSignal in signals {
                let signal = storedSignal.signal
                let key = PerformanceSeriesKey(
                    instrumentID: signal.instrumentID,
                    timeframe: signal.timeframe
                )
                guard let matchingBars = barsBySeries[key] else { continue }
                let updatedPerformance = zip(Self.performanceHorizons, storedSignal.performance).map {
                    horizon, stored -> StoredPerformance in
                    let target = signal.lastBarEnd.addingTimeInterval(Double(horizon.minutes * 60))
                    let candidate = firstBar(endingAtOrAfter: target, in: matchingBars)
                    let matchedBar: Bar?
                    if let matchedBarEnd = stored.matchedBarEnd {
                        matchedBar = candidate.flatMap { $0.end <= matchedBarEnd ? $0 : nil }
                    } else if stored.value == nil {
                        matchedBar = candidate
                    } else {
                        matchedBar = nil
                    }
                    guard let matchedBar else { return stored }
                    return StoredPerformance(
                        value: (matchedBar.close / signal.lastClose) - 1,
                        matchedBarEnd: matchedBar.end
                    )
                }
                guard updatedPerformance != storedSignal.performance else { continue }
                try database.execute(
                    """
                    UPDATE signals
                    SET return_5m = ?, return_15m = ?, return_30m = ?, return_60m = ?,
                        return_5m_bar_end = ?, return_15m_bar_end = ?,
                        return_30m_bar_end = ?, return_60m_bar_end = ?
                    WHERE id = ?
                    """,
                    bindings: [
                        sqliteValue(updatedPerformance[0].value),
                        sqliteValue(updatedPerformance[1].value),
                        sqliteValue(updatedPerformance[2].value),
                        sqliteValue(updatedPerformance[3].value),
                        sqliteValue(updatedPerformance[0].matchedBarEnd),
                        sqliteValue(updatedPerformance[1].matchedBarEnd),
                        sqliteValue(updatedPerformance[2].matchedBarEnd),
                        sqliteValue(updatedPerformance[3].matchedBarEnd),
                        .text(signal.id)
                    ]
                )
            }
        }
    }

    private static let performanceQueryChunkSize = 200
    private static let performanceProvenanceMigration = "signal_performance_provenance_v1"

    private static let performanceHorizons = [
        PerformanceHorizon(minutes: 5, returnColumn: "return_5m", matchedBarEndColumn: "return_5m_bar_end"),
        PerformanceHorizon(minutes: 15, returnColumn: "return_15m", matchedBarEndColumn: "return_15m_bar_end"),
        PerformanceHorizon(minutes: 30, returnColumn: "return_30m", matchedBarEndColumn: "return_30m_bar_end"),
        PerformanceHorizon(minutes: 60, returnColumn: "return_60m", matchedBarEndColumn: "return_60m_bar_end")
    ]

    private static func migratePerformanceProvenance(in database: SQLiteDatabase) throws {
        try database.transaction {
            try database.execute(
                """
                CREATE TABLE IF NOT EXISTS schema_migrations (
                  name TEXT PRIMARY KEY
                )
                """
            )
            let alreadyMigrated = try !database.query(
                "SELECT name FROM schema_migrations WHERE name = ?",
                bindings: [.text(performanceProvenanceMigration)],
                map: { try $0.text(0) }
            ).isEmpty
            guard !alreadyMigrated else { return }

            let columns = Set(try database.query(
                "PRAGMA table_info(signals)",
                map: { try $0.text(1) }
            ))
            let isUnmigratedLegacySchema = performanceHorizons.allSatisfy {
                !columns.contains($0.matchedBarEndColumn)
            }
            for horizon in performanceHorizons where !columns.contains(horizon.matchedBarEndColumn) {
                try database.execute(
                    "ALTER TABLE signals ADD COLUMN \(horizon.matchedBarEndColumn) INTEGER"
                )
            }

            if isUnmigratedLegacySchema {
                let barsTableExists = try !database.query(
                    "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'bars'",
                    map: { try $0.text(0) }
                ).isEmpty
                if barsTableExists {
                    try database.execute(
                        """
                        CREATE INDEX IF NOT EXISTS bars_series_end_idx
                        ON bars (instrument_id, timeframe, end_at, start_at)
                        """
                    )
                    for horizon in performanceHorizons {
                        let targetOffset = horizon.minutes * 60
                        try database.execute(
                            """
                            UPDATE signals
                            SET (\(horizon.returnColumn), \(horizon.matchedBarEndColumn)) = (
                              SELECT (b.close / signals.last_close) - 1, b.end_at
                              FROM bars AS b
                              WHERE b.instrument_id = signals.instrument_id
                                AND b.timeframe = signals.timeframe
                                AND b.end_at >= signals.last_bar_end + \(targetOffset)
                              ORDER BY b.end_at ASC, b.start_at ASC
                              LIMIT 1
                            )
                            WHERE \(horizon.matchedBarEndColumn) IS NULL
                              AND EXISTS (
                                SELECT 1
                                FROM bars AS b
                                WHERE b.instrument_id = signals.instrument_id
                                  AND b.timeframe = signals.timeframe
                                  AND b.end_at >= signals.last_bar_end + \(targetOffset)
                              )
                            """
                        )
                    }
                }
            }

            try database.execute(
                "INSERT INTO schema_migrations (name) VALUES (?)",
                bindings: [.text(performanceProvenanceMigration)]
            )
        }
    }

    public func prune(before cutoff: Date) throws {
        try database.transaction {
            try database.execute(
                "DELETE FROM signals WHERE last_bar_end < ?",
                bindings: [.integer(sqliteEpoch(cutoff))]
            )
            try database.execute(
                "DELETE FROM notification_events WHERE created_at < ?",
                bindings: [.integer(sqliteEpoch(cutoff))]
            )
        }
    }

    private func decodeSignal(_ row: SQLiteRow) throws -> ConfirmedSignal {
        let rawTimeframe = Int(try row.integer(1))
        guard let timeframe = Timeframe(rawValue: rawTimeframe) else {
            throw PersistenceError.invalidTimeframe(rawTimeframe)
        }
        let rawDirection = try row.text(2)
        guard let direction = SignalDirection(rawValue: rawDirection) else {
            throw PersistenceError.invalidSignalDirection(rawDirection)
        }
        return ConfirmedSignal(
            instrumentID: try row.text(0),
            timeframe: timeframe,
            direction: direction,
            sequenceStart: sqliteDate(try row.integer(3)),
            lastBarEnd: sqliteDate(try row.integer(4)),
            lastClose: try row.double(5),
            extremePrice: try row.double(6),
            sourceUpdatedAt: sqliteDate(try row.integer(7)),
            return5m: try row.optionalDouble(8),
            return15m: try row.optionalDouble(9),
            return30m: try row.optionalDouble(10),
            return60m: try row.optionalDouble(11)
        )
    }

    private func decodePerformanceSignal(_ row: SQLiteRow) throws -> PerformanceSignal {
        PerformanceSignal(
            signal: try decodeSignal(row),
            performance: [
                StoredPerformance(value: try row.optionalDouble(8), matchedBarEnd: try row.optionalDate(12)),
                StoredPerformance(value: try row.optionalDouble(9), matchedBarEnd: try row.optionalDate(13)),
                StoredPerformance(value: try row.optionalDouble(10), matchedBarEnd: try row.optionalDate(14)),
                StoredPerformance(value: try row.optionalDouble(11), matchedBarEnd: try row.optionalDate(15))
            ]
        )
    }
}

private struct PerformanceSeriesKey: Hashable {
    let instrumentID: String
    let timeframe: Timeframe
}

private struct PerformanceSeriesRange {
    let key: PerformanceSeriesKey
    let minimumBarEnd: Date
    let maximumBarEnd: Date
}

private struct PerformanceHorizon {
    let minutes: Int
    let returnColumn: String
    let matchedBarEndColumn: String
}

private struct PerformanceSignal {
    let signal: ConfirmedSignal
    let performance: [StoredPerformance]
}

private struct StoredPerformance: Equatable {
    let value: Double?
    let matchedBarEnd: Date?
}

private func firstBar(endingAtOrAfter target: Date, in bars: [Bar]) -> Bar? {
    var lowerBound = 0
    var upperBound = bars.count
    while lowerBound < upperBound {
        let middle = lowerBound + (upperBound - lowerBound) / 2
        if bars[middle].end < target {
            lowerBound = middle + 1
        } else {
            upperBound = middle
        }
    }
    return lowerBound < bars.count ? bars[lowerBound] : nil
}

private func sqliteValue(_ value: Double?) -> SQLiteValue {
    value.map(SQLiteValue.real) ?? .null
}

private func sqliteValue(_ value: Date?) -> SQLiteValue {
    value.map { .integer(sqliteEpoch($0)) } ?? .null
}

private extension SQLiteRow {
    func optionalDate(_ index: Int32) throws -> Date? {
        try optionalInteger(index).map(sqliteDate)
    }
}
