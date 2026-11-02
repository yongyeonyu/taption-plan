import Foundation
import SwiftUI

enum MapHomeLocationDestination: String, CaseIterable, Identifiable {
    case home
    case company
    case school
    case academy
    case exercise
    case hobby
    case restaurant
    case user

    var id: String { rawValue }

    /// 앱 그림체로 그린 위치 아이콘(`tools/generate_place_icons.py`).
    var iconAssetName: String { "PlaceIcon_\(rawValue)" }

    var placeKind: FrequentPlaceKind? {
        switch self {
        case .home: .home
        case .company: .company
        case .school: .school
        case .academy: .academy
        case .exercise: .exercise
        case .hobby: .hobby
        case .restaurant: .restaurant
        case .user: nil
        }
    }

    init?(placeKind: FrequentPlaceKind) {
        switch placeKind {
        case .home: self = .home
        case .company: self = .company
        case .school: self = .school
        case .academy: self = .academy
        case .exercise: self = .exercise
        case .hobby: self = .hobby
        case .restaurant: self = .restaurant
        case .custom: self = .user
        }
    }

    var koreanName: String {
        switch self {
        case .home: "집"
        case .company: "회사"
        case .school: "학교"
        case .academy: "학원"
        case .exercise: "운동"
        case .hobby: "취미"
        case .restaurant: "식당"
        case .user: "사용자"
        }
    }

    var englishName: String {
        switch self {
        case .home: "Home"
        case .company: "Work"
        case .school: "School"
        case .academy: "Academy"
        case .exercise: "Exercise"
        case .hobby: "Hobby"
        case .restaurant: "Restaurant"
        case .user: "User"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house.fill"
        case .company: "building.2.fill"
        case .school: "graduationcap.fill"
        case .academy: "book.closed.fill"
        case .exercise: "figure.run"
        case .hobby: "paintpalette.fill"
        case .restaurant: "storefront.fill"
        case .user: "mappin.and.ellipse"
        }
    }

    /// RPG 탐험 테마의 랜드마크 아이콘. 집=오두막, 회사=길드 성,
    /// 학교=지식의 탑, 학원=마법 연구소, 운동=훈련장, 취미=공연장,
    /// 식당=주점. 지도 배지에서 판타지 느낌을 준다.
    var rpgSystemImage: String {
        switch self {
        case .home: "tent.fill"
        case .company: "building.columns.fill"
        case .school: "books.vertical.fill"
        case .academy: "wand.and.stars"
        case .exercise: "figure.strengthtraining.traditional"
        case .hobby: "theatermasks.fill"
        case .restaurant: "fork.knife"
        case .user: "flag.fill"
        }
    }

    var tint: Color {
        // Low-chroma terrain colors keep every registered landmark in the
        // same parchment-map palette while preserving category distinction.
        switch self {
        case .home: Color(hex: "#976744")
        case .company: Color(hex: "#65745E")
        case .school: Color(hex: "#7B6C55")
        case .academy: Color(hex: "#796D82")
        case .exercise: Color(hex: "#A75F4A")
        case .hobby: Color(hex: "#987F4D")
        case .restaurant: Color(hex: "#A56347")
        case .user: Color(hex: "#756E5B")
        }
    }
}

struct MapHomeLocationThumbnail: View {
    let destination: MapHomeLocationDestination
    var size: CGFloat = 42

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(destination.tint.opacity(0.14))
            Image(destination.iconAssetName)
                .resizable()
                .scaledToFit()
                .padding(size * 0.1)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

enum MapHomeStickmanAction: String, CaseIterable, Hashable, Sendable {
    case activity
    case computer
    case company
    case school
    case reading
    case hobby
    case sleeping
    case movement
    case eating
    case exercise
    case unconfirmed
    case walking
    case running
    case car
    case subway
    case train
    case privateVehicle
    case bus
    case ship
    case airplane
    case cycling
    case health
    case shower
    case housework

    var isMoving: Bool {
        switch self {
        case .movement, .walking, .running, .car, .subway, .train,
             .privateVehicle, .bus, .ship, .airplane, .cycling:
            true
        default:
            false
        }
    }

