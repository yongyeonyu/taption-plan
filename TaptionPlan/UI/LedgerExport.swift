import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// 가계부 표준 양식(LED1111A07, 대표 지시: 흔히 쓰는 가계부 서식으로 일상·여행 모두 통일).
/// 이월잔액 → 일자 | 구분 | 항목 | 적요 | 수입 | 지출 | 잔액 | 비고 → 합계 → 항목별 지출(비율·예산 대비).
/// 엑셀·CSV·이미지·앱 요약이 모두 이 행을 쓴다.
@MainActor
enum LedgerStandard {
    struct Row: Equatable {
        var date: Date
        var isIncome: Bool
        var category: String
        var memo: String
        var amount: Double
        var balance: Double
        var note: String
    }

    static func header(_ language: MapHomeLanguage) -> [String] {
        [language.text("일자", "Date"), language.text("구분", "Type"), language.text("항목", "Category"), language.text("적요", "Description"),
         language.text("수입", "Income"), language.text("지출", "Expense"), language.text("잔액", "Balance"), language.text("비고", "Notes")]
    }

    /// 원화 기준 행. 잔액은 이월잔액에서 시작해 수입은 더하고 지출은 뺀다.
    static func rows(_ entries: [LedgerEntry], carryOver: Double, language: MapHomeLanguage) -> [Row] {
        var balance = carryOver
        return entries.sorted { $0.occurredAt < $1.occurredAt }.map { entry in
            let amount = entry.amountKRW ?? 0
            balance += entry.kind == .income ? amount : -amount
            return Row(date: entry.occurredAt, isIncome: entry.kind == .income, category: entry.category.title(language), memo: entry.title,
                       amount: amount, balance: balance, note: note(entry, language: language))
        }
    }

    /// 비고: 원래 통화 금액, 여행이면 낸 사람·몫, 여행 이체, 장소·메모, 들어온 길(AI·결제 문자·영수증).
    static func note(_ entry: LedgerEntry, language: MapHomeLanguage) -> String {
        var parts: [String] = []
        if entry.currency != "KRW" { parts.append("\(entry.currency) \(LedgerTable.plain(entry.amount))") }
        if entry.transfer != nil { parts.append(language.text("여행 이체", "Trip transfer")) }
        let split = LedgerSummary.splitText(entry, language: language)
        if !split.isEmpty { parts.append(split) }
        if let place = entry.place, !place.isEmpty { parts.append(place) }
        if let memo = entry.note, !memo.isEmpty, entry.source != .message || memo != entry.title { parts.append(memo) }
        switch entry.source {
        case .manual: break
        case .assistant: parts.append("AI")
        case .message: parts.append(language.text("결제 문자", "Payment text"))
        case .receipt: parts.append(language.text("영수증", "Receipt"))
        }
        return parts.joined(separator: " · ")
    }

    static func dateText(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let format = DateFormatter()
        format.calendar = calendar; format.timeZone = calendar.timeZone; format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH:mm"
        return format.string(from: date)
    }

