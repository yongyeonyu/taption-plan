import Foundation

enum CategoryCatalog {
    static let builtIn: [CategoryDefinition] = [
        category("movement", "이동", .movement, "#E8D3B3", "#A87A3D", "#C58C35", 0),
        category("location", "위치", .location, "#D5EAF5", "#4F87A7", "#4E9BC4", 1),
        category("activity", "활동", .activity, "#D4E7D1", "#4D7A49", "#568D51", 2),
        category("photo", "사진", .photo, "#EADDF3", "#8754A9", "#965CB9", 3),
        category("project", "프로젝트", .briefcase, "#BEDAE3", "#4E8EA8", "#4E9CB8", 4),
        category("exercise", "운동", .exercise, "#FED5CF", "#B4584D", "#E46252", 5),
        category("study", "학습", .book, "#D3C7E6", "#7654A4", "#805BB1", 6),
        category("hobby", "취미", .music, "#C4E9DA", "#477F69", "#4B9879", 7),
        category("sleep", "수면", .sleep, "#C9D6E5", "#536F91", "#5B7EA8", 8),
        category("routine", "일과", .home, "#F7E8B4", "#A98118", "#B58A12", 9),
        category("relationship", "관계", .relationship, "#F9D9E1", "#A75B70", "#B9617B", 10),
        category("rest", "휴식", .cafe, "#E3E4E8", "#696D77", "#777C88", 11),
        category("travel", "여행", .travel, "#CDE8F1", "#407F98", "#3F91AE", 12),
        category("health", "건강", .health, "#D4E7D1", "#4D7A49", "#568D51", 13),
        category("event", "이벤트", .event, "#F5DDEE", "#9D5D86", "#B86B9D", 14),
        // Role- and situation-neutral categories. Users choose the ones they
        // need during start configuration; all remain available later.
        category("work", "업무", .work, "#D9E5F2", "#496A8E", "#5A82A8", 15),
        category("family", "가족", .family, "#F7DDE6", "#9A5A72", "#B56A84", 16),
        category("parenting", "육아", .stroller, "#F8E2D0", "#A96C3E", "#C9844A", 17),
        category("finance", "재정", .shopping, "#E4E8CF", "#68783A", "#82944A", 18),
        category("housing", "주거", .building, "#E7DED2", "#78654E", "#987F60", 19),
        category("career", "커리어", .target, "#E5D9F1", "#72518E", "#9067AD", 20),
        category("creative", "창작·공연", .performance, "#F2D9E9", "#8B4F78", "#A9618D", 21),
        category("pet", "반려동물", .pet, "#F5E2C4", "#94703C", "#B38A4D", 22),
        category("community", "봉사·커뮤니티", .community, "#DDEBE6", "#4C7467", "#5B8D7D", 23),
        category("student", "학생", .student, "#DCE7F7", "#4B6591", "#5877A8", 24),
        category("exam", "수험", .exam, "#F4E1C6", "#94652B", "#AA7835", 25),
        category("military", "군인", .military, "#DDE5D3", "#5D7040", "#6F8750", 26),
        category("athlete", "운동선수", .athlete, "#F5D6D4", "#934A4B", "#A95758", 27),
        category("pregnancy", "임신·출산", .pregnancy, "#F5DDE8", "#9A5875", "#B66887", 28),
        category("caregiver", "돌봄", .caregiver, "#E6DDF3", "#69538D", "#7F67AA", 29),
        category("government", "공공·공무", .government, "#DCE8EE", "#4D6E7A", "#5F8998", 30),
        category("food", "식생활", .food, "#F5E4CB", "#976A38", "#AE7F43", 31)
    ]

