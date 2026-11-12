import Foundation

/// 여행 일정을 손으로 빠르게 넣기(TVQ1112A01): 한 줄에서 시각·길이·분류를 읽고, 기본값과 다음 시작을 정한다.
public enum TravelQuickEntry {
    public struct Parsed: Hashable, Sendable {
        /// 시각·길이 말을 뺀 이름.
        public var title: String
        /// 그날 0시부터의 분.
        public var startMinute: Int?
        public var durationMinutes: Int?
        /// 여행 일정 종류(`meal`·`transfer`…).
        public var kind: String?

        public init(title: String, startMinute: Int? = nil, durationMinutes: Int? = nil, kind: String? = nil) {
            self.title = title
            self.startMinute = startMinute
            self.durationMinutes = durationMinutes
            self.kind = kind
        }
    }

    public static let step = 15
    /// 길이 칩(분).
    public static let durations = [15, 30, 45, 60, 90, 120, 180, 240]

    /// 분류별 기본 길이(분).
    public static func defaultDuration(kind: String) -> Int {
        switch kind {
        case "transfer": 30
        case "cafe": 45
        case "meal", "shopping", "rest", "photo", "other": 60
        case "flight", "activity": 120
        case "sleep", "lodging": 480
        default: 90
        }
    }

    /// 계획표 열(이동·식사·관광·숙소)을 눌렀을 때의 종류.
    public static func kind(forColumn column: Int) -> String {
        ["transfer", "meal", "sight", "lodging"][min(max(column, 0), 3)]
    }

    /// 새 일정의 시작: 그날 마지막 일정의 끝, 없으면 오늘은 지금(15분 올림), 아니면 09:00. 자정을 넘기지 않는다.
    public static func nextStart(lastEndMinute: Int?, nowMinute: Int?) -> Int {
        let raw = lastEndMinute ?? nowMinute.map { ($0 + step - 1) / step * step } ?? 9 * 60
        return min(max(raw, 0), 1_440 - step)
    }

    /// 누른 자리의 분을 15분 단위로 내린다.
    public static func snapped(_ minute: Int) -> Int {
        min(max(minute, 0), 1_440 - step) / step * step
    }

    /// 순서: 범위(「9-11」) → 시각(「12시 30분」「2pm」) → 길이(「1시간 반」「45m」). 읽은 말은 이름에서 뺀다.
    public static func parse(_ text: String) -> Parsed {
        var rest = " " + text + " "
        var parsed = Parsed(title: "")
        var mealWord: String?
        if let match = firstMatch(rangePattern, in: rest),
           var start = clock(match, marker: 1, hour: 2, minute: 3, half: nil, suffix: 4),
           var end = clock(match, marker: 5, hour: 6, minute: 7, half: nil, suffix: 8) {
            if end.minute == 0 { end.minute = 1_440 }
            // 끝에만 오후 표시가 있으면 시작도 오후다(「7-9pm」). 끝이 시작보다 앞이면 끝을 오후로 본다(「10-2」).
            if end.isExplicit, !start.isExplicit, start.minute < 720, start.minute + 720 < end.minute { start.minute += 720 }
            if end.minute <= start.minute, end.minute <= 720, end.minute + 720 > start.minute { end.minute += 720 }
            if end.minute > start.minute, start.minute < 1_440, end.minute <= 1_440 {
                parsed.startMinute = start.minute
                parsed.durationMinutes = end.minute - start.minute
                mealWord = start.word
                rest = removing(match, from: rest)
            }
        }
        if parsed.startMinute == nil, let match = firstMatch(timePattern, in: rest) {
            let found = group(match, 2) != nil
                ? clock(match, marker: 1, hour: 2, minute: 3, half: nil, suffix: 4)
                : clock(match, marker: 5, hour: 6, minute: 7, half: 8, suffix: 9)
            if let found, found.minute < 1_440 {
                parsed.startMinute = found.minute
                mealWord = found.word
                rest = removing(match, from: rest)
            }
        }
        if parsed.durationMinutes == nil, let match = firstMatch(durationPattern, in: rest) {
            let hours = Double(group(match, 1) ?? group(match, 5) ?? "") ?? 0
            let half = group(match, 2) != nil ? 30.0 : 0
            let minutes = Double(group(match, 3) ?? group(match, 4) ?? group(match, 6) ?? group(match, 7) ?? "") ?? 0
            let total = Int((hours * 60 + half + minutes).rounded())
            if total > 0, total <= 1_440 {
                parsed.durationMinutes = total
                rest = removing(match, from: rest)
            }
        }
        parsed.title = rest.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // 「저녁 7시」처럼 시각에 붙은 아침·저녁만 남으면 그 말이 이름이다.
        if parsed.title.isEmpty, let mealWord, ["아침", "저녁"].contains(mealWord) { parsed.title = mealWord }
        parsed.kind = kind(in: parsed.title)
        return parsed
    }

    // MARK: 읽는 규칙

