import Foundation
import UIKit
import UniformTypeIdentifiers

/// 키가 든 글은 이 기기에만 10분 동안 복사한다(SEC1110A02). 다른 기기로 넘어가는 클립보드에 올리지 않는다.
enum AssistantClipboard {
    static let lifetime: TimeInterval = 600

    static func options(now: Date = .now) -> [UIPasteboard.OptionsKey: Any] {
        [.localOnly: true, .expirationDate: now.addingTimeInterval(lifetime)]
    }

    static func items(_ text: String) -> [[String: Any]] { [[UTType.plainText.identifier: text]] }

    @MainActor
    static func copy(_ text: String, to pasteboard: UIPasteboard = .general, now: Date = .now) {
        pasteboard.setItems(items(text), options: options(now: now))
    }
}

/// 「AI 연결」에 보이는 AI(AIR1110A03). 연결 방식·앱 스킴·App Store 번호·요금제 표시를 한곳에 둔다.
enum AssistantAIProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case pickle, chatGPT, claude, gemini, cue, muse, other

    var id: String { rawValue }

    /// 튜토리얼과 「AI 연결」 맨 위에 함께 보이는 AI(AIR1110A04, Cue는 AIC1111A01, Muse는 MUS1120A01).
    static let featured: [Self] = [.pickle, .chatGPT, .claude, .gemini, .cue, .muse]

    func title(_ language: MapHomeLanguage) -> String {
        switch self {
        case .pickle: language.text("피클", "Pickle")
        case .chatGPT: "ChatGPT"
        case .claude: "Claude"
        case .gemini: "Gemini"
        case .cue: "Cue"
        case .muse: "Muse"
        case .other: language.text("기타", "Other")
        }
    }

    /// 2026-11-10 확인한 앱 번호(iTunes 조회).
    var appStoreID: String? {
        switch self {
        case .pickle: "6795790129"
        case .chatGPT: "6448311069"
        case .claude: "6473753684"
        case .gemini: "6477489729"
        // Cue by Manus(대표 확인 2026-11-11, iTunes 조회 ai.manus.agents). 앱 스킴은 확인하지 못해 없다.
        case .cue: "6808613358"
        // Muse from Meta: 미국 스토어(6760173601)에만 있고 한국 스토어 조회(itunes.apple.com/kr/lookup)는 2026-11-20 resultCount 0이다.
        // 미국 ID를 넣으면 한국 사용자에게 「받기」가 잘못 뜨므로 nil로 둔다. 한국 조회가 1이 되면 그때 넣는다(MUS1120A01).
        case .muse: nil
        case .other: nil
        }
    }

    var appStoreURL: URL? { appStoreID.flatMap { URL(string: "https://apps.apple.com/app/id\($0)") } }

    /// 설치 확인용 스킴. 넷 모두 확인하지 않은 값이라 못 열면 App Store로 간다(SEC1110A02).
    /// Info.plist `LSApplicationQueriesSchemes`에도 같은 값이 있다.
    var scheme: String? {
        switch self {
        case .pickle: "pickle"
        case .chatGPT: "chatgpt"
        case .claude: "claude"
        case .gemini: "googlegemini"
        // Cue(Manus) 스킴은 공개 문서에서 확인하지 못해 두지 않는다. 연결돼 있으면 「열기」로 App Store 화면을 연다(CUE1111A01).
        // Muse 스킴도 공개 문서에서 확인하지 못했다(MUS1120A01). `LSApplicationQueriesSchemes`에 넣지 않는다.
        case .cue, .muse, .other: nil
        }
    }

    var appURL: URL? { scheme.flatMap { URL(string: "\($0)://") } }

    /// 설치돼 있으면 앱, 없으면 App Store.
    func destination(installed: Bool) -> URL? { installed ? appURL : appStoreURL }

    /// 「받기」 자리 단추(CUE1111A01). 설치가 확인되거나 이미 연결된 AI는 「열기」다.
    /// 앱 스킴으로 열 수 없으면 App Store 화면으로 간다(설치된 앱이면 거기서 「열기」).
    func openButton(installed: Bool, connected: Bool) -> (isOpen: Bool, url: URL?) {
        guard installed || connected else { return (false, appStoreURL) }
        return (true, installed ? (appURL ?? appStoreURL) : appStoreURL)
    }

    @MainActor
    var isInstalled: Bool { appURL.map { UIApplication.shared.canOpenURL($0) } ?? false }

    /// claude.ai·ChatGPT는 OAuth 커넥터로 잇는다. 나머지는 연결 키(REST·헤더)를 쓴다.
    var usesOAuth: Bool { self == .chatGPT || self == .claude }

    /// 요금제 조건(AIR1110A04, 2026-11-10 공개 문서 기준). 튜토리얼과 메뉴가 같은 값을 쓴다.
    func planBadge(_ language: MapHomeLanguage) -> String? {
        switch self {
        case .pickle: language.text("무료", "Free")
        case .claude: language.text("무료 가능 · 무료는 커넥터 1개", "Free OK · 1 connector on Free")
        // GPT1111A01: 맞춤 GPT(Actions)는 Plus 이상, MCP 커넥터는 Business·Enterprise·Edu(OpenAI 도움말 2026-11-11).
        case .chatGPT: language.text("유료 · 맞춤 GPT는 Plus 이상", "Paid · Custom GPT on Plus+")
        case .gemini: language.text("유료 · API 키 필요", "Paid · API key needed")
        // 대표 확인(2026-11-11): Cue는 무료로 연결된다.
        case .cue: language.text("무료", "Free")
        // Muse: 무료(앱 내 구입 있음, App Store 2026-11-20).
        case .muse: language.text("무료", "Free")
        case .other: nil
        }
    }

    /// 연결 키를 만들어 그 AI 화면에서 MCP 주소·키를 직접 등록하는 방식(Cue CUE1110A01, Muse MUS1120A01).
    var usesKeyConnector: Bool { self == .cue || self == .muse }

    var isFreePlan: Bool { self == .pickle || self == .claude || self == .cue || self == .muse }

    static func planFootnote(_ language: MapHomeLanguage) -> String {
        language.text("요금제 조건은 각 서비스 사정에 따라 바뀔 수 있어요.", "Plan requirements may change at each service's discretion.")
    }

    /// OAuth 연결의 앱 이름으로 어느 AI인지 맞춘다.
    func matchesClient(_ name: String) -> Bool {
        let lower = name.lowercased()
        switch self {
        case .chatGPT: return lower.contains("chatgpt") || lower.contains("openai")
        case .claude: return lower.contains("claude") || lower.contains("anthropic")
        case .gemini: return lower.contains("gemini")
        case .pickle: return lower.contains("pickle")
        case .cue: return lower == "cue" || lower.hasPrefix("cue ")
        case .muse: return lower.contains("muse")
        case .other: return false
        }
    }
}

