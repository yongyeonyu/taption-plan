import SwiftUI
import UIKit

/// 메인 메뉴 → 연결 → 「AI 연결」(AIR1110A03, 예전 「AI 비서」). AI별 연결, 연결 키 관리(승인 PIN은 앱 비밀번호, PIN1110A01),
/// 할 수 있는 일·한 일을 둔다. 기록 공유 수준·보관 기간 고르기는 없앴고(ASM1115A01), 서버 기록 지우기는 데이터 보호 화면에 있다.
struct AssistantSettingsView: View {
    @Bindable var model: AppModel
    let language: MapHomeLanguage

    @Environment(\.dismiss) private var dismiss
    @State private var relayKey = TripRelay.key
    @State private var store = AssistantConnectionStore()
    @State private var selected: AssistantAIProvider?
    @AppStorage(AssistantRegistration.reconnectKey) private var needsReconnect = false

    var body: some View {
        NavigationStack {
            Form {
            Group {
                if needsReconnect { reconnectSection }
                AssistantProviderListSection(language: language, store: store) { selected = $0 }
                if let relayKey, let host = TripRelay.host {
                    AssistantConnectionsSection(language: language, host: host, masterKey: relayKey, store: store)
                }
                SharedRulesContributeSection(language: language)
                Section {
                    NavigationLink(language.text("AI가 할 수 있는 일", "What the AI can do")) { AssistantActionTogglesView(language: language) }
                    NavigationLink(language.text("AI가 한 일", "What the AI did")) { AssistantActionLogView(model: model, language: language) }
                    NavigationLink(language.text("AI 규칙", "AI rules")) { AssistantRuleListView(language: language) }
                }
            }
            .listRowBackground(Color.tpSurface)
        }
        .tpListStyle()
        // 대표 지시(AIC1111A01): 메뉴 「AI 연결」 글자를 한 단계 작게.
        .font(.taptionStyle(.subheadline))
            .navigationTitle(language.text("AI 연결", "AI connections"))
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: selected) { _, next in
                // 목록으로 돌아오면 단계를 잊는다. 다시 만들어진 화면(다른 앱에 다녀옴)은 아래 task에서 되살린다.
                if next == nil { AssistantGuideMemory.shared.end() }
            }
            .navigationDestination(item: $selected) { provider in
                AssistantProviderView(provider: provider, language: language, store: store)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(language.text("완료", "Done")) { dismiss() } }
            }
            .task {
                if selected == nil, let active = AssistantGuideMemory.shared.activeProvider() { selected = active }
                await AssistantRegistration.ensureReady()
                relayKey = TripRelay.key
                await store.reload()
            }
        }
    }

    private var reconnectSection: some View {
        Section {
            Text(language.text(
                "보안 업데이트로 예전 AI 연결을 모두 끊었어요. 쓰던 AI를 아래에서 다시 연결해 주세요.",
                "A security update disconnected your previous AI connections. Reconnect the AIs you use below."
            )).font(.taptionStyle(.footnote))
            Button(language.text("알겠어요", "Got it")) { needsReconnect = false }
        }
    }
}

