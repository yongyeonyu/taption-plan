@preconcurrency import ActivityKit
import EventKit
import SwiftUI
import UIKit

struct AppShellView: View {
    private static let legacyUIEnabled = false
    private static let liveActivityTicker = Timer.publish(every: 30, on: .main, in: .common).autoconnect() // body마다 새로 만들지 않는다(PRF1101A01)

    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(
        AppLanguagePreference.sharedDefaultsKey,
        store: UserDefaults(suiteName: AppLanguagePreference.appGroupIdentifier)
    ) private var languageRawValue = AppLanguagePreference.current.rawValue
    /// 테마를 바꾸면 화면을 새로 그려 모든 색을 다시 읽는다(UIX1101A04).
    @AppStorage(TaptionUITheme.storageKey) private var uiThemeRaw = TaptionUITheme.classic.rawValue
    @State private var model = AppModel(startsCommerceLocked: true)
    @State private var proAccess = TaptionProAccessController()
    private let sensorLiveActivityController =
        SensorCollectionLiveActivityController.shared
    @State private var showsMapHome = true
    @State private var isSecurityStateReady = false
    @State private var hasCompletedInitialProRefresh = false
    @State private var hasCompletedInitialMapShellPreparation = false
    /// 전체 로딩이 너무 오래 걸리면 시간 제한 후 홈을 연다.
    @State private var launchTimeoutPassed = false
    /// 오늘 경로(하루 데이터)를 기다리는 유예가 지났다. 스플래시를 붙잡지 않는다.
    @State private var mapShellGraceElapsed = false
    @State private var mapShellGraceTask: Task<Void, Never>?
    @State private var hasRenderedInitialDestination = false
    @State private var isInitialLaunchOverlayVisible = true
    @State private var initialLaunchProgressValue = 0.0
    @State private var initialLaunchProgressTarget = 0.0
    @State private var initialLaunchProgressTask: Task<Void, Never>?
    @State private var initialLaunchStartedAt: TimeInterval?
    @State private var lockGeneration = 0
    @State private var automaticBiometricAttemptedGeneration: Int?
    @State private var isBiometricAuthenticationInFlight = false
    @State private var biometricPromptInterruptedScene = false
    @State private var isFirstRunTutorialPending = false

    /// 사슬이 길면 타입 검사가 17초 걸려(ARC1103A01) 세 덩어리로 나눈다. 수식어 순서는 그대로다.
    private var appLifecycleContent: some View {
        appStateObservers(appEventObservers(appRootWithSheets))
    }

