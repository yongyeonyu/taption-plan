import AppIntents
import PhotosUI
import SwiftUI

/// 가계부 화면(LED1110A01). 왼쪽 위 `₩` 버튼으로 연다. 달마다 지출·수입·예산과 오늘 손익, 날짜별 목록.
struct LedgerSheet: View {
    let language: MapHomeLanguage
    /// 여행 모드에서 열면 그 여행 장부를 바로 연다.
    var tripID: String?
    /// 앱 여행 계획에서 가져온 여행(장부가 아직 없으면 눌러서 만든다).
    var plannedTrips: [LedgerTrip] = []

    @Environment(\.dismiss) private var dismiss
    @State private var month = LedgerBook.monthKey(.now)
    @State private var editing: LedgerEntry?
    @State private var isAdding = false
    @State private var isEditingBudget = false
    @State private var isSettling = false
    @State private var isShowingShortcutGuide = false
    @State private var draft: LedgerEntry?
    @State private var receiptItem: PhotosPickerItem?
    @State private var captureNote: String?
    @State private var path: [String] = []
    @State private var isAddingTrip = false
    private var book: LedgerBook { .shared }

    var body: some View {
        // 이 달 기록을 한 번만 걸러 시간순으로 날짜별로 묶는다. 묶음마다 다시 거르면 스크롤이 끊겼다(LDU1111A01).
        let groups = LedgerDayGroup.groups(monthEntries)
        return NavigationStack(path: $path) {
            List {
                Group {
                summarySection
                tripsSection
                captureSection
                ForEach(groups) { group in
                    Section(group.day.formatted(date: .abbreviated, time: .omitted)) {
                        ForEach(group.entries) { entry in
                            // 짝 기록도 여기서 고치고 지운다(LED1111A09). 그 여행 장부는 밀어서 연다.
                            Button { editing = entry } label: { LedgerRow(entry: entry, language: language) }
                                .buttonStyle(.plain)
                                .swipeActions {
                                    Button(language.text("지우기", "Delete"), role: .destructive) { Task { await book.remove(entry) } }
                                    if let tripID = entry.transfer?.tripID, book.trip(tripID) != nil {
                                        Button(language.text("여행 장부", "Trip ledger")) { path = [tripID] }
                                    }
                                }
                        }
                    }
                }
                if groups.isEmpty {
                    Text(language.text("이 달에는 기록이 없어요. + 로 더해 보세요.", "No entries this month. Tap + to add one."))
                        .foregroundStyle(Color.tpSecondary)
                }
                }
                .listRowBackground(Color.tpSurface)
            }
            .tpListStyle()
            // 당겨서 AI 비서 명령을 바로 받는다(SYN1111A01).
            .refreshable { await AssistantCommandRefresh.now(language: language, manual: true) }
            .navigationTitle(language.text("가계부", "Ledger"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(language.text("닫기", "Close")) { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        Button(language.text("이 달 예산", "Monthly budget")) { isEditingBudget = true }
                        Button(language.text("정산하기", "Settle up")) { isSettling = true }
                        Button { isShowingShortcutGuide = true } label: {
                            Label(language.text("결제 문자 자동으로 넣기", "Add payment texts automatically"), systemImage: "message.badge")
                        }
                        ShareLink(item: LedgerTableFile(name: "BOKKI-\(month).csv") { [monthEntries, monthCarryOver, monthTitle, language] in
                            LedgerTable.csv(monthEntries, carryOver: monthCarryOver, title: language.text("BOKKI 가계부 \(monthTitle)", "BOKKI ledger \(monthTitle)"), language: language)
                        },
                                  preview: SharePreview(language.text("가계부 \(monthTitle) 표", "Ledger \(monthTitle) table"))) {
                            Label(language.text("이 달 표로 내보내기", "Export this month as a table"), systemImage: "tablecells")
                        }
                        ShareLink(item: LedgerTableFile(name: "BOKKI-ledger.csv") { [language] in
                            LedgerTable.csv(LedgerBook.shared.dailyEntries, title: language.text("BOKKI 가계부 전체", "BOKKI ledger (all)"), language: language)
                        },
                                  preview: SharePreview(language.text("가계부 전체 표", "Whole ledger table"))) {
                            Label(language.text("전체 표로 내보내기", "Export everything as a table"), systemImage: "square.and.arrow.up")
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    Button { isAdding = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel(language.text("기록 더하기", "Add entry"))
                }
            }
            .task {
                await book.load()
                await book.refreshRates()
                await book.fillMissingKRW()
                await book.syncEndedTrips()
                if let tripID, path.isEmpty { await openTrip(tripID) }
            }
            .navigationDestination(for: String.self) { id in LedgerTripView(tripID: id, language: language) }
            .sheet(isPresented: $isAddingTrip) {
                LedgerTripForm(language: language, trip: LedgerTrip(id: "ledger-" + UUID().uuidString, name: "", start: .now, end: .now)) { trip in
                    Task { await book.saveTrip(trip); path = [trip.id] }
                }
            }
            .sheet(isPresented: $isAdding) {
                LedgerEntryForm(language: language, entry: LedgerEntry(occurredAt: .now, amount: 0, title: ""))
            }
            .sheet(item: $editing) { entry in LedgerEntryForm(language: language, entry: entry, isNew: false) }
            .sheet(item: $draft) { entry in LedgerEntryForm(language: language, entry: entry) }
            .onChange(of: receiptItem) { _, item in
                guard let item else { return }
                Task { await readReceipt(item) }
            }
            .sheet(isPresented: $isEditingBudget) { LedgerBudgetForm(language: language, period: month) }
            .sheet(isPresented: $isShowingShortcutGuide) { LedgerShortcutGuide(language: language) }
            .sheet(isPresented: $isSettling) {
                LedgerSettleView(language: language, entries: monthEntries.filter { $0.transfer == nil })
            }
        }
    }

    /// 일상 장부의 이 달: 여행 안 기록은 빼고 여행과 오간 짝 기록(경비·정산)만 담는다(LED1111A05).
    private var monthEntries: [LedgerEntry] {
        guard let interval = monthInterval else { return [] }
        return book.dailyEntries.filter { interval.contains($0.occurredAt) && $0.occurredAt != interval.end }
    }

    private var monthInterval: DateInterval? {
        let parts = month.split(separator: "-").compactMap { Int($0) }
        let calendar = Calendar.autoupdatingCurrent
        guard parts.count == 2, let start = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: 1)) else { return nil }
        return calendar.dateInterval(of: .month, for: start)
    }

    /// 이 달 첫날까지의 이월잔액.
    private var monthCarryOver: Double {
        let first = month.split(separator: "-").compactMap { Int($0) }
        guard first.count == 2, let start = Calendar.autoupdatingCurrent.date(from: DateComponents(year: first[0], month: first[1], day: 1)) else { return 0 }
        return book.carryOver(before: start)
    }

    /// 여행 장부 목록. 장부가 있는 여행과, 앱 여행 계획 중 아직 장부가 없는 여행(누르면 만든다).
    @ViewBuilder
    private var tripsSection: some View {
        let missing = plannedTrips.filter { planned in !book.trips.contains { $0.id == planned.id } }
        Section {
                ForEach(book.trips) { trip in
                    NavigationLink(value: trip.id) {
                        LabeledContent(trip.name, value: LedgerMoney.text(LedgerTripMath.sheet(trip, entries: book.entries).myCost, language: language))
                    }
                }
                ForEach(missing) { trip in
                    Button { Task { await openTrip(trip.id) } } label: {
                        Label(language.text("\(trip.name) 장부 만들기", "Start a ledger for \(trip.name)"), systemImage: "plus.circle")
                    }
                }
                Button { isAddingTrip = true } label: {
                    Label(language.text("새 여행 장부", "New trip ledger"), systemImage: "airplane.circle")
                }
        } header: {
            Text(language.text("여행 장부", "Trip ledgers"))
        } footer: {
            Text(language.text("여행 예산은 일상에서 「여행 경비」로 나가고, 여행이 끝나면 남은 돈이 「여행 정산」으로 돌아와요.", "A trip budget leaves daily as a trip expense; leftovers come back as a trip refund when it ends."))
        }
    }

    /// 여행 장부를 연다. 앱 여행 계획에만 있으면 그 이름·기간으로 만든다.
    private func openTrip(_ id: String) async {
        if book.trip(id) == nil, let planned = plannedTrips.first(where: { $0.id == id }) { await book.saveTrip(planned) }
        guard book.trip(id) != nil else { return }
        path = [id]
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
            // 단축어 자동화 안내를 메뉴 안에만 두면 찾기 어렵다(대표 질문 2026-11-11).
            Button { isShowingShortcutGuide = true } label: {
                Label(language.text("결제 문자 자동으로 넣기", "Add payment texts automatically"), systemImage: "message.badge")
            }
        } footer: {
            Text(captureNote ?? language.text("카드 결제 문자를 복사해 붙여 넣거나 영수증 사진을 고르면 채워 드려요. 「결제 문자 자동으로 넣기」로 단축어를 걸면 문자가 오자마자 들어가요.", "Paste a card payment text or pick a receipt photo to fill an entry. Set up \"Add payment texts automatically\" so texts go in as they arrive."))
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

    private var summarySection: some View {
        let spent = LedgerBook.total(monthEntries, .expense)
        let earned = LedgerBook.total(monthEntries, .income)
        let budget = book.budget(for: month)
        let monthlyNet = MapHomeSalaryPolicy.monthlyNet(MapHomeSalaryPolicy.loadSettings())
        return Section {
            HStack {
                Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                Spacer()
                Text(monthTitle).font(.taptionStyle(.headline))
                Spacer()
                Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
            }
            .buttonStyle(.borderless)
            // 표준 가계부 순서: 이월잔액 · 수입 · 지출 · 잔액(LED1111A07).
            LabeledContent(language.text("이월잔액", "Carried over"), value: LedgerMoney.text(monthCarryOver, language: language))
            LabeledContent(language.text("수입", "Income"), value: LedgerMoney.text(earned, language: language))
            LabeledContent(language.text("지출", "Spent"), value: LedgerMoney.text(spent, language: language))
            LabeledContent(language.text("잔액", "Balance"), value: LedgerMoney.text(monthCarryOver + earned - spent, language: language))
                .fontWeight(.bold)
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
            LedgerEntryIcon(entry: entry, size: 22).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).lineLimit(1)
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold))
                    .foregroundStyle(Color.tpInk)
                // 시각을 맨 앞에(LDU1111A01).
                Text([entry.occurredAt.formatted(date: .omitted, time: .shortened), entry.category.title(language), entry.payer, sourceText].compactMap { $0 }.joined(separator: " · "))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text((entry.kind == .expense ? "−" : "+") + LedgerMoney.text(entry.amount, currency: entry.currency, language: language))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .bold))
                    .foregroundStyle(entry.kind == .expense ? Color.tpInk : Color.green)
                if entry.currency != "KRW", let krw = entry.amountKRW {
                    Text(LedgerMoney.text(krw, language: language))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .semibold))
                        .foregroundStyle(Color.tpSecondary)
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
    /// 여행 장부에서 쓸 때 동행(나 빼고). 있으면 「낸 사람」·「누구 몫」을 고른다(LED1111A05).
    var members: [String]? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var amountText = ""
    @State private var manualRateText = ""
    private var book: LedgerBook { .shared }
    static let currencies = ["KRW", "USD", "JPY", "EUR", "CNY", "TWD", "HKD", "THB", "VND", "SGD", "PHP", "IDR", "GBP", "AUD", "CAD"]

    init(language: MapHomeLanguage, entry: LedgerEntry, isNew: Bool = true, members: [String]? = nil) {
        self.language = language
        _entry = State(initialValue: entry)
        self.isNew = isNew
        self.members = members
        _amountText = State(initialValue: entry.amount > 0 ? Self.plain(entry.amount) : "")
    }

    var body: some View {
        NavigationStack {
            Form {
            Group {
                if let transfer = entry.transfer {
                    transferSection(transfer)
                } else {
                    entrySection
                }
                if let members, entry.kind == .expense, entry.transfer == nil {
                    LedgerShareSection(language: language, members: members, payer: $entry.payer, shareNames: $entry.shareNames)
                } else if let members, !members.isEmpty, entry.kind == .income, entry.transfer == nil {
                    LedgerIncomeFromSection(language: language, members: members, payer: $entry.payer)
                }
                Section {
                    if members == nil, entry.transfer == nil {
                        TextField(language.text("낸 사람 (비우면 나)", "Paid by (blank = me)"), text: Binding(get: { entry.payer ?? "" }, set: { entry.payer = $0.isEmpty ? nil : $0 }))
                    }
                    TextField(language.text("장소", "Place"), text: Binding(get: { entry.place ?? "" }, set: { entry.place = $0.isEmpty ? nil : $0 }))
                    TextField(language.text("메모", "Note"), text: Binding(get: { entry.note ?? "" }, set: { entry.note = $0.isEmpty ? nil : $0 }))
                } footer: {
                    Text(language.text("낸 사람을 적으면 「정산하기」에서 나눌 돈을 계산해요.", "Add who paid to split costs in Settle up."))
                }
                if !isNew {
                    Section {
                        Button(language.text("지우기", "Delete"), role: .destructive) {
                            let value = entry
                            Task {
                                await book.remove(value)
                                dismiss()
                            }
                        }
                    } footer: {
                        if entry.memoID != nil {
                            Text(language.text("지우면 이 메모는 「메모로만」이 돼 다시 가계부에 들어오지 않아요.", "Deleting makes this memo note-only so it won't come back to the ledger."))
                        }
                    }
                }
            }
            .listRowBackground(Color.tpSurface)
        }
        .tpListStyle()
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

    private var entrySection: some View {
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
                    .font(.taptionStyle(.caption)).foregroundStyle(.secondary)
                TextField(language.text("직접 넣는 환율 (1단위 = 원)", "Manual rate (1 unit = KRW)"), text: $manualRateText).keyboardType(.decimalPad)
            }
            Picker(language.text("분류", "Category"), selection: $entry.category) {
                ForEach(LedgerCategory.allCases) { Label($0.title(language), systemImage: $0.symbol).tag($0) }
            }
            DatePicker(language.text("때", "When"), selection: $entry.occurredAt)
        }
    }

    /// 예산 이체·정산 짝 기록(LED1111A09). 금액·날짜를 고치면 일상 쪽과 여행 쪽이 함께 바뀐다.
    @ViewBuilder private func transferSection(_ transfer: LedgerTransfer) -> some View {
        let trip = book.trip(transfer.tripID)
        Section {
            Text(entry.title)
            if transfer.kind == .settlement {
                Picker(language.text("종류", "Type"), selection: $entry.kind) {
                    Text(language.text("지출", "Expense")).tag(LedgerEntry.Kind.expense)
                    Text(language.text("수입", "Income")).tag(LedgerEntry.Kind.income)
                }
                .pickerStyle(.segmented)
            }
            HStack {
                TextField(language.text("금액(원)", "Amount (KRW)"), text: $amountText).keyboardType(.numberPad)
                Text("KRW").foregroundStyle(.secondary)
            }
            DatePicker(language.text("때", "When"), selection: $entry.occurredAt)
        } footer: {
            Text(transfer.kind == .funding
                 ? language.text("여행 예산이에요. 고치면 일상의 「여행 경비」와 여행의 「경비 받음」이 함께 바뀌어요.", "This is the trip budget. Editing it changes both the daily and trip sides.")
                 : language.text("여행 정산이에요. 고치면 그 금액으로 고정돼요. 일상 쪽 수입이면 반납, 지출이면 추가 경비예요.", "This is the trip settlement. Editing fixes it to this amount. Daily income means returned, expense means extra."))
        }
        if transfer.kind == .settlement, trip?.settlementKRW != nil, !isNew {
            Section {
                Button(language.text("자동 정산으로 되돌리기", "Back to automatic settlement")) {
                    Task {
                        await book.resetSettlement(transfer.tripID)
                        dismiss()
                    }
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
            if value.transfer != nil {
                await book.saveTransfer(value)
                return dismiss()
            }
            await book.save(value)
            // 여행 기록이 바뀌면 끝난 여행의 정산 짝 기록도 다시 맞춘다.
            if let tripID = value.tripID { await book.syncTrip(tripID) }
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
            Group {
                TextField(language.text("이 달 지출 예산(원)", "Spending budget this month (KRW)"), text: $amountText).keyboardType(.numberPad)
            }
            .listRowBackground(Color.tpSurface)
        }
        .tpListStyle()
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
            Group {
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
            .listRowBackground(Color.tpSurface)
        }
        .tpListStyle()
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

/// 결제 문자 자동 넣기 안내(LED1111A10, 대표 질문 2026-11-11: 단축어 추가 메뉴가 어디 있나).
/// 단축어 자동화는 앱이 대신 만들 수 없어 순서를 보여 주고 단축어 앱을 연다.
struct LedgerShortcutGuide: View {
    let language: MapHomeLanguage
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var steps: [String] {
        [
            language.text("단축어 앱 → 아래 「자동화」 → 오른쪽 위 +", "Shortcuts app → Automation → + at the top right"),
            language.text("「메시지」 → 「메시지 내용에 포함」에 카드사 이름이나 「승인」을 적기", "Message → \"Message Contains\" → type your card company or \"approved\""),
            language.text("「즉시 실행」을 고르고 다음", "Choose \"Run Immediately\", then Next"),
            language.text("「새로운 빈 자동화」 → 동작 검색에서 「결제 문자 넣기」(BOKKI Plan)", "New Blank Automation → search actions for \"Add payment text\" (BOKKI Plan)"),
            language.text("「메시지」 칸이 받은 메시지로 채워졌는지 보고 완료", "Check that the Message field is the received message, then Done"),
        ]
    }

    var body: some View {
        NavigationStack {
            List {
                Group {
                Section {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        Label { Text(step) } icon: { Text(verbatim: "\(index + 1)").font(.taptionStyle(.headline)) }
                    }
                } footer: {
                    Text(language.text("카드 결제 문자가 오면 가계부에 바로 들어가요. 읽지 못한 형식은 「붙여넣기」로 넣어 주세요.", "Card payment texts go straight into the ledger. Paste any format it can't read."))
                }
                Section {
                    Button {
                        if let url = URL(string: "shortcuts://") { openURL(url) }
                    } label: { Label(language.text("단축어 앱 열기", "Open Shortcuts"), systemImage: "square.2.layers.3d") }
                    ShortcutsLink()
                }
                }
                .listRowBackground(Color.tpSurface)
            }
            .tpListStyle()
            .navigationTitle(language.text("결제 문자 자동으로 넣기", "Add payment texts automatically"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(language.text("완료", "Done")) { dismiss() } } }
        }
    }
}

/// 가계부 한 달을 날짜별로 묶는다. 날짜도, 같은 날 안도 오래된 것부터 시간순(LDU1111A01).
struct LedgerDayGroup: Identifiable, Equatable {
    let day: Date
    let entries: [LedgerEntry]
    var id: Date { day }

    static func groups(_ entries: [LedgerEntry], calendar: Calendar = .autoupdatingCurrent) -> [LedgerDayGroup] {
        let sorted = entries.sorted { $0.occurredAt == $1.occurredAt ? $0.createdAt < $1.createdAt : $0.occurredAt < $1.occurredAt }
        var result: [LedgerDayGroup] = []
        for entry in sorted {
            let day = calendar.startOfDay(for: entry.occurredAt)
            if let last = result.last, last.day == day {
                result[result.count - 1] = LedgerDayGroup(day: day, entries: last.entries + [entry])
            } else {
                result.append(LedgerDayGroup(day: day, entries: [entry]))
            }
        }
        return result
    }
}
