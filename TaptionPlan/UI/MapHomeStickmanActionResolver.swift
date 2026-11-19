import Foundation
import SwiftUI

enum MapHomeStickmanActionResolver {
    // 현재 시각의 판정에 쓰이는 원본만 hash한다. 활성 기록의 필드 변경도
    // fingerprint에 포함하므로 개수와 ID가 같아도 오래된 결과를 쓰지 않는다.
    private static let actionCacheLock = NSLock()
    private struct ActionCacheKey: Hashable {
        let date: Date
        let inputFingerprint: Int
    }

    private static let actionCacheLimit = 128
    nonisolated(unsafe) private static var actionCache:
        [ActionCacheKey: MapHomeStickmanAction] = [:]

    private static func actionCacheKey(
        date: Date,
        actuals: [ActualRecord],
        travel: [TravelSegment],
        places: [PlaceStay],
        frequentPlaces: [FrequentPlace],
        readings: [SensorReading],
        sleepSessions: [SleepSession]
    ) -> ActionCacheKey {
        var hasher = Hasher()
        hasher.combine(actuals)
        hasher.combine(travel)
        hasher.combine(places)
        hasher.combine(frequentPlaces)
        hasher.combine(readings)
        hasher.combine(sleepSessions)
        return ActionCacheKey(
            date: date,
            inputFingerprint: hasher.finalize()
        )
    }

    static func action(
        at date: Date,
        actuals: [ActualRecord],
        travel: [TravelSegment],
        places: [PlaceStay],
        frequentPlaces: [FrequentPlace],
        readings: [SensorReading] = [],
        sleepSessions: [SleepSession] = []
    ) -> MapHomeStickmanAction {
        let actuals = actuals.filter { active($0, at: date) || isRecentWorkout($0, before: date) }
        let travel = travel.filter { $0.span.contains(date) }
        let places = places.filter { $0.span.contains(date) }
        let readings = readings.filter {
            $0.motion.isMovement && abs($0.timestamp.timeIntervalSince(date)) <= 3 * 60
        }
        let sleepSessions = sleepSessions.filter {
            $0.isAppleWatchConfirmed && $0.span.contains(date)
        }
        let key = actionCacheKey(
            date: date,
            actuals: actuals,
            travel: travel,
            places: places,
            frequentPlaces: frequentPlaces,
            readings: readings,
            sleepSessions: sleepSessions
        )
        actionCacheLock.lock()
        if let cached = actionCache[key] {
            actionCacheLock.unlock()
            return cached
        }
        actionCacheLock.unlock()
        let result = _computeAction(
            at: date,
            actuals: actuals,
            travel: travel,
            places: places,
            frequentPlaces: frequentPlaces,
            readings: readings,
            sleepSessions: sleepSessions
        )
        actionCacheLock.lock()
        if actionCache.count >= actionCacheLimit {
            actionCache.removeAll(keepingCapacity: true)
        }
        actionCache[key] = result
        actionCacheLock.unlock()
        return result
    }