extension AssistantKeyProviders {
    static func provider(_ id: String, defaults: UserDefaults = .standard) -> AssistantAIProvider? {
        ((defaults.dictionary(forKey: defaultsKey) as? [String: String])?[id]).flatMap(AssistantAIProvider.init(rawValue:))
    }

    static func save(_ id: String, provider: AssistantAIProvider, defaults: UserDefaults = .standard) {
        var values = defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        values[id] = provider.rawValue
        defaults.set(values, forKey: defaultsKey)
    }

    /// 쓸 수 있는(끝나지 않은) 그 AI의 연결 키.
    static func activeKey(for provider: AssistantAIProvider, in keys: [AssistantScopedKey], now: Date = .now, defaults: UserDefaults = .standard) -> AssistantScopedKey? {
        keys.first { key in
            key.isActive(now: now) && (self.provider(key.id, defaults: defaults) == provider
                || key.source == "oauth" && key.client.map(provider.matchesClient) == true)
        }
    }
}

/// OAuth 승인 화면에 넣는 1회용 「연결 코드」(8글자, 10분).
struct AssistantOAuthCode: Equatable, Sendable {
    static let lifetime: TimeInterval = 600

    var code: String
    var expiresAt: Date

    func remaining(now: Date = .now) -> TimeInterval { max(0, expiresAt.timeIntervalSince(now)) }