    private var appRootWithSheets: some View {
        NavigationStack {
            Group {
                if proAccess.grantsAccess {
                    content
                } else {
                    Color.tpSurface.ignoresSafeArea()
                }
            }
            .id(uiThemeRaw)
            .onAppear {
                markInitialDestinationRendered()
            }
            .toolbar(.hidden, for: .navigationBar)
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
        .appleWatchInstallPrompt(model: model, isBlocked: isFirstRunTutorialPending || isInitialLaunchOverlayVisible)
        .fullScreenCover(isPresented: firstRunTutorialBinding) {
            FirstRunTutorialView(model: model) { finishFirstRunTutorial() }
        }
        .font(.taption(size: 17))
        .tint(Color.tpPrimaryFill)
        .preferredColorScheme((TaptionUITheme(rawValue: uiThemeRaw) ?? .classic).colorScheme)
    }

    private func appEventObservers(_ content: some View) -> some View {
        content
        .task {
            await performInitialLaunchPreparation()
            TaptionUITheme.follow(mapStyle: model.settings.mapDisplayStyle)
        }
        .onChange(of: model.settings.mapDisplayStyle) { _, style in
            TaptionUITheme.follow(mapStyle: style)
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
    }

    private func appStateObservers(_ content: some View) -> some View {
        content
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
            recordLaunchGate("bootstrapped")
            advanceInitialLaunchProgress(to: 0.86)
            dismissInitialLaunchOverlayIfReady()
        }
        .onChange(of: model.hasPreparedStartupSettings) { _, _ in
            recordLaunchGate("startup_settings")
            advanceInitialLaunchProgress(to: 0.86)
            dismissInitialLaunchOverlayIfReady()
        }
        .onChange(of: isSecurityStateReady) { _, _ in
            recordLaunchGate("security_state")
            dismissInitialLaunchOverlayIfReady()
        }
        .onChange(of: model.sensorCollectionSessionState) { _, _ in
            Task { await reconcileSensorLiveActivity() }
        }
        .onChange(of: model.sensorCollectionSessionID) { _, _ in
            Task { await reconcileSensorLiveActivity() }
        }
        .onChange(of: model.snapshotSavedAt) { _, _ in
            Task { await reconcileSensorLiveActivity() }
        }
        .onReceive(Self.liveActivityTicker) { _ in
            guard scenePhase == .active else { return }
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
        .id(languageRawValue).environment(\.locale, appLocale) // 언어를 바꾸면 화면을 새로 만들어 바로 반영한다.
    }

    private var appLocale: Locale {
        AppLanguagePreference.resolve(rawValue: languageRawValue).locale
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
            mapShellGraceElapsed: mapShellGraceElapsed,
            isBootstrapped: model.isBootstrapped || launchTimeoutPassed,
            grantsAccess: proAccess.grantsAccess
        )
    }

    /// 지도 첫 화면이 오늘 경로를 다 읽을 때까지 스플래시를 붙잡지 않는다.
    /// 앱을 쓸 수 있는 상태는 갖춰졌는데 지도만 경로를 더 읽는 중이면, 0.6초 뒤
    /// 스플래시를 걷고 경로는 그 위에 채운다(대표 요청: 시작 로딩 최적화).
    private func scheduleMapShellGraceIfNeeded() {
        guard mapShellGraceTask == nil, isInitialLaunchOverlayVisible,
              !hasCompletedInitialMapShellPreparation, hasCompletedInitialProRefresh,
              isSecurityStateReady, hasRenderedInitialDestination,
              model.isBootstrapped, proAccess.grantsAccess else { return }
        mapShellGraceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            mapShellGraceElapsed = true
            recordLaunchGate("map_shell_grace")
            dismissInitialLaunchOverlayIfReady()
        }
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
                // 목표에 닿았는데 준비가 안 끝났으면 조금씩 계속 간다(예전에는 0.86에서 얼어붙었다).
                // 천장은 적재 전 0.90, 적재 뒤 0.97 — 읽는 내내 97%에 있으면 멈춘 것처럼 보인다.
                let goal = AppShellInitialLaunchProgressMath.goal(
                    current: initialLaunchProgressValue,
                    target: initialLaunchProgressTarget,
                    bootstrapped: model.isBootstrapped
                )
                let next = AppShellInitialLaunchProgressMath.next(
                    current: initialLaunchProgressValue,
                    target: goal
                )
                if next != initialLaunchProgressValue {
                    withAnimation(.linear(duration: 0.12)) {
                        initialLaunchProgressValue = next
                    }
                }
                if initialLaunchProgressValue >= 1 { break }
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func markInitialDestinationRendered() {
        guard !hasRenderedInitialDestination else { return }
        hasRenderedInitialDestination = true
        recordLaunchGate("destination_rendered")
        advanceInitialLaunchProgress(to: 0.36)
        dismissInitialLaunchOverlayIfReady()
    }

    /// 시작 게이트가 하나씩 열릴 때마다 걸린 시간을 남긴다(자세한 설명은 `AppShellLaunchGateRecorder`).
    private func recordLaunchGate(_ gate: String) {
        AppShellLaunchGateRecorder.record(gate, startedAt: initialLaunchStartedAt)
    }

    private func dismissInitialLaunchOverlayIfReady() {
        // 아직 안 걷혔으면, 오늘 경로를 기다리느라 스플래시에 갇히지 않도록
        // 짧은 유예를 걸어 둔다(아래).
        scheduleMapShellGraceIfNeeded()
        guard isInitialLaunchOverlayVisible, initialLaunchReady else { return }
        initialLaunchProgressTask?.cancel()
        initialLaunchProgressTarget = 1
        withAnimation(.easeOut(duration: 0.18)) {
            initialLaunchProgressValue = 1
            isInitialLaunchOverlayVisible = false
        }
        // 권한 시트는 스플래시가 걷힌 뒤에 띄운다. 시작 화면 뒤에서 이벤트킷·건강
        // 권한을 읽고 시트를 올리면 메인 스레드를 먼저 잡아 지도 첫 화면이 늦어진다.
        scheduleDeferredPermissionPreparation()
        if let initialLaunchStartedAt {
            TaptionPlanDiagnosticsLogger.shared.record(
                "initial_launch_ready",
                fields: ["duration_ms": String(Int((
                    ProcessInfo.processInfo.systemUptime - initialLaunchStartedAt
                ) * 1_000))]
            )
        }
    }

    /// 스플래시에 보일 지금 단계. 전체 데이터 → 오늘 경로 순서로 바뀐다.
    private var launchStatusText: String {
        if !model.isBootstrapped {
            return AppLanguagePreference.text(korean: "데이터 불러오는 중…", english: "Loading data…", rawPreference: languageRawValue)
        }
        return AppLanguagePreference.text(korean: "경로 불러오는 중…", english: "Loading routes…", rawPreference: languageRawValue)
    }

    @ViewBuilder
    private var initialLaunchOverlay: some View {
        if isInitialLaunchOverlayVisible {
            // LaunchScreen.storyboard와 같게 고정(아이콘 190pt·중심 -70pt·제목 시스템 25pt)해 이어 그릴 때 커지지 않게 한다(UIX1101B03).
            GeometryReader { proxy in
                VStack(spacing: 12) {
                    Image("TaptionSplashIcon").resizable().scaledToFit()
                        .frame(width: 190, height: 190)
                    Text("BOKKI Plan")
                        .font(.taptionFixed(size: 25, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(height: 32)
                        .padding(.top, 10)
                    ProgressView(value: initialLaunchProgress, total: 1)
                        .progressViewStyle(.linear)
                        .frame(width: 220)
                        .tint(.white)
                        .background(Capsule().fill(.white.opacity(0.22)))
                        .accessibilityValue("\(Int((initialLaunchProgress * 100).rounded()))%")
                        .accessibilityLabel(
                            AppLanguagePreference.text(
                                korean: "활동과 이동 경로 불러오는 중",
                                english: "Loading activities and routes",
                                rawPreference: languageRawValue
                            )
                        )
                    Text("\(Int((initialLaunchProgress * 100).rounded()))%")
                        .font(.taptionFixed(size: 12, weight: .semibold))
                    Text(launchStatusText)
                        .font(.taptionFixed(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, proxy.size.height / 2 - 70 - 95)
            }
            .ignoresSafeArea()
            .background(Color("LaunchBackground").ignoresSafeArea())
            .transition(.opacity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                AppLanguagePreference.text(
                    korean: "BOKKI Plan 불러오는 중",
                    english: "Loading BOKKI Plan",
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
                    .frame(width: 190, height: 190)
                    .offset(y: -70)
            }
                .ignoresSafeArea()
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
        // 시작 순간 화면이 비활성이었으면 튜토리얼 판단을 건너뛰었을 수 있다.
        if phase == .active, !isFirstRunTutorialPending, !isInitialLaunchOverlayVisible,
           proAccess.grantsAccess, FirstRunTutorialStore().defersPermissionPrompts {
            _ = prepareFirstRunTutorial()
        }
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
                TaptionPlanDiagnosticsSession.recordPhase(.active)
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
                TaptionPlanDiagnosticsSession.recordPhase(.background)
                if proAccess.grantsAccess {
                    await model.sceneEnteredBackground()
                } else {
                    await model.suspendForCommerceLock()
                }
            case .inactive:
                TaptionPlanDiagnosticsSession.recordPhase(.inactive)
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
        initialLaunchStartedAt = ProcessInfo.processInfo.systemUptime
        TaptionPlanDiagnosticsLogger.shared.record("initial_launch_started", fields: TaptionPlanDiagnosticsSession.launchContextFields())
        recordLaunchGate("launch_task_started")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            launchTimeoutPassed = true
            dismissInitialLaunchOverlayIfReady()
        }
        startInitialLaunchProgressTicker()
        advanceInitialLaunchProgress(to: 0.04)
        await proAccess.refreshAccess()
        hasCompletedInitialProRefresh = true
        recordLaunchGate("pro_refresh")
        advanceInitialLaunchProgress(to: 0.18)
        scheduleDeferredStoreKitProductLoad()
        if proAccess.grantsAccess {
            advanceInitialLaunchProgress(to: 0.20)
            await model.sceneBecameActive()
            recordLaunchGate("scene_became_active")
            advanceInitialLaunchProgress(to: 0.86)
            // 권한 준비는 스플래시가 걷힌 뒤로 미룬다(dismissInitialLaunchOverlayIfReady).
        } else {
            advanceInitialLaunchProgress(to: 0.80)
            await model.suspendForCommerceLock()
        }
        if model.isAppLocked {
            lockGeneration &+= 1
            automaticBiometricAttemptedGeneration = nil
        }
        if let planID = TaptionPlanAppDelegate.takePendingPlanID(),
           let url = URL(
                string: "taptionplan://plan/\(planID.uuidString)"
           ) {
            await model.openDeepLink(url)
        }
        advanceInitialLaunchProgress(to: 0.96)
        isSecurityStateReady = true
        advanceInitialLaunchProgress(to: 0.98)
        dismissInitialLaunchOverlayIfReady()
    }

    private func scheduleDeferredPermissionPreparation() {
        Task { @MainActor in
            await Task.yield()
            await model.refreshPermissions()
            guard scenePhase == .active, proAccess.grantsAccess else { return }
            if prepareFirstRunTutorial() { return }
            model.presentPermissionOnboardingIfNeeded()
            await model.requestMissingLocationPermissionAtLaunch()
            await activateRequiredSensorsIfReady()
            await reconcileSensorLiveActivity()
        }
    }

    /// 잠금 화면이나 상점 잠금 위로 올라오지 않는다. 잠금을 풀면 보던 단계에서 다시 뜬다.
    private var firstRunTutorialBinding: Binding<Bool> {
        Binding(
            get: { isFirstRunTutorialPending && !model.isAppLocked && proAccess.grantsAccess },
            set: { _ in }
        )
    }

    /// 튜토리얼을 띄우면 true. 그 동안 권한 시트와 위치 팝업은 나오지 않는다.
    private func prepareFirstRunTutorial() -> Bool {
        guard NSClassFromString("XCTestCase") == nil else { return false }
        let store = FirstRunTutorialStore()
        let snapshot = model.snapshot
        let decision = FirstRunTutorialPolicy.decision(
            outcome: store.outcome,
            savedStep: store.savedStep,
            permissionOnboardingDone: UserDefaults.standard.bool(forKey: AppModel.permissionOnboardingKey),
            hasUserData: !snapshot.plans.isEmpty
                || !snapshot.actuals.isEmpty
                || !snapshot.places.isEmpty
                || !snapshot.travel.isEmpty
                || model.settings.frequentPlaces.contains { $0.point != nil }
        )
        switch decision {
        case .present(let step):
            store.save(step: step)
            isFirstRunTutorialPending = true
            return true
        case .markExistingUser:
            store.finish(.existingUser)
            return false
        case .none:
            return false
        }
    }

    private func finishFirstRunTutorial() {
        isFirstRunTutorialPending = false
        Task { @MainActor in
            await activateRequiredSensorsIfReady()
            await reconcileSensorLiveActivity()
        }
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

    /// 위젯·알림·URL이 보낸 링크를 받는다. 지도가 루트 화면이므로 레거시 탭
    /// 스위치와 상관없이 항상 `AppModel`에 넘긴다. 화면을 옮기는 일은
    /// `MapHomeView`가 `pendingMapHomeRoute`를 소비하면서 한다.
    private func handleOpenURL(_ url: URL) {
        Task { @MainActor in
            await model.bootstrap()
            await model.openDeepLink(url)
        }
    }

    private func handlePlanNotification(_ notification: Notification) {
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
                    recordLaunchGate("map_shell")
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

    /// 등록된 비밀번호의 자릿수(이전에 4자리로 등록했다면 4).
    private var pinDigits: Int { model.securityStatus.pinDigits }

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
                    korean: "\(pinDigits)자리 비밀번호",
                    english: "\(pinDigits)-digit PIN",
                    rawPreference: languageRawValue
                ),
                text: $pin
            )
                .keyboardType(.numberPad)
                .textContentType(.password)
                .multilineTextAlignment(.center)
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(22)), weight: .bold))
                .foregroundStyle(Color.tpInk)
                .padding(.horizontal, 18)
                .frame(width: 210, height: 48)
                .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: TaptionRadius.card))
                .onChange(of: pin) { _, value in
                    pin = String(value.filter(\.isNumber).prefix(pinDigits))
                    if pin.count == pinDigits {
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
                        language.text(
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
        VStack(alignment: .leading, spacing: TaptionSpacing.regular) {
            Image(systemName: "sensor.fill")
                .accessibilityHidden(true)
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(30)), weight: .bold))
                .foregroundStyle(Color.tpReferenceRose)
            Text(language.text("필수 권한 설정", "Required permissions"))
                .font(.taption(size: 27, weight: .black))
                .foregroundStyle(Color.tpInk)
            Text(
                language.text(
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
        .background(Color.tpCard, in: RoundedRectangle(cornerRadius: 20))
    }

    private func permissionCard(
        _ permission: RequiredPermission
    ) -> some View {
        let missing = gate.missing.contains(permission)
        return HStack(spacing: 12) {
            Image(systemName: metadata(permission).icon)
                .accessibilityHidden(true)
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(18)), weight: .semibold))
                .foregroundStyle(
                    missing ? Color.tpReferenceRose : Color.tpReferenceMint
                )
                .frame(width: 38, height: 38)
                .background(
                    (missing ? Color.tpReferenceRose : Color.tpReferenceMint)
                        .opacity(0.1),
                    in: RoundedRectangle(cornerRadius: TaptionRadius.panel)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(metadata(permission).title)
                    .font(.taption(size: 15, weight: .bold))
                    .foregroundStyle(Color.tpInk)
                Text(
                    missing
                        ? language.text("설정 필요", "Required")
                        : language.text("허용됨", "Allowed")
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
                .background(Color.tpPrimaryFill, in: Capsule())
                .buttonStyle(.plain)
                .disabled(requesting != nil)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .accessibilityLabel(language.text("허용됨", "Granted"))
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(22))))
                    .foregroundStyle(Color.tpReferenceMint)
            }
        }
        .padding(13)
        .background(Color.tpCard, in: RoundedRectangle(cornerRadius: 16))
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
            language.text("설정 열기", "Open Settings")
        default:
            language.text("허용하기", "Allow")
        }
    }

    private func metadata(
        _ permission: RequiredPermission
    ) -> (icon: String, title: String) {
        switch permission {
        case .locationAlways:
            ("location.fill", language.text("위치 항상 허용", "Always Location"))
        case .locationPrecise:
            ("scope", language.text("정확한 위치", "Precise Location"))
        case .motion:
            ("figure.walk.motion", language.text("동작 및 피트니스", "Motion & Fitness"))
        case .healthKitRequestCompleted:
            ("heart.fill", language.text("건강 데이터", "Health Data"))
        case .calendar:
            ("calendar", language.text("캘린더 전체 접근", "Full Calendar Access"))
        case .notifications:
            ("bell.fill", language.text("알림", "Notifications"))
        case .liveActivities:
            ("iphone.radiowaves.left.and.right", language.text("실시간 현황", "Live Activities"))
        }
    }

    private var language: AppLanguagePreference.ResolvedLanguage {
        AppLanguagePreference.resolve(rawValue: languageRawValue)
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
                                .font(.system(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .bold))
                                .frame(width: 40, height: 40)
                                .background(
                                    Color.black.opacity(0.06),
                                    in: Circle()
                                )
                                .taptionTouchTarget(visualWidth: 40, visualHeight: 40)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(language.text("닫기", "Close"))
                    }
                }

                Image(systemName: "sparkles")
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(34)), weight: .bold))
                    .foregroundStyle(Color.tpReferenceBlue)
                    .frame(width: 72, height: 72)
                    .background(
                        Color.tpReferenceBlue.opacity(0.12),
                        in: RoundedRectangle(
                            cornerRadius: 22,
                            style: .continuous
                        )
                    )

                VStack(spacing: TaptionSpacing.cozy) {
                    Text(title)
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(25)),
                            weight: .bold
                        ))
                        .foregroundStyle(Color.tpInk)
                    Text(detail)
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 11) {
                    featureRow(
                        "cloud.sun.fill",
                        language.text("시간대별 날씨 기록", "Hourly weather records")
                    )
                    featureRow(
                        "location.fill",
                        language.text("실시간 GPS와 이동 경로", "Live GPS and travel routes")
                    )
                    featureRow(
                        "tram.fill",
                        language.text("지하철·버스 자동 판정", "Automatic subway and bus detection")
                    )
                    featureRow(
                        "icloud.fill",
                        language.text("iCloud 백업과 기기 연동", "iCloud backup and device sync")
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
                    ProgressView(language.text("Pro 상태 확인 중", "Checking Pro status"))
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
            Button(language.text("확인", "OK")) { controller.message = nil }
        } message: {
            proMessage
        }
    }

    private var title: String {
        switch controller.state {
        case .loading:
            "Taption Plan Pro"
        case .trialNotStarted:
            language.text("14일 무료 체험", "14-day free trial")
        case .trial(_, let remainingDays):
            language.text(
                "14일 무료 체험 · \(remainingDays)일 남음",
                "14-day free trial · \(remainingDays) days left"
            )
        case .purchased:
            language.text("Pro를 영구 이용 중입니다", "You own Pro permanently")
        case .expired:
            language.text("14일 무료 체험이 종료되었습니다", "Your 14-day free trial has ended")
        }
    }

    private var detail: String {
        switch controller.state {
        case .loading:
            language.text(
                "구매 및 체험 상태를 확인하고 있습니다.",
                "Checking your purchase and trial status."
            )
        case .trialNotStarted:
            language.text(
                "버튼을 누르면 14일 무료 체험이 시작됩니다. 자동 결제는 없습니다.",
                "Tap the button to start a 14-day free trial. You will not be charged automatically."
            )
        case .trial:
            language.text(
                "14일 무료 체험이 끝나도 자동 결제되지 않으며, 한 번 구매하면 계속 사용할 수 있습니다.",
                "The trial does not renew automatically. A single purchase unlocks Pro permanently."
            )
        case .purchased:
            language.text(
                "추가 결제나 자동 갱신 없이 모든 기능을 계속 사용할 수 있습니다.",
                "Keep using every feature with no additional payment or renewal."
            )
        case .expired:
            language.text(
                "계속 사용하려면 Pro를 한 번 구매하거나 기존 구매 내역을 복원해 주세요.",
                "Purchase Pro once or restore an existing purchase to continue."
            )
        }
    }

    private var language: AppLanguagePreference.ResolvedLanguage {
        AppLanguagePreference.resolve(rawValue: languageRawValue)
    }

    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: 12) {
            if controller.state == .trialNotStarted {
                Button {
                    controller.startTrial()
                } label: {
                    Text(language.text("14일 무료 체험 시작", "Start 14-day free trial"))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(17)), weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.tpPrimaryFill)
            }

