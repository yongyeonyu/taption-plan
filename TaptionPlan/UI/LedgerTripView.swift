import ContactsUI
import SwiftUI

/// 여행 장부(LED1111A05). 일상에서 받은 예산 안에서 쓴 돈과, 맨 아래 내 기준 대차대조·정산.
struct LedgerTripView: View {
    let tripID: String
    let language: MapHomeLanguage
    @State private var isAdding = false
    @State private var isEditingTrip = false
    @State private var editing: LedgerEntry?
    @State private var hasLoaded = false
    @Environment(\.dismiss) private var dismissView
    private var book: LedgerBook { .shared }

    var body: some View {
        if let trip = book.trip(tripID) {
            let entries = book.tripEntries(tripID).sorted { $0.occurredAt < $1.occurredAt }
            let sheet = LedgerTripMath.sheet(trip, entries: book.entries)
            List {
            Group {
                Section {
                    LabeledContent(language.text("기간", "Dates"), value: "\(trip.start.formatted(date: .abbreviated, time: .omitted)) – \(trip.end.formatted(date: .abbreviated, time: .omitted))")
                    LabeledContent(language.text("예산", "Budget"), value: trip.budgetKRW.map { LedgerMoney.text($0, language: language) } ?? language.text("없음", "None"))
                    LabeledContent(language.text("함께 간 사람", "With"), value: trip.members.isEmpty ? language.text("나 혼자", "Just me") : trip.members.joined(separator: ", "))
                    Button(language.text("여행 장부 고치기", "Edit trip ledger")) { isEditingTrip = true }
                }
                Section(language.text("기록", "Entries")) {
                    if entries.isEmpty {
                        Text(language.text("+ 로 여행 중 쓴 돈을 넣어요. 다 같이 쓴 돈은 n분의 1로 나눠요.", "Tap + to add trip spending. Money spent by everyone is split evenly."))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(entries) { entry in
                        Button { editing = entry } label: { LedgerTripRow(entry: entry, trip: trip, language: language) }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button(language.text("지우기", "Delete"), role: .destructive) { Task { await book.remove(entry) } }
                            }
                    }
                }
                LedgerTripSheetSection(trip: trip, sheet: sheet, language: language)
            }
            .listRowBackground(Color.tpSurface)
        }
        .tpListStyle()
            .font(.taptionStyle(.subheadline))
            .refreshable { await AssistantCommandRefresh.now(language: language, manual: true) }
            .navigationTitle(trip.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { isAdding = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel(language.text("여행 기록 더하기", "Add trip entry"))
                }
            }
            .task { await book.syncTrip(tripID) }
            .sheet(isPresented: $isAdding) {
                LedgerEntryForm(language: language, entry: LedgerEntry(occurredAt: .now, amount: 0, title: "", tripID: tripID), members: trip.members)
            }
            .sheet(item: $editing) { entry in LedgerEntryForm(language: language, entry: entry, isNew: false, members: trip.members) }
            .sheet(isPresented: $isEditingTrip) {
                LedgerTripForm(language: language, trip: trip, onDelete: {
                    Task { await book.deleteTrip(trip.id); dismissView() }
                }) { updated in Task { await book.saveTrip(updated) } }
            }
        } else if hasLoaded {
            // 지웠거나 없는 여행 장부: 끝없이 기다리지 않고 알린다(리뷰).
            Text(language.text("이 여행 장부가 없어요. 가계부의 「여행 장부」에서 만들 수 있어요.", "This trip ledger doesn't exist. You can create one under Trip ledgers."))
                .foregroundStyle(.secondary).padding()
        } else {
            ProgressView().task { await book.load(); hasLoaded = true }
        }
    }
}

