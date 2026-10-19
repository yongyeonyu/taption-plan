import Foundation
import SQLite3

/// 센서·기기 원본 이벤트 하나. 워치 요약·가속도 묶음, 기기 원시 봉투처럼 한 번 받으면 바꾸지 않는 값이다.
/// 본문(`payload`)은 JSON 문자열이라 `json_extract`로 조회할 수 있다.
struct TaptionRawEvent: Equatable, Sendable {
    enum Kind {
        static let deviceEnvelope = "device-envelope"
        static let watchSummary = "watch-summary"
        static let watchAcceleration = "watch-acceleration"
    }

    /// 이벤트 종류. 같은 종류 안에서 `id`가 유일하다.
    var kind: String
    var id: String
    var timestamp: Date
    var sequence: Int64 = 0
    /// 자동 수집(`auto`)인지 가져온 값(`imported`)인지. 사용자가 고친 값은 이 표에 넣지 않는다.
    var origin: TaptionStoreRecord.Origin = .auto
    /// 값이 어디서 왔는지(기기·전송 경로·가공 여부).
    var provenance: [String] = []
    var payload: String

    /// 저장되는 모양으로 같은지. 시각은 1970년 기준 초(저장 열)로 바뀐 값으로 비교해,
    /// 저장했다가 읽은 값과 원래 값의 마지막 비트 차이를 다른 내용으로 보지 않는다.
    func storedFormEquals(_ other: TaptionRawEvent) -> Bool {
        kind == other.kind && id == other.id && sequence == other.sequence && origin == other.origin
            && provenance == other.provenance && payload == other.payload
            && timestamp.timeIntervalSince1970 == other.timestamp.timeIntervalSince1970
    }
}

/// 원본 이벤트 본문의 JSON 변환. 시각은 기본(`timeIntervalSinceReferenceDate`) 방식이라 다시 읽어도 비트 단위로 같다.
/// 사람이 보는 시각은 `raw_events.ts`/`records.start_ts` 열(1970년 기준 초)에 따로 있다.
enum TaptionRawPayloadCoding {
    static func encode<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan"
        )
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from payload: String) throws -> Value {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan"
        )
        return try decoder.decode(type, from: Data(payload.utf8))
    }
}

