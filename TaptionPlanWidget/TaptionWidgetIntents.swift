import ActivityKit
import AppIntents
import OSLog
import SwiftUI
import TaptionPlanCore
import WidgetKit

struct TaptionWidgetActionIntent: AppIntent {
    static let title: LocalizedStringResource = "Taption 계획 처리"
    static let description = IntentDescription("위젯에서 계획을 완료하거나 이동합니다.")
    static let openAppWhenRun = false

    @Parameter(title: "계획 ID")
    var planID: String

    @Parameter(title: "동작")
    var actionRawValue: String

    init() {
        planID = ""
        actionRawValue = TaptionWidgetCommandKind.complete.rawValue
    }

    init(planID: String, action: TaptionWidgetCommandKind) {
        self.planID = planID
        actionRawValue = action.rawValue
    }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: planID),
              let action = TaptionWidgetCommandKind(rawValue: actionRawValue) else {
            return .result()
        }

        try await TaptionWidgetCommandRunner.run(
            TaptionWidgetCommand(planID: id, kind: action)
        )
        return .result()
    }
}

struct TaptionWidgetLocationTrackingIntent: AppIntent {
    static let title: LocalizedStringResource = "이동 위치 트래킹"
    static let description = IntentDescription("아이폰의 이동 위치 기록을 켜거나 끕니다.")
    static let openAppWhenRun = true

    @Parameter(title: "켜기")
    var enabled: Bool

    init() {
        enabled = false
    }

    init(enabled: Bool) {
        self.enabled = enabled
    }

    func perform() async throws -> some IntentResult {
        TaptionLocationTrackingRequestStore.write(enabled)
        if let repository = try? TaptionStoreRepository.appGroup(),
           var snapshot = try? await repository.load() {
            snapshot.settings.locationEnabled = enabled
            if !enabled {
                snapshot.settings.backgroundPreciseLocationEnabled = false
            }
            snapshot.updatedAt = .now
            if (try? await repository.save(snapshot)) != nil {
                let payload = TaptionWidgetPayloadFactory.make(
                    from: snapshot,
                    hidesSensitiveContent: TaptionExternalPrivacyStore.isLocked
                )
                try? TaptionWidgetSharedStore.writePayload(payload)
            }
        }
        WidgetCenter.shared.reloadTimelines(ofKind: TaptionWidgetKind.schedule)
        return .result()
    }
}

struct TaptionWidgetLocationGuidanceIntent: AppIntent {
    static let title: LocalizedStringResource = "GPS 트래킹 권한 안내"
    static let description = IntentDescription("아이폰에서 위치 권한 안내를 다시 엽니다.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        TaptionLocationTrackingRequestStore.requestGuidance()
        return .result()
    }
}
