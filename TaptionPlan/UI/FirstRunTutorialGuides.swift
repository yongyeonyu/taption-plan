import SwiftUI

/// 설명 단계의 줄. 그림의 번호와 맞춘다.
struct FirstRunGuideRow: Equatable {
    let icon: String
    let title: String
    let detail: String
}

/// 튜토리얼 설명 문구. 앱에서 실제로 누르는 곳의 이름을 그대로 쓴다(FRT1104A01).
enum FirstRunGuideCatalog {
    static func isGuide(_ step: FirstRunTutorialStep) -> Bool {
        switch step {
        case .map, .playback, .sidebarCalendar, .clipEditor, .memos, .summary: true
        default: false
        }
    }

    static func rows(for step: FirstRunTutorialStep, language: MapHomeLanguage) -> [FirstRunGuideRow] {
        func row(_ icon: String, _ koTitle: String, _ enTitle: String, _ ko: String, _ en: String) -> FirstRunGuideRow {
            FirstRunGuideRow(icon: icon, title: language.runtimeText(koTitle, enTitle), detail: language.runtimeText(ko, en))
        }
        switch step {
        case .map:
            return [
                row("hand.draw", "움직이기", "Move", "한 손가락으로 끌어 옮기고, 두 손가락을 벌려 확대합니다.", "Drag with one finger. Spread two fingers to zoom."),
                row("location.fill", "현재 위치", "Location", "아래 막대의 현재 위치를 누르면 오늘, 지금 있는 곳으로 돌아옵니다.", "Tap Location in the bottom bar to return to today and where you are."),
                row("calendar.day.timeline.right", "다른 날", "Other days", "오른쪽 위 날짜를 누르면 날짜 줄이 펼쳐집니다. 밀어서 날을 옮깁니다.", "Tap the date at the top right to open the date strip, then swipe."),
                row("pawprint.fill", "기록 읽기", "Reading it", "선과 발자국은 지나온 길, 아이콘은 등록한 곳입니다.", "Lines and footprints show where you went. Icons mark saved places."),
                row("square.3.layers.3d", "표시 바꾸기", "Display", "지도 스타일과 보이는 항목은 메뉴 > 표시에서 고릅니다.", "Choose map style and what's shown in Menu > Display."),
            ]
        case .playback:
            return [
                row("play.fill", "재생", "Play", "고양이가 그날의 길을 따라갑니다. 같은 자리의 멈춤으로 세웁니다.", "The cat follows your day. Tap Pause in the same spot to stop."),
                row("record.circle", "녹화", "Record", "영상에 넣을 항목을 고르고 ‘녹화하며 재생’을 누릅니다.", "Choose what to include, then tap ‘Record and play’."),
                row("film", "영상 만들기", "Render", "‘끊김 없는 영상 만들기’는 몇 분 걸리지만 끊기지 않습니다.", "‘Render smooth video’ takes a few minutes but never stutters."),
                row("photo.on.rectangle", "저장", "Save", "사진 권한을 허용하면 사진 앱에 저장됩니다.", "With Photos access, videos are saved to Photos."),
            ]
        case .sidebarCalendar:
            return [
                row("chevron.down", "펼치고 접기", "Show and hide", "오른쪽 위 날짜 아래 화살표로 펼치고, 막대 맨 위 화살표로 접습니다.", "Use the arrow under the date to show it and the arrow on top to hide it."),
                row("hand.draw", "시각 고르기", "Pick a time", "막대 오른쪽 가장자리를 위아래로 끌면 그 시각의 하루가 보입니다.", "Drag along the bar's right edge to see that moment."),
                row("paintpalette", "색 읽기", "Colors", "색은 업무·공부·이동처럼 그 시간에 한 일입니다.", "Colors show what you did, like work, study, or travel."),
                row("calendar", "달력", "Calendar", "아래 막대의 달력에서 지난 날을 찾아 고릅니다.", "Find and pick past days with Calendar in the bottom bar."),
            ]
        case .clipEditor:
            return [
                row("pencil", "여는 법", "Open", "시간 막대 아래 연필을 누르거나 막대를 두 번 누릅니다.", "Tap the pencil under the time bar, or double-tap the bar."),
                row("arrow.up.and.down", "옮기고 자르기", "Move and trim", "클립을 끌어 옮기고, 양 끝을 잡아 길이를 줄입니다.", "Drag a clip to move it. Drag its ends to trim."),
                row("scissors", "가르기", "Split", "재생 헤드 자리에서 클립을 둘로 나눕니다.", "Split a clip at the playhead."),
                row("rectangle.stack", "전체 덮기", "Overwrite all", "나뉜 클립을 한 번에 같은 분류로 바꿉니다.", "Change split clips to one category at once."),
            ]
        case .memos:
            return [
                row("plus", "메모", "Memo", "아래 막대의 메모를 누르면 지금 시각과 위치로 메모가 생깁니다.", "Tap Memo in the bottom bar to add one at this time and place."),
                row("hand.tap", "지도 메모", "Map memo", "지도를 길게 누르고 ‘위치 메모 추가’를 고르면 그 자리에 붙습니다.", "Long-press the map and choose ‘Add location memo’ to pin it there."),
                row("note.text", "모아 보기", "Browse", "왼쪽 위 메모 단추와 사이드바에서 봅니다.", "Find them with the memo button at the top left and in the sidebar."),
                row("eye", "표시 고르기", "Show or hide", "메뉴 > 표시 > 메모 표시에서 고릅니다.", "Choose in Menu > Display > Show memos."),
            ]
        case .summary:
            return [
                row("house.fill", "하루 요약", "Day summary", "아래 막대의 집이나 지도의 집 그림을 누르면 열립니다.", "Tap Home in the bottom bar or the home on the map."),
                row("checkmark.seal", "연속 달성", "Streak", "‘미확인’ 없이 기록을 채운 날이 달성입니다.", "A day counts when its records have no ‘unconfirmed’ time left."),
                row("gift", "주간 보상", "Weekly reward", "7일 연속이면 진화를 하나 고르고, 땅과 액세서리를 모읍니다.", "Every 7 days in a row, choose an evolution and collect land and accessories."),
            ]
        default:
            return []
        }
    }
}

