import SwiftUI

/// 메모 편집 화면의 지출 칩(LED1111A03). 글에서 금액을 알아보면 「지출 4,500원 · 카페」를 보이고,
/// 누르면 이 메모만 「메모로만」으로 바꾼다(가계부에 넣지 않음). 다시 누르면 되돌린다. 저장해야 반영된다.
struct LedgerMemoChip: View {
    let memoID: UUID
    let text: String
    let language: MapHomeLanguage
    @State private var optedOut = false

    var body: some View {
        if let found = LedgerMemoAmount.find(text) {
            Button {
                optedOut.toggle()
                LedgerMemoOptOut.pending[memoID] = optedOut
            } label: {
                Label(label(found), systemImage: optedOut ? "note.text" : (found.kind == .income ? "plus.circle.fill" : "wonsign.circle.fill"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .bold))
                    .foregroundStyle(optedOut ? Color.tpSecondary : Color.tpAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.tpCard, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("memo-ledger-chip")
            .onAppear {
                LedgerMemoOptOut.pending[memoID] = nil
                optedOut = LedgerMemoOptOut.contains(memoID)
            }
        }
    }

    private func label(_ found: LedgerMemoAmount.Found) -> String {
        guard !optedOut else { return language.text("메모로만 · 눌러서 가계부에 넣기", "Memo only · tap to add to ledger") }
        let money = LedgerMoney.text(found.amount, currency: found.currency, language: language)
        let category = found.kind == .income ? language.text("수입", "Income") : LedgerCategory.guess(found.title).title(language)
        let kind = found.kind == .income ? language.text("수입", "Income") : language.text("지출", "Expense")
        return found.kind == .income
            ? "\(kind) \(money) · \(language.text("눌러서 메모로만", "tap for memo only"))"
            : "\(kind) \(money) · \(category) · \(language.text("눌러서 메모로만", "tap for memo only"))"
    }
}
