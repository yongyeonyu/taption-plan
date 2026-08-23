import SwiftUI

struct AppShellView: View {
    private static let legacyUIEnabled = false

    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel()
    @State private var proAccess = TaptionProAccessController()
    @State private var showsMapHome = true
    @State private var isSecurityStateReady = false
    @State private var lockGeneration = 0
    @State private var automaticBiometricAttemptedGeneration: Int?
    @State private var isBiometricAuthenticationInFlight = false
    @State private var biometricPromptInterruptedScene = false

    var body: some View {
        NavigationStack {
            Group {
                if proAccess.grantsAccess {
                    content
                } else {
                    Color.tpSurface.ignoresSafeArea()
                }
            }
                .toolbar(.hidden, for: .navigationBar)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if Self.legacyUIEnabled && model.showsBottomBar && !showsMapHome {
                DraftBottomNavigationBar(model: model)
            }
        }
        .sheet(
            isPresented: Binding(
                get: { Self.legacyUIEnabled && model.isAddPlanPresented },
                set: { model.isAddPlanPresented = $0 }
            )
        ) {
            AddPlanSheet(model: model)
        }
        .sheet(
            item: Binding(
                get: { Self.legacyUIEnabled ? model.selectedAction : nil },
                set: { model.selectedAction = $0 }
            )
        ) { item in
            QuickActionSheet(model: model, item: item)
        }
        .sheet(
            item: Binding(
                get: { Self.legacyUIEnabled ? model.planEditorRequest : nil },
                set: { model.planEditorRequest = $0 }
            )
        ) { request in
            PlanEditorSheet(model: model, planID: request.id)
        }
        .sheet(
            isPresented: Binding(
                get: { Self.legacyUIEnabled && model.isPermissionOnboardingPresented },
                set: { model.isPermissionOnboardingPresented = $0 }
            )
        ) {
            PermissionOnboardingSheet(
                model: model,
                initialFeature: model.permissionOnboardingStartFeature
            )
                .interactiveDismissDisabled()
        }
        .font(.taption(size: 17))
        .tint(.tpInk)
        .preferredColorScheme(.light)
        .task {
            isSecurityStateReady = true
            await proAccess.refresh()
            if proAccess.grantsAccess {
                await model.sceneBecameActive()
            } else {
                await model.suspendForCommerceLock()
            }
            if model.isAppLocked {
                lockGeneration &+= 1
                automaticBiometricAttemptedGeneration = nil
            }
            if proAccess.grantsAccess {
                model.presentPermissionOnboardingIfNeeded()
            }
            if Self.legacyUIEnabled,
               let planID = TaptionPlanAppDelegate.takePendingPlanID(),
               let url = URL(
                    string: "taptionplan://plan/\(planID.uuidString)"
               ) {
                showsMapHome = false
                await model.openDeepLink(url)
            }
        }
        .onOpenURL { url in
            handleOpenURL(url)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .taptionPlanOpenNotificationPlan
            )
        ) { notification in
            handlePlanNotification(notification)
        }
        .onChange(of: scenePhase) { _, phase in
            handleScenePhaseChange(phase)
        }
        .onChange(of: proAccess.grantsAccess) { _, grantsAccess in
            Task { @MainActor in
                if grantsAccess {
                    await model.sceneBecameActive()
                    model.presentPermissionOnboardingIfNeeded()
                } else {
                    await model.suspendForCommerceLock()
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
            userFacingErrorMessage
        }
        .accessibilityHidden(shouldHidePrimaryContent)
        .overlay(alignment: .top) {
            floorCalibrationNotice
        }
        .overlay {
            securityOverlay
        }
        .animation(
            .easeInOut(duration: 0.25),
            value: model.floorCalibrationNotice
        )
    }

    private var userFacingErrorMessage: some View {
        let message = model.userFacingError ?? ""
        return Text(message)
    }

    private var shouldHideAppSnapshot: Bool {
        guard scenePhase != .active else { return false }
        let settings = model.securityStatus.settings
        return settings.lockOnForeground || settings.lockOnLaunch
    }

    private var shouldHidePrimaryContent: Bool {
        !isSecurityStateReady
            || model.isAppLocked
            || !proAccess.grantsAccess
            || shouldHideAppSnapshot
    }

    @ViewBuilder
    private var securityOverlay: some View {
        if !isSecurityStateReady || model.isAppLocked {
            MapHomeAppLockView(
                model: model,
                isCheckingInitialState: !isSecurityStateReady,
                lockGeneration: lockGeneration,
                automaticBiometricAttemptedGeneration: $automaticBiometricAttemptedGeneration,
                isBiometricAuthenticationInFlight: $isBiometricAuthenticationInFlight
            )
        } else if !proAccess.grantsAccess {
            TaptionProAccessView(
                controller: proAccess,
                allowsDismiss: false
            )
        } else if shouldHideAppSnapshot {
            Color.tpInk
                .ignoresSafeArea()
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var floorCalibrationNotice: some View {
        if let notice = model.floorCalibrationNotice {
            Text(notice)
                .font(.taption(size: 14))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Capsule().fill(Color.tpInk.opacity(0.92)))
                .padding(.top, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        let mustCoverBeforeForeground =
            phase == .active
            && model.securityStatus.settings.lockOnForeground
        if phase == .active, biometricPromptInterruptedScene {
            // Face ID can briefly drive the scene inactive/active while its
            // prompt is finishing. Treat that pair as part of the current
            // unlock generation; otherwise handleForeground() relocks the
            // app immediately after a successful authentication.
            biometricPromptInterruptedScene = false
            isSecurityStateReady = true
            return
        }
        if mustCoverBeforeForeground {
            isSecurityStateReady = false
            lockGeneration &+= 1
            automaticBiometricAttemptedGeneration = nil
        }
        if phase == .inactive, isBiometricAuthenticationInFlight {
            biometricPromptInterruptedScene = true
        }
        Task { @MainActor in
            switch phase {
            case .active:
                await proAccess.refresh()
                if proAccess.grantsAccess {
                    await model.sceneBecameActive()
                } else {
                    await model.suspendForCommerceLock()
                }
                isSecurityStateReady = true
            case .background:
                if proAccess.grantsAccess {
                    await model.sceneEnteredBackground()
                } else {
                    await model.suspendForCommerceLock()
                }
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }

    private func handleOpenURL(_ url: URL) {
        guard Self.legacyUIEnabled else { return }
        Task { @MainActor in
            showsMapHome = false
            await model.bootstrap()
            await model.openDeepLink(url)
        }
    }

    private func handlePlanNotification(_ notification: Notification) {
        guard Self.legacyUIEnabled else { return }
        let pendingID = TaptionPlanAppDelegate.takePendingPlanID()
        let planID = pendingID ?? (notification.object as? UUID)
        guard let planID,
              let url = URL(
                string: "taptionplan://plan/\(planID.uuidString)"
              ) else {
            return
        }
        handleOpenURL(url)
    }

    @ViewBuilder
    private var content: some View {
        if Self.legacyUIEnabled, let detail = model.detail {
            switch detail {
            case .group:
                GroupGanttView(model: model)
            case .goal:
                GoalDetailView(model: model)
            case .actual(let recordID):
                ActualRecordDetailView(model: model, recordID: recordID)
            case .actualEditor(let recordID):
                ActualRecordDetailView(
                    model: model,
                    recordID: recordID,
                    opensEditor: true
                )
            case .actualSegment(let recordID, let span):
                ActualRecordDetailView(
                    model: model,
                    recordID: recordID,
                    correctionSpan: span
                )
            case .actualSegmentEditor(let recordID, let span):
                ActualRecordDetailView(
                    model: model,
                    recordID: recordID,
                    correctionSpan: span,
                    opensEditor: true
                )
            case .unconfirmedEditor(let span):
                UnconfirmedRecordDetailView(model: model, span: span)
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
        if Self.legacyUIEnabled && !showsMapHome {
            legacyRootContent
        } else {
            MapHomeView(model: model, proAccess: proAccess)
        }
    }

    @ViewBuilder
    private var legacyRootContent: some View {
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

private struct MapHomeAppLockView: View {
    @Bindable var model: AppModel
    let isCheckingInitialState: Bool
    let lockGeneration: Int
    @Binding var automaticBiometricAttemptedGeneration: Int?
    @Binding var isBiometricAuthenticationInFlight: Bool
    @State private var pin = ""
    @State private var errorMessage: String?
    @State private var isAuthenticating = false
    @State private var showsPINInput = false

    var body: some View {
        ZStack {
            Color.tpInk.ignoresSafeArea()
            VStack(spacing: 18) {
                Image("MapHomeHomeIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 92, height: 92)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                Text("Taption Plan")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                if isCheckingInitialState {
                    ProgressView().tint(.white)
                } else {
                    Text("잠금을 해제해 주세요")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.70))
                    if showsPINInput || !model.securityStatus.settings.biometricUnlockEnabled {
                        SecureField("4자리 비밀번호", text: $pin)
                            .keyboardType(.numberPad)
                            .textContentType(.password)
                            .multilineTextAlignment(.center)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.tpInk)
                            .padding(.horizontal, 18)
                            .frame(width: 210, height: 48)
                            .background(.white, in: RoundedRectangle(cornerRadius: 14))
                            .onChange(of: pin) { _, value in
                                pin = String(value.filter(\.isNumber).prefix(4))
                                if pin.count == 4 { unlockWithPIN() }
                            }
                    }

                    if model.securityStatus.settings.biometricUnlockEnabled {
                        Button {
                            unlockWithBiometrics()
                        } label: {
                            Label("Face ID / Touch ID", systemImage: "faceid")
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.tpReferenceMint)
                        }
                        .disabled(isAuthenticating)
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.tpReferenceRose)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30)
                    }
                }
            }
            .padding(28)
        }
        .task(id: isCheckingInitialState) {
            startAutomaticBiometricAuthenticationIfNeeded()
        }
    }

    private func startAutomaticBiometricAuthenticationIfNeeded() {
        guard !isCheckingInitialState,
              model.securityStatus.settings.biometricUnlockEnabled,
              automaticBiometricAttemptedGeneration != lockGeneration else { return }
        automaticBiometricAttemptedGeneration = lockGeneration
        unlockWithBiometrics(isAutomaticAttempt: true)
    }

    private func unlockWithPIN() {
        guard !isAuthenticating, pin.count == 4 else { return }
        do {
            try model.unlockApp(withPIN: pin)
            pin = ""
            errorMessage = nil
        } catch {
            pin = ""
            errorMessage = error.localizedDescription
        }
    }

    private func unlockWithBiometrics(isAutomaticAttempt: Bool = false) {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        isBiometricAuthenticationInFlight = true
        if isAutomaticAttempt {
            showsPINInput = false
        }
        Task { @MainActor in
            defer {
                isAuthenticating = false
                isBiometricAuthenticationInFlight = false
            }
            do {
                try await model.unlockAppWithBiometrics()
                errorMessage = nil
            } catch {
                // Biometrics are only a fast path. Keep the PIN available after
                // cancellation, failure, or an unavailable sensor.
                showsPINInput = true
                errorMessage = error.localizedDescription
            }
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
    @State private var isRequesting = false
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

    init(model: AppModel, initialFeature: PermissionFeature? = nil) {
        self.model = model
        _index = State(
            initialValue: initialFeature.flatMap { feature in
                Self.steps.firstIndex { $0.feature == feature }
            } ?? 0
        )
    }

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
                Button("모두 허용") { requestRemaining() }
                    .font(.taption(size: 10, weight: .bold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.tpInk)
                    .disabled(isRequesting)
                Button("전체 건너뛰기") { finish() }
                    .font(.taption(size: 10, weight: .bold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.tpSecondary)
                    .disabled(isRequesting)
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

    /// 남은 권한을 순서대로 한 번에 요청한다. 시스템 권한창은 한 번에 하나만
    /// 뜨므로 순차로 진행하고, 중간에 버튼을 다시 누르지 못하게 막는다.
    private func requestRemaining() {
        guard !isRequesting else { return }
        isRequesting = true
        Task {
            while index < Self.steps.count {
                await request(Self.steps[index])
            }
            isRequesting = false
        }
    }

    private func advance() {
        guard index < Self.steps.count else { return }
        index += 1
    }

    private func finish() {
        Task { await model.finishPermissionOnboarding() }
    }
}

struct TaptionProAccessView: View {
    @Bindable var controller: TaptionProAccessController
    let allowsDismiss: Bool

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                if allowsDismiss {
                    HStack {
                        Spacer()
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .bold))
                                .frame(width: 40, height: 40)
                                .background(
                                    Color.black.opacity(0.06),
                                    in: Circle()
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("닫기")
                    }
                }

                Image(systemName: "sparkles")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Color.tpReferenceBlue)
                    .frame(width: 72, height: 72)
                    .background(
                        Color.tpReferenceBlue.opacity(0.12),
                        in: RoundedRectangle(
                            cornerRadius: 22,
                            style: .continuous
                        )
                    )

                VStack(spacing: 7) {
                    Text(title)
                        .font(.system(
                            size: 25,
                            weight: .bold,
                            design: .rounded
                        ))
                        .foregroundStyle(Color.tpInk)
                    Text(detail)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 11) {
                    featureRow("cloud.sun.fill", "시간대별 날씨 기록")
                    featureRow("location.fill", "실시간 GPS와 이동 경로")
                    featureRow("tram.fill", "지하철·버스 자동 판정")
                    featureRow("icloud.fill", "iCloud 백업과 기기 연동")
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color.white,
                    in: RoundedRectangle(
                        cornerRadius: 20,
                        style: .continuous
                    )
                )

                if controller.state == .loading {
                    ProgressView("Pro 상태 확인 중")
                        .padding(.vertical, 18)
                } else {
                    actionButtons
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, allowsDismiss ? 12 : 72)
            .padding(.bottom, 28)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.tpBackground.ignoresSafeArea())
        .alert(
            "Taption Plan Pro",
            isPresented: Binding(
                get: { controller.message != nil },
                set: { if !$0 { controller.message = nil } }
            )
        ) {
            Button("확인") { controller.message = nil }
        } message: {
            Text(controller.message ?? "")
        }
    }

    private var title: String {
        switch controller.state {
        case .loading:
            "Taption Plan Pro"
        case .trialNotStarted:
            "14일 무료 체험"
        case .trial(_, let remainingDays):
            "14일 무료 체험 · " + String(remainingDays) + "일 남음"
        case .purchased:
            "Pro를 영구 이용 중입니다"
        case .expired:
            "14일 무료 체험이 종료되었습니다"
        }
    }

    private var detail: String {
        switch controller.state {
        case .loading:
            "구매 및 체험 상태를 확인하고 있습니다."
        case .trialNotStarted:
            "버튼을 누르면 14일 무료 체험이 시작됩니다. 자동 결제는 없습니다."
        case .trial:
            "14일 무료 체험이 끝나도 자동 결제되지 않으며, 한 번 구매하면 계속 사용할 수 있습니다."
        case .purchased:
            "추가 결제나 자동 갱신 없이 모든 기능을 계속 사용할 수 있습니다."
        case .expired:
            "계속 사용하려면 Pro를 한 번 구매하거나 기존 구매 내역을 복원해 주세요."
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: 12) {
            if controller.state == .trialNotStarted {
                Button {
                    controller.startTrial()
                } label: {
                    Text("14일 무료 체험 시작")
                        .font(.system(size: 17, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.tpInk)
            }

            if !controller.hasPermanentAccess {
                Button {
                    Task { await controller.purchase() }
                } label: {
                    VStack(spacing: 3) {
                        Text("\(purchasePrice)로 Pro 영구 구매")
                            .font(.system(size: 16, weight: .bold))
                        Text("한 번 결제 · 자동 갱신 없음")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)

                Button("구매 복원") {
                    Task { await controller.restore() }
                }
                .font(.system(size: 14, weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Color.tpReferenceBlue)
            } else if allowsDismiss {
                Button("계속 사용") { dismiss() }
                    .font(.system(size: 17, weight: .bold))
                    .buttonStyle(.borderedProminent)
                    .tint(Color.tpInk)
            }
        }
        .disabled(controller.isActionInFlight)
        .overlay {
            if controller.isActionInFlight {
                ProgressView()
            }
        }
    }

    private var purchasePrice: String {
        controller.product?.displayPrice ?? "US $0.99"
    }

    private func featureRow(_ icon: String, _ title: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.tpReferenceBlue)
                .frame(width: 24)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.tpInk)
        }
    }
}

#Preview {
    AppShellView()
}
