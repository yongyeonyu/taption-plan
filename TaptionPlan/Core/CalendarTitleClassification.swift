import Foundation

/// 일정 제목 → 상세활동(CAL1103A01). 사용자가 고른 값 > 단어 규칙 순서다.
enum CalendarTitleClassification {
    enum Origin: Equatable, Sendable { case user, rule }

    struct Verdict: Equatable, Sendable {
        var detailID: String?
        var origin: Origin
    }

    struct Resolved: Sendable {
        var detail: RecordClassificationDetail
        var categoryID: String
        var evidence: String
    }

    private static let evidencePrefix = "일정 제목 "

    static func key(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 일정으로 고를 수 있는 상세활동. 이동·수면·미확인과 경로·휴식·걷기는 일정 제목으로 정하지 않는다.
    static var selectableCategories: [RecordClassificationCategory] {
        RecordClassificationCatalog.categories.compactMap { category in
            guard !["movement", "sleep", "unconfirmed"].contains(category.id) else { return nil }
            var value = category
            value.details = category.details.filter { detail in
                detail.automaticOnly != true && !["stationary", "walking"].contains(detail.behavior) && !detail.id.hasSuffix(".route")
            }
            return value.details.isEmpty ? nil : value
        }
    }

    static var selectableDetailIDs: [String] { selectableCategories.flatMap { $0.details.map(\.id) } }

    private static let rules: [(detailID: String, korean: [String], english: Set<String>)] = [
        ("work.meeting", ["회의", "미팅", "면담", "스탠드업"], ["meeting", "standup", "sync", "1:1"]),
        ("health.hospital", ["병원", "진료", "치과", "검진", "한의원", "피부과", "내과"], ["hospital", "clinic", "dentist"]),
        ("health.salon", ["미용실", "헤어", "커트", "네일"], ["salon", "haircut"]),
        ("study.academy", ["학원"], ["academy"]),
        ("study.class", ["수업", "강의", "세미나"], ["class", "lecture", "seminar"]),
        ("eating.meal", ["점심", "저녁", "아침", "식사", "회식", "브런치"], ["lunch", "dinner", "breakfast", "brunch"]),
        ("housework.groceries", ["장보기", "마트"], ["groceries"]),
        ("housework.laundry", ["빨래"], ["laundry"]),
        ("housework.cooking", ["요리"], ["cooking"]),
        ("housework.chores", ["청소", "집안일"], ["chores"]),
        ("health.meditation", ["명상"], ["meditation"]),
        ("hobby.reading", ["독서"], ["reading"]),
        ("activity.date", ["데이트"], ["date"]),
        ("activity.family", ["가족", "부모님", "엄마", "아빠"], ["family"]),
        ("activity.friends", ["친구", "모임"], ["friends"]),
        ("activity.phoneCall", ["통화", "전화"], ["call"])
    ]

    static func ruleDetailID(for title: String) -> String? {
        let text = key(title)
        let tokens = Set(text.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "-" }).map(String.init))
        return rules.first { rule in
            rule.korean.contains(where: text.contains) || !rule.english.isDisjoint(with: tokens)
        }?.detailID
    }

    static func verdict(for title: String, stored: [String: CalendarTitleDetail]) -> Verdict? {
        if let value = stored[key(title)] { return Verdict(detailID: value.detailID, origin: .user) }
        return ruleDetailID(for: title).map { Verdict(detailID: $0, origin: .rule) }
    }

    /// 사용자가 "분류 안 함"으로 정한 일정은 회의 판정의 근거로도 쓰지 않는다.
    static func counted(_ events: [CalendarRecord], stored: [String: CalendarTitleDetail]) -> [CalendarRecord] {
        guard !stored.isEmpty else { return events }
        return events.filter {
            stored[key($0.title)].map { $0.detailID != nil } ?? true
        }
    }

    /// 그 장소에서 믿어도 되는 상세활동. 자동 판정은 등록 장소의 성격과 어긋나면 쓰지 않고
    /// 사용자가 고른 값만 장소보다 앞선다. 집에서 "병원" 일정이면 실제로 가지 않은 것이다.
    static func detail(
        for title: String,
        stored: [String: CalendarTitleDetail],
        at place: FrequentPlaceKind?
    ) -> Resolved? {
        guard let verdict = verdict(for: title, stored: stored), let id = verdict.detailID,
              let categoryID = id.split(separator: ".").first.map(String.init),
              let detail = RecordClassificationCatalog.categories.first(where: { $0.id == categoryID })?
                .details.first(where: { $0.id == id }),
              verdict.origin == .user || fits(id, categoryID: categoryID, at: place) else { return nil }
        let origin = switch verdict.origin {
        case .user: "직접 정함"
        case .rule: "단어 규칙"
        }
        return Resolved(detail: detail, categoryID: categoryID, evidence: "\(evidencePrefix)'\(title)' · \(origin)")
    }

    private static let awayFromHomeDetails: Set<String> = [
        "health.hospital", "health.salon", "study.academy", "housework.groceries", "activity.friends", "activity.date"
    ]

    private static func fits(_ id: String, categoryID: String, at place: FrequentPlaceKind?) -> Bool {
        switch place {
        case nil, .custom: true
        case .home: !awayFromHomeDetails.contains(id)
        case .company: categoryID == "work"
        case .school, .academy: categoryID == "study"
        case .exercise: false
        case .restaurant: categoryID == "eating"
        case .hobby: categoryID == "hobby"
        }
    }

    /// 일정이 생기거나 지워지거나 제목 분류를 고치면 잠긴 자동 분류도 따라간다. 사용자가 고친 기록은 그대로다.
    static func freshWins(previous: ActualRecord, candidate: ActualRecord) -> Bool {
        previous.source == .location && candidate.source == .location
            && !previous.manuallyCorrected && !ActualRecord.userOwned(previous)
            && (isCalendarDerived(previous) || isCalendarDerived(candidate))
    }

    static func isCalendarDerived(_ actual: ActualRecord) -> Bool {
        actual.evidence.contains { $0.hasPrefix(evidencePrefix) || $0.hasPrefix("캘린더 일정 ") }
    }
}
