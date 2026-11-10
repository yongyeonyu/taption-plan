import ActivityKit
import SwiftUI
import UIKit

private struct PermissionOnboardingStep: Identifiable {
    let feature: PermissionFeature
    let icon: String
    let title: String
    let detail: String

    var id: String { feature.rawValue }
}

struct PermissionOnboardingProgress: Equatable {
    private(set) var index: Int

    init(index: Int = 0) {
        self.index = max(0, index)
    }

    mutating func completeRequest(_ didComplete: Bool) {
        guard didComplete else { return }
        index += 1
    }

    mutating func skipCurrentStep() {
        index += 1
    }
}

struct PermissionOnboardingSheet: View {
    @Bindable var model: AppModel
    @State private var progress = PermissionOnboardingProgress()
    @State private var isRequesting = false
    @State private var requestError: String?
    @State private var skipped: Set<String> = []
    @State private var liveActivitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
    /// 처음 실행 튜토리얼 안에 들어가면 제목과 끝내기 단추는 튜토리얼이 맡는다.
    private let isEmbedded: Bool
    private let language = MapHomeLanguage.current
    @Environment(\.scenePhase) private var scenePhase

    private static let features: [PermissionFeature] = [.location, .motion, .health, .photos, .calendar, .notifications]

    private var steps: [PermissionOnboardingStep] {
        [
            PermissionOnboardingStep(
                feature: .location,
                icon: "mappin.and.ellipse",
                title: language.text("위치 · 이동", "Location · Travel"),
                detail: language.text("머문 장소와 이동 경로를 자동으로 남깁니다. ‘항상 허용’이어야 앱을 닫은 뒤에도 기록됩니다.", "Records places and routes automatically. Only ‘Always’ keeps recording after you close the app.")
            ),
            PermissionOnboardingStep(
                feature: .motion,
                icon: "figure.walk.motion",
                title: language.text("동작 · 피트니스", "Motion · Fitness"),
                detail: language.text("걷기·달리기 같은 이동 상태와 걸음, 층수 변화를 추정합니다.", "Estimates walking, running, steps, and floor changes.")
            ),
            PermissionOnboardingStep(
                feature: .health,
                icon: "heart.text.square",
                title: language.text("건강 데이터", "Health"),
                detail: language.text("iPhone 건강 앱과 승인된 건강 앱의 걸음·운동·수면을 읽습니다. Apple Watch 기록도 함께 반영합니다.", "Reads steps, workouts, and sleep from Health and approved apps, including Apple Watch.")
            ),
            PermissionOnboardingStep(
                feature: .photos,
                icon: "photo.on.rectangle",
                title: language.text("사진", "Photos"),
                detail: language.text("사진을 찍은 위치와 시각에 맞춰 지도에 보여주고, 재생 화면 녹화 영상을 사진 앱에 저장합니다.", "Shows photos on the map by place and time, and saves playback videos to Photos.")
            ),
            PermissionOnboardingStep(
                feature: .calendar,
                icon: "calendar",
                title: language.text("캘린더", "Calendar"),
                detail: language.text("이미 잡혀 있는 일정을 시간표에 함께 보여줍니다.", "Shows your existing events alongside your schedule.")
            ),
            PermissionOnboardingStep(
                feature: .notifications,
                icon: "bell.badge",
                title: language.text("알림", "Notifications"),
                detail: language.text("계획한 시각에 맞춰 알려줍니다.", "Reminds you at planned times.")
            ),
        ]
    }

