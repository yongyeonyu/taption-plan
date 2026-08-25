import Foundation
import Testing
import TaptionRouteEngine
@testable import TaptionPlan

struct TaptionRouteEngineAdapterTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    private func reading(
        _ seconds: TimeInterval,
        latitude: Double,
        motion: MotionKind = .walking,
        accuracy: Double = 5,
        sequence: Int? = nil
    ) -> SensorReading {
        SensorReading(
            timestamp: base.addingTimeInterval(seconds),
            point: GeoPoint(latitude: latitude, longitude: 126, altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: -1),
            motion: motion,
            sequence: sequence
        )
    }

    @Test func convertsReadingsAndSelectsCoordinateByMinute() {
        let values = [reading(0, latitude: 37), reading(60, latitude: 37.001)]
        let snapshot = TaptionRouteEngineAdapter.displaySnapshot(
            readings: values,
            selectedDate: base.addingTimeInterval(30)
        )
        #expect(snapshot.log.normalizedSamples.count == 2)
        #expect(abs((snapshot.selectedCoordinate?.latitude ?? 0) - 37.0005) < 0.000_01)
    }

    @Test func exposesMovementRangesAndQuarterRatePlayback() {
        let values = [
            reading(0, latitude: 37),
            reading(60, latitude: 37.001),
            reading(20 * 60, latitude: 37.002)
        ]
        let ranges = TaptionRouteEngineAdapter.movingMinuteRanges(from: values)
        #expect(ranges.count == 2)
        let playback = TaptionRouteEngineAdapter.playbackInput(
            at: base.addingTimeInterval(60), readings: values
        )
        #expect(playback.rateMetersPerSecond == 0)
    }

    @Test func carZeroDistanceDoesNotCreateDottedRoute() {
        let values = [
            reading(0, latitude: 37, motion: .automotive),
            reading(60, latitude: 37, motion: .automotive)
        ]
        let segment = TravelSegment(
            mode: .car,
            span: TimeSpan(start: base, end: base.addingTimeInterval(60)),
            distanceMeters: 0,
            confidence: .high,
            evidence: ["automotive"]
        )
        #expect(!TaptionRouteEngineAdapter.allowsDottedRoute(for: segment, readings: values))
    }
}