    private static func _computeAction(
        at date: Date,
        actuals: [ActualRecord],
        travel: [TravelSegment],
        places: [PlaceStay],
        frequentPlaces: [FrequentPlace],
        readings: [SensorReading] = [],
        sleepSessions: [SleepSession] = []
    ) -> MapHomeStickmanAction {
        let activeActuals = actuals.compactMap { actual -> (ActualRecord, MapHomeStickmanAction)? in
            guard active(actual, at: date),
                  let action = action(for: actual) else { return nil }
            return (actual, action)
        }
        let hasExplicitOverride = actuals.contains {
            active($0, at: date)
                && ($0.manuallyCorrected || $0.source == .manual)
        }
        if !hasExplicitOverride,
           hasAppleWatchConfirmedSleep(
               at: date,
               actuals: actuals,
               sleepSessions: sleepSessions
           ) {
            return sleepStageAction(at: date, actuals: actuals, sleepSessions: sleepSessions)
        }

        // 사용자가 직접 정한 머무는 분류는 센서가 이동으로 본 구간에서도 그대로 보여 준다.
        if let chosen = activeActuals
            .filter({ ($0.0.manuallyCorrected || $0.0.source == .manual) && !$0.1.isMoving })
            .max(by: higherPriority) {
            return chosen.1
        }

        if let segment = travel
            .filter({ $0.span.contains(date) })
            .max(by: { $0.span.start < $1.span.start }) {
            return action(for: segment.mode)
        }

        // Watch records are the confirmed side of the sensor fusion. Let
        // them win over an inferred iPhone reading while keeping an already
        // resolved travel segment above both sources for transport playback.
        if let candidate = activeActuals
            .filter({ $0.0.source == .appleWatch })
            .max(by: higherPriority) {
            return candidate.1
        }

        let nearbyMovement = readings
            .filter {
                $0.motion.isMovement
                    && abs($0.timestamp.timeIntervalSince(date)) <= 3 * 60
            }
            .min {
                abs($0.timestamp.timeIntervalSince(date))
                    < abs($1.timestamp.timeIntervalSince(date))
            }
        if let nearbyMovement {
            return action(for: nearbyMovement.motion)
        }

        let activePlaces = places
            .filter { $0.span.contains(date) }
            .sorted { $0.span.start > $1.span.start }
        let placeAction = activePlaces.lazy.compactMap { action(for: $0, frequentPlaces: frequentPlaces) }.first
        if let candidate = activeActuals.max(by: higherPriority) {
            // 자동 기록의 일반 활동보다 식당·회사 같은 장소가 더 구체적이다(CAT1103A01).
            let isGeneric = candidate.1 == .activity || candidate.1 == .restStarfish || candidate.1 == .restBox
            if isGeneric, placeAction == nil || placeAction == .activity, recentlyExercised(before: date, actuals: actuals) { return .recovery }
            if candidate.1 == .activity || placeAction != .activity, isGeneric, let placeAction { return placeAction }
            return candidate.1
        }
        if placeAction == nil || placeAction == .activity, recentlyExercised(before: date, actuals: actuals) { return .recovery }
        return placeAction ?? .activity
    }

    /// 운동을 마치고 30분 안에 쉬는 동안은 회복 자세다. 10분 넘게 운동한 기록만 본다.
    private static func recentlyExercised(before date: Date, actuals: [ActualRecord]) -> Bool {
        actuals.contains { isRecentWorkout($0, before: date) }
    }

    private static func isRecentWorkout(_ actual: ActualRecord, before date: Date) -> Bool {
        guard let end = actual.endedAt, end <= date, date.timeIntervalSince(end) <= 30 * 60,
              end.timeIntervalSince(actual.startedAt) >= 10 * 60 else { return false }
        return actual.categoryID.lowercased().split(separator: ".").first == "exercise"
    }

    /// 머문 기록이 생기기 전 실시간 위치의 동작. 지점이 겹치면 가장 작은 곳이다(CAT1103A01).
    static func action(atCurrent point: GeoPoint?, frequentPlaces: [FrequentPlace]) -> MapHomeStickmanAction? {
        guard let point else { return nil }
        let inside = frequentPlaces.filter {
            guard let center = $0.point else { return false }
            let y = (point.latitude - center.latitude) * 111_320
            let x = (point.longitude - center.longitude) * 111_320 * cos(center.latitude * .pi / 180)
            return (x * x + y * y).squareRoot() <= $0.radiusMeters
        }
        return inside.min { $0.radiusMeters < $1.radiusMeters }.map { action(for: $0.kind) }
    }

    private static func action(for kind: FrequentPlaceKind) -> MapHomeStickmanAction {
        switch kind {
        case .company: .company
        case .school: .school
        case .academy: .reading
        case .restaurant: .eating
        case .home, .custom: .activity
        case .hobby: .hobby
        case .exercise: .exercise
        }
    }

