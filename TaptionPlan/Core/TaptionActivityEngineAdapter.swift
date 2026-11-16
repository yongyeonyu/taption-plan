import Foundation
import TaptionPlanEngine

struct TaptionActivityClassificationResult: Sendable {
    let state: ActivityClassificationState

    var segments: [ActivitySegment] { state.segments }

    var majorCategoryIDs: [String] {
        var seen = Set<String>()
        return segments.compactMap { seen.insert($0.majorCategoryID).inserted ? $0.majorCategoryID : nil }
    }
}

struct TaptionSensorQualityProjection: Sendable {
    let readings: [SensorReading]
    let routeReadings: [SensorReading]
    let rejectionCounts: [String: Int]
    let impossibleLocationCount: Int
    let innovationOutlierCount: Int
}

struct TaptionDataTrustProjection: Sendable {
    let rawReadings: [SensorReading]
    let filteredGPSReadings: [SensorReading]
    let supportingReadings: [SensorReading]
    let actuals: [UUID: ActivityDataProvenance]
    let places: [UUID: ActivityDataProvenance]
    let travel: [UUID: ActivityDataProvenance]
}

enum TaptionActivityEngineAdapter {
    static let engine = ActivityClassificationEngine()
    static let confirmedSleepModelVersion = "manual-confirmed-sleep-v1"
    static let inferredGapModelVersion = AutomaticModelVersion.inferredGap
    static let classifiedActivityModelVersion = AutomaticModelVersion.classifiedActivity
    static let strictSleepModelVersion = AutomaticModelVersion.strictSleep

    static func dataTrustProjection(
        readings: [SensorReading],
        actuals: [ActualRecord],
        places: [PlaceStay],
        travel: [TravelSegment]
    ) -> TaptionDataTrustProjection {
        let quality = qualityProjection(from: readings)
        return TaptionDataTrustProjection(
            rawReadings: readings,
            filteredGPSReadings: quality.routeReadings,
            supportingReadings: readings.filter(isSupportingReading),
            actuals: Dictionary(
                actuals.map { ($0.id, provenance(for: $0)) },
                uniquingKeysWith: { _, latest in latest }
            ),
            places: Dictionary(
                places.map { ($0.id, provenance(for: $0)) },
                uniquingKeysWith: { _, latest in latest }
            ),
            travel: Dictionary(
                travel.map { ($0.id, provenance(for: $0)) },
                uniquingKeysWith: { _, latest in latest }
            )
        )
    }

    static func provenance(for reading: SensorReading) -> ActivityDataProvenance {
        let supporting = isSupportingReading(reading)
        let source = reading.sourceDevice == .appleWatch ? "apple-watch" : "iphone"
        let span = ActivityTimeSpan(
            start: reading.timestamp,
            end: reading.timestamp.addingTimeInterval(1)
        )
        return ActivityDataProvenance(
            tier: supporting ? .supporting : .groundTruth,
            status: .observed,
            source: supporting ? "coarse-location-\(source)" : "raw-sensor-\(source)",
            evidence: supporting
                ? ["GPS 유실 또는 대략적 위치", "Wi-Fi·기지국 보조"]
                : ["원본 센서 관측"],
            confidence: supporting ? 0.45 : 1,
            span: span
        )
    }

    static func provenance(for actual: ActualRecord) -> ActivityDataProvenance {
        let isUserCorrected = actual.manuallyCorrected
            || actual.source == .manual
            || actual.source == .timer
        let isGroundTruth = isUserCorrected
            || !actual.source.usesAutomaticClassification
        let score = confidenceScore(actual.confidence)
        let span = ActivityTimeSpan(
            start: actual.startedAt,
            end: max(actual.startedAt.addingTimeInterval(1), actual.endedAt ?? actual.startedAt)
        )
        if isGroundTruth {
            return ActivityDataProvenance(
                tier: .groundTruth,
                status: isUserCorrected ? .userCorrected : .observed,
                source: actual.source.rawValue,
                evidence: actual.evidence,
                confidence: score,
                span: span
            )
        }
        let status: ActivityInferenceStatus = actual.categoryID == "unconfirmed"
            ? .unresolved
            : ActivityAutomaticConfirmation.status(for: score)
        return ActivityDataProvenance(
            tier: .expected,
            status: status,
            source: actual.modelVersion ?? actual.source.rawValue,
            evidence: actual.evidence,
            confidence: score,
            span: span
        )
    }

