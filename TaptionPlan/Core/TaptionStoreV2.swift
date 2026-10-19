import Foundation
import SQLite3
import TaptionPlanCore

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
    /// 같은 종류·`id`의 원본 이벤트가 이미 다른 내용으로 저장돼 있다.
    case rawEventConflict(kind: String, id: String)
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
    /// 같은 종류 안에서 처음 저장된 순서. 불러올 때 이 순서를 유지한다.
    var ord = 0
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
        Column(name: "dm_n", path: "deviceMotionSummary.sampleCount", kind: .int),
        Column(name: "dm_acc_mean_g", path: "deviceMotionSummary.meanUserAccelerationG", kind: .real),
        Column(name: "dm_acc_std_g", path: "deviceMotionSummary.userAccelerationStandardDeviationG", kind: .real),
        Column(name: "dm_acc_peak_g", path: "deviceMotionSummary.peakUserAccelerationG", kind: .real),
        Column(name: "dm_rot_mean", path: "deviceMotionSummary.meanRotationRateRadiansPerSecond", kind: .real),
        Column(name: "dm_rot_std", path: "deviceMotionSummary.rotationRateStandardDeviationRadiansPerSecond", kind: .real),
        Column(name: "dm_rot_peak", path: "deviceMotionSummary.peakRotationRateRadiansPerSecond", kind: .real),
        // 항상 들어 있는 불리언은 열로 두면 값 없이 헤더 1바이트만 쓴다(JSON이면 행마다 20바이트 남짓).
        Column(name: "matches_transit", path: "matchesPublicTransitRoute", kind: .bool),
        Column(name: "frequent_stops", path: "frequentStops", kind: .bool),
        Column(name: "ride_hailing", path: "rideHailingHint", kind: .bool),
        Column(name: "near_airport", path: "nearAirport", kind: .bool),
        Column(name: "near_port", path: "nearPort", kind: .bool),
        Column(name: "on_water", path: "onWater", kind: .bool),
        Column(name: "floors_up", path: "floorsAscended", kind: .int),
        Column(name: "floors_down", path: "floorsDescended", kind: .int),
        Column(name: "walk_dist_m", path: "walkingRunningDistanceMeters", kind: .real),
        Column(name: "pace_s_per_m", path: "currentPaceSecondsPerMeter", kind: .real),
        Column(name: "cadence_hz", path: "currentCadenceStepsPerSecond", kind: .real),
        Column(name: "system_floor", path: "systemFloor", kind: .int),
        Column(name: "screen_brightness", path: "screenBrightness", kind: .real),
        Column(name: "wifi_ssid", path: "connectedWiFiSSID", kind: .text),
        Column(name: "behavior_conf", path: "behaviorConfidenceScore", kind: .real),
        Column(name: "watch_workout", path: "watchWorkoutKind", kind: .text),
        Column(name: "watch_acc_x", path: "watchAccelerationAverageG.x", kind: .real),
        Column(name: "watch_acc_y", path: "watchAccelerationAverageG.y", kind: .real),
        Column(name: "watch_acc_z", path: "watchAccelerationAverageG.z", kind: .real),
        Column(name: "watch_acc_std", path: "watchAccelerationStandardDeviationG", kind: .real),
        Column(name: "watch_jerk", path: "watchAccelerationMeanJerkGPerSecond", kind: .real),
    ]

    enum Value: Equatable, Sendable {
        case null
        case int(Int64)
        case real(Double)
        case text(String)
        case blob(Data)
    }

    struct Row: Equatable, Sendable {
        var id: String
        var timestamp: Double
        var day: Int
        var values: [Value]
        var extra: String?
    }

    /// UUID 문자열을 16바이트로. 문자열(36자)보다 행마다 20바이트가 줄고 색인도 작아진다.
    static func uuidData(_ string: String) -> Data? {
        guard let uuid = UUID(uuidString: string) else { return nil }
        return withUnsafeBytes(of: uuid.uuid) { Data($0) }
    }

    static func uuidString(from data: Data) -> String? {
        guard data.count == 16 else { return nil }
        let uuid = data.withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) }
        return UUID(uuid: uuid).uuidString
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

    static func dayNumber(for date: Date, calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
    }

    static func row(for reading: SensorReading, calendar: Calendar) throws -> Row {
        var object = try JSONSerialization.jsonObject(
            with: encoder().encode(reading)
        ) as? [String: Any] ?? [:]
        guard let id = object["id"] as? String, uuidData(id) != nil,
              let timestamp = (object["timestamp"] as? NSNumber)?.doubleValue else {
            throw TaptionStoreV2Error.corruptRow("reading without a UUID id or timestamp")
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
            day: dayNumber(for: Date(timeIntervalSince1970: timestamp), calendar: calendar),
            values: values,
            extra: extra
        )
    }

    /// 두 기록이 저장소에 같은 내용으로 저장되는지(시각 반올림 같은 표현 차이는 무시).
    static func sameStoredContent(_ lhs: SensorReading, _ rhs: SensorReading) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        guard let left = try? row(for: lhs, calendar: calendar),
              let right = try? row(for: rhs, calendar: calendar) else { return false }
        return left == right
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
            object[parts[0]] = inner.isEmpty ? nil : inner
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
    static let fileName = "taption-store.sqlite"

    /// 사용자의 달력 설정(불교력·연호력 등)과 무관하게 그레고리력 현지 날짜로 `day`를 계산한다.
    static func localGregorianCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }

    private nonisolated(unsafe) static var sharedStores: [String: TaptionStoreV2] = [:]
    private static let sharedLock = NSLock()

    /// 앱이 쓰는 저장소 하나. 센서·계획·기록이 같은 파일과 같은 연결을 쓴다.
    static func applicationSupport(fileManager: FileManager = .default) throws -> TaptionStoreV2 {
        let root = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let storeRoot = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: TaptionPlanSharedContainer.appGroupIdentifier
        ) ?? root.appendingPathComponent("TaptionPlan", isDirectory: true)
        return try shared(at: storeRoot.appendingPathComponent(fileName, isDirectory: false))
    }

    static func shared(at url: URL) throws -> TaptionStoreV2 {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if let existing = sharedStores[url.path] { return existing }
        let store = try TaptionStoreV2(url: url)
        sharedStores[url.path] = store
        return store
    }

    private var connection: TaptionSQLiteConnection?
    let calendar: Calendar
    /// 저장소 파일 위치. 같은 폴더에 쓰기 잠금 파일을 둘 때 쓴다.
    nonisolated let url: URL

    /// `url`에 새 저장소를 만들거나 연다. `calendar`는 `day` 열(현지 날짜)을 정하는 데 쓴다.
    init(url: URL, calendar: Calendar = TaptionStoreV2.localGregorianCalendar()) throws {
        self.calendar = calendar
        self.url = url
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
        // 앱·위젯이 같은 파일을 열므로 다른 쪽 쓰기가 끝나길 잠깐 기다린다(바로 실패하지 않는다).
        sqlite3_busy_timeout(handle, 5_000)
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
            let blobs = chunk.compactMap(TaptionReadingRowCodec.uuidData)
            guard !blobs.isEmpty else { continue }
            let placeholders = Array(repeating: "?", count: blobs.count).joined(separator: ", ")
            let result = try loadReadings(where: "id IN (\(placeholders))", bindings: blobs.map { .blob($0) })
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
                for value in stored {
                    // Date는 1970 기준 초로 바꿀 때 반올림되므로 저장 형태끼리 비교한다.
                    guard let sent = incoming[value.id.uuidString],
                          TaptionReadingRowCodec.sameStoredContent(sent, value) else {
                        throw TaptionStoreV2Error.readingConflict(value.id.uuidString)
                    }
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
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            defer { code = sqlite3_step(statement) }
            var values: [TaptionReadingRowCodec.Value] = []
            for offset in 0..<names.count {
                values.append(Self.value(statement, Int32(3 + offset)))
            }
            let extraIndex = Int32(3 + names.count)
            let row = TaptionReadingRowCodec.Row(
                id: {
                    if case .blob(let data) = Self.value(statement, 0),
                       let string = TaptionReadingRowCodec.uuidString(from: data) { return string }
                    return ""
                }(),
                timestamp: sqlite3_column_double(statement, 1),
                day: Int(sqlite3_column_int64(statement, 2)),
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
        guard code == SQLITE_DONE else {
            throw TaptionStoreV2Error.sqlFailed(String(cString: sqlite3_errmsg(db)))
        }
        return (readings, failures)
    }

    private nonisolated func bindRow(_ statement: OpaquePointer, _ row: TaptionReadingRowCodec.Row) {
        var index: Int32 = 1
        bind(statement, index, .blob(TaptionReadingRowCodec.uuidData(row.id) ?? Data())); index += 1
        bind(statement, index, .real(row.timestamp)); index += 1
        bind(statement, index, .int(Int64(row.day))); index += 1
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
                guard let data = TaptionReadingRowCodec.uuidData(id) else { continue }
                sqlite3_reset(statement)
                bind(statement, 1, .blob(data))
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
            try upsertRecordRows(db, records)
            try exec(db, "COMMIT")
        } catch {
            try? exec(db, "ROLLBACK")
            throw error
        }
    }

    /// 이미 시작한 트랜잭션 안에서 행을 쓴다.
    private func upsertRecordRows(_ db: OpaquePointer, _ records: [TaptionStoreRecord]) throws {
        let statement = try prepare(db, """
            INSERT OR REPLACE INTO records
            (id, kind, day, start_ts, end_ts, updated_ts, origin, deleted, ord, body)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(statement) }
        for record in records {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            bind(statement, 1, .text(record.id))
            bind(statement, 2, .text(record.kind))
            bind(statement, 3, record.start.map {
                .int(Int64(TaptionReadingRowCodec.dayNumber(for: $0, calendar: calendar)))
            } ?? .null)
            bind(statement, 4, record.start.map { .real($0.timeIntervalSince1970) } ?? .null)
            bind(statement, 5, record.end.map { .real($0.timeIntervalSince1970) } ?? .null)
            bind(statement, 6, .real(record.updatedAt.timeIntervalSince1970))
            bind(statement, 7, .text(record.origin.rawValue))
            bind(statement, 8, .int(record.isDeleted ? 1 : 0))
            bind(statement, 9, .int(Int64(record.ord)))
            bind(statement, 10, .text(record.body))
            try step(db, statement)
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
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            defer { code = sqlite3_step(statement) }
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
        guard code == SQLITE_DONE else {
            throw TaptionStoreV2Error.sqlFailed(String(cString: sqlite3_errmsg(db)))
        }
        return result
    }

    /// 지워지지 않은 모든 기록 행(종류, id, 순서, 본문). 불러오기와 변경 비교의 기준으로 쓴다.
    func allRecordRows() throws -> [(kind: String, id: String, ord: Int, body: String)] {
        let db = try handle()
        let statement = try prepare(
            db, "SELECT kind, id, ord, body FROM records WHERE deleted = 0 ORDER BY kind, ord, id"
        )
        defer { sqlite3_finalize(statement) }
        var rows: [(kind: String, id: String, ord: Int, body: String)] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            defer { code = sqlite3_step(statement) }
            rows.append((
                String(cString: sqlite3_column_text(statement, 0)),
                String(cString: sqlite3_column_text(statement, 1)),
                Int(sqlite3_column_int64(statement, 2)),
                String(cString: sqlite3_column_text(statement, 3))
            ))
        }
        guard code == SQLITE_DONE else {
            throw TaptionStoreV2Error.sqlFailed(String(cString: sqlite3_errmsg(db)))
        }
        return rows
    }

    /// 한 트랜잭션으로 바뀐 행은 쓰고, 사라진 행은 삭제 표시(톰스톤)로 바꾼다. 도중에 실패하면 둘 다 되돌린다.
    /// 삭제 표시는 본문을 비우고 `deleted=1`, 수정 시각을 `deletedAt`(이전 수정 시각보다 항상 뒤)으로 둔다.
    /// 월 백업이 "이 id가 지워졌다"를 담고 복원 때 오래된 로컬 행에 적용할 수 있게 하기 위해서다.
    func applyRecordChanges(
        upserts: [TaptionStoreRecord], deletes: [(kind: String, id: String)], deletedAt: Date = Date()
    ) throws {
        guard !upserts.isEmpty || !deletes.isEmpty else { return }
        let db = try handle()
        try exec(db, "BEGIN IMMEDIATE")
        do {
            if !deletes.isEmpty {
                let statement = try prepare(db, """
                    UPDATE records SET deleted = 1, body = '{}', end_ts = NULL,
                      updated_ts = MAX(?, updated_ts + 0.001)
                    WHERE kind = ? AND id = ?
                    """)
                defer { sqlite3_finalize(statement) }
                for item in deletes {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    bind(statement, 1, .real(deletedAt.timeIntervalSince1970))
                    bind(statement, 2, .text(item.kind))
                    bind(statement, 3, .text(item.id))
                    try step(db, statement)
                }
            }
            try upsertRecordRows(db, upserts)
            try exec(db, "COMMIT")
        } catch {
            try? exec(db, "ROLLBACK")
            throw error
        }
    }

    func deleteAllRecords() throws {
        try exec(try handle(), "DELETE FROM records")
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

    // MARK: 월 백업 보조

    /// 시각 범위 `[from, to)` 안의 행 수와 시각 범위. 기록은 시작 시각이 있는 행만 센다.
    func rangeStats(from: Double, to: Double) throws -> (readings: Int, records: Int, first: Double?, last: Double?) {
        let db = try handle()
        let statement = try prepare(db, """
            SELECT
              (SELECT COUNT(*) FROM readings WHERE ts >= ?1 AND ts < ?2),
              (SELECT COUNT(*) FROM records WHERE start_ts >= ?1 AND start_ts < ?2),
              (SELECT MIN(v) FROM (SELECT MIN(ts) AS v FROM readings WHERE ts >= ?1 AND ts < ?2
                 UNION ALL SELECT MIN(start_ts) FROM records WHERE start_ts >= ?1 AND start_ts < ?2)),
              (SELECT MAX(v) FROM (SELECT MAX(ts) AS v FROM readings WHERE ts >= ?1 AND ts < ?2
                 UNION ALL SELECT MAX(start_ts) FROM records WHERE start_ts >= ?1 AND start_ts < ?2))
            """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, .real(from))
        bind(statement, 2, .real(to))
        guard sqlite3_step(statement) == SQLITE_ROW else { return (0, 0, nil, nil) }
        func optional(_ column: Int32) -> Double? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_double(statement, column)
        }
        return (Int(sqlite3_column_int64(statement, 0)), Int(sqlite3_column_int64(statement, 1)),
                optional(2), optional(3))
    }

    /// 데이터가 있는 가장 이른·늦은 시각(센서 원본과 시작 시각이 있는 기록).
    func dataTimeBounds() throws -> (first: Double, last: Double)? {
        let db = try handle()
        let statement = try prepare(db, """
            SELECT MIN(v), MAX(w) FROM (
              SELECT MIN(ts) AS v, MAX(ts) AS w FROM readings
              UNION ALL SELECT MIN(start_ts), MAX(start_ts) FROM records)
            """)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return (sqlite3_column_double(statement, 0), sqlite3_column_double(statement, 1))
    }

    /// 백업용 기록 행. 삭제 표시 행과 순서(`ord`)까지 포함하고 결정적 순서(종류, id)로 돌려준다.
    func recordsForBackup(from: Double, to: Double) throws -> [TaptionStoreRecord] {
        try loadBackupRecords(where: "start_ts >= ? AND start_ts < ?", bindings: [.real(from), .real(to)])
    }

    /// 시작 시각이 없는 기록(설정 헤더·분류 등). 달에 속하지 않아 설정 백업 파일에 담는다.
    func undatedRecordsForBackup() throws -> [TaptionStoreRecord] {
        try loadBackupRecords(where: "start_ts IS NULL", bindings: [])
    }

    func undatedRecordCount() throws -> Int {
        try scalarInt("SELECT COUNT(*) FROM records WHERE start_ts IS NULL")
    }

    private func loadBackupRecords(
        where condition: String, bindings: [TaptionReadingRowCodec.Value]
    ) throws -> [TaptionStoreRecord] {
        let db = try handle()
        let statement = try prepare(db, """
            SELECT id, kind, start_ts, end_ts, updated_ts, origin, deleted, ord, body
            FROM records WHERE \(condition) ORDER BY kind, id
            """)
        defer { sqlite3_finalize(statement) }
        for (offset, value) in bindings.enumerated() { bind(statement, Int32(offset + 1), value) }
        var result: [TaptionStoreRecord] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            defer { code = sqlite3_step(statement) }
            guard let origin = TaptionStoreRecord.Origin(
                rawValue: String(cString: sqlite3_column_text(statement, 5))
            ) else { throw TaptionStoreV2Error.corruptRow("unknown origin") }
            func date(_ column: Int32) -> Date? {
                sqlite3_column_type(statement, column) == SQLITE_NULL
                    ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
            }
            result.append(TaptionStoreRecord(
                id: String(cString: sqlite3_column_text(statement, 0)),
                kind: String(cString: sqlite3_column_text(statement, 1)),
                start: date(2), end: date(3),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                origin: origin,
                isDeleted: sqlite3_column_int(statement, 6) != 0,
                ord: Int(sqlite3_column_int64(statement, 7)),
                body: String(cString: sqlite3_column_text(statement, 8))
            ))
        }
        guard code == SQLITE_DONE else {
            throw TaptionStoreV2Error.sqlFailed(String(cString: sqlite3_errmsg(db)))
        }
        return result
    }

    /// 복원용. 같은 종류·`id`가 있으면 파일의 행이 더 나중에 고친 것일 때만 덮어쓴다(로컬 최신 편집 보호).
    /// 새로 넣었거나 덮어쓴 행 수를 돌려준다.
    @discardableResult
    func upsertRecordsKeepingNewer(_ records: [TaptionStoreRecord]) throws -> Int {
        let db = try handle()
        try exec(db, "BEGIN IMMEDIATE")
        var changed = 0
        do {
            let statement = try prepare(db, """
                INSERT INTO records (id, kind, day, start_ts, end_ts, updated_ts, origin, deleted, ord, body)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(kind, id) DO UPDATE SET
                  day = excluded.day, start_ts = excluded.start_ts,
                  end_ts = excluded.end_ts, updated_ts = excluded.updated_ts, origin = excluded.origin,
                  deleted = excluded.deleted, ord = excluded.ord, body = excluded.body
                WHERE excluded.updated_ts > records.updated_ts
                """)
            defer { sqlite3_finalize(statement) }
            for record in records {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(statement, 1, .text(record.id))
                bind(statement, 2, .text(record.kind))
                bind(statement, 3, record.start.map {
                    .int(Int64(TaptionReadingRowCodec.dayNumber(for: $0, calendar: calendar)))
                } ?? .null)
                bind(statement, 4, record.start.map { .real($0.timeIntervalSince1970) } ?? .null)
                bind(statement, 5, record.end.map { .real($0.timeIntervalSince1970) } ?? .null)
                bind(statement, 6, .real(record.updatedAt.timeIntervalSince1970))
                bind(statement, 7, .text(record.origin.rawValue))
                bind(statement, 8, .int(record.isDeleted ? 1 : 0))
                bind(statement, 9, .int(Int64(record.ord)))
                bind(statement, 10, .text(record.body))
                try step(db, statement)
                changed += Int(sqlite3_changes(db))
            }
            try exec(db, "COMMIT")
        } catch {
            try? exec(db, "ROLLBACK")
            throw error
        }
        return changed
    }

    /// 오프로드용. `[from, to)`의 센서 원본·기록 행을 한 트랜잭션으로 지우되, 지운 행 수가 검증한 수와 다르면
    /// (검증 뒤에 새 행이 들어온 경우) 되돌리고 `false`를 돌려준다.
    func deleteRange(from: Double, to: Double, expectedReadings: Int, expectedRecords: Int) throws -> Bool {
        let db = try handle()
        try exec(db, "BEGIN IMMEDIATE")
        do {
            var removed: [Int] = []
            for table in [("readings", "ts"), ("records", "start_ts")] {
                let statement = try prepare(db, "DELETE FROM \(table.0) WHERE \(table.1) >= ? AND \(table.1) < ?")
                defer { sqlite3_finalize(statement) }
                bind(statement, 1, .real(from))
                bind(statement, 2, .real(to))
                try step(db, statement)
                removed.append(Int(sqlite3_changes(db)))
            }
            guard removed == [expectedReadings, expectedRecords] else {
                try exec(db, "ROLLBACK")
                return false
            }
            try exec(db, "COMMIT")
            return true
        } catch {
            try? exec(db, "ROLLBACK")
            throw error
        }
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

    /// 삭제로 생긴 빈 공간을 파일에서 실제로 돌려준다(오프로드 뒤에 부른다).
    func reclaimSpace() throws {
        let db = try handle()
        try exec(db, "PRAGMA wal_checkpoint(TRUNCATE)")
        // 한 번에 다 돌려주면 오래 막히므로 나눠서 돌려준다.
        for _ in 0..<10_000 {
            guard try scalarInt("PRAGMA freelist_count") > 0 else { break }
            try exec(db, "PRAGMA incremental_vacuum(2000)")
        }
        try exec(db, "PRAGMA wal_checkpoint(TRUNCATE)")
    }

    /// 위치·센서 원본만 지운다(계획·기록은 두고).
    func deleteAllReadings() throws {
        try exec(try handle(), "DELETE FROM readings")
        try reclaimSpace()
    }

    func deleteAll() throws {
        let db = try handle()
        try exec(db, "BEGIN IMMEDIATE")
        do {
            try exec(db, "DELETE FROM readings")
            try exec(db, "DELETE FROM records")
            try exec(db, "DELETE FROM raw_events")
            try exec(db, "DELETE FROM meta WHERE key <> 'schema_version'")
            try exec(db, "COMMIT")
        } catch {
            try? exec(db, "ROLLBACK")
            throw error
        }
        // 삭제 요청은 파일에 바이트가 남지 않게 빈 공간까지 돌려준다.
        try reclaimSpace()
    }

    // MARK: SQLite 보조

    private static func configure(_ db: OpaquePointer) throws {
        // auto_vacuum은 파일을 처음 만들 때(WAL 전환 전에) 정해야 적용된다. 이미 있는 파일에는 영향이 없다.
        for pragma in [
            "PRAGMA auto_vacuum=INCREMENTAL", "PRAGMA journal_mode=WAL",
            // 삭제한 위치 기록의 바이트가 빈 페이지에 남지 않게 지울 때 0으로 덮는다.
            "PRAGMA secure_delete=ON",
            "PRAGMA synchronous=NORMAL", "PRAGMA foreign_keys=ON",
        ] {
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
        try createRawEventsTable(db)
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
                BEGIN IMMEDIATE;
                CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS readings (
                    id BLOB NOT NULL UNIQUE,
                    ts REAL NOT NULL,
                    day INTEGER NOT NULL,
                    \(columnDefinitions),
                    extra TEXT
                );
                CREATE INDEX IF NOT EXISTS readings_ts ON readings(ts);
                CREATE TABLE IF NOT EXISTS records (
                    id TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    day INTEGER,
                    start_ts REAL,
                    end_ts REAL,
                    updated_ts REAL NOT NULL,
                    origin TEXT NOT NULL CHECK (origin IN ('auto', 'user', 'imported')),
                    deleted INTEGER NOT NULL DEFAULT 0,
                    ord INTEGER NOT NULL DEFAULT 0,
                    body TEXT NOT NULL,
                    PRIMARY KEY (kind, id)
                );
                CREATE INDEX IF NOT EXISTS records_kind_start ON records(kind, start_ts);
                INSERT OR IGNORE INTO meta (key, value) VALUES ('schema_version', '\(schemaVersion)');
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

    func handle() throws -> OpaquePointer {
        guard let connection else { throw TaptionStoreV2Error.openFailed("closed") }
        return connection.pointer
    }

    func exec(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(error)
            throw TaptionStoreV2Error.sqlFailed(message)
        }
    }

    func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw TaptionStoreV2Error.sqlFailed(String(cString: sqlite3_errmsg(db)))
        }
        return statement
    }

    func step(_ db: OpaquePointer, _ statement: OpaquePointer) throws {
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else {
            throw TaptionStoreV2Error.sqlFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    func scalarInt(_ sql: String) throws -> Int {
        let db = try handle()
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }

    nonisolated func bind(_ statement: OpaquePointer, _ index: Int32, _ value: TaptionReadingRowCodec.Value) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        switch value {
        case .null: sqlite3_bind_null(statement, index)
        case .int(let number): sqlite3_bind_int64(statement, index, number)
        case .real(let number): sqlite3_bind_double(statement, index, number)
        case .text(let text): sqlite3_bind_text(statement, index, text, -1, transient)
        case .blob(let data):
            _ = data.withUnsafeBytes { buffer in
                sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), transient)
            }
        }
    }

    private static func value(_ statement: OpaquePointer?, _ column: Int32) -> TaptionReadingRowCodec.Value {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER: .int(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT: .real(sqlite3_column_double(statement, column))
        case SQLITE_TEXT: .text(String(cString: sqlite3_column_text(statement, column)))
        case SQLITE_BLOB:
            .blob(Data(bytes: sqlite3_column_blob(statement, column), count: Int(sqlite3_column_bytes(statement, column))))
        default: .null
        }
    }
}
