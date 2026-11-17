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
        guard isValidHex(lightHex),
              darkHex.map(isValidHex) ?? true,
              actualHex.map(isValidHex) ?? true else {
            throw CategoryError.invalidColor
        }
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
        let rank = Dictionary(
            orderedIDs.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
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
