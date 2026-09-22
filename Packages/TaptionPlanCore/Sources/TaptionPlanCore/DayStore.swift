import Foundation
import CSQLite

private func exactlyEqual(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.elementsEqual(rhs.utf8)
}

private func hashExactBytes(_ value: String, into hasher: inout Hasher) {
    hasher.combine(value.utf8.count)
    for byte in value.utf8 {
        hasher.combine(byte)
    }
}

public enum TaptionPlanDayStoreError: Error, Equatable, Sendable {
    case invalidDay
    case invalidDomain
    case invalidIdentifier
    case invalidMetadataKey
    case invalidMigrationKey
    case eventConflict(id: String)
    case revisionOverflow
    case database(code: Int32, message: String)
    case databaseCorrupt(message: String)
}

public struct TaptionPlanMapDayCacheKey: Hashable, Sendable {
    public let day: TaptionPlanDayKey
    public let algorithmKey: String
    public let styleKey: String

    public init(day: TaptionPlanDayKey, algorithmKey: String, styleKey: String) {
        self.day = day
        self.algorithmKey = algorithmKey
        self.styleKey = styleKey
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.day == rhs.day
            && exactlyEqual(lhs.algorithmKey, rhs.algorithmKey)
            && exactlyEqual(lhs.styleKey, rhs.styleKey)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(day)
        hashExactBytes(algorithmKey, into: &hasher)
        hashExactBytes(styleKey, into: &hasher)
    }
}

public struct TaptionPlanMapDayDocument: Hashable, Sendable {
    public let key: TaptionPlanMapDayCacheKey
    public let revision: UInt64
    public let updatedAt: Date
    public let payload: Data

    public init(
        key: TaptionPlanMapDayCacheKey,
        revision: UInt64,
        updatedAt: Date,
        payload: Data
    ) {
        self.key = key
        self.revision = revision
        self.updatedAt = updatedAt
        self.payload = payload
    }
}

