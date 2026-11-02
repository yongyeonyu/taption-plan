import Foundation
import TaptionPlanEngine

struct FloorTimelineResult: Sendable {
    var places: [PlaceStay]
    var transitions: [FloorTransition]
}

struct FloorTimelineEngine: Sendable {
    var estimator = FloorEstimator(minimumStableSampleCount: 3)
    var minimumPlaceSegmentDuration: TimeInterval = 60

    func apply(
        readings: [SensorReading],
        to detectedPlaces: [PlaceStay],
        knownPlaces: [PlaceStay]
    ) -> FloorTimelineResult {
        var floorByPlaceKey = knownFloorMap(knownPlaces)
        var resolvedPlaces: [PlaceStay] = []
        var transitions: [FloorTransition] = []
        let readingIndex = SensorEvidenceTimeIndex(readings: readings)

        for var place in detectedPlaces.sorted(by: {
            $0.span.start < $1.span.start
        }) {
            let relevant = readingIndex.readings(in: place.span)
            let baselineFloor =
                place.floor ?? floorByPlaceKey[place.placeKey]
            guard var transition = estimator.estimate(
                readings: relevant,
                placeKey: place.placeKey,
                baselineFloor: baselineFloor
            ) else {
                if place.floor == nil {
                    place.floor = baselineFloor
                }
                resolvedPlaces.append(place)
                continue
            }

            // 이동의 출발 층은 이 체류의 기준 층이다. 그 기준을 만든 근거를
            // 함께 남겨야 나중에 기준을 고쳤을 때 출발·도착 층이 따라온다.
            transition.floorEvidence = place.floorEvidence
            transitions.append(transition)
            guard let fromFloor = transition.fromFloor,
                  let toFloor = transition.toFloor else {
                resolvedPlaces.append(place)
                continue
            }
            floorByPlaceKey[place.placeKey] = toFloor

            if let segments = split(
                place,
                transition: transition,
                fromFloor: fromFloor,
                toFloor: toFloor
            ) {
                resolvedPlaces.append(contentsOf: segments)
            } else {
                place.floor = toFloor
                place.floorEvidence = place.floorEvidence?
                    .offset(by: toFloor - fromFloor)
                place.confidence = transition.confidence
                place.isConfirmed = false
                resolvedPlaces.append(place)
            }
        }

        return FloorTimelineResult(
            places: resolvedPlaces,
            transitions: transitions
        )
    }

    private func knownFloorMap(
        _ places: [PlaceStay]
    ) -> [String: Int] {
        let grouped = Dictionary(grouping: places) {
            $0.placeKey
        }
        return grouped.reduce(into: [String: Int]()) {
            values, entry in
            let ordered = entry.value.sorted {
                $0.span.end < $1.span.end
            }
            let known = ordered.last {
                $0.floor != nil && $0.isConfirmed
            } ?? ordered.last { $0.floor != nil }
            if let floor = known?.floor {
                values[entry.key] = floor
            }
        }
    }

    private func split(
        _ place: PlaceStay,
        transition: FloorTransition,
        fromFloor: Int,
        toFloor: Int
    ) -> [PlaceStay]? {
        guard fromFloor != toFloor,
              transition.span.start.timeIntervalSince(place.span.start)
                >= minimumPlaceSegmentDuration,
              place.span.end.timeIntervalSince(transition.span.end)
                >= minimumPlaceSegmentDuration else {
            return nil
        }

        var before = place
        before.id = UUID()
        before.floor = fromFloor
        before.span = TimeSpan(
            start: place.span.start,
            end: transition.span.start
        )

        var after = place
        after.id = UUID()
        after.floor = toFloor
        // 근거를 잰 자리는 체류가 시작된 앞 조각이다. 뒤 조각은 그보다
        // 오르내린 만큼 위에 있다.
        after.floorEvidence = place.floorEvidence?
            .offset(by: toFloor - fromFloor)
        after.span = TimeSpan(
            start: transition.span.end,
            end: place.span.end
        )
        after.confidence = transition.confidence
        after.isConfirmed = false
        return [before, after]
    }
}
