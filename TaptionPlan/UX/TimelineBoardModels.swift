import Foundation

struct TimelineBoardDataIndex {
    let childCounts: [UUID: Int]
    let parentPlanIDs: Set<UUID>
    let categoryNames: [String: String]

    init(
        plans: [PlanRecord],
        categories: [CategoryDefinition]
    ) {
        let parentIDs = plans.compactMap(\.parentID)
        childCounts = Dictionary(
            parentIDs.map { ($0, 1) },
            uniquingKeysWith: +
        )
        parentPlanIDs = Set(parentIDs)
        categoryNames = Dictionary(
            categories.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
    }
}

struct PlanCategoryPathKey: Hashable {
    let categoryID: String
    let middleName: String?
    let subName: String?

    var isRoot: Bool {
        middleName == nil && subName == nil
    }

    var stableID: String {
        [
            categoryID,
            middleName ?? "_",
            subName ?? "_",
        ].joined(separator: "::")
    }
}

enum PlanCategoryPathPresentation {
    static func key(for plan: PlanRecord) -> PlanCategoryPathKey {
        PlanCategoryPathKey(
            categoryID: plan.categoryID,
            middleName: normalizedPart(plan.middleCategoryName),
            subName: normalizedPart(plan.subCategoryName)
        )
    }

    static func title(
        categoryName: String,
        key: PlanCategoryPathKey
    ) -> String {
        parts(categoryName: categoryName, key: key)
            .joined(separator: "\n")
    }

    static func detail(
        categoryName: String,
        key: PlanCategoryPathKey
    ) -> String {
        parts(categoryName: categoryName, key: key)
            .joined(separator: " › ")
    }

    static func isOrderedBefore(
        _ lhs: PlanCategoryPathKey,
        _ rhs: PlanCategoryPathKey,
        categoryName: String,
        plansBeforeRoot: Bool = false
    ) -> Bool {
        if lhs.isRoot != rhs.isRoot {
            return plansBeforeRoot ? rhs.isRoot : lhs.isRoot
        }
        return detail(categoryName: categoryName, key: lhs)
            < detail(categoryName: categoryName, key: rhs)
    }

    private static func normalizedPart(_ value: String?) -> String? {
        let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean?.isEmpty == false ? clean : nil
    }

    private static func parts(
        categoryName: String,
        key: PlanCategoryPathKey
    ) -> [String] {
        [categoryName, key.middleName, key.subName].compactMap { $0 }
    }
}
