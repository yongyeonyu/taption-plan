import Foundation
import TaptionPlanEngine

enum MovementCorrectionEngine {
    private static let maximumRememberedCorrections = 200
    /// 기억한 철도 보정을 믿으려면 구간 기록의 이만큼은 철도 경로·지하철 Wi-Fi에 맞아야 한다.
    static let minimumRailEvidenceShare = 0.3

    static func recording(
        mode: TravelMode,
        for segment: TravelSegment,
        places: [PlaceStay],
        existing: [TravelModeCorrection],
        at date: Date = .now
    ) -> [TravelModeCorrection] {
        let placeKeys = placeKeys(for: segment, places: places)
        let previous = bestCorrection(
            for: segment,
            places: places,
            in: existing
        )
        let correction = TravelModeCorrection(
            id: previous.flatMap { $0.span.overlapsMostly(segment.span) ? $0.id : nil } ?? UUID(),
            fromPlaceKey: placeKeys.from,
            toPlaceKey: placeKeys.to,
            span: segment.span,
            mode: mode,
            inferredMode: previous?.inferredMode ?? segment.mode,
            inferredConfidence:
                previous?.inferredConfidence ?? segment.confidence,
            updatedAt: date
        )

        // 다른 날에 고친 보정은 그 날의 수정이므로 남긴다. 같은 구간을 다시 고칠 때만 바꾼다(PAW1102A03).
        var result = existing.filter { value in
            guard value.span.overlapsMostly(segment.span) else { return true }
            return !matchesSameTarget(value, segment: segment, places: places) && value.id != previous?.id
        }
        result.append(correction)
        result.sort { $0.updatedAt < $1.updatedAt }
        if result.count > maximumRememberedCorrections {
            result.removeFirst(result.count - maximumRememberedCorrections)
        }
        return result
    }

    /// 기억해 둔 지하철·기차 보정이 이 구간의 센서 근거와 정면으로 부딪치는지.
    /// 구간 안 기록의 대부분이 자동차 모션이고 철도 경로·지하철 Wi-Fi 신호가 일부 순간뿐이면 철도가 아니다.
    /// 역 근처 신호는 근거로 치지 않는다. 차로 한 시간 달리면 역 옆을 한 번은 지나가 막는 장치가 풀렸다(대표 지적, PAW1102A03).
    /// 예전에는 과거에 "집→회사 = 지하철"로 확인한 기억이 자동차로 간 날에도 그대로 덮어써져 지하철 경로(미확인 경로)가 떴다(대표 지적, ARC1030A04).
    static func isContradictedByAutomotive(
        _ correction: TravelModeCorrection,
        segment: TravelSegment,
        readings: [SensorReading]
    ) -> Bool {
        guard correction.mode == .subway || correction.mode == .train else { return false }
        // 이 구간 자체에 건 보정(같은 시간대)은 사용자가 직접 고른 것이라 센서 근거가 달라도 따른다.
        // 막는 것은 다른 날의 보정이 장소 이름이 같다는 이유로 옮겨 오는 경우뿐이다.
        if correction.span.overlapsMostly(segment.span) { return false }
        let inSpan = readings.filter {
            $0.timestamp >= segment.span.start && $0.timestamp <= segment.span.end
        }
        guard inSpan.count >= 20 else { return false }
        let automotive = inSpan.filter { $0.motion == .automotive }.count
        guard Double(automotive) / Double(inSpan.count) >= 0.6 else { return false }
        let railReadings = inSpan.filter {
            $0.matchesRailRoute || ($0.subwayWiFiObservationStreak ?? 0) > 0
        }.count
        return Double(railReadings) / Double(inSpan.count) < minimumRailEvidenceShare
    }

