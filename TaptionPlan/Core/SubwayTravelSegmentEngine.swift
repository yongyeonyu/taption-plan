import Foundation
import TaptionPlanEngine

/// 지도 보강값과 Core Motion 라벨이 비어 있던 과거 기록에서도 원본 GPS가
/// 철도역을 순서대로 통과했다면 이동 세그먼트를 복원한다. 원본 표본은 바꾸지
/// 않고, 파생 구간만 만들어 자동차 조각과 `unknown` 공백을 대체한다.
enum SubwayTravelSegmentEngine {
    /// 배터리 절약 프로필은 15분 간격으로 표본을 남긴다. 예약 실행의
    /// 지연까지 감안해 한 번의 표본 공백은 18분까지 같은 이동으로 잇는다.
    /// 역 GPS가 출발·도착만 남은 경우에는 두 끝점의 철도 근거와 연결된
    /// 카탈로그 경로를 확인한 뒤에만 30분까지 이어서 지하 구간을 복원한다.
    static let defaultMaximumReadingGap: TimeInterval = 18 * 60
    private static let railEndpointMaximumReadingGap: TimeInterval = 30 * 60

    static func confirmedRoute(
        for segment: TravelSegment,
        readingIndex: SensorEvidenceTimeIndex
    ) -> TravelSegment? {
        guard RouteConfirmedSubwayIntervalIndex.hasTrustedSubwayRoute(segment) else { return nil }
        if segment.subwayRoute.map(SubwayStationCatalog.isValid) == true { return segment }
        let context = TimeSpan(start: segment.span.start.addingTimeInterval(-2 * 60),
            end: segment.span.end.addingTimeInterval(2 * 60))
        var groups: [[SensorReading]] = []
        var current: [SensorReading] = []
        let ordered = readingIndex.readings(in: context).sorted { $0.timestamp < $1.timestamp }
        for reading in ordered {
            if reading.trackingSessionEnded == true || reading.sourceDevice == .appleWatch {
                if !current.isEmpty { groups.append(current) }
                current = []
                continue
            }
            if let last = current.last,
               (reading.timestamp.timeIntervalSince(last.timestamp) > railEndpointMaximumReadingGap
                || (last.trackingSessionID != nil && reading.trackingSessionID != nil
                    && last.trackingSessionID != reading.trackingSessionID)) {
                groups.append(current)
                current = []
            }
            current.append(reading)
        }
        if !current.isEmpty { groups.append(current) }
        let candidates = groups.compactMap { group -> TravelSegment? in
            let journey = SubwayStationCatalog.stationJourney(from: group)
            // User boarding confirmation supplies the rail evidence required for sparse endpoints.
            let trajectory = SubwayStationCatalog.coordinateTrajectory(from: group)
                ?? SubwayStationCatalog.sparseEndpointTrajectory(from: group)
            guard let route = journey?.route ?? trajectory?.route,
                  SubwayStationCatalog.isValid(route),
                  let observedSpan = journey?.span ?? trajectory?.span,
                  let overlap = observedSpan.intersection(with: segment.span),
                  overlap.duration / max(1, observedSpan.duration) >= 0.5 else { return nil }
            var value = segment
            value.subwayRoute = route
            value.span = overlap
            return value
        }
        return candidates.max { $0.span.duration < $1.span.duration }
    }

    static func segments(
        from readings: [SensorReading],
        maximumReadingGap: TimeInterval = defaultMaximumReadingGap,
        userTransitLocations: [UserTransitLocation] = [],
        registeredCarAudioNames: Set<String> = []
    ) -> [TravelSegment] {
        let maximumGap = maximumReadingGap.isFinite
            ? max(0, maximumReadingGap)
            : defaultMaximumReadingGap
        return inferSegments(
            from: groups(from: readings, maximumGap: maximumGap),
            userTransitLocations: userTransitLocations,
            registeredCarAudioNames: registeredCarAudioNames
        )
    }

