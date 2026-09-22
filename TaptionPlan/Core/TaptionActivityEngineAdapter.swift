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
    static let inferredGapModelVersion = "activity-gap-viterbi-v1"
    static let classifiedActivityModelVersion = "activity-classifier-v1"
    static let strictSleepModelVersion = "sleep-rule-v1"

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
            modelVersion: "place-activity-v1"
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
        let configuration = SleepInferenceConfiguration(
            minimumSupportingConditions: homePoint == nil ? 2 : 3
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
                ambientIsDark: reading.screenBrightness.map { $0 <= 0.25 },
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
        let routeReadings = try TaptionRouteEngineAdapter.filteredReadings(
            from: projected,
            includeLowConfidenceBoundaries: false,
            cancellationCheck: cancellationCheck
        )
        try cancellationCheck()
        return TaptionSensorQualityProjection(
            readings: projected,
            routeReadings: routeReadings,
            rejectionCounts: rejectionCounts
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

    static func matchingTravelIndices(
        for readings: [SensorReading],
        travel: [TravelSegment]
    ) -> (indices: [Int?], operationCount: Int) {
        do {
            return try matchingTravelIndices(
                for: readings,
                travel: travel,
                cancellationCheck: {}
            )
        } catch {
            preconditionFailure("Unexpected travel indexing cancellation: \(error)")
        }
    }

    static func matchingTravelIndices(
        for readings: [SensorReading],
        travel: [TravelSegment],
        cancellationCheck: () throws -> Void
    ) throws -> (indices: [Int?], operationCount: Int) {
        try cancellationCheck()
        var operationCount = 0
        guard !readings.isEmpty else { return ([], operationCount) }
        if travel.isEmpty {
            var matches: [Int?] = []
            matches.reserveCapacity(readings.count)
            for _ in readings.indices {
                try recordWork(&operationCount, cancellationCheck: cancellationCheck)
                matches.append(nil)
            }
            try cancellationCheck()
            return (matches, operationCount)
        }

        var orderedReadings: [Int] = []
        orderedReadings.reserveCapacity(readings.count)
        for index in readings.indices {
            try recordWork(&operationCount, cancellationCheck: cancellationCheck)
            if !readings[index].timestamp.timeIntervalSinceReferenceDate.isNaN {
                orderedReadings.append(index)
            }
        }
        orderedReadings = try cancellableSort(
            orderedReadings,
            operationCount: &operationCount,
            cancellationCheck: cancellationCheck
        ) { lhs, rhs in
            let lhsTimestamp = readings[lhs].timestamp
            let rhsTimestamp = readings[rhs].timestamp
            if lhsTimestamp != rhsTimestamp { return lhsTimestamp < rhsTimestamp }
            return lhs < rhs
        }

        // Date's <= treats NaN as true, so normalize NaN interval edges to infinities.
        let negativeInfinity = Date(timeIntervalSinceReferenceDate: -.infinity)
        let positiveInfinity = Date(timeIntervalSinceReferenceDate: .infinity)
        var intervalStarts: [Date] = []
        var intervalEnds: [Date] = []
        intervalStarts.reserveCapacity(travel.count)
        intervalEnds.reserveCapacity(travel.count)
        for segment in travel {
            try recordWork(&operationCount, cancellationCheck: cancellationCheck)
            intervalStarts.append(
                segment.span.start.timeIntervalSinceReferenceDate.isNaN
                    ? negativeInfinity
                    : segment.span.start
            )
            intervalEnds.append(
                segment.span.end.timeIntervalSinceReferenceDate.isNaN
                    ? positiveInfinity
                    : segment.span.end
            )
        }
        var travelIndices: [Int] = []
        travelIndices.reserveCapacity(travel.count)
        for index in travel.indices {
            try recordWork(&operationCount, cancellationCheck: cancellationCheck)
            travelIndices.append(index)
        }
        let orderedTravel = try cancellableSort(
            travelIndices,
            operationCount: &operationCount,
            cancellationCheck: cancellationCheck
        ) { lhs, rhs in
            if intervalStarts[lhs] != intervalStarts[rhs] {
                return intervalStarts[lhs] < intervalStarts[rhs]
            }
            return lhs < rhs
        }

        var matches: [Int?] = []
        matches.reserveCapacity(readings.count)
        for _ in readings.indices {
            try recordWork(&operationCount, cancellationCheck: cancellationCheck)
            matches.append(nil)
        }
        // A NaN reading satisfied both original span comparisons for every interval.
        for index in readings.indices {
            try recordWork(&operationCount, cancellationCheck: cancellationCheck)
            if readings[index].timestamp.timeIntervalSinceReferenceDate.isNaN {
                matches[index] = 0
            }
        }
        guard !orderedReadings.isEmpty else {
            try cancellationCheck()
            return (matches, operationCount)
        }

        var active = TravelMatchHeap()
        var nextTravel = 0

        for readingIndex in orderedReadings {
            try recordWork(&operationCount, cancellationCheck: cancellationCheck)
            let timestamp = readings[readingIndex].timestamp
            while nextTravel < orderedTravel.count {
                try recordWork(&operationCount, cancellationCheck: cancellationCheck)
                let travelIndex = orderedTravel[nextTravel]
                guard intervalStarts[travelIndex] <= timestamp else { break }
                try active.insert(
                    travelIndex,
                    operationCount: &operationCount,
                    cancellationCheck: cancellationCheck
                )
                nextTravel += 1
            }
            while let first = active.minimum {
                try recordWork(&operationCount, cancellationCheck: cancellationCheck)
                guard intervalEnds[first] < timestamp else { break }
                try active.removeMinimum(
                    operationCount: &operationCount,
                    cancellationCheck: cancellationCheck
                )
            }
            matches[readingIndex] = active.minimum
            try recordWork(&operationCount, cancellationCheck: cancellationCheck)
        }
        try cancellationCheck()
        return (matches, operationCount)
    }

    private static func recordWork(
        _ operationCount: inout Int,
        cancellationCheck: () throws -> Void
    ) rethrows {
        operationCount += 1
        if operationCount == 1 || operationCount.isMultiple(of: 256) {
            try cancellationCheck()
        }
    }

    private static func cancellableSort<Element>(
        _ values: [Element],
        operationCount: inout Int,
        cancellationCheck: () throws -> Void,
        by areInIncreasingOrder: (Element, Element) -> Bool
    ) rethrows -> [Element] {
        guard values.count > 1 else {
            try cancellationCheck()
            return values
        }

        var source = values
        var destination = values
        var width = 1
        while width < values.count {
            var lower = 0
            while lower < values.count {
                let middle = min(lower + width, values.count)
                let upper = min(middle + width, values.count)
                var left = lower
                var right = middle
                var output = lower
                while output < upper {
                    try recordWork(&operationCount, cancellationCheck: cancellationCheck)
                    if left < middle,
                       right >= upper || !areInIncreasingOrder(source[right], source[left]) {
                        destination[output] = source[left]
                        left += 1
                    } else {
                        destination[output] = source[right]
                        right += 1
                    }
                    output += 1
                }
                lower = upper
            }
            swap(&source, &destination)
            width = width > values.count / 2 ? values.count : width * 2
        }
        try cancellationCheck()
        return source
    }

    private struct TravelMatchHeap {
        private var indices: [Int] = []

        var minimum: Int? { indices.first }

        mutating func insert(
            _ index: Int,
            operationCount: inout Int,
            cancellationCheck: () throws -> Void
        ) rethrows {
            indices.append(index)
            var child = indices.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                try TaptionActivityEngineAdapter.recordWork(
                    &operationCount,
                    cancellationCheck: cancellationCheck
                )
                guard indices[parent] > indices[child] else { break }
                indices.swapAt(parent, child)
                child = parent
            }
        }

        mutating func removeMinimum(
            operationCount: inout Int,
            cancellationCheck: () throws -> Void
        ) rethrows {
            guard !indices.isEmpty else { return }
            let last = indices.removeLast()
            guard !indices.isEmpty else { return }
            indices[0] = last

            var parent = 0
            while true {
                let left = parent * 2 + 1
                guard left < indices.count else { break }
                let right = left + 1
                var child = left
                if right < indices.count {
                    try TaptionActivityEngineAdapter.recordWork(
                        &operationCount,
                        cancellationCheck: cancellationCheck
                    )
                    if indices[right] < indices[left] { child = right }
                }
                try TaptionActivityEngineAdapter.recordWork(
                    &operationCount,
                    cancellationCheck: cancellationCheck
                )
                guard indices[parent] > indices[child] else { break }
                indices.swapAt(parent, child)
                parent = child
            }
        }
    }

    static func inferredGapActuals(
        readings: [SensorReading],
        travel: [TravelSegment],
        actuals: [ActualRecord],
        inside span: TimeSpan,
        createdAt: Date = .now
    ) -> [ActualRecord] {
        let protected = actuals.filter { $0.modelVersion != inferredGapModelVersion }
        let gaps = ReviewCoverageEngine.unconfirmedRecords(
            actuals: protected,
            in: [span],
            asOf: span.end
        )
        guard !gaps.isEmpty else { return [] }
        let allEvidence = evidence(from: readings, travel: travel)
        let gapEngine = ActivityGapInferenceEngine()
        return gaps.flatMap { gap -> [ActualRecord] in
            let gapSpan = TimeSpan(
                start: gap.startedAt,
                end: gap.endedAt ?? gap.startedAt
            )
            guard gapSpan.duration > 0 else { return [] }
            let preceding = protected
                .filter { ($0.endedAt ?? $0.startedAt) <= gapSpan.start }
                .max { ($0.endedAt ?? $0.startedAt) < ($1.endedAt ?? $1.startedAt) }
            let following = protected
                .filter { $0.startedAt >= gapSpan.end }
                .min { $0.startedAt < $1.startedAt }
            let inferred = gapEngine.infer(.init(
                span: .init(start: gapSpan.start, end: gapSpan.end),
                evidence: allEvidence,
                precedingAnchor: preceding.map(activityGapAnchor),
                followingAnchor: following.map(activityGapAnchor)
            ))
            return inferred.map { segment in
                ActualRecord(
                    id: segment.id,
                    planID: nil,
                    title: engine.taxonomy.detail(for: segment.detailID)?.title
                        ?? engine.taxonomy.major(for: segment.majorCategoryID)?.title
                        ?? "활동",
                    categoryID: segment.majorCategoryID,
                    startedAt: segment.span.start,
                    endedAt: segment.span.end,
                    source: .motion,
                    confidence: ConfidenceLevel(score: segment.confidence),
                    createdAt: createdAt,
                    behavior: segment.behavior,
                    evidence: segment.provenance,
                    modelVersion: inferredGapModelVersion
                )
            }
        }
    }

    static func confirmedSleepOverrides(
        corrections: [UUID: ActivityCorrection],
        actuals: [ActualRecord]
    ) -> [ActivityClassificationOverride] {
        activityOverrides(corrections: corrections, actuals: actuals)
            .filter(\.isSleep)
    }

    static func activityOverrides(
        corrections: [UUID: ActivityCorrection],
        actuals: [ActualRecord]
    ) -> [ActivityClassificationOverride] {
        actuals.compactMap { actual -> ActivityClassificationOverride? in
            let correction = correction(for: actual, corrections: corrections)
            guard correction != nil || actual.manuallyCorrected || actual.isClassificationLocked else {
                return nil
            }
            let start = correction?.startedAt ?? actual.startedAt
            let fallbackEnd = actual.endedAt ?? start.addingTimeInterval(1)
            let end = max(start, correction?.endedAt ?? fallbackEnd)
            let categoryID = correction?.categoryID ?? actual.categoryID
            let resolvedDetailID = correction.map { self.detailID(for: $0) }
                ?? engine.taxonomy.detail(majorID: categoryID, behavior: actual.behavior ?? "")?.id
                ?? engine.taxonomy.major(for: categoryID)?.details.first?.id
            return ActivityClassificationOverride(
                id: actual.id,
                span: ActivityTimeSpan(start: start, end: end),
                majorCategoryID: categoryID,
                detailID: resolvedDetailID,
                title: correction?.title ?? actual.title,
                behavior: correction?.behavior ?? actual.behavior,
                updatedAt: actual.createdAt,
                isLocked: actual.manuallyCorrected || correction != nil || actual.isClassificationLocked,
                isUserConfirmed: correction != nil || actual.manuallyCorrected
            )
        }
    }

    static func applyingConfirmedSleepOverrides(
        to actuals: [ActualRecord],
        corrections: [UUID: ActivityCorrection]
    ) -> [ActualRecord] {
        applying(
            confirmedSleepOverrides(corrections: corrections, actuals: actuals),
            to: actuals
        )
    }

    static func confirmedSleepOverrides(
        _ spans: [TimeSpan]
    ) -> [ActivityClassificationOverride] {
        normalizedSleepSpans(spans).map { span in
            ActivityClassificationOverride(
                id: ActivityStableID.uuid(
                    seed: "confirmed-sleep|\(span.start.timeIntervalSince1970)|\(span.end.timeIntervalSince1970)"
                ),
                span: ActivityTimeSpan(start: span.start, end: span.end),
                majorCategoryID: "sleep",
                detailID: "sleep.core",
                title: "수면",
                behavior: "core",
                updatedAt: span.start
            )
        }
    }

    static func confirmedSleepActuals(
        _ spans: [TimeSpan],
        createdAt: Date = .now
    ) -> [ActualRecord] {
        normalizedSleepSpans(spans).map { makeConfirmedSleepActual($0, createdAt: createdAt) }
    }

    static func migratedConfirmedSleepSpans(
        existing: [TimeSpan],
        corrections: [UUID: ActivityCorrection],
        actuals: [ActualRecord]
    ) -> [TimeSpan] {
        let current = normalizedSleepSpans(existing)
        guard current.isEmpty else { return current }

        var candidates = corrections.values.compactMap { correction -> TimeSpan? in
            guard correction.categoryID == "sleep",
                  let start = correction.startedAt,
                  let end = correction.endedAt,
                  end > start else { return nil }
            return TimeSpan(start: start, end: end)
        }
        candidates += actuals.compactMap { actual -> TimeSpan? in
            guard actual.categoryID == "sleep",
                  actual.manuallyCorrected,
                  let end = actual.endedAt,
                  end > actual.startedAt else { return nil }
            return TimeSpan(start: actual.startedAt, end: end)
        }
        return normalizedSleepSpans(candidates)
    }

    static func applyingConfirmedSleepSpans(
        _ spans: [TimeSpan],
        to actuals: [ActualRecord],
        createdAt: Date = .now
    ) -> [ActualRecord] {
        let normalized = normalizedSleepSpans(spans)
        let withoutPreviousConfirmedSleep = actuals.filter {
            $0.modelVersion != confirmedSleepModelVersion
        }
        guard !normalized.isEmpty else { return withoutPreviousConfirmedSleep }
        let cut = applying(
            confirmedSleepOverrides(normalized),
            to: withoutPreviousConfirmedSleep
        )
        let preserved = cut.filter { actual in
            guard actual.categoryID == "sleep" else { return true }
            let actualSpan = TimeSpan(
                start: actual.startedAt,
                end: actual.endedAt ?? actual.startedAt.addingTimeInterval(1)
            )
            return !normalized.contains { actualSpan.intersection(with: $0) != nil }
        }
        let freshSleep = normalized.map { span in
            let existingCreatedAt = actuals.first(where: {
                $0.modelVersion == confirmedSleepModelVersion
                    && $0.startedAt == span.start
                    && $0.endedAt == span.end
            })?.createdAt
            return makeConfirmedSleepActual(
                span,
                createdAt: existingCreatedAt ?? createdAt
            )
        }
        return (preserved + freshSleep).sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    static func applying(
        _ overrides: [ActivityClassificationOverride],
        to actuals: [ActualRecord]
    ) -> [ActualRecord] {
        actuals.flatMap { actual -> [ActualRecord] in
            guard actual.source != .manual else { return [actual] }
            let originalSpan = TimeSpan(
                start: actual.startedAt,
                end: actual.endedAt ?? actual.startedAt.addingTimeInterval(1)
            )
            let relevant = overrides.filter { override in
                let span = TimeSpan(start: override.span.start, end: override.span.end)
                return originalSpan.intersection(with: span) != nil
            }
            guard !relevant.isEmpty else { return [actual] }
            var cuts = Set([originalSpan.start, originalSpan.end])
            for override in relevant {
                let span = TimeSpan(start: override.span.start, end: override.span.end)
                guard let intersection = originalSpan.intersection(with: span) else { continue }
                cuts.insert(intersection.start)
                cuts.insert(intersection.end)
            }
            let points = cuts.sorted()
            guard points.count >= 2 else { return [actual] }
            return points.indices.dropLast().compactMap { index -> ActualRecord? in
                let start = points[index]
                let end = points[index + 1]
                guard start < end else { return nil }
                let midpoint = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
                let selected = relevant
                    .filter { $0.span.start <= midpoint && midpoint < $0.span.end }
                    .sorted { lhs, rhs in
                        if lhs.isSleep != rhs.isSleep { return lhs.isSleep }
                        return lhs.updatedAt > rhs.updatedAt
                    }
                    .first
                var value = actual
                value.id = stableRecordID(
                    originalID: actual.id,
                    start: start,
                    end: end,
                    override: selected
                )
                value.startedAt = start
                value.endedAt = end
                if let selected {
                    value.title = selected.title ?? value.title
                    value.categoryID = selected.majorCategoryID
                    value.behavior = selected.behavior ?? selected.detailID
                    value.confidence = .high
                    value.evidence = unique(value.evidence + ["사용자 확인"])
                    value.manuallyCorrected = true
                }
                return value
            }
        }
    }

    static func makeStableManualActual(
        span: TimeSpan,
        option: ActivityCorrectionOption,
        createdAt: Date = .now
    ) -> ActualRecord {
        let id = ActivityStableID.uuid(
            seed: [
                "manual",
                String(span.start.timeIntervalSince1970),
                String(span.end.timeIntervalSince1970),
                option.categoryID,
                option.behavior ?? "",
                option.title
            ].joined(separator: "|")
        )
        return ActualRecord(
            id: id,
            planID: nil,
            title: option.title,
            categoryID: option.categoryID,
            startedAt: span.start,
            endedAt: span.end,
            source: .manual,
            confidence: .high,
            createdAt: createdAt,
            behavior: option.behavior,
            evidence: ["사용자 입력"],
            manuallyCorrected: true
        )
    }

    private static func correction(
        for actual: ActualRecord,
        corrections: [UUID: ActivityCorrection]
    ) -> ActivityCorrection? {
        if let direct = corrections[actual.id] { return direct }
        return corrections.values.sorted { lhs, rhs in
            let lhsStart = lhs.startedAt ?? .distantPast
            let rhsStart = rhs.startedAt ?? .distantPast
            if lhsStart != rhsStart { return lhsStart < rhsStart }
            return (lhs.endedAt ?? .distantPast) < (rhs.endedAt ?? .distantPast)
        }.first { correction in
            guard correction.startedAt != nil || correction.endedAt != nil else { return false }
            let correctionStart = correction.startedAt ?? actual.startedAt
            let correctionEnd = correction.endedAt
                ?? actual.endedAt
                ?? correctionStart.addingTimeInterval(1)
            let actualSpan = TimeSpan(
                start: actual.startedAt,
                end: actual.endedAt ?? actual.startedAt.addingTimeInterval(1)
            )
            return actualSpan.intersection(
                with: TimeSpan(start: correctionStart, end: correctionEnd)
            ) != nil
        }
    }

    private static func detailID(for correction: ActivityCorrection) -> String {
        if let behavior = correction.behavior {
            if correction.categoryID == "sleep" { return "sleep.\(behavior)" }
            if let detail = engine.taxonomy.detail(majorID: correction.categoryID, behavior: behavior) {
                return detail.id
            }
        }
        return engine.taxonomy.major(for: correction.categoryID)?.details.first?.id
            ?? "\(correction.categoryID).automatic"
    }

    private static func detailID(for segment: TravelSegment) -> String {
        switch segment.mode {
        case .walking: return "movement.walking"
        case .running: return "movement.running"
        case .cycling: return "movement.cycling"
        case .subway: return "movement.subway"
        case .bus: return "movement.bus"
        case .car: return "movement.car"
        case .taxi: return "movement.car"
        case .train: return "movement.subway"
        case .ship: return "movement.ship"
        case .airplane: return "movement.airplane"
        }
    }

    private static func activityGapAnchor(
        _ actual: ActualRecord
    ) -> ActivityGapAnchor {
        let behavior = actual.behavior
            ?? engine.taxonomy.major(for: actual.categoryID)?.details.first?.behavior
            ?? actual.categoryID
        let detail = engine.taxonomy.detail(
            majorID: actual.categoryID,
            behavior: behavior
        )?.id ?? engine.taxonomy.major(for: actual.categoryID)?.details.first?.id
            ?? "\(actual.categoryID).automatic"
        return ActivityGapAnchor(
            majorCategoryID: actual.categoryID,
            detailID: detail,
            behavior: behavior
        )
    }

    private static func motion(for value: MotionKind) -> ActivityMotion {
        switch value {
        case .stationary: return .stationary
        case .walking: return .walking
        case .running: return .running
        case .cycling: return .cycling
        case .automotive: return .automotive
        case .unknown: return .unknown
        }
    }

    private static func behaviorHint(
        for value: String?,
        hasMovementAlgorithmResult: Bool
    ) -> String? {
        guard let value else { return nil }
        let normalized = value.localizedLowercase
        let movementBehaviors = [
            "walking", "running", "cycling", "automotive", "subway",
            "publictransit", "stairsup", "stairsdown", "elevator",
            "걷기", "걷", "달리기", "자전거", "자동차", "지하철",
            "대중교통", "계단", "엘리베이터"
        ]
        if movementBehaviors.contains(where: { normalized.contains($0) }) {
            return hasMovementAlgorithmResult ? value : nil
        }
        return value
    }

    private static func stableRecordID(
        originalID: UUID,
        start: Date,
        end: Date,
        override: ActivityClassificationOverride?
    ) -> UUID {
        guard start != end else { return originalID }
        let seed = [
            originalID.uuidString,
            String(start.timeIntervalSince1970),
            String(end.timeIntervalSince1970),
            override?.majorCategoryID ?? "original",
            override?.detailID ?? ""
        ].joined(separator: "|")
        return ActivityStableID.uuid(seed: seed)
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func normalizedSleepSpans(_ spans: [TimeSpan]) -> [TimeSpan] {
        let ordered = spans
            .filter { $0.duration > 0 }
            .sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                return $0.end < $1.end
            }
        var result: [TimeSpan] = []
        for span in ordered {
            guard let previous = result.last, span.start <= previous.end else {
                result.append(span)
                continue
            }
            result[result.count - 1] = TimeSpan(
                start: previous.start,
                end: max(previous.end, span.end)
            )
        }
        return result
    }

    private static func makeConfirmedSleepActual(
        _ span: TimeSpan,
        createdAt: Date
    ) -> ActualRecord {
        let id = ActivityStableID.uuid(
            seed: "confirmed-sleep|\(span.start.timeIntervalSince1970)|\(span.end.timeIntervalSince1970)"
        )
        return ActualRecord(
            id: id,
            planID: nil,
            title: "수면",
            categoryID: "sleep",
            startedAt: span.start,
            endedAt: span.end,
            source: .manual,
            confidence: .high,
            createdAt: createdAt,
            behavior: "core",
            evidence: ["사용자 확인 수면"],
            modelVersion: confirmedSleepModelVersion,
            manuallyCorrected: true
        )
    }
}

private struct ActivityClassificationIntervalIndex<Value> {
    private struct Entry {
        let value: Value
        let span: TimeSpan
        let inputOrder: Int
    }

    private let entries: [Entry]
    private let prefixMaximumEnds: [Date]

    init(
        _ values: [(inputOrder: Int, value: Value)],
        span: (Value) -> TimeSpan
    ) {
        entries = values
            .map { value in
                Entry(
                    value: value.value,
                    span: span(value.value),
                    inputOrder: value.inputOrder
                )
            }
            .sorted {
                if $0.span.start != $1.span.start {
                    return $0.span.start < $1.span.start
                }
                return $0.inputOrder < $1.inputOrder
            }

        var latestEnd = Date.distantPast
        prefixMaximumEnds = entries.map { entry in
            latestEnd = max(latestEnd, entry.span.end)
            return latestEnd
        }
    }

    func forEachCandidate(
        overlapping span: TimeSpan,
        inspectionCount: inout Int?,
        _ body: (Value, Int) -> Void
    ) {
        guard span.start < span.end, !entries.isEmpty else { return }

        var lower = 0
        var upper = prefixMaximumEnds.count
        while lower < upper {
            inspectionCount? += 1
            let middle = lower + (upper - lower) / 2
            if prefixMaximumEnds[middle] > span.start {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        let firstCandidate = lower

        upper = entries.count
        while lower < upper {
            inspectionCount? += 1
            let middle = lower + (upper - lower) / 2
            if entries[middle].span.start < span.end {
                lower = middle + 1
            } else {
                upper = middle
            }
        }

        for entry in entries[firstCandidate..<lower] {
            inspectionCount? += 1
            body(entry.value, entry.inputOrder)
        }
    }
}

/// Makes automatic major-category decisions durable without touching the
/// sensor archive. A refresh may produce a new span or more evidence, but a
/// stored automatic record keeps its previous category unless a registered
/// destination resolves an earlier unknown stay. Explicit activity corrections
/// remain the only user override.
enum ActivityClassificationLockEngine {
    static func lockingAutomaticClassifications(
        _ actuals: [ActualRecord]
    ) -> [ActualRecord] {
        lockingAutomaticClassifications(actuals, cancellationCheck: {})
    }

    static func lockingAutomaticClassifications(
        _ actuals: [ActualRecord],
        cancellationCheck: () throws -> Void
    ) rethrows -> [ActualRecord] {
        try cancellationCheck()
        var locked: [ActualRecord] = []
        locked.reserveCapacity(actuals.count)
        for (index, actual) in actuals.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            guard actual.source.usesAutomaticClassification else {
                locked.append(actual)
                continue
            }
            var value = actual
            value.isClassificationLocked = true
            locked.append(value)
        }
        try cancellationCheck()
        return locked
    }

    static func mergingLockedClassifications(
        existing: [ActualRecord],
        fresh: [ActualRecord],
        inside: TimeSpan
    ) -> [ActualRecord] {
        var inspectionCount: Int? = nil
        return mergingLockedClassifications(
            existing: existing,
            fresh: fresh,
            inside: inside,
            inspectionCount: &inspectionCount
        )
    }

    static func mergingLockedClassifications(
        existing: [ActualRecord],
        fresh: [ActualRecord],
        inside: TimeSpan,
        candidateInspectionCount: inout Int
    ) -> [ActualRecord] {
        var inspectionCount: Int? = candidateInspectionCount
        let result = mergingLockedClassifications(
            existing: existing,
            fresh: fresh,
            inside: inside,
            inspectionCount: &inspectionCount
        )
        candidateInspectionCount = inspectionCount ?? candidateInspectionCount
        return result
    }

    private static func mergingLockedClassifications(
        existing: [ActualRecord],
        fresh: [ActualRecord],
        inside: TimeSpan,
        inspectionCount: inout Int?
    ) -> [ActualRecord] {
        let locked = existing.filter { actual in
            actual.isClassificationLocked
                && actual.source.usesAutomaticClassification
                && actual.span(asOf: inside.end).intersection(with: inside) != nil
        }
        var groupedLocked: [String: [(inputOrder: Int, value: ActualRecord)]] = [:]
        for (inputOrder, actual) in locked.enumerated() {
            groupedLocked[actual.source.rawValue, default: []].append(
                (inputOrder, actual)
            )
        }
        let indexes = groupedLocked.mapValues { values in
            ActivityClassificationIntervalIndex(values, span: classificationSpan)
        }
        var matchedLockedIndices = Set<Int>()
        var merged = fresh.map { candidate in
            guard candidate.source.usesAutomaticClassification else {
                return candidate
            }
            var value = candidate
            value.isClassificationLocked = true
            var bestMatch: (record: ActualRecord, overlap: TimeInterval, inputOrder: Int)?
            indexes[candidate.source.rawValue]?.forEachCandidate(
                overlapping: classificationSpan(candidate),
                inspectionCount: &inspectionCount
            ) { previous, inputOrder in
                guard overlapRatio(previous, candidate) >= 0.2 else { return }
                matchedLockedIndices.insert(inputOrder)
                let overlap = overlapDuration(previous, candidate)
                if bestMatch == nil
                    || overlap > bestMatch!.overlap
                    || (
                        overlap == bestMatch!.overlap
                            && inputOrder < bestMatch!.inputOrder
                    ) {
                    bestMatch = (previous, overlap, inputOrder)
                }
            }
            guard let previous = bestMatch?.record else {
                return value
            }
            guard !shouldAdoptFreshDestinationClassification(
                previous: previous,
                candidate: candidate
            ) else {
                return value
            }
            value.categoryID = previous.categoryID
            value.title = previous.title
            value.behavior = previous.behavior
            if previous.manuallyCorrected {
                value.manuallyCorrected = true
            }
            return value
        }
        let retained = locked.enumerated().compactMap { inputOrder, previous in
            matchedLockedIndices.contains(inputOrder) ? nil : previous
        }
        merged.append(contentsOf: retained)
        return merged.sorted {
            if $0.startedAt != $1.startedAt {
                return $0.startedAt < $1.startedAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private static func shouldAdoptFreshDestinationClassification(
        previous: ActualRecord,
        candidate: ActualRecord
    ) -> Bool {
        guard previous.source == .location,
              candidate.source == .location,
              !previous.manuallyCorrected,
              (
                  previous.behavior == StationaryContextKind.unknownStay.rawValue
                      || (
                          previous.categoryID == "activity"
                              && previous.title == "머무름"
                      )
              ),
              let behavior = candidate.behavior.flatMap(
                  StationaryContextKind.init(rawValue:)
              ),
              behavior != .unknownStay,
              candidate.evidence.contains(where: {
                  $0.hasPrefix("자주가는 곳:")
              }) else {
            return false
        }
        return true
    }

    static func mergingLockedTravel(
        existing: [TravelSegment],
        fresh: [TravelSegment],
        inside: TimeSpan
    ) -> [TravelSegment] {
        var inspectionCount: Int? = nil
        return mergingLockedTravel(
            existing: existing,
            fresh: fresh,
            inside: inside,
            inspectionCount: &inspectionCount
        )
    }

    static func mergingLockedTravel(
        existing: [TravelSegment],
        fresh: [TravelSegment],
        inside: TimeSpan,
        candidateInspectionCount: inout Int
    ) -> [TravelSegment] {
        var inspectionCount: Int? = candidateInspectionCount
        let result = mergingLockedTravel(
            existing: existing,
            fresh: fresh,
            inside: inside,
            inspectionCount: &inspectionCount
        )
        candidateInspectionCount = inspectionCount ?? candidateInspectionCount
        return result
    }

    private static func mergingLockedTravel(
        existing: [TravelSegment],
        fresh: [TravelSegment],
        inside: TimeSpan,
        inspectionCount: inout Int?
    ) -> [TravelSegment] {
        let locked = existing.filter {
            $0.isClassificationLocked
                && $0.span.intersection(with: inside) != nil
        }
        let index = ActivityClassificationIntervalIndex(
            locked.enumerated().map { ($0.offset, $0.element) },
            span: \TravelSegment.span
        )
        var matchedLockedIndices = Set<Int>()
        var merged = fresh.map { candidate in
            var value = candidate
            var bestMatch: (segment: TravelSegment, overlap: TimeInterval, inputOrder: Int)?
            index.forEachCandidate(
                overlapping: candidate.span,
                inspectionCount: &inspectionCount
            ) { previous, inputOrder in
                guard overlapRatio(previous.span, candidate.span) >= 0.2 else {
                    return
                }
                matchedLockedIndices.insert(inputOrder)
                let overlap = overlapDuration(previous.span, candidate.span)
                if bestMatch == nil
                    || overlap > bestMatch!.overlap
                    || (
                        overlap == bestMatch!.overlap
                            && inputOrder < bestMatch!.inputOrder
                    ) {
                    bestMatch = (previous, overlap, inputOrder)
                }
            }
            guard let previous = bestMatch?.segment else {
                value.isClassificationLocked = true
                return value
            }
            let isResolvedSubway = candidate.mode == .subway
                && candidate.subwayRoute.map(SubwayStationCatalog.isValid) == true
            let previousSubwayIsValidated = previous.mode != .subway
                || previous.isConfirmed
                || previous.subwayRoute.map(SubwayStationCatalog.isValid) == true
            if previousSubwayIsValidated,
               !candidate.isConfirmed,
               !isResolvedSubway {
                value.mode = previous.mode
                value.subwayRoute = previous.subwayRoute ?? value.subwayRoute
                value.isConfirmed = previous.isConfirmed
            }
            value.isClassificationLocked = true
            return value
        }
        let retained = locked.enumerated().compactMap { inputOrder, previous in
            let validatedSubway = previous.mode != .subway
                || previous.isConfirmed
                || previous.subwayRoute.map(SubwayStationCatalog.isValid) == true
            return validatedSubway && !matchedLockedIndices.contains(inputOrder)
                ? previous
                : nil
        }
        merged.append(contentsOf: retained)
        return merged.sorted {
            if $0.span.start != $1.span.start {
                return $0.span.start < $1.span.start
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private static func overlapRatio(
        _ lhs: ActualRecord,
        _ rhs: ActualRecord
    ) -> Double {
        let lhsSpan = classificationSpan(lhs)
        let rhsSpan = classificationSpan(rhs)
        return overlapDuration(lhsSpan, rhsSpan)
            / max(1, min(lhsSpan.duration, rhsSpan.duration))
    }

    private static func overlapDuration(
        _ lhs: ActualRecord,
        _ rhs: ActualRecord
    ) -> TimeInterval {
        overlapDuration(classificationSpan(lhs), classificationSpan(rhs))
    }

    private static func classificationSpan(_ actual: ActualRecord) -> TimeSpan {
        TimeSpan(
            start: actual.startedAt,
            end: actual.endedAt ?? actual.startedAt.addingTimeInterval(1)
        )
    }

    private static func overlapDuration(
        _ lhs: TimeSpan,
        _ rhs: TimeSpan
    ) -> TimeInterval {
        lhs.intersection(with: rhs)?.duration ?? 0
    }

    private static func overlapRatio(
        _ lhs: TimeSpan,
        _ rhs: TimeSpan
    ) -> Double {
        overlapDuration(lhs, rhs) / max(1, min(lhs.duration, rhs.duration))
    }
}