    static func parse(_ data: Data, now: Date = .now) -> Self? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let code = (object["code"] as? String)?.trimmingCharacters(in: .whitespaces), (4...16).contains(code.count) else { return nil }
        let latest = now.addingTimeInterval(lifetime)
        var expiresAt = latest
        // REV1117A02: 남은 초를 먼저 본다. 서버 시각(expiresAt)을 기기 시계와 견주면 시계가 틀린 기기에서 남은 시간이 틀린다.
        if let seconds = object["expiresIn"] as? Int {
            expiresAt = min(now.addingTimeInterval(TimeInterval(max(0, seconds))), latest)
        } else if let text = object["expiresAt"] as? String, let date = TripRelay.isoDate(text) {
            expiresAt = min(date, latest)
        }
        return Self(code: code, expiresAt: expiresAt)
    }
}

extension TripRelay {
    static func mcpURL(host: String) -> String { "https://\(host)/mcp" }
    static func openAPIURL(host: String) -> String { "https://\(host)/openapi.json" }

    /// claude.ai 「맞춤 커넥터 추가」 창을 이름·주소를 채워 연다(CLD1111A01, Claude 앱이 알려 준 형식, 확인 못 함).
    /// 주소에는 키를 넣지 않는다(대표 결정): Add 뒤 승인 화면에서 연결 코드와 PIN으로 OAuth 승인한다.
    static func claudeAddConnectorURL(host: String) -> URL? {
        var components = URLComponents(string: "https://claude.ai/customize/connectors")
        components?.queryItems = [
            URLQueryItem(name: "modal", value: "add-custom-connector"),
            URLQueryItem(name: "connectorName", value: "BOKKI Plan"),
            URLQueryItem(name: "connectorUrl", value: mcpURL(host: host)),
        ]
        return components?.url
    }
    /// Claude 「로그인 없음」 커넥터 주소. 연결 키가 주소에 들어간다(CLD1110A01). 주 키는 넣지 않는다(서버도 거절).
    static func mcpKeyURL(host: String, key: String) -> String { "https://\(host)/mcp/\(key)" }

    /// 연결 안내를 서버에 맡기고 1회용 주소가 든 짧은 글을 돌려준다(SET1110A01). 클립보드·대화에는 키가 남지 않는다.
    /// 서버에 닿지 못하면 nil이고, 부르는 쪽은 전체 안내를 복사한다.
    @MainActor
    static func setupLinkText(for text: String, env: AssistantRegistration.Environment = .live) async -> String? {
        guard let master = env.secrets.read(.master),
              let body = try? JSONSerialization.data(withJSONObject: ["text": text]),
              let reply = await send(relayRequest("/setup", method: "POST", body: body, token: master, host: env.host, client: env.client()), session: env.session),
              reply.status == 201,
              let object = (try? JSONSerialization.jsonObject(with: reply.data)) as? [String: Any],
              let url = object["url"] as? String, let host = env.host, url.hasPrefix("https://\(host)/s/") else { return nil }
        return setupLinkMessage(url)
    }

    /// Cue용 안내: MCP 연결 방법을 먼저 적고, MCP를 쓸 수 없으면 REST로 쓰는 법을 이어 붙인다(CUE1110A01).
    static func cueSetupText(host: String, key: String, scope: AssistantKeyScope, expiresAt: Date?) -> String {
        """
        BOKKI Plan connection for Cue.
        Preferred: add a remote MCP server (connector) with URL \(mcpURL(host: host)) and the request header Authorization: Bearer \(key). If your connector only takes a URL, use \(mcpKeyURL(host: host, key: key)) with no sign-in.
        If you can't add MCP servers, use the web API below with the same key.

        """ + assistantSetupText(host: host, key: key, scope: scope, expiresAt: expiresAt)
    }