/// 데이터 보호 화면의 「AI 서버 기록 모두 지우기」(ASM1115A01). 예전 「AI 연결 › 새 키로 바꾸기」와 같은 일을 한다:
/// 새 주 키를 등록하고 예전 키로 서버의 AI용 키·기록·명령·계획을 지운 뒤 바꾼다(SEC1110A02).
struct AssistantServerEraseRow: View {
    let model: AppModel
    let language: MapHomeLanguage
    @State private var isRotating = false
    @State private var isConfirming = false
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(language.text(
                "서버에 올린 기록과 모든 AI 연결, PIN을 지워요. 쓰던 AI는 다시 연결해야 해요. 연결 키가 새어 나간 것 같을 때 쓰세요.",
                "Deletes the records on the server, every AI connection and the PIN. You'll need to reconnect the AIs you use. Use it if a connection key may have leaked."
            ))
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
            .foregroundStyle(.secondary)
            Button(language.text("AI 서버 기록 모두 지우기", "Erase all AI server records"), role: .destructive) { isConfirming = true }
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                .disabled(isRotating || AssistantRelayGate.isRotating || TripRelay.key == nil)
                .confirmationDialog(
                    language.text("새 키로 바꿀까요?", "Replace the link key?"), isPresented: $isConfirming, titleVisibility: .visible
                ) {
                    Button(language.text("바꾸고 모두 지우기", "Replace and delete everything"), role: .destructive) { erase() }
                    Button(language.text("취소", "Cancel"), role: .cancel) {}
                } message: {
                    Text(language.text(
                        "서버에 올린 기록과 모든 AI 연결, PIN이 지워져요. 쓰던 AI는 다시 연결해야 해요.",
                        "The records on the server, every AI connection and the PIN are deleted. You'll need to reconnect the AIs you use."
                    ))
                }
            if let note {
                Text(note).font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium)).foregroundStyle(.secondary)
            }
        }
    }

    private func erase() {
        guard !isRotating else { return }
        isRotating = true
        let model = model
        Task { @MainActor in
            defer { isRotating = false }
            guard await TripRelay.rotateMasterKey() != nil else {
                note = AssistantKeyText.rotationFailed(language)
                return
            }
            note = language.text("지웠어요.", "Erased.")
            await AssistantActivitySync.run(model: model)
        }
    }
}

extension AssistantRetention {
    /// 보관 기간 고르기를 화면에서 없앴다(ASM1115A01). 30일로 두었던 기기는 한 번 7일로 내리고 서버의 날들을 지워 새 기간으로 다시 올리게 한다.
    /// 바꿨으면 true.
    @MainActor @discardableResult
    static func retireMonth(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.integer(forKey: defaultsKey) == month.rawValue else { return false }
        defaults.set(week.rawValue, forKey: defaultsKey)
        AssistantActivityUploadGate.reset()
        AssistantActivitySync.requestClear(defaults: defaults)
        return true
    }
}

/// 앱 상태를 지켜보고 하루 기록을 올린다. 지도 화면 본문이 저장마다 다시 그려지지 않게 따로 둔다.
private struct AssistantActivityObserver: View {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task {
                await AssistantRegistration.ensureReady()
                AssistantRetention.retireMonth()
                await AssistantActivitySync.run(model: model)
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active: Task { await AssistantActivitySync.run(model: model) }
                case .background: AssistantActivitySync.runInBackground(model: model)
                default: break
                }
            }
            .task {
                // 말풍선 파일은 한 번만 읽고, 시간 창은 30초마다 메모리에서만 본다. 바뀔 때만 다시 그려진다(BUB1110A01).
                // 앱을 켤 때와 날이 바뀔 때 지난 날의 event 말풍선을 지운다(BUB1110A02).
                var cleanedDay: Date?
                while !Task.isCancelled {
                    let today = Calendar.autoupdatingCurrent.startOfDay(for: .now)
                    if cleanedDay != today {
                        AssistantBubbleStore.cleanExpired()
                        cleanedDay = today
                    }
                    AssistantBubbleBoard.current.refresh()
                    try? await Task.sleep(for: .seconds(30))
                }
            }
            .onChange(of: model.snapshotSavedAt) { _, _ in AssistantActivitySync.requestSoon(model: model) }
            .onChange(of: model.rawDayRevisionSignal) { _, _ in AssistantActivitySync.requestSoon(model: model) }
    }
}

/// 알림은 이 작은 뷰만 지켜본다. 지도 화면 본문은 알림 때문에 다시 계산되지 않는다(REV1110A06).
private struct AssistantNoticeHost: View {
    private var inbox: AssistantInbox { .current }

