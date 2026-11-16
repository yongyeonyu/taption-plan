import SwiftUI

/// 메뉴 찾기·최근에 연 줄에 쓰는 메뉴 항목(HUX1116A05). 시트를 여는 줄은 메뉴를 먼저 닫는다.
enum MapHomeMenuShortcut: String, CaseIterable, Identifiable, Sendable {
    case placeBook, passport, display, counter, calendarConnect, car, shortcuts, ai
    case settings, dataProtection, homeGuide, alerts, dayCard, planReality, ledger, addExpense, attribution

    var id: String { rawValue }

    func title(_ language: MapHomeLanguage) -> String {
        switch self {
        case .placeBook: language.text("장소 도감", "Place book")
        case .passport: language.text("여권", "Passport")
        case .display: language.text("표시", "Display")
        case .counter: language.text("카운터", "Counter")
        case .calendarConnect: language.text("캘린더 연결", "Calendar")
        case .car: language.text("내 차 등록", "My car")
        case .shortcuts: language.text("단축어 · Siri", "Shortcuts · Siri")
        case .ai: language.text("AI 연결", "AI connections")
        case .settings: language.text("설정", "Settings")
        case .dataProtection: language.text("데이터 보호", "Data Protection")
        case .homeGuide: language.text("홈 사용법", "Home guide")
        case .alerts: language.text("알림", "Alerts")
        case .dayCard: language.text("하루 카드", "Day card")
        case .planReality: language.text("계획과 실제", "Plan vs actual")
        case .ledger: language.text("가계부", "Ledger")
        case .addExpense: language.text("지출 넣기", "Add spending")
        case .attribution: language.text("지도 출처", "Map attribution")
        }
    }

    /// 이름 말고도 찾기에 걸리는 말(한국어·영어 모두).
    var keywords: [String] {
        switch self {
        case .placeBook: ["도장", "stamp", "places"]
        case .passport: ["여행", "trip", "travel"]
        case .display: ["지도 스타일", "안개", "사이드바", "map style", "fog", "sidebar"]
        case .counter: ["걸음", "연봉", "steps", "salary"]
        case .calendarConnect: ["구글", "일정", "google", "events"]
        case .car: ["블루투스", "카플레이", "bluetooth", "carplay"]
        case .shortcuts: ["결제 문자", "payment", "siri"]
        case .ai: ["비서", "assistant"]
        case .settings: ["권한", "permissions"]
        case .dataProtection: ["백업", "비밀번호", "backup", "password"]
        case .homeGuide: ["제스처", "도움말", "gesture", "help"]
        case .alerts: ["알람", "alarm", "notification"]
        case .dayCard: ["공유", "share"]
        case .planReality: ["통계", "stats"]
        case .ledger: ["지출", "돈", "money", "spending"]
        case .addExpense: ["₩", "돈", "money", "expense"]
        case .attribution: ["저작권", "license", "copyright"]
        }
    }

    var systemImage: String {
        switch self {
        case .placeBook: "seal.fill"
        case .passport: "book.closed.fill"
        case .display: "square.3.layers.3d"
        case .counter: "number.circle.fill"
        case .calendarConnect: "calendar.badge.plus"
        case .car: "car.fill"
        case .shortcuts: "square.2.layers.3d"
        case .ai: "sparkles"
        case .settings: "gearshape.fill"
        case .dataProtection: "lock.shield.fill"
        case .homeGuide: "hand.tap.fill"
        case .alerts: "bell.badge"
        case .dayCard: "photo.on.rectangle.angled"
        case .planReality: "chart.bar.xaxis"
        case .ledger: "wonsign.circle.fill"
        case .addExpense: "plus.circle.fill"
        case .attribution: "info.circle"
        }
    }

    var tintHex: String {
        switch self {
        case .placeBook, .passport: MapHomeInkWash.sealHex
        case .display, .counter: "#C98A3F"
        case .calendarConnect: "#3E8FDC"
        case .car: "#4F86B8"
        case .shortcuts: "#C2557A"
        case .ai: "#7A6FD0"
        case .settings, .dataProtection, .homeGuide: "#8A6A4F"
        case .alerts: "#D9952B"
        case .dayCard: "#D9627F"
        case .planReality: "#2F3E6B"
        case .ledger, .addExpense: "#3F9C6B"
        case .attribution: "#8C8574"
        }
    }

