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

    @Test func confirmedOrCompletelyRecordedRouteDoesNotCreateDottedRoute() {
        let values = [
            reading(0, latitude: 37),
            reading(60, latitude: 37.001)
        ]
        let confirmed = TravelSegment(
            mode: .car,
            span: TimeSpan(start: base, end: base.addingTimeInterval(60)),
            distanceMeters: 100,
            confidence: .high,
            evidence: ["automotive"],
            isConfirmed: true
        )
        let recorded = TravelSegment(
            mode: .car,
            span: TimeSpan(start: base, end: base.addingTimeInterval(60)),
            distanceMeters: 100,
            confidence: .medium,
            evidence: ["automotive"]
        )

        #expect(!TaptionRouteEngineAdapter.allowsDottedRoute(for: confirmed, readings: []))
        #expect(!TaptionRouteEngineAdapter.allowsDottedRoute(for: recorded, readings: values))
    }

    @Test func uncertainRouteWithRecordingGapCanCreateDottedRoute() {
        let values = [
            reading(0, latitude: 37),
            reading(60, latitude: 37.001)
        ]
        let segment = TravelSegment(
            mode: .car,
            span: TimeSpan(start: base, end: base.addingTimeInterval(20 * 60)),
            distanceMeters: 1_000,
            confidence: .medium,
            evidence: ["automotive"]
        )

        #expect(TaptionRouteEngineAdapter.allowsDottedRoute(for: segment, readings: values))
    }

    @Test func continuousFifteenMinuteRouteDoesNotCreateDottedRoute() {
        let values = stride(from: 0, through: 20 * 60, by: 10 * 60).map {
            reading(TimeInterval($0), latitude: 37 + Double($0) / 1_000_000)
        }
        let segment = TravelSegment(
            mode: .car,
            span: TimeSpan(start: base, end: base.addingTimeInterval(20 * 60)),
            distanceMeters: 1_000,
            confidence: .medium,
            evidence: ["자동차"]
        )

        #expect(!TaptionRouteEngineAdapter.allowsDottedRoute(for: segment, readings: values))
    }
}
