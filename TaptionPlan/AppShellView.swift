import SwiftUI

struct AppShellView: View {
    @State private var model = AppModel()

    var body: some View {
        NavigationStack {
            rootContent
                .toolbar(.hidden, for: .navigationBar)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BottomNavigationBar(model: model)
        }
        .sheet(isPresented: $model.isAddPlanPresented) {
            AddPlanSheet()
        }
        .tint(.tpInk)
    }

    @ViewBuilder
    private var rootContent: some View {
        switch model.selectedTab {
        case .schedule:
            ScheduleView(model: model)
        case .goals:
            GoalsView()
        case .review:
            ReviewView()
        case .settings:
            SettingsView()
        }
    }
}

private struct BottomNavigationBar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            tabButton(.schedule)
            tabButton(.goals)

            Button {
                model.isAddPlanPresented = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(Color.tpInk, in: Circle())
                    .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
                    .accessibilityLabel("계획 추가")
            }
            .frame(maxWidth: .infinity)
            .offset(y: -8)

            tabButton(.review)
            tabButton(.settings)
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private func tabButton(_ tab: RootTab) -> some View {
        Button {
            model.selectedTab = tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 19, weight: model.selectedTab == tab ? .semibold : .regular))
                Text(tab.rawValue)
                    .font(.caption2)
            }
            .foregroundStyle(model.selectedTab == tab ? Color.tpInk : Color.tpSecondary)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(model.selectedTab == tab ? .isSelected : [])
    }
}

#Preview {
    AppShellView()
        .modelContainer(for: PlanItem.self, inMemory: true)
}
