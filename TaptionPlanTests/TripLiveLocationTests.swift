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

    func testAgoTextAndFreshnessLevels() {
        XCTAssertEqual(Policy.agoText(minutes: 0, .korean), "방금")
        XCTAssertEqual(Policy.agoText(minutes: 3, .korean), "3분 전")
        XCTAssertEqual(Policy.opacity(.fresh), 1)
        XCTAssertLessThan(Policy.opacity(.lost), Policy.opacity(.dim))
    }
}
