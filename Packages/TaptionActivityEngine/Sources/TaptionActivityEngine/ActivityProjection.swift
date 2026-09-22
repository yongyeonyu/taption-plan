import Foundation

private func activityFusionStep(
    _ operationCount: inout Int,
    cancellationCheck: (Int) throws -> Void
) rethrows {
    operationCount += 1
    if operationCount == 1 || operationCount.isMultiple(of: 256) {
        try cancellationCheck(operationCount)
    }
}

private struct ActivityEvidenceSweepIndex {
    private let orderedIndexByMember: [Int]
    private let memberGroup: [Int]
    private let membersByID: [UUID: [Int]]
    private let groupTimestamps: [Date]
    private var memberIsLive: [Bool]
    private var memberPrevious: [Int]
    private var memberNext: [Int]
    private var groupHead: [Int]
    private var groupLiveCount: [Int]
    private var groupPrevious: [Int]
    private var groupNext: [Int]
    private var firstActiveGroup: Int
    private var leftCursor = -1

    init(
        source: ActivitySensorSource,
        ordered: [ActivitySensorEvidence],
        operationCount: inout Int,
        cancellationCheck: (Int) throws -> Void
    ) rethrows {
        var orderedIndexByMember: [Int] = []
        var memberGroup: [Int] = []
        var membersByID: [UUID: [Int]] = [:]
        var groupTimestamps: [Date] = []
        var memberPrevious: [Int] = []
        var memberNext: [Int] = []
        var groupHead: [Int] = []
        var groupTail: [Int] = []
        var groupLiveCount: [Int] = []
        var groupPrevious: [Int] = []
        var groupNext: [Int] = []

        for orderedIndex in ordered.indices {
            try activityFusionStep(&operationCount, cancellationCheck: cancellationCheck)
            let value = ordered[orderedIndex]
            guard value.source == source else { continue }

            let member = orderedIndexByMember.count
            let group: Int
            if let lastGroup = groupTimestamps.indices.last,
               groupTimestamps[lastGroup] == value.timestamp {
                group = lastGroup
                memberPrevious.append(groupTail[group])
                memberNext.append(-1)
                memberNext[groupTail[group]] = member
                groupTail[group] = member
                groupLiveCount[group] += 1
            } else {
                group = groupTimestamps.count
                groupTimestamps.append(value.timestamp)
                memberPrevious.append(-1)
                memberNext.append(-1)
                groupHead.append(member)
                groupTail.append(member)
                groupLiveCount.append(1)
                groupPrevious.append(group - 1)
                groupNext.append(group + 1)
            }

            orderedIndexByMember.append(orderedIndex)
            memberGroup.append(group)
            membersByID[value.id, default: []].append(member)
        }

        if !groupNext.isEmpty {
            groupNext[groupNext.count - 1] = -1
        }
        self.orderedIndexByMember = orderedIndexByMember
        self.memberGroup = memberGroup
        self.membersByID = membersByID
        self.groupTimestamps = groupTimestamps
        self.memberIsLive = Array(repeating: true, count: orderedIndexByMember.count)
        self.memberPrevious = memberPrevious
        self.memberNext = memberNext
        self.groupHead = groupHead
        self.groupLiveCount = groupLiveCount
        self.groupPrevious = groupPrevious
        self.groupNext = groupNext
        self.firstActiveGroup = groupTimestamps.isEmpty ? -1 : 0
    }

    mutating func nearestCandidate(
        to timestamp: Date,
        within window: TimeInterval,
        ordered: [ActivitySensorEvidence],
        operationCount: inout Int,
        cancellationCheck: (Int) throws -> Void
    ) rethrows -> Int? {
        while true {
            let next = leftCursor < 0 ? firstActiveGroup : groupNext[leftCursor]
            try activityFusionStep(&operationCount, cancellationCheck: cancellationCheck)
            guard next >= 0, groupTimestamps[next] <= timestamp else { break }
            leftCursor = next
        }

        let leftGroup = leftCursor
        let rightGroup = leftGroup < 0 ? firstActiveGroup : groupNext[leftGroup]
        var bestMember = -1

        if leftGroup >= 0 {
            operationCount += 1
            let distance = timestamp.timeIntervalSince(groupTimestamps[leftGroup])
            if distance <= window, groupHead[leftGroup] >= 0 {
                consider(
                    groupHead[leftGroup],
                    against: &bestMember,
                    timestamp: timestamp,
                    ordered: ordered,
                    operationCount: &operationCount
                )
            }
        }

        if rightGroup >= 0, rightGroup != leftGroup {
            operationCount += 1
            let distance = groupTimestamps[rightGroup].timeIntervalSince(timestamp)
            if distance <= window, groupHead[rightGroup] >= 0 {
                consider(
                    groupHead[rightGroup],
                    against: &bestMember,
                    timestamp: timestamp,
                    ordered: ordered,
                    operationCount: &operationCount
                )
            }
        }

        return bestMember < 0 ? nil : orderedIndexByMember[bestMember]
    }

