import SwiftUI
import TaptionTripShare

// 공유 정산(TSH1114A26 묶음 C).
// - 계산은 패키지의 `ShareSettlementCalculator.settle`만 쓴다(참여자 번호 순·항목 id 순이라 모든 기기에서 같다).
//   넣는 것은 방의 공유 지출뿐이고, 원화 환산(`amountKRW`)이 있으면 그 값으로 센다. 나눌 사람이 비면 낸 사람 혼자다.
//   기존 `LedgerTripMath.sheet`는 내 기준이라 여기에 쓰지 않는다.
// - 「보냄」 표시는 보낸 사람의 카드(`sent`)에 있고 마감 뒤에도 고칠 수 있다. 마감·다시 열기는 주인만 한다.
// - 공유 예산은 방(`meta.budget`)에만 있다. 내 여행 장부의 예산과 따로다.

/// 공유 정산에 보일 값. 방 사본에서만 만든다.
struct TripShareSettlementSummary: Equatable, Sendable {
    var settlements: [ShareSettlement]
    /// 누군가 「보냄」으로 표시한 송금(`ShareTransfer.key`).
    var sent: Set<String>
    /// 공유 예산(원). 없으면 nil.
    var budget: Int?
    /// 공동으로 쓴 돈(원화로 센 것만).
    var spentKRW: Int
    var isOff: Bool
    var closed: Bool

    init(view: ShareRoomView, names: TripShareNames) {
        let entries = view.items(of: .expenseShared).compactMap { item -> ShareSettlementEntry? in
            guard case .sharedExpense(let expense) = item.content else { return nil }
            return ShareSettlementEntry(id: item.id, expense: expense)
        }
        isOff = view.meta?.settlementOff == true
        settlements = ShareSettlementCalculator.settle(entries, parties: names.parties)
        sent = Set(view.cards.values.flatMap { $0.sent ?? [] })
        budget = view.meta?.budget
        spentKRW = settlements.first { $0.currency == ShareSettlementCalculator.baseCurrency }?.balances.reduce(0) { $0 + $1.paid } ?? 0
        closed = view.closed
    }

    var transfers: [ShareTransfer] { settlements.flatMap(\.transfers) }
}

@MainActor
enum TripShareSettlement {
    /// 내가 보낼 송금의 「보냄」 표시를 켜거나 끈다. 내 카드에 적으므로 마감 뒤에도 된다. 지금 정산에 없는 옛 표시는 함께 걷어 낸다.
    @discardableResult
    static func setSent(_ transfer: ShareTransfer, sent: Bool, tripID: String) async -> TripShareLedger.Failure? {
        let store = TripShareStore.shared
        guard let room = await TripShareLedger.open(tripID: tripID), room.view.canWrite, let names = store.names(tripID: tripID),
              transfer.from == .member(room.view.me), var card = room.view.cards[room.view.me] else { return .viewOnly }
        let live = Set(TripShareSettlementSummary(view: room.view, names: names).transfers.map(\.key))
        var keys = Set(card.sent ?? []).intersection(live)
        if sent { keys.insert(transfer.key) } else { keys.remove(transfer.key) }
        card.sent = keys.isEmpty ? nil : keys.sorted()
        do {
            guard try await room.session.publish(card: card) == .done else { return .conflict }
        } catch { return TripShareLedger.failure(error) }
        await store.refresh(tripID: tripID)
        return nil
    }

    /// 정산 마감(true)·다시 열기(false). 주인만.
    @discardableResult
    static func setClosed(_ closed: Bool, tripID: String) async -> TripShareLedger.Failure? {
        guard let room = await TripShareLedger.open(tripID: tripID), room.view.canWrite, room.view.isOwner else { return .viewOnly }
        do { try await room.session.setSettlementClosed(closed) } catch { return TripShareLedger.failure(error) }
        await TripShareStore.shared.refresh(tripID: tripID)
        return nil
    }
}

/// 공유 정산: 공유 예산·송금 목록·「보냄」 체크·주인의 마감/다시 열기.
struct TripShareSettlementSection: View {
    @Bindable var model: AppModel
    let language: MapHomeLanguage
    let tripID: String

    @State private var failure: TripShareLedger.Failure?
    @State private var isEditingBudget = false
    @State private var budgetText = ""

    private var store: TripShareStore { .shared }

