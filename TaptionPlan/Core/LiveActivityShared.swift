import ActivityKit
import Foundation
import OSLog
import SwiftUI
import TaptionPlanCore

struct TaptionActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        private enum CodingKeys: String, CodingKey {
            case title
            case categoryID
            case startedAt
            case endsAt
            case catStyle
            case isRunning
            case majorCategoryID
            case majorCategoryTitle
            case majorCategorySystemImage
            case compactActivityTitle
            case compactActivityCategoryID
            case compactAnimationFrame
        }

        var title: String
        var categoryID: String
        var startedAt: Date
        var endsAt: Date
        var catStyle: String
        var isRunning: Bool
        var majorCategoryID: String = "activity"
        var majorCategoryTitle: String = AppLanguagePreference.text("활동", "Activity")
        var majorCategorySystemImage: String = "sparkles"
        var compactActivityTitle: String?
        var compactActivityCategoryID: String?
        var compactAnimationFrame: Int?

        init(
            title: String,
            categoryID: String,
            startedAt: Date,
            endsAt: Date,
            catStyle: String,
            isRunning: Bool,
            majorCategoryID: String = "activity",
            majorCategoryTitle: String = AppLanguagePreference.text("활동", "Activity"),
            majorCategorySystemImage: String = "sparkles",
            compactActivityTitle: String? = nil,
            compactActivityCategoryID: String? = nil,
            compactAnimationFrame: Int? = nil
        ) {
            self.title = title
            self.categoryID = categoryID
            self.startedAt = startedAt
            self.endsAt = endsAt
            self.catStyle = catStyle
            self.isRunning = isRunning
            self.majorCategoryID = majorCategoryID
            self.majorCategoryTitle = majorCategoryTitle
            self.majorCategorySystemImage = majorCategorySystemImage
            self.compactActivityTitle = compactActivityTitle
            self.compactActivityCategoryID = compactActivityCategoryID
            self.compactAnimationFrame = compactAnimationFrame
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.title = try container.decode(String.self, forKey: .title)
            self.categoryID = try container.decode(String.self, forKey: .categoryID)
            self.startedAt = try container.decode(Date.self, forKey: .startedAt)
            self.endsAt = try container.decode(Date.self, forKey: .endsAt)
            self.catStyle = try container.decode(String.self, forKey: .catStyle)
            self.isRunning = try container.decode(Bool.self, forKey: .isRunning)
            self.majorCategoryID = try container.decodeIfPresent(
                String.self,
                forKey: .majorCategoryID
            ) ?? "activity"
            self.majorCategoryTitle = try container.decodeIfPresent(
                String.self,
                forKey: .majorCategoryTitle
            ) ?? AppLanguagePreference.text("활동", "Activity")
            self.majorCategorySystemImage = try container.decodeIfPresent(
                String.self,
                forKey: .majorCategorySystemImage
            ) ?? "sparkles"
            self.compactActivityTitle = try container.decodeIfPresent(String.self, forKey: .compactActivityTitle)
            self.compactActivityCategoryID = try container.decodeIfPresent(String.self, forKey: .compactActivityCategoryID)
            self.compactAnimationFrame = try container.decodeIfPresent(Int.self, forKey: .compactAnimationFrame)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(title, forKey: .title)
            try container.encode(categoryID, forKey: .categoryID)
            try container.encode(startedAt, forKey: .startedAt)
            try container.encode(endsAt, forKey: .endsAt)
            try container.encode(catStyle, forKey: .catStyle)
            try container.encode(isRunning, forKey: .isRunning)
            try container.encode(majorCategoryID, forKey: .majorCategoryID)
            try container.encode(majorCategoryTitle, forKey: .majorCategoryTitle)
            try container.encode(
                majorCategorySystemImage,
                forKey: .majorCategorySystemImage
            )
            try container.encodeIfPresent(compactActivityTitle, forKey: .compactActivityTitle)
            try container.encodeIfPresent(compactActivityCategoryID, forKey: .compactActivityCategoryID)
            try container.encodeIfPresent(compactAnimationFrame, forKey: .compactAnimationFrame)
        }
    }

    var planID: UUID
}

enum TaptionLiveActivityStickmanAction: String, CaseIterable, Codable, Hashable, Sendable {
    case activity
    case computer
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
    case privateVehicle
    case bus
    case ship
    case airplane
    case cycling

    var isMoving: Bool {
        switch self {
        case .movement, .walking, .running, .car, .subway,
             .privateVehicle, .bus, .ship, .airplane, .cycling:
            true
        default:
            false
        }
    }