    /// 누르면 시트가 떠서 메뉴를 먼저 닫는 항목. 나머지는 메뉴 안 묶음을 펼친다.
    var opensSheet: Bool { ![.display, .counter, .settings].contains(self) }
}

enum MapHomeMenuFinder {
    static let recentLimit = 3

    /// 이름(한국어·영어)과 덧붙인 말에서 찾는다. 대소문자·띄어쓰기·「·」 같은 기호를 가리지 않는다.
    static func matches(_ query: String, in shortcuts: [MapHomeMenuShortcut]) -> [MapHomeMenuShortcut] {
        let needle = normalized(query)
        guard !needle.isEmpty else { return [] }
        return shortcuts.filter { shortcut in
            ([shortcut.title(.korean), shortcut.title(.english)] + shortcut.keywords)
                .contains { normalized($0).contains(needle) }
        }
    }

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber || $0 == "₩" }
    }

    /// 최근에 연 줄: 맨 앞에 새로 넣고 겹친 것은 빼며 3개까지.
    static func recents(_ raw: String, adding shortcut: MapHomeMenuShortcut) -> String {
        var list = recentShortcuts(raw).filter { $0 != shortcut }
        list.insert(shortcut, at: 0)
        return list.prefix(recentLimit).map(\.rawValue).joined(separator: ",")
    }

    static func recentShortcuts(_ raw: String) -> [MapHomeMenuShortcut] {
        raw.split(separator: ",").compactMap { MapHomeMenuShortcut(rawValue: String($0)) }
    }
}

/// 홈 화면에 표시가 없는 손짓을 모은 한 장(HUX1116A05).
struct MapHomeUsageGuideSheet: View {
    let language: MapHomeLanguage
    @Environment(\.dismiss) private var dismiss

    private var rows: [(String, String, String)] {
        [
            ("pawprint.fill", language.text("화랑이 누르기", "Tap the cat"), language.text("카운터 창을 켜고 끕니다. 카운터 창을 누르면 자세히 봅니다.", "Shows or hides the counter. Tap the counter for details.")),
            ("hand.point.up.left.fill", language.text("지도 길게 누르기", "Long-press the map"), language.text("그 자리에 메모를 넣습니다.", "Adds a memo at that spot.")),
            ("house.fill", language.text("지도의 집 누르기", "Tap home on the map"), language.text("하루 요약을 엽니다.", "Opens the day summary.")),
            ("hand.tap.fill", language.text("사이드바 두 번 누르기", "Double-tap the sidebar"), language.text("그 시간 기록을 고칩니다.", "Edits the record at that time.")),
            ("hand.raised.fill", language.text("사이드바 길게 누르기", "Long-press the sidebar"), language.text("무늬가 무슨 뜻인지 봅니다.", "Shows what the patterns mean.")),
            ("arrow.up.left.and.arrow.down.right", language.text("사이드바 두 손가락 벌리기", "Pinch the sidebar"), language.text("시간선을 크게 봅니다.", "Zooms the timeline.")),
            ("arrow.up.and.down", language.text("화면 오른쪽 끝 끌기", "Drag the right edge"), language.text("시각을 고릅니다.", "Picks a time.")),
            ("note.text", language.text("「메모」 길게 누르기", "Long-press Memo"), language.text("가계부를 엽니다. 할 일 판 ₩ 줄의 ＋로 지출을 바로 넣을 수도 있습니다.", "Opens the ledger. The ＋ on the ₩ row adds spending directly.")),
        ]
    }