    /// 다른 날 기억만으로는 지하철을 확정하지 않는다. 탑승·하차역이 있는 유효한 노선이 있어야 하고,
    /// 고도 변화가 없으면 역을 지나간 것이다(대표 지시, PAW1102A03). 이 구간에 직접 고른 보정은 따른다.
    private static func lacksSubwayProof(_ correction: TravelModeCorrection, segment: TravelSegment) -> Bool {
        guard correction.mode == .subway else { return false }
        if correction.span.overlapsMostly(segment.span) { return false }
        if segment.evidence.contains(TravelModeClassifier.noAltitudeChangeEvidence) { return true }
        return segment.subwayRoute.map(SubwayStationCatalog.isValid) != true
    }

    static func applying(
        _ corrections: [TravelModeCorrection],
        to segments: [TravelSegment],
        places: [PlaceStay],
        readings: [SensorReading] = []
    ) -> [TravelSegment] {
        segments.map { segment in
            guard let correction = bestCorrection(
                for: segment,
                places: places,
                in: corrections
            ), !isContradictedByAutomotive(correction, segment: segment, readings: readings),
               !lacksSubwayProof(correction, segment: segment) else {
                return segment
            }
            var value = segment
            value.mode = correction.mode
            value.confidence = .high
            value.isConfirmed = true
            value.evidence.removeAll { $0.hasPrefix("사용자 확인") }
            value.evidence.append("사용자 확인 기억")
            return value
        }
    }

    static func correction(
        for segment: TravelSegment,
        places: [PlaceStay],
        in corrections: [TravelModeCorrection]
    ) -> TravelModeCorrection? {
        bestCorrection(
            for: segment,
            places: places,
            in: corrections
        )
    }

    static func removingCorrection(
        for segment: TravelSegment,
        places: [PlaceStay],
        from corrections: [TravelModeCorrection]
    ) -> [TravelModeCorrection] {
        guard let matched = bestCorrection(
            for: segment,
            places: places,
            in: corrections
        ) else {
            return corrections
        }
        return corrections.filter { $0.id != matched.id }
    }

    private static func bestCorrection(
        for segment: TravelSegment,
        places: [PlaceStay],
        in corrections: [TravelModeCorrection]
    ) -> TravelModeCorrection? {
        corrections
            .compactMap { correction -> (TravelModeCorrection, Double)? in
                guard let score = matchScore(
                    correction,
                    segment: segment,
                    places: places
                ) else {
                    return nil
                }
                return (correction, score)
            }
            .max {
                if $0.1 == $1.1 {
                    if $0.0.updatedAt != $1.0.updatedAt {
                        return $0.0.updatedAt < $1.0.updatedAt
                    }
                    return $0.0.id.uuidString > $1.0.id.uuidString
                }
                return $0.1 < $1.1
            }?
            .0
    }

    private static func matchesSameTarget(
        _ correction: TravelModeCorrection,
        segment: TravelSegment,
        places: [PlaceStay]
    ) -> Bool {
        matchScore(
            correction,
            segment: segment,
            places: places
        ) != nil
    }

    private static func matchScore(
        _ correction: TravelModeCorrection,
        segment: TravelSegment,
        places: [PlaceStay]
    ) -> Double? {
        let segmentKeys = placeKeys(for: segment, places: places)
        if let correctionFrom = correction.fromPlaceKey,
           let correctionTo = correction.toPlaceKey,
           correctionFrom == segmentKeys.from,
           correctionTo == segmentKeys.to {
            return 3
        }

        guard let intersection = correction.span.intersection(
            with: segment.span
        ) else {
            return nil
        }
        let shorterDuration = max(
            1,
            min(correction.span.duration, segment.span.duration)
        )
        let overlapRatio = intersection.duration / shorterDuration
        guard overlapRatio >= 0.5 else { return nil }
        return 1 + overlapRatio
    }

    private static func placeKeys(
        for segment: TravelSegment,
        places: [PlaceStay]
    ) -> (from: String?, to: String?) {
        let keysByID = Dictionary(
            uniqueKeysWithValues: places.map { ($0.id, $0.placeKey) }
        )
        return (
            segment.fromPlaceID.flatMap { keysByID[$0] },
            segment.toPlaceID.flatMap { keysByID[$0] }
        )
    }
}