    static func resolve(categoryID: String, title: String) -> Self {
        let category = categoryID.lowercased().replacingOccurrences(of: " ", with: "")
        let categoryRoot = category.split(separator: ".", maxSplits: 1).first.map(String.init) ?? category
        if categoryRoot == "movement", category.contains(".") {
            let detail = String(category.split(separator: ".", maxSplits: 1)[1])
            let details: [String: Self] = ["walking": .walking, "running": .running,
                "car": .car, "subway": .subway, "privatevehicle": .privateVehicle,
                "bus": .bus, "ship": .ship, "airplane": .airplane, "cycling": .cycling]
            if let action = details[detail] { return action }
        }
        switch categoryRoot {
        case "activity", "shower", "housework": return .activity
        case "computer", "work": return .computer
        case "reading", "study": return .reading
        case "hobby": return .hobby
        case "sleeping", "sleep": return .sleeping
        case "movement": return .movement
        case "eating", "food": return .eating
        case "exercise": return .exercise
        case "unconfirmed", "unknown": return .unconfirmed
        default: break
        }
        let value = "\(categoryID) \(title)".lowercased()
        let has = { (terms: [String]) in terms.contains { value.contains($0) } }

        if category == "unconfirmed" || category == "unknown"
            || has(["unconfirmed", "unknown", "미확인"]) {
            return .unconfirmed
        }

        if has(["movement.running", "달리기", "running"]) { return .running }
        if has(["movement.walking", "걷기", "walking", "walk"]) { return .walking }
        if has(["movement.privatevehicle", "자가용", "private vehicle", "privatevehicle"]) { return .privateVehicle }
        if has(["movement.car", "자동차", "차량", "car", "driving"]) { return .car }
        if has(["movement.subway", "지하철", "subway", "metro"]) { return .subway }
        if has(["movement.bus", "버스", "bus"]) { return .bus }
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if has(["movement.ship", "선박", "ship", "ferry"]) || normalizedTitle == "배" { return .ship }
        if has(["movement.airplane", "비행기", "항공", "airplane", "flight"]) { return .airplane }
        if has(["movement.cycling", "자전거", "cycling", "bike"]) { return .cycling }

        if has(["업무", "회사", "컴퓨터", "work"]) { return .computer }
        if has(["수업", "학교", "독서", "study", "school", "reading"]) { return .reading }
        if has(["취미", "hobby"]) { return .hobby }
        if has(["수면", "잠", "sleep"]) { return .sleeping }
        if has(["식사", "밥", "food", "meal", "eating"]) { return .eating }
        if has(["운동", "exercise"]) { return .exercise }

        if has(["활동", "activity"]) { return .activity }
        if has(["이동", "movement"]) { return .movement }
        return .activity
    }

    /// 지금 활동의 대분류 이름. 다이나믹 아일랜드·잠금화면·워치가 같은 값을 쓴다.
    /// 상태에 저장된 제목(`currentActivityTitle`)은 한국어라, 영어 설정에서는 이 이름으로 바꿔 보여 준다.
    var localizedTitle: String {
        AppLanguagePreference.runtimeText(koreanTitle, englishTitle)
    }

    var koreanTitle: String {
        switch self {
        case .activity: "활동"
        case .computer: "업무"
        case .reading: "학습"
        case .hobby: "취미"
        case .sleeping: "수면"
        case .movement: "이동"
        case .eating: "식사"
        case .exercise: "운동"
        case .unconfirmed: "확인 중"
        case .walking: "걷기"
        case .running: "달리기"
        case .car: "자동차"
        case .subway: "지하철"
        case .privateVehicle: "자가용"
        case .bus: "버스"
        case .ship: "배"
        case .airplane: "비행기"
        case .cycling: "자전거"
        }
    }

    var englishTitle: String {
        switch self {
        case .activity: "Activity"
        case .computer: "Work"
        case .reading: "Study"
        case .hobby: "Hobby"
        case .sleeping: "Sleep"
        case .movement: "Movement"
        case .eating: "Meal"
        case .exercise: "Exercise"
        case .unconfirmed: "Checking"
        case .walking: "Walking"
        case .running: "Running"
        case .car: "Driving"
        case .subway: "Subway"
        case .privateVehicle: "Car"
        case .bus: "Bus"
        case .ship: "Ferry"
        case .airplane: "Flight"
        case .cycling: "Cycling"
        }
    }
}

enum TaptionLiveActivityCatPolicy {
    static func action(categoryID: String, title: String) -> TaptionCatAnimationAction {
        switch TaptionLiveActivityStickmanAction.resolve(categoryID: categoryID, title: title) {
        case .sleeping: .sleeping
        case .eating: .eating
        case .running, .exercise: .running
        case .movement, .walking: .walking
        case .hobby: .ballPlay
        case .computer: .kneading
        case .reading: .kneading
        case .unconfirmed: .startled
        default: .sitting
        }
    }
}
