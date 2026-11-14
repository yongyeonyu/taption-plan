import SwiftUI
import TaptionTripShare

// 묶음 C가 채운다(TSH1114A26). 0단계는 컴파일되는 뼈대와 아래 약속만 둔다.
//
// 0단계가 약속한 것
// - `TripSharePanel`이 `List` 안에서 `TripShareSettlementSection(model:language:tripID:)`을 부른다(`Section`으로 그린다).
//   C는 `LedgerTripView`의 정산 구역(`LedgerTripSheetSection`)도 공유 여행이면 이것으로 바꾼다(그 파일은 C가 고친다).
// - 계산은 패키지의 `ShareSettlementCalculator.settle(_:parties:)`만 쓴다(참여자 번호 순·항목 id 순이라 모든 기기에서 같다).
//   기존 `LedgerTripMath.sheet`는 내 기준이라 공유 정산에 쓰지 않는다(돈 줄의 「내가 쓴 돈」에만).
// - 넣을 것: `view.items(of: .expenseShared)`, 사람은 `store.names(tripID:)?.parties`, 「정산 안 함」은 `view.meta?.settlementOff`.
// - 「보냄」 표시는 내 카드의 `sent`(`ShareTransfer.key`)에 두고 `session.publish(card:)`로 올린다(마감 뒤에도 된다).
// - 마감·다시 열기는 주인만: `session.setSettlementClosed(_:)`. 상태는 `view.closed`.

/// 공유 정산: 송금 목록·「보냄」 체크·주인의 마감/다시 열기.
struct TripShareSettlementSection: View {
    @Bindable var model: AppModel
    let language: MapHomeLanguage
    let tripID: String

    var body: some View {
        EmptyView()
    }
}