// MARK: - 첫 화면

/// Studio 첫 화면처럼 이름, 한 줄 설명, 두 갈래로 끝낸다. 두 갈래 단추는 튜토리얼 아래쪽에 있다.
struct FirstRunWelcomePage: View {
    let language: MapHomeLanguage

    private var chapters: [(icon: String, title: String, detail: String)] {
        [
            ("checklist", language.text("먼저 설정", "Set up first"), language.text("권한, 집과 회사, 연봉, 고양이", "Permissions, home and work, salary, your cat")),
            ("map", language.text("화면 익히기", "Learn the screen"), language.text("지도, 재생, 사이드바, 편집, 메모, 집 성장", "Map, playback, sidebar, editing, memos, home growth")),
            ("lock.shield", language.text("연결과 보호", "Connect and protect"), language.text("캘린더, 백업 비밀번호", "Calendars, backup password")),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                FirstRunMascot(scene: .groom, size: 120)
                    .frame(maxWidth: .infinity)
                Text("BOKKI Plan")
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(30)), weight: .bold))
                    .foregroundStyle(Color.tpInk)
                    .accessibilityAddTraits(.isHeader)
                Text(language.text("하루가 지도 위에 저절로 기록됩니다. 무엇부터 하면 되는지 차례로 알려 드릴게요.", "Your day records itself on a map. Here's what to do first, one step at a time."))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.body), weight: .medium))
                    .foregroundStyle(Color.tpSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(chapters, id: \.title) { chapter in
                        FirstRunRowView(badge: .icon(chapter.icon), title: chapter.title, detail: chapter.detail)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text(language.text("언제든 건너뛸 수 있습니다. 메뉴 > 설정에서 다시 볼 수 있습니다.", "Skip anytime. Watch it again in Menu > Settings."))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.label), weight: .medium))
                    .foregroundStyle(Color.tpSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
        }
    }
}

// MARK: - 공통 줄

struct FirstRunRowView: View {
    enum Badge {
        case icon(String)
        case number(Int)
    }

    let badge: Badge
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                switch badge {
                case .icon(let name):
                    Image(systemName: name)
                        .font(.system(size: TaptionType.scaled(TaptionType.bodyStrong), weight: .semibold))
                        .foregroundStyle(Color.tpAccent)
                case .number(let number):
                    FirstRunNumberBadge(number: number)
                }
            }
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.bodyStrong), weight: .bold))
                    .foregroundStyle(Color.tpInk)
                Text(detail)
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.body), weight: .medium))
                    .foregroundStyle(Color.tpSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct FirstRunNumberBadge: View {
    let number: Int

    var body: some View {
        Text("\(number)")
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.caption), weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(Color.tpAccent, in: Circle())
    }
}

