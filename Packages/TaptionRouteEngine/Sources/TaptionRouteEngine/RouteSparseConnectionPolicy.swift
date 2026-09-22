import Foundation

public enum RouteSparseConnectionPolicy {
    public static let maximumGapDuration: TimeInterval = 15 * 60
    public static let minimumSparseGapDuration: TimeInterval = 5 * 60
    public static let maximumSparseDistanceMeters: Double = 1_000
    /// 지상 이동으로는 불가능한 속도(약 198km/h). 라우트 필터의 unknown-mode
    /// 상한과 같다. 이 속도를 넘으면 gap 길이와 무관하게 두 표본을 잇지 않는다.
    public static let impossibleSpeedMetersPerSecond: Double = 55

    public static func breaksConnection(
        gapDuration: TimeInterval,
        distanceMeters: Double?
    ) -> Bool {
        guard let distanceMeters else { return false }
        // 기존 규칙: 5분 초과 gap + 1km 초과 거리면 끊는다.
        if gapDuration > minimumSparseGapDuration
            && distanceMeters > maximumSparseDistanceMeters {
            return true
        }
        // 추가 규칙: gap이 짧아도 물리적으로 불가능한 속도(회사→집 순간이동
        // 같은 오래된/좌표 튐)면 끊는다. 이전에는 gap이 5분 이하이면 아무리
        // 멀어도 연결돼 재생 시 회사↔집 직선 점프가 생겼다.
        if gapDuration > 0,
           distanceMeters / gapDuration > impossibleSpeedMetersPerSecond {
            return true
        }
        return false
    }
}
