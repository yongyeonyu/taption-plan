import Foundation
import Security

extension AssistantEnvironment {
    /// 지금 앱의 환경: 키체인·기기 설정·실서버, 헤더에는 지금 공유 수준과 잠금 여부.
    @MainActor static var live: AssistantEnvironment {
        AssistantEnvironment(
            secrets: AssistantKeychainSecrets.shared, defaults: .standard, session: .shared, host: TripRelay.host,
            clearConnections: { AssistantKeyStore.removeAll() }, saveConnection: { AssistantKeyStore.save($0) },
            client: { .live }
        )
    }
}

/// 지금 앱의 환경으로 부르는 길. 패키지의 본체는 환경을 받기만 한다(PKG1114A19).
extension AssistantRegistration {
    private static var preparing: Task<Bool, Never>?
    private static var searching: Task<String?, Never>?

    static func isReady() -> Bool { isReady(.live) }

    static let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// 앱을 열 때 부른다. 여러 곳에서 불러도 한 번만 돈다.
    @discardableResult
    static func ensureReady() async -> Bool {
        // 단위 시험의 호스트 앱이 실서버에 등록·바꾸기를 하면 시험의 바꾸기 표시와 겹친다(EXE1110A01).
        guard !isTestHost else { return false }
        if isReady() { return true }
        if let preparing { return await preparing.value }
        let task = Task { @MainActor in await prepare(.live) }
        preparing = task
        let ready = await task.value
        preparing = nil
        return ready
    }

    /// 카카오 검색에 붙이는 설치마다의 검색 전용 키(PIN 없음). 등록하지 못하면 nil.
    static func searchToken() async -> String? {
        if let searching { return await searching.value }
        let task = Task { @MainActor in await searchToken(.live) }
        searching = task
        let token = await task.value
        searching = nil
        return token
    }
}
