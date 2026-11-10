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
    func create(for provider: AssistantAIProvider, pin: String, language: MapHomeLanguage) async -> Made {
        guard await AssistantRegistration.ensureReady() else { return .failure(AssistantKeyText.rotationFailed(language)) }
        switch await TripRelay.registerScopedKey(label: provider.title(language), scope: .write, period: .quarter, pin: pin, provider: provider) {
        case let .created(key, token):
            await reload()
            return .key(key, token: token)
        case let .refused(refusal):
            return .failure(refusal.text(language))
        case .failed:
            return .failure(language.text("연결을 만들지 못했어요.", "Couldn't create the connection."))
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
    @State private var message: String?
    @State private var isWorking = false
    @State private var installed = false
    /// 다시 복사할 수 있는 연결 키. 키체인은 나타날 때와 만든 뒤에만 읽는다.
    @State private var existing: (key: AssistantScopedKey, token: String)?

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
            if provider.usesOAuth { oauthSections } else { keySection }
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
        .sheet(isPresented: $isAskingPIN) {
            if provider.usesOAuth {
                // 연결 코드는 PIN이 있어야 나온다. 없을 때만 여기서 만든다.
                AssistantPINSheet(language: language, mode: .create, purpose: pinPurpose, isGate: true) { _ in await fetchCode() }
            } else {
                AssistantPINSheet.gate(language: language, purpose: pinPurpose) { pin in await afterPIN(pin) }
            }
        }
    }

    private var name: String { provider.title(language) }

    private var pinPurpose: String {
        provider.usesOAuth
            ? language.text("연결 코드를 받기 전에 PIN을 정해요. 승인 화면에서 같은 PIN을 넣어요.", "Set your PIN before getting a code. Enter the same PIN on the approval page.")
            : language.text("\(name) 연결 키를 만들어요.", "Creates a connection key for \(name).")
    }

    // MARK: 연결 키

    private var keySection: some View {
        Section {
            Text(keySteps).font(.footnote)
            Button(language.text("연결하기", "Connect")) { isAskingPIN = true }
            if let existing {
                Button(language.text("연결 안내 다시 복사", "Copy setup again")) { copySetup(existing.token, key: existing.key) }
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
                Text(left > 0
                     ? language.text("\(left / 60)분 \(left % 60)초 남음 · 한 번만 쓸 수 있어요", "\(left / 60)m \(left % 60)s left · single use")
                     : language.text("코드가 끝났어요. 새로 받아 주세요.", "The code expired. Get a new one."))
                    .font(.caption).foregroundStyle(left > 0 ? Color.secondary : Color.red)
                if left > 0 { Button(language.text("코드 복사", "Copy code")) { copy(code.code) }.buttonStyle(.borderless) }
            }
        }
    }

    // MARK: 동작

    /// PIN이 이미 있으면 묻지 않고 코드를 받는다. 서버가 PIN이 없다고 하면 만들기 화면을 띄운다(REV1110A06).
    private func requestCode() {
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            message = await fetchCode()
        }
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
        switch await store.create(for: provider, pin: pin, language: language) {
        case let .failure(text): return text
        case let .key(key, token):
            existing = (key, token)
            copySetup(token, key: key)
        }
        if provider == .pickle { openApp() }
        return nil
    }

    private func copySetup(_ token: String, key: AssistantScopedKey) {
        let text = provider == .gemini
            ? TripRelay.geminiSettings(host: host, key: token)
            : TripRelay.assistantSetupText(host: host, key: token, scope: key.scope, expiresAt: key.expiresAt)
        copy(text)
        message = language.text("연결 안내를 복사했어요. 10분 뒤 클립보드에서 지워져요.", "Setup copied. It is cleared from the clipboard in 10 minutes.")
    }

    private func copy(_ text: String) { AssistantClipboard.copy(text) }

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
            Button(language.text("기타 AI (웹 요청)", "Other AI (web requests)")) { onConnect(.other) }
        } header: {
            Text(language.text("AI 고르기", "Choose an AI"))
        } footer: {
            Text(AssistantAIProvider.planFootnote(language))
        }
    }
}
