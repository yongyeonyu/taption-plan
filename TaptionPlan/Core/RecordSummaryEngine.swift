import Foundation
import TaptionPlanEngine

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

    static func english(_ interval: TimeInterval) -> String {
        let totalMinutes = max(0, Int(interval / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return AppLanguagePreference.ResolvedLanguage.english.text("\(minutes)분", "\(minutes)m") }
        if minutes == 0 { return AppLanguagePreference.ResolvedLanguage.english.text("\(hours)시간", "\(hours)h") }
        return AppLanguagePreference.ResolvedLanguage.english.text("\(hours)시간 \(minutes)분", "\(hours)h \(minutes)m")
    }

    static func localized(_ interval: TimeInterval, english useEnglish: Bool) -> String {
        useEnglish ? english(interval) : korean(interval)
    }
}

/// 자동 기록은 `activity` 하나에 걸음·수면·이동이 섞여 들어온다. 어느 줄에
/// 묶을지 판단하는 규칙을 화면마다 따로 두면 시간표와 기록이 어긋나므로
/// 한 곳에서만 정한다.
enum ActualRecordCategoryResolver {
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
        // 단어 경계 판정(ClassifierKeywords): "배달"·"배드민턴"이 이동이 되지 않는다.
        switch ClassifierKeywords.categoryID(in: "\(actual.title) \(actual.behavior ?? "")") {
        case "sleep": return "sleep"
        case "movement": return "movement"
        default: return "activity"
        }
    }
}

/// 기록 화면과 자동 분류가 공유하는 최소 분류표다. 센서·HealthKit 원본의
/// `categoryID`, 제목, 근거는 바꾸지 않고, 저장 기록을 분석·표시할 때만 이
/// 일과 → 상세활동 계층으로 정규화한다.
enum RecordAnalysisCategoryPolicy {
    // 같은 레코드를 한 화면 갱신에서 여러 엔진이 반복 분류하던 것을 없앤다.
    // 분류는 순수 함수(입력: title/behavior/categoryID/evidence)이므로 그
    // 입력이 그대로면 결과도 같다. 뷰 body 경로에서 하루 actuals × 수십
    // 키워드 contains가 재실행돼 watchdog(36초)을 넘기던 CRS0925W01의 뿌리.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var categoryCache: [String: String] = [:]

    private static func cacheKey(_ actual: ActualRecord) -> String {
        "\(actual.id.uuidString)|\(actual.title)|\(actual.behavior ?? "")|\(actual.categoryID)|\(actual.source)|\(actual.manuallyCorrected)|\(actual.evidence.joined(separator: ","))"
    }

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
    /// 분류 결과는 레코드 입력 기준으로 캐시한다(CRS0925W01).
    static func categoryID(for actual: ActualRecord) -> String {
        let key = cacheKey(actual)
        cacheLock.lock()
        if let cached = categoryCache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        let result = _computeCategoryID(for: actual)
        cacheLock.lock()
        if categoryCache.count >= 4_096 { categoryCache.removeAll(keepingCapacity: true) }
        categoryCache[key] = result
        cacheLock.unlock()
        return result
    }

    private static func _computeCategoryID(for actual: ActualRecord) -> String {
        if let relocated = RecordClassificationCatalog.relocatedCategoryID(from: actual.categoryID, behavior: actual.behavior) { return relocated }
        if actual.manuallyCorrected || actual.source == .manual, categoryIDs.contains(actual.categoryID) {
            return actual.categoryID
        }
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
            return "housework"
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
            case "food", "eating":
                return "eating"
            default:
                return "activity"
            }
        }

        if value.contains("깊은수면") {
            return "sleep"
        }
        // 단어 경계 판정 하나(ClassifierKeywords)로 정한다. 부분 문자열로 보면
        // "배달"·"배드민턴"이 이동, "remote"가 수면이 됐다.
        if let keywordCategory = ClassifierKeywords.categoryID(
            in: "\(actual.title) \(actual.behavior ?? "")"
        ), keywordCategory != "activity" {
            return keywordCategory
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
        case "work": return "업무"
        case "study": return "수업(집 - 학교·학원)"
        case "hobby": return "취미(집 - 취미)"
        case "exercise": return "운동"
        case "shower": return "샤워"
        case "housework": return "집안일"
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

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
    }
}

/// 목록·고리·막대가 같은 분석 범위 규칙을 쓰도록 한 곳에 둔다.
extension RecordAnalysisScope {
    func categoryID(for actual: ActualRecord) -> String {
        switch self {
        case .legacy: ActualRecordCategoryResolver.categoryID(for: actual)
        case .canonical: RecordAnalysisCategoryPolicy.categoryID(for: actual)
        }
    }

    func phase(_ phase: DayPhase) -> DayPhase {
        switch self {
        case .legacy: phase
        case .canonical: RecordAnalysisCategoryPolicy.canonicalPhase(phase)
        }
    }
}