    static func provenance(for place: PlaceStay) -> ActivityDataProvenance {
        let registered = place.isRegisteredFrequentPlace
        let score = confidenceScore(place.confidence)
        return ActivityDataProvenance(
            tier: registered ? .groundTruth : .expected,
            status: registered ? .observed : ActivityAutomaticConfirmation.status(for: score),
            source: registered ? "registered-place" : "place-detection-v1",
            evidence: registered ? ["사용자 등록 장소"] : ["GPS 체류 감지"],
            confidence: score,
            span: ActivityTimeSpan(start: place.span.start, end: place.span.end)
        )
    }

    static func provenance(for travel: TravelSegment) -> ActivityDataProvenance {
        let score = confidenceScore(travel.confidence)
        let isUserCorrected = travel.evidence.contains {
            $0.hasPrefix("사용자 확인") || $0 == "사용자 교정"
        }
        return ActivityDataProvenance(
            tier: isUserCorrected ? .groundTruth : .expected,
            status: isUserCorrected
                ? .userCorrected
                : ActivityAutomaticConfirmation.status(for: score),
            source: isUserCorrected ? "user-travel-correction" : "travel-inference-v1",
            evidence: travel.evidence,
            confidence: score,
            span: ActivityTimeSpan(start: travel.span.start, end: travel.span.end)
        )
    }

    static func trustLabel(for actual: ActualRecord) -> String {
        trustLabel(provenance(for: actual))
    }

    static func trustLabel(for reading: SensorReading) -> String {
        trustLabel(provenance(for: reading))
    }

    static func trustLabel(for place: PlaceStay) -> String {
        trustLabel(provenance(for: place))
    }

    static func trustLabel(for travel: TravelSegment) -> String {
        trustLabel(provenance(for: travel))
    }

    static func provenanceMarkers(for actual: ActualRecord) -> [String] {
        markers(for: provenance(for: actual))
    }

    static func provenanceMarkers(for reading: SensorReading) -> [String] {
        markers(for: provenance(for: reading))
    }

    static func provenanceMarkers(for place: PlaceStay) -> [String] {
        markers(for: provenance(for: place))
    }

    static func provenanceMarkers(for travel: TravelSegment) -> [String] {
        markers(for: provenance(for: travel))
    }

    static func classifiedActivityActuals(
        readings: [SensorReading],
        travel: [TravelSegment],
        corrections: [UUID: ActivityCorrection],
        actuals: [ActualRecord],
        inside span: TimeSpan,
        createdAt: Date = .now
    ) -> [ActualRecord] {
        do {
            return try classifiedActivityActuals(
                readings: readings,
                travel: travel,
                corrections: corrections,
                actuals: actuals,
                inside: span,
                createdAt: createdAt,
                cancellationCheck: {}
            )
        } catch {
            preconditionFailure("Unexpected activity classification cancellation: \(error)")
        }
    }

    static func classifiedActivityActuals(
        readings: [SensorReading],
        travel: [TravelSegment],
        corrections: [UUID: ActivityCorrection],
        actuals: [ActualRecord],
        inside span: TimeSpan,
        createdAt: Date = .now,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) throws -> [ActualRecord] {
        var dayReadings: [SensorReading] = []
        dayReadings.reserveCapacity(readings.count)
        for (index, reading) in readings.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            if RouteTimelineTimestamp.isValid(reading.timestamp)
                && reading.timestamp >= span.start
                && reading.timestamp < span.end {
                dayReadings.append(reading)
            }
        }

