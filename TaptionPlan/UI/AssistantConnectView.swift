import Observation
import SwiftUI

/// 서버의 연결 키 목록. 「AI 연결」 화면과 튜토리얼이 함께 쓴다(AIR1110A03).
@MainActor
@Observable
final class AssistantConnectionStore {
    var keys: [AssistantScopedKey]?
    var loadFailed = false

    func reload() async {
        guard await AssistantRegistration.ensureReady() else {
            keys = keys ?? []
            loadFailed = true
            return
        }
        let loaded = await TripRelay.scopedKeys()
        keys = loaded ?? keys ?? []
        loadFailed = loaded == nil
    }

    func isConnected(_ provider: AssistantAIProvider) -> Bool {
        AssistantKeyProviders.activeKey(for: provider, in: keys ?? []) != nil
    }

    /// 그 AI의 연결 키 글자(키체인에 있는 것만). 키체인을 읽으니 화면 본문에서 부르지 않는다.
    func token(for provider: AssistantAIProvider) -> (key: AssistantScopedKey, token: String)? {
        for key in keys ?? [] where key.isActive() && AssistantKeyProviders.provider(key.id) == provider {
            if let token = AssistantKeyStore.token(for: key.id) { return (key, token) }
        }
        return nil
    }

    enum Made {
        case key(AssistantScopedKey, token: String)
        case failure(String)
    }

    /// PIN으로 그 AI의 연결 키를 만든다. 실패하면 보여 줄 문구.
    func create(
        for provider: AssistantAIProvider, pin: String, language: MapHomeLanguage, scope: AssistantKeyScope = .write, period: AssistantKeyPeriod = .quarter
    ) async -> Made {
        guard await AssistantRegistration.ensureReady() else { return .failure(AssistantKeyText.rotationFailed(language)) }
        switch await TripRelay.registerScopedKey(label: provider.title(language), scope: scope, period: period, pin: pin, provider: provider) {
        case let .created(key, token):
            await reload()
            return .key(key, token: token)
        case let .refused(refusal):
            return .failure(refusal.text(language))
        case .failed:
            // 응답이 없거나 읽지 못했다(네트워크).
            return .failure(language.text("AI 서버에 연결하지 못했어요. 인터넷 연결을 확인하고 다시 해 주세요.", "Couldn't reach the AI server. Check your connection and try again."))
        }
    }
}

/// 피클·ChatGPT·Claude·Gemini 한 줄: 이름, 요금제 배지, 받기/열기, 연결(AIR1110A04). 튜토리얼과 메뉴가 같이 쓴다.
struct AssistantProviderRow: View {
    let provider: AssistantAIProvider
    let language: MapHomeLanguage
    let isConnected: Bool
    let onConnect: () -> Void

    @Environment(\.openURL) private var openURL
    /// 설치 확인(`canOpenURL`)은 나타날 때 한 번만 한다.
    @State private var installed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(provider.title(language)).font(.body.weight(.semibold))
                if let badge = provider.planBadge(language) {
                    Text(badge)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(provider.isFreePlan ? Color.green : Color.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background((provider.isFreePlan ? Color.green : Color.orange).opacity(0.14), in: Capsule())
                }
                Spacer(minLength: 0)
                Text(isConnected ? language.text("연결됨", "Connected") : language.text("안 됨", "Not connected"))
                    .font(.caption).foregroundStyle(isConnected ? Color.green : Color.secondary)
            }
            HStack {
                if provider.appStoreURL != nil {
                    Button(installed ? language.text("열기", "Open") : language.text("받기", "Get")) {
                        if let url = provider.destination(installed: installed) { openURL(url) }
                    }
                    .accessibilityIdentifier("assistantGet.\(provider.rawValue)")
                }
                Spacer()
                Button(language.text("연결", "Connect"), action: onConnect)
                    .accessibilityIdentifier("assistantConnect.\(provider.rawValue)")
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 2)
        .task { installed = provider.isInstalled }
    }
}

/// AI별 연결 방법(AIR1110A03). 피클·기타·Gemini는 연결 키, ChatGPT·Claude는 OAuth 커넥터와 1회용 연결 코드.
struct AssistantProviderView: View {
    let provider: AssistantAIProvider
    let language: MapHomeLanguage
    let store: AssistantConnectionStore

