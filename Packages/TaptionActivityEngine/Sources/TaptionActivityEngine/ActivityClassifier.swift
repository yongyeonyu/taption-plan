import Foundation

enum ActivityClassificationWorkPhase: Equatable, Sendable {
    case normalization
    case sorting
    case deduplication
    case segmentConstruction
}

private struct ActivityClassificationCheckpoints {
    private let checkCancellation: @Sendable (ActivityClassificationWorkPhase) throws -> Void
    private var normalizationOperations = 0
    private var sortingOperations = 0
    private var deduplicationOperations = 0
    private var segmentConstructionOperations = 0

    init(checkCancellation: @escaping @Sendable (ActivityClassificationWorkPhase) throws -> Void) {
        self.checkCancellation = checkCancellation
    }

    mutating func step(_ phase: ActivityClassificationWorkPhase) throws {
        let operation: Int
        switch phase {
        case .normalization:
            normalizationOperations += 1
            operation = normalizationOperations
        case .sorting:
            sortingOperations += 1
            operation = sortingOperations
        case .deduplication:
            deduplicationOperations += 1
            operation = deduplicationOperations
        case .segmentConstruction:
            segmentConstructionOperations += 1
            operation = segmentConstructionOperations
        }
        if operation == 1 || operation.isMultiple(of: 256) {
            try checkCancellation(phase)
        }
    }