struct LedgerTripRow: View {
    let entry: LedgerEntry
    let trip: LedgerTrip
    let language: MapHomeLanguage

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.transfer != nil ? "arrow.left.arrow.right.circle" : entry.category.symbol)
                .frame(width: 24).foregroundStyle(Color.tpAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).lineLimit(1)
                Text(detail).font(.taptionStyle(.caption)).foregroundStyle(.secondary)
            }
            Spacer()
            Text((entry.kind == .expense ? "−" : "+") + LedgerMoney.text(entry.amount, currency: entry.currency, language: language))
                .foregroundStyle(entry.kind == .expense ? Color.primary : Color.green)
        }
    }

    private var detail: String {
        let time = entry.occurredAt.formatted(date: .abbreviated, time: .shortened)
        guard entry.transfer == nil, entry.kind == .expense else { return time }
        let payer = LedgerName.display(entry.payer ?? LedgerTrip.me, language)
        let share: String = {
            guard let names = entry.shareNames else { return language.text("다 같이", "Everyone") }
            if names == [LedgerTrip.me] { return language.text("나만", "Only me") }
            return names.map { LedgerName.display($0, language) }.joined(separator: "·")
        }()
        return language.text("\(time) · \(payer) 냄 · \(share)", "\(time) · \(payer) paid · \(share)")
    }
}

enum LedgerName {
    static func display(_ name: String, _ language: MapHomeLanguage) -> String {
        name == LedgerTrip.me ? language.text("나", "Me") : name
    }
}

/// 맨 아래 내 기준 대차대조와 정산(대표 결정: 「A에게 줄 돈 −3만」「B에게 받을 돈 +2만」).
struct LedgerTripSheetSection: View {
    let trip: LedgerTrip
    let sheet: LedgerTripSheet
    let language: MapHomeLanguage

    var body: some View {
        Section {
            line(language.text("일상에서 받은 예산", "Budget from daily"), sheet.budget)
            if sheet.otherIncome > 0 { line(language.text("그 밖의 수입", "Other income"), sheet.otherIncome) }
            line(language.text("내가 낸 돈", "I paid"), -sheet.myPaid)
            line(language.text("지금 남은 돈", "Cash left now"), sheet.cashLeft, bold: true)
            if sheet.receivedFromOthers > 0 { line(language.text("친구에게 미리 받은 돈", "Collected from friends"), sheet.receivedFromOthers) }
            line(language.text("다 같이 쓴 돈", "Spent together"), sheet.sharedTotal, signed: false)
            line(language.text("내 몫", "My share"), sheet.myCost, signed: false)
        } header: {
            Text(language.text("대차대조", "Balance"))
        }
        Section {
            if sheet.mine.isEmpty {
                Text(language.text("주고받을 돈이 없어요.", "Nothing to settle.")).foregroundStyle(.secondary)
            }
            ForEach(Array(sheet.mine.enumerated()), id: \.offset) { _, transfer in
                if transfer.to == LedgerTrip.me {
                    line(language.text("\(transfer.from)에게 받을 돈", "From \(transfer.from)"), transfer.amountKRW)
                } else {
                    line(language.text("\(transfer.to)에게 줄 돈", "To \(transfer.to)"), -transfer.amountKRW)
                }
            }
            line(sheet.leftover >= 0 ? language.text("정산 뒤 일상으로 돌아갈 돈", "Back to daily after settling") : language.text("일상에서 더 보낼 돈", "More from daily"),
                 sheet.leftover, bold: true)
            ForEach(Array(sheet.transfers.filter { $0.from != LedgerTrip.me && $0.to != LedgerTrip.me }.enumerated()), id: \.offset) { _, transfer in
                Text(language.text("\(transfer.from) → \(transfer.to) \(LedgerMoney.text(transfer.amountKRW, language: language))", "\(transfer.from) → \(transfer.to) \(LedgerMoney.text(transfer.amountKRW, language: language))"))
                    .font(.taptionStyle(.caption)).foregroundStyle(.secondary)
            }
        } header: {
            Text(language.text("정산(내 기준)", "Settle up (for me)"))
        } footer: {
            Text(language.text("여행이 끝난 다음 날 남은 돈은 일상으로 돌아가고, 모자라면 일상에서 더 보내요.", "The day after the trip, leftovers go back to daily; a shortfall is topped up from daily."))
        }
    }

