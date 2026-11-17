import SwiftUI
import TaptionTripShare

// 지출 폼의 공개 범위 고르기(TSH1114A26 묶음 C).
// - 「공동」은 방에 올라 정산에 들어가고(낸 사람·나눌 사람을 고른다), 「내 것」은 일행에게 보일지만 고른다.
// - 공유하지 않는 여행에서는 아무것도 그리지 않는다. 수입에는 범위가 없다(이 기기에만).
// - 새 지출의 처음 값은 `TripShareLedger.defaultScope`(여행 기본값 「내 지출 전부 공유」), 있던 지출은 지금 놓인 범위다.

/// 지출 폼의 공개 범위 고르기. 저장·지움이 실패하면 그 까닭도 여기서 알린다.
struct TripShareExpenseScopePicker: View {
    let language: MapHomeLanguage
    let tripID: String
    let entry: LedgerEntry
    let isNew: Bool
    @Binding var scope: TripShareExpenseScope
    @Binding var payer: String?
    @Binding var shareNames: [String]?
    @Binding var failure: TripShareLedger.Failure?

    @State private var hasLoaded = false
    private var store: TripShareStore { .shared }

    var body: some View {
        if store.isShared(tripID) {
            let view = store.view(tripID: tripID)
            if entry.kind == .expense {
                Section {
                    Picker(language.text("누구 지출", "Whose expense"), selection: Binding(get: { scope == .shared }, set: { scope = $0 ? .shared : .ownHidden })) {
                        Text(language.text("공동", "Shared")).tag(true)
                        Text(language.text("내 것", "Mine")).tag(false)
                    }
                    .pickerStyle(.segmented)
                    .disabled(view?.closed == true && scope != .shared)
                    .accessibilityIdentifier("tripShareExpenseScope")
                    if scope != .shared {
                        Toggle(language.text("일행에게 보이기", "Show to the group"), isOn: Binding(get: { scope == .ownOpen }, set: { scope = $0 ? .ownOpen : .ownHidden }))
                            .accessibilityIdentifier("tripShareExpenseOpen")
                    }
                } header: {
                    Text(language.text("함께 쓰는 여행", "Shared trip"))
                } footer: {
                    Text(footer(closed: view?.closed == true, canWrite: view?.canWrite == true))
                }
                .task {
                    // 가계부만 열었을 때도 방을 열어 지금 범위를 읽는다. 한 번만 한다(고른 값을 덮지 않게).
                    guard !hasLoaded else { return }
                    TripShareLedger.pendingScopeForms.insert(entry.id)
                    defer { TripShareLedger.pendingScopeForms.remove(entry.id) }
                    await TripShareLedger.open(tripID: tripID)
                    guard !hasLoaded else { return }
                    hasLoaded = true
                    scope = isNew ? TripShareLedger.defaultScope(for: entry) : TripShareLedger.scope(of: entry)
                }
                .alert(failure?.message(language) ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                    Button(language.text("확인", "OK")) { failure = nil }
                }
                if scope == .shared {
                    LedgerShareSection(language: language, members: store.names(tripID: tripID)?.others ?? [], payer: $payer, shareNames: $shareNames)
                }
            }
        }
    }

    private func footer(closed: Bool, canWrite: Bool) -> String {
        if !canWrite, scope != .ownHidden { return TripShareText.viewOnly(language) }
        if closed { return language.text("정산을 마감해서 공동 지출은 넣거나 바꿀 수 없어요.", "Settlement is closed, so shared expenses can't be added or changed.") }
        switch scope {
        case .shared: return language.text("일행 모두에게 보이고 정산에 들어가요.", "Everyone in the group sees it and it counts in settling up.")
        case .ownOpen: return language.text("일행에게 보이지만 정산에는 들어가지 않아요.", "The group can see it, but it isn't part of settling up.")
        case .ownHidden: return language.text("이 기기에만 남아요. 일행에게 보이지 않아요.", "Stays on this device. The group can't see it.")
        }
    }
}
