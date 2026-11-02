import Foundation
import TaptionPlanEngine

struct FrequentPlaceResolutionEngine: Sendable {
    func applying(
        _ frequentPlaces: [FrequentPlace],
        to detectedPlaces: [PlaceStay],
        readings: [SensorReading]
    ) -> [PlaceStay] {
        let candidates = frequentPlaces.filter {
            $0.point != nil && $0.isAutomaticRecordingEnabled
        }
        guard !candidates.isEmpty else { return detectedPlaces }
        let readingIndex = SensorEvidenceTimeIndex(readings: readings)

        return detectedPlaces.map { place in
            guard let point = place.point,
                  let match = nearestMatch(
                    to: point,
                    candidates: candidates,
                    readings: readingIndex.readings(in: place.span)
                  ) ?? zoneMatch(
                    candidates: candidates,
                    span: place.span,
                    readings: readingIndex.readings(in: place.span)
                  ) else {
                return place
            }

            // 짧은 방문은 일반 장소로 남겨 두고, 설정한 체류 시간 이상일
            // 때만 자주가는 곳으로 확정합니다.
            let minimumDwellMinutes = match.kind == .restaurant
                ? 15
                : match.minimumDwellMinutes
            guard place.span.duration
                    >= TimeInterval(minimumDwellMinutes * 60) else {
                return place
            }

            var updated = place
            updated.placeKey = match.stablePlaceKey
            updated.displayName = match.name
            updated.buildingName = match.name

            let placeReadings = readingIndex.readings(in: place.span)
            let anchor = placeReadings.min { $0.timestamp < $1.timestamp }
            // 층수는 이 관측에서 파생된다. 표본은 7일 뒤 지워지므로 근거가
            // 된 숫자를 기록 옆에 남겨 둔다. 이번 새로고침에 표본이 없다면
            // 이미 적어 둔 근거를 지우지 않는다.
            if let evidence = anchor.flatMap({ FloorEvidence($0) }) {
                updated.floorEvidence = evidence
            }

            // A user-confirmed floor is the building anchor. GPS altitude and
            // barometric altitude drift by several metres while standing in
            // one place, so recalculating from the first sample made a fixed
            // home/company floor jump on every refresh. Real floor changes
            // are handled separately by FloorTimelineEngine after they remain
            // stable across multiple samples.
            if let floor = match.floor {
                // 등록된 기준 층은 날씨·문 개폐·사람 움직임에 따른
                // 기압/GPS drift로 덮지 않는다. 실제 층 이동은 여러 표본을
                // 본 FloorTimelineEngine이 별도로 확정한다.
                updated.floor = floor
                updated.confidence = .high
            } else if let calibration = match.floorCalibration,
                      let estimate = FloorCalibrationEngine().estimate(
                          readings: placeReadings,
                          calibration: calibration
                      ) {
                updated.floor = estimate.floor
                updated.confidence = estimate.confidence
            }
            updated.isConfirmed = true
            return updated
        }
    }

    /// 체류 중심이 반경 밖이어도 표본이 세 원 판정으로 체류의 절반 넘게 그 안에 있었으면 그 장소다.
    /// 반경을 줄인 장소에서 표본 몇 개가 중심을 끌어 머문 것을 놓치지 않게 한다.
    private func zoneMatch(
        candidates: [FrequentPlace],
        span: TimeSpan,
        readings: [SensorReading]
    ) -> FrequentPlace? {
        return candidates.filter { place in
            guard let center = place.point else { return false }
            let covered = PlaceZoneStayTracker.stays(readings: readings, center: center, radius: place.radiusMeters)
                .reduce(0) { $0 + ($1.span.intersection(with: span)?.duration ?? 0) }
            return covered >= span.duration / 2
        }.min { $0.radiusMeters < $1.radiusMeters }
    }

