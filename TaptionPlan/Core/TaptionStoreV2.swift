import Foundation
import SQLite3

/// 새 저장소(스키마 1). 이전 DB·백업과 호환하지 않는다.
///
/// - 위치·센서 원본은 압축된 덩어리가 아니라 **열이 나뉜 표**(`readings`)에 둔다. SQL로 바로 분석할 수 있다.
///   열로 빼지 않은 나머지 필드는 `extra` JSON에 남겨 원본이 사라지지 않는다.
/// - 계획·기록·메모 등은 `records` 표의 행 하나씩으로 둔다. 모든 행에 출처(`origin`: 자동/사용자/가져옴)가 있다.
/// - 파일은 표준 SQLite라서 `sqlite3` 명령으로도 열린다.
enum TaptionStoreV2Error: Error, Equatable {
    case openFailed(String)
    case sqlFailed(String)
    case unsupportedSchema(Int)
    case corruptRow(String)
    /// 같은 `id`의 센서 원본이 이미 다른 내용으로 저장돼 있다(원본은 바꾸지 않는다).
    case readingConflict(String)
}

struct TaptionStoreRecord: Equatable, Sendable {
    enum Origin: String, Sendable {
        case auto
        case user
        case imported
    }

    var id: String
    var kind: String
    var start: Date?
    var end: Date?
    var updatedAt: Date
    var origin: Origin
    var isDeleted = false
    /// 레코드 내용(JSON 문자열). `json_extract`로 조회할 수 있다.
    var body: String
}

/// `SensorReading`을 열이 나뉜 행으로 바꾸고 되돌린다. 합성 Codable의 JSON 키(=필드 이름)를 이용한다.
enum TaptionReadingRowCodec {
    enum Kind: Sendable {
        case text, real, int, bool
    }

    struct Column: Sendable {
        let name: String
        /// JSON 경로. `point.latitude`처럼 한 단계 안쪽 키를 쓸 수 있다.
        let path: String
        let kind: Kind
    }

    static let columns: [Column] = [
        Column(name: "lat", path: "point.latitude", kind: .real),
        Column(name: "lon", path: "point.longitude", kind: .real),
        Column(name: "alt", path: "point.altitude", kind: .real),
        Column(name: "h_acc", path: "point.horizontalAccuracy", kind: .real),
        Column(name: "v_acc", path: "point.verticalAccuracy", kind: .real),
        Column(name: "fix_quality", path: "locationFixQuality", kind: .text),
        Column(name: "speed_mps", path: "speedMetersPerSecond", kind: .real),
        Column(name: "speed_acc_mps", path: "speedAccuracyMetersPerSecond", kind: .real),
        Column(name: "course_deg", path: "courseDegrees", kind: .real),
        Column(name: "course_acc_deg", path: "courseAccuracyDegrees", kind: .real),
        Column(name: "motion", path: "motion", kind: .text),
        Column(name: "motion_conf", path: "motionConfidence", kind: .text),
        Column(name: "gps_available", path: "gpsAvailable", kind: .bool),
        Column(name: "source_device", path: "sourceDevice", kind: .text),
        Column(name: "tracking_session_id", path: "trackingSessionID", kind: .text),
        Column(name: "tracking_kind", path: "trackingKind", kind: .text),
        Column(name: "tracking_auto", path: "trackingWasAutomaticallyDetected", kind: .bool),
        Column(name: "session_ended", path: "trackingSessionEnded", kind: .bool),
        Column(name: "seq", path: "sequence", kind: .int),
        Column(name: "nearby_station", path: "nearbyStation", kind: .bool),
        Column(name: "station_name", path: "nearbyStationName", kind: .text),
        Column(name: "matches_rail", path: "matchesRailRoute", kind: .bool),
        Column(name: "power_state", path: "powerState", kind: .text),
        Column(name: "screen_on", path: "screenIsOn", kind: .bool),
        Column(name: "behavior", path: "behavior", kind: .text),
        Column(name: "step_count", path: "stepCount", kind: .int),
        Column(name: "rel_alt_m", path: "relativeAltitudeMeters", kind: .real),
        Column(name: "pressure_kpa", path: "pressureKilopascals", kind: .real),
    ]

