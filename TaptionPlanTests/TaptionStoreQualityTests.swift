import Foundation
import SQLite3
import XCTest
@testable import TaptionPlan

/// 저장소가 조용히 버리는 것(열 강등·해독 실패·`day` 불일치)을 실제로 세는지 확인한다.
/// 계수는 프로세스 전역이므로 테스트마다 비운다.
final class TaptionStoreQualityTests: XCTestCase {
    private var root: URL!

    private var storeURL: URL { root.appendingPathComponent("store.sqlite") }

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("taption-quality-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        TaptionStoreQualityLedger.shared.reset()
    }

    override func tearDownWithError() throws {
        TaptionStoreQualityLedger.shared.reset()
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    // MARK: G1 — 열 강등

    func testMatchingValueIsNotCountedAsDemoted() {
        let column = TaptionReadingRowCodec.Column(name: "speed_mps", path: "speedMetersPerSecond", kind: .real)
        var object: [String: Any] = ["speedMetersPerSecond": 1.5]
        XCTAssertEqual(TaptionReadingRowCodec.take(column, from: &object), .real(1.5))
        XCTAssertTrue(TaptionStoreQualityLedger.shared.snapshot().demotedColumns.isEmpty)
        XCTAssertTrue(object.isEmpty, "열로 옮긴 키는 사전에서 빠져야 한다")
    }

    func testWrongTypeIsCountedAsDemotedAndLeftInPlace() {
        let column = TaptionReadingRowCodec.Column(name: "speed_mps", path: "speedMetersPerSecond", kind: .real)
        var object: [String: Any] = ["speedMetersPerSecond": "fast"]
        XCTAssertEqual(TaptionReadingRowCodec.take(column, from: &object), .null)
        XCTAssertEqual(TaptionStoreQualityLedger.shared.snapshot().demotedColumns["speed_mps"], 1)
        XCTAssertEqual(object["speedMetersPerSecond"] as? String, "fast", "값은 extra로 남아야 한다")
    }

    func testMissingKeyIsNotCountedAsDemoted() {
        let column = TaptionReadingRowCodec.Column(name: "speed_mps", path: "speedMetersPerSecond", kind: .real)
        var object: [String: Any] = [:]
        XCTAssertEqual(TaptionReadingRowCodec.take(column, from: &object), .null)
        XCTAssertTrue(
            TaptionStoreQualityLedger.shared.snapshot().demotedColumns.isEmpty,
            "키가 아예 없는 정상적인 빈 값은 강등이 아니다"
        )
    }

    func testNestedColumnDemotionIsCounted() {
        let column = TaptionReadingRowCodec.Column(name: "lat", path: "point.latitude", kind: .real)
        var object: [String: Any] = ["point": ["latitude": "north"]]
        XCTAssertEqual(TaptionReadingRowCodec.take(column, from: &object), .null)
        XCTAssertEqual(TaptionStoreQualityLedger.shared.snapshot().demotedColumns["lat"], 1)
    }

    func testBooleanColumnRejectsNumbers() {
        // JSON 불리언은 NSNumber로 오지만 CFBoolean 타입이어야 한다. 정수 1은 강등이다.
        let column = TaptionReadingRowCodec.Column(name: "screen_on", path: "screenIsOn", kind: .bool)
        var number: [String: Any] = ["screenIsOn": NSNumber(value: 1)]
        XCTAssertEqual(TaptionReadingRowCodec.take(column, from: &number), .null)
        var flag: [String: Any] = ["screenIsOn": NSNumber(value: true)]
        XCTAssertEqual(TaptionReadingRowCodec.take(column, from: &flag), .int(1))
        XCTAssertEqual(TaptionStoreQualityLedger.shared.snapshot().demotedColumns["screen_on"], 1)
    }

    // MARK: G2 — 해독 실패

    func testUnreadableRowIsCountedAndLoadReportsIncomplete() async throws {
        let store = try TaptionStoreV2(url: storeURL, calendar: calendar(secondsFromGMT: 0))
        // `extra`가 JSON이 아니면 `reading(from:)`이 corruptRow로 실패한다.
        // 다른 버전이 쓴 파일이나 손상된 파일에서 실제로 생길 수 있는 모양이다.
        try execute(
            """
            INSERT INTO readings (id, ts, day, extra)
            VALUES (x'00112233445566778899AABBCCDDEEFF', 1000, 20260101, '{')
            """
        )
        let result = try await store.readingsLoadResult(
            from: Date(timeIntervalSince1970: 0),
            through: Date(timeIntervalSince1970: 5000)
        )
        XCTAssertTrue(result.readings.isEmpty)
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(TaptionStoreQualityLedger.shared.snapshot().unreadableRows, 1)
        XCTAssertEqual(TaptionStoreQualityLedger.shared.snapshot().unreadableReasons.count, 1)
    }

    func testReadableRowIsNotCounted() async throws {
        let store = try TaptionStoreV2(url: storeURL, calendar: calendar(secondsFromGMT: 0))
        // 실제 모델로 쓴 행은 하나도 빠지지 않고, 열 강등도 없어야 한다(오경보 방지).
        let reading = SensorReading(
            timestamp: Date(timeIntervalSince1970: 1000),
            point: GeoPoint(
                latitude: 37.5612, longitude: 126.8115, altitude: 21.5,
                horizontalAccuracy: 12.25, verticalAccuracy: 3
            ),
            locationFixQuality: .precise,
            gpsAvailable: true,
            sourceDevice: .iPhone
        )
        try await store.appendImmutableReadings([reading])
        let result = try await store.readingsLoadResult(
            from: Date(timeIntervalSince1970: 0),
            through: Date(timeIntervalSince1970: 5000)
        )
        XCTAssertEqual(result.readings.count, 1)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(TaptionStoreQualityLedger.shared.snapshot().unreadableRows, 0)
        XCTAssertTrue(
            TaptionStoreQualityLedger.shared.snapshot().demotedColumns.isEmpty,
            "실제 모델의 값은 어느 열과도 형태가 어긋나지 않아야 한다"
        )
    }

    // MARK: G4 — day 불일치

    func testDayDriftIsDetectedWhenTheStoredDayWasWrittenInAnotherTimeZone() async throws {
        // 2026-01-01 20:00 UTC = 2026-01-02 05:00 KST. UTC로 쓴 행은 day가 20260101이다.
        let utc = try TaptionStoreV2(url: storeURL, calendar: calendar(secondsFromGMT: 0))
        try execute(
            """
            INSERT INTO readings (id, ts, day)
            VALUES (x'00112233445566778899AABBCCDDEEFF', 1767297600, 20260101)
            """
        )
        let sameZone = try await utc.dayDrift()
        XCTAssertTrue(sameZone.isClean, "쓴 달력과 같은 달력으로 보면 어긋나지 않는다")

        let seoul = try TaptionStoreV2(url: storeURL, calendar: calendar(secondsFromGMT: 9 * 3600))
        let drift = try await seoul.dayDrift()
        XCTAssertEqual(drift.days, 1)
        XCTAssertEqual(drift.rows, 1)
        XCTAssertEqual(TaptionStoreQualityLedger.shared.snapshot().driftedDays, 1)
    }

    func testDayRangesCountsDriftWithoutRowCount() async throws {
        let utc = try TaptionStoreV2(url: storeURL, calendar: calendar(secondsFromGMT: 0))
        try execute(
            """
            INSERT INTO readings (id, ts, day)
            VALUES (x'00112233445566778899AABBCCDDEEFF', 1767297600, 20260101)
            """
        )
        _ = try await utc.dayRanges()
        XCTAssertEqual(TaptionStoreQualityLedger.shared.snapshot().driftedDays, 0, "같은 달력이면 0이다")

        let seoul = try TaptionStoreV2(url: storeURL, calendar: calendar(secondsFromGMT: 9 * 3600))
        let ranges = try await seoul.dayRanges()
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(TaptionStoreQualityLedger.shared.snapshot().driftedDays, 1)
    }

    // MARK: 원장

    func testResetClearsEveryCounter() {
        TaptionStoreQualityLedger.shared.recordDemotedColumn("lat")
        TaptionStoreQualityLedger.shared.recordUnreadableRow(TaptionStoreV2Error.corruptRow("bad"))
        TaptionStoreQualityLedger.shared.recordDayDrift(days: 2, rows: 10)
        TaptionStoreQualityLedger.shared.reset()
        XCTAssertEqual(TaptionStoreQualityLedger.shared.snapshot(), TaptionStoreQualityLedger.Snapshot())
    }

    // MARK: 도우미

    /// 저장소 밖에서 행을 직접 넣는다. 운영 코드에 테스트용 통로를 만들지 않으려고 이렇게 한다.
    private func execute(_ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(storeURL.path, &db) == SQLITE_OK else {
            throw TaptionStoreV2Error.openFailed(storeURL.path)
        }
        defer { sqlite3_close(db) }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(error)
            throw TaptionStoreV2Error.sqlFailed(message)
        }
    }

    private func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    private func calendar(secondsFromGMT: Int) -> Calendar {
        calendar(TimeZone(secondsFromGMT: secondsFromGMT) ?? TimeZone(identifier: "GMT") ?? .current)
    }
}
