@preconcurrency import ActivityKit
import EventKit
import SwiftUI
import UIKit

struct AppShellView: View {
    private static let legacyUIEnabled = false

    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(
        AppLanguagePreference.sharedDefaultsKey,
        store: UserDefaults(suiteName: AppLanguagePreference.appGroupIdentifier)
    ) private var languageRawValue = AppLanguagePreference.current.rawValue
    @State private var model = AppModel(startsCommerceLocked: true)
    @State private var proAccess = TaptionProAccessController()
    private let sensorLiveActivityController =
        SensorCollectionLiveActivityController.shared
    @State private var showsMapHome = true
    @State private var isSecurityStateReady = false
    @State private var hasCompletedInitialProRefresh = false
    @State private var hasCompletedInitialMapShellPreparation = false
    @State private var hasRenderedInitialDestination = false
    @State private var isInitialLaunchOverlayVisible = true
    @State private var initialLaunchProgressValue = 0.0
    @State private var initialLaunchProgressTarget = 0.0
    @State private var initialLaunchProgressTask: Task<Void, Never>?
    @State private var initialLaunchCompletionTask: Task<Void, Never>?
    @State private var lockGeneration = 0
    @State private var automaticBiometricAttemptedGeneration: Int?
    @State private var isBiometricAuthenticationInFlight = false
    @State private var biometricPromptInterruptedScene = false

