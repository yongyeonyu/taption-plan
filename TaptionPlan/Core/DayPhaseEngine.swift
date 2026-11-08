import Foundation
import TaptionPlanEngine

/// 하루를 겹치지 않는 일과 한 줄로 요약한다. 현재 화면은 수면·이동·운동·
/// 업무·학업·취미·활동·미확인만 사용하고, 예전 세부 일과 값은 보관 자료와
/// 하위 기능의 호환을 위해 남겨 둔다.
enum DayPhase: String, CaseIterable, Sendable {
    case unconfirmed
    case sleep
    case movement
    case exercise
    case hobby
    case activity
    case appointment
    case commuteToWork
    case commuteToSchool
    case commuteToAcademy
    case activityDeparture
    case work
    case study
    case commuteHomeFromWork
    case commuteHomeFromSchool
    case commuteHomeFromAcademy
    case activityReturn
    case evening

    static let timelineRows: [Self] = [
        .sleep, .movement, .exercise, .work, .study, .hobby, .activity,
        .appointment, .unconfirmed,
    ]

    var title: String {
        switch self {
        case .unconfirmed: "미확인"
        case .sleep: "수면"
        case .movement: "이동"
        case .exercise: "운동"
        case .hobby: "취미"
        case .activity: "활동"
        case .appointment: "약속"
        case .commuteToWork: "출근"
        case .commuteToSchool: "등교"
        case .commuteToAcademy: "등원"
        case .activityDeparture: "시작"
        case .work: "업무"
        case .study: "수업"
        case .commuteHomeFromWork: "퇴근"
        case .commuteHomeFromSchool: "하교"
        case .commuteHomeFromAcademy: "하원"
        case .activityReturn: "종료"
        case .evening: "저녁"
        }
    }

    /// 활동은 겹친 일과 중 해당 종류의 줄에만 배치한다. 특히 일반 활동이
    /// 수면 구간을 빌려 수면 줄에 그려지지 않게 한다.
    static func phase(forActivityCategory categoryID: String) -> Self {
        switch categoryID {
        case "sleep": .sleep
        case "movement": .movement
        case "exercise", "workout": .exercise
        case "work": .work
        case "study": .study
        case "hobby": .hobby
        case "unconfirmed": .unconfirmed
        default: .activity
        }
    }

    /// 같은 시각을 두 근거가 주장해도 일과는 하나만 남긴다. 확정 운동이 가장
    /// 강하고, 수면은 업무·학업·취미보다 우선한다. 이동과 일반 활동은 그
    /// 위 분류들이 비운 구간만 채운다.
    var precedence: Int {
        switch self {
        case .exercise: 8
        case .sleep: 7
        case .work, .study, .hobby: 6
        case .movement: 5
        case .commuteToWork, .commuteToSchool, .commuteToAcademy,
             .activityDeparture,
             .commuteHomeFromWork, .commuteHomeFromSchool,
             .commuteHomeFromAcademy, .activityReturn: 4
        case .appointment: 4
        case .activity: 2
        case .evening: 1
        case .unconfirmed: 0
        }
    }
}

struct DayPhaseSpan: Equatable, Sendable {
    let phase: DayPhase
    let span: TimeSpan
}

/// 이미 만들어 둔 수면 기록·정지 문맥·이동 구간만 읽어 하루를 겹치지 않는
/// 줄거리로 나눈다. 새로 수집하는 값은 없고, 근거가 없는 과거는 `미확인`으로
/// 채워 상위 기간에서 하루가 정확히 24시간이 되게 한다.
enum DayPhaseEngine {
    /// 하루보다 넓은 기간에서는 여러 날의 줄거리가 같은 각도에 겹쳐 뭉개진다.
    /// 그때는 아무것도 만들지 않는다.
    static let maximumSpanDuration: TimeInterval = 26 * 3_600

    /// 이동과 앞뒤 머무름이 이만큼 안에서 맞닿으면 한 오감으로 본다.
    static let joinTolerance: TimeInterval = 15 * 60

    /// 갈아타는 사이의 기다림. 이보다 짧게 끊긴 이동은 한 번의 오감이다.
    static let transferGap: TimeInterval = 20 * 60

