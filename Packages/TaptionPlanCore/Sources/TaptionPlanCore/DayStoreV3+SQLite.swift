import CSQLite
import CryptoKit
import Foundation

extension TaptionPlanV3Store {
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

    func readRawEvent(_ statement: OpaquePointer) throws -> TaptionPlanRawEvent {
        guard let deviceValue = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
              let device = TaptionPlanStoreDevice(rawValue: deviceValue),
              let dayValue = sqlite3_column_text(statement, 1).map({ String(cString: $0) }),
              let day = parseDayKey(dayValue),
              let id = sqlite3_column_text(statement, 4).map({ String(cString: $0) }),
              !id.isEmpty,
              let domain = sqlite3_column_text(statement, 5).map({ String(cString: $0) }),
              !domain.isEmpty else {
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

    func readMaterializedDay(
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

    func withTransaction<Result>(
        _ body: () throws -> Result
    ) throws -> Result {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let result = try body()
            try execute("COMMIT;")
            return result
        } catch {
            _ = try? execute("ROLLBACK;")
            throw error
        }
    }

    func withReadTransaction<Result>(
        _ body: () throws -> Result
    ) throws -> Result {
        try execute("BEGIN DEFERRED TRANSACTION;")
        do {
            let result = try body()
            try execute("COMMIT;")
            return result
        } catch {
            _ = try? execute("ROLLBACK;")
            throw error
        }
    }

    func currentRawEventPageScanState() throws -> RawEventPageScanState {
        RawEventPageScanState(
            storeID: rawEventPageStoreID,
            rawEventRevision: rawEventRevision,
            dataVersion: try currentDataVersion()
        )
    }

    func execute(
        _ sql: String,
        binds: ((OpaquePointer) throws -> Void)? = nil
    ) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try binds?(statement)
        guard try step(statement) == SQLITE_DONE else { throw lastError() }
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        guard let database else { throw lastError() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw lastError()
        }
        return statement
    }

    func step(_ statement: OpaquePointer) throws -> Int32 {
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw lastError() }
        return result
    }

    func reset(_ statement: OpaquePointer) throws {
        guard sqlite3_reset(statement) == SQLITE_OK,
              sqlite3_clear_bindings(statement) == SQLITE_OK else {
            throw lastError()
        }
    }

