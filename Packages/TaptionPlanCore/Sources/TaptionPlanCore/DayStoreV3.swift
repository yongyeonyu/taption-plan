import CSQLite
import CryptoKit
import Foundation

public enum TaptionPlanStoreDevice: String, Codable, Hashable, Sendable {
    case iPhone
    case appleWatch
}

public struct TaptionPlanRawEvent: Codable, Hashable, Sendable {
    public let device: TaptionPlanStoreDevice
    public let day: TaptionPlanDayKey
    public let timestamp: Date
    public let sequence: UInt64
    public let id: String
    public let domain: String
    public let provenance: [String]
    public let payload: Data

    public init(
        device: TaptionPlanStoreDevice,
        day: TaptionPlanDayKey,
        timestamp: Date,
        sequence: UInt64,
        id: String,
        domain: String,
        provenance: [String],
        payload: Data
    ) {
        self.device = device
        self.day = day
        self.timestamp = timestamp
        self.sequence = sequence
        self.id = id
        self.domain = domain
        self.provenance = provenance
        self.payload = payload
    }
}

public struct TaptionPlanMaterializedDay: Codable, Hashable, Sendable {
    public let device: TaptionPlanStoreDevice
    public let day: TaptionPlanDayKey
    public let sourceRevision: UInt64
    public let projectionVersion: UInt64
    public let generatedAt: Date
    public let rawDigest: String
    public let rawEventCount: Int
    public let firstTimestamp: Date?
    public let lastTimestamp: Date?
    public let payload: Data

    public init(
        device: TaptionPlanStoreDevice,
        day: TaptionPlanDayKey,
        sourceRevision: UInt64,
        projectionVersion: UInt64,
        generatedAt: Date = .now,
        rawDigest: String,
        rawEventCount: Int,
        firstTimestamp: Date?,
        lastTimestamp: Date?,
        payload: Data
    ) {
        self.device = device
        self.day = day
        self.sourceRevision = sourceRevision
        self.projectionVersion = projectionVersion
        self.generatedAt = generatedAt
        self.rawDigest = rawDigest
        self.rawEventCount = rawEventCount
        self.firstTimestamp = firstTimestamp
        self.lastTimestamp = lastTimestamp
        self.payload = payload
    }
}

public struct TaptionPlanDayDigest: Codable, Hashable, Sendable {
    public let device: TaptionPlanStoreDevice
    public let day: TaptionPlanDayKey
    public let eventCount: Int
    public let firstTimestamp: Date?
    public let lastTimestamp: Date?
    public let sha256: String

    public init(
        device: TaptionPlanStoreDevice,
        day: TaptionPlanDayKey,
        eventCount: Int,
        firstTimestamp: Date?,
        lastTimestamp: Date?,
        sha256: String
    ) {
        self.device = device
        self.day = day
        self.eventCount = eventCount
        self.firstTimestamp = firstTimestamp
        self.lastTimestamp = lastTimestamp
        self.sha256 = sha256
    }
}

public enum TaptionPlanV3StoreError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case invalidDomain
    case invalidDevice
    case invalidIdentifier
    case integerOverflow
    case payloadConflict(device: TaptionPlanStoreDevice, domain: String, id: String)
    case materializationMismatch
    case database(code: Int32, message: String)
    case databaseCorrupt(message: String)
}