    static func phases(
        actuals: [ActualRecord],
        travel: [TravelSegment],
        stays: [PlaceStay],
        placeKinds: [String: FrequentPlaceKind],
        in span: TimeSpan,
        asOf: Date = .now
    ) -> [DayPhaseSpan] {
        guard span.duration > 0, span.duration <= maximumSpanDuration else {
            return []
        }
        // 자정 직전에 시작한 오감의 도착지를 놓치지 않도록 하루 앞뒤를 조금
        // 넓혀 근거를 읽고, 조각은 마지막에 하루로 자른다.
        let margin = joinTolerance + transferGap
        let window = TimeSpan(
            start: span.start.addingTimeInterval(-margin),
            end: span.end.addingTimeInterval(margin)
        )
        // Filter by time once before classifying titles or grouping places.
        // The margin keeps overnight records and commute arrival evidence.
        let actuals = actuals.filter {
            $0.span(asOf: asOf).intersection(with: window) != nil
        }
        let travel = travel.filter { $0.span.intersection(with: window) != nil }
        let stays = stays.filter { $0.span.intersection(with: window) != nil }
        let contexts = stationaryContexts(actuals, in: window, asOf: asOf)
        let workBlocks = destinationAwareBlocks(
                contexts,
                kind: .work,
                as: .work,
                stays: stays,
                placeKinds: placeKinds,
                in: window,
                returnGap: 2 * 60 * 60,
                matchesDestination: { $0 == .company }
            )
        let studyBlocks = destinationAwareBlocks(
                contexts,
                kind: .study,
                as: .study,
                stays: stays,
                placeKinds: placeKinds,
                in: window,
                returnGap: 2 * 60 * 60,
                matchesDestination: { $0 == .school || $0 == .academy }
            )
        let hobbyBlocks = destinationAwareBlocks(
            contexts,
            kind: .hobby,
            as: .hobby,
            stays: stays,
            placeKinds: placeKinds,
            in: window,
            returnGap: 2 * 60 * 60,
            matchesDestination: { $0 == .hobby }
        )
        let facilityExerciseBlocks = destinationAwareBlocks(
            contexts,
            kind: .gymFacility,
            as: .exercise,
            stays: stays,
            placeKinds: placeKinds,
            in: window,
            returnGap: 15 * 60,
            matchesDestination: { $0 == .exercise }
        )
        let sleepSpans = ActualIntervalMergeEngine.union(
            actuals
                .filter(AutomaticRecordTimelineEngine.isSleep)
                .compactMap { $0.span(asOf: asOf).intersection(with: window) },
            mergeGap: 0
        )
        let exerciseSpans = ActualIntervalMergeEngine.union(
            actuals.compactMap { actual -> TimeSpan? in
                guard AutomaticRecordTimelineEngine.isConfirmedWorkout(actual)
                else { return nil }
                return actual.span(asOf: asOf).intersection(with: window)
            } + facilityExerciseBlocks.map(\.span),
            mergeGap: 60
        )
        let movementEvidence = travel.compactMap {
            $0.span.intersection(with: window)
        } + actuals.compactMap { actual -> TimeSpan? in
            guard actual.source != .manual,
                  actual.source != .timer,
                  ActualRecordCategoryResolver.categoryID(for: actual)
                    == "movement" else { return nil }
            return actual.span(asOf: asOf).intersection(with: window)
        }
        let movementSpans = ActualIntervalMergeEngine.union(
            movementEvidence.flatMap {
                ActualIntervalMergeEngine.subtracting(exerciseSpans, from: $0)
            },
            mergeGap: 60
        )
        let phaseBlocks: [(DayPhase, [DayPhaseSpan])] = [
            (.work, workBlocks), (.study, studyBlocks),
            (.hobby, hobbyBlocks),
        ]
        let broadBlocks = phaseBlocks.flatMap { phase, blocks in
            let actualSpans = automaticSpans(
                actuals,
                in: window,
                asOf: asOf,
                categoryID: phase.rawValue
            )
            return ActualIntervalMergeEngine.union(
                blocks.map(\.span) + actualSpans,
                mergeGap: 60
            ).map { DayPhaseSpan(phase: phase, span: $0) }
        }
        let activitySpans = ActualIntervalMergeEngine.union(
            contexts.map(\.span) + automaticSpans(
                actuals,
                in: window,
                asOf: asOf,
                // "eating"이 빠지면 자동 식사 기록이 미확인으로 남았다.
                categoryIDs: [
                    "activity", "rest", "routine", "housework", "food", "eating",
                    "relationship", "health", "appUsage",
                ]
            ),
            mergeGap: 60
        )

        let candidates = broadBlocks
            + exerciseSpans.map { DayPhaseSpan(phase: .exercise, span: $0) }
            + sleepSpans.map { DayPhaseSpan(phase: .sleep, span: $0) }
            + movementSpans.map { DayPhaseSpan(phase: .movement, span: $0) }
            + activitySpans.map { DayPhaseSpan(phase: .activity, span: $0) }
        return resolved(
            candidates.compactMap { value in
                value.span.intersection(with: span).map {
                    DayPhaseSpan(phase: value.phase, span: $0)
                }
            }
        )
    }

