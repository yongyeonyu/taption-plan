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
    /// 이월잔액(여행은 0에서 시작하고 첫 줄이 「경비 받음」).
    var carryOver: Double
    var income: Double
    var expense: Double
    /// 달 예산(달 요약일 때만).
    var budget: Double?
    /// 여행이면 내 기준 대차대조.
    var trip: LedgerTrip?
    var sheet: LedgerTripSheet?

    var balance: Double { carryOver + income - expense }

    @MainActor
    func rows(_ language: MapHomeLanguage) -> [LedgerStandard.Row] { LedgerStandard.rows(entries, carryOver: carryOver, language: language) }

    @MainActor
    func byCategory(_ language: MapHomeLanguage) -> [(String, Double)] { LedgerStandard.byCategory(entries, language: language) }

    @MainActor
    static func make(_ period: LedgerSummaryPeriod, day: Date, book: LedgerBook = .shared, language: MapHomeLanguage,
                     calendar: Calendar = .autoupdatingCurrent) -> LedgerSummary {
        let format = Date.FormatStyle(date: .abbreviated, time: .omitted)
        if period == .trip, let trip = book.trips.first(where: { $0.start <= day.addingTimeInterval(86_399) && calendar.startOfDay(for: $0.end).addingTimeInterval(86_400) > day }) {
            let entries = book.tripEntries(trip.id).sorted { $0.occurredAt < $1.occurredAt }
            return summary(title: language.text("\(trip.name) 여행 가계부", "\(trip.name) trip ledger"),
                           range: "\(trip.start.formatted(format)) – \(trip.end.formatted(format))", entries: entries, carryOver: 0,
                           budget: nil, trip: trip, sheet: LedgerTripMath.sheet(trip, entries: book.entries))
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
        let budget = period == .month ? book.budget(for: LedgerBook.monthKey(start, calendar: calendar))?.amountKRW : nil
        return summary(title: language.text("가계부", "Household ledger"), range: range, entries: entries,
                       carryOver: book.carryOver(before: start), budget: budget, trip: nil, sheet: nil)
    }

    private static func summary(title: String, range: String, entries: [LedgerEntry], carryOver: Double, budget: Double?,
                                trip: LedgerTrip?, sheet: LedgerTripSheet?) -> LedgerSummary {
        LedgerSummary(
            title: title, rangeText: range, entries: entries, carryOver: carryOver,
            income: entries.filter { $0.kind == .income }.reduce(0) { $0 + $1.countedKRW },
            expense: entries.filter { $0.kind == .expense }.reduce(0) { $0 + $1.countedKRW },
            budget: budget, trip: trip, sheet: sheet
        )
    }

    /// 표준 가계부 엑셀(LED1111A07): 제목·기간, 요약(이월·수입·지출·잔액·예산), 내역(일자|구분|항목|적요|수입|지출|잔액|비고)
    /// 이월잔액 줄에서 잔액 수식이 이어지고, 합계(SUM)·항목별 지출(SUMIF·비율), 여행이면 대차대조·정산.
    @MainActor
    func xlsx(language: MapHomeLanguage, calendar: Calendar = .autoupdatingCurrent) -> Data {
        typealias C = LedgerXLSX.Cell
        var sheet = LedgerXLSX(sheetName: title, widths: [17, 7, 12, 24, 13, 13, 14, 30])
        sheet.add([C(value: .text("BOKKI \(title)"), style: .title)])
        sheet.add([C(value: .text(rangeText), style: .note)])
        sheet.add([])
        let summaryLine: [(String, Double)] = [
            (language.text("이월잔액", "Carried over"), carryOver), (language.text("수입", "Income"), income),
            (language.text("지출", "Expense"), expense), (language.text("잔액", "Balance"), balance),
        ] + (budget.map { [(language.text("예산", "Budget"), $0), (language.text("예산 남음", "Budget left"), $0 - expense)] } ?? [])
        sheet.add(summaryLine.map { C(value: .text($0.0), style: .header) })
        sheet.add(summaryLine.map { C(value: .number($0.1), style: .moneyBold) })
        sheet.add([])
        sheet.add(LedgerStandard.header(language).map { C(value: .text($0), style: .header) })
        let carryRow = sheet.rows.count + 1
        sheet.add([C(value: .text(language.text("이월잔액", "Carried over")), style: .bold), C(value: .empty), C(value: .empty), C(value: .empty),
                   C(value: .empty), C(value: .empty), C(value: .number(carryOver), style: .moneyBold)])
        let first = carryRow + 1
        for row in rows(language) {
            let r = sheet.rows.count + 1
            sheet.add([
                C(value: .text(LedgerStandard.dateText(row.date, calendar: calendar))),
                C(value: .text(row.isIncome ? language.text("수입", "Income") : language.text("지출", "Expense"))),
                C(value: .text(row.category)), C(value: .text(row.memo)),
                row.isIncome ? C(value: .number(row.amount), style: .money) : C(value: .empty),
                row.isIncome ? C(value: .empty) : C(value: .number(row.amount), style: .money),
                C(value: .formula("G\(r - 1)+E\(r)-F\(r)", cached: row.balance), style: .money),
                C(value: .text(row.note)),
            ])
        }
        let last = max(first, sheet.rows.count)
        sheet.add([C(value: .text(language.text("합계", "Total")), style: .bold), C(value: .empty), C(value: .empty), C(value: .empty),
                   C(value: .formula("SUM(E\(first):E\(last))", cached: income), style: .moneyBold),
                   C(value: .formula("SUM(F\(first):F\(last))", cached: expense), style: .moneyBold),
                   C(value: .formula("G\(carryRow)+SUM(E\(first):E\(last))-SUM(F\(first):F\(last))", cached: balance), style: .moneyBold)])
        sheet.add([])
        sheet.add([C(value: .text(language.text("항목별 지출", "Spending by category")), style: .header),
                   C(value: .text(language.text("지출", "Expense")), style: .header), C(value: .text(language.text("비율", "Share")), style: .header)])
        let categories = byCategory(language)
        let spent = max(1, categories.reduce(0) { $0 + $1.1 })
        for (name, total) in categories {
            sheet.add([C(value: .text(name)),
                       C(value: .formula("SUMIFS(F\(first):F\(last),C\(first):C\(last),\"\(name.replacingOccurrences(of: "\"", with: ""))\",H\(first):H\(last),\"<>*\(language.text("여행 이체", "Trip transfer"))*\")", cached: total), style: .money),
                       C(value: .text(String(format: "%.1f%%", total / spent * 100)))])
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
        guard entry.tripID != nil, entry.transfer == nil else { return entry.payer ?? "" }
        guard entry.kind == .expense else {
            return entry.payer.map { language.text("\($0)에게 받음", "from \($0)") } ?? ""
        }
        let payer = LedgerName.display(entry.payer ?? LedgerTrip.me, language)
        guard let names = entry.shareNames else { return language.text("\(payer) · 다 같이", "\(payer) · everyone") }
        return "\(payer) · " + names.map { LedgerName.display($0, language) }.joined(separator: "·")
    }

    static func balanceLines(_ sheet: LedgerTripSheet, language: MapHomeLanguage) -> [(String, Double)] {
        var lines: [(String, Double)] = [
            (language.text("일상에서 받은 예산", "Budget from daily"), sheet.budget),
            (language.text("내가 낸 돈", "I paid"), -sheet.myPaid),
            (language.text("지금 남은 돈", "Cash left now"), sheet.cashLeft),
            (language.text("다 같이 쓴 돈", "Spent together"), sheet.sharedTotal),
            (language.text("내 몫", "My share"), sheet.myCost),
        ]
        if sheet.otherIncome > 0 { lines.insert((language.text("그 밖의 수입", "Other income"), sheet.otherIncome), at: 1) }
        if sheet.receivedFromOthers > 0 { lines.insert((language.text("친구에게 미리 받은 돈", "Collected from friends"), sheet.receivedFromOthers), at: 1) }
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
    /// 공유를 누를 때만 엑셀을 만든다(리뷰).
    let make: @MainActor @Sendable () -> Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: UTType("org.openxmlformats.spreadsheetml.sheet") ?? .data) { file in
            let data = await file.make()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(file.name)
            try data.write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

/// 표준 가계부 표(화면·이미지 공용, LED1111A07). 엑셀과 같은 순서: 요약 → 이월 → 내역 → 합계 → 항목별 → (여행) 대차대조.
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
                total(language.text("이월잔액", "Carried over"), summary.carryOver, Color.tpInk)
                total(language.text("수입", "Income"), summary.income, .green)
                total(language.text("지출", "Expense"), summary.expense, .red)
                total(language.text("잔액", "Balance"), summary.balance, summary.balance < 0 ? .red : Color.tpInk)
            }
            if let budget = summary.budget {
                Text(language.text("예산 \(LedgerMoney.text(budget, language: language)) · 남음 \(LedgerMoney.text(budget - summary.expense, language: language))",
                                   "Budget \(LedgerMoney.text(budget, language: language)) · left \(LedgerMoney.text(budget - summary.expense, language: language))"))
                    .font(.taptionFixed(size: 12)).foregroundStyle(budget - summary.expense < 0 ? Color.red : Color.tpSecondary)
            }
            Divider()
            HStack(spacing: 6) {
                Text(language.text("일자", "Date")).frame(width: 58, alignment: .leading)
                Text(language.text("항목·적요", "Category · description"))
                Spacer()
                Text(language.text("수입/지출", "In/Out")).frame(width: 82, alignment: .trailing)
                Text(language.text("잔액", "Balance")).frame(width: 82, alignment: .trailing)
            }
            .font(.taptionFixed(size: 11, weight: .semibold)).foregroundStyle(Color.tpSecondary)
            HStack(spacing: 6) {
                Text(language.text("이월잔액", "Carried over")).font(.taptionFixed(size: 12, weight: .medium))
                Spacer()
                Text(LedgerMoney.text(summary.carryOver, language: language)).monospacedDigit().frame(width: 82, alignment: .trailing)
            }
            .font(.taptionFixed(size: 12))
            ForEach(Array(summary.rows(language).enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 6) {
                    Text(row.date.formatted(.dateTime.month(.defaultDigits).day().hour().minute())).foregroundStyle(Color.tpSecondary).frame(width: 58, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(row.category) · \(row.memo)").lineLimit(1)
                        if !row.note.isEmpty { Text(row.note).font(.taptionFixed(size: 10)).foregroundStyle(Color.tpSecondary).lineLimit(1) }
                    }
                    Spacer(minLength: 4)
                    Text((row.isIncome ? "+" : "−") + LedgerMoney.text(row.amount, language: language))
                        .monospacedDigit().foregroundStyle(row.isIncome ? .green : Color.tpInk).frame(width: 82, alignment: .trailing)
                    Text(LedgerMoney.text(row.balance, language: language)).monospacedDigit().foregroundStyle(Color.tpSecondary).frame(width: 82, alignment: .trailing)
                }
                .font(.taptionFixed(size: 12))
            }
            if summary.entries.isEmpty {
                Text(language.text("이 기간에는 기록이 없어요.", "No entries in this period.")).font(.taptionFixed(size: 12)).foregroundStyle(Color.tpSecondary)
            }
            let categories = summary.byCategory(language)
            if !categories.isEmpty {
                Divider()
                Text(language.text("항목별 지출", "Spending by category")).font(.taptionFixed(size: 13, weight: .semibold))
                let spent = max(1, categories.reduce(0) { $0 + $1.1 })
                ForEach(Array(categories.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 8) {
                        Text(item.0).frame(width: 78, alignment: .leading)
                        GeometryReader { proxy in
                            Capsule().fill(Color.tpAccent.opacity(0.35)).frame(width: max(4, proxy.size.width * item.1 / spent))
                        }
                        .frame(height: 8)
                        Text(String(format: "%.0f%%", item.1 / spent * 100)).frame(width: 36, alignment: .trailing).foregroundStyle(Color.tpSecondary)
                        Text(LedgerMoney.text(item.1, language: language)).monospacedDigit().frame(width: 86, alignment: .trailing)
                    }
                    .font(.taptionFixed(size: 12))
                }
            }
            if let sheet = summary.sheet {
                Divider()
                Text(language.text("대차대조(내 기준)", "Balance (for me)")).font(.taptionFixed(size: 13, weight: .semibold))
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
        .background(Color.tpCard, in: RoundedRectangle(cornerRadius: TaptionCorner.large, style: .continuous))
    }

    private func total(_ title: String, _ value: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.taptionFixed(size: 11)).foregroundStyle(Color.tpSecondary)
            Text(LedgerMoney.text(value, language: language)).font(.taptionFixed(size: 14, weight: .semibold)).foregroundStyle(color)
                .monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
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
                ShareLink(item: LedgerXLSXFile(name: "BOKKI-\(fileStem(summary)).xlsx") { [summary, language] in summary.xlsx(language: language) },
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
