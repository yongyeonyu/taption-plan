import Foundation
import TaptionPlanCore

// `ActivityCorrection`은 `TaptionPlanCore/Domain/ActivityCorrection.swift`에 있다.

public struct ActivityCorrectionOption: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var behavior: String?
    public var categoryID: String
    public var systemImage: String
    public var isAutomatic: Bool
    public var isCustom: Bool
    public var isAutomaticOnly: Bool

    public init(
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

    public var correction: ActivityCorrection {
        ActivityCorrection(
            title: title,
            behavior: behavior,
            categoryID: categoryID
        )
    }

    public static func custom(_ title: String) -> ActivityCorrectionOption {
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

public enum ActivityCorrectionEngine {
    public static func replacingActivity(
        in existing: ActivityCorrection?,
        with option: ActivityCorrectionOption
    ) -> ActivityCorrection {
        var correction = option.correction
        correction.startedAt = existing?.startedAt
        correction.endedAt = existing?.endedAt
        return correction
    }

    public static func applying(
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
