import SwiftUI

struct AppShellView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel()

    var body: some View {
        NavigationStack {
            content
                .toolbar(.hidden, for: .navigationBar)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.showsBottomBar {
                DraftBottomNavigationBar(model: model)
            }
        }
        .sheet(isPresented: $model.isAddPlanPresented) {
            AddPlanSheet(model: model)
        }
        .sheet(item: $model.selectedAction) { item in
            QuickActionSheet(model: model, item: item)
        }
        .sheet(item: $model.planEditorRequest) { request in
            PlanEditorSheet(model: model, planID: request.id)
        }
        .sheet(isPresented: $model.isPermissionOnboardingPresented) {
            PermissionOnboardingSheet(model: model)
                .interactiveDismissDisabled()
        }
        .font(.taption(size: 17))
        .tint(.tpInk)
        .preferredColorScheme(.light)
        .task {
            await model.sceneBecameActive()
            model.presentPermissionOnboardingIfNeeded()
            if let planID = TaptionPlanAppDelegate.takePendingPlanID(),
               let url = URL(
                    string: "taptionplan://plan/\(planID.uuidString)"
               ) {
                await model.openDeepLink(url)
            }
        }
        .onOpenURL { url in
            Task { @MainActor in
                await model.bootstrap()
                await model.openDeepLink(url)
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .taptionPlanOpenNotificationPlan
            )
        ) { notification in
            let planID =
                TaptionPlanAppDelegate.takePendingPlanID()
                ?? notification.object as? UUID
            guard let planID,
                  let url = URL(
                    string: "taptionplan://plan/\(planID.uuidString)"
                  ) else {
                return
            }
            Task { @MainActor in
                await model.bootstrap()
                await model.openDeepLink(url)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            Task {
                switch phase {
                case .active:
                    await model.sceneBecameActive()
                case .background:
                    await model.sceneEnteredBackground()
                case .inactive:
                    break
                @unknown default:
                    break
                }
            }
        }
        .alert(
            "확인해 주세요",
            isPresented: Binding(
                get: { model.userFacingError != nil },
                set: { if !$0 { model.clearError() } }
            )
        ) {
            Button("확인") { model.clearError() }
        } message: {
            Text(model.userFacingError ?? "")
        }
        .overlay(alignment: .top) {
            if let notice = model.floorCalibrationNotice {
                Text(notice)
                    .font(.taption(size: 14))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        Capsule().fill(Color.tpInk.opacity(0.92))
                    )
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(
            .easeInOut(duration: 0.25),
            value: model.floorCalibrationNotice
        )
    }

    @ViewBuilder
    private var content: some View {
        if let detail = model.detail {
            switch detail {
            case .group:
                GroupGanttView(model: model)
            case .goal:
                GoalDetailView(model: model)
            case .actual(let recordID):
                ActualRecordDetailView(model: model, recordID: recordID)
            case .locationTimeline:
                LocationTimelineView(model: model)
            case .memo:
                MemoDetailView(model: model)
            case .inference:
                InferenceDetailView(model: model)
            case .catPicker:
                CatPickerView(model: model)
            case .categoryManager:
                CategoryManagerView(model: model)
            case .categorySetup:
                CategorySetupView(model: model)
            case .widgetPreview:
                WidgetPreviewView(model: model)
            }
        } else {
            rootContent
        }
    }

    @ViewBuilder
    private var rootContent: some View {
        switch model.selectedTab {
        case .schedule:
            ScheduleView(model: model)
        case .goals:
            GoalsView(model: model)
        case .review:
            ReviewView(model: model)
        case .settings:
            SettingsView(model: model)
        }
    }
}

private struct PermissionOnboardingStep: Identifiable {
    let feature: PermissionFeature
    let icon: String
    let title: String
    let detail: String

    var id: String { feature.rawValue }
}

struct PermissionOnboardingSheet: View {
    @Bindable var model: AppModel
    @State private var index = 0
    @State private var skipped: Set<String> = []

    private static let steps: [PermissionOnboardingStep] = [
        PermissionOnboardingStep(
            feature: .location,
            icon: "mappin.and.ellipse",
            title: "위치 · 이동",
            detail: "머문 장소와 이동 경로를 자동으로 남깁니다. ‘항상 허용’이어야 앱을 닫은 뒤에도 기록됩니다."
        ),
        PermissionOnboardingStep(
            feature: .health,
            icon: "heart.text.square",
            title: "건강 · Apple Watch",
            detail: "걸음·운동·수면을 건강 앱과 Apple Watch에서 읽어옵니다."
        ),
        PermissionOnboardingStep(
            feature: .calendar,
            icon: "calendar",
            title: "캘린더",
            detail: "이미 잡혀 있는 일정을 시간표에 함께 보여줍니다."
        ),
        PermissionOnboardingStep(
            feature: .photos,
            icon: "photo",
            title: "사진",
            detail: "촬영 시각에 맞춰 하루를 되짚을 수 있습니다."
        ),
        PermissionOnboardingStep(
            feature: .notifications,
            icon: "bell.badge",
            title: "알림",
            detail: "계획한 시각에 맞춰 알려줍니다."
        ),
        PermissionOnboardingStep(
            feature: .appUsage,
            icon: "app.badge.clock",
            title: "앱 사용시간",
            detail: "시간대별 앱 사용 기록을 시간표에 더합니다."
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(showsIndicators: false) {
                VStack(spacing: 9) {
                    ForEach(
                        Array(Self.steps.enumerated()),
                        id: \.element.id
                    ) { offset, step in
                        stepCard(step, offset: offset)
                    }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 12)
            }
            footer
        }
        .background(Color.tpBackground)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("하루는 알아서 기록됩니다")
                .font(.taption(size: 15, weight: .black))
                .foregroundStyle(Color.tpInk)
            Text("Taption Plan은 위치·건강·캘린더·사진·앱 사용시간을 읽어 하루를 대신 적습니다. 필요한 것만 허용해도 되고, 설정에서 언제든 바꿀 수 있습니다.")
                .font(.taption(size: 9))
                .foregroundStyle(Color.tpSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.white)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if isFinished {
                Button("시작하기") { finish() }
                    .font(.taption(size: 11, weight: .bold))
                    .buttonStyle(.borderedProminent)
                    .tint(Color.tpInk)
                    .frame(maxWidth: .infinity)
            } else {
                Button("전체 건너뛰기") { finish() }
                    .font(.taption(size: 10, weight: .bold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.tpSecondary)
                Spacer(minLength: 4)
                Text("\(index + 1) / \(Self.steps.count)")
                    .font(.taption(size: 9, weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.white)
    }

    private func stepCard(
        _ step: PermissionOnboardingStep,
        offset: Int
    ) -> some View {
        let isCurrent = offset == index
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: step.icon)
                    .font(.taption(size: 14))
                    .foregroundStyle(Color.tpInk)
                    .frame(width: 29, height: 29)
                    .background(
                        Color.tpBackground,
                        in: RoundedRectangle(cornerRadius: 9)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title)
                        .font(.taption(size: 11, weight: .bold))
                        .foregroundStyle(Color.tpInk)
                    Text(step.detail)
                        .font(.taption(size: 8))
                        .foregroundStyle(Color.tpSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Text(stateText(step))
                    .font(.taption(size: 8.5, weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
            }
            if isCurrent {
                HStack(spacing: 10) {
                    Button("허용하기") {
                        Task { await request(step) }
                    }
                    .font(.taption(size: 10, weight: .bold))
                    .buttonStyle(.borderedProminent)
                    .tint(Color.tpInk)
                    Button("건너뛰기") {
                        skipped.insert(step.id)
                        advance()
                    }
                    .font(.taption(size: 10, weight: .bold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.tpSecondary)
                }
                .disabled(model.isRefreshingIntegrations)
                .padding(.leading, 38)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .draftCard()
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    isCurrent ? Color.tpInk.opacity(0.32) : Color.clear,
                    lineWidth: 1
                )
        )
        .opacity(offset > index ? 0.5 : 1)
    }

    private var isFinished: Bool { index >= Self.steps.count }

    private func stateText(_ step: PermissionOnboardingStep) -> String {
        if skipped.contains(step.id) { return "나중에" }
        let state = model.permissionState(for: step.feature)
        return state == .notDetermined ? "" : state.settingsLabel
    }

    private func request(_ step: PermissionOnboardingStep) async {
        switch step.feature {
        case .location: await model.enableLocationCollection()
        case .health: await model.requestHealth()
        case .calendar: await model.requestCalendar()
        case .photos: await model.requestPhotos()
        case .notifications: await model.requestNotifications()
        case .appUsage: await model.requestAppUsageAuthorization()
        default: break
        }
        // 시트가 떠 있는 동안에는 루트 경고창이 뜨지 않는다. 결과는 각 줄의
        // 상태 문구로 보여주고 안내 문구는 지운다.
        model.clearError()
        advance()
    }

    private func advance() {
        guard index < Self.steps.count else { return }
        index += 1
    }

    private func finish() {
        Task { await model.finishPermissionOnboarding() }
    }
}

#Preview {
    AppShellView()
}
