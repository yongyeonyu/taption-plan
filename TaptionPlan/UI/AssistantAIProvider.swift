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
    case pickle, chatGPT, claude, gemini, other

    var id: String { rawValue }

    /// 튜토리얼과 「AI 연결」 맨 위에 함께 보이는 넷(AIR1110A04).
    static let featured: [Self] = [.pickle, .chatGPT, .claude, .gemini]

    func title(_ language: MapHomeLanguage) -> String {
        switch self {
        case .pickle: language.text("피클", "Pickle")
        case .chatGPT: "ChatGPT"
        case .claude: "Claude"
        case .gemini: "Gemini"
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
        case .other: nil
        }
    }

    var appURL: URL? { scheme.flatMap { URL(string: "\($0)://") } }

    /// 설치돼 있으면 앱, 없으면 App Store.
    func destination(installed: Bool) -> URL? { installed ? appURL : appStoreURL }

    @MainActor
    var isInstalled: Bool { appURL.map { UIApplication.shared.canOpenURL($0) } ?? false }

    /// claude.ai·ChatGPT는 OAuth 커넥터로 잇는다. 나머지는 연결 키(REST·헤더)를 쓴다.
    var usesOAuth: Bool { self == .chatGPT || self == .claude }

    /// 요금제 조건(AIR1110A04, 2026-11-10 공개 문서 기준). 튜토리얼과 메뉴가 같은 값을 쓴다.
    func planBadge(_ language: MapHomeLanguage) -> String? {
        switch self {
        case .pickle: language.text("무료", "Free")
        case .claude: language.text("무료 가능 · 무료는 커넥터 1개", "Free OK · 1 connector on Free")
        case .chatGPT: language.text("유료 (Plus 이상)", "Paid (Plus or higher)")
        case .gemini: language.text("유료 · API 키 필요", "Paid · API key needed")
        case .other: nil
        }
    }

    var isFreePlan: Bool { self == .pickle || self == .claude }

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
        case .other: return false
        }
    }
}

/// 연결 키가 어느 AI 것인지 기기에만 둔다(이름·기간과 같은 자리).
enum AssistantKeyProviders {
    static let defaultsKey = "assistantKeyProviders"

    static func provider(_ id: String, defaults: UserDefaults = .standard) -> AssistantAIProvider? {
        ((defaults.dictionary(forKey: defaultsKey) as? [String: String])?[id]).flatMap(AssistantAIProvider.init(rawValue:))
    }

    static func save(_ id: String, provider: AssistantAIProvider, defaults: UserDefaults = .standard) {
        var values = defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        values[id] = provider.rawValue
        defaults.set(values, forKey: defaultsKey)
    }

    static func remove(_ id: String, defaults: UserDefaults = .standard) {
        var values = defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        values[id] = nil
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
        if let text = object["expiresAt"] as? String, let date = TripRelay.isoDate(text) {
            expiresAt = min(date, latest)
        } else if let seconds = object["expiresIn"] as? Int {
            expiresAt = min(now.addingTimeInterval(TimeInterval(seconds)), latest)
        }
        return Self(code: code, expiresAt: expiresAt)
    }
}

extension TripRelay {
    static func mcpURL(host: String) -> String { "https://\(host)/mcp" }
    /// Claude 「로그인 없음」 커넥터 주소. 연결 키가 주소에 들어간다(CLD1110A01). 주 키는 넣지 않는다(서버도 거절).
    static func mcpKeyURL(host: String, key: String) -> String { "https://\(host)/mcp/\(key)" }

    /// 연결 안내를 서버에 맡기고 1회용 주소가 든 짧은 글을 돌려준다(SET1110A01). 클립보드·대화에는 키가 남지 않는다.
    /// 서버에 닿지 못하면 nil이고, 부르는 쪽은 전체 안내를 복사한다.
    @MainActor
    static func setupLinkText(for text: String, env: AssistantRegistration.Environment = .live) async -> String? {
        guard let master = env.secrets.read(.master),
              let body = try? JSONSerialization.data(withJSONObject: ["text": text]),
              let reply = await send(relayRequest("/setup", method: "POST", body: body, token: master, host: env.host), session: env.session),
              reply.status == 201,
              let object = (try? JSONSerialization.jsonObject(with: reply.data)) as? [String: Any],
              let url = object["url"] as? String, let host = env.host, url.hasPrefix("https://\(host)/s/") else { return nil }
        return setupLinkMessage(url)
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
        let request = relayRequest("/oauth/code", method: "POST", body: Data("{}".utf8), token: master, host: env.host)
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
