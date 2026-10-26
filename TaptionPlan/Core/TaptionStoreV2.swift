import CryptoKit
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

/// 사용자에게는 짧은 한국어 안내만 보이고, 자세한 원인은 진단 로그에 남는다.
extension TaptionStoreV2Error: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .openFailed, .sqlFailed: "기록 저장소를 여는 중 문제가 생겼습니다."
        case .unsupportedSchema: "이 앱 버전보다 새 기록 형식입니다. 앱을 업데이트해 주세요."
        case .corruptRow, .readingConflict, .rawEventConflict: "일부 기록을 읽지 못했습니다."
        }
    }
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

/// 같은 (종류, id) 기록이 두 곳(로컬·백업 파일)에 있을 때 어느 쪽이 이기는지 정하는 순서.
/// 입력 순서나 기기와 무관하게 결정적이어야 여러 기기에서 합쳐도 같은 결과로 수렴한다:
/// 수정 시각이 나중인 쪽 → 같으면 삭제 표시 → 그래도 같으면 본문 SHA-256(hex)이 큰 쪽(같으면 바꾸지 않는다).
enum TaptionRecordMerge {
    struct Existing: Equatable, Sendable {
        var updated: Double
        var isDeleted: Bool
        var body: String
    }

    static func incomingWins(existing: Existing, incoming: TaptionStoreRecord) -> Bool {
        let incomingUpdated = incoming.updatedAt.timeIntervalSince1970
        if incomingUpdated != existing.updated { return incomingUpdated > existing.updated }
        if incoming.isDeleted != existing.isDeleted { return incoming.isDeleted }
        return bodyDigest(incoming.body) > bodyDigest(existing.body)
    }

    static func bodyDigest(_ body: String) -> String {
        SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
    }
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

    static func dayNumber(for date: Date, calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
    }