    init(model: AppModel, initialFeature: PermissionFeature? = nil, isEmbedded: Bool = false) {
        self.model = model
        self.isEmbedded = isEmbedded
        // 튜토리얼로 돌아오면 이미 답한 권한을 다시 묻지 않는다.
        let firstUnanswered = isEmbedded
            ? Self.features.firstIndex { model.permissionState(for: $0) == .notDetermined } ?? Self.features.count
            : 0
        _progress = State(
            initialValue: PermissionOnboardingProgress(
                index: initialFeature.flatMap { feature in
                    Self.features.firstIndex(of: feature)
                } ?? firstUnanswered
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isEmbedded { header }
            ScrollView(showsIndicators: false) {
                VStack(spacing: 9) {
                    allowAllButton
                    ForEach(
                        Array(steps.enumerated()),
                        id: \.element.id
                    ) { offset, step in
                        stepCard(step, offset: offset)
                    }
                    liveActivityCard
                    if isEmbedded, hasDeniedPermission {
                        Button(language.text("iOS 설정에서 바꾸기", "Change in iOS Settings")) {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                        .font(.taption(size: 10, weight: .bold))
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("firstRunOpenSettings")
                    }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 12)
            }
            if !isEmbedded || !isFinished { footer }
        }
        .background(Color.tpBackground)
        // iOS 설정에 다녀온 뒤에도 실제 값을 보여 준다.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            liveActivitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
            if isEmbedded { Task { await model.refreshPermissions() } }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: TaptionSpacing.compact) {
            Text(language.text("하루는 알아서 기록됩니다", "Your day records itself"))
                .font(.taption(size: 15, weight: .black))
                .foregroundStyle(Color.tpInk)
            Text(language.text("BOKKI Plan은 위치·건강·캘린더를 읽어 하루를 대신 적습니다. 필요한 것만 허용해도 되고, 설정에서 언제든 바꿀 수 있습니다.", "BOKKI Plan reads location, health, and calendar to write your day for you. Allow only what you need and change it anytime in Settings."))
                .font(.taption(size: 9))
                .foregroundStyle(Color.tpSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.tpCard)
    }

    private var footer: some View {
        HStack(spacing: TaptionSpacing.regular) {
            if isFinished {
                Button(language.text("시작하기", "Get started")) { finish() }
                    .font(.taption(size: 11, weight: .bold))
                    .buttonStyle(.borderedProminent)
                    .tint(Color.tpPrimaryFill)
                    .frame(maxWidth: .infinity)
            } else {
                if !isEmbedded {
                    Button(language.text("전체 건너뛰기", "Skip all")) { finish() }
                        .font(.taption(size: 10, weight: .bold))
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.tpSecondary)
                        .disabled(isRequesting || model.isRequestingPermission)
                }
                Spacer(minLength: 4)
                Text("\(progress.index + 1) / \(steps.count)")
                    .font(.taption(size: 9, weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.tpCard)
    }

    /// 실시간 현황은 요청 창이 없고 iOS 설정에서만 바꾼다. 그래서 순서 요청과 따로 둔다(PRM1105A01).
    private var liveActivityCard: some View {
        VStack(alignment: .leading, spacing: TaptionSpacing.regular) {
            HStack(spacing: 9) {
                Image(systemName: "lock.iphone")
                    .accessibilityHidden(true)
                    .font(.taption(size: 14))
                    .foregroundStyle(Color.tpInk)
                    .frame(width: 29, height: 29)
                    .background(Color.tpBackground, in: RoundedRectangle(cornerRadius: TaptionRadius.control))
                VStack(alignment: .leading, spacing: 2) {
                    Text(language.text("잠금화면 · 실시간 현황", "Lock Screen · Live Activities"))
                        .font(.taption(size: 11, weight: .bold))
                        .foregroundStyle(Color.tpInk)
                    Text(language.text(
                        "지금 활동을 잠금화면과 다이나믹 아일랜드에 보여줍니다.",
                        "Shows your current activity on the Lock Screen and Dynamic Island."
                    ))
                    .font(.taption(size: 8))
                    .foregroundStyle(Color.tpSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Text(liveActivitiesEnabled ? language.text("켜짐", "On") : language.text("꺼짐", "Off"))
                    .font(.taption(size: 8.5, weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
            }
            if !liveActivitiesEnabled {
                Button(language.text("설정 열기", "Open Settings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .font(.taption(size: 10, weight: .bold))
                .buttonStyle(.borderedProminent)
                .tint(Color.tpPrimaryFill)
                .padding(.leading, 38)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .draftCard()
        .accessibilityIdentifier("permissionLiveActivities")
    }

    private func stepCard(
        _ step: PermissionOnboardingStep,
        offset: Int
    ) -> some View {
        let isCurrent = offset == progress.index
        return VStack(alignment: .leading, spacing: TaptionSpacing.regular) {
            HStack(spacing: 9) {
                Image(systemName: step.icon)
                    .accessibilityHidden(true)
                    .font(.taption(size: 14))
                    .foregroundStyle(Color.tpInk)
                    .frame(width: 29, height: 29)
                    .background(
                        Color.tpBackground,
                        in: RoundedRectangle(cornerRadius: TaptionRadius.control)
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
                if needsAlwaysLocation(step) {
                    // 「항상 허용」이 아니면 눌러서 iOS 설정으로 간다(대표 지시).
                    Button { LocationAlwaysPrompt.settingsURL.map { UIApplication.shared.open($0) } } label: {
                        Text(language.text("설정에서 '항상'으로", "Set to Always"))
                            .font(.taption(size: 8.5, weight: .bold))
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.trailing)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(stateText(step))
                        .font(.taption(size: 8.5, weight: .bold))
                        .foregroundStyle(Color.tpSecondary)
                }
            }
            if needsAlwaysLocation(step) {
                Text(LocationAlwaysPrompt.message(language))
                    .font(.taption(size: 8, weight: .semibold))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 38)
            }
            if isCurrent {
                HStack(spacing: 10) {
                    Button(language.text("허용하기", "Allow")) {
                        Task { await request(step) }
                    }
                    .font(.taption(size: 10, weight: .bold))
                    .buttonStyle(.borderedProminent)
                    .tint(Color.tpPrimaryFill)
                    Button(language.text("건너뛰기", "Skip")) {
                        skipped.insert(step.id)
                        requestError = nil
                        progress.skipCurrentStep()
                    }
                    .font(.taption(size: 10, weight: .bold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.tpSecondary)
                }
                .disabled(isRequesting || model.isRequestingPermission)
                .padding(.leading, 38)
                if let requestError {
                    Text(requestError)
                        .font(.taption(size: 8))
                        .foregroundStyle(Color.tpSecondary)
                        .padding(.leading, 38)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .draftCard()
        .overlay(
            RoundedRectangle(cornerRadius: TaptionRadius.card, style: .continuous)
                .stroke(
                    isCurrent ? Color.tpInk.opacity(0.32) : Color.clear,
                    lineWidth: 1
                )
        )
        .opacity(offset > progress.index ? 0.5 : 1)
    }

    private var isFinished: Bool { progress.index >= Self.features.count }

    /// 위치를 이미 물었는데 「항상」이 아니다.
    private func needsAlwaysLocation(_ step: PermissionOnboardingStep) -> Bool {
        step.feature == .location && model.permissionState(for: .location) != .notDetermined
            && model.sensorService?.hasAlwaysLocationAuthorization() != true
    }

    private var hasDeniedPermission: Bool {
        Self.features.contains { model.permissionState(for: $0) == .denied }
    }

    private func stateText(_ step: PermissionOnboardingStep) -> String {
        if skipped.contains(step.id) { return language.text("나중에", "Later") }
        let state = model.permissionState(for: step.feature)
        if state == .notDetermined { return "" }
        return FirstRunTutorialPolicy.permissionLabel(
            step.feature,
            state: state,
            isLocationAlways: model.sensorService?.hasAlwaysLocationAuthorization() == true,
            language: language
        )
    }

    private func request(_ step: PermissionOnboardingStep) async {
        guard !isRequesting else { return }
        isRequesting = true
        let didComplete = await requestPermission(for: step)
        progress.completeRequest(didComplete)
        if didComplete {
            requestError = nil
            // 시트가 떠 있는 동안에는 루트 경고창이 뜨지 않는다. 결과는 각 줄의
            // 상태 문구로 보여주고 안내 문구는 지운다.
            model.clearError()
        } else {
            requestError = language.text("요청을 완료하지 못했습니다. 다시 시도해 주세요.", "Couldn't finish the request. Please try again.")
        }
        isRequesting = false
    }

    private func requestPermission(
        for step: PermissionOnboardingStep
    ) async -> Bool {
        switch step.feature {
        case .location:
            let didEnable = await model.enableLocationCollection()
            // 거부하면 모델이 이 시트를 다시 띄우려 한다. 튜토리얼 안에서는 줄의 상태 문구로 보여 준다.
            if isEmbedded { model.isPermissionOnboardingPresented = false }
            return didEnable
        case .motion:
            await model.requestRequiredPermission(.motion)
            // 시뮬레이터처럼 팝업 없이 끝나는 기기가 있다. 상태는 실제 값만 줄에 보여 주고 다음으로 간다.
            return true
        case .health: return await model.requestHealth()
        case .calendar: return await model.requestCalendar()
        case .notifications: return await model.requestNotifications()
        case .photos:
            await model.requestPhotos()
            return model.permissionState(for: .photos) != .notDetermined
        default: return false
        }
    }

    /// 아직 답하지 않은 권한을 위에서부터 차례로 요청한다. 시스템 권한창은 한 번에 하나만 뜬다.
    /// 거부했거나 실시간 현황이 꺼져 있으면 앱이 다시 물을 수 없어 끝에 iOS 설정을 연다.
    private func requestAll() {
        guard !isRequesting else { return }
        isRequesting = true
        Task {
            for step in steps where model.permissionState(for: step.feature) == .notDetermined {
                guard await requestPermission(for: step) else {
                    requestError = language.text("요청을 완료하지 못했습니다. 다시 시도해 주세요.", "Couldn't finish the request. Please try again.")
                    isRequesting = false
                    return
                }
                requestError = nil
                model.clearError()
            }
            await model.refreshPermissions()
            progress = PermissionOnboardingProgress(index: Self.features.count)
            liveActivitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
            isRequesting = false
            if !isAllAllowed, let url = URL(string: UIApplication.openSettingsURLString) {
                await UIApplication.shared.open(url)
            }
        }
    }

    private var isAllAllowed: Bool {
        liveActivitiesEnabled && Self.features.allSatisfy { model.permissionState(for: $0).isGranted }
    }

    private var allowAllButton: some View {
        Button(action: requestAll) {
            Text(isAllAllowed ? language.text("모두 허용됨", "All allowed") : language.text("모두 허용", "Allow all"))
                .font(.taption(size: 12, weight: .bold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(.white)
                .background(Color.tpPrimaryFill, in: RoundedRectangle(cornerRadius: TaptionRadius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isAllAllowed || isRequesting || model.isRequestingPermission)
        .opacity(isAllAllowed ? 0.5 : 1)
        .accessibilityIdentifier("permissionAllowAll")
    }

    private func finish() {
        Task { await model.finishPermissionOnboarding() }
    }
}