    /// Muse 채팅에 붙여 넣을 안내(MUS1120A03·MUS1120A04). Muse에는 「MCP 서버 추가」 화면이 없어 채팅으로 맞춤 커넥터를 만들어 달라고 한다.
    /// 연결 키 값과 키가 든 주소는 한 글자도 넣지 않는다(키 자리는 `<connection key>`). 키는 Muse가 띄우는 보안 입력으로만 따로 준다.
    /// 뒤에 API 안내(읽기·쓰기·AI 작업)를 붙이고, 권한·기간은 만든 키의 것을 쓴다. 공식 설정 화면이 있다고 단정하지 않는다.
    static func museSetupText(host: String, language: MapHomeLanguage, scope: AssistantKeyScope = .read, expiresAt: Date? = nil) -> String {
        // AI에게 보내는 글이라 번역 표에 넣지 않는다. 한국어 사용자는 한국어 머리말, API 안내는 영어 그대로.
        let mcp = mcpURL(host: host)
        let intro: String
        if language == .korean {
            intro = "뽀끼 플랜 연결을 위해 커스텀 커넥터를 만들어 줘.\n- MCP 주소: \(mcp) (Streamable HTTP)\n- 인증: Authorization: Bearer 연결 키\n- 연결 키는 이 채팅에 적지 말고, 키를 받을 보안 입력 화면을 보여 줘. 내가 거기에 따로 넣을게. 답변에도 키를 되풀이하지 마.\n- 연결한 뒤 도구 목록을 확인하고 오늘 기록을 읽어 보며 시험해서 결과를 알려 줘.\n\n아래는 연결한 뒤 쓸 API 안내야. 안내 속 \(museKeyPlaceholder) 자리에는 보안 입력으로 받은 연결 키를 써 줘."
        } else {
            intro = "Please create a custom connector for BOKKI Plan.\n- MCP URL: \(mcp) (Streamable HTTP)\n- Auth: Authorization: Bearer with a connection key\n- Don't ask me to type the key in this chat; show me a secure input screen to receive it and I will enter it there. Never repeat the key in your replies.\n- After connecting, list the tools, test by reading today's records, and tell me the result.\n\nBelow is the API guide to use after connecting. Wherever it says \(museKeyPlaceholder), use the connection key you received through the secure input."
        }
        return intro + "\n\n" + assistantSetupText(host: host, key: museKeyPlaceholder, scope: scope, expiresAt: expiresAt)
    }

    /// Muse 안내 글 속 키 자리 표시자. 실제 키가 아니다.
    static let museKeyPlaceholder = "<connection key>"

    /// 연결 키 + MCP 직접 등록 방식(Cue)의 안내 글. Muse는 키 없는 `museSetupText`를 따로 쓴다. 다른 AI는 nil.
    static func keyConnectorSetupText(for provider: AssistantAIProvider, host: String, key: String, scope: AssistantKeyScope, expiresAt: Date?) -> String? {
        switch provider {
        case .cue: cueSetupText(host: host, key: key, scope: scope, expiresAt: expiresAt)
        default: nil
        }
    }

    static func setupLinkMessage(_ url: String) -> String {
        "Connect to my BOKKI Plan app: open \(url) and follow the instructions there. "
            + "The link works for 10 minutes and only a few reads, so read it now and keep what it says (it includes the key you will use)."
    }

    enum OAuthCodeReply: Equatable, Sendable {
        case code(AssistantOAuthCode)
        /// 409 `pin_not_set`: PIN부터 만들어야 한다.
        case pinNotSet
        case failed
    }

    /// `POST /oauth/code`(주 키). PIN은 승인 화면에서 서버가 확인하므로 여기서는 묻지 않는다(REV1110A06).
    @MainActor
    static func requestOAuthCode(env: AssistantRegistration.Environment = .live, now: Date = .now) async -> OAuthCodeReply {
        guard let master = env.secrets.read(.master) else { return .failed }
        let request = relayRequest("/oauth/code", method: "POST", body: Data("{}".utf8), token: master, host: env.host, client: env.client())
        guard let reply = await send(request, session: env.session) else { return .failed }
        if (200..<300).contains(reply.status) { return AssistantOAuthCode.parse(reply.data, now: now).map(OAuthCodeReply.code) ?? .failed }
        guard AssistantServerRefusal.parse(status: reply.status, data: reply.data)?.kind == .pinNotSet else { return .failed }
        AssistantPINStore.mark(isSet: false, defaults: env.defaults)
        return .pinNotSet
    }

    /// Claude Code는 OAuth로 잇는다. 명령에 키를 넣지 않는다.
    static func claudeCodeCommand(host: String) -> String {
        "claude mcp add --transport http bokki \(mcpURL(host: host))"
    }

    /// Gemini CLI `~/.gemini/settings.json`에 넣을 연결. 그 연결의 키만 넣는다.
    static func geminiSettings(host: String, key: String) -> String {
        """
        Add this to ~/.gemini/settings.json (merge into "mcpServers" if it exists):
        {
          "mcpServers": {
            "bokki": {
              "httpUrl": "\(mcpURL(host: host))",
              "headers": { "Authorization": "Bearer \(key)" }
            }
          }
        }
        """
    }
}
