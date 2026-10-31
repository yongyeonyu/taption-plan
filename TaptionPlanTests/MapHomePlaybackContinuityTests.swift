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
}
