import Foundation
import TaptionPlanCore

/// 기록 합계가 원본 분류를 그대로 읽을지, 기록 화면의 공통 일과표로
/// 정규화할지 호출부가 명시한다. 위젯처럼 공용 모델만 빌드하는 대상도
/// 같은 함수 시그니처를 공유할 수 있도록 기본 모델 파일에 둔다.
enum RecordAnalysisScope: Sendable {
    case legacy
    case canonical
}

/// 공용 타깃(위젯 포함)이 기록을 합칠 때 쓰는 문자열 기반 정규화기다.
/// 상세 문맥은 iPhone 앱에서 더 풍부하게 보정하지만, 모든 타깃이 최소한
/// 같은 상위 분류를 계산하도록 의존성을 작게 유지한다.
enum RecordAnalysisCategoryNormalizer {
    static func categoryID(
        for rawCategoryID: String,
        title: String = "",
        behavior: String? = nil
    ) -> String {
        let value = [title, behavior ?? ""].joined(separator: " ")
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        let words = Set(
            [title, behavior ?? ""].joined(separator: " ").lowercased()
                .split { !($0.isASCII && $0.isLetter) }.map(String.init)
        )
        let rawValue = rawCategoryID.lowercased()
            .replacingOccurrences(of: " ", with: "")
        // 사용자가 직접 고르는 분류라 글자 추정으로 바꾸지 않는다.
        if rawValue == "shower" { return "activity" }
        if rawValue == "housework" { return rawValue }
        if rawCategoryID == "unconfirmed"
            || value.contains("unconfirmed-activity")
            || value.contains("unconfirmed-movement")
            || value.contains("unconfirmed-gap")
            || value.contains("미확인") {
            return "unconfirmed"
        }
        if value.contains("housework") || value.contains("집안일")
            || value.contains("groceries") || value.contains("장보기")
            || value.contains("cooking") || value.contains("요리") {
            return "housework"
        }
        if value.contains("sleep") || value.contains("수면")
            || value.contains("코어") || value.contains("깊은")
            || words.contains("rem") {
            return "sleep"
        }
        if value.contains("work") || value.contains("업무") || value.contains("근무") {
            return "work"
        }
        if value.contains("study") || value.contains("수업") || value.contains("학습") {
            return "study"
        }
        if value.contains("hobby") || value.contains("취미") {
            return "hobby"
        }
        if rawValue == "food" || rawValue.contains("meal") || rawValue.contains("eating")
            || value.contains("meal") || value.contains("eating")
            || value.contains("dining") || value.contains("food")
            || value.contains("식사")
            || value.contains("밥")
            || value.contains("음식") || value.contains("먹")
            || value.contains("아침") || value.contains("점심")
            || value.contains("저녁") || value.contains("간식")
            || value.contains("외식") || value.contains("식당") {
            return "eating"
        }
        if value.contains("exercise") || value.contains("운동") {
            return "exercise"
        }
        if value.contains("walking") || value.contains("걷")
            || value.contains("automotive") || value.contains("자동차")
            || value.contains("자가용") || value.contains("privatevehicle")
            || words.contains("car") || value.contains("driving")
            || value.contains("subway") || value.contains("metro")
            || value.contains("지하철") || value.contains("transit")
            || value.contains("publictransit") || value.contains("버스")
            || words.contains("bus") || value.contains("배")
            || value.contains("ship") || value.contains("ferry")
            || value.contains("비행기") || value.contains("airplane")
            || value.contains("자전거") || value.contains("cycling")
            || words.contains("bike") || value.contains("train")
            || words.contains("rail") {
            return "movement"
        }
        switch rawCategoryID {
        case let value where RecordClassificationCatalog.categoryIDs.contains(value):
            return value
        default:
            return "activity"
        }
    }
}

struct RecordClassificationFile: Codable, Sendable {
    var version: Int
    var categories: [RecordClassificationCategory]
}

struct RecordClassificationCategory: Codable, Identifiable, Sendable {
    var id: String
    var title: String
    var systemImage: String
    var automaticOnly: Bool?
    var details: [RecordClassificationDetail]
}