    @Environment(\.openURL) private var openURL
    @State private var isAskingPIN = false
    @State private var code: AssistantOAuthCode?
    /// 승인 화면에 넣을 PIN(앱 비밀번호에서 만든 값). 코드와 함께만 보인다.
    @State private var approvalPIN: String?
    @State private var message: String?
    @State private var isWorking = false
    @State private var installed = false
    /// Cue: 권한과 사용 기간을 고른다(CUE1110A01). 기본은 읽기 전용·90일.
    @State private var cueAllowsEdits = false
    @State private var cuePeriod = AssistantKeyPeriod.quarter
    /// 다시 복사할 수 있는 연결 키. 키체인은 나타날 때와 만든 뒤에만 읽는다.
    @State private var existing: (key: AssistantScopedKey, token: String)?
    /// 복사한 뒤 「붙여 넣어 주세요」 창. PIN 시트가 닫힌 뒤에 띄운다.
    @State private var pendingPasteGuide = false
    /// Claude를 OAuth 대신 「주소 하나(연결 키 포함)」로 잇는다(CLD1110A01).
    @State private var makesKeyURL = false
    @State private var isShowingPasteGuide = false

    private var host: String { TripRelay.host ?? "" }

    var body: some View {
        Form {
            Section {
                LabeledContent(language.text("상태", "Status"), value: store.isConnected(provider) ? language.text("연결됨", "Connected") : language.text("안 됨", "Not connected"))
                if let badge = provider.planBadge(language) { LabeledContent(language.text("요금제", "Plan"), value: badge) }
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                if provider.planBadge(language) != nil { Text(AssistantAIProvider.planFootnote(language)) }
            }
            if provider == .cue { cueSections } else if provider.usesOAuth { oauthSections } else { keySection }
            if provider.appStoreURL != nil {
                Section {
                    Button(installed ? language.text("\(name) 열기", "Open \(name)")
                                     : language.text("App Store에서 받기", "Get it on the App Store")) { openApp() }
                }
            }
        }
        .navigationTitle(provider.title(language))
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isWorking)
        .task {
            installed = provider.isInstalled
            if store.keys == nil { await store.reload() }
            existing = store.token(for: provider)
        }
        .sheet(isPresented: $isAskingPIN, onDismiss: showPendingPasteGuide) {
            if provider.usesOAuth && !makesKeyURL {
                // 연결 코드는 PIN이 있어야 나온다. 없을 때만 여기서 만든다.
                AssistantPINSheet(language: language, purpose: pinPurpose) { pin in
                    approvalPIN = pin
                    return await fetchCode()
                }
            } else {
                AssistantPINSheet.gate(language: language, purpose: pinPurpose) { pin in await afterPIN(pin) }
            }
        }
        .alert(AssistantPasteGuide.title(language), isPresented: $isShowingPasteGuide) {
            if provider == .claude, let web = URL(string: "https://claude.ai") {
                Button(language.text("claude.ai 열기", "Open claude.ai")) { openURL(web) }
            }
            if provider.appStoreURL != nil, provider != .gemini {
                Button(language.text("\(name) 열기", "Open \(name)")) { openApp() }
            }
            Button(language.text("확인", "OK"), role: .cancel) {}
        } message: {
            Text(AssistantPasteGuide.message(provider, language))
        }
    }

    private var name: String { provider.title(language) }

    private var pinPurpose: String {
        provider.usesOAuth
            ? language.text("앱 비밀번호를 넣으면 연결 코드와 승인 화면에 넣을 PIN이 나와요.", "Enter your app password to get a code and the PIN for the approval page.")
            : language.text("\(name) 연결 키를 만들어요.", "Creates a connection key for \(name).")
    }

    // MARK: Cue (CUE1110A01)

    /// Cue에는 MCP 주소와 연결 키를 따로 넣는다. 자동으로 이어 주지 않으니 Cue에서 직접 등록한다.
    /// 주 키는 보이지도 복사되지도 않는다. 키는 피클과 같이 이 기기 키체인에만 둔다.
    @ViewBuilder
    private var cueSections: some View {
        Section {
            Toggle(language.text("기록 수정 허용", "Allow record edits"), isOn: $cueAllowsEdits)
            Picker(language.text("사용 기간", "Valid for"), selection: $cuePeriod) {
                ForEach(AssistantKeyPeriod.allCases) { Text($0.title(language)).tag($0) }
            }
            if cuePeriod == .never {
                Text(language.text("키가 새면 직접 끊어야 해요.", "If the key leaks, you have to cut it yourself.")).font(.footnote).foregroundStyle(.orange)
            }
            Button(existing == nil ? language.text("Cue 연결 키 만들기", "Make a Cue key") : language.text("새 키로 다시 만들기", "Make a new key")) { isAskingPIN = true }
        } header: {
            Text(language.text("권한과 기간", "Access and period"))
        } footer: {
            Text(cueAllowsEdits
                 ? language.text("Cue가 기록을 읽고 메모·일정·기록 수정을 보낼 수 있어요. 보낸 것은 앱에서 되돌릴 수 있어요.", "Cue can read records and send memo, schedule and record edits. You can undo them in the app.")
                 : language.text("Cue는 기록을 읽기만 해요.", "Cue can only read records."))
        }
        Section {
            Text(cueSteps).font(.footnote)
            LabeledContent(language.text("MCP 주소", "MCP URL"), value: TripRelay.mcpURL(host: host)).font(.footnote)
            Button(language.text("MCP 주소 복사", "Copy MCP URL")) {
                copy(TripRelay.mcpURL(host: host))
                message = language.text("MCP 주소를 복사했어요.", "MCP URL copied.")
            }
            if let existing {
                LabeledContent(language.text("연결 키", "Connection key"), value: AssistantCueText.masked(existing.token)).font(.footnote.monospaced())
                Button(language.text("연결 키 복사", "Copy connection key")) {
                    copy(existing.token)
                    message = language.text("연결 키를 복사했어요. 10분 뒤 클립보드에서 지워져요.", "Key copied. It is cleared from the clipboard in 10 minutes.")
                }
            }
        } header: {
            Text(language.text("Cue에서 직접 등록", "Register in Cue"))
        } footer: {
            Text(language.text(
                "앱이 Cue에 자동으로 연결해 주지는 않아요. 연결 키는 이 연결에만 쓰는 키이고, 앱의 주 키는 보내지 않아요. 아래 「연결 키 관리」에서 언제든 끊을 수 있어요.",
                "The app doesn't connect to Cue for you. The key is only for this connection; the app's own key is never sent. You can cut it anytime under connection keys."
            ))
        }
    }

    private var cueSteps: String {
        language.text(
            "1. 위에서 권한·기간을 고르고 「Cue 연결 키 만들기」를 눌러요.\n2. Cue에서 MCP 서버(커넥터)를 추가하는 화면을 열어요.\n3. 서버 주소에 MCP 주소를 붙여 넣어요.\n4. 인증 칸(요청 헤더)에 Authorization: Bearer 뒤에 연결 키를 붙여 넣어요. 칸 이름은 Cue 화면을 따라 주세요.\n5. 저장한 뒤 Cue에서 「오늘 기록 읽어 줘」처럼 물어 확인해요.",
            "1. Pick access and period above, then tap Make a Cue key.\n2. In Cue, open the screen for adding an MCP server (connector).\n3. Paste the MCP URL as the server address.\n4. In the auth field (request header), enter Authorization: Bearer followed by the connection key. Field names follow Cue's screen.\n5. Save, then ask Cue something like \"read today's records\" to check."
        )
    }

    // MARK: 연결 키

    private var keySection: some View {
        Section {
            Text(keySteps).font(.footnote)
            Button(language.text("연결하기", "Connect")) { isAskingPIN = true }
            if let existing {
                Button(language.text("연결 안내 다시 복사", "Copy setup again")) {
                    Task {
                        await copySetup(existing.token, key: existing.key)
                        isShowingPasteGuide = true
                    }
                }
            }
        } footer: {
            if provider == .gemini {
                Text(language.text(
                    "Gemini 앱은 연결할 수 없어요. 앱에서는 여행 프롬프트를 복사해 붙여 넣고, 받은 JSON을 이 앱에 붙여 넣어 주세요.",
                    "The Gemini app can't connect. In the app, paste the trip prompt and bring the JSON back here."
                ))
            }
        }
    }

    private var keySteps: String {
        switch provider {
        case .gemini:
            language.text(
                "Gemini CLI: 연결하기를 누르면 settings.json에 넣을 설정이 복사돼요. ~/.gemini/settings.json에 붙여 넣고 gemini를 다시 시작하세요.",
                "Gemini CLI: Connect copies a block for settings.json. Paste it into ~/.gemini/settings.json and restart gemini."
            )
        case .pickle:
            language.text("연결하기를 누르면 연결 안내가 복사되고 피클이 열려요. 피클 채팅창에 붙여 넣어 주세요.", "Connect copies the setup and opens Pickle. Paste it into the Pickle chat.")
        default:
            language.text("연결하기를 누르면 연결 안내가 복사돼요. 웹 요청을 할 수 있는 AI에 붙여 넣어 주세요.", "Connect copies the setup. Paste it into any AI that can make web requests.")
        }
    }

    // MARK: OAuth

    @ViewBuilder
    private var oauthSections: some View {
        if provider == .claude { keyURLSection }
        Section {
            Text(oauthSteps).font(.footnote)
            LabeledContent(language.text("서버 주소", "Server URL"), value: TripRelay.mcpURL(host: host)).font(.footnote)
            Button(language.text("서버 주소 복사", "Copy server URL")) { copy(TripRelay.mcpURL(host: host)) }
            Button(language.text("연결 코드 받기", "Get a connection code")) { requestCode() }
            if let code { codeView(code) }
        } header: {
            Text(language.text("커넥터로 연결", "Connect as a connector"))
        }
        if provider == .claude {
            Section {
                Text(TripRelay.claudeCodeCommand(host: host)).font(.footnote.monospaced()).textSelection(.enabled)
                Button(language.text("명령 복사", "Copy command")) { copy(TripRelay.claudeCodeCommand(host: host)) }
            } header: {
                Text("Claude Code")
            } footer: {
                Text(language.text("터미널에 붙여 넣은 뒤 /mcp에서 bokki를 인증하고, 열린 화면에 연결 코드와 PIN을 넣어요.",
                                   "Paste it in a terminal, authenticate bokki in /mcp, then enter the code and PIN on the page that opens."))
            }
        }
        if provider == .chatGPT {
            Section {
                Text(language.text(
                    "맞춤 GPT는 Actions에 https://\(host)/openapi.json을 넣고 인증에 「기타」 연결 키를 Bearer로 넣어요.",
                    "For a custom GPT, add https://\(host)/openapi.json under Actions and use an Other connection key as the Bearer token."
                )).font(.footnote)
            }
        }
    }

    /// 모바일에서 가장 쉬운 길: 연결 키가 든 주소 하나를 붙여 넣고 「로그인 없음」을 고른다(CLD1110A01).
    private var keyURLSection: some View {
        Section {
            Text(language.text(
                "연결 주소를 만들면 복사돼요. Claude → 설정 → 커넥터 → 맞춤 커넥터 추가에 주소를 붙여 넣고, 인증은 「로그인 없음」을 고르면 끝나요.",
                "Make a link and it's copied. In Claude, open Settings → Connectors → Add custom connector, paste the link and choose No sign-in."
            )).font(.footnote)
            Button(language.text("연결 주소 만들기", "Make a connection link")) {
                makesKeyURL = true
                isAskingPIN = true
            }
            if let existing {
                Button(language.text("연결 주소 다시 복사", "Copy the link again")) {
                    Task {
                        await copySetup(existing.token, key: existing.key)
                        isShowingPasteGuide = true
                    }
                }
            }
        } header: {
            Text(language.text("주소 하나로 연결 (추천)", "Connect with one link (recommended)"))
        } footer: {
            Text(language.text(
                "주소에 연결 키가 들어 있어요. 다른 사람에게 보이지 마세요. 아래 「연결 키 관리」에서 언제든 끊을 수 있어요.",
                "The link contains a connection key. Don't share it. You can cut it anytime under connection keys."
            ))
        }
    }

    private var oauthSteps: String {
        provider == .claude
            ? language.text(
                "claude.ai → 설정 → 커넥터 → 맞춤 커넥터 추가에 서버 주소를 넣고 연결을 누르세요. 열린 화면에 아래 연결 코드와 PIN을 넣으면 끝나요.",
                "On claude.ai, open Settings → Connectors → Add custom connector, enter the server URL and connect. Enter the code below and your PIN on the page that opens."
            )
            : language.text(
                "ChatGPT → 설정 → 앱과 커넥터 → 고급에서 개발자 모드를 켜고, 커넥터 만들기에 서버 주소를 넣으세요(OAuth). 열린 화면에 아래 연결 코드와 PIN을 넣으면 끝나요.",
                "In ChatGPT, open Settings → Apps & Connectors → Advanced, turn on developer mode and create a connector with the server URL (OAuth). Enter the code below and your PIN on the page that opens."
            )
    }

    private func codeView(_ code: AssistantOAuthCode) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = Int(code.remaining(now: context.date))
            VStack(alignment: .leading, spacing: 4) {
                Text(code.code).font(.title2.monospaced().weight(.bold)).textSelection(.enabled)
                if let approvalPIN, left > 0 {
                    LabeledContent(language.text("승인 화면 PIN", "Approval page PIN")) {
                        Text(approvalPIN).font(.body.monospaced().weight(.semibold)).textSelection(.enabled)
                    }
                }
                Text(left > 0
                     ? language.text("\(left / 60)분 \(left % 60)초 남음 · 한 번만 쓸 수 있어요", "\(left / 60)m \(left % 60)s left · single use")
                     : language.text("코드가 끝났어요. 새로 받아 주세요.", "The code expired. Get a new one."))
                    .font(.caption).foregroundStyle(left > 0 ? Color.secondary : Color.red)
                if left > 0 { Button(language.text("코드 복사", "Copy code")) { copy(code.code) }.buttonStyle(.borderless) }
            }
        }
    }

    // MARK: 동작

    /// 앱 비밀번호를 받아 서버 PIN을 맞춘 뒤 코드를 받는다(PIN1110A01). 승인 화면 PIN을 함께 보여야 해서 매번 묻는다.
    private func requestCode() {
        code = nil
        approvalPIN = nil
        isAskingPIN = true
    }

    /// 실패하면 보여 줄 문구.
    private func fetchCode() async -> String? {
        let failure = language.text("연결 코드를 받지 못했어요.", "Couldn't get a connection code.")
        guard await AssistantRegistration.ensureReady() else { return failure }
        switch await TripRelay.requestOAuthCode() {
        case let .code(made):
            code = made
            return nil
        case .pinNotSet:
            if !isAskingPIN { isAskingPIN = true }
            return AssistantServerRefusal(kind: .pinNotSet).text(language)
        case .failed:
            return failure
        }
    }

    /// PIN을 받은 뒤 연결 키를 만든다.
    private func afterPIN(_ pin: String) async -> String? {
        let old = provider == .cue ? existing?.key : nil
        let made = provider == .cue
            ? await store.create(for: provider, pin: pin, language: language, scope: cueAllowsEdits ? .write : .read, period: cuePeriod)
            : await store.create(for: provider, pin: pin, language: language)
        switch made {
        case let .failure(text): return text
        case let .key(key, token):
            existing = (key, token)
            if provider == .cue {
                // 새 키를 만들었으면 예전 Cue 키는 끊는다. 주소와 키는 화면에서 따로 복사한다.
                if let old, old.id != key.id { _ = await TripRelay.revokeScopedKey(old.id) }
                await store.reload()
                message = language.text("연결 키를 만들었어요. 아래에서 MCP 주소와 연결 키를 복사해 Cue에 넣어 주세요.", "Key made. Copy the MCP URL and the key below into Cue.")
                return nil
            }
            await copySetup(token, key: key)
        }
        // 시트가 닫히면 「붙여 넣어 주세요」 창을 띄우고, 거기서 피클을 연다.
        pendingPasteGuide = true
        return nil
    }

    /// 웹 요청을 하는 AI에는 키 대신 1회용 주소만 복사한다(SET1110A01). 서버에 닿지 못하면 전체 안내를 복사한다.
    private func copySetup(_ token: String, key: AssistantScopedKey) async {
        switch provider {
        case .gemini: copy(TripRelay.geminiSettings(host: host, key: token))
        case .claude: copy(TripRelay.mcpKeyURL(host: host, key: token))
        default:
            let full = TripRelay.assistantSetupText(host: host, key: token, scope: key.scope, expiresAt: key.expiresAt)
            copy(await TripRelay.setupLinkText(for: full) ?? full)
        }
        message = language.text("연결 안내를 복사했어요. 10분 뒤 클립보드에서 지워져요.", "Setup copied. It is cleared from the clipboard in 10 minutes.")
    }

    private func copy(_ text: String) { AssistantClipboard.copy(text) }

    private func showPendingPasteGuide() {
        makesKeyURL = false
        guard pendingPasteGuide else { return }
        pendingPasteGuide = false
        isShowingPasteGuide = true
    }

    private func openApp() {
        installed = provider.isInstalled
        if let url = provider.destination(installed: installed) { openURL(url) }
    }
}

