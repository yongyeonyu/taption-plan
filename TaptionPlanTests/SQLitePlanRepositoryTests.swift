import Foundation
import Darwin
import SQLite3
import XCTest
@testable import TaptionPlan
import TaptionPlanCore

final class CloudKitSnapshotAssetTests: XCTestCase {
    func testCloudKitTemporaryAssetUsesFileProtection() throws {
        let url = try CloudKitSnapshotSyncService.writeTemporaryAsset(
            Data(repeating: 0x41, count: 850_001)
        )
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
#if !targetEnvironment(simulator)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey]
                as? FileProtectionType,
            .completeUntilFirstUserAuthentication
        )
#endif
    }
}

final class UnavailablePlanRepositoryTests: XCTestCase {
    func testUnavailableRepositoryFailsClosedForLoadSaveAndDelete() async {
        let repository = UnavailablePlanRepository()
        do {
            _ = try await repository.load()
            XCTFail("unavailable repository unexpectedly loaded")
        } catch {
            XCTAssertEqual(error as? PlanRepositoryAvailabilityError, .unavailable)
        }
        do {
            try await repository.save(.empty)
            XCTFail("unavailable repository unexpectedly saved")
        } catch {
            XCTAssertEqual(error as? PlanRepositoryAvailabilityError, .unavailable)
        }
        do {
            try await repository.deleteAll()
            XCTFail("unavailable repository unexpectedly deleted")
        } catch {
            XCTAssertEqual(error as? PlanRepositoryAvailabilityError, .unavailable)
        }
    }
}

import SQLite3

final class TaptionStoreV2Tests: XCTestCase {
    private var directory: URL!
    private var calendar: Calendar!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("store-v2-\(UUID().uuidString)")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul") ?? .current
        self.calendar = calendar
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var storeURL: URL { directory.appendingPathComponent("taption.sqlite") }
    private let base = Date(timeIntervalSince1970: 1_792_300_000)  // 2026-10-18 14:06 KST

    private func reading(
        _ offset: TimeInterval, speed: Double? = nil, device: TrackingDevice = .iPhone
    ) -> SensorReading {
        var value = SensorReading(
            timestamp: base.addingTimeInterval(offset),
            point: GeoPoint(latitude: 37.5612, longitude: 126.8115, altitude: 21.5,
                            horizontalAccuracy: 12.25, verticalAccuracy: 3),
            locationFixQuality: .precise,
            gpsAvailable: true,
            sourceDevice: device
        )
        value.speedMetersPerSecond = speed
        return value
    }

    func testReappendingTheSameReadingWithFractionalTimestampIsNotAConflict() async throws {
        let store = try TaptionStoreV2(url: storeURL, calendar: calendar)
        // Date.now 같은 값은 1970년 기준 초로 바꿀 때 마지막 비트가 달라질 수 있다.
        let stamp = Date(timeIntervalSinceReferenceDate: 800_000_000.123456789)
        var value = reading(0)
        value.timestamp = stamp
        try await store.appendImmutableReadings([value])
        try await store.appendImmutableReadings([value])
        let count = try await store.readingCount()
        XCTAssertEqual(count, 1)
    }

