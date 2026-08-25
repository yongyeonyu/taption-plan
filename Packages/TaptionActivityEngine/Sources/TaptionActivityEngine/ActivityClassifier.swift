import Foundation

public struct ActivityEngineConfiguration: Codable, Hashable, Sendable {
    public var maximumGap: TimeInterval
    public var defaultSampleDuration: TimeInterval

    public init(maximumGap: TimeInterval = 15 * 60, defaultSampleDuration: TimeInterval = 1) {
        self.maximumGap = maximumGap
        self.defaultSampleDuration = defaultSampleDuration
    }
}

public struct ActivityClassificationEngine: Sendable {
    public let taxonomy: ActivityTaxonomy
    public let configuration: ActivityEngineConfiguration

    public init(taxonomy: ActivityTaxonomy = .default, configuration: ActivityEngineConfiguration = .init()) {
        self.taxonomy = taxonomy
        self.configuration = configuration
    }

    public func classify(
        _ evidence: [ActivitySensorEvidence],
        overrides: [ActivityClassificationOverride] = []
    ) -> [ActivitySegment] {
        classifyState(evidence, overrides: overrides).segments
    }

    public func classifyState(
        _ evidence: [ActivitySensorEvidence],
        overrides: [ActivityClassificationOverride] = []
    ) -> ActivityClassificationState {
        let normalized = normalize(evidence)
        return ActivityClassificationState(
            evidence: normalized,
            overrides: normalizedOverrides(overrides),
            segments: buildSegments(normalized, overrides: overrides)
        )
    }

    /// Rebuilds only the classification tail semantically while retaining a
    /// single normalized source of truth. This keeps the result identical to
    /// a full pass and lets adapters publish the unchanged prefix immediately.
    public func append(
        _ appended: [ActivitySensorEvidence],
        to state: ActivityClassificationState,
        overrides: [ActivityClassificationOverride]? = nil
    ) -> ActivityClassificationState {
        let activeOverrides = normalizedOverrides(overrides ?? state.overrides)
        let newEvidence = normalize(appended)
        if let lastEvidence = state.evidence.last,
           let firstNew = newEvidence.first,
           firstNew.timestamp > lastEvidence.timestamp,
           activeOverrides == state.overrides,
           let previousLast = state.segments.last {
            let tail = buildSegments([lastEvidence] + newEvidence, overrides: activeOverrides)
            guard let firstTail = tail.first else { return state }
            let prefix = Array(state.segments.dropLast())
            let nextSegments: [ActivitySegment]
            if sameClassification(previousLast, firstTail),
               firstNew.timestamp.timeIntervalSince(lastEvidence.timestamp) <= configuration.maximumGap {
                let merged = ActivitySegment(
                    id: previousLast.id,
                    span: ActivityTimeSpan(start: previousLast.span.start, end: firstTail.span.end),
                    majorCategoryID: previousLast.majorCategoryID,
                    detailID: previousLast.detailID,
                    title: previousLast.title,
                    behavior: previousLast.behavior,
                    confidence: min(previousLast.confidence, firstTail.confidence),
                    evidence: unique(previousLast.evidence + firstTail.evidence),
                    sampleCount: previousLast.sampleCount + firstTail.sampleCount - 1,
                    isUserConfirmed: previousLast.isUserConfirmed
                )
                nextSegments = prefix + [merged] + Array(tail.dropFirst())
            } else {
                nextSegments = state.segments + Array(tail.dropFirst())
            }
            return ActivityClassificationState(evidence: state.evidence + newEvidence, overrides: activeOverrides, segments: nextSegments)
        }
        return classifyState(state.evidence + appended, overrides: activeOverrides)
    }

    public func reclassifyTail(
        existing state: ActivityClassificationState,
        appendedEvidence: [ActivitySensorEvidence],
        overrides: [ActivityClassificationOverride]? = nil
    ) -> ActivityClassificationState {
        append(appendedEvidence, to: state, overrides: overrides)
    }

