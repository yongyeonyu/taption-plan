import XCTest
import UIKit
import CoreLocation
import StoreKit
import StoreKitTest
import TaptionPlanCore
@testable import TaptionPlan

final class MapHomePlaybackContinuityTests: XCTestCase {
    private let dayStart = Date(timeIntervalSince1970: 1_700_000_000)

    private func point(_ latitude: Double, _ longitude: Double) -> GeoPoint {
        GeoPoint(
            latitude: latitude,
            longitude: longitude,
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 10
        )
    }

    private func place(
        _ id: UUID,
        _ point: GeoPoint,
        from start: TimeInterval,
        to end: TimeInterval
    ) -> PlaceStay {
        PlaceStay(
            id: id,
            placeKey: id.uuidString,
            displayName: "place",
            span: TimeSpan(
                start: dayStart.addingTimeInterval(start),
                end: dayStart.addingTimeInterval(end)
            ),
            confidence: .high,
            point: point
        )
    }

    /// 예상 경로 요청도 센서도 없는 미확인 이동에서 화랑이가 사라지지 않는다(대표 지적, UXP1024D20 ①).
    func testGapCoordinateWalksBetweenPlaceEndpoints() {
        let from = UUID()
        let to = UUID()
        let places = [
            place(from, point(37.0, 127.0), from: 0, to: 3_600),
            place(to, point(37.1, 127.2), from: 7_200, to: 10_800),
        ]
        let travel = [
            TravelSegment(
                fromPlaceID: from,
                toPlaceID: to,
                mode: .walking,
                span: TimeSpan(
                    start: dayStart.addingTimeInterval(3_600),
                    end: dayStart.addingTimeInterval(7_200)
                ),
                distanceMeters: 2_000,
                confidence: .low,
                evidence: []
            )
        ]
        let middle = MapHomePlaybackLocation.gapCoordinate(
            at: dayStart.addingTimeInterval(5_400),
            travel: travel,
            places: places
        )
        XCTAssertEqual(middle?.latitude ?? 0, 37.05, accuracy: 0.000_1)
        XCTAssertEqual(middle?.longitude ?? 0, 127.1, accuracy: 0.000_1)

        let start = MapHomePlaybackLocation.gapCoordinate(
            at: dayStart.addingTimeInterval(3_600),
            travel: travel,
            places: places
        )
        XCTAssertEqual(start?.latitude ?? 0, 37.0, accuracy: 0.000_1)

        // 구간 밖에서는 아무것도 지어내지 않는다.
        XCTAssertNil(
            MapHomePlaybackLocation.gapCoordinate(
                at: dayStart.addingTimeInterval(9_000),
                travel: travel,
                places: places
            )
        )
    }

    /// 출발·도착 장소 좌표를 모르면 보간하지 않는다(지어낸 좌표를 만들지 않는다).
    func testGapCoordinateNeedsBothEndpoints() {
        let travel = [
            TravelSegment(
                mode: .walking,
                span: TimeSpan(
                    start: dayStart,
                    end: dayStart.addingTimeInterval(600)
                ),
                distanceMeters: 300,
                confidence: .low,
                evidence: []
            )
        ]
        XCTAssertNil(
            MapHomePlaybackLocation.gapCoordinate(
                at: dayStart.addingTimeInterval(300),
                travel: travel,
                places: []
            )
        )
    }

    /// 재생 프레임이 있으면 그 좌표를 그대로 쓴다(보간이 끼어들지 않는다).
    func testResolveOrGapPrefersSensorResolution() {
        let reading = SensorReading(
            timestamp: dayStart.addingTimeInterval(300),
            point: point(36.5, 126.5),
            motion: .walking,
            motionConfidence: .high
        )
        let resolved = MapHomePlaybackLocation.resolveOrGap(
            at: dayStart.addingTimeInterval(300),
            frame: nil,
            normalizedReadings: [reading],
            travel: [],
            places: []
        )
        XCTAssertEqual(resolved?.coordinate.latitude ?? 0, 36.5, accuracy: 0.000_1)
    }

    /// 슬라이드바를 수면까지 거슬러 가면 집으로 간다. 그날 다른 곳에 머문 기록이 있으면 그 자리다.
    func testRestingLocationGoesHomeDuringSleep() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let home = GeoPoint(latitude: 37.5, longitude: 127, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5)
        let office = GeoPoint(latitude: 37.6, longitude: 127.1, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5)
        let reading = SensorReading(timestamp: base.addingTimeInterval(7_200), point: office, motion: .unknown)
        let sleep = TimeSpan(start: base, end: base.addingTimeInterval(3_600))
        let resolved = try XCTUnwrap(MapHomePlaybackLocation.restingLocation(
            at: base.addingTimeInterval(600), normalizedReadings: [reading], places: [], sleepSpans: [sleep], home: home
        ))
        XCTAssertEqual(resolved.coordinate.latitude, home.latitude)
        // 수면이 아니어도 첫 표본 전에는 첫 표본 자리에 둔다.
        let early = try XCTUnwrap(MapHomePlaybackLocation.restingLocation(
            at: base.addingTimeInterval(5_000), normalizedReadings: [reading], places: [], sleepSpans: [sleep], home: home
        ))
        XCTAssertEqual(early.coordinate.latitude, office.latitude)
        XCTAssertNil(MapHomePlaybackLocation.restingLocation(
            at: base.addingTimeInterval(9_000), normalizedReadings: [reading], places: [], sleepSpans: [sleep], home: home
        ))
    }

    /// 회의가 앞뒤 업무에 합쳐져 사라지면 안 된다.
    func testMeetingStaysSeparateFromSurroundingWork() {
        let calendar = Calendar.autoupdatingCurrent
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        func record(_ title: String, _ behavior: String, _ from: Int, _ to: Int) -> ActualRecord {
            ActualRecord(planID: nil, title: title, categoryID: "work", startedAt: day.addingTimeInterval(Double(from) * 3_600), endedAt: day.addingTimeInterval(Double(to) * 3_600), source: .location, behavior: behavior)
        }
        let segments = MapHomeTimeRailSegmentEngine.segments(
            from: [record("업무", "work", 9, 11), record("회의", "meeting", 11, 12), record("업무", "work", 12, 14)],
            on: day, asOf: day.addingTimeInterval(86_400), calendar: calendar
        )
        XCTAssertEqual(segments.filter { $0.categoryID == "work" }.map(\.title), ["업무", "회의", "업무"])
    }

    func testMemoOverlayQueuesEveryPassedMemoInOrder() {
        let events: [(minute: Double, moment: String)] = [(minute: 10, moment: "a"), (minute: 11, moment: "b"), (minute: 30, moment: "c")]
        XCTAssertEqual(MapHomePlaybackMomentsOverlay.passed(events, from: 5, to: 12), ["a", "b"])
        XCTAssertTrue(MapHomePlaybackMomentsOverlay.passed(events, from: 12, to: 5).isEmpty)
    }
}
