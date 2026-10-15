import Foundation

public protocol BarStoring: Sendable {
    func upsert(_ bars: [Bar]) async throws
    func load(instrumentID: String, timeframe: Timeframe, from: Date) async throws -> [Bar]
    func distinctTradingDates() async throws -> [Date]
    func prune(before: Date) async throws
}

public actor BarRepository: BarStoring {
    private let database: SQLiteDatabase

    public init(databaseURL: URL) throws {
        let database = try SQLiteDatabase(url: databaseURL)
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS bars (
              instrument_id TEXT NOT NULL,
              timeframe INTEGER NOT NULL,
              start_at INTEGER NOT NULL,
              end_at INTEGER NOT NULL,
              open REAL NOT NULL,
              high REAL NOT NULL,
              low REAL NOT NULL,
              close REAL NOT NULL,
              volume REAL NOT NULL,
              amount REAL NOT NULL,
              source_updated_at INTEGER NOT NULL,
              PRIMARY KEY (instrument_id, timeframe, start_at)
            )
            """
        )
        try database.execute(
            """
            CREATE INDEX IF NOT EXISTS bars_start_idx
            ON bars (start_at)
            """
        )
        self.database = database
    }

    public func upsert(_ bars: [Bar]) throws {
        guard !bars.isEmpty else { return }
        try database.transaction {
            for bar in bars {
                try database.execute(
                    """
                    INSERT INTO bars
                      (instrument_id, timeframe, start_at, end_at, open, high, low, close,
                       volume, amount, source_updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(instrument_id, timeframe, start_at) DO UPDATE SET
                      end_at = excluded.end_at,
                      open = excluded.open,
                      high = excluded.high,
                      low = excluded.low,
                      close = excluded.close,
                      volume = excluded.volume,
                      amount = excluded.amount,
                      source_updated_at = excluded.source_updated_at
                    """,
                    bindings: [
                        .text(bar.instrumentID),
                        .integer(Int64(bar.timeframe.rawValue)),
                        .integer(sqliteEpoch(bar.start)),
                        .integer(sqliteEpoch(bar.end)),
                        .real(bar.open),
                        .real(bar.high),
                        .real(bar.low),
                        .real(bar.close),
                        .real(bar.volume),
                        .real(bar.amount),
                        .integer(sqliteEpoch(bar.sourceUpdatedAt))
                    ]
                )
            }
        }
    }

    public func load(
        instrumentID: String,
        timeframe: Timeframe,
        from: Date
    ) throws -> [Bar] {
        try database.query(
            """
            SELECT instrument_id, timeframe, start_at, end_at, open, high, low, close,
                   volume, amount, source_updated_at
            FROM bars
            WHERE instrument_id = ? AND timeframe = ? AND start_at >= ?
            ORDER BY start_at ASC
            """,
            bindings: [
                .text(instrumentID),
                .integer(Int64(timeframe.rawValue)),
                .integer(sqliteEpoch(from))
            ],
            map: decodeBar
        )
    }

    public func distinctTradingDates() throws -> [Date] {
        let timestamps = try database.query(
            """
            SELECT MIN(start_at)
            FROM bars
            GROUP BY date(start_at, 'unixepoch', '+8 hours')
            ORDER BY MIN(start_at) ASC
            """,
            map: { try $0.integer(0) }
        )
        var calendar = Calendar(identifier: .gregorian)
        guard let timeZone = TimeZone(identifier: "Asia/Shanghai") else {
            throw PersistenceError.database("Asia/Shanghai time zone is unavailable")
        }
        calendar.timeZone = timeZone
        return timestamps.map { calendar.startOfDay(for: sqliteDate($0)) }
    }

    public func prune(before cutoff: Date) throws {
        try database.execute(
            "DELETE FROM bars WHERE start_at < ?",
            bindings: [.integer(sqliteEpoch(cutoff))]
        )
    }

    private func decodeBar(_ row: SQLiteRow) throws -> Bar {
        let rawTimeframe = Int(try row.integer(1))
        guard let timeframe = Timeframe(rawValue: rawTimeframe) else {
            throw PersistenceError.invalidTimeframe(rawTimeframe)
        }
        return Bar(
            instrumentID: try row.text(0),
            timeframe: timeframe,
            start: sqliteDate(try row.integer(2)),
            end: sqliteDate(try row.integer(3)),
            open: try row.double(4),
            high: try row.double(5),
            low: try row.double(6),
            close: try row.double(7),
            volume: try row.double(8),
            amount: try row.double(9),
            sourceUpdatedAt: sqliteDate(try row.integer(10)),
            isClosed: true
        )
    }
}

func sqliteEpoch(_ date: Date) -> Int64 {
    Int64(date.timeIntervalSince1970.rounded(.towardZero))
}

func sqliteDate(_ epoch: Int64) -> Date {
    Date(timeIntervalSince1970: TimeInterval(epoch))
}