    public func normalize(_ evidence: [ActivitySensorEvidence]) -> [ActivitySensorEvidence] {
        let ordered = evidence.sorted(by: isEarlier)
        var result: [ActivitySensorEvidence] = []
        var index = 0
        while index < ordered.count {
            let timestamp = ordered[index].timestamp
            var end = index + 1
            while end < ordered.count && ordered[end].timestamp == timestamp { end += 1 }
            if let first = ordered[index..<end].first {
                let selected = ordered[index..<end].dropFirst().reduce(first) { current, candidate in
                    betterDuplicate(candidate, current) ? candidate : current
                }
                result.append(selected)
            }
            index = end
        }
        return result
    }

    private func buildSegments(
        _ evidence: [ActivitySensorEvidence],
        overrides: [ActivityClassificationOverride]
    ) -> [ActivitySegment] {
        guard !evidence.isEmpty else { return [] }
        var raw: [RawSegment] = []
        var current: RawSegment?
        for index in evidence.indices {
            let sample = evidence[index]
            let next = evidence.indices.contains(index + 1) ? evidence[index + 1] : nil
            let sampleEnd = next.map { min($0.timestamp, sample.timestamp.addingTimeInterval(configuration.defaultSampleDuration)) }
                ?? sample.timestamp.addingTimeInterval(configuration.defaultSampleDuration)
            let classification = classification(for: sample, overrides: overrides)
            let canJoin = current.map {
                $0.classification == classification
                    && sample.timestamp.timeIntervalSince($0.span.end) <= configuration.maximumGap
            } ?? false
            if canJoin {
                current?.append(sample, endingAt: sampleEnd)
            } else {
                if let current { raw.append(current) }
                current = RawSegment(sample: sample, endingAt: sampleEnd, classification: classification)
            }
        }
        if let current { raw.append(current) }

        var segments = raw.map(makeSegment)
        if !overrides.isEmpty {
            segments = applyOverrides(segments, overrides: overrides)
        }
        return mergeAdjacent(segments)
    }