    mutating func consume(
        id: UUID,
        operationCount: inout Int,
        cancellationCheck: (Int) throws -> Void
    ) rethrows {
        guard let members = membersByID[id] else {
            try activityFusionStep(&operationCount, cancellationCheck: cancellationCheck)
            return
        }
        for member in members {
            try activityFusionStep(&operationCount, cancellationCheck: cancellationCheck)
            guard memberIsLive[member] else { continue }

            let group = memberGroup[member]
            let previous = memberPrevious[member]
            let next = memberNext[member]
            if previous >= 0 {
                memberNext[previous] = next
            } else {
                groupHead[group] = next
            }
            if next >= 0 {
                memberPrevious[next] = previous
            }
            memberIsLive[member] = false
            groupLiveCount[group] -= 1

            if groupLiveCount[group] == 0 {
                removeGroup(group, operationCount: &operationCount)
            }
        }
    }

    private func consider(
        _ candidate: Int,
        against bestMember: inout Int,
        timestamp: Date,
        ordered: [ActivitySensorEvidence],
        operationCount: inout Int
    ) {
        guard bestMember >= 0 else {
            bestMember = candidate
            return
        }

        operationCount += 1
        let candidateEvidence = ordered[orderedIndexByMember[candidate]]
        let bestEvidence = ordered[orderedIndexByMember[bestMember]]
        let candidateDistance = abs(candidateEvidence.timestamp.timeIntervalSince(timestamp))
        let bestDistance = abs(bestEvidence.timestamp.timeIntervalSince(timestamp))
        if candidateDistance < bestDistance
            || (candidateDistance == bestDistance
                && ActivityUUIDOrder.precedes(candidateEvidence.id, bestEvidence.id)) {
            bestMember = candidate
        }
    }

    private mutating func removeGroup(_ group: Int, operationCount: inout Int) {
        operationCount += 1
        let previous = groupPrevious[group]
        let next = groupNext[group]
        if previous >= 0 {
            groupNext[previous] = next
        } else {
            firstActiveGroup = next
        }
        if next >= 0 {
            groupPrevious[next] = previous
        }
        if leftCursor == group {
            leftCursor = previous
        }
        groupPrevious[group] = -1
        groupNext[group] = -1
    }
}

public enum ActivitySensorEvidenceFusion {
    public static let defaultMatchingWindow: TimeInterval = 2

    public static func fuse(
        _ evidence: [ActivitySensorEvidence],
        matchingWindow: TimeInterval = defaultMatchingWindow
    ) -> [ActivitySensorEvidence] {
        var ignoredOperationCount = 0
        return fuse(
            evidence,
            matchingWindow: matchingWindow,
            sweepOperationCount: &ignoredOperationCount
        )
    }

    public static func fuse(
        _ evidence: [ActivitySensorEvidence],
        matchingWindow: TimeInterval = defaultMatchingWindow,
        cancellationCheck: @Sendable () throws -> Void
    ) rethrows -> [ActivitySensorEvidence] {
        var operationCount = 0
        return try fuse(
            evidence,
            matchingWindow: matchingWindow,
            sweepOperationCount: &operationCount,
            cancellationCheck: { _ in try cancellationCheck() }
        )
    }

    static func fuse(
        _ evidence: [ActivitySensorEvidence],
        matchingWindow: TimeInterval,
        sweepOperationCount: inout Int
    ) -> [ActivitySensorEvidence] {
        fuse(
            evidence,
            matchingWindow: matchingWindow,
            sweepOperationCount: &sweepOperationCount,
            cancellationCheck: { _ in }
        )
    }

