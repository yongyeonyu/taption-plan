import Foundation
import TaptionLedgerCore
import TaptionTripShare

// 묶음 C가 채운다(TSH1114A26). 0단계는 컴파일되는 뼈대와 아래 약속만 둔다.
//
// 0단계가 약속한 것
// - `TripShareStore`가 세션의 변화마다 `roomChanged(model:link:view:event:)`를 부른다.
//   공유 지출은 `view.items(of: .expenseShared)`, 공개한 개인 지출은 `view.items(of: .expenseOwn)`.
// - 평문 ⇄ 가계부: `TripShareMapping.sharedExpense(_:names:)`·`entry(_:roomItemID:tripID:names:existing:)`,
//   개인(공개) `ownExpense(_:)`·`entry(_:roomItemID:tripID:existing:)`. 방 항목 id는 `TripShareMapping.roomItemID(entryID:)`.
//   이름표는 `TripShareStore.shared.names(tripID:)`(같은 닉네임은 「가을 (2)」로 갈라져 있다).
// - 남의 개인 지출은 가계부(SQLite)에 넣지 않는다. 방 사본(`view`)에서만 읽어 보여 준다.
// - 비공개·개인 지출의 몫은 `TripShareMapping.privateShare`(나만)로 고정한다. 비워 두면 기존 계산이 「다 같이」로 나눈다.
// - 공유 예산은 `view.meta?.budget`이고 `LedgerTrip.budgetKRW`에 넣지 않는다.
// - 자동으로 들어온 지출(문자·Siri·통행료 등 `source != .manual`)은 올리지 않는다(대표 결정).
//
// C가 할 일: 범위별 저장(`session.write`)·투영(`LedgerBook.shared.save`), 닉네임이 바뀌면 투영한 지출의 `payer`·`shareNames`와
//   `LedgerTrip.members`(`names.others`) 다시 쓰기, 마감(`view.closed`) 뒤 입력 막기.

/// 지출의 공개 범위. 비공개는 방에 올리지 않는다.
enum TripShareExpenseScope: String, CaseIterable, Sendable {
    /// 공유 지출: 정산에 들어간다.
    case shared
    /// 개인 지출, 일행에게 보임. 정산에는 들어가지 않는다.
    case ownOpen
    /// 개인 지출, 이 기기에만.
    case ownHidden
}

/// 방의 지출을 가계부에 투영하고, 가계부의 지출을 범위에 맞게 방에 올린다.
@MainActor
enum TripShareLedger {
    static func roomChanged(model: AppModel, link: TripShareLink, view: ShareRoomView, event: ShareSessionEvent) async {}

    /// 지금 그 지출이 놓인 범위. 방 사본에 대응이 없으면 비공개다.
    static func scope(of entry: LedgerEntry) -> TripShareExpenseScope {
        guard let tripID = entry.tripID, let view = TripShareStore.shared.view(tripID: tripID) else { return .ownHidden }
        let id = TripShareMapping.roomItemID(entryID: entry.id)
        switch view.items.first(where: { $0.id == id })?.kind {
        case ShareKind.expenseShared.rawValue: return .shared
        case ShareKind.expenseOwn.rawValue: return .ownOpen
        default: return .ownHidden
        }
    }
}