    enum Value: Equatable, Sendable {
        case null
        case int(Int64)
        case real(Double)
        case text(String)
    }

    struct Row: Equatable, Sendable {
        var id: String
        var timestamp: Double
        var day: String
        var values: [Value]
        var extra: String?
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    static func dayKey(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func row(for reading: SensorReading, calendar: Calendar) throws -> Row {
        var object = try JSONSerialization.jsonObject(
            with: encoder().encode(reading)
        ) as? [String: Any] ?? [:]
        guard let id = object["id"] as? String,
              let timestamp = (object["timestamp"] as? NSNumber)?.doubleValue else {
            throw TaptionStoreV2Error.corruptRow("reading without id or timestamp")
        }
        object["id"] = nil
        object["timestamp"] = nil
        var values: [Value] = []
        values.reserveCapacity(columns.count)
        for column in columns {
            values.append(take(column, from: &object))
        }
        let extra: String? = object.isEmpty ? nil : String(
            decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            as: UTF8.self
        )
        return Row(
            id: id,
            timestamp: timestamp,
            day: dayKey(for: Date(timeIntervalSince1970: timestamp), calendar: calendar),
            values: values,
            extra: extra
        )
    }

    static func reading(from row: Row) throws -> SensorReading {
        var object: [String: Any] = [:]
        if let extra = row.extra {
            guard let parsed = try JSONSerialization.jsonObject(with: Data(extra.utf8)) as? [String: Any] else {
                throw TaptionStoreV2Error.corruptRow("extra is not an object")
            }
            object = parsed
        }
        object["id"] = row.id
        object["timestamp"] = row.timestamp
        for (column, value) in zip(columns, row.values) {
            put(column, value, into: &object)
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        do {
            return try decoder().decode(SensorReading.self, from: data)
        } catch {
            throw TaptionStoreV2Error.corruptRow("reading \(row.id): \(error)")
        }
    }

    /// 값의 형태가 열과 맞을 때만 열로 옮기고, 맞지 않으면 `extra`에 그대로 둔다.
    private static func take(_ column: Column, from object: inout [String: Any]) -> Value {
        let parts = column.path.split(separator: ".").map(String.init)
        if parts.count == 2 {
            guard var inner = object[parts[0]] as? [String: Any], let raw = inner[parts[1]],
                  let value = convert(raw, kind: column.kind) else { return .null }
            inner[parts[1]] = nil
            object[parts[0]] = inner
            return value
        }
        guard let raw = object[parts[0]], let value = convert(raw, kind: column.kind) else { return .null }
        object[parts[0]] = nil
        return value
    }

    private static func put(_ column: Column, _ value: Value, into object: inout [String: Any]) {
        guard value != .null else { return }
        let parts = column.path.split(separator: ".").map(String.init)
        let json: Any
        switch (column.kind, value) {
        case (.bool, .int(let number)): json = number != 0
        case (_, .int(let number)): json = number
        case (_, .real(let number)): json = number
        case (_, .text(let text)): json = text
        default: return
        }
        if parts.count == 2 {
            var inner = object[parts[0]] as? [String: Any] ?? [:]
            inner[parts[1]] = json
            object[parts[0]] = inner
        } else {
            object[parts[0]] = json
        }
    }

    private static func convert(_ raw: Any, kind: Kind) -> Value? {
        switch kind {
        case .text:
            guard let text = raw as? String else { return nil }
            return .text(text)
        case .bool:
            guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return .int(number.boolValue ? 1 : 0)
        case .int:
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return .int(number.int64Value)
        case .real:
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return .real(number.doubleValue)
        }
    }
}

/// SQLite 연결을 감싸 해제될 때 닫는다(액터의 deinit에서 포인터를 직접 만질 수 없어서 분리했다).
private final class TaptionSQLiteConnection: @unchecked Sendable {
    let pointer: OpaquePointer

    init(_ pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        sqlite3_close_v2(pointer)
    }
}

actor TaptionStoreV2 {
    static let schemaVersion = 1

    private var connection: TaptionSQLiteConnection?
    private let calendar: Calendar

    /// `url`에 새 저장소를 만들거나 연다. `calendar`는 `day` 열(현지 날짜)을 정하는 데 쓴다.
    init(url: URL, calendar: Calendar = .autoupdatingCurrent) throws {
        self.calendar = calendar
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let handle { sqlite3_close_v2(handle) }
            throw TaptionStoreV2Error.openFailed(message)
        }
        do {
            try Self.configure(handle)
        } catch {
            sqlite3_close_v2(handle)
            throw error
        }
        connection = TaptionSQLiteConnection(handle)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    /// 연결을 닫는다. 이후 호출은 실패한다.
    func close() {
        connection = nil
    }

    // MARK: 위치·센서 원본

    /// 같은 `id`가 이미 있으면 덮어쓴다.
    @discardableResult
    func upsertReadings(_ readings: [SensorReading]) throws -> Int {
        let db = try handle()
        try exec(db, "BEGIN IMMEDIATE")
        do {
            let names = TaptionReadingRowCodec.columns.map(\.name)
            let columnList = (["id", "ts", "day"] + names + ["extra"]).joined(separator: ", ")
            let placeholders = Array(repeating: "?", count: names.count + 4).joined(separator: ", ")
            let statement = try prepare(db, "INSERT OR REPLACE INTO readings (\(columnList)) VALUES (\(placeholders))")
            defer { sqlite3_finalize(statement) }
            for reading in readings {
                let row = try TaptionReadingRowCodec.row(for: reading, calendar: calendar)
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bindRow(statement, row)
                try step(db, statement)
            }
            try exec(db, "COMMIT")
        } catch {
            try? exec(db, "ROLLBACK")
            throw error
        }
        return readings.count
    }

    func readings(from start: Date, to end: Date) throws -> [SensorReading] {
        let result = try loadReadings(
            where: "ts >= ? AND ts < ?",
            bindings: [.real(start.timeIntervalSince1970), .real(end.timeIntervalSince1970)]
        )
        if let failure = result.failures.first { throw failure }
        return result.readings
    }

    /// 끝을 포함하는 범위 조회. 해석할 수 없는 행은 건너뛰고 `isComplete`를 false로 돌려준다.
    func readingsLoadResult(
        from start: Date,
        through end: Date
    ) throws -> (readings: [SensorReading], isComplete: Bool) {
        let result = try loadReadings(
            where: "ts >= ? AND ts <= ?",
            bindings: [.real(start.timeIntervalSince1970), .real(end.timeIntervalSince1970)]
        )
        return (result.readings, result.failures.isEmpty)
    }

    func allReadingsLoadResult() throws -> (readings: [SensorReading], isComplete: Bool) {
        let result = try loadReadings(where: "1 = 1", bindings: [])
        return (result.readings, result.failures.isEmpty)
    }

    func readings(ids: [String]) throws -> [SensorReading] {
        var found: [SensorReading] = []
        for chunk in stride(from: 0, to: ids.count, by: 400).map({ Array(ids[$0..<min($0 + 400, ids.count)]) }) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            let result = try loadReadings(where: "id IN (\(placeholders))", bindings: chunk.map { .text($0) })
            if let failure = result.failures.first { throw failure }
            found += result.readings
        }
        return found
    }

    /// 센서 원본은 바꾸지 않는다. 새 `id`는 넣고, 같은 내용은 그대로 두며, 내용이 다르면 전체를 되돌리고 거부한다.
    func appendImmutableReadings(_ readings: [SensorReading]) throws {
        let db = try handle()
        try exec(db, "BEGIN IMMEDIATE")
        do {
            let names = TaptionReadingRowCodec.columns.map(\.name)
            let columnList = (["id", "ts", "day"] + names + ["extra"]).joined(separator: ", ")
            let placeholders = Array(repeating: "?", count: names.count + 4).joined(separator: ", ")
            let statement = try prepare(db, "INSERT OR IGNORE INTO readings (\(columnList)) VALUES (\(placeholders))")
            defer { sqlite3_finalize(statement) }
            var existingIDs: [String] = []
            var incoming: [String: SensorReading] = [:]
            for reading in readings {
                let row = try TaptionReadingRowCodec.row(for: reading, calendar: calendar)
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bindRow(statement, row)
                try step(db, statement)
                if sqlite3_changes(db) == 0 {
                    existingIDs.append(row.id)
                    incoming[row.id] = reading
                }
            }
            if !existingIDs.isEmpty {
                let stored = try self.readings(ids: existingIDs)
                for value in stored where incoming[value.id.uuidString] != value {
                    throw TaptionStoreV2Error.readingConflict(value.id.uuidString)
                }
            }
            try exec(db, "COMMIT")
        } catch {
            try? exec(db, "ROLLBACK")
            throw error
        }
    }

    /// 이미 있는 `id`는 건드리지 않고 새 기록만 넣는다. 새로 들어간 `id`를 돌려준다.
    func insertNewReadings(_ readings: [SensorReading]) throws -> [String] {
        let db = try handle()
        try exec(db, "BEGIN IMMEDIATE")
        var inserted: [String] = []
        do {
            let names = TaptionReadingRowCodec.columns.map(\.name)
            let columnList = (["id", "ts", "day"] + names + ["extra"]).joined(separator: ", ")
            let placeholders = Array(repeating: "?", count: names.count + 4).joined(separator: ", ")
            let statement = try prepare(db, "INSERT OR IGNORE INTO readings (\(columnList)) VALUES (\(placeholders))")
            defer { sqlite3_finalize(statement) }
            for reading in readings {
                let row = try TaptionReadingRowCodec.row(for: reading, calendar: calendar)
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bindRow(statement, row)
                try step(db, statement)
                if sqlite3_changes(db) > 0 { inserted.append(row.id) }
            }
            try exec(db, "COMMIT")
        } catch {
            try? exec(db, "ROLLBACK")
            throw error
        }
        return inserted
    }

    /// 기록이 있는 현지 날짜마다 첫·마지막 시각 범위.
    func dayRanges() throws -> [ClosedRange<Date>] {
        let db = try handle()
        let statement = try prepare(db, "SELECT MIN(ts), MAX(ts) FROM readings GROUP BY day ORDER BY day")
        defer { sqlite3_finalize(statement) }
        var ranges: [ClosedRange<Date>] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let lower = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
            let upper = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
            ranges.append(lower...max(lower, upper))
        }
        return ranges
    }