    /// Prefer the movement windows already found between known places. A
    /// whole-day coordinate pass can join morning and evening commutes and
    /// then choose an unrelated rail path, even though each individual move
    /// contains enough station evidence.
    static func segments(
        from readings: [SensorReading],
        within candidateSpans: [TimeSpan],
        maximumReadingGap: TimeInterval = defaultMaximumReadingGap,
        userTransitLocations: [UserTransitLocation] = [],
        registeredCarAudioNames: Set<String> = []
    ) -> [TravelSegment] {
        guard !candidateSpans.isEmpty else {
            return segments(
                from: readings,
                maximumReadingGap: maximumReadingGap,
                userTransitLocations: userTransitLocations,
                registeredCarAudioNames: registeredCarAudioNames
            )
        }
        return segments(
            from: SensorEvidenceTimeIndex(readings: readings),
            within: candidateSpans,
            maximumReadingGap: maximumReadingGap,
            userTransitLocations: userTransitLocations,
            registeredCarAudioNames: registeredCarAudioNames
        )
    }

    static func segments(
        from readingIndex: SensorEvidenceTimeIndex,
        within candidateSpans: [TimeSpan],
        maximumReadingGap: TimeInterval = defaultMaximumReadingGap,
        userTransitLocations: [UserTransitLocation] = [],
        registeredCarAudioNames: Set<String> = []
    ) -> [TravelSegment] {
        guard !candidateSpans.isEmpty else { return [] }
        let maximumGap = maximumReadingGap.isFinite
            ? max(0, maximumReadingGap)
            : defaultMaximumReadingGap
        let candidateGroups = candidateSpans.flatMap { span -> [[SensorReading]] in
            let context = TimeSpan(
                start: span.start.addingTimeInterval(-10 * 60),
                end: span.end.addingTimeInterval(10 * 60)
            )
            return groups(
                from: readingIndex.readings(in: context),
                maximumGap: maximumGap
            )
        }
        return inferSegments(
            from: candidateGroups,
            userTransitLocations: userTransitLocations,
            registeredCarAudioNames: registeredCarAudioNames
        )
            .filter { segment in
                candidateSpans.contains { span in
                    segment.span.intersection(with: span) != nil
                }
            }
    }

    /// Rebuilds subway-derived travel after a cloud restore. Existing user
    /// confirmations remain authoritative; only overlapping unconfirmed
    /// candidates are replaced by the route inferred from restored samples.
    static func mergingRestoredTravel(
        existing: [TravelSegment],
        readings: [SensorReading],
        userTransitLocations: [UserTransitLocation] = []
    ) -> [TravelSegment] {
        let detected = segments(
            from: readings,
            userTransitLocations: userTransitLocations
        )
        guard !detected.isEmpty else {
            return existing.sorted { $0.span.start < $1.span.start }
        }

        var result = existing
        for candidate in detected {
            let preserved = result.filter { segment in
                segment.mode == .subway
                    && segment.isConfirmed
                    && restoredOverlapEnough(segment.span, candidate.span)
            }
            if !preserved.isEmpty { continue }

            result.removeAll { segment in
                !segment.isConfirmed
                    && segment.span.intersection(with: candidate.span) != nil
            }
            result.append(candidate)
        }
        return result.sorted { $0.span.start < $1.span.start }
    }

    private static func restoredOverlapEnough(
        _ lhs: TimeSpan,
        _ rhs: TimeSpan
    ) -> Bool {
        let overlap = lhs.intersection(with: rhs)?.duration ?? 0
        let shorter = max(1, min(lhs.duration, rhs.duration))
        return overlap / shorter >= 0.5
    }