    static func fuse(
        _ evidence: [ActivitySensorEvidence],
        matchingWindow: TimeInterval,
        sweepOperationCount: inout Int,
        cancellationCheck: (Int) throws -> Void
    ) rethrows -> [ActivitySensorEvidence] {
        sweepOperationCount = 0
        try cancellationCheck(sweepOperationCount)
        var valid: [ActivitySensorEvidence] = []
        var hasWatch = false
        for value in evidence {
            try activityFusionStep(&sweepOperationCount, cancellationCheck: cancellationCheck)
            guard ActivityTimestamp.isValid(value.timestamp) else { continue }
            valid.append(value)
            if value.source == .appleWatch {
                hasWatch = true
            }
        }
        let ordered = try cancellableSort(
            valid,
            operationCount: &sweepOperationCount,
            cancellationCheck: cancellationCheck,
            by: earlierEvidence
        )
        guard hasWatch else { return ordered }

        let window = matchingWindow.isFinite
            ? max(0, matchingWindow)
            : defaultMatchingWindow
        var phones = try ActivityEvidenceSweepIndex(
            source: .iPhone,
            ordered: ordered,
            operationCount: &sweepOperationCount,
            cancellationCheck: cancellationCheck
        )
        var watches = try ActivityEvidenceSweepIndex(
            source: .appleWatch,
            ordered: ordered,
            operationCount: &sweepOperationCount,
            cancellationCheck: cancellationCheck
        )
        var consumed = Set<UUID>()
        var result: [ActivitySensorEvidence] = []

        for candidate in ordered {
            try activityFusionStep(&sweepOperationCount, cancellationCheck: cancellationCheck)
            guard !consumed.contains(candidate.id) else { continue }
            guard candidate.source != .combined else {
                result.append(candidate)
                consumed.insert(candidate.id)
                try phones.consume(
                    id: candidate.id,
                    operationCount: &sweepOperationCount,
                    cancellationCheck: cancellationCheck
                )
                try watches.consume(
                    id: candidate.id,
                    operationCount: &sweepOperationCount,
                    cancellationCheck: cancellationCheck
                )
                continue
            }

            let counterpartIndex: Int?
            switch candidate.source {
            case .iPhone:
                counterpartIndex = try watches.nearestCandidate(
                    to: candidate.timestamp,
                    within: window,
                    ordered: ordered,
                    operationCount: &sweepOperationCount,
                    cancellationCheck: cancellationCheck
                )
            case .appleWatch:
                counterpartIndex = try phones.nearestCandidate(
                    to: candidate.timestamp,
                    within: window,
                    ordered: ordered,
                    operationCount: &sweepOperationCount,
                    cancellationCheck: cancellationCheck
                )
            case .combined:
                counterpartIndex = nil
            }

            if let counterpartIndex {
                let counterpart = ordered[counterpartIndex]
                let phone = candidate.source == .iPhone ? candidate : counterpart
                let watch = candidate.source == .appleWatch ? candidate : counterpart
                result.append(combined(phone: phone, watch: watch))
                consumed.insert(counterpart.id)
                try phones.consume(
                    id: counterpart.id,
                    operationCount: &sweepOperationCount,
                    cancellationCheck: cancellationCheck
                )
                try watches.consume(
                    id: counterpart.id,
                    operationCount: &sweepOperationCount,
                    cancellationCheck: cancellationCheck
                )
            } else {
                result.append(candidate)
            }
            consumed.insert(candidate.id)
            try phones.consume(
                id: candidate.id,
                operationCount: &sweepOperationCount,
                cancellationCheck: cancellationCheck
            )
            try watches.consume(
                id: candidate.id,
                operationCount: &sweepOperationCount,
                cancellationCheck: cancellationCheck
            )
        }

        return try cancellableSort(
            result,
            operationCount: &sweepOperationCount,
            cancellationCheck: cancellationCheck,
            by: earlierEvidence
        )
    }

    private static func cancellableSort(
        _ values: [ActivitySensorEvidence],
        operationCount: inout Int,
        cancellationCheck: (Int) throws -> Void,
        by areInIncreasingOrder: (ActivitySensorEvidence, ActivitySensorEvidence) -> Bool
    ) rethrows -> [ActivitySensorEvidence] {
        guard values.count > 1 else {
            try cancellationCheck(operationCount)
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
                    try activityFusionStep(&operationCount, cancellationCheck: cancellationCheck)
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
        try cancellationCheck(operationCount)
        return source
    }

    private static func earlierEvidence(
        _ lhs: ActivitySensorEvidence,
        _ rhs: ActivitySensorEvidence
    ) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        return ActivityUUIDOrder.precedes(lhs.id, rhs.id)
    }