    // 행 ↔ 모델 변환(`row(for:)`·`reading(from:)`)과 내용 비교(`sameStoredContent`)는
    // `TaptionStoreColumnCoding.swift`에 있다.
    // 열 ↔ 값 변환(`take`·`convert`)은 `TaptionStoreQuality.swift`에 있다. 열 강등을 거기서 센다. 읽기는 사전을 거치지 않는다.
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
    /// 2: 확정한 하루 요약(`sealed_days`) 표가 늘었다. 1인 파일은 표만 덧붙이고 그대로 쓴다.
    static let schemaVersion = 2
    static let fileName = "taption-store.sqlite"
    /// 메모는 따로 보관한다. 파일만 다르고 표·보호 등급·삭제 방식은 같다.
    static let memoFileName = "taption-memos.sqlite"

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
        try shared(at: try applicationSupportURL(fileName: fileName, fileManager: fileManager))
    }

    /// 메모 전용 저장소. 앱 그룹 컨테이너의 같은 폴더에 `taption-memos.sqlite`로 둔다.
    /// 파일이 달라도 여는 방식·표 구조·파일 보호 등급·`secure_delete`가 본 저장소와 같다.
    static func applicationSupportMemos(fileManager: FileManager = .default) throws -> TaptionStoreV2 {
        try shared(at: try applicationSupportURL(fileName: memoFileName, fileManager: fileManager))
    }

    static func applicationSupportURL(
        fileName: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        let root = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let storeRoot = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: TaptionPlanSharedContainer.appGroupIdentifier
        ) ?? root.appendingPathComponent("TaptionPlan", isDirectory: true)
        return storeRoot.appendingPathComponent(fileName, isDirectory: false)
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
        _ = try appendReadings(readings, rejectingConflicts: true)
    }

    /// 백업 합치기용. `appendImmutableReadings`와 같지만 같은 `id`의 내용이 다르면 거부하지 않고 로컬 행을 지키며,
    /// 그런 `id`의 개수를 돌려준다(한 행 때문에 달 전체 백업이 영원히 멈추지 않게 한다).
    func mergeReadingsKeepingLocal(_ readings: [SensorReading]) throws -> Int {
        try appendReadings(readings, rejectingConflicts: false)
    }

    private func appendReadings(_ readings: [SensorReading], rejectingConflicts: Bool) throws -> Int {
        let db = try handle()
        try exec(db, "BEGIN IMMEDIATE")
        var conflicts = 0
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
                        if rejectingConflicts { throw TaptionStoreV2Error.readingConflict(value.id.uuidString) }
                        conflicts += 1
                        continue
                    }
                }
            }
            try exec(db, "COMMIT")
        } catch {
            try? exec(db, "ROLLBACK")
            throw error
        }
        return conflicts
    }

    /// 기록이 있는 현지 날짜마다 첫·마지막 시각 범위.
    /// 저장된 `day`가 지금 달력과 어긋나면(시간대 이동) 조용히 넘기지 않고 센다. 정확한 행 수는 `dayDrift()`가 센다.
    func dayRanges() throws -> [ClosedRange<Date>] {
        let db = try handle()
        let statement = try prepare(db, "SELECT day, MIN(ts), MAX(ts) FROM readings GROUP BY day ORDER BY day")
        defer { sqlite3_finalize(statement) }
        var ranges: [ClosedRange<Date>] = []
        var driftedDays = 0
        while sqlite3_step(statement) == SQLITE_ROW {
            let stored = Int(sqlite3_column_int64(statement, 0))
            let lower = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
            let upper = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            if TaptionReadingRowCodec.dayNumber(for: lower, calendar: calendar) != stored { driftedDays += 1 }
            ranges.append(lower...max(lower, upper))
        }
        TaptionStoreQualityLedger.shared.recordDayDrift(days: driftedDays, rows: nil)
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
                TaptionStoreQualityLedger.shared.recordUnreadableRow(error)
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

    /// 방금 넣은 행을 되돌리는 용도(복원 세션 롤백 등)다. **사용자 삭제 경로가 아니다.**
    /// 센서 원본에는 삭제 표시(톰스톤)가 없다. 이미 월 백업 파일에 담긴 행을 이 함수로 지우면 다음 백업이 파일에서
    /// 합집합으로 되살린다. 사용자가 원본을 지우는 경로는 전체 삭제(`deleteAllReadings`/`deleteAll`)뿐이고,
    /// 그쪽은 백업 무효화 표시를 남긴다.
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

    /// 이미 시작한 트랜잭션 안에서 행을 쓴다. 같은 행의 수정 시각(`updated_ts`)은 줄어들지 않는다(단조 증가):
    /// 백업의 "최신 수정이 이긴다" 규칙과 상위 집합 판정이 수정 시각의 후퇴에 속지 않게 한다.
    private func upsertRecordRows(_ db: OpaquePointer, _ records: [TaptionStoreRecord]) throws {
        let statement = try prepare(db, """
            INSERT INTO records
            (id, kind, day, start_ts, end_ts, updated_ts, origin, deleted, ord, body)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(kind, id) DO UPDATE SET
              day = excluded.day, start_ts = excluded.start_ts, end_ts = excluded.end_ts,
              updated_ts = MAX(excluded.updated_ts, records.updated_ts),
              origin = excluded.origin, deleted = excluded.deleted, ord = excluded.ord, body = excluded.body
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
        try allRecordRows(kinds: nil)
    }

    /// 지정한 종류의 행만 읽는다(`kinds`가 nil이면 모든 종류).
    ///
    /// 시작 적재는 스냅샷에 담기는 종류만 필요하다. HealthKit 원본 표본은
    /// `HealthKitImportStore`가 따로 쓰고 읽으므로 시작 경로에서 읽을 이유가 없다 —
    /// 실기기 로그에서 1,284,890행 중 1,258,394행이 그 표본이었고, 읽기에만 13.8초를 썼다.
    func allRecordRows(kinds: [String]?) throws -> [(kind: String, id: String, ord: Int, body: String)] {
        let db = try handle()
        let filter: String
        if let kinds, !kinds.isEmpty {
            let placeholders = Array(repeating: "?", count: kinds.count).joined(separator: ", ")
            filter = " AND kind IN (\(placeholders))"
        } else {
            filter = ""
        }
        let statement = try prepare(
            db,
            "SELECT kind, id, ord, body FROM records WHERE deleted = 0\(filter) ORDER BY kind, ord, id"
        )
        defer { sqlite3_finalize(statement) }
        if let kinds, !kinds.isEmpty {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (offset, kind) in kinds.enumerated() {
                sqlite3_bind_text(statement, Int32(offset + 1), kind, -1, transient)
            }
        }
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

    /// 모든 기록 행을 하드 삭제한다(전체 삭제 경로). 월 백업과 어긋나지 않게 같은 트랜잭션에서
    /// 백업 무효화 표시(`backup.wipe.token`)를 남긴다. 호출자는 사용자 확인 뒤 `TaptionBackupEngine.deleteAllBackups()`도 불러야
    /// 한다. 표시가 있는 동안 엔진은 이 삭제 이전에 만든 백업 파일을 합치거나 덮어쓰지 않고(되살림 방지) 알린다.
    func deleteAllRecords() throws {
        let db = try handle()
        try exec(db, "BEGIN IMMEDIATE")
        do {
            try exec(db, "DELETE FROM records")
            try markBackupsStale(db)
            try exec(db, "COMMIT")
        } catch {
            try? exec(db, "ROLLBACK")
            throw error
        }
    }

    static let backupWipeTokenKey = "backup.wipe.token"

    /// 데이터가 통째로 지워졌음을 새 무작위 값으로 남긴다. 엔진은 파일을 쓸 때 이 값을 달/설정 범위별로 기록하고,
    /// 값이 다른 파일을 "삭제 이전의 오래된 백업"으로 본다. 시계에 의존하지 않는다.
    private func markBackupsStale(_ db: OpaquePointer) throws {
        let statement = try prepare(db, "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, .text(Self.backupWipeTokenKey))
        bind(statement, 2, .text(UUID().uuidString))
        try step(db, statement)
    }

    /// 삭제 표시된 행까지 포함한 한 종류의 모든 행. 저장소 이동(메모 분리)에서 삭제 표시도 함께 옮길 때 쓴다.
    /// 삭제 표시를 두고 오면 백업을 합칠 때 오래된 메모가 되살아난다.
    func recordsIncludingDeleted(kind: String) throws -> [TaptionStoreRecord] {
        let db = try handle()
        let statement = try prepare(db, """
            SELECT id, kind, start_ts, end_ts, updated_ts, origin, deleted, ord, body
            FROM records WHERE kind = ? ORDER BY ord, id
            """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, .text(kind))
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

    /// 한 종류의 기록 행을 하드 삭제한다(삭제 표시를 남기지 않는다).    /// 사용자 삭제가 아니라 저장소 이동에만 쓴다: 메모를 별도 파일로 옮길 때 옛 파일에 남은 행을 지운다.
    /// 삭제 표시를 남기면 백업의 "삭제가 이긴다" 규칙이 옮긴 메모를 다시 지워 버린다.
    func deleteRecords(kind: String) throws {
        let db = try handle()
        let statement = try prepare(db, "DELETE FROM records WHERE kind = ?")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, .text(kind))
        try step(db, statement)
    }

    /// `[from, to)`에 시작하는 기록 행을 하드 삭제한다. 백업 파일에 담아 검증한 뒤 로컬에서 지울 때
    /// 메모 파일처럼 본 저장소 밖에 있는 행에 쓴다(본 저장소는 `deleteRange`가 지문까지 확인하고 지운다).
    func deleteRecordRange(from: Double, to: Double) throws -> Int {
        let db = try handle()
        try exec(db, "BEGIN IMMEDIATE")
        do {
            let statement = try prepare(db, """
                DELETE FROM records
                WHERE start_ts >= ?1 AND start_ts < ?2
                  AND NOT (end_ts IS NOT NULL AND end_ts > ?2)
                """)
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, .real(from))
            bind(statement, 2, .real(to))
            try step(db, statement)
            let removed = Int(sqlite3_changes(db))
            try exec(db, "COMMIT")
            return removed
        } catch {
            try? exec(db, "ROLLBACK")
            throw error
        }
    }

    func recordCount(kind: String? = nil) throws -> Int {        if let kind {
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

    /// 복원·백업 합치기용. 같은 종류·`id`가 있으면 `TaptionRecordMerge`의 순서(수정 시각이 나중인 쪽, 같으면 삭제 표시,
    /// 그래도 같으면 본문 해시가 큰 쪽)로 이기는 쪽만 남긴다. 같은 입력이면 어느 기기에서 합쳐도 같은 결과다.
    /// 새로 넣었거나 덮어쓴 행 수를 돌려준다.
    @discardableResult
    func upsertRecordsKeepingNewer(_ records: [TaptionStoreRecord]) throws -> Int {
        let db = try handle()
        try exec(db, "BEGIN IMMEDIATE")
        var changed = 0
        do {
            let lookup = try prepare(db, "SELECT updated_ts, deleted, body FROM records WHERE kind = ? AND id = ?")
            defer { sqlite3_finalize(lookup) }
            for record in records {
                sqlite3_reset(lookup)
                sqlite3_clear_bindings(lookup)
                bind(lookup, 1, .text(record.kind))
                bind(lookup, 2, .text(record.id))
                if sqlite3_step(lookup) == SQLITE_ROW {
                    let existing = TaptionRecordMerge.Existing(
                        updated: sqlite3_column_double(lookup, 0),
                        isDeleted: sqlite3_column_int(lookup, 1) != 0,
                        body: String(cString: sqlite3_column_text(lookup, 2))
                    )
                    guard TaptionRecordMerge.incomingWins(existing: existing, incoming: record) else { continue }
                }
                try upsertRecordRows(db, [record])
                changed += 1
            }
            try exec(db, "COMMIT")
        } catch {
            try? exec(db, "ROLLBACK")
            throw error
        }
        return changed
    }

    /// 범위 `[from, to)`의 상태 지문. 오프로드가 "검증한 그 상태 그대로인지"를 가리는 데 쓴다.
    /// 센서 원본은 수정이 `INSERT OR REPLACE`라 다시 쓰면 rowid가 새로 커지므로 개수와 가장 큰 rowid로 편집을 잡고,
    /// 기록은 행 개수와 (종류, id, 수정 시각, 삭제 여부, 본문) 해시로 같은 수정 시각의 편집까지 잡는다.
    struct RangeFingerprint: Equatable, Sendable {
        var readings = 0
        var maxReadingRowID: Int64 = 0
        var records = 0
        var recordDigest = ""
    }

    func rangeFingerprint(from: Double, to: Double) throws -> RangeFingerprint {
        let db = try handle()
        return try fingerprint(db, from: from, to: to)
    }

    private func fingerprint(_ db: OpaquePointer, from: Double, to: Double) throws -> RangeFingerprint {
        var result = RangeFingerprint()
        let statement = try prepare(db, "SELECT COUNT(*), COALESCE(MAX(rowid), 0) FROM readings WHERE ts >= ? AND ts < ?")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, .real(from))
        bind(statement, 2, .real(to))
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw TaptionStoreV2Error.sqlFailed(String(cString: sqlite3_errmsg(db)))
        }
        result.readings = Int(sqlite3_column_int64(statement, 0))
        result.maxReadingRowID = sqlite3_column_int64(statement, 1)
        var hasher = SHA256()
        for record in try loadBackupRecords(where: "start_ts >= ? AND start_ts < ?", bindings: [.real(from), .real(to)]) {
            result.records += 1
            hasher.update(data: Data(
                "\(record.kind)\u{1F}\(record.id)\u{1F}\(record.updatedAt.timeIntervalSince1970)\u{1F}\(record.isDeleted)\u{1F}\(record.body)\u{1E}".utf8
            ))
        }
        result.recordDigest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return result
    }

    /// 오프로드용. `[from, to)`의 센서 원본과 기록 행을 한 트랜잭션으로 지우되, 같은 트랜잭션에서 범위의 지문을 다시
    /// 계산해 `expected`(검증을 시작할 때 잰 값)와 다르면 되돌리고 `nil`을 돌려준다(검증 뒤 삭제 사이에 들어온 새 행뿐
    /// 아니라 편집·삭제 표시도 놓치지 않는다). 봉인 표시(`sealedMeta`)는 같은 트랜잭션에 기록해 크래시로
    /// "지웠는데 봉인 표시가 없는" 상태가 생기지 않게 한다.
    /// 끝(`end_ts`)이 `to` 뒤인 기록(달이 끝나도 진행 중인 긴 기록)은 지우지 않고 남긴다. 지운 행 수를 돌려준다.
    func deleteRange(
        from: Double, to: Double, expected: RangeFingerprint, sealedMeta: (key: String, value: String)? = nil
    ) throws -> (readings: Int, records: Int)? {
        let db = try handle()
        try exec(db, "BEGIN IMMEDIATE")
        do {
            guard try fingerprint(db, from: from, to: to) == expected else {
                try exec(db, "ROLLBACK")
                return nil
            }
            var removed: [Int] = []
            let conditions = [
                ("readings", "ts >= ?1 AND ts < ?2"),
                ("records", "start_ts >= ?1 AND start_ts < ?2 AND NOT (end_ts IS NOT NULL AND end_ts > ?2)"),
            ]
            for (table, condition) in conditions {
                let statement = try prepare(db, "DELETE FROM \(table) WHERE \(condition)")
                defer { sqlite3_finalize(statement) }
                bind(statement, 1, .real(from))
                bind(statement, 2, .real(to))
                try step(db, statement)
                removed.append(Int(sqlite3_changes(db)))
            }
            if let sealedMeta {
                let statement = try prepare(db, "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)")
                defer { sqlite3_finalize(statement) }
                bind(statement, 1, .text(sealedMeta.key))
                bind(statement, 2, .text(sealedMeta.value))
                try step(db, statement)
            }
            try exec(db, "COMMIT")
            return (removed[0], removed[1])
        } catch {
            try? exec(db, "ROLLBACK")
            throw error
        }
    }

    /// 데이터(센서 원본·시작 시각이 있는 기록)가 있는 UTC 날짜 번호(1970-01-01부터). 월 순회가 비정상으로 먼
    /// 시각(예: `distantPast`) 하나 때문에 수만 달을 도는 것을 막고, 실제 데이터가 있는 달만 고르는 데 쓴다.
    func dataUTCDays() throws -> [Int] {
        let db = try handle()
        let statement = try prepare(db, """
            SELECT DISTINCT CAST(v / 86400.0 AS INTEGER) AS d FROM (
              SELECT ts AS v FROM readings UNION ALL SELECT start_ts FROM records WHERE start_ts IS NOT NULL)
            ORDER BY d
            """)
        defer { sqlite3_finalize(statement) }
        var days: [Int] = []
        while sqlite3_step(statement) == SQLITE_ROW { days.append(Int(sqlite3_column_int64(statement, 0))) }
        return days
    }

    // MARK: 확정한 하루 요약

    /// 확정한 하루를 저장한다. 같은 날짜가 있으면 덮어쓴다(다시 확정한 경우).
    func upsertSealedDays(_ days: [TaptionSealedDay]) throws {
        guard !days.isEmpty else { return }
        let db = try handle()
        try exec(db, "BEGIN IMMEDIATE")
        do {
            let statement = try prepare(db, """
                INSERT INTO sealed_days (day, sealed_ts, fingerprint, payload) VALUES (?, ?, ?, ?)
                ON CONFLICT(day) DO UPDATE SET
                  sealed_ts = excluded.sealed_ts,
                  fingerprint = excluded.fingerprint,
                  payload = excluded.payload
                """)
            defer { sqlite3_finalize(statement) }
            for day in days {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(statement, 1, .int(Int64(Self.dayNumber(for: day.dayStart, calendar: calendar))))
                bind(statement, 2, .real(day.sealedAt.timeIntervalSince1970))
                bind(statement, 3, day.sourceFingerprint.map { .text($0) } ?? .null)
                bind(statement, 4, .blob(try Self.sealedPayload(day)))
                try step(db, statement)
            }
            try exec(db, "COMMIT")
        } catch {
            try? exec(db, "ROLLBACK")
            throw error
        }
    }

    /// `[from, through]`(둘 다 `yyyymmdd`) 범위의 확정 요약. 해석할 수 없는 행은 건너뛴다.
    func sealedDays(from: Int? = nil, through: Int? = nil) throws -> [TaptionSealedDay] {
        let db = try handle()
        var sql = "SELECT payload FROM sealed_days"
        if from != nil || through != nil { sql += " WHERE 1 = 1" }
        if from != nil { sql += " AND day >= ?" }
        if through != nil { sql += " AND day <= ?" }
        sql += " ORDER BY day"
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        var index: Int32 = 1
        if let from { bind(statement, index, .int(Int64(from))); index += 1 }
        if let through { bind(statement, index, .int(Int64(through))) }
        var result: [TaptionSealedDay] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            defer { code = sqlite3_step(statement) }
            guard let blob = Self.blob(statement, 0) else { continue }
            if let value = Self.decodeSealedDay(blob) { result.append(value) }
        }
        guard code == SQLITE_DONE else {
            throw TaptionStoreV2Error.sqlFailed(String(cString: sqlite3_errmsg(db)))
        }
        return result
    }

    func sealedDay(for day: Date) throws -> TaptionSealedDay? {
        let db = try handle()
        let statement = try prepare(db, "SELECT payload FROM sealed_days WHERE day = ?")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, .int(Int64(Self.dayNumber(for: day, calendar: calendar))))
        guard sqlite3_step(statement) == SQLITE_ROW, let blob = Self.blob(statement, 0) else { return nil }
        return Self.decodeSealedDay(blob)
    }

    func sealedDayCount() throws -> Int {
        try scalarInt("SELECT COUNT(*) FROM sealed_days")
    }

    func deleteSealedDays(numbers: [Int]) throws {
        guard !numbers.isEmpty else { return }
        let db = try handle()
        try exec(db, "BEGIN IMMEDIATE")
        do {
            let statement = try prepare(db, "DELETE FROM sealed_days WHERE day = ?")
            defer { sqlite3_finalize(statement) }
            for number in numbers {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(statement, 1, .int(Int64(number)))
                try step(db, statement)
            }
            try exec(db, "COMMIT")
        } catch {
            try? exec(db, "ROLLBACK")
            throw error
        }
    }

    private static func dayNumber(for date: Date, calendar: Calendar) -> Int {
        TaptionReadingRowCodec.dayNumber(for: date, calendar: calendar)
    }

    private static func sealedPayload(_ day: TaptionSealedDay) throws -> Data {
        let encoded = try TaptionPlanCanonicalStorage.encode(day, compress: true)
        return TaptionPlanCanonicalStorage.envelope(for: encoded)
    }

    private static func decodeSealedDay(_ envelope: Data) -> TaptionSealedDay? {
        guard let payload = try? TaptionPlanCanonicalStorage.encodedPayload(from: envelope),
              let value = try? TaptionPlanCanonicalStorage.decode(TaptionSealedDay.self, from: payload),
              value.version <= TaptionSealedDay.currentVersion else { return nil }
        return value
    }

    private static func blob(_ statement: OpaquePointer?, _ column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) == SQLITE_BLOB,
              let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
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
    /// 전체 삭제 경로: 백업 무효화 표시를 같은 트랜잭션에 남긴다(`deleteAllRecords` 설명 참고).
    func deleteAllReadings() throws {
        let db = try handle()
        try exec(db, "BEGIN IMMEDIATE")
        do {
            try exec(db, "DELETE FROM readings")
            try markBackupsStale(db)
            try exec(db, "COMMIT")
        } catch {
            try? exec(db, "ROLLBACK")
            throw error
        }
        try reclaimSpace()
    }

    /// 전체 삭제 경로(원본·기록·원본 이벤트·메타). 백업 무효화 표시는 `deleteAllRecords` 설명과 같다.
    func deleteAll() throws {
        let db = try handle()
        try exec(db, "BEGIN IMMEDIATE")
        do {
            try exec(db, "DELETE FROM readings")
            try exec(db, "DELETE FROM records")
            try exec(db, "DELETE FROM raw_events")
            try exec(db, "DELETE FROM sealed_days")
            try exec(db, "DELETE FROM meta WHERE key <> 'schema_version'")
            // 봉인·달력 같은 백업 보조 값은 함께 지우되, 이전 백업 파일이 무효라는 표시는 남긴다.
            try markBackupsStale(db)
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
        } else {
            try addMissingRecordsColumns(db)
        }
        // 확정한 하루 요약 표는 1인 파일에도 덧붙인다(기존 행은 건드리지 않는다).
        try execStatic(db, Self.sealedDaysSchema)
        if current < schemaVersion {
            try execStatic(db, "PRAGMA user_version = \(schemaVersion)")
        }
    }

    /// 확정한 하루 요약. 하루에 한 행이고 본문은 이진 프로퍼티 리스트를 LZFSE로 압축한 덩어리다.
    private static let sealedDaysSchema = """
        CREATE TABLE IF NOT EXISTS sealed_days (
            day INTEGER PRIMARY KEY,
            sealed_ts REAL NOT NULL,
            fingerprint TEXT,
            payload BLOB NOT NULL
        );
        """

    /// 순서 열(`ord`)이 생기기 전에 만든 저장소는 같은 user_version 1이라, 열이 없으면 한 번 덧붙인다(기존 행은 0).
    private static func addMissingRecordsColumns(_ db: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(records)", -1, &statement, nil) == SQLITE_OK else {
            throw TaptionStoreV2Error.sqlFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        var hasOrd = false
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1), String(cString: name) == "ord" { hasOrd = true }
        }
        guard !hasOrd else { return }
        guard sqlite3_exec(db, "ALTER TABLE records ADD COLUMN ord INTEGER NOT NULL DEFAULT 0", nil, nil, nil) == SQLITE_OK else {
            throw TaptionStoreV2Error.sqlFailed(String(cString: sqlite3_errmsg(db)))
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

    private static func execStatic(_ db: OpaquePointer, _ sql: String) throws {
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
