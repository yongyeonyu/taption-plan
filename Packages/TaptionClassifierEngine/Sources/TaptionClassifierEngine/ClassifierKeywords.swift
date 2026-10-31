import Foundation

/// 제목·behavior 문자열에서 분류를 읽는 단 하나의 키워드 판정.
///
/// 부분 문자열 대신 단어 단위로 본다. 한글 한 글자 키워드(배·잠·밥)는 그 글자
/// 하나이거나 조사가 붙은 경우만 인정해 배달·배드민턴·잠깐을 잡지 않는다. 두
/// 글자 이상은 앞부분 일치를 허용하되 제외어를 먼저 거른다. 영문은 낱말 전체
/// 일치만 본다(`rem`이 `remote`를, `work`가 `workout`을 잡지 않는다).
public enum ClassifierKeywords {
    public static let sleep: Set<String> = ["수면", "잠", "취침", "낮잠", "코어", "sleep", "sleeping", "nap", "rem", "asleep"]
    public static let work: Set<String> = ["업무", "근무", "회의", "야근", "work", "working", "meeting", "office"]
    public static let studyClass: Set<String> = ["수업", "학습", "강의", "공부", "학교", "study", "studying", "class", "lecture", "school"]
    public static let academy: Set<String> = ["학원", "academy", "tutoring"]
    public static let hobby: Set<String> = ["취미", "hobby"]
    public static let eating: Set<String> = [
        "식사", "밥", "점심", "저녁식사", "아침식사", "요리", "식당", "외식",
        "meal", "eating", "lunch", "dinner", "breakfast", "cooking", "restaurant",
    ]
    public static let exercise: Set<String> = [
        "운동", "헬스", "요가", "필라테스", "수영", "배드민턴", "테니스", "축구", "농구", "등산", "클라이밍",
        "exercise", "workout", "gym", "yoga", "pilates", "swimming", "badminton", "tennis", "hiking",
    ]
    public static let housework: Set<String> = ["집안일", "청소", "빨래", "설거지", "housework", "cleaning", "laundry"]

    public static let modeWords: [(TransportMode, Set<String>)] = [
        (.walking, ["걷기", "걷다", "걸음", "도보", "산책", "계단", "walking", "walk", "stairs"]),
        (.running, ["달리기", "러닝", "조깅", "running", "run", "jogging"]),
        (.cycling, ["자전거", "사이클", "cycling", "bike", "bicycle"]),
        (.car, ["자동차", "자가용", "차량", "택시", "운전", "automotive", "car", "taxi", "driving"]),
        (.bus, ["버스", "bus"]),
        (.subway, ["지하철", "전철", "subway", "metro"]),
        (.train, ["기차", "열차", "ktx", "srt", "train", "rail"]),
        (.ship, ["배", "선박", "페리", "여객선", "유람선", "ship", "ferry", "boat"]),
        (.airplane, ["비행기", "비행", "항공", "airplane", "flight", "plane"]),
    ]
    public static let genericMovement: Set<String> = ["이동", "통근", "transit", "commute"]

    /// 두 글자 이상 키워드가 앞부분으로 걸려도 다른 뜻이 되는 낱말.
    public static let exclusions: Set<String> = [
        "배달", "배송", "배터리", "배구", "배우", "배경", "배포", "배정", "배치",
        "이동통신", "버스킹", "수면제", "코어근육", "운동화", "회의실예약",
    ]

    private static let particles: [String] = [
        "으로", "에서", "부터", "까지", "타고", "타기", "탑승", "하기", "했다", "중",
        "을", "를", "이", "가", "은", "는", "로", "에", "와", "과", "도", "만", "의", "편",
    ]

    /// 한글 연속, 영문·숫자 연속을 낱말로 자른다.
    public static func tokens(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var currentIsHangul: Bool?
        for scalar in text.lowercased().unicodeScalars {
            let hangul = (0xAC00...0xD7A3).contains(scalar.value)
            let latin = CharacterSet.alphanumerics.contains(scalar) && !hangul
            guard hangul || latin else {
                if !current.isEmpty { result.append(current) }
                current = ""
                currentIsHangul = nil
                continue
            }
            if let currentIsHangul, currentIsHangul != hangul, !current.isEmpty {
                result.append(current)
                current = ""
            }
            current.unicodeScalars.append(scalar)
            currentIsHangul = hangul
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    public static func token(_ token: String, matches keyword: String) -> Bool {
        if token == keyword { return true }
        guard let first = keyword.unicodeScalars.first, (0xAC00...0xD7A3).contains(first.value),
              token.hasPrefix(keyword) else { return false }
        if exclusions.contains(where: token.hasPrefix) { return false }
        let rest = String(token.dropFirst(keyword.count))
        if keyword.count == 1 { return particles.contains(rest) }
        return true
    }

    public static func contains(_ text: String, any keywords: Set<String>) -> Bool {
        let words = tokens(text)
        return words.contains { word in keywords.contains { token(word, matches: $0) } }
    }

    public static func mode(in text: String) -> TransportMode? {
        let words = tokens(text)
        return modeWords.first { _, keywords in
            words.contains { word in keywords.contains { token(word, matches: $0) } }
        }?.0
    }

    /// 제목·behavior만으로 정할 수 있는 대분류. 정할 수 없으면 nil.
    public static func categoryID(in text: String) -> String? {
        if contains(text, any: housework) { return "activity" }
        if contains(text, any: sleep) { return "sleep" }
        if contains(text, any: work) { return "work" }
        if contains(text, any: academy) || contains(text, any: studyClass) { return "study" }
        if contains(text, any: hobby) { return "hobby" }
        if contains(text, any: eating) { return "eating" }
        if contains(text, any: exercise) { return "exercise" }
        if mode(in: text) != nil || contains(text, any: genericMovement) { return "movement" }
        return nil
    }
}
