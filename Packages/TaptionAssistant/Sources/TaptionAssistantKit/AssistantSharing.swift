import Foundation

/// AI 비서에게 하루 기록을 얼마나 보낼지(AIR1110A01·TRP1110A06). 기기에만 두는 설정이다.
public enum AssistantShareLevel: String, CaseIterable, Identifiable, Sendable {
    case off
    case summary
    case visits

    public static let defaultsKey = "assistantShareLevel"

    public var id: String { rawValue }

    public static func current(_ defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .summary
    }

    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    /// 덜 보내는 쪽으로 바꿨는가. 그러면 서버에 남은 더 자세한 날들을 지운다(REV1110A06).
    public static func isDowngrade(from old: Self, to new: Self) -> Bool { new.rank < old.rank }
}

/// 서버에 하루 기록을 남겨 둘 기간(TRP1110A07). 기본 7일.
public enum AssistantRetention: Int, CaseIterable, Identifiable, Sendable {
    case oneDay = 1
    case week = 7
    case month = 30

    public static let defaultsKey = "assistantRetentionDays"

    public var id: Int { rawValue }

    public static func current(_ defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.integer(forKey: defaultsKey)) ?? .week
    }
}

/// 요청 헤더에 싣는 이 기기의 상태. 패키지는 앱 설정·잠금을 모르므로 앱이 넣어 준다(PKG1114A19).
public struct AssistantClientState: Equatable, Sendable {
    public var level: AssistantShareLevel
    public var debug: Bool
    public var locked: Bool

    public init(level: AssistantShareLevel, debug: Bool, locked: Bool) {
        self.level = level
        self.debug = debug
        self.locked = locked
    }
}

/// 중계 서버의 다른 경로(하루 기록·명령)를 부르는 요청(AIR1110A01·TRP1110A07). 공유 수준·잠금 여부는 앱이 넣어 준다.
extension TripRelay {
    public static let clientHeaderName = "x-bokki-client"

    /// `<기기 종류 식별자>;<빌드>;<공유 수준>[;debug][;locked]`. 서버가 AI 응답의 `sync`에 실어 어느 기기의 기록인지 알린다(AIC1112A01).
    /// `locked`는 사생활 잠금 중이라 하루 기록 올리기를 쉬고 있다는 표시다(AIL1112A01).
    /// 기기 이름·사용자 정보는 넣지 않는다. 모양이 맞지 않으면 보내지 않는다.
    public static func clientHeader(
        model: String = hardwareModel, build: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
        level: AssistantShareLevel, debug: Bool, locked: Bool
    ) -> String? {
        let device = String(model.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == ",") }.prefix(24))
        guard let build, let first = device.unicodeScalars.first, CharacterSet.letters.contains(first),
              !build.isEmpty, build.count <= 8, build.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return ([device, build, level.rawValue] + (debug ? ["debug"] : []) + (locked ? ["locked"] : [])).joined(separator: ";")
    }

    /// `iPhone12,3` 같은 기기 종류 식별자(사용자가 붙인 기기 이름이 아니다).
    public static let hardwareModel: String = {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }()

    /// `token`을 주면 그 키로 부른다(키를 바꾸기 전 예전 키로 지울 때, SEC1110A01).
    /// `host`는 시험에서만 바꾼다(SEC1110A02). `client`는 헤더에 싣는 공유 수준·잠금 여부로, 앱이 넣어 준다.
    public static func relayRequest(
        _ path: String, method: String, query: [URLQueryItem] = [], body: Data? = nil, token: String? = nil, host: String? = TripRelay.host,
        client: AssistantClientState, timeout: TimeInterval = 10
    ) -> URLRequest? {
        guard let url = url(path, query: query, host: host), let key = token ?? key else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(clientHeader(level: client.level, debug: client.debug, locked: client.locked), forHTTPHeaderField: clientHeaderName)
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }
}
