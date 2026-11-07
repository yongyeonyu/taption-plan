import CoreLocation
import HealthKit
import UserNotifications
import XCTest
@testable import TaptionPlan

/// GPS1105A01: 움직이는 동안 머문 자리 영역을 위치마다 다시 걸지 않는다.
final class StayRegionArmingPolicyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func fix(
        north meters: Double,
        at seconds: TimeInterval,
        speed: Double = 0,
        accuracy: Double = 10
    ) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37.5 + meters / 111_000, longitude: 127.0),
            altitude: 0,
            horizontalAccuracy: accuracy,
            verticalAccuracy: -1,
            course: -1,
            courseAccuracy: -1,
            speed: speed,
            speedAccuracy: speed >= 0 ? 0.5 : -1,
            timestamp: start.addingTimeInterval(seconds)
        )
    }

    func testMovingFixesNeverArm() {
        var policy = StayRegionArmingPolicy()
        // 40분 동안 1.4m/s로 걷는다. 영역 반경 안에서 시간이 흘러도 속도가 움직임이면 걸지 않는다.
        var armed = 0
        for step in 0..<240 {
            let t = TimeInterval(step * 10)
            if policy.observe(fix(north: Double(step) * 14, at: t, speed: 1.4), motionIsStationary: false) != nil {
                armed += 1
            }
        }
        XCTAssertEqual(armed, 0)
    }

    func testSlowDriftWithoutSpeedStillNeedsTheSameSpot() {
        var policy = StayRegionArmingPolicy()
        // 속도를 모르는 위치가 매번 반경(30m) 밖으로 옮겨 가면 머문 것이 아니다.
        for step in 0..<20 {
            XCTAssertNil(policy.observe(fix(north: Double(step) * 40, at: TimeInterval(step * 60), speed: -1), motionIsStationary: false))
        }
    }

    func testDwellOfTwoMinutesArmsAtTheAnchor() {
        var policy = StayRegionArmingPolicy()
        XCTAssertNil(policy.observe(fix(north: 0, at: 0), motionIsStationary: false))
        XCTAssertNil(policy.observe(fix(north: 8, at: 60), motionIsStationary: false))
        XCTAssertNil(policy.observe(fix(north: 5, at: 119), motionIsStationary: false))
        let center = policy.observe(fix(north: 12, at: 120), motionIsStationary: false)
        XCTAssertEqual(center?.timestamp, start, "영역 중심은 머물기 시작한 기준점이다")
    }

    func testStationaryMotionArmsWithoutWaiting() {
        var policy = StayRegionArmingPolicy()
        XCTAssertNotNil(policy.observe(fix(north: 0, at: 0), motionIsStationary: true))
    }

    func testStationaryMotionDoesNotOverrideAMovingSpeed() {
        var policy = StayRegionArmingPolicy()
        XCTAssertNil(policy.observe(fix(north: 0, at: 0, speed: 0.6), motionIsStationary: true))
        XCTAssertNil(policy.observe(fix(north: 1, at: 300, speed: 3), motionIsStationary: true))
    }

    func testLeavingTheSpotRestartsTheDwell() {
        var policy = StayRegionArmingPolicy()
        _ = policy.observe(fix(north: 0, at: 0), motionIsStationary: false)
        XCTAssertNotNil(policy.observe(fix(north: 5, at: 180), motionIsStationary: false))
        XCTAssertNil(policy.observe(fix(north: 200, at: 240), motionIsStationary: false), "새 자리에서는 다시 2분을 센다")
        XCTAssertNil(policy.observe(fix(north: 205, at: 300), motionIsStationary: false))
        XCTAssertEqual(policy.observe(fix(north: 203, at: 360), motionIsStationary: false)?.timestamp, start.addingTimeInterval(240))
    }

    func testSpeedBelowThresholdCountsAsStill() {
        XCTAssertFalse(StayRegionArmingPolicy.isMoving(fix(north: 0, at: 0, speed: 0.4)))
        XCTAssertTrue(StayRegionArmingPolicy.isMoving(fix(north: 0, at: 0, speed: 0.5)))
        XCTAssertFalse(StayRegionArmingPolicy.isMoving(fix(north: 0, at: 0, speed: -1)))
    }

    @MainActor
    func testCollectorRemembersOnlyASystemPause() {
        let collector = AppleSensorCollector()
        let manager = CLLocationManager()
        XCTAssertFalse(collector.locationUpdatesPausedBySystem)
        collector.locationManagerDidPauseLocationUpdates(manager)
        XCTAssertTrue(collector.locationUpdatesPausedBySystem)
        collector.locationManagerDidResumeLocationUpdates(manager)
        XCTAssertFalse(collector.locationUpdatesPausedBySystem)
    }

    func testResumeRestartsUpdatesOnlyWhenPausedOrOnRegionExit() {
        XCTAssertTrue(LocationPauseRegionPolicy.restartsUpdates(trigger: .region, updatesPausedBySystem: false))
        XCTAssertTrue(LocationPauseRegionPolicy.restartsUpdates(trigger: .region, updatesPausedBySystem: true))
        XCTAssertTrue(LocationPauseRegionPolicy.restartsUpdates(trigger: .wake, updatesPausedBySystem: true))
        XCTAssertFalse(LocationPauseRegionPolicy.restartsUpdates(trigger: .wake, updatesPausedBySystem: false))
    }
}