        var dayTravel: [TravelSegment] = []
        dayTravel.reserveCapacity(travel.count)
        for (index, segment) in travel.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            if segment.span.intersection(with: span) != nil {
                dayTravel.append(segment)
            }
        }

        var dayActuals: [ActualRecord] = []
        dayActuals.reserveCapacity(actuals.count)
        for (index, actual) in actuals.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            if actual.span(asOf: span.end).intersection(with: span) != nil {
                dayActuals.append(actual)
            }
        }

        let result = try classify(
            readings: dayReadings,
            travel: dayTravel,
            corrections: corrections,
            actuals: dayActuals,
            cancellationCheck: cancellationCheck
        )
        let activitySpan = ActivityTimeSpan(start: span.start, end: span.end)
        var projected: [ActualRecord] = []
        projected.reserveCapacity(result.segments.count)
        for (index, segment) in result.segments.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            guard !segment.isUserConfirmed,
                  segment.span.duration >= 5 * 60,
                  let clipped = segment.span.intersection(activitySpan),
                  clipped.duration >= 5 * 60 else {
                continue
            }
            let clippedTimeSpan = TimeSpan(start: clipped.start, end: clipped.end)
            if segment.majorCategoryID == "movement" {
                var overlapsTravel = false
                for (travelIndex, travelSegment) in dayTravel.enumerated() {
                    if travelIndex.isMultiple(of: 256) { try cancellationCheck() }
                    if (travelSegment.span.intersection(with: clippedTimeSpan)?.duration ?? 0)
                        >= min(5 * 60, clippedTimeSpan.duration * 0.5) {
                        overlapsTravel = true
                        break
                    }
                }
                if overlapsTravel { continue }
            }
            var overlapsAutomaticActual = false
            for (actualIndex, actual) in dayActuals.enumerated() {
                if actualIndex.isMultiple(of: 256) { try cancellationCheck() }
                if actual.source.usesAutomaticClassification
                    && (actual.span(asOf: span.end).intersection(with: clippedTimeSpan)?.duration
                        ?? 0) >= min(5 * 60, clippedTimeSpan.duration * 0.5) {
                    overlapsAutomaticActual = true
                    break
                }
            }
            if overlapsAutomaticActual { continue }
            projected.append(ActualRecord(
                id: segment.id,
                planID: nil,
                title: segment.title,
                categoryID: segment.majorCategoryID,
                startedAt: clipped.start,
                endedAt: clipped.end,
                source: .motion,
                confidence: ConfidenceLevel(score: segment.confidence),
                createdAt: createdAt,
                behavior: segment.behavior,
                evidence: unique(segment.evidence + ["필터링 센서 투영"]),
                modelVersion: classifiedActivityModelVersion
            ))
        }
        try cancellationCheck()
        return projected
    }

    static func placeActivityActual(
        for stay: PlaceStay,
        registeredKind: FrequentPlaceKind?,
        inside span: TimeSpan,
        createdAt: Date = .now
    ) -> ActualRecord? {
        guard let clipped = stay.span.intersection(with: span) else { return nil }
        let evidence = ActivityPlaceEvidence(
            span: ActivityTimeSpan(start: clipped.start, end: clipped.end),
            registeredKind: activityPlaceKind(for: registeredKind),
            poiKind: activityPOIKind(for: stay.displayName)
        )
        guard let inference = PlaceActivityInferenceEngine().infer(evidence) else {
            return nil
        }
        let title: String
        switch inference.categoryID {
        case "work": title = "근무"
        case "study": title = "수업·학습"
        case "eating": title = "식사"
        case "activity": title = "휴식"
        default: title = stay.displayName
        }
        return ActualRecord(
            id: ActivityStableID.uuid(
                seed: "place-activity|\(stay.id.uuidString)|\(clipped.start.timeIntervalSince1970)|\(clipped.end.timeIntervalSince1970)"
            ),
            planID: nil,
            title: title,
            categoryID: inference.categoryID,
            startedAt: clipped.start,
            endedAt: clipped.end,
            source: .location,
            confidence: ConfidenceLevel(score: inference.confidence),
            createdAt: createdAt,
            behavior: inference.detailID,
            evidence: unique(inference.provenance.evidence + ["장소 의미 예상"]),
            modelVersion: AutomaticModelVersion.placeActivity
        )
    }

    static func strictSleepActuals(
        readings: [SensorReading],
        actuals: [ActualRecord],
        inside span: TimeSpan,
        homePoint: GeoPoint?,
        maximumSampleGap: TimeInterval,
        authoritativeSleepSpans: [TimeSpan] = [],
        asOf: Date = .now,
        createdAt: Date = .now
    ) -> [ActualRecord] {
        // 집이 등록돼 있어도 보조 조건 3개(집 반경·어두움·충전)를 모두 요구하면
        // 충전 없이 자거나 화면 꺼짐으로 밝기(어두움)가 미상일 때 절대 성립하지
        // 않는다. 실기기 로그에서 워치리스 수면이 매 윈도 conditions_or_continuity_not_met
        // 로 전량 탈락한 원인이라 2개로 낮춘다. 핵심 조건(화면 꺼짐·30분 무사용·
        // 이동 없음)은 그대로 유지된다.
        let configuration = SleepInferenceConfiguration(
            minimumSupportingConditions: 2
        )
        let ordered = readings
            .filter {
                RouteTimelineTimestamp.isValid($0.timestamp)
                    && $0.sourceDevice != .appleWatch
                    && span.contains($0.timestamp)
                    && $0.timestamp <= asOf
            }
            .sorted { $0.timestamp < $1.timestamp }
        guard ordered.count >= 2 else { return [] }

        var runs: [[SleepRuleSample]] = []
        var inactivityStart: Date?
        var previous: SensorReading?
        for reading in ordered {
            if let previous,
               reading.timestamp.timeIntervalSince(previous.timestamp)
                    > max(maximumSampleGap, 20 * 60) {
                runs.append([])
                inactivityStart = nil
            }
            let moved = phoneMoved(reading, after: previous)
            let inactive = !moved && isInactive(reading)
            if inactive {
                inactivityStart = inactivityStart ?? reading.timestamp
            } else {
                inactivityStart = nil
            }
            let distance = homePoint.flatMap { home in
                reading.point.map { distanceMeters($0, home) }
            }
            let ruleSample = SleepRuleSample(
                timestamp: reading.timestamp,
                screenIsOn: reading.screenIsOn,
                inactivityDuration: inactivityStart.map {
                    reading.timestamp.timeIntervalSince($0)
                } ?? 0,
                phoneMoved: moved,
                distanceFromHomeMeters: distance,
                // 화면이 꺼져 있으면 밝기 표본이 없어 nil 이 된다. 이때 어두움을
                // '미상'으로 두면 보조 조건에서 빠져 무충전 취침이 절대 성립하지
                // 않았다. 화면 꺼짐 자체를 어두움 근거로 인정한다(밝기 값이 있으면
                // 그대로 판정).
                ambientIsDark: reading.screenBrightness.map { $0 <= 0.25 }
                    ?? (reading.screenIsOn == false ? true : nil),
                isCharging: reading.powerState?.isCharging == true,
                userWakeActivity: reading.screenIsOn == true
                    || moved
                    || (reading.stepCount ?? 0) > 0
            )
            if ruleSample.userWakeActivity,
               runs.last?.isEmpty == false {
                runs.append([])
            }
            if runs.isEmpty {
                runs.append([ruleSample])
            } else {
                runs[runs.count - 1].append(ruleSample)
            }
            previous = reading
        }

        let blocked = actuals.compactMap { actual -> TimeSpan? in
            guard actual.source == .appUsage
                    || AutomaticRecordTimelineEngine.isConfirmedWorkout(actual)
                    || (actual.source == .healthKit
                        && AutomaticRecordTimelineEngine.isSleep(actual))
                    || (actual.source == .appleWatch
                        && AutomaticRecordTimelineEngine.isSleep(actual)) else {
                return nil
            }
            return actual.span(asOf: asOf).intersection(with: span)
        } + authoritativeSleepSpans.compactMap { $0.intersection(with: span) }
        let engine = SleepInferenceEngine(configuration: configuration)
        return runs.compactMap { samples in
            let result = engine.infer(samples)
            guard result.state == .asleep,
                  let provenance = result.provenance,
                  let candidate = TimeSpan(
                      start: provenance.span.start,
                      end: provenance.span.end
                  ).intersection(with: span),
                  candidate.duration >= configuration.persistenceDuration,
                  !blocked.contains(where: { $0.intersection(with: candidate) != nil }) else {
                return nil
            }
            return ActualRecord(
                id: ActivityStableID.uuid(
                    seed: "\(strictSleepModelVersion)|\(candidate.start.timeIntervalSince1970)|\(candidate.end.timeIntervalSince1970)"
                ),
                planID: nil,
                title: "수면",
                categoryID: "sleep",
                startedAt: candidate.start,
                endedAt: candidate.end,
                source: .motion,
                confidence: ConfidenceLevel(score: provenance.confidence),
                createdAt: createdAt,
                behavior: "sleep-rule",
                evidence: unique(provenance.evidence + ["모든 수면 조건 충족"]),
                modelVersion: strictSleepModelVersion
            )
        }
    }

    private static func isSupportingReading(_ reading: SensorReading) -> Bool {
        reading.locationFixQuality == .approximate || !reading.gpsAvailable
    }

    private static func activityPlaceKind(
        for kind: FrequentPlaceKind?
    ) -> ActivityPlaceKind? {
        switch kind {
        case .home: .home
        case .company: .workplace
        case .school, .academy: .school
        case .restaurant: .restaurant
        case .hobby, .exercise, .custom, nil: nil
        }
    }

    private static func activityPOIKind(for name: String) -> ActivityPlaceKind? {
        let value = name.localizedLowercase
        if ["식당", "음식점", "레스토랑", "restaurant", "mcdonald", "맥도날드", "치킨"]
            .contains(where: value.contains) {
            return .restaurant
        }
        if ["회사", "오피스", "office", "business"].contains(where: value.contains) {
            return .workplace
        }
        if ["학교", "학원", "대학", "school", "academy", "university"]
            .contains(where: value.contains) {
            return .school
        }
        if ["집", "home"].contains(where: value.contains) {
            return .home
        }
        return nil
    }

    private static func confidenceScore(_ confidence: ConfidenceLevel) -> Double {
        switch confidence {
        case .low: 0.25
        case .medium: 0.60
        case .high: 0.90
        }
    }

    private static func trustLabel(_ provenance: ActivityDataProvenance) -> String {
        switch provenance.tier {
        case .groundTruth:
            return provenance.status == .userCorrected
                ? "Ground truth · 사용자 확인"
                : "Ground truth"
        case .supporting:
            return "보조 데이터"
        case .expected:
            switch provenance.status {
            case .automaticallyConfirmed:
                return "예상 데이터 · 자동확정"
            case .unresolved:
                return "예상 데이터 · 미확인"
            default:
                return "예상 데이터"
            }
        }
    }

    private static func markers(
        for provenance: ActivityDataProvenance
    ) -> [String] {
        [
            "data-tier:\(provenance.tier.rawValue)",
            "inference-status:\(provenance.status.rawValue)",
            "provenance:\(provenance.source)",
        ]
    }

    private static func isInactive(_ reading: SensorReading) -> Bool {
        guard (reading.stepCount ?? 0) <= 0 else { return false }
        switch reading.motion {
        case .stationary:
            return true
        case .unknown:
            guard let summary = reading.deviceMotionSummary else { return true }
            return summary.userAccelerationStandardDeviationG <= 0.01
                && summary.meanRotationRateRadiansPerSecond <= 0.03
        case .walking, .running, .cycling, .automotive:
            return false
        }
    }

    private static func phoneMoved(
        _ reading: SensorReading,
        after _: SensorReading?
    ) -> Bool {
        if reading.motion.isMovement || (reading.stepCount ?? 0) > 0 {
            return true
        }
        guard reading.motion == .unknown,
              let summary = reading.deviceMotionSummary else {
            return false
        }
        return summary.userAccelerationStandardDeviationG > 0.01
            || summary.meanRotationRateRadiansPerSecond > 0.03
    }

    static func forEachRejectedQualityDecision(
        _ decisions: [TaptionScalarQualityDecision],
        cancellationCheck: () throws -> Void,
        apply: (TaptionScalarQualityDecision) throws -> Void
    ) rethrows {
        for (index, decision) in decisions.enumerated() {
            if index.isMultiple(of: 512) { try cancellationCheck() }
            guard decision.reason != nil else { continue }
            try apply(decision)
        }
    }

    static func qualityProjection(
        from readings: [SensorReading]
    ) -> TaptionSensorQualityProjection {
        qualityProjection(from: readings, cancellationCheck: {})
    }

    static func qualityProjection(
        from readings: [SensorReading],
        cancellationCheck: () throws -> Void
    ) rethrows -> TaptionSensorQualityProjection {
        try cancellationCheck()
        var operationCount = 0
        var projected: [SensorReading] = []
        projected.reserveCapacity(readings.count)
        for reading in readings {
            try recordWork(&operationCount, cancellationCheck: cancellationCheck)
            if RouteTimelineTimestamp.isValid(reading.timestamp) {
                projected.append(reading)
            }
        }
        projected = try cancellableSort(
            projected,
            operationCount: &operationCount,
            cancellationCheck: cancellationCheck
        ) {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.id.uuidString < $1.id.uuidString
        }
        var rejectionCounts: [String: Int] = [:]

        func apply(
            _ keyPath: WritableKeyPath<SensorReading, Double?>,
            label: String,
            range: ClosedRange<Double>,
            minimumDeviation: Double
        ) throws {
            try cancellationCheck()
            let filter = TaptionRobustScalarFilter(configuration: .init(
                physicalRange: range,
                minimumAbsoluteDeviation: minimumDeviation
            ))
            var values: [Double?] = []
            values.reserveCapacity(projected.count)
            for (index, reading) in projected.enumerated() {
                if index.isMultiple(of: 256) { try cancellationCheck() }
                values.append(reading[keyPath: keyPath])
            }
            let decisions = try filter.decisions(
                for: values,
                cancellationCheck: cancellationCheck
            )
            try forEachRejectedQualityDecision(
                decisions,
                cancellationCheck: cancellationCheck
            ) { decision in
                projected[decision.index][keyPath: keyPath] = nil
                let reason = decision.reason?.rawValue ?? "unknown"
                rejectionCounts["\(label).\(reason)", default: 0] += 1
            }
        }

        try apply(\.speedMetersPerSecond, label: "speed", range: 0...120, minimumDeviation: 0.25)
        try apply(\.speedAccuracyMetersPerSecond, label: "speedAccuracy", range: 0...60, minimumDeviation: 0.25)
        try apply(\.courseDegrees, label: "course", range: 0...360, minimumDeviation: 1)
        try apply(\.courseAccuracyDegrees, label: "courseAccuracy", range: 0...180, minimumDeviation: 1)
        try apply(\.relativeAltitudeMeters, label: "relativeAltitude", range: -12_000...12_000, minimumDeviation: 0.5)
        try apply(\.pressureKilopascals, label: "pressure", range: 30...120, minimumDeviation: 0.05)
        try apply(\.currentPaceSecondsPerMeter, label: "currentPace", range: 0.05...3_600, minimumDeviation: 0.05)
        try apply(\.currentCadenceStepsPerSecond, label: "cadence", range: 0...5, minimumDeviation: 0.05)
        try apply(\.averageActivePaceSecondsPerMeter, label: "activePace", range: 0.05...3_600, minimumDeviation: 0.05)
        try apply(\.watchAccelerationStandardDeviationG, label: "accelerationStd", range: 0...20, minimumDeviation: 0.02)
        try apply(\.watchAccelerationMeanJerkGPerSecond, label: "accelerationJerk", range: 0...100, minimumDeviation: 0.05)
        try apply(\.behaviorConfidenceScore, label: "behaviorConfidence", range: 0...1, minimumDeviation: 0.02)

        try cancellationCheck()
        let route = try TaptionRouteEngineAdapter.prepareFilteredReadings(
            from: projected,
            includeLowConfidenceBoundaries: false,
            cancellationCheck: cancellationCheck
        )
        try cancellationCheck()
        return TaptionSensorQualityProjection(
            readings: projected,
            routeReadings: route.readings,
            rejectionCounts: route.ghostExcursionCount > 0 ? rejectionCounts.merging(["location.ghostExcursion": route.ghostExcursionCount], uniquingKeysWith: +) : rejectionCounts, // 유령 체류 수도 거부 근거로 센다 (CLN1110A01)
            impossibleLocationCount: route.impossibleLocationCount,
            innovationOutlierCount: route.innovationOutlierCount
        )
    }

    static func classify(
        readings: [SensorReading],
        travel: [TravelSegment] = [],
        corrections: [UUID: ActivityCorrection] = [:],
        actuals: [ActualRecord] = []
    ) -> TaptionActivityClassificationResult {
        do {
            return try classify(
                readings: readings,
                travel: travel,
                corrections: corrections,
                actuals: actuals,
                cancellationCheck: {}
            )
        } catch {
            preconditionFailure("Unexpected activity classification cancellation: \(error)")
        }
    }

    static func classify(
        readings: [SensorReading],
        travel: [TravelSegment] = [],
        corrections: [UUID: ActivityCorrection] = [:],
        actuals: [ActualRecord] = [],
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) throws -> TaptionActivityClassificationResult {
        try cancellationCheck()
        let overrides = activityOverrides(corrections: corrections, actuals: actuals)
        try cancellationCheck()
        let classifiedEvidence = try evidence(
            from: readings,
            travel: travel,
            cancellationCheck: cancellationCheck
        )
        let projection = try ActivityClassificationProjection(
            engine: engine,
            evidence: classifiedEvidence,
            overrides: overrides,
            cancellationCheck: cancellationCheck
        )
        return TaptionActivityClassificationResult(state: projection.state)
    }

    static func evidence(
        from readings: [SensorReading],
        travel: [TravelSegment] = []
    ) -> [ActivitySensorEvidence] {
        do {
            return try evidence(from: readings, travel: travel, cancellationCheck: {})
        } catch {
            preconditionFailure("Unexpected activity evidence cancellation: \(error)")
        }
    }

    static func evidence(
        from readings: [SensorReading],
        travel: [TravelSegment],
        cancellationCheck: () throws -> Void
    ) throws -> [ActivitySensorEvidence] {
        try cancellationCheck()
        let travelIndices = try matchingTravelIndices(
            for: readings,
            travel: travel,
            cancellationCheck: cancellationCheck
        ).indices
        var result: [ActivitySensorEvidence] = []
        result.reserveCapacity(readings.count)
        var operationCount = 0
        for (readingIndex, reading) in readings.enumerated() {
            try recordWork(&operationCount, cancellationCheck: cancellationCheck)
            let travelSegment = travelIndices[readingIndex].map { travel[$0] }
            let detailHint = travelSegment.map(detailID(for:))
            let accuracy = reading.point?.horizontalAccuracy
            let hasValidCoordinate = reading.point.map { point in
                point.latitude.isFinite
                    && point.longitude.isFinite
                    && (-90...90).contains(point.latitude)
                    && (-180...180).contains(point.longitude)
            } == true
            let hasValidatedPreciseFix = reading.gpsAvailable
                && hasValidCoordinate
                && accuracy.map { $0.isFinite && (0...150).contains($0) } == true
                && reading.locationFixQuality != .approximate
            result.append(ActivitySensorEvidence(
                id: reading.id,
                timestamp: reading.timestamp,
                motion: motion(for: reading.motion),
                speedMetersPerSecond: reading.speedMetersPerSecond,
                horizontalAccuracyMeters: accuracy,
                isPreciseLocation: hasValidatedPreciseFix,
                stepCount: reading.stepCount,
                screenIsOn: reading.screenIsOn,
                screenBrightness: reading.screenBrightness,
                categoryHint: travelSegment == nil ? nil : "movement",
                detailHint: detailHint,
                behaviorHint: behaviorHint(
                    for: reading.behavior,
                    hasMovementAlgorithmResult: travelSegment != nil
                ),
                confidence: reading.behaviorConfidenceScore,
                evidence: reading.behaviorEvidence ?? [],
                sequence: reading.sequence,
                source: reading.sourceDevice == .appleWatch ? .appleWatch : .iPhone
            ))
        }
        try cancellationCheck()
        return result
    }
}
