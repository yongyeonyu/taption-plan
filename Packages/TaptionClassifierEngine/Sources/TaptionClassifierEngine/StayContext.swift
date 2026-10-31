import Foundation

/// 머문 자리의 맥락.
public enum StayContext: String, Codable, CaseIterable, Sendable {
    case work, classLesson, academy, hobby, eating, exercise, rest, unknown

    public var categoryID: String {
        switch self {
        case .work: "work"
        case .classLesson, .academy: "study"
        case .hobby: "hobby"
        case .eating: "eating"
        case .exercise: "exercise"
        case .rest, .unknown: "activity"
        }
    }

    public var detailBehavior: String {
        switch self {
        case .work: "work"
        case .classLesson: "class"
        case .academy: "academy"
        case .hobby: "hobby"
        case .eating: "meal"
        case .exercise: "exercise"
        case .rest: "stationary"
        case .unknown: "unconfirmed"
        }
    }
}

/// 등록 장소 종류(앱 `FrequentPlaceKind`의 원본 문자열).
public enum RegisteredPlaceKind: String, Codable, Sendable {
    case home, school, academy, company, hobby, exercise, restaurant, custom
}

public struct StayContextInput: Sendable {
    public var interval: ClassifierInterval
    public var registeredKind: RegisteredPlaceKind?
    /// 지도 POI 분류 문자열(예: "restaurant", "cafe", "fitnessCenter", "school").
    public var pointOfInterest: String?
    public var calendarTitles: [String]
    /// 체류 중 몸이 움직인 비율(워치 가속·걸음 근거, 0…1).
    public var activeFraction: Double?
    public var calendar: Calendar

    public init(interval: ClassifierInterval, registeredKind: RegisteredPlaceKind? = nil, pointOfInterest: String? = nil, calendarTitles: [String] = [], activeFraction: Double? = nil, calendar: Calendar = .current) {
        self.interval = interval
        self.registeredKind = registeredKind
        self.pointOfInterest = pointOfInterest
        self.calendarTitles = calendarTitles
        self.activeFraction = activeFraction
        self.calendar = calendar
    }
}

public struct StayContextResult: Hashable, Sendable {
    public var context: StayContext
    public var score: Double
    public var evidence: [String]
}

/// 등록 종류·POI·일정·길이·시간대 사전확률로 맥락을 고른다.
public enum StayContextClassifier {
    public static func classify(_ input: StayContextInput) -> StayContextResult {
        var scores: [StayContext: Double] = [.rest: 0.2, .unknown: 0.25]
        var evidence: [StayContext: [String]] = [:]
        func add(_ context: StayContext, _ value: Double, _ reason: String) {
            scores[context, default: 0] += value
            evidence[context, default: []].append(reason)
        }
        let minutes = input.interval.duration / 60
        let hour = input.calendar.component(.hour, from: input.interval.start)
        let weekday = input.calendar.component(.weekday, from: input.interval.start)
        let isWeekday = (2...6).contains(weekday)
        let mealHour = (11...14).contains(hour) || (17...21).contains(hour) || (7...9).contains(hour)

        switch input.registeredKind {
        case .company:
            add(.work, minutes >= 30 ? 1.2 : 0.5, "등록 장소: 회사")
            if isWeekday, (8...19).contains(hour) { add(.work, 0.3, "평일 근무 시간") }
        case .school:
            add(.classLesson, minutes >= 30 ? 1.2 : 0.5, "등록 장소: 학교")
        case .academy:
            add(.academy, minutes >= 30 ? 1.2 : 0.5, "등록 장소: 학원")
        case .hobby: add(.hobby, 1.1, "등록 장소: 취미")
        case .exercise: add(.exercise, minutes >= 15 ? 1.1 : 0.4, "등록 장소: 운동")
        case .restaurant:
            add(.eating, (15...120).contains(minutes) ? 1.2 : 0.5, "등록 장소: 식당")
        case .home: add(.rest, 0.8, "등록 장소: 집")
        case .custom, .none: break
        }

        switch input.pointOfInterest?.lowercased() {
        case "restaurant", "bakery", "foodmarket":
            add(.eating, mealHour ? 0.8 : 0.4, "주변 식당")
        case "cafe": add(.rest, 0.4, "주변 카페")
        case "fitnesscenter", "stadium", "swimming", "gym":
            add(.exercise, 0.7, "주변 운동시설")
        case "school", "university":
            add(.classLesson, 0.6, "주변 학교")
        default: break
        }

        for title in input.calendarTitles {
            if let category = ClassifierKeywords.categoryID(in: title) {
                let context: StayContext? = switch category {
                case "work": .work
                case "study": ClassifierKeywords.contains(title, any: ClassifierKeywords.academy) ? .academy : .classLesson
                case "hobby": .hobby
                case "eating": .eating
                case "exercise": .exercise
                default: nil
                }
                if let context { add(context, 0.9, "일정: \(title)") }
            }
        }
        if let active = input.activeFraction {
            if active >= 0.5 { add(.exercise, 0.5 * active, "몸 움직임 \(Int(active * 100))%") }
            if active < 0.1 { add(.rest, 0.2, "거의 움직이지 않음") }
        }
        if mealHour, (20...90).contains(minutes), input.registeredKind == nil, input.pointOfInterest != nil {
            add(.eating, 0.2, "식사 시간대")
        }

        let total = scores.values.reduce(0, +)
        let best = scores.max { $0.value == $1.value ? $0.key.rawValue > $1.key.rawValue : $0.value < $1.value }!
        return StayContextResult(context: best.key, score: total > 0 ? best.value / total : 0, evidence: evidence[best.key] ?? [])
    }
}