    private func loadReadings(
        where condition: String,
        bindings: [TaptionReadingRowCodec.Value]
    ) throws -> (readings: [SensorReading], failures: [Error]) {
        let db = try handle()
        let names = TaptionReadingRowCodec.columns.map(\.name)
        let columnList = (["id", "ts", "day"] + names + ["extra"]).joined(separator: ", ")
        let statement = try prepare(
            db,
            "SELECT \(columnList) FROM readings WHERE \(condition) ORDER BY ts, seq, id"
        )
        defer { sqlite3_finalize(statement) }
        for (offset, value) in bindings.enumerated() {
            bind(statement, Int32(offset + 1), value)
        }
        var readings: [SensorReading] = []
        var failures: [Error] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var values: [TaptionReadingRowCodec.Value] = []
            for offset in 0..<names.count {
                values.append(Self.value(statement, Int32(3 + offset)))
            }
            let extraIndex = Int32(3 + names.count)
            let row = TaptionReadingRowCodec.Row(
                id: String(cString: sqlite3_column_text(statement, 0)),
                timestamp: sqlite3_column_double(statement, 1),
                day: String(cString: sqlite3_column_text(statement, 2)),
                values: values,
                extra: sqlite3_column_type(statement, extraIndex) == SQLITE_NULL
                    ? nil : String(cString: sqlite3_column_text(statement, extraIndex))
            )
            do {
                readings.append(try TaptionReadingRowCodec.reading(from: row))
            } catch {
                failures.append(error)
            }
        }
        return (readings, failures)
    }