struct RecordClassificationDetail: Codable, Identifiable, Sendable {
    var id: String
    var title: String
    var behavior: String
    var systemImage: String
    var automaticOnly: Bool?
}

/// 앱·위젯·테스트가 함께 읽는 유일한 일과/상세활동 카탈로그다. 원본은
/// `TaptionPlanCore`의 분류표 JSON(v3) 하나이고, 읽지 못하면 상위 일과만 남긴다.
enum RecordClassificationCatalog {
    static let file: RecordClassificationFile = load()

    static var categories: [RecordClassificationCategory] {
        file.categories
    }

    static var categoryIDs: [String] {
        categories.map(\.id)
    }

    static var options: [ActivityCorrectionOption] {
        categories.flatMap { category in
            let phase = ActivityCorrectionOption(
                id: "phase.\(category.id)",
                title: category.title,
                behavior: nil,
                categoryID: category.id,
                systemImage: category.systemImage,
                isAutomatic: category.automaticOnly ?? false,
                isCustom: false,
                isAutomaticOnly: category.automaticOnly ?? false
            )
            let details = category.details.map { detail in
                ActivityCorrectionOption(
                    id: "detail.\(detail.id)",
                    title: detail.title,
                    behavior: detail.behavior,
                    categoryID: category.id,
                    systemImage: detail.systemImage,
                    isAutomatic: detail.automaticOnly
                        ?? category.automaticOnly
                        ?? false,
                    isCustom: false,
                    isAutomaticOnly: detail.automaticOnly
                        ?? category.automaticOnly
                        ?? false
                )
            }
            return [phase] + details
        }
    }

    /// 분류표에서 자리를 옮긴 상세활동의 지난 저장값을 지금 대분류로 읽는다(v5). 저장값은 고치지 않는다.
    static func relocatedCategoryID(from categoryID: String, behavior: String?) -> String? {
        switch (categoryID, behavior) {
        case ("shower", _): "activity"
        case ("activity", "housework"), ("activity", "groceries"), ("routine", "housework"),
             ("eating", "cooking"), ("food", "cooking"),
             ("housework", "cooking"), ("housework", "groceries"): "housework"
        default: nil
        }
    }

    /// 판정 값을 분류표의 상세활동 이름으로 맞춘다. 분류표에 없는 값은 원래 이름을 그대로 쓴다.
    static func detailTitle(categoryID: String, behavior: String?) -> String? {
        guard let behavior else { return nil }
        let aliases = ["homeRest": "stationary", "cafe": "stationary", "waiting": "stationary",
                       "call": "phoneCall", "mealPlace": "meal", "showering": "shower",
                       "housework": "chores", "gymFacility": "exercise"]
        let target = aliases[behavior] ?? behavior
        return categories.first { $0.id == categoryID }?.details.first { $0.behavior == target }?.title
    }

    private static func load() -> RecordClassificationFile {
        ActivityTaxonomyResource.data.flatMap {
            try? JSONDecoder().decode(RecordClassificationFile.self, from: $0)
        } ?? fallback
    }

    private static let fallback = RecordClassificationFile(
        version: 0,
        categories: [
            category("activity", "활동", "sparkles"),
            category("work", "업무", "briefcase.fill"),
            category("study", "수업", "book.fill"),
            category("hobby", "취미", "paintpalette.fill"),
            category("sleep", "수면", "moon.zzz.fill"),
            category("movement", "이동", "figure.walk.motion"),
            category("eating", "식사", "fork.knife"),
            category("exercise", "운동", "figure.strengthtraining.traditional"),
            category("health", "건강관리", "heart.text.square.fill"),
            category("housework", "집안일", "house.fill"),
            category("unconfirmed", "미확인", "questionmark.circle.fill"),
        ]
    )

    private static func category(
        _ id: String,
        _ title: String,
        _ systemImage: String
    ) -> RecordClassificationCategory {
        RecordClassificationCategory(
            id: id,
            title: title,
            systemImage: systemImage,
            automaticOnly: false,
            details: []
        )
    }
}
