import Foundation
import TaptionPlanCore

/// AI 비서가 읽는 하루 기록(AIR1110A01·TRP1110A07). 좌표·경로·주소·센서 원본은 담지 않는다.
struct AssistantActivityDay: Codable, Equatable, Sendable {
    struct Summary: Codable, Equatable, Sendable {
        var categories: [Category]
        var recordedMinutes: Int
        var steps: Int?
        var plansScheduled: Int
        var plansCompleted: Int
    }

    struct Category: Codable, Equatable, Sendable {
        var id: String
        var title: String
        var minutes: Int
    }

    struct Record: Codable, Equatable, Sendable {
        struct Kind: Codable, Equatable, Sendable {
            var id: String
            var title: String
        }

        var id: String
        var start: String
        var end: String
        var title: String
        var category: Kind
        var source: String
    }

    struct Memo: Codable, Equatable, Sendable {
        var id: String
        var time: String?
        var text: String
    }

    /// 그날 일정. `id`로 `updateSchedule`·`deleteSchedule`을 고른다(AIR1110A02).
    struct Plan: Codable, Equatable, Sendable {
        var id: String
        var title: String
        var start: String
        var end: String
    }

    struct Visit: Codable, Equatable, Sendable {
        var place: String
        var start: String
        var end: String
        var minutes: Int
    }

    struct Move: Codable, Equatable, Sendable {
        var from: String?
        var to: String?
        var mode: String
        var start: String
        var end: String
        var minutes: Int
        /// 이동 구간 id(ACT1111A01). `setTravelMode`가 이것으로 고른다. 예전 기록에는 없다.
        var id: String?

        private enum CodingKeys: String, CodingKey { case from, to, mode, start, end, minutes, id }

        /// 출발·도착을 모르면 칸을 빼지 않고 null로 둔다.
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(from, forKey: .from)
            try values.encode(to, forKey: .to)
            try values.encode(mode, forKey: .mode)
            try values.encode(start, forKey: .start)
            try values.encode(end, forKey: .end)
            try values.encode(minutes, forKey: .minutes)
            try values.encodeIfPresent(id, forKey: .id)
        }
    }

    var date: String
    var timeZone: String
    var updatedAt: String?
    var summary: Summary
    var records: [Record]
    var memos: [Memo]
    var plans: [Plan] = []
    var visits: [Visit]?
    var moves: [Move]?
    /// 루틴·여행 일정·수면(AIR1110A03). 비면 칸째 빼서 예전 날의 해시가 그대로다.
    var goals: [Goal]?
    var trips: [Trip]?
    var sleep: [Sleep]?
    var expenses: [Expense]?
    /// 비면 칸째 뺀다(예전 날의 해시가 그대로).
    var budget: Budget?
    var unconfirmed: [Unconfirmed]?
}

/// 하루 기록을 만드는 데 필요한 값. 앱 상태에서 모으고, 시험은 직접 만든다.
struct AssistantActivityInput: Sendable {
    var day: Date
    var calendar: Calendar
    var language: MapHomeLanguage
    var categories: [AssistantActivityDay.Category]
    var steps: Int?
    var plansScheduled: Int
    var plansCompleted: Int
    var actuals: [ActualRecord]
    var categoryTitles: [String: String]
    var memos: [ActionMemo]
    var stays: [PlaceStay]
    var travel: [TravelSegment]
    /// 등록 장소의 안정 키 → 사용자가 붙인 이름.
    var registeredNames: [String: String]
    var now: Date
    var plans: [PlanRecord] = []
    var goals: [PlanRecord] = []
    var tripStops: [TravelPlanStop] = []
    var tripItems: [TravelTripItem] = []
    var ledger: [LedgerEntry] = []
    var budget: AssistantActivityDay.Budget?
}

