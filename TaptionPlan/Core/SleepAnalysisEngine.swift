import Foundation

struct SleepAnalysisEngine: Sendable {
    var maximumGapBetweenSegments: TimeInterval = 90 * 60

    /// HealthKit's overnight sleep for a calendar day starts the evening
    /// before and ends at noon of that day.  Keeping the boundary in one
    /// place makes the query deterministic across midnight and time zones.
    static func overnightSpan(
        containing date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> TimeSpan {
        let dayStart = calendar.startOfDay(for: date)
        let start = calendar.date(
            byAdding: .hour,
            value: -6,
            to: dayStart
        ) ?? dayStart.addingTimeInterval(-6 * 3_600)
        let end = calendar.date(
            byAdding: .hour,
            value: 12,
            to: dayStart
        ) ?? dayStart.addingTimeInterval(12 * 3_600)
        return TimeSpan(start: start, end: end)
    }

    func sessions(
        from segments: [SleepSegment],
        inside requestedSpan: TimeSpan? = nil
    ) -> [SleepSession] {
        // 요청 구간으로 먼저 자른 뒤 등급을 따진다. 구간 밖의 워치 기록 때문에
        // 구간 안의 아이폰 기록이 지워지는 일을 막기 위해서다.
        let withinSpan = deduplicatedSegments(segments).compactMap { segment -> SleepSegment? in
            guard let requestedSpan else { return segment }
            guard let overlap = segment.span.intersection(with: requestedSpan) else {
                return nil
            }
            var value = segment
            value.span = overlap
            return value
        }
        let clipped = suppressingLowerTierClaims(in: withinSpan)
        let ordered = clipped.sorted {
            if $0.span.start == $1.span.start {
                return $0.span.end < $1.span.end
            }
            return $0.span.start < $1.span.start
        }
        guard let first = ordered.first else { return [] }

        var groups: [[SleepSegment]] = []
        var current = [first]
        var currentEnd = first.span.end

        for segment in ordered.dropFirst() {
            if segment.span.start.timeIntervalSince(currentEnd) > maximumGapBetweenSegments {
                groups.append(current)
                current = [segment]
                currentEnd = segment.span.end
            } else {
                current.append(segment)
                currentEnd = max(currentEnd, segment.span.end)
            }
        }
        groups.append(current)

        return groups.compactMap(makeSession)
    }

    private func makeSession(_ segments: [SleepSegment]) -> SleepSession? {
        let asleepSegments = segments.filter(\.stage.isAsleep)
        // iPhone and third-party HealthKit sources may provide only an
        // `inBed` sample. Preserve that source record instead of requiring an
        // Apple Watch sleep stage.
        let sessionSegments = asleepSegments.isEmpty
            ? segments.filter { $0.stage == .inBed }
            : asleepSegments
        guard let first = sessionSegments.min(by: { $0.span.start < $1.span.start }) else {
            return nil
        }
        let last = sessionSegments.max(by: { $0.span.end < $1.span.end }) ?? first
        let inBedDuration = unionDuration(
            segments.filter { $0.stage == .inBed }.map(\.span)
        )
        let asleepDuration: TimeInterval
        let stageDurations = resolvedStageDurations(segments)
        asleepDuration = stageDurations.reduce(0) {
            $0 + ($1.key.isAsleep ? $1.value : 0)
        }
        guard asleepDuration > 0 || inBedDuration > 0 else { return nil }

        let sessionEnd: Date
        if asleepSegments.isEmpty {
            sessionEnd = segments
                .filter { $0.stage == .inBed }
                .map(\.span.end)
                .max() ?? last.span.end
        } else {
            sessionEnd = segments
                .filter { $0.stage == .awake && $0.span.end > last.span.end }
                .map(\.span.end)
                .max() ?? last.span.end
        }

        return SleepSession(
            id: first.id,
            span: TimeSpan(start: first.span.start, end: sessionEnd),
            asleepDuration: asleepDuration,
            awakeDuration: stageDurations[.awake, default: 0],
            inBedDuration: inBedDuration,
            stageDurations: stageDurations,
            sourceNames: unique(
                segments.map(\.sourceName).filter { !$0.isEmpty }
            ),
            segments: segments.sorted { $0.span.start < $1.span.start }
        )
    }

    private func resolvedStageDurations(
        _ segments: [SleepSegment]
    ) -> [SleepStage: TimeInterval] {
        let boundaries = Array(
            Set(segments.flatMap { [$0.span.start, $0.span.end] })
        ).sorted()
        guard boundaries.count >= 2 else { return [:] }

        var durations: [SleepStage: TimeInterval] = [:]
        for (start, end) in zip(boundaries, boundaries.dropFirst()) {
            guard start < end else { continue }
            let active = segments.filter {
                $0.span.start < end && start < $0.span.end
            }
            // 겹친 구간은 먼저 출처 등급으로, 같은 등급 안에서는 단계의
            // 구체성으로 고른다. 워치가 잰 구간에 아이폰 추정이 덮이지 않는다.
            guard let selected = active.max(by: { lhs, rhs in
                let left = (lhs.sourceTier.priority, stagePriority(lhs.stage))
                let right = (rhs.sourceTier.priority, stagePriority(rhs.stage))
                return left < right
            }) else {
                continue
            }
            durations[selected.stage, default: 0] += end.timeIntervalSince(start)
        }
        return durations
    }

    private func unionDuration(_ spans: [TimeSpan]) -> TimeInterval {
        let ordered = spans.sorted { $0.start < $1.start }
        guard var current = ordered.first else { return 0 }
        var duration: TimeInterval = 0

        for span in ordered.dropFirst() {
            if span.start <= current.end {
                current.end = max(current.end, span.end)
            } else {
                duration += current.duration
                current = span
            }
        }
        return duration + current.duration
    }

    private func deduplicatedSegments(
        _ segments: [SleepSegment]
    ) -> [SleepSegment] {
        var seen = Set<UUID>()
        return segments.filter { seen.insert($0.id).inserted }
    }

    // MARK: - 출처 등급

    /// 그 밤에 더 높은 등급의 수면 주장이 있으면, 그 시간을 덮는 낮은 등급의
    /// 수면·기상 주장을 버린다. 애플워치가 밤을 직접 쟀다면 아이폰의 추정이
    /// 그 위에 섞이지 않게 하려는 것이다.
    ///
    /// 겹치는 구간만 지우므로 워치가 자지 않은 낮잠(다른 시간대)은 그대로 남고,
    /// `inBed`는 수면 주장이 아니라 수면 효율의 분모라서 건드리지 않는다.
    private func suppressingLowerTierClaims(
        in segments: [SleepSegment]
    ) -> [SleepSegment] {
        let claims = segments.filter { $0.stage.isAsleep || $0.stage == .awake }
        guard let authority = claims
            .filter(\.stage.isAsleep)
            .map(\.sourceTier)
            .max(by: { $0.priority < $1.priority }),
            authority != .unknown else {
            return segments
        }
        let authorityClaims = claims.filter { $0.sourceTier == authority }
        guard !authorityClaims.isEmpty else { return segments }

        return segments.filter { segment in
            guard segment.stage.isAsleep || segment.stage == .awake else {
                return true
            }
            guard segment.sourceTier.priority < authority.priority else {
                return true
            }
            return !authorityClaims.contains {
                $0.span.intersection(with: segment.span) != nil
            }
        }
    }

    /// 워치 기록이 늦게 도착했을 때, 아이폰으로 먼저 만든 잠정 결과를 어떻게
    /// 고쳤는지 기록한다. `previous`는 새 결과로 갈아 끼우기 전의 세션들이다.
    func reconciliations(
        previous: [SleepSession],
        resolved: [SleepSession],
        inside span: TimeSpan? = nil,
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [SleepReconciliation] {
        guard !resolved.isEmpty, !previous.isEmpty else { return [] }
        var result: [SleepReconciliation] = []
        for session in resolved where session.isWatchAuthoritative {
            // 기상 시각이 속한 밤을 기준으로 삼는다. 세션 시작(밤 11시)으로
            // 잡으면 자정을 넘긴 새벽 구간이 창 밖으로 밀린다.
            let night = Self.overnightSpan(
                containing: session.span.end,
                calendar: calendar
            )
            let estimate = previous
                .filter { candidate in
                    guard candidate.isProvisional else { return false }
                    if let span,
                       candidate.span.intersection(with: span) == nil {
                        return false
                    }
                    return candidate.span.intersection(with: night) != nil
                }
                .max { $0.asleepDuration < $1.asleepDuration }
            guard let estimate else { continue }
            result.append(
                SleepReconciliation(
                    id: UUID(),
                    overnightDate: calendar.startOfDay(for: session.span.end),
                    estimatedTier: estimate.sourceTier,
                    estimatedSpan: estimate.span,
                    estimatedAsleepDuration: estimate.asleepDuration,
                    authoritativeTier: session.sourceTier,
                    authoritativeSpan: session.span,
                    authoritativeAsleepDuration: session.asleepDuration,
                    reason: .watchReplacedEstimate,
                    reconciledAt: now
                )
            )
        }
        return result
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func stagePriority(_ stage: SleepStage) -> Int {
        stage.overlapPriority
    }
}

/// 새로 읽은 수면 세션을 기존 목록에 갈아 끼우고, 그때 워치가 아이폰 추정을
/// 고쳤는지 함께 돌려준다. 목록을 통째로 다루는 일을 모델 밖으로 뺀다.
enum SleepSessionInstallation {
    struct Result: Sendable {
        var sessions: [SleepSession]
        var reconciliations: [SleepReconciliation]
    }

    /// `predicate`가 참인 기존 세션만 새 세션으로 교체한다. 워치 스냅샷 경로는
    /// 워치가 확정한 세션만 갈아 끼우므로 이 필터가 필요하다.
    static func installing(
        _ fresh: [SleepSession],
        into current: [SleepSession],
        inside span: TimeSpan?,
        replacing predicate: (SleepSession) -> Bool = { _ in true },
        now: Date = .now
    ) -> Result {
        let replaced = current.filter { session in
            guard predicate(session) else { return false }
            guard let span else { return true }
            return session.span.intersection(with: span) != nil
        }
        let kept = current.filter { !replaced.contains($0) }
        return Result(
            sessions: (kept + fresh).sorted { $0.span.start < $1.span.start },
            reconciliations: SleepAnalysisEngine().reconciliations(
                previous: replaced,
                resolved: fresh,
                inside: span,
                now: now
            )
        )
    }
}

/// 워치가 아이폰 추정을 갈아 끼운 기록을 쌓는다. 같은 밤·같은 사유는 최신
/// 것으로 교체하고 최근 30건만 남긴다.
enum SleepReconciliationLedger {
    static let limit = 30

    static func appending(
        _ records: [SleepReconciliation],
        to existing: [SleepReconciliation]
    ) -> [SleepReconciliation] {
        guard !records.isEmpty else { return existing }
        var result = existing
        for record in records {
            result.removeAll {
                $0.overnightDate == record.overnightDate
                    && $0.reason == record.reason
            }
            result.append(record)
            TaptionPlanDiagnosticsLogger.shared.record(
                "sleep_watch_reconciled",
                fields: [
                    "estimated_tier": record.estimatedTier.rawValue,
                    "estimated_asleep_minutes": String(
                        Int(record.estimatedAsleepDuration / 60)
                    ),
                    "authoritative_tier": record.authoritativeTier.rawValue,
                    "authoritative_asleep_minutes": String(
                        Int(record.authoritativeAsleepDuration / 60)
                    ),
                    "asleep_minutes_delta": String(
                        Int(record.asleepDurationDelta / 60)
                    ),
                    "start_minutes_delta": String(
                        Int(record.spanStartDelta / 60)
                    ),
                ]
            )
        }
        result.sort { $0.reconciledAt < $1.reconciledAt }
        if result.count > limit {
            result.removeFirst(result.count - limit)
        }
        return result
    }
}
