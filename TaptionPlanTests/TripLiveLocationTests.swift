import CoreLocation
import XCTest
@testable import TaptionPlan
import TaptionTripShare

/// 여행 중 동행 위치(LOC1116S01): 보낼지 판단·기본 기간·동의 상태.
final class TripLiveLocationTests: XCTestCase {
    private typealias Policy = TripLiveLocationPolicy
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func fix(_ lat: Double, _ lon: Double, accuracy: Double = 10, after seconds: TimeInterval = 0) -> Policy.Fix {
        .init(latitude: lat, longitude: lon, accuracy: accuracy, at: t0.addingTimeInterval(seconds))
    }

    func testFirstGoodFixIsSentButBadAccuracyIsNot() {
        XCTAssertTrue(Policy.shouldSend(fix(37.5, 127), last: nil, isForeground: true))
        XCTAssertFalse(Policy.shouldSend(fix(37.5, 127, accuracy: 500), last: nil, isForeground: true))
        XCTAssertFalse(Policy.shouldSend(fix(37.5, 127, accuracy: -1), last: nil, isForeground: true))
    }

    func testForegroundNeedsMovementAndGapOrAHeartbeat() {
        let last = fix(37.5000, 127.0)
        XCTAssertFalse(Policy.shouldSend(fix(37.5000, 127.0, after: 20), last: last, isForeground: true), "움직이지 않음")
        XCTAssertFalse(Policy.shouldSend(fix(37.5003, 127.0, after: 5), last: last, isForeground: true), "간격 15초 전")
        XCTAssertTrue(Policy.shouldSend(fix(37.5003, 127.0, after: 20), last: last, isForeground: true), "33m·20초")
        XCTAssertTrue(Policy.shouldSend(fix(37.5000, 127.0, after: 301), last: last, isForeground: true), "멈춰 있어도 5분 심장박동")
    }

    func testBackgroundIsSlowerThanForeground() {
        let last = fix(37.5000, 127.0)
        XCTAssertFalse(Policy.shouldSend(fix(37.5003, 127.0, after: 30), last: last, isForeground: false))
        XCTAssertFalse(Policy.shouldSend(fix(37.5003, 127.0, after: 90), last: last, isForeground: false), "33m는 50m 미만")
        XCTAssertTrue(Policy.shouldSend(fix(37.5010, 127.0, after: 90), last: last, isForeground: false))
        XCTAssertFalse(Policy.shouldSend(fix(37.5000, 127.0, after: 301), last: last, isForeground: false), "뒤에서는 멈춘 채 알리지 않는다")
    }

