import Foundation
import TaptionPlanCore

// `ActivityCorrection`은 `TaptionPlanCore/Domain/ActivityCorrection.swift`에 있다.

struct ActivityCorrectionOption: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var behavior: String?
    var categoryID: String
    var systemImage: String
    var isAutomatic: Bool
    var isCustom: Bool
    var isAutomaticOnly: Bool

    init(
        id: String,
        title: String,
        behavior: String?,
        categoryID: String,
        systemImage: String,
        isAutomatic: Bool,
        isCustom: Bool,
        isAutomaticOnly: Bool = false
    ) {
        self.id = id
        self.title = title
        self.behavior = behavior
        self.categoryID = categoryID
        self.systemImage = systemImage
        self.isAutomatic = isAutomatic
        self.isCustom = isCustom
        self.isAutomaticOnly = isAutomaticOnly
    }

    var correction: ActivityCorrection {
        ActivityCorrection(
            title: title,
            behavior: behavior,
            categoryID: categoryID
        )
    }

    static func custom(_ title: String) -> ActivityCorrectionOption {
        let normalized = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let systemImage = normalized.contains("양치")
            || normalized.contains("brush")
            ? "toothbrush.fill"
            : "tag.fill"
        return ActivityCorrectionOption(
            id: "custom.\(title)",
            title: title,
            behavior: nil,
            categoryID: "activity",
            systemImage: systemImage,
            isAutomatic: false,
            isCustom: true,
            isAutomaticOnly: false
        )
    }
}

enum ActivityCorrectionEngine {
    static func replacingActivity(
        in existing: ActivityCorrection?,
        with option: ActivityCorrectionOption
    ) -> ActivityCorrection {
        var correction = option.correction
        correction.startedAt = existing?.startedAt
        correction.endedAt = existing?.endedAt
        return correction
    }

    static func applying(
        _ corrections: [UUID: ActivityCorrection],
        to actuals: [ActualRecord]
    ) -> [ActualRecord] {
        guard !corrections.isEmpty else { return actuals }
        return actuals.map { actual in
            guard let correction = corrections[actual.id] else { return actual }
            var value = actual
            value.title = correction.title
            value.behavior = correction.behavior
            value.categoryID = correction.categoryID
            if let startedAt = correction.startedAt {
                value.startedAt = startedAt
            }
            if let endedAt = correction.endedAt {
                value.endedAt = endedAt
            }
            value.manuallyCorrected = true
            return value
        }
    }
}