    private static func combined(
        phone: ActivitySensorEvidence,
        watch: ActivitySensorEvidence
    ) -> ActivitySensorEvidence {
        let watchBehavior = watch.behaviorHint ?? watch.detailHint ?? watch.categoryHint
        let phoneBehavior = phone.behaviorHint ?? phone.detailHint ?? phone.categoryHint
        let sequence = [phone.sequence, watch.sequence].compactMap { $0 }.max()
        let confidence = [phone.confidence, watch.confidence].compactMap { $0 }.max()
        return ActivitySensorEvidence(
            id: ActivityStableID.uuid(seed: "combined|\(phone.id.uuidString)|\(watch.id.uuidString)"),
            timestamp: min(phone.timestamp, watch.timestamp),
            motion: watch.motion == .unknown ? phone.motion : watch.motion,
            speedMetersPerSecond: phone.speedMetersPerSecond ?? watch.speedMetersPerSecond,
            horizontalAccuracyMeters: phone.horizontalAccuracyMeters ?? watch.horizontalAccuracyMeters,
            isPreciseLocation: phone.isPreciseLocation || watch.isPreciseLocation,
            stepCount: watch.stepCount ?? phone.stepCount,
            screenIsOn: phone.screenIsOn ?? watch.screenIsOn,
            screenBrightness: phone.screenBrightness ?? watch.screenBrightness,
            categoryHint: watch.categoryHint ?? phone.categoryHint,
            detailHint: watch.detailHint ?? phone.detailHint,
            behaviorHint: watchBehavior ?? phoneBehavior,
            confidence: confidence,
            evidence: unique(phone.evidence + watch.evidence + ["Apple Watch + iPhone 조합"]),
            sequence: sequence,
            source: .combined
        )
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

public struct ActivityClassificationProjection: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let inputEvidence: [ActivitySensorEvidence]
    public let state: ActivityClassificationState
    public let majorCategoryIDs: [String]

    public init(
        engine: ActivityClassificationEngine = .init(),
        evidence: [ActivitySensorEvidence],
        overrides: [ActivityClassificationOverride] = []
    ) {
        version = Self.currentVersion
        inputEvidence = evidence
        let fused = ActivitySensorEvidenceFusion.fuse(evidence)
        let validMajorIDs = Set(engine.taxonomy.majors.map(\.id))
        let safeOverrides = overrides.map { override in
            guard validMajorIDs.contains(override.majorCategoryID) else {
                return ActivityClassificationOverride(
                    id: override.id,
                    span: override.span,
                    majorCategoryID: engine.taxonomy.majors.first?.id ?? "activity",
                    detailID: nil,
                    title: override.title,
                    behavior: override.behavior,
                    updatedAt: override.updatedAt,
                    isLocked: override.isLocked,
                    isUserConfirmed: override.isUserConfirmed
                )
            }
            return override
        }
        state = engine.classifyState(fused, overrides: safeOverrides)
        var seen = Set<String>()
        majorCategoryIDs = state.segments.compactMap {
            seen.insert($0.majorCategoryID).inserted ? $0.majorCategoryID : nil
        }
    }

    public init(
        engine: ActivityClassificationEngine = .init(),
        evidence: [ActivitySensorEvidence],
        overrides: [ActivityClassificationOverride] = [],
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) throws {
        version = Self.currentVersion
        inputEvidence = evidence
        let fused = try ActivitySensorEvidenceFusion.fuse(
            evidence,
            cancellationCheck: cancellationCheck
        )
        let validMajorIDs = Set(engine.taxonomy.majors.map(\.id))
        var safeOverrides: [ActivityClassificationOverride] = []
        safeOverrides.reserveCapacity(overrides.count)
        for (index, override) in overrides.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            guard validMajorIDs.contains(override.majorCategoryID) else {
                safeOverrides.append(ActivityClassificationOverride(
                    id: override.id,
                    span: override.span,
                    majorCategoryID: engine.taxonomy.majors.first?.id ?? "activity",
                    detailID: nil,
                    title: override.title,
                    behavior: override.behavior,
                    updatedAt: override.updatedAt,
                    isLocked: override.isLocked,
                    isUserConfirmed: override.isUserConfirmed
                ))
                continue
            }
            safeOverrides.append(override)
        }
        state = try engine.classifyState(
            fused,
            overrides: safeOverrides,
            cancellationCheck: { _ in try cancellationCheck() }
        )
        var seen = Set<String>()
        var categoryIDs: [String] = []
        categoryIDs.reserveCapacity(state.segments.count)
        for (index, segment) in state.segments.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            if seen.insert(segment.majorCategoryID).inserted {
                categoryIDs.append(segment.majorCategoryID)
            }
        }
        majorCategoryIDs = categoryIDs
    }
}
