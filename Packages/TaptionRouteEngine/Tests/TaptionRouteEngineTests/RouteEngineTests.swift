import Foundation
import Testing
@testable import TaptionRouteEngine

struct RouteEngineTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    private func sample(_ seconds: TimeInterval, _ latitude: Double, accuracy: Double = 5, mode: RouteTravelMode = .walking, sequence: Int64? = nil) -> RouteSample {
        RouteSample(timestamp: base.addingTimeInterval(seconds), coordinate: .init(latitude: latitude, longitude: 126), horizontalAccuracyMeters: accuracy, sequence: sequence, mode: mode)
    }

    @Test func duplicatePrefersPreciseThenSequence() {
        let a = sample(0, 37, accuracy: 100, sequence: 1)
        let b = sample(0, 37.01, accuracy: 5, sequence: 1)
        let c = sample(0, 37.02, accuracy: 5, sequence: 2)
        #expect(RouteLoggerRouteFilter.normalizeDuplicates([a, b, c]).first?.coordinate.latitude == c.coordinate.latitude)
    }

    @Test func stationaryDriftStaysAtAnchor() {
        let values = [sample(0, 37), sample(1, 37.00001), sample(2, 37.00002)]
        let result = RouteLoggerRouteFilter().filter(values)
        #expect(result.segments.first?.pathSamples.map(\.coordinate.latitude).allSatisfy { $0 == 37 } == true)
    }

    @Test func walkingRunningAndCarAcceptReasonableMotion() {
        let walk = RouteLoggerRouteFilter().filter([sample(0, 37), sample(10, 37.0002, mode: .walking)]).segments
        let run = RouteLoggerRouteFilter().filter([sample(0, 37), sample(10, 37.0005, mode: .running)]).segments
        let car = RouteLoggerRouteFilter().filter([sample(0, 37, mode: .automotive), sample(10, 37.005, mode: .automotive)]).segments
        #expect(walk.count == 1 && run.count == 1 && car.count == 1)
    }

    @Test func oneSecondFiveHundredMeterJumpStartsSegment() {
        let result = RouteLoggerRouteFilter().filter([sample(0, 37), sample(1, 37.005, mode: .walking)])
        #expect(result.segments.count == 2)
    }

    @Test func accuracyBoundaryKeepsApproximateOutOfPath() {
        let result = RouteLoggerRouteFilter().filter([sample(0, 37), sample(1, 37.001, accuracy: 500)])
        #expect(result.segments.first?.pathSamples.count == 1)
        #expect(result.segments.first?.boundarySamples.count == 1)
        #expect(result.segments.first?.isLowConfidence == true)
    }

    @Test func segmentBoundaryRetainsFilteredCoordinates() {
        let values = [sample(0, 37), sample(1, 37.0001), sample(902, 37.001)]
        let result = RouteLoggerRouteFilter().filter(values)
        #expect(result.segments.count == 2)
        #expect(result.segments.first?.pathSamples.last?.coordinate.latitude != values[1].coordinate.latitude)
        #expect(result.segments.last?.pathSamples.first?.coordinate.latitude == values[2].coordinate.latitude)
    }

    @Test func fifteenMinuteGapStartsNewSegment() {
        let result = RouteLoggerRouteFilter().filter([sample(0, 37), sample(901, 37.001)])
        #expect(result.segments.count == 2)
        #expect(result.segments.last?.isNewSegment == true)
    }

    @Test func indexInterpolatesInTime() {
        let index = RouteTimeCoordinateIndex(samples: [sample(0, 37), sample(10, 37.001)])
        #expect(abs((index.sample(at: base.addingTimeInterval(5))?.coordinate.latitude ?? 0) - 37.0005) < 0.000001)
    }

    @Test func simplifierRetainsTurnsAndCapsAt4096() {
        var points: [RouteCoordinate] = []
        for i in 0..<10_000 { points.append(.init(latitude: 37 + Double(i) * 0.000001, longitude: 126 + (i % 2 == 0 ? 0 : 0.00001))) }
        let simplified = RoutePathSimplifier.simplify(points, toleranceMeters: 0.1)
        #expect(simplified.first == points.first && simplified.last == points.last)
        #expect(simplified.count <= 4_096)
    }

    @Test func subwayEvidenceWinsAndFalseZeroDistanceIsRejected() {
        let subway = SubwayRouteEvidence(lineName: "9호선", stationNames: ["가정", "검암", "마곡나루"], coordinates: [.init(latitude: 37, longitude: 126), .init(latitude: 37.5, longitude: 126.5)])
        #expect(RouteEvidenceGate.allowsDottedRoute(.init(subway: subway)))
        #expect(SubwayRoutePrecedence.resolve(gps: [sample(0, 37)], evidence: subway).count == 2)
        #expect(!RouteEvidenceGate.allowsDottedRoute(.init(motionDetected: true, cellularContinuity: true, observedDistanceMeters: 0)))
    }

    @Test func playbackMovingIsQuarterAndStationaryIsCurrent() {
        #expect(RoutePlaybackPolicy.rate(currentSpeedMetersPerSecond: 8, movementDetected: false) == 8)
        #expect(RoutePlaybackPolicy.rate(currentSpeedMetersPerSecond: 8, movementDetected: true) == 2)
        #expect(RoutePlaybackPolicy.duration(distanceMeters: 100, currentSpeedMetersPerSecond: 8, movementDetected: true) == 50)
    }
}