    private nonisolated func bindRow(_ statement: OpaquePointer, _ row: TaptionReadingRowCodec.Row) {
        var index: Int32 = 1
        bind(statement, index, .text(row.id)); index += 1
        bind(statement, index, .real(row.timestamp)); index += 1
        bind(statement, index, .text(row.day)); index += 1
        for value in row.values {
            bind(statement, index, value); index += 1
        }
        bind(statement, index, row.extra.map { .text($0) } ?? .null)
    }

    func deleteReadings(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let db = try handle()
        try exec(db, "BEGIN IMMEDIATE")
        do {
            let statement = try prepare(db, "DELETE FROM readings WHERE id = ?")
            defer { sqlite3_finalize(statement) }
            for id in ids {
                sqlite3_reset(statement)
                bind(statement, 1, .text(id))
                try step(db, statement)
            }
            try exec(db, "COMMIT")
        } catch {
            try? exec(db, "ROLLBACK")
            throw error
        }
    }

    func readingCount() throws -> Int {
        try scalarInt("SELECT COUNT(*) FROM readings")
    }

    // MARK: 기록(계획·메모·장소·이동 등)

    func upsertRecords(_ records: [TaptionStoreRecord]) throws {
        let db = try handle()
        try exec(db, "BEGIN IMMEDIATE")
        do {
            let statement = try prepare(db, """
                INSERT OR REPLACE INTO records
                (id, kind, day, start_ts, end_ts, updated_ts, origin, deleted, body)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            defer { sqlite3_finalize(statement) }
            for record in records {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(statement, 1, .text(record.id))
                bind(statement, 2, .text(record.kind))
                bind(statement, 3, record.start.map {
                    .text(TaptionReadingRowCodec.dayKey(for: $0, calendar: calendar))
                } ?? .null)
                bind(statement, 4, record.start.map { .real($0.timeIntervalSince1970) } ?? .null)
                bind(statement, 5, record.end.map { .real($0.timeIntervalSince1970) } ?? .null)
                bind(statement, 6, .real(record.updatedAt.timeIntervalSince1970))
                bind(statement, 7, .text(record.origin.rawValue))
                bind(statement, 8, .int(record.isDeleted ? 1 : 0))
                bind(statement, 9, .text(record.body))
                try step(db, statement)
            }
            try exec(db, "COMMIT")
        } catch {
            try? exec(db, "ROLLBACK")
            throw error
        }
    }

    /// 삭제 표시된 행은 제외한다. `start`/`end`를 주면 시작 시각이 그 범위에 있는 행만 돌려준다.
    func records(kind: String, from start: Date? = nil, to end: Date? = nil) throws -> [TaptionStoreRecord] {
        let db = try handle()
        var sql = """
            SELECT id, kind, start_ts, end_ts, updated_ts, origin, deleted, body
            FROM records WHERE kind = ? AND deleted = 0
            """
        if start != nil { sql += " AND start_ts >= ?" }
        if end != nil { sql += " AND start_ts < ?" }
        sql += " ORDER BY start_ts, id"
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        var index: Int32 = 1
        bind(statement, index, .text(kind)); index += 1
        if let start { bind(statement, index, .real(start.timeIntervalSince1970)); index += 1 }
        if let end { bind(statement, index, .real(end.timeIntervalSince1970)) }
        var result: [TaptionStoreRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let origin = TaptionStoreRecord.Origin(
                rawValue: String(cString: sqlite3_column_text(statement, 5))
            ) else { throw TaptionStoreV2Error.corruptRow("unknown origin") }
            result.append(TaptionStoreRecord(
                id: String(cString: sqlite3_column_text(statement, 0)),
                kind: String(cString: sqlite3_column_text(statement, 1)),
                start: sqlite3_column_type(statement, 2) == SQLITE_NULL
                    ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                end: sqlite3_column_type(statement, 3) == SQLITE_NULL
                    ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                origin: origin,
                isDeleted: sqlite3_column_int(statement, 6) != 0,
                body: String(cString: sqlite3_column_text(statement, 7))
            ))
        }
        return result
    }

    func recordCount(kind: String? = nil) throws -> Int {
        if let kind {
            let db = try handle()
            let statement = try prepare(db, "SELECT COUNT(*) FROM records WHERE kind = ?")
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, .text(kind))
            return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
        }
        return try scalarInt("SELECT COUNT(*) FROM records")
    }

    // MARK: 메타·삭제

    func meta(_ key: String) throws -> String? {
        let db = try handle()
        let statement = try prepare(db, "SELECT value FROM meta WHERE key = ?")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, .text(key))
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return String(cString: sqlite3_column_text(statement, 0))
    }

    func setMeta(_ key: String, _ value: String) throws {
        let db = try handle()
        let statement = try prepare(db, "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, .text(key))
        bind(statement, 2, .text(value))
        try step(db, statement)
    }

    func deleteAll() throws {
        let db = try handle()
        try exec(db, "BEGIN IMMEDIATE")
        do {
            try exec(db, "DELETE FROM readings")
            try exec(db, "DELETE FROM records")
            try exec(db, "COMMIT")
        } catch {
            try? exec(db, "ROLLBACK")
            throw error
        }
    }

    // MARK: SQLite 보조

    private static func configure(_ db: OpaquePointer) throws {
        for pragma in ["PRAGMA journal_mode=WAL", "PRAGMA synchronous=NORMAL", "PRAGMA foreign_keys=ON"] {
            var error: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, pragma, nil, nil, &error) != SQLITE_OK {
                let message = error.map { String(cString: $0) } ?? "pragma failed"
                sqlite3_free(error)
                throw TaptionStoreV2Error.sqlFailed(message)
            }
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK else {
            throw TaptionStoreV2Error.sqlFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        let current = sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int(statement, 0)) : 0
        if current > schemaVersion { throw TaptionStoreV2Error.unsupportedSchema(current) }
        if current == 0 {
            let columnDefinitions = TaptionReadingRowCodec.columns.map { column -> String in
                let type: String
                switch column.kind {
                case .text: type = "TEXT"
                case .real: type = "REAL"
                case .int, .bool: type = "INTEGER"
                }
                return "\(column.name) \(type)"
            }.joined(separator: ",\n    ")
            let script = """
                BEGIN;
                CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE readings (
                    id TEXT PRIMARY KEY,
                    ts REAL NOT NULL,
                    day TEXT NOT NULL,
                    \(columnDefinitions),
                    extra TEXT
                );
                CREATE INDEX readings_ts ON readings(ts);
                CREATE INDEX readings_day ON readings(day);
                CREATE TABLE records (
                    id TEXT PRIMARY KEY,
                    kind TEXT NOT NULL,
                    day TEXT,
                    start_ts REAL,
                    end_ts REAL,
                    updated_ts REAL NOT NULL,
                    origin TEXT NOT NULL CHECK (origin IN ('auto', 'user', 'imported')),
                    deleted INTEGER NOT NULL DEFAULT 0,
                    body TEXT NOT NULL
                );
                CREATE INDEX records_kind_start ON records(kind, start_ts);
                CREATE INDEX records_day ON records(day);
                INSERT INTO meta (key, value) VALUES ('schema_version', '\(schemaVersion)');
                PRAGMA user_version = \(schemaVersion);
                COMMIT;
                """
            var error: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, script, nil, nil, &error) != SQLITE_OK {
                let message = error.map { String(cString: $0) } ?? "schema failed"
                sqlite3_free(error)
                throw TaptionStoreV2Error.sqlFailed(message)
            }
        }
    }

    private func handle() throws -> OpaquePointer {
        guard let connection else { throw TaptionStoreV2Error.openFailed("closed") }
        return connection.pointer
    }

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(error)
            throw TaptionStoreV2Error.sqlFailed(message)
        }
    }

    private func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw TaptionStoreV2Error.sqlFailed(String(cString: sqlite3_errmsg(db)))
        }
        return statement
    }

    private func step(_ db: OpaquePointer, _ statement: OpaquePointer) throws {
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else {
            throw TaptionStoreV2Error.sqlFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func scalarInt(_ sql: String) throws -> Int {
        let db = try handle()
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }

    private nonisolated func bind(_ statement: OpaquePointer, _ index: Int32, _ value: TaptionReadingRowCodec.Value) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        switch value {
        case .null: sqlite3_bind_null(statement, index)
        case .int(let number): sqlite3_bind_int64(statement, index, number)
        case .real(let number): sqlite3_bind_double(statement, index, number)
        case .text(let text): sqlite3_bind_text(statement, index, text, -1, transient)
        }
    }

    private static func value(_ statement: OpaquePointer?, _ column: Int32) -> TaptionReadingRowCodec.Value {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER: .int(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT: .real(sqlite3_column_double(statement, column))
        case SQLITE_TEXT: .text(String(cString: sqlite3_column_text(statement, column)))
        default: .null
        }
    }
}
