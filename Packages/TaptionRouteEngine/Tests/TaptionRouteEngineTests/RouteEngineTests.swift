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

    @Test func oneSecondFiveHundredMeterJumpIsRejectedWithoutMutatingRawInput() {
        let values = [sample(0, 37), sample(1, 37.005, mode: .walking)]
        let result = RouteLoggerRouteFilter().filterWithReport(values)
        #expect(result.log.segments.count == 1)
        #expect(result.log.segments.first?.pathSamples.map(\.id) == [values[0].id])
        #expect(result.decisions.contains { $0.id == values[1].id && $0.reason == .impossibleSpeed })
        #expect(values[1].coordinate.latitude == 37.005)
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

    @Test func cumulativeDistancePlaybackUsesSameCoordinateForMarkerAndRoute() {
        let projection = RoutePlaybackProjection(coordinates: [
            .init(latitude: 37, longitude: 126),
            .init(latitude: 37, longitude: 126.01),
            .init(latitude: 37.01, longitude: 126.01)
        ])
        let firstLeg = projection.sample(progress: 0.25)
        let secondLeg = projection.sample(progress: 0.75)

        #expect(firstLeg?.coordinate.latitude == 37)
        #expect(firstLeg?.coordinate.longitude ?? 0 > 126)
        #expect(secondLeg?.coordinate.longitude == 126.01)
        #expect(secondLeg?.coordinate.latitude ?? 0 > 37)
        #expect(firstLeg?.distanceMeters ?? 0 < secondLeg?.distanceMeters ?? 0)
    }

    @Test func lookAheadQuantizesToEightDirectionsAndFrameIndexIsDeterministic() {
        let projection = RoutePlaybackProjection(coordinates: [
            .init(latitude: 37, longitude: 126),
            .init(latitude: 37.01, longitude: 126)
        ])
        let first = projection.sample(progress: 0.5)
        let same = projection.sample(progress: 0.5)
        let end = projection.sample(progress: 1)

        #expect(first?.direction == .north)
        #expect(first == same)
        #expect(first?.frameIndex == 12)
        #expect(end?.frameIndex == 23)
    }

    @Test func invalidCoordinatesAreExcludedFromImmutableProjection() {
        let projection = RoutePlaybackProjection(coordinates: [
            .init(latitude: .nan, longitude: 126),
            .init(latitude: 37, longitude: 126)
        ])

        #expect(projection.coordinates.count == 1)
        #expect(projection.totalDistanceMeters == 0)
        #expect(projection.sample(progress: 0.5)?.coordinate.latitude == 37)
    }

    @Test func approximateSamplesAreOnlyLowConfidenceRunBoundaries() {
        let values = (0..<3).map { index in
            RouteSample(
                timestamp: base.addingTimeInterval(TimeInterval(index)),
                coordinate: .init(latitude: 37 + Double(index) * 0.0001, longitude: 126),
                horizontalAccuracyMeters: 500,
                isApproximate: true
            )
        }
        let result = RouteLoggerRouteFilter().filterWithReport(values)
        #expect(result.log.segments.first?.pathSamples.isEmpty == true)
        #expect(result.log.segments.first?.boundarySamples.map(\.id) == [values[0].id, values[2].id])
        #expect(result.decisions.contains { $0.id == values[1].id && $0.reason == .lowConfidenceSuppressed })
    }

    @Test func gapInferenceUsesSubwayEvidenceAndRejectsUnboundedGap() {
        let start = RouteCoordinate(latitude: 37.52, longitude: 126.67)
        let end = RouteCoordinate(latitude: 37.56, longitude: 126.83)
        let subwaySample = RouteSample(
            timestamp: base.addingTimeInterval(600),
            coordinate: start,
            horizontalAccuracyMeters: 20,
            mode: .subway
        )
        let engine = RouteGapInferenceEngine()
        let inferred = engine.infer(.init(
            start: base,
            end: base.addingTimeInterval(1_800),
            startCoordinate: start,
            endCoordinate: end,
            samples: [subwaySample]
        ))
        #expect(inferred.mode == .subway)
        #expect(inferred.provenance == "filtered-sensor-mode")

        let rejected = engine.infer(.init(
            start: base,
            end: base.addingTimeInterval(5 * 60 * 60),
            startCoordinate: start,
            endCoordinate: end,
            precedingMode: .automotive,
            followingMode: .automotive
        ))
        #expect(!rejected.allowsConnection)
    }

    @Test func extendedTransportModesHaveDistinctSpeedsAndExpectedRouteProvenance() {
        #expect(RouteTravelMode.bus.maximumSpeedMetersPerSecond < RouteTravelMode.train.maximumSpeedMetersPerSecond)
        #expect(RouteTravelMode.airplane.maximumSpeedMetersPerSecond > RouteTravelMode.train.maximumSpeedMetersPerSecond)
        #expect(RouteTravelMode.privateVehicle.maximumSpeedMetersPerSecond == RouteTravelMode.automotive.maximumSpeedMetersPerSecond)

        let expected = ExpectedRoute(
            span: DateInterval(start: base, duration: 3_600),
            mode: .airplane,
            coordinates: [.init(latitude: 37, longitude: 126), .init(latitude: 35, longitude: 129)],
            source: .airportDirect,
            confidence: 0.8,
            provenance: ["airport-to-airport-direct"]
        )

        #expect(expected.isHighConfidence)
        #expect(expected.source == .airportDirect)
        #expect(expected.provenance == ["airport-to-airport-direct"])
    }
}
