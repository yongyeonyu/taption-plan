import SwiftUI
import TaptionTripShare

// 묶음 A가 채운다(TSH1114A26). 0단계는 컴파일되는 뼈대와 아래 약속만 둔다.
//
// 0단계가 약속한 것
// - `AppModel.deleteTravelTrip`은 지우기 전에 `tripWillDelete(model:tripID:)`를 부르고, false면 지우지 않는다.
//   공유하지 않는 여행은 늘 true다. 주인이면 방을 어떻게 할지(방 지우기), 참여자면 나가기를 여기서 처리한다.
//   뼈대는 서버에 알리지 않고 이 기기에서만 방을 잊는다(`store.forget(tripID:)`).
//   A는 그 앞에 `session.deleteRoom()`(주인)·`session.leave()`(참여자)를 넣는다.
// - 주인 동작은 세션으로 한다: `kick(member:)`(끝나면 비밀번호 바꾸기 권유), `rotate(to:)`·`confirmRotation(with:)`(키 교체),
//   `setExpiry(_:)`(기한), `deleteRoom()`. 끝나면 `store.refresh(tripID:)`.
//   키가 바뀌면(교체·다시 증명) 새 뿌리 키·세대를 `store.saveSecrets(_:roomID:)`로 키체인에 적는다.

/// 주인만 하는 일과 여행을 지울 때의 방 처리.
@MainActor
enum TripShareOwnerActions {
    /// 여행을 지우기 직전에 불린다. false를 돌려주면 지우지 않는다.
    static func tripWillDelete(model: AppModel, tripID: String) async -> Bool {
        let store = TripShareStore.shared
        guard let link = store.link(tripID: tripID) else { return true }
        switch link.role {
        case .owner: break // A: 방 지우기(서버) — 실패하면 묻고 false.
        case .member: break // A: 나가기(서버).
        }
        await store.forget(tripID: tripID)
        return true
    }
}