    /// 건강 앱 수면 단계에 맞는 장면. 깊은 수면과 REM 말고는 평소 수면 장면이다.
    static func sleepStageAction(
        at date: Date,
        actuals: [ActualRecord],
        sleepSessions: [SleepSession]
    ) -> MapHomeStickmanAction {
        let stage = sleepSessions.lazy
            .filter { $0.span.contains(date) }
            .flatMap(\.segments)
            .first { $0.span.contains(date) && $0.stage.isAsleep }?.stage
        switch stage {
        case .deep: return .deepSleep
        case .rem: return .remSleep
        case .some: return .sleeping
        case nil:
            let staged = actuals.lazy.filter { active($0, at: date) }.compactMap { dailyAction(title: $0.title, behavior: $0.behavior) }
            return staged.first { $0 == .deepSleep || $0 == .remSleep } ?? .sleeping
        }
    }

    static func hasAppleWatchConfirmedSleep(
        at date: Date,
        actuals: [ActualRecord],
        sleepSessions: [SleepSession]
    ) -> Bool {
        guard !actuals.contains(where: {
            active($0, at: date)
                && ($0.manuallyCorrected || $0.source == .manual)
        }) else {
            return false
        }
        if actuals.contains(where: {
            active($0, at: date)
                && isAppleWatchConfirmedSleep($0)
        }) {
            return true
        }
        return sleepSessions.contains {
            $0.isAppleWatchConfirmed && $0.span.contains(date)
        }
    }

    private static func isAppleWatchConfirmedSleep(
        _ actual: ActualRecord
    ) -> Bool {
        guard actual.source == .appleWatch else { return false }
        let categoryRoot = actual.categoryID.lowercased()
            .split(separator: ".", maxSplits: 1)
            .first
            .map(String.init)
        if categoryRoot == "sleep" || categoryRoot == "sleeping" {
            return true
        }
        if actual.behavior?.lowercased() == WatchBehaviorKind.sleep.rawValue {
            return true
        }
        let title = actual.title.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        return title == "수면" || title == "sleep"
    }

    /// 그 시각 대분류와 상세 활동으로 정한 동작. 이동·미확인은 위치·센서 판정에 맡긴다.
    static func railAction(
        segment: MapHomeTimeRailSegment?,
        details: [MapHomeSectionDetail],
        minute: Int? = nil
    ) -> MapHomeStickmanAction? {
        guard let segment, !["movement", "activity", "unconfirmed"].contains(segment.categoryID) else { return nil }
        // 그 시각에 걸친 상세만 본다. 구간 전체에서 고르면 1분짜리 걷기가 근무 내내 이겼다(PLY1106A01).
        let current = minute.map { minute in details.filter { $0.startMinute <= minute && minute < $0.endMinute } } ?? details
        // 가장 짧은 상세가 가장 구체적이다.
        let detail = current.min { ($0.endMinute - $0.startMinute) < ($1.endMinute - $1.startMinute) }
        return action(for: segment.categoryID, label: detail?.title ?? "")
    }

    static func action(for mode: TravelMode) -> MapHomeStickmanAction {
        switch mode {
        case .walking: .walking
        case .running: .running
        case .cycling: .cycling
        case .car, .taxi: .car
        case .subway: .subway
        case .train: .train
        case .bus: .bus
        case .airplane: .airplane
        case .ship: .ship
        }
    }

