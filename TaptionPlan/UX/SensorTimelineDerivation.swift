import Foundation
import TaptionPlanCore

/// 센서 갱신의 순수 계산. 주 스레드 밖에서 돌고 snapshot에 닿지 않는다(RFA1105A02).
enum SensorStayDerivation {
    struct Input: Sendable {
        var detectedPlaces: [PlaceStay]
        var readings: [SensorReading]
        var knownPlaces: [PlaceStay]
        var frequentPlaces: [FrequentPlace]
        var healthMovementEvidence: [AppleMovementEvidence]
        var userTransitLocations: [UserTransitLocation]
        var registeredCarAudioNames: Set<String>
        var motionActivities: [MotionActivityRecord]
        var pedometer: PedometerSummary?
        var previousSubwaySegments: [TravelSegment]
    }

    struct Output: Sendable {
        var basePlaces: [PlaceStay]
        var places: [PlaceStay]
        var floors: [FloorTransition]
        var inferredTravel: [TravelSegment]
    }

    // `nonisolated async`라 주 스레드 밖에서 돈다(`ClassifierAdapter.travelTimelineInBackground`와 같은 방식).
    nonisolated static func detect(readings: [SensorReading], knownPlaces: [PlaceStay]) async -> [PlaceStay] {
        PlaceDetectionEngine().detectStays(readings: readings, knownNames: knownNames(knownPlaces))
    }

    /// 같은 장소 키가 여럿이면 뒤의 이름이 남는다(기존 `reduce`와 같다).
    static func knownNames(_ places: [PlaceStay]) -> [String: String] {
        places.reduce(into: [String: String]()) { $0[$1.placeKey] = $1.displayName }
    }

    /// 경로 판정에 쓰는 측정값: 시각이 맞는 것만 시간순으로 모아 움직임 기록을 입힌다(ARC1103A01 A안).
    nonisolated static func routeReadingsInBackground(
        _ readings: [SensorReading],
        activities: [MotionActivityRecord]
    ) async -> [SensorReading] {
        routeReadings(readings, activities: activities)
    }

    static func routeReadings(_ readings: [SensorReading], activities: [MotionActivityRecord]) -> [SensorReading] {
        AppleDeviceGroundTruthEngine.applyingMotionHistory(
            to: readings
                .filter { RouteTimelineTimestamp.isValid($0.timestamp) }
                .sorted { $0.timestamp < $1.timestamp },
            activities: activities
        )
    }

    nonisolated static func runInBackground(_ input: Input) async -> Output {
        run(input)
    }

    static func run(_ input: Input) -> Output {
        let resolved = FrequentPlaceResolutionEngine().applying(
            input.frequentPlaces,
            to: input.detectedPlaces,
            readings: input.readings
        )
        let floorTimeline = FloorTimelineEngine().apply(
            readings: input.readings,
            to: resolved,
            knownPlaces: input.knownPlaces
        )
        let basePlaces = PlaceStayMergeEngine.merging(floorTimeline.places)
        let walkingLocations = WalkingLocationEngine()
            .build(readings: input.readings)
            .filter { walkingLocation in
                !basePlaces.contains { place in
                    guard let placePoint = place.point,
                          let walkingPoint = walkingLocation.point,
                          place.span.intersection(
                              with: walkingLocation.span
                          ) != nil else {
                        return false
                    }
                    return distanceMeters(placePoint, walkingPoint) <= 100
                }
            }
        let gpsSegments = MovementRouteBuilder().build(
            stays: basePlaces,
            readings: input.readings,
            healthEvidence: input.healthMovementEvidence,
            userTransitLocations: input.userTransitLocations,
            registeredCarAudioNames: input.registeredCarAudioNames
        )
        let inferredTravel = AppleDeviceGroundTruthEngine.mergingTravel(
            gpsSegments: gpsSegments,
            motionActivities: input.motionActivities,
            pedometer: input.pedometer,
            healthEvidence: input.healthMovementEvidence,
            readings: input.readings,
            preservedSubwaySegments: input.previousSubwaySegments,
            userTransitLocations: input.userTransitLocations,
            registeredCarAudioNames: input.registeredCarAudioNames
        )
        return Output(
            basePlaces: basePlaces,
            places: basePlaces + walkingLocations,
            floors: floorTimeline.transitions,
            inferredTravel: inferredTravel
        )
    }
}

enum SensorTravelDerivation {
    struct Input: Sendable {
        var inferredTravel: [TravelSegment]
        var timeline: [ClassifierAdapter.TimelineSegment]
        var basePlaces: [PlaceStay]
        var readings: [SensorReading]
        var motionActivities: [MotionActivityRecord]
        var corrections: [TravelModeCorrection]
        var boardingDecisions: [TransitBoardingDecision]
        var maximumGap: TimeInterval
        var registeredCarAudioNames: Set<String>
    }

    struct Generated: Sendable {
        var travel: [TravelSegment]
        var railJourneys: [RailJourneyRecognizer.Journey]
    }

    nonisolated static func generatedInBackground(_ input: Input) async -> Generated {
        generated(input)
    }

    nonisolated static func finishedInBackground(_ input: Input, merged: [TravelSegment], railJourneys: [RailJourneyRecognizer.Journey]) async -> [TravelSegment] {
        finished(input, merged: merged, railJourneys: railJourneys)
    }

    static func generated(_ input: Input) -> Generated {
        let correctedTravel = AppleDeviceGroundTruthEngine.resolvingOverlaps(
            AppleDeviceGroundTruthEngine.enforcingMotionFamily(
                MovementCorrectionEngine.applying(
                    input.corrections,
                    to: ClassifierAdapter.resolvingTravelModes(input.inferredTravel, timeline: input.timeline),
                    places: input.basePlaces,
                    readings: input.readings
                ),
                activities: input.motionActivities,
                readings: input.readings
            )
        )
        let travel = AppleDeviceGroundTruthEngine.coalescingTravel(
            TransitBoardingDecisionEngine.applying(
                input.boardingDecisions,
                to: correctedTravel
            ),
            stays: input.basePlaces,
            maximumGap: input.maximumGap
        )
        return Generated(travel: travel, railJourneys: RailJourneyRecognizer.journeys(readings: input.readings))
    }

    static func finished(_ input: Input, merged: [TravelSegment], railJourneys: [RailJourneyRecognizer.Journey]) -> [TravelSegment] {
        let recognizedTravel = CarAudioTravelConfirmation.enforcingRegisteredCar(
            SubwayAlighting.applying(
                RailJourneyRecognizer.applying(
                    railJourneys,
                    to: merged,
                    corrections: input.corrections
                ),
                readings: input.readings,
                corrections: input.corrections
            ),
            readings: input.readings,
            registered: input.registeredCarAudioNames,
            corrections: input.corrections
        )
        return WalkingDistanceBreakdown.make(travel: recognizedTravel, readings: input.readings)
            .annotating(recognizedTravel)
    }
}
