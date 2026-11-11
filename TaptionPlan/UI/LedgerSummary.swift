import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// 지출 요약(LED1111A05): 하루 카드 화면의 둘째 탭. 하루·주·달(여행 중이면 이 여행 전체)을 가계부 양식 표로 보이고,
/// 같은 표를 진짜 엑셀(.xlsx)과 세로 이미지로 내보낸다.
enum LedgerSummaryPeriod: String, CaseIterable, Identifiable {
    case day, week, month, trip
    var id: String { rawValue }

    func title(_ language: MapHomeLanguage) -> String {
        switch self {
        case .day: language.text("하루", "Day")
        case .week: language.text("주", "Week")
        case .month: language.text("달", "Month")
        case .trip: language.text("여행", "Trip")
        }
    }
}

struct LedgerSummary: Equatable {
    var title: String
    var rangeText: String
    var entries: [LedgerEntry]
    var income: Double
    var expense: Double
    var byCategory: [(LedgerCategory, Double)]
    /// 여행이면 내 기준 대차대조.
    var trip: LedgerTrip?
    var sheet: LedgerTripSheet?

    var balance: Double { income - expense }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title == rhs.title && lhs.rangeText == rhs.rangeText && lhs.entries == rhs.entries && lhs.sheet == rhs.sheet
    }

    @MainActor
    static func make(_ period: LedgerSummaryPeriod, day: Date, book: LedgerBook = .shared, language: MapHomeLanguage,
                     calendar: Calendar = .autoupdatingCurrent) -> LedgerSummary {
        let format = Date.FormatStyle(date: .abbreviated, time: .omitted)
        if period == .trip, let trip = book.trips.first(where: { $0.start <= day.addingTimeInterval(86_399) && calendar.startOfDay(for: $0.end).addingTimeInterval(86_400) > day }) {
            let entries = book.tripEntries(trip.id).sorted { $0.occurredAt < $1.occurredAt }
            return summary(title: trip.name, range: "\(trip.start.formatted(format)) – \(trip.end.formatted(format))", entries: entries,
                           trip: trip, sheet: LedgerTripMath.sheet(trip, entries: book.entries))
        }
        let start: Date, end: Date
        switch period {
        case .day, .trip:
            start = calendar.startOfDay(for: day); end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        case .week:
            let interval = calendar.dateInterval(of: .weekOfYear, for: day)
            start = interval?.start ?? calendar.startOfDay(for: day); end = interval?.end ?? start
        case .month:
            let interval = calendar.dateInterval(of: .month, for: day)
            start = interval?.start ?? calendar.startOfDay(for: day); end = interval?.end ?? start
        }
        let entries = book.dailyEntries.filter { $0.occurredAt >= start && $0.occurredAt < end }.sorted { $0.occurredAt < $1.occurredAt }
        let last = end.addingTimeInterval(-1)
        let range = period == .day ? start.formatted(format) : "\(start.formatted(format)) – \(last.formatted(format))"
        return summary(title: language.text("가계부", "Ledger"), range: range, entries: entries, trip: nil, sheet: nil)
    }

    private static func summary(title: String, range: String, entries: [LedgerEntry], trip: LedgerTrip?, sheet: LedgerTripSheet?) -> LedgerSummary {
        let expenses = entries.filter { $0.kind == .expense && $0.transfer == nil }
        let byCategory = Dictionary(grouping: expenses, by: \.category).map { ($0.key, $0.value.reduce(0) { $0 + ($1.amountKRW ?? 0) }) }.sorted { $0.1 > $1.1 }
        return LedgerSummary(
            title: title, rangeText: range, entries: entries,
            income: entries.filter { $0.kind == .income }.reduce(0) { $0 + ($1.amountKRW ?? 0) },
            expense: entries.filter { $0.kind == .expense }.reduce(0) { $0 + ($1.amountKRW ?? 0) },
            byCategory: byCategory, trip: trip, sheet: sheet
        )
    }

    /// 가계부 양식 엑셀: 제목·기간, 날짜|시각|분류|내용|수입|지출|잔액|원래 금액|낸 사람·몫, 합계(수식), 분류별(SUMIF), 여행이면 대차대조·정산.
    @MainActor
    func xlsx(language: MapHomeLanguage, calendar: Calendar = .autoupdatingCurrent) -> Data {
        typealias C = LedgerXLSX.Cell
        var sheet = LedgerXLSX(sheetName: title, widths: [12, 7, 12, 26, 13, 13, 14, 16, 18])
        sheet.add([C(value: .text("BOKKI \(title)"), style: .title)])
        sheet.add([C(value: .text(rangeText), style: .note)])
        sheet.add([])
        let headers = [language.text("날짜", "Date"), language.text("시각", "Time"), language.text("분류", "Category"), language.text("내용", "What"),
                       language.text("수입", "Income"), language.text("지출", "Expense"), language.text("잔액", "Balance"),
                       language.text("원래 금액", "Original"), language.text("낸 사람·몫", "Paid by · split")]
        sheet.add(headers.map { C(value: .text($0), style: .header) })
        let first = sheet.rows.count + 1
        let day = DateFormatter(), time = DateFormatter()
        day.calendar = calendar; day.timeZone = calendar.timeZone; day.dateFormat = "yyyy-MM-dd"
        time.calendar = calendar; time.timeZone = calendar.timeZone; time.dateFormat = "HH:mm"
        var running = 0.0
        for entry in entries {
            let r = sheet.rows.count + 1
            let krw = entry.amountKRW ?? 0
            running += entry.kind == .income ? krw : -krw
            let original = entry.currency == "KRW" ? "" : "\(entry.currency) \(LedgerTable.plain(entry.amount))"
            sheet.add([
                C(value: .text(day.string(from: entry.occurredAt))), C(value: .text(time.string(from: entry.occurredAt))),
                C(value: .text(entry.category.title(language))), C(value: .text(entry.title)),
                entry.kind == .income ? C(value: .number(krw), style: .money) : C(value: .empty),
                entry.kind == .expense ? C(value: .number(krw), style: .money) : C(value: .empty),
                C(value: .formula(r == first ? "E\(r)-F\(r)" : "G\(r - 1)+E\(r)-F\(r)", cached: running), style: .money),
                C(value: .text(original)), C(value: .text(Self.splitText(entry, language: language))),
            ])
        }
        let last = max(first, sheet.rows.count)
        sheet.add([])
        sheet.add([C(value: .text(language.text("합계", "Total")), style: .bold), C(value: .empty), C(value: .empty), C(value: .empty),
                   C(value: .formula("SUM(E\(first):E\(last))", cached: income), style: .moneyBold),
                   C(value: .formula("SUM(F\(first):F\(last))", cached: expense), style: .moneyBold),
                   C(value: .formula("SUM(E\(first):E\(last))-SUM(F\(first):F\(last))", cached: balance), style: .moneyBold)])
        sheet.add([])
        sheet.add([C(value: .text(language.text("분류별 지출", "Spending by category")), style: .header), C(value: .text(language.text("금액", "Amount")), style: .header)])
        for (category, total) in byCategory {
            let name = category.title(language).replacingOccurrences(of: "\"", with: "")
            sheet.add([C(value: .text(name)), C(value: .formula("SUMIF(C\(first):C\(last),\"\(name)\",F\(first):F\(last))", cached: total), style: .money)])
        }
        if let trip, let tripSheet = self.sheet {
            sheet.add([])
            sheet.add([C(value: .text(language.text("대차대조(내 기준)", "Balance (for me)")), style: .header), C(value: .text(language.text("금액", "Amount")), style: .header)])
            for (title, value) in Self.balanceLines(tripSheet, language: language) {
                sheet.add([C(value: .text(title)), C(value: .number(value), style: .money)])
            }
            sheet.add([])
            sheet.add([C(value: .text(language.text("정산", "Settle up")), style: .header), C(value: .text(language.text("금액", "Amount")), style: .header)])
            for transfer in tripSheet.transfers {
                let from = LedgerName.display(transfer.from, language), to = LedgerName.display(transfer.to, language)
                sheet.add([C(value: .text("\(from) → \(to)")), C(value: .number(transfer.amountKRW), style: .money)])
            }
            if !trip.members.isEmpty {
                sheet.add([C(value: .text(language.text("함께 간 사람: ", "With: ") + trip.members.joined(separator: ", ")), style: .note)])
            }
        }
        return sheet.data()
    }

    static func splitText(_ entry: LedgerEntry, language: MapHomeLanguage) -> String {
        guard entry.tripID != nil, entry.transfer == nil, entry.kind == .expense else { return entry.payer ?? "" }
        let payer = LedgerName.display(entry.payer ?? LedgerTrip.me, language)
        guard let names = entry.shareNames else { return language.text("\(payer) · 다 같이", "\(payer) · everyone") }
        return "\(payer) · " + names.map { LedgerName.display($0, language) }.joined(separator: "·")
    }

    static func balanceLines(_ sheet: LedgerTripSheet, language: MapHomeLanguage) -> [(String, Double)] {
        var lines: [(String, Double)] = [
            (language.text("일상에서 받은 예산", "Budget from daily"), sheet.budget),
            (language.text("내가 낸 돈", "I paid"), -sheet.myPaid),
            (language.text("지금 남은 돈", "Cash left now"), sheet.cashLeft),
            (language.text("다 같이 쓴 돈(공금)", "Shared spending"), sheet.sharedTotal),
            (language.text("내 몫", "My share"), sheet.myCost),
        ]
        if sheet.otherIncome > 0 { lines.insert((language.text("그 밖의 수입", "Other income"), sheet.otherIncome), at: 1) }
        for transfer in sheet.mine {
            if transfer.to == LedgerTrip.me {
                lines.append((language.text("\(transfer.from)에게 받을 돈", "From \(transfer.from)"), transfer.amountKRW))
            } else {
                lines.append((language.text("\(transfer.to)에게 줄 돈", "To \(transfer.to)"), -transfer.amountKRW))
            }
        }
        lines.append((sheet.leftover >= 0 ? language.text("정산 뒤 일상으로 돌아갈 돈", "Back to daily after settling") : language.text("일상에서 더 보낼 돈", "More from daily"), sheet.leftover))
        return lines
    }
}