    /// 기준점을 고친 뒤, 이미 저장된 이 장소의 체류를 새 기준으로 다시
    /// 매긴다. 기록이 스스로 지닌 근거를 먼저 쓰고, 그것이 없는 옛 기록은
    /// 7일 보관분과 대표 GPS 고도 순으로 보완한다. 어느 근거도 없을 때만
    /// 있던 층수를 그대로 둔다.
    func reapplyingFloors(
        of place: FrequentPlace,
        to places: [PlaceStay],
        readings: [SensorReading]
    ) -> [PlaceStay] {
        guard let calibration = place.floorCalibration else { return places }
        let key = place.stablePlaceKey
        let readingIndex = SensorEvidenceTimeIndex(readings: readings)
        let engine = FloorCalibrationEngine()
        return places.map { stay in
            guard stay.placeKey == key else { return stay }
            let estimate: CalibratedAltitudeEstimate?
            if let evidence = stay.floorEvidence {
                estimate = engine.estimate(
                    evidence: evidence,
                    at: stay.point ?? place.point,
                    calibration: calibration
                )
            } else {
                let stayReadings = readingIndex.readings(in: stay.span)
                if !stayReadings.isEmpty {
                    estimate = engine.estimate(
                        readings: stayReadings,
                        calibration: calibration
                    )
                } else if let point = stay.point,
                          point.altitude.isFinite {
                    // 예전 기록도 대표 GPS 고도는 자체 보관한다. 기압 원본이
                    // 만료됐더라도 이 낮은 신뢰도의 근거로 현재 보정값을 다시
                    // 적용할 수 있으며, 저장된 좌표와 원본 센서는 바꾸지 않는다.
                    estimate = engine.estimate(
                        evidence: FloorEvidence(measuredAt: stay.span.start),
                        at: point,
                        calibration: calibration
                    )
                } else {
                    estimate = nil
                }
            }
            guard let estimate else { return stay }
            var updated = stay
            updated.floor = estimate.floor
            updated.confidence = estimate.confidence
            return updated
        }
    }

    /// 층 이동 기록도 기준 층 위에 얹혀 있다. 오르내린 층수는 그대로 두고
    /// 출발 층만 새 기준으로 다시 매겨 도착 층까지 함께 옮긴다. 사용자가
    /// 직접 고른 도착 층은 건드리지 않는다.
    func reapplyingFloors(
        of place: FrequentPlace,
        to transitions: [FloorTransition]
    ) -> [FloorTransition] {
        guard let calibration = place.floorCalibration else {
            return transitions
        }
        let key = place.stablePlaceKey
        let engine = FloorCalibrationEngine()
        return transitions.map { transition in
            guard transition.placeKey == key,
                  !transition.isUserConfirmed,
                  let evidence = transition.floorEvidence,
                  let from = transition.fromFloor,
                  let estimate = engine.estimate(
                    evidence: evidence,
                    at: place.point,
                    calibration: calibration
                  ) else {
                return transition
            }
            var updated = transition
            updated.fromFloor = estimate.floor
            updated.toFloor = transition.toFloor.map {
                $0 - from + estimate.floor
            }
            return updated
        }
    }

    /// `applying` 은 확정된 체류의 `placeKey` 를 자주가는 곳의 안정 키로
    /// 바꾼다. 그 키로 장소 종류를 되찾아 정지 구간 문맥 추론에 넘긴다.
    func kindsByPlaceKey(
        _ frequentPlaces: [FrequentPlace]
    ) -> [String: FrequentPlaceKind] {
        frequentPlaces.reduce(into: [:]) { $0[$1.stablePlaceKey] = $1.kind }
    }

    /// 반경 안 후보를 점수로 고른다(ALG1102A01). 회사 반경 안의 식당에 있으면 식당이 이긴다.
    /// 높이가 어긋나는 후보는 빼서 5층 사무실이 1층 식당으로 잡히지 않게 하고, 하나만 남는 경우 그 하나를 높이로 지우지 않는다.
    /// 사용자가 정한 장소의 좌표·키는 바꾸지 않는다. 판정 입력일 뿐이다.
    func nearestMatch(
        to point: GeoPoint,
        candidates: [FrequentPlace],
        readings: [SensorReading] = []
    ) -> FrequentPlace? {
        let containing = candidates.compactMap { frequent -> (FrequentPlace, Double)? in
            guard let frequentPoint = frequent.point else { return nil }
            let distance = distanceMeters(point, frequentPoint)
            return distance <= frequent.radiusMeters
                ? (frequent, distance)
                : nil
        }
        let places = containing.map(\.0)
        let atHeight = containing.filter { !PlaceHeightMatch.isAtOtherHeight($0.0, among: places, readings: readings) }
        let accuracy = point.horizontalAccuracy >= 0 ? point.horizontalAccuracy : 0
        return (atHeight.isEmpty ? containing : atHeight)
            .max(by: {
                let left = Self.matchScore(distance: $0.1, radius: $0.0.radiusMeters, accuracy: accuracy)
                let right = Self.matchScore(distance: $1.1, radius: $1.0.radiusMeters, accuracy: accuracy)
                return left != right ? left < right : $0.0.stablePlaceKey > $1.0.stablePlaceKey
            })?
            .0
    }

