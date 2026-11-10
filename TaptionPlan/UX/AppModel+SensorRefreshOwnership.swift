import Foundation

/// 센서 갱신 작업 안에서 일어난 스냅샷 변경인지 가린다(REV1110A04).
/// 갱신 작업과 그 자식 작업만 `isActive`가 참이다. 편집·다시 읽기·시계 동기화·가져오기는 다른 작업에서 돈다.
enum SensorRefreshMutationScope {
    @TaskLocal static var isActive = false
}

extension AppModel {
    /// 갱신 도중 다른 작업이 스냅샷을 바꾸면 갱신이 실패해도 갱신 전 값으로 되돌리지 않는다.
    /// 되돌리면 그 변경이 메모리에서 사라지고 다음 저장이 그 행을 지운다(REV1110A04).
    func noteSnapshotMutationForSensorRefresh() {
        guard isSensorTimelineRefreshing, !SensorRefreshMutationScope.isActive else { return }
        userEditedDuringSensorRefresh = true
    }
}