    private func line(_ title: String, _ amount: Double, bold: Bool = false, signed: Bool = true) -> some View {
        LabeledContent {
            Text((signed && amount > 0 ? "+" : "") + LedgerMoney.text(amount, language: language))
                .fontWeight(bold ? .bold : .regular)
                .foregroundStyle(signed && amount < 0 ? Color.red : (signed && amount > 0 ? Color.green : Color.primary))
        } label: {
            Text(title).fontWeight(bold ? .bold : .regular)
        }
    }
}

/// 여행 수입이 누구에게 받은 돈인지(총무일 때 친구에게 미리 받은 돈). 나면 내 다른 수입(환불 등)이다.
struct LedgerIncomeFromSection: View {
    let language: MapHomeLanguage
    let members: [String]
    @Binding var payer: String?

    var body: some View {
        Section {
            Picker(language.text("누구에게 받은 돈", "Received from"), selection: Binding(get: { payer ?? LedgerTrip.me }, set: { payer = $0 == LedgerTrip.me ? nil : $0 })) {
                Text(language.text("내 수입(환불 등)", "My income (refund etc.)")).tag(LedgerTrip.me)
                ForEach(members, id: \.self) { Text($0).tag($0) }
            }
        } footer: {
            Text(language.text("총무라서 친구에게 미리 받은 돈이면 그 사람을 고르세요. 정산에서 그 사람이 낸 돈으로 쳐요.", "If you collected it from a friend as the organizer, pick them. It counts as what they paid when settling."))
        }
    }
}

/// 여행 지출의 「낸 사람」과 「누구 몫」(대표 결정: 공금 없이 「다 같이」는 n분의 1).
struct LedgerShareSection: View {
    let language: MapHomeLanguage
    let members: [String]
    @Binding var payer: String?
    @Binding var shareNames: [String]?

    private enum Mode: Hashable { case me, everyone, pick }

    private var mode: Mode {
        guard let names = shareNames else { return .everyone }
        return names == [LedgerTrip.me] ? .me : .pick
    }

    var body: some View {
        Section {
            Picker(language.text("낸 사람", "Paid by"), selection: Binding(get: { payer ?? LedgerTrip.me }, set: { payer = $0 == LedgerTrip.me ? nil : $0 })) {
                ForEach([LedgerTrip.me] + members, id: \.self) { Text(LedgerName.display($0, language)).tag($0) }
            }
            Picker(language.text("누구 몫", "For whom"), selection: Binding(get: { mode }, set: { next in
                switch next {
                case .me: shareNames = [LedgerTrip.me]
                case .everyone: shareNames = nil
                case .pick: shareNames = [LedgerTrip.me] + members
                }
            })) {
                Text(language.text("나만", "Only me")).tag(Mode.me)
                Text(language.text("다 같이", "Everyone")).tag(Mode.everyone)
                Text(language.text("골라서", "Pick")).tag(Mode.pick)
            }
            .pickerStyle(.segmented)
            if mode == .pick {
                ForEach([LedgerTrip.me] + members, id: \.self) { name in
                    Toggle(LedgerName.display(name, language), isOn: Binding(
                        get: { shareNames?.contains(name) ?? true },
                        set: { on in
                            var names = shareNames ?? ([LedgerTrip.me] + members)
                            if on { if !names.contains(name) { names.append(name) } } else { names.removeAll { $0 == name } }
                            shareNames = names.isEmpty ? [LedgerTrip.me] : names
                        }
                    ))
                }
            }
        } header: {
            Text(language.text("나누기", "Split"))
        } footer: {
            Text(language.text("「다 같이」는 n분의 1로 나눠요. 친구가 낸 돈도 넣으면 정산에 들어가요.", "\"Everyone\" splits evenly. Add what friends paid too so settling is right."))
        }
    }
}

/// 여행 장부 만들기·고치기: 이름·기간·예산·함께 간 사람.
struct LedgerTripForm: View {
    let language: MapHomeLanguage
    @State var trip: LedgerTrip
    /// 있으면 「여행 장부 지우기」를 보인다(고칠 때만).
    var onDelete: (() -> Void)? = nil
    let onSave: (LedgerTrip) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var budgetText = ""
    @State private var newMember = ""
    @State private var isPickingContact = false

