import Foundation
import TaptionPlanEngine

struct MovementRouteBuilder: Sendable {
    var classifier = TravelModeClassifier()

    func build(
        stays: [PlaceStay],
        readings: [SensorReading],
        healthEvidence: [AppleMovementEvidence] = [],
        correctedModes: [String: TravelMode] = [:],
        userTransitLocations: [UserTransitLocation] = [],
        registeredCarAudioNames: Set<String> = [],
        motionActivities: [MotionActivityRecord] = []
    ) -> [TravelSegment] {
        var inspectionCount: Int? = nil
        return build(
            stays: stays,
            readings: readings,
            healthEvidence: healthEvidence,
            correctedModes: correctedModes,
            userTransitLocations: userTransitLocations,
            registeredCarAudioNames: registeredCarAudioNames,
            motionActivities: motionActivities,
            inspectionCount: &inspectionCount
        )
    }

    func build(
        stays: [PlaceStay],
        readings: [SensorReading],
        healthEvidence: [AppleMovementEvidence] = [],
        correctedModes: [String: TravelMode] = [:],
        userTransitLocations: [UserTransitLocation] = [],
        registeredCarAudioNames: Set<String> = [],
        motionActivities: [MotionActivityRecord] = [],
        candidateInspectionCount: inout Int
    ) -> [TravelSegment] {
        var inspectionCount: Int? = candidateInspectionCount
        let result = build(
            stays: stays,
            readings: readings,
            healthEvidence: healthEvidence,
            correctedModes: correctedModes,
            userTransitLocations: userTransitLocations,
            registeredCarAudioNames: registeredCarAudioNames,
            motionActivities: motionActivities,
            inspectionCount: &inspectionCount
        )
        candidateInspectionCount = inspectionCount
            ?? candidateInspectionCount
        return result
    }

    private func build(
        stays: [PlaceStay],
        readings: [SensorReading],
        healthEvidence: [AppleMovementEvidence],
        correctedModes: [String: TravelMode],
        userTransitLocations: [UserTransitLocation],
        registeredCarAudioNames: Set<String>,
        motionActivities: [MotionActivityRecord],
        inspectionCount: inout Int?
    ) -> [TravelSegment] {
        let orderedStays = stays.sorted { $0.span.start < $1.span.start }
        guard orderedStays.count >= 2 else { return [] }
        let evidenceIndex = SensorEvidenceTimeIndex(
            readings: readings,
            healthEvidence: healthEvidence
        )

        return zip(orderedStays, orderedStays.dropFirst()).compactMap { from, to in
            guard from.placeKey != to.placeKey else { return nil }
            let gap = TimeSpan(start: from.span.end, end: to.span.start)
            guard gap.duration > 0 else { return nil }
            let gapReadings = evidenceIndex.readings(
                in: gap,
                inspectionCount: &inspectionCount
            )
            let span = Self.trimmingUnobservedLead(
                Self.departureSpan(gap, readings: gapReadings, origin: from.point),
                readings: gapReadings,
                motion: motionActivities
            )
            let segmentReadings = gapReadings.filter { $0.timestamp >= span.start }
            let originReadings = evidenceIndex.readings(
                in: from.span,
                inspectionCount: &inspectionCount
            )
            let destinationReadings = evidenceIndex.readings(
                in: to.span,
                inspectionCount: &inspectionCount
            )
            let signature = "\(from.placeKey)->\(to.placeKey)"
            let segmentHealthEvidence = evidenceIndex.healthEvidence(
                overlapping: span,
                inspectionCount: &inspectionCount
            )
            let correctedMode = correctedModes[signature]
            let wbsMode = correctedMode == nil
                ? WBSMovementTransportPolicy.recommendedMode(
                    from: from,
                    to: to,
                    originReadings: originReadings,
                    destinationReadings: destinationReadings
                )
                : nil
            guard !segmentReadings.isEmpty
                    || !segmentHealthEvidence.isEmpty
                    || correctedMode != nil
                    || wbsMode != nil else {
                return nil
            }
            let inference = wbsMode.map {
                MovementInference(
                    mode: $0,
                    confidence: .high,
                    score: 0.95,
                    evidence: [$0 == .airplane
                        ? "체류 사이 점프: 지상 불가 속도 · 비행"
                        : "체류 사이 점프"]
                )
            } ?? classifier.classify(
                readings: segmentReadings,
                inside: span,
                healthEvidence: segmentHealthEvidence,
                correctedMode: correctedMode,
                userTransitLocations: userTransitLocations,
                altitudeContext: evidenceIndex.readings(
                    in: TravelModeClassifier.altitudeContextSpan(span),
                    inspectionCount: &inspectionCount
                ),
                registeredCarAudioNames: registeredCarAudioNames
            )
            let sensorDistance = TravelDistanceMath.pathMeters(readings: segmentReadings)
            let endpointDistance = from.point.flatMap { origin in
                to.point.map { destination in
                    distanceMeters(origin, destination)
                }
            } ?? 0
            // 비행은 끝점 대권 거리. 예전 70m/s 컷 때문에 GPS 점 사이 거리가 0이 됐다.
            let distance = inference.mode == .airplane
                ? endpointDistance
                : (sensorDistance > 0 ? sensorDistance : (wbsMode != nil ? endpointDistance : 0))
            return TravelSegment(
                fromPlaceID: from.id,
                toPlaceID: to.id,
                mode: inference.mode,
                span: span,
                distanceMeters: distance,
                confidence: inference.confidence,
                evidence: inference.evidence,
                isConfirmed: correctedMode != nil
                    || CarAudioTravelConfirmation.confirms(inference.evidence),
                subwayRoute: inference.subwayRoute
            )
        }
    }