    /// 항목별 지출(원화). 이체는 빼고 큰 순서.
    static func byCategory(_ entries: [LedgerEntry], language: MapHomeLanguage) -> [(String, Double)] {
        let expenses = entries.filter { $0.kind == .expense && $0.transfer == nil }
        return Dictionary(grouping: expenses) { $0.category.title(language) }
            .map { ($0.key, $0.value.reduce(0) { $0 + ($1.amountKRW ?? 0) }) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
    }
}

/// CSV 내보내기도 표준 양식(엑셀·넘버스·구글 시트에서 한글이 깨지지 않게 BOM).
@MainActor
enum LedgerTable {
    static func csv(_ entries: [LedgerEntry], carryOver: Double = 0, title: String? = nil, language: MapHomeLanguage,
                    calendar: Calendar = .autoupdatingCurrent) -> String {
        var lines: [String] = []
        if let title { lines.append(cell(title)) }
        lines.append(LedgerStandard.header(language).map(cell).joined(separator: ","))
        lines.append([language.text("이월잔액", "Carried over"), "", "", "", "", "", plain(carryOver), ""].map(cell).joined(separator: ","))
        let rows = LedgerStandard.rows(entries, carryOver: carryOver, language: language)
        for row in rows {
            lines.append([
                LedgerStandard.dateText(row.date, calendar: calendar),
                row.isIncome ? language.text("수입", "Income") : language.text("지출", "Expense"),
                row.category, row.memo,
                row.isIncome ? plain(row.amount) : "", row.isIncome ? "" : plain(row.amount),
                plain(row.balance), row.note,
            ].map(cell).joined(separator: ","))
        }
        let income = rows.filter(\.isIncome).reduce(0) { $0 + $1.amount }, expense = rows.filter { !$0.isIncome }.reduce(0) { $0 + $1.amount }
        lines.append([language.text("합계", "Total"), "", "", "", plain(income), plain(expense), plain(carryOver + income - expense), ""].map(cell).joined(separator: ","))
        lines.append("")
        lines.append([language.text("항목별 지출", "Spending by category"), language.text("지출", "Expense"), language.text("비율", "Share")].map(cell).joined(separator: ","))
        let byCategory = LedgerStandard.byCategory(entries, language: language)
        let total = max(1, byCategory.reduce(0) { $0 + $1.1 })
        for (name, amount) in byCategory {
            lines.append([name, plain(amount), String(format: "%.1f%%", amount / total * 100)].map(cell).joined(separator: ","))
        }
        return "\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n"
    }

    /// 쉼표·따옴표·줄바꿈이 든 칸은 따옴표로 감싼다. =·+·-·@로 시작하면 계산식으로 열리지 않게 앞에 '를 붙인다.
    static func cell(_ value: String) -> String {
        var text = value
        if let first = text.first, "=+-@".contains(first), Double(text) == nil { text = "'" + text }
        guard text.contains(where: { ",\"\n\r".contains($0) }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func plain(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
    }
}

/// 공유 시트에 넘기는 표 파일. 누를 때 만든다.
struct LedgerTableFile: Transferable {
    let name: String
    let text: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { file in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(file.name)
            try Data(file.text.utf8).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

/// 하루 요약의 지출 칸(LED1111A04). 그날 지출이 없으면 아무것도 그리지 않는다.
struct LedgerDaySummarySection: View {
    let day: Date
    let language: MapHomeLanguage
    private var book: LedgerBook { .shared }

    var body: some View {
        let entries = book.entries(on: day).filter { $0.kind == .expense && $0.transfer == nil }.sorted { $0.occurredAt < $1.occurredAt }
        VStack(alignment: .leading, spacing: 10) {
            if !entries.isEmpty {
                HStack {
                    Label(language.text("지출", "Spending"), systemImage: "wonsign.circle.fill")
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                        .foregroundStyle(Color.tpSecondary)
                    Spacer()
                    Text(LedgerMoney.text(LedgerBook.total(entries, .expense), language: language))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .bold))
                        .foregroundStyle(Color.tpInk)
                }
                ForEach(entries) { entry in
                    HStack(spacing: 10) {
                        Image(systemName: entry.category.symbol)
                            .foregroundStyle(Color.tpAccent)
                            .frame(width: 24)
                        Text(entry.title).lineLimit(1).foregroundStyle(Color.tpInk)
                        Text(entry.occurredAt.formatted(date: .omitted, time: .shortened)).foregroundStyle(Color.tpSecondary)
                        Spacer()
                        Text(LedgerMoney.text(entry.amount, currency: entry.currency, language: language))
                            .monospacedDigit()
                            .foregroundStyle(Color.tpInk)
                    }
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .medium))
                }
            }
        }
        .task { await book.load() }
    }
}