    func check(_ phase: ActivityClassificationWorkPhase) throws {
        try checkCancellation(phase)
    }
}

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
        do {
            return try classifyState(
                evidence,
                overrides: overrides,
                cancellationCheck: { _ in }
            )
        } catch {
            preconditionFailure("Unexpected activity classification failure: \(error)")
        }
    }

    func classifyState(
        _ evidence: [ActivitySensorEvidence],
        overrides: [ActivityClassificationOverride],
        cancellationCheck: @escaping @Sendable (ActivityClassificationWorkPhase) throws -> Void
    ) throws -> ActivityClassificationState {
        var checkpoints = ActivityClassificationCheckpoints(checkCancellation: cancellationCheck)
        try checkpoints.check(.normalization)
        let normalized = try normalize(evidence, checkpoints: &checkpoints)
        let activeOverrides = try normalizedOverrides(overrides, checkpoints: &checkpoints)
        let segments = try buildSegments(
            normalized,
            overrides: activeOverrides,
            checkpoints: &checkpoints
        )
        try checkpoints.check(.segmentConstruction)
        return ActivityClassificationState(
            evidence: normalized,
            overrides: activeOverrides,
            segments: segments,
            engineIdentity: engineIdentity
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
        do {
            return try append(
                appended,
                to: state,
                overrides: overrides,
                cancellationCheck: { _ in }
            )
        } catch {
            preconditionFailure("Unexpected activity append failure: \(error)")
        }
    }

    func append(
        _ appended: [ActivitySensorEvidence],
        to state: ActivityClassificationState,
        overrides: [ActivityClassificationOverride]?,
        cancellationCheck: @escaping @Sendable (ActivityClassificationWorkPhase) throws -> Void
    ) throws -> ActivityClassificationState {
        var checkpoints = ActivityClassificationCheckpoints(checkCancellation: cancellationCheck)
        try checkpoints.check(.normalization)
        let activeOverrides = try normalizedOverrides(
            overrides ?? state.overrides,
            checkpoints: &checkpoints
        )
        let newEvidence = try normalize(appended, checkpoints: &checkpoints)
        if let lastEvidence = state.evidence.last,
           let firstNew = newEvidence.first,
           firstNew.timestamp > lastEvidence.timestamp,
           activeOverrides == state.overrides,
           state.engineIdentity == engineIdentity,
           let previousLast = state.segments.last,
           previousLast.span.start <= lastEvidence.timestamp,
           lastEvidence.timestamp < previousLast.span.end {
            let tail = try buildSegments(
                [lastEvidence] + newEvidence,
                overrides: activeOverrides,
                checkpoints: &checkpoints
            )
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
                    isUserConfirmed: previousLast.isUserConfirmed,
                    provenance: .init(
                        tier: previousLast.provenance.tier,
                        status: previousLast.provenance.status,
                        source: previousLast.provenance.source,
                        evidence: unique(previousLast.provenance.evidence + firstTail.provenance.evidence),
                        confidence: min(previousLast.confidence, firstTail.confidence),
                        span: ActivityTimeSpan(start: previousLast.span.start, end: firstTail.span.end)
                    )
                )
                nextSegments = prefix + [merged] + Array(tail.dropFirst())
            } else {
                return try classifyState(
                    state.evidence + appended,
                    overrides: activeOverrides,
                    cancellationCheck: cancellationCheck
                )
            }
            return ActivityClassificationState(
                evidence: state.evidence + newEvidence,
                overrides: activeOverrides,
                segments: nextSegments,
                engineIdentity: engineIdentity
            )
        }
        return try classifyState(
            state.evidence + appended,
            overrides: activeOverrides,
            cancellationCheck: cancellationCheck
        )
    }

    public func reclassifyTail(
        existing state: ActivityClassificationState,
        appendedEvidence: [ActivitySensorEvidence],
        overrides: [ActivityClassificationOverride]? = nil
    ) -> ActivityClassificationState {
        append(appendedEvidence, to: state, overrides: overrides)
    }

    public func normalize(_ evidence: [ActivitySensorEvidence]) -> [ActivitySensorEvidence] {
        do {
            var checkpoints = ActivityClassificationCheckpoints { _ in }
            try checkpoints.check(.normalization)
            return try normalize(evidence, checkpoints: &checkpoints)
        } catch {
            preconditionFailure("Unexpected activity normalization failure: \(error)")
        }
    }

    private func normalize(
        _ evidence: [ActivitySensorEvidence],
        checkpoints: inout ActivityClassificationCheckpoints
    ) throws -> [ActivitySensorEvidence] {
        var valid: [ActivitySensorEvidence] = []
        valid.reserveCapacity(evidence.count)
        for sample in evidence {
            try checkpoints.step(.normalization)
            if ActivityTimestamp.isValid(sample.timestamp) {
                valid.append(sample)
            }
        }
        let ordered = try cancellableSort(
            valid,
            by: isEarlier,
            phase: .sorting,
            checkpoints: &checkpoints
        )
        var result: [ActivitySensorEvidence] = []
        result.reserveCapacity(ordered.count)
        var index = 0
        while index < ordered.count {
            try checkpoints.step(.deduplication)
            let timestamp = ordered[index].timestamp
            var end = index + 1
            var selected = ordered[index]
            while end < ordered.count && ordered[end].timestamp == timestamp {
                try checkpoints.step(.deduplication)
                if betterDuplicate(ordered[end], selected) {
                    selected = ordered[end]
                }
                end += 1
            }
            result.append(selected)
            index = end
        }
        try checkpoints.check(.deduplication)
        return result
    }

    private func cancellableSort<Element>(
        _ values: [Element],
        by areInIncreasingOrder: (Element, Element) -> Bool,
        phase: ActivityClassificationWorkPhase,
        checkpoints: inout ActivityClassificationCheckpoints
    ) throws -> [Element] {
        // Standard-library sorting cannot observe cancellation while it runs.
        guard values.count > 1 else {
            try checkpoints.check(phase)
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
                    try checkpoints.step(phase)
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
        try checkpoints.check(phase)
        return source
    }

    private func buildSegments(
        _ evidence: [ActivitySensorEvidence],
        overrides: [ActivityClassificationOverride],
        checkpoints: inout ActivityClassificationCheckpoints
    ) throws -> [ActivitySegment] {
        guard !evidence.isEmpty else { return [] }
        var raw: [RawSegment] = []
        var current: RawSegment?
        var nextOverride = 0
        var activeOverrideHeap: [Int] = []
        for index in evidence.indices {
            try checkpoints.step(.segmentConstruction)
            let sample = evidence[index]
            let next = evidence.indices.contains(index + 1) ? evidence[index + 1] : nil
            let sampleEnd = next.map { min($0.timestamp, sample.timestamp.addingTimeInterval(configuration.defaultSampleDuration)) }
                ?? sample.timestamp.addingTimeInterval(configuration.defaultSampleDuration)
            while nextOverride < overrides.count,
                  overrides[nextOverride].span.start <= sample.timestamp {
                try checkpoints.step(.segmentConstruction)
                try pushOverride(
                    nextOverride,
                    into: &activeOverrideHeap,
                    overrides: overrides,
                    checkpoints: &checkpoints
                )
                nextOverride += 1
            }
            while let winner = activeOverrideHeap.first,
                  overrides[winner].span.end <= sample.timestamp {
                try checkpoints.step(.segmentConstruction)
                _ = try popOverride(
                    from: &activeOverrideHeap,
                    overrides: overrides,
                    checkpoints: &checkpoints
                )
            }
            let classification = classification(
                for: sample,
                override: activeOverrideHeap.first.map { overrides[$0] }
            )
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

        var segments: [ActivitySegment] = []
        segments.reserveCapacity(raw.count)
        for value in raw {
            try checkpoints.step(.segmentConstruction)
            segments.append(makeSegment(value))
        }
        if !overrides.isEmpty {
            segments = try applyOverrides(
                segments,
                overrides: overrides,
                evidence: evidence,
                checkpoints: &checkpoints
            )
        }
        return try mergeAdjacent(segments, checkpoints: &checkpoints)
    }

    private func classification(
        for sample: ActivitySensorEvidence,
        override: ActivityClassificationOverride?
    ) -> Classification {
        if let override {
            return Classification(
                majorID: override.majorCategoryID,
                detailID: override.detailID ?? defaultDetailID(for: override.majorCategoryID),
                title: override.title ?? taxonomy.major(for: override.majorCategoryID)?.title ?? "활동",
                behavior: override.behavior ?? override.detailID.flatMap { taxonomy.detail(for: $0)?.behavior } ?? "manual",
                confidence: 1,
                evidence: [
                    override.isUserConfirmed
                        ? (override.isSleep ? "사용자 확인 수면" : "사용자 확인")
                        : "자동 분류 잠금"
                ],
                confirmed: override.isUserConfirmed
            )
        }

        let signals = ([sample.categoryHint, sample.detailHint, sample.behaviorHint] + sample.evidence)
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let hasSleepContext = signals.contains {
            containsAny($0, ["sleep", "수면", "취침", "낮잠"])
        }
        let hasBareSleepStage = signals.contains { ["core", "deep", "rem"].contains($0) }
        if hasSleepContext || hasBareSleepStage {
            let behavior: String
            if signals.contains(where: { $0 == "deep" || (hasSleepContext && containsAny($0, ["deep", "깊은"])) }) {
                behavior = "deep"
            } else if signals.contains(where: { $0 == "rem" || (hasSleepContext && $0.contains("rem")) }) {
                behavior = "rem"
            } else {
                behavior = "core"
            }
            return automatic(major: "sleep", detail: "sleep.\(behavior)", behavior: behavior, sample: sample, evidence: "수면 센서 근거")
        }
        if let detail = sample.detailHint.flatMap({ taxonomy.detail(for: $0) }) {
            return automatic(major: majorID(for: detail.id), detail: detail.id, behavior: detail.behavior, sample: sample, evidence: "상세 활동 힌트")
        }
        if sample.categoryHint == "movement",
           let motionClassification = preciseMotionClassification(for: sample) {
            return motionClassification
        }
        if let category = sample.categoryHint, taxonomy.major(for: category) != nil {
            return automatic(major: category, detail: defaultDetailID(for: category), behavior: taxonomy.detail(for: defaultDetailID(for: category))?.behavior ?? category, sample: sample, evidence: "대분류 활동 힌트")
        }
        if let behavior = sample.behaviorHint {
            if let detail = taxonomy.majors.lazy.compactMap({ $0.details.first { $0.behavior.caseInsensitiveCompare(behavior) == .orderedSame } }).first {
                return automatic(major: majorID(for: detail.id), detail: detail.id, behavior: detail.behavior, sample: sample, evidence: "센서 행동 근거")
            }
        }
        if let motionClassification = preciseMotionClassification(for: sample) {
            return motionClassification
        }
        if let speed = sample.speedMetersPerSecond {
            if speed >= 8 { return automatic(major: "movement", detail: "movement.car", behavior: "automotive", sample: sample, evidence: "속도 근거") }
            if speed >= 1 { return automatic(major: "movement", detail: "movement.walking", behavior: "walking", sample: sample, evidence: "속도 근거") }
        }
        return automatic(major: "activity", detail: "activity.rest", behavior: "stationary", sample: sample, evidence: "정지 센서 근거")
    }

    private func preciseMotionClassification(
        for sample: ActivitySensorEvidence
    ) -> Classification? {
        switch sample.motion {
        case .walking:
            return automatic(
                major: "movement",
                detail: "movement.walking",
                behavior: "walking",
                sample: sample,
                evidence: "Core Motion 보행"
            )
        case .running:
            return automatic(
                major: "movement",
                detail: "movement.running",
                behavior: "running",
                sample: sample,
                evidence: "Core Motion 달리기"
            )
        case .cycling:
            return automatic(
                major: "movement",
                detail: "movement.cycling",
                behavior: "cycling",
                sample: sample,
                evidence: "Core Motion 자전거"
            )
        case .automotive:
            return automatic(
                major: "movement",
                detail: "movement.car",
                behavior: "automotive",
                sample: sample,
                evidence: "Core Motion 차량"
            )
        case .stationary, .unknown:
            return nil
        }
    }

    private func pushOverride(
        _ index: Int,
        into heap: inout [Int],
        overrides: [ActivityClassificationOverride],
        checkpoints: inout ActivityClassificationCheckpoints
    ) throws {
        heap.append(index)
        var child = heap.count - 1
        while child > 0 {
            try checkpoints.step(.segmentConstruction)
            let parent = (child - 1) / 2
            guard hasHigherPriority(
                overrides[heap[child]],
                than: overrides[heap[parent]]
            ) else { break }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    private func popOverride(
        from heap: inout [Int],
        overrides: [ActivityClassificationOverride],
        checkpoints: inout ActivityClassificationCheckpoints
    ) throws -> Int? {
        guard let first = heap.first else { return nil }
        let last = heap.removeLast()
        guard !heap.isEmpty else { return first }
        heap[0] = last
        var parent = 0
        while true {
            try checkpoints.step(.segmentConstruction)
            let left = parent * 2 + 1
            guard left < heap.count else { break }
            let right = left + 1
            var highest = left
            if right < heap.count,
               hasHigherPriority(
                   overrides[heap[right]],
                   than: overrides[heap[left]]
               ) {
                highest = right
            }
            guard hasHigherPriority(
                overrides[heap[highest]],
                than: overrides[heap[parent]]
            ) else { break }
            heap.swapAt(parent, highest)
            parent = highest
        }
        return first
    }

    private func hasHigherPriority(
        _ lhs: ActivityClassificationOverride,
        than rhs: ActivityClassificationOverride
    ) -> Bool {
        if lhs.isSleep != rhs.isSleep { return lhs.isSleep }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return ActivityUUIDOrder.precedes(lhs.id, rhs.id)
    }

    private func automatic(major: String, detail: String, behavior: String, sample: ActivitySensorEvidence, evidence: String) -> Classification {
        Classification(majorID: major, detailID: detail, title: taxonomy.detail(for: detail)?.title ?? taxonomy.major(for: major)?.title ?? "활동", behavior: behavior, confidence: sample.confidence ?? (sample.isPreciseLocation ? 0.8 : 0.55), evidence: [evidence] + sample.evidence, confirmed: false)
    }

    private func applyOverrides(
        _ segments: [ActivitySegment],
        overrides: [ActivityClassificationOverride],
        evidence: [ActivitySensorEvidence],
        checkpoints: inout ActivityClassificationCheckpoints
    ) throws -> [ActivitySegment] {
        var result: [ActivitySegment] = []
        result.reserveCapacity(segments.count)
        var nextOverride = 0
        var activeOverrides: [Int] = []

        for segment in segments {
            try checkpoints.step(.segmentConstruction)
            var cursor = segment.span.start
            while cursor < segment.span.end {
                try checkpoints.step(.segmentConstruction)
                while nextOverride < overrides.count,
                      overrides[nextOverride].span.start <= cursor {
                    try checkpoints.step(.segmentConstruction)
                    try pushOverride(
                        nextOverride,
                        into: &activeOverrides,
                        overrides: overrides,
                        checkpoints: &checkpoints
                    )
                    nextOverride += 1
                }
                while let winner = activeOverrides.first,
                      overrides[winner].span.end <= cursor {
                    try checkpoints.step(.segmentConstruction)
                    _ = try popOverride(
                        from: &activeOverrides,
                        overrides: overrides,
                        checkpoints: &checkpoints
                    )
                }

                var boundary = segment.span.end
                if nextOverride < overrides.count {
                    boundary = min(boundary, overrides[nextOverride].span.start)
                }
                if let winner = activeOverrides.first {
                    boundary = min(boundary, overrides[winner].span.end)
                }
                guard boundary > cursor else { break }

                let span = ActivityTimeSpan(start: cursor, end: boundary)
                if span.start == segment.span.start,
                   span.end == segment.span.end,
                   activeOverrides.isEmpty {
                    result.append(segment)
                } else {
                    result.append(overriddenSegment(
                        segment,
                        span: span,
                        override: activeOverrides.first.map { overrides[$0] },
                        evidence: evidence
                    ))
                }
                cursor = boundary
            }
        }
        return result
    }

    private func overriddenSegment(
        _ segment: ActivitySegment,
        span: ActivityTimeSpan,
        override: ActivityClassificationOverride?,
        evidence: [ActivitySensorEvidence]
    ) -> ActivitySegment {
        let id = ActivityStableID.uuid(seed: "\(segment.id.uuidString)|\(span.start.timeIntervalSince1970)")
        let sampleCount = sampleCount(in: span, evidence: evidence)
        guard let override else {
            return ActivitySegment(
                id: id,
                span: span,
                majorCategoryID: segment.majorCategoryID,
                detailID: segment.detailID,
                title: segment.title,
                behavior: segment.behavior,
                confidence: segment.confidence,
                evidence: segment.evidence,
                sampleCount: sampleCount,
                isUserConfirmed: segment.isUserConfirmed,
                provenance: .init(
                    tier: segment.provenance.tier,
                    status: segment.provenance.status,
                    source: segment.provenance.source,
                    evidence: segment.provenance.evidence,
                    confidence: segment.provenance.confidence,
                    span: span
                )
            )
        }

        let midpoint = span.start.addingTimeInterval(span.duration / 2)
        let classification = classification(
            for: ActivitySensorEvidence(timestamp: midpoint),
            override: override
        )
        return ActivitySegment(
            id: id,
            span: span,
            majorCategoryID: classification.majorID,
            detailID: classification.detailID,
            title: classification.title,
            behavior: classification.behavior,
            confidence: classification.confidence,
            evidence: classification.evidence,
            sampleCount: sampleCount,
            isUserConfirmed: classification.confirmed,
            provenance: .init(
                tier: classification.confirmed ? .groundTruth : .expected,
                status: classification.confirmed
                    ? .userCorrected
                    : ActivityAutomaticConfirmation.status(for: classification.confidence),
                source: classification.confirmed ? "user-correction" : "classification-lock",
                evidence: classification.evidence,
                confidence: classification.confidence,
                span: span
            )
        )
    }

    private func sampleCount(
        in span: ActivityTimeSpan,
        evidence: [ActivitySensorEvidence]
    ) -> Int {
        lowerBound(span.end, in: evidence) - lowerBound(span.start, in: evidence)
    }

    private func lowerBound(
        _ timestamp: Date,
        in evidence: [ActivitySensorEvidence]
    ) -> Int {
        var lower = 0
        var upper = evidence.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if evidence[middle].timestamp < timestamp {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private func mergeAdjacent(
        _ segments: [ActivitySegment],
        checkpoints: inout ActivityClassificationCheckpoints
    ) throws -> [ActivitySegment] {
        var result: [ActivitySegment] = []
        for segment in segments {
            try checkpoints.step(.segmentConstruction)
            guard let last = result.last,
                  last.majorCategoryID == segment.majorCategoryID,
                  last.detailID == segment.detailID,
                  last.isUserConfirmed == segment.isUserConfirmed,
                  last.span.end == segment.span.start else { result.append(segment); continue }
            result[result.count - 1] = ActivitySegment(id: last.id, span: ActivityTimeSpan(start: last.span.start, end: segment.span.end), majorCategoryID: last.majorCategoryID, detailID: last.detailID, title: last.title, behavior: last.behavior, confidence: min(last.confidence, segment.confidence), evidence: unique(last.evidence + segment.evidence), sampleCount: last.sampleCount + segment.sampleCount, isUserConfirmed: last.isUserConfirmed, provenance: .init(tier: last.provenance.tier, status: last.provenance.status, source: last.provenance.source, evidence: unique(last.provenance.evidence + segment.provenance.evidence), confidence: min(last.confidence, segment.confidence), span: ActivityTimeSpan(start: last.span.start, end: segment.span.end)))
        }
        return result
    }

    private func makeSegment(_ raw: RawSegment) -> ActivitySegment {
        ActivitySegment(id: ActivityStableID.uuid(seed: raw.firstID.uuidString), span: raw.span, majorCategoryID: raw.classification.majorID, detailID: raw.classification.detailID, title: raw.classification.title, behavior: raw.classification.behavior, confidence: raw.confidence, evidence: raw.evidence, sampleCount: raw.sampleCount, isUserConfirmed: raw.classification.confirmed, provenance: .init(tier: raw.classification.confirmed ? .groundTruth : .expected, status: raw.classification.confirmed ? .userCorrected : ActivityAutomaticConfirmation.status(for: raw.confidence), source: raw.classification.confirmed ? "user-correction" : "activity-classifier-v1", evidence: raw.evidence, confidence: raw.confidence, span: raw.span))
    }

    private func normalizedOverrides(
        _ overrides: [ActivityClassificationOverride],
        checkpoints: inout ActivityClassificationCheckpoints
    ) throws -> [ActivityClassificationOverride] {
        var valid: [ActivityClassificationOverride] = []
        valid.reserveCapacity(overrides.count)
        for override in overrides {
            try checkpoints.step(.normalization)
            if ActivityTimestamp.isValid(override.span.start),
               ActivityTimestamp.isValid(override.span.end),
               ActivityTimestamp.isValid(override.updatedAt) {
                valid.append(override)
            }
        }
        return try cancellableSort(
            valid,
            by: {
                if $0.span.start != $1.span.start { return $0.span.start < $1.span.start }
                return ActivityUUIDOrder.precedes($0.id, $1.id)
            },
            phase: .sorting,
            checkpoints: &checkpoints
        )
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

    private var engineIdentity: ActivityClassificationEngineIdentity {
        ActivityClassificationEngineIdentity(
            taxonomy: taxonomy,
            configuration: configuration
        )
    }

    private func isEarlier(_ lhs: ActivitySensorEvidence, _ rhs: ActivitySensorEvidence) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        return ActivityUUIDOrder.precedes(lhs.id, rhs.id)
    }

    private func betterDuplicate(_ lhs: ActivitySensorEvidence, _ rhs: ActivitySensorEvidence) -> Bool {
        if lhs.isPreciseLocation != rhs.isPreciseLocation { return lhs.isPreciseLocation }
        let leftAccuracy = lhs.horizontalAccuracyMeters.map { $0.isFinite ? $0 : .greatestFiniteMagnitude } ?? .greatestFiniteMagnitude
        let rightAccuracy = rhs.horizontalAccuracyMeters.map { $0.isFinite ? $0 : .greatestFiniteMagnitude } ?? .greatestFiniteMagnitude
        if leftAccuracy != rightAccuracy { return leftAccuracy < rightAccuracy }
        if lhs.sequence != rhs.sequence { return (lhs.sequence ?? Int.min) > (rhs.sequence ?? Int.min) }
        return ActivityUUIDOrder.precedes(lhs.id, rhs.id)
    }
}

enum ActivityUUIDOrder {
    static func precedes(_ lhs: UUID, _ rhs: UUID) -> Bool {
        withUnsafeBytes(of: lhs.uuid) { lhsBytes in
            withUnsafeBytes(of: rhs.uuid) { rhsBytes in
                for index in 0..<16 where lhsBytes[index] != rhsBytes[index] {
                    return lhsBytes[index] < rhsBytes[index]
                }
                return false
            }
        }
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
