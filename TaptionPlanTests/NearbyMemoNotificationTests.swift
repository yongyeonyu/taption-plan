import CoreLocation
import XCTest
@testable import TaptionPlan

final class NearbyMemoNotificationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return value
    }
    private var yesterday: Date { now.addingTimeInterval(-24 * 60 * 60) }

    private func memo(
        text: String = "맛있었다",
        symbol: String? = "food.pasta",
        latitude: Double? = 37.5665,
        longitude: Double = 126.978,
        at: Date? = nil,
        createdAt: Date? = nil
    ) -> ActionMemo {
        let occurred = at ?? yesterday
        var value = ActionMemo(
            occurredAt: occurred,
            mapPoint: latitude.map {
                GeoPoint(latitude: $0, longitude: longitude, altitude: 0, horizontalAccuracy: 0, verticalAccuracy: 0)
            },
            kind: .idea,
            text: text,
            createdAt: createdAt ?? occurred
        )
        value.stickerSymbol = symbol
        return value
    }

    func testOnlyPastLocationMemosWithChosenIconAreEligible() {
        let chosen = memo()
        let places = NearbyMemoPolicy.places(
            from: [
                chosen,
                memo(symbol: StickerCatalog.defaultMemoSymbol),
                memo(symbol: nil),
                memo(latitude: nil),
                memo(at: now)
            ],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(places.map(\.key), [chosen.id])
    }

    func testOldStickerNameCountsAsChosenIcon() {
        let places = NearbyMemoPolicy.places(from: [memo(symbol: "star.fill")], now: now, calendar: calendar)
        XCTAssertEqual(places.count, 1)
    }

    func testCloseMemosBecomeOnePlaceKeepingFirstKeyAndLatestText() {
        let first = memo(text: "처음", at: yesterday.addingTimeInterval(-3600))
        let close = memo(text: "나중", latitude: 37.56655, at: yesterday)
        let far = memo(text: "먼 곳", latitude: 37.58)
        let places = NearbyMemoPolicy.places(from: [close, far, first], now: now, calendar: calendar)
        XCTAssertEqual(places.count, 2)
        let group = places.first { $0.key == first.id }
        XCTAssertEqual(group?.memoCount, 2)
        XCTAssertEqual(group?.latestText, "나중")
        XCTAssertEqual(group.map(NearbyMemoPolicy.body(for:))?.hasPrefix("나중"), true)
        XCTAssertEqual(group.map(NearbyMemoPolicy.body(for:))?.count ?? 0 > 2, true)
    }

    func testSelectionPrefersNearbyAndCapsCount() throws {
        let places = (0..<15).map { index in
            NearbyMemoPlace(
                key: UUID(),
                coordinate: NearbyMemoCoordinate(latitude: 37 + Double(index) * 0.01, longitude: 127),
                latestAt: yesterday.addingTimeInterval(Double(index)),
                latestText: "\(index)",
                memoCount: 1
            )
        }
        let near = NearbyMemoPolicy.selection(
            from: places,
            near: NearbyMemoCoordinate(latitude: 37, longitude: 127),
            lastFired: [:],
            now: now
        )
        XCTAssertEqual(near.count, NearbyMemoPolicy.maximumPlaces)
        XCTAssertEqual(near.first?.latestText, "0")
        let recent = NearbyMemoPolicy.selection(from: places, near: nil, lastFired: [:], now: now)
        XCTAssertEqual(recent.first?.latestText, "14")
    }

    func testRenotifyWaitsOneDay() {
        let place = NearbyMemoPlace(
            key: UUID(),
            coordinate: NearbyMemoCoordinate(latitude: 37, longitude: 127),
            latestAt: yesterday,
            latestText: "a",
            memoCount: 1
        )
        let id = NearbyMemoPolicy.identifier(for: place.key)
        XCTAssertTrue(NearbyMemoPolicy.selection(
            from: [place], near: nil, lastFired: [id: now.addingTimeInterval(-23 * 3600)], now: now
        ).isEmpty)
        XCTAssertEqual(NearbyMemoPolicy.selection(
            from: [place], near: nil, lastFired: [id: now.addingTimeInterval(-24 * 3600)], now: now
        ).count, 1)
    }

    func testFireTimeComesOnlyFromRequestsThatLeftThePendingList() {
        let delivered = now.addingTimeInterval(-600)
        let result = NearbyMemoPolicy.updatedFireTimes(
            previous: ["old": now.addingTimeInterval(-25 * 3600)],
            registered: ["waiting", "shown", "cleared"],
            pending: ["waiting"],
            delivered: ["shown": delivered],
            now: now
        )
        XCTAssertNil(result["waiting"])
        XCTAssertEqual(result["shown"], delivered)
        XCTAssertEqual(result["cleared"], now)
        XCTAssertNil(result["old"], "재알림 간격이 지난 기록은 버린다")
    }

    func testAvailabilityNeverActiveWithoutExistingPermissions() {
        func state(
            enabled: Bool = true,
            notifications: Bool = true,
            location: CLAuthorizationStatus = .authorizedWhenInUse,
            full: Bool = true
        ) -> NearbyMemoAvailability {
            NearbyMemoAvailability.resolve(
                isEnabled: enabled,
                notificationsGranted: notifications,
                locationStatus: location,
                hasFullAccuracy: full
            )
        }
        XCTAssertEqual(state(), .active)
        XCTAssertEqual(state(location: .authorizedAlways), .active)
        XCTAssertEqual(state(enabled: false), .turnedOff)
        XCTAssertEqual(state(notifications: false), .notificationsNotAllowed)
        XCTAssertEqual(state(location: .notDetermined), .locationNotAllowed)
        XCTAssertEqual(state(location: .denied), .locationNotAllowed)
        XCTAssertEqual(state(full: false), .approximateLocation)
    }

    func testPlanRemindersLeaveRoomForNearbyMemos() {
        XCTAssertLessThanOrEqual(
            PlanNotificationPolicy.maximumPendingPlanReminders + NearbyMemoPolicy.maximumPlaces,
            60
        )
    }
}