    var body: some View {
        if let notice = inbox.notice {
            AssistantNoticeBanner(text: notice) { inbox.show(nil) }
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// 명령을 반영한 뒤 잠깐 보이는 알림. 누르면 바로 닫힌다.
private struct AssistantNoticeBanner: View {
    let text: String
    let onClose: () -> Void

    var body: some View {
        Button(action: onClose) {
            Label(text, systemImage: "sparkles")
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                .foregroundStyle(Color.tpInk)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .mapHomeGlass(in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.bottom, 96)
        .task(id: text) {
            try? await Task.sleep(for: .seconds(4))
            onClose()
        }
    }
}

extension MapHomeView {
    /// AI 비서 시트·알림·기록 올리기를 지도 화면에 붙인다.
    func assistantLayers<Content: View>(_ content: Content) -> some View {
        content
            .sheet(isPresented: $isAssistantPresented) {
                AssistantSettingsView(model: model, language: language)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .overlay(alignment: .bottom) {
                LedgerTollRepeatObserver(model: model)
                if TripRelay.isAvailable {
                    AssistantActivityObserver(model: model)
                    AssistantConfirmHost(model: model, language: language) { AssistantInbox.current.show($0) }
                    AssistantScreenHost(language: language) { openAssistantScreen($0) }
                    AssistantQuestionHost(language: language)
                }
                AssistantBubbleLinkBar(language: language)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 16)
                    .padding(.bottom, 150)
                AssistantNoticeHost()
            }
    }
}

extension MapHomeView {
    /// AI가 열어 달라고 한 화면(ACX1112A01). 메뉴 단추가 하는 일과 같다.
    func openAssistantScreen(_ screen: AssistantScreen) {
        switch screen {
        case .paymentAutomation, .shortcuts: isShortcutsGuidePresented = true
        case .aiConnection: isAssistantPresented = true
        case .ledger: LedgerPresenter.shared.isPresented = true
        case .dataProtection: isDataProtectionPresented = true
        case .settings:
            openMenu()
            isSettingsMenuExpanded = true
        case .salary: isSalarySettingsPresented = true
        case .carAudio: isCarAudioSheetPresented = true
        case .alarm: isAlarmSettingsPresented = true
        case .placeBook: isPlaceBookPresented = true
        case .passport: isPassportPresented = true
        case .unconfirmedReview: isUnconfirmedReviewPresented = true
        case .travel: isTravelHomePresented = true
        // ACT1114A07
        case .dayCard: isDailyCardPresented = true
        case .calendarConnect: isCalendarConnectPresented = true
        case .categoryAdd: isCategoryAddPresented = true
        // 이 둘은 `AssistantScreenHost`가 직접 띄운다.
        case .paymentAlerts, .aiRules: break
        }
    }
}

/// 열어 달라는 화면 요청을 지켜보다 앱이 앞에 있을 때 띄운다(ACX1112A01). 지도 화면 본문은 이 때문에 다시 계산되지 않는다.
/// 「BOKKI 결제」 자동화 안내는 링크가 있으면 여기서 바로 띄운다. 스위치는 사용자가 단축어 앱에서 켠다.
private struct AssistantScreenHost: View {
    let language: MapHomeLanguage
    let open: (AssistantScreen) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var isTutorialPresented = false
    /// 지도 화면에 단추가 없는 목록 화면(결제 알림 받기·AI 규칙, ACT1114A07).
    @State private var list: AssistantScreen?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: "\(AssistantScreenRequest.shared.pending?.rawValue ?? "")|\(scenePhase == .active)") { show() }
            .sheet(isPresented: $isTutorialPresented) {
                if let link = BokkiPaymentShortcut.automationLink { BokkiPaymentAddPopup(link: link, language: language) }
            }
            .sheet(isPresented: Binding(get: { list != nil }, set: { if !$0 { list = nil } })) {
                NavigationStack {
                    Group {
                        if list == .aiRules { AssistantRuleListView(language: language) } else { PaymentAlertSourcesView(language: language) }
                    }
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(language.text("완료", "Done")) { list = nil } } }
                }
            }
    }

    private func show() {
        guard scenePhase == .active, let screen = AssistantScreenRequest.shared.take() else { return }
        if screen == .paymentAutomation, BokkiPaymentShortcut.hasAutomationLink { isTutorialPresented = true }
        else if screen == .paymentAlerts || screen == .aiRules { list = screen }
        else { open(screen) }
    }
}

extension View {
    func mapHomeAssistant(_ host: MapHomeView) -> some View { host.assistantLayers(self) }
}