enum AssistantActivityBuilder {
    static let recordLimit = 200
    static let memoLimit = 50
    static let placeLimit = 150
    static let planLimit = 100
    static let minimumVisit: TimeInterval = 5 * 60
    /// 이동 앞뒤의 머문 곳을 찾는 거리(시간).
    static let neighbourGap: TimeInterval = 15 * 60

    static func make(_ input: AssistantActivityInput, level: AssistantShareLevel) -> AssistantActivityDay? {
        guard level != .off else { return nil }
        let calendar = input.calendar
        let start = calendar.startOfDay(for: input.day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let day = TimeSpan(start: start, end: end)
        let stamp = Stamp(calendar: calendar)
        var result = AssistantActivityDay(
            date: stamp.date(start),
            timeZone: calendar.timeZone.identifier,
            summary: AssistantActivityDay.Summary(
                categories: input.categories,
                recordedMinutes: input.categories.reduce(0) { $0 + $1.minutes },
                steps: input.steps.flatMap { $0 > 0 ? $0 : nil },
                plansScheduled: input.plansScheduled,
                plansCompleted: input.plansCompleted
            ),
            records: records(input, day: day, stamp: stamp),
            memos: memos(input.memos, day: day, stamp: stamp),
            plans: plans(input.plans, day: day, stamp: stamp)
        )
        addExtras(to: &result, input, day: day, stamp: stamp)
        if level == .visits {
            let stays = visitStays(input.stays, travel: input.travel, day: day)
            result.visits = stays.prefix(placeLimit).map { stay in
                let span = stay.span.intersection(with: day) ?? stay.span
                return AssistantActivityDay.Visit(
                    place: placeName(stay, registered: input.registeredNames, language: input.language),
                    start: stamp.instant(span.start), end: stamp.instant(span.end), minutes: minutes(span)
                )
            }
            result.moves = moves(input, stays: stays, day: day, stamp: stamp)
        }
        return result
    }

    private static func records(_ input: AssistantActivityInput, day: TimeSpan, stamp: Stamp) -> [AssistantActivityDay.Record] {
        // 합치기 같은 구간 편집 덮개가 다 덮은 자동 기록은 화면처럼 빼고 보낸다(AIR1110A02).
        let covers = input.actuals.filter { $0.modelVersion == ActivitySectionOverrideEngine.modelVersion }.map { $0.span(asOf: input.now) }
        return input.actuals
            .filter { $0.categoryID != "unconfirmed" }
            .filter { actual in
                isUserRecord(actual) || !covers.contains { $0.start <= actual.startedAt && actual.span(asOf: input.now).end <= $0.end }
            }
            .compactMap { actual -> (ActualRecord, TimeSpan)? in
                actual.span(asOf: input.now).intersection(with: day).flatMap { $0.duration >= 60 ? (actual, $0) : nil }
            }
            .sorted { $0.1.start < $1.1.start }
            .prefix(recordLimit)
            .map { actual, span in
                AssistantActivityDay.Record(
                    id: actual.id.uuidString,
                    start: stamp.instant(span.start),
                    end: stamp.instant(span.end),
                    title: recordTitle(actual, language: input.language),
                    category: .init(id: actual.categoryID, title: input.categoryTitles[actual.categoryID] ?? actual.categoryID),
                    source: isUserRecord(actual) ? "user" : "auto"
                )
            }
    }

    /// 위치로 만든 자동 기록 이름이 주소처럼 보이면 「머문 곳」으로 바꾼다. 가게·장소 이름은 보낸다(SEC1110A02, 대표 결정).
    static func recordTitle(_ actual: ActualRecord, language: MapHomeLanguage) -> String {
        if actual.source == .location, !isUserRecord(actual), isAddressLike(actual.title) { return language.text("머문 곳", "Place") }
        return RecordClassificationCatalog.localizedDetailTitle(actual.title, language: language)
    }

    static func isUserRecord(_ actual: ActualRecord) -> Bool {
        actual.manuallyCorrected || actual.source == .manual || actual.source == .timer
    }

    private static func memos(_ memos: [ActionMemo], day: TimeSpan, stamp: Stamp) -> [AssistantActivityDay.Memo] {
        memos
            .filter { $0.occurredAt >= day.start && $0.occurredAt < day.end }
            .sorted { $0.occurredAt < $1.occurredAt }
            .prefix(memoLimit)
            .map { memo in
                AssistantActivityDay.Memo(
                    id: memo.id.uuidString,
                    time: memo.isTimeless == true ? nil : stamp.clock(memo.occurredAt),
                    text: String(memo.text.prefix(1_000))
                )
            }
    }

    private static func plans(_ plans: [PlanRecord], day: TimeSpan, stamp: Stamp) -> [AssistantActivityDay.Plan] {
        plans
            .filter { $0.span.end > day.start && $0.span.start < day.end }
            .sorted { $0.span.start < $1.span.start }
            .prefix(planLimit)
            .map { plan in
                AssistantActivityDay.Plan(
                    id: plan.id.uuidString, title: String(plan.title.prefix(200)),
                    start: stamp.instant(plan.span.start), end: stamp.instant(plan.span.end)
                )
            }
    }

    /// 지하철·기차로 지나간 자리와 5분이 안 되는 자리는 머문 곳에서 뺀다.
    private static func visitStays(_ stays: [PlaceStay], travel: [TravelSegment], day: TimeSpan) -> [PlaceStay] {
        let rails = MapHomeRailIndex(travel: travel)
        return stays
            .filter { ($0.span.intersection(with: day)?.duration ?? 0) >= minimumVisit && !rails.isPassThrough($0.span) }
            .sorted { $0.span.start < $1.span.start }
    }

    private static func moves(
        _ input: AssistantActivityInput, stays: [PlaceStay], day: TimeSpan, stamp: Stamp
    ) -> [AssistantActivityDay.Move] {
        let name = { (stay: PlaceStay?) in
            stay.map { placeName($0, registered: input.registeredNames, language: input.language) }
        }
        return input.travel
            .compactMap { segment -> (TravelSegment, TimeSpan)? in
                segment.span.intersection(with: day).flatMap { $0.duration >= 60 ? (segment, $0) : nil }
            }
            .sorted { $0.1.start < $1.1.start }
            .prefix(placeLimit)
            .map { segment, span in
                let from = stays.first { $0.id == segment.fromPlaceID }
                    ?? stays.last { $0.span.end <= segment.span.start.addingTimeInterval(60) && segment.span.start.timeIntervalSince($0.span.end) <= neighbourGap }
                let to = stays.first { $0.id == segment.toPlaceID }
                    ?? stays.first { $0.span.start >= segment.span.end.addingTimeInterval(-60) && $0.span.start.timeIntervalSince(segment.span.end) <= neighbourGap }
                return AssistantActivityDay.Move(
                    from: name(from), to: name(to), mode: mode(segment.mode),
                    start: stamp.instant(span.start), end: stamp.instant(span.end), minutes: minutes(span),
                    id: segment.id.uuidString
                )
            }
    }

    static func mode(_ mode: TravelMode) -> String {
        switch mode {
        case .walking, .running: "walk"
        case .subway: "subway"
        case .bus: "bus"
        case .car, .taxi: "car"
        case .train: "train"
        case .airplane: "flight"
        case .cycling, .ship: "other"
        }
    }

    /// 등록 장소 이름, 없으면 주소처럼 보이지 않는 장소 이름, 그것도 없으면 「머문 곳」.
    static func placeName(_ stay: PlaceStay, registered: [String: String], language: MapHomeLanguage) -> String {
        if let name = registered[stay.placeKey] { return name }
        for candidate in [stay.displayName, stay.buildingName ?? ""] {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !isAddressLike(trimmed) { return trimmed }
        }
        return language.text("머문 곳", "Place")
    }

    /// 도로명·지번·좌표·구·丁目처럼 보이면 보내지 않는다(SEC1110A02에서 구·군·区·丁目·길 이름·거리 접미어를 더함).
    static func isAddressLike(_ text: String) -> Bool {
        let patterns = [
            #"(로|길|번길|동|가|리|읍|면)\s*\d"#,
            #"\d+\s*-\s*\d+"#,
            #"\d+\s*번지"#,
            #"^-?\d+(\.\d+)?\s*,\s*-?\d+(\.\d+)?$"#,
            #"^\d+\s+\S+.*\b(St|Street|Rd|Road|Ave|Avenue|Blvd|Boulevard|Lane|Ln|Dr|Drive|Pkwy|Parkway|Way|Ct|Court|Pl|Place|Hwy|Highway|Ter|Terrace|Cir|Circle|Sq|Square)\b"#,
            #"(특별시|광역시|특별자치|[가-힣]+시\s+[가-힣]+구)"#,
            // 강남구·울주군(입구는 뺀다), 渋谷区·道玄坂2丁目·番地
            #"(^|\s)[가-힣]{1,4}(?<!입)(구|군)(\s|$)"#,
            #"[\p{Han}\p{Hiragana}\p{Katakana}]+区"#,
            #"丁目|番地|\d+番\d*"#,
            // 번호 없는 길 이름만: 테헤란로, 세종대로
            #"^[가-힣\d]{1,10}(대로|로|길)$"#,
            #"^[가-힣]{1,4}(동|읍)$"#,
            #"^(Rue|Avenue|Boulevard|Calle|Avenida|Via|Viale|Chemin|Allée)\s"#,
            #"(strasse|straße|str\.|gasse|weg|allee|platz)(\s*\d|$)"#,
            // REV1110A06: 번지가 앞에 오는 주소(12 rue de Rivoli, 10 Via Roma), 5th Avenue, 역삼1동, …路12号
            #"^\d+\s*(bis|ter)?,?\s+(rue|avenue|av\.?|boulevard|bd\.?|chemin|allée|place|quai|via|viale|piazza|corso|calle|avenida|paseo|plaza|rua|travessa)\b"#,
            #"\b(rue|via|viale|piazza|corso|calle|avenida|paseo|rua)\s+\S.*\s\d+\w?$"#,
            #"\b\d+(st|nd|rd|th)\s+(St|Street|Ave|Avenue|Rd|Road|Blvd|Boulevard)\b"#,
            #"[가-힣]{1,6}\d+(동|가|리)$"#,
            #"[路街道巷弄]\s*\d+\s*[号號]?|\d+\s*[号號](\s|$)"#,
        ]
        return patterns.contains { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    private static func minutes(_ span: TimeSpan) -> Int { max(0, Int((span.duration / 60).rounded())) }

    /// 날짜·시각 글자. 모두 그 기기의 시간대로 쓴다.
    struct Stamp {
        private let dayFormatter: DateFormatter
        private let instantFormatter: DateFormatter
        private let clockFormatter: DateFormatter

        init(calendar: Calendar) {
            func make(_ format: String) -> DateFormatter {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.timeZone = calendar.timeZone
                formatter.dateFormat = format
                return formatter
            }
            dayFormatter = make("yyyy-MM-dd")
            instantFormatter = make("yyyy-MM-dd'T'HH:mmxxx")
            clockFormatter = make("HH:mm")
        }

        /// `instant`가 쓴 글자(`yyyy-MM-dd'T'HH:mmxxx`)를 다시 읽는다. 시간대는 글자에 든 값을 따른다.
        @MainActor static let instantParser: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mmxxx"
            return formatter
        }()

        func date(_ value: Date) -> String { dayFormatter.string(from: value) }
        func instant(_ value: Date) -> String { instantFormatter.string(from: value) }
        func clock(_ value: Date) -> String { clockFormatter.string(from: value) }
    }
}
