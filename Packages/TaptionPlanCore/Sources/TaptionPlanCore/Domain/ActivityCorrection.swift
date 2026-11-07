import Foundation

/// 사용자가 자동 기록의 표시 분류만 교정한 값. 센서 원본과 근거는
/// 그대로 보존하고, 다음 자동 갱신 뒤에도 같은 표시를 복원한다.
public struct ActivityCorrection: Codable, Hashable, Sendable {
    public var title: String
    public var behavior: String?
    public var categoryID: String
    /// 사용자 조정 시간은 센서 원본이 아니라 표시용 파생값이다.
    public var startedAt: Date?
    public var endedAt: Date?

    public init(
        title: String,
        behavior: String? = nil,
        categoryID: String = "activity",
        startedAt: Date? = nil,
        endedAt: Date? = nil
    ) {
        self.title = title
        self.behavior = behavior
        self.categoryID = categoryID
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}
