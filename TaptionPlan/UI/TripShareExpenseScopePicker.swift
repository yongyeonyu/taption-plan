import SwiftUI

// 묶음 C가 채운다(TSH1114A26). 0단계는 컴파일되는 뼈대와 아래 약속만 둔다.
//
// 0단계가 약속한 것
// - 범위는 `TripShareExpenseScope`(공유 / 개인-공개 / 개인-비공개) 하나의 값이다.
// - 공유하지 않는 여행(`!TripShareStore.shared.isShared(tripID)`)에서는 아무것도 그리지 않는다.
// - 「내 지출 전부 공유」의 여행 기본값은 `store.view(tripID:)?.meta?.shareAllExpenses`.
//
// C가 할 일: 고르는 화면, 그리고 `LedgerEntryForm`(`LedgerSheet.swift`, C가 고친다)에 이 줄을 놓고 저장·지움을 `TripShareLedger`로 보내기.

/// 지출 폼의 공개 범위 고르기.
struct TripShareExpenseScopePicker: View {
    let language: MapHomeLanguage
    let tripID: String
    @Binding var scope: TripShareExpenseScope

    var body: some View {
        EmptyView()
    }
}
