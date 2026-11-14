import Foundation
import Security

/// 중계 키를 두는 자리(SEC1110A02). 주 키, 바꾸는 중인 새 주 키, 지도 검색용 키.
public enum AssistantSecretSlot: String, CaseIterable, Sendable {
    case master
    case pendingMaster
    case search
}

/// 키체인 대신 시험에서 메모리를 쓰려고 나눈다.
@MainActor
public protocol AssistantSecretStore: AnyObject {
    func read(_ slot: AssistantSecretSlot) -> String?
    @discardableResult func write(_ value: String?, to slot: AssistantSecretSlot) -> Bool
}

/// 기기에만 두는 키체인(이 기기만, 첫 잠금 해제 뒤). 주 키는 예전 자리(`relay-key`)를 그대로 쓴다.
@MainActor
public final class AssistantKeychainSecrets: AssistantSecretStore {
    public static let shared = AssistantKeychainSecrets()
    private static let service = "com.taption.plan.triprelay"

    private func query(_ slot: AssistantSecretSlot) -> [String: Any] {
        let account = switch slot {
        case .master: "relay-key"
        case .pendingMaster: "relay-key-pending"
        case .search: "search-key"
        }
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: account]
    }

    public func read(_ slot: AssistantSecretSlot) -> String? {
        var item: CFTypeRef?
        var request = query(slot)
        request[kSecReturnData as String] = true
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    @discardableResult
    public func write(_ value: String?, to slot: AssistantSecretSlot) -> Bool {
        SecItemDelete(query(slot) as CFDictionary)
        guard let value else { return true }
        var item = query(slot)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

/// 주 키를 바꾸는 동안 예전 키로 올리거나 명령을 받지 않게 막는다(REV1110A06).
@MainActor
public enum AssistantRelayGate {
    public private(set) static var isRotating = false
    private static var activeWork = 0

    /// 올리기·명령 받기를 시작한다. 주 키를 바꾸는 중이면 false.
    public static func begin() -> Bool {
        guard !isRotating else { return false }
        activeWork += 1
        return true
    }

    public static func end() { activeWork = max(0, activeWork - 1) }

    public static func beginRotation() -> Bool {
        guard !isRotating else { return false }
        isRotating = true
        return true
    }

    public static func endRotation() { isRotating = false }

    /// 하던 요청이 끝나기를 30초까지 기다린다.
    public static func waitUntilIdle(timeout: TimeInterval = 30) async -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while activeWork > 0 {
            guard Date.now < deadline, (try? await Task.sleep(for: .milliseconds(100))) != nil else { return false }
        }
        return true
    }
}