    /// 대표 지시: 행동 분류마다 화랑이 장면이 전부 달라야 한다.
    var hwarangScene: HwarangScene {
        switch self {
        case .running: .runLoop
        case .cycling: .bicycle
        case .train: .train
        case .movement, .walking: .stroll
        case .car, .privateVehicle: .carFront
        case .subway: .subway
        case .bus: .bus
        case .ship: .boat
        case .airplane: .airplane
        case .shower: .shower
        case .housework: .robotVacuum
        case .sleeping: .sleep
        case .eating: .eat
        case .computer, .company: .work
        case .reading, .school: .study
        case .hobby: .yarn
        case .exercise: .wheel
        case .health: .stretch
        case .activity: .groom
        case .unconfirmed: .confused
        }
    }

    /// 설정 키: 재생 때 탈것을 탄 화랑이를 보여 줄지.
    static let vehicleDisplayKey = "mapHome.showsVehicleRides"
    static let runningSpeedMetersPerSecond = 2.2

    /// 지도 마커 장면. 탈것 표시가 꺼져 있으면 속도에 따라 걷거나 뛰기만 한다.
    func markerScene(speedMetersPerSecond: Double?, showsVehicles: Bool) -> HwarangScene {
        guard isMoving else { return hwarangScene }
        if self == .running { return .runLoop }
        if showsVehicles, hwarangScene.isVehicleScene { return hwarangScene }
        return (speedMetersPerSecond ?? 0) >= Self.runningSpeedMetersPerSecond ? .runLoop : .walkLoop
    }

    var animatesPresentation: Bool {
        switch self {
        case .computer, .company, .school, .reading, .hobby, .sleeping, .eating,
             .activity, .exercise, .health, .unconfirmed, .shower, .housework:
            true
        default:
            isMoving
        }
    }

    var title: String {
        func t(_ korean: String, _ english: String) -> String {
            AppLanguagePreference.text(korean: korean, english: english)
        }
        switch self {
        case .activity: return t("활동", "Activity")
        case .train: return t("기차", "Train")
        case .shower: return t("샤워", "Shower")
        case .housework: return t("집안일", "Housework")
        case .computer: return t("업무", "Work")
        case .company: return t("회사 업무", "Office work")
        case .school: return t("학교 학습", "School")
        case .reading: return t("수업", "Class")
        case .hobby: return t("취미", "Hobby")
        case .sleeping: return t("수면", "Sleep")
        case .movement: return t("이동", "Movement")
        case .eating: return t("식사", "Meal")
        case .exercise: return t("운동", "Exercise")
        case .unconfirmed: return t("미확인", "Unconfirmed")
        case .walking: return t("걷기", "Walking")
        case .running: return t("달리기", "Running")
        case .car: return t("자동차", "Car")
        case .subway: return t("지하철 탑승", "Subway ride")
        case .privateVehicle: return t("자가용", "Private car")
        case .bus: return t("버스 탑승", "Bus ride")
        case .ship: return t("배", "Ship")
        case .airplane: return t("비행기", "Airplane")
        case .cycling: return t("자전거", "Cycling")
        case .health: return t("건강", "Health")
        }
    }
}

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
        let actuals = actuals.filter { active($0, at: date) }
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
            return .sleeping
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

        if let candidate = activeActuals.max(by: higherPriority) {
            return candidate.1
        }

        let activePlaces = places
            .filter { $0.span.contains(date) }
            .sorted { $0.span.start > $1.span.start }
        for place in activePlaces {
            if let action = action(for: place, frequentPlaces: frequentPlaces) {
                return action
            }
        }
        return .activity
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
        let category = categoryID.lowercased()
        let categoryRoot = category.split(separator: ".", maxSplits: 1).first.map(String.init) ?? category
        let value = "\(category) \(label)".lowercased()
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
        let detailMappings: [(String, MapHomeStickmanAction)] = [
            ("movement.walking", .walking),
            ("movement.running", .running),
            ("movement.car", .car),
            ("movement.subway", .subway),
            ("movement.privatevehicle", .car),
            ("movement.bus", .bus),
            ("movement.ship", .ship),
            ("movement.airplane", .airplane),
            ("movement.cycling", .cycling)
        ]
        if let mapping = detailMappings.first(where: { value.contains($0.0) }) {
            return mapping.1
        }
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