/// BGR1028A01: 잠긴 기기에서 HealthKit이 거절한 것은 배너로 띄우지 않는다.
final class BackgroundRefreshErrorPolicyTests: XCTestCase {
    func testProtectedHealthDataErrorIsNotShown() {
        let locked = NSError(domain: HKErrorDomain, code: HKError.Code.errorDatabaseInaccessible.rawValue)
        XCTAssertEqual(locked.code, 6)
        XCTAssertTrue(HealthRefreshErrorPolicy.isProtectedDataUnavailable(locked))
        XCTAssertFalse(HealthRefreshErrorPolicy.showsBanner(for: locked, showErrors: true))
        let wrapped = NSError(domain: "Taption", code: 1, userInfo: [NSUnderlyingErrorKey: locked])
        XCTAssertTrue(HealthRefreshErrorPolicy.isProtectedDataUnavailable(wrapped))
    }

    func testOtherHealthErrorsStillFollowShowErrors() {
        let denied = NSError(domain: HKErrorDomain, code: HKError.Code.errorAuthorizationDenied.rawValue)
        XCTAssertFalse(HealthRefreshErrorPolicy.isProtectedDataUnavailable(denied))
        XCTAssertTrue(HealthRefreshErrorPolicy.showsBanner(for: denied, showErrors: true))
        XCTAssertFalse(HealthRefreshErrorPolicy.showsBanner(for: denied, showErrors: false))
        XCTAssertFalse(HealthRefreshErrorPolicy.isProtectedDataUnavailable(NSError(domain: "other", code: 6)))
    }

    func testFinishFieldsExplainTheError() {
        let message = "건강 데이터를 읽지 못했습니다. 권한이 없습니다."
        let fields = BackgroundRefreshUserErrorDiagnostics.fields(atStart: nil, atEnd: message)
        XCTAssertEqual(fields["user_error"], message)
        XCTAssertEqual(fields["user_error_state"], "new")
        XCTAssertEqual(fields["user_error_category"], "health")
        XCTAssertEqual(
            BackgroundRefreshUserErrorDiagnostics.fields(atStart: nil, atEnd: nil),
            ["user_error": "none", "user_error_state": "none", "user_error_category": "none"]
        )
    }

    func testFinishStateSeparatesCarriedFromNewErrors() {
        typealias D = BackgroundRefreshUserErrorDiagnostics
        XCTAssertEqual(D.state(atStart: "a", atEnd: "a"), "carried")
        XCTAssertEqual(D.state(atStart: "a", atEnd: "b"), "replaced")
        XCTAssertEqual(D.state(atStart: "a", atEnd: nil), "cleared")
        XCTAssertEqual(D.category("Could not sync calendar"), "calendar")
        XCTAssertEqual(D.category("변경 내용을 저장하지 못했습니다."), "storage")
        XCTAssertEqual(D.category("알 수 없는 문제"), "other")
        let long = String(repeating: "가", count: 300)
        XCTAssertEqual(D.fields(atStart: nil, atEnd: long)["user_error"]?.count, D.maximumTextLength)
    }
}

/// ARC1030A03: 하루 카드 알림을 누르면 로그에 남는다.
final class MapHomeAlarmDiagnosticsTests: XCTestCase {
    func testDailyCardTapIsRecordedWithDelay() {
        let delivered = Date(timeIntervalSince1970: 1_800_000_000)
        let record = MapHomeAlarmDiagnostics.tapped(
            kind: MapHomeAlarmKind.dailyCard.rawValue,
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            deliveredAt: delivered,
            now: delivered.addingTimeInterval(95.4)
        )
        XCTAssertEqual(record?.event, "daily_card_tapped")
        XCTAssertEqual(record?.fields["action"], "open")
        XCTAssertEqual(record?.metrics["delivered_to_tap_s"], 95)
    }

    func testOtherAlarmsAreNotRecordedAsDailyCard() {
        XCTAssertNil(MapHomeAlarmDiagnostics.tapped(
            kind: MapHomeAlarmKind.arriveHome.rawValue,
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            deliveredAt: .now,
            now: .now
        ))
        XCTAssertNil(MapHomeAlarmDiagnostics.presented(kind: nil))
        XCTAssertEqual(MapHomeAlarmDiagnostics.presented(kind: MapHomeAlarmKind.dailyCard.rawValue)?.event, "daily_card_presented")
        XCTAssertEqual(MapHomeAlarmDiagnostics.action(UNNotificationDismissActionIdentifier), "dismiss")
    }
}