    /// 위치 오차를 감안해 반경 안에 있을 확률에 장소 크기 가중을 곱한다. 작은 장소가 더 구체적인 답이라
    /// 식당(30m)은 회사(100m 이상) 반경 안에서도 이기고, 크기가 비슷하면 거리와 정확도가 가른다.
    static func matchScore(distance: Double, radius: Double, accuracy: Double) -> Double {
        let sigma = max(5, accuracy)
        let inside = 0.5 * erfc(-(radius - distance) / (sigma * 2.0.squareRoot()))
        return inside * 100 / (30 + radius)
    }
}

/// 지정 장소의 층·기준 고도와 체류 고도를 견준다(ALT1102A01).
enum PlaceHeightMatch {
    /// 기압 절대값은 날씨로 몇 시간 만에 수십 미터씩 움직인다. 기준을 그 방문 안에서 잰 경우만 비교한다(ALG1102A01).
    private static let visitMargin: TimeInterval = 30 * 60
    private static let gpsToleranceMeters = 12.0

    static func isAtOtherHeight(_ place: FrequentPlace, among places: [FrequentPlace], readings: [SensorReading]) -> Bool {
        guard places.count >= 2, !readings.isEmpty, let targetFloor = place.floor else { return false }
        // 층만 적은 장소는 겹친 다른 장소의 기준 고도에 층 차이를 더해 쓴다(같은 건물이라고 본다).
        let own = references(of: place)
        let sources = own.isEmpty ? places.filter { $0.id != place.id }.flatMap(references) : own
        guard let reference = sources.min(by: { abs($0.0.floor - targetFloor) < abs($1.0.floor - targetFloor) }) else { return false }
        let floorHeight = max(2.2, reference.1)
        let times = readings.map(\.timestamp)
        let visit = (times.min() ?? .distantPast)...(times.max() ?? .distantFuture)
        let measured = readings.compactMap { reading -> (meters: Double, source: AltitudeDelta.Source)? in
            guard let delta = AltitudeDelta.between(
                sample(reference.0, visit: visit),
                and: currentSample(reading)
            ) else { return nil }
            return (delta.meters, delta.source)
        }
        guard let source = measured.first?.source else { return false }
        let values = measured.filter { $0.source == source }.map(\.meters).sorted()
        let expected = Double(targetFloor - reference.0.floor) * floorHeight
        let gap = abs(values[values.count / 2] - expected)
        switch source {
        case .relativeAltitude: return gap > floorHeight * 0.75
        case .pressure: return gap > floorHeight * 1.5
        case .gps: return gap > max(floorHeight * 1.5, gpsToleranceMeters)
        }
    }

    private static func references(of place: FrequentPlace) -> [(FloorCalibrationPoint, Double)] {
        // 지도에서 찍기만 한 장소는 기준 고도가 없다.
        (place.floorCalibration?.resolvedReferencePoints ?? [])
            .filter { $0.point.verticalAccuracy >= 0 || $0.pressureKilopascals != nil || $0.relativeAltitudeMeters != nil }
            .map { ($0, place.floorHeightMeters) }
    }

    private static func sample(_ reference: FloorCalibrationPoint, visit: ClosedRange<Date>) -> AltitudeDelta.Sample {
        var value = AltitudeDelta.Sample(reference)
        if reference.point.verticalAccuracy < 0 { value.altitudeMeters = nil }
        let isSameVisit = reference.capturedAt >= visit.lowerBound.addingTimeInterval(-visitMargin)
            && reference.capturedAt <= visit.upperBound.addingTimeInterval(visitMargin)
        if !isSameVisit { value.pressureKilopascals = nil }
        return value
    }

    private static func currentSample(_ reading: SensorReading) -> AltitudeDelta.Sample {
        var value = AltitudeDelta.Sample(reading)
        if (reading.point?.verticalAccuracy ?? -1) < 0 { value.altitudeMeters = nil }
        return value
    }
}

/// 등록되지 않았는데 반복해서 머문 자리. 앱은 이름을 지어내지 않고, 이미
/// 역지오코딩으로 받아 둔 이름이 있으면 그것만 제안한다. 등록은 사용자가 한다.
struct FrequentPlaceSuggestion: Identifiable, Hashable, Sendable {
    enum Reason: Hashable, Sendable {
        /// 한 주 안에 세 번 이상.
        case weekly
        /// 한 달 안에 열 번 이상.
        case monthly
    }

    var id: String
    var point: GeoPoint
    var suggestedName: String?
    var visitCount: Int
    var firstVisitedAt: Date
    var lastVisitedAt: Date
    var reason: Reason
}