    private static func action(for actual: ActualRecord) -> MapHomeStickmanAction? {
        let category = actual.categoryID.lowercased()
        let categoryRoot = category.split(separator: ".", maxSplits: 1).first.map(String.init) ?? category
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
            switch frequent.kind {
            case .company: return .company
            case .school: return .school
            case .academy: return .reading
            case .restaurant: return .eating
            case .home, .custom: return .activity
            case .hobby: return .hobby
            case .exercise: return .exercise
            }
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

enum MapHomeStickmanAnimationEngine {
    static let frameDuration = TaptionLiveActivityStickmanAnimation.frameDuration
    static let phaseCount = TaptionLiveActivityStickmanAnimation.frameCount

    static func phase(at date: Date, reducesMotion: Bool = false) -> Int {
        TaptionLiveActivityStickmanAnimation.frameIndex(
            at: date.timeIntervalSinceReferenceDate,
            isAnimating: !reducesMotion
        )
    }

    static func phase(for progress: Double) -> Int {
        guard progress.isFinite else { return 0 }
        let normalized = min(max(progress, 0), 1)
        return min(
            phaseCount - 1,
            Int((normalized * Double(phaseCount)).rounded(.down))
        )
    }

    static func oscillation(for phase: Int) -> Double {
        sin(2 * .pi * Double(phase) / Double(phaseCount))
    }

    static func secondaryOscillation(for phase: Int) -> Double {
        sin(4 * .pi * Double(phase) / Double(phaseCount))
    }

    static func pulse(for phase: Int) -> Double {
        (oscillation(for: phase) + 1) / 2
    }
}

/// 화면에서 화랑이가 왼쪽·오른쪽 어디로 가는지 정한다. 거의 위아래로 가면 이전 방향을 유지해 좌우로 튀지 않게 한다.
@MainActor
enum MapHomeStickmanFacing {
    private static var last = false

    static func facesLeft(headingDegrees: Double, cameraHeading: Double) -> Bool {
        last = resolve(headingDegrees: headingDegrees, cameraHeading: cameraHeading, previous: last)
        return last
    }

    nonisolated static func resolve(headingDegrees: Double, cameraHeading: Double, previous: Bool) -> Bool {
        guard headingDegrees.isFinite, cameraHeading.isFinite else { return previous }
        let horizontal = sin((headingDegrees - cameraHeading) * .pi / 180)
        return abs(horizontal) < 0.26 ? previous : horizontal < 0
    }
}

enum MapHomeStickmanRoutePhase {
    case actual
    case forecast

    var color: Color {
        Color(
            hex: self == .actual
                ? MapHomeWBSTripStyle.actualRouteHex
                : MapHomeWBSTripStyle.forecastRouteHex
        )
    }
}

/// 이동 속도를 30km/h 구간으로 나눠 고양이 동작·표정·이펙트를 바꾼다.
/// 동작만 보고 속도를 가늠할 수 있게, 구간이 오를수록 걷기→뛰기→질주→
/// (피카츄처럼) 번개 질주로 변한다.
enum MapHomeSpeedTier: Int, CaseIterable, Sendable {
    case idle       // 정지/미세 이동
    case strolling  // 0-10km/h 우아하게 걷기
    case walking    // 10-30
    case jogging    // 30-60 걷기→뛰기 전환
    case running    // 60-90 매우 빠르게
    case flying     // 90-120 거의 날아가듯
    case pikachu    // 120+ 번개 질주

    static func tier(forMetersPerSecond mps: Double?) -> MapHomeSpeedTier {
        guard let mps, mps > 0 else { return .idle }
        let kmh = mps * 3.6
        switch kmh {
        case ..<0.8: return .idle
        case ..<10: return .strolling
        case ..<30: return .walking
        case ..<60: return .jogging
        case ..<90: return .running
        case ..<120: return .flying
        default: return .pikachu
        }
    }

    /// 이 구간에서 쓸 화랑이 장면. 지도에서 움직이는 동안은 멈추지 않는 걷기·달리기만 쓴다.
    var scene: HwarangScene {
        switch self {
        case .idle, .strolling, .walking: .walkLoop
        case .jogging, .running, .flying, .pikachu: .runLoop
        }
    }

    /// 동작 재생 배속. 빠를수록 다리가 더 빨리 움직인다.
    var frameRateMultiplier: Double {
        switch self {
        case .idle: return 1
        case .strolling: return 0.8
        case .walking: return 1.1
        case .jogging: return 1.6
        case .running: return 2.2
        case .flying: return 3.0
        case .pikachu: return 4.0
        }
    }

    /// 진행 방향으로 기울이는 각도(질주감).
    var leanDegrees: Double {
        switch self {
        case .idle, .strolling, .walking: return 0
        case .jogging: return 6
        case .running: return 12
        case .flying: return 20
        case .pikachu: return 26
        }
    }

    /// 뒤로 끌리는 스피드 라인 개수(0=없음).
    var speedLines: Int {
        switch self {
        case .idle, .strolling, .walking: return 0
        case .jogging: return 2
        case .running: return 3
        case .flying: return 4
        case .pikachu: return 5
        }
    }

    var isPikachu: Bool { self == .pikachu }
}

struct MapHomeStickmanMarker: View {
    static let size = CGSize(width: 36, height: 36)

    let action: MapHomeStickmanAction
    var animationPhase: Int? = nil
    var routePhase: MapHomeStickmanRoutePhase = .actual
    var speedMetersPerSecond: Double? = nil
    var equippedAccessoryID: String? = nil
    var facesLeft = false
    @AppStorage(MapHomeStickmanAction.vehicleDisplayKey) private var showsVehicles = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        let isStatic = reduceMotion || isLuminanceReduced || !action.animatesPresentation
        let scene = action.markerScene(speedMetersPerSecond: speedMetersPerSecond, showsVehicles: showsVehicles)
        let tier = action.isMoving && !scene.isVehicleScene
            ? MapHomeSpeedTier.tier(forMetersPerSecond: speedMetersPerSecond)
            : .idle
        let hat = MapHomeGrowthAccessoryCatalog.hatAssetName(for: equippedAccessoryID)
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 30,
                paused: isStatic || animationPhase != nil
            )
        ) { context in
            let clock = animationPhase.map { Double($0) * MapHomeStickmanAnimationEngine.frameDuration }
                ?? HwarangClock.seconds(at: context.date)
            let sec = isStatic ? 0 : clock * (action.isMoving ? tier.frameRateMultiplier : 1)
            ZStack {
                // 스피드 라인 — 빠를수록 뒤로 더 많이 끌린다.
                if tier.speedLines > 0 {
                    HStack(spacing: 1.5) {
                        ForEach(0..<tier.speedLines, id: \.self) { i in
                            Capsule()
                                .fill(
                                    (tier.isPikachu ? Color.yellow : Color.tpAccent)
                                        .opacity(0.55 - Double(i) * 0.08)
                                )
                                .frame(width: 6 + CGFloat(i) * 2, height: 1.6)
                        }
                    }
                    .offset(x: Self.size.width * (facesLeft ? 0.9 : -0.9))
                }
                HwarangSceneView(
                    scene: scene,
                    sec: sec,
                    width: Self.size.width * 1.6,
                    anchorHeight: Self.size.height,
                    facesLeft: facesLeft && action.isMoving,
                    hatAssetName: hat,
                    showsBackdrop: false
                )
                .rotationEffect(.degrees(facesLeft ? -tier.leanDegrees * 0.5 : tier.leanDegrees * 0.5))
                // 피카츄 구간 — 번개 스파크.
                if tier.isPikachu {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .black))
                        .foregroundStyle(.yellow)
                        .shadow(color: .orange.opacity(0.8), radius: 2)
                        .offset(x: Self.size.width * 0.28, y: -Self.size.height * 0.26)
                }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .shadow(color: .black.opacity(0.14), radius: 3, y: 1)
        .accessibilityHidden(true)
    }
}