// MARK: - 설명 단계

struct FirstRunGuidePage: View {
    let step: FirstRunTutorialStep
    let date: Date
    let language: MapHomeLanguage

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                illustration
                    .frame(maxWidth: .infinity)
                    .padding(14)
                    .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityHidden(true)
                ForEach(Array(FirstRunGuideCatalog.rows(for: step, language: language).enumerated()), id: \.offset) { offset, row in
                    FirstRunRowView(badge: .number(offset + 1), title: row.title, detail: row.detail)
                }
            }
            .padding(18)
        }
    }

    @ViewBuilder
    private var illustration: some View {
        switch step {
        case .map:
            VStack(spacing: 12) {
                FirstRunMapSketch(language: language, showsHomeLevel: false)
                FirstRunBottomBarSketch(highlights: [.location], date: date, language: language)
            }
        case .playback:
            FirstRunBottomBarSketch(highlights: [.play, .record], date: date, language: language)
        case .sidebarCalendar:
            VStack(spacing: 12) {
                FirstRunSidebarSketch(date: date, language: language)
                FirstRunBottomBarSketch(highlights: [.calendar], date: date, language: language)
            }
        case .clipEditor:
            FirstRunClipIllustration().frame(height: 96)
        case .memos:
            VStack(spacing: 12) {
                FirstRunMapSketch(language: language, showsHomeLevel: false, memoText: language.text("여기 또 오기", "Come back here"))
                FirstRunBottomBarSketch(highlights: [.memo], date: date, language: language)
            }
        case .summary:
            VStack(spacing: 12) {
                FirstRunMapSketch(language: language, showsHomeLevel: true)
                FirstRunBottomBarSketch(highlights: [.home], date: date, language: language)
            }
        default:
            EmptyView()
        }
    }
}

/// 하단 막대 그림. 실제 단추를 그대로 써서 앱과 같은 모양을 유지한다.
private struct FirstRunBottomBarSketch: View {
    enum Item: CaseIterable {
        case menu, calendar, location, home, play, record, memo
    }

    let highlights: Set<Item>
    let date: Date
    let language: MapHomeLanguage

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Item.allCases, id: \.self) { item in
                button(item)
                    .background {
                        if highlights.contains(item) {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.tpAccent.opacity(0.16))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(Color.tpAccent, lineWidth: 2)
                                }
                        }
                    }
            }
        }
        .padding(.horizontal, 4)
        .mapHomeBottomBarPill()
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func button(_ item: Item) -> some View {
        switch item {
        case .menu: icon("line.3.horizontal", language.text("메뉴", "Menu"))
        case .calendar:
            MapHomeBottomBarButton(title: language.text("달력", "Calendar"), action: {}) {
                MapHomeCalendarGlyph(date: date, language: language)
            }
        case .location: icon("location.fill", language.text("현재 위치", "Location"))
        case .home: icon("house.fill", language.text("집", "Home"))
        case .play: icon("play.fill", language.text("재생", "Play"))
        case .record: icon("record.circle", language.text("녹화", "Record"))
        case .memo: icon("plus", language.text("메모", "Memo"))
        }
    }

    private func icon(_ name: String, _ title: String) -> some View {
        MapHomeBottomBarButton(title: title, action: {}) {
            TaptionBarIcon(systemImage: name)
        }
    }
}

/// 지도 그림: 길과 집과 고양이. 실제 지도 타일은 쓰지 않는다.
private struct FirstRunMapSketch: View {
    let language: MapHomeLanguage
    let showsHomeLevel: Bool
    var memoText: String?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let home = CGPoint(x: size.width * 0.2, y: size.height * 0.68)
            let work = CGPoint(x: size.width * 0.82, y: size.height * 0.28)
            let cat = CGPoint(x: size.width * 0.54, y: size.height * 0.42)
            ZStack {
                Color.tpBackground
                Path { path in
                    path.move(to: home)
                    path.addCurve(
                        to: work,
                        control1: CGPoint(x: size.width * 0.42, y: size.height * 0.75),
                        control2: CGPoint(x: size.width * 0.58, y: size.height * 0.2)
                    )
                }
                .stroke(Color.tpReferenceBlue, style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [2, 8]))
                Image(MapHomeLocationDestination.home.iconAssetName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 42, height: 42)
                    .position(home)
                if showsHomeLevel {
                    Text("Lv.1")
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.caption), weight: .bold))
                        .foregroundStyle(Color.tpInk)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.tpSurface, in: Capsule())
                        .position(x: home.x, y: home.y + 30)
                }
                Image(MapHomeLocationDestination.company.iconAssetName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 36, height: 36)
                    .position(work)
                FirstRunMascot(scene: .walkLoop, size: 54)
                    .position(cat)
                if let memoText {
                    Text(memoText)
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.caption), weight: .semibold))
                        .foregroundStyle(Color.tpInk)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color(hex: "#F3C766").opacity(0.85), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .rotationEffect(.degrees(-3))
                        .position(x: size.width * 0.72, y: size.height * 0.72)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .frame(height: 132)
    }
}

