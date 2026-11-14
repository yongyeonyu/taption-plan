import Foundation
import Security
import Synchronization
import TaptionAssistantKit
import TaptionTripShare

/// 여행 공유(TSH1114A26)가 바깥과 닿는 곳을 한데 묶는다: 전송(서버 주소)·키 보관·곁 파일·앱 등록 키.
/// 패키지 `TaptionTripShare`는 이것들을 받기만 한다. 시험은 가짜 서버 전송과 메모리 보관으로 바꿔 넣는다.
struct TripShareEnvironment: Sendable {
    /// 서버 주소가 없으면 nil이고, 그러면 공유 기능 전체를 숨긴다.
    var transport: (any ShareTransport)?
    var secrets: any ShareSecretStore
    var sidecar: TripShareSidecar
    /// 방 만들기에만 쓰는 앱 등록 키. 등록을 먼저 보장하고(`AssistantRegistration.ensureReady()`) 못 하면 nil.
    var appKey: @Sendable () async -> String?
    var session = ShareSessionEnvironment()

    var isAvailable: Bool { transport != nil }

    /// 초대 링크는 앱 전용 스킴 하나다(대표 결정): `taptionplan://share#<roomId>.<linkSecret>`.
    static let inviteHost = "share"

    static func inviteURL(_ invite: ShareInvite) -> URL? {
        URL(string: "taptionplan://\(inviteHost)").flatMap(invite.url(opening:))
    }

    /// 붙여넣은 글이나 열린 주소에서 초대를 읽는다. 우리 스킴·호스트가 아니면 nil.
    static func invite(from text: String) -> ShareInvite? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "taptionplan", url.host == inviteHost else { return nil }
        return ShareInvite(url: url)
    }

    @MainActor static var live: TripShareEnvironment {
        TripShareEnvironment(
            transport: TripRelay.host.flatMap { URL(string: "https://\($0)") }.map { URLSessionShareTransport(baseURL: $0) },
            secrets: TripShareKeychain(), sidecar: .live,
            appKey: { @MainActor in await AssistantRegistration.ensureReady() ? TripRelay.key : nil }
        )
    }
}

/// 방의 비밀(뿌리 키·링크 비밀·참여 토큰·주인 키)을 키체인에 둔다: 방 하나에 항목 하나, 이 기기에서만.
/// 비밀번호 자체는 어디에도 저장하지 않는다.
struct TripShareKeychain: ShareSecretStore {
    var service = "com.taption.plan.tripshare"

    private func query(_ roomID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: roomID]
    }

    func secrets(roomID: String) throws -> ShareRoomSecrets? {
        var item: CFTypeRef?
        var request = query(roomID)
        request[kSecReturnData as String] = true
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw ShareError.crypto }
        return try JSONDecoder().decode(ShareRoomSecrets.self, from: data)
    }

    func save(_ secrets: ShareRoomSecrets, roomID: String) throws {
        guard ShareIdentifiers.isRoomID(roomID) else { throw ShareError.invalidResponse }
        SecItemDelete(query(roomID) as CFDictionary)
        var item = query(roomID)
        item[kSecValueData as String] = try JSONEncoder().encode(secrets)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw ShareError.crypto }
    }

    func remove(roomID: String) throws {
        let status = SecItemDelete(query(roomID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ShareError.crypto }
    }
}

/// 메모리에만 두는 보관(시험·미리 보기).
final class TripShareMemorySecrets: ShareSecretStore {
    private let values = Mutex<[String: ShareRoomSecrets]>([:])

    func secrets(roomID: String) throws -> ShareRoomSecrets? { values.withLock { $0[roomID] } }
    func save(_ secrets: ShareRoomSecrets, roomID: String) throws { values.withLock { $0[roomID] = secrets } }
    func remove(roomID: String) throws { values.withLock { $0[roomID] = nil } }
}
