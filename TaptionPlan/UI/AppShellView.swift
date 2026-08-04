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
        .sheet(item: $model.floorCalibrationPrompt) { prompt in
            FloorCalibrationPromptSheet(model: model, prompt: prompt)
        }
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

private struct FloorCalibrationPromptSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let prompt: FloorCalibrationPrompt

    @State private var selectedPlaceID: UUID
    @State private var selectedFloor: Int

    init(model: AppModel, prompt: FloorCalibrationPrompt) {
        self.model = model
        self.prompt = prompt
        _selectedPlaceID = State(initialValue: prompt.placeID)
        _selectedFloor = State(
            initialValue: prompt.suggestedFloor == 0
                ? 1
                : prompt.suggestedFloor
        )
    }

    private var availablePlaces: [FrequentPlace] {
        model.snapshot.settings.frequentPlaces.filter { $0.point != nil }
    }

    private var floors: [Int] {
        Array(-20 ... -1) + Array(1 ... 200)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(
                        "\(prompt.measuredAltitudeMeters, format: .number.precision(.fractionLength(1)))m 고도가 감지되었습니다."
                    )
                    .foregroundStyle(Color.tpSecondary)
                } header: {
                    Text("층수 보정이 필요합니다")
                }

                Section("보정할 위치") {
                    if availablePlaces.isEmpty {
                        Text("설정된 위치가 없습니다")
                            .foregroundStyle(Color.tpSecondary)
                    } else {
                        Picker("위치", selection: $selectedPlaceID) {
                            ForEach(availablePlaces) { place in
                                Label(
                                    place.name,
                                    systemImage: place.kind.systemImage
                                )
                                    .tag(place.id)
                            }
                        }
                    }
                }

                Section("감지된 층수") {
                    Picker("층수", selection: $selectedFloor) {
                        ForEach(floors, id: \.self) { floor in
                            Text(floor < 0 ? "지하 \(-floor)층" : "\(floor)층")
                                .tag(floor)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(height: 130)
                }
            }
            .navigationTitle(prompt.placeName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("나중에") {
                        model.dismissFloorCalibrationPrompt()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        saveCalibration()
                    }
                    .disabled(availablePlaces.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func saveCalibration() {
        guard availablePlaces.contains(where: { $0.id == selectedPlaceID }) else {
            return
        }
        model.addFrequentPlaceFloorCalibration(
            selectedPlaceID,
            floor: selectedFloor
        )
        if model.floorCalibrationPrompt == nil {
            dismiss()
        }
    }
}

#Preview {
    AppShellView()
}