    static func makeCustom(
        name: String,
        icon: CategoryIcon,
        lightHex: String,
        darkHex: String? = nil,
        actualHex: String? = nil,
        existing: [CategoryDefinition]
    ) throws -> CategoryDefinition {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CategoryError.emptyName }
        guard !existing.contains(where: {
            $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }) else {
            throw CategoryError.duplicateName
        }
        guard isValidHex(lightHex) else { throw CategoryError.invalidColor }
        let sortOrder = (existing.map(\.sortOrder).max() ?? -1) + 1
        return CategoryDefinition(
            id: "custom.\(UUID().uuidString.lowercased())",
            name: trimmed,
            icon: icon,
            lightHex: normalizedHex(lightHex),
            darkHex: normalizedHex(darkHex ?? lightHex),
            actualHex: normalizedHex(actualHex ?? lightHex),
            sortOrder: sortOrder,
            isBuiltIn: false
        )
    }

    static func update(
        _ category: CategoryDefinition,
        name: String? = nil,
        icon: CategoryIcon? = nil,
        lightHex: String? = nil,
        hidden: Bool? = nil
    ) throws -> CategoryDefinition {
        var value = category
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw CategoryError.emptyName }
            value.name = trimmed
        }
        if let icon { value.icon = icon }
        if let lightHex {
            guard isValidHex(lightHex) else { throw CategoryError.invalidColor }
            value.lightHex = normalizedHex(lightHex)
        }
        if let hidden { value.isHidden = hidden }
        return value
    }

    static func reordered(
        _ categories: [CategoryDefinition],
        orderedIDs: [String]
    ) -> [CategoryDefinition] {
        let rank = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map {
            ($0.element, $0.offset)
        })
        return categories
            .map { category in
                var value = category
                value.sortOrder = rank[category.id] ?? category.sortOrder + orderedIDs.count
                return value
            }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    static func moving(
        _ categories: [CategoryDefinition],
        fromOffsets source: IndexSet,
        toOffset destination: Int
    ) -> [CategoryDefinition] {
        var orderedIDs = categories
            .sorted { $0.sortOrder < $1.sortOrder }
            .map(\.id)
        let movingIDs = source
            .sorted()
            .compactMap { index in
                orderedIDs.indices.contains(index)
                    ? orderedIDs[index]
                    : nil
            }
        for index in source.sorted(by: >)
        where orderedIDs.indices.contains(index) {
            orderedIDs.remove(at: index)
        }
        let removedBeforeDestination = source.filter {
            $0 < destination
        }.count
        let insertionIndex = min(
            orderedIDs.count,
            max(0, destination - removedBeforeDestination)
        )
        orderedIDs.insert(
            contentsOf: movingIDs,
            at: insertionIndex
        )
        return reordered(categories, orderedIDs: orderedIDs)
    }

    static func deleting(
        categoryID: String,
        reassigningTo replacementID: String,
        categories: [CategoryDefinition],
        plans: [PlanRecord],
        actuals: [ActualRecord]
    ) throws -> CategoryDeletionResult {
        guard categoryID != replacementID else {
            throw CategoryError.sameReplacement
        }
        guard categories.contains(where: { $0.id == replacementID }) else {
            throw CategoryError.replacementMissing
        }
        guard let target = categories.first(where: { $0.id == categoryID }) else {
            throw CategoryError.categoryMissing
        }
        guard !target.isBuiltIn else { throw CategoryError.builtInCannotDelete }

        return CategoryDeletionResult(
            categories: categories.filter { $0.id != categoryID },
            plans: plans.map { plan in
                guard plan.categoryID == categoryID else { return plan }
                var value = plan
                value.categoryID = replacementID
                value.updatedAt = .now
                return value
            },
            actuals: actuals.map { actual in
                guard actual.categoryID == categoryID else { return actual }
                var value = actual
                value.categoryID = replacementID
                return value
            }
        )
    }

    private static func category(
        _ id: String,
        _ name: String,
        _ icon: CategoryIcon,
        _ light: String,
        _ dark: String,
        _ actual: String,
        _ order: Int
    ) -> CategoryDefinition {
        CategoryDefinition(
            id: id,
            name: name,
            icon: icon,
            lightHex: light,
            darkHex: dark,
            actualHex: actual,
            sortOrder: order,
            isBuiltIn: true
        )
    }

    private static func isValidHex(_ value: String) -> Bool {
        normalizedHex(value).range(
            of: "^#[0-9A-F]{6}$",
            options: .regularExpression
        ) != nil
    }

    private static func normalizedHex(_ value: String) -> String {
        let trimmed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        return trimmed.hasPrefix("#") ? trimmed : "#\(trimmed)"
    }
}

enum CategoryHierarchyCatalog {
    static let defaultMiddleSuggestions = [
        "준비", "진행", "정리", "기록",
    ]

    static let middleSuggestionsByCategoryID: [String: [String]] = [
        "movement": [
            "도보", "러닝", "달리기", "자전거", "차량", "버스", "지하철", "전철",
        ],
        "location": [
            "집", "회사", "학교", "학원", "운동시설", "식당·카페",
        ],
        "activity": [
            "수면", "휴식", "이동", "업무", "생활", "샤워", "청소", "미확인", "활동",
        ],
        "photo": [
            "일상", "사람", "장소", "음식", "기록", "작품",
        ],
        "project": [
            "기획", "회의", "제작", "문서", "검토", "운영",
        ],
        "exercise": [
            "달리기", "사이클", "등산", "산책", "근력", "수영", "구기", "스트레칭",
        ],
        "study": [
            "수업", "복습", "과제", "시험", "자격증", "독서",
        ],
        "hobby": [
            "음악", "게임", "만들기", "관람", "수집", "동호회",
        ],
        "sleep": [
            "밤잠", "낮잠", "취침 준비", "수면 회복",
        ],
        "routine": [
            "취침", "출근", "업무", "학업", "취미", "운동", "퇴근", "아침", "점심", "저녁",
        ],
        "relationship": [
            "가족", "친구", "연인", "동료", "모임", "육아",
        ],
        "rest": [
            "휴식", "산책", "명상", "영상", "음악", "아무것도 안 하기",
        ],
        "travel": [
            "계획", "예약", "이동", "관광", "숙소", "식사",
        ],
        "health": [
            "진료", "약", "재활", "검사", "건강관리", "영양",
        ],
        "event": [
            "기념일", "공연", "전시", "모임", "행사 준비", "경조사",
        ],
        "work": [
            "회의", "집중업무", "문서", "결재", "출장", "당직", "정산",
        ],
        "family": [
            "가족 일정", "병원", "식사", "돌봄", "모임", "기념일",
        ],
        "parenting": [
            "수유", "목욕", "이유식", "등하원", "검진", "놀이·발달",
        ],
        "finance": [
            "예산", "지출", "저축", "투자", "세금", "정산",
        ],
        "housing": [
            "청소", "정리", "수리", "계약", "관리비", "이사",
        ],
        "career": [
            "자격증", "취업", "이직", "포트폴리오", "면접", "네트워킹",
        ],
        "creative": [
            "기획", "촬영", "제작", "리허설", "공연", "전시",
        ],
        "pet": [
            "산책", "식사", "놀이", "미용", "병원", "훈련",
        ],
        "community": [
            "봉사", "동호회", "모임", "운영", "준비", "회고",
        ],
        "student": [
            "수업", "과제", "동아리", "시험", "통학", "생활관리",
        ],
        "exam": [
            "기출", "모의고사", "오답", "암기", "강의", "컨디션",
        ],
        "military": [
            "근무", "훈련", "정비", "점호", "휴가", "체력관리",
        ],
        "athlete": [
            "훈련", "경기", "회복", "식단", "전술", "기록분석",
        ],
        "pregnancy": [
            "진료", "운동", "영양", "약복용", "검사", "스트레스관리",
        ],
        "caregiver": [
            "돌봄", "병원", "식사", "복약", "동행", "휴식",
        ],
        "government": [
            "민원", "보고", "회의", "결재", "현장", "교육",
        ],
        "food": [
            "식사", "장보기", "요리", "영양", "기록", "외식",
        ],
    ]