    /// 출발 전 머무름을 이동에서 뗀다(CAT1029A03).
    ///
    /// 자는 동안 GPS가 끊기면 앞 머무름이 마지막 표본에서 끝나, 잠든 시각부터 도착까지가
    /// 한 이동이 되고 GPS 손실이 지하철 점수로 읽혔다. 출발지에 머문 근거(출발지 200m 안의
    /// 정지 표본, 또는 2시간 넘게 이어진 정지)가 있고 출발 근거가 30분 넘게 늦으면,
    /// 이동은 마지막 정지 표본에서 시작한다. 지하에서 GPS만 끊긴 이동은 그 근거가 없어 그대로다.
    static func departureSpan(_ gap: TimeSpan, readings: [SensorReading], origin: GeoPoint?) -> TimeSpan {
        func isNearOrigin(_ reading: SensorReading) -> Bool {
            guard let origin, let point = reading.point, point.horizontalAccuracy <= 100 else { return false }
            return distanceMeters(origin, point) <= 200
        }
        guard let departure = readings.firstIndex(where: { reading in
            let awayFromOrigin = reading.point.map { $0.horizontalAccuracy <= 100 } == true
                && origin != nil && !isNearOrigin(reading)
            return awayFromOrigin || reading.motion == .automotive || reading.motion == .cycling
                || (reading.motion != .stationary && (reading.speedMetersPerSecond ?? 0) >= 1.5)
        }) else { return gap }
        let still = readings[..<departure].filter { $0.motion == .stationary }
        guard let lastStill = still.last,
              readings[departure].timestamp.timeIntervalSince(gap.start) > 30 * 60,
              still.contains(where: isNearOrigin)
                || lastStill.timestamp.timeIntervalSince(still[0].timestamp) >= 2 * 60 * 60,
              lastStill.timestamp > gap.start, lastStill.timestamp < gap.end else { return gap }
        return TimeSpan(start: lastStill.timestamp, end: gap.end)
    }

    /// 앞 머무름 끝과 첫 표본 사이가 이만큼 넘게 비면 앱이 꺼져 있던 것으로 본다.
    static let maximumUnobservedLead: TimeInterval = 30 * 60
    /// 이어진 움직임으로 볼 Core Motion 기록 사이 틈.
    static let motionChainGap: TimeInterval = 2 * 60

