import MapKit
import SwiftUI
import UIKit

/// 처음 실행 튜토리얼(FRT1102A01, FRT1104A01). 설정 화면을 새로 만들지 않고 기존 화면과 모델 함수를 쓴다.
/// 입력은 그 자리에서 저장되므로, 도중에 앱을 닫아도 지금까지 고른 값은 남는다.
struct FirstRunTutorialView: View {
    /// 다시 보기는 처음 실행 기록과 초기 비밀번호를 건드리지 않는다.
    enum Mode { case firstRun, replay }

    @Bindable var model: AppModel
    let mode: Mode
    let onFinished: () -> Void

    @State private var step: FirstRunTutorialStep
    @State private var pin = ""
    @State private var confirmation = ""
    @State private var passwordMessage: String?
    @State private var isFinishing = false

    private let store = FirstRunTutorialStore()
    private let language = MapHomeLanguage.current

    init(model: AppModel, mode: Mode = .firstRun, startStep: FirstRunTutorialStep? = nil, onFinished: @escaping () -> Void) {
        self.model = model
        self.mode = mode
        self.onFinished = onFinished
        _step = State(initialValue: startStep ?? (mode == .replay ? .welcome : FirstRunTutorialStore().savedStep ?? .welcome))
    }

    // 참고 화면 모양(FRD1111A01, 대표 지시): 위에 내용 카드, 그 아래 작은 분류·큰 제목·설명, 아래 점 표시와 꽉 찬 「계속」.
    // 색은 앱 시그니처(크림 바탕·흰 카드·테라코타 단추·먹색 글자).
    var body: some View {
        VStack(spacing: 0) {
            topBar
            page
                .id(step)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scrollDismissesKeyboard(.interactively)
                .background(Color.tpCard, in: RoundedRectangle(cornerRadius: TaptionCorner.sheet, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: TaptionCorner.sheet, style: .continuous))
                .shadow(color: Color.tpInk.opacity(0.08), radius: 18, y: 8)
                .padding(.horizontal, 22)
                .padding(.top, 6)
            if step != .welcome { header }
            pageDots
            bottomBar
        }
        // 넓은 화면에서 글줄이 너무 길어지지 않게 묶는다.
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .background(Color.tpBackground.ignoresSafeArea())
        .disabled(isFinishing)
        // 묶지 않으면 이 이름이 안쪽 단추의 이름을 덮어쓴다.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("firstRunTutorial")
    }

    // MARK: 위쪽