    /// 표시·상위 집계용 일과. 기록이 존재하는 과거 구간은 근거가 없는 자리도
    /// `미확인`으로 채워 하루가 끝났을 때 정확히 24시간이 되게 한다. 현재
    /// 시각 이후는 자동 기록으로 만들지 않는다.
    static func completePhases(
        actuals: [ActualRecord],
        travel: [TravelSegment],
        stays: [PlaceStay],
        placeKinds: [String: FrequentPlaceKind],
        in span: TimeSpan,
        asOf: Date = .now
    ) -> [DayPhaseSpan] {
        guard span.duration <= maximumSpanDuration else { return [] }
        let end = min(span.end, asOf)
        guard end > span.start else { return [] }
        let observed = TimeSpan(start: span.start, end: end)
        let known = phases(
            actuals: actuals,
            travel: travel,
            stays: stays,
            placeKinds: placeKinds,
            in: span,
            asOf: asOf
        ).compactMap { value in
            value.span.intersection(with: observed).map {
                DayPhaseSpan(phase: value.phase, span: $0)
            }
        }
        let unknown = ActualIntervalMergeEngine.subtracting(
            known.map(\.span),
            from: observed
        ).map { DayPhaseSpan(phase: .unconfirmed, span: $0) }
        return (known + unknown).sorted { $0.span.start < $1.span.start }
    }

