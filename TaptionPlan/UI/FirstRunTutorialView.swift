import MapKit
import SwiftUI
import UIKit

/// 처음 실행 튜토리얼(FRT1102A01). 설정 화면을 새로 만들지 않고 기존 화면과 모델 함수를 쓴다.
/// 입력은 그 자리에서 저장되므로, 도중에 앱을 닫아도 지금까지 고른 값은 남는다.
struct FirstRunTutorialView: View {
    @Bindable var model: AppModel
    let onFinished: () -> Void

    @State private var step: FirstRunTutorialStep
    @State private var pin = ""
    @State private var confirmation = ""
    @State private var passwordMessage: String?
    @State private var isFinishing = false

    private let store = FirstRunTutorialStore()
    private let language = MapHomeLanguage.current

    init(model: AppModel, onFinished: @escaping () -> Void) {
        self.model = model
        self.onFinished = onFinished
        _step = State(initialValue: FirstRunTutorialStore().savedStep ?? .permissions)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            header
            page
                .id(step)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scrollDismissesKeyboard(.interactively)
            bottomBar
        }
        .background(Color.tpBackground.ignoresSafeArea())
        .disabled(isFinishing)
        .accessibilityIdentifier("firstRunTutorial")
    }

    // MARK: 위쪽

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                if let previous = step.previous { move(to: previous) }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: TaptionType.scaled(TaptionType.title), weight: .semibold))
                    .foregroundStyle(Color.tpInk)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(step.previous == nil ? 0 : 1)
            .disabled(step.previous == nil)
            .accessibilityLabel(language.text("이전", "Back"))

            HStack(spacing: 5) {
                ForEach(FirstRunTutorialStep.allCases) { item in
                    Capsule()
                        .fill(item.rawValue <= step.rawValue ? Color.tpAccent : Color.tpLine)
                        .frame(height: 4)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("\(step.rawValue + 1) / \(FirstRunTutorialStep.allCases.count)")

            Button(language.text("전체 건너뛰기", "Skip all")) {
                finish(.skipped)
            }
            .font(.system(size: TaptionType.scaled(TaptionType.label), weight: .semibold, design: .rounded))
            .foregroundStyle(Color.tpSecondary)
            .buttonStyle(.plain)
            .frame(minHeight: 44)
        }
        .padding(.horizontal, 12)
    }

    private var header: some View {
        HStack(spacing: 12) {
            FirstRunMascot(scene: scene(of: step), size: 72)
            VStack(alignment: .leading, spacing: 4) {
                Text(title(of: step))
                    .font(.system(size: TaptionType.scaled(TaptionType.display), weight: .bold, design: .rounded))
                    .foregroundStyle(Color.tpInk)
                Text(detail(of: step))
                    .font(.system(size: TaptionType.scaled(TaptionType.body), weight: .medium, design: .rounded))
                    .foregroundStyle(Color.tpSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    private func scene(of step: FirstRunTutorialStep) -> HwarangScene {
        switch step {
        case .permissions: .groom
        case .home: .sleep
        case .workAndSchool: .work
        case .salary: .eat
        case .password: .study
        case .clipEditor: .yarn
        case .counters: .stretch
        }
    }

    private func title(of step: FirstRunTutorialStep) -> String {
        switch step {
        case .permissions: language.text("권한 허용", "Permissions")
        case .home: language.text("집 위치", "Home")
        case .workAndSchool: language.text("회사 · 학교", "Work · School")
        case .salary: language.text("연봉 설정", "Salary")
        case .password: language.text("비밀번호", "Password")
        case .clipEditor: language.text("클립 편집", "Clip editor")
        case .counters: language.text("카운터", "Counters")
        }
    }

    private func detail(of step: FirstRunTutorialStep) -> String {
        switch step {
        case .permissions: language.text("하루를 자동으로 기록하는 데 씁니다. 필요한 것만 허용해도 됩니다.", "Used to record your day automatically. Allow only what you need.")
        case .home: language.text("집에 머문 시간을 자동으로 구분합니다.", "Time at home is recognized automatically.")
        case .workAndSchool: language.text("업무와 학습 시간을 구분하는 기준이 됩니다.", "Used to tell work and study time apart.")
        case .salary: language.text("업무 시간에만 번 돈이 쌓입니다. 금액은 이 기기에만 저장됩니다.", "Earnings grow only during work time. Stored only on this device.")
        case .password: language.text("앱 잠금과 iCloud 백업에 같은 비밀번호를 씁니다.", "App lock and iCloud backup share this password.")
        case .clipEditor: language.text("자동 기록이 틀렸으면 영상 편집처럼 고칩니다.", "Fix automatic records the way you edit a video.")
        case .counters: language.text("화랑이 머리 위에 보여 줄 것을 고릅니다.", "Choose what appears above Hwarang.")
        }
    }

    // MARK: 단계

    @ViewBuilder
    private var page: some View {
        switch step {
        case .permissions:
            PermissionOnboardingSheet(model: model, isEmbedded: true)
        case .home:
            ScrollView {
                FirstRunPlacePicker(model: model, destination: .home, language: language)
                    .padding(18)
            }
        case .workAndSchool:
            ScrollView {
                VStack(spacing: 12) {
                    FirstRunPlacePicker(model: model, destination: .company, language: language)
                    FirstRunPlacePicker(model: model, destination: .school, language: language)
                }
                .padding(18)
            }
        case .salary:
            MapHomeSalarySettingsSheet(
                language: language,
                monthWorkSeconds: 0,
                projectedMonthWorkSeconds: 0,
                showsOnlyPayInput: true
            )
        case .password:
            FirstRunPasswordPage(
                model: model,
                language: language,
                pin: $pin,
                confirmation: $confirmation,
                message: $passwordMessage
            )
        case .clipEditor:
            FirstRunClipEditorPage(language: language)
        case .counters:
            FirstRunCountersPage(language: language)
        }
    }

    // MARK: 아래쪽

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button(language.text("건너뛰기", "Skip")) { skipStep() }
                .font(.system(size: TaptionType.scaled(TaptionType.bodyStrong), weight: .semibold, design: .rounded))
                .foregroundStyle(Color.tpSecondary)
                .buttonStyle(.plain)
                .frame(minWidth: 88, minHeight: 50)
            Button { confirmStep() } label: {
                Text(step.next == nil
                    ? language.text("시작하기", "Get started")
                    : language.text("다음", "Next"))
                    .font(.system(size: TaptionType.scaled(TaptionType.bodyStrong), weight: .bold, design: .rounded))
                    .foregroundStyle(Color.tpSurface)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Color.tpPrimaryFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private func confirmStep() {
        if step == .password, !savePasswordEntry() { return }
        advance()
    }

    private func skipStep() {
        if step == .password {
            pin = ""
            confirmation = ""
            passwordMessage = nil
        }
        advance()
    }

    private func advance() {
        if step == .password { registerDefaultPINIfNeeded() }
        if let next = step.next {
            move(to: next)
        } else {
            finish(.completed)
        }
    }

    private func move(to target: FirstRunTutorialStep) {
        dismissKeyboard()
        store.save(step: target)
        withAnimation(.snappy) { step = target }
    }

    /// 틀린 입력이면 머무른다.
    private func savePasswordEntry() -> Bool {
        switch FirstRunTutorialPolicy.passwordEntry(pin: pin, confirmation: confirmation) {
        case .keepCurrent:
            return true
        case .save(let value):
            do {
                try model.configureBackupPIN(value)
                pin = ""
                confirmation = ""
                passwordMessage = nil
                return true
            } catch {
                passwordMessage = error.localizedDescription
                return false
            }
        case .incomplete:
            passwordMessage = language.text("6자리 숫자를 두 칸에 모두 입력해 주세요.", "Enter 6 digits in both fields.")
            return false
        case .mismatch:
            passwordMessage = language.text("비밀번호 확인이 일치하지 않습니다.", "Passwords do not match.")
            return false
        }
    }

    private func registerDefaultPINIfNeeded() {
        guard let value = FirstRunTutorialPolicy.pinToRegister(hasPIN: model.securityStatus.hasPIN) else { return }
        try? model.configureBackupPIN(value)
    }

    private func finish(_ outcome: FirstRunTutorialOutcome) {
        guard !isFinishing else { return }
        isFinishing = true
        dismissKeyboard()
        registerDefaultPINIfNeeded()
        store.finish(outcome)
        // 건너뛴 사람에게 다음 실행에 권한 시트를 다시 올리지 않는다.
        UserDefaults.standard.set(true, forKey: AppModel.healthPermissionReminderKey)
        Task { @MainActor in
            await model.finishPermissionOnboarding()
            // 커버 뒤에 쌓인 권한 안내 문구가 닫힌 뒤에 경고창으로 뜨지 않게 한다.
            model.clearError()
            onFinished()
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

private struct FirstRunMascot: View {
    let scene: HwarangScene
    let size: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24)) { context in
            HwarangSceneView(
                scene: scene,
                sec: HwarangClock.seconds(at: context.date),
                width: size * 1.1,
                anchorHeight: size,
                showsBackdrop: false,
                keepsBodySize: false
            )
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - 위치

private struct FirstRunPlacePicker: View {
    @Bindable var model: AppModel
    let destination: MapHomeLocationDestination
    let language: MapHomeLanguage

    @State private var query = ""
    @State private var completer = MapHomeSearchCompleter()
    @State private var savedName: String?
    @State private var searchFailed = false
    @FocusState private var isSearchFocused: Bool

    private var place: FrequentPlace? {
        guard let kind = destination.placeKind else { return nil }
        return model.settings.frequentPlaces.first { $0.kind == kind }
    }

    private var currentPoint: GeoPoint? { model.latestSensorReading?.point }

    private var searchRegion: MKCoordinateRegion {
        guard let currentPoint else { return MKCoordinateRegion(.world) }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: currentPoint.latitude, longitude: currentPoint.longitude),
            span: MKCoordinateSpan(latitudeDelta: 1, longitudeDelta: 1)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(destination.iconAssetName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(language.text(destination.koreanName, destination.englishName))
                        .font(.system(size: TaptionType.scaled(TaptionType.bodyStrong), weight: .bold, design: .rounded))
                        .foregroundStyle(Color.tpInk)
                    if place?.point != nil {
                        Text(savedName ?? language.text("저장됨", "Saved"))
                            .font(.system(size: TaptionType.scaled(TaptionType.label), weight: .medium, design: .rounded))
                            .foregroundStyle(Color.tpSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if place?.point != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.tpAccent)
                        .accessibilityLabel(language.text("저장됨", "Saved"))
                }
            }

            if let point = place?.point {
                mapPreview(point)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.tpSecondary)
                    .accessibilityHidden(true)
                TextField(language.text("주소나 장소 이름 검색", "Search address or place"), text: $query)
                    .focused($isSearchFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("firstRunSearch.\(destination.rawValue)")
            }
            .font(.system(size: TaptionType.scaled(TaptionType.body), weight: .medium, design: .rounded))
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Color.tpBackground, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .onChange(of: query) { _, value in
                searchFailed = false
                completer.update(query: value, region: searchRegion)
            }

            if isSearchFocused || !query.isEmpty {
                ForEach(completer.results, id: \.self) { result in
                    Button { select(result) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.title)
                                .font(.system(size: TaptionType.scaled(TaptionType.body), weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.tpInk)
                            if !result.subtitle.isEmpty {
                                Text(result.subtitle)
                                    .font(.system(size: TaptionType.scaled(TaptionType.label), weight: .medium, design: .rounded))
                                    .foregroundStyle(Color.tpSecondary)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if searchFailed {
                Text(language.text("위치를 찾지 못했습니다. 다른 이름으로 검색해 주세요.", "Couldn't find it. Try another name."))
                    .font(.system(size: TaptionType.scaled(TaptionType.label), weight: .medium, design: .rounded))
                    .foregroundStyle(Color.tpSecondary)
            }

            Button {
                guard let place else { return }
                model.setFrequentPlaceToCurrentLocation(place.id)
                savedName = language.text("현재 위치로 저장됨", "Saved from current location")
                clearSearch()
            } label: {
                Label(language.text("현재 위치로 저장", "Use current location"), systemImage: "location.fill")
                    .font(.system(size: TaptionType.scaled(TaptionType.body), weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .tint(Color.tpAccent)
            .disabled(currentPoint == nil)

            if currentPoint == nil {
                Text(model.permissionState(for: .location).isGranted
                    ? language.text("현재 위치를 받는 중입니다. 검색으로도 저장할 수 있습니다.", "Waiting for your location. You can also search.")
                    : language.text("위치를 허용하면 현재 위치로도 저장할 수 있습니다.", "Allow location to use your current position."))
                    .font(.system(size: TaptionType.scaled(TaptionType.label), weight: .medium, design: .rounded))
                    .foregroundStyle(Color.tpSecondary)
            }
        }
        .padding(14)
        .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func mapPreview(_ point: GeoPoint) -> some View {
        let coordinate = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
        return Map(
            position: .constant(.region(MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: 600,
                longitudinalMeters: 600
            ))),
            interactionModes: []
        ) {
            Annotation("", coordinate: coordinate) {
                Image(destination.iconAssetName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 34, height: 34)
            }
        }
        .frame(height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .accessibilityHidden(true)
    }

    private func select(_ completion: MKLocalSearchCompletion) {
        let request = MKLocalSearch.Request(completion: completion)
        Task { @MainActor in
            guard let item = try? await MKLocalSearch(request: request).start().mapItems.first,
                  let place else {
                searchFailed = true
                return
            }
            let coordinate = item.placemark.coordinate
            model.setFrequentPlaceLocation(
                place.id,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
            savedName = item.name ?? completion.title
            clearSearch()
        }
    }

    private func clearSearch() {
        query = ""
        isSearchFocused = false
        completer.clear()
    }
}

// MARK: - 비밀번호

private struct FirstRunPasswordPage: View {
    @Bindable var model: AppModel
    let language: MapHomeLanguage
    @Binding var pin: String
    @Binding var confirmation: String
    @Binding var message: String?

    private var security: PlanSecurityStatus { model.securityStatus }
    private var isAppLockOn: Bool { security.settings.lockOnLaunch && security.settings.lockOnForeground }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                card {
                    // 앱 잠금을 켜면 초기값이 먼저 등록된다. 그래도 번호는 계속 보여 준다.
                    if security.hasPIN, model.rememberedBackupPassword != FirstRunTutorialPolicy.defaultPIN {
                        Text(language.text("등록된 비밀번호가 있습니다", "A password is already set"))
                            .font(.system(size: TaptionType.scaled(TaptionType.title), weight: .bold, design: .rounded))
                        note(language.text("바꾸지 않으면 그대로 씁니다.", "It stays as is unless you change it."))
                    } else {
                        Text(language.text("초기 비밀번호", "Default password"))
                            .font(.system(size: TaptionType.scaled(TaptionType.label), weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.tpSecondary)
                        Text(FirstRunTutorialPolicy.defaultPIN)
                            .font(.system(size: TaptionType.scaled(TaptionType.display), weight: .bold, design: .monospaced))
                            .accessibilityIdentifier("firstRunDefaultPIN")
                        note(language.text("바꾸지 않으면 이 번호로 시작합니다.", "This is used unless you change it."))
                    }
                }

                card {
                    Text(language.text("새 비밀번호(6자리)", "New password (6 digits)"))
                        .font(.system(size: TaptionType.scaled(TaptionType.body), weight: .semibold, design: .rounded))
                    pinField(language.text("새 비밀번호", "New password"), text: $pin, id: "firstRunPIN")
                    pinField(language.text("비밀번호 확인", "Confirm password"), text: $confirmation, id: "firstRunPINConfirm")
                    if let message {
                        Text(message)
                            .font(.system(size: TaptionType.scaled(TaptionType.label), weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.tpReferenceRose)
                    }
                }

                card {
                    Toggle(
                        language.text("앱을 열 때마다 잠금", "Lock whenever the app opens"),
                        isOn: Binding(get: { isAppLockOn }, set: { setAppLock($0) })
                    )
                    .font(.system(size: TaptionType.scaled(TaptionType.body), weight: .semibold, design: .rounded))
                    .tint(Color.tpAccent)
                    note(language.text("끄면 비밀번호는 백업에만 쓰입니다.", "When off, the password is used only for backups."))
                }

                note(language.text(
                    "비밀번호를 잊으면 백업을 복구할 수 없습니다. 예전 iCloud 백업은 그때 쓴 비밀번호로 열립니다.",
                    "Without the password, backups can't be restored. Older iCloud backups open with the password used then."
                ))
                .padding(.horizontal, 4)
            }
            .padding(18)
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .foregroundStyle(Color.tpInk)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: TaptionType.scaled(TaptionType.label), weight: .medium, design: .rounded))
            .foregroundStyle(Color.tpSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func pinField(_ title: String, text: Binding<String>, id: String) -> some View {
        SecureField(title, text: text)
            .keyboardType(.numberPad)
            .textContentType(.newPassword)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier(id)
            .onChange(of: text.wrappedValue) { _, value in
                let digits = String(value.filter(\.isNumber).prefix(PlanPINVerifier.currentDigits))
                if digits != value { text.wrappedValue = digits }
                message = nil
            }
    }

    private func setAppLock(_ enabled: Bool) {
        do {
            // 앱 잠금은 비밀번호가 있어야 켜진다.
            if enabled, let value = FirstRunTutorialPolicy.pinToRegister(hasPIN: security.hasPIN) {
                try model.configureBackupPIN(value)
            }
            var settings = security.settings
            settings.lockOnLaunch = enabled
            settings.lockOnForeground = enabled
            try model.configureAppLock(settings)
        } catch {
            message = error.localizedDescription
        }
    }
}

// MARK: - 클립 편집 소개

private struct FirstRunClipEditorPage: View {
    let language: MapHomeLanguage

    private var rows: [(icon: String, title: String, detail: String)] {
        [
            ("pencil", language.text("여는 법", "Open"), language.text("시간 막대 아래 연필을 누르거나 막대를 두 번 누릅니다.", "Tap the pencil under the time bar, or double-tap the bar.")),
            ("arrow.up.and.down", language.text("옮기고 자르기", "Move and trim"), language.text("클립을 끌어 옮기고, 양 끝을 잡아 길이를 줄입니다.", "Drag a clip to move it. Drag its ends to trim.")),
            ("scissors", language.text("가르기", "Split"), language.text("재생 헤드 자리에서 클립을 둘로 나눕니다.", "Split a clip at the playhead.")),
            ("rectangle.stack", language.text("전체 덮기", "Overwrite all"), language.text("나뉜 클립을 한 번에 같은 분류로 바꿉니다.", "Change split clips to one category at once.")),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                FirstRunClipIllustration()
                    .frame(height: 96)
                    .frame(maxWidth: .infinity)
                    .padding(14)
                    .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                ForEach(rows, id: \.title) { row in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: row.icon)
                            .font(.system(size: TaptionType.scaled(TaptionType.bodyStrong), weight: .semibold))
                            .foregroundStyle(Color.tpAccent)
                            .frame(width: 28, height: 28)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                                .font(.system(size: TaptionType.scaled(TaptionType.bodyStrong), weight: .bold, design: .rounded))
                                .foregroundStyle(Color.tpInk)
                            Text(row.detail)
                                .font(.system(size: TaptionType.scaled(TaptionType.body), weight: .medium, design: .rounded))
                                .foregroundStyle(Color.tpSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(18)
        }
    }
}

/// 클립 경계를 끌어 자르는 모습을 되풀이한다.
private struct FirstRunClipIllustration: View {
    private let cycle = 4.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: cycle) / cycle
            let swing = 0.5 - 0.5 * cos(phase * 2 * .pi)
            GeometryReader { proxy in
                let edge = proxy.size.width * (0.34 + 0.22 * swing)
                let split = proxy.size.width * 0.76
                ZStack(alignment: .leading) {
                    clip(Color.tpReferenceBlue, x: 0, width: edge - 2)
                    clip(Color.tpReferenceMint, x: edge + 2, width: split - edge - 4)
                    clip(Color.tpReferenceRose, x: split + 2, width: proxy.size.width - split - 2)
                    Capsule()
                        .fill(Color.tpInk)
                        .frame(width: 5, height: proxy.size.height * 0.74)
                        .offset(x: edge - 2.5)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    private func clip(_ color: Color, x: CGFloat, width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(color.opacity(0.7))
            .frame(width: max(width, 0), height: 54)
            .offset(x: x)
    }
}

// MARK: - 카운터

private struct FirstRunCountersPage: View {
    let language: MapHomeLanguage

    @AppStorage(MapHomeCounterKind.steps.storageKey) private var showsSteps = true
    @AppStorage(MapHomeCounterKind.distance.storageKey) private var showsDistance = true
    @AppStorage(MapHomeCounterKind.work.storageKey) private var showsWork = true
    @AppStorage(MapHomeCounterKind.study.storageKey) private var showsStudy = true
    @AppStorage(MapHomeCounterKind.hobby.storageKey) private var showsHobby = true
    @AppStorage(MapHomeCounterKind.exercise.storageKey) private var showsExercise = true
    @AppStorage("mapHomeCounter.salary") private var showsSalary = true
    @AppStorage(MapHomeSalaryPolicy.annualKey) private var annualPay = 0.0
    @AppStorage(MapHomeSalaryPolicy.monthlyPayKey) private var monthlyPay = 0.0
    @AppStorage(MapHomeSalaryPolicy.isHourlyKey) private var isHourly = false
    @AppStorage(MapHomeSalaryPolicy.hourlyKey) private var hourlyPay = 0.0

    /// 연봉 줄은 금액이 있어야 지도에 나온다.
    private var isSalaryConfigured: Bool {
        isHourly ? hourlyPay > 0 : annualPay > 0 || monthlyPay > 0
    }

    private var sampleBadges: [MapHomeCounterBadge] {
        MapHomeCounterKind.allCases.compactMap { kind in
            binding(kind).wrappedValue ? MapHomeCounterBadge(kind: kind, text: sampleText(kind)) : nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                VStack(spacing: 6) {
                    Text(language.text("예시", "Example"))
                        .font(.system(size: TaptionType.scaled(TaptionType.caption), weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.tpSecondary)
                    MapHomeCounterTable(
                        salary: showsSalary && isSalaryConfigured
                            ? MapHomeCounterSalary(text: language.text("12,340원", "12,340 USD"), isWorking: true)
                            : nil,
                        badges: sampleBadges,
                        language: language
                    )
                }
                .frame(maxWidth: .infinity)
                .padding(14)
                .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(spacing: 2) {
                    Toggle(isOn: $showsSalary) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(language.text("연봉 카운터", "Salary counter"), systemImage: "wonsign.circle.fill")
                            if !isSalaryConfigured {
                                Text(language.text("연봉을 적으면 나타납니다", "Appears once you enter a salary"))
                                    .font(.system(size: TaptionType.scaled(TaptionType.caption), weight: .medium, design: .rounded))
                                    .foregroundStyle(Color.tpSecondary)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    ForEach(MapHomeCounterKind.allCases) { kind in
                        Toggle(isOn: binding(kind)) {
                            Label(kind.menuTitle(language), systemImage: kind.systemImage)
                        }
                        .padding(.vertical, 6)
                    }
                }
                .font(.system(size: TaptionType.scaled(TaptionType.body), weight: .semibold, design: .rounded))
                .foregroundStyle(Color.tpInk)
                .tint(Color.tpAccent)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(18)
        }
    }

    private func binding(_ kind: MapHomeCounterKind) -> Binding<Bool> {
        switch kind {
        case .steps: $showsSteps
        case .distance: $showsDistance
        case .work: $showsWork
        case .study: $showsStudy
        case .hobby: $showsHobby
        case .exercise: $showsExercise
        }
    }

    private func sampleText(_ kind: MapHomeCounterKind) -> String {
        switch kind {
        case .steps: "8,432"
        case .distance: "4.2km"
        case .work: language.text("3시간 12분", "3h 12m")
        case .study: language.text("42분", "42m")
        case .hobby: language.text("1시간 5분", "1h 5m")
        case .exercise: language.text("25분", "25m")
        }
    }
}