    func testRawEventsAreImmutableKeepOriginAndProvenanceAndRollBackOnConflict() async throws {
        let store = try TaptionStoreV2(url: storeURL, calendar: calendar)
        let first = TaptionRawEvent(
            kind: "watch-acceleration", id: "a", timestamp: base, sequence: 3,
            origin: .auto, provenance: ["source-device:appleWatch"], payload: "{\"x\":1}"
        )
        let second = TaptionRawEvent(
            kind: "watch-acceleration", id: "b", timestamp: base.addingTimeInterval(10),
            origin: .imported, provenance: [], payload: "{\"x\":2}"
        )
        let inserted = try await store.appendRawEvents([first, second])
        XCTAssertEqual(inserted, ["a", "b"])
        let repeated = try await store.appendRawEvents([first])
        XCTAssertEqual(repeated, [], "같은 내용은 그대로 두고 새로 넣은 것으로 세지 않는다")

        var changed = first
        changed.payload = "{\"x\":9}"
        let fresh = TaptionRawEvent(kind: "watch-acceleration", id: "c", timestamp: base, payload: "{}")
        do {
            _ = try await store.appendRawEvents([fresh, changed])
            XCTFail("a different payload with the same id was accepted")
        } catch let error as TaptionStoreV2Error {
            XCTAssertEqual(error, .rawEventConflict(kind: "watch-acceleration", id: "a"))
        }
        let count = try await store.rawEventCount(kind: "watch-acceleration")
        XCTAssertEqual(count, 2, "충돌이 있으면 같은 묶음의 다른 이벤트도 들어가지 않는다")

        let all = try await store.rawEvents(kind: "watch-acceleration")
        XCTAssertEqual(all.map(\.id), ["a", "b"])
        XCTAssertEqual(all.first?.provenance, ["source-device:appleWatch"])
        XCTAssertEqual(all.last?.origin, .imported)
        let window = try await store.rawEvents(kind: "watch-acceleration", from: base, through: base)
        XCTAssertEqual(window.map(\.id), ["a"])
        try await store.validateRawEvents([first, second])
        do {
            try await store.validateRawEvents([changed])
            XCTFail("validation accepted a conflicting event")
        } catch is TaptionStoreV2Error {}

        try await store.deleteRawEvents(kind: "watch-acceleration", ids: ["a"])
        let remaining = try await store.rawEvents(kind: "watch-acceleration").map(\.id)
        XCTAssertEqual(remaining, ["b"])
        try await store.deleteAll()
        let afterDeleteAll = try await store.rawEventCount(kind: "watch-acceleration")
        XCTAssertEqual(afterDeleteAll, 0)
    }

    func testReappendingARawEventWithFractionalTimestampIsNotAConflict() async throws {
        let store = try TaptionStoreV2(url: storeURL, calendar: calendar)
        let event = TaptionRawEvent(
            kind: "watch-summary", id: "s:1",
            timestamp: Date(timeIntervalSinceReferenceDate: 800_000_000.123456789),
            payload: "{}"
        )
        let first = try await store.appendRawEvents([event])
        let second = try await store.appendRawEvents([event])
        try await store.validateRawEvents([event])
        XCTAssertEqual(first, ["s:1"])
        XCTAssertEqual(second, [])
    }

