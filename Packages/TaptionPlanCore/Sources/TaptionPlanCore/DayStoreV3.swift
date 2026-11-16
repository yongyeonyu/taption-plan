import CSQLite
import CryptoKit
import Foundation

func exactlyEqual(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.elementsEqual(rhs.utf8)
}

func exactBytesPrecede(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
}

func hashExactBytes(_ value: String, into hasher: inout Hasher) {
    hasher.combine(value.utf8.count)
    for byte in value.utf8 {
        hasher.combine(byte)
    }
}

func containsNUL(_ value: String) -> Bool {
    value.utf8.contains(0)
}

/// SQLite v3 storage for append-only device events and one derived row per day.
/// The actor owns the connection so a prepared statement is never used across
/// concurrent callers and the raw table remains the source of truth.
public actor TaptionPlanV3Store {
    public static let maximumRawEventPageSize = 1_024
    public static let defaultRawEventPageBytes = 1 * 1_024 * 1_024
    public static let maximumRawEventPageBytes = 4 * 1_024 * 1_024
    public static let schemaVersion = 3
    public static let projectionVersion: UInt64 = 5 // 5: classifier-v1(ALG1101A01)
    static let rawDigestCacheCapacity = 64
    static let rawDigestCacheAtomicWriteMarker =
        "raw_digest_cache_atomic_write_v1"

    public let device: TaptionPlanStoreDevice
    nonisolated(unsafe) var database: OpaquePointer?
    let rawEventPageStoreID = UUID()
    var rawEventRevision: UInt64 = 0
    var rawDigestCache = TaptionBoundedCache<
        TaptionPlanDayKey, (dataVersion: Int64, digest: TaptionPlanDayDigest)
    >(capacity: rawDigestCacheCapacity)
    var rawDigestCacheCount: Int { rawDigestCache.count }

    public init(url: URL, device: TaptionPlanStoreDevice) throws {
        self.device = device
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Self.applyFileProtection(to: directory)

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
            try Self.applyFileProtection(to: url)
            try Self.applyFileProtection(
                to: URL(fileURLWithPath: url.path + "-wal")
            )
            try Self.applyFileProtection(
                to: URL(fileURLWithPath: url.path + "-shm")
            )
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

    @discardableResult
    public func appendRawEvents(
        _ events: [TaptionPlanRawEvent]
    ) throws -> Set<TaptionPlanRawEventIdentifier> {
        try appendRawEvents(events, outboxItems: [])
    }

    @discardableResult
    public func appendRawEvents(
        _ events: [TaptionPlanRawEvent],
        outboxItems: [TaptionPlanV3OutboxItem],
        restoreSessionID: UUID? = nil
    ) throws -> Set<TaptionPlanRawEventIdentifier> {
        try validate(events)
        try validate(outboxItems)
        guard !events.isEmpty || !outboxItems.isEmpty else { return [] }
        let insertedIDs = try withTransaction {
            let insertedIDs = try insertRawEvents(events)
            try insertOutboxItems(outboxItems)
            if let restoreSessionID {
                for event in events where insertedIDs.contains(.init(domain: event.domain, id: event.id)) {
                    let receipt = try prepare("INSERT INTO raw_restore_receipts(device,session,domain,id,event) VALUES(?,?,?,?,?);")
                    defer { sqlite3_finalize(receipt) }
                    try bind(device.rawValue, to: receipt, at: 1)
                    try bind(restoreSessionID.uuidString, to: receipt, at: 2)
                    try bind(event.domain, to: receipt, at: 3)
                    try bind(event.id, to: receipt, at: 4)
                    try bind(JSONEncoder().encode(event), to: receipt, at: 5)
                    guard try step(receipt) == SQLITE_DONE else { throw lastError() }
                }
            }
            let insertedDays = Set(events.lazy.compactMap { event in
                insertedIDs.contains(
                    .init(domain: event.domain, id: event.id)
                ) ? event.day : nil
            })
            try removePersistedRawDigests(for: insertedDays)
            return insertedIDs
        }
        if !insertedIDs.isEmpty { rawEventRevision &+= 1 }
        let insertedDays = Set(events.lazy.compactMap { event in
            insertedIDs.contains(
                .init(domain: event.domain, id: event.id)
            ) ? event.day : nil
        })
        for day in insertedDays {
            removeCachedRawDigest(for: day)
        }
        return insertedIDs
    }

    public func finishRestoreSession(_ sessionID: UUID, committed: Bool) throws {
        let changedDays = try withTransaction { () throws -> Set<TaptionPlanDayKey> in
            var changed: Set<TaptionPlanDayKey> = []
            if !committed {
                while true {
                    let page = try prepare("SELECT event FROM raw_restore_receipts WHERE device=? AND session=? LIMIT 256;")
                    var events: [TaptionPlanRawEvent] = []
                    do {
                        defer { sqlite3_finalize(page) }
                        try bind(device.rawValue, to: page, at: 1)
                        try bind(sessionID.uuidString, to: page, at: 2)
                        while try step(page) == SQLITE_ROW {
                            events.append(try JSONDecoder().decode(TaptionPlanRawEvent.self, from: readData(page, at: 0)))
                        }
                    }
                    if events.isEmpty { break }
                    for event in events {
                        let lookup = try prepare("SELECT device,day_key,timestamp,sequence,id,domain,provenance,payload FROM raw_events WHERE device=? AND domain=? AND id=?;")
                        defer { sqlite3_finalize(lookup) }
                        try bind(device.rawValue, to: lookup, at: 1)
                        try bind(event.domain, to: lookup, at: 2)
                        try bind(event.id, to: lookup, at: 3)
                        if try step(lookup) == SQLITE_ROW, try readRawEvent(lookup) == event {
                            let delete = try prepare("DELETE FROM raw_events WHERE device=? AND domain=? AND id=?;")
                            defer { sqlite3_finalize(delete) }
                            try bind(device.rawValue, to: delete, at: 1)
                            try bind(event.domain, to: delete, at: 2)
                            try bind(event.id, to: delete, at: 3)
                            guard try step(delete) == SQLITE_DONE else { throw lastError() }
                            changed.insert(event.day)
                        }
                        let receipt = try prepare("DELETE FROM raw_restore_receipts WHERE device=? AND session=? AND domain=? AND id=?;")
                        defer { sqlite3_finalize(receipt) }
                        try bind(device.rawValue, to: receipt, at: 1)
                        try bind(sessionID.uuidString, to: receipt, at: 2)
                        try bind(event.domain, to: receipt, at: 3)
                        try bind(event.id, to: receipt, at: 4)
                        guard try step(receipt) == SQLITE_DONE else { throw lastError() }
                    }
                }
            }
            let clear = try prepare("DELETE FROM raw_restore_receipts WHERE device=? AND session=?;")
            defer { sqlite3_finalize(clear) }
            try bind(device.rawValue, to: clear, at: 1)
            try bind(sessionID.uuidString, to: clear, at: 2)
            guard try step(clear) == SQLITE_DONE else { throw lastError() }
            try removePersistedRawDigests(for: changed)
            return changed
        }
        if !changedDays.isEmpty { rawEventRevision &+= 1 }
        for day in changedDays { removeCachedRawDigest(for: day) }
    }

    public func pendingOutboxItems(
        limit: Int = 50
    ) throws -> [TaptionPlanV3OutboxItem] {
        let boundedLimit = min(max(limit, 1), 256)
        let statement = try prepare(
            """
            SELECT id, kind, payload
            FROM device_outbox
            WHERE device = ?
            ORDER BY sequence
            LIMIT ?;
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(device.rawValue, to: statement, at: 1)
        try bind(Int64(boundedLimit), to: statement, at: 2)
        var items: [TaptionPlanV3OutboxItem] = []
        while try step(statement) == SQLITE_ROW {
            guard let id = sqlite3_column_text(statement, 0).map({
                String(cString: $0)
            }), let kind = sqlite3_column_text(statement, 1).map({
                String(cString: $0)
            }) else {
                throw TaptionPlanV3StoreError.databaseCorrupt(
                    message: "Invalid outbox item"
                )
            }
            items.append(
                TaptionPlanV3OutboxItem(
                    id: id,
                    kind: kind,
                    payload: readData(statement, at: 2)
                )
            )
        }
        return items
    }

    public func deleteOutboxItems(ids: [String]) throws {
        guard ids.allSatisfy({ !$0.isEmpty && !containsNUL($0) }) else {
            throw TaptionPlanV3StoreError.invalidIdentifier
        }
        guard !ids.isEmpty else { return }
        let statement = try prepare(
            "DELETE FROM device_outbox WHERE device = ? AND id = ?;"
        )
        defer { sqlite3_finalize(statement) }
        try withTransaction {
            for id in ids {
                try reset(statement)
                try bind(device.rawValue, to: statement, at: 1)
                try bind(id, to: statement, at: 2)
                guard try step(statement) == SQLITE_DONE else {
                    throw lastError()
                }
            }
        }
    }

    public func replaceMaterializedDay(_ materialized: TaptionPlanMaterializedDay) throws {
        try withTransaction {
            try writeMaterializedDay(materialized)
        }
    }

    @discardableResult
    public func replaceMaterializedDay(
        _ materialized: TaptionPlanMaterializedDay,
        onlyIfCurrent expected: TaptionPlanMaterializedDay?
    ) throws -> Bool {
        guard materialized.device == device,
              expected == nil
                || (expected?.device == device
                    && expected?.day == materialized.day) else {
            throw TaptionPlanV3StoreError.invalidDevice
        }
        return try withTransaction {
            let current = try materializedDay(for: materialized.day)
            if let expected {
                guard let current,
                      Self.matchesMaterializedProjection(current, expected) else {
                    return false
                }
            } else if current != nil {
                return false
            }
            try writeMaterializedDay(materialized)
            return true
        }
    }

    @discardableResult
    public func restoreMaterializedDay(
        _ previous: TaptionPlanMaterializedDay?,
        for day: TaptionPlanDayKey,
        onlyIfCurrent expected: TaptionPlanMaterializedDay
    ) throws -> Bool {
        try validate(day: day)
        guard expected.device == device, expected.day == day,
              previous == nil || (previous?.device == device && previous?.day == day) else {
            throw TaptionPlanV3StoreError.invalidDevice
        }
        return try withTransaction {
            guard let current = try materializedDay(for: day),
                  Self.matchesMaterializedProjection(current, expected) else {
                return false
            }
            if let previous {
                try writeMaterializedDay(previous)
            } else {
                try removeMaterializedDay(for: day)
            }
            return true
        }
    }

    private static func matchesMaterializedProjection(
        _ lhs: TaptionPlanMaterializedDay,
        _ rhs: TaptionPlanMaterializedDay
    ) -> Bool {
        lhs.device == rhs.device
            && lhs.day == rhs.day
            && lhs.sourceRevision == rhs.sourceRevision
            && lhs.projectionVersion == rhs.projectionVersion
            && lhs.generatedAt.timeIntervalSince1970
                == rhs.generatedAt.timeIntervalSince1970
            && lhs.rawDigest == rhs.rawDigest
            && lhs.rawEventCount == rhs.rawEventCount
            && sameStoredTimestamp(lhs.firstTimestamp, rhs.firstTimestamp)
            && sameStoredTimestamp(lhs.lastTimestamp, rhs.lastTimestamp)
            && lhs.payload == rhs.payload
    }

    private static func sameStoredTimestamp(
        _ lhs: Date?,
        _ rhs: Date?
    ) -> Bool {
        lhs?.timeIntervalSince1970 == rhs?.timeIntervalSince1970
    }

    public func materializedDay(
        for day: TaptionPlanDayKey
    ) throws -> TaptionPlanMaterializedDay? {
        try validate(day: day)
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
        try validate(day: day)
        let statement = try prepare(
            "DELETE FROM day_materialized WHERE device = ? AND day_key = ?;"
        )
        defer { sqlite3_finalize(statement) }
        try bind(device.rawValue, to: statement, at: 1)
        try bind(Self.dayKey(day), to: statement, at: 2)
        guard try step(statement) == SQLITE_DONE else { throw lastError() }
    }

    private func writeMaterializedDay(
        _ materialized: TaptionPlanMaterializedDay
    ) throws {
        guard materialized.device == device else {
            throw TaptionPlanV3StoreError.invalidDevice
        }
        try validate(day: materialized.day)
        guard !materialized.rawDigest.isEmpty else {
            throw TaptionPlanV3StoreError.materializationMismatch
        }
        guard let rawEventCount = Int64(exactly: materialized.rawEventCount),
              rawEventCount >= 0 else {
            throw TaptionPlanV3StoreError.integerOverflow
        }
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

    public func deleteAllData() throws {
        guard let database else { throw lastError() }
        var deletedRawEvents = false
        try withTransaction {
            try execute(
                "DELETE FROM raw_events WHERE device = ?;",
                binds: { statement in
                    try self.bind(self.device.rawValue, to: statement, at: 1)
                }
            )
            deletedRawEvents = sqlite3_changes(database) > 0
            try execute("DELETE FROM raw_restore_receipts WHERE device=?;", binds: { statement in
                try self.bind(self.device.rawValue, to: statement, at: 1)
            })
            try execute(
                "DELETE FROM day_materialized WHERE device = ?;",
                binds: { statement in
                    try self.bind(self.device.rawValue, to: statement, at: 1)
                }
            )
            try execute(
                "DELETE FROM raw_digest_cache WHERE device = ?;",
                binds: { statement in
                    try self.bind(self.device.rawValue, to: statement, at: 1)
                }
            )
            try execute(
                "DELETE FROM device_outbox WHERE device = ?;",
                binds: { statement in
                    try self.bind(self.device.rawValue, to: statement, at: 1)
                }
            )
        }
        if deletedRawEvents { rawEventRevision &+= 1 }
        rawDigestCache.removeAll(keepingCapacity: true)
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
        try optimize()
    }

    public func optimize() throws {
        try execute("PRAGMA optimize;")
    }

    public func markMigrationCompleted(_ key: String, at date: Date = .now) throws -> Bool {
        guard !key.isEmpty, !containsNUL(key) else {
            throw TaptionPlanV3StoreError.invalidIdentifier
        }
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
        guard !key.isEmpty, !containsNUL(key) else {
            throw TaptionPlanV3StoreError.invalidIdentifier
        }
        let statement = try prepare(
            "SELECT 1 FROM migration_markers WHERE key = ? LIMIT 1;"
        )
        defer { sqlite3_finalize(statement) }
        try bind(key, to: statement, at: 1)
        return try step(statement) == SQLITE_ROW
    }

    static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
