import Foundation
import CryptoKit

/// 기록 화면이 쓰는 "N시간 N분" 표기. 화면마다 같은 계산을 다시 쓰지 않도록
/// 한 곳에 둔다.
enum DurationText {
    static func korean(_ interval: TimeInterval) -> String {
        let totalMinutes = max(0, Int(interval / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return "\(minutes)분" }
        if minutes == 0 { return "\(hours)시간" }
        return "\(hours)시간 \(minutes)분"
    }

    static func signedKorean(_ interval: TimeInterval) -> String {
        (interval > 0 ? "＋" : "－") + korean(abs(interval))
    }

    /// 1분이 되지 않는 사용도 실제로 있었던 사용이다. "0분"이라고 적으면
    /// 없던 일처럼 읽히므로, 시간표 상세와 기록 목록이 같은 문구를 쓴다.
    static func koreanAtLeastAMinute(_ interval: TimeInterval) -> String {
        interval > 0 && interval < 60 ? "1분 미만" : korean(interval)
    }
}

/// 막대 그림의 세로 눈금. 눈금 자리가 좁아 한 시간이 넘으면 시간만 적고,
/// 그 아래는 분으로 적는다.
enum DurationAxisText {
    static func korean(hours: Double) -> String {
        let minutes = Int((hours * 60).rounded())
        if minutes == 0 { return "0" }
        if minutes < 60 { return "\(minutes)분" }
        if minutes % 60 == 0 { return "\(minutes / 60)시간" }
        return DurationText.korean(Double(minutes) * 60)
    }
}

/// 자동 기록은 `activity` 하나에 걸음·수면·이동이 섞여 들어온다. 어느 줄에
/// 묶을지 판단하는 규칙을 화면마다 따로 두면 시간표와 기록이 어긋나므로
/// 한 곳에서만 정한다.
enum ActualRecordCategoryResolver {
    private static let movementWords = [
        "걷", "달리", "러닝", "자전거", "사이클", "계단", "차량", "자동차",
        "버스", "지하철", "택시", "기차", "비행기", "배", "이동", "walking",
        "running", "cycling", "automotive", "subway", "transit",
    ]

    static func categoryID(for actual: ActualRecord) -> String {
        if let context = actual.behavior.flatMap(
            StationaryContextKind.init(rawValue:)
        ) {
            return context.categoryID
        }
        if actual.title.trimmingCharacters(in: .whitespacesAndNewlines)
            == StationaryContextKind.unknownStay.title {
            return StationaryContextKind.unknownStay.categoryID
        }
        guard actual.categoryID == "activity" else { return actual.categoryID }
        let value = "\(actual.title) \(actual.behavior ?? "")".lowercased()
        if value.contains("수면") || value.contains("sleep") { return "sleep" }
        return movementWords.contains(where: value.contains)
            ? "movement"
            : "activity"
    }
}

/// 기록 화면과 자동 분류가 공유하는 최소 분류표다. 센서·HealthKit 원본의
/// `categoryID`, 제목, 근거는 바꾸지 않고, 저장 기록을 분석·표시할 때만 이
/// 일과 → 상세활동 계층으로 정규화한다.
enum RecordAnalysisCategoryPolicy {
    static var categoryIDs: [String] {
        RecordClassificationCatalog.categoryIDs
    }

    static var phaseOrder: [DayPhase] {
        categoryIDs.map { phase(for: $0) }
    }

    static var options: [ActivityCorrectionOption] {
        RecordClassificationCatalog.options
    }

    static func isPhaseOption(_ option: ActivityCorrectionOption) -> Bool {
        option.id.hasPrefix("phase.")
    }

    static func phase(for categoryID: String) -> DayPhase {
        switch categoryID {
        case "work": .work
        case "study": .study
        case "hobby": .hobby
        case "sleep": .sleep
        case "movement": .movement
        case "eating": .activity
        case "exercise": .exercise
        case "unconfirmed": .unconfirmed
        default: .activity
        }
    }

    /// 자동 기록을 여덟 개 상위 분류 중 하나로만 분석한다. 기록 자체는
    /// 호출자에게 돌려주지 않고, 이 값만 합계·고리·범례의 열쇠로 쓴다.
    static func categoryID(for actual: ActualRecord) -> String {
        if actual.categoryID == ReviewCoverageEngine.unconfirmedCategoryID
            || actual.behavior == "unconfirmed-activity"
            || actual.behavior == "unconfirmed-movement"
            || actual.behavior == "unconfirmed-gap"
            || normalized(actual.title) == "미확인" {
            return "unconfirmed"
        }

        let value = normalized("\(actual.title) \(actual.behavior ?? "")")
        if actual.behavior == WatchBehaviorKind.housework.rawValue
            || actual.behavior == StationaryContextKind.housework.rawValue
            || value.contains("집안일")
            || value.contains("housework") {
            return "activity"
        }

        if ["work", "study", "hobby"].contains(actual.categoryID),
           let behavior = actual.behavior,
           [
               WatchBehaviorKind.stationary.rawValue,
               WatchBehaviorKind.sitting.rawValue,
               WatchBehaviorKind.standing.rawValue,
               WatchBehaviorKind.lying.rawValue,
               WatchBehaviorKind.walking.rawValue,
           ].contains(behavior) {
            return actual.categoryID
        }

        if let kind = actual.behavior.flatMap(WatchBehaviorKind.fromModelLabel) {
            switch kind {
            case .sleep: return "sleep"
            case .walking, .running, .cycling, .stairsUp, .stairsDown,
                 .elevator, .automotive, .publicTransit, .subway:
                return "movement"
            case .exercise: return "exercise"
            case .unknown: return "activity"
            default: return "activity"
            }
        }

        if let context = actual.behavior.flatMap(StationaryContextKind.init(rawValue:)) {
            switch context.categoryID {
            case "work", "study", "hobby", "exercise":
                return context.categoryID
            default:
                return "activity"
            }
        }

        if value.contains("코어") || value.contains("깊은")
            || value.contains("rem") || value.contains("수면")
            || value.contains("sleep") {
            return "sleep"
        }
        if value.contains("업무") || value.contains("근무") || value.contains("work") {
            return "work"
        }
        if value.contains("수업") || value.contains("학습") || value.contains("study") {
            return "study"
        }
        if value.contains("취미") || value.contains("hobby") {
            return "hobby"
        }
        if value.contains("식사") || value.contains("밥")
            || value.contains("요리") || value.contains("meal")
            || value.contains("eating") || value.contains("cooking") {
            return "eating"
        }
        if value.contains("운동") || value.contains("exercise") {
            return "exercise"
        }
        if value.contains("걷") || value.contains("자동차") || value.contains("자가용")
            || value.contains("지하철") || value.contains("버스") || value.contains("배")
            || value.contains("비행기") || value.contains("자전거")
            || value.contains("walking") || value.contains("automotive")
            || value.contains("subway") || value.contains("transit") {
            return "movement"
        }

        switch actual.categoryID {
        default: return categoryID(for: actual.categoryID)
        }
    }

    static func categoryID(for rawID: String) -> String {
        switch rawID {
        case let value where categoryIDs.contains(value):
            return value
        default:
            // 기존의 업무·수업 외 사용자 카테고리는 원본을 유지하되, 자동
            // 기록 분석에서는 활동으로만 남긴다.
            return "activity"
        }
    }

    static func canonicalPhase(_ phase: DayPhase) -> DayPhase {
        switch phase {
        case .sleep: .sleep
        case .movement, .commuteToWork, .commuteToSchool, .commuteToAcademy,
             .commuteHomeFromWork, .commuteHomeFromSchool,
             .commuteHomeFromAcademy:
            .movement
        case .work: .work
        case .study: .study
        case .hobby: .hobby
        case .exercise: .exercise
        case .unconfirmed: .unconfirmed
        default: .activity
        }
    }

    static func detailTitle(for actual: ActualRecord) -> String {
        let category = categoryID(for: actual)
        if let detail = RecordClassificationCatalog.categories
            .first(where: { $0.id == category })?.details
            .first(where: { detail in
                detail.behavior == actual.behavior
                    || normalized(actual.title).contains(
                        normalized(detail.title)
                    )
            }) {
            return detail.title
        }
        switch category {
        case "work": return "업무(집 - 회사)"
        case "study": return "수업(집 - 학교·학원)"
        case "hobby": return "취미(집 - 취미)"
        case "exercise": return "운동"
        case "sleep":
            return SleepStage(rawValue: actual.behavior ?? "")?.displayName ?? "수면"
        case "movement": return movementTitle(for: actual)
        case "unconfirmed": return "미확인"
        default:
            let behavior = actual.behavior.flatMap(WatchBehaviorKind.fromModelLabel)
            return behavior == .stationary || behavior == .sitting
                || behavior == .standing || behavior == .lying
                || normalized(actual.title).contains("휴식")
                ? "휴식"
                : "미확인"
        }
    }

    static func movementTitle(for actual: ActualRecord) -> String {
        let value = normalized("\(actual.title) \(actual.behavior ?? "")")
        if value.contains("자가용") || value.contains("privatevehicle") {
            return "자가용"
        }
        if value.contains("지하철") || value.contains("subway") { return "지하철" }
        if value.contains("버스") || value.contains("bus") || value.contains("transit") {
            return "버스"
        }
        if value.contains("배") || value.contains("ship") { return "배" }
        if value.contains("비행기") || value.contains("airplane") {
            return "비행기"
        }
        if value.contains("자전거") || value.contains("cycling") { return "자전거" }
        if value.contains("걷") || value.contains("walking") { return "걷기" }
        if value.contains("자동차") || value.contains("automotive") || value.contains("car") {
            return "자동차"
        }
        return "미확인"
    }

    static func movementTitle(for mode: TravelMode) -> String {
        switch mode {
        case .walking: "걷기"
        case .cycling: "자전거"
        case .subway, .train: "지하철"
        case .bus: "버스"
        case .ship: "배"
        case .airplane: "비행기"
        case .car, .taxi: "자동차"
        case .running: "미확인"
        }
    }

    static func movementToken(for mode: TravelMode) -> String {
        switch mode {
        case .walking: TravelMode.walking.rawValue
        case .cycling: TravelMode.cycling.rawValue
        case .subway, .train: TravelMode.subway.rawValue
        case .bus: TravelMode.bus.rawValue
        case .ship: TravelMode.ship.rawValue
        case .airplane: TravelMode.airplane.rawValue
        case .car, .taxi: TravelMode.car.rawValue
        case .running: "unknown"
        }
    }

    static func movementTitle(for token: String) -> String {
        guard token != "unknown" else { return "미확인" }
        return TravelMode(rawValue: token).map(movementTitle(for:)) ?? "미확인"
    }

    static func canonicalSleepStage(_ stage: SleepStage) -> SleepStage? {
        switch stage {
        case .core, .deep, .rem: stage
        case .asleepUnspecified: .core
        case .inBed, .awake: nil
        }
    }

