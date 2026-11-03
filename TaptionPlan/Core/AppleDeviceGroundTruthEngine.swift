import Foundation
import TaptionPlanEngine

/// Reconciles records that already exist in Apple's device stores with
/// Taption's own in-app estimates. Plans and user-entered records are retained;
/// only records from the same Apple source are replaced.
enum AppleDeviceGroundTruthEngine {
    private struct MotionActivityEntry: Sendable {
        let activity: MotionActivityRecord
        let inputOrder: Int
    }

    private struct MotionReadingEntry: Sendable {
        let reading: SensorReading
        let inputOrder: Int
    }

    private struct AutomotiveActivityDurationIndex: Sendable {
        private struct Point: Sendable {
            let timestamp: Date
            let accumulatedDuration: TimeInterval
            let activeCount: Int
        }

        private let points: [Point]

        init(activities: [MotionActivityRecord]) {
            var deltas: [Date: Int] = [:]
            for activity in activities where activity.motion == .automotive {
                guard RouteTimelineTimestamp.isValid(activity.span.start),
                      RouteTimelineTimestamp.isValid(activity.span.end),
                      activity.span.duration > 0 else {
                    continue
                }
                deltas[activity.span.start, default: 0] += 1
                deltas[activity.span.end, default: 0] -= 1
            }

            var accumulatedDuration: TimeInterval = 0
            var activeCount = 0
            var previousTimestamp: Date?
            points = deltas.keys.sorted().map { timestamp in
                if let previousTimestamp {
                    accumulatedDuration += TimeInterval(activeCount)
                        * timestamp.timeIntervalSince(previousTimestamp)
                }
                activeCount += deltas[timestamp, default: 0]
                previousTimestamp = timestamp
                return Point(
                    timestamp: timestamp,
                    accumulatedDuration: accumulatedDuration,
                    activeCount: activeCount
                )
            }
        }

        func overlapDuration(
            in span: TimeSpan,
            inspectionCount: inout Int?
        ) -> TimeInterval {
            guard span.duration > 0,
                  RouteTimelineTimestamp.isValid(span.start),
                  RouteTimelineTimestamp.isValid(span.end) else {
                return 0
            }
            return max(
                0,
                integral(at: span.end, inspectionCount: &inspectionCount)
                    - integral(at: span.start, inspectionCount: &inspectionCount)
            )
        }