    static func action(
        for categoryID: String,
        label: String
    ) -> MapHomeStickmanAction {
        // 사용자 분류에 고른 화랑이 동작이 있으면 메뉴·재생 모두 그 동작이다.
        if let custom = MapHomeCustomAnimations.action(categoryID: categoryID) { return custom }
        let category = categoryID.lowercased()
        let categoryRoot = category.split(separator: ".", maxSplits: 1).first.map(String.init) ?? category
        let value = "\(category) \(label)".lowercased()
        if let daily = dailyAction(title: label, behavior: nil) { return daily }
        let detailMappings: [(String, MapHomeStickmanAction)] = [
            ("activity.rest", .restStarfish),
            ("work.rest", .restCroissant),
            ("work.walking", .workWalking),
            ("study.rest", .restDonut),
            ("hobby.rest", .restLoaf),
            ("health.recovery", .recovery),
            ("health.medication", .medication),
            ("sleep.deep", .deepSleep),
            ("sleep.rem", .remSleep),
            ("movement.walking", .walking),
            ("movement.running", .running),
            ("movement.car", .car),
            ("movement.subway", .subway),
            ("movement.train", .train),
            ("movement.privatevehicle", .car),
            ("movement.bus", .bus),
            ("movement.ship", .ship),
            ("movement.airplane", .airplane),
            ("movement.cycling", .cycling)
        ]
        if let mapping = detailMappings.first(where: { category == $0.0 }) { return mapping.1 }
        // 대분류 줄의 상세 이름 '휴식'도 기록과 같은 휴식 자세다(PLY1106A01).
        if let rest = restAction(categoryRoot: categoryRoot, title: label, behavior: nil) { return rest }
        if let walking = workWalkingAction(categoryRoot: categoryRoot, title: label, behavior: nil) { return walking }
        if categoryRoot == "company" || value.contains("company") { return .company }
        if categoryRoot == "school" || value.contains("school") { return .school }
        if let action = majorCategoryAction(for: categoryRoot) {
            if categoryRoot == "work", value.contains("회사") { return .company }
            if categoryRoot == "study", value.contains("학교") { return .school }
            return action
        }
        if categoryRoot == "work", value.contains("회사") {
            return .company
        }
        if categoryRoot == "study", value.contains("학교") {
            return .school
        }
        // 사용자가 추가한 분류 이름. "housework"가 아래 "work"에 걸리지 않게 먼저 본다.
        if value.contains("샤워") || value.contains("shower") { return .shower }
        if value.contains("집안일") || value.contains("청소") || value.contains("housework") { return .housework }
        if categoryRoot == "unconfirmed" || categoryRoot == "unknown"
            || value.contains("unconfirmed") || value.contains("unknown")
            || value.contains("미확인") {
            return .unconfirmed
        }
        if value.contains("running") || value.contains("달리기") {
            return .running
        }
        if value.contains("subway") || value.contains("metro") || value.contains("지하철") {
            return .subway
        }
        if value.contains("privatevehicle") || value.contains("자가용") {
            return .car
        }
        if value.contains("bus") || value.contains("버스") {
            return .bus
        }
        let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.contains("ship") || value.contains("선박") || normalizedLabel == "배" {
            return .ship
        }
        if value.contains("airplane") || value.contains("비행기") || value.contains("항공") {
            return .airplane
        }
        if value.contains("cycling") || value.contains("bike") || value.contains("자전거") {
            return .cycling
        }
        if value.contains("car") || value.contains("driving")
            || value.contains("자동차") || value.contains("차량") {
            return .car
        }
        if value.contains("sleep") || value.contains("수면") || value.contains("잠") {
            return .sleeping
        }
        if value.contains("eating") || value.contains("food")
            || value.contains("식사") || value.contains("밥") {
            return .eating
        }
        if value.contains("work") || value.contains("업무")
            || value.contains("회사") || value.contains("컴퓨터") {
            return .computer
        }
        if value.contains("study") || value.contains("학교")
            || value.contains("수업") || value.contains("독서") {
            return .reading
        }
        if value.contains("exercise") || value.contains("운동") { return .exercise }
        if value.contains("hobby") || value.contains("취미") { return .hobby }
        if value.contains("movement") || value.contains("이동") { return .movement }
        return .activity
    }

    private static func majorCategoryAction(
        for categoryRoot: String
    ) -> MapHomeStickmanAction? {
        switch categoryRoot {
        case "activity": .activity
        case "work", "computer": .computer
        case "study", "reading": .reading
        case "hobby": .hobby
        case "sleep", "sleeping": .sleeping
        case "movement": .movement
        case "eating", "food": .eating
        case "exercise": .exercise
        case "health": .health
        case "shower": .shower
        case "housework": .housework
        case "unconfirmed", "unknown": .unconfirmed
        default: nil
        }
    }

    static func action(for motion: MotionKind) -> MapHomeStickmanAction {
        switch motion {
        case .walking: .walking
        case .running: .running
        case .cycling: .cycling
        case .automotive: .car
        case .stationary: .activity
        case .unknown: .unconfirmed
        }
    }

