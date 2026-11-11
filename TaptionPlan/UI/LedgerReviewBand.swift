import SwiftUI

/// 메모 패널 「지출」 탭 위의 「확인 필요」 띠(LRV1111A01). 누르면 목록이 열려 하나씩 넣거나 버린다.
struct LedgerReviewBand: View {
    let language: MapHomeLanguage
    @State private var isPresented = false
    private var store: LedgerReviewStore { .shared }

    var body: some View {
        if !store.items.isEmpty {
            Button { isPresented = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    Text(language.text("확인 필요 \(store.items.count)건", "\(store.items.count) to review")).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").foregroundStyle(Color.tpSecondary)
                }
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium))
                .foregroundStyle(Color.tpInk)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .mapHomeGlass(in: RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ledger-review-band")
            .sheet(isPresented: $isPresented) { LedgerReviewSheet(language: language) }
        }
    }
}

struct LedgerReviewSheet: View {
    let language: MapHomeLanguage
    @Environment(\.dismiss) private var dismiss
    private var store: LedgerReviewStore { .shared }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.items) { item in row(item) }
                } footer: {
                    Text(language.text(
                        "가게 이름을 읽지 못했거나, 방금 같은 금액의 결제가 있었거나, 이체로 보이는 결제예요. 넣기 전에는 합계에 들어가지 않아요.",
                        "These had no shop name, matched a payment just added, or look like a transfer. They don't count until you add them."
                    ))
                }
            }
            .tpListStyle()
            .font(.taptionStyle(.subheadline))
            .navigationTitle(language.text("확인 필요", "Needs review"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(language.text("완료", "Done")) { dismiss() } } }
            .onChange(of: store.items.isEmpty) { _, isEmpty in if isEmpty { dismiss() } }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ item: LedgerReviewStore.Item) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.entry.title).font(.taptionStyle(.subheadline, weight: .medium))
                Spacer(minLength: 8)
                Text(LedgerMoney.text(item.entry.amount, currency: item.entry.currency, language: language))
                    .font(.taptionStyle(.subheadline, weight: .semibold))
            }
            Text("\(item.entry.occurredAt.formatted(date: .abbreviated, time: .shortened)) · \(reasonText(item.reason))")
                .font(.taptionStyle(.footnote))
                .foregroundStyle(Color.tpSecondary)
            HStack(spacing: 10) {
                Button(language.text("가계부에 넣기", "Add to ledger")) { Task { await store.accept(item.id) } }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.tpAccent)
                Button(language.text("버리기", "Discard"), role: .destructive) { store.remove(item.id) }
                    .buttonStyle(.bordered)
            }
            .font(.taptionStyle(.footnote, weight: .semibold))
            .controlSize(.small)
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.tpSurface)
    }

    private func reasonText(_ reason: LedgerReviewStore.Reason) -> String {
        switch reason {
        case .noMerchant: language.text("가게 이름 없음", "No shop name")
        case .duplicate: language.text("같은 금액이 방금 있었음", "Same amount just added")
        case .transfer: language.text("이체로 보임", "Looks like a transfer")
        }
    }
}

/// 내 계좌 이름 등록(LIN1111A01). 이 이름이 든 이체·출금 문자는 지출로 넣지 않는다. 기기에만 둔다.
struct LedgerOwnAccountsSheet: View {
    let language: MapHomeLanguage
    @Environment(\.dismiss) private var dismiss
    @State private var names = LedgerOwnAccounts.names()
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(names, id: \.self) { Text($0) }
                        .onDelete { offsets in
                            names.remove(atOffsets: offsets)
                            LedgerOwnAccounts.set(names)
                        }
                    HStack {
                        TextField(language.text("예: 토스통장, 홍길동", "e.g. Toss account, my name"), text: $draft)
                            .submitLabel(.done)
                            .onSubmit(add)
                        Button(language.text("더하기", "Add"), action: add)
                            .disabled(draft.trimmingCharacters(in: .whitespaces).count < 2)
                    }
                } footer: {
                    Text(language.text(
                        "이체·출금 문자에 이 이름이 들어 있으면 내 계좌로 옮긴 돈으로 보고 지출에 넣지 않아요. 이름은 이 기기에만 둬요.",
                        "If a transfer or withdrawal text contains one of these names, it's treated as moving money to your own account and isn't added as spending. Names stay on this device."
                    ))
                }
                .listRowBackground(Color.tpSurface)
            }
            .tpListStyle()
            .font(.taptionStyle(.subheadline))
            .navigationTitle(language.text("내 계좌 이름", "My account names"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(language.text("완료", "Done")) { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func add() {
        let name = draft.trimmingCharacters(in: .whitespaces)
        guard name.count >= 2 else { return }
        LedgerOwnAccounts.set(names + [name])
        names = LedgerOwnAccounts.names()
        draft = ""
    }
}
