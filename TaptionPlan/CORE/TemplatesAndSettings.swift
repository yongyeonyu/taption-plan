import Foundation

enum CategoryCatalog {
    static let builtIn: [CategoryDefinition] = [
        category("movement", "이동", .travel, "#E8D3B3", "#A87A3D", "#C58C35", 0),
        category("location", "위치", .location, "#D5EAF5", "#4F87A7", "#4E9BC4", 1),
        category("photo", "사진", .photo, "#EADDF3", "#8754A9", "#965CB9", 2),
        category("project", "프로젝트", .briefcase, "#BEDAE3", "#4E8EA8", "#4E9CB8", 3),
        category("exercise", "운동", .exercise, "#FED5CF", "#B4584D", "#E46252", 4),
        category("study", "학습", .book, "#D3C7E6", "#7654A4", "#805BB1", 5),
        category("hobby", "취미", .music, "#C4E9DA", "#477F69", "#4B9879", 6),
        category("sleep", "수면", .sleep, "#C9D6E5", "#536F91", "#5B7EA8", 7),
        category("routine", "생활", .home, "#F7E8B4", "#A98118", "#B58A12", 8),
        category("relationship", "관계", .family, "#F9D9E1", "#A75B70", "#B9617B", 9),
        category("rest", "휴식", .nature, "#E3E4E8", "#696D77", "#777C88", 10),
        category("travel", "여행", .travel, "#CDE8F1", "#407F98", "#3F91AE", 11),
        category("health", "건강", .health, "#D4E7D1", "#4D7A49", "#568D51", 12)
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

enum TemplateError: Error, Equatable {
    case roleMissing
    case tooManySituations
    case tooManyGoals
    case unknownComponent(String)
}

enum TemplateCatalog {
    static let roles: [ProfileComponent] = [
        component(
            "student", .role, "학생",
            ["study", "movement", "relationship", "hobby", "exercise", "sleep"],
            ["study": "학업"],
            ["수업", "과제", "시험", "발표", "동아리", "알바"],
            [.calendar: true, .health: false],
            ["학업과 휴식"]
        ),
        component(
            "employee", .role, "회사원",
            ["project", "movement", "health", "relationship", "rest", "sleep"],
            ["project": "업무"],
            ["회의", "집중업무", "보고서", "출장", "출퇴근"],
            [.calendar: true, .health: false],
            ["업무와 회복"]
        ),
        component(
            "public-servant", .role, "공무원",
            ["project", "movement", "study", "health", "rest", "sleep"],
            ["project": "행정업무", "study": "교육"],
            ["문서", "결재", "민원", "현장 점검", "교육", "당직"],
            [.calendar: true, .location: false],
            ["행정·현장 시간"]
        ),
        component(
            "military", .role, "군인",
            ["project", "exercise", "routine", "movement", "sleep", "rest"],
            ["project": "근무", "exercise": "훈련"],
            ["당직", "교육훈련", "체력단련", "개인정비", "외출·휴가"],
            [.location: false, .calendar: false, .cloud: false],
            ["근무와 회복"]
        ),
        component(
            "athlete", .role, "운동선수",
            ["exercise", "health", "sleep", "routine", "travel", "rest"],
            ["exercise": "훈련", "routine": "식사"],
            ["기술훈련", "웨이트", "재활", "경기", "원정"],
            [.health: true, .calendar: true],
            ["훈련과 회복"]
        ),
        component(
            "performer", .role, "연예·공연",
            ["project", "movement", "health", "rest", "travel", "sleep"],
            ["project": "작품·활동"],
            ["콜타임", "분장", "리허설", "촬영", "녹음", "공연"],
            [.location: false, .calendar: false, .cloud: false],
            ["활동과 대기"]
        ),
        component(
            "freelancer", .role, "프리랜서·창작자",
            ["project", "health", "routine", "relationship", "rest", "sleep"],
            ["project": "창작·프로젝트"],
            ["작업", "미팅", "영업", "정산", "콘텐츠 제작"],
            [.calendar: true],
            ["창작과 생활"]
        ),
        component(
            "owner", .role, "자영업자",
            ["project", "routine", "health", "relationship", "sleep", "rest"],
            ["project": "영업·운영"],
            ["오픈", "마감", "발주", "재고", "정산", "고객 응대"],
            [.calendar: true],
            ["영업과 회복"]
        ),
        component(
            "shift-worker", .role, "교대·현장직",
            ["project", "movement", "health", "sleep", "rest", "routine"],
            ["project": "근무"],
            ["주간근무", "야간근무", "인수인계", "회복"],
            [.calendar: true, .health: true],
            ["근무·수면 리듬"]
        ),
        component(
            "caregiver", .role, "육아·가사",
            ["routine", "relationship", "health", "movement", "rest", "sleep"],
            ["routine": "돌봄·생활"],
            ["등하원", "병원", "식사", "집안일", "가족 일정"],
            [.calendar: true, .health: false],
            ["돌봄과 개인 회복"]
        )
    ]

    static let situations: [ProfileComponent] = [
        situation(
            "parenting", "육아",
            ["routine", "relationship", "movement", "health", "rest", "sleep"],
            ["routine": "돌봄"],
            ["등하원", "수유", "병원", "가족 일정", "개인 회복"],
            [.calendar: true],
            ["업무·돌봄 균형"]
        ),
        situation(
            "pregnancy", "임신·출산",
            ["health", "rest", "exercise", "routine"],
            ["health": "진료·회복"],
            ["진료", "휴식", "운동", "출산 준비", "회복"],
            [.health: false, .cloud: false],
            ["건강과 회복"]
        ),
        situation(
            "family-care", "가족돌봄·간병",
            ["health", "relationship", "movement", "rest"],
            [:],
            ["병원", "약", "이동", "돌봄 교대", "휴식"],
            [.cloud: false, .location: false],
            ["돌봄과 휴식"]
        ),
        situation(
            "rehabilitation", "치료·재활",
            ["health", "exercise", "sleep", "rest"],
            ["exercise": "재활운동"],
            ["진료", "약", "재활운동", "통증 메모", "수면"],
            [.health: true, .cloud: false],
            ["회복 추세"]
        ),
        situation(
            "job-change", "취업·이직",
            ["project", "study", "relationship", "rest"],
            ["project": "지원·준비"],
            ["지원", "포트폴리오", "면접", "학습", "네트워킹"],
            [.calendar: true],
            ["지원 단계와 준비시간"]
        ),
        situation(
            "startup", "창업준비",
            ["project", "study", "relationship", "rest"],
            ["project": "창업"],
            ["제품", "고객 인터뷰", "행정", "자금", "영업"],
            [.calendar: true],
            ["본업과 창업 충돌"]
        ),
        situation(
            "night-shift", "교대·야간",
            ["project", "sleep", "health", "routine", "rest"],
            [:],
            ["야간근무", "이동", "수면", "식사", "회복"],
            [.health: true],
            ["근무·수면 리듬"]
        ),
        situation(
            "leave", "휴직·방학",
            ["rest", "study", "travel", "routine", "health"],
            [:],
            ["회복", "학습", "여행", "생활 재정비"],
            [:],
            ["생활 균형"]
        ),
        situation(
            "relocation", "이사·정착",
            ["project", "movement", "routine", "rest"],
            ["project": "이사"],
            ["계약", "짐", "행정", "이동", "생활 기반"],
            [.location: false, .cloud: false],
            ["정착 진행"]
        ),
        situation(
            "long-trip", "장기출장·여행",
            ["travel", "movement", "project", "rest", "sleep"],
            [:],
            ["이동", "예약", "업무", "시차", "휴식"],
            [.calendar: true],
            ["이동과 휴식"]
        ),
        situation(
            "retirement", "은퇴·전환기",
            ["health", "relationship", "hobby", "study", "rest"],
            [:],
            ["건강", "관계", "취미", "봉사", "학습"],
            [.health: false],
            ["생활 균형"]
        ),
        situation(
            "side-job", "부업·투잡",
            ["project", "movement", "routine", "rest", "sleep"],
            ["project": "본업·부업"],
            ["본업", "부업", "이동", "정산", "휴식"],
            [.calendar: true],
            ["역할별 시간과 과로"]
        )
    ]

    static let goals: [ProfileComponent] = [
        goal("exam-suneung", "수능", ["study", "health", "rest", "sleep"], ["study": "수험"], ["수업", "과목 공부", "기출", "모의고사"]),
        goal("certificate", "자격증", ["study", "health", "rest"], [:], ["강의", "문제풀이", "복습", "시험"]),
        goal("employment", "취업", ["project", "study", "relationship"], ["project": "취업 준비"], ["지원", "포트폴리오", "면접"]),
        goal("career-change", "이직", ["project", "study", "relationship"], ["project": "이직 준비"], ["지원", "면접", "네트워킹"]),
        goal("business", "창업", ["project", "study", "relationship"], ["project": "창업"], ["제품", "고객 인터뷰", "행정"]),
        goal("competition", "대회", ["exercise", "health", "travel"], ["exercise": "대회 준비"], ["훈련", "리허설", "대회"]),
        goal("trip-prep", "여행 준비", ["travel", "project", "movement"], [:], ["예약", "짐", "이동"]),
        goal("wedding", "결혼 준비", ["project", "relationship", "routine"], ["project": "결혼 준비"], ["예약", "미팅", "가족 일정"]),
        goal("moving", "이사", ["project", "movement", "routine"], ["project": "이사"], ["계약", "짐", "행정"])
    ]

    static let representativeSelections: [ProfileSelection] = [
        ProfileSelection(roleID: "employee", situationIDs: ["parenting"]),
        ProfileSelection(roleID: "student", goalIDs: ["exam-suneung"]),
        ProfileSelection(roleID: "employee", goalIDs: ["certificate"])
    ]

    static func apply(_ selection: ProfileSelection) throws -> TemplateApplication {
        guard let role = roles.first(where: { $0.id == selection.roleID }) else {
            throw TemplateError.roleMissing
        }
        guard selection.situationIDs.count <= 2 else {
            throw TemplateError.tooManySituations
        }
        guard selection.goalIDs.count <= 2 else {
            throw TemplateError.tooManyGoals
        }

        let selectedSituations = try selection.situationIDs.map { id in
            guard let value = situations.first(where: { $0.id == id }) else {
                throw TemplateError.unknownComponent(id)
            }
            return value
        }
        let selectedGoals = try selection.goalIDs.map { id in
            guard let value = goals.first(where: { $0.id == id }) else {
                throw TemplateError.unknownComponent(id)
            }
            return value
        }
        let components = [role] + selectedSituations + selectedGoals

        var categories: [String] = []
        var displayNames: [String: String] = [:]
        var quickAdds: [String] = []
        var permissions: [PermissionFeature: Bool] = [:]
        var reviewFocus: [String] = []

        for component in components {
            appendUnique(component.categoryIDs, to: &categories)
            displayNames.merge(component.categoryDisplayNames) { _, new in new }
            appendUnique(component.quickAdds, to: &quickAdds)
            for (feature, enabled) in component.suggestedPermissions {
                if permissions[feature] == false { continue }
                permissions[feature] = enabled
            }
            appendUnique(component.reviewFocus, to: &reviewFocus)
        }

        let suffixNames = (selectedSituations + selectedGoals).map(\.name)
        let displayName = ([role.name] + suffixNames).joined(separator: " + ")
        return TemplateApplication(
            selection: selection,
            displayName: displayName,
            visibleCategoryIDs: categories,
            categoryDisplayNames: displayNames,
            quickAdds: quickAdds,
            suggestedPermissions: permissions,
            reviewFocus: reviewFocus
        )
    }

    static func makeGoalPlans(
        for selection: ProfileSelection,
        startingAt date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) throws -> [PlanRecord] {
        let selectedGoals = try selection.goalIDs.map { id in
            guard let goal = goals.first(where: { $0.id == id }) else {
                throw TemplateError.unknownComponent(id)
            }
            return goal
        }
        let end = calendar.date(byAdding: .year, value: 1, to: date)
            ?? date.addingTimeInterval(365 * 86_400)
        return selectedGoals.map { goal in
            PlanRecord(
                title: goal.name,
                span: TimeSpan(start: date, end: end),
                categoryID: goal.categoryIDs.first ?? "project",
                isImportant: true
            )
        }
    }

    private static func component(
        _ id: String,
        _ kind: ProfileComponentKind,
        _ name: String,
        _ categories: [String],
        _ names: [String: String],
        _ quickAdds: [String],
        _ permissions: [PermissionFeature: Bool],
        _ review: [String]
    ) -> ProfileComponent {
        ProfileComponent(
            id: id,
            kind: kind,
            name: name,
            categoryIDs: categories,
            categoryDisplayNames: names,
            quickAdds: quickAdds,
            suggestedPermissions: permissions,
            reviewFocus: review
        )
    }

    private static func situation(
        _ id: String,
        _ name: String,
        _ categories: [String],
        _ names: [String: String],
        _ quickAdds: [String],
        _ permissions: [PermissionFeature: Bool],
        _ review: [String]
    ) -> ProfileComponent {
        component(id, .situation, name, categories, names, quickAdds, permissions, review)
    }

    private static func goal(
        _ id: String,
        _ name: String,
        _ categories: [String],
        _ names: [String: String],
        _ quickAdds: [String]
    ) -> ProfileComponent {
        component(id, .goal, name, categories, names, quickAdds, [:], ["\(name) 준비시간"])
    }

    private static func appendUnique<T: Hashable>(
        _ values: [T],
        to result: inout [T]
    ) {
        var seen = Set(result)
        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
    }
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