    private static let marker = "(오전|오후|아침|낮|저녁|밤|새벽)?\\s*"
    private static let suffix = "\\s*(am|pm|a\\.m\\.|p\\.m\\.)?"
    private static let rangeSide = marker + "(\\d{1,2})(?:(?::|시(?!간))\\s*(?:(\\d{1,2})\\s*분?)?)?" + suffix
    /// 1 표시 · 2 시 · 3 분 · 4 am/pm — 5 표시 · 6 시 · 7 분 · 8 am/pm.
    private static let rangePattern = regex("(?<![\\d.:])" + rangeSide + "\\s*[-~–]\\s*" + rangeSide + "(?![\\d:])")
    /// 쌍점 꼴 1 표시 · 2 시 · 3 분 · 4 am/pm | 「시」·am/pm 꼴 5 표시 · 6 시 · 7 분 · 8 반 · 9 am/pm.
    private static let timePattern = regex(
        "(?<![\\d.:])(?:" + marker + "(\\d{1,2}):(\\d{2})" + suffix
            + "|" + marker + "(\\d{1,2})(?:시(?!간)\\s*(?:(\\d{1,2})\\s*분|(반))?|(?=\\s*(?:am|pm|a\\.m\\.|p\\.m\\.)(?![a-z])))" + suffix + ")(?![\\d:])"
    )
    /// 1 시간 · 2 반 · 3 분 | 4 분 | 5 h · 6 m | 7 m.
    private static let durationPattern = regex(
        "(?<![\\d.:])(?:(\\d+(?:\\.\\d+)?)\\s*시간\\s*(반)?\\s*(?:(\\d{1,2})\\s*분)?|(\\d{1,3})\\s*분"
            + "|(\\d+(?:\\.\\d+)?)\\s*(?:hours?|hrs?|h)(?![a-z])\\s*(?:(\\d{1,2})\\s*(?:mins?|m)(?![a-z]))?"
            + "|(\\d{1,3})\\s*(?:minutes?|mins?|m)(?![a-z]))"
    )

    /// 식이 잘못되면 nil이고, 그때는 아무것도 읽지 않는다(시험이 식을 지킨다).
    private static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private struct Match {
        let result: NSTextCheckingResult
        let source: NSString
    }

    private struct Clock {
        var minute: Int
        /// 오전·오후를 적었는지.
        var isExplicit: Bool
        var word: String?
    }

    private static func firstMatch(_ regex: NSRegularExpression?, in text: String) -> Match? {
        let source = text as NSString
        return regex?.firstMatch(in: text, range: NSRange(location: 0, length: source.length)).map { Match(result: $0, source: source) }
    }

    private static func group(_ match: Match, _ index: Int) -> String? {
        let range = match.result.range(at: index)
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        return match.source.substring(with: range)
    }

    private static func removing(_ match: Match, from text: String) -> String {
        (text as NSString).replacingCharacters(in: match.result.range, with: " ")
    }

    private static func clock(_ match: Match, marker: Int, hour: Int, minute: Int, half: Int?, suffix: Int) -> Clock? {
        guard let hourText = group(match, hour), var value = Int(hourText) else { return nil }
        var minutes = Int(group(match, minute) ?? "") ?? 0
        if let half, group(match, half) != nil { minutes = 30 }
        guard value <= 24, minutes < 60 else { return nil }
        let word = group(match, marker)
        let tail = group(match, suffix)?.lowercased().replacingOccurrences(of: ".", with: "")
        var isExplicit = true
        if tail == "pm" || ["오후", "저녁", "밤", "낮"].contains(word ?? "") {
            // 「밤 12시」는 자정, 「낮 11시」는 오전 그대로.
            if word == "밤", value == 12 { value = 0 } else if value < 12, !(word == "낮" && value >= 10) { value += 12 }
        } else if tail == "am" || ["오전", "아침", "새벽"].contains(word ?? "") {
            if value == 12 { value = 0 }
        } else {
            isExplicit = false
            // 표시 없는 1~6시는 오후로 본다(여행 계획에 새벽은 드물다). 「06:00」처럼 0을 붙이면 그대로.
            if (1...6).contains(value), !hourText.hasPrefix("0") { value += 12 }
        }
        return Clock(minute: value * 60 + minutes, isExplicit: isExplicit, word: word)
    }

    private static let kindWords: [(kind: String, words: [String])] = [
        ("flight", ["비행기", "항공", "공항", "탑승", "flight", "airport"]),
        ("lodging", ["체크인", "체크아웃", "호텔", "숙소", "료칸", "게스트하우스", "hotel", "check-in", "checkout", "hostel"]),
        ("sleep", ["취침", "수면", "잠자", "sleep"]),
        ("cafe", ["카페", "커피", "디저트", "cafe", "coffee"]),
        ("meal", ["아침식사", "조식", "점심", "저녁식사", "저녁 식사", "저녁밥", "식사", "맛집", "브런치", "라멘", "초밥", "breakfast", "lunch", "dinner", "brunch", "restaurant"]),
        ("transfer", ["이동", "지하철", "전철", "버스", "택시", "기차", "열차", "신칸센", "ktx", "페리", "렌터카", "도보", "subway", "train", "bus", "taxi", "ferry", "transfer", "drive"]),
        ("shopping", ["쇼핑", "면세", "시장", "백화점", "아울렛", "shopping", "market", "mall"]),
        ("photo", ["사진", "포토", "야경", "전망대", "photo", "viewpoint"]),
        ("rest", ["휴식", "쉬기", "온천", "마사지", "스파", "rest", "spa"]),
        ("activity", ["체험", "투어", "수영", "스키", "등산", "트레킹", "공연", "놀이공원", "tour", "hike", "show"]),
        ("sight", ["관광", "박물관", "미술관", "성", "신사", "사원", "절", "궁", "공원", "museum", "temple", "castle", "park"]),
    ]

    /// 이름에 든 낱말로 종류를 짐작한다. 한 글자 낱말(성·절·궁)은 낱말 끝에 있을 때만 본다.
    static func kind(in title: String) -> String? {
        let lowered = title.lowercased()
        if lowered == "아침" || lowered == "저녁" { return "meal" }
        let tokens = lowered.split(whereSeparator: \.isWhitespace)
        for entry in kindWords {
            for word in entry.words {
                if word.count == 1 ? tokens.contains(where: { $0.count > 1 && $0.hasSuffix(word) }) : lowered.contains(word) { return entry.kind }
            }
        }
        return nil
    }
}
