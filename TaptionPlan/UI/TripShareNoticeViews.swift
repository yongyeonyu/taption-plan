import SwiftUI
import TaptionTripShare

// 묶음 C가 채운다(TSH1114A26). 0단계는 컴파일되는 뼈대와 아래 약속만 둔다.
//
// 0단계가 약속한 것
// - `TripShareNoticeBand(model:language:tripID:)`은 여행 머리줄의 돈 줄 아래에 이미 놓여 있다(확인 안 한 공지 한 줄 + 「확인」).
// - `TripShareNoticeList(model:language:tripID:)`은 공유 판(`TripSharePanel`)의 `List` 안에서 불린다(목록·작성·확인 현황, `Section`으로 그린다).
// - 공지는 `store.view(tripID:)?.items(of: .notice)`, 확인은 `item.acks`(참여자 번호 → 시각), 내 번호는 `view.me`.
//   확인은 `session.acknowledge(noticeID:)`, 쓰기는 `session.write([.create(.notice(...))])`. 끝나면 `store.refresh(tripID:)`.
// - 공유하지 않는 여행에서는 둘 다 아무것도 그리지 않는다. 공지는 방이 사라지면 함께 사라진다(로컬 정본에 넣지 않는다).
// - 장소는 이름만(`ShareNoticeContent.place`), 좌표는 싣지 않는다.

/// 여행 머리줄 아래의 확인 안 한 공지 띠.
struct TripShareNoticeBand: View {
    @Bindable var model: AppModel
    let language: MapHomeLanguage
    let tripID: String

    var body: some View {
        EmptyView()
    }
}

/// 공유 판의 공지 구역: 목록·작성·확인한 사람과 아직인 사람.
struct TripShareNoticeList: View {
    @Bindable var model: AppModel
    let language: MapHomeLanguage
    let tripID: String

    var body: some View {
        EmptyView()
    }
}