    /// 앱이 꺼져 표본이 하나도 없던 긴 시간은 이동에 넣지 않는다(MOV1110A01).
    ///
    /// 회사에서 일하는 동안 앱이 3시간 반 꺼져 있다가 CarPlay로 깨어나자, 이동이 마지막 회사 표본부터
    /// 시작해 근무 시간 전체가 자동차가 됐다. iOS가 그동안 남긴 Core Motion 기록에서 첫 표본으로 이어지는
    /// 움직임(걷기·달리기·자전거·차)의 시작을 출발로 본다. 그 시간 Core Motion 기록이 없으면 언제 떠났는지
    /// 알 수 없으니 그대로 둔다. 뗀 앞부분은 이동도 체류도 아닌 「미확인」으로 남는다.
    static func trimmingUnobservedLead(
        _ span: TimeSpan,
        readings: [SensorReading],
        motion: [MotionActivityRecord]
    ) -> TimeSpan {
        guard let first = readings.lazy.map(\.timestamp).filter({ $0 >= span.start }).min(),
              first.timeIntervalSince(span.start) > maximumUnobservedLead else { return span }
        let recorded = motion
            .filter { $0.span.end > span.start && $0.span.start < first }
            .sorted { $0.span.start < $1.span.start }
        guard !recorded.isEmpty else { return span }
        var start = first
        for activity in recorded.reversed() {
            guard Self.isMoving(activity.motion),
                  start.timeIntervalSince(activity.span.end) <= motionChainGap else { break }
            start = min(start, activity.span.start)
        }
        return TimeSpan(start: max(span.start, start), end: span.end)
    }

    private static func isMoving(_ motion: MotionKind) -> Bool {
        switch motion {
        case .walking, .running, .cycling, .automotive: true
        case .stationary, .unknown: false
        }
    }

}

/// 비행 중 GPS가 비어도 두 체류 사이 점프로 항공 구간을 만든다. 끝점 이름(공항·항구)만으로는
/// 정하지 않는다: 지상에서 불가능한 속도(70m/s 초과)이고 100km 넘게 떨어졌거나 양끝이
/// 공항 근처일 때만 비행이다(`TravelDistance.isFlightJump`). 배는 물 위 속도 근거가 있어야
/// 하므로 여기서 만들지 않는다. 원본 표본은 수정하지 않는다.
enum WBSMovementTransportPolicy {
    static func recommendedMode(
        from origin: PlaceStay,
        to destination: PlaceStay,
        originReadings: [SensorReading] = [],
        destinationReadings: [SensorReading] = []
    ) -> TravelMode? {
        guard let start = origin.point, let end = destination.point else { return nil }
        let duration = destination.span.start.timeIntervalSince(origin.span.end)
        return TravelDistance.isFlightJump(
            distanceMeters: distanceMeters(start, end),
            duration: duration,
            originNearAirport: originReadings.contains(where: \.nearAirport),
            destinationNearAirport: destinationReadings.contains(where: \.nearAirport)
        ) ? .airplane : nil
    }
}

/// 앱이 꺼져 어떤 표본(위치·움직임·화면)도 없던 긴 시간(MOV1110A01). 이 시간은 이동·식사 후보·공백 추정으로
/// 채우지 않고 미확인으로 둔다. iOS가 따로 남긴 Core Motion 기록은 원본이라 그대로 둔다.
enum UnobservedAppSpans {
    static let minimum = MovementRouteBuilder.maximumUnobservedLead

    /// 다시 켜진 때가 이동 안(또는 이동 시작 5분 안)일 때만 센다. 집에서 자는 동안 꺼져 있던 밤처럼
    /// 같은 자리로 돌아온 공백은 예전처럼 둔다.
    static func spans(readings: [SensorReading], travel: [TravelSegment], inside: TimeSpan) -> [TimeSpan] {
        let times = readings.lazy.map(\.timestamp).filter { inside.contains($0) }.sorted()
        return zip(times, times.dropFirst()).compactMap { before, after in
            guard after.timeIntervalSince(before) > minimum,
                  travel.contains(where: { $0.span.contains(after) || abs($0.span.start.timeIntervalSince(after)) <= 5 * 60 })
            else { return nil }
            return TimeSpan(start: before, end: after)
        }
    }

    /// 기록의 절반 넘게 그런 시간 안에 있다.
    static func covers(_ spans: [TimeSpan], _ span: TimeSpan) -> Bool {
        guard span.duration > 0 else { return false }
        let inside = spans.reduce(0) { $0 + ($1.intersection(with: span)?.duration ?? 0) }
        return inside > span.duration / 2
    }
}
