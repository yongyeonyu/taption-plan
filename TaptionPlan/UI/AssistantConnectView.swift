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

/// 피클·ChatGPT·Claude·Gemini·Cue·Muse 한 줄: 이름, 요금제 배지, 받기/열기, 연결(AIR1110A04). 튜토리얼과 메뉴가 같이 쓴다.
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
                Text(provider.title(language)).font(.taptionStyle(.subheadline, weight: .medium))
                if let badge = provider.planBadge(language) {
                    Text(badge)
                        .font(.taptionStyle(.caption2, weight: .bold))
                        .foregroundStyle(provider.isFreePlan ? Color.green : Color.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background((provider.isFreePlan ? Color.green : Color.orange).opacity(0.14), in: Capsule())
                }
                Spacer(minLength: 0)
                Text(isConnected ? language.text("연결됨", "Connected") : language.text("안 됨", "Not connected"))
                    .font(.taptionStyle(.caption)).foregroundStyle(isConnected ? Color.green : Color.secondary)
            }
            HStack {
                if provider.appStoreURL != nil {
                    let open = provider.openButton(installed: installed, connected: isConnected)
                    Button(open.isOpen ? language.text("열기", "Open") : language.text("받기", "Get")) {
                        if let url = open.url { openURL(url) }
                    }
                    .accessibilityIdentifier("assistantGet.\(provider.rawValue)")
                }
                Spacer()
                Button(language.text("연결", "Connect"), action: onConnect)
                    .accessibilityIdentifier("assistantConnect.\(provider.rawValue)")
            }
            // 대표 지시(AIC1111A01): 단추 글자를 작고 굵지 않게. 튜토리얼과 메뉴가 같은 줄을 쓴다.
            .font(.taptionStyle(.footnote, weight: .regular))
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 2)
        .task { installed = provider.isInstalled }
    }
}