    func testRawEventTableIsPlainSQLAndSurvivesReopen() async throws {
        let store = try TaptionStoreV2(url: storeURL, calendar: calendar)
        try await store.appendRawEvents([TaptionRawEvent(
            kind: "device-envelope", id: "e1", timestamp: base, provenance: ["source:gps"],
            payload: "{\"kind\":\"location\"}"
        )])
        await store.close()
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(storeURL.path, &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(
            handle,
            "SELECT json_extract(payload, '$.kind'), origin, ts FROM raw_events WHERE kind = 'device-envelope'",
            -1, &statement, nil
        ), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), "location")
        XCTAssertEqual(String(cString: sqlite3_column_text(statement, 1)), "auto")
        XCTAssertEqual(sqlite3_column_double(statement, 2), base.timeIntervalSince1970)
        let reopened = try TaptionStoreV2(url: storeURL, calendar: calendar)
        let count = try await reopened.rawEventCount(kind: "device-envelope")
        XCTAssertEqual(count, 1)
    }

    func testReadingRoundTripKeepsEveryFieldIncludingNestedOnes() async throws {
        let store = try TaptionStoreV2(url: storeURL, calendar: calendar)
        var rich = reading(0, speed: 1.75)
        rich.motion = .walking
        rich.motionConfidence = .high
        rich.courseDegrees = 271.5
        rich.nearbyStation = true
        rich.nearbyStationName = "송정"
        rich.matchesRailRoute = true
        rich.stepCount = 1234
        rich.behavior = "commute"
        rich.trackingSessionID = UUID()
        rich.trackingKind = .automatic
        rich.trackingWasAutomaticallyDetected = true
        rich.sequence = 42
        rich.deviceMotionSummary = DeviceMotionSummary(
            sampleCount: 30, meanUserAccelerationG: 0.12, userAccelerationStandardDeviationG: 0.03,
            peakUserAccelerationG: 0.4, meanRotationRateRadiansPerSecond: 0.2,
            rotationRateStandardDeviationRadiansPerSecond: 0.05, peakRotationRateRadiansPerSecond: 0.9
        )
        rich.behaviorEvidence = ["a", "b"]
        try await store.upsertReadings([rich, reading(10)])

        let loaded = try await store.readings(from: base.addingTimeInterval(-1), to: base.addingTimeInterval(60))
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.first, rich)
        XCTAssertNil(loaded.last?.speedMetersPerSecond)
    }

    func testUpsertReplacesTheSameIDAndRangeIsHalfOpenAndOrdered() async throws {
        let store = try TaptionStoreV2(url: storeURL, calendar: calendar)
        var first = reading(30, speed: 1)
        try await store.upsertReadings([first, reading(0), reading(60)])
        first.speedMetersPerSecond = 9
        try await store.upsertReadings([first])
        let count = try await store.readingCount()
        XCTAssertEqual(count, 3)
        let loaded = try await store.readings(from: base, to: base.addingTimeInterval(60))
        XCTAssertEqual(loaded.map(\.timestamp), [base, base.addingTimeInterval(30)])
        XCTAssertEqual(loaded.last?.speedMetersPerSecond, 9)
    }

    func testReadingsAreQueryableWithPlainSQLByColumn() async throws {
        let store = try TaptionStoreV2(url: storeURL, calendar: calendar)
        try await store.upsertReadings([
            reading(0, speed: 0.5), reading(30, speed: 25), reading(60, speed: 40, device: .appleWatch),
        ])
        await store.close()

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(storeURL.path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(database) }
        func scalar(_ sql: String) -> Int32 {
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(database, sql, -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            return sqlite3_column_int(statement, 0)
        }
        XCTAssertEqual(scalar("SELECT COUNT(*) FROM readings WHERE speed_mps > 20"), 2)
        XCTAssertEqual(scalar("SELECT COUNT(*) FROM readings WHERE source_device = 'appleWatch'"), 1)
        XCTAssertEqual(scalar("SELECT COUNT(*) FROM readings WHERE day = 20261018"), 3, "현지(서울) 날짜가 정수로 나뉜다")
        XCTAssertEqual(scalar("SELECT COUNT(*) FROM readings WHERE h_acc < 20 AND fix_quality = 'precise'"), 3)
        XCTAssertEqual(scalar("PRAGMA user_version"), Int32(TaptionStoreV2.schemaVersion))
        XCTAssertEqual(scalar("PRAGMA auto_vacuum"), 2, "삭제한 공간을 돌려받으려면 증분 auto_vacuum이어야 한다")
    }

    func testStoreStaysSmallAndGivesSpaceBackAfterDeletingOldDays() async throws {
        let store = try TaptionStoreV2(url: storeURL, calendar: calendar)
        let count = 6_000
        let readings = (0..<count).map { index -> SensorReading in
            var value = reading(Double(index) * 6, speed: Double(index % 30))
            value.motion = index % 3 == 0 ? .walking : .stationary
            value.deviceMotionSummary = DeviceMotionSummary(
                sampleCount: 12, meanUserAccelerationG: 0.01, userAccelerationStandardDeviationG: 0.005,
                peakUserAccelerationG: 0.05, meanRotationRateRadiansPerSecond: 0.01,
                rotationRateStandardDeviationRadiansPerSecond: 0.004, peakRotationRateRadiansPerSecond: 0.03
            )
            return value
        }
        try await store.upsertReadings(readings)
        try await store.reclaimSpace()
        func size() -> Int {
            ((try? FileManager.default.attributesOfItem(atPath: storeURL.path)[.size]) as? Int) ?? 0
        }
        let fullSize = size()
        let bytesPerRow = Double(fullSize) / Double(count)
        print("ARC1019A01 store bytes_per_reading=\(bytesPerRow) total=\(fullSize)")
        XCTAssertLessThan(bytesPerRow, 260, "움직임 요약까지 있는 기록 한 건이 이 크기를 넘지 않아야 한다")

        // 앞의 3/4를 지우고 공간을 돌려받는다.
        let doomed = readings.prefix(count * 3 / 4).map { $0.id.uuidString }
        try await store.deleteReadings(ids: Array(doomed))
        try await store.reclaimSpace()
        let shrunk = size()
        XCTAssertLessThan(shrunk, fullSize / 2, "삭제 뒤 파일이 실제로 줄어야 한다")
        let remaining = try await store.readingCount()
        XCTAssertEqual(remaining, count / 4)
    }

    func testSameIDInDifferentKindsDoesNotOverwriteEachOther() async throws {
        let store = try TaptionStoreV2(url: storeURL, calendar: calendar)
        func record(_ kind: String, _ body: String) -> TaptionStoreRecord {
            TaptionStoreRecord(id: "same", kind: kind, start: base, end: nil, updatedAt: base,
                               origin: .user, body: body)
        }
        try await store.upsertRecords([record("category", #"{"a":1}"#), record("photo", #"{"b":2}"#)])
        let categories = try await store.records(kind: "category")
        let photos = try await store.records(kind: "photo")
        XCTAssertEqual(categories.map(\.body), [#"{"a":1}"#])
        XCTAssertEqual(photos.map(\.body), [#"{"b":2}"#])
    }

    func testApplyRecordChangesRollsBackDeletesWhenTheWriteFails() async throws {
        let store = try TaptionStoreV2(url: storeURL, calendar: calendar)
        func record(_ id: String) -> TaptionStoreRecord {
            TaptionStoreRecord(id: id, kind: "plan", start: base, end: nil, updatedAt: base,
                               origin: .user, body: "{}")
        }
        try await store.upsertRecords([record("keep")])
        // origin CHECK는 통과하지만 body가 NOT NULL인 열에 NULL을 넣을 수 없으니, 잘못된 kind 길이 대신
        // 저장소가 거부하는 입력(닫힌 연결)으로 실패를 만든다.
        await store.close()
        do {
            try await store.applyRecordChanges(upserts: [record("new")], deletes: [("plan", "keep")])
            XCTFail("닫힌 저장소는 거부해야 한다")
        } catch {}
        let reopened = try TaptionStoreV2(url: storeURL, calendar: calendar)
        let kept = try await reopened.records(kind: "plan")
        XCTAssertEqual(kept.map(\.id), ["keep"], "실패한 변경은 삭제도 반영하지 않는다")
    }

    func testResendingTheSameReadingWithFractionalSecondsIsNotAConflict() async throws {
        let store = try TaptionStoreV2(url: storeURL, calendar: calendar)
        // 기준일(2001) 기준 소수 초를 가진 시각: 1970 기준으로 바꾸면 반올림되는 값이다.
        let fractional = Date(timeIntervalSinceReferenceDate: 813_740_029.554995)
        let sent = SensorReading(
            timestamp: fractional,
            point: GeoPoint(latitude: 37.5, longitude: 126.9, altitude: 1, horizontalAccuracy: 5, verticalAccuracy: 5),
            locationFixQuality: .precise, gpsAvailable: true
        )
        try await store.appendImmutableReadings([sent])
        try await store.appendImmutableReadings([sent])   // 같은 기록 재전송: 거부하면 안 된다.
        var changed = sent
        changed.speedMetersPerSecond = 12
        do {
            try await store.appendImmutableReadings([changed])
            XCTFail("같은 id에 다른 내용은 거부해야 한다")
        } catch let error as TaptionStoreV2Error {
            XCTAssertEqual(error, .readingConflict(sent.id.uuidString))
        }
        let count = try await store.readingCount()
        XCTAssertEqual(count, 1)
    }

    func testDeleteAllLeavesNoReadingBytesAndSecureDeleteIsOn() async throws {
        let store = try TaptionStoreV2(url: storeURL, calendar: calendar)
        let marker = "VERY-UNIQUE-SSID-9f3a7c"
        var value = reading(0)
        value.connectedWiFiSSID = marker
        try await store.upsertReadings([value])
        try await store.deleteAll()
        await store.close()
        for suffix in ["", "-wal"] {
            let path = storeURL.path + suffix
            guard let data = FileManager.default.contents(atPath: path) else { continue }
            XCTAssertNil(data.range(of: Data(marker.utf8)), "삭제 뒤 \(path)에 값이 남아 있다")
        }
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(storeURL.path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM readings", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 0)
    }

    func testDayUsesTheGregorianCalendarEvenWhenTheUserCalendarIsBuddhist() async throws {
        let store = try TaptionStoreV2(url: storeURL)   // 기본 달력: 그레고리력 현지 날짜
        try await store.upsertReadings([reading(0)])
        let ranges = try await store.dayRanges()
        XCTAssertEqual(ranges.count, 1)
        let parts = TaptionStoreV2.localGregorianCalendar().dateComponents([.year], from: base)
        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(
            TaptionReadingRowCodec.dayNumber(for: base, calendar: Calendar(identifier: .buddhist)) / 10_000,
            2569, "불교력이면 연도가 달라진다는 전제(기본 달력은 이 값을 쓰지 않는다)"
        )
    }

    func testRecordsKeepOriginAndSkipDeletedAndFilterByKindAndRange() async throws {
        let store = try TaptionStoreV2(url: storeURL, calendar: calendar)
        func record(_ id: String, kind: String, offset: TimeInterval, origin: TaptionStoreRecord.Origin,
                    deleted: Bool = false) -> TaptionStoreRecord {
            TaptionStoreRecord(
                id: id, kind: kind, start: base.addingTimeInterval(offset),
                end: base.addingTimeInterval(offset + 600), updatedAt: base, origin: origin,
                isDeleted: deleted, body: #"{"title":"\#(id)"}"#
            )
        }
        try await store.upsertRecords([
            record("a", kind: "plan", offset: 0, origin: .user),
            record("b", kind: "plan", offset: 3_600, origin: .auto),
            record("c", kind: "plan", offset: 7_200, origin: .user, deleted: true),
            record("d", kind: "memo", offset: 0, origin: .imported),
        ])
        let plans = try await store.records(kind: "plan")
        XCTAssertEqual(plans.map(\.id), ["a", "b"])
        XCTAssertEqual(plans.map(\.origin), [.user, .auto])
        XCTAssertEqual(plans.first?.body, #"{"title":"a"}"#)
        let later = try await store.records(kind: "plan", from: base.addingTimeInterval(1_800))
        XCTAssertEqual(later.map(\.id), ["b"])
        let memoCount = try await store.recordCount(kind: "memo")
        let totalCount = try await store.recordCount()
        XCTAssertEqual(memoCount, 1)
        XCTAssertEqual(totalCount, 4)
    }

    func testReopenKeepsDataAndNewerSchemaIsRefusedAndDeleteAllClears() async throws {
        do {
            let store = try TaptionStoreV2(url: storeURL, calendar: calendar)
            try await store.upsertReadings([reading(0)])
            try await store.setMeta("device", "iPhone 11 Pro")
            await store.close()
        }
        let reopened = try TaptionStoreV2(url: storeURL, calendar: calendar)
        let reopenedCount = try await reopened.readingCount()
        let device = try await reopened.meta("device")
        let version = try await reopened.meta("schema_version")
        XCTAssertEqual(reopenedCount, 1)
        XCTAssertEqual(device, "iPhone 11 Pro")
        XCTAssertEqual(version, String(TaptionStoreV2.schemaVersion))
        try await reopened.deleteAll()
        let clearedCount = try await reopened.readingCount()
        XCTAssertEqual(clearedCount, 0)
        await reopened.close()

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(storeURL.path, &database, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        sqlite3_exec(database, "PRAGMA user_version = 99", nil, nil, nil)
        sqlite3_close(database)
        XCTAssertThrowsError(try TaptionStoreV2(url: storeURL, calendar: calendar)) { error in
            XCTAssertEqual(error as? TaptionStoreV2Error, .unsupportedSchema(99))
        }
    }
}

final class TaptionStoreRepositoryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("repo-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() throws -> TaptionStoreV2 {
        try TaptionStoreV2(url: directory.appendingPathComponent("taption.sqlite"))
    }

    private func plan(_ title: String, at seconds: TimeInterval) -> PlanRecord {
        let start = Date(timeIntervalSince1970: 1_792_300_000 + seconds)
        return PlanRecord(title: title, span: TimeSpan(start: start, end: start.addingTimeInterval(1_800)),
                          categoryID: "activity")
    }

    func testEmptyStoreLoadsAnEmptySnapshot() async throws {
        let repository = TaptionStoreRepository(store: try makeStore())
        let snapshot = try await repository.load()
        XCTAssertEqual(snapshot.updatedAt, .distantPast)
        XCTAssertTrue(snapshot.plans.isEmpty)
    }

    func testSnapshotRoundTripKeepsItemsOrderAndSettingsAcrossInstances() async throws {
        let store = try makeStore()
        var snapshot = TaptionDataSnapshot.empty
        snapshot.updatedAt = Date(timeIntervalSince1970: 1_792_300_100)
        snapshot.plans = [plan("둘째", at: 3_600), plan("첫째", at: 0), plan("셋째", at: 7_200)]
        snapshot.memos = [ActionMemo(kind: .nextAction, text: "메모",
                                     createdAt: Date(timeIntervalSince1970: 1_792_300_000),
                                     updatedAt: Date(timeIntervalSince1970: 1_792_300_000))]
        snapshot.settings.mapDisplayStyle = .hybrid
        try await TaptionStoreRepository(store: store).save(snapshot)

        let reloaded = try await TaptionStoreRepository(store: store).load()
        XCTAssertEqual(reloaded.plans.map(\.title), ["둘째", "첫째", "셋째"], "처음 저장한 순서를 유지한다")
        XCTAssertEqual(reloaded.plans.map(\.id), snapshot.plans.map(\.id))
        XCTAssertEqual(reloaded.memos.map(\.text), ["메모"])
        XCTAssertEqual(reloaded.settings.mapDisplayStyle, .hybrid)
        XCTAssertEqual(reloaded.updatedAt, snapshot.updatedAt)
    }

    func testSaveWritesOnlyChangedRowsAndRemovesDeletedOnes() async throws {
        let store = try makeStore()
        let repository = TaptionStoreRepository(store: store)
        var snapshot = TaptionDataSnapshot.empty
        snapshot.updatedAt = Date(timeIntervalSince1970: 1_792_300_100)
        let keep = plan("그대로", at: 0)
        var edit = plan("고칠 것", at: 3_600)
        let remove = plan("지울 것", at: 7_200)
        snapshot.plans = [keep, edit, remove]
        try await repository.save(snapshot)

        edit.title = "고쳤다"
        snapshot.updatedAt = Date(timeIntervalSince1970: 1_792_300_200)
        snapshot.plans = [keep, edit]
        try await repository.save(snapshot)

        let rows = try await store.records(kind: "plan")
        XCTAssertEqual(rows.count, 2)
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        XCTAssertEqual(byID["\(keep.id)"]?.updatedAt, Date(timeIntervalSince1970: 1_792_300_100),
                       "바뀌지 않은 행은 다시 쓰지 않는다")
        XCTAssertEqual(byID["\(edit.id)"]?.updatedAt, Date(timeIntervalSince1970: 1_792_300_200))
        XCTAssertNil(byID["\(remove.id)"])
        XCTAssertEqual(byID["\(keep.id)"]?.origin, .user)
        XCTAssertNotNil(byID["\(keep.id)"]?.start, "본문의 span에서 시작 시각을 뽑는다")

        let reloaded = try await TaptionStoreRepository(store: store).load()
        XCTAssertEqual(reloaded.plans.map(\.title), ["그대로", "고쳤다"])
    }

    func testUndecodableHeaderFailsInsteadOfLoadingEmptyAndWipingOnNextSave() async throws {
        let store = try makeStore()
        let repository = TaptionStoreRepository(store: store)
        var snapshot = TaptionDataSnapshot.empty
        snapshot.updatedAt = Date(timeIntervalSince1970: 1_792_300_100)
        snapshot.plans = [plan("지키는 계획", at: 0)]
        try await repository.save(snapshot)
        // 앱 업데이트로 헤더를 해석하지 못하게 된 상황.
        try await store.upsertRecords([TaptionStoreRecord(
            id: "snapshot", kind: "header", start: nil, end: nil,
            updatedAt: Date(timeIntervalSince1970: 1_792_300_100), origin: .user, body: #"{"unexpected":true}"#
        )])

        let fresh = TaptionStoreRepository(store: store)
        do {
            _ = try await fresh.load()
            XCTFail("해석할 수 없는 헤더는 빈 스냅샷이 아니라 실패여야 한다")
        } catch {
            XCTAssertEqual(error as? RepositoryError, .invalidSnapshot)
        }
        let remaining = try await store.records(kind: "plan")
        XCTAssertEqual(remaining.count, 1, "실패해도 저장된 계획은 그대로여야 한다")
    }

    func testConcurrentSavesEndWithTheLastSnapshotInTheStore() async throws {
        let store = try makeStore()
        let repository = TaptionStoreRepository(store: store)
        var base = TaptionDataSnapshot.empty
        base.updatedAt = Date(timeIntervalSince1970: 1_792_300_100)
        var item = plan("원래", at: 0)
        base.plans = [item]
        try await repository.save(base)

        var edited = base
        item.title = "수정"
        edited.plans = [item]
        edited.updatedAt = Date(timeIntervalSince1970: 1_792_300_200)
        // 두 저장이 동시에 들어온다. 어느 쪽이 먼저 도착할지는 정해지지 않으므로 순서를 가정하지 않는다.
        // 직렬화가 맞다면 저장소는 둘 중 하나의 완전한 상태이고, 내부 비교 기준(known)도 저장소와 같다.
        let editedSnapshot = edited
        let baseSnapshot = base
        let first = Task { try await repository.save(editedSnapshot) }
        let second = Task { try await repository.save(baseSnapshot) }
        _ = try await first.value
        _ = try await second.value

        let afterRace = try await TaptionStoreRepository(store: store).load().plans.map(\.title)
        XCTAssertTrue(afterRace == ["원래"] || afterRace == ["수정"], "섞인 상태가 저장되면 안 된다: \(afterRace)")

        // 내부 기준이 어긋났다면 이 저장은 "바뀐 것 없음"으로 건너뛰어 저장소가 그대로 남는다.
        try await repository.save(base)
        let reloaded = try await TaptionStoreRepository(store: store).load()
        XCTAssertEqual(reloaded.plans.map(\.title), ["원래"])
        try await repository.save(edited)
        let reedited = try await TaptionStoreRepository(store: store).load()
        XCTAssertEqual(reedited.plans.map(\.title), ["수정"])
    }

    func testDeleteAllClearsPlanDataButNotSensorReadings() async throws {
        let store = try makeStore()
        let repository = TaptionStoreRepository(store: store)
        var snapshot = TaptionDataSnapshot.empty
        snapshot.updatedAt = Date(timeIntervalSince1970: 1_792_300_100)
        snapshot.plans = [plan("계획", at: 0)]
        try await repository.save(snapshot)
        try await store.upsertReadings([SensorReading(
            timestamp: Date(timeIntervalSince1970: 1_792_300_000),
            point: GeoPoint(latitude: 37, longitude: 126, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5),
            locationFixQuality: .precise, gpsAvailable: true
        )])

        try await repository.deleteAll()
        let cleared = try await repository.load()
        XCTAssertEqual(cleared.updatedAt, .distantPast)
        let readingCount = try await store.readingCount()
        XCTAssertEqual(readingCount, 1)
    }

    func testFutureWeatherForecastSurvivesRoundTrip() async throws {
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let forecast = WeatherContext(
            observedAt: observedAt,
            fetchedAt: observedAt.addingTimeInterval(-60),
            isForecast: true,
            condition: "맑음",
            symbolName: "sun.max.fill",
            temperatureCelsius: 27,
            point: GeoPoint(latitude: 37.5, longitude: 127, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5)
        )
        var value = TaptionDataSnapshot.empty
        value.weather = [forecast]
        let store = try makeStore()
        try await TaptionStoreRepository(store: store).save(value)
        let restored = try await TaptionStoreRepository(store: store).load()

        XCTAssertEqual(restored.weather, [forecast])
        XCTAssertEqual(restored.weather.first?.isForecast, true)
    }

    func testMapStickersSurviveRoundTrip() async throws {
        let occurredAt = Date(timeIntervalSince1970: 1_800_000_000)
        var value = TaptionDataSnapshot.empty
        value.stickers = [
            MapSticker(
                title: "현장 메모",
                memo: "원본 위치",
                placement: .map,
                point: GeoPoint(latitude: 37.5, longitude: 127, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5),
                occurredAt: occurredAt,
                createdAt: occurredAt,
                updatedAt: occurredAt
            ),
        ]
        let store = try makeStore()
        try await TaptionStoreRepository(store: store).save(value)
        let restored = try await TaptionStoreRepository(store: store).load()

        XCTAssertEqual(restored.stickers, value.stickers)
    }

    func testRepositoryCreatedBeforeDeletionCannotRestoreStaleData() async throws {
        let deletionFence = DataDeletionFenceTestFixture()
        defer { deletionFence.restore() }
        let store = try makeStore()
        let stale = TaptionStoreRepository(store: store)
        let deleting = TaptionStoreRepository(store: store)
        var old = TaptionDataSnapshot.empty
        old.updatedAt = Date(timeIntervalSince1970: 1_792_300_100)
        old.plans = [plan("삭제 전 계획", at: 0)]
        try await stale.save(old)

        let generation = TaptionDataDeletionFence.advance()
        TaptionDataDeletionFence.finish(generation: generation)
        try await deleting.deleteAll()
        do {
            try await stale.save(old)
            XCTFail("stale repository restored deleted data")
        } catch {
            XCTAssertEqual(error as? RepositoryError, .staleGeneration)
        }
        let restored = try await deleting.load()
        XCTAssertEqual(restored, .empty)
        try await deleting.save(old)
        let saved = try await deleting.load()
        XCTAssertEqual(saved.plans.map(\.title), ["삭제 전 계획"])
    }

    func testRepositoryRejectsSaveWhileGlobalDeletionFenceIsActive() async throws {
        let deletionFence = DataDeletionFenceTestFixture()
        defer { deletionFence.restore() }
        let repository = TaptionStoreRepository(store: try makeStore())
        let generation = TaptionDataDeletionFence.advance()
        defer { TaptionDataDeletionFence.finish(generation: generation) }

        do {
            try await repository.save(.empty)
            XCTFail("repository wrote while user data deletion was active")
        } catch {
            XCTAssertEqual(error as? RepositoryError, .staleGeneration)
        }

        try await repository.deleteAll()
        TaptionDataDeletionFence.finish(generation: generation)
        var replacement = TaptionDataSnapshot.empty
        replacement.categories = CategoryCatalog.builtIn
        try await repository.save(replacement)
        let saved = try await repository.load()
        XCTAssertEqual(saved.categories, CategoryCatalog.builtIn)
    }
}
