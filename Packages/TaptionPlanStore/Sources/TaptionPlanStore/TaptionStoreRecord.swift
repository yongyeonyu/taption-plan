import CryptoKit
import Foundation

/// 새 저장소(스키마 1). 이전 DB·백업과 호환하지 않는다.
///
/// - 위치·센서 원본은 압축된 덩어리가 아니라 **열이 나뉜 표**(`readings`)에 둔다. SQL로 바로 분석할 수 있다.
///   열로 빼지 않은 나머지 필드는 `extra` JSON에 남겨 원본이 사라지지 않는다.
/// - 계획·기록·메모 등은 `records` 표의 행 하나씩으로 둔다. 모든 행에 출처(`origin`: 자동/사용자/가져옴)가 있다.
/// - 파일은 표준 SQLite라서 `sqlite3` 명령으로도 열린다.
public enum TaptionStoreV2Error: Error, Equatable {
    case openFailed(String)
    case sqlFailed(String)
    case unsupportedSchema(Int)
    case corruptRow(String)
    /// 같은 `id`의 센서 원본이 이미 다른 내용으로 저장돼 있다(원본은 바꾸지 않는다).
    case readingConflict(String)
    /// 같은 종류·`id`의 원본 이벤트가 이미 다른 내용으로 저장돼 있다.
    case rawEventConflict(kind: String, id: String)
}

/// 사용자에게는 짧은 한국어 안내만 보이고, 자세한 원인은 진단 로그에 남는다.
extension TaptionStoreV2Error: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .openFailed, .sqlFailed: "기록 저장소를 여는 중 문제가 생겼습니다."
        case .unsupportedSchema: "이 앱 버전보다 새 기록 형식입니다. 앱을 업데이트해 주세요."
        case .corruptRow, .readingConflict, .rawEventConflict: "일부 기록을 읽지 못했습니다."
        }
    }
}

public struct TaptionStoreRecord: Equatable, Sendable {
    public enum Origin: String, Sendable {
        case auto
        case user
        case imported
    }

    public var id: String
    public var kind: String
    public var start: Date?
    public var end: Date?
    public var updatedAt: Date
    public var origin: Origin
    public var isDeleted = false
    /// 같은 종류 안에서 처음 저장된 순서. 불러올 때 이 순서를 유지한다.
    public var ord = 0
    /// 레코드 내용(JSON 문자열). `json_extract`로 조회할 수 있다.
    public var body: String

    public init(
        id: String,
        kind: String,
        start: Date? = nil,
        end: Date? = nil,
        updatedAt: Date,
        origin: Origin,
        isDeleted: Bool = false,
        ord: Int = 0,
        body: String
    ) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.updatedAt = updatedAt
        self.origin = origin
        self.isDeleted = isDeleted
        self.ord = ord
        self.body = body
    }
}

/// 같은 (종류, id) 기록이 두 곳(로컬·백업 파일)에 있을 때 어느 쪽이 이기는지 정하는 순서.
/// 입력 순서나 기기와 무관하게 결정적이어야 여러 기기에서 합쳐도 같은 결과로 수렴한다:
/// 수정 시각이 나중인 쪽 → 같으면 삭제 표시 → 그래도 같으면 본문 SHA-256(hex)이 큰 쪽(같으면 바꾸지 않는다).
public enum TaptionRecordMerge {
    public struct Existing: Equatable, Sendable {
        public var updated: Double
        public var isDeleted: Bool
        public var body: String

        public init(
            updated: Double,
            isDeleted: Bool,
            body: String
        ) {
            self.updated = updated
            self.isDeleted = isDeleted
            self.body = body
        }
    }

    public static func incomingWins(existing: Existing, incoming: TaptionStoreRecord) -> Bool {
        let incomingUpdated = incoming.updatedAt.timeIntervalSince1970
        if incomingUpdated != existing.updated { return incomingUpdated > existing.updated }
        if incoming.isDeleted != existing.isDeleted { return incoming.isDeleted }
        return bodyDigest(incoming.body) > bodyDigest(existing.body)
    }

    public static func bodyDigest(_ body: String) -> String {
        SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
