import SwiftUI
import TaptionPlanStore
import TaptionTripShare

// 묶음 A가 채운다(TSH1114A26). 0단계는 컴파일되는 뼈대와 아래 약속만 둔다.
//
// 0단계가 약속한 것(방 만들기의 순서)
// 1. 비밀번호 규칙은 `SharePasswordPolicy.issue(in:)`만 쓴다.
// 2. `ShareInvite.make()` → `ShareKeys.derive(roomID:linkSecret:password:)`(60만 회라 화면 밖 Task에서, 진행 표시).
// 3. 앱 등록 키는 `await TripShareStore.shared.appKey()`(등록을 먼저 보장한다. nil이면 만들지 못한다고 알린다).
// 4. `ShareRoomClient.createRoom(transport:appKey:request:)` → 응답으로 `ShareRoomSecrets`를 만들고
//    `store.register(TripShareLink(roomID:tripID:role: .owner, phase: .uploading), secrets:)`.
// 5. `store.open(tripID:)`로 세션을 열고 `meta`(`TripShareMapping.meta`)·내 카드·기존 일정(`TripShareMapping.plan`, 50건씩)을 올린다.
//    올린 방 항목 id는 `link.uploaded`에 적어 끊겨도 이어 올리고, 다 올리면 `link.phase = .sharing`으로 `store.save(link)`.
// 6. 링크는 `TripShareEnvironment.inviteURL(invite)`를 공유 시트로, 비밀번호는 화면에만(「따로 알려 주세요」).
// - 좌표는 올리지 않는다: 장소는 핀 이름만 `TripShareMapping.plan(_:place:)`에 넘긴다.

/// 공유 만들기: 비밀번호 → 방 만들기 → 올리는 중 → 초대 링크.
struct TripShareCreateSheet: View {
    @Bindable var model: AppModel
    let language: MapHomeLanguage
    let trip: TravelTrip

    var body: some View {
        EmptyView()
    }
}