/// 오른쪽 시간 막대 그림. 번호는 아래 설명 줄과 같다.
private struct FirstRunSidebarSketch: View {
    let date: Date
    let language: MapHomeLanguage

    private static let segments: [(color: Color, weight: CGFloat)] = [
        (.tpReferenceBlue, 2), (.tpReferenceMint, 3), (.tpReferenceRose, 1), (.tpReferenceBlue, 2),
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            FirstRunMapSketch(language: language, showsHomeLevel: false)
            VStack(spacing: 4) {
                Text(date.formatted(.dateTime.day().locale(language.locale)))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.bodyStrong), weight: .bold))
                    .foregroundStyle(Color.tpInk)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.tpAccent)
                VStack(spacing: 2) {
                    ForEach(Self.segments.indices, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Self.segments[index].color.opacity(0.75))
                            .frame(height: 16 * Self.segments[index].weight)
                    }
                }
                .frame(width: 26)
                .overlay(alignment: .trailing) {
                    Capsule()
                        .fill(Color.tpInk)
                        .frame(width: 12, height: 5)
                        .offset(x: 9, y: -6)
                }
                Image(systemName: "pencil")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.tpInk)
            }
            .frame(width: 44)
        }
        .frame(maxHeight: 180)
    }
}

// MARK: - 고양이

struct FirstRunCatPage: View {
    @Bindable var model: AppModel
    let language: MapHomeLanguage

    private var cats: [(coat: CatCoat, name: String, caption: String)] {
        [
            (.white, language.text("화랑이", "Hwarang"), language.text("수컷 · 흰 털 · 파란 눈", "Male · white · blue eyes")),
            (.calico, language.text("춘향이", "Chunhyang"), language.text("암컷 · 삼색 털 · 호박색 눈", "Female · calico · amber eyes")),
            (.mackerel, language.text("윤복이", "Yunbok"), language.text("암컷 · 줄무늬 · 흰 가슴과 양말", "Female · tabby · white chest and socks")),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(cats, id: \.coat) { cat in
                    Button { model.selectCatCoat(cat.coat) } label: {
                        HStack(spacing: 12) {
                            CatFaceView(coat: cat.coat)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(cat.name)
                                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.bodyStrong), weight: .bold))
                                    .foregroundStyle(Color.tpInk)
                                Text(cat.caption)
                                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.label), weight: .medium))
                                    .foregroundStyle(Color.tpSecondary)
                            }
                            Spacer(minLength: 0)
                            if model.selectedCatCoat == cat.coat {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.tpAccent)
                                    .accessibilityHidden(true)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(model.selectedCatCoat == cat.coat ? Color.tpAccent : Color.clear, lineWidth: 2)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.selectedCatCoat == cat.coat ? .isSelected : [])
                    .accessibilityIdentifier("firstRunCat.\(cat.name)")
                }
                FirstRunRowView(
                    badge: .icon("line.3.horizontal"),
                    title: language.text("나중에 바꾸기", "Change later"),
                    detail: language.text("메뉴를 열고 ‘오늘 하루’ 옆 고양이를 누릅니다.", "Open Menu and tap the cat next to ‘Today’.")
                )
                .padding(.top, 4)
            }
            .padding(18)
        }
    }
}

// MARK: - 캘린더 연결

struct FirstRunCalendarPage: View {
    @Bindable var model: AppModel
    let language: MapHomeLanguage

    @State private var isGoogleConnected = GoogleCalendarAccount.shared.isConnected
    @State private var isConnecting = false
    @State private var googleMessage: String?

