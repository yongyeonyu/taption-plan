import XCTest
import UIKit
import CoreLocation
import StoreKit
import StoreKitTest
import TaptionPlanCore
@testable import TaptionPlan

// PLY1029A07: 재생 경로 다듬기는 앞뒤를 똑같이 봐서 GPS 튐만 누르고 경로에서 뒤처지지 않는다.
@MainActor
final class PlaybackPathSmoothingTests: XCTestCase {
    func testCenteredSmoothingDampsZigzagWithoutLag() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let dayStart = calendar.date(from: DateComponents(year: 2026, month: 10, day: 29))!
        let start = dayStart.addingTimeInterval(9 * 3_600)
        // 동쪽으로 초당 약 10m, 2초마다 표본, 남북으로 ±30m 번갈아 튄다.
        let readings = (0..<120).map { index -> SensorReading in
            let zigzag = index.isMultiple(of: 2) ? 0.00027 : -0.00027
            return SensorReading(
                timestamp: start.addingTimeInterval(Double(index) * 2),
                point: GeoPoint(latitude: 37.5 + zigzag, longitude: 126.9 + Double(index) * 0.000226,
                                altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5),
                speedMetersPerSecond: 10, motion: .automotive, motionConfidence: .high
            )
        }
        let driver = MapHomePlaybackDriver(inputs: .init(
            startMinute: 540, endMinute: 545, movingRanges: [], dayStart: dayStart,
            readings: readings, travel: [], places: [], zoomPlan: MapHomePlaybackZoomPlan(inputs: [])
        ))
        var rawDeviation = 0.0, smoothDeviation = 0.0, lag = 0.0
        for second in stride(from: 30.0, through: 200.0, by: 1.0) {
            let date = start.addingTimeInterval(second)
            let raw = try XCTUnwrap(driver.smoothedPositionForTesting(raw: true, at: date))
            let smooth = try XCTUnwrap(driver.smoothedPosition(at: date))
            rawDeviation += abs(raw.latitude - 37.5)
            smoothDeviation += abs(smooth.latitude - 37.5)
            lag += abs(smooth.longitude - raw.longitude)
        }
        XCTAssertLessThan(smoothDeviation, rawDeviation * 0.5, "남북 튐이 절반 아래로 줄어야 한다")
        XCTAssertLessThan(lag / 171, 0.00002, "동서 방향으로는 뒤처지지 않는다(평균 2m 미만)")
    }
}
