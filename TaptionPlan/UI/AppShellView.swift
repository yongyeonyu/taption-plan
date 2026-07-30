import SwiftUI

struct AppShellView: View {
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
            AddPlanSheet()
        }
        .sheet(item: $model.selectedAction) { item in
            QuickActionSheet(model: model, item: item)
        }
        .tint(.tpInk)
        .preferredColorScheme(.light)
    }

    @ViewBuilder
    private var content: some View {
        if let detail = model.detail {
            switch detail {
            case .group:
                GroupGanttView(model: model)
            case .locationTimeline:
                LocationTimelineView(model: model)
            case .memo:
                MemoDetailView(model: model)
            case .inference:
                InferenceDetailView(model: model)
            case .catPicker:
                CatPickerView(model: model)
            case .onboarding:
                OnboardingView(model: model)
            case .templateReview:
                TemplateReviewView(model: model)
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
        .modelContainer(for: PlanItem.self, inMemory: true)
}