    private static func inferSegments(
        from groups: [[SensorReading]],
        userTransitLocations: [UserTransitLocation],
        registeredCarAudioNames: Set<String> = []
    ) -> [TravelSegment] {
        var result: [TravelSegment] = []
        for group in groups {
            let stationJourney = SubwayStationCatalog.stationJourney(
                from: group
            )
            let strictTrajectory = SubwayStationCatalog.coordinateTrajectory(
                from: group
            )
            let railMatchCount = group.filter(\.matchesRailRoute).count
            let hasRailConfirmation = !group.isEmpty
                && railMatchCount >= 2
                && Double(railMatchCount) / Double(group.count) >= 0.25
            let trajectory = strictTrajectory
                ?? (hasRailConfirmation
                    ? SubwayStationCatalog.sparseEndpointTrajectory(from: group)
                    : nil)
            guard let span = stationJourney?.span ?? trajectory?.span else {
                continue
            }
            let contextSpan = TimeSpan(
                start: span.start.addingTimeInterval(-2 * 60),
                end: span.end.addingTimeInterval(2 * 60)
            )
            let context = group.filter { contextSpan.contains($0.timestamp) }
            let altitudeSpan = TravelModeClassifier.altitudeContextSpan(span)
            let inference = TravelModeClassifier().classify(
                readings: context,
                inside: span,
                userTransitLocations: userTransitLocations,
                altitudeContext: group.filter { altitudeSpan.contains($0.timestamp) },
                registeredCarAudioNames: registeredCarAudioNames
            )
            guard inference.mode == .subway || inference.mode == .train else {
                continue
            }
            guard let route = inference.subwayRoute
                ?? stationJourney?.route
                ?? trajectory?.route,
                  SubwayStationCatalog.isValid(route) else {
                continue
            }
            let sparseEndpointEvidence = trajectory?.isSparseEndpointTrajectory == true
                ? ["철도 지도 신호·출발역·도착역 복원"]
                : []
            let stationStateEvidence = stationJourney?.evidence ?? []
            var routeSourceEvidence = trajectory == nil
                ? ["역 체류 상태로 지하철 구간 확정"]
                : ["원본 GPS 철도 궤적 복원"]
            if inference.mode == .train {
                routeSourceEvidence.append("철도 탑승을 지하철 카탈로그 경로로 변환")
            }
            result.append(TravelSegment(
                mode: .subway,
                span: span,
                distanceMeters: pathDistance(route.coordinates),
                confidence: stationJourney?.isConfirmed == true
                    ? .high
                    : (trajectory?.isSparseEndpointTrajectory == true
                        ? .medium
                        : .high),
                evidence: Array(
                    Set(
                        inference.evidence
                            + sparseEndpointEvidence
                            + stationStateEvidence
                            + routeSourceEvidence
                    )
                ).sorted(),
                subwayRoute: route
            ))
        }
        return result
    }

    private static func groups(
        from readings: [SensorReading],
        maximumGap: TimeInterval
    ) -> [[SensorReading]] {
        var result: [[SensorReading]] = []
        for reading in readings
            .filter({ RouteTimelineTimestamp.isValid($0.timestamp) })
            .sorted(by: { $0.timestamp < $1.timestamp }) {
            guard var current = result.popLast() else {
                result.append([reading])
                continue
            }
            if let previous = current.last,
               shouldJoin(
                   previous,
                   reading,
                   maximumGap: maximumGap
               ) {
                current.append(reading)
                result.append(current)
            } else {
                result.append(current)
                result.append([reading])
            }
        }
        return result
    }

    private static func shouldJoin(
        _ previous: SensorReading,
        _ next: SensorReading,
        maximumGap: TimeInterval
    ) -> Bool {
        guard previous.trackingSessionEnded != true, next.trackingSessionEnded != true,
              previous.sourceDevice != .appleWatch, next.sourceDevice != .appleWatch else { return false }
        if let previousID = previous.trackingSessionID,
           let nextID = next.trackingSessionID, previousID != nextID { return false }
        let gap = next.timestamp.timeIntervalSince(previous.timestamp)
        if gap <= maximumGap { return true }
        guard maximumGap == defaultMaximumReadingGap,
              gap <= railEndpointMaximumReadingGap,
              previous.point != nil,
              next.point != nil,
              previous.nearbyStation,
              next.nearbyStation,
              previous.matchesRailRoute,
              next.matchesRailRoute,
              let previousName = previous.nearbyStationName,
              let nextName = next.nearbyStationName,
              !previousName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !nextName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        return SubwayStationCatalog.route(for: [previousName, nextName]) != nil
    }

    private static func pathDistance(_ points: [GeoPoint]) -> Double {
        zip(points, points.dropFirst()).reduce(0) {
            $0 + distanceMeters($1.0, $1.1)
        }
    }
}