#if DEBUG
            if case .expired = controller.state {
                Button {
                    controller.resetTrialForTesting()
                } label: {
                    Text(language.text(
                        "개발자 체험 14일 초기화",
                        "Reset developer trial for 14 days"
                    ))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(17)), weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.tpPrimaryFill)
            }
#endif

            if TaptionCommercePolicy.supportsPaidPurchase,
               !controller.hasPermanentAccess {
                Button {
                    Task { await controller.purchase() }
                } label: {
                    VStack(spacing: 3) {
                        Text(purchaseTitle)
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(16)), weight: .bold))
                        Text(
                            language.text(
                                "한 번 결제 · 자동 갱신 없음",
                                "One-time purchase · No auto-renewal"
                            )
                        )
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)

                Button(language.text("구매 복원", "Restore purchase")) {
                    Task { await controller.restore() }
                }
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Color.tpReferenceBlue)
            } else if allowsDismiss {
                Button(language.text("계속 사용", "Continue")) { dismiss() }
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(17)), weight: .bold))
                    .buttonStyle(.borderedProminent)
                    .tint(Color.tpPrimaryFill)
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
            return language.text(
                "\(displayPrice)로 Pro 영구 구매",
                "Buy Pro permanently for \(displayPrice)"
            )
        }
        return language.text("Pro 영구 구매", "Buy Pro permanently")
    }

    @ViewBuilder
    private var proMessage: some View {
        switch controller.message {
        case .trialStarted:
            Text(language.text("14일 무료 체험이 시작되었습니다.", "Your 14-day free trial has started."))
        case .trialAlreadyUsed:
            Text(language.text(
                "이 기기 또는 iCloud에 저장된 기록에서 14일 무료 체험을 이미 사용했습니다.",
                "The 14-day free trial has already been used on this device or in its synced iCloud record."
            ))
#if DEBUG
        case .trialResetFailed:
            Text(language.text(
                "개발자 체험 기록을 초기화하지 못했습니다.",
                "The developer trial record could not be reset."
            ))
#endif
        case .purchaseCompleted:
            Text(language.text("Pro 영구 구매가 완료되었습니다.", "Your permanent Pro purchase is complete."))
        case .purchasePending:
            Text(language.text("구매 승인을 기다리고 있습니다.", "Waiting for purchase approval."))
        case .purchaseUnavailable:
            Text(language.text(
                "App Store에서 구매 항목을 아직 불러오지 못했습니다.",
                "The purchase is not available from the App Store yet."
            ))
        case .receiptVerificationFailed:
            Text(language.text("구매 영수증을 확인하지 못했습니다.", "The purchase receipt could not be verified."))
        case .purchaseFailed:
            Text(language.text(
                "구매를 완료하지 못했습니다. 잠시 후 다시 시도해 주세요.",
                "The purchase could not be completed. Please try again later."
            ))
        case .restoreCompleted:
            Text(language.text("구매 내역을 복원했습니다.", "Your purchase was restored."))
        case .restoreNotFound:
            Text(language.text("복원할 Pro 구매 내역이 없습니다.", "No Pro purchase was found to restore."))
        case .restoreFailed:
            Text(language.text(
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
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(16)), weight: .semibold))
                .foregroundStyle(Color.tpReferenceBlue)
                .frame(width: 24)
            Text(title)
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .semibold))
                .foregroundStyle(Color.tpInk)
        }
    }
}

#Preview {
    AppShellView()
}
