import Testing
@testable import NineBarCore

@Suite("SignalRepositoryTests")
struct SignalRepositoryTests {
    @Test("signal and notification keys survive repository reopen")
    func uniquenessSurvivesReopen() async throws {
        let url = try temporarySQLiteURL()
        let signal = confirmedSignal(instrumentID: "sh.600519", timeframe: .fiveMinutes)

        do {
            let repository = try SignalRepository(databaseURL: url)
            #expect(try await repository.insertIfAbsent(signal))
            #expect(try await !repository.insertIfAbsent(signal))
            #expect(try await repository.recordNotificationIfNew(
                key: "\(signal.instrumentID)|\(signal.timeframe.rawValue)|\(signal.direction.rawValue)|\(Int(signal.sequenceStart.timeIntervalSince1970))|9",
                createdAt: signal.lastBarEnd
            ))
        }

        let reopened = try SignalRepository(databaseURL: url)
        #expect(try await !reopened.insertIfAbsent(signal))
        #expect(try await !reopened.recordNotificationIfNew(
            key: "\(signal.instrumentID)|\(signal.timeframe.rawValue)|\(signal.direction.rawValue)|\(Int(signal.sequenceStart.timeIntervalSince1970))|9",
            createdAt: signal.lastBarEnd
        ))
        #expect(try await reopened.recent(limit: 10) == [signal])
    }

    @Test("recent returns newest signals first and honors the limit")
    func recentOrdersAndLimits() async throws {
        let repository = try SignalRepository(databaseURL: temporarySQLiteURL())
        let oldest = confirmedSignal(end: "2026-09-01T09:35:00+08:00")
        let middle = confirmedSignal(end: "2026-09-01T09:40:00+08:00")
        let newest = confirmedSignal(end: "2026-09-01T09:45:00+08:00")
        _ = try await repository.insertIfAbsent(middle)
        _ = try await repository.insertIfAbsent(newest)
        _ = try await repository.insertIfAbsent(oldest)

        #expect(try await repository.recent(limit: 2).map(\.lastBarEnd) == [newest.lastBarEnd, middle.lastBarEnd])
        #expect(try await repository.recent(limit: 0).isEmpty)
    }

    @Test("performance uses first completed matching bar at each wall-clock horizon")
    func performanceUsesFirstMatchingCompletedBar() async throws {
        let repository = try SignalRepository(databaseURL: temporarySQLiteURL())
        let signal = confirmedSignal()
        _ = try await repository.insertIfAbsent(signal)
        let bars = [
            performanceBar(instrumentID: "sz.000001", minutesAfter: 5, close: 80),
            performanceBar(timeframe: .fiveMinutes, minutesAfter: 5, close: 70),
            performanceBar(minutesAfter: 5, close: 11, isClosed: false),
            performanceBar(minutesAfter: 4, close: 50),
            performanceBar(minutesAfter: 6, close: 11),
            performanceBar(minutesAfter: 16, close: 12),
            performanceBar(minutesAfter: 31, close: 13),
            performanceBar(minutesAfter: 61, close: 14),
            performanceBar(minutesAfter: 70, close: 99)
        ]

        try await repository.updatePerformance(using: bars)

        let updated = try #require(await repository.recent(limit: 1).first)
        #expect(abs(try #require(updated.return5m) - 0.1) < 0.000_000_1)
        #expect(abs(try #require(updated.return15m) - 0.2) < 0.000_000_1)
        #expect(abs(try #require(updated.return30m) - 0.3) < 0.000_000_1)
        #expect(abs(try #require(updated.return60m) - 0.4) < 0.000_000_1)
    }

    @Test("performance crosses lunch and overnight gaps to the first later bar")
    func performanceUsesFirstBarAcrossSessionGaps() async throws {
        let repository = try SignalRepository(databaseURL: temporarySQLiteURL())
        let lunchSignal = confirmedSignal(
            instrumentID: "sz.000001",
            end: "2026-09-01T11:29:00+08:00"
        )
        let overnightSignal = confirmedSignal(
            instrumentID: "sh.600519",
            end: "2026-09-01T14:59:00+08:00"
        )
        _ = try await repository.insertIfAbsent(lunchSignal)
        _ = try await repository.insertIfAbsent(overnightSignal)

        try await repository.updatePerformance(using: [
            performanceBar(
                instrumentID: lunchSignal.instrumentID,
                end: "2026-09-01T13:01:00+08:00",
                close: 12
            ),
            performanceBar(
                instrumentID: overnightSignal.instrumentID,
                end: "2026-09-02T09:31:00+08:00",
                close: 11
            )
        ])

        let updated = Dictionary(uniqueKeysWithValues: try await repository.recent(limit: 2).map {
            ($0.instrumentID, $0)
        })
        let lunch = try #require(updated[lunchSignal.instrumentID])
        let overnight = try #require(updated[overnightSignal.instrumentID])
        for value in [lunch.return5m, lunch.return15m, lunch.return30m, lunch.return60m] {
            #expect(abs(try #require(value) - 0.2) < 0.000_000_1)
        }
        for value in [overnight.return5m, overnight.return15m, overnight.return30m, overnight.return60m] {
            #expect(abs(try #require(value) - 0.1) < 0.000_000_1)
        }
    }

    @Test("performance pins the first matched bar and writes only its corrections")
    func performanceDoesNotDriftOrWriteForNonmatchingBatches() async throws {
        let url = try temporarySQLiteURL()
        let repository = try SignalRepository(databaseURL: url)
        let signal = confirmedSignal(end: "2026-09-01T14:59:00+08:00")
        _ = try await repository.insertIfAbsent(signal)
        let audit = try SQLiteDatabase(url: url)
        try installSignalUpdateAudit(in: audit)

        let matched = performanceBar(
            instrumentID: signal.instrumentID,
            end: "2026-09-02T09:31:00+08:00",
            close: 11
        )
        try await repository.updatePerformance(using: [matched])
        #expect(try signalUpdateCount(in: audit) == 1)

        try await repository.updatePerformance(using: [performanceBar(
            instrumentID: signal.instrumentID,
            end: "2026-09-03T09:31:00+08:00",
            close: 12
        )])
        try await repository.updatePerformance(using: [matched])

        let unchanged = try #require(await repository.recent(limit: 1).first)
        for value in [unchanged.return5m, unchanged.return15m, unchanged.return30m, unchanged.return60m] {
            #expect(abs(try #require(value) - 0.1) < 0.000_000_1)
        }
        #expect(try signalUpdateCount(in: audit) == 1)

        try await repository.updatePerformance(using: [performanceBar(
            instrumentID: signal.instrumentID,
            end: "2026-09-02T09:31:00+08:00",
            close: 11.5
        )])

        let corrected = try #require(await repository.recent(limit: 1).first)
        for value in [corrected.return5m, corrected.return15m, corrected.return30m, corrected.return60m] {
            #expect(abs(try #require(value) - 0.15) < 0.000_000_1)
        }
        #expect(try signalUpdateCount(in: audit) == 2)
    }

    @Test("an earlier matching bar replaces a later match when history arrives out of order")
    func performanceMovesProvenanceToAnEarlierMatch() async throws {
        let repository = try SignalRepository(databaseURL: temporarySQLiteURL())
        _ = try await repository.insertIfAbsent(confirmedSignal())

        try await repository.updatePerformance(using: [performanceBar(minutesAfter: 7, close: 12)])
        #expect(abs(try #require(await repository.recent(limit: 1).first?.return5m) - 0.2) < 0.000_000_1)

        try await repository.updatePerformance(using: [performanceBar(minutesAfter: 6, close: 11)])
        #expect(abs(try #require(await repository.recent(limit: 1).first?.return5m) - 0.1) < 0.000_000_1)
    }

    @Test("legacy schema recovers first-bar provenance and remains correct after reopen")
    func legacySchemaMigratesPerformanceProvenance() async throws {
        let url = try temporarySQLiteURL()
        let barRepository = try BarRepository(databaseURL: url)
        let legacyDatabase = try SQLiteDatabase(url: url)
        try createLegacySignalsTable(in: legacyDatabase)
        let signal = confirmedSignal()
        let unmatchedLegacySignal = confirmedSignal(instrumentID: "sz.000001")
        try insertLegacySignal(signal, return5m: 0.2, into: legacyDatabase)
        try insertLegacySignal(unmatchedLegacySignal, return5m: 0.3, into: legacyDatabase)
        try await barRepository.upsert([
            performanceBar(minutesAfter: 6, close: 11),
            performanceBar(minutesAfter: 7, close: 12)
        ])

        do {
            let migrated = try SignalRepository(databaseURL: url)
            let recovered = try #require(await migrated.recent(limit: 2).first {
                $0.instrumentID == signal.instrumentID
            })
            #expect(abs(try #require(recovered.return5m) - 0.1) < 0.000_000_1)
        }

        try await barRepository.upsert([
            performanceBar(
                instrumentID: unmatchedLegacySignal.instrumentID,
                minutesAfter: 8,
                close: 14
            )
        ])
        let reopened = try SignalRepository(databaseURL: url)
        try await reopened.updatePerformance(using: [performanceBar(minutesAfter: 8, close: 13)])
        let stableValues = try await reopened.recent(limit: 2)
        #expect(abs(try #require(stableValues.first {
            $0.instrumentID == signal.instrumentID
        }?.return5m) - 0.1) < 0.000_000_1)
        #expect(abs(try #require(stableValues.first {
            $0.instrumentID == unmatchedLegacySignal.instrumentID
        }?.return5m) - 0.3) < 0.000_000_1)
        let frozenLegacyState = try storedFiveMinutePerformance(
            in: legacyDatabase,
            instrumentID: unmatchedLegacySignal.instrumentID
        )
        #expect(abs(try #require(frozenLegacyState.value) - 0.3) < 0.000_000_1)
        #expect(frozenLegacyState.matchedBarEnd == nil)

        try await reopened.updatePerformance(using: [performanceBar(minutesAfter: 6, close: 11.5)])
        #expect(abs(try #require(await reopened.recent(limit: 2).first {
            $0.instrumentID == signal.instrumentID
        }?.return5m) - 0.15) < 0.000_000_1)
    }

    @Test("provenance columns without a migration marker freeze ambiguous legacy returns")
    func provenanceColumnsWithoutMarkerFreezeAmbiguousLegacyReturns() async throws {
        let url = try temporarySQLiteURL()
        let barRepository = try BarRepository(databaseURL: url)
        let database = try SQLiteDatabase(url: url)
        try createLegacySignalsTable(in: database)
        try addPerformanceProvenanceColumns(in: database)
        let signal = confirmedSignal()
        try insertLegacySignal(signal, return5m: 0.3, into: database)
        try await barRepository.upsert([performanceBar(minutesAfter: 8, close: 14)])

        do {
            let migrated = try SignalRepository(databaseURL: url)
            #expect(abs(try #require(await migrated.recent(limit: 1).first?.return5m) - 0.3) < 0.000_000_1)
        }

        let reopened = try SignalRepository(databaseURL: url)
        #expect(abs(try #require(await reopened.recent(limit: 1).first?.return5m) - 0.3) < 0.000_000_1)
        let stored = try storedFiveMinutePerformance(in: database, instrumentID: signal.instrumentID)
        #expect(abs(try #require(stored.value) - 0.3) < 0.000_000_1)
        #expect(stored.matchedBarEnd == nil)
    }

    @Test("an empty new database records its migration decision before later rows")
    func emptyDatabaseMigrationDecisionIsIdempotent() async throws {
        let url = try temporarySQLiteURL()
        do {
            _ = try SignalRepository(databaseURL: url)
        }
        let database = try SQLiteDatabase(url: url)
        let signal = confirmedSignal()
        try insertLegacySignal(signal, return5m: 0.3, into: database)
        let barRepository = try BarRepository(databaseURL: url)
        try await barRepository.upsert([performanceBar(minutesAfter: 8, close: 14)])

        let reopened = try SignalRepository(databaseURL: url)
        #expect(abs(try #require(await reopened.recent(limit: 1).first?.return5m) - 0.3) < 0.000_000_1)
        let stored = try storedFiveMinutePerformance(in: database, instrumentID: signal.instrumentID)
        #expect(abs(try #require(stored.value) - 0.3) < 0.000_000_1)
        #expect(stored.matchedBarEnd == nil)
    }

    @Test("a failed provenance migration rolls back and retries from the legacy schema")
    func failedPerformanceProvenanceMigrationRetriesAtomically() async throws {
        let url = try temporarySQLiteURL()
        let database = try SQLiteDatabase(url: url)
        try createLegacySignalsTable(in: database)
        let signal = confirmedSignal()
        try insertLegacySignal(signal, return5m: 0.2, into: database)
        try database.execute("CREATE TABLE bars (invalid INTEGER)")

        #expect(throws: PersistenceError.self) {
            _ = try SignalRepository(databaseURL: url)
        }

        try database.execute("DROP TABLE bars")
        let barRepository = try BarRepository(databaseURL: url)
        try await barRepository.upsert([performanceBar(minutesAfter: 6, close: 11)])
        let retried = try SignalRepository(databaseURL: url)
        #expect(abs(try #require(await retried.recent(limit: 1).first?.return5m) - 0.1) < 0.000_000_1)
        let stored = try storedFiveMinutePerformance(in: database, instrumentID: signal.instrumentID)
        #expect(stored.matchedBarEnd == Int64(performanceBar(minutesAfter: 6, close: 11).end.timeIntervalSince1970))
    }

    @Test("performance remains nil when a later matching bar is unavailable")
    func unavailablePerformanceRemainsNil() async throws {
        let repository = try SignalRepository(databaseURL: temporarySQLiteURL())
        _ = try await repository.insertIfAbsent(confirmedSignal())

        try await repository.updatePerformance(using: [
            performanceBar(minutesAfter: 5, close: 11)
        ])

        let updated = try #require(await repository.recent(limit: 1).first)
        #expect(updated.return5m != nil)
        #expect(updated.return15m == nil)
        #expect(updated.return30m == nil)
        #expect(updated.return60m == nil)
    }

    @Test("performance refreshes replace computed horizons and preserve unavailable horizons")
    func performanceRefreshesMergeComputedAndStoredValues() async throws {
        let repository = try SignalRepository(databaseURL: temporarySQLiteURL())
        _ = try await repository.insertIfAbsent(confirmedSignal())

        try await repository.updatePerformance(using: [
            performanceBar(minutesAfter: 6, close: 11),
            performanceBar(minutesAfter: 16, close: 12)
        ])
        try await repository.updatePerformance(using: [])
        try await repository.updatePerformance(using: [
            performanceBar(instrumentID: "sz.000001", minutesAfter: 31, close: 90)
        ])
        try await repository.updatePerformance(using: [
            performanceBar(minutesAfter: 6, close: 11.5)
        ])

        let corrected = try #require(await repository.recent(limit: 1).first)
        #expect(abs(try #require(corrected.return5m) - 0.15) < 0.000_000_1)
        #expect(abs(try #require(corrected.return15m) - 0.2) < 0.000_000_1)
        #expect(corrected.return30m == nil)
        #expect(corrected.return60m == nil)

        try await repository.updatePerformance(using: [
            performanceBar(minutesAfter: 6, close: 11.5),
            performanceBar(minutesAfter: 16, close: 12),
            performanceBar(minutesAfter: 31, close: 13),
            performanceBar(minutesAfter: 61, close: 14)
        ])

        let updated = try #require(await repository.recent(limit: 1).first)
        #expect(abs(try #require(updated.return5m) - 0.15) < 0.000_000_1)
        #expect(abs(try #require(updated.return15m) - 0.2) < 0.000_000_1)
        #expect(abs(try #require(updated.return30m) - 0.3) < 0.000_000_1)
        #expect(abs(try #require(updated.return60m) - 0.4) < 0.000_000_1)
    }

    @Test("performance updates query only affected series")
    func performanceUpdateDoesNotDecodeUnrelatedStoredRows() async throws {
        let url = try temporarySQLiteURL()
        let repository = try SignalRepository(databaseURL: url)
        _ = try await repository.insertIfAbsent(confirmedSignal())
        let database = try SQLiteDatabase(url: url)
        try database.execute(
            """
            INSERT INTO signals
              (id, instrument_id, timeframe, direction, sequence_start, last_bar_end,
               last_close, extreme_price, source_updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text("unrelated-invalid"), .text("sz.300750"), .integer(99), .text("top"),
                .integer(1), .integer(2), .real(10), .real(11), .integer(2)
            ]
        )

        try await repository.updatePerformance(using: [
            performanceBar(minutesAfter: 6, close: 11)
        ])

        let databaseRows = try database.query(
            "SELECT return_5m FROM signals WHERE instrument_id = ?",
            bindings: [.text("sh.600519")],
            map: { try $0.optionalDouble(0) }
        )
        #expect(abs(try #require(databaseRows.first ?? nil) - 0.1) < 0.000_000_1)
    }

    @Test("performance updates chunk more than two hundred series and refresh corrected values")
    func performanceUpdatesChunkedSeriesAndCorrections() async throws {
        let url = try temporarySQLiteURL()
        let repository = try SignalRepository(databaseURL: url)
        let audit = try SQLiteDatabase(url: url)
        try installSignalUpdateAudit(in: audit)
        let seriesCount = 205
        var bars: [Bar] = []

        for index in 0..<seriesCount {
            let instrumentID = "sh." + String(repeating: "0", count: 6 - String(index).count) + String(index)
            _ = try await repository.insertIfAbsent(confirmedSignal(instrumentID: instrumentID))
            bars.append(performanceBar(instrumentID: instrumentID, minutesAfter: 6, close: 11))
        }
        _ = try await repository.insertIfAbsent(confirmedSignal(instrumentID: "sz.999999"))

        try await repository.updatePerformance(using: bars)
        let correctedBars = bars.map { bar in
            Bar(
                instrumentID: bar.instrumentID,
                timeframe: bar.timeframe,
                start: bar.start,
                end: bar.end,
                open: 12,
                high: 12,
                low: 12,
                close: 12,
                volume: bar.volume,
                amount: bar.amount,
                sourceUpdatedAt: bar.sourceUpdatedAt,
                isClosed: true
            )
        }
        try await repository.updatePerformance(using: correctedBars)
        try await repository.updatePerformance(using: correctedBars)

        let values = try await repository.recent(limit: seriesCount + 1)
        #expect(values.filter { $0.instrumentID.hasPrefix("sh.") }.allSatisfy {
            abs(($0.return5m ?? -1) - 0.2) < 0.000_000_1
        })
        #expect(values.first { $0.instrumentID == "sz.999999" }?.return5m == nil)
        #expect(try signalUpdateCount(in: audit) == seriesCount * 2)
    }

    @Test("invalid stored timeframe throws instead of trapping")
    func invalidStoredTimeframeThrows() async throws {
        let url = try temporarySQLiteURL()
        let repository = try SignalRepository(databaseURL: url)
        let database = try SQLiteDatabase(url: url)
        try database.execute(
            """
            INSERT INTO signals
              (id, instrument_id, timeframe, direction, sequence_start, last_bar_end,
               last_close, extreme_price, source_updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [.text("invalid"), .text("sh.600519"), .integer(99), .text("sideways"),
                       .integer(1), .integer(2), .real(10), .real(11), .integer(2)]
        )

        await #expect(throws: PersistenceError.self) {
            _ = try await repository.recent(limit: 10)
        }
    }

    @Test("invalid stored direction throws instead of trapping")
    func invalidStoredDirectionThrows() async throws {
        let url = try temporarySQLiteURL()
        let repository = try SignalRepository(databaseURL: url)
        let database = try SQLiteDatabase(url: url)
        try database.execute(
            """
            INSERT INTO signals
              (id, instrument_id, timeframe, direction, sequence_start, last_bar_end,
               last_close, extreme_price, source_updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [.text("invalid"), .text("sh.600519"), .integer(1), .text("sideways"),
                       .integer(1), .integer(2), .real(10), .real(11), .integer(2)]
        )

        await #expect(throws: PersistenceError.self) {
            _ = try await repository.recent(limit: 10)
        }
    }
}

private func confirmedSignal(
    instrumentID: String = "sh.600519",
    timeframe: Timeframe = .oneMinute,
    end endText: String = "2026-09-01T10:00:00+08:00"
) -> ConfirmedSignal {
    let end = isoDate(endText)
    return ConfirmedSignal(
        instrumentID: instrumentID,
        timeframe: timeframe,
        direction: .top,
        sequenceStart: end.addingTimeInterval(-8 * 60),
        lastBarEnd: end,
        lastClose: 10,
        extremePrice: 10.4,
        sourceUpdatedAt: end,
        return5m: nil,
        return15m: nil,
        return30m: nil,
        return60m: nil
    )
}

private func performanceBar(
    instrumentID: String = "sh.600519",
    timeframe: Timeframe = .oneMinute,
    minutesAfter: Int,
    close: Double,
    isClosed: Bool = true
) -> Bar {
    let end = isoDate("2026-09-01T10:00:00+08:00").addingTimeInterval(Double(minutesAfter * 60))
    return Bar(
        instrumentID: instrumentID,
        timeframe: timeframe,
        start: end.addingTimeInterval(-60),
        end: end,
        open: close,
        high: close,
        low: close,
        close: close,
        volume: 100,
        amount: close * 100,
        sourceUpdatedAt: end,
        isClosed: isClosed
    )
}

private func installSignalUpdateAudit(in database: SQLiteDatabase) throws {
    try database.execute("CREATE TABLE signal_update_audit (updates INTEGER NOT NULL)")
    try database.execute("INSERT INTO signal_update_audit (updates) VALUES (0)")
    try database.execute(
        """
        CREATE TRIGGER signal_update_audit_trigger
        AFTER UPDATE ON signals
        BEGIN
          UPDATE signal_update_audit SET updates = updates + 1;
        END
        """
    )
}

private func signalUpdateCount(in database: SQLiteDatabase) throws -> Int {
    let value = try #require(database.query(
        "SELECT updates FROM signal_update_audit",
        map: { try $0.integer(0) }
    ).first)
    return Int(value)
}

private func createLegacySignalsTable(in database: SQLiteDatabase) throws {
    try database.execute(
        """
        CREATE TABLE signals (
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
          return_60m REAL
        )
        """
    )
}

private func addPerformanceProvenanceColumns(in database: SQLiteDatabase) throws {
    for column in [
        "return_5m_bar_end",
        "return_15m_bar_end",
        "return_30m_bar_end",
        "return_60m_bar_end"
    ] {
        try database.execute("ALTER TABLE signals ADD COLUMN \(column) INTEGER")
    }
}

private func storedFiveMinutePerformance(
    in database: SQLiteDatabase,
    instrumentID: String
) throws -> (value: Double?, matchedBarEnd: Int64?) {
    try #require(database.query(
        "SELECT return_5m, return_5m_bar_end FROM signals WHERE instrument_id = ?",
        bindings: [.text(instrumentID)],
        map: { row in
            (value: try row.optionalDouble(0), matchedBarEnd: try row.optionalInteger(1))
        }
    ).first)
}

private func insertLegacySignal(
    _ signal: ConfirmedSignal,
    return5m: Double,
    into database: SQLiteDatabase
) throws {
    try database.execute(
        """
        INSERT INTO signals
          (id, instrument_id, timeframe, direction, sequence_start, last_bar_end,
           last_close, extreme_price, source_updated_at, return_5m)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            .real(return5m)
        ]
    )
}

private func performanceBar(
    instrumentID: String,
    timeframe: Timeframe = .oneMinute,
    end endText: String,
    close: Double
) -> Bar {
    let end = isoDate(endText)
    return Bar(
        instrumentID: instrumentID,
        timeframe: timeframe,
        start: end.addingTimeInterval(-60),
        end: end,
        open: close,
        high: close,
        low: close,
        close: close,
        volume: 100,
        amount: close * 100,
        sourceUpdatedAt: end,
        isClosed: true
    )
}