    @State private var isConfirmingDelete = false

    init(language: MapHomeLanguage, trip: LedgerTrip, onDelete: (() -> Void)? = nil, onSave: @escaping (LedgerTrip) -> Void) {
        self.language = language
        _trip = State(initialValue: trip)
        self.onDelete = onDelete
        self.onSave = onSave
        _budgetText = State(initialValue: trip.budgetKRW.map { LedgerEntryForm.plain($0) } ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
            Group {
                Section {
                    TextField(language.text("이름 (예: 대구 여행)", "Name (e.g. Daegu trip)"), text: $trip.name)
                    DatePicker(language.text("시작", "Start"), selection: $trip.start, displayedComponents: .date)
                    DatePicker(language.text("끝", "End"), selection: $trip.end, in: trip.start..., displayedComponents: .date)
                    TextField(language.text("예산(원, 비우면 없음)", "Budget (KRW, blank = none)"), text: $budgetText).keyboardType(.numberPad)
                } footer: {
                    Text(language.text("예산은 일상 가계부에서 「여행 경비」로 나가요.", "The budget leaves the daily ledger as a trip expense."))
                }
                Section(language.text("함께 간 사람", "Travelling with")) {
                    ForEach(trip.members, id: \.self) { Text($0) }
                        .onDelete { trip.members.remove(atOffsets: $0) }
                    HStack {
                        TextField(language.text("이름 넣기", "Add a name"), text: $newMember)
                        Button(language.text("넣기", "Add")) { addMember(newMember) }
                            .disabled(newMember.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Button(language.text("연락처에서 고르기", "Pick from Contacts")) { isPickingContact = true }
                }
                if onDelete != nil {
                    Section {
                        Button(language.text("여행 장부 지우기", "Delete trip ledger"), role: .destructive) { isConfirmingDelete = true }
                    } footer: {
                        Text(language.text("예산 이체와 정산은 지우고, 여행 중 기록은 일상 가계부로 옮겨요.", "Budget transfers and settlement are removed; trip entries move to the daily ledger."))
                    }
                }
            }
            .listRowBackground(Color.tpSurface)
        }
        .tpListStyle()
            .font(.taptionStyle(.subheadline))
            .navigationTitle(language.text("여행 장부", "Trip ledger"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(language.text("취소", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.text("저장", "Save")) {
                        trip.name = trip.name.trimmingCharacters(in: .whitespaces)
                        trip.budgetKRW = LedgerNumber.parse(budgetText).flatMap { $0 > 0 ? $0 : nil }
                        onSave(trip)
                        dismiss()
                    }
                    .disabled(trip.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .sheet(isPresented: $isPickingContact) { LedgerContactPicker { names in names.forEach(addMember) } }
            .confirmationDialog(language.text("여행 장부를 지울까요?", "Delete this trip ledger?"), isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                Button(language.text("지우기", "Delete"), role: .destructive) {
                    dismiss()
                    onDelete?()
                }
            }
        }
    }

    private func addMember(_ raw: String) {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != LedgerTrip.me, !trip.members.contains(name) else { return }
        trip.members.append(String(name.prefix(30)))
        newMember = ""
    }
}

/// 시스템 연락처 고르기. 고른 사람의 이름만 받는다(연락처 권한을 묻지 않는다).
struct LedgerContactPicker: UIViewControllerRepresentable {
    let onPick: ([String]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        picker.displayedPropertyKeys = [CNContactGivenNameKey, CNContactFamilyNameKey]
        return picker
    }

    func updateUIViewController(_ controller: CNContactPickerViewController, context: Context) {}

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let onPick: ([String]) -> Void
        init(onPick: @escaping ([String]) -> Void) { self.onPick = onPick }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contacts: [CNContact]) {
            onPick(contacts.compactMap { contact in
                let name = CNContactFormatter.string(from: contact, style: .fullName) ?? contact.givenName
                return name.isEmpty ? nil : name
            })
        }
    }
}