extension TaptionStoreV2 {
    /// 원본 표(`raw_events`)를 만든다. 열 때마다 불리므로 이미 있으면 아무것도 하지 않는다.
    static func createRawEventsTable(_ db: OpaquePointer) throws {
        let script = """
            CREATE TABLE IF NOT EXISTS raw_events (
                kind TEXT NOT NULL,
                id TEXT NOT NULL,
                ts REAL NOT NULL,
                day INTEGER NOT NULL,
                seq INTEGER NOT NULL DEFAULT 0,
                origin TEXT NOT NULL CHECK (origin IN ('auto', 'imported')),
                provenance TEXT NOT NULL,
                payload TEXT NOT NULL,
                PRIMARY KEY (kind, id)
            ) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS raw_events_kind_ts ON raw_events(kind, ts);
            """
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, script, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "raw_events failed"
            sqlite3_free(error)
            throw TaptionStoreV2Error.sqlFailed(message)
        }
    }

    /// 새 `id`는 넣고, 같은 내용이 이미 있으면 그대로 두며, 내용이 다르면 전체를 되돌리고 거부한다.
    /// 새로 들어간 `id`를 돌려준다.
    @discardableResult
    func appendRawEvents(_ events: [TaptionRawEvent]) throws -> [String] {
        guard !events.isEmpty else { return [] }
        let db = try handle()
        try exec(db, "BEGIN IMMEDIATE")
        var inserted: [String] = []
        do {
            let statement = try prepare(db, """
                INSERT OR IGNORE INTO raw_events (kind, id, ts, day, seq, origin, provenance, payload)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """)
            defer { sqlite3_finalize(statement) }
            for event in events {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(statement, 1, .text(event.kind))
                bind(statement, 2, .text(event.id))
                bind(statement, 3, .real(event.timestamp.timeIntervalSince1970))
                bind(statement, 4, .int(Int64(dayNumber(of: event.timestamp))))
                bind(statement, 5, .int(event.sequence))
                bind(statement, 6, .text(event.origin.rawValue))
                bind(statement, 7, .text(Self.encodeProvenance(event.provenance)))
                bind(statement, 8, .text(event.payload))
                try step(db, statement)
                if sqlite3_changes(db) > 0 {
                    inserted.append(event.id)
                } else if let stored = try rawEvent(db, kind: event.kind, id: event.id), !stored.storedFormEquals(event) {
                    throw TaptionStoreV2Error.rawEventConflict(kind: event.kind, id: event.id)
                }
            }
            try exec(db, "COMMIT")
        } catch {
            try? exec(db, "ROLLBACK")
            throw error
        }
        return inserted
    }

    /// 쓰지 않고, 같은 `id`에 다른 내용이 이미 있는지만 확인한다.
    func validateRawEvents(_ events: [TaptionRawEvent]) throws {
        let db = try handle()
        for event in events {
            if let stored = try rawEvent(db, kind: event.kind, id: event.id), !stored.storedFormEquals(event) {
                throw TaptionStoreV2Error.rawEventConflict(kind: event.kind, id: event.id)
            }
        }
    }

    /// 시각이 `start...end`(양끝 포함)인 이벤트를 시각·순서·id 순으로. 범위를 주지 않으면 모두.
    func rawEvents(
        kind: String, from start: Date? = nil, through end: Date? = nil, idPrefix: String? = nil, limit: Int? = nil,
        newestFirst: Bool = false
    ) throws -> [TaptionRawEvent] {
        let db = try handle()
        var sql = "\(Self.rawEventColumns) FROM raw_events WHERE kind = ?"
        if start != nil { sql += " AND ts >= ?" }
        if end != nil { sql += " AND ts <= ?" }
        if idPrefix != nil { sql += " AND substr(id, 1, ?) = ?" }
        sql += newestFirst ? " ORDER BY seq DESC, ts DESC, id DESC" : " ORDER BY ts, seq, id"
        if let limit { sql += " LIMIT \(max(0, limit))" }
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        var index: Int32 = 1
        bind(statement, index, .text(kind)); index += 1
        if let start { bind(statement, index, .real(start.timeIntervalSince1970)); index += 1 }
        if let end { bind(statement, index, .real(end.timeIntervalSince1970)); index += 1 }
        if let idPrefix {
            bind(statement, index, .int(Int64(idPrefix.count))); index += 1
            bind(statement, index, .text(idPrefix))
        }
        var result: [TaptionRawEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(try Self.event(from: statement))
        }
        return result
    }

    func rawEventIDs(kind: String, ids: [String]) throws -> Set<String> {
        let db = try handle()
        let statement = try prepare(db, "SELECT 1 FROM raw_events WHERE kind = ? AND id = ?")
        defer { sqlite3_finalize(statement) }
        var found = Set<String>()
        for id in ids {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            bind(statement, 1, .text(kind))
            bind(statement, 2, .text(id))
            if sqlite3_step(statement) == SQLITE_ROW { found.insert(id) }
        }
        return found
    }

    func rawEventCount(kind: String) throws -> Int {
        let db = try handle()
        let statement = try prepare(db, "SELECT COUNT(*) FROM raw_events WHERE kind = ?")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, .text(kind))
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }

    /// 이벤트가 있는 현지 날짜마다 첫·마지막 시각 범위. `kind`를 주지 않으면 모든 종류.
    func rawEventDayRanges(kind: String? = nil) throws -> [ClosedRange<Date>] {
        let db = try handle()
        let statement = try prepare(
            db,
            "SELECT MIN(ts), MAX(ts) FROM raw_events\(kind == nil ? "" : " WHERE kind = ?") GROUP BY day ORDER BY day"
        )
        defer { sqlite3_finalize(statement) }
        if let kind { bind(statement, 1, .text(kind)) }
        var ranges: [ClosedRange<Date>] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let lower = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
            let upper = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
            ranges.append(lower...max(lower, upper))
        }
        return ranges
    }

    func deleteRawEvents(kind: String, ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let db = try handle()
        try exec(db, "BEGIN IMMEDIATE")
        do {
            let statement = try prepare(db, "DELETE FROM raw_events WHERE kind = ? AND id = ?")
            defer { sqlite3_finalize(statement) }
            for id in ids {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(statement, 1, .text(kind))
                bind(statement, 2, .text(id))
                try step(db, statement)
            }
            try exec(db, "COMMIT")
        } catch {
            try? exec(db, "ROLLBACK")
            throw error
        }
    }

    func deleteRawEvents(kind: String) throws {
        let db = try handle()
        let statement = try prepare(db, "DELETE FROM raw_events WHERE kind = ?")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, .text(kind))
        try step(db, statement)
    }

    /// 지정한 종류의 기록(`records`)을 모두 **삭제 표시(톰스톤)** 로 바꾼다. 행을 지우지 않는다.
    /// 하드 삭제하면 월 백업 파일에 남은 같은 행이 다음 백업의 합집합에서 되살아나기 때문이다. 본문은 `{}`로 비우고
    /// 수정 시각은 이전보다 항상 뒤로 둬서(`applyRecordChanges`와 같은 규칙) 오래된 백업 행을 이긴다.
    /// 읽기 API(`records(kind:)` 등)는 삭제 표시를 숨긴다. 전체 삭제(`deleteAllRecords`)와 달리 백업 무효화 표시는 남기지 않는다.
    func deleteRecords(kinds: [String], deletedAt: Date = Date()) throws {
        guard !kinds.isEmpty else { return }
        let db = try handle()
        try exec(db, "BEGIN IMMEDIATE")
        do {
            let statement = try prepare(db, """
                UPDATE records SET deleted = 1, body = '{}', end_ts = NULL,
                  updated_ts = MAX(?, updated_ts + 0.001)
                WHERE kind = ? AND deleted = 0
                """)
            defer { sqlite3_finalize(statement) }
            for kind in kinds {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(statement, 1, .real(deletedAt.timeIntervalSince1970))
                bind(statement, 2, .text(kind))
                try step(db, statement)
            }
            try exec(db, "COMMIT")
        } catch {
            try? exec(db, "ROLLBACK")
            throw error
        }
    }

    /// 쓰기 로그(WAL)를 본 파일에 합친다. 앱이 백그라운드로 가기 전에 부른다.
    func checkpoint() throws {
        try exec(try handle(), "PRAGMA wal_checkpoint(PASSIVE)")
    }

    func deleteMeta(_ key: String) throws {
        let db = try handle()
        let statement = try prepare(db, "DELETE FROM meta WHERE key = ?")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, .text(key))
        try step(db, statement)
    }

    /// 종류가 같은 `records` 행의 `id`가 있는 것만 골라 돌려준다.
    func existingRecordIDs(kind: String, ids: [String]) throws -> Set<String> {
        let db = try handle()
        let statement = try prepare(db, "SELECT 1 FROM records WHERE kind = ? AND id = ? AND deleted = 0")
        defer { sqlite3_finalize(statement) }
        var found = Set<String>()
        for id in ids {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            bind(statement, 1, .text(kind))
            bind(statement, 2, .text(id))
            if sqlite3_step(statement) == SQLITE_ROW { found.insert(id) }
        }
        return found
    }

    // MARK: 보조

    private static let rawEventColumns = "SELECT kind, id, ts, seq, origin, provenance, payload"

    private func dayNumber(of date: Date) -> Int {
        TaptionReadingRowCodec.dayNumber(for: date, calendar: calendar)
    }

    private func rawEvent(_ db: OpaquePointer, kind: String, id: String) throws -> TaptionRawEvent? {
        let statement = try prepare(db, "\(Self.rawEventColumns) FROM raw_events WHERE kind = ? AND id = ?")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, .text(kind))
        bind(statement, 2, .text(id))
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return try Self.event(from: statement)
    }

    private static func event(from statement: OpaquePointer) throws -> TaptionRawEvent {
        guard let origin = TaptionStoreRecord.Origin(
            rawValue: String(cString: sqlite3_column_text(statement, 4))
        ) else { throw TaptionStoreV2Error.corruptRow("unknown origin") }
        return TaptionRawEvent(
            kind: String(cString: sqlite3_column_text(statement, 0)),
            id: String(cString: sqlite3_column_text(statement, 1)),
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
            sequence: sqlite3_column_int64(statement, 3),
            origin: origin,
            provenance: decodeProvenance(String(cString: sqlite3_column_text(statement, 5))),
            payload: String(cString: sqlite3_column_text(statement, 6))
        )
    }

    private static func encodeProvenance(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func decodeProvenance(_ text: String) -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(text.utf8))) ?? []
    }
}
