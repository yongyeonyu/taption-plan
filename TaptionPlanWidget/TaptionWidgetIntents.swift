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

        var command = TaptionWidgetCommand(planID: id, kind: action)
        var refreshedPayload: TaptionWidgetPayload?
        do {
            let repository = try TaptionStoreRepository.appGroup()
            let source = try await repository.load()
            let updated = try TaptionWidgetCommandEngine.apply(
                command,
                to: source
            )
            try await repository.save(updated)
            refreshedPayload = TaptionWidgetPayloadFactory.make(
                from: updated,
                hidesSensitiveContent: TaptionExternalPrivacyStore.isLocked
            )
            command.appliedToSharedRepository = true
        } catch {
            command.appliedToSharedRepository = false
        }

        if let refreshedPayload {
            try? TaptionWidgetSharedStore.writePayload(refreshedPayload)
        }
        try TaptionWidgetSharedStore.appendCommand(command)
        // 종료·완료는 시스템이 허락하면 여기서 바로 Live Activity를 끝내고, 앱도 명령을 받을 때 다시 끝낸다(REV1110A04).
        if action == .complete || action == .stopCurrentActivity {
            for activity in Activity<TaptionActivityAttributes>.activities where activity.attributes.planID == id {
                var state = activity.content.state
                state.isRunning = false
                state.endsAt = max(state.startedAt, min(.now, state.endsAt))
                await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .default)
            }
        }
        WidgetCenter.shared.reloadTimelines(ofKind: TaptionWidgetKind.schedule)
        WidgetCenter.shared.reloadAllTimelines()
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
