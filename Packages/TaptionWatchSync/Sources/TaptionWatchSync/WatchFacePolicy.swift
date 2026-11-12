import Foundation
import os

/// 시계 페이스·스마트 스택·Watch 앱이 같이 쓰는 표시 판정. 값 계산만 해서 시험할 수 있게 둔다.
public enum TaptionWatchFacePolicy {
    public struct RGB: Hashable, Sendable {
        public var red: Double
        public var green: Double
        public var blue: Double
    }

    /// 24시간을 1로 본 하루 고리의 한 조각.
    public struct DaySegment: Hashable, Sendable {
        public var categoryID: String
        public var hex: String?
        public var start: Double
        public var end: Double
    }

    // MARK: - 고양이·색

    public static func majorCategoryID(_ categoryID: String) -> String {
        categoryID.split(separator: ".").first.map(String.init) ?? categoryID
    }

    public static func catAssetName(style: String, categoryID: String, poseName: String? = nil) -> String {
        let coat = switch style {
        case "calico": "calico"
        case "mackerel": "mackerel"
        default: "white"
        }
        return "WatchCat-\(coat)-\(poseName ?? catAction(categoryID: categoryID))"
    }

    public static func catAction(categoryID: String) -> String {
        switch majorCategoryID(categoryID) {
        case "sleep": "Sleep"
        case "eating": "Eat"
        case "exercise": "Run"
        case "movement": "Walk"
        case "hobby": "Hobby"
        case "work": "Work"
        case "study": "Study"
        case "unconfirmed": "Check"
        default: "Rest"
        }
    }

    /// 스마트 스택과 Watch 앱 「지금」 쪽의 바탕색. 흰 글자가 읽히는 어두운 색이다.
    public static func background(categoryID: String) -> RGB {
        switch majorCategoryID(categoryID) {
        case "work": RGB(red: 0.11, green: 0.23, blue: 0.43)
        case "study": RGB(red: 0.25, green: 0.17, blue: 0.43)
        case "eating": RGB(red: 0.48, green: 0.24, blue: 0.07)
        case "sleep": RGB(red: 0.15, green: 0.15, blue: 0.37)
        case "movement": RGB(red: 0.48, green: 0.29, blue: 0.07)
        case "exercise": RGB(red: 0.08, green: 0.33, blue: 0.18)
        case "rest": RGB(red: 0.18, green: 0.29, blue: 0.23)
        case "hobby": RGB(red: 0.42, green: 0.15, blue: 0.27)
        default: RGB(red: 0.17, green: 0.17, blue: 0.17)
        }
    }