    private var deviceState: PermissionState { model.permissionState(for: .calendar) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                card(
                    icon: "calendar",
                    title: language.text("아이폰 캘린더", "iPhone Calendar"),
                    detail: language.text("캘린더 앱에 추가한 Apple·Google·Naver 일정을 봅니다.", "See Apple, Google, and Naver events added to the Calendar app."),
                    state: FirstRunTutorialPolicy.permissionLabel(.calendar, state: deviceState, isLocationAlways: false, language: language)
                ) {
                    if deviceState == .notDetermined {
                        Button(language.text("허용하기", "Allow")) {
                            Task {
                                _ = await model.requestCalendar()
                                model.clearError()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.tpPrimaryFill)
                        .disabled(model.isRequestingPermission)
                        .accessibilityIdentifier("firstRunCalendarAllow")
                    } else if deviceState == .denied {
                        Button(language.text("iOS 설정에서 바꾸기", "Change in iOS Settings")) {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                }

                card(
                    icon: "globe",
                    title: language.text("구글 계정 직접 연결", "Connect Google directly"),
                    detail: language.text("구글 로그인으로 Google Calendar를 바로 읽습니다. 캘린더 앱에 넣지 않아도 됩니다.", "Sign in to read Google Calendar directly, without adding it to the Calendar app."),
                    state: isGoogleConnected ? language.text("연결됨", "Connected") : language.text("연결 안 함", "Not connected")
                ) {
                    if !isGoogleConnected {
                        Button(language.text("구글 연결", "Connect Google")) { connectGoogle() }
                            .buttonStyle(.bordered)
                            .tint(Color.tpAccent)
                            .disabled(isConnecting)
                            .accessibilityIdentifier("firstRunGoogleConnect")
                    }
                    if let googleMessage {
                        Text(googleMessage)
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.label), weight: .semibold))
                            .foregroundStyle(Color.tpReferenceRose)
                    }
                }

                FirstRunRowView(
                    badge: .icon("arrow.up.left"),
                    title: language.text("일정 보는 곳", "Where to see events"),
                    detail: language.text("지도 왼쪽 위 구글 단추와 시간 막대에 나타납니다.", "Events appear under the Google button at the top left and on the time bar.")
                )
                .padding(.top, 4)
            }
            .padding(18)
        }
    }

    private func card<Content: View>(
        icon: String,
        title: String,
        detail: String,
        state: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(title, systemImage: icon)
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.bodyStrong), weight: .bold))
                    .foregroundStyle(Color.tpInk)
                Spacer(minLength: 0)
                Text(state)
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.label), weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
            }
            Text(detail)
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.body), weight: .medium))
                .foregroundStyle(Color.tpSecondary)
                .fixedSize(horizontal: false, vertical: true)
            content()
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.body), weight: .semibold))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func connectGoogle() {
        isConnecting = true
        googleMessage = nil
        Task { @MainActor in
            defer { isConnecting = false }
            do {
                try await GoogleCalendarAccount.shared.connect()
            } catch GoogleCalendarError.cancelled {
                // 사용자가 로그인 창을 닫은 경우는 알리지 않는다.
            } catch {
                googleMessage = error.localizedDescription
            }
            isGoogleConnected = GoogleCalendarAccount.shared.isConnected
        }
    }
}

// MARK: - 마무리

/// 지금 실제 상태와, 나중에 바꾸는 곳을 보여 준다. 설정하지 않은 것을 끝난 것처럼 말하지 않는다.
struct FirstRunFinishPage: View {
    @Bindable var model: AppModel
    let language: MapHomeLanguage

    @AppStorage(MapHomeSalaryPolicy.annualKey) private var annualPay = 0.0
    @AppStorage(MapHomeSalaryPolicy.monthlyPayKey) private var monthlyPay = 0.0
    @AppStorage(MapHomeSalaryPolicy.isHourlyKey) private var isHourly = false
    @AppStorage(MapHomeSalaryPolicy.hourlyKey) private var hourlyPay = 0.0

    private struct Status: Identifiable {
        let title: String
        let state: String
        let isDone: Bool
        let place: String
        var id: String { title }
    }

    private func hasPlace(_ kind: FrequentPlaceKind) -> Bool {
        model.settings.frequentPlaces.contains { $0.kind == kind && $0.point != nil }
    }

    private func placeStatus(_ title: String, _ kind: FrequentPlaceKind) -> Status {
        let isDone = hasPlace(kind)
        return Status(
            title: title,
            state: isDone ? language.text("저장됨", "Saved") : language.text("아직 없음", "Not yet"),
            isDone: isDone,
            place: language.text("메뉴 > 위치", "Menu > Location")
        )
    }