    func bind(_ value: String, to statement: OpaquePointer, at index: Int32) throws {
        guard sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient) == SQLITE_OK else {
            throw lastError()
        }
    }

    func bindText(_ value: Data, to statement: OpaquePointer, at index: Int32) throws {
        guard value.count <= Int(Int32.max) else {
            throw TaptionPlanV3StoreError.integerOverflow
        }
        let result = value.withUnsafeBytes { bytes in
            sqlite3_bind_text(
                statement,
                index,
                bytes.baseAddress?.assumingMemoryBound(to: CChar.self),
                Int32(value.count),
                Self.sqliteTransient
            )
        }
        guard result == SQLITE_OK else { throw lastError() }
    }

    func bind(_ value: UInt64, to statement: OpaquePointer, at index: Int32) throws {
        guard value <= UInt64(Int64.max) else {
            throw TaptionPlanV3StoreError.integerOverflow
        }
        try bind(Int64(value), to: statement, at: index)
    }

    func bind(_ value: Int64, to statement: OpaquePointer, at index: Int32) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else { throw lastError() }
    }

    func bind(_ value: TimeInterval?, to statement: OpaquePointer, at index: Int32) throws {
        let result: Int32
        if let value {
            result = sqlite3_bind_double(statement, index, value)
        } else {
            result = sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else { throw lastError() }
    }

    func bind(_ value: Data, to statement: OpaquePointer, at index: Int32) throws {
        if value.isEmpty {
            guard sqlite3_bind_zeroblob(statement, index, 0) == SQLITE_OK else { throw lastError() }
            return
        }
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

    func readData(_ statement: OpaquePointer, at index: Int32) -> Data {
        let length = Int(sqlite3_column_bytes(statement, index))
        guard length > 0, let bytes = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: bytes, count: length)
    }

    func currentDataVersion() throws -> Int64 {
        let statement = try prepare("PRAGMA data_version;")
        defer { sqlite3_finalize(statement) }
        guard try step(statement) == SQLITE_ROW else { throw lastError() }
        return sqlite3_column_int64(statement, 0)
    }

    func persistedRawDigest(
        for day: TaptionPlanDayKey
    ) throws -> TaptionPlanDayDigest? {
        let statement = try prepare(
            """
            SELECT event_count, first_timestamp, last_timestamp, sha256
            FROM raw_digest_cache
            WHERE device = ? AND day_key = ?;
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(device.rawValue, to: statement, at: 1)
        try bind(Self.dayKey(day), to: statement, at: 2)
        guard try step(statement) == SQLITE_ROW else { return nil }
        let count = sqlite3_column_int64(statement, 0)
        guard let eventCount = Int(exactly: count), eventCount >= 0,
              let sha256 = sqlite3_column_text(statement, 3).map({
                  String(cString: $0)
              }), !sha256.isEmpty else {
            throw TaptionPlanV3StoreError.databaseCorrupt(
                message: "Invalid persisted raw digest"
            )
        }
        let firstTimestamp = sqlite3_column_type(statement, 1) == SQLITE_NULL
            ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
        let lastTimestamp = sqlite3_column_type(statement, 2) == SQLITE_NULL
            ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
        return TaptionPlanDayDigest(
            device: device,
            day: day,
            eventCount: eventCount,
            firstTimestamp: firstTimestamp,
            lastTimestamp: lastTimestamp,
            sha256: sha256
        )
    }

    func persistRawDigest(_ digest: TaptionPlanDayDigest) throws {
        try execute(
            """
            INSERT INTO raw_digest_cache(
                device, day_key, event_count, first_timestamp,
                last_timestamp, sha256
            ) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(device, day_key) DO UPDATE SET
                event_count = excluded.event_count,
                first_timestamp = excluded.first_timestamp,
                last_timestamp = excluded.last_timestamp,
                sha256 = excluded.sha256;
            """,
            binds: { statement in
                try self.bind(digest.device.rawValue, to: statement, at: 1)
                try self.bind(Self.dayKey(digest.day), to: statement, at: 2)
                guard let eventCount = Int64(exactly: digest.eventCount) else {
                    throw TaptionPlanV3StoreError.integerOverflow
                }
                try self.bind(eventCount, to: statement, at: 3)
                try self.bind(digest.firstTimestamp?.timeIntervalSince1970, to: statement, at: 4)
                try self.bind(digest.lastTimestamp?.timeIntervalSince1970, to: statement, at: 5)
                try self.bind(digest.sha256, to: statement, at: 6)
            }
        )
    }

    func removePersistedRawDigests(
        for days: Set<TaptionPlanDayKey>
    ) throws {
        guard !days.isEmpty else { return }
        let statement = try prepare(
            "DELETE FROM raw_digest_cache WHERE device = ? AND day_key = ?;"
        )
        defer { sqlite3_finalize(statement) }
        for day in days {
            try reset(statement)
            try bind(device.rawValue, to: statement, at: 1)
            try bind(Self.dayKey(day), to: statement, at: 2)
            guard try step(statement) == SQLITE_DONE else { throw lastError() }
        }
    }

    func cachedRawDigest(
        for day: TaptionPlanDayKey,
        dataVersion: Int64
    ) -> TaptionPlanDayDigest? {
        guard let cached = rawDigestCache.value(for: day),
              cached.dataVersion == dataVersion else {
            removeCachedRawDigest(for: day)
            return nil
        }
        return cached.digest
    }

    func cacheRawDigest(
        _ digest: TaptionPlanDayDigest,
        for day: TaptionPlanDayKey,
        dataVersion: Int64
    ) {
        rawDigestCache.insert((dataVersion, digest), for: day)
    }

    func removeCachedRawDigest(for day: TaptionPlanDayKey) {
        rawDigestCache.removeValue(for: day)
    }

    func readUInt64(_ value: Int64) throws -> UInt64 {
        guard value >= 0 else {
            throw TaptionPlanV3StoreError.databaseCorrupt(message: "Negative unsigned value")
        }
        return UInt64(value)
    }

    func encodeProvenance(_ values: [String]) throws -> Data {
        try JSONEncoder().encode(values)
    }

    func decodeProvenance(_ data: Data) throws -> [String] {
        do {
            return try JSONDecoder().decode([String].self, from: data)
        } catch {
            throw TaptionPlanV3StoreError.databaseCorrupt(message: "Invalid provenance payload")
        }
    }

    static func dayKey(_ day: TaptionPlanDayKey) -> String {
        String(format: "%04d-%02d-%02d", day.year, day.month, day.day)
    }

    func parseDayKey(_ value: String) -> TaptionPlanDayKey? {
        TaptionPlanDayKey(storageKey: value)
    }

    static func appendCanonical(_ value: String, to hasher: inout SHA256) {
        appendCanonical(Data(value.utf8), to: &hasher)
    }

    static func appendCanonical(_ value: TimeInterval, to hasher: inout SHA256) {
        appendCanonical(value.bitPattern, to: &hasher)
    }

    static func appendCanonical(_ values: [String], to hasher: inout SHA256) {
        appendCanonical(UInt64(values.count), to: &hasher)
        for value in values {
            appendCanonical(value, to: &hasher)
        }
    }

    static func appendCanonical(_ value: Data, to hasher: inout SHA256) {
        appendCanonical(UInt64(value.count), to: &hasher)
        hasher.update(data: value)
    }

    static func appendCanonicalBlob(
        _ statement: OpaquePointer,
        at index: Int32,
        to hasher: inout SHA256
    ) throws {
        let length = Int(sqlite3_column_bytes(statement, index))
        appendCanonical(UInt64(length), to: &hasher)
        guard length > 0 else { return }
        guard let bytes = sqlite3_column_blob(statement, index) else {
            throw TaptionPlanV3StoreError.databaseCorrupt(
                message: "Invalid raw event payload"
            )
        }
        hasher.update(
            bufferPointer: UnsafeRawBufferPointer(start: bytes, count: length)
        )
    }

    static func appendCanonical(_ value: UInt64, to hasher: inout SHA256) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { hasher.update(bufferPointer: $0) }
    }

    func lastError() -> TaptionPlanV3StoreError {
        guard let database else {
            return .database(code: SQLITE_MISUSE, message: "Database is closed")
        }
        return Self.error(
            code: sqlite3_errcode(database),
            message: String(cString: sqlite3_errmsg(database))
        )
    }

    static func error(code: Int32, message: String) -> TaptionPlanV3StoreError {
        if code == SQLITE_CORRUPT || code == SQLITE_NOTADB {
            return .databaseCorrupt(message: message)
        }
        return .database(code: code, message: message)
    }
}
