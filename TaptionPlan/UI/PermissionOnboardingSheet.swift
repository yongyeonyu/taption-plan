import SwiftUI

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
    /// 처음 실행 튜토리얼 안에 들어가면 제목과 끝내기 단추는 튜토리얼이 맡는다.
    private let isEmbedded: Bool

    private static let steps: [PermissionOnboardingStep] = [
        PermissionOnboardingStep(
            feature: .location,
            icon: "mappin.and.ellipse",
            title: "위치 · 이동",
            detail: "머문 장소와 이동 경로를 자동으로 남깁니다. ‘항상 허용’이어야 앱을 닫은 뒤에도 기록됩니다."
        ),
        PermissionOnboardingStep(
            feature: .motion,
            icon: "figure.walk.motion",
            title: "동작 · 피트니스",
            detail: "걷기·달리기 같은 이동 상태와 걸음, 층수 변화를 추정합니다."
        ),
        PermissionOnboardingStep(
            feature: .health,
            icon: "heart.text.square",
            title: "건강 데이터",
            detail: "iPhone 건강 앱과 승인된 건강 앱의 걸음·운동·수면을 읽습니다. Apple Watch 기록도 함께 반영합니다."
        ),
        PermissionOnboardingStep(
            feature: .photos,
            icon: "photo.on.rectangle",
            title: "사진",
            detail: "사진을 찍은 위치와 시각에 맞춰 지도에 보여주고, 재생 화면 녹화 영상을 사진 앱에 저장합니다."
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

    init(model: AppModel, initialFeature: PermissionFeature? = nil, isEmbedded: Bool = false) {
        self.model = model
        self.isEmbedded = isEmbedded
        _progress = State(
            initialValue: PermissionOnboardingProgress(
                index: initialFeature.flatMap { feature in
                    Self.steps.firstIndex { $0.feature == feature }
                } ?? 0
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isEmbedded { header }
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
            if !isEmbedded || !isFinished { footer }
        }
        .background(Color.tpBackground)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: TaptionSpacing.compact) {
            Text("하루는 알아서 기록됩니다")
                .font(.taption(size: 15, weight: .black))
                .foregroundStyle(Color.tpInk)
            Text("BOKKI Plan은 위치·건강·캘린더를 읽어 하루를 대신 적습니다. 필요한 것만 허용해도 되고, 설정에서 언제든 바꿀 수 있습니다.")
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
                Button("시작하기") { finish() }
                    .font(.taption(size: 11, weight: .bold))
                    .buttonStyle(.borderedProminent)
                    .tint(Color.tpPrimaryFill)
                    .frame(maxWidth: .infinity)
            } else {
                Button("모두 허용") { requestRemaining() }
                    .font(.taption(size: 10, weight: .bold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.tpInk)
                    .disabled(isRequesting || model.isRequestingPermission)
                if !isEmbedded {
                    Button("전체 건너뛰기") { finish() }
                        .font(.taption(size: 10, weight: .bold))
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.tpSecondary)
                        .disabled(isRequesting || model.isRequestingPermission)
                }
                Spacer(minLength: 4)
                Text("\(progress.index + 1) / \(Self.steps.count)")
                    .font(.taption(size: 9, weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.tpCard)
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
                    .tint(Color.tpPrimaryFill)
                    Button("건너뛰기") {
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

    private var isFinished: Bool { progress.index >= Self.steps.count }

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
            requestError = "요청을 완료하지 못했습니다. 다시 시도해 주세요."
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

    /// 남은 권한을 순서대로 한 번에 요청한다. 시스템 권한창은 한 번에 하나만
    /// 뜨므로 순차로 진행하고, 중간에 버튼을 다시 누르지 못하게 막는다.
    private func requestRemaining() {
        guard !isRequesting else { return }
        isRequesting = true
        Task {
            while progress.index < Self.steps.count {
                let didComplete = await requestPermission(
                    for: Self.steps[progress.index]
                )
                progress.completeRequest(didComplete)
                if didComplete {
                    requestError = nil
                    model.clearError()
                } else {
                    requestError = "요청을 완료하지 못했습니다. 다시 시도해 주세요."
                    break
                }
            }
            isRequesting = false
        }
    }

    private func finish() {
        Task { await model.finishPermissionOnboarding() }
    }
}
