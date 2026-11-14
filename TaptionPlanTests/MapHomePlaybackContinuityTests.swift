import XCTest
import UIKit
import CoreLocation
import MapKit
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

/// KMP1114A04: 카카오 지도의 화면 점 ↔ 좌표 변환(아핀 풀이·방위·카메라 거리).
final class MapHomeKakaoProjectionTests: XCTestCase {
    private let size = CGSize(width: 390, height: 800)
    private let center = CLLocationCoordinate2D(latitude: 37.5, longitude: 127)

    func testWorldCoordinateRoundTrips() {
        for coordinate in [center, CLLocationCoordinate2D(latitude: -33.9, longitude: 151.2), CLLocationCoordinate2D(latitude: 0, longitude: -179.5)] {
            let world = MapHomeKakaoProjection.world(coordinate)
            let back = MapHomeKakaoProjection.coordinate(worldX: world.x, worldY: world.y)
            XCTAssertEqual(back.latitude, coordinate.latitude, accuracy: 1e-9)
            XCTAssertEqual(back.longitude, coordinate.longitude, accuracy: 1e-9)
        }
    }

    func testCameraProjectionPutsCenterMidScreenAndNorthUp() {
        let projection = MapHomeKakaoProjection(center: center, cameraDistance: 550, heading: 0, size: size)
        let middle = projection.point(for: center)
        XCTAssertEqual(middle.x, 195, accuracy: 1e-6)
        XCTAssertEqual(middle.y, 400, accuracy: 1e-6)
        let north = projection.point(for: CLLocationCoordinate2D(latitude: 37.501, longitude: 127))
        XCTAssertEqual(north.x, 195, accuracy: 1e-6)
        XCTAssertLessThan(north.y, 400)
        XCTAssertGreaterThan(projection.point(for: CLLocationCoordinate2D(latitude: 37.5, longitude: 127.001)).x, 195)
        XCTAssertEqual(projection.heading, 0, accuracy: 1e-9)
        XCTAssertEqual(projection.cameraDistance, 550, accuracy: 1e-6)
    }

    func testHeadingIsClockwiseLikeTheVectorMap() {
        // 방위 90°: 화면 위쪽이 동쪽이다.
        let projection = MapHomeKakaoProjection(center: center, cameraDistance: 550, heading: 90, size: size)
        let east = projection.point(for: CLLocationCoordinate2D(latitude: 37.5, longitude: 127.001))
        XCTAssertEqual(east.x, 195, accuracy: 1e-6)
        XCTAssertLessThan(east.y, 400)
        // 북쪽은 화면 왼쪽으로 간다.
        XCTAssertLessThan(projection.point(for: CLLocationCoordinate2D(latitude: 37.501, longitude: 127)).x, 195)
        XCTAssertEqual(projection.heading, 90, accuracy: 1e-9)
    }

    func testThreeScreenSamplesRecoverTheSameProjection() throws {
        let truth = MapHomeKakaoProjection(center: center, cameraDistance: 1_800, heading: 217, size: size)
        let screen = MapHomeKakaoProjection.samplePoints(in: size)
        let solved = try XCTUnwrap(MapHomeKakaoProjection(screen: screen, coordinates: screen.map(truth.coordinate(at:)), size: size))
        XCTAssertEqual(solved.heading, 217, accuracy: 1e-6)
        XCTAssertEqual(solved.cameraDistance, 1_800, accuracy: 1e-3)
        XCTAssertFalse(solved.differs(from: truth))
        let marker = CLLocationCoordinate2D(latitude: 37.503, longitude: 126.996)
        XCTAssertEqual(solved.point(for: marker).x, truth.point(for: marker).x, accuracy: 1e-4)
        XCTAssertEqual(solved.point(for: marker).y, truth.point(for: marker).y, accuracy: 1e-4)
        // 화면 점 → 좌표 → 화면 점.
        let back = solved.point(for: solved.coordinate(at: CGPoint(x: 31, y: 702)))
        XCTAssertEqual(back.x, 31, accuracy: 1e-6)
        XCTAssertEqual(back.y, 702, accuracy: 1e-6)
    }

    func testUnusableSamplesGiveNoProjection() {
        let line = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 200, y: 0)]
        XCTAssertNil(MapHomeKakaoProjection(screen: line, coordinates: [center, center, center], size: size))
        // 엔진이 준비되기 전에는 세 점이 같은 좌표로 온다.
        XCTAssertNil(MapHomeKakaoProjection(screen: MapHomeKakaoProjection.samplePoints(in: size), coordinates: [center, center, center], size: size))
        XCTAssertNil(MapHomeKakaoProjection(screen: MapHomeKakaoProjection.samplePoints(in: .zero), coordinates: [center, center, center], size: .zero))
    }

    func testCameraDistanceMatchesTheVisibleSpan() {
        let projection = MapHomeKakaoProjection(center: center, cameraDistance: 550, heading: 0, size: size)
        // 화면 층은 위도 폭으로 1pt의 거리를 구한다. 카메라 거리와 같은 값을 가리켜야 한다.
        let metersPerPoint = projection.span.latitudeDelta * 111_320 / 800
        XCTAssertEqual(metersPerPoint, projection.metersPerPoint, accuracy: projection.metersPerPoint * 0.005)
        XCTAssertEqual(projection.metersPerPoint * 800 * MapHomeKakaoProjection.distancePerVisibleMeter, 550, accuracy: 1e-6)
        XCTAssertEqual(projection.center.latitude, center.latitude, accuracy: 1e-9)
        XCTAssertEqual(projection.center.longitude, center.longitude, accuracy: 1e-9)
    }

    func testRegionFitShowsTheWholeRegion() {
        let region = MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.010))
        let distance = MapHomeKakaoProjection.cameraDistance(fitting: region, size: size)
        let span = MapHomeKakaoProjection(center: center, cameraDistance: distance, heading: 0, size: size).span
        XCTAssertGreaterThanOrEqual(span.latitudeDelta, 0.008 * 0.995)
        XCTAssertGreaterThanOrEqual(span.longitudeDelta, 0.010 * 0.995)
        // 꼭 맞는 쪽은 남기지 않는다.
        XCTAssertLessThan(min(span.latitudeDelta / 0.008, span.longitudeDelta / 0.010), 1.01)
    }

    func testStillMapIsNotReportedAsMoved() {
        let projection = MapHomeKakaoProjection(center: center, cameraDistance: 550, heading: 30, size: size)
        let nudged = MapHomeKakaoProjection(center: CLLocationCoordinate2D(latitude: 37.5 + 1e-10, longitude: 127), cameraDistance: 550, heading: 30, size: size)
        XCTAssertFalse(projection.differs(from: nudged))
        let moved = MapHomeKakaoProjection(center: CLLocationCoordinate2D(latitude: 37.5001, longitude: 127), cameraDistance: 550, heading: 30, size: size)
        XCTAssertTrue(projection.differs(from: moved))
        XCTAssertTrue(projection.differs(from: MapHomeKakaoProjection(center: center, cameraDistance: 550, heading: 31, size: size)))
    }
}