    private var statuses: [Status] {
        let locationState = model.permissionState(for: .location)
        let calendarState = model.permissionState(for: .calendar)
        let hasSalary = isHourly ? hourlyPay > 0 : annualPay > 0 || monthlyPay > 0
        let isDefaultPIN = model.securityStatus.hasPIN && model.rememberedBackupPassword == FirstRunTutorialPolicy.defaultPIN
        let isCalendarLinked = calendarState.isGranted || GoogleCalendarAccount.shared.isConnected
        return [
            Status(
                title: language.text("위치 권한", "Location access"),
                state: FirstRunTutorialPolicy.permissionLabel(
                    .location,
                    state: locationState,
                    isLocationAlways: model.sensorService?.hasAlwaysLocationAuthorization() == true,
                    language: language
                ),
                isDone: locationState.isGranted,
                place: language.text("iOS 설정 > BOKKI Plan", "iOS Settings > BOKKI Plan")
            ),
            placeStatus(language.text("집", "Home"), .home),
            placeStatus(language.text("회사", "Work"), .company),
            Status(
                title: language.text("연봉", "Salary"),
                state: hasSalary ? language.text("입력함", "Entered") : language.text("아직 없음", "Not yet"),
                isDone: hasSalary,
                place: language.text("메뉴 > 카운터", "Menu > Counters")
            ),
            Status(
                title: language.text("캘린더", "Calendar"),
                state: isCalendarLinked ? language.text("연결됨", "Connected") : language.text("연결 안 함", "Not connected"),
                isDone: isCalendarLinked,
                place: language.text("지도 왼쪽 위 구글 단추", "Google button, top left of the map")
            ),
            Status(
                title: language.text("백업 비밀번호", "Backup password"),
                state: isDefaultPIN
                    ? language.text("초기값 \(FirstRunTutorialPolicy.defaultPIN)", "Default \(FirstRunTutorialPolicy.defaultPIN)")
                    : model.securityStatus.hasPIN ? language.text("등록됨", "Set") : language.text("아직 없음", "Not yet"),
                isDone: model.securityStatus.hasPIN && !isDefaultPIN,
                place: language.text("메뉴 > 설정 > 데이터 보호", "Menu > Settings > Data Protection")
            ),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(spacing: 12) {
                    ForEach(statuses) { status in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: status.isDone ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(status.isDone ? Color.tpAccent : Color.tpSecondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(status.title)
                                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.bodyStrong), weight: .bold))
                                    .foregroundStyle(Color.tpInk)
                                Text(status.place)
                                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.label), weight: .medium))
                                    .foregroundStyle(Color.tpSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            Text(status.state)
                                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.label), weight: .semibold))
                                .foregroundStyle(Color.tpSecondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(14)
                .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                FirstRunRowView(
                    badge: .icon("lightbulb"),
                    title: language.text("오늘 할 일은 없습니다", "Nothing else to do today"),
                    detail: language.text("평소처럼 지내면 하루가 쌓입니다. 저녁에 지도를 열고 재생해 보세요.", "Go about your day and it builds up. Open the map tonight and tap Play.")
                )
                FirstRunRowView(
                    badge: .icon("arrow.counterclockwise"),
                    title: language.text("다시 보기", "Watch again"),
                    detail: language.text("메뉴 > 설정 > 튜토리얼 다시 보기", "Menu > Settings > Replay tutorial")
                )
            }
            .padding(18)
        }
    }
}

// MARK: - 다시 보기

/// 메뉴 > 설정의 줄. 튜토리얼 표시까지 여기서 맡아 지도 화면을 늘리지 않는다.
struct FirstRunTutorialReplayRow: View {
    @Bindable var model: AppModel
    let language: MapHomeLanguage

    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "graduationcap.fill")
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(16)), weight: .semibold))
                    .foregroundStyle(Color.tpAccent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(language.text("튜토리얼 다시 보기", "Replay tutorial"))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold))
                    Text(language.text("권한, 설정, 화면 사용법", "Permissions, setup, how to use the screen"))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(10.5)), weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(Color.primary)
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .background(Color.tpAccent.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("firstRunTutorialReplay")
        .fullScreenCover(isPresented: $isPresented) {
            FirstRunTutorialView(model: model, mode: .replay) { isPresented = false }
        }
    }
}