    private var topBar: some View {
        HStack(spacing: 6) {
            Button(language.text("닫기", "Close")) { finish(.skipped) }
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.label), weight: .semibold))
                .foregroundStyle(Color.tpSecondary)
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .accessibilityIdentifier("firstRunClose")
            if step != .welcome, let previous = step.previous {
                Button { move(to: previous) } label: {
                    Label(language.text("이전", "Back"), systemImage: "chevron.left")
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.label), weight: .semibold))
                        .foregroundStyle(Color.tpInk)
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .padding(.leading, 8)
                .accessibilityIdentifier("firstRunBack")
            }
            Spacer(minLength: 0)
            // 전체 건너뛰기는 첫 화면의 「바로 시작」이 맡는다.
            Button(language.text("건너뛰기", "Skip")) { skipStep() }
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.label), weight: .semibold))
                .foregroundStyle(Color.tpSecondary)
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .opacity(step.hasInput ? 1 : 0)
                .disabled(!step.hasInput)
                .accessibilityIdentifier("firstRunSkip")
        }
        .padding(.horizontal, 20)
    }

    /// 카드 아래 글: 작은 분류(고양이와 장 이름), 큰 제목, 설명. 가운데 맞춤.
    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                FirstRunMascot(scene: scene(of: step), size: 30)
                Text(chapterTitle(step.chapter))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.caption), weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(Color.tpAccent)
            }
            Text(title(of: step))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.display), weight: .bold))
                .foregroundStyle(Color.tpInk)
                .multilineTextAlignment(.center)
            Text(detail(of: step))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.body), weight: .medium))
                .foregroundStyle(Color.tpSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.top, 18)
    }

    /// 지금 장(기본 설정·화면 익히기·연결과 보호)의 단계 점. 지금 단계만 길게.
    private var pageDots: some View {
        let steps = FirstRunTutorialStep.allCases.filter { $0.chapter == step.chapter }
        return HStack(spacing: 7) {
            ForEach(steps) { item in
                Capsule()
                    .fill(item == step ? Color.tpAccent : Color.tpBorder.opacity(0.5))
                    .frame(width: item == step ? 22 : 7, height: 7)
            }
        }
        .animation(.snappy, value: step)
        .padding(.top, 18)
        .accessibilityElement()
        .accessibilityLabel("\(step.number) / \(FirstRunTutorialStep.allCases.count)")
        .accessibilityIdentifier("firstRunProgress")
    }

    private func scene(of step: FirstRunTutorialStep) -> HwarangScene {
        switch step {
        case .welcome, .permissions, .dayCardTime, .cat: .groom
        case .home, .summary: .sleep
        case .workAndSchool, .calendar, .appleWatch, .aiConnect, .shortcuts: .work
        case .car: .stroll
        case .salary, .finish: .eat
        case .map: .atlas
        case .playback: .stroll
        case .sidebarCalendar, .memos, .password: .study
        case .clipEditor: .yarn
        case .counters: .stretch
        }
    }

    private func chapterTitle(_ chapter: FirstRunTutorialChapter) -> String {
        switch chapter {
        case .start: language.text("시작", "Start")
        case .setup: language.text("기본 설정", "Setup")
        case .learn: language.text("화면 익히기", "Learn the screen")
        case .connect: language.text("연결과 보호", "Connect and protect")
        case .finish: language.text("마무리", "Done")
        }
    }

    private func title(of step: FirstRunTutorialStep) -> String {
        switch step {
        case .welcome: "BOKKI Plan"
        case .permissions: language.text("권한 허용", "Permissions")
        case .dayCardTime: language.text("하루 카드 시각", "Day card time")
        case .home: language.text("집 위치", "Home")
        case .workAndSchool: language.text("회사 · 학교", "Work · School")
        case .car: language.text("내 차", "My car")
        case .salary: language.text("연봉 설정", "Salary")
        case .cat: language.text("고양이 고르기", "Pick your cat")
        case .map: language.text("지도 보는 법", "Reading the map")
        case .playback: language.text("재생과 녹화", "Play and record")
        case .sidebarCalendar: language.text("사이드바와 달력", "Sidebar and calendar")
        case .clipEditor: language.text("클립 편집", "Clip editor")
        case .memos: language.text("메모 · 지도 메모", "Memos · Map memos")
        case .summary: language.text("하루 요약과 집 성장", "Day summary and home growth")
        case .counters: language.text("카운터", "Counters")
        case .calendar: language.text("캘린더 연결", "Connect calendars")
        case .appleWatch: language.text("Apple Watch", "Apple Watch")
        case .aiConnect: language.text("AI 연결", "Connect an AI")
        case .shortcuts: language.text("단축어 · Siri", "Shortcuts · Siri")
        case .password: language.text("백업 비밀번호", "Backup password")
        case .finish: language.text("준비됐습니다", "You're ready")
        }
    }

    private func detail(of step: FirstRunTutorialStep) -> String {
        switch step {
        case .welcome: ""
        case .permissions: language.text("하루를 자동으로 기록하는 데 씁니다. 필요한 것만 허용해도 됩니다. 자동 기록 중에는 상단에 위치 표시가 보일 수 있습니다.", "Used to record your day automatically. Allow only what you need. The location icon may stay visible during automatic recording.")
        case .dayCardTime: language.text("어제 하루를 담은 카드를 알림으로 보낼 시각을 고릅니다.", "Choose when yesterday's card arrives as a notification.")
        case .home: language.text("집에 머문 시간을 자동으로 구분합니다.", "Time at home is recognized automatically.")
        case .workAndSchool: language.text("업무와 학습 시간을 구분하는 기준이 됩니다.", "Used to tell work and study time apart.")
        case .car: language.text("차에 블루투스로 연결되면 그 이동을 자동차로 기록합니다. 이어폰은 고르지 마세요.", "Trips with your car's Bluetooth connected are recorded as car. Don't pick earphones.")
        case .salary: language.text("업무 시간에만 번 돈이 쌓입니다. 금액은 이 기기에만 저장됩니다.", "Earnings grow only during work time. Stored only on this device.")
        case .cat: language.text("지도에서 하루를 함께 걸을 고양이입니다.", "This cat walks through your day on the map.")
        case .map: language.text("앱의 첫 화면입니다. 하루가 지도 위에 그려집니다.", "This is the main screen. Your day is drawn on the map.")
        case .playback: language.text("하루를 다시 보고 영상으로 남깁니다.", "Replay your day and keep it as a video.")
        case .sidebarCalendar: language.text("오른쪽 시간 막대로 하루를, 달력으로 지난 날을 봅니다.", "See the day on the right time bar and past days in the calendar.")
        case .clipEditor: language.text("자동 기록이 틀렸으면 영상 편집처럼 고칩니다.", "Fix automatic records the way you edit a video.")
        case .memos: language.text("생각과 장소를 그 시각에 남깁니다.", "Keep thoughts and places at the moment they happen.")
        case .summary: language.text("기록을 마친 날이 쌓이면 집이 자랍니다.", "Your home grows as you complete days.")
        case .counters: language.text("지도 위 고양이 곁에 보여 줄 것을 고릅니다.", "Choose what appears next to the cat on the map.")
        case .calendar: language.text("일정을 하루 기록과 함께 봅니다. 읽기만 합니다.", "See events with your day. Read only.")
        case .appleWatch: language.text("손목의 움직임까지 더해 하루를 기록합니다.", "Adds movement from your wrist to your day.")
        case .aiConnect: language.text("AI가 하루 기록을 읽고 일정·메모를 대신 정리합니다. 나중에 메뉴 > 연결에서도 할 수 있습니다.", "Let an AI read your day and tidy plans and memos for you. You can also do this later in Menu > Connections.")
        case .shortcuts: language.text("결제 문자·앱 알림이 오면 가계부에 저절로 들어가게 하고, Siri로 말해서 바로 넣습니다. 나중에 메뉴 › 연결에서도 볼 수 있습니다.", "Let payment texts and app alerts flow into the ledger, and add things by talking to Siri. Also in Menu › Connections.")
        case .password: language.text("앱 잠금과 iCloud 백업에 같은 비밀번호를 씁니다.", "App lock and iCloud backup share this password.")
        case .finish: language.text("지금 상태입니다. 비어 있는 것은 나중에 해도 됩니다.", "Here's where things stand. Anything open can wait.")
        }
    }

    // MARK: 단계

    @ViewBuilder
    private var page: some View {
        switch step {
        case .welcome:
            FirstRunWelcomePage(language: language)
        case .permissions:
            PermissionOnboardingSheet(model: model, isEmbedded: true)
        case .dayCardTime:
            FirstRunDayCardTimePage(model: model, language: language)
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
        case .car:
            FirstRunCarPage(model: model, language: language)
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
                registersDefaultPIN: mode == .firstRun,
                pin: $pin,
                confirmation: $confirmation,
                message: $passwordMessage
            )
        case .cat:
            FirstRunCatPage(model: model, language: language)
        case .map, .playback, .sidebarCalendar, .clipEditor, .memos, .summary:
            FirstRunGuidePage(step: step, date: model.selectedDate, language: language)
                .id(step)
        case .counters:
            FirstRunCountersPage(language: language)
        case .appleWatch:
            FirstRunAppleWatchPage(model: model, language: language)
        case .aiConnect:
            FirstRunAIConnectPage(language: language)
        case .shortcuts:
            List { BokkiShortcutsGuideSections(language: language) }.tpListStyle()
        case .calendar:
            FirstRunCalendarPage(model: model, language: language)
        case .finish:
            FirstRunFinishPage(model: model, language: language)
        }
    }

    // MARK: 아래쪽

    private var bottomBar: some View {
        VStack(spacing: 6) {
            Button { confirmStep() } label: {
                HStack(spacing: 8) {
                    Text(primaryTitle)
                    if step != .finish { Image(systemName: "arrow.right") }
                }
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.bodyStrong), weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(Color.tpAccent, in: RoundedRectangle(cornerRadius: TaptionCorner.sheet, style: .continuous))
                .shadow(color: Color.tpAccent.opacity(0.28), radius: 12, y: 6)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("firstRunNext")
            if step == .welcome {
                Button(language.text("바로 시작", "Start now")) { finish(.skipped) }
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.label), weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                    .buttonStyle(.plain)
                    .frame(minHeight: 40)
                    .accessibilityIdentifier("firstRunStartNow")
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: language.text("차근차근 따라 하기", "Walk me through")
        case .finish: mode == .replay ? language.text("닫기", "Close") : language.text("시작하기", "Get started")
        default: language.text("계속", "Continue")
        }
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
        if mode == .firstRun { store.save(step: target) }
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
        guard mode == .firstRun, let value = FirstRunTutorialPolicy.pinToRegister(hasPIN: model.securityStatus.hasPIN) else { return }
        try? model.configureBackupPIN(value)
    }

    private func finish(_ outcome: FirstRunTutorialOutcome) {
        guard !isFinishing else { return }
        isFinishing = true
        dismissKeyboard()
        if mode == .replay {
            model.clearError()
            onFinished()
            return
        }
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

struct FirstRunMascot: View {
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

    /// 지도 검색과 같이 현재 위치 둘레를 먼저 찾는다(SRC1108A01).
    private var searchRegion: MKCoordinateRegion {
        guard let currentPoint else { return MKCoordinateRegion(.world) }
        return MapHomeSearchPolicy.region(
            visibleCenter: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            visibleSpan: MKCoordinateSpan(latitudeDelta: 0, longitudeDelta: 0),
            current: CLLocationCoordinate2D(latitude: currentPoint.latitude, longitude: currentPoint.longitude)
        )
    }

    /// 다녀온 곳·지하철역은 이름 중간 글자로도 찾는다. 이 장소 자신은 뺀다.
    private var localMatches: [MapHomeSearchResult] {
        MapHomeSearchPolicy.localMatches(
            query,
            places: model.settings.frequentPlaces.filter { $0.id != place?.id },
            visited: model.snapshot.places,
            origin: currentPoint.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) },
            language: language
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
                    Text(language.runtimeText(destination.koreanName, destination.englishName))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.bodyStrong), weight: .bold))
                        .foregroundStyle(Color.tpInk)
                    if place?.point != nil {
                        Text(savedName ?? language.text("저장됨", "Saved"))
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.label), weight: .medium))
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

            MapHomePlacePinPicker(
                point: place?.point,
                fallback: currentPoint,
                tint: Color.tpAccent,
                language: language
            ) { coordinate in
                guard let place else { return }
                model.setFrequentPlaceLocation(place.id, latitude: coordinate.latitude, longitude: coordinate.longitude)
                savedName = language.text("지도에서 저장됨", "Saved from the map")
                clearSearch()
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
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.body), weight: .medium))
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Color.tpBackground, in: RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous))
            .onChange(of: query) { _, value in
                searchFailed = false
                completer.update(query: value, region: searchRegion)
            }

            if isSearchFocused || !query.isEmpty {
                ForEach(localMatches) { result in
                    Button { select(result) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.title)
                                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.body), weight: .semibold))
                                .foregroundStyle(Color.tpInk)
                            Text(result.subtitle)
                                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.label), weight: .medium))
                                .foregroundStyle(Color.tpSecondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                ForEach(completer.results, id: \.self) { result in
                    Button { select(result) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.title)
                                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.body), weight: .semibold))
                                .foregroundStyle(Color.tpInk)
                            if !result.subtitle.isEmpty {
                                Text(result.subtitle)
                                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.label), weight: .medium))
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
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.label), weight: .medium))
                    .foregroundStyle(Color.tpSecondary)
            }

            Button {
                guard let place else { return }
                model.setFrequentPlaceToCurrentLocation(place.id)
                savedName = language.text("현재 위치로 저장됨", "Saved from current location")
                clearSearch()
            } label: {
                Label(language.text("현재 위치로 저장", "Use current location"), systemImage: "location.fill")
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.body), weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .tint(Color.tpAccent)
            .disabled(currentPoint == nil)

            if currentPoint == nil {
                Text(model.permissionState(for: .location).isGranted
                    ? language.text("현재 위치를 받는 중입니다. 검색으로도 저장할 수 있습니다.", "Waiting for your location. You can also search.")
                    : language.text("위치를 허용하면 현재 위치로도 저장할 수 있습니다.", "Allow location to use your current position."))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.label), weight: .medium))
                    .foregroundStyle(Color.tpSecondary)
            }
            // 새로 등록하면 기본 200m(PLR1112A01). 이미 등록한 장소는 그 장소의 반경을 보인다.
            Text(language.text("반경", "Radius")
                + " \(Int((place?.point == nil ? FrequentPlace.defaultRadiusMeters : place?.radiusMeters ?? FrequentPlace.defaultRadiusMeters).rounded()))m · "
                + language.text("이 안에 있으면 이 장소로 봐요. 나중에 장소 정보에서 바꿀 수 있어요.", "Inside this range counts as this place. You can change it later in the place details."))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.label), weight: .medium))
                .foregroundStyle(Color.tpSecondary)
        }
        .padding(14)
        .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous))
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

    private func select(_ result: MapHomeSearchResult) {
        guard let place else { return }
        model.setFrequentPlaceLocation(place.id, latitude: result.coordinate.latitude, longitude: result.coordinate.longitude)
        savedName = result.title
        clearSearch()
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
    let registersDefaultPIN: Bool
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
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.title), weight: .bold))
                        note(language.text("바꾸지 않으면 그대로 씁니다.", "It stays as is unless you change it."))
                    } else if !registersDefaultPIN, !security.hasPIN {
                        Text(language.text("아직 비밀번호가 없습니다", "No password yet"))
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.title), weight: .bold))
                        note(language.text("아래에 적고 다음을 누르면 저장됩니다.", "Enter one below and tap Next to save it."))
                    } else {
                        Text(language.text("초기 비밀번호", "Default password"))
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.label), weight: .semibold))
                            .foregroundStyle(Color.tpSecondary)
                        Text(FirstRunTutorialPolicy.defaultPIN)
                            .font(.system(size: TaptionType.scaled(TaptionType.display), weight: .bold, design: .monospaced))
                            .accessibilityIdentifier("firstRunDefaultPIN")
                        note(language.text("바꾸지 않으면 이 번호로 시작합니다.", "This is used unless you change it."))
                    }
                }

                card {
                    Text(language.text("새 비밀번호(6자리)", "New password (6 digits)"))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.body), weight: .semibold))
                    pinField(language.text("새 비밀번호", "New password"), text: $pin, id: "firstRunPIN")
                    pinField(language.text("비밀번호 확인", "Confirm password"), text: $confirmation, id: "firstRunPINConfirm")
                    if let message {
                        Text(message)
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.label), weight: .semibold))
                            .foregroundStyle(Color.tpReferenceRose)
                    }
                }

                card {
                    Toggle(
                        language.text("앱을 열 때마다 잠금", "Lock whenever the app opens"),
                        isOn: Binding(get: { isAppLockOn }, set: { setAppLock($0) })
                    )
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.body), weight: .semibold))
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
            .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous))
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.label), weight: .medium))
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
            if enabled, registersDefaultPIN, let value = FirstRunTutorialPolicy.pinToRegister(hasPIN: security.hasPIN) {
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

// MARK: - 클립 편집 그림

// MARK: - 카운터

private struct FirstRunCountersPage: View {
    let language: MapHomeLanguage

    @AppStorage(MapHomeCounterKind.steps.storageKey) private var showsSteps = true
    @AppStorage(MapHomeCounterKind.distance.storageKey) private var showsDistance = true
    @AppStorage(MapHomeCounterKind.work.storageKey) private var showsWork = true
    @AppStorage(MapHomeCounterKind.study.storageKey) private var showsStudy = true
    @AppStorage(MapHomeCounterKind.hobby.storageKey) private var showsHobby = true
    @AppStorage(MapHomeCounterKind.exercise.storageKey) private var showsExercise = true
    @AppStorage(MapHomeCounterKind.spending.storageKey) private var showsSpending = true
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
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.caption), weight: .semibold))
                        .foregroundStyle(Color.tpSecondary)
                    MapHomeCounterTable(
                        salary: showsSalary && isSalaryConfigured
                            ? MapHomeCounterSalary(text: AppRegion.current.moneyText(12_340), isWorking: true)
                            : nil,
                        badges: sampleBadges,
                        language: language
                    )
                }
                .frame(maxWidth: .infinity)
                .padding(14)
                .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous))

                VStack(spacing: 2) {
                    Toggle(isOn: $showsSalary) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(language.text("연봉 카운터", "Salary counter"), systemImage: "wonsign.circle.fill")
                            if !isSalaryConfigured {
                                Text(language.text("연봉을 적으면 나타납니다", "Appears once you enter a salary"))
                                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.caption), weight: .medium))
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
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.body), weight: .semibold))
                .foregroundStyle(Color.tpInk)
                .tint(Color.tpAccent)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous))
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
        case .spending: $showsSpending
        }
    }

    private func sampleText(_ kind: MapHomeCounterKind) -> String {
        switch kind {
        case .steps: "8,432"
        case .distance: AppRegion.current.distanceText(meters: 4_200, compact: true)
        case .work: language.text("3시간 12분", "3h 12m")
        case .study: language.text("42분", "42m")
        case .hobby: language.text("1시간 5분", "1h 5m")
        case .exercise: language.text("25분", "25m")
        case .spending: language.text("12,300원", "₩12,300")
        }
    }
}
