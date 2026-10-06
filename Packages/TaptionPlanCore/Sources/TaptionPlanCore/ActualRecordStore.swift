import Foundation
import CSQLite

extension TaptionPlanDayStore {
    public struct ActualRow: Sendable, Equatable {
        public var key: String
        public var position: Int
        public var id: String
        public var planID: String?
        public var routineID: String?
        public var title: String
        public var categoryID: String
        public var startedAt: Date
        public var endedAt: Date?
        public var source: String
        public var confidence: String
        public var createdAt: Date
        public var behavior: String?
        public var evidence: Data
        public var routeID: String?
        public var sensorChunkID: String?
        public var modelVersion: String?
        public var manuallyCorrected: Bool
        public var classificationLocked: Bool

        public init(key: String, position: Int, id: String, planID: String?, routineID: String?,
                    title: String, categoryID: String, startedAt: Date, endedAt: Date?,
                    source: String, confidence: String, createdAt: Date, behavior: String?,
                    evidence: Data, routeID: String?, sensorChunkID: String?, modelVersion: String?,
                    manuallyCorrected: Bool, classificationLocked: Bool) {
            self.key = key; self.position = position; self.id = id
            self.planID = planID; self.routineID = routineID; self.title = title
            self.categoryID = categoryID; self.startedAt = startedAt; self.endedAt = endedAt
            self.source = source; self.confidence = confidence; self.createdAt = createdAt
            self.behavior = behavior; self.evidence = evidence; self.routeID = routeID
            self.sensorChunkID = sensorChunkID; self.modelVersion = modelVersion
            self.manuallyCorrected = manuallyCorrected; self.classificationLocked = classificationLocked
        }
    }

    static let actualRecordSchema = """
    CREATE TABLE IF NOT EXISTS actual_records (
        row_id INTEGER PRIMARY KEY, record_key TEXT NOT NULL UNIQUE,
        position INTEGER NOT NULL CHECK(position >= 0), id TEXT NOT NULL,
        plan_id TEXT, routine_id TEXT, title TEXT NOT NULL, category_id TEXT NOT NULL,
        started_at REAL NOT NULL, ended_at REAL, source TEXT NOT NULL,
        confidence TEXT NOT NULL, created_at REAL NOT NULL, behavior TEXT,
        evidence BLOB NOT NULL, route_id TEXT, sensor_chunk_id TEXT, model_version TEXT,
        manually_corrected INTEGER NOT NULL CHECK(manually_corrected IN (0,1)),
        classification_locked INTEGER NOT NULL CHECK(classification_locked IN (0,1))
    );
    CREATE INDEX IF NOT EXISTS actual_records_id_index ON actual_records(id);
    CREATE INDEX IF NOT EXISTS actual_records_position_index ON actual_records(position);
    CREATE VIRTUAL TABLE IF NOT EXISTS actual_record_ranges USING rtree(row_id, starts, ends);
    CREATE TABLE IF NOT EXISTS actual_record_generation(singleton INTEGER PRIMARY KEY CHECK(singleton=1), revision INTEGER NOT NULL);
    INSERT OR IGNORE INTO actual_record_generation VALUES(1,0);
    """ + actualRecordTriggers.joined(separator: "\n")

    private static let actualRecordTriggers = [
        """
        CREATE TRIGGER IF NOT EXISTS actual_records_insert AFTER INSERT ON actual_records BEGIN
            INSERT INTO actual_record_ranges VALUES(NEW.row_id, NEW.started_at, MAX(NEW.started_at,COALESCE(NEW.ended_at,1.0e30)));
            UPDATE actual_record_generation SET revision=revision+1 WHERE singleton=1;
        END;
        """,
        """
        CREATE TRIGGER IF NOT EXISTS actual_records_update AFTER UPDATE ON actual_records BEGIN
            UPDATE actual_record_ranges SET starts=NEW.started_at, ends=MAX(NEW.started_at,COALESCE(NEW.ended_at,1.0e30)) WHERE row_id=NEW.row_id;
            UPDATE actual_record_generation SET revision=revision+1 WHERE singleton=1;
        END;
        """,
        """
        CREATE TRIGGER IF NOT EXISTS actual_records_delete AFTER DELETE ON actual_records BEGIN
            DELETE FROM actual_record_ranges WHERE row_id=OLD.row_id;
            UPDATE actual_record_generation SET revision=revision+1 WHERE singleton=1;
        END;
        """
    ]