    var body: some View {
        NavigationStack {
            List(rows, id: \.1) { row in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: row.0)
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(16)), weight: .semibold))
                        .foregroundStyle(Color.tpAccent)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.1).font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .semibold))
                        Text(row.2).font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .regular))
                            .foregroundStyle(Color.tpSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
            .navigationTitle(language.text("홈 사용법", "Home guide"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.text("닫기", "Close")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

extension View {
    func mapHomeUsageGuide(isPresented: Binding<Bool>, language: MapHomeLanguage) -> some View {
        sheet(isPresented: isPresented) { MapHomeUsageGuideSheet(language: language) }
    }
}

extension MapHomeView {
    var availableMenuShortcuts: [MapHomeMenuShortcut] {
        MapHomeMenuShortcut.allCases.filter { $0 != .ai || TripRelay.isAvailable }
    }

    /// 메뉴 줄 하나를 연다. 시트를 여는 줄은 메뉴를 먼저 닫아 시트를 닫았을 때 메뉴가 남지 않게 한다.
    func performMenuShortcut(_ shortcut: MapHomeMenuShortcut) {
        menuRecentRaw = MapHomeMenuFinder.recents(menuRecentRaw, adding: shortcut)
        menuSearchQuery = ""
        if shortcut.opensSheet { isMenuOpen = false }
        switch shortcut {
        case .placeBook: isPlaceBookPresented = true
        case .passport:
            passportStartPage = 0
            passportReturnPage = nil
            isPassportPresented = true
        case .display: isDisplayMenuExpanded = true
        case .counter:
            isDisplayMenuExpanded = true
            isCounterMenuExpanded = true
        case .calendarConnect: isCalendarConnectPresented = true
        case .car: isCarAudioSheetPresented = true
        case .shortcuts: isShortcutsGuidePresented = true
        case .ai: isAssistantPresented = true
        case .settings: isSettingsMenuExpanded = true
        case .dataProtection: isDataProtectionPresented = true
        case .homeGuide: isHomeGuidePresented = true
        case .alerts: isAlarmSettingsPresented = true
        case .dayCard: isDailyCardPresented = true
        case .planReality: isPlanRealityPresented = true
        case .ledger: LedgerPresenter.shared.isPresented = true
        case .addExpense: LedgerPresenter.shared.presentAdding()
        case .attribution: isMapAttributionPresented = true
        }
    }

    func menuShortcutRow(_ shortcut: MapHomeMenuShortcut) -> some View {
        menuRowButton(shortcut.systemImage, shortcut.title(language), tint: .tpMenuChip(shortcut.tintHex)) {
            performMenuShortcut(shortcut)
        }
    }

    /// 메뉴 맨 위: 찾기 칸, 그 아래 찾은 줄 또는 최근에 연 줄 3개.
    @ViewBuilder
    var menuFinderSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.tpSecondary)
            TextField(language.text("메뉴 찾기", "Search menu"), text: $menuSearchQuery)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit {
                    if let first = MapHomeMenuFinder.matches(menuSearchQuery, in: availableMenuShortcuts).first {
                        performMenuShortcut(first)
                    }
                }
            if !menuSearchQuery.isEmpty {
                Button { menuSearchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.tpSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(language.text("지우기", "Clear"))
            }
        }
        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .medium))
        .padding(.horizontal, 14)
        .frame(minHeight: TaptionMenuMetrics.minimumHitSize)
        .mapHomeGlass(in: Capsule())
        .padding(.bottom, 10)
        .accessibilityIdentifier("mapHomeMenuSearch")

        let found = MapHomeMenuFinder.matches(menuSearchQuery, in: availableMenuShortcuts)
        if !menuSearchQuery.isEmpty {
            menuGroupCard {
                if found.isEmpty {
                    Text(language.text("찾는 메뉴가 없어요", "No matching menu"))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .regular))
                        .foregroundStyle(Color.tpSecondary)
                        .modifier(MapHomeMenuRowPadding())
                        .padding(.horizontal, 12)
                }
                ForEach(Array(found.enumerated()), id: \.element) { index, shortcut in
                    if index > 0 { menuGroupDivider }
                    menuShortcutRow(shortcut)
                }
            }
        } else {
            let recent = MapHomeMenuFinder.recentShortcuts(menuRecentRaw).filter(availableMenuShortcuts.contains)
            if !recent.isEmpty {
                menuGroupLabel(language.text("최근", "Recent"))
                menuGroupCard {
                    ForEach(Array(recent.enumerated()), id: \.element) { index, shortcut in
                        if index > 0 { menuGroupDivider }
                        menuShortcutRow(shortcut)
                    }
                }
            }
        }
    }
}
