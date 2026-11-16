import CSQLite
import CryptoKit
import Foundation

extension TaptionPlanV3Store {
    nonisolated static func initializeDatabase(_ database: OpaquePointer) throws {
        try sqliteExecute(database, "PRAGMA busy_timeout=5000;")
        try enableWriteAheadLog(database)
        try sqliteExecute(database, "PRAGMA synchronous=NORMAL;")
        let hasSchemaTable = try sqliteTableExists(database, "schema_meta")
        if hasSchemaTable {
            let version = try sqliteSchemaVersion(database)
            guard version == Self.schemaVersion else {
                throw TaptionPlanV3StoreError.unsupportedSchema(version)
            }
            guard try sqliteTableExists(database, "raw_events"),
                  try sqliteTableExists(database, "day_materialized") else {
                throw TaptionPlanV3StoreError.databaseCorrupt(
                    message: "Missing v3 storage table"
                )
            }
            try sqliteExecute(
                database,
                """
                CREATE INDEX IF NOT EXISTS raw_events_day_time_index
                    ON raw_events(device, day_key, timestamp, sequence, id, domain);
                CREATE INDEX IF NOT EXISTS raw_events_domain_day_time_index
                    ON raw_events(device, day_key, domain, timestamp, sequence, id);
                CREATE INDEX IF NOT EXISTS day_materialized_day_index
                    ON day_materialized(device, day_key);
                """
            )
            try sqliteExecute(
                database,
                """
                CREATE TABLE IF NOT EXISTS raw_restore_receipts(
                    device TEXT NOT NULL, session TEXT NOT NULL, domain TEXT NOT NULL,
                    id TEXT NOT NULL, event BLOB NOT NULL,
                    PRIMARY KEY(device,session,domain,id)
                );
                CREATE TABLE IF NOT EXISTS migration_markers(
                    key TEXT NOT NULL PRIMARY KEY,
                    completed_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS raw_digest_cache(
                    device TEXT NOT NULL,
                    day_key TEXT NOT NULL,
                    event_count INTEGER NOT NULL,
                    first_timestamp REAL,
                    last_timestamp REAL,
                    sha256 TEXT NOT NULL,
                    PRIMARY KEY(device, day_key)
                );
                CREATE TABLE IF NOT EXISTS device_outbox(
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    device TEXT NOT NULL,
                    id TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    payload BLOB NOT NULL,
                    UNIQUE(device, id)
                );
                CREATE INDEX IF NOT EXISTS device_outbox_device_sequence_index
                    ON device_outbox(device, sequence);
                """
            )
            try Self.clearLegacyRawDigestCache(database)
            try sqliteExecute(database, "PRAGMA optimize;")
            return
        }

        guard try sqliteUserTableCount(database) == 0 else {
            throw TaptionPlanV3StoreError.unsupportedSchema(0)
        }
        try sqliteExecute(database, "BEGIN IMMEDIATE TRANSACTION;")
        do {
            if try sqliteTableExists(database, "schema_meta") {
                try sqliteExecute(database, "ROLLBACK;")
                try Self.initializeDatabase(database)
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
            CREATE INDEX raw_events_domain_day_time_index
                ON raw_events(device, day_key, domain, timestamp, sequence, id);
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
            CREATE TABLE raw_restore_receipts(
                device TEXT NOT NULL, session TEXT NOT NULL, domain TEXT NOT NULL,
                id TEXT NOT NULL, event BLOB NOT NULL,
                PRIMARY KEY(device,session,domain,id)
            );
            CREATE TABLE migration_markers(
                key TEXT NOT NULL PRIMARY KEY,
                completed_at REAL NOT NULL
            );
            CREATE TABLE raw_digest_cache(
                device TEXT NOT NULL,
                day_key TEXT NOT NULL,
                event_count INTEGER NOT NULL,
                first_timestamp REAL,
                last_timestamp REAL,
                sha256 TEXT NOT NULL,
                PRIMARY KEY(device, day_key)
            );
            CREATE TABLE device_outbox(
                sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                device TEXT NOT NULL,
                id TEXT NOT NULL,
                kind TEXT NOT NULL,
                payload BLOB NOT NULL,
                UNIQUE(device, id)
            );
            CREATE INDEX device_outbox_device_sequence_index
                ON device_outbox(device, sequence);
            """
            )
            try sqliteExecute(database, "COMMIT;")
        } catch {
            try? sqliteExecute(database, "ROLLBACK;")
            throw error
        }
        try Self.clearLegacyRawDigestCache(database)
        try sqliteExecute(database, "PRAGMA optimize;")
    }

    private nonisolated static func enableWriteAheadLog(
        _ database: OpaquePointer
    ) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while true {
            do {
                try sqliteExecute(database, "PRAGMA journal_mode=WAL;")
                return
            } catch {
                guard let storeError = error as? TaptionPlanV3StoreError,
                      case let .database(code, _) = storeError,
                      code == SQLITE_BUSY,
                      ProcessInfo.processInfo.systemUptime < deadline else {
                    throw error
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
    }

    private nonisolated static func clearLegacyRawDigestCache(
        _ database: OpaquePointer
    ) throws {
        guard try !hasMigrationMarker(database) else { return }
        try sqliteExecute(database, "BEGIN IMMEDIATE TRANSACTION;")
        do {
            try sqliteExecute(
                database,
                """
                INSERT OR IGNORE INTO migration_markers(key, completed_at)
                VALUES ('\(Self.rawDigestCacheAtomicWriteMarker)',
                        CAST(strftime('%s', 'now') AS REAL));
                """
            )
            if sqlite3_changes(database) == 1 {
                try sqliteExecute(database, "DELETE FROM raw_digest_cache;")
            }
            try sqliteExecute(database, "COMMIT;")
        } catch {
            try? sqliteExecute(database, "ROLLBACK;")
            throw error
        }
    }

    private nonisolated static func hasMigrationMarker(
        _ database: OpaquePointer
    ) throws -> Bool {
        let statement = try sqlitePrepare(
            database,
            "SELECT 1 FROM migration_markers WHERE key = ? LIMIT 1;"
        )
        defer { sqlite3_finalize(statement) }
        try sqliteBind(
            Self.rawDigestCacheAtomicWriteMarker,
            to: statement,
            at: 1,
            database: database
        )
        return try sqliteStep(database, statement) == SQLITE_ROW
    }

    nonisolated static func applyFileProtection(to url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    nonisolated static func validateExistingDatabase(at url: URL) throws {
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
            guard try sqliteTableExists(handle, "raw_events"),
                  try sqliteTableExists(handle, "day_materialized") else {
                throw TaptionPlanV3StoreError.databaseCorrupt(
                    message: "Missing v3 storage table"
                )
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
}