    private static let actualColumns = "record_key, position, id, plan_id, routine_id, title, category_id, started_at, ended_at, source, confidence, created_at, behavior, evidence, route_id, sensor_chunk_id, model_version, manually_corrected, classification_locked"

    public func actualRecordRevision() throws -> UInt64 {
        let statement = try prepare("SELECT revision FROM actual_record_generation WHERE singleton=1;")
        defer { sqlite3_finalize(statement) }
        guard try step(statement) == SQLITE_ROW, sqlite3_column_int64(statement, 0) >= 0 else { throw lastError() }
        return UInt64(sqlite3_column_int64(statement, 0))
    }

    public func actualRecordCount() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM actual_records;")
        defer { sqlite3_finalize(statement) }
        guard try step(statement) == SQLITE_ROW else { throw lastError() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    public func actualRecords(in range: ClosedRange<Date>? = nil) throws -> [ActualRow] {
        let sql: String
        if range != nil {
            // RTree bounds round outwards; REAL predicates preserve exact subsecond boundaries.
            let columns = Self.actualColumns.split(separator: ",").map { "a." + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ",")
            sql = "SELECT \(columns) FROM actual_record_ranges r CROSS JOIN actual_records a ON a.row_id=r.row_id WHERE r.starts<=?1 AND r.ends>=?2 AND a.started_at<=?1 AND (a.ended_at IS NULL OR MAX(a.started_at,a.ended_at)>=?2) ORDER BY a.position;"
        } else {
            sql = "SELECT \(Self.actualColumns) FROM actual_records ORDER BY position;"
        }
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        if let range {
            try bind(range.upperBound.timeIntervalSinceReferenceDate, to: statement, at: 1)
            try bind(range.lowerBound.timeIntervalSinceReferenceDate, to: statement, at: 2)
        }
        var result: [ActualRow] = []
        while try step(statement) == SQLITE_ROW {
            if result.count.isMultiple(of: 256) { try Task.checkCancellation() }
            result.append(try readActual(statement))
        }
        return result
    }

    /// Replacement and its index become visible together; failures restore rows, index and triggers.
    public func replaceActualRecords(_ load: @Sendable (isolated TaptionPlanDayStore) throws -> Void) throws {
        try withSnapshotWriteTransaction { store in
            for suffix in ["insert", "update", "delete"] {
                try store.execute("DROP TRIGGER actual_records_\(suffix);")
            }
            try store.execute("DELETE FROM actual_records;")
            try store.execute("DELETE FROM actual_record_ranges;")
            try load(store)
            try store.execute("INSERT INTO actual_record_ranges SELECT row_id, started_at, MAX(started_at,COALESCE(ended_at,1.0e30)) FROM actual_records;")
            for sql in Self.actualRecordTriggers { try store.execute(sql) }
            guard try store.actualRecordRevision() < UInt64(Int64.max) else {
                throw TaptionPlanDayStoreError.revisionOverflow
            }
            try store.execute("UPDATE actual_record_generation SET revision=revision+1 WHERE singleton=1;")
        }
    }

    public func applyActualRecordDelta(upserting rows: [ActualRow], deletingKeys: [String], replaceAll: Bool = false) throws {
        try withTransaction {
            if replaceAll { try execute("DELETE FROM actual_records;") }
            let deleting = try prepare("DELETE FROM actual_records WHERE record_key=?;")
            defer { sqlite3_finalize(deleting) }
            for key in deletingKeys {
                try Task.checkCancellation()
                sqlite3_reset(deleting)
                try bindActualText(key, to: deleting, at: 1)
                guard try step(deleting) == SQLITE_DONE else { throw lastError() }
            }
            let columns = Self.actualColumns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let updates = columns.dropFirst().map { "\($0)=excluded.\($0)" }.joined(separator: ",")
            let slots = Array(repeating: "?", count: columns.count).joined(separator: ",")
            let statement = try prepare("INSERT INTO actual_records(\(Self.actualColumns)) VALUES(\(slots)) ON CONFLICT(record_key) DO UPDATE SET \(updates);")
            defer { sqlite3_finalize(statement) }
            for row in rows {
                try Task.checkCancellation()
                guard row.position >= 0, !row.key.isEmpty, !row.id.isEmpty,
                      row.startedAt.timeIntervalSinceReferenceDate.isFinite,
                      row.endedAt?.timeIntervalSinceReferenceDate.isFinite != false,
                      row.createdAt.timeIntervalSinceReferenceDate.isFinite else {
                    throw TaptionPlanDayStoreError.invalidIdentifier
                }
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try bindActualText(row.key, to: statement, at: 1)
                try bind(UInt64(row.position), to: statement, at: 2)
                for (offset, value) in [row.id, row.planID, row.routineID, row.title, row.categoryID].enumerated() {
                    try bindActualText(value, to: statement, at: Int32(3 + offset))
                }
                try bind(row.startedAt.timeIntervalSinceReferenceDate, to: statement, at: 8)
                if let end = row.endedAt { try bind(end.timeIntervalSinceReferenceDate, to: statement, at: 9) }
                try bindActualText(row.source, to: statement, at: 10)
                try bindActualText(row.confidence, to: statement, at: 11)
                try bind(row.createdAt.timeIntervalSinceReferenceDate, to: statement, at: 12)
                try bindActualText(row.behavior, to: statement, at: 13)
                try bind(row.evidence, to: statement, at: 14)
                try bindActualText(row.routeID, to: statement, at: 15)
                try bindActualText(row.sensorChunkID, to: statement, at: 16)
                try bindActualText(row.modelVersion, to: statement, at: 17)
                try bind(UInt64(row.manuallyCorrected ? 1 : 0), to: statement, at: 18)
                try bind(UInt64(row.classificationLocked ? 1 : 0), to: statement, at: 19)
                guard try step(statement) == SQLITE_DONE else { throw lastError() }
            }
        }
    }

    private func bindActualText(_ value: String?, to statement: OpaquePointer, at index: Int32) throws {
        guard let value else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else { throw lastError() }
            return
        }
        let result = value.utf8CString.withUnsafeBufferPointer {
            sqlite3_bind_text(statement, index, $0.baseAddress, Int32($0.count - 1), Self.sqliteTransient)
        }
        guard result == SQLITE_OK else { throw lastError() }
    }

    private func readActual(_ statement: OpaquePointer) throws -> ActualRow {
        func text(_ index: Int32) throws -> String? {
            guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
            guard let bytes = sqlite3_column_text(statement, index),
                  let value = String(bytes: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, index))), encoding: .utf8) else {
                throw TaptionPlanDayStoreError.databaseCorrupt(message: "Invalid record text")
            }
            return value
        }
        func required(_ index: Int32) throws -> String {
            guard let value = try text(index) else { throw TaptionPlanDayStoreError.databaseCorrupt(message: "Missing record field") }
            return value
        }
        return try ActualRow(key: required(0), position: Int(sqlite3_column_int64(statement, 1)),
            id: required(2), planID: text(3), routineID: text(4), title: required(5), categoryID: required(6),
            startedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 7)),
            endedAt: sqlite3_column_type(statement, 8) == SQLITE_NULL ? nil : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 8)),
            source: required(9), confidence: required(10), createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 11)),
            behavior: text(12), evidence: readData(statement, at: 13), routeID: text(14), sensorChunkID: text(15),
            modelVersion: text(16), manuallyCorrected: sqlite3_column_int64(statement, 17) == 1,
            classificationLocked: sqlite3_column_int64(statement, 18) == 1)
    }
}
