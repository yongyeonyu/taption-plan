import CoreLocation
import XCTest
@testable import TaptionPlan

/// ARN1114A17: 앱이 꺼져 있어도 울릴 도착 위치 알림을 고르는 규칙. 좌표는 꾸민 값이다(위도 0.001도는 약 111m).
final class ArrivalAlertPlanTests: XCTestCase {
    /// 2027-01-15 08:00 UTC. 오늘은 8시간 전에 시작했고 16시간 뒤에 끝난다.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func candidate(_ id: UUID = UUID(), latitude: Double = 0.5, opens: TimeInterval = -600, closes: TimeInterval = 3_600) -> ArrivalCandidate {
        ArrivalCandidate(
            stopID: id, title: "곳", latitude: latitude, longitude: 0.5,
            opensAt: now.addingTimeInterval(opens), closesAt: now.addingTimeInterval(closes), tripID: nil, itemID: nil
        )
    }

    private func select(
        _ candidates: [ArrivalCandidate], near latitude: Double? = nil, shown: Set<UUID> = [], slots: Int = 8
    ) -> [UUID] {
        ArrivalAlertPlan.selection(
            candidates: candidates, near: latitude.map { CLLocationCoordinate2D(latitude: $0, longitude: 0.5) },
            now: now, shown: shown, slots: slots, calendar: calendar
        ).map(\.stopID)
    }

    func testSlotsShareTheRegionBudgetWithOtherRegions() {
        XCTAssertEqual(ArrivalAlertPlan.slots(otherRegions: 11), 8, "근처 메모 10곳과 머무름 영역 1곳이 다 차도 8곳")
        XCTAssertEqual(ArrivalAlertPlan.slots(otherRegions: 0), 10, "덜 쓰면 10곳까지")
        XCTAssertEqual(ArrivalAlertPlan.slots(otherRegions: 9), 10)
        XCTAssertEqual(ArrivalAlertPlan.slots(otherRegions: 17), 2)
        XCTAssertEqual(ArrivalAlertPlan.slots(otherRegions: 30), 0)
    }

    func testRadiusStaysWithinWhatTheDeviceCanMonitor() {
        XCTAssertEqual(ArrivalAlertPlan.radius(maximum: 1_000), ArrivalDetector.radius)
        XCTAssertEqual(ArrivalAlertPlan.radius(maximum: 150), 150)
        XCTAssertEqual(ArrivalAlertPlan.radius(maximum: -1), ArrivalDetector.radius, "상한을 모르면 그대로")
        XCTAssertGreaterThanOrEqual(ArrivalAlertPlan.radius(maximum: 1_000), ArrivalAlertPlan.minimumRadius)
    }

    func testOnlyTodaysUnfinishedUnshownPlacesAreArmed() {
        let open = UUID(), later = UUID(), ended = UUID(), tomorrow = UUID(), seen = UUID(), invalid = UUID()
        let picked = select([
            candidate(open, latitude: 0.50),
            candidate(later, latitude: 0.51, opens: 15 * 3_600, closes: 20 * 3_600),
            candidate(ended, latitude: 0.52, opens: -7_200, closes: 0),
            candidate(tomorrow, latitude: 0.53, opens: 16 * 3_600, closes: 40 * 3_600),
            candidate(seen, latitude: 0.54),
            candidate(invalid, latitude: 95)
        ], shown: [seen])
        XCTAssertEqual(picked, [open, later], "오늘 안에 창이 열리는 일정만, 전날 밤에는 걸지 않는다")
    }

    func testOpenPlacesComeFirstByDistanceThenUpcomingByTime() {
        let near = UUID(), far = UUID(), soon = UUID(), late = UUID()
        let all = [
            candidate(late, latitude: 0.501, opens: 7_200, closes: 9_000),
            candidate(soon, latitude: 0.58, opens: 600, closes: 9_000),
            candidate(far, latitude: 0.56),
            candidate(near, latitude: 0.52, opens: -60)
        ]
        XCTAssertEqual(select(all, near: 0.5), [near, far, soon, late])
        XCTAssertEqual(select(all, near: 0.5, slots: 2), [near, far], "자리가 모자라면 앞선 것만")
        XCTAssertEqual(Array(select(all, near: nil).prefix(2)), [far, near], "위치를 모르면 창이 먼저 열린 순")
        XCTAssertTrue(select(all, slots: 0).isEmpty)
    }

    func testSamePlaceIsArmedOnce() {
        let first = UUID(), sameSpot = UUID(), apart = UUID()
        let picked = select([
            candidate(first, latitude: 0.5, opens: -600),
            candidate(sameSpot, latitude: 0.5004, opens: 3_600, closes: 7_200),
            candidate(apart, latitude: 0.501, opens: 3_600, closes: 7_200)
        ])
        XCTAssertEqual(picked, [first, apart], "약 44m는 같은 곳, 약 111m는 다른 곳")
        XCTAssertEqual(
            select([candidate(first), candidate(sameSpot, latitude: 0.5004, opens: 3_600, closes: 7_200)], shown: [first]),
            [sameSpot], "앞선 일정을 보인 뒤에는 다음 일정을 건다"
        )
    }

    func testDeliveredAlertsJoinTheShownRecord() {
        let rang = UUID(), cleared = UUID(), waiting = UUID(), early = UUID(), gone = UUID()
        let id = ArrivalAlertPlan.identifier(for:)
        let deliveredAt = now.addingTimeInterval(-300)
        let fired = ArrivalAlertPlan.firedStops(
            registered: [id(rang), id(cleared), id(waiting), id(early), id(gone), "nearby-memo-x"],
            pending: [id(waiting)],
            delivered: [id(rang): deliveredAt, id(early): deliveredAt],
            candidates: [
                candidate(rang), candidate(cleared), candidate(waiting),
                candidate(early, opens: 5 * 3_600, closes: 6 * 3_600)
            ],
            now: now
        )
        XCTAssertEqual(fired[rang], deliveredAt, "알림 센터에 남아 있으면 전달 시각")
        XCTAssertEqual(fired[cleared], now, "지워졌으면 확인한 때")
        XCTAssertNil(fired[waiting], "아직 걸려 있다")
        XCTAssertNil(fired[early], "창이 열리기 한참 전에 울린 것은 다시 건다")
        XCTAssertEqual(fired[gone], now, "일정이 없어져도 기록은 남긴다")
        XCTAssertEqual(fired.count, 3)
    }

    func testAlertWithinGraceBeforeWindowCountsAsArrival() {
        let stop = UUID()
        let fired = ArrivalAlertPlan.firedStops(
            registered: [ArrivalAlertPlan.identifier(for: stop)], pending: [], delivered: [:],
            candidates: [candidate(stop, opens: ArrivalAlertPlan.earlyGrace, closes: 9_000)], now: now
        )
        XCTAssertEqual(fired[stop], now)
    }

    @MainActor
    func testManagerRecordsAlertedStopsOnce() {
        let suite = "ArrivalAlertPlanTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let stop = UUID()
        let manager = ArrivalCardManager(defaults: defaults)
        XCTAssertTrue(manager.shownStopIDs(now: now).isEmpty)
        manager.markShown([stop: now.addingTimeInterval(-60)], now: now)
        manager.markShown([stop: now], now: now)
        XCTAssertEqual(ArrivalCardManager(defaults: defaults).shownStopIDs(now: now), [stop])
        XCTAssertTrue(ArrivalCardManager(defaults: defaults).shownStopIDs(now: now.addingTimeInterval(ArrivalDetector.shownRetention)).isEmpty)
    }

    func testAlertContentMatchesTheArrivalNotificationAndHidesTitleWhenLocked() {
        let stop = UUID()
        let shownTitle = ArrivalCardManager.content(for: candidate(stop), hidesTitle: false)
        let hidden = ArrivalCardManager.content(for: candidate(stop), hidesTitle: true)
        XCTAssertEqual(shownTitle.title, "곳")
        XCTAssertNotEqual(hidden.title, "곳")
        XCTAssertFalse(hidden.body.contains("곳"))
        XCTAssertEqual(hidden.userInfo[ArrivalCardManager.userInfoStopID] as? String, stop.uuidString)
    }
}