/// SQLite v3 storage for append-only device events and one derived row per day.
/// The actor owns the connection so a prepared statement is never used across
/// concurrent callers and the raw table remains the source of truth.
public actor TaptionPlanV3Store {
    public static let schemaVersion = 3
    public static let projectionVersion: UInt64 = 1

    public let device: TaptionPlanStoreDevice
    private nonisolated(unsafe) var database: OpaquePointer?

    public init(url: URL, device: TaptionPlanStoreDevice) throws {
        self.device = device
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if FileManager.default.fileExists(atPath: url.path) {
            try Self.validateExistingDatabase(at: url)
        }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK,
              let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) }
                ?? "Unable to open database"
            sqlite3_close(handle)
            throw Self.error(code: SQLITE_CANTOPEN, message: message)
        }
        database = handle
        do {
            try Self.initializeDatabase(handle)
        } catch {
            sqlite3_close(handle)
            database = nil
            throw error
        }
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    public func appendRawEvents(_ events: [TaptionPlanRawEvent]) throws {
        guard events.allSatisfy({ $0.device == device }) else {
            throw TaptionPlanV3StoreError.invalidDevice
        }
        guard events.allSatisfy({ !$0.domain.isEmpty && !$0.id.isEmpty }) else {
            throw TaptionPlanV3StoreError.invalidIdentifier
        }
        try withTransaction {
            for event in events {
                if let existing = try rawEvent(
                    device: event.device,
                    domain: event.domain,
                    id: event.id
                ) {
                    guard existing == event else {
                        throw TaptionPlanV3StoreError.payloadConflict(
                            device: event.device,
                            domain: event.domain,
                            id: event.id
                        )
                    }
                    continue
                }
                try execute(
                    """
                    INSERT INTO raw_events(
                        device, day_key, timestamp, sequence, id, domain,
                        provenance, payload
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                    """,
                    binds: { statement in
                        try self.bind(event.device.rawValue, to: statement, at: 1)
                        try self.bind(Self.dayKey(event.day), to: statement, at: 2)
                        try self.bind(event.timestamp.timeIntervalSince1970, to: statement, at: 3)
                        try self.bind(event.sequence, to: statement, at: 4)
                        try self.bind(event.id, to: statement, at: 5)
                        try self.bind(event.domain, to: statement, at: 6)
                        try self.bind(try self.encodeProvenance(event.provenance), to: statement, at: 7)
                        try self.bind(event.payload, to: statement, at: 8)
                    }
                )
            }
        }
    }

    public func rawEvents(
        for day: TaptionPlanDayKey,
        domain: String? = nil
    ) throws -> [TaptionPlanRawEvent] {
        if let domain, domain.isEmpty {
            throw TaptionPlanV3StoreError.invalidDomain
        }
        let statement: OpaquePointer
        if domain == nil {
            statement = try prepare(
                """
                SELECT device, day_key, timestamp, sequence, id, domain,
                       provenance, payload
                FROM raw_events
                WHERE device = ? AND day_key = ?
                ORDER BY day_key, timestamp, sequence, id;
                """
            )
        } else {
            statement = try prepare(
                """
                SELECT device, day_key, timestamp, sequence, id, domain,
                       provenance, payload
                FROM raw_events
                WHERE device = ? AND day_key = ? AND domain = ?
                ORDER BY day_key, timestamp, sequence, id;
                """
            )
        }
        defer { sqlite3_finalize(statement) }
        try bind(device.rawValue, to: statement, at: 1)
        try bind(Self.dayKey(day), to: statement, at: 2)
        if let domain {
            try bind(domain, to: statement, at: 3)
        }
        var result: [TaptionPlanRawEvent] = []
        while try step(statement) == SQLITE_ROW {
            result.append(try readRawEvent(statement))
        }
        return result
    }

    public func rawDigest(for day: TaptionPlanDayKey) throws -> TaptionPlanDayDigest {
        let events = try rawEvents(for: day)
        return Self.digest(events: events, device: device, day: day)
    }

    /// Computes the same canonical digest used by the SQLite reader. Migration
    /// code uses this to compare the source event set before and after import.
    public static func digest(
        events: [TaptionPlanRawEvent],
        device: TaptionPlanStoreDevice,
        day: TaptionPlanDayKey
    ) -> TaptionPlanDayDigest {
        let ordered = events.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
            return $0.id < $1.id
        }
        var hasher = SHA256()
        for event in ordered {
            appendCanonical(event.device.rawValue, to: &hasher)
            appendCanonical(Self.dayKey(event.day), to: &hasher)
            appendCanonical(event.timestamp.timeIntervalSince1970, to: &hasher)
            appendCanonical(event.sequence, to: &hasher)
            appendCanonical(event.id, to: &hasher)
            appendCanonical(event.domain, to: &hasher)
            appendCanonical(event.provenance, to: &hasher)
            appendCanonical(event.payload, to: &hasher)
        }
        return TaptionPlanDayDigest(
            device: device,
            day: day,
            eventCount: ordered.count,
            firstTimestamp: ordered.first?.timestamp,
            lastTimestamp: ordered.last?.timestamp,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }

    public func replaceMaterializedDay(_ materialized: TaptionPlanMaterializedDay) throws {
        guard materialized.device == device else {
            throw TaptionPlanV3StoreError.invalidDevice
        }
        guard !materialized.rawDigest.isEmpty else {
            throw TaptionPlanV3StoreError.materializationMismatch
        }
        guard let rawEventCount = Int64(exactly: materialized.rawEventCount),
              rawEventCount >= 0 else {
            throw TaptionPlanV3StoreError.integerOverflow
        }
        try withTransaction {
            try execute(
                """
                INSERT INTO day_materialized(
                    device, day_key, source_revision, projection_version,
                    generated_at, raw_digest, raw_event_count,
                    first_timestamp, last_timestamp, payload
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(device, day_key) DO UPDATE SET
                    source_revision = excluded.source_revision,
                    projection_version = excluded.projection_version,
                    generated_at = excluded.generated_at,
                    raw_digest = excluded.raw_digest,
                    raw_event_count = excluded.raw_event_count,
                    first_timestamp = excluded.first_timestamp,
                    last_timestamp = excluded.last_timestamp,
                    payload = excluded.payload;
                """,
                binds: { statement in
                    try self.bind(materialized.device.rawValue, to: statement, at: 1)
                    try self.bind(Self.dayKey(materialized.day), to: statement, at: 2)
                    try self.bind(materialized.sourceRevision, to: statement, at: 3)
                    try self.bind(materialized.projectionVersion, to: statement, at: 4)
                    try self.bind(materialized.generatedAt.timeIntervalSince1970, to: statement, at: 5)
                    try self.bind(materialized.rawDigest, to: statement, at: 6)
                    try self.bind(rawEventCount, to: statement, at: 7)
                    try self.bind(materialized.firstTimestamp?.timeIntervalSince1970, to: statement, at: 8)
                    try self.bind(materialized.lastTimestamp?.timeIntervalSince1970, to: statement, at: 9)
                    try self.bind(materialized.payload, to: statement, at: 10)
                }
            )
        }
    }

    public func materializedDay(
        for day: TaptionPlanDayKey
    ) throws -> TaptionPlanMaterializedDay? {
        let statement = try prepare(
            """
            SELECT device, day_key, source_revision, projection_version,
                   generated_at, raw_digest, raw_event_count,
                   first_timestamp, last_timestamp, payload
            FROM day_materialized
            WHERE device = ? AND day_key = ?;
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(device.rawValue, to: statement, at: 1)
        try bind(Self.dayKey(day), to: statement, at: 2)
        guard try step(statement) == SQLITE_ROW else { return nil }
        return try readMaterializedDay(statement)
    }

    public func removeMaterializedDay(for day: TaptionPlanDayKey) throws {
        let statement = try prepare(
            "DELETE FROM day_materialized WHERE device = ? AND day_key = ?;"
        )
        defer { sqlite3_finalize(statement) }
        try bind(device.rawValue, to: statement, at: 1)
        try bind(Self.dayKey(day), to: statement, at: 2)
        guard try step(statement) == SQLITE_DONE else { throw lastError() }
    }

    public func allDays() throws -> [TaptionPlanDayKey] {
        let statement = try prepare(
            """
            SELECT day_key FROM raw_events WHERE device = ?
            UNION
            SELECT day_key FROM day_materialized WHERE device = ?
            ORDER BY day_key;
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(device.rawValue, to: statement, at: 1)
        try bind(device.rawValue, to: statement, at: 2)
        var result: [TaptionPlanDayKey] = []
        while try step(statement) == SQLITE_ROW {
            guard let value = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
                  let day = parseDayKey(value) else {
                throw TaptionPlanV3StoreError.databaseCorrupt(
                    message: "Invalid day key in v3 index"
                )
            }
            result.append(day)
        }
        return result
    }

    /// Returns SQLite's chosen plan for the date query. Callers can record it
    /// with their migration/performance evidence and assert index search.
    public func explainRawDayQuery() throws -> [String] {
        let statement = try prepare(
            """
            EXPLAIN QUERY PLAN
            SELECT device, day_key, timestamp, sequence, id, domain,
                   provenance, payload
            FROM raw_events
            WHERE device = ? AND day_key = ?
            ORDER BY day_key, timestamp, sequence, id;
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(device.rawValue, to: statement, at: 1)
        try bind("2000-01-01", to: statement, at: 2)
        var result: [String] = []
        while try step(statement) == SQLITE_ROW {
            if let detail = sqlite3_column_text(statement, 3) {
                result.append(String(cString: detail))
            }
        }
        return result
    }

    public func checkpoint() throws {
        guard let database else { throw lastError() }
        let result = sqlite3_wal_checkpoint_v2(
            database,
            nil,
            SQLITE_CHECKPOINT_PASSIVE,
            nil,
            nil
        )
        guard result == SQLITE_OK else {
            throw Self.error(
                code: result,
                message: String(cString: sqlite3_errmsg(database))
            )
        }
    }

    public func markMigrationCompleted(_ key: String, at date: Date = .now) throws -> Bool {
        guard !key.isEmpty else { throw TaptionPlanV3StoreError.invalidIdentifier }
        try execute(
            "INSERT OR IGNORE INTO migration_markers(key, completed_at) VALUES (?, ?);",
            binds: { statement in
                try self.bind(key, to: statement, at: 1)
                try self.bind(date.timeIntervalSince1970, to: statement, at: 2)
            }
        )
        return sqlite3_changes(database) == 1
    }

    public func migrationCompleted(_ key: String) throws -> Bool {
        guard !key.isEmpty else { throw TaptionPlanV3StoreError.invalidIdentifier }
        let statement = try prepare(
            "SELECT 1 FROM migration_markers WHERE key = ? LIMIT 1;"
        )
        defer { sqlite3_finalize(statement) }
        try bind(key, to: statement, at: 1)
        return try step(statement) == SQLITE_ROW
    }

    private nonisolated static func initializeDatabase(_ database: OpaquePointer) throws {
        try sqliteExecute(database, "PRAGMA busy_timeout=5000;")
        try sqliteExecute(database, "PRAGMA journal_mode=WAL;")
        try sqliteExecute(database, "PRAGMA synchronous=NORMAL;")
        let hasSchemaTable = try sqliteTableExists(database, "schema_meta")
        if hasSchemaTable {
            let version = try sqliteSchemaVersion(database)
            guard version == Self.schemaVersion else {
                throw TaptionPlanV3StoreError.unsupportedSchema(version)
            }
            try sqliteExecute(
                database,
                """
                CREATE TABLE IF NOT EXISTS migration_markers(
                    key TEXT NOT NULL PRIMARY KEY,
                    completed_at REAL NOT NULL
                );
                """
            )
            return
        }

        guard try sqliteUserTableCount(database) == 0 else {
            throw TaptionPlanV3StoreError.unsupportedSchema(0)
        }
        try sqliteExecute(
            database,
            """
            CREATE TABLE schema_meta(
                key TEXT NOT NULL PRIMARY KEY,
                value TEXT NOT NULL
            );
            INSERT INTO schema_meta(key, value) VALUES ('schema_version', '3');
            CREATE TABLE raw_events(
                device TEXT NOT NULL,
                day_key TEXT NOT NULL,
                timestamp REAL NOT NULL,
                sequence INTEGER NOT NULL,
                id TEXT NOT NULL,
                domain TEXT NOT NULL,
                provenance BLOB NOT NULL,
                payload BLOB NOT NULL,
                PRIMARY KEY(device, domain, id)
            );
            CREATE INDEX raw_events_day_time_index
                ON raw_events(device, day_key, timestamp, sequence, id, domain);
            CREATE TABLE day_materialized(
                device TEXT NOT NULL,
                day_key TEXT NOT NULL,
                source_revision INTEGER NOT NULL,
                projection_version INTEGER NOT NULL,
                generated_at REAL NOT NULL,
                raw_digest TEXT NOT NULL,
                raw_event_count INTEGER NOT NULL,
                first_timestamp REAL,
                last_timestamp REAL,
                payload BLOB NOT NULL,
                PRIMARY KEY(device, day_key)
            );
            CREATE INDEX day_materialized_day_index
                ON day_materialized(device, day_key);
            CREATE TABLE migration_markers(
                key TEXT NOT NULL PRIMARY KEY,
                completed_at REAL NOT NULL
            );
            """
        )
        try sqliteExecute(
            database,
            """
            CREATE TABLE IF NOT EXISTS migration_markers(
                key TEXT NOT NULL PRIMARY KEY,
                completed_at REAL NOT NULL
            );
            """
        )
    }

    private nonisolated static func validateExistingDatabase(at url: URL) throws {
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) }
                ?? "Unable to inspect database"
            sqlite3_close(handle)
            throw error(code: result, message: message)
        }
        defer { sqlite3_close(handle) }

        let hasSchemaTable = try sqliteTableExists(handle, "schema_meta")
        if hasSchemaTable {
            let version = try sqliteSchemaVersion(handle)
            guard version == Self.schemaVersion else {
                throw TaptionPlanV3StoreError.unsupportedSchema(version)
            }
            return
        }
        guard try sqliteUserTableCount(handle) == 0 else {
            throw TaptionPlanV3StoreError.unsupportedSchema(0)
        }
    }

    private nonisolated static func sqliteSchemaVersion(_ database: OpaquePointer) throws -> Int {
        let statement = try sqlitePrepare(
            database,
            "SELECT value FROM schema_meta WHERE key = 'schema_version' LIMIT 1;"
        )
        defer { sqlite3_finalize(statement) }
        guard try sqliteStep(database, statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
              let version = Int(value) else {
            throw TaptionPlanV3StoreError.databaseCorrupt(
                message: "Missing v3 schema version"
            )
        }
        return version
    }

    private nonisolated static func sqliteTableExists(
        _ database: OpaquePointer,
        _ name: String
    ) throws -> Bool {
        let statement = try sqlitePrepare(
            database,
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;"
        )
        defer { sqlite3_finalize(statement) }
        try sqliteBind(name, to: statement, at: 1, database: database)
        return try sqliteStep(database, statement) == SQLITE_ROW
    }

    private nonisolated static func sqliteUserTableCount(_ database: OpaquePointer) throws -> Int {
        let statement = try sqlitePrepare(
            database,
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%';"
        )
        defer { sqlite3_finalize(statement) }
        guard try sqliteStep(database, statement) == SQLITE_ROW else {
            throw sqliteError(database)
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private nonisolated static func sqliteExecute(
        _ database: OpaquePointer,
        _ sql: String
    ) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        guard result == SQLITE_OK else {
            let text = message.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(message)
            throw error(code: result, message: text)
        }
    }

    private nonisolated static func sqlitePrepare(
        _ database: OpaquePointer,
        _ sql: String
    ) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw sqliteError(database)
        }
        return statement
    }

    private nonisolated static func sqliteStep(
        _ database: OpaquePointer,
        _ statement: OpaquePointer
    ) throws -> Int32 {
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else {
            throw sqliteError(database)
        }
        return result
    }

    private nonisolated static func sqliteBind(
        _ value: String,
        to statement: OpaquePointer,
        at index: Int32,
        database: OpaquePointer
    ) throws {
        guard sqlite3_bind_text(statement, index, value, -1, sqliteTransient) == SQLITE_OK else {
            throw sqliteError(database)
        }
    }

    private nonisolated static func sqliteError(
        _ database: OpaquePointer
    ) -> TaptionPlanV3StoreError {
        error(code: sqlite3_errcode(database), message: String(cString: sqlite3_errmsg(database)))
    }

    private func rawEvent(
        device: TaptionPlanStoreDevice,
        domain: String,
        id: String
    ) throws -> TaptionPlanRawEvent? {
        let statement = try prepare(
            """
            SELECT device, day_key, timestamp, sequence, id, domain,
                   provenance, payload
            FROM raw_events
            WHERE device = ? AND domain = ? AND id = ?;
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(device.rawValue, to: statement, at: 1)
        try bind(domain, to: statement, at: 2)
        try bind(id, to: statement, at: 3)
        guard try step(statement) == SQLITE_ROW else { return nil }
        return try readRawEvent(statement)
    }

    private func readRawEvent(_ statement: OpaquePointer) throws -> TaptionPlanRawEvent {
        guard let deviceValue = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
              let device = TaptionPlanStoreDevice(rawValue: deviceValue),
              let dayValue = sqlite3_column_text(statement, 1).map({ String(cString: $0) }),
              let day = parseDayKey(dayValue),
              let id = sqlite3_column_text(statement, 4).map({ String(cString: $0) }),
              let domain = sqlite3_column_text(statement, 5).map({ String(cString: $0) }) else {
            throw TaptionPlanV3StoreError.databaseCorrupt(message: "Invalid raw event row")
        }
        return TaptionPlanRawEvent(
            device: device,
            day: day,
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
            sequence: try readUInt64(sqlite3_column_int64(statement, 3)),
            id: id,
            domain: domain,
            provenance: try decodeProvenance(readData(statement, at: 6)),
            payload: readData(statement, at: 7)
        )
    }

    private func readMaterializedDay(
        _ statement: OpaquePointer
    ) throws -> TaptionPlanMaterializedDay {
        guard let deviceValue = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
              let device = TaptionPlanStoreDevice(rawValue: deviceValue),
              let dayValue = sqlite3_column_text(statement, 1).map({ String(cString: $0) }),
              let day = parseDayKey(dayValue),
              let digest = sqlite3_column_text(statement, 5).map({ String(cString: $0) }) else {
            throw TaptionPlanV3StoreError.databaseCorrupt(message: "Invalid materialized row")
        }
        let rawCount = sqlite3_column_int64(statement, 6)
        guard let rawEventCount = Int(exactly: rawCount), rawEventCount >= 0 else {
            throw TaptionPlanV3StoreError.databaseCorrupt(message: "Negative raw event count")
        }
        let sourceRevision = try readUInt64(sqlite3_column_int64(statement, 2))
        let projectionVersion = try readUInt64(sqlite3_column_int64(statement, 3))
        let generatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
        let firstTimestamp = sqlite3_column_type(statement, 7) == SQLITE_NULL
            ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
        let lastTimestamp = sqlite3_column_type(statement, 8) == SQLITE_NULL
            ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 8))
        return TaptionPlanMaterializedDay(
            device: device,
            day: day,
            sourceRevision: sourceRevision,
            projectionVersion: projectionVersion,
            generatedAt: generatedAt,
            rawDigest: digest,
            rawEventCount: rawEventCount,
            firstTimestamp: firstTimestamp,
            lastTimestamp: lastTimestamp,
            payload: readData(statement, at: 9)
        )
    }

    private func withTransaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try body()
            try execute("COMMIT;")
        } catch {
            _ = try? execute("ROLLBACK;")
            throw error
        }
    }

    private func execute(
        _ sql: String,
        binds: ((OpaquePointer) throws -> Void)? = nil
    ) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try binds?(statement)
        guard try step(statement) == SQLITE_DONE else { throw lastError() }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let database else { throw lastError() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw lastError()
        }
        return statement
    }

    private func step(_ statement: OpaquePointer) throws -> Int32 {
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw lastError() }
        return result
    }

    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) throws {
        guard sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient) == SQLITE_OK else {
            throw lastError()
        }
    }

    private func bind(_ value: UInt64, to statement: OpaquePointer, at index: Int32) throws {
        guard value <= UInt64(Int64.max) else {
            throw TaptionPlanV3StoreError.integerOverflow
        }
        try bind(Int64(value), to: statement, at: index)
    }

    private func bind(_ value: Int64, to statement: OpaquePointer, at index: Int32) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else { throw lastError() }
    }

    private func bind(_ value: TimeInterval?, to statement: OpaquePointer, at index: Int32) throws {
        let result: Int32
        if let value {
            result = sqlite3_bind_double(statement, index, value)
        } else {
            result = sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else { throw lastError() }
    }

    private func bind(_ value: Data, to statement: OpaquePointer, at index: Int32) throws {
        let result = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(
                statement,
                index,
                bytes.baseAddress,
                Int32(value.count),
                Self.sqliteTransient
            )
        }
        guard result == SQLITE_OK else { throw lastError() }
    }

    private func readData(_ statement: OpaquePointer, at index: Int32) -> Data {
        let length = Int(sqlite3_column_bytes(statement, index))
        guard length > 0, let bytes = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: bytes, count: length)
    }

    private func readUInt64(_ value: Int64) throws -> UInt64 {
        guard value >= 0 else {
            throw TaptionPlanV3StoreError.databaseCorrupt(message: "Negative unsigned value")
        }
        return UInt64(value)
    }

    private func encodeProvenance(_ values: [String]) throws -> Data {
        try JSONEncoder().encode(values)
    }

    private func decodeProvenance(_ data: Data) throws -> [String] {
        do {
            return try JSONDecoder().decode([String].self, from: data)
        } catch {
            throw TaptionPlanV3StoreError.databaseCorrupt(message: "Invalid provenance payload")
        }
    }

    private static func dayKey(_ day: TaptionPlanDayKey) -> String {
        String(format: "%04d-%02d-%02d", day.year, day.month, day.day)
    }

    private func parseDayKey(_ value: String) -> TaptionPlanDayKey? {
        let components = value.split(separator: "-").compactMap { Int($0) }
        guard components.count == 3 else { return nil }
        return TaptionPlanDayKey(year: components[0], month: components[1], day: components[2])
    }

    private static func appendCanonical(_ value: String, to hasher: inout SHA256) {
        appendCanonical(Data(value.utf8), to: &hasher)
    }

    private static func appendCanonical(_ value: TimeInterval, to hasher: inout SHA256) {
        appendCanonical(value.bitPattern, to: &hasher)
    }

    private static func appendCanonical(_ values: [String], to hasher: inout SHA256) {
        appendCanonical(UInt64(values.count), to: &hasher)
        for value in values {
            appendCanonical(value, to: &hasher)
        }
    }

    private static func appendCanonical(_ value: Data, to hasher: inout SHA256) {
        appendCanonical(UInt64(value.count), to: &hasher)
        hasher.update(data: value)
    }

    private static func appendCanonical(_ value: UInt64, to hasher: inout SHA256) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { hasher.update(bufferPointer: $0) }
    }

    private func lastError() -> TaptionPlanV3StoreError {
        guard let database else {
            return .database(code: SQLITE_MISUSE, message: "Database is closed")
        }
        return Self.error(
            code: sqlite3_errcode(database),
            message: String(cString: sqlite3_errmsg(database))
        )
    }

    private static func error(code: Int32, message: String) -> TaptionPlanV3StoreError {
        if code == SQLITE_CORRUPT || code == SQLITE_NOTADB {
            return .databaseCorrupt(message: message)
        }
        return .database(code: code, message: message)
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