    static func completePhasesAcrossDays(
        actuals: [ActualRecord],
        travel: [TravelSegment],
        stays: [PlaceStay],
        placeKinds: [String: FrequentPlaceKind],
        in span: TimeSpan,
        calendar: Calendar,
        asOf: Date = .now
    ) -> [DayPhaseSpan] {
        let end = min(span.end, asOf)
        guard end > span.start else { return [] }
        var result: [DayPhaseSpan] = []
        var day = calendar.startOfDay(for: span.start)
        while day < end {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day)
            else { break }
            result += completePhases(
                actuals: actuals,
                travel: travel,
                stays: stays,
                placeKinds: placeKinds,
                in: TimeSpan(
                    start: max(day, span.start),
                    end: min(next, span.end)
                ),
                asOf: asOf
            )
            day = next
        }
        return result
    }

    static func categoryDurations(
        _ phases: [DayPhaseSpan],
        scope: RecordAnalysisScope = .legacy
    ) -> [CategoryDuration] {
        var totals: [DayPhase: TimeInterval] = [:]
        for value in phases {
            totals[scope.phase(value.phase), default: 0] += value.span.duration
        }
        return totals.map {
            CategoryDuration(
                categoryID: $0.key.rawValue,
                planned: 0,
                actual: $0.value
            )
        }.sorted {
            $0.actual == $1.actual
                ? $0.categoryID < $1.categoryID
                : $0.actual > $1.actual
        }
    }

    static func assignments(
        of span: TimeSpan,
        to phases: [DayPhaseSpan]
    ) -> [DayPhaseSpan] {
        phases.compactMap { value in
            value.span.intersection(with: span).map {
                DayPhaseSpan(phase: value.phase, span: $0)
            }
        }
    }

    // MARK: - 근거 모으기

    private static func stationaryContexts(
        _ actuals: [ActualRecord],
        in window: TimeSpan,
        asOf: Date
    ) -> [(kind: StationaryContextKind, span: TimeSpan)] {
        var seen = Set<UUID>()
        return actuals.compactMap { actual in
            guard actual.source == .location,
                  let behavior = actual.behavior,
                  let kind = StationaryContextKind(rawValue: behavior),
                  seen.insert(actual.id).inserted,
                  let visible = actual.span(asOf: asOf)
                      .intersection(with: window) else {
                return nil
            }
            return (kind, visible)
        }
    }

    private static func automaticSpans(
        _ actuals: [ActualRecord],
        in window: TimeSpan,
        asOf: Date,
        categoryID: String
    ) -> [TimeSpan] {
        automaticSpans(
            actuals,
            in: window,
            asOf: asOf,
            categoryIDs: [categoryID]
        )
    }

    private static func automaticSpans(
        _ actuals: [ActualRecord],
        in window: TimeSpan,
        asOf: Date,
        categoryIDs: Set<String>
    ) -> [TimeSpan] {
        actuals.compactMap { actual in
            guard actual.source != .manual,
                  actual.source != .timer,
                  actual.source != .calendar,
                  categoryIDs.contains(
                    ActualRecordCategoryResolver.categoryID(for: actual)
                  ) else { return nil }
            return actual.span(asOf: asOf).intersection(with: window)
        }
    }

    /// 같은 목적지(회사, 학교, 학원)에 실제로 머물렀으면 오타 없이 업무/수업 문맥을
    /// 유지한다. 체류 근거가 있으면 문맥이 잠깐 비워도 같은 장소면 같은 일과를
    /// 이어서 본다.
    private static func destinationAwareBlocks(
        _ contexts: [(kind: StationaryContextKind, span: TimeSpan)],
        kind: StationaryContextKind,
        as phase: DayPhase,
        stays: [PlaceStay],
        placeKinds: [String: FrequentPlaceKind],
        in window: TimeSpan,
        returnGap: TimeInterval,
        matchesDestination: (FrequentPlaceKind) -> Bool
    ) -> [DayPhaseSpan] {
        let contextSpans = contexts
            .filter { $0.kind == kind }
            .map(\.span)

        let destinationSpans = Dictionary(grouping: stays) { $0.placeKey }
            .values.flatMap { samePlace in
            let spans = samePlace.compactMap { stay -> TimeSpan? in
            guard let kind = placeKinds[stay.placeKey],
                  matchesDestination(kind),
                  let visible = stay.span.intersection(with: window) else {
                return nil
            }
            return visible
            }
            return ActualIntervalMergeEngine.union(spans, mergeGap: returnGap)
        }

        return ActualIntervalMergeEngine.union(
            contextSpans + destinationSpans,
            mergeGap: 60
        )
        .map { DayPhaseSpan(phase: phase, span: $0) }
    }

    // MARK: - 한 줄로 펴기

    /// 경계마다 우선순위가 가장 높은 줄거리 하나만 남겨 고리를 한 줄로 만든다.
    /// 같은 줄거리가 이어지면 한 조각으로 붙인다.
    private static func resolved(_ candidates: [DayPhaseSpan]) -> [DayPhaseSpan] {
        let boundaries = Array(
            Set(candidates.flatMap { [$0.span.start, $0.span.end] })
        ).sorted()
        guard boundaries.count >= 2 else { return [] }

        var result: [DayPhaseSpan] = []
        for (start, end) in zip(boundaries, boundaries.dropFirst()) {
            guard start < end else { continue }
            let winner = candidates
                .filter { $0.span.start < end && start < $0.span.end }
                .max {
                    $0.phase.precedence == $1.phase.precedence
                        ? $0.phase.rawValue < $1.phase.rawValue
                        : $0.phase.precedence < $1.phase.precedence
                }
            guard let winner else { continue }
            if let last = result.last,
               last.phase == winner.phase,
               last.span.end >= start {
                result[result.count - 1] = DayPhaseSpan(
                    phase: last.phase,
                    span: TimeSpan(start: last.span.start, end: end)
                )
            } else {
                result.append(
                    DayPhaseSpan(
                        phase: winner.phase,
                        span: TimeSpan(start: start, end: end)
                    )
                )
            }
        }
        return result
    }
}
