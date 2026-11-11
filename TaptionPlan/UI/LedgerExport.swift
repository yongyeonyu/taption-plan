import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// 가계부를 표로 내보낸다(LED1111A04, 대표 지시 2026-11-11). 엑셀·넘버스·구글 시트에서 바로 열리는 CSV(UTF-8, 한글 깨짐 방지 BOM).
@MainActor
enum LedgerTable {
    static func header(_ language: MapHomeLanguage) -> [String] {
        [
            language.text("날짜", "Date"), language.text("시각", "Time"), language.text("종류", "Type"),
            language.text("분류", "Category"), language.text("내용", "What"), language.text("금액", "Amount"),
            language.text("통화", "Currency"), language.text("원화", "KRW"), language.text("낸 사람", "Paid by"),
            language.text("장소", "Place"), language.text("메모", "Note"), language.text("들어온 길", "Source"),
        ]
    }

    static func csv(_ entries: [LedgerEntry], language: MapHomeLanguage, calendar: Calendar = .autoupdatingCurrent) -> String {
        let day = DateFormatter(), time = DateFormatter()
        day.calendar = calendar; day.timeZone = calendar.timeZone; day.locale = Locale(identifier: "en_US_POSIX"); day.dateFormat = "yyyy-MM-dd"
        time.calendar = calendar; time.timeZone = calendar.timeZone; time.locale = Locale(identifier: "en_US_POSIX"); time.dateFormat = "HH:mm"
        var lines = [header(language).map(cell).joined(separator: ",")]
        for entry in entries.sorted(by: { $0.occurredAt < $1.occurredAt }) {
            lines.append([
                day.string(from: entry.occurredAt), time.string(from: entry.occurredAt),
                entry.kind == .expense ? language.text("지출", "Expense") : language.text("수입", "Income"),
                entry.category.title(language), entry.title, plain(entry.amount), entry.currency,
                entry.amountKRW.map(plain) ?? "", entry.payer ?? "", entry.place ?? "", entry.note ?? "", source(entry.source, language),
            ].map(cell).joined(separator: ","))
        }
        let spent = LedgerBook.total(entries, .expense), earned = LedgerBook.total(entries, .income)
        lines.append("")
        lines.append([language.text("지출 합계", "Total spent"), "", "", "", "", "", "KRW", plain(spent)].map(cell).joined(separator: ","))
        lines.append([language.text("수입 합계", "Total income"), "", "", "", "", "", "KRW", plain(earned)].map(cell).joined(separator: ","))
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

    private static func source(_ source: LedgerEntry.Source, _ language: MapHomeLanguage) -> String {
        switch source {
        case .manual: language.text("직접", "Manual")
        case .assistant: "AI"
        case .message: language.text("결제 문자", "Payment text")
        case .receipt: language.text("영수증", "Receipt")
        }
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
        let entries = book.entries(on: day).filter { $0.kind == .expense }.sorted { $0.occurredAt < $1.occurredAt }
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
