import SwiftUI
import TaptionTripShare

// 묶음 A가 채운다(TSH1114A26). 0단계는 컴파일되는 뼈대와 아래 약속만 둔다.
//
// 0단계가 약속한 것
// - `TripShareHost`가 `TripShareJoinSheet(model:language:invite:)`으로 띄운다. 열린 주소로 왔으면 `invite`가 있고,
//   목록의 참여 단추로 왔으면 nil이라 붙여넣기(`PasteButton`)부터 받는다. 붙여넣은 글은 `TripShareEnvironment.invite(from:)`로 읽는다.
// - 순서: 링크 확인 → 비밀번호 → 닉네임. `ShareKeys.derive` → `ShareRoomClient.join(transport:roomID:proof:)` →
//   `store.register(TripShareLink(roomID:tripID: TripShareMapping.joinedTripID(roomID:), role: .member, phase: .sharing), secrets:)`
//   → `store.open(tripID:)` → 내 카드 올리기(`session.publish(card:)`).
// - 로컬 여행과 일정은 B의 `TripSharePlanProjector`가 방 내용을 받아 만든다(여기서 만들지 않는다).
// - 오류 문구는 여기서 정한다(`wrong_password` 남은 횟수·`join_locked` 기다림·`room_full`·404). 패키지에는 문구가 없다.

/// 초대로 참여.
struct TripShareJoinSheet: View {
    @Bindable var model: AppModel
    let language: MapHomeLanguage
    let invite: ShareInvite?

    var body: some View {
        EmptyView()
    }
}
