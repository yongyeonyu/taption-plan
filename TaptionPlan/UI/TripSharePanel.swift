import SwiftUI
import TaptionTripShare

// 묶음 A가 채운다(TSH1114A26). 0단계는 컴파일되는 뼈대와 아래 약속만 둔다.
//
// 0단계가 약속한 것
// - `TripShareHost`가 `TripSharePanel(model:language:tripID:)`으로 시트에 띄운다(초기화 인자를 바꾸지 않는다).
// - 공유 전(`store.link(tripID:) == nil`)이면 「공유 만들기」(`TripShareCreateSheet`), 참여한 여행(`role == .member`)에는 만들기가 없다.
// - 공유 중이면 구역 순서: 참여자(`TripShareMembersView`) → 공지(C의 `TripShareNoticeList`) → 정산(C의 `TripShareSettlementSection`)
//   → 주인 동작(`TripShareOwnerActions`). C의 두 화면은 이미 뼈대가 있으니 그대로 불러 넣으면 된다.
// - 읽는 값: `TripShareStore.shared.link(tripID:)`, `.view(tripID:)`, `.names(tripID:)`, `.canEdit(tripID)`.

/// 그 여행의 공유 판.
struct TripSharePanel: View {
    @Bindable var model: AppModel
    let language: MapHomeLanguage
    let tripID: String

    var body: some View {
        NavigationStack {
            List {
                TripShareMembersView(language: language, tripID: tripID)
                TripShareNoticeList(model: model, language: language, tripID: tripID)
                TripShareSettlementSection(model: model, language: language, tripID: tripID)
            }
            .navigationTitle(language.text("여행 공유", "Share trip"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