public actor TaptionPlanDayStore {
    public struct EventIdentifier: Hashable, Sendable {
        public let rawValue: String

        public init(_ rawValue: String) {
            self.rawValue = rawValue
        }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            exactlyEqual(lhs.rawValue, rhs.rawValue)
        }

        public func hash(into hasher: inout Hasher) {
            hashExactBytes(rawValue, into: &hasher)
        }
    }

    public struct Snapshot: Hashable, Sendable {
        public let domain: String
        public let day: TaptionPlanDayKey
        public let revision: UInt64
        public let updatedAt: Date
        public let payload: Data

        public static func == (lhs: Self, rhs: Self) -> Bool {
            exactlyEqual(lhs.domain, rhs.domain)
                && lhs.day == rhs.day
                && lhs.revision == rhs.revision
                && lhs.updatedAt == rhs.updatedAt
                && lhs.payload == rhs.payload
        }

        public func hash(into hasher: inout Hasher) {
            hashExactBytes(domain, into: &hasher)
            hasher.combine(day)
            hasher.combine(revision)
            hasher.combine(updatedAt)
            hasher.combine(payload)
        }

        public init(
            domain: String,
            day: TaptionPlanDayKey,
            revision: UInt64,
            updatedAt: Date,
            payload: Data
        ) {
            self.domain = domain
            self.day = day
            self.revision = revision
            self.updatedAt = updatedAt
            self.payload = payload
        }
    }

    public struct Event: Hashable, Sendable {
        public let day: TaptionPlanDayKey
        public let timestamp: Date
        public let sequence: UInt64
        public let id: String
        public let domain: String
        public let payload: Data

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.day == rhs.day
                && lhs.timestamp == rhs.timestamp
                && lhs.sequence == rhs.sequence
                && exactlyEqual(lhs.id, rhs.id)
                && exactlyEqual(lhs.domain, rhs.domain)
                && lhs.payload == rhs.payload
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(day)
            hasher.combine(timestamp)
            hasher.combine(sequence)
            hashExactBytes(id, into: &hasher)
            hashExactBytes(domain, into: &hasher)
            hasher.combine(payload)
        }

        public init(
            day: TaptionPlanDayKey,
            timestamp: Date,
            sequence: UInt64,
            id: String,
            domain: String,
            payload: Data
        ) {
            self.day = day
            self.timestamp = timestamp
            self.sequence = sequence
            self.id = id
            self.domain = domain
            self.payload = payload
        }
    }

    private nonisolated(unsafe) var database: OpaquePointer?
    private let allowsUndatedSnapshots: Bool
    private static let undatedSnapshotDay = TaptionPlanDayKey(year: 0, month: 0, day: 0)
    private static let snapshotUpsertSQL =
        """
        INSERT INTO snapshots(domain, day_key, revision, updated_at, payload)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(domain, day_key) DO UPDATE SET
            revision = excluded.revision,
            updated_at = excluded.updated_at,
            payload = excluded.payload
        WHERE excluded.revision > snapshots.revision;
        """
    private static let eventInsertSQL =
        "INSERT INTO events(day_key, timestamp, sequence, id, domain, payload) VALUES (?, ?, ?, ?, ?, ?);"
    private static let uniqueEventInsertSQL =
        "INSERT INTO events(day_key, timestamp, sequence, id, domain, payload) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO NOTHING;"
    private static let eventLookupSQL =
        "SELECT day_key, timestamp, sequence, id, domain, payload FROM events WHERE id = ?;"
    private static let eventUpsertSQL =
        """
        INSERT INTO events(day_key, timestamp, sequence, id, domain, payload)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            day_key = excluded.day_key,
            timestamp = excluded.timestamp,
            sequence = excluded.sequence,
            domain = excluded.domain,
            payload = excluded.payload
        WHERE events.domain = excluded.domain;
        """
    private static let eventDeleteSQL =
        "DELETE FROM events WHERE id = ? AND domain = ?;"

    /// Opts legacy state snapshots into the 0000-00-00 key; events and map days still require dates.
    public init(url: URL, allowsUndatedSnapshots: Bool = false) throws {
        self.allowsUndatedSnapshots = allowsUndatedSnapshots
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database"
            sqlite3_close(handle)
            throw Self.error(code: SQLITE_CANTOPEN, message: message)
        }
        database = handle
        do {
            try Self.initializeDatabase(handle)
            #if os(iOS) || os(watchOS)
            try Self.applyFileProtection(to: url)
            try Self.applyFileProtection(
                to: URL(fileURLWithPath: url.path + "-wal")
            )
            try Self.applyFileProtection(
                to: URL(fileURLWithPath: url.path + "-shm")
            )
            #endif
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

    public func saveSnapshot(_ snapshot: Snapshot) throws {
        try saveSnapshots([snapshot])
    }

    /// Persists a Codable value using the canonical binary/LZFSE/checksummed format.
    public func saveCodableSnapshot<Value: Encodable>(
        _ value: Value, domain: String, day: TaptionPlanDayKey,
        revision: UInt64, updatedAt: Date = .now
    ) throws {
        let encoded = try TaptionPlanCanonicalStorage.encode(value)
        try saveSnapshot(.init(
            domain: domain,
            day: day,
            revision: revision,
            updatedAt: updatedAt,
            payload: TaptionPlanCanonicalStorage.envelope(for: encoded)
        ))
    }

    public func codableSnapshot<Value: Decodable>(
        _ type: Value.Type, domain: String, day: TaptionPlanDayKey
    ) throws -> Value? {
        guard let snapshot = try snapshot(domain: domain, day: day) else { return nil }
        let encoded = try TaptionPlanCanonicalStorage.encodedPayload(from: snapshot.payload)
        return try TaptionPlanCanonicalStorage.decode(type, from: encoded)
    }

    public func saveCodableMapDayDocument<Value: Encodable>(
        _ value: Value,
        day: TaptionPlanDayKey,
        algorithmKey: String,
        styleKey: String,
        updatedAt: Date = .now
    ) throws -> TaptionPlanMapDayDocument {
        let encoded = try TaptionPlanCanonicalStorage.encode(value)
        return try saveMapDayDocument(
            day: day,
            algorithmKey: algorithmKey,
            styleKey: styleKey,
            updatedAt: updatedAt,
            payload: TaptionPlanCanonicalStorage.envelope(for: encoded)
        )
    }

    public func codableMapDayDocument<Value: Decodable>(
        _ type: Value.Type,
        day: TaptionPlanDayKey,
        algorithmKey: String,
        styleKey: String
    ) throws -> Value? {
        guard let document = try mapDayDocument(
            day: day,
            algorithmKey: algorithmKey,
            styleKey: styleKey
        ) else { return nil }
        let encoded = try TaptionPlanCanonicalStorage.encodedPayload(from: document.payload)
        return try TaptionPlanCanonicalStorage.decode(type, from: encoded)
    }

    /// Converts an already-current canonical record once. There is intentionally no legacy decoder.
    @discardableResult
    public func convertCodableSnapshotOnce<Value: Codable>(
        _ type: Value.Type, from sourceDomain: String, to destinationDomain: String? = nil,
        day: TaptionPlanDayKey, marker: String
    ) throws -> Bool {
        guard !(try migrationCompleted(marker)) else { return false }
        guard let value = try codableSnapshot(type, domain: sourceDomain, day: day),
              let source = try snapshot(domain: sourceDomain, day: day) else { return false }
        try saveCodableSnapshot(value, domain: destinationDomain ?? sourceDomain, day: day,
                                revision: source.revision, updatedAt: source.updatedAt)
        return try markMigrationCompleted(marker)
    }

    public func saveSnapshots(_ snapshots: [Snapshot]) throws {
        guard !snapshots.isEmpty else { return }
        let statement = try prepare(Self.snapshotUpsertSQL)
        defer { sqlite3_finalize(statement) }
        try withTransaction {
            for snapshot in snapshots {
                try validate(snapshotDay: snapshot.day)
                try validate(domain: snapshot.domain)
                try reset(statement)
                try bind(snapshot.domain, to: statement, at: 1)
                try bind(dayKey(snapshot.day), to: statement, at: 2)
                try bind(snapshot.revision, to: statement, at: 3)
                try bind(snapshot.updatedAt.timeIntervalSince1970, to: statement, at: 4)
                try bind(snapshot.payload, to: statement, at: 5)
                guard try step(statement) == SQLITE_DONE else {
                    throw lastError()
                }
            }
        }
    }

    public func snapshot(domain: String, day: TaptionPlanDayKey) throws -> Snapshot? {
        try validate(snapshotDay: day)
        try validate(domain: domain)
        let statement = try prepare(
            "SELECT domain, day_key, revision, updated_at, payload FROM snapshots WHERE domain = ? AND day_key = ?;"
        )
        defer { sqlite3_finalize(statement) }
        try bind(domain, to: statement, at: 1)
        try bind(dayKey(day), to: statement, at: 2)
        guard try step(statement) == SQLITE_ROW else { return nil }
        return try readSnapshot(statement)
    }

    public func snapshots(day: TaptionPlanDayKey) throws -> [Snapshot] {
        try validate(snapshotDay: day)
        let statement = try prepare(
            "SELECT domain, day_key, revision, updated_at, payload FROM snapshots WHERE day_key = ? ORDER BY domain;"
        )
        defer { sqlite3_finalize(statement) }
        try bind(dayKey(day), to: statement, at: 1)
        var result: [Snapshot] = []
        while try step(statement) == SQLITE_ROW {
            result.append(try readSnapshot(statement))
        }
        return result
    }

    public func mapDayDocument(
        day: TaptionPlanDayKey,
        algorithmKey: String,
        styleKey: String
    ) throws -> TaptionPlanMapDayDocument? {
        let key = try mapKey(day: day, algorithmKey: algorithmKey, styleKey: styleKey)
        guard let snapshot = try snapshot(domain: mapDomain(for: key), day: day) else {
            return nil
        }
        return .init(
            key: key,
            revision: snapshot.revision,
            updatedAt: snapshot.updatedAt,
            payload: snapshot.payload
        )
    }

    @discardableResult
    public func saveMapDayDocument(
        day: TaptionPlanDayKey,
        algorithmKey: String,
        styleKey: String,
        updatedAt: Date = .now,
        payload: Data
    ) throws -> TaptionPlanMapDayDocument {
        let key = try mapKey(day: day, algorithmKey: algorithmKey, styleKey: styleKey)
        let domain = mapDomain(for: key)
        let statement = try prepare(Self.snapshotUpsertSQL)
        defer { sqlite3_finalize(statement) }
        var revision: UInt64 = 0
        try withTransaction {
            let currentRevision = try snapshot(domain: domain, day: day)?.revision ?? 0
            guard currentRevision < UInt64.max else {
                throw TaptionPlanDayStoreError.revisionOverflow
            }
            revision = currentRevision + 1
            try saveSnapshotRow(
                .init(
                    domain: domain,
                    day: day,
                    revision: revision,
                    updatedAt: updatedAt,
                    payload: payload
                ),
                using: statement
            )
        }
        return .init(
            key: key,
            revision: revision,
            updatedAt: updatedAt,
            payload: payload
        )
    }

    public func appendEvents(_ events: [Event]) throws {
        guard !events.isEmpty else { return }
        let statement = try prepare(Self.eventInsertSQL)
        defer { sqlite3_finalize(statement) }
        try withTransaction {
            for event in events {
                try validate(event: event)
                try reset(statement)
                try bind(event, to: statement)
                guard try step(statement) == SQLITE_DONE else {
                    throw lastError()
                }
            }
        }
    }

    @discardableResult
    public func appendUniqueEvents(_ events: [Event]) throws -> Set<String> {
        try validateUnambiguousStringIdentifiers(events.map(\.id))
        return Set(try appendUniqueEventIdentifiers(events).map(\.rawValue))
    }

    @discardableResult
    public func appendUniqueEventIdentifiers(
        _ events: [Event]
    ) throws -> Set<EventIdentifier> {
        guard !events.isEmpty else { return [] }
        let insert = try prepare(Self.uniqueEventInsertSQL)
        let lookup = try prepare(Self.eventLookupSQL)
        var insertedIDs = Set<EventIdentifier>()
        defer {
            sqlite3_finalize(insert)
            sqlite3_finalize(lookup)
        }
        try withTransaction {
            for event in events {
                try validate(event: event)
                try reset(insert)
                try bind(event, to: insert)
                guard try step(insert) == SQLITE_DONE else {
                    throw lastError()
                }
                guard sqlite3_changes(database) == 0 else {
                    insertedIDs.insert(EventIdentifier(event.id))
                    continue
                }
                try reset(lookup)
                try bind(event.id, to: lookup, at: 1)
                guard try step(lookup) == SQLITE_ROW else { throw lastError() }
                guard try readEvent(lookup) == event else {
                    throw TaptionPlanDayStoreError.eventConflict(id: event.id)
                }
            }
        }
        return insertedIDs
    }

    public func validateUniqueEvents(_ events: [Event]) throws {
        guard !events.isEmpty else { return }
        var candidates: [EventIdentifier: Event] = [:]
        for event in events {
            try validate(event: event)
            let id = EventIdentifier(event.id)
            if let existing = candidates[id], existing != event {
                throw TaptionPlanDayStoreError.eventConflict(id: event.id)
            }
            candidates[id] = event
        }
        let lookup = try prepare(Self.eventLookupSQL)
        defer { sqlite3_finalize(lookup) }
        for (id, event) in candidates {
            try reset(lookup)
            try bind(id.rawValue, to: lookup, at: 1)
            guard try step(lookup) == SQLITE_ROW else { continue }
            guard try readEvent(lookup) == event else {
                throw TaptionPlanDayStoreError.eventConflict(id: event.id)
            }
        }
    }

    public func upsertEvents(_ events: [Event]) throws {
        guard !events.isEmpty else { return }
        let statement = try prepare(Self.eventUpsertSQL)
        defer { sqlite3_finalize(statement) }
        try withTransaction {
            for event in events {
                try upsertEventRow(event, using: statement)
            }
        }
    }

    @discardableResult
    public func upsertEvents(
        _ events: [Event],
        onlyIfUnchangedFrom expectedEvents: [Event]
    ) throws -> Set<EventIdentifier> {
        guard !events.isEmpty else { return [] }
        var expectedByID: [EventIdentifier: Event] = [:]
        for event in expectedEvents {
            try validate(event: event)
            let id = EventIdentifier(event.id)
            if let existing = expectedByID[id], existing != event {
                throw TaptionPlanDayStoreError.eventConflict(id: event.id)
            }
            expectedByID[id] = event
        }
        var repairsByID: [EventIdentifier: Event] = [:]
        for event in events {
            try validate(event: event)
            let id = EventIdentifier(event.id)
            guard let expected = expectedByID[id],
                  exactlyEqual(expected.domain, event.domain),
                  expected.day == event.day,
                  expected.timestamp == event.timestamp,
                  expected.sequence == event.sequence else {
                throw TaptionPlanDayStoreError.eventConflict(id: event.id)
            }
            if let existing = repairsByID[id], existing != event {
                throw TaptionPlanDayStoreError.eventConflict(id: event.id)
            }
            repairsByID[id] = event
        }

        let lookup = try prepare(Self.eventLookupSQL)
        let upsert = try prepare(Self.eventUpsertSQL)
        defer {
            sqlite3_finalize(lookup)
            sqlite3_finalize(upsert)
        }
        var updatedIDs = Set<EventIdentifier>()
        try withTransaction {
            for (id, repair) in repairsByID {
                try reset(lookup)
                try bind(id.rawValue, to: lookup, at: 1)
                guard try step(lookup) == SQLITE_ROW,
                      try readEvent(lookup) == expectedByID[id] else {
                    continue
                }
                try upsertEventRow(repair, using: upsert)
                updatedIDs.insert(id)
            }
        }
        return updatedIDs
    }

    public func deleteEvents(ids: [String], domain: String) throws {
        guard !ids.isEmpty else { return }
        try validate(domain: domain)
        for id in ids { try validate(identifier: id) }
        let statement = try prepare(Self.eventDeleteSQL)
        defer { sqlite3_finalize(statement) }
        try withTransaction {
            for id in ids {
                try deleteEventRow(id: id, domain: domain, using: statement)
            }
        }
    }

    public func existingEventIDs(
        _ ids: [String],
        domain: String
    ) throws -> Set<String> {
        try validateUnambiguousStringIdentifiers(ids)
        return Set(try existingEventIdentifiers(ids, domain: domain).map(\.rawValue))
    }

    public func existingEventIdentifiers(
        _ ids: [String],
        domain: String
    ) throws -> Set<EventIdentifier> {
        guard !ids.isEmpty else { return [] }
        try validate(domain: domain)
        for id in ids { try validate(identifier: id) }
        let statement = try prepare(
            "SELECT id FROM events WHERE id = ? AND domain = ?;"
        )
        defer { sqlite3_finalize(statement) }
        var result = Set<EventIdentifier>()
        for id in ids {
            try reset(statement)
            try bind(id, to: statement, at: 1)
            try bind(domain, to: statement, at: 2)
            if try step(statement) == SQLITE_ROW {
                result.insert(EventIdentifier(id))
            }
        }
        return result
    }

    public func deleteEvents(domain: String) throws {
        try validate(domain: domain)
        try execute(
            "DELETE FROM events WHERE domain = ?;",
            binds: { statement in
                try self.bind(domain, to: statement, at: 1)
            }
        )
    }

    public func deleteAllContent() throws {
        try withTransaction {
            try execute("DELETE FROM snapshots;")
            try execute("DELETE FROM events;")
            try execute("DELETE FROM metadata;")
        }
    }

    public func applyEventDelta(
        upserting events: [Event],
        deletingIDs: [String],
        domain: String,
        snapshots: [Snapshot] = []
    ) throws {
        try validate(domain: domain)
        for event in events { try validate(event: event) }
        for id in deletingIDs { try validate(identifier: id) }
        guard events.allSatisfy({ exactlyEqual($0.domain, domain) }) else {
            throw TaptionPlanDayStoreError.invalidDomain
        }
        let upsert = events.isEmpty ? nil : try prepare(Self.eventUpsertSQL)
        let deleting = deletingIDs.isEmpty ? nil : try prepare(Self.eventDeleteSQL)
        let saving = snapshots.isEmpty ? nil : try prepare(Self.snapshotUpsertSQL)
        defer {
            sqlite3_finalize(upsert)
            sqlite3_finalize(deleting)
            sqlite3_finalize(saving)
        }
        try withTransaction {
            for event in events {
                try upsertEventRow(event, using: upsert)
            }
            for id in Set(deletingIDs.map(EventIdentifier.init)) {
                try deleteEventRow(
                    id: id.rawValue,
                    domain: domain,
                    using: deleting
                )
            }
            for snapshot in snapshots {
                try saveSnapshotRow(snapshot, using: saving)
            }
        }
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

    public func events(
        from start: TaptionPlanDayKey,
        through end: TaptionPlanDayKey,
        domain: String? = nil
    ) throws -> [Event] {
        try validate(day: start)
        try validate(day: end)
        if let domain { try validate(domain: domain) }
        let statement: OpaquePointer
        if domain == nil {
            statement = try prepare(
                "SELECT day_key, timestamp, sequence, id, domain, payload FROM events WHERE day_key >= ? AND day_key <= ? ORDER BY day_key, timestamp, sequence, id;"
            )
        } else {
            statement = try prepare(
                "SELECT day_key, timestamp, sequence, id, domain, payload FROM events WHERE day_key >= ? AND day_key <= ? AND domain = ? ORDER BY day_key, timestamp, sequence, id;"
            )
        }
        defer { sqlite3_finalize(statement) }
        try bind(dayKey(start), to: statement, at: 1)
        try bind(dayKey(end), to: statement, at: 2)
        if let domain { try bind(domain, to: statement, at: 3) }
        var result: [Event] = []
        while try step(statement) == SQLITE_ROW {
            result.append(try readEvent(statement))
        }
        return result
    }

    public func allEvents(domain: String? = nil) throws -> [Event] {
        if let domain { try validate(domain: domain) }
        let statement: OpaquePointer
        if domain == nil {
            statement = try prepare(
                "SELECT day_key, timestamp, sequence, id, domain, payload FROM events ORDER BY day_key, timestamp, sequence, id;"
            )
        } else {
            statement = try prepare(
                "SELECT day_key, timestamp, sequence, id, domain, payload FROM events WHERE domain = ? ORDER BY day_key, timestamp, sequence, id;"
            )
        }
        defer { sqlite3_finalize(statement) }
        if let domain { try bind(domain, to: statement, at: 1) }
        var result: [Event] = []
        while try step(statement) == SQLITE_ROW {
            result.append(try readEvent(statement))
        }
        return result
    }

    public func setMetadata(_ value: String, forKey key: String) throws {
        try validate(key: key, error: .invalidMetadataKey)
        try execute(
            "INSERT INTO metadata(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;",
            binds: { statement in
                try self.bind(key, to: statement, at: 1)
                try self.bind(value, to: statement, at: 2)
            }
        )
    }

    public func metadata(forKey key: String) throws -> String? {
        try validate(key: key, error: .invalidMetadataKey)
        let statement = try prepare("SELECT value FROM metadata WHERE key = ?;")
        defer { sqlite3_finalize(statement) }
        try bind(key, to: statement, at: 1)
        guard try step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_text(statement, 0).map { String(cString: $0) }
    }

    public func markMigrationCompleted(_ key: String, at date: Date = .now) throws -> Bool {
        try validate(key: key, error: .invalidMigrationKey)
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
        try validate(key: key, error: .invalidMigrationKey)
        let statement = try prepare("SELECT 1 FROM migration_markers WHERE key = ? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        try bind(key, to: statement, at: 1)
        return try step(statement) == SQLITE_ROW
    }

    private static func initializeDatabase(_ database: OpaquePointer) throws {
        let statements = [
            "PRAGMA busy_timeout=5000;",
            "PRAGMA journal_mode=WAL;",
            "PRAGMA synchronous=NORMAL;",
            "PRAGMA foreign_keys=ON;",
            """
            CREATE TABLE IF NOT EXISTS snapshots (
                domain TEXT NOT NULL,
                day_key TEXT NOT NULL,
                revision INTEGER NOT NULL,
                updated_at REAL NOT NULL,
                payload BLOB NOT NULL,
                PRIMARY KEY (domain, day_key)
            );
            CREATE TABLE IF NOT EXISTS events (
                day_key TEXT NOT NULL,
                timestamp REAL NOT NULL,
                sequence INTEGER NOT NULL,
                id TEXT NOT NULL PRIMARY KEY,
                domain TEXT NOT NULL,
                payload BLOB NOT NULL
            );
            CREATE INDEX IF NOT EXISTS events_day_time_index
                ON events(day_key, timestamp, sequence, id, domain);
            CREATE INDEX IF NOT EXISTS events_domain_day_time_index
                ON events(domain, day_key, timestamp, sequence, id);
            CREATE TABLE IF NOT EXISTS metadata (
                key TEXT NOT NULL PRIMARY KEY,
                value TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS migration_markers (
                key TEXT NOT NULL PRIMARY KEY,
                completed_at REAL NOT NULL
            );
            """
        ]
        for sql in statements {
            var message: UnsafeMutablePointer<CChar>?
            let result = sqlite3_exec(database, sql, nil, nil, &message)
            guard result == SQLITE_OK else {
                let text = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
                sqlite3_free(message)
                throw Self.error(code: result, message: text)
            }
        }
    }

    private static func applyFileProtection(to url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    private func withTransaction(_ body: () throws -> Void) throws {
        try Task.checkCancellation()
        sqlite3_progress_handler(database, 1000, { _ in
            Task<Never, Never>.isCancelled ? 1 : 0
        }, nil)
        defer { sqlite3_progress_handler(database, 0, nil, nil) }
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try body()
            try Task.checkCancellation()
            try execute("COMMIT;")
        } catch {
            sqlite3_progress_handler(database, 0, nil, nil)
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

    private func saveSnapshotRow(
        _ snapshot: Snapshot,
        using statement: OpaquePointer?
    ) throws {
        guard let statement else { throw lastError() }
        try validate(snapshotDay: snapshot.day)
        try validate(domain: snapshot.domain)
        try reset(statement)
        try bind(snapshot.domain, to: statement, at: 1)
        try bind(dayKey(snapshot.day), to: statement, at: 2)
        try bind(snapshot.revision, to: statement, at: 3)
        try bind(snapshot.updatedAt.timeIntervalSince1970, to: statement, at: 4)
        try bind(snapshot.payload, to: statement, at: 5)
        guard try step(statement) == SQLITE_DONE else { throw lastError() }
    }

    private func upsertEventRow(
        _ event: Event,
        using statement: OpaquePointer?
    ) throws {
        guard let statement else { throw lastError() }
        try validate(event: event)
        try reset(statement)
        try bind(event, to: statement)
        guard try step(statement) == SQLITE_DONE else { throw lastError() }
    }

    private func deleteEventRow(
        id: String,
        domain: String,
        using statement: OpaquePointer?
    ) throws {
        guard let statement else { throw lastError() }
        try validate(identifier: id)
        try validate(domain: domain)
        try reset(statement)
        try bind(id, to: statement, at: 1)
        try bind(domain, to: statement, at: 2)
        guard try step(statement) == SQLITE_DONE else { throw lastError() }
    }

    private func bind(_ event: Event, to statement: OpaquePointer) throws {
        try validate(event: event)
        try bind(dayKey(event.day), to: statement, at: 1)
        try bind(event.timestamp.timeIntervalSince1970, to: statement, at: 2)
        try bind(event.sequence, to: statement, at: 3)
        try bind(event.id, to: statement, at: 4)
        try bind(event.domain, to: statement, at: 5)
        try bind(event.payload, to: statement, at: 6)
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

    private func reset(_ statement: OpaquePointer) throws {
        guard sqlite3_reset(statement) == SQLITE_OK,
              sqlite3_clear_bindings(statement) == SQLITE_OK else {
            throw lastError()
        }
    }

    private func readSnapshot(_ statement: OpaquePointer) throws -> Snapshot {
        guard let domain = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
              !domain.isEmpty,
              let dayValue = sqlite3_column_text(statement, 1).map({ String(cString: $0) }),
              let day = parseSnapshotDayKey(dayValue) else {
            throw TaptionPlanDayStoreError.databaseCorrupt(
                message: "Invalid snapshot row"
            )
        }
        let revision = try readUInt64(sqlite3_column_int64(statement, 2))
        let payload = readData(statement, at: 4)
        return Snapshot(
            domain: domain,
            day: day,
            revision: revision,
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
            payload: payload
        )
    }

    private func readEvent(_ statement: OpaquePointer) throws -> Event {
        guard let dayValue = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
              let day = parseDayKey(dayValue),
              day.isValidStorageKey,
              let id = sqlite3_column_text(statement, 3).map({ String(cString: $0) }),
              !id.isEmpty,
              let domain = sqlite3_column_text(statement, 4).map({ String(cString: $0) }),
              !domain.isEmpty else {
            throw TaptionPlanDayStoreError.databaseCorrupt(
                message: "Invalid event row"
            )
        }
        return Event(
            day: day,
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
            sequence: try readUInt64(sqlite3_column_int64(statement, 2)),
            id: id,
            domain: domain,
            payload: readData(statement, at: 5)
        )
    }

    private func readData(_ statement: OpaquePointer, at index: Int32) -> Data {
        let length = Int(sqlite3_column_bytes(statement, index))
        guard length > 0, let bytes = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: bytes, count: length)
    }

    private func readUInt64(_ value: Int64) throws -> UInt64 {
        guard value >= 0 else { throw TaptionPlanDayStoreError.databaseCorrupt(message: "Negative integer in unsigned column") }
        return UInt64(value)
    }

    private func validate(domain: String) throws {
        guard !domain.isEmpty, !domain.utf8.contains(0) else {
            throw TaptionPlanDayStoreError.invalidDomain
        }
    }

    private func validate(day: TaptionPlanDayKey) throws {
        guard day.isValidStorageKey else {
            throw TaptionPlanDayStoreError.invalidDay
        }
    }

    private func validate(snapshotDay day: TaptionPlanDayKey) throws {
        if allowsUndatedSnapshots && day == Self.undatedSnapshotDay { return }
        try validate(day: day)
    }

    private func validate(identifier: String) throws {
        guard !identifier.isEmpty, !identifier.utf8.contains(0) else {
            throw TaptionPlanDayStoreError.invalidIdentifier
        }
    }

    private func validate(event: Event) throws {
        try validate(day: event.day)
        try validate(domain: event.domain)
        try validate(identifier: event.id)
    }

    private func validateUnambiguousStringIdentifiers(
        _ identifiers: [String]
    ) throws {
        let exactIdentifiers = Set(identifiers.map(EventIdentifier.init))
        guard exactIdentifiers.count == Set(identifiers).count else {
            throw TaptionPlanDayStoreError.invalidIdentifier
        }
    }

    private func mapKey(
        day: TaptionPlanDayKey,
        algorithmKey: String,
        styleKey: String
    ) throws -> TaptionPlanMapDayCacheKey {
        try validate(day: day)
        guard !algorithmKey.isEmpty, !styleKey.isEmpty,
              !algorithmKey.utf8.contains(0), !styleKey.utf8.contains(0) else {
            throw TaptionPlanDayStoreError.invalidDomain
        }
        return .init(day: day, algorithmKey: algorithmKey, styleKey: styleKey)
    }

    private func mapDomain(for key: TaptionPlanMapDayCacheKey) -> String {
        return "map:v2:\(key.algorithmKey.utf8.count):\(key.algorithmKey):"
            + "\(key.styleKey.utf8.count):\(key.styleKey)"
    }

    private func validate(key: String, error: TaptionPlanDayStoreError) throws {
        guard !key.isEmpty, !key.utf8.contains(0) else { throw error }
    }

    private func dayKey(_ day: TaptionPlanDayKey) -> String {
        String(format: "%04d-%02d-%02d", day.year, day.month, day.day)
    }

    private func parseDayKey(_ value: String) -> TaptionPlanDayKey? {
        TaptionPlanDayKey(storageKey: value)
    }

    private func parseSnapshotDayKey(_ value: String) -> TaptionPlanDayKey? {
        if allowsUndatedSnapshots && value == "0000-00-00" {
            return Self.undatedSnapshotDay
        }
        return parseDayKey(value)
    }

    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) throws {
        let result = sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient)
        guard result == SQLITE_OK else { throw lastError() }
    }

    private func bind(_ value: UInt64, to statement: OpaquePointer, at index: Int32) throws {
        guard value <= UInt64(Int64.max) else { throw TaptionPlanDayStoreError.revisionOverflow }
        let result = sqlite3_bind_int64(statement, index, Int64(value))
        guard result == SQLITE_OK else { throw lastError() }
    }

    private func bind(_ value: TimeInterval, to statement: OpaquePointer, at index: Int32) throws {
        let result = sqlite3_bind_double(statement, index, value)
        guard result == SQLITE_OK else { throw lastError() }
    }

    private func bind(_ value: Data, to statement: OpaquePointer, at index: Int32) throws {
        let result: Int32 = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(value.count), Self.sqliteTransient)
        }
        guard result == SQLITE_OK else { throw lastError() }
    }

    private func lastError() -> TaptionPlanDayStoreError {
        guard let database else { return .database(code: SQLITE_MISUSE, message: "Database is closed") }
        let code = sqlite3_errcode(database)
        let message = String(cString: sqlite3_errmsg(database))
        return Self.error(code: code, message: message)
    }

    private static func error(code: Int32, message: String) -> TaptionPlanDayStoreError {
        if code == SQLITE_CORRUPT || code == SQLITE_NOTADB {
            return .databaseCorrupt(message: message)
        }
        return .database(code: code, message: message)
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