/// AI별 연결 방법(AIR1110A03). 피클·기타·Gemini는 연결 키, Cue·Muse는 연결 키 + MCP 직접 등록, ChatGPT·Claude는 OAuth 커넥터와 1회용 연결 코드.
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
    /// 연결 키를 만드는 단계 안에서 권한과 사용 기간을 고른다(KEY1120A01). Cue·Muse는 읽기 전용, 나머지는 예전처럼 기록 수정 허용이 기본. 기간은 90일.
    @State private var editsChoice: Bool?
    @State private var connectorPeriod = AssistantKeyPeriod.quarter
    /// 다시 복사할 수 있는 연결 키. 키체인은 나타날 때와 만든 뒤에만 읽는다.
    @State private var existing: (key: AssistantScopedKey, token: String)?
    /// 복사한 뒤 「붙여 넣어 주세요」 창. PIN 시트가 닫힌 뒤에 띄운다.
    @State private var pendingPasteGuide = false
    /// Claude를 OAuth 대신 「주소 하나(연결 키 포함)」로 잇는다(CLD1110A01).
    @State private var makesKeyURL = false
    /// Claude 바로 추가: 코드를 받은 뒤 코드·PIN을 보이고 키 없는 추가 창을 연다(CLD1111A01).
    @State private var opensClaudeAdd = false
    @State private var isShowingClaudeAdd = false
    @State private var isShowingPasteGuide = false

    private var host: String { TripRelay.host ?? "" }

    private var connectorAllowsEdits: Bool { editsChoice ?? !provider.usesKeyConnector }
    /// Claude는 OAuth가 기본이라 이 선택을 쓰지 않는다. 연결 키를 만드는 나머지 AI는 모두 키 만들기 단계에서 고른다.
    private var choosesKeyOptions: Bool { provider != .claude }

    var body: some View {
        Form {
            Group {
            Section {
                LabeledContent(language.text("상태", "Status"), value: store.isConnected(provider) ? language.text("연결됨", "Connected") : language.text("안 됨", "Not connected"))
                if let badge = provider.planBadge(language) { LabeledContent(language.text("요금제", "Plan"), value: badge) }
                if let message { Text(message).font(.taptionStyle(.footnote)).foregroundStyle(.secondary) }
            } footer: {
                if provider.planBadge(language) != nil { Text(AssistantAIProvider.planFootnote(language)) }
            }
            AssistantGuideSection(
                provider: provider,
                steps: AssistantGuidePlan.steps(
                    provider, host: host, token: existing?.token,
                    code: code.flatMap { $0.remaining(now: .now) > 0 ? $0.code : nil }, pin: approvalPIN, language: language,
                    scope: existing?.key.scope ?? .read, expiresAt: existing?.key.expiresAt
                ),
                language: language, isConnected: store.isConnected(provider), perform: performGuide,
                keyOptions: choosesKeyOptions ? AnyView(keyOptionRows) : nil
            )
            if provider.usesKeyConnector { keyConnectorSections } else if provider.usesOAuth { oauthSections } else { keySection }
            if provider.appStoreURL != nil {
                Section {
                    Button(installed ? language.text("\(name) 열기", "Open \(name)")
                                     : language.text("App Store에서 받기", "Get it on the App Store")) { openApp() }
                }
            }
        }
            .listRowBackground(Color.tpSurface)
        }
        .tpListStyle()
        .font(.taptionStyle(.subheadline))
        .navigationTitle(provider.title(language))
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isWorking)
        .task {
            installed = provider.isInstalled
            // 다른 앱에 다녀와 화면이 다시 만들어졌으면 받아 둔 코드·PIN을 되살린다(GDE1111A01).
            let memory = AssistantGuideMemory.shared
            memory.begin(provider)
            if code == nil, memory.code != nil { code = memory.code; approvalPIN = memory.approvalPIN }
            if store.keys == nil { await store.reload() }
            existing = store.token(for: provider)
        }
        .sheet(isPresented: $isAskingPIN, onDismiss: showPendingPasteGuide) {
            if provider.usesOAuth && !makesKeyURL {
                // 연결 코드는 PIN이 있어야 나온다. 없을 때만 여기서 만든다.
                AssistantPINSheet(language: language, purpose: pinPurpose) { pin in
                    approvalPIN = pin
                    let failure = await fetchCode()
                    if failure == nil, opensClaudeAdd, let code { copy(code.code) }
                    if failure == nil, let code {
                        AssistantGuideMemory.shared.keep(code: code, pin: pin)
                        advanceGuide(from: "code")
                    }
                    return failure
                }
            } else {
                AssistantPINSheet.gate(language: language, purpose: pinPurpose) { pin in await afterPIN(pin) }
            }
        }
        .alert(language.text("연결 코드를 복사했어요", "Code copied"), isPresented: $isShowingClaudeAdd) {
            if let add = TripRelay.claudeAddConnectorURL(host: host) {
                Button(language.text("Claude 열기", "Open Claude")) { openURL(add) }
            }
            Button(language.text("취소", "Cancel"), role: .cancel) {}
        } message: {
            Text(language.text(
                "Claude에서 「Add」를 누르면 승인 화면이 열려요. 코드를 붙여 넣고 PIN \(approvalPIN ?? "")을 넣어 주세요. 코드는 10분 안에 한 번만 쓸 수 있어요.",
                "Tap Add in Claude to open the approval page. Paste the code and enter PIN \(approvalPIN ?? ""). The code works once within 10 minutes."
            ))
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

    // MARK: 연결 키 + MCP 직접 등록 (Cue CUE1110A01, Muse MUS1120A01)

    /// Cue·Muse에는 MCP 주소와 연결 키를 따로 넣는다. 자동으로 이어 주지 않으니 그 AI에서 직접 등록한다.
    /// 주 키는 보이지도 복사되지도 않는다. 키는 피클과 같이 이 기기 키체인에만 둔다.
    @ViewBuilder
    private var keyConnectorSections: some View {
        Section {
            Text(keySteps).font(.taptionStyle(.footnote))
            if provider == .muse {
                // Muse에는 MCP 주소 복사 단계가 없다. 키 없는 안내 글을 채팅에 붙여 넣는다(MUS1120A03).
                Button(language.text("설정 안내 복사 (키 없음)", "Copy setup (no key)")) {
                    copy(TripRelay.museSetupText(host: host, language: language, scope: existing?.key.scope ?? .read, expiresAt: existing?.key.expiresAt))
                    isShowingPasteGuide = true
                }
            } else {
                LabeledContent(language.text("MCP 주소", "MCP URL"), value: TripRelay.mcpURL(host: host)).font(.taptionStyle(.footnote))
                Button(language.text("MCP 주소 복사", "Copy MCP URL")) {
                    copy(TripRelay.mcpURL(host: host))
                    message = language.text("MCP 주소를 복사했어요.", "MCP URL copied.")
                }
            }
            if let existing {
                // 주소·MCP·키를 한 번에: 1회용 주소 한 줄만 복사하고, AI가 열면 안내 전체가 나온다(SET1110A01).
                if provider != .muse {
                Button(language.text("연결 안내 한 번에 복사 (추천)", "Copy everything at once (recommended)")) {
                    Task {
                        let full = TripRelay.keyConnectorSetupText(for: provider, host: host, key: existing.token, scope: existing.key.scope, expiresAt: existing.key.expiresAt)
                            ?? TripRelay.assistantSetupText(host: host, key: existing.token, scope: existing.key.scope, expiresAt: existing.key.expiresAt)
                        copy(await TripRelay.setupLinkText(for: full) ?? full)
                        isShowingPasteGuide = true
                    }
                }
                }
                LabeledContent(language.text("연결 키", "Connection key"), value: AssistantCueText.masked(existing.token)).font(.footnote.monospaced())
                Button(language.text("연결 키 복사", "Copy connection key")) {
                    copy(existing.token)
                    message = language.text("연결 키를 복사했어요. 10분 뒤 클립보드에서 지워져요.", "Key copied. It is cleared from the clipboard in 10 minutes.")
                }
                if provider == .muse {
                    Text(language.text("키를 복사한 뒤, Muse가 보여주는 보안 입력 화면에 붙여 넣어주세요. 키를 채팅에 직접 적지 마세요.", "Copy the key, then paste it into the secure input screen Muse shows. Never type the key directly in the chat."))
                        .font(.taptionStyle(.footnote)).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(provider == .muse ? language.text("Muse에 연결", "Connect to Muse") : language.text("\(name)에서 직접 등록", "Register in \(name)"))
        } footer: {
            Text(language.text(
                "앱이 \(name)에 자동으로 연결해 주지는 않아요. 연결 키는 이 연결에만 쓰는 키이고, 앱의 주 키는 보내지 않아요. 아래 「연결 키 관리」에서 언제든 끊을 수 있어요.",
                "The app doesn't connect to \(name) for you. The key is only for this connection; the app's own key is never sent. You can cut it anytime under connection keys."
            ))
        }
    }

    /// 연결 키를 만드는 단계(1단계) 안에서 권한·기간을 고른다. 다시 등록하면(단계를 처음부터) 그게 새 키 발급이다(KEY1120A01).
    @ViewBuilder
    private var keyOptionRows: some View {
        Toggle(language.text("기록 수정 허용", "Allow record edits"), isOn: Binding(get: { connectorAllowsEdits }, set: { editsChoice = $0 }))
        Picker(language.text("사용 기간", "Valid for"), selection: $connectorPeriod) {
            ForEach(AssistantKeyPeriod.allCases) { Text($0.title(language)).tag($0) }
        }
        if connectorPeriod == .never {
            Text(language.text("키가 새면 직접 끊어야 해요.", "If the key leaks, you have to cut it yourself.")).font(.taptionStyle(.footnote)).foregroundStyle(.orange)
        }
        Text(connectorAllowsEdits
             ? language.text("\(name)가 기록을 읽고 메모·일정·기록 수정을 보낼 수 있어요. 보낸 것은 앱에서 되돌릴 수 있어요.", "\(name) can read records and send memo, schedule and record edits. You can undo them in the app.")
             : language.text("\(name)는 기록을 읽기만 해요.", "\(name) can only read records."))
            .font(.taptionStyle(.footnote)).foregroundStyle(.secondary)
    }

    private var cueSteps: String {
        language.text(
            "1. 위 「단계별 연결」의 키 만들기 단계에서 권한·기간을 고르고 연결 키를 만들어요.\n2. Cue에서 MCP 서버(커넥터)를 추가하는 화면을 열어요.\n3. 서버 주소에 MCP 주소를 붙여 넣어요.\n4. 인증 칸(요청 헤더)에 Authorization: Bearer 뒤에 연결 키를 붙여 넣어요. 칸 이름은 Cue 화면을 따라 주세요.\n5. 저장한 뒤 Cue에서 「오늘 기록 읽어 줘」처럼 물어 확인해요.",
            "1. In the Step by step card above, pick access and period in the make-key step and make the key.\n2. In Cue, open the screen for adding an MCP server (connector).\n3. Paste the MCP URL as the server address.\n4. In the auth field (request header), enter Authorization: Bearer followed by the connection key. Field names follow Cue's screen.\n5. Save, then ask Cue something like \"read today's records\" to check."
        )
    }

    // MARK: 연결 키

    private var keySection: some View {
        Section {
            Text(keySteps).font(.taptionStyle(.footnote))
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
                "Gemini CLI: 위 「단계별 연결」에서 키를 만들면 settings.json에 넣을 설정이 복사돼요. ~/.gemini/settings.json에 붙여 넣고 gemini를 다시 시작하세요.",
                "Gemini CLI: making the key in the Step by step card above copies a block for settings.json. Paste it into ~/.gemini/settings.json and restart gemini."
            )
        case .pickle:
            language.text("위 「단계별 연결」에서 키를 만들면 연결 안내가 복사돼요. 피클 채팅창에 붙여 넣어 주세요.", "Making the key in the Step by step card above copies the setup. Paste it into the Pickle chat.")
        case .cue:
            cueSteps
        // Muse에는 「MCP 서버 추가」 설정 화면이 없다. 안내를 채팅에 붙여 넣고 맞춤 커넥터를 만들어 달라고 한 뒤, 키는 Muse의 보안 입력창에 넣는다(MUS1120A01).
        case .muse:
            language.text(
                "1. 위 「단계별 연결」의 키 만들기 단계에서 권한·기간을 고르고 연결 키를 만들어요.\n2. 설정 안내를 복사해요. 키는 들어 있지 않아요.\n3. Muse 채팅에 붙여 넣고 보내서 커스텀 커넥터를 만들어 달라고 해요.\n4. 키를 복사한 뒤, Muse가 보여주는 보안 입력 화면에 붙여 넣어요. 키를 채팅에 직접 적지 마세요.\n5. Muse가 연결을 시험한 뒤 연결됐다고 알려 주면 끝나요. 한국 App Store에는 아직 Muse 앱이 없어서 앱이 없으면 웹으로 이용해요.",
                "1. In the make-key step of the Step by step card above, pick access and period and make the key.\n2. Copy the setup. It doesn't contain the key.\n3. Paste it into the Muse chat and send it to ask for a custom connector.\n4. Copy the key, then paste it into the secure input screen Muse shows. Never type the key directly in the chat.\n5. You're done when Muse tests the connection and tells you it's connected. Muse isn't on the Korean App Store yet, so use the web version if you don't have the app."
            )
        default:
            language.text("위 「단계별 연결」에서 키를 만들면 연결 안내가 복사돼요. 웹 요청을 할 수 있는 AI에 붙여 넣어 주세요.", "Making the key in the Step by step card above copies the setup. Paste it into any AI that can make web requests.")
        }
    }

    // MARK: OAuth

    @ViewBuilder
    private var oauthSections: some View {
        if provider == .claude { claudeAddSection }
        if provider == .claude { keyURLSection }
        if provider == .chatGPT { gptActionsSection }
        Section {
            Text(oauthSteps).font(.taptionStyle(.footnote))
            LabeledContent(language.text("서버 주소", "Server URL"), value: TripRelay.mcpURL(host: host)).font(.taptionStyle(.footnote))
            Button(language.text("서버 주소 복사", "Copy server URL")) { copy(TripRelay.mcpURL(host: host)) }
            Button(language.text("연결 코드 받기", "Get a connection code")) { requestCode() }
            if let code { codeView(code) }
        } header: {
            Text(provider == .chatGPT
                 ? language.text("커넥터로 연결 (Business·Enterprise·Edu, Pro는 읽기만)", "Connector (Business, Enterprise, Edu; Pro read-only)")
                 : language.text("커넥터로 연결", "Connect as a connector"))
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
    }

    /// ChatGPT Plus에서 되는 길: 맞춤 GPT의 Actions에 스키마 주소와 연결 키(Bearer)를 넣는다(GPT1111A01).
    /// MCP 커넥터는 OpenAI 도움말 기준 Business·Enterprise·Edu가 대상이고 Pro는 읽기만 된다.
    private var gptActionsSection: some View {
        Section {
            Text(language.text(
                "1. 위 「단계별 연결」의 키 만들기 단계에서 권한·기간을 고르고 연결 키를 만들어요.\n2. ChatGPT → GPT 만들기 → 구성 → 작업(Actions) → 새 작업 만들기 → 가져오기(URL)에 스키마 주소를 붙여 넣어요.\n3. 인증 → API 키 → 인증 유형 Bearer를 고르고 연결 키를 붙여 넣어요.\n4. 미리보기에서 「오늘 기록 읽어 줘」로 확인한 뒤 저장해요.",
                "1. In the Step by step card above, pick access and period in the make-key step and make the key.\n2. In ChatGPT, open Create a GPT → Configure → Actions → Create new action → Import from URL and paste the schema URL.\n3. Under Authentication choose API key, auth type Bearer, and paste the key.\n4. Check in the preview with \"read today's records\", then save."
            )).font(.taptionStyle(.footnote))
            LabeledContent(language.text("스키마 주소", "Schema URL"), value: TripRelay.openAPIURL(host: host)).font(.taptionStyle(.footnote))
            Button(language.text("스키마 주소 복사", "Copy schema URL")) {
                copy(TripRelay.openAPIURL(host: host))
                message = language.text("스키마 주소를 복사했어요.", "Schema URL copied.")
            }
            if let existing {
                LabeledContent(language.text("연결 키", "Connection key"), value: AssistantCueText.masked(existing.token)).font(.footnote.monospaced())
                Button(language.text("연결 키 복사", "Copy connection key")) {
                    copy(existing.token)
                    message = language.text("연결 키를 복사했어요. 10분 뒤 클립보드에서 지워져요.", "Key copied. It is cleared from the clipboard in 10 minutes.")
                }
                if provider == .muse {
                    Text(language.text("키를 복사한 뒤, Muse가 보여주는 보안 입력 화면에 붙여 넣어주세요. 키를 채팅에 직접 적지 마세요.", "Copy the key, then paste it into the secure input screen Muse shows. Never type the key directly in the chat."))
                        .font(.taptionStyle(.footnote)).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(language.text("맞춤 GPT로 연결 (Plus 이상, 추천)", "Custom GPT (Plus or higher, recommended)"))
        } footer: {
            Text(language.text(
                "맞춤 GPT는 그 GPT 안에서만 BOKKI를 읽고 보내요. 키는 이 연결에만 쓰고, 「연결 키 관리」에서 언제든 끊을 수 있어요.",
                "The custom GPT reads and sends only inside that GPT. The key is only for this connection; cut it anytime under connection keys."
            ))
        }
    }

    /// 키 없는 추가 창 + 승인(CLD1111A01, 대표 결정). 앱 비밀번호 → 연결 코드·PIN → 코드 복사 → Claude 추가 창.
    private var claudeAddSection: some View {
        Section {
            Text(language.text(
                "1. 「Claude에서 바로 추가」를 누르고 앱 비밀번호를 넣어요.\n2. 연결 코드가 복사되고 승인 PIN이 보여요.\n3. Claude가 열리면 「Add」를 누르고, 승인 화면에 코드를 붙여 넣고 PIN을 넣어요.",
                "1. Tap Add in Claude now and enter your app password.\n2. A connection code is copied and the approval PIN is shown.\n3. In Claude tap Add, then paste the code and enter the PIN on the approval page."
            )).font(.taptionStyle(.footnote))
            Button(language.text("Claude에서 바로 추가 (추천)", "Add in Claude now (recommended)")) {
                opensClaudeAdd = true
                requestCode()
            }
        } header: {
            Text(language.text("바로 추가 (키가 남지 않음)", "Quick add (no key left anywhere)"))
        } footer: {
            Text(language.text("링크와 Claude 설정에는 서버 주소만 남고, 승인은 8시간마다 바뀌는 토큰으로 이어져요.", "Only the server URL is in the link and in Claude; access runs on a token that rotates every 8 hours."))
        }
    }

    /// 모바일에서 가장 쉬운 길: 연결 키가 든 주소 하나를 붙여 넣고 「로그인 없음」을 고른다(CLD1110A01).
    private var keyURLSection: some View {
        Section {
            Text(language.text(
                "연결 주소를 만들면 복사돼요. Claude → 설정 → 커넥터 → 맞춤 커넥터 추가에 주소를 붙여 넣고, 인증은 「로그인 없음」을 고르면 끝나요.",
                "Make a link and it's copied. In Claude, open Settings → Connectors → Add custom connector, paste the link and choose No sign-in."
            )).font(.taptionStyle(.footnote))
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
            // 코드와 PIN을 각자 줄에 둔다. 길게 눌러 고르면 두 줄이 함께 잡혀 복사 버튼만 쓴다(CLD1111A01).
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(language.text("연결 코드", "Connection code")).font(.taptionStyle(.footnote)).foregroundStyle(.secondary)
                    Spacer()
                    Text(code.code).font(.title2.monospaced().weight(.bold))
                }
                if let approvalPIN, left > 0 {
                    HStack(alignment: .firstTextBaseline) {
                        Text(language.text("승인 화면 PIN", "Approval page PIN")).font(.taptionStyle(.footnote)).foregroundStyle(.secondary)
                        Spacer()
                        Text(approvalPIN).font(.title2.monospaced().weight(.bold))
                    }
                }
                Text(left > 0
                     ? language.text("\(left / 60)분 \(left % 60)초 남음 · 한 번만 쓸 수 있어요", "\(left / 60)m \(left % 60)s left · single use")
                     : language.text("코드가 끝났어요. 새로 받아 주세요.", "The code expired. Get a new one."))
                    .font(.taptionStyle(.caption)).foregroundStyle(left > 0 ? Color.secondary : Color.red)
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
        // 다시 만들면 예전 키는 끊는다. 앱은 AI마다 마지막 키만 기억해 남은 키를 화면에서 다룰 수 없다(REV1117A02).
        let old = existing?.key
        let made = choosesKeyOptions
            ? await store.create(for: provider, pin: pin, language: language, scope: connectorAllowsEdits ? .write : .read, period: connectorPeriod)
            : await store.create(for: provider, pin: pin, language: language)
        switch made {
        case let .failure(text): return text
        case let .key(key, token):
            existing = (key, token)
            advanceGuide(from: "key")
            if let old, old.id != key.id {
                _ = await TripRelay.revokeScopedKey(old.id)
                await store.reload()
            }
            if provider == .muse {
                // 키만 만든다. 키 없는 설정 안내는 2단계에서 따로 복사하고, 키는 4단계에서 Muse 보안 입력에 따로 넣는다(MUS1120A04).
                message = language.text("연결 키를 만들었어요. 다음 단계에서 설정 안내를 복사해요.", "Key made. Copy the setup in the next step.")
                return nil
            }
            if let full = TripRelay.keyConnectorSetupText(for: provider, host: host, key: token, scope: key.scope, expiresAt: key.expiresAt) {
                // 주소와 키는 화면에서 따로 복사한다.
                copy(await TripRelay.setupLinkText(for: full) ?? full)
                message = language.text("연결 안내를 복사했어요. \(name) 채팅창에 붙여 넣어 주세요. MCP 주소와 키를 따로 넣어도 돼요.", "Setup copied. Paste it into the \(name) chat, or enter the MCP URL and key separately.")
                pendingPasteGuide = true
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
        case .chatGPT: copy(token)
        default:
            let full = TripRelay.assistantSetupText(host: host, key: token, scope: key.scope, expiresAt: key.expiresAt)
            copy(await TripRelay.setupLinkText(for: full) ?? full)
        }
        message = language.text("연결 안내를 복사했어요. 10분 뒤 클립보드에서 지워져요.", "Setup copied. It is cleared from the clipboard in 10 minutes.")
    }

    private func copy(_ text: String) { AssistantClipboard.copy(text) }

    /// 단계 버튼(GDE1111A01). 복사·열기는 바로 다음 단계로, 키·코드는 만든 뒤에 넘어간다.
    private func performGuide(_ action: AssistantGuideStep.Action) {
        let memory = AssistantGuideMemory.shared
        switch action {
        case .makeKey:
            if provider == .chatGPT { makesKeyURL = true }
            isAskingPIN = true
        case .getCode:
            requestCode()
        case let .copy(value):
            copy(value)
            message = language.text("복사했어요. 붙여 넣은 뒤 돌아오세요.", "Copied. Paste it, then come back.")
            memory.go(to: memory.step(for: provider) + 1)
        case let .open(url):
            memory.go(to: memory.step(for: provider) + 1)
            openURL(url)
        case .check:
            Task { @MainActor in
                let wasConnected = store.isConnected(provider)
                await store.reload()
                existing = store.token(for: provider)
                message = store.isConnected(provider)
                    ? language.text("연결됐어요.", "Connected.")
                    : language.text("아직 연결되지 않았어요. 앞 단계를 다시 확인해 주세요.", "Not connected yet. Check the previous steps.")
                // 방금 연결됐으면 그 AI에서 BOKKI Plan과 이어진 첫 대화를 연다(AIW1114A01).
                if !wasConnected, store.isConnected(provider) { openChat() }
            }
        }
    }

    /// 그 단계를 보고 있을 때만 다음으로 넘긴다.
    private func advanceGuide(from id: String) {
        let memory = AssistantGuideMemory.shared
        let steps = AssistantGuidePlan.steps(provider, host: host, token: existing?.token, code: code?.code, pin: approvalPIN, language: language, scope: existing?.key.scope ?? .read, expiresAt: existing?.key.expiresAt)
        let index = memory.step(for: provider)
        if steps.indices.contains(index), steps[index].id == id { memory.go(to: index + 1) }
    }

    private func showPendingPasteGuide() {
        makesKeyURL = false
        if opensClaudeAdd {
            opensClaudeAdd = false
            if code != nil { isShowingClaudeAdd = true }
            return
        }
        guard pendingPasteGuide else { return }
        pendingPasteGuide = false
        isShowingPasteGuide = true
    }

    private func openApp() {
        installed = provider.isInstalled
        if store.isConnected(provider) { openChat() } else if let url = provider.destination(installed: installed) { openURL(url) }
    }

    /// 첫 인사 글을 복사하고 그 AI의 새 대화를 연다. 글을 주소로 받는 AI는 채워진 채 열린다.
    private func openChat() {
        installed = provider.isInstalled
        copy(AITaskRequest.welcome)
        if let url = AITaskRequest.chatURL(provider, prompt: AITaskRequest.welcome) ?? provider.destination(installed: installed) { openURL(url) }
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
            Button(language.text("기타 AI (웹 요청)", "Other AI (web requests)")) { onConnect(.other) }
                .font(.taptionStyle(.subheadline, weight: .regular))
        } header: {
            Text(language.text("AI 고르기", "Choose an AI")).font(.taptionStyle(.footnote, weight: .medium))
        } footer: {
            Text(AssistantAIProvider.planFootnote(language)).font(.taptionStyle(.caption))
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
        case .chatGPT:
            return language.text(
                "연결 키를 복사했어요. GPT 구성 → 작업 → 인증에서 API 키·Bearer를 고르고 붙여 넣어 주세요. 스키마 주소는 이 화면에서 따로 복사해요. 클립보드는 10분 뒤 지워져요.",
                "Key copied. In the GPT's Configure → Actions → Authentication, choose API key and Bearer, then paste it. Copy the schema URL from this screen. The clipboard is cleared in 10 minutes."
            )
        case .muse:
            return language.text(
                "Muse 채팅에 붙여 넣고 보내 주세요. 키는 채팅에 쓰지 말고, Muse가 보여주는 보안 입력 화면에 넣어 주세요(키는 이 화면에서 복사해요). 클립보드는 10분 뒤 지워져요.",
                "Paste it into the Muse chat and send. Don't type the key in the chat; enter it when Muse shows its secure input (copy the key on this screen). The clipboard is cleared in 10 minutes."
            )
        case .cue:
            place = language.text("Cue 채팅창에 붙여 넣고 보내 주세요. Cue가 주소를 열어 MCP 주소와 키를 받아 가요. 안 되면 아래에서 MCP 주소와 키를 따로 넣어 주세요.", "Paste it into the Cue chat and send. Cue opens the link to get the MCP URL and key. If that fails, enter them separately below.")
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
