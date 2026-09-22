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

    @Test func boundarySamplesAttachToNearestSegmentAndEarlierWinsTies() {
        let values = [
            sample(0, 37),
            sample(2, 37.0001),
            sample(51, 37.0005, accuracy: 500),
            sample(100, 37.001),
            sample(102, 37.0011),
        ]
        let result = RouteLoggerRouteFilter(
            configuration: .init(segmentGap: 10)
        ).filter(values)

        #expect(result.segments.count == 2)
        #expect(result.segments[0].boundarySamples.map(\.id) == [values[2].id])
        #expect(result.segments[1].boundarySamples.isEmpty)
    }

    @Test func fifteenMinuteGapStartsNewSegment() {
        let result = RouteLoggerRouteFilter().filter([sample(0, 37), sample(901, 37.001)])
        #expect(result.segments.count == 2)
        #expect(result.segments.last?.isNewSegment == true)
    }

    @Test func sparseConnectionBreaksOnlyPastBothThresholds() {
        #expect(!RouteSparseConnectionPolicy.breaksConnection(
            gapDuration: 5 * 60,
            distanceMeters: 1_001
        ))
        #expect(!RouteSparseConnectionPolicy.breaksConnection(
            gapDuration: 5 * 60 + 1,
            distanceMeters: 1_000
        ))
        #expect(RouteSparseConnectionPolicy.breaksConnection(
            gapDuration: 5 * 60 + 1,
            distanceMeters: 1_001
        ))
        #expect(!RouteSparseConnectionPolicy.breaksConnection(
            gapDuration: 5 * 60 + 1,
            distanceMeters: nil
        ))
    }

    @Test func indexInterpolatesInTime() {
        let index = RouteTimeCoordinateIndex(samples: [sample(0, 37), sample(10, 37.001)])
        #expect(abs((index.sample(at: base.addingTimeInterval(5))?.coordinate.latitude ?? 0) - 37.0005) < 0.000001)
    }

    @Test func indexInterpolatesAcrossDatelineUsingShortestLongitude() {
        let index = RouteTimeCoordinateIndex(samples: [
            RouteSample(
                timestamp: base,
                coordinate: .init(latitude: 10, longitude: 179.9),
                horizontalAccuracyMeters: 5
            ),
            RouteSample(
                timestamp: base.addingTimeInterval(10),
                coordinate: .init(latitude: 10, longitude: -179.9),
                horizontalAccuracyMeters: 5
            ),
        ])

        let midpoint = index.sample(at: base.addingTimeInterval(5))?.coordinate.longitude
        #expect(abs(abs(midpoint ?? 0) - 180) < 0.001)
    }

    @Test func routeFilterKeepsDatelineAdjacentSamplesInOnePath() {
        let values = [
            RouteSample(
                timestamp: base,
                coordinate: .init(latitude: 10, longitude: 179.999),
                horizontalAccuracyMeters: 5,
                mode: .walking
            ),
            RouteSample(
                timestamp: base.addingTimeInterval(60),
                coordinate: .init(latitude: 10, longitude: -179.999),
                horizontalAccuracyMeters: 5,
                mode: .walking
            ),
        ]

        let log = RouteLoggerRouteFilter().filter(values)
        #expect(log.segments.count == 1)
        #expect(log.segments.first?.pathSamples.count == 2)
    }

    @Test func indexAndFilterRejectNonFiniteTimestampsBeforeSorting() {
        let invalid = RouteSample(
            timestamp: Date(timeIntervalSince1970: .nan),
            coordinate: .init(latitude: 37, longitude: 126),
            horizontalAccuracyMeters: 5
        )
        let outOfRange = RouteSample(
            timestamp: Date(timeIntervalSinceReferenceDate: 1e100),
            coordinate: .init(latitude: 37, longitude: 126),
            horizontalAccuracyMeters: 5
        )
        let valid = [sample(0, 37), sample(10, 37.001)]
        let index = RouteTimeCoordinateIndex(samples: [invalid, outOfRange] + valid)
        #expect(index.sample(at: Date(timeIntervalSince1970: .nan)) == nil)
        let interpolated = index.sample(at: base.addingTimeInterval(5))
        #expect(abs((interpolated?.coordinate.latitude ?? 0) - 37.0005) < 0.000001)

        let result = RouteLoggerRouteFilter().filterWithReport([valid[1], invalid, outOfRange, valid[0]])
        #expect(result.log.normalizedSamples.map(\.id) == valid.map(\.id))
        #expect(!result.decisions.contains { $0.id == invalid.id })
        #expect(!result.decisions.contains { $0.id == outOfRange.id })
        #expect(RouteLoggerRouteFilter.normalizeDuplicates([invalid, outOfRange] + valid).map(\.id) == valid.map(\.id))
    }

    @Test func indexDoesNotInterpolateAcrossRouteSegments() {
        let index = RouteTimeCoordinateIndex(segments: [
            [sample(0, 37), sample(10, 37.001)],
            [sample(100, 37.01), sample(110, 37.011)],
        ])

        #expect(index.sample(at: base.addingTimeInterval(5)) != nil)
        #expect(index.sample(at: base.addingTimeInterval(50)) == nil)
        #expect(index.sample(at: base.addingTimeInterval(105)) != nil)
    }

    @Test func indexOrdersUnsortedRouteSegments() {
        let index = RouteTimeCoordinateIndex(segments: [
            [sample(100, 37.01), sample(110, 37.011)],
            [sample(0, 37), sample(10, 37.001)],
        ])

        #expect(abs((index.sample(at: base.addingTimeInterval(5))?.coordinate.latitude ?? 0) - 37.0005) < 0.000001)
        #expect(index.sample(at: base.addingTimeInterval(50)) == nil)
        #expect(abs((index.sample(at: base.addingTimeInterval(105))?.coordinate.latitude ?? 0) - 37.0105) < 0.000001)
    }

    @Test func indexClampsUsingLatestSegmentEndWhenRangesOverlap() {
        let index = RouteTimeCoordinateIndex(segments: [
            [sample(0, 37), sample(100, 37.01)],
            [sample(50, 38), sample(60, 38.01)],
        ])

        #expect(abs((index.sample(at: base.addingTimeInterval(80))?.coordinate.latitude ?? 0) - 37.008) < 0.000001)
        #expect(abs((index.sample(at: base.addingTimeInterval(110))?.coordinate.latitude ?? 0) - 37.01) < 0.000001)
    }

    @Test func indexKeepsFirstMatchingSegmentWhenRangesOverlap() {
        let index = RouteTimeCoordinateIndex(segments: [
            [sample(0, 37), sample(100, 37.01)],
            [sample(50, 38), sample(60, 38.01)],
        ])

        #expect(abs((index.sample(at: base.addingTimeInterval(55))?.coordinate.latitude ?? 0) - 37.0055) < 0.000001)
    }

    @Test func indexChoosesSameSegmentWhenEqualStartInputsAreReversed() {
        let first = [
            RouteSample(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                timestamp: base,
                coordinate: .init(latitude: 37, longitude: 126)
            ),
            RouteSample(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                timestamp: base.addingTimeInterval(10),
                coordinate: .init(latitude: 37.001, longitude: 126)
            ),
        ]
        let second = [
            RouteSample(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                timestamp: base,
                coordinate: .init(latitude: 38, longitude: 126)
            ),
            RouteSample(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
                timestamp: base.addingTimeInterval(10),
                coordinate: .init(latitude: 38.001, longitude: 126)
            ),
        ]

        let date = base.addingTimeInterval(5)
        let forward = RouteTimeCoordinateIndex(segments: [first, second]).sample(at: date)
        let reversed = RouteTimeCoordinateIndex(segments: [second, first]).sample(at: date)

        #expect(abs((forward?.coordinate.latitude ?? 0) - 37.0005) < 0.000001)
        #expect(reversed?.coordinate == forward?.coordinate)
    }

    @Test func simplifierRetainsTurnsAndCapsAt4096() {
        var points: [RouteCoordinate] = []
        for i in 0..<10_000 { points.append(.init(latitude: 37 + Double(i) * 0.000001, longitude: 126 + (i % 2 == 0 ? 0 : 0.00001))) }
        var cancellationChecks = 0
        let simplified = RoutePathSimplifier.simplify(
            points,
            toleranceMeters: 0.1,
            cancellationCheck: { cancellationChecks += 1 }
        )
        #expect(simplified.first == points.first && simplified.last == points.last)
        #expect(simplified.count <= 4_096)
        #expect(cancellationChecks <= 200)
    }

    @Test func simplifierClampsInvalidMaximumCount() {
        let points = [
            RouteCoordinate(latitude: 37, longitude: 126),
            RouteCoordinate(latitude: 37.001, longitude: 126.001),
            RouteCoordinate(latitude: 37.002, longitude: 126),
        ]

        let simplified = RoutePathSimplifier.simplify(
            points,
            toleranceMeters: 0.1,
            maximumCount: 0
        )

        #expect(simplified.count <= 2)
        #expect(simplified.first == points.first)
        #expect(simplified.last == points.last)
    }

    @Test func simplifierCollapsesDenseStraightRouteAfterBoundingCandidates() {
        let points = (0..<10_000).map { index in
            RouteCoordinate(latitude: 37, longitude: 126 + Double(index) * 0.00001)
        }

        let simplified = RoutePathSimplifier.simplify(
            points,
            toleranceMeters: 5,
            maximumCount: 400
        )

        #expect(simplified.count == 2)
        #expect(simplified.first == points.first)
        #expect(simplified.last == points.last)
    }

    @Test func simplifierKeepsSharpDeviationOutsideUniformStrideUnderMaximumCount() {
        let deviationIndex = 1_234
        let points = (0..<10_000).map { index in
            RouteCoordinate(
                latitude: index == deviationIndex ? 0.02 : 0,
                longitude: Double(index) * 0.00001
            )
        }

        let simplified = RoutePathSimplifier.simplify(
            points,
            toleranceMeters: 1,
            maximumCount: 8
        )

        #expect(simplified.count <= 8)
        #expect(simplified.contains(points[deviationIndex]))
    }

    @Test func simplifierPropagatesCancellationDuringBoundedReduction() {
        let points = (0..<10_000).map { index in
            RouteCoordinate(
                latitude: Double(index % 2) * 0.0001,
                longitude: Double(index) * 0.00001
            )
        }
        var checks = 0
        var wasCancelled = false
        do {
            _ = try RoutePathSimplifier.simplify(
                points,
                toleranceMeters: 0.1,
                maximumCount: 100,
                cancellationCheck: {
                    checks += 1
                    if checks == 4 { throw CancellationError() }
                }
            )
        } catch is CancellationError {
            wasCancelled = true
        } catch {
            Issue.record("Unexpected simplifier error: \(error)")
        }
        #expect(wasCancelled)
        #expect(checks == 4)
    }

    @Test func filterPropagatesCancellationDuringDuplicateSorting() {
        let values = (0..<4_096).reversed().map {
            sample(Double($0), 37 + Double($0) * 0.000001)
        }
        var checks = 0
        var wasCancelled = false
        do {
            _ = try RouteLoggerRouteFilter().filterWithReport(
                values,
                cancellationCheck: {
                    checks += 1
                    if checks == 36 { throw CancellationError() }
                }
            )
        } catch is CancellationError {
            wasCancelled = true
        } catch {
            Issue.record("Unexpected route filter error: \(error)")
        }
        #expect(wasCancelled)
        #expect(checks == 36)
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

    @Test func playbackLowerBoundPreservesDuplicateDistanceAndBoundarySemantics() {
        let start = RouteCoordinate(latitude: 0, longitude: 0)
        let middle = RouteCoordinate(latitude: 0.01, longitude: 0)
        let end = RouteCoordinate(latitude: 0.02, longitude: 0)
        let projection = RoutePlaybackProjection(coordinates: [
            start, start, middle, middle, end, end
        ])

        #expect(projection.sample(progress: -1)?.coordinate == start)
        #expect(projection.sample(progress: 0)?.coordinate == start)
        #expect(projection.sample(progress: 0.5)?.coordinate == middle)
        #expect(projection.sample(progress: 1)?.coordinate == end)
        #expect(projection.sample(progress: 2)?.coordinate == end)
    }

    @Test func playbackSamplesLargeCumulativeDistanceIndex() {
        let coordinates = (0...50_000).map { index in
            RouteCoordinate(latitude: -2 + Double(index) * 0.00008, longitude: 0)
        }
        let projection = RoutePlaybackProjection(coordinates: coordinates)

        let midpoint = projection.sample(progress: 0.5)

        #expect(projection.coordinates.count == 50_001)
        #expect(abs(midpoint?.coordinate.latitude ?? .infinity) < 0.000_001)
    }

    @Test func routePlaybackInterpolatesAcrossDatelineByShortestPath() {
        let projection = RoutePlaybackProjection(coordinates: [
            .init(latitude: 10, longitude: 179.9),
            .init(latitude: 10, longitude: -179.9),
        ])

        let midpoint = projection.sample(progress: 0.5)

        #expect(projection.totalDistanceMeters < 30_000)
        #expect(abs(abs(midpoint?.coordinate.longitude ?? 0) - 180) < 0.001)
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

    @Test func gapInferenceBreaksEqualEvidenceTiesDeterministically() {
        let start = RouteCoordinate(latitude: 37, longitude: 127)
        let end = RouteCoordinate(latitude: 37.05, longitude: 127)
        let modes: [RouteTravelMode] = [.cycling, .bus, .cycling, .bus]
        func infer(_ modes: [RouteTravelMode]) -> RouteTravelMode? {
            RouteGapInferenceEngine().infer(.init(
                start: base,
                end: base.addingTimeInterval(600),
                startCoordinate: start,
                endCoordinate: end,
                samples: modes.enumerated().map { index, mode in
                    RouteSample(
                        timestamp: base.addingTimeInterval(TimeInterval(index + 1)),
                        coordinate: start,
                        mode: mode
                    )
                }
            )).mode
        }

        #expect(infer(modes) == .bus)
        #expect(infer(Array(modes.reversed())) == .bus)
    }

    @Test func gapInferenceRejectsImplausiblySlowLongGap() {
        let start = RouteCoordinate(latitude: 37, longitude: 127)
        let end = RouteCoordinate(latitude: 37.00018, longitude: 127)
        let decision = RouteGapInferenceEngine().infer(.init(
            start: base,
            end: base.addingTimeInterval(4 * 60 * 60),
            startCoordinate: start,
            endCoordinate: end,
            explicitMode: .walking
        ))

        #expect(!decision.allowsConnection)
    }

    @Test func gapInferenceKeepsEvidenceBackedTransitWithNearbyEndpoints() {
        let start = RouteCoordinate(latitude: 37, longitude: 127)
        let end = RouteCoordinate(latitude: 37.001, longitude: 127.001)
        let decision = RouteGapInferenceEngine().infer(.init(
            start: base,
            end: base.addingTimeInterval(60 * 60),
            startCoordinate: start,
            endCoordinate: end,
            samples: [
                RouteSample(
                    timestamp: base.addingTimeInterval(30 * 60),
                    coordinate: start,
                    mode: .subway
                ),
            ]
        ))

        #expect(decision.mode == .subway)
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