    private static func active(_ actual: ActualRecord, at date: Date) -> Bool {
        actual.startedAt <= date
            && (actual.endedAt == nil || date <= actual.endedAt!)
    }

    /// 직접 고르는 상세 분류(RIG1103A02). 제목이나 behavior가 정확히 같을 때만 대분류보다 먼저 자기 장면을 쓴다.
    private static let dailyActions: [String: MapHomeStickmanAction] = [
        "깊은 수면": .deepSleep, "deep": .deepSleep, "rem 수면": .remSleep, "rem": .remSleep,
        "회의": .meeting, "meeting": .meeting, "설거지": .dishes, "dishes": .dishes, "커피·티타임": .coffee, "coffee": .coffee, "멍때리기": .restBox, "zoningout": .restBox, "회복": .recovery, "recovery": .recovery, "투약": .medication, "medication": .medication,
        "샤워": .shower, "shower": .shower, "showering": .shower,
        "집안일": .housework, "housework": .housework, "chores": .housework,
        "낮잠": .nap, "nap": .nap, "요리": .cooking, "cooking": .cooking,
        "장보기": .groceries, "groceries": .groceries, "빨래": .laundry, "laundry": .laundry,
        "친구 만남": .friends, "friends": .friends, "데이트": .date, "dating": .date,
        "가족": .family, "family": .family, "통화": .phoneCall, "phonecall": .phoneCall, "공연/영화 관람": .performanceMovie, "performancemovie": .performanceMovie,
        "명상": .meditation, "meditation": .meditation, "병원": .hospital, "hospital": .hospital,
        "미용실": .salon, "salon": .salon, "독서": .bookReading, "reading": .bookReading,
        "게임": .game, "gaming": .game, "음악": .music, "music": .music,
        "영상 보기": .video, "video": .video, "반려동물 돌보기": .petCare, "petcare": .petCare
    ]

    /// 휴식 상세활동은 대분류마다 자세가 다르다. 집에서 쉬는 자동 기록은 상자 안이다.
    private static func restAction(categoryRoot: String, title: String, behavior: String?) -> MapHomeStickmanAction? {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if behavior == StationaryContextKind.homeRest.rawValue || name == "집에서 휴식" { return .restBox }
        guard behavior == "stationary" || name == "휴식" else { return nil }
        switch categoryRoot {
        case "work": return .restCroissant
        case "study": return .restDonut
        case "hobby": return .restLoaf
        case "activity", "rest": return .restStarfish
        default: return nil
        }
    }

    /// 업무 중 걷기는 노트북을 끼고 걷는다. 실제 이동 구간은 이 판정보다 먼저 일반 걷기로 정해진다.
    private static func workWalkingAction(categoryRoot: String, title: String, behavior: String?) -> MapHomeStickmanAction? {
        guard categoryRoot == "work" else { return nil }
        let isWalking = behavior?.lowercased() == "walking" || title.trimmingCharacters(in: .whitespacesAndNewlines) == "걷기"
        return isWalking ? .workWalking : nil
    }

    static func clearActionCache() {
        actionCacheLock.lock(); defer { actionCacheLock.unlock() }
        actionCache.removeAll(keepingCapacity: true)
    }

