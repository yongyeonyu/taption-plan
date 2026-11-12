import SwiftUI
import UIKit

/// 메인 메뉴 → 연결 → 「AI 연결」(AIR1110A03, 예전 「AI 비서」). AI별 연결, 연결 키 관리(승인 PIN은 앱 비밀번호, PIN1110A01),
/// 할 수 있는 일·한 일, 기록 공유 수준과 보관 기간, 주 키 바꾸기를 둔다. 위험한 설정은 여기서만 바꾼다.
struct AssistantSettingsView: View {
    @Bindable var model: AppModel
    let language: MapHomeLanguage

    @Environment(\.dismiss) private var dismiss
    @State private var relayKey = TripRelay.key
    @State private var isRotating = false
    @State private var keyMessage: String?
    @State private var store = AssistantConnectionStore()
    @State private var selected: AssistantAIProvider?
    @State private var isConfirmingRotation = false
    @AppStorage(AssistantShareLevel.defaultsKey) private var levelRaw = AssistantShareLevel.summary.rawValue
    @AppStorage(AssistantRetention.defaultsKey) private var retentionDays = AssistantRetention.week.rawValue
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
                Section {
                    NavigationLink(language.text("AI가 할 수 있는 일", "What the AI can do")) { AssistantActionTogglesView(language: language) }
                    NavigationLink(language.text("AI가 한 일", "What the AI did")) { AssistantActionLogView(model: model, language: language) }
                }
                Section {
                    Picker(language.text("기록 공유", "Share records"), selection: $levelRaw) {
                        ForEach(AssistantShareLevel.allCases) { Text($0.title(language)).tag($0.rawValue) }
                    }
                    Picker(language.text("서버 보관 기간", "Keep on server"), selection: $retentionDays) {
                        ForEach(AssistantRetention.allCases) { Text($0.title(language)).tag($0.rawValue) }
                    }
                } footer: {
                    Text(language.text(
                        "좌표와 경로는 보내지 않아요. 기록은 고른 기간이 지나면 서버에서 지워져요. AI 비서가 보낸 메모·일정·기록 수정은 앱을 열 때나 백그라운드 새로 고침 때 바로 반영돼요.",
                        "Coordinates and routes are never sent. Records are deleted from the server after the chosen period. Memos, schedules and record edits from the AI assistant are applied when you open the app or during background refresh."
                    ))
                }
                keySection
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
            .onChange(of: levelRaw) { old, new in
                // 덜 보내는 쪽으로 바꾸면 서버에 남은 더 자세한 날(장소 이름 등)을 모두 지운다(REV1110A06).
                let before = AssistantShareLevel(rawValue: old) ?? .summary, after = AssistantShareLevel(rawValue: new) ?? .summary
                resync(clearing: AssistantShareLevel.isDowngrade(from: before, to: after))
            }
            .onChange(of: retentionDays) { old, new in
                // 기간이 바뀌면 서버 보관 시간도 새로 정해지도록 모든 날을 다시 올린다.
                AssistantActivityUploadGate.reset()
                resync(clearing: new < old)
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

    private var keySection: some View {
        Section {
            Label(
                relayKey == nil ? language.text("연동 키가 없어요", "No link key") : language.text("연동 키가 있어요", "Link key is set"),
                systemImage: relayKey == nil ? "key" : "key.fill"
            )
            Button(language.text("새 키로 바꾸기", "Replace with a new key"), role: .destructive) { isConfirmingRotation = true }
                .disabled(isRotating || AssistantRelayGate.isRotating)
                .confirmationDialog(
                    language.text("새 키로 바꿀까요?", "Replace the link key?"), isPresented: $isConfirmingRotation, titleVisibility: .visible
                ) {
                    Button(language.text("바꾸고 모두 지우기", "Replace and delete everything"), role: .destructive) { replaceKey() }
                    Button(language.text("취소", "Cancel"), role: .cancel) {}
                } message: {
                    Text(language.text(
                        "서버에 올린 기록과 모든 AI 연결, PIN이 지워져요. 쓰던 AI는 다시 연결해야 해요.",
                        "The records on the server, every AI connection and the PIN are deleted. You'll need to reconnect the AIs you use."
                    ))
                }
            if let keyMessage { Text(keyMessage).font(.taptionStyle(.footnote)).foregroundStyle(.secondary) }
        } footer: {
            Text(language.text(
                "연동 키는 이 기기에만 있고 AI에게 주지 않아요. 키를 바꾸면 서버의 기록과 AI 연결을 모두 지워요.",
                "The link key stays on this device and is never given to the AI. Replacing it deletes the server records and all AI connections."
            ))
        }
    }

    /// 새 주 키를 등록하고 예전 키로 서버의 AI용 키·기록·명령·계획을 지운 뒤 바꾼다(SEC1110A02).
    private func replaceKey() {
        guard !isRotating else { return }
        isRotating = true
        Task { @MainActor in
            defer { isRotating = false }
            guard let key = await TripRelay.rotateMasterKey() else {
                keyMessage = AssistantKeyText.rotationFailed(language)
                return
            }
            relayKey = key
            keyMessage = nil
            await store.reload()
            resync(clearing: false)
        }
    }

    /// 덜 보내게 하거나 기간을 줄이면 서버 기록을 지우고, 켜져 있으면 새 설정으로 다시 올린다.
    /// 지우기는 적어 두었다가 `run`이 올리기 전에 하므로, 지금 서버에 닿지 못해도 다음에 지운다.
    private func resync(clearing: Bool) {
        let model = model
        if clearing { AssistantActivitySync.requestClear() }
        Task { @MainActor in await AssistantActivitySync.run(model: model) }
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

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: "\(AssistantScreenRequest.shared.pending?.rawValue ?? "")|\(scenePhase == .active)") { show() }
            .sheet(isPresented: $isTutorialPresented) {
                if let link = BokkiPaymentShortcut.automationLink { BokkiPaymentAddPopup(link: link, language: language) }
            }
    }

    private func show() {
        guard scenePhase == .active, let screen = AssistantScreenRequest.shared.take() else { return }
        if screen == .paymentAutomation, BokkiPaymentShortcut.hasAutomationLink { isTutorialPresented = true } else { open(screen) }
    }
}

extension View {
    func mapHomeAssistant(_ host: MapHomeView) -> some View { host.assistantLayers(self) }
}
