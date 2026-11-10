import Observation
import SwiftUI

/// 메모 목록의 거르기(LED1111A03): 전체 · 메모 · 지출.
enum LedgerMemoFilter: String, CaseIterable, Identifiable {
    case all, memos, expenses
    var id: String { rawValue }

    func title(_ language: MapHomeLanguage) -> String {
        switch self {
        case .all: language.text("전체", "All")
        case .memos: language.text("메모", "Memos")
        case .expenses: language.text("지출", "Spending")
        }
    }
}

/// 가계부 화면을 어디서든 연다(메모 목록 머리, 「+ 메모」 길게 누르기). 화면은 지도 왼쪽 위 단추 뒤에 붙은 호스트가 띄운다.
@MainActor
@Observable
final class LedgerPresenter {
    static let shared = LedgerPresenter()
    var isPresented = false
}

struct LedgerSheetHost: View {
    let language: MapHomeLanguage
    var tripID: String?
    @Bindable private var presenter = LedgerPresenter.shared

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .sheet(isPresented: $presenter.isPresented) { LedgerSheet(language: language, tripID: tripID) }
    }
}

/// 메모 목록 맨 위: 거르기와 이 달 지출·오늘 지출, 가계부 열기.
struct LedgerMemoHeader: View {
    @Binding var filter: LedgerMemoFilter
    let language: MapHomeLanguage
    let day: Date
    private var book: LedgerBook { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $filter) {
                ForEach(LedgerMemoFilter.allCases) { Text($0.title(language)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Button { LedgerPresenter.shared.isPresented = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wonsign.circle.fill").foregroundStyle(Color.tpAccent)
                    Text(summary).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").foregroundStyle(Color.tpSecondary)
                }
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold))
                .foregroundStyle(Color.tpInk)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .mapHomeGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("memo-ledger-open")
        }
        .task { await book.load() }
    }

    private var summary: String {
        let today = LedgerBook.total(book.entries(on: day), .expense)
        let month = LedgerBook.total(book.entries(inMonth: LedgerBook.monthKey(day)), .expense)
        return language.text(
            "그날 \(LedgerMoney.text(today, language: language)) · 이 달 \(LedgerMoney.text(month, language: language))",
            "Day \(LedgerMoney.text(today, language: language)) · Month \(LedgerMoney.text(month, language: language))"
        )
    }
}

/// 「지출」로 거르면 그날 가계부 기록을 메모 카드처럼 보인다. 누르면 가계부가 열린다.
struct LedgerDayCards: View {
    let language: MapHomeLanguage
    let day: Date
    private var book: LedgerBook { .shared }

    var body: some View {
        let entries = book.entries(on: day).sorted { $0.occurredAt < $1.occurredAt }
        if entries.isEmpty {
            Text(language.text("그날 지출이 없어요. 메모에 「커피 4500」처럼 쓰면 들어가요.", "No spending that day. Write a memo like \"Coffee 4500\" to add one."))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium))
                .foregroundStyle(Color.tpSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .mapHomeGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        ForEach(entries) { entry in
            Button { LedgerPresenter.shared.isPresented = true } label: {
                LedgerRow(entry: entry, language: language)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .mapHomeGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }
}

extension MapHomeView {
    /// 「메모」로 거르면 가계부에 이어진 메모는 뺀다.
    var panelMemos: [ActionMemo] {
        memoLedgerFilter == .memos ? queuedMemos.filter { LedgerBook.shared.entry(forMemo: $0.id) == nil } : queuedMemos
    }

    /// 가계부에 이어진 메모 카드의 금액 표시.
    func memoLedgerBadge(_ memo: ActionMemo) -> String? {
        guard let entry = LedgerBook.shared.entry(forMemo: memo.id) else { return nil }
        return (entry.kind == .expense ? "−" : "+") + LedgerMoney.text(entry.amount, currency: entry.currency, language: language)
    }
}