    public static func rgb(hex: String?) -> RGB? {
        guard let hex, let value = UInt32(hex.replacingOccurrences(of: "#", with: ""), radix: 16) else { return nil }
        return RGB(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    // MARK: - 일정

    /// 진행 중인 일정 다음에 남은 일정. 목표 묶음은 뺀다.
    public static func agenda(
        _ items: [TaptionWatchPlanItem],
        at now: Date,
        limit: Int = 6
    ) -> [TaptionWatchPlanItem] {
        let plans = items.filter { !$0.isGoal }
        return Array(
            (TaptionWatchLiveItemPolicy.current(plans, at: now)
                + TaptionWatchLiveItemPolicy.upcoming(plans, at: now))
                .prefix(limit)
        )
    }

    /// 다음 일정이 다가온 정도(0~1). `window` 전부터 차기 시작해 시작 시각에 1이 된다.
    public static func approachFraction(
        startsAt: Date,
        now: Date,
        window: TimeInterval = 3_600
    ) -> Double {
        guard window > 0 else { return 0 }
        return min(1, max(0, 1 - startsAt.timeIntervalSince(now) / window))
    }

    // MARK: - 하루

    /// 긴 분류부터 이어 붙인 하루 고리. 시간 순서가 아니라 분류별 합이다.
    public static func daySegments(
        _ summary: TaptionWatchDaySummary,
        limit: Int = 5
    ) -> [DaySegment] {
        var cursor = 0.0
        return summary.topCategories(limit: limit).compactMap { category in
            let start = cursor
            cursor = min(1, cursor + Double(category.minutes) / 1_440)
            guard cursor > start else { return nil }
            return DaySegment(categoryID: category.categoryID, hex: category.hex, start: start, end: cursor)
        }
    }

    public static func durationText(
        _ minutes: Int,
        language: AppLanguagePreference.ResolvedLanguage
    ) -> String {
        let hours = max(0, minutes) / 60
        let remainder = max(0, minutes) % 60
        if hours == 0 { return language.text("\(remainder)분", "\(remainder) min") }
        if remainder == 0 { return language.text("\(hours)시간", "\(hours) hr") }
        return language.text("\(hours)시간 \(remainder)분", "\(hours) hr \(remainder) min")
    }

    // MARK: - 타임라인

    /// 위젯이 다시 그려야 하는 시각. 경과 시간·남은 시간 글자는 시스템이 스스로 갱신하므로
    /// 15분 격자면 고리 비율이 어긋나지 않는다. 일정 시작·확인 요청 만료·자정은 경계로 넣는다.
    public static func timelineDates(
        now: Date,
        payload: TaptionWatchPayload?,
        step: TimeInterval = 15 * 60,
        horizon: TimeInterval = 3_600,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [Date] {
        let end = now.addingTimeInterval(horizon)
        var dates = Set(stride(from: now, through: end, by: step))
        let items = payload?.items ?? []
        for item in items where TaptionWatchLiveItemPolicy.isLive(item, at: now) {
            dates.insert(item.startsAt)
            dates.insert(item.endsAt)
        }
        if let suggestion = payload?.activitySuggestion {
            dates.insert(suggestion.endedAt.addingTimeInterval(suggestionLifetime))
        }
        if let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) {
            dates.insert(midnight)
        }
        return dates.filter { now <= $0 && $0 <= end }.sorted()
    }

    public static let suggestionLifetime: TimeInterval = 2 * 3_600

    public static func activeSuggestion(
        _ payload: TaptionWatchPayload?,
        at now: Date
    ) -> TaptionWatchActivitySuggestion? {
        guard let value = payload?.activitySuggestion,
              now.timeIntervalSince(value.endedAt) <= suggestionLifetime else { return nil }
        return value
    }

    /// 스마트 스택에서 이 위젯을 얼마나 앞에 둘지. 확인할 것 > 수집 문제 > 곧 시작할 일정 순서다.
    public static func relevanceScore(
        payload: TaptionWatchPayload?,
        hasAlert: Bool,
        at now: Date
    ) -> Float {
        if activeSuggestion(payload, at: now) != nil { return 90 }
        if hasAlert { return 80 }
        let next = agenda(payload?.items ?? [], at: now).first { $0.startsAt > now }
        if let next {
            let remaining = next.startsAt.timeIntervalSince(now)
            if remaining <= 15 * 60 { return 70 }
            if remaining <= 3_600 { return 40 }
        }
        return payload?.currentActivity == nil ? 0 : 10
    }
}

/// 같은 바이트는 한 번만 푼다. 위젯은 타임라인 항목마다 저장값을 다시 읽으므로
/// 바뀌지 않은 값을 매번 JSON으로 풀지 않게 한다.
public final class TaptionWatchDecodeCache<Value: Decodable & Sendable>: Sendable {
    private struct State: Sendable {
        var data: Data?
        var value: Value?
        var decodeCount = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public var decodeCount: Int { state.withLock { $0.decodeCount } }

    public func value(for data: Data) -> Value? {
        state.withLock { state in
            if state.data == data { return state.value }
            state.decodeCount += 1
            state.value = try? JSONDecoder().decode(Value.self, from: data)
            state.data = data
            return state.value
        }
    }

    public func reset() {
        state.withLock { $0 = State(decodeCount: $0.decodeCount) }
    }
}