/// 「AI 연결」 맨 위 AI 목록(AIR1110A04). 기타는 배지 없이 연결만.
struct AssistantProviderListSection: View {
    let language: MapHomeLanguage
    let store: AssistantConnectionStore
    let onConnect: (AssistantAIProvider) -> Void

    var body: some View {
        Section {
            ForEach(AssistantAIProvider.featured) { provider in
                AssistantProviderRow(provider: provider, language: language, isConnected: store.isConnected(provider)) { onConnect(provider) }
            }
            Button("Cue") { onConnect(.cue) }
            Button(language.text("기타 AI (웹 요청)", "Other AI (web requests)")) { onConnect(.other) }
        } header: {
            Text(language.text("AI 고르기", "Choose an AI"))
        } footer: {
            Text(AssistantAIProvider.planFootnote(language))
        }
    }
}

/// 연결 안내를 복사한 뒤 어디에 붙여 넣는지 알리는 창의 문구.
enum AssistantPasteGuide {
    static func title(_ language: MapHomeLanguage) -> String {
        language.text("연결 안내를 복사했어요", "Setup copied")
    }

    static func message(_ provider: AssistantAIProvider, _ language: MapHomeLanguage) -> String {
        let name = provider.title(language)
        let place: String
        switch provider {
        case .gemini:
            place = language.text("~/.gemini/settings.json에 붙여 넣고 gemini를 다시 시작해 주세요.", "Paste it into ~/.gemini/settings.json and restart gemini.")
        case .claude:
            return language.text(
                "Claude → 설정 → 커넥터 → 맞춤 커넥터 추가에 주소를 붙여 넣고 인증은 「로그인 없음」을 고르세요. 클립보드는 10분 뒤 지워져요.",
                "In Claude, open Settings → Connectors → Add custom connector, paste the link and choose No sign-in. The clipboard is cleared in 10 minutes."
            )
        case .other:
            place = language.text("웹 요청을 할 수 있는 AI의 채팅창에 붙여 넣고 보내 주세요.", "Paste it into the chat of an AI that can make web requests, then send.")
        default:
            place = language.text("\(name) 채팅창에 붙여 넣고 보내 주세요.", "Paste it into the \(name) chat and send.")
        }
        return place + " " + language.text("클립보드는 10분 뒤 지워져요.", "The clipboard is cleared in 10 minutes.")
    }
}

enum AssistantCueText {
    /// 화면에는 앞 4자·뒤 4자만 보인다. 복사 버튼만 키 전체를 쓴다.
    static func masked(_ token: String) -> String {
        guard token.count > 8 else { return String(repeating: "•", count: token.count) }
        return "\(token.prefix(4))…\(token.suffix(4))"
    }
}
