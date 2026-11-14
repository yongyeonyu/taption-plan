import SwiftUI
import TaptionTripShare

// 묶음 A가 채운다(TSH1114A26). 0단계는 컴파일되는 뼈대와 아래 약속만 둔다.
//
// 0단계가 약속한 것
// - `TripShareMemberBadge(tripID:language:)`는 여행 카드에 이미 놓여 있다(「사람 N」). 값은 `store.memberCount(tripID:)`.
// - `TripShareMembersView(language:tripID:)`는 공유 판의 첫 구역이다(`List` 안의 `Section`으로 그린다).
// - 읽는 값: `store.view(tripID:)?.members`(번호·접속 중), `.cards`(닉네임·색), `.isOwner`, `store.names(tripID:)`.
// - 내보내기는 `TripShareOwnerActions`가 한다.

/// 여행 카드의 「사람 N」. 공유하지 않는 여행이면 아무것도 그리지 않는다.
struct TripShareMemberBadge: View {
    let tripID: String
    let language: MapHomeLanguage

    var body: some View {
        if let count = TripShareStore.shared.memberCount(tripID: tripID) {
            Label(language.runtimeText("사람 \(count)", "\(count) people"), systemImage: "person.2.fill")
                .font(.caption2.weight(.medium))
                .accessibilityIdentifier("travelTripShareCount-\(tripID)")
        }
    }
}

/// 참여자 목록(닉네임·색·접속 중·주인 표시).
struct TripShareMembersView: View {
    let language: MapHomeLanguage
    let tripID: String

    var body: some View {
        EmptyView()
    }
}