    func testDefaultWindowIsStartDayMidnightToEndDayEndInTheTripZone() throws {
        let window = try XCTUnwrap(Policy.defaultWindow(startDay: "2031-05-05", endDay: "2031-05-09", timeZoneID: "Asia/Tokyo"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let from = Date(timeIntervalSince1970: Double(window.from) / 1000), until = Date(timeIntervalSince1970: Double(window.until) / 1000)
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day, .hour], from: from), DateComponents(year: 2031, month: 5, day: 5, hour: 0))
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day, .hour], from: until), DateComponents(year: 2031, month: 5, day: 10, hour: 0))
        XCTAssertTrue(window.contains(window.from))
        XCTAssertFalse(window.contains(window.until), "끝 24시(다음 날 0시)는 밖")
        XCTAssertNil(Policy.defaultWindow(startDay: "2031-05-05", endDay: "2031-07-30", timeZoneID: "Asia/Tokyo"), "40일을 넘으면 주인이 직접")
        XCTAssertNil(Policy.defaultWindow(startDay: "2031-05-09", endDay: "2031-05-05", timeZoneID: nil))
        XCTAssertNil(Policy.defaultWindow(startDay: "garbage", endDay: "2031-05-05", timeZoneID: nil))
    }

    func testConsentSendingAndHiding() {
        var consent = TripLiveLocationConsent()
        XCTAssertFalse(consent.isSending(at: t0), "기본은 꺼짐")
        consent.enabled = true
        XCTAssertTrue(consent.isSending(at: t0))
        consent.hiddenUntil = t0.addingTimeInterval(3600)
        XCTAssertFalse(consent.isSending(at: t0))
        XCTAssertTrue(consent.isHidden(at: t0))
        XCTAssertTrue(consent.isSending(at: t0.addingTimeInterval(3601)), "숨김이 끝나면 다시 보낸다")
    }

    @MainActor
    func testServicePersistsConsentPerTripAndDefaultsOff() async throws {
        let suite = UserDefaults(suiteName: "tripLive-\(UUID().uuidString)")!
        let service = TripLiveLocationService(defaults: suite)
        XCTAssertFalse(service.consent("trip-a").enabled)
        // 켜기는 방이 있어야 하므로(공유 여행이 아님) 상태만 저장되고 아무것도 보내지 않는다.
        await service.setEnabled(false, tripID: "trip-a")
        XCTAssertFalse(TripLiveLocationService(defaults: suite).consent("trip-b").enabled)
    }

    /// 서버 없이 연결만 있는 창구(REV1117A01). 끝나면 원래 창구·서비스로 되돌린다.
    @MainActor
    private func withSharedTrip(
        _ tripID: String, _ body: (TripShareStore, TripLiveLocationService, String) async throws -> Void
    ) async throws {
        let originalStore = TripShareStore.shared, originalService = TripLiveLocationService.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TripLiveLocationTests-\(UUID().uuidString)", isDirectory: true)
        let suiteName = "tripLive-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer {
            TripShareStore.shared = originalStore
            TripLiveLocationService.shared = originalService
            try? FileManager.default.removeItem(at: folder)
        }
        let store = TripShareStore(environment: TripShareEnvironment(
            transport: nil, secrets: TripShareMemorySecrets(), sidecar: TripShareSidecar(directory: folder), appKey: { nil }
        ))
        let service = TripLiveLocationService(defaults: suite)
        TripShareStore.shared = store
        TripLiveLocationService.shared = service
        let roomID = ShareIdentifiers.roomID()
        try store.register(
            TripShareLink(roomID: roomID, tripID: tripID, role: .owner, phase: .sharing),
            secrets: ShareRoomSecrets(root: ShareBytes.random(32), linkSecret: ShareIdentifiers.linkSecret(), token: "token-1", ownerKey: "owner-1", member: 1, epoch: 1)
        )
        try await body(store, service, suiteName)
    }

    /// 방을 잊으면(나가기·방 지우기·끝난 방 치우기·같은 여행을 새 방으로 다시 공유) 그 여행의 「켬」도 지운다.
    /// 남겨 두면 새 방의 다른 동행에게 본인이 켜지 않은 위치가 나간다(「본인이 여행마다 켜야」).
    @MainActor
    func testForgettingTheRoomClearsThatTripsLocationConsent() async throws {
        try await withSharedTrip("trip-a") { store, service, suiteName in
            await service.setEnabled(true, tripID: "trip-a")
            XCTAssertTrue(service.consent("trip-a").enabled)
            await store.forget(tripID: "trip-a")
            XCTAssertFalse(service.consent("trip-a").enabled, "옛 방의 켬이 남으면 안 된다")
            XCTAssertFalse(TripLiveLocationService(defaults: UserDefaults(suiteName: suiteName)!).consent("trip-a").enabled, "저장한 값도 지운다")
            try store.register(
                TripShareLink(roomID: ShareIdentifiers.roomID(), tripID: "trip-a", role: .owner, phase: .sharing),
                secrets: ShareRoomSecrets(root: ShareBytes.random(32), linkSecret: ShareIdentifiers.linkSecret(), token: "token-2", ownerKey: "owner-2", member: 1, epoch: 1)
            )
            XCTAssertFalse(service.consent("trip-a").enabled, "새 방에서는 다시 켜야 한다")
        }
    }

    /// 앱을 다시 켜면 저장된 「켬」으로 30초 점검(기간 끝 자동 끔·멈춤 중 5분 알림·「몇 분 전」)이 다시 돈다.
    @MainActor
    func testSavedConsentRestartsThePeriodicCheckWhenTheTripIsWatched() async throws {
        try await withSharedTrip("trip-a") { _, service, suiteName in
            await service.setEnabled(true, tripID: "trip-a")
            let relaunched = TripLiveLocationService(defaults: UserDefaults(suiteName: suiteName)!)
            TripLiveLocationService.shared = relaunched
            XCTAssertTrue(relaunched.consent("trip-a").enabled)
            XCTAssertFalse(relaunched.isTicking)
            await relaunched.watch(tripID: "trip-a")
            XCTAssertTrue(relaunched.isTicking, "저장된 켬이 있으면 점검을 다시 시작한다")
            await relaunched.setEnabled(false, tripID: "trip-a")
            await service.setEnabled(false, tripID: "trip-a")
        }
    }

    func testAgoTextAndFreshnessLevels() {
        XCTAssertEqual(Policy.agoText(minutes: 0, .korean), "방금")
        XCTAssertEqual(Policy.agoText(minutes: 3, .korean), "3분 전")
        XCTAssertEqual(Policy.opacity(.fresh), 1)
        XCTAssertLessThan(Policy.opacity(.lost), Policy.opacity(.dim))
    }
}
