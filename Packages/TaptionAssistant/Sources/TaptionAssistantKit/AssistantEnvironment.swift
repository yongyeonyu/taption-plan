import Foundation

/// AI 연결 코드가 쓰는 바깥 것들(PKG1114A19). 패키지는 앱 설정·잠금·키체인의 연결 키를 모르므로 앱이 넣어 준다.
/// 시험은 메모리 저장소와 가짜 세션을 넣는다.
public struct AssistantEnvironment {
    public var secrets: AssistantSecretStore
    public var defaults: UserDefaults
    public var session: URLSession
    public var host: String?
    /// 키체인의 연결 키를 지운다. 시험은 비워 둔다.
    public var clearConnections: () -> Void
    /// 새 연결 키를 키체인에 둔다. 시험은 저장하지 않는다.
    public var saveConnection: (String) -> Bool
    /// 요청 헤더에 싣는 공유 수준·잠금 여부. 요청을 만들 때마다 읽는다.
    public var client: @Sendable () -> AssistantClientState
    /// 주 키를 바꿀 때 AI 규칙을 예전 키(첫째)에서 새 키(둘째)로 옮기고 예전 자리에서 지운다. 옮기지 못하면 false(AIF1118A01).
    /// 규칙 사본은 앱에 있어 앱이 넣는다. 시험은 옮길 것이 없다고 본다.
    public var moveRules: @MainActor (String, String, AssistantEnvironment) async -> Bool = { _, _, _ in true }

    public init(
        secrets: AssistantSecretStore, defaults: UserDefaults, session: URLSession, host: String?,
        clearConnections: @escaping () -> Void, saveConnection: @escaping (String) -> Bool = { _ in true },
        client: @escaping @Sendable () -> AssistantClientState
    ) {
        self.secrets = secrets
        self.defaults = defaults
        self.session = session
        self.host = host
        self.clearConnections = clearConnections
        self.saveConnection = saveConnection
        self.client = client
    }
}
