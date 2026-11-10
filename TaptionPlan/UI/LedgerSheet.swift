import PhotosUI
import SwiftUI

/// 가계부 화면(LED1110A01). 왼쪽 위 `₩` 버튼으로 연다. 달마다 지출·수입·예산과 오늘 손익, 날짜별 목록.
struct LedgerSheet: View {
    let language: MapHomeLanguage
    /// 여행 모드에서 열면 그 여행에 붙여 넣는다.
    var tripID: String?

    @Environment(\.dismiss) private var dismiss
    @State private var month = LedgerBook.monthKey(.now)
    @State private var editing: LedgerEntry?
    @State private var isAdding = false
    @State private var isEditingBudget = false
    @State private var isSettling = false
    @State private var draft: LedgerEntry?
    @State private var receiptItem: PhotosPickerItem?
    @State private var captureNote: String?
    private var book: LedgerBook { .shared }

    var body: some View {
        NavigationStack {
            List {
                summarySection
                if tripID != nil { tripSection }
                captureSection
                ForEach(days, id: \.self) { day in
                    Section(day.formatted(date: .abbreviated, time: .omitted)) {
                        ForEach(book.entries(on: day).filter { LedgerBook.monthKey($0.occurredAt) == month }) { entry in
                            Button { editing = entry } label: { LedgerRow(entry: entry, language: language) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                if days.isEmpty {
                    Text(language.text("이 달에는 기록이 없어요. + 로 더해 보세요.", "No entries this month. Tap + to add one."))
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(language.text("가계부", "Ledger"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(language.text("닫기", "Close")) { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        Button(language.text("이 달 예산", "Monthly budget")) { isEditingBudget = true }
                        Button(language.text("정산하기", "Settle up")) { isSettling = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                    Button { isAdding = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel(language.text("기록 더하기", "Add entry"))
                }
            }
            .task {
                await book.load()
                await book.refreshRates()
                await book.fillMissingKRW()
            }
            .sheet(isPresented: $isAdding) {
                LedgerEntryForm(language: language, entry: LedgerEntry(occurredAt: .now, amount: 0, title: "", tripID: tripID))
            }
            .sheet(item: $editing) { entry in LedgerEntryForm(language: language, entry: entry, isNew: false) }
            .sheet(item: $draft) { entry in LedgerEntryForm(language: language, entry: entry) }
            .onChange(of: receiptItem) { _, item in
                guard let item else { return }
                Task { await readReceipt(item) }
            }
            .sheet(isPresented: $isEditingBudget) { LedgerBudgetForm(language: language, period: month) }
            .sheet(isPresented: $isSettling) {
                LedgerSettleView(language: language, entries: tripID.map { id in book.entries.filter { $0.tripID == id } } ?? book.entries(inMonth: month))
            }
        }
    }

    private var monthEntries: [LedgerEntry] { book.entries(inMonth: month) }

    /// 여행 정산(귀국 정산): 이 여행에 묶인 기록을 통화별로 더하고 원화 합계를 보인다.
    private var tripSection: some View {
        let trip = book.entries.filter { $0.tripID == tripID && $0.kind == .expense }
        let byCurrency = Dictionary(grouping: trip, by: \.currency).mapValues { $0.reduce(0) { $0 + $1.amount } }
        return Section(language.text("이 여행", "This trip")) {
            ForEach(byCurrency.keys.sorted(), id: \.self) { code in
                LabeledContent(code, value: LedgerMoney.text(byCurrency[code] ?? 0, currency: code, language: language))
            }
            LabeledContent(language.text("원화로 모두", "Total in KRW"), value: LedgerMoney.text(LedgerBook.total(trip, .expense), language: language))
            if trip.isEmpty {
                Text(language.text("여행 중에 넣은 기록이 여기 모여요.", "Entries added during this trip gather here.")).foregroundStyle(.secondary)
            }
        }
    }

    /// 결제 문자 붙여넣기와 영수증 사진. 읽은 값으로 입력 화면을 채우고, 저장은 확인한 뒤에만.
    private var captureSection: some View {
        Section {
            HStack {
                PasteButton(payloadType: String.self) { strings in
                    let text = strings.joined(separator: "\n")
                    Task { @MainActor in fill(LedgerMessageParser.parse(text), source: .message) }
                }
                .labelStyle(.titleAndIcon)
                Spacer()
                PhotosPicker(selection: $receiptItem, matching: .images) {
                    Label(language.text("영수증", "Receipt"), systemImage: "doc.text.viewfinder")
                }
            }
            .buttonStyle(.borderless)
        } footer: {
            Text(captureNote ?? language.text("카드 결제 문자를 복사해 붙여 넣거나 영수증 사진을 고르면 채워 드려요. 단축어 「결제 문자 넣기」로 문자가 오면 바로 넣을 수도 있어요.", "Paste a card payment text or pick a receipt photo to fill an entry. The Shortcuts action \"Add payment text\" can add texts as they arrive."))
        }
    }

    private func fill(_ parsed: LedgerMessageParser.Draft?, source: LedgerEntry.Source) {
        guard let parsed else {
            captureNote = language.text("읽지 못했어요. + 로 직접 넣어 주세요.", "Couldn't read it. Tap + to enter it yourself.")
            return
        }
        captureNote = nil
        var entry = LedgerMessageParser.entry(parsed, source: source)
        entry.tripID = tripID
        draft = entry
    }

    private func readReceipt(_ item: PhotosPickerItem) async {
        defer { receiptItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data)?.cgImage else { return fill(nil, source: .receipt) }
        fill(LedgerReceiptReader.draft(await LedgerReceiptReader.recognize(image)), source: .receipt)
    }

    private var days: [Date] {
        let calendar = Calendar.autoupdatingCurrent
        return Array(Set(monthEntries.map { calendar.startOfDay(for: $0.occurredAt) })).sorted(by: >)
    }

    private var summarySection: some View {
        let spent = LedgerBook.total(monthEntries, .expense)
        let earned = LedgerBook.total(monthEntries, .income)
        let budget = book.budget(for: month)
        let monthlyNet = MapHomeSalaryPolicy.monthlyNet(MapHomeSalaryPolicy.loadSettings())
        return Section {
            HStack {
                Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                Spacer()
                Text(monthTitle).font(.headline)
                Spacer()
                Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
            }
            .buttonStyle(.borderless)
            LabeledContent(language.text("지출", "Spent"), value: LedgerMoney.text(spent, language: language))
            LabeledContent(language.text("수입", "Income"), value: LedgerMoney.text(earned, language: language))
            if let budget {
                let left = budget.amountKRW - spent
                LabeledContent(language.text("예산 남음", "Budget left"), value: LedgerMoney.text(left, language: language))
                    .foregroundStyle(left < 0 ? Color.red : Color.primary)
                ProgressView(value: min(1, max(0, spent / max(1, budget.amountKRW))))
            }
            if month == LedgerBook.monthKey(.now), monthlyNet > 0 {
                let net = book.todayNet(monthlyNet: monthlyNet)
                LabeledContent(language.text("오늘 손익(세후 월급 기준)", "Today's net (after-tax pay)"), value: LedgerMoney.text(net, language: language))
                    .foregroundStyle(net < 0 ? Color.red : Color.green)
            }
        }
    }

    private var monthTitle: String {
        let parts = month.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return month }
        return language.text("\(parts[0])년 \(parts[1])월", "\(parts[1])/\(parts[0])")
    }

    private func shiftMonth(_ step: Int) {
        let calendar = Calendar.autoupdatingCurrent
        let parts = month.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, let start = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: 1)),
              let next = calendar.date(byAdding: .month, value: step, to: start) else { return }
        month = LedgerBook.monthKey(next)
    }
}

struct LedgerRow: View {
    let entry: LedgerEntry
    let language: MapHomeLanguage

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.category.symbol).frame(width: 24).foregroundStyle(Color.tpAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).lineLimit(1)
                Text([entry.category.title(language), entry.payer, sourceText].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text((entry.kind == .expense ? "−" : "+") + LedgerMoney.text(entry.amount, currency: entry.currency, language: language))
                    .foregroundStyle(entry.kind == .expense ? Color.primary : Color.green)
                if entry.currency != "KRW", let krw = entry.amountKRW {
                    Text(LedgerMoney.text(krw, language: language)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
    }

    private var sourceText: String? {
        switch entry.source {
        case .manual: nil
        case .assistant: language.text("AI가 넣음", "Added by AI")
        case .message: language.text("결제 문자", "Payment text")
        case .receipt: language.text("영수증", "Receipt")
        }
    }
}

/// 기록 하나 넣기·고치기.
struct LedgerEntryForm: View {
    let language: MapHomeLanguage
    @State var entry: LedgerEntry
    var isNew = true

    @Environment(\.dismiss) private var dismiss
    @State private var amountText = ""
    @State private var manualRateText = ""
    private var book: LedgerBook { .shared }
    static let currencies = ["KRW", "USD", "JPY", "EUR", "CNY", "TWD", "HKD", "THB", "VND", "SGD", "PHP", "IDR", "GBP", "AUD", "CAD"]

    init(language: MapHomeLanguage, entry: LedgerEntry, isNew: Bool = true) {
        self.language = language
        _entry = State(initialValue: entry)
        self.isNew = isNew
        _amountText = State(initialValue: entry.amount > 0 ? Self.plain(entry.amount) : "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(language.text("종류", "Type"), selection: $entry.kind) {
                        Text(language.text("지출", "Expense")).tag(LedgerEntry.Kind.expense)
                        Text(language.text("수입", "Income")).tag(LedgerEntry.Kind.income)
                    }
                    .pickerStyle(.segmented)
                    TextField(language.text("내용 (예: 커피)", "What (e.g. Coffee)"), text: $entry.title)
                        .onChange(of: entry.title) { _, title in
                            if isNew, entry.category == .other { entry.category = LedgerCategory.guess(title) }
                        }
                    HStack {
                        TextField(language.text("금액", "Amount"), text: $amountText).keyboardType(.decimalPad)
                        Picker("", selection: $entry.currency) { ForEach(Self.currencies, id: \.self) { Text($0).tag($0) } }
                            .labelsHidden()
                    }
                    if entry.currency != "KRW" {
                        let rate = LedgerFX.krwPerUnit(entry.currency, table: book.fx, manual: book.manualRates)
                        Text(rate.map { language.text("1 \(entry.currency) ≈ \(Int($0.rounded()))원", "1 \(entry.currency) ≈ ₩\(Int($0.rounded()))") }
                             ?? language.text("환율을 몰라요. 아래에 직접 넣어 주세요.", "Rate unknown. Enter it below."))
                            .font(.caption).foregroundStyle(.secondary)
                        TextField(language.text("직접 넣는 환율 (1단위 = 원)", "Manual rate (1 unit = KRW)"), text: $manualRateText).keyboardType(.decimalPad)
                    }
                    Picker(language.text("분류", "Category"), selection: $entry.category) {
                        ForEach(LedgerCategory.allCases) { Label($0.title(language), systemImage: $0.symbol).tag($0) }
                    }
                    DatePicker(language.text("때", "When"), selection: $entry.occurredAt)
                }
                Section {
                    TextField(language.text("낸 사람 (비우면 나)", "Paid by (blank = me)"), text: Binding(get: { entry.payer ?? "" }, set: { entry.payer = $0.isEmpty ? nil : $0 }))
                    TextField(language.text("장소", "Place"), text: Binding(get: { entry.place ?? "" }, set: { entry.place = $0.isEmpty ? nil : $0 }))
                    TextField(language.text("메모", "Note"), text: Binding(get: { entry.note ?? "" }, set: { entry.note = $0.isEmpty ? nil : $0 }))
                } footer: {
                    Text(language.text("낸 사람을 적으면 「정산하기」에서 나눌 돈을 계산해요.", "Add who paid to split costs in Settle up."))
                }
                if !isNew {
                    Section {
                        Button(language.text("지우기", "Delete"), role: .destructive) {
                            Task { await book.delete(entry.id); dismiss() }
                        }
                    }
                }
            }
            .navigationTitle(isNew ? language.text("기록 더하기", "Add entry") : language.text("기록 고치기", "Edit entry"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(language.text("취소", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.text("저장", "Save")) { save() }.disabled(!isValid)
                }
            }
        }
    }

    private var isValid: Bool {
        (LedgerNumber.parse(amountText) ?? 0) > 0 && !entry.title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func save() {
        let original = entry
        entry.amount = LedgerNumber.parse(amountText) ?? 0
        let rate = LedgerNumber.parse(manualRateText).flatMap { $0 > 0 ? $0 : nil }
        if let rate {
            var rates = book.manualRates
            rates[entry.currency] = rate
            book.manualRates = rates
        }
        // 금액·통화·환율을 바꿨거나 환산이 비었을 때만 다시 계산한다(메모만 고친 옛 외화 기록의 원화 값은 그대로).
        if isNew || rate != nil || entry.amountKRW == nil || entry.amount != original.amount || entry.currency != original.currency {
            entry.amountKRW = book.krw(entry.amount, currency: entry.currency)
        }
        let value = entry
        Task {
            await book.save(value)
            dismiss()
        }
    }

    /// 입력 칸에 넣을 글. 저장 때 읽는 방식과 같은 지역 소수점을 쓴다(독일어 12,5).
    static func plain(_ value: Double, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

struct LedgerBudgetForm: View {
    let language: MapHomeLanguage
    let period: String
    @Environment(\.dismiss) private var dismiss
    @State private var amountText = ""
    private var book: LedgerBook { .shared }

    var body: some View {
        NavigationStack {
            Form {
                TextField(language.text("이 달 지출 예산(원)", "Spending budget this month (KRW)"), text: $amountText).keyboardType(.numberPad)
            }
            .navigationTitle(language.text("예산", "Budget"))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { amountText = book.budget(for: period).map { String(Int($0.amountKRW)) } ?? "" }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(language.text("취소", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.text("저장", "Save")) {
                        let amount = LedgerNumber.parse(amountText) ?? 0
                        let budget = amount > 0 ? LedgerBudget(period: period, category: nil, amountKRW: amount) : nil
                        Task {
                            await book.setBudget(budget, for: "\(period)|all", period: period, category: nil)
                            dismiss()
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// 단체 정산: 함께한 사람 이름을 넣으면 똑같이 나눠 누가 누구에게 얼마 보내면 되는지 보인다.
struct LedgerSettleView: View {
    let language: MapHomeLanguage
    let entries: [LedgerEntry]
    @Environment(\.dismiss) private var dismiss
    @State private var namesText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(language.text("함께한 사람 (쉼표로, 예: 민수, 지영)", "People (comma separated)"), text: $namesText)
                } footer: {
                    Text(language.text("나도 포함해 똑같이 나눠요. 기록의 「낸 사람」이 비었으면 내가 낸 것이에요.", "Split equally including you. A blank payer means you paid."))
                }
                let me = language.text("나", "Me")
                let people = namesText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                let transfers = LedgerSettlement.transfers(entries, people: people, me: me)
                Section(language.text("보낼 돈", "Transfers")) {
                    if transfers.isEmpty {
                        Text(language.text("이름을 넣으면 계산해요.", "Enter names to calculate.")).foregroundStyle(.secondary)
                    }
                    ForEach(Array(transfers.enumerated()), id: \.offset) { _, transfer in
                        LabeledContent("\(transfer.from) → \(transfer.to)", value: LedgerMoney.text(transfer.amountKRW, language: language))
                    }
                }
                Section {
                    LabeledContent(language.text("함께 쓴 돈", "Total spent"), value: LedgerMoney.text(LedgerBook.total(entries, .expense), language: language))
                }
            }
            .navigationTitle(language.text("정산하기", "Settle up"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(language.text("완료", "Done")) { dismiss() } } }
        }
    }
}

/// 입력 칸 숫자. 기기 지역의 소수점·자리 구분을 따른다(독일어 12,50 = 12.5).
enum LedgerNumber {
    static func parse(_ text: String, locale: Locale = .current) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        if let value = formatter.number(from: trimmed)?.doubleValue { return value }
        let grouping = locale.groupingSeparator ?? ","
        let decimal = locale.decimalSeparator ?? "."
        return Double(trimmed.replacingOccurrences(of: grouping, with: "").replacingOccurrences(of: decimal, with: "."))
    }
}
