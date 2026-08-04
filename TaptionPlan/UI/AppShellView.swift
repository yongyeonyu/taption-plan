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
        .font(.taption(size: 17))
        .tint(.tpInk)
        .preferredColorScheme(.light)
        .task {
            await model.sceneBecameActive()
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

#Preview {
    AppShellView()
}
