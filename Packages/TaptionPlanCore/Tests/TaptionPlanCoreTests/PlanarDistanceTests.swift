import XCTest
@testable import TaptionPlanCore

/// 날짜변경선을 넘는 평면 거리 회귀 시험 (REV1110A04).
final class PlanarDistanceTests: XCTestCase {
    private func point(_ latitude: Double, _ longitude: Double) -> GeoPoint {
        GeoPoint(latitude: latitude, longitude: longitude, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: -1)
    }

    func testMetersUsesShorterLongitudeAcrossAntimeridian() {
        let distance = PlanarDistance.meters(point(0, 179.9999), point(0, -179.9999))
        XCTAssertEqual(distance, 0.0002 * 111_320, accuracy: 0.01)
    }

    func testSegmentMetersUsesShorterLongitudeAcrossAntimeridian() {
        let distance = PlanarDistance.segmentMeters(point(0, 180), point(0.001, 179.999), point(0.001, -179.999))
        XCTAssertEqual(distance, 0.001 * 111_320, accuracy: 0.01)
    }

    func testOrdinaryDistanceIsUnchanged() {
        let distance = PlanarDistance.meters(point(37, 127), point(37, 127.001))
        XCTAssertEqual(distance, 0.001 * 111_320 * cos(37 * .pi / 180), accuracy: 1e-6)
    }
}
