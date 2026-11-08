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
    nonisolated static func detect(readings: [SensorReading], knownNames: [String: String]) async -> [PlaceStay] {
        PlaceDetectionEngine().detectStays(readings: readings, knownNames: knownNames)
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
        let basePlaces = floorTimeline.places
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
        // 지하철·기차 탑승 거리는 선로 길이로 정한다(SUB1108A01).
        let recognizedTravel = SubwayRideTrack.applyingTrackDistance(CarAudioTravelConfirmation.enforcingRegisteredCar(
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
        ))
        return WalkingDistanceBreakdown.make(travel: recognizedTravel, readings: input.readings)
            .annotating(recognizedTravel)
    }
}