    static func canonicalized(
        _ actuals: [ActualRecord]
    ) -> [ActualRecord] {
        actuals.map { actual in
            var value = actual
            value.categoryID = categoryID(for: actual)
            value.title = detailTitle(for: actual)
            return value
        }
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
    }
}

// MARK: - 계층형 기록 목록

/// 기간 안의 자동·수동 기록을 카테고리 → 항목의 두 단계로 접는다.
/// 화면은 이 결과만 그리고, 제스처 중에는 다시 계산하지 않는다.
enum ActualRecordGroupingEngine {
    static func groups(
        actuals: [ActualRecord],
        in span: TimeSpan,
        categories: [CategoryDefinition],
        asOf: Date = .now,
        scope: RecordAnalysisScope = .legacy
    ) -> [RecordCategoryGroup] {
        groups(
            actuals: actuals,
            in: [span],
            categories: categories,
            asOf: asOf,
            scope: scope
        )
    }

    /// 고른 칸이 여럿일 때도 목록은 하나다. 기록을 칸마다 잘라 담고 같은
    /// 항목의 조각을 합쳐, 떨어진 칸을 골라도 합계가 겹쳐 세어지지 않는다.
    static func groups(
        actuals: [ActualRecord],
        in spans: [TimeSpan],
        categories: [CategoryDefinition],
        asOf: Date = .now,
        scope: RecordAnalysisScope = .legacy
    ) -> [RecordCategoryGroup] {
        var seen = Set<UUID>()
        var byCategory: [String: [(record: ActualRecord, span: TimeSpan)]] = [:]

        for actual in actuals {
            guard seen.insert(actual.id).inserted else { continue }
            let id = switch scope {
            case .legacy: ActualRecordCategoryResolver.categoryID(for: actual)
            case .canonical: RecordAnalysisCategoryPolicy.categoryID(for: actual)
            }
            for span in spans {
                let limit = min(asOf, span.end)
                guard actual.startedAt < limit,
                      let visible = actual.span(asOf: limit)
                          .intersection(with: span),
                      visible.duration > 0 else {
                    continue
                }
                byCategory[id, default: []].append((actual, visible))
            }
        }

        let definitions = Dictionary(
            categories.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return byCategory
            .map { categoryID, values in
                let children = mergedChildren(values, scope: scope)
                let definition = definitions[categoryID]
                return RecordCategoryGroup(
                    id: categoryID,
                    name: displayName(
                        categoryID: categoryID,
                        definition: definition
                    ),
                    colorHex: definition?.darkHex,
                    icon: definition?.icon,
                    duration: children.reduce(0) { $0 + $1.duration },
                    dominantChildTitle: children
                        .max { $0.duration < $1.duration }?
                        .title,
                    children: children
                )
            }
            .sorted {
                $0.duration == $1.duration
                    ? $0.id < $1.id
                    : $0.duration > $1.duration
            }
    }

    /// 하루 원형의 바깥 일과와 그 안에서 실제로 측정된 활동을 한 단계로
    /// 묶는다. 일과 구간은 서로 겹치지 않으므로 상위 합계가 하루 구간과
    /// 같고, 하위 활동은 해당 일과 안에서만 합산된다.
    static func phaseGroups(
        phases: [DayPhaseSpan],
        actuals: [ActualRecord],
        categories: [CategoryDefinition],
        asOf: Date = .now,
        scope: RecordAnalysisScope = .legacy
    ) -> [RecordCategoryGroup] {
        let definitions = Dictionary(
            categories.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var spansByPhase: [DayPhase: [TimeSpan]] = [:]
        for phase in phases {
            let canonical = switch scope {
            case .legacy: phase.phase
            case .canonical: RecordAnalysisCategoryPolicy.canonicalPhase(phase.phase)
            }
            spansByPhase[canonical, default: []].append(phase.span)
        }

        var phaseStarts: [String: Date] = [:]
        var result: [RecordCategoryGroup] = []
        for (phase, spans) in spansByPhase {
            let merged = ActualIntervalMergeEngine.union(spans)
            var values: [(record: ActualRecord, span: TimeSpan)] = []
            for actual in actuals {
                guard actual.behavior != "unconfirmed-gap" else { continue }
                let actualSpan = actual.span(asOf: asOf)
                for phaseSpan in merged {
                    guard let visible = actualSpan.intersection(with: phaseSpan)
                    else { continue }
                    values.append((record: actual, span: visible))
                }
            }
            let children = mergedChildren(values, scope: scope)
            let definition = definitions[phase.rawValue]
            phaseStarts[phase.rawValue] = merged.first?.start ?? .distantFuture
            let duration = merged.reduce(0) { $0 + $1.duration }
            let dominantChild = children.max { $0.duration < $1.duration }?.title
            result.append(RecordCategoryGroup(
                id: phase.rawValue,
                name: phase.title,
                colorHex: definition?.darkHex,
                icon: definition?.icon,
                duration: duration,
                dominantChildTitle: dominantChild,
                children: children
            ))
        }
        return result.sorted {
            let left = phaseStarts[$0.id] ?? .distantFuture
            let right = phaseStarts[$1.id] ?? .distantFuture
            return left == right ? $0.id < $1.id : left < right
        }
    }

    /// 자동 기록은 같은 제목이 하루에 여러 번 끊겨 들어온다. 제목이 같으면
    /// 한 줄로 합치고 겹치는 구간은 한 번만 센다. 한 기록이 고른 칸 여럿에
    /// 걸쳐 잘렸을 때는 조각이 아니라 기록을 센다.
    private static func mergedChildren(
        _ values: [(record: ActualRecord, span: TimeSpan)],
        scope: RecordAnalysisScope = .legacy
    ) -> [RecordGroupChild] {
        Dictionary(grouping: values) {
            childTitle($0.record, scope: scope).lowercased()
        }
            .values
            .compactMap { entries -> RecordGroupChild? in
                let ordered = entries.sorted { $0.span.start < $1.span.start }
                guard let first = ordered.first else { return nil }
                return RecordGroupChild(
                    id: first.record.id.uuidString,
                    title: childTitle(first.record, scope: scope),
                    duration: ActualIntervalMergeEngine.duration(
                        of: ordered.map(\.span)
                    ),
                    start: first.span.start,
                    recordID: first.record.id,
                    occurrenceCount: Set(ordered.map(\.record.id)).count
                )
            }
            .sorted {
                $0.start == $1.start ? $0.title < $1.title : $0.start < $1.start
            }
    }

    private static func childTitle(
        _ actual: ActualRecord,
        scope: RecordAnalysisScope
    ) -> String {
        switch scope {
        case .legacy:
            if ActualRecordCategoryResolver.categoryID(for: actual) == "movement" {
                return MovementPresentation.title(for: actual)
            }
            let trimmed = actual.title.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !trimmed.isEmpty { return trimmed }
            return TimelineRowKind.title(forCategoryID: actual.categoryID)
                ?? actual.categoryID
        case .canonical:
            return RecordAnalysisCategoryPolicy.detailTitle(for: actual)
        }
    }

    private static func displayName(
        categoryID: String,
        definition: CategoryDefinition?
    ) -> String {
        // 어플·날씨처럼 사용자 카테고리에 없는 자동 줄도 한글 이름을 갖는다.
        if categoryID == ReviewCoverageEngine.unconfirmedCategoryID {
            return "미확인"
        }
        if let name = definition?.name { return name }
        return TimelineRowKind.title(forCategoryID: categoryID) ?? categoryID
    }
}

// MARK: - 일별 기준 리포트 보관

enum ReviewReportArchiveEngine {
    static func refreshed(
        snapshot: TaptionDataSnapshot,
        asOf: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [YearlyReviewArchive] {
        let today = calendar.startOfDay(for: asOf)
        var sources = sourcesByDay(snapshot: snapshot, asOf: asOf, calendar: calendar)
        sources[today, default: .empty].categories = snapshot.categories

        let existingDays = Dictionary(
            uniqueKeysWithValues: snapshot.yearlyReports
                .flatMap(\.days)
                .map { ($0.span.start, $0) }
        )
        let dayStarts = Set(sources.keys).union(existingDays.keys).filter {
            $0 <= today
        }
        let review = ReviewEngine(calendar: calendar)
        let days = dayStarts.sorted().compactMap { dayStart -> DailyReviewArchive? in
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            else { return nil }
            let span = TimeSpan(start: dayStart, end: dayEnd)
            let effectiveEnd = min(dayEnd, asOf)
            guard effectiveEnd > dayStart else { return nil }
            var source = sources[dayStart, default: .empty]
            source.categories = snapshot.categories
            source.frequentPlaces = snapshot.settings.frequentPlaces
            source.sort()
            let fingerprint = fingerprint(source, effectiveEnd: effectiveEnd)
            if let existing = existingDays[dayStart],
               existing.sourceFingerprint == fingerprint {
                return existing
            }
            if let existing = existingDays[dayStart],
               dayStart < today,
               source.isEmpty {
                return existing
            }

            let visibleActuals = ReviewCoverageEngine.records(
                actuals: RestSleepDisplayEngine.visibleActuals(
                    MovementDisplayEngine.reviewActuals(
                        source.actuals,
                        travel: source.travel,
                        calendarEvents: source.calendarEvents,
                        asOf: effectiveEnd
                    ),
                    asOf: effectiveEnd
                ),
                in: [span],
                asOf: effectiveEnd
            )
            let phaseActuals = DayPhaseEvidenceEngine.records(
                from: source.actuals,
                intersecting: span,
                asOf: effectiveEnd
            )
            let report = review.report(
                over: [span],
                plans: source.plans,
                actuals: visibleActuals,
                weather: source.weather,
                photos: source.photos,
                memos: source.memos,
                asOf: effectiveEnd,
                scope: .canonical
            )
            let dayPhases = DayPhaseEngine.categoryDurations(
                DayPhaseEngine.completePhases(
                    actuals: phaseActuals,
                    travel: source.travel,
                    stays: source.places,
                    placeKinds: FrequentPlaceResolutionEngine()
                        .kindsByPlaceKey(source.frequentPlaces),
                    in: span,
                    asOf: effectiveEnd
                ),
                scope: .canonical
            )
            return DailyReviewArchive(
                id: dayID(dayStart, calendar: calendar),
                span: span,
                report: report,
                dayPhases: dayPhases,
                groups: ActualRecordGroupingEngine.groups(
                    actuals: visibleActuals,
                    in: span,
                    categories: source.categories,
                    asOf: effectiveEnd,
                    scope: .canonical
                ),
                sourceFingerprint: fingerprint,
                updatedAt: asOf
            )
        }

        return Dictionary(grouping: days) {
            calendar.dateInterval(of: .year, for: $0.span.start)?.start
                ?? $0.span.start
        }.keys.sorted().compactMap { start in
            guard let interval = calendar.dateInterval(of: .year, for: start)
            else { return nil }
            let span = TimeSpan(start: interval.start, end: interval.end)
            return ReviewArchiveHierarchy.year(
                span: span,
                days: days.filter { span.contains($0.span.start) },
                asOf: asOf,
                calendar: calendar
            )
        }
    }

    private static func sourcesByDay(
        snapshot: TaptionDataSnapshot,
        asOf: Date,
        calendar: Calendar
    ) -> [Date: DailyReviewSource] {
        var result: [Date: DailyReviewSource] = [:]
        for plan in snapshot.plans {
            distribute(plan.span, asOf: asOf, calendar: calendar) { day, span in
                var value = plan
                value.span = span
                result[day, default: .empty].plans.append(value)
            }
        }
        for actual in snapshot.actuals {
            distribute(actual.span(asOf: asOf), asOf: asOf, calendar: calendar) {
                day, span in
                var value = actual
                value.startedAt = span.start
                value.endedAt = span.end
                result[day, default: .empty].actuals.append(value)
            }
        }
        for event in snapshot.calendarEvents {
            distribute(event.span, asOf: asOf, calendar: calendar) { day, span in
                var value = event
                value.span = span
                result[day, default: .empty].calendarEvents.append(value)
            }
        }
        for place in snapshot.places {
            distribute(place.span, asOf: asOf, calendar: calendar) { day, span in
                var value = place
                value.span = span
                result[day, default: .empty].places.append(value)
            }
        }
        for travel in snapshot.travel {
            distribute(travel.span, asOf: asOf, calendar: calendar) { day, span in
                var value = travel
                value.span = span
                result[day, default: .empty].travel.append(value)
            }
        }
        for memo in snapshot.memos where memo.occurredAt <= asOf {
            result[calendar.startOfDay(for: memo.occurredAt), default: .empty]
                .memos.append(memo)
        }
        for weather in snapshot.weather where weather.observedAt <= asOf {
            result[calendar.startOfDay(for: weather.observedAt), default: .empty]
                .weather.append(weather)
        }
        for photo in snapshot.photos where photo.capturedAt <= asOf {
            result[calendar.startOfDay(for: photo.capturedAt), default: .empty]
                .photos.append(photo)
        }
        return result
    }

    private static func distribute(
        _ source: TimeSpan,
        asOf: Date,
        calendar: Calendar,
        body: (Date, TimeSpan) -> Void
    ) {
        let end = min(source.end, asOf)
        guard end > source.start else { return }
        var day = calendar.startOfDay(for: source.start)
        while day < end {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day)
            else { break }
            if let clipped = TimeSpan(start: source.start, end: end)
                .intersection(with: TimeSpan(start: day, end: next)) {
                body(day, clipped)
            }
            day = next
        }
    }

    private static func fingerprint(
        _ source: DailyReviewSource,
        effectiveEnd: Date
    ) -> String {
        let minute = Date(
            timeIntervalSince1970: floor(effectiveEnd.timeIntervalSince1970 / 60) * 60
        )
        let payload = DailyReviewFingerprint(source: source, effectiveEnd: minute)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = (try? encoder.encode(payload)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func dayID(_ date: Date, calendar: Calendar) -> String {
        let value = calendar.dateComponents([.year, .month, .day], from: date)
        return "day-\(value.year ?? 0)-\(value.month ?? 0)-\(value.day ?? 0)"
    }
}

private struct DailyReviewFingerprint: Codable {
    var source: DailyReviewSource
    var effectiveEnd: Date
}

private struct DailyReviewSource: Codable {
    var plans: [PlanRecord] = []
    var actuals: [ActualRecord] = []
    var memos: [ActionMemo] = []
    var categories: [CategoryDefinition] = []
    var frequentPlaces: [FrequentPlace] = []
    var photos: [PhotoMoment] = []
    var calendarEvents: [CalendarRecord] = []
    var weather: [WeatherContext] = []
    var places: [PlaceStay] = []
    var travel: [TravelSegment] = []

    static let empty = DailyReviewSource()

    var isEmpty: Bool {
        plans.isEmpty && actuals.isEmpty && memos.isEmpty && photos.isEmpty
            && calendarEvents.isEmpty && weather.isEmpty && places.isEmpty
            && travel.isEmpty
    }

    mutating func sort() {
        plans.sort { $0.id.uuidString < $1.id.uuidString }
        actuals.sort { $0.id.uuidString < $1.id.uuidString }
        memos.sort { $0.id.uuidString < $1.id.uuidString }
        categories.sort { $0.id < $1.id }
        frequentPlaces.sort { $0.id.uuidString < $1.id.uuidString }
        photos.sort { $0.id < $1.id }
        calendarEvents.sort { $0.id < $1.id }
        weather.sort { $0.id.uuidString < $1.id.uuidString }
        places.sort { $0.id.uuidString < $1.id.uuidString }
        travel.sort { $0.id.uuidString < $1.id.uuidString }
    }
}

// MARK: - 24시간 기록 범위

/// 기록 화면은 같은 시각에 들어온 센서 결과를 모두 더하지 않는다. 수면처럼
/// 더 구체적인 기록을 먼저 남기고 겹친 하위 신뢰 기록을 잘라 낸 뒤, 측정되지
/// 않은 과거만 `미확인`으로 채운다. 저장된 원본은 건드리지 않는다.
enum ReviewCoverageEngine {
    static let unconfirmedCategoryID = "unconfirmed"

    static func records(
        actuals: [ActualRecord],
        in spans: [TimeSpan],
        asOf: Date = .now
    ) -> [ActualRecord] {
        let targets = ActualIntervalMergeEngine.union(
            spans.compactMap { span in
                let end = min(span.end, asOf)
                return end > span.start
                    ? TimeSpan(start: span.start, end: end)
                    : nil
            },
            mergeGap: 0
        )
        guard !targets.isEmpty else { return [] }

        let unique = Dictionary(
            actuals.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted(by: isHigherPriority)
        var pieceOffsets: [UUID: Int] = [:]
        var result: [ActualRecord] = []

        for target in targets {
            var covered: [TimeSpan] = []
            for actual in unique {
                guard let visible = actual.span(asOf: asOf)
                    .intersection(with: target) else { continue }
                let remainders = ActualIntervalMergeEngine.subtracting(
                    covered,
                    from: visible
                )
                for remainder in remainders where remainder.duration > 0 {
                    let offset = pieceOffsets[actual.id, default: 0]
                    pieceOffsets[actual.id] = offset + 1
                    var piece = actual
                    piece.id = offset == 0
                        ? actual.id
                        : stableID(
                            "record.\(actual.id.uuidString).\(offset)"
                        )
                    piece.startedAt = remainder.start
                    piece.endedAt = remainder.end
                    result.append(piece)
                    covered.append(remainder)
                }
            }

            for gap in ActualIntervalMergeEngine.subtracting(
                covered,
                from: target
            ) where gap.duration > 0 {
                result.append(unconfirmedRecord(for: gap))
            }
        }
        return result.sorted {
            $0.startedAt == $1.startedAt
                ? precedence($0) > precedence($1)
                : $0.startedAt < $1.startedAt
        }
    }

    static func unconfirmedRecords(
        actuals: [ActualRecord],
        in spans: [TimeSpan],
        asOf: Date = .now
    ) -> [ActualRecord] {
        records(actuals: actuals, in: spans, asOf: asOf).filter {
            $0.categoryID == unconfirmedCategoryID
        }
    }

    private static func isHigherPriority(
        _ lhs: ActualRecord,
        _ rhs: ActualRecord
    ) -> Bool {
        let left = precedence(lhs)
        let right = precedence(rhs)
        if left != right { return left > right }
        if lhs.confidence != rhs.confidence {
            return confidence(lhs.confidence) > confidence(rhs.confidence)
        }
        if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func precedence(_ actual: ActualRecord) -> Int {
        if AutomaticRecordTimelineEngine.isConfirmedWorkout(actual) {
            return 1_300
        }
        if AutomaticRecordTimelineEngine.isSleep(actual) { return 1_200 }
        if actual.manuallyCorrected || actual.source == .manual { return 1_100 }
        let category = ActualRecordCategoryResolver.categoryID(for: actual)
        return switch category {
        case "movement": 800
        case "activity", "exercise", "health": 700
        case "work", "study", "routine": 600
        case "rest": 500
        case "appUsage": 100
        case unconfirmedCategoryID: 0
        default: 400
        }
    }

    private static func confidence(_ value: ConfidenceLevel) -> Int {
        switch value {
        case .high: 3
        case .medium: 2
        case .low: 1
        }
    }

    private static func unconfirmedRecord(for span: TimeSpan) -> ActualRecord {
        ActualRecord(
            id: stableID(
                "gap.\(span.start.timeIntervalSince1970).\(span.end.timeIntervalSince1970)"
            ),
            planID: nil,
            title: "미확인",
            categoryID: unconfirmedCategoryID,
            startedAt: span.start,
            endedAt: span.end,
            source: .motion,
            confidence: .low,
            createdAt: span.end,
            behavior: "unconfirmed-gap",
            evidence: ["자동 기록이 없는 시간"],
            modelVersion: "review-coverage-v1"
        )
    }

    private static func stableID(_ seed: String) -> UUID {
        var bytes = Array(repeating: UInt8(0), count: 16)
        var hash = UInt64(14_695_981_039_346_656_037)
        for (index, byte) in seed.utf8.enumerated() {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
            bytes[index % bytes.count] ^= UInt8(truncatingIfNeeded: hash >> 24)
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

/// 겹침 제거 뒤 하나의 자동 기록이 여러 표시 조각으로 갈렸을 때, 사용자가
/// 고른 조각만 수동 파생 기록으로 교정한다. 센서 원본 전체에 교정을 걸면
/// 떨어져 보이는 다른 조각까지 함께 바뀌므로 표시 구간을 별도 ID로 보존한다.
enum ActivityFragmentCorrectionEngine {
    static func needsSeparateRecord(
        source: ActualRecord,
        displayedSpan: TimeSpan,
        tolerance: TimeInterval = 1
    ) -> Bool {
        guard let sourceEnd = source.endedAt else { return true }
        return abs(source.startedAt.timeIntervalSince(displayedSpan.start))
                > tolerance
            || abs(sourceEnd.timeIntervalSince(displayedSpan.end)) > tolerance
    }

    static func record(
        source: ActualRecord,
        displayedSpan: TimeSpan,
        correctedSpan: TimeSpan,
        option: ActivityCorrectionOption?,
        createdAt: Date = .now
    ) -> ActualRecord {
        ActualRecord(
            id: stableID(sourceID: source.id, span: displayedSpan),
            planID: source.planID,
            routineID: source.routineID,
            title: option?.title ?? source.title,
            categoryID: option?.categoryID ?? source.categoryID,
            startedAt: correctedSpan.start,
            endedAt: correctedSpan.end,
            source: .manual,
            confidence: .high,
            createdAt: createdAt,
            behavior: option?.behavior ?? source.behavior,
            evidence: ["사용자가 표시 구간을 분류함"],
            modelVersion: "manual-activity-fragment-v1",
            manuallyCorrected: true
        )
    }

    static func stableID(sourceID: UUID, span: TimeSpan) -> UUID {
        let start = Int64(
            (span.start.timeIntervalSince1970 * 1_000).rounded()
        )
        let end = Int64(
            (span.end.timeIntervalSince1970 * 1_000).rounded()
        )
        let seed = "activity-fragment.\(sourceID.uuidString).\(start).\(end)"
        var bytes = Array(repeating: UInt8(0), count: 16)
        var hash = UInt64(14_695_981_039_346_656_037)
        for (index, byte) in seed.utf8.enumerated() {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
            bytes[index % bytes.count] ^= UInt8(truncatingIfNeeded: hash >> 24)
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

struct ActivitySectionOverridePiece: Hashable, Sendable {
    var span: TimeSpan
    var option: ActivityCorrectionOption
}

enum ActivitySectionEditMode: Hashable, Sendable {
    case replace(editedSpan: TimeSpan, option: ActivityCorrectionOption)
    case cutLowerUnconfirmed(
        cutAt: Date,
        option: ActivityCorrectionOption
    )
    case insertDetail(
        detailSpan: TimeSpan,
        option: ActivityCorrectionOption
    )
}

struct ActivitySectionEditRequest: Hashable, Sendable {
    var sourceIDs: [UUID]
    var originalSpan: TimeSpan
    var originalOption: ActivityCorrectionOption
    var mode: ActivitySectionEditMode
}

struct ActivitySectionEditSaveResult: Hashable, Sendable {
    var recordIDs: [UUID]
    var selectedSpan: TimeSpan
}

/// Builds user-owned display records over immutable sensor and travel data.
/// Every plan covers the original section without gaps, so shrinking or
/// slicing a section never exposes a stale automatic candidate underneath.
enum ActivitySectionOverrideEngine {
    static let modelVersion = "manual-activity-section-v2"

    static let unconfirmedOption = ActivityCorrectionOption(
        id: "phase.unconfirmed",
        title: "미확인",
        behavior: "unconfirmed-gap",
        categoryID: "unconfirmed",
        systemImage: "questionmark",
        isAutomatic: false,
        isCustom: false
    )

    static func pieces(
        for request: ActivitySectionEditRequest
    ) -> [ActivitySectionOverridePiece] {
        let original = request.originalSpan
        let values: [ActivitySectionOverridePiece]
        switch request.mode {
        case let .replace(editedSpan, option):
            guard let edited = editedSpan.intersection(with: original) else {
                return []
            }
            values = coveragePieces(
                original: original,
                middle: edited,
                middleOption: option,
                outsideOption: unconfirmedOption
            )

        case let .cutLowerUnconfirmed(cutAt, option):
            guard cutAt > original.start, cutAt < original.end else { return [] }
            values = [
                ActivitySectionOverridePiece(
                    span: TimeSpan(start: original.start, end: cutAt),
                    option: option
                ),
                ActivitySectionOverridePiece(
                    span: TimeSpan(start: cutAt, end: original.end),
                    option: unconfirmedOption
                ),
            ]

        case let .insertDetail(detailSpan, option):
            guard let detail = detailSpan.intersection(with: original) else {
                return []
            }
            values = coveragePieces(
                original: original,
                middle: detail,
                middleOption: option,
                outsideOption: request.originalOption
            )
        }
        return coalesced(values)
    }

    static func records(
        for request: ActivitySectionEditRequest,
        createdAt: Date = .now
    ) -> [ActualRecord] {
        pieces(for: request).map { piece in
            ActualRecord(
                id: stableID(
                    sourceIDs: request.sourceIDs,
                    originalSpan: request.originalSpan,
                    piece: piece
                ),
                planID: nil,
                title: piece.option.title,
                categoryID: piece.option.categoryID,
                startedAt: piece.span.start,
                endedAt: piece.span.end,
                source: .manual,
                confidence: .high,
                createdAt: createdAt,
                behavior: piece.option.behavior,
                evidence: ["사용자가 행동 구간을 편집함"],
                modelVersion: modelVersion,
                manuallyCorrected: true
            )
        }
    }

    static func isEditableOverride(_ actual: ActualRecord) -> Bool {
        actual.source == .manual && actual.manuallyCorrected
    }

    private static func coveragePieces(
        original: TimeSpan,
        middle: TimeSpan,
        middleOption: ActivityCorrectionOption,
        outsideOption: ActivityCorrectionOption
    ) -> [ActivitySectionOverridePiece] {
        var values: [ActivitySectionOverridePiece] = []
        if original.start < middle.start {
            values.append(ActivitySectionOverridePiece(
                span: TimeSpan(start: original.start, end: middle.start),
                option: outsideOption
            ))
        }
        values.append(ActivitySectionOverridePiece(
            span: middle,
            option: middleOption
        ))
        if middle.end < original.end {
            values.append(ActivitySectionOverridePiece(
                span: TimeSpan(start: middle.end, end: original.end),
                option: outsideOption
            ))
        }
        return values
    }

    private static func coalesced(
        _ pieces: [ActivitySectionOverridePiece]
    ) -> [ActivitySectionOverridePiece] {
        pieces.reduce(into: []) { result, piece in
            guard piece.span.duration > 0 else { return }
            guard var previous = result.last,
                  previous.span.end == piece.span.start,
                  previous.option.title == piece.option.title,
                  previous.option.categoryID == piece.option.categoryID,
                  previous.option.behavior == piece.option.behavior
            else {
                result.append(piece)
                return
            }
            result.removeLast()
            previous.span = TimeSpan(
                start: previous.span.start,
                end: piece.span.end
            )
            result.append(previous)
        }
    }

    private static func stableID(
        sourceIDs: [UUID],
        originalSpan: TimeSpan,
        piece: ActivitySectionOverridePiece
    ) -> UUID {
        let sources = sourceIDs.map(\.uuidString).sorted().joined(separator: ",")
        let seed = [
            modelVersion,
            sources,
            milliseconds(originalSpan.start),
            milliseconds(originalSpan.end),
            milliseconds(piece.span.start),
            milliseconds(piece.span.end),
            piece.option.categoryID,
            piece.option.behavior ?? "",
            piece.option.title,
        ].joined(separator: ".")
        var bytes = Array(repeating: UInt8(0), count: 16)
        var hash = UInt64(14_695_981_039_346_656_037)
        for (index, byte) in seed.utf8.enumerated() {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
            bytes[index % bytes.count] ^= UInt8(truncatingIfNeeded: hash >> 24)
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func milliseconds(_ date: Date) -> String {
        String(Int64((date.timeIntervalSince1970 * 1_000).rounded()))
    }
}

/// 일과는 이동 표시용으로 합쳐진 사본이 아니라 HealthKit·Apple Watch 원본을
/// 읽는다. 그래야 같은 걷기가 활동에서는 `걷기`, 일과에서는 `운동`이 된다.
enum DayPhaseEvidenceEngine {
    static func records(
        from actuals: [ActualRecord],
        intersecting span: TimeSpan,
        asOf: Date = .now
    ) -> [ActualRecord] {
        AutomaticRecordTimelineEngine.visibleThroughNow(
            actuals,
            intersecting: span,
            asOf: asOf
        )
    }
}

// MARK: - 기간 고르기

/// 기록 화면에서 손가락으로 켜고 끄는 한 칸.
struct ReviewPeriodBucket: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let span: TimeSpan
}

/// 기록 화면이 읽을 구간을 정한다. 고른 칸이 없으면 기간 전체 하나이고,
/// 고른 칸이 있으면 그 칸들의 합집합이다. 합계·눈금판·목록이 모두 이 한
/// 값을 읽어야 서로 다른 숫자를 말하지 않는다.
enum ReviewSelectionEngine {
    /// 배율마다 고를 수 있는 칸의 크기. 하루는 나누지 않는다 — 하루는 늘
    /// 통째로 본다.
    static func bucketLevel(for level: TimelineLevel) -> TimelineLevel? {
        switch level {
        case .day: nil
        case .week: .day
        case .month: .week
        case .year: .month
        }
    }

    static func buckets(
        for level: TimelineLevel,
        in period: TimeSpan,
        calendar: Calendar
    ) -> [ReviewPeriodBucket] {
        guard let bucketLevel = bucketLevel(for: level) else { return [] }
        let component = component(for: bucketLevel)
        var result: [ReviewPeriodBucket] = []
        var cursor = period.start

        while cursor < period.end {
            guard let interval = calendar.dateInterval(
                of: component,
                for: cursor
            ) else {
                break
            }
            let span = TimeSpan(
                start: max(interval.start, period.start),
                end: min(interval.end, period.end)
            )
            if span.duration > 0 {
                result.append(
                    ReviewPeriodBucket(
                        id: identifier(of: span.start, calendar: calendar),
                        label: label(
                            of: span,
                            level: bucketLevel,
                            index: result.count,
                            calendar: calendar
                        ),
                        span: span
                    )
                )
            }
            guard interval.end > cursor else { break }
            cursor = interval.end.addingTimeInterval(0.001)
        }
        return result
    }

    /// 고른 칸이 없거나 지금 기간에 없는 칸만 남았으면 기간 전체로 돌아간다.
    /// 화면이 아무것도 가리키지 않는 상태에 빠지지 않게 하는 마지막 방어다.
    static func spans(
        period: TimeSpan,
        buckets: [ReviewPeriodBucket],
        selectedIDs: Set<String>
    ) -> [TimeSpan] {
        let chosen = buckets
            .filter { selectedIDs.contains($0.id) }
            .map(\.span)
        guard !chosen.isEmpty else { return [period] }
        return ActualIntervalMergeEngine.union(chosen, mergeGap: 0)
    }

    static func chartSpan(
        _ selectedID: String?,
        buckets: [RecordChartBucket]
    ) -> TimeSpan? {
        guard let selectedID else { return nil }
        return buckets.first { $0.id == selectedID }?.span
    }

    private static func component(
        for level: TimelineLevel
    ) -> Calendar.Component {
        switch level {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
    }

    private static func identifier(
        of start: Date,
        calendar: Calendar
    ) -> String {
        ISO8601DateFormatter.string(
            from: start,
            timeZone: calendar.timeZone,
            formatOptions: [.withInternetDateTime]
        )
    }

    private static let weekdayNames = ["일", "월", "화", "수", "목", "금", "토"]

    private static func label(
        of span: TimeSpan,
        level: TimelineLevel,
        index: Int,
        calendar: Calendar
    ) -> String {
        switch level {
        case .day:
            let weekday = calendar.component(.weekday, from: span.start)
            return weekdayNames[max(1, min(7, weekday)) - 1]
        case .week:
            return "\(index + 1)주"
        case .month:
            return "\(calendar.component(.month, from: span.start))월"
        case .year:
            return "\(calendar.component(.year, from: span.start))년"
        }
    }
}

// MARK: - 기록 차트

struct RecordClockArc: Identifiable, Equatable, Sendable {
    let id: String
    let categoryID: String
    /// 하루를 0…1로 본 시작·끝 위치. 자정이 0이다.
    let startFraction: Double
    let endFraction: Double
}

struct RecordClockRing: Identifiable, Equatable, Sendable {
    let id: String
    let categoryID: String
    let duration: TimeInterval
    let arcs: [RecordClockArc]
}

/// 하루 눈금판에 덧대는 띠. 카테고리 고리가 "무엇을 했는가"라면, 그 바깥의
/// `dayPhase` 는 "어떤 하루였는가"이고 안쪽 띠들은 그 안의 결이다. 한 띠에는
/// 종류가 다른 조각이 이어 붙는다.
enum RecordClockDetailKind: String, Equatable, Sendable {
    case dayPhase
    case sleepStage
    case travel
    case weather
    case location
}

struct RecordClockDetailArc: Identifiable, Equatable, Sendable {
    let id: String
    /// 색과 이름을 고르는 열쇠. 수면은 `SleepStage`, 이동은 `TravelMode`의
    /// 원시값이다.
    let token: String
    let startFraction: Double
    let endFraction: Double
}

struct RecordClockDetailRing: Identifiable, Equatable, Sendable {
    let id: String
    let kind: RecordClockDetailKind
    let arcs: [RecordClockDetailArc]
}

/// 원형 시간표의 날씨 조각은 한 칸에 온도·상태·미세먼지를 함께 보인다.
/// 문자열 하나로 보관해 기존의 가벼운 링 모델과 범례 선택을 그대로 쓴다.
enum WeatherClockToken {
    static func make(_ context: WeatherContext) -> String {
        let condition = context.condition.replacingOccurrences(of: "|", with: "/")
        let symbol = context.symbolName.replacingOccurrences(of: "|", with: "/")
        let temperature = Int(context.temperatureCelsius.rounded())
        let air = context.airQuality
        let grade = air.map { String($0.overallGrade.rawValue) } ?? "-"
        let pm10 = air.map { String(Int($0.pm10MicrogramsPerCubicMeter.rounded())) } ?? "-"
        let pm25 = air.map { String(Int($0.pm25MicrogramsPerCubicMeter.rounded())) } ?? "-"
        return [condition, symbol, String(temperature), grade, pm10, pm25].joined(separator: "|")
    }

    static func displayName(_ token: String) -> String {
        let parts = token.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 6, let temperature = Int(parts[2]) else { return token }
        return "\(weatherEmoji(for: parts[1])) \(temperature)° · \(airEmoji(for: parts[3]))"
    }

    /// 원형 시간표의 호출 라벨에서 미세먼지 표식을 더 작게 그릴 수 있도록
    /// 저장된 토큰을 세 조각으로 나눈다. 저장 형식은 바꾸지 않는다.
    static func compactParts(
        _ token: String
    ) -> (weather: String, temperature: String, air: String)? {
        let parts = token.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 6, let temperature = Int(parts[2]) else { return nil }
        return (
            weatherEmoji(for: parts[1]),
            String(temperature),
            airEmoji(for: parts[3])
        )
    }

    static func airGrade(_ token: String) -> AirQualityGrade? {
        let parts = token.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 6, let raw = Int(parts[3]) else { return nil }
        return AirQualityGrade(rawValue: raw)
    }

    private static func weatherEmoji(for symbol: String) -> String {
        switch symbol {
        case "sun.max.fill", "sun.min.fill": "☀️"
        case "moon.fill", "moon.stars.fill": "🌙"
        case "cloud.sun.fill", "cloud.moon.fill": "🌤️"
        case "cloud.fill": "☁️"
        case "cloud.fog.fill": "🌫️"
        case "cloud.drizzle.fill": "🌦️"
        case "cloud.sleet.fill": "🌨️"
        case "cloud.rain.fill", "cloud.heavyrain.fill": "🌧️"
        case "cloud.snow.fill": "❄️"
        case "cloud.bolt.rain.fill": "⛈️"
        default: "🌡️"
        }
    }

    private static func airEmoji(for rawGrade: String) -> String {
        switch Int(rawGrade).flatMap(AirQualityGrade.init(rawValue:)) {
        case .good: "🟢"
        case .moderate: "🟡"
        case .bad: "🟠"
        case .veryBad: "🔴"
        case nil: "⚪️"
        }
    }
}

struct RecordChartSlice: Identifiable, Equatable, Sendable {
    let id: String
    let categoryID: String
    let duration: TimeInterval
}

struct RecordChartBucket: Identifiable, Equatable, Sendable {
    let id: String
    let span: TimeSpan
    let slices: [RecordChartSlice]

    var total: TimeInterval {
        slices.reduce(0) { $0 + $1.duration }
    }
}

/// 기록 화면의 그림 데이터. 뷰 본문에서 계산하면 제스처마다 전체 기간을
/// 다시 훑게 되므로 순수 함수로 떼어 두고 데이터가 바뀔 때만 부른다.
enum RecordChartEngine {
    /// 하루 원형 시간표. 카테고리마다 하나의 고리를 만들어 겹친 기록이
    /// 서로를 가리지 않게 한다. 고리는 총 시간이 긴 쪽이 바깥이다.
    static func clockRings(
        actuals: [ActualRecord],
        in span: TimeSpan,
        asOf: Date = .now,
        scope: RecordAnalysisScope = .legacy
    ) -> [RecordClockRing] {
        let limit = min(asOf, span.end)
        let total = span.duration
        guard total > 0 else { return [] }

        var byCategory: [String: [TimeSpan]] = [:]
        var seen = Set<UUID>()
        for actual in actuals {
            guard seen.insert(actual.id).inserted else { continue }
            guard actual.startedAt < limit,
                  let visible = actual.span(asOf: limit)
                      .intersection(with: span),
                  visible.duration > 0 else {
                continue
            }
            let categoryID = switch scope {
            case .legacy: ActualRecordCategoryResolver.categoryID(for: actual)
            case .canonical: RecordAnalysisCategoryPolicy.categoryID(for: actual)
            }
            byCategory[categoryID, default: []].append(visible)
        }

        return byCategory
            .map { categoryID, spans in
                let merged = ActualIntervalMergeEngine.union(spans)
                return RecordClockRing(
                    id: categoryID,
                    categoryID: categoryID,
                    duration: merged.reduce(0) { $0 + $1.duration },
                    arcs: merged.enumerated().map { offset, value in
                        RecordClockArc(
                            id: "\(categoryID).\(offset)",
                            categoryID: categoryID,
                            startFraction: value.start
                                .timeIntervalSince(span.start) / total,
                            endFraction: value.end
                                .timeIntervalSince(span.start) / total
                        )
                    }
                )
            }
            .sorted {
                $0.duration == $1.duration
                    ? $0.categoryID < $1.categoryID
                    : $0.duration > $1.duration
            }
    }

    /// 주·월·년 막대. `unit`은 한 칸의 길이(주·월은 하루, 년은 한 달)다.
    /// `categoryIDs`가 비어 있지 않으면 고른 카테고리만 남긴다. 흐리게
    /// 덮는 대신 여기서 걸러야 세로 범위도 남은 자료에 맞출 수 있다.
    static func buckets(
        actuals: [ActualRecord],
        in span: TimeSpan,
        unit: Calendar.Component,
        calendar: Calendar,
        categoryIDs: Set<String> = [],
        asOf: Date = .now
    ) -> [RecordChartBucket] {
        let limit = min(asOf, span.end)
        let visible = uniqueVisible(
            actuals,
            in: span,
            asOf: limit,
            categoryIDs: categoryIDs
        )

        return buckets(
            values: visible,
            in: span,
            unit: unit,
            calendar: calendar
        )
    }

    /// 주·월·년은 세부 활동이 아니라 일별로 확정된 일과를 합산한다. 매일을
    /// 먼저 24시간 분류한 뒤에만 일·월 단위 막대로 묶어, 상위 기간에서
    /// 중복 활동 시간이 더해지지 않게 한다.
    static func phaseBuckets(
        actuals: [ActualRecord],
        travel: [TravelSegment],
        stays: [PlaceStay],
        placeKinds: [String: FrequentPlaceKind],
        in span: TimeSpan,
        unit: Calendar.Component,
        calendar: Calendar,
        asOf: Date = .now,
        scope: RecordAnalysisScope = .legacy
    ) -> [RecordChartBucket] {
        let end = min(span.end, asOf)
        guard end > span.start else { return [] }
        let values = DayPhaseEngine.completePhasesAcrossDays(
            actuals: actuals,
            travel: travel,
            stays: stays,
            placeKinds: placeKinds,
            in: span,
            calendar: calendar,
            asOf: asOf
        ).map {
            let phase = switch scope {
            case .legacy: $0.phase
            case .canonical: RecordAnalysisCategoryPolicy.canonicalPhase($0.phase)
            }
            return (phase.rawValue, $0.span)
        }
        return buckets(
            values: values,
            in: span,
            unit: unit,
            calendar: calendar
        )
    }

    static func categoryDurations(
        in buckets: [RecordChartBucket]
    ) -> [CategoryDuration] {
        var totals: [String: TimeInterval] = [:]
        for slice in buckets.flatMap(\.slices) {
            totals[slice.categoryID, default: 0] += slice.duration
        }
        return totals.map {
            CategoryDuration(categoryID: $0.key, planned: 0, actual: $0.value)
        }.sorted {
            $0.actual == $1.actual
                ? $0.categoryID < $1.categoryID
                : $0.actual > $1.actual
        }
    }

    private static func buckets(
        values: [(categoryID: String, span: TimeSpan)],
        in span: TimeSpan,
        unit: Calendar.Component,
        calendar: Calendar
    ) -> [RecordChartBucket] {
        var result: [RecordChartBucket] = []
        var cursor = calendar.dateInterval(of: unit, for: span.start)?.start
            ?? span.start
        while cursor < span.end {
            guard let next = calendar.date(
                byAdding: unit,
                value: 1,
                to: cursor
            ) else {
                break
            }
            let bucketSpan = TimeSpan(
                start: max(cursor, span.start),
                end: min(next, span.end)
            )
            result.append(
                RecordChartBucket(
                    id: ISO8601DateFormatter.string(
                        from: bucketSpan.start,
                        timeZone: calendar.timeZone,
                        formatOptions: [.withInternetDateTime]
                    ),
                    span: bucketSpan,
                    slices: slices(of: values, in: bucketSpan)
                )
            )
            cursor = next
        }
        return result
    }

    /// 고른 카테고리만 남긴 막대에서 가장 높은 칸(시간). 세로 눈금 범위를
    /// 이 값으로 다시 잡아 막대가 높이를 다 쓰게 한다.
    static func maxTotalHours(_ buckets: [RecordChartBucket]) -> Double {
        let peak = (buckets.map(\.total).max() ?? 0) / 3_600
        return peak > 0 ? peak : 1
    }

    private static func uniqueVisible(
        _ actuals: [ActualRecord],
        in span: TimeSpan,
        asOf: Date,
        categoryIDs: Set<String>
    ) -> [(categoryID: String, span: TimeSpan)] {
        var seen = Set<UUID>()
        return actuals.compactMap { actual in
            guard seen.insert(actual.id).inserted else { return nil }
            let categoryID = ActualRecordCategoryResolver.categoryID(for: actual)
            guard categoryIDs.isEmpty || categoryIDs.contains(categoryID) else {
                return nil
            }
            guard actual.startedAt < asOf,
                  let visible = actual.span(asOf: asOf)
                      .intersection(with: span),
                  visible.duration > 0 else {
                return nil
            }
            return (categoryID, visible)
        }
    }

    private static func slices(
        of values: [(categoryID: String, span: TimeSpan)],
        in bucket: TimeSpan
    ) -> [RecordChartSlice] {
        var byCategory: [String: [TimeSpan]] = [:]
        for value in values {
            guard let clipped = value.span.intersection(with: bucket),
                  clipped.duration > 0 else {
                continue
            }
            byCategory[value.categoryID, default: []].append(clipped)
        }
        return byCategory
            .map { categoryID, spans in
                RecordChartSlice(
                    id: categoryID,
                    categoryID: categoryID,
                    duration: ActualIntervalMergeEngine.duration(of: spans)
                )
            }
            .sorted {
                $0.duration == $1.duration
                    ? $0.categoryID < $1.categoryID
                    : $0.duration > $1.duration
            }
    }
}

/// 메모는 구간이 아니라 순간이다. 시간표는 구간만 그릴 수 있으므로 순간을
/// 표식으로 바꾸고, 한 화면에서 서로 구분되지 않을 만큼 붙은 표식은 하나로
/// 합친다. 화소보다 얇은 조각을 수백 개 그리면 화면이 멈춘다는 사실은 눈금판
/// 띠에서 이미 배웠으므로 기준값도 그 띠와 같은 것
/// (`RecordClockDetailEngine.minimumArcFraction`)을 쓴다.
enum MemoTimelineEngine {
    /// 항목에 딸리지 않은 메모가 갖는 분류. 곧 시간표 메모 줄의 id 다.
    static let categoryID = TimelineRowKind.memo.rawValue

    /// 표식 하나의 기본 길이. 하루의 0.4%는 약 6분이다.
    static let markerDuration: TimeInterval =
        86_400 * RecordClockDetailEngine.minimumArcFraction

    /// 보이는 기간이 넓을수록 더 많이 합친다. 주는 약 40분, 월은 약 3시간,
    /// 년은 약 하루 반 안에 있는 메모가 표식 하나로 모인다.
    static func clusterInterval(
        visibleDuration: TimeInterval
    ) -> TimeInterval {
        max(
            markerDuration,
            visibleDuration * RecordClockDetailEngine.minimumArcFraction
        )
    }

    /// 시간표 메모 줄에 그려질 표식. 여러 메모가 모였으면 `memoIDs` 가 그
    /// 전부를 들고 있어 탭 한 번으로 묶음을 열 수 있다.
    struct Marker: Identifiable, Equatable, Sendable {
        let id: UUID
        let span: TimeSpan
        let memoIDs: [UUID]
        let title: String

        var count: Int { memoIDs.count }
    }

    static func markers(
        from memos: [ActionMemo],
        in span: TimeSpan,
        visibleDuration: TimeInterval
    ) -> [Marker] {
        let interval = clusterInterval(visibleDuration: visibleDuration)
        let sorted = memos
            .filter { $0.occurredAt >= span.start && $0.occurredAt < span.end }
            .sorted {
                $0.occurredAt == $1.occurredAt
                    ? $0.id.uuidString < $1.id.uuidString
                    : $0.occurredAt < $1.occurredAt
            }
        var result: [Marker] = []
        var grouped: [ActionMemo] = []
        for memo in sorted {
            // 앞 메모와의 간격이 표식 하나 길이보다 좁으면 같은 자리를 다시
            // 칠할 뿐이므로 이어 붙인다. 눈금판 띠의 합치기 규칙과 같다.
            if let previous = grouped.last,
               memo.occurredAt.timeIntervalSince(previous.occurredAt)
                   < interval {
                grouped.append(memo)
                continue
            }
            if let marker = marker(grouped, interval: interval) {
                result.append(marker)
            }
            grouped = [memo]
        }
        if let marker = marker(grouped, interval: interval) {
            result.append(marker)
        }
        return result
    }

    /// 표식을 탭했을 때 열 메모. 표식이 덮은 구간은 반열림이라 이웃 표식의
    /// 메모를 끌어오지 않는다.
    static func memoIDs(
        in span: TimeSpan,
        from memos: [ActionMemo]
    ) -> [UUID] {
        memos
            .filter { $0.occurredAt >= span.start && $0.occurredAt < span.end }
            .sorted { $0.occurredAt < $1.occurredAt }
            .map(\.id)
    }

    /// 하단 메모 카드가 늘어놓는 메모. 표식과 달리 합치지 않고 시간 순서
    /// 그대로 보여 준다. 구간이 반열림인 것은 표식과 같다.
    static func detailList(
        in span: TimeSpan,
        from memos: [ActionMemo]
    ) -> [ActionMemo] {
        memos
            .filter { $0.occurredAt >= span.start && $0.occurredAt < span.end }
            .sorted {
                $0.occurredAt == $1.occurredAt
                    ? $0.createdAt < $1.createdAt
                    : $0.occurredAt < $1.occurredAt
            }
    }

    /// 메모를 남길 순간. 시간표가 지금을 비추고 있으면 지금이고, 지난 기간을
    /// 펼쳐 둔 상태라면 화면 한가운데다. 어제에 남긴 메모는 어제에 남는다.
    static func entryDate(now: Date, visibleSpan: TimeSpan) -> Date {
        guard now >= visibleSpan.start, now < visibleSpan.end else {
            return visibleSpan.start
                .addingTimeInterval(visibleSpan.duration / 2)
        }
        return now
    }

    static func title(count: Int, firstText: String) -> String {
        count <= 1
            ? firstText.trimmingCharacters(in: .whitespacesAndNewlines)
            : "메모 \(count)개"
    }

    private static func marker(
        _ memos: [ActionMemo],
        interval: TimeInterval
    ) -> Marker? {
        guard let first = memos.first, let last = memos.last else {
            return nil
        }
        return Marker(
            id: first.id,
            span: TimeSpan(
                start: first.occurredAt,
                end: last.occurredAt.addingTimeInterval(interval)
            ),
            memoIDs: memos.map(\.id),
            title: title(count: memos.count, firstText: first.text)
        )
    }
}

// MARK: - 하루의 줄거리

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

    /// 집 반대편에 등록해 둔 곳이 오가는 길의 이름을 정한다. 취미·운동은
    /// 오가는 일이 아니라 그 자체가 하루의 한 대목이라 출퇴근 같은 말 대신
    /// 시작·종료로 적는다. 집이나 이름 없는 곳은 여기서 아무 말도 만들지
    /// 않고, 부르는 말을 정지 문맥에 넘긴다.
    static func roundTrip(
        to kind: FrequentPlaceKind
    ) -> (there: DayPhase, back: DayPhase)? {
        switch kind {
        case .company: (.commuteToWork, .commuteHomeFromWork)
        case .school: (.commuteToSchool, .commuteHomeFromSchool)
        case .academy: (.commuteToAcademy, .commuteHomeFromAcademy)
        case .hobby, .exercise: (.activityDeparture, .activityReturn)
        case .home, .custom: nil
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
                categoryIDs: [
                    "activity", "rest", "routine", "food", "relationship",
                    "health", "appUsage",
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
            let phase = switch scope {
            case .legacy: value.phase
            case .canonical: RecordAnalysisCategoryPolicy.canonicalPhase(value.phase)
            }
            totals[phase, default: 0] += value.span.duration
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

    /// 층이 바뀌어 둘로 갈린 체류처럼 맞닿은 같은 문맥만 하나로 붙인다.
    /// 점심처럼 사이가 벌어진 시간은 메우지 않고 빈칸으로 남긴다.
    private static func mergedBlocks(
        _ contexts: [(kind: StationaryContextKind, span: TimeSpan)],
        kind: StationaryContextKind,
        as phase: DayPhase
    ) -> [DayPhaseSpan] {
        ActualIntervalMergeEngine.union(
            contexts.filter { $0.kind == kind }.map(\.span),
            mergeGap: 60
        )
        .map { DayPhaseSpan(phase: phase, span: $0) }
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

    // MARK: - 오감

    /// 걷고·타고·걷는 한 번의 오감은 이동 구간 여럿으로 들어온다. 사이가
    /// 짧고 그 사이에 들른 곳이 없으면 한 줄로 잇는다.
    private static func chains(
        travel: [TravelSegment],
        contexts: [(kind: StationaryContextKind, span: TimeSpan)],
        window: TimeSpan
    ) -> [TimeSpan] {
        var result: [TimeSpan] = []
        for leg in travel
            .compactMap({ $0.span.intersection(with: window) })
            .sorted(by: { $0.start < $1.start }) {
            guard var current = result.popLast() else {
                result.append(leg)
                continue
            }
            let gap = TimeSpan(
                start: current.end,
                end: max(current.end, leg.start)
            )
            if leg.start <= current.end.addingTimeInterval(transferGap),
               !visited(during: gap, contexts: contexts) {
                current.end = max(current.end, leg.end)
                result.append(current)
            } else {
                result.append(current)
                result.append(leg)
            }
        }
        return result
    }

    /// 갈아타며 기다린 시간은 아직 오는 길이지만, 카페나 운동시설처럼 들른
    /// 곳이 있으면 거기서 오감이 끊긴다. 대기·머무름은 갈 곳을 가리키지
    /// 않으므로 길을 끊지 않는다.
    private static func visited(
        during gap: TimeSpan,
        contexts: [(kind: StationaryContextKind, span: TimeSpan)]
    ) -> Bool {
        guard gap.duration > 0 else { return false }
        return contexts.contains {
            $0.kind != .waiting
                && $0.kind != .unknownStay
                && $0.span.intersection(with: gap) != nil
        }
    }

    /// 집 반대편에 등록해 둔 곳에 머문 시간. 오감의 이름을 여기서 가져온다.
    private struct NamedDestination {
        let there: DayPhase
        let back: DayPhase
        let span: TimeSpan
    }

    /// 자주가는 곳으로 확정된 체류만 이름을 갖는다. 집과 이름 없는 종류는
    /// 여기 들어오지 않아 오감의 이름을 만들지 못한다.
    private static func destinations(
        stays: [PlaceStay],
        placeKinds: [String: FrequentPlaceKind],
        window: TimeSpan
    ) -> [NamedDestination] {
        stays.compactMap { stay in
            guard let kind = placeKinds[stay.placeKey],
                  let pair = DayPhase.roundTrip(to: kind),
                  let visible = stay.span.intersection(with: window) else {
                return nil
            }
            return NamedDestination(
                there: pair.there,
                back: pair.back,
                span: visible
            )
        }
        .sorted { $0.span.start < $1.span.start }
    }

    /// 오감의 이름은 어디서 떠나 어디에 닿았는지가 정한다. 집을 나서 등록해
    /// 둔 곳에 닿으면 그 곳의 종류가 이름을 정하고, 그 반대가 돌아오는 길이다.
    /// 둘 중 어느 쪽도 아니면 이름을 붙이지 않는다.
    private static func commutes(
        travel: [TravelSegment],
        contexts: [(kind: StationaryContextKind, span: TimeSpan)],
        window: TimeSpan,
        workBlocks: [DayPhaseSpan],
        homeSpans: [TimeSpan],
        destinations: [NamedDestination]
    ) -> [DayPhaseSpan] {
        chains(travel: travel, contexts: contexts, window: window)
        .compactMap { chain in
            if left(homeSpans, at: chain.start),
               let phase = phaseGoingOut(
                   after: chain.end,
                   destinations: destinations,
                   workBlocks: workBlocks
               ) {
                return DayPhaseSpan(phase: phase, span: chain)
            }
            if arrived(homeSpans, at: chain.end),
               let phase = phaseComingHome(
                   before: chain.start,
                   destinations: destinations,
                   workBlocks: workBlocks
               ) {
                return DayPhaseSpan(phase: phase, span: chain)
            }
            return nil
        }
    }

    /// 등록해 둔 곳에 닿았으면 그 종류가 이름을 정한다. 등록하지 않은 곳이나
    /// 이름 없는 종류에 닿았으면 도착해서 무엇이 시작되는지를 보고 정하던
    /// 예전 규칙으로 돌아가고, 그마저 없으면 이름을 짓지 않는다.
    private static func phaseGoingOut(
        after boundary: Date,
        destinations: [NamedDestination],
        workBlocks: [DayPhaseSpan]
    ) -> DayPhase? {
        if let arrival = destinations.first(where: {
            follows($0.span, boundary)
        }) {
            return arrival.there
        }
        guard let arrival = workBlocks.first(where: {
            follows($0.span, boundary)
        }) else {
            return nil
        }
        return arrival.phase == .work ? .commuteToWork : .commuteToSchool
    }

    private static func phaseComingHome(
        before boundary: Date,
        destinations: [NamedDestination],
        workBlocks: [DayPhaseSpan]
    ) -> DayPhase? {
        if let departure = destinations.last(where: {
            precedes($0.span, boundary)
        }) {
            return departure.back
        }
        guard let departure = workBlocks.last(where: {
            precedes($0.span, boundary)
        }) else {
            return nil
        }
        return departure.phase == .work
            ? .commuteHomeFromWork
            : .commuteHomeFromSchool
    }

    /// 그 경계 직전까지 이어지던 시간인지. 오차만큼은 맞닿은 것으로 본다.
    private static func precedes(_ span: TimeSpan, _ boundary: Date) -> Bool {
        span.start < boundary
            && span.end >= boundary.addingTimeInterval(-joinTolerance)
    }

    /// 그 경계 직후부터 이어지는 시간인지.
    private static func follows(_ span: TimeSpan, _ boundary: Date) -> Bool {
        span.end > boundary
            && span.start <= boundary.addingTimeInterval(joinTolerance)
    }

    private static func left(_ spans: [TimeSpan], at boundary: Date) -> Bool {
        spans.contains { precedes($0, boundary) }
    }

    private static func arrived(_ spans: [TimeSpan], at boundary: Date) -> Bool {
        spans.contains { follows($0, boundary) }
    }

    /// 저녁은 그날의 일과를 마치고 돌아온 뒤 집에 있었다는 근거에서만 나온다.
    /// 돌아온 길이 없으면 저녁도 없다. 취미·운동을 다녀온 길은 여기 들지
    /// 않는다 — 저녁에 잠깐 나갔다 왔다고 그 전에 집에서 보낸 저녁이 없던
    /// 일이 되면 안 된다.
    private static func evenings(
        after commutes: [DayPhaseSpan],
        homeSpans: [TimeSpan],
        in span: TimeSpan
    ) -> [DayPhaseSpan] {
        guard let returned = commutes
            .filter({
                $0.phase == .commuteHomeFromWork
                    || $0.phase == .commuteHomeFromSchool
                    || $0.phase == .commuteHomeFromAcademy
            })
            .map(\.span.end)
            .max() else {
            return []
        }
        let evening = TimeSpan(start: returned, end: max(returned, span.end))
        return homeSpans
            .compactMap { $0.intersection(with: evening) }
            .map { DayPhaseSpan(phase: .evening, span: $0) }
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

/// 눈금판에 덧대는 띠의 조각을 만든다. 이미 받아 둔 수면 단계와 이동 구간,
/// 정지 문맥만 읽고 건강 데이터를 새로 묻지 않는다.
enum RecordClockDetailEngine {
    /// 이보다 짧은 조각은 띠 굵기보다 얇게 그려져 보이지도 않으면서 그리는
    /// 값만 늘린다. 하루의 0.4%는 약 6분이다.
    static let minimumArcFraction: Double = 0.004

    /// 한 띠가 가질 수 있는 조각 수의 상한. 넘으면 기준을 넓혀 더 합친다.
    /// 재생 중에는 이 띠를 프레임마다 다시 그리므로 상한이 곧 예산이다.
    static let maximumArcCount = 32

    /// 가장 바깥의 일과 띠. 조각을 만드는 규칙은 `DayPhaseEngine` 이 정하고,
    /// 여기서는 안쪽 띠와 똑같은 기준으로 얇은 조각을 합쳐 그릴 값을 줄인다.
    static func phaseRing(
        actuals: [ActualRecord],
        travel: [TravelSegment],
        stays: [PlaceStay],
        placeKinds: [String: FrequentPlaceKind],
        in span: TimeSpan,
        asOf: Date = .now,
        scope: RecordAnalysisScope = .legacy
    ) -> RecordClockDetailRing? {
        let phases = DayPhaseEngine.completePhases(
            actuals: actuals,
            travel: travel,
            stays: stays,
            placeKinds: placeKinds,
            in: span,
            asOf: asOf
        )
        let pieces = phases.map { phase -> (String, TimeSpan) in
            let value = switch scope {
            case .legacy: phase.phase
            case .canonical: RecordAnalysisCategoryPolicy.canonicalPhase(phase.phase)
            }
            return (value.rawValue, phase.span)
        }
        return ring(
            kind: .dayPhase,
            pieces: pieces,
            in: span
        )
    }

    /// 두 번째이자 마지막 단계인 활동 띠에 덮어 쓸 세부 근거. 수면 단계와
    /// 이동수단은 별도 상세 띠를 만들지 않고 해당 활동 구간의 색을 바꾼다.
    static func activityRings(
        sleepSessions: [SleepSession],
        travel: [TravelSegment],
        in span: TimeSpan,
        scope: RecordAnalysisScope = .legacy
    ) -> [RecordClockDetailRing] {
        [
            activitySleepRing(
                sessions: sleepSessions,
                in: span,
                scope: scope
            ),
            travelRing(
                segments: travel,
                in: span,
                scope: scope
            ),
        ].compactMap { $0 }
    }

    /// 수면 단계 띠. HealthKit은 같은 시각에 여러 단계를 겹쳐 보내므로
    /// 경계마다 한 단계를 골라 한 줄로 편다.
    static func sleepRing(
        sessions: [SleepSession],
        in span: TimeSpan,
        scope: RecordAnalysisScope = .legacy
    ) -> RecordClockDetailRing? {
        var seen = Set<UUID>()
        var clipped: [(stage: SleepStage, span: TimeSpan)] = []
        for session in sessions {
            for segment in session.segments {
                guard seen.insert(segment.id).inserted else { continue }
                let stage: SleepStage?
                switch scope {
                case .legacy:
                    stage = segment.stage
                case .canonical:
                    stage = RecordAnalysisCategoryPolicy.canonicalSleepStage(
                        segment.stage
                    )
                }
                guard let stage else { continue }
                guard let visible = segment.span.intersection(with: span),
                      visible.duration > 0 else {
                    continue
                }
                clipped.append((stage, visible))
            }
        }
        return ring(
            kind: .sleepStage,
            pieces: resolvedStages(clipped),
            in: span
        )
    }

    /// 활동 띠에는 실제로 잠든 단계만 올린다. `침대에 있음`과 `깨어 있음`은
    /// 수면 단계가 아니므로 기존 수면 구간의 바탕색으로 남는다.
    static func activitySleepRing(
        sessions: [SleepSession],
        in span: TimeSpan,
        scope: RecordAnalysisScope = .legacy
    ) -> RecordClockDetailRing? {
        guard let source = sleepRing(
            sessions: sessions,
            in: span,
            scope: scope
        ) else {
            return nil
        }
        let asleep = source.arcs.filter {
            SleepStage(rawValue: $0.token)?.isAsleep == true
        }
        guard !asleep.isEmpty else { return nil }
        let hasWatchSource = sessions.flatMap(\.segments).contains { segment in
            segment.sourceName.localizedCaseInsensitiveContains("watch")
                || segment.deviceName?
                    .localizedCaseInsensitiveContains("watch") == true
        }
        guard !hasWatchSource else {
            return RecordClockDetailRing(
                id: source.id,
                kind: source.kind,
                arcs: asleep
            )
        }
        let pieces = asleep.map { arc in
            (
                SleepStage.asleepUnspecified.rawValue,
                TimeSpan(
                    start: span.start.addingTimeInterval(
                        span.duration * arc.startFraction
                    ),
                    end: span.start.addingTimeInterval(
                        span.duration * arc.endFraction
                    )
                )
            )
        }
        return ring(kind: .sleepStage, pieces: pieces, in: span)
    }

    /// 이동 구간 띠. 같은 이동 수단이 이어지면 한 조각으로 붙인다.
    static func travelRing(
        segments: [TravelSegment],
        in span: TimeSpan,
        scope: RecordAnalysisScope = .legacy
    ) -> RecordClockDetailRing? {
        var seen = Set<UUID>()
        var pieces: [(token: String, span: TimeSpan)] = []
        for segment in segments.sorted(by: { $0.span.start < $1.span.start }) {
            guard seen.insert(segment.id).inserted else { continue }
            guard let visible = segment.span.intersection(with: span),
                  visible.duration > 0 else {
                continue
            }
            // 겹쳐 들어온 구간도 한 줄에 그려야 하므로 앞 조각 뒤로 민다.
            let start = max(visible.start, pieces.last?.span.end ?? visible.start)
            guard start < visible.end else { continue }
            let token: String
            switch scope {
            case .legacy:
                token = segment.mode.rawValue
            case .canonical:
                token = RecordAnalysisCategoryPolicy.movementToken(
                    for: segment.mode
                )
            }
            pieces.append(
                (
                    token,
                    TimeSpan(start: start, end: visible.end)
                )
            )
        }
        return ring(kind: .travel, pieces: pieces, in: span)
    }

    /// 측정 시각별 날씨 띠. 같은 상태는 `WeatherTimelineEngine`이 하나로
    /// 합치고, 상태가 바뀐 시각만 원 안쪽에서 경계를 만든다.
    static func weatherRing(
        contexts: [WeatherContext],
        in span: TimeSpan,
        asOf: Date = .now
    ) -> RecordClockDetailRing? {
        let limit = min(span.end, asOf)
        guard span.start < limit else { return nil }
        let visibleSpan = TimeSpan(start: span.start, end: limit)
        let pieces = WeatherTimelineEngine.coalesced(contexts).compactMap {
            context -> (token: String, span: TimeSpan)? in
            guard context.observedAt < limit,
                  let visible = WeatherTimelineEngine.span(for: context)
                    .intersection(with: visibleSpan),
                  visible.duration > 0 else { return nil }
            return (WeatherClockToken.make(context), visible)
        }
        return ring(kind: .weather, pieces: pieces, in: span)
    }

    /// 머문 장소 띠. 날씨와 함께 상세 고리 아래의 환경 정보로 보여 준다.
    /// 장소 이름과 층수만 토큰으로 보관하고, 원본 위치 좌표는 모델에 그대로
    /// 남겨 둔다.
    static func locationRing(
        stays: [PlaceStay],
        in span: TimeSpan,
        asOf: Date = .now
    ) -> RecordClockDetailRing? {
        let limit = min(span.end, asOf)
        guard span.start < limit else { return nil }
        let visibleSpan = TimeSpan(start: span.start, end: limit)
        let pieces = stays.compactMap { stay -> (token: String, span: TimeSpan)? in
            guard let visible = stay.span.intersection(with: visibleSpan),
                  visible.duration > 0 else { return nil }
            let name = stay.displayName
                .replacingOccurrences(of: "|", with: "/")
            let token = stay.floor.map { "\(name) · \($0)층" } ?? name
            return (token, visible)
        }
        return ring(kind: .location, pieces: pieces, in: span)
    }

    /// 겹친 단계 가운데 구체적인 관측이 이긴다. 경계마다 한 단계만 남겨
    /// 띠가 서로를 가리지 않게 한다.
    private static func resolvedStages(
        _ segments: [(stage: SleepStage, span: TimeSpan)]
    ) -> [(token: String, span: TimeSpan)] {
        let boundaries = Array(
            Set(segments.flatMap { [$0.span.start, $0.span.end] })
        ).sorted()
        guard boundaries.count >= 2 else { return [] }

        var result: [(token: String, span: TimeSpan)] = []
        for (start, end) in zip(boundaries, boundaries.dropFirst()) {
            guard start < end else { continue }
            let winner = segments
                .filter { $0.span.start < end && start < $0.span.end }
                .max { $0.stage.overlapPriority < $1.stage.overlapPriority }
            guard let winner else { continue }
            result.append(
                (winner.stage.rawValue, TimeSpan(start: start, end: end))
            )
        }
        return result
    }

    private static func ring(
        kind: RecordClockDetailKind,
        pieces: [(token: String, span: TimeSpan)],
        in span: TimeSpan
    ) -> RecordClockDetailRing? {
        let total = span.duration
        guard total > 0, !pieces.isEmpty else { return nil }

        var minimum = minimumArcFraction
        var condensed = condensed(pieces, minimumDuration: minimum * total)
        while condensed.count > maximumArcCount, minimum < 0.05 {
            minimum *= 2
            condensed = self.condensed(
                pieces,
                minimumDuration: minimum * total
            )
        }
        guard !condensed.isEmpty else { return nil }

        return RecordClockDetailRing(
            id: kind.rawValue,
            kind: kind,
            arcs: condensed.enumerated().map { offset, piece in
                RecordClockDetailArc(
                    id: "\(kind.rawValue).\(offset)",
                    token: piece.token,
                    startFraction: min(
                        1,
                        piece.span.start.timeIntervalSince(span.start) / total
                    ),
                    endFraction: min(
                        1,
                        piece.span.end.timeIntervalSince(span.start) / total
                    )
                )
            }
        )
    }

    /// 눈에 띄지 않을 만큼 짧은 조각은 그리지 않고 이웃에 합친다. 화소보다
    /// 얇은 조각을 수백 개 그리면 화면이 멈춘다. 붙어 있는 이웃이 없으면
    /// 최소 길이까지만 늘려 하나로 남긴다.
    private static func condensed(
        _ pieces: [(token: String, span: TimeSpan)],
        minimumDuration: TimeInterval
    ) -> [(token: String, span: TimeSpan)] {
        var merged: [(token: String, span: TimeSpan)] = []
        for piece in pieces.sorted(by: { $0.span.start < $1.span.start }) {
            guard let last = merged.last else {
                merged.append(piece)
                continue
            }
            let gap = piece.span.start.timeIntervalSince(last.span.end)
            guard gap < minimumDuration else {
                merged.append(piece)
                continue
            }
            if last.token == piece.token
                || piece.span.duration < minimumDuration {
                merged[merged.count - 1] = (
                    last.token,
                    TimeSpan(
                        start: last.span.start,
                        end: max(last.span.end, piece.span.end)
                    )
                )
            } else if last.span.duration < minimumDuration {
                // 앞 조각이 너무 짧으면 뒤 조각이 그 자리를 이어받는다.
                merged[merged.count - 1] = (
                    piece.token,
                    TimeSpan(start: last.span.start, end: piece.span.end)
                )
            } else {
                merged.append(piece)
            }
        }

        return merged.map { piece in
            guard piece.span.duration < minimumDuration else { return piece }
            return (
                piece.token,
                TimeSpan(
                    start: piece.span.start,
                    end: piece.span.start.addingTimeInterval(minimumDuration)
                )
            )
        }
    }
}

// MARK: - 하루 원형 시간표의 재생·고르기

/// 원형 시간표는 재생 중 매 프레임 다시 그린다. 그때마다 하루를 다시 집계하면
/// 예산을 넘기므로, 이미 만들어 둔 고리를 자르고 고르는 일만 여기서 한다.
enum RecordClockEngine {
    /// 재생이 00시에서 24시까지 한 바퀴 도는 데 걸리는 시간. 오늘은 같은
    /// 속도로 현재 시각까지만 진행한다.
    static let sweepDuration: TimeInterval = 24

    /// 재생 중 화면 갱신 예산. 한 시간당 1초라 60Hz면 충분히 매끄럽다.
    static let frameInterval: TimeInterval = 1.0 / 60.0

    /// 24시간 눈금판에 표시하는 모든 시각.
    static let labeledHours = Array(0..<24)

    /// 가로로 이만큼 끌어야 날짜가 넘어간다.
    static let swipeThreshold: Double = 44

    /// 보고 있는 하루가 지금을 품을 때만 현재 시각 위치(0…1)를 준다.
    /// 오늘이 아니면 바늘을 그리지 않는다.
    static func nowFraction(in span: TimeSpan, asOf: Date = .now) -> Double? {
        let total = span.duration
        guard total > 0, span.start <= asOf, asOf < span.end else { return nil }
        return asOf.timeIntervalSince(span.start) / total
    }

    /// 과거 날짜는 24시, 오늘은 현재 시각, 미래 날짜는 00시까지만 재생한다.
    static func playbackEndFraction(
        in span: TimeSpan,
        asOf: Date = .now
    ) -> Double {
        guard span.duration > 0 else { return 0 }
        if asOf <= span.start { return 0 }
        if asOf >= span.end { return 1 }
        return asOf.timeIntervalSince(span.start) / span.duration
    }

    /// 재생 진행률. `endFraction`에 도달하면 더 진행하지 않는다.
    static func progress(
        start: Date?,
        now: Date,
        endFraction: Double = 1
    ) -> Double? {
        guard let start else { return nil }
        let end = endFraction.isFinite
            ? min(1, max(0, endFraction))
            : 1
        let elapsed = now.timeIntervalSince(start)
        guard elapsed.isFinite else { return 0 }
        guard elapsed > 0 else { return 0 }
        return min(end, elapsed / sweepDuration)
    }

    /// 자정이 위쪽인 24시간 시계에서 한 점의 시각 비율을 구한다.
    static func clockFraction(
        x: Double,
        y: Double,
        centerX: Double,
        centerY: Double
    ) -> Double {
        var fraction = (atan2(y - centerY, x - centerX) + .pi / 2)
            / (2 * .pi)
        fraction -= floor(fraction)
        return fraction
    }

    /// 범례에서 고른 카테고리만 남긴다. 고르지 않았으면 그대로 둔다.
    static func rings(
        _ rings: [RecordClockRing],
        isolating categoryID: String?
    ) -> [RecordClockRing] {
        guard let categoryID else { return rings }
        return rings.filter { $0.categoryID == categoryID }
    }

    /// 재생머리가 지난 만큼만 남긴다. 진행률이 nil이면 자르지 않는다.
    static func rings(
        _ rings: [RecordClockRing],
        revealedThrough progress: Double?
    ) -> [RecordClockRing] {
        guard let progress else { return rings }
        return rings.compactMap { ring in
            let arcs = ring.arcs.compactMap { arc -> RecordClockArc? in
                guard arc.startFraction < progress else { return nil }
                guard arc.endFraction > progress else { return arc }
                return RecordClockArc(
                    id: arc.id,
                    categoryID: arc.categoryID,
                    startFraction: arc.startFraction,
                    endFraction: progress
                )
            }
            guard !arcs.isEmpty else { return nil }
            return RecordClockRing(
                id: ring.id,
                categoryID: ring.categoryID,
                duration: ring.duration,
                arcs: arcs
            )
        }
    }

    /// 안쪽 띠도 재생머리를 따라 드러난다. 아직 아무것도 지나지 않았어도
    /// 띠 자체는 남겨야 눈금판에서 줄이 사라졌다 나타나지 않는다.
    static func detailRings(
        _ rings: [RecordClockDetailRing],
        revealedThrough progress: Double?
    ) -> [RecordClockDetailRing] {
        guard let progress else { return rings }
        return rings.map { ring in
            RecordClockDetailRing(
                id: ring.id,
                kind: ring.kind,
                arcs: ring.arcs.compactMap { arc in
                    guard arc.startFraction < progress else { return nil }
                    guard arc.endFraction > progress else { return arc }
                    return RecordClockDetailArc(
                        id: arc.id,
                        token: arc.token,
                        startFraction: arc.startFraction,
                        endFraction: progress
                    )
                }
            )
        }
    }

    /// 띠 하나짜리 바깥 고리도 같은 규칙으로 드러난다.
    static func detailRing(
        _ ring: RecordClockDetailRing?,
        revealedThrough progress: Double?
    ) -> RecordClockDetailRing? {
        guard let ring else { return nil }
        return detailRings([ring], revealedThrough: progress).first
    }

    /// 재생머리가 지금 지나고 있는 조각. 이 조각만 굵게 그리고, 이름과 시각을
    /// 읽음창에 적는다.
    static func arc(
        in ring: RecordClockDetailRing?,
        at fraction: Double
    ) -> RecordClockDetailArc? {
        ring?.arcs.first {
            $0.startFraction <= fraction && fraction < $0.endFraction
        }
    }

    /// 조각이 가리키는 실제 시각. 각도는 하루를 0…1로 나눈 값이라 되돌릴 때
    /// 초 단위로 반올림해야 8시 12분이 8시 11분 59초로 새지 않는다.
    static func span(
        of arc: RecordClockDetailArc,
        in span: TimeSpan
    ) -> TimeSpan {
        TimeSpan(
            start: date(at: arc.startFraction, in: span),
            end: date(at: arc.endFraction, in: span)
        )
    }

    /// 활동 고리의 조각을 사용자가 고른 실제 시각으로 되돌린다.
    static func span(
        of arc: RecordClockArc,
        in span: TimeSpan
    ) -> TimeSpan {
        TimeSpan(
            start: date(at: arc.startFraction, in: span),
            end: date(at: arc.endFraction, in: span)
        )
    }

    /// 읽음창이 적는 시각. 기록 상세·목표 화면이 구간을 적을 때와 같은 표기라
    /// 화면마다 시각을 다르게 읽지 않는다. 오전·오후를 떼면 눈금판이 24시간
    /// 판인데 6시가 두 번 생겨 읽는 사람이 어느 쪽인지 알 수 없다.
    static func timeRangeText(_ span: TimeSpan) -> String {
        "\(clockText(span.start))–\(clockText(span.end))"
    }

    private static func clockText(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    private static func date(at fraction: Double, in span: TimeSpan) -> Date {
        span.start.addingTimeInterval((fraction * span.duration).rounded())
    }

    /// 재생머리가 지금 지나고 있는 카테고리. 이 기록만 굵게 그린다.
    static func categoryIDs(
        in rings: [RecordClockRing],
        at fraction: Double
    ) -> Set<String> {
        var result: Set<String> = []
        for ring in rings where ring.arcs.contains(
            where: { $0.startFraction <= fraction && fraction < $0.endFraction }
        ) {
            result.insert(ring.categoryID)
        }
        return result
    }

    /// 가운데 고정 재생머리에서 스크롤한 거리와 하루 위치를 서로 바꾼다.
    static func playheadFraction(
        contentOffset: Double,
        timelineWidth: Double
    ) -> Double {
        guard timelineWidth > 0 else { return 0 }
        return min(1, max(0, contentOffset / timelineWidth))
    }

    static func contentOffset(
        for fraction: Double,
        timelineWidth: Double
    ) -> Double {
        max(0, timelineWidth) * min(1, max(0, fraction))
    }

    /// 가로로 충분히 끌었을 때만 날짜를 옮긴다. 왼쪽으로 끌면 다음 날이다.
    /// 세로가 더 길면 목록 스크롤이므로 날짜를 건드리지 않는다.
    static func swipeStep(
        width: Double,
        height: Double,
        threshold: Double = swipeThreshold
    ) -> Int? {
        guard abs(width) >= threshold, abs(width) > abs(height) else {
            return nil
        }
        return width < 0 ? 1 : -1
    }
}