    private static func dailyAction(title: String, behavior: String?) -> MapHomeStickmanAction? {
        behavior.flatMap { dailyActions[$0.lowercased()] }
            ?? dailyActions[title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }

    private static func action(for actual: ActualRecord) -> MapHomeStickmanAction? {
        if let custom = MapHomeCustomAnimations.action(categoryID: actual.categoryID) { return custom }
        if let daily = dailyAction(title: actual.title, behavior: actual.behavior) { return daily }
        let category = actual.categoryID.lowercased()
        let categoryRoot = category.split(separator: ".", maxSplits: 1).first.map(String.init) ?? category
        if let rest = restAction(categoryRoot: categoryRoot, title: actual.title, behavior: actual.behavior) { return rest }
        if let walking = workWalkingAction(categoryRoot: categoryRoot, title: actual.title, behavior: actual.behavior) { return walking }
        if let action = majorCategoryAction(for: categoryRoot) {
            return action
        }
        let text = ([actual.title, actual.behavior] + actual.evidence)
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        if category.contains("movement.privatevehicle") || contains(text, ["privatevehicle", "자가용"]) {
            return .car
        }
        if category.contains("movement.bus") || contains(text, ["버스", "bus"]) {
            return .bus
        }
        if category.contains("movement.ship") || contains(text, ["선박", "ship"]) || containsToken(text, "배") {
            return .ship
        }
        if category.contains("movement.airplane") || contains(text, ["항공", "비행기", "airplane"]) {
            return .airplane
        }
        if categoryRoot == "sleep" || contains(text, ["수면", "잠", "sleep"]) {
            return .sleeping
        }
        if categoryRoot == "eating"
            || categoryRoot == "food"
            || contains(text, ["식사", "밥", "meal", "eating"]) {
            return .eating
        }
        if categoryRoot == "work"
            || contains(text, ["회사", "근무", "업무", "컴퓨터", "work"]) {
            return .computer
        }
        if categoryRoot == "study"
            || contains(text, ["학교", "수업", "학습", "독서", "study"]) {
            return .reading
        }
        if contains(text, ["지하철", "subway", "metro"]) {
            return .subway
        }
        if contains(text, ["자동차", "차량", "운전", "car", "driving"]) {
            return .car
        }
        if contains(text, ["자전거", "cycling", "bike"]) {
            return .cycling
        }
        if contains(text, ["달리기", "running"]) {
            return .running
        }
        if contains(text, ["걷", "walking", "walk"]) {
            return .walking
        }
        return nil
    }

    private static func action(
        for place: PlaceStay,
        frequentPlaces: [FrequentPlace]
    ) -> MapHomeStickmanAction? {
        if let frequent = frequentPlaces.first(where: {
            $0.stablePlaceKey == place.placeKey
        }) {
            return action(for: frequent.kind)
        }

        let text = [place.displayName, place.buildingName]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        if contains(text, ["회사"]) { return .company }
        if contains(text, ["학교", "school"]) { return .school }
        if contains(text, ["근무", "work"]) { return .computer }
        if contains(text, ["학원", "academy"]) { return .reading }
        if contains(text, ["식당", "restaurant", "meal"]) { return .eating }
        if contains(text, ["취미", "hobby"]) { return .hobby }
        return .activity
    }

    private static func higherPriority(
        _ lhs: (ActualRecord, MapHomeStickmanAction),
        _ rhs: (ActualRecord, MapHomeStickmanAction)
    ) -> Bool {
        let leftRank = priority(of: lhs.0)
        let rightRank = priority(of: rhs.0)
        if leftRank != rightRank { return leftRank > rightRank }
        if lhs.0.startedAt != rhs.0.startedAt {
            return lhs.0.startedAt > rhs.0.startedAt
        }
        return lhs.0.id.uuidString > rhs.0.id.uuidString
    }

    private static func priority(of actual: ActualRecord) -> Int {
        let category = actual.categoryID.lowercased()
        let text = ([actual.title, actual.behavior] + actual.evidence)
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        let semanticRank: Int
        if category == "sleep" || contains(text, ["수면", "잠", "sleep"]) {
            semanticRank = 80
        } else if category == "eating" || category == "food"
                    || contains(text, ["식사", "밥", "meal", "eating"]) {
            semanticRank = 70
        } else if category == "work"
                    || contains(text, ["회사", "근무", "업무", "work"]) {
            semanticRank = 60
        } else if category == "study"
                    || contains(text, ["학교", "수업", "학습", "독서", "study"]) {
            semanticRank = 50
        } else {
            semanticRank = 10
        }
        return semanticRank + (actual.manuallyCorrected ? 1_000 : 0)
    }

    private static func contains(_ text: String, _ terms: [String]) -> Bool {
        terms.contains { text.contains($0) }
    }

    private static func containsToken(_ text: String, _ token: String) -> Bool {
        text.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .contains(token)
    }
}
