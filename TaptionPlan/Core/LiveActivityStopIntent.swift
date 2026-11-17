import ActivityKit
import AppIntents
import Foundation
import WidgetKit

/// 잠금 화면·다이나믹 아일랜드의 「종료」. `LiveActivityIntent`라 앱을 열지 않고 앱 프로세스에서
/// 바로 돈다. 앱 대상과 위젯 대상에 같이 넣어 시스템이 앱 쪽에서 실행한다(WLA1117A01).
struct TaptionLiveActivityStopIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Taption 활동 종료"
    static let description = IntentDescription("Live Activity의 지금 계획을 끝냅니다.")
    static let openAppWhenRun = false
    static let isDiscoverable = false

    @Parameter(title: "계획 ID")
    var planID: String

    init() {
        planID = ""
    }

    init(planID: String) {
        self.planID = planID
    }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: planID) else { return .result() }
        #if !TAPTION_WIDGET
        if await Self.stopInLiveApp(planID: id) { return .result() }
        #endif
        try await TaptionWidgetCommandRunner.run(
            TaptionWidgetCommand(planID: id, kind: .stopCurrentActivity)
        )
        return .result()
    }

    #if !TAPTION_WIDGET
    /// 떠 있는 앱 모델이 있으면 화면 버튼과 같은 길로 끝내 메모리·저장소·활동이 함께 바뀐다.
    @MainActor
    private static func stopInLiveApp(planID: UUID) async -> Bool {
        guard let model = AppModel.live, model.isBootstrapped,
              model.snapshot.plans.contains(where: { $0.id == planID }) else { return false }
        await model.performQuickAction(.stopCurrentActivity, planID: planID)
        return true
    }
    #endif
}

/// 위젯·Live Activity 명령을 공유 저장소에 바로 쓰고, 앱이 열릴 때 확인하도록 명령도 남긴다.
enum TaptionWidgetCommandRunner {
    static func run(_ command: TaptionWidgetCommand) async throws {
        var command = command
        var refreshedPayload: TaptionWidgetPayload?
        do {
            let repository = try TaptionStoreRepository.appGroup()
            let source = try await repository.load()
            let updated = try TaptionWidgetCommandEngine.apply(command, to: source)
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
        // 종료·완료는 여기서 바로 Live Activity를 끝내고, 앱도 명령을 받을 때 다시 끝낸다(REV1110A04).
        if command.kind == .complete || command.kind == .stopCurrentActivity {
            for activity in Activity<TaptionActivityAttributes>.activities
            where activity.attributes.planID == command.planID {
                var state = activity.content.state
                state.isRunning = false
                state.endsAt = max(state.startedAt, min(.now, state.endsAt))
                await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .default)
            }
        }
        WidgetCenter.shared.reloadAllTimelines()
    }
}
