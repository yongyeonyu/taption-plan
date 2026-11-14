import SwiftUI
import TaptionTripShare

// 묶음 B가 채운다(TSH1114A26). 0단계는 컴파일되는 뼈대와 아래 약속만 둔다.
//
// 0단계가 약속한 것
// - `TravelModeView`의 편집 진입(넣기·곳 더하기·열기·옮기기·길이·지우기·순서·되돌리기·여행 고치기)은 모두
//   `route(model:tripID:edit:local:)`을 거친다. `local`은 공유하지 않는 여행에서 하던 그대로의 동작이다.
// - 공유하지 않는 여행은 늘 `local()`. 공유 여행의 되돌리기(`.history`)는 막는다(대표 결정).
// - 뼈대의 나머지 동작은 통과다: 고칠 수 있으면(`store.canEdit`) `local()`, 아니면 「보기만」 안내.
//
// B가 할 일: 공유 여행이면 `local()`을 그대로 부르지 않고
//   잠금(`session.lock(items:groups:)`, 60초마다 `extendLocks()`) → 쓰기(`session.write([ShareEdit])`, 충돌이면 최신본으로 바뀜)
//   → 로컬 반영(`model.applySharedPlanChanges`) → 풀기(`session.unlock`) 순서로 한다.
//   `.open`은 잠금을 잡은 뒤 `local()`로 편집기를 열고, 저장·지움은 `TravelQuickEntrySheet` 안에서 이 편집기를 부르게 고친다.
//   방 항목 id는 `TripShareMapping.roomItemID(tripID:itemID:)`, 날 묶음은 `store.groupName(tripID:day:)`, 평문은 `TripShareMapping.plan`.
//   다른 사람이 잡은 칸(`store.lockState(tripID:itemID:)`이 `.other`)은 편집기를 열지 않고 알린다.

/// 공유 여행의 편집을 받는 곳.
@MainActor
enum TripSharePlanEditor {
    static func route(model: AppModel, tripID: String, edit: TripSharePlanEdit, local: @escaping () -> Void) {
        let store = TripShareStore.shared
        guard model.isSharedTrip(tripID) else { return local() }
        if edit == .history {
            store.notice = TripShareText.undoBlocked(.current)
        } else if store.canEdit(tripID) {
            local()
        } else {
            store.notice = TripShareText.viewOnly(.current)
        }
    }
}