    var body: some View {
        if store.isShared(tripID), let view = store.view(tripID: tripID), let names = store.names(tripID: tripID) {
            let summary = TripShareSettlementSummary(view: view, names: names)
            Section {
                LabeledContent(language.text("공유 예산", "Shared budget"), value: summary.budget.map { money($0) } ?? language.text("없음", "None"))
                LabeledContent(language.text("공동으로 쓴 돈", "Spent together"), value: money(summary.spentKRW))
                if let budget = summary.budget {
                    LabeledContent(language.text("남은 공유 예산", "Shared budget left"), value: money(budget - summary.spentKRW))
                }
                if view.isOwner {
                    Button(language.text("공유 예산 고치기", "Edit shared budget")) {
                        budgetText = summary.budget.map(String.init) ?? ""
                        isEditingBudget = true
                    }
                    .disabled(!view.canWrite)
                }
            } header: {
                Text(language.text("공유 예산", "Shared budget"))
            } footer: {
                Text(language.text("일행이 함께 보는 예산이에요. 내 여행 장부의 예산과는 따로예요.", "A budget the whole group sees. It's separate from your own trip ledger budget."))
            }
            .alert(language.text("공유 예산(원)", "Shared budget (KRW)"), isPresented: $isEditingBudget) {
                TextField(language.text("비우면 없음", "Blank = none"), text: $budgetText).keyboardType(.numberPad)
                Button(language.text("취소", "Cancel"), role: .cancel) {}
                Button(language.text("저장", "Save")) {
                    let budget = LedgerNumber.parse(budgetText).map(TripShareMapping.clampedWhole)
                    Task { failure = await TripShareLedger.setSharedBudget(budget, tripID: tripID) }
                }
            }
            Section {
                if summary.isOff {
                    Text(language.text("정산하지 않는 여행이에요.", "This trip doesn't settle up.")).foregroundStyle(.secondary)
                } else if summary.transfers.isEmpty {
                    Text(language.text("주고받을 돈이 없어요.", "Nothing to settle.")).foregroundStyle(.secondary)
                } else {
                    ForEach(summary.transfers, id: \.key) { transfer in
                        transferRow(transfer, isSent: summary.sent.contains(transfer.key), me: view.me, names: names, canWrite: view.canWrite)
                    }
                }
                if summary.closed {
                    Label(language.text("정산을 마감했어요. 공동 지출은 더 바꿀 수 없어요.", "Settlement is closed. Shared expenses can't be changed anymore."), systemImage: "lock.fill")
                        .foregroundStyle(.secondary)
                }
                if view.isOwner, !summary.isOff {
                    Button(summary.closed ? language.text("정산 다시 열기", "Reopen settlement") : language.text("정산 마감", "Close settlement")) {
                        Task { failure = await TripShareSettlement.setClosed(!summary.closed, tripID: tripID) }
                    }
                    .disabled(!view.canWrite)
                    .accessibilityIdentifier("tripShareSettlementClose")
                }
            } header: {
                Text(language.text("공유 정산", "Group settlement"))
            } footer: {
                Text(language.text("공동 지출만 계산해요. 모두의 화면에 같은 결과가 보여요.", "Only shared expenses are counted. Everyone sees the same result."))
            }
            .alert(failure?.message(language) ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button(language.text("확인", "OK")) { failure = nil }
            }
        }
    }

    private func money(_ amount: Int, currency: String = ShareSettlementCalculator.baseCurrency) -> String {
        LedgerMoney.text(TripShareMapping.amount(minorUnits: amount, currency: currency), currency: currency, language: language)
    }

    @ViewBuilder
    private func transferRow(_ transfer: ShareTransfer, isSent: Bool, me: Int, names: TripShareNames, canWrite: Bool) -> some View {
        let from = names.name(transfer.from), to = names.name(transfer.to)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(from) → \(to)")
                Text(money(transfer.amount, currency: transfer.currency)).font(.taptionStyle(.caption)).foregroundStyle(.secondary)
            }
            Spacer()
            if transfer.from == .member(me) {
                Button {
                    Task { failure = await TripShareSettlement.setSent(transfer, sent: !isSent, tripID: tripID) }
                } label: {
                    Label(language.text("보냄", "Sent"), systemImage: isSent ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(.borderless)
                .disabled(!canWrite)
            } else if isSent {
                Label(language.text("보냄", "Sent"), systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
            }
        }
    }
}

/// 여행 장부에 보이는 일행의 공개한 개인 지출. 방 사본에서만 읽고 내 가계부에는 넣지 않는다.
struct TripShareOpenExpensesSection: View {
    let language: MapHomeLanguage
    let tripID: String

    var body: some View {
        let store = TripShareStore.shared
        if store.isShared(tripID), let view = store.view(tripID: tripID), let names = store.names(tripID: tripID) {
            let expenses = TripShareLedger.openExpenses(of: view, names: names)
            if !expenses.isEmpty {
                Section {
                    ForEach(expenses) { expense in
                        LabeledContent {
                            Text(LedgerMoney.text(expense.amount, currency: expense.currency, language: language))
                        } label: {
                            Text(verbatim: expense.title.isEmpty ? expense.name : "\(expense.name) · \(expense.title)")
                            Text(expense.at.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                } header: {
                    Text(language.text("일행이 공개한 개인 지출", "Personal spending the group shared"))
                } footer: {
                    Text(language.text("보기만 해요. 정산과 내 가계부에는 들어가지 않아요.", "View only. Not part of settling up or your own ledger."))
                }
            }
        }
    }
}