        private func integral(
            at timestamp: Date,
            inspectionCount: inout Int?
        ) -> TimeInterval {
            var lower = 0
            var upper = points.count
            while lower < upper {
                inspectionCount? += 1
                let middle = lower + (upper - lower) / 2
                if points[middle].timestamp <= timestamp {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            guard lower > 0 else { return 0 }
            let point = points[lower - 1]
            return point.accumulatedDuration
                + TimeInterval(point.activeCount)
                    * timestamp.timeIntervalSince(point.timestamp)
        }
    }

    private struct StayInterruptionIndex: Sendable {
        private static let minimumOverlap: TimeInterval = 3 * 60

        private struct Entry: Sendable {
            let start: Date
            let end: Date
        }

        private let entries: [Entry]
        private let prefixMaximumEnds: [Date]

        init(stays: [PlaceStay]) {
            entries = stays.compactMap { stay in
                guard stay.span.duration >= Self.minimumOverlap else {
                    return nil
                }
                return Entry(start: stay.span.start, end: stay.span.end)
            }.sorted { lhs, rhs in
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                return lhs.end < rhs.end
            }

            var latestEnd = Date.distantPast
            prefixMaximumEnds = entries.map { entry in
                latestEnd = max(latestEnd, entry.end)
                return latestEnd
            }
        }

        func containsInterruption(
            in gap: TimeSpan,
            inspectionCount: inout Int?
        ) -> Bool {
            guard gap.duration >= Self.minimumOverlap,
                  !entries.isEmpty else {
                return false
            }
            let latestStart = gap.end.addingTimeInterval(
                -Self.minimumOverlap
            )
            let earliestEnd = gap.start.addingTimeInterval(
                Self.minimumOverlap
            )
            var lower = 0
            var upper = entries.count
            while lower < upper {
                inspectionCount? += 1
                let middle = lower + (upper - lower) / 2
                if entries[middle].start <= latestStart {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            guard lower > 0 else { return false }
            return prefixMaximumEnds[lower - 1] >= earliestEnd
        }
    }

    /// Projects Apple's device history onto a new array. The archived iPhone
    /// and Watch readings remain the immutable ground truth and are never
    /// rewritten by this reconciliation step.
    static func applyingMotionHistory(
        to readings: [SensorReading],
        activities: [MotionActivityRecord]
    ) -> [SensorReading] {
        var inspectionCount: Int? = nil
        return applyingMotionHistory(
            to: readings,
            activities: activities,
            inspectionCount: &inspectionCount
        )
    }

    static func applyingMotionHistory(
        to readings: [SensorReading],
        activities: [MotionActivityRecord],
        candidateInspectionCount: inout Int
    ) -> [SensorReading] {
        var inspectionCount: Int? = candidateInspectionCount
        let result = applyingMotionHistory(
            to: readings,
            activities: activities,
            inspectionCount: &inspectionCount
        )
        candidateInspectionCount = inspectionCount
            ?? candidateInspectionCount
        return result
    }

    private static func applyingMotionHistory(
        to readings: [SensorReading],
        activities: [MotionActivityRecord],
        inspectionCount: inout Int?
    ) -> [SensorReading] {
        let orderedReadings: [MotionReadingEntry] = readings.enumerated().compactMap {
            inputOrder, reading -> MotionReadingEntry? in
            guard RouteTimelineTimestamp.isValid(reading.timestamp) else {
                return nil
            }
            return MotionReadingEntry(
                reading: reading,
                inputOrder: inputOrder
            )
        }.sorted {
            if $0.reading.timestamp != $1.reading.timestamp {
                return $0.reading.timestamp < $1.reading.timestamp
            }
            return $0.inputOrder < $1.inputOrder
        }
        let orderedActivities: [MotionActivityEntry] = activities.enumerated().compactMap {
            inputOrder, activity -> MotionActivityEntry? in
            guard activity.motion != .unknown,
                  RouteTimelineTimestamp.isValid(activity.span.start),
                  RouteTimelineTimestamp.isValid(activity.span.end) else {
                return nil
            }
            return MotionActivityEntry(
                activity: activity,
                inputOrder: inputOrder
            )
        }.sorted {
            if $0.activity.span.start != $1.activity.span.start {
                return $0.activity.span.start < $1.activity.span.start
            }
            return $0.inputOrder < $1.inputOrder
        }

        var nextActivity = 0
        var activeHeap: [Int] = []
        return orderedReadings.map { entry in
            while nextActivity < orderedActivities.count {
                inspectionCount? += 1
                guard orderedActivities[nextActivity].activity.span.start
                        <= entry.reading.timestamp else {
                    break
                }
                pushMotionActivity(
                    nextActivity,
                    into: &activeHeap,
                    activities: orderedActivities,
                    inspectionCount: &inspectionCount
                )
                nextActivity += 1
            }
            while let winner = activeHeap.first {
                inspectionCount? += 1
                guard orderedActivities[winner].activity.span.end
                        < entry.reading.timestamp else {
                    break
                }
                _ = popMotionActivity(
                    from: &activeHeap,
                    activities: orderedActivities,
                    inspectionCount: &inspectionCount
                )
            }
            guard let winner = activeHeap.first else {
                return entry.reading
            }
            var value = entry.reading
            let activity = orderedActivities[winner].activity
            value.motion = activity.motion
            value.motionConfidence = activity.confidence
            return value
        }
    }

    private static func pushMotionActivity(
        _ index: Int,
        into heap: inout [Int],
        activities: [MotionActivityEntry],
        inspectionCount: inout Int?
    ) {
        heap.append(index)
        var child = heap.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            inspectionCount? += 1
            guard motionActivity(
                activities[heap[child]],
                outranks: activities[heap[parent]]
            ) else { return }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    @discardableResult
    private static func popMotionActivity(
        from heap: inout [Int],
        activities: [MotionActivityEntry],
        inspectionCount: inout Int?
    ) -> Int? {
        guard let first = heap.first else { return nil }
        let last = heap.removeLast()
        guard !heap.isEmpty else { return first }
        heap[0] = last
        var parent = 0
        while true {
            let left = parent * 2 + 1
            guard left < heap.count else { break }
            let right = left + 1
            var highest = left
            if right < heap.count {
                inspectionCount? += 1
                if motionActivity(
                    activities[heap[right]],
                    outranks: activities[heap[left]]
                ) {
                    highest = right
                }
            }
            inspectionCount? += 1
            guard motionActivity(
                activities[heap[highest]],
                outranks: activities[heap[parent]]
            ) else { break }
            heap.swapAt(parent, highest)
            parent = highest
        }
        return first
    }

    private static func motionActivity(
        _ lhs: MotionActivityEntry,
        outranks rhs: MotionActivityEntry
    ) -> Bool {
        if lhs.activity.span.start != rhs.activity.span.start {
            return lhs.activity.span.start > rhs.activity.span.start
        }
        return lhs.inputOrder > rhs.inputOrder
    }

    static func mergingTravel(
        gpsSegments: [TravelSegment],
        motionActivities: [MotionActivityRecord],
        pedometer: PedometerSummary?,
        healthEvidence: [AppleMovementEvidence] = [],
        readings: [SensorReading] = [],
        preservedSubwaySegments: [TravelSegment] = [],
        userTransitLocations: [UserTransitLocation] = [],
        registeredCarAudioNames: Set<String> = []
    ) -> [TravelSegment] {
        var inspectionCount: Int? = nil
        return mergingTravel(
            gpsSegments: gpsSegments,
            motionActivities: motionActivities,
            pedometer: pedometer,
            healthEvidence: healthEvidence,
            readings: readings,
            preservedSubwaySegments: preservedSubwaySegments,
            userTransitLocations: userTransitLocations,
            registeredCarAudioNames: registeredCarAudioNames,
            inspectionCount: &inspectionCount
        )
    }

    static func mergingTravel(
        gpsSegments: [TravelSegment],
        motionActivities: [MotionActivityRecord],
        pedometer: PedometerSummary?,
        healthEvidence: [AppleMovementEvidence] = [],
        readings: [SensorReading] = [],
        preservedSubwaySegments: [TravelSegment] = [],
        userTransitLocations: [UserTransitLocation] = [],
        registeredCarAudioNames: Set<String> = [],
        candidateInspectionCount: inout Int
    ) -> [TravelSegment] {
        var inspectionCount: Int? = candidateInspectionCount
        let result = mergingTravel(
            gpsSegments: gpsSegments,
            motionActivities: motionActivities,
            pedometer: pedometer,
            healthEvidence: healthEvidence,
            readings: readings,
            preservedSubwaySegments: preservedSubwaySegments,
            userTransitLocations: userTransitLocations,
            registeredCarAudioNames: registeredCarAudioNames,
            inspectionCount: &inspectionCount
        )
        candidateInspectionCount = inspectionCount
            ?? candidateInspectionCount
        return result
    }

    private static func mergingTravel(
        gpsSegments: [TravelSegment],
        motionActivities: [MotionActivityRecord],
        pedometer: PedometerSummary?,
        healthEvidence: [AppleMovementEvidence],
        readings: [SensorReading],
        preservedSubwaySegments: [TravelSegment],
        userTransitLocations: [UserTransitLocation],
        registeredCarAudioNames: Set<String>,
        inspectionCount: inout Int?
    ) -> [TravelSegment] {
        inspectionCount? += gpsSegments.count
            + motionActivities.count
            + healthEvidence.count
            + readings.count
            + preservedSubwaySegments.count
        let candidateSpans = gpsSegments.map(\.span)
        let gpsIndex = TimeSpanValueIndex(gpsSegments) { $0.span }
        let evidenceIndex = SensorEvidenceTimeIndex(
            readings: readings,
            healthEvidence: healthEvidence
        )
        let detectedSubwaySegments = candidateSpans.isEmpty
            ? SubwayTravelSegmentEngine.segments(
                from: readings,
                userTransitLocations: userTransitLocations,
                registeredCarAudioNames: registeredCarAudioNames
            )
            : SubwayTravelSegmentEngine.segments(
                from: evidenceIndex,
                within: candidateSpans,
                userTransitLocations: userTransitLocations,
                registeredCarAudioNames: registeredCarAudioNames
            )
        let trajectorySubwaySegments = stabilizedSubwaySegments(
            detected: detectedSubwaySegments,
            preserved: preservedSubwaySegments,
            freshVehicle: gpsSegments.filter(TravelModeClassifier.isMotionBackedCar)
        )
            .map { segment in
                guard let matched = gpsIndex
                    .values(
                        overlapping: segment.span,
                        inspectionCount: &inspectionCount
                    )
                    .filter({ overlappingEnough($0.span, segment.span) })
                    .max(by: {
                        overlapDuration($0.span, segment.span)
                            < overlapDuration($1.span, segment.span)
                    }) else { return segment }
                var value = segment
                value.fromPlaceID = matched.fromPlaceID
                value.toPlaceID = matched.toPlaceID
                if matched.span.duration <= segment.span.duration + 30 * 60 {
                    value.span = TimeSpan(
                        start: min(matched.span.start, segment.span.start),
                        end: max(matched.span.end, segment.span.end)
                    )
                }
                return value
            }
        let trajectorySubwayIndex = TimeSpanValueIndex(
            trajectorySubwaySegments
        ) { $0.span }
        let primarySegments = gpsSegments.filter { gps in
            !trajectorySubwayIndex.contains(
                overlapping: gps.span,
                inspectionCount: &inspectionCount
            ) { subway, _ in
                subwayDisplaces(subway, gps)
            }
        } + trajectorySubwaySegments
        let primaryIndex = TimeSpanValueIndex(primarySegments) { $0.span }
        let watchSegments = healthEvidence
            .filter {
                $0.source == .appleWatch
                    && $0.kind == .workout
                    && $0.workoutMode != nil
                    && $0.span.duration >= 60
            }
            .filter { workout in
                !primaryIndex.contains(
                    overlapping: workout.span,
                    inspectionCount: &inspectionCount
                ) { _, _ in
                    true
                }
            }
            .map { workout in
                TravelSegment(
                    mode: workout.workoutMode ?? .walking,
                    span: workout.span,
                    distanceMeters: workout.distanceMeters ?? 0,
                    confidence: .high,
                    evidence: [
                        "Apple Watch 운동 기록",
                        "HealthKit 기기 출처 확인",
                    ]
                )
            }
        let watchIndex = TimeSpanValueIndex(watchSegments) { $0.span }
        let candidates = motionActivities
            .filter { $0.span.duration >= 60 }
            .filter { activity in
                !primaryIndex.contains(
                    overlapping: activity.span,
                    inspectionCount: &inspectionCount
                ) { _, _ in
                    true
                }
                    && !watchIndex.contains(
                        overlapping: activity.span,
                        inspectionCount: &inspectionCount
                    ) { _, _ in
                        true
                    }
            }
            .compactMap { activity -> (MotionActivityRecord, MovementInference)? in
                guard travelMode(for: activity.motion) != nil else {
                    return nil
                }
                // 구간 안의 실제 표본을 함께 넘겨야 분류기가 속도를 볼 수 있다.
                // 모션 라벨만 주면 차량 이동도 보행으로 남는다.
                let inside = evidenceIndex.readings(
                    in: activity.span,
                    inspectionCount: &inspectionCount
                )
                let context = inside.isEmpty
                    ? [
                        SensorReading(
                            timestamp: activity.span.start,
                            motion: activity.motion,
                            motionConfidence: activity.confidence,
                            gpsAvailable: false
                        ),
                    ]
                    : inside
                let inference = TravelModeClassifier().classify(
                    readings: context,
                    inside: activity.span,
                    healthEvidence: evidenceIndex.healthEvidence(
                        overlapping: activity.span,
                        inspectionCount: &inspectionCount
                    ),
                    userTransitLocations: userTransitLocations,
                    altitudeContext: evidenceIndex.readings(
                        in: TravelModeClassifier.altitudeContextSpan(activity.span),
                        inspectionCount: &inspectionCount
                    ),
                    registeredCarAudioNames: registeredCarAudioNames
                )
                return (activity, inference)
            }

        let walkingRunningDuration = candidates.reduce(0) { result, candidate in
            switch candidate.1.mode {
            case .walking, .running:
                result + candidate.0.span.duration
            default:
                result
            }
        }

        let motionSegments = candidates.map { activity, inference in
            let mode = inference.mode
            let usesPedometerDistance =
                (mode == .walking || mode == .running)
                && walkingRunningDuration > 0
            let distance = usesPedometerDistance
                ? (pedometer?.distanceMeters ?? 0)
                    * activity.span.duration / walkingRunningDuration
                : 0
            var evidence = ["iPhone Core Motion 기록"]
            if usesPedometerDistance, pedometer?.distanceMeters != nil {
                evidence.append("iPhone 걸음·거리 기록")
            }
            if activity.motion == .automotive,
               !CarAudioTravelConfirmation.confirms(inference.evidence) {
                evidence.append("차량 종류는 사용자 확인 필요")
            }
            evidence.append(contentsOf: inference.evidence)
            return TravelSegment(
                mode: mode,
                span: activity.span,
                distanceMeters: distance,
                confidence: inference.confidence,
                evidence: Array(Set(evidence)).sorted(),
                isConfirmed: CarAudioTravelConfirmation.confirms(inference.evidence),
                subwayRoute: inference.subwayRoute
            )
        }

        return (primarySegments + watchSegments + motionSegments)
            .sorted { $0.span.start < $1.span.start }
    }

    private static func stabilizedSubwaySegments(
        detected: [TravelSegment],
        preserved: [TravelSegment],
        freshVehicle: [TravelSegment] = []
    ) -> [TravelSegment] {
        var result = detected
        for segment in preserved where segment.mode == .subway {
            guard let route = segment.subwayRoute,
                  segment.confidence == .high
                    || segment.isClassificationLocked,
                  SubwayStationCatalog.isValid(route) else {
                continue
            }
            guard let index = result.firstIndex(where: {
                overlappingEnough($0.span, segment.span)
            }) else {
                // 새로 감지되지 않은 예전 자동 지하철은, 같은 시간이 고신뢰 자동차로 판정됐으면 되살리지 않는다(EXP1029A01).
                guard segment.isConfirmed
                        || !freshVehicle.contains(where: { overlappingEnough($0.span, segment.span) })
                else { continue }
                result.append(segment)
                continue
            }
            // 새 판정이 고도 변화가 없어 지하철을 뺐으면 예전 자동 지하철로 되돌리지 않는다.
            if result[index].evidence.contains(TravelModeClassifier.noAltitudeChangeEvidence),
               !segment.isConfirmed { continue }
            result[index] = preferredSubwaySegment(
                result[index],
                over: segment
            )
        }
        return result
    }

    /// 확인된 지하철 구간은 GPS·Core Motion의 자동차 후보보다 우선한다.
    /// 두 구간이 같은 시각을 조금이라도 공유하는 경우에도 역 순서·환승·
    /// 정차 패턴으로 확정된 지하철을 자동차가 덮어쓰지 않게 한다.
    private static func subwayDisplaces(
        _ subway: TravelSegment,
        _ candidate: TravelSegment
    ) -> Bool {
        guard subway.mode == .subway,
              subway.confidence == .high,
              let route = subway.subwayRoute,
              SubwayStationCatalog.isValid(route) else {
            return overlappingEnough(candidate.span, subway.span)
        }
        let overlap = overlapDuration(candidate.span, subway.span)
        guard overlap > 0 else { return false }
        let shorter = max(
            1,
            min(candidate.span.duration, subway.span.duration)
        )
        return overlap / shorter >= 0.2
    }

    private static func preferredSubwaySegment(
        _ lhs: TravelSegment,
        over rhs: TravelSegment
    ) -> TravelSegment {
        let lhsStops = lhs.subwayRoute?.stops.count ?? 0
        let rhsStops = rhs.subwayRoute?.stops.count ?? 0
        let preferred: TravelSegment
        if lhsStops != rhsStops {
            preferred = lhsStops > rhsStops ? lhs : rhs
        } else if lhs.confidence != rhs.confidence {
            preferred = lhs.confidence == .high ? lhs : rhs
        } else {
            preferred = lhs.span.duration >= rhs.span.duration ? lhs : rhs
        }
        var value = preferred
        value.span = TimeSpan(
            start: min(lhs.span.start, rhs.span.start),
            end: max(lhs.span.end, rhs.span.end)
        )
        value.evidence = Array(Set(lhs.evidence + rhs.evidence)).sorted()
        value.isConfirmed = lhs.isConfirmed || rhs.isConfirmed
        value.fromPlaceID = lhs.fromPlaceID ?? rhs.fromPlaceID
        value.toPlaceID = lhs.toPlaceID ?? rhs.toPlaceID
        value.distanceMeters = max(lhs.distanceMeters, rhs.distanceMeters)
        value.subwayRoute = preferred.subwayRoute
            ?? lhs.subwayRoute
            ?? rhs.subwayRoute
        return value
    }

    private static func overlappingEnough(
        _ lhs: TimeSpan,
        _ rhs: TimeSpan
    ) -> Bool {
        let shorter = max(1, min(lhs.duration, rhs.duration))
        return overlapDuration(lhs, rhs) / shorter >= 0.5
    }

    private static func overlapDuration(
        _ lhs: TimeSpan,
        _ rhs: TimeSpan
    ) -> TimeInterval {
        lhs.intersection(with: rhs)?.duration ?? 0
    }

    /// Core Motion이 자동차로 본 구간은 최종 결과에서도 동력 이동으로 남긴다.
    /// 분류기 내부 점수 융합이 자전거·보행을 만들어 내는 일이 있어, 기록
    /// 상세와 시간표가 서로 다른 수단을 보여주는 문제를 여기서 끊는다.
    /// 걸음이 실제로 늘어난 구간은 라벨이 틀린 것이므로 건드리지 않는다.
    static func enforcingMotionFamily(
        _ segments: [TravelSegment],
        activities: [MotionActivityRecord],
        readings: [SensorReading]
    ) -> [TravelSegment] {
        var inspectionCount: Int? = nil
        return enforcingMotionFamily(
            segments,
            activities: activities,
            readings: readings,
            inspectionCount: &inspectionCount
        )
    }

    static func enforcingMotionFamily(
        _ segments: [TravelSegment],
        activities: [MotionActivityRecord],
        readings: [SensorReading],
        candidateInspectionCount: inout Int
    ) -> [TravelSegment] {
        var inspectionCount: Int? = candidateInspectionCount
        let result = enforcingMotionFamily(
            segments,
            activities: activities,
            readings: readings,
            inspectionCount: &inspectionCount
        )
        candidateInspectionCount = inspectionCount
            ?? candidateInspectionCount
        return result
    }

    private static func enforcingMotionFamily(
        _ segments: [TravelSegment],
        activities: [MotionActivityRecord],
        readings: [SensorReading],
        inspectionCount: inout Int?
    ) -> [TravelSegment] {
        let pedestrianModes: Set<TravelMode> = [.walking, .running, .cycling]
        inspectionCount? += activities.count + readings.count
        let automotiveIndex = AutomotiveActivityDurationIndex(
            activities: activities
        )
        let readingIndex = SensorEvidenceTimeIndex(readings: readings)
        return segments.map { segment in
            guard pedestrianModes.contains(segment.mode) else { return segment }
            let automotive = automotiveIndex.overlapDuration(
                in: segment.span,
                inspectionCount: &inspectionCount
            )
            guard automotive >= segment.span.duration * 0.6,
                  segment.span.duration >= 120 else {
                return segment
            }
            let steps = readingIndex
                .readings(
                    in: segment.span,
                    inspectionCount: &inspectionCount
                )
                .compactMap(\.stepCount)
            let stepDelta = (steps.max() ?? 0) - (steps.min() ?? 0)
            let minutes = max(1, segment.span.duration / 60)
            guard Double(stepDelta) / minutes < 20 else { return segment }
            var value = segment
            value.mode = .car
            value.evidence = Array(
                Set(value.evidence + ["iPhone Core Motion 자동차"])
            ).sorted()
            return value
        }
    }

    /// 같은 시각에 두 개 이상의 이동이 겹치면 시간표가 여러 줄로 쪼개져
    /// 보인다. 신뢰도가 높고 긴 구간을 남기고, 나머지는 잘라내거나 버린다.
    static func resolvingOverlaps(
        _ segments: [TravelSegment]
    ) -> [TravelSegment] {
        let ordered = segments.filter { $0.span.duration > 0 }.sorted {
            if $0.span.start == $1.span.start {
                return $0.span.duration > $1.span.duration
            }
            return $0.span.start < $1.span.start
        }
        var suffixStart = Array(
            repeating: Date.distantFuture,
            count: ordered.count + 1
        )
        if !ordered.isEmpty {
            for index in stride(from: ordered.count - 1, through: 0, by: -1) {
                suffixStart[index] = min(
                    suffixStart[index + 1],
                    ordered[index].span.start
                )
            }
        }
        var result: [TravelSegment] = []
        for (index, segment) in ordered.enumerated() {
            guard let last = result.last,
                  last.span.intersection(with: segment.span) != nil else {
                result.append(segment)
                continue
            }
            let keepsExisting = confidenceRank(last.confidence)
                > confidenceRank(segment.confidence)
                || (confidenceRank(last.confidence)
                    == confidenceRank(segment.confidence)
                    && last.span.duration >= segment.span.duration)
            if keepsExisting {
                // 뒤쪽만 남겨 이어 붙일 수 있으면 잘라서 유지한다.
                guard segment.span.end.timeIntervalSince(last.span.end) >= 60
                else { continue }
                // The trimmed suffix would be reordered behind a later
                // input. Drop this lower-priority candidate so the one-pass
                // output stays sorted and cannot overlap an earlier winner.
                guard suffixStart[index + 1] >= last.span.end else {
                    continue
                }
                var trimmed = segment
                trimmed.span = TimeSpan(
                    start: last.span.end,
                    end: segment.span.end
                )
                let retained = trimmed.span.duration
                    / max(1, segment.span.duration)
                trimmed.distanceMeters = segment.distanceMeters * retained
                result.append(trimmed)
            } else {
                guard last.span.end.timeIntervalSince(segment.span.start) < 60
                        || last.span.duration < 60 else {
                    var trimmedLast = last
                    trimmedLast.span = TimeSpan(
                        start: last.span.start,
                        end: segment.span.start
                    )
                    let retained = trimmedLast.span.duration
                        / max(1, last.span.duration)
                    trimmedLast.distanceMeters = last.distanceMeters * retained
                    result[result.count - 1] = trimmedLast
                    result.append(segment)
                    if last.span.end.timeIntervalSince(segment.span.end) >= 60 {
                        var tail = last
                        tail.span = TimeSpan(
                            start: segment.span.end,
                            end: last.span.end
                        )
                        let tailRatio = tail.span.duration
                            / max(1, last.span.duration)
                        tail.distanceMeters = last.distanceMeters * tailRatio
                        result.append(tail)
                    }
                    continue
                }
                result[result.count - 1] = segment
            }
        }
        return result.filter { $0.span.duration > 0 }.sorted {
            if $0.span.start != $1.span.start {
                return $0.span.start < $1.span.start
            }
            return $0.span.end < $1.span.end
        }
    }

    /// 듀티사이클 샘플링이 만든 같은 모드의 이동 조각을 하나로 잇는다.
    /// 조각 사이에 체류가 감지되어 있으면 실제로 멈춘 것이므로 잇지 않는다.
    static func coalescingTravel(
        _ segments: [TravelSegment],
        stays: [PlaceStay],
        maximumGap: TimeInterval
    ) -> [TravelSegment] {
        var inspectionCount: Int? = nil
        return coalescingTravel(
            segments,
            stays: stays,
            maximumGap: maximumGap,
            inspectionCount: &inspectionCount
        )
    }

    static func coalescingTravel(
        _ segments: [TravelSegment],
        stays: [PlaceStay],
        maximumGap: TimeInterval,
        candidateInspectionCount: inout Int
    ) -> [TravelSegment] {
        var inspectionCount: Int? = candidateInspectionCount
        let result = coalescingTravel(
            segments,
            stays: stays,
            maximumGap: maximumGap,
            inspectionCount: &inspectionCount
        )
        candidateInspectionCount = inspectionCount
            ?? candidateInspectionCount
        return result
    }

    private static func coalescingTravel(
        _ segments: [TravelSegment],
        stays: [PlaceStay],
        maximumGap: TimeInterval,
        inspectionCount: inout Int?
    ) -> [TravelSegment] {
        inspectionCount? += stays.count
        let stayIndex = StayInterruptionIndex(stays: stays)
        var result: [TravelSegment] = []
        for segment in segments.sorted(by: { $0.span.start < $1.span.start }) {
            guard var last = result.last,
                  last.mode == segment.mode,
                  segment.span.start.timeIntervalSince(last.span.end)
                      <= maximumGap,
                  !stayIndex.containsInterruption(
                      in: TimeSpan(
                          start: last.span.end,
                          end: segment.span.start
                      ),
                      inspectionCount: &inspectionCount
                  ) else {
                result.append(segment)
                continue
            }
            last.span = TimeSpan(
                start: last.span.start,
                end: max(last.span.end, segment.span.end)
            )
            last.distanceMeters += segment.distanceMeters
            if confidenceRank(segment.confidence)
                > confidenceRank(last.confidence) {
                last.confidence = segment.confidence
            }
            last.evidence = Array(Set(last.evidence + segment.evidence))
                .sorted()
            last.isConfirmed = last.isConfirmed || segment.isConfirmed
            last.toPlaceID = segment.toPlaceID ?? last.toPlaceID
            last.subwayRoute = last.subwayRoute ?? segment.subwayRoute
            result[result.count - 1] = last
        }
        return result
    }

    private static func confidenceRank(_ level: ConfidenceLevel) -> Int {
        switch level {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }

    static func replacingHealthKitActuals(
        existing: [ActualRecord],
        with fresh: [ActualRecord],
        inside span: TimeSpan
    ) -> [ActualRecord] {
        var seen = Set<UUID>()
        let uniqueFresh = fresh.filter {
            ($0.source == .healthKit || $0.source == .appleWatch)
                && seen.insert($0.id).inserted
        }
        let freshIDs = Set(uniqueFresh.map(\.id))
        let linkedWorkouts = uniqueFresh.filter { $0.planID != nil }
        let hasFreshSleep = uniqueFresh.contains { actual in
            AutomaticRecordTimelineEngine.isSleep(actual)
                && actual.span().intersection(with: span) != nil
        }
        return (
            existing.filter { existingActual in
                if existingActual.source == .healthKit,
                   existingActual.span().intersection(with: span) != nil {
                    // HealthKit can transiently return no sleep samples while
                    // its store is catching up. Do not erase the last known
                    // canonical sleep unless a fresh sleep result replaced it.
                    return AutomaticRecordTimelineEngine.isSleep(existingActual)
                        && !hasFreshSleep
                }
                if existingActual.source == .appleWatch,
                   AutomaticRecordTimelineEngine.isSleep(existingActual),
                   existingActual.span().intersection(with: span) != nil {
                    return !hasFreshSleep
                }
                if existingActual.source == .appleWatch,
                   freshIDs.contains(existingActual.id) {
                    return false
                }
                guard existingActual.source == .timer,
                      let planID = existingActual.planID else {
                    return true
                }
                let supersededByWatchWorkout = linkedWorkouts.contains { workout in
                    guard workout.planID == planID else { return false }
                    let endsAt = workout.endedAt ?? workout.startedAt
                    let timerSpan = existingActual.span(asOf: endsAt)
                    let startsTogether = abs(
                        existingActual.startedAt.timeIntervalSince(workout.startedAt)
                    ) <= 5 * 60
                    return startsTogether
                        || timerSpan.intersection(with: workout.span()) != nil
                }
                return !supersededByWatchWorkout
            }
            + uniqueFresh
        )
        .sorted { $0.startedAt < $1.startedAt }
    }

    private static func travelMode(for motion: MotionKind) -> TravelMode? {
        switch motion {
        case .walking:
            .walking
        case .running:
            .running
        case .cycling:
            .cycling
        case .automotive:
            .car
        case .stationary, .unknown:
            nil
        }
    }
}