/// 엑셀 파일. 공유를 누를 때 만든다.
struct LedgerXLSXFile: Transferable {
    let name: String
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: UTType("org.openxmlformats.spreadsheetml.sheet") ?? .data) { file in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(file.name)
            try file.data.write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

/// 가계부 양식 표(화면·이미지 공용). 앱 글꼴로 그린다.
struct LedgerSummaryTable: View {
    let summary: LedgerSummary
    let language: MapHomeLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("BOKKI \(summary.title)").font(.taptionFixed(size: 20, weight: .bold))
                Text(summary.rangeText).font(.taptionFixed(size: 12)).foregroundStyle(Color.tpSecondary)
            }
            HStack {
                total(language.text("수입", "Income"), summary.income, .green)
                total(language.text("지출", "Expense"), summary.expense, .red)
                total(language.text("잔액", "Balance"), summary.balance, summary.balance < 0 ? .red : Color.tpInk)
            }
            if !summary.byCategory.isEmpty {
                let maximum = max(1, summary.byCategory.first?.1 ?? 1)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(summary.byCategory.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 8) {
                            Image(systemName: item.0.symbol).frame(width: 18).foregroundStyle(Color.tpAccent)
                            Text(item.0.title(language)).frame(width: 72, alignment: .leading)
                            GeometryReader { proxy in
                                Capsule().fill(Color.tpAccent.opacity(0.35)).frame(width: max(4, proxy.size.width * item.1 / maximum))
                            }
                            .frame(height: 8)
                            Text(LedgerMoney.text(item.1, language: language)).monospacedDigit().frame(width: 92, alignment: .trailing)
                        }
                        .font(.taptionFixed(size: 12))
                    }
                }
            }
            Divider()
            ForEach(summary.entries) { entry in
                HStack(spacing: 8) {
                    Text(entry.occurredAt.formatted(.dateTime.month(.defaultDigits).day().hour().minute())).foregroundStyle(Color.tpSecondary).frame(width: 92, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title).lineLimit(1)
                        let split = LedgerSummary.splitText(entry, language: language)
                        if !split.isEmpty { Text(split).font(.taptionFixed(size: 10)).foregroundStyle(Color.tpSecondary) }
                    }
                    Spacer(minLength: 4)
                    Text((entry.kind == .expense ? "−" : "+") + LedgerMoney.text(entry.amountKRW ?? 0, language: language))
                        .monospacedDigit().foregroundStyle(entry.kind == .expense ? Color.tpInk : .green)
                }
                .font(.taptionFixed(size: 12))
            }
            if summary.entries.isEmpty {
                Text(language.text("이 기간에는 기록이 없어요.", "No entries in this period.")).font(.taptionFixed(size: 12)).foregroundStyle(Color.tpSecondary)
            }
            if let sheet = summary.sheet {
                Divider()
                Text(language.text("대차대조(내 기준)", "Balance (for me)")).font(.taptionFixed(size: 13, weight: .bold))
                ForEach(Array(LedgerSummary.balanceLines(sheet, language: language).enumerated()), id: \.offset) { _, line in
                    HStack {
                        Text(line.0)
                        Spacer()
                        Text((line.1 > 0 ? "+" : "") + LedgerMoney.text(line.1, language: language)).monospacedDigit()
                            .foregroundStyle(line.1 < 0 ? Color.red : Color.tpInk)
                    }
                    .font(.taptionFixed(size: 12))
                }
            }
        }
        .padding(18)
        .background(Color.tpCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func total(_ title: String, _ value: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.taptionFixed(size: 11)).foregroundStyle(Color.tpSecondary)
            Text(LedgerMoney.text(value, language: language)).font(.taptionFixed(size: 15, weight: .bold)).foregroundStyle(color).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 하루 카드 화면의 「지출 요약」 탭 내용.
struct LedgerSummaryPanel: View {
    let day: Date
    let language: MapHomeLanguage
    @State private var period: LedgerSummaryPeriod = .day
    @State private var imageURL: URL?
    @State private var message: String?
    private var book: LedgerBook { .shared }

    private var periods: [LedgerSummaryPeriod] {
        let inTrip = book.trips.contains { $0.start <= day.addingTimeInterval(86_399) && Calendar.autoupdatingCurrent.startOfDay(for: $0.end).addingTimeInterval(86_400) > day }
        return LedgerSummaryPeriod.allCases.filter { $0 != .trip || inTrip }
    }

    var body: some View {
        let summary = LedgerSummary.make(period, day: day, language: language)
        VStack(spacing: 14) {
            Picker("", selection: $period) {
                ForEach(periods) { Text($0.title(language)).tag($0) }
            }
            .pickerStyle(.segmented)
            LedgerSummaryTable(summary: summary, language: language)
            HStack(spacing: 12) {
                ShareLink(item: LedgerXLSXFile(name: "BOKKI-\(fileStem(summary)).xlsx", data: summary.xlsx(language: language)),
                          preview: SharePreview(language.text("가계부 엑셀", "Ledger spreadsheet"))) {
                    Label(language.text("엑셀", "Excel"), systemImage: "tablecells").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                Button { shareImage(summary) } label: {
                    Label(language.text("이미지", "Image"), systemImage: "photo").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.tpAccent)
            }
            if let message { Text(message).font(.taptionStyle(.footnote)).foregroundStyle(Color.tpAccent) }
        }
        .task { await book.load(); await book.syncEndedTrips() }
        .sheet(item: $imageURL) { url in MapHomeShareSheet(url: url) }
    }

    private func fileStem(_ summary: LedgerSummary) -> String {
        let format = DateFormatter()
        format.dateFormat = "yyyyMMdd"
        return "\(period.rawValue)-\(format.string(from: day))"
    }

    /// 표를 그대로 세로 이미지로(앱 글꼴, 3배 해상도).
    private func shareImage(_ summary: LedgerSummary) {
        let renderer = ImageRenderer(content: LedgerSummaryTable(summary: summary, language: language).frame(width: 390).background(Color.tpBackground))
        renderer.scale = 3
        guard let image = renderer.uiImage, let data = image.pngData() else {
            message = language.text("이미지를 만들지 못했어요.", "Couldn't make the image.")
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BOKKI-\(fileStem(summary)).png")
        do {
            try data.write(to: url, options: .atomic)
            imageURL = url
        } catch {
            message = language.text("이미지를 만들지 못했어요.", "Couldn't make the image.")
        }
    }
}