struct MapHomeStickmanGlyph: View {
    let action: MapHomeStickmanAction
    var size: CGFloat = 30
    var equippedAccessoryID: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        let isStatic = reduceMotion || isLuminanceReduced || !action.animatesPresentation
        let hat = MapHomeGrowthAccessoryCatalog.hatAssetName(for: equippedAccessoryID)
        // 같은 화면의 화랑이들이 동시에 같은 자세로 겹치지 않게 분류별로 시작을 어긋낸다.
        let offset = Double(MapHomeStickmanAction.allCases.firstIndex(of: action) ?? 0) * 3.7
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: isStatic)) { context in
            HwarangSceneView(
                scene: action.hwarangScene,
                sec: isStatic ? 0 : HwarangClock.seconds(at: context.date) + offset,
                width: size * 1.6,
                anchorHeight: size,
                hatAssetName: hat,
                showsBackdrop: size >= 36,
                keepsBodySize: false
            )
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// 메뉴 머리글의 화랑이: 지도를 펼쳐 든 모습과 발자국.
struct MapHomeMenuHeaderCat: View {
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion)) { context in
            HwarangSceneView(
                scene: .atlas,
                sec: reduceMotion ? 0 : HwarangClock.seconds(at: context.date),
                width: size * 1.3,
                anchorHeight: size,
                showsBackdrop: false
            )
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

enum HwarangClock {
    /// 소수 정밀도를 지키려고 큰 주기로 나머지를 쓴다.
    static func seconds(at date: Date) -> Double {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 86_400)
    }
}