    static let subSuggestionsByCategoryID: [String: [String: [String]]] = [
        "routine": [
            "취침": [
                "취침", "취침 준비", "기상", "낮잠",
            ],
            "출근": [
                "도보", "자동차", "버스", "지하철", "전철", "기타 이동",
            ],
            "아침": [
                "기상", "아침 식사", "산책", "준비",
            ],
            "점심": [
                "점심 식사", "휴식", "외출", "이동",
            ],
            "저녁": [
                "저녁 식사", "정리", "휴식", "산책",
            ],
            "업무": [
                "회의", "문서", "집중", "보고", "일정",
            ],
            "학업": [
                "수업", "과제", "복습", "시험", "자료 정리",
            ],
            "취미": [
                "영화", "게임", "독서", "동호회", "관람",
            ],
            "운동": [
                "걷기운동", "달리기", "자전거", "근력운동", "요가", "스트레칭",
            ],
            "퇴근": [
                "도보", "자동차", "버스", "지하철", "전철", "기타 이동",
            ],
        ],
        "activity": [
            "수면": [
                "깊은 수면", "코어수면", "회복 수면", "야간 수면", "낮잠",
            ],
            "휴식": [
                "정지", "샤워", "목욕", "명상", "짧은 휴식",
            ],
            "이동": [
                "걷기", "달리기", "자전거", "자동차", "버스", "지하철",
            ],
            "업무": [
                "연락", "문서", "회의", "처리", "기획",
            ],
            "생활": [
                "청소", "요리", "정리", "빨래", "세탁",
            ],
            "샤워": [
                "샤워", "목욕", "모발", "피부 관리",
            ],
            "청소": [
                "물걸레", "청소기", "정리", "거주 공간 정리",
            ],
            "미확인": [
                "분류 대기", "상태 확인", "추정 정리",
            ],
            "활동": [
                "메모", "기록", "연결", "임시 분류",
            ],
        ],
    ]

    private static let fallbackSubSuggestions = [
        "추가", "기타", "기록", "임시",
    ]

    static func middleSuggestions(for categoryID: String) -> [String] {
        middleSuggestionsByCategoryID[categoryID]
            ?? defaultMiddleSuggestions
    }

    static func subSuggestions(
        for categoryID: String,
        middleName: String?
    ) -> [String] {
        let key = middleName?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty,
              let mapping = subSuggestionsByCategoryID[categoryID] else {
            return fallbackSubSuggestions
        }
        return mapping[key] ?? fallbackSubSuggestions
    }
}

enum CategoryError: Error, Equatable {
    case emptyName
    case duplicateName
    case invalidColor
    case categoryMissing
    case replacementMissing
    case sameReplacement
    case builtInCannotDelete
}

struct CategoryDeletionResult: Sendable {
    var categories: [CategoryDefinition]
    var plans: [PlanRecord]
    var actuals: [ActualRecord]
}


actor FeatureSettingsStore {
    private let defaults: UserDefaults
    private let key = "taption.feature-settings.v1"

    init(suiteName: String? = nil) {
        self.defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    func load() -> AppFeatureSettings {
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(AppFeatureSettings.self, from: data) else {
            return .defaults
        }
        return value
    }

    func save(_ settings: AppFeatureSettings) throws {
        defaults.set(try JSONEncoder().encode(settings), forKey: key)
    }

    func reset() {
        defaults.removeObject(forKey: key)
    }
}