    private func classification(
        for sample: ActivitySensorEvidence,
        overrides: [ActivityClassificationOverride]
    ) -> Classification {
        let active = overrides.filter { $0.span.start <= sample.timestamp && sample.timestamp < $0.span.end }
            .sorted { lhs, rhs in
                if lhs.isSleep != rhs.isSleep { return lhs.isSleep }
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        if let override = active.first {
            return Classification(
                majorID: override.majorCategoryID,
                detailID: override.detailID ?? defaultDetailID(for: override.majorCategoryID),
                title: override.title ?? taxonomy.major(for: override.majorCategoryID)?.title ?? "활동",
                behavior: override.behavior ?? override.detailID.flatMap { taxonomy.detail(for: $0)?.behavior } ?? "manual",
                confidence: 1,
                evidence: [override.isSleep ? "사용자 확인 수면" : "사용자 확인"],
                confirmed: true
            )
        }

        let text = ([sample.categoryHint, sample.detailHint, sample.behaviorHint] + sample.evidence)
            .compactMap { $0?.lowercased() }.joined(separator: " ")
        if containsAny(text, ["sleep", "수면", "취침", "낮잠", "core", "deep", "rem"]) {
            let behavior = containsAny(text, ["deep", "깊은"]) ? "deep" : containsAny(text, ["rem"]) ? "rem" : "core"
            return automatic(major: "sleep", detail: "sleep.\(behavior)", behavior: behavior, sample: sample, evidence: "수면 센서 근거")
        }
        if let detail = sample.detailHint.flatMap({ taxonomy.detail(for: $0) }) {
            return automatic(major: majorID(for: detail.id), detail: detail.id, behavior: detail.behavior, sample: sample, evidence: "상세 활동 힌트")
        }
        if let category = sample.categoryHint, taxonomy.major(for: category) != nil {
            return automatic(major: category, detail: defaultDetailID(for: category), behavior: taxonomy.detail(for: defaultDetailID(for: category))?.behavior ?? category, sample: sample, evidence: "대분류 활동 힌트")
        }
        if let behavior = sample.behaviorHint {
            if let detail = taxonomy.majors.lazy.compactMap({ $0.details.first { $0.behavior.caseInsensitiveCompare(behavior) == .orderedSame } }).first {
                return automatic(major: majorID(for: detail.id), detail: detail.id, behavior: detail.behavior, sample: sample, evidence: "센서 행동 근거")
            }
        }
        switch sample.motion {
        case .walking: return automatic(major: "movement", detail: "movement.walking", behavior: "walking", sample: sample, evidence: "Core Motion 보행")
        case .running: return automatic(major: "movement", detail: "movement.running", behavior: "running", sample: sample, evidence: "Core Motion 달리기")
        case .cycling: return automatic(major: "movement", detail: "movement.cycling", behavior: "cycling", sample: sample, evidence: "Core Motion 자전거")
        case .automotive: return automatic(major: "movement", detail: "movement.car", behavior: "automotive", sample: sample, evidence: "Core Motion 차량")
        case .stationary, .unknown:
            if let speed = sample.speedMetersPerSecond {
                if speed >= 8 { return automatic(major: "movement", detail: "movement.car", behavior: "automotive", sample: sample, evidence: "속도 근거") }
                if speed >= 1 { return automatic(major: "movement", detail: "movement.walking", behavior: "walking", sample: sample, evidence: "속도 근거") }
            }
            return automatic(major: "activity", detail: "activity.rest", behavior: "stationary", sample: sample, evidence: "정지 센서 근거")
        }
    }

    private func automatic(major: String, detail: String, behavior: String, sample: ActivitySensorEvidence, evidence: String) -> Classification {
        Classification(majorID: major, detailID: detail, title: taxonomy.detail(for: detail)?.title ?? taxonomy.major(for: major)?.title ?? "활동", behavior: behavior, confidence: sample.confidence ?? (sample.isPreciseLocation ? 0.8 : 0.55), evidence: [evidence] + sample.evidence, confirmed: false)
    }

    private func applyOverrides(_ segments: [ActivitySegment], overrides: [ActivityClassificationOverride]) -> [ActivitySegment] {
        segments.flatMap { segment in
            let relevant = overrides.filter { $0.span.intersects(segment.span) }
                .sorted { lhs, rhs in if lhs.isSleep != rhs.isSleep { return lhs.isSleep }; return lhs.updatedAt > rhs.updatedAt }
            guard !relevant.isEmpty else { return [segment] }
            var cuts = Set([segment.span.start, segment.span.end])
            for override in relevant { cuts.insert(max(segment.span.start, override.span.start)); cuts.insert(min(segment.span.end, override.span.end)) }
            let points = cuts.sorted()
            return (0..<(points.count - 1)).compactMap { index in
                let span = ActivityTimeSpan(start: points[index], end: points[index + 1])
                guard span.duration > 0 else { return nil }
                let midpoint = span.start.addingTimeInterval(span.duration / 2)
                if let override = relevant.first(where: { $0.span.start <= midpoint && midpoint < $0.span.end }) {
                    let c = classification(for: ActivitySensorEvidence(timestamp: midpoint), overrides: [override])
                    return ActivitySegment(id: stableID(seed: "\(segment.id.uuidString)|\(span.start.timeIntervalSince1970)"), span: span, majorCategoryID: c.majorID, detailID: c.detailID, title: c.title, behavior: c.behavior, confidence: c.confidence, evidence: c.evidence, sampleCount: segment.sampleCount, isUserConfirmed: true)
                }
                return ActivitySegment(id: stableID(seed: "\(segment.id.uuidString)|\(span.start.timeIntervalSince1970)"), span: span, majorCategoryID: segment.majorCategoryID, detailID: segment.detailID, title: segment.title, behavior: segment.behavior, confidence: segment.confidence, evidence: segment.evidence, sampleCount: segment.sampleCount, isUserConfirmed: segment.isUserConfirmed)
            }
        }
    }

    private func mergeAdjacent(_ segments: [ActivitySegment]) -> [ActivitySegment] {
        var result: [ActivitySegment] = []
        for segment in segments {
            guard let last = result.last,
                  last.majorCategoryID == segment.majorCategoryID,
                  last.detailID == segment.detailID,
                  last.isUserConfirmed == segment.isUserConfirmed,
                  last.span.end == segment.span.start else { result.append(segment); continue }
            result[result.count - 1] = ActivitySegment(id: last.id, span: ActivityTimeSpan(start: last.span.start, end: segment.span.end), majorCategoryID: last.majorCategoryID, detailID: last.detailID, title: last.title, behavior: last.behavior, confidence: min(last.confidence, segment.confidence), evidence: unique(last.evidence + segment.evidence), sampleCount: last.sampleCount + segment.sampleCount, isUserConfirmed: last.isUserConfirmed)
        }
        return result
    }

    private func makeSegment(_ raw: RawSegment) -> ActivitySegment {
        ActivitySegment(id: stableID(seed: raw.firstID.uuidString), span: raw.span, majorCategoryID: raw.classification.majorID, detailID: raw.classification.detailID, title: raw.classification.title, behavior: raw.classification.behavior, confidence: raw.confidence, evidence: raw.evidence, sampleCount: raw.sampleCount, isUserConfirmed: raw.classification.confirmed)
    }

    private func normalizedOverrides(_ overrides: [ActivityClassificationOverride]) -> [ActivityClassificationOverride] {
        overrides.sorted { lhs, rhs in if lhs.span.start != rhs.span.start { return lhs.span.start < rhs.span.start }; return lhs.id.uuidString < rhs.id.uuidString }
    }

    private func defaultDetailID(for majorID: String) -> String {
        taxonomy.major(for: majorID)?.details.first?.id ?? "\(majorID).automatic"
    }

    private func majorID(for detailID: String) -> String { detailID.split(separator: ".").first.map(String.init) ?? "activity" }

    private func containsAny(_ value: String, _ values: [String]) -> Bool { values.contains { value.contains($0) } }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func sameClassification(_ lhs: ActivitySegment, _ rhs: ActivitySegment) -> Bool {
        lhs.majorCategoryID == rhs.majorCategoryID
            && lhs.detailID == rhs.detailID
            && lhs.isUserConfirmed == rhs.isUserConfirmed
    }

    private func isEarlier(_ lhs: ActivitySensorEvidence, _ rhs: ActivitySensorEvidence) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func betterDuplicate(_ lhs: ActivitySensorEvidence, _ rhs: ActivitySensorEvidence) -> Bool {
        if lhs.isPreciseLocation != rhs.isPreciseLocation { return lhs.isPreciseLocation }
        let leftAccuracy = lhs.horizontalAccuracyMeters.map { $0.isFinite ? $0 : .greatestFiniteMagnitude } ?? .greatestFiniteMagnitude
        let rightAccuracy = rhs.horizontalAccuracyMeters.map { $0.isFinite ? $0 : .greatestFiniteMagnitude } ?? .greatestFiniteMagnitude
        if leftAccuracy != rightAccuracy { return leftAccuracy < rightAccuracy }
        if lhs.sequence != rhs.sequence { return (lhs.sequence ?? Int.min) > (rhs.sequence ?? Int.min) }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func stableID(seed: String) -> UUID {
        var h1: UInt64 = 0xcbf29ce484222325
        var h2: UInt64 = 0x9e3779b185ebca87
        for byte in seed.utf8 { h1 = (h1 ^ UInt64(byte)) &* 0x100000001b3; h2 = (h2 ^ UInt64(byte)) &* 0x9e3779b185ebca87 }
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<8 { bytes[index] = UInt8((h1 >> UInt64(index * 8)) & 0xff); bytes[index + 8] = UInt8((h2 >> UInt64(index * 8)) & 0xff) }
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

private struct Classification: Hashable, Sendable {
    let majorID: String
    let detailID: String
    let title: String
    let behavior: String
    let confidence: Double
    let evidence: [String]
    let confirmed: Bool
}

private struct RawSegment: Sendable {
    let firstID: UUID
    let classification: Classification
    var span: ActivityTimeSpan
    var sampleCount: Int
    var confidence: Double
    var evidence: [String]

    init(sample: ActivitySensorEvidence, endingAt end: Date, classification: Classification) {
        self.firstID = sample.id
        self.classification = classification
        self.span = ActivityTimeSpan(start: sample.timestamp, end: end)
        self.sampleCount = 1
        self.confidence = classification.confidence
        self.evidence = classification.evidence
    }

    mutating func append(_ sample: ActivitySensorEvidence, endingAt end: Date) {
        span = ActivityTimeSpan(start: span.start, end: end)
        sampleCount += 1
        confidence = min(confidence, classification.confidence)
        for item in classification.evidence where !evidence.contains(item) { evidence.append(item) }
    }
}