    private var appLifecycleContent: some View {
        NavigationStack {
            Group {
                if proAccess.grantsAccess {
                    content
                } else {
                    Color.tpSurface.ignoresSafeArea()
                }
            }
            .onAppear {
                markInitialDestinationRendered()
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if Self.legacyUIEnabled && model.showsBottomBar && !showsMapHome {
                DraftBottomNavigationBar(model: model)
            }
        }
        .sheet(isPresented: addPlanSheetBinding) {
            AddPlanSheet(model: model)
        }
        .sheet(item: quickActionSheetBinding) { item in
            QuickActionSheet(model: model, item: item)
        }
        .sheet(item: planEditorSheetBinding) { request in
            PlanEditorSheet(model: model, planID: request.id)
        }
        .sheet(isPresented: $model.isPermissionOnboardingPresented) {
            PermissionOnboardingSheet(
                model: model,
                initialFeature: model.permissionOnboardingStartFeature
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .font(.taption(size: 17))
        .tint(.tpInk)
        .preferredColorScheme(.light)
        .task {
            await performInitialLaunchPreparation()
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
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.didReceiveMemoryWarningNotification
            )
        ) { _ in
            model.handleMemoryPressure()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .EKEventStoreChanged)
        ) { _ in
            model.scheduleCalendarStoreRefresh(forceWide: true)
        }
        .onChange(of: scenePhase) { _, phase in
            handleScenePhaseChange(phase)
        }
        .onChange(of: proAccess.state) { _, _ in
            dismissInitialLaunchOverlayIfReady()
        }
        .onChange(of: proAccess.grantsAccess) { _, grantsAccess in
            Task { @MainActor in
                if grantsAccess {
                    await model.sceneBecameActive()
                    scheduleDeferredSensorActivation()
                } else {
                    await model.suspendForCommerceLock()
                }
                await reconcileSensorLiveActivity()
            }
        }
        .onChange(of: model.isBootstrapped) { _, _ in
            advanceInitialLaunchProgress(to: 0.86)
            dismissInitialLaunchOverlayIfReady()
        }
        .onChange(of: isSecurityStateReady) { _, _ in
            dismissInitialLaunchOverlayIfReady()
        }
        .onChange(of: model.sensorCollectionSessionState) { _, _ in
            Task { await reconcileSensorLiveActivity() }
        }
        .onChange(of: model.sensorCollectionSessionID) { _, _ in
            Task { await reconcileSensorLiveActivity() }
        }
        .onChange(of: model.lastSensorSavedAt) { _, _ in
            Task { await reconcileSensorLiveActivity() }
        }
        .onChange(of: model.settings.gpsLoggingPreferences) { _, _ in
            Task { await reconcileSensorLiveActivity() }
        }
        .onChange(of: requiredPermissionGate.sensorCollectionReady) { _, ready in
            guard ready else { return }
            Task {
                await activateRequiredSensorsIfReady()
                await reconcileSensorLiveActivity()
            }
        }
    }

    var body: some View {
        ZStack {
            appLifecycleContent
                .accessibilityHidden(shouldHidePrimaryContent)
            securityOverlay
            initialLaunchOverlay
        }
        .alert(
            "확인해 주세요",
            isPresented: userFacingErrorBinding
        ) {
            Button("확인") { model.clearError() }
        } message: {
            userFacingErrorMessage
        }
        .overlay(alignment: .top) {
            floorCalibrationNotice
        }
        .animation(
            .easeInOut(duration: 0.25),
            value: model.floorCalibrationNotice
        )
        .environment(\.locale, appLocale)
    }

    private var appLocale: Locale {
        switch AppLanguagePreference.resolve(rawValue: languageRawValue) {
        case .korean: Locale(identifier: "ko_KR")
        case .english: Locale(identifier: "en_US")
        }
    }

    private var userFacingErrorMessage: some View {
        let message = model.userFacingError ?? ""
        return Text(
            AppLanguagePreference.localized(
                message,
                rawPreference: languageRawValue
            )
        )
    }

    private var userFacingErrorBinding: Binding<Bool> {
        Binding<Bool>(
            get: { model.userFacingError != nil },
            set: { isPresented in
                if !isPresented {
                    model.clearError()
                }
            }
        )
    }

    private var addPlanSheetBinding: Binding<Bool> {
        Binding(
            get: { Self.legacyUIEnabled && model.isAddPlanPresented },
            set: { model.isAddPlanPresented = $0 }
        )
    }

    private var quickActionSheetBinding: Binding<QuickActionItem?> {
        Binding(
            get: { Self.legacyUIEnabled ? model.selectedAction : nil },
            set: { model.selectedAction = $0 }
        )
    }

    private var planEditorSheetBinding: Binding<PlanEditorRequest?> {
        Binding(
            get: { Self.legacyUIEnabled ? model.planEditorRequest : nil },
            set: { model.planEditorRequest = $0 }
        )
    }

    private var shouldHideAppSnapshot: Bool {
        guard scenePhase != .active else { return false }
        let settings = model.securityStatus.settings
        return settings.lockOnForeground || settings.lockOnLaunch
    }

    private var shouldHidePrimaryContent: Bool {
        isInitialLaunchOverlayVisible
            || !isSecurityStateReady
            || model.isAppLocked
            || !proAccess.grantsAccess
            || shouldHideAppSnapshot
    }

    private var requiredPermissionGate: RequiredPermissionGate {
        model.requiredPermissionGate(
            liveActivitiesEnabled:
                ActivityAuthorizationInfo().areActivitiesEnabled
        )
    }

    private var initialLaunchReady: Bool {
        AppShellInitialLaunchGate.isReady(
            hasCompletedInitialProRefresh: hasCompletedInitialProRefresh,
            isSecurityStateReady: isSecurityStateReady,
            hasRenderedInitialDestination: hasRenderedInitialDestination,
            hasCompletedInitialMapShellPreparation:
                hasCompletedInitialMapShellPreparation,
            isBootstrapped: model.isBootstrapped,
            grantsAccess: proAccess.grantsAccess
        )
    }

    private var initialLaunchProgress: Double {
        initialLaunchProgressValue
    }

    private func advanceInitialLaunchProgress(to target: Double) {
        let target = min(max(target, 0), 1)
        guard target > initialLaunchProgressTarget else { return }
        initialLaunchProgressTarget = target
        startInitialLaunchProgressTicker()
    }

    private func startInitialLaunchProgressTicker() {
        guard initialLaunchProgressTask == nil else { return }
        initialLaunchProgressTask = Task { @MainActor in
            defer { initialLaunchProgressTask = nil }
            while !Task.isCancelled {
                let next = AppShellInitialLaunchProgressMath.next(
                    current: initialLaunchProgressValue,
                    target: initialLaunchProgressTarget
                )
                if next != initialLaunchProgressValue {
                    withAnimation(.linear(duration: 0.12)) {
                        initialLaunchProgressValue = next
                    }
                }
                if !isInitialLaunchOverlayVisible,
                   initialLaunchProgressValue >= 1 {
                    break
                }
                if initialLaunchProgressValue >= initialLaunchProgressTarget {
                    break
                }
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func markInitialDestinationRendered() {
        guard !hasRenderedInitialDestination else { return }
        hasRenderedInitialDestination = true
        advanceInitialLaunchProgress(to: 0.36)
        dismissInitialLaunchOverlayIfReady()
    }

    private func dismissInitialLaunchOverlayIfReady() {
        guard isInitialLaunchOverlayVisible, initialLaunchReady else { return }
        advanceInitialLaunchProgress(to: 1)
        guard initialLaunchCompletionTask == nil else { return }
        initialLaunchCompletionTask = Task { @MainActor in
            while !Task.isCancelled, initialLaunchProgressValue < 1 {
                try? await Task.sleep(for: .milliseconds(33))
            }
            guard !Task.isCancelled, initialLaunchReady else {
                initialLaunchCompletionTask = nil
                return
            }
            withAnimation(.easeOut(duration: 0.18)) {
                initialLaunchProgressValue = 1
                isInitialLaunchOverlayVisible = false
            }
            initialLaunchCompletionTask = nil
        }
    }

    @ViewBuilder
    private var initialLaunchOverlay: some View {
        if isInitialLaunchOverlayVisible {
            ZStack {
                Color("LaunchBackground")
                    .ignoresSafeArea()
                VStack(spacing: 20) {
                    Image("TaptionSplashIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 230, height: 230)
                    Text("Taption Plan")
                        .font(.system(size: 25, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    ProgressView(value: initialLaunchProgress, total: 1)
                        .progressViewStyle(.linear)
                        .frame(width: 220)
                        .tint(.white)
                        .background(
                            Capsule()
                                .fill(.white.opacity(0.22))
                        )
                        .accessibilityValue("\(Int((initialLaunchProgress * 100).rounded()))%")
                        .accessibilityLabel(
                            AppLanguagePreference.text(
                                korean: "활동과 이동 경로 불러오는 중",
                                english: "Loading activities and routes",
                                rawPreference: languageRawValue
                            )
                        )
                    Text("\(Int((initialLaunchProgress * 100).rounded()))%")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.82))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                AppLanguagePreference.text(
                    korean: "Taption Plan 불러오는 중",
                    english: "Loading Taption Plan",
                    rawPreference: languageRawValue
                )
            )
            .zIndex(10)
        }
    }

    @ViewBuilder
    private var securityOverlay: some View {
        if !isSecurityStateReady || model.isAppLocked {
            MapHomeAppLockView(
                model: model,
                isCheckingInitialState: !isSecurityStateReady,
                lockGeneration: lockGeneration,
                languageRawValue: languageRawValue,
                automaticBiometricAttemptedGeneration: $automaticBiometricAttemptedGeneration,
                isBiometricAuthenticationInFlight: $isBiometricAuthenticationInFlight
            )
        } else if !proAccess.grantsAccess {
            TaptionProAccessView(
                controller: proAccess,
                allowsDismiss: false
            )
        } else if shouldHideAppSnapshot {
            ZStack {
                Color("LaunchBackground")
                    .ignoresSafeArea()
                Image("TaptionSplashIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 250, height: 250)
            }
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var floorCalibrationNotice: some View {
        if let notice = model.floorCalibrationNotice {
            Text(
                AppLanguagePreference.localized(
                    notice,
                    rawPreference: languageRawValue
                )
            )
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
                await proAccess.refreshAccess()
                scheduleDeferredStoreKitProductLoad()
                if proAccess.grantsAccess {
                    await model.sceneBecameActive()
                    scheduleDeferredSensorActivation()
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
                if proAccess.grantsAccess {
                    await model.reconcileSensorCollectionLiveActivity(
                        isForeground: true
                    )
                }
            @unknown default:
                break
            }
            await reconcileSensorLiveActivity()
        }
    }

    private func performInitialLaunchPreparation() async {
        startInitialLaunchProgressTicker()
        advanceInitialLaunchProgress(to: 0.04)
        await proAccess.refreshAccess()
        hasCompletedInitialProRefresh = true
        advanceInitialLaunchProgress(to: 0.18)
        scheduleDeferredStoreKitProductLoad()
        if proAccess.grantsAccess {
            advanceInitialLaunchProgress(to: 0.20)
            await model.sceneBecameActive()
            await model.refreshPermissions()
            model.presentPermissionOnboardingIfNeeded()
            advanceInitialLaunchProgress(to: 0.86)
            scheduleDeferredSensorActivation()
        } else {
            advanceInitialLaunchProgress(to: 0.80)
            await model.suspendForCommerceLock()
        }
        if model.isAppLocked {
            lockGeneration &+= 1
            automaticBiometricAttemptedGeneration = nil
        }
        if Self.legacyUIEnabled,
           let planID = TaptionPlanAppDelegate.takePendingPlanID(),
           let url = URL(
                string: "taptionplan://plan/\(planID.uuidString)"
           ) {
            showsMapHome = false
            await model.openDeepLink(url)
        }
        await reconcileSensorLiveActivity()
        advanceInitialLaunchProgress(to: 0.96)
        isSecurityStateReady = true
        advanceInitialLaunchProgress(to: 0.98)
        dismissInitialLaunchOverlayIfReady()
    }

    private func scheduleDeferredStoreKitProductLoad() {
        Task { @MainActor in
            await Task.yield()
            await proAccess.loadProductIfNeeded()
        }
    }

    private func scheduleDeferredSensorActivation() {
        Task { @MainActor in
            await Task.yield()
            guard proAccess.grantsAccess else { return }
            await activateRequiredSensorsIfReady()
        }
    }

    private func reconcileSensorLiveActivity() async {
        guard proAccess.grantsAccess else {
            await sensorLiveActivityController.stop(
                lastSavedAt: model.lastSensorSavedAt,
                collectionKinds: []
            )
            return
        }
        await model.reconcileSensorCollectionLiveActivity(
            isForeground: scenePhase != .background
        )
    }

    private func activateRequiredSensorsIfReady() async {
        guard requiredPermissionGate.sensorCollectionReady else { return }
        await model.activateRequiredSensorCollection()
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
            MapHomeView(
                model: model,
                proAccess: proAccess,
                onInitialDataReady: {
                    hasCompletedInitialMapShellPreparation = true
                    advanceInitialLaunchProgress(to: 0.98)
                    dismissInitialLaunchOverlayIfReady()
                }
            )
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

enum AppShellInitialLaunchProgressMath {
    static func next(
        current: Double,
        target: Double,
        minimumStep: Double = 0.004
    ) -> Double {
        let current = min(max(current, 0), 1)
        let target = min(max(target, current), 1)
        guard target > current else { return current }
        let step = max(minimumStep, (target - current) * 0.18)
        return min(target, current + step)
    }
}

enum AppShellInitialLaunchGate {
    static func isReady(
        hasCompletedInitialProRefresh: Bool,
        isSecurityStateReady: Bool,
        hasRenderedInitialDestination: Bool,
        hasCompletedInitialMapShellPreparation: Bool,
        isBootstrapped: Bool,
        grantsAccess: Bool
    ) -> Bool {
        hasCompletedInitialProRefresh
            && isSecurityStateReady
            && hasRenderedInitialDestination
            && (hasCompletedInitialMapShellPreparation || !grantsAccess)
            && (isBootstrapped || !grantsAccess)
    }
}

struct AppLockBiometricAttemptGate {
    static func shouldStart(
        generation: Int,
        attemptedGeneration: Int?,
        isInFlight: Bool
    ) -> Bool {
        !isInFlight && attemptedGeneration != generation
    }
}

private struct MapHomeAppLockView: View {
    @Bindable var model: AppModel
    let isCheckingInitialState: Bool
    let lockGeneration: Int
    let languageRawValue: String
    @Binding var automaticBiometricAttemptedGeneration: Int?
    @Binding var isBiometricAuthenticationInFlight: Bool
    @State private var errorMessage: String?
    @State private var isAuthenticating = false
    @State private var showsPINInput = false

    var body: some View {
        ZStack {
            Color("LaunchBackground")
                .ignoresSafeArea()
            Image("TaptionSplashIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 250, height: 250)
                .accessibilityLabel(
                    AppLanguagePreference.text(
                        korean: "앱 잠금 해제 필요",
                        english: "App unlock required",
                        rawPreference: languageRawValue
                    )
                )
        }
        .sheet(isPresented: $showsPINInput) {
            AppLockPINSheet(
                model: model,
                errorMessage: errorMessage,
                languageRawValue: languageRawValue
            )
                .interactiveDismissDisabled()
                .presentationDetents([.height(220)])
                .presentationDragIndicator(.visible)
        }
        .onAppear {
            presentPINIfBiometricsAreUnavailable()
        }
        .task(id: isCheckingInitialState) {
            startAutomaticBiometricAuthenticationIfNeeded()
        }
    }

    private func startAutomaticBiometricAuthenticationIfNeeded() {
        guard !isCheckingInitialState,
              model.securityStatus.settings.biometricUnlockEnabled,
              AppLockBiometricAttemptGate.shouldStart(
                  generation: lockGeneration,
                  attemptedGeneration: automaticBiometricAttemptedGeneration,
                  isInFlight: isBiometricAuthenticationInFlight
              ) else {
            presentPINIfBiometricsAreUnavailable()
            return
        }
        automaticBiometricAttemptedGeneration = lockGeneration
        unlockWithBiometrics()
    }

    private func presentPINIfBiometricsAreUnavailable() {
        guard !isCheckingInitialState,
              !model.securityStatus.settings.biometricUnlockEnabled else { return }
        showsPINInput = true
    }

    private func unlockWithBiometrics() {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        isBiometricAuthenticationInFlight = true
        Task { @MainActor in
            defer {
                isAuthenticating = false
                isBiometricAuthenticationInFlight = false
            }
            do {
                try await model.unlockAppWithBiometrics()
                errorMessage = nil
            } catch {
                showsPINInput = true
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct AppLockPINSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let errorMessage: String?
    let languageRawValue: String
    @State private var pin = ""
    @State private var validationMessage: String?

    private var displayedError: String? {
        validationMessage ?? errorMessage
    }

    var body: some View {
        VStack(spacing: 14) {
            Text(
                AppLanguagePreference.text(
                    korean: "PIN",
                    english: "PIN",
                    rawPreference: languageRawValue
                )
            )
                .font(.taption(size: 20, weight: .bold))
            SecureField(
                AppLanguagePreference.text(
                    korean: "4자리 비밀번호",
                    english: "4-digit PIN",
                    rawPreference: languageRawValue
                ),
                text: $pin
            )
                .keyboardType(.numberPad)
                .textContentType(.password)
                .multilineTextAlignment(.center)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(Color.tpInk)
                .padding(.horizontal, 18)
                .frame(width: 210, height: 48)
                .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 14))
                .onChange(of: pin) { _, value in
                    pin = String(value.filter(\.isNumber).prefix(4))
                    if pin.count == 4 {
                        unlock()
                    }
                }
            if let displayedError {
                Text(displayedError)
                    .font(.taption(size: 12))
                    .foregroundStyle(Color.tpReferenceRose)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .padding(24)
    }

    private func unlock() {
        do {
            try model.unlockApp(withPIN: pin)
            dismiss()
        } catch {
            pin = ""
            validationMessage = error.localizedDescription
        }
    }
}

private struct RequiredPermissionGateView: View {
    @Bindable var model: AppModel
    let gate: RequiredPermissionGate
    let languageRawValue: String

    @State private var requesting: RequiredPermission?

    var body: some View {
        ZStack {
            Color.tpBackground.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    VStack(spacing: 9) {
                        ForEach(RequiredPermission.allCases, id: \.rawValue) {
                            permissionCard($0)
                        }
                    }
                    Text(
                        text(
                            "모든 권한이 확인되면 GPS와 센서 기록이 5분 간격으로 자동 시작됩니다.",
                            "GPS and sensor recording starts automatically every 5 minutes after all permissions are verified."
                        )
                    )
                    .font(.taption(size: 12))
                    .foregroundStyle(Color.tpSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
        }
        .preferredColorScheme(.light)
        .accessibilityAddTraits(.isModal)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "sensor.fill")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Color.tpReferenceRose)
            Text(text("필수 권한 설정", "Required permissions"))
                .font(.taption(size: 27, weight: .black))
                .foregroundStyle(Color.tpInk)
            Text(
                text(
                    "자동 기록에 필요한 권한입니다. 빠진 권한이 있으면 기록 화면을 사용할 수 없습니다.",
                    "These permissions are required for automatic recording. The timeline remains locked until all are enabled."
                )
            )
            .font(.taption(size: 14))
            .foregroundStyle(Color.tpSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 20))
    }

    private func permissionCard(
        _ permission: RequiredPermission
    ) -> some View {
        let missing = gate.missing.contains(permission)
        return HStack(spacing: 12) {
            Image(systemName: metadata(permission).icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(
                    missing ? Color.tpReferenceRose : Color.tpReferenceMint
                )
                .frame(width: 38, height: 38)
                .background(
                    (missing ? Color.tpReferenceRose : Color.tpReferenceMint)
                        .opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 12)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(metadata(permission).title)
                    .font(.taption(size: 15, weight: .bold))
                    .foregroundStyle(Color.tpInk)
                Text(
                    missing
                        ? text("설정 필요", "Required")
                        : text("허용됨", "Allowed")
                )
                .font(.taption(size: 11, weight: .semibold))
                .foregroundStyle(Color.tpSecondary)
            }
            Spacer(minLength: 8)
            if missing {
                Button {
                    request(permission)
                } label: {
                    if requesting == permission {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text(actionTitle(permission))
                    }
                }
                .font(.taption(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(minWidth: 78, minHeight: 38)
                .background(Color.tpInk, in: Capsule())
                .buttonStyle(.plain)
                .disabled(requesting != nil)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.tpReferenceMint)
            }
        }
        .padding(13)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
    }

    private func request(_ permission: RequiredPermission) {
        guard requesting == nil else { return }
        requesting = permission
        Task { @MainActor in
            await model.requestRequiredPermission(permission)
            requesting = nil
        }
    }

    private func actionTitle(_ permission: RequiredPermission) -> String {
        switch permission {
        case .locationPrecise, .liveActivities:
            text("설정 열기", "Open Settings")
        default:
            text("허용하기", "Allow")
        }
    }

    private func metadata(
        _ permission: RequiredPermission
    ) -> (icon: String, title: String) {
        switch permission {
        case .locationAlways:
            ("location.fill", text("위치 항상 허용", "Always Location"))
        case .locationPrecise:
            ("scope", text("정확한 위치", "Precise Location"))
        case .motion:
            ("figure.walk.motion", text("동작 및 피트니스", "Motion & Fitness"))
        case .healthKitRequestCompleted:
            ("heart.fill", text("건강 데이터", "Health Data"))
        case .calendar:
            ("calendar", text("캘린더 전체 접근", "Full Calendar Access"))
        case .notifications:
            ("bell.fill", text("알림", "Notifications"))
        case .liveActivities:
            ("iphone.radiowaves.left.and.right", text("실시간 현황", "Live Activities"))
        }
    }

    private func text(_ korean: String, _ english: String) -> String {
        AppLanguagePreference.text(
            korean: korean,
            english: english,
            rawPreference: languageRawValue
        )
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
            title: "건강 데이터",
            detail: "iPhone 건강 앱과 승인된 건강 앱의 걸음·운동·수면을 읽습니다. Apple Watch 기록도 함께 반영합니다."
        ),
        PermissionOnboardingStep(
            feature: .calendar,
            icon: "calendar",
            title: "캘린더",
            detail: "이미 잡혀 있는 일정을 시간표에 함께 보여줍니다."
        ),
        PermissionOnboardingStep(
            feature: .notifications,
            icon: "bell.badge",
            title: "알림",
            detail: "계획한 시각에 맞춰 알려줍니다."
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
            Text("Taption Plan은 위치·건강·캘린더를 읽어 하루를 대신 적습니다. 필요한 것만 허용해도 되고, 설정에서 언제든 바꿀 수 있습니다.")
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
        if step.feature == .health, !model.settings.healthEnabled {
            return state == .denied || state == .unavailable
                ? state.settingsLabel
                : "연결 필요"
        }
        return state == .notDetermined ? "" : state.settingsLabel
    }

    private func request(_ step: PermissionOnboardingStep) async {
        switch step.feature {
        case .location: await model.enableLocationCollection()
        case .health: await model.requestHealth()
        case .calendar: await model.requestCalendar()
        case .photos: break
        case .notifications: await model.requestNotifications()
        case .appUsage: break
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
    @AppStorage(
        AppLanguagePreference.sharedDefaultsKey,
        store: UserDefaults(suiteName: AppLanguagePreference.appGroupIdentifier)
    ) private var languageRawValue = AppLanguagePreference.current.rawValue

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
                        .accessibilityLabel(text("닫기", "Close"))
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
                    featureRow(
                        "cloud.sun.fill",
                        text("시간대별 날씨 기록", "Hourly weather records")
                    )
                    featureRow(
                        "location.fill",
                        text("실시간 GPS와 이동 경로", "Live GPS and travel routes")
                    )
                    featureRow(
                        "tram.fill",
                        text("지하철·버스 자동 판정", "Automatic subway and bus detection")
                    )
                    featureRow(
                        "icloud.fill",
                        text("iCloud 백업과 기기 연동", "iCloud backup and device sync")
                    )
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
                    ProgressView(text("Pro 상태 확인 중", "Checking Pro status"))
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
        .task {
            await controller.refresh()
        }
        .alert(
            "Taption Plan Pro",
            isPresented: Binding(
                get: { controller.message != nil },
                set: { if !$0 { controller.message = nil } }
            )
        ) {
            Button(text("확인", "OK")) { controller.message = nil }
        } message: {
            proMessage
        }
    }

    private var title: String {
        switch controller.state {
        case .loading:
            "Taption Plan Pro"
        case .trialNotStarted:
            text("14일 무료 체험", "14-day free trial")
        case .trial(_, let remainingDays):
            text(
                "14일 무료 체험 · \(remainingDays)일 남음",
                "14-day free trial · \(remainingDays) days left"
            )
        case .purchased:
            text("Pro를 영구 이용 중입니다", "You own Pro permanently")
        case .expired:
            text("14일 무료 체험이 종료되었습니다", "Your 14-day free trial has ended")
        }
    }

    private var detail: String {
        switch controller.state {
        case .loading:
            text(
                "구매 및 체험 상태를 확인하고 있습니다.",
                "Checking your purchase and trial status."
            )
        case .trialNotStarted:
            text(
                "버튼을 누르면 14일 무료 체험이 시작됩니다. 자동 결제는 없습니다.",
                "Tap the button to start a 14-day free trial. You will not be charged automatically."
            )
        case .trial:
            text(
                "14일 무료 체험이 끝나도 자동 결제되지 않으며, 한 번 구매하면 계속 사용할 수 있습니다.",
                "The trial does not renew automatically. A single purchase unlocks Pro permanently."
            )
        case .purchased:
            text(
                "추가 결제나 자동 갱신 없이 모든 기능을 계속 사용할 수 있습니다.",
                "Keep using every feature with no additional payment or renewal."
            )
        case .expired:
            text(
                "계속 사용하려면 Pro를 한 번 구매하거나 기존 구매 내역을 복원해 주세요.",
                "Purchase Pro once or restore an existing purchase to continue."
            )
        }
    }

    private func text(_ korean: String, _ english: String) -> String {
        AppLanguagePreference.text(
            korean: korean,
            english: english,
            rawPreference: languageRawValue
        )
    }

    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: 12) {
            if controller.state == .trialNotStarted {
                Button {
                    controller.startTrial()
                } label: {
                    Text(text("14일 무료 체험 시작", "Start 14-day free trial"))
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
                        Text(purchaseTitle)
                            .font(.system(size: 16, weight: .bold))
                        Text(
                            text(
                                "한 번 결제 · 자동 갱신 없음",
                                "One-time purchase · No auto-renewal"
                            )
                        )
                            .font(.system(size: 11, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)

                Button(text("구매 복원", "Restore purchase")) {
                    Task { await controller.restore() }
                }
                .font(.system(size: 14, weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Color.tpReferenceBlue)
            } else if allowsDismiss {
                Button(text("계속 사용", "Continue")) { dismiss() }
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

    private var purchaseTitle: String {
        if let displayPrice = controller.product?.displayPrice {
            return text(
                "\(displayPrice)로 Pro 영구 구매",
                "Buy Pro permanently for \(displayPrice)"
            )
        }
        return text("Pro 영구 구매", "Buy Pro permanently")
    }

    @ViewBuilder
    private var proMessage: some View {
        switch controller.message {
        case .trialStarted:
            Text(text("14일 무료 체험이 시작되었습니다.", "Your 14-day free trial has started."))
        case .trialAlreadyUsed:
            Text(text(
                "이 기기 또는 iCloud에 저장된 기록에서 14일 무료 체험을 이미 사용했습니다.",
                "The 14-day free trial has already been used on this device or in its synced iCloud record."
            ))
        case .purchaseCompleted:
            Text(text("Pro 영구 구매가 완료되었습니다.", "Your permanent Pro purchase is complete."))
        case .purchasePending:
            Text(text("구매 승인을 기다리고 있습니다.", "Waiting for purchase approval."))
        case .purchaseUnavailable:
            Text(text(
                "App Store에서 구매 항목을 아직 불러오지 못했습니다.",
                "The purchase is not available from the App Store yet."
            ))
        case .receiptVerificationFailed:
            Text(text("구매 영수증을 확인하지 못했습니다.", "The purchase receipt could not be verified."))
        case .purchaseFailed:
            Text(text(
                "구매를 완료하지 못했습니다. 잠시 후 다시 시도해 주세요.",
                "The purchase could not be completed. Please try again later."
            ))
        case .restoreCompleted:
            Text(text("구매 내역을 복원했습니다.", "Your purchase was restored."))
        case .restoreNotFound:
            Text(text("복원할 Pro 구매 내역이 없습니다.", "No Pro purchase was found to restore."))
        case .restoreFailed:
            Text(text(
                "구매 내역을 복원하지 못했습니다. 잠시 후 다시 시도해 주세요.",
                "Your purchase could not be restored. Please try again later."
            ))
        case nil:
            EmptyView()
        }
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
