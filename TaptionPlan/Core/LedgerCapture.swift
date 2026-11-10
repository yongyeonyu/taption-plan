import Foundation
import Vision

/// 카드 결제 문자를 가계부 기록 후보로 읽는다(LED1110A01 결제 감지). iOS는 다른 앱 문자를 못 읽으므로
/// 사용자가 붙여 넣거나 단축어 「메시지를 받을 때」 자동화가 넘긴 글만 본다. 모르는 형식은 nil이라 직접 고친다.
enum LedgerMessageParser {
    struct Draft: Equatable, Sendable {
        var amount: Double
        var currency: String
        var merchant: String?
        var card: String?
        var occurredAt: Date?
        var isCancel: Bool
    }

    static let cards = ["KB국민", "국민", "신한", "삼성", "현대", "롯데", "우리", "하나", "BC", "비씨", "NH농협", "농협", "씨티", "카카오뱅크", "카카오페이", "토스", "IBK", "기업"]
    private static let noise = ["누적", "잔액", "일시불", "할부", "Web발신", "web발신", "승인", "결제", "사용", "카드", "체크", "님", "*"]
    private static let currencies = ["USD", "JPY", "EUR", "CNY", "TWD", "HKD", "THB", "VND", "SGD", "PHP", "IDR", "GBP", "AUD", "CAD"]

    static func parse(_ text: String, now: Date = .now, calendar: Calendar = .autoupdatingCurrent) -> Draft? {
        let flat = text.replacingOccurrences(of: "\r", with: "\n")
        guard flat.count <= 1_000, ["승인", "결제", "사용", "approved", "Approved"].contains(where: flat.contains) else { return nil }
        guard let money = amount(flat) else { return nil }
        let time = when(flat, now: now, calendar: calendar)
        return Draft(
            amount: money.value, currency: money.currency, merchant: merchant(flat, after: time?.range),
            card: cards.first { flat.contains($0) }.map { $0 + (flat.contains("체크") ? "체크" : "카드") },
            occurredAt: time?.date, isCancel: flat.contains("취소")
        )
    }

    /// `12,000원`·`USD 12.50`·`$12.50`. 누적·잔액 금액은 건너뛴다.
    static func amount(_ text: String) -> (value: Double, currency: String)? {
        for raw in text.split(separator: "\n").map(String.init) {
            // 같은 줄 뒤에 붙은 누적·잔액 금액은 앞까지만 본다.
            let line = ["누적", "잔액"].compactMap { raw.range(of: $0)?.lowerBound }.min().map { String(raw[..<$0]) } ?? raw
            if let match = line.firstMatch(of: /([0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)\s*원/), let value = number(String(match.1)), value > 0 {
                return (value, "KRW")
            }
            for code in currencies {
                if let regex = try? Regex("\(code)\\s*([0-9][0-9,]*(?:\\.[0-9]+)?)"), let match = line.firstMatch(of: regex),
                   let value = match.output[1].substring.flatMap({ number(String($0)) }), value > 0 {
                    return (value, code)
                }
            }
            if let match = line.firstMatch(of: /\$\s*([0-9][0-9,]*(?:\.[0-9]+)?)/), let value = number(String(match.1)), value > 0 {
                return (value, "USD")
            }
        }
        return nil
    }

    /// `11/10 12:30`. 연도는 지금 기준이고, 미래가 되면 작년으로 본다.
    static func when(_ text: String, now: Date, calendar: Calendar) -> (date: Date, range: Range<String.Index>)? {
        guard let match = text.firstMatch(of: /(\d{1,2})[\/.-](\d{1,2})\s+(\d{1,2}):(\d{2})/),
              let month = Int(match.1), let day = Int(match.2), let hour = Int(match.3), let minute = Int(match.4),
              (1...12).contains(month), (1...31).contains(day), (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        var parts = DateComponents(year: calendar.component(.year, from: now), month: month, day: day, hour: hour, minute: minute)
        guard var date = calendar.date(from: parts) else { return nil }
        if date > now.addingTimeInterval(86_400) {
            parts.year = (parts.year ?? 0) - 1
            date = calendar.date(from: parts) ?? date
        }
        return (date, match.range)
    }

    /// 시각 뒤 같은 줄, 없으면 다음 줄들 가운데 잡음이 아닌 첫 글.
    static func merchant(_ text: String, after range: Range<String.Index>?) -> String? {
        let tail = range.map { String(text[$0.upperBound...]) } ?? text
        for raw in tail.split(separator: "\n").map(String.init) {
            var line = raw
            if let cut = line.range(of: "누적") { line = String(line[..<cut.lowerBound]) }
            line = line.replacing(/([0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)\s*원/, with: "")
            line = line.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
            guard line.count >= 2, line.count <= 40, !noise.contains(where: line.contains), !cards.contains(where: line.hasPrefix),
                  line.contains(where: \.isLetter) else { continue }
            return line
        }
        return nil
    }

    static func number(_ text: String) -> Double? { Double(text.replacingOccurrences(of: ",", with: "")) }

    /// 기록 후보. 취소 문자는 수입(환불)으로 둔다.
    static func entry(_ draft: Draft, now: Date = .now, source: LedgerEntry.Source = .message) -> LedgerEntry {
        let title = draft.merchant ?? draft.card ?? "결제"
        return LedgerEntry(
            occurredAt: draft.occurredAt ?? now, amount: draft.amount, currency: draft.currency,
            kind: draft.isCancel ? .income : .expense, category: draft.isCancel ? .other : LedgerCategory.guess(title),
            title: title, note: draft.card, source: source
        )
    }
}

/// 영수증 사진의 글자를 기기에서 읽어 합계를 찾는다(Vision). 사진·글은 남기지 않는다.
enum LedgerReceiptReader {
    static let totalWords = ["합계", "총액", "총 금액", "받을금액", "받을 금액", "결제금액", "결제 금액", "판매금액", "TOTAL", "Total", "AMOUNT", "合計", "合计"]

    static func recognize(_ image: CGImage) async -> [String] {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let lines = (request.results as? [VNRecognizedTextObservation])?.compactMap { $0.topCandidates(1).first?.string } ?? []
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["ko-KR", "en-US", "ja-JP", "zh-Hans"]
            request.usesLanguageCorrection = false
            do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch { continuation.resume(returning: []) }
        }
    }

    /// 합계 줄의 금액(그 줄에 없으면 다음 줄). 합계 줄이 없으면 가장 큰 금액. 가게 이름은 첫 글자 줄.
    static func draft(_ lines: [String]) -> LedgerMessageParser.Draft? {
        var total: Double?
        for (index, line) in lines.enumerated() where totalWords.contains(where: line.contains) {
            let candidates = [line] + (lines.indices.contains(index + 1) ? [lines[index + 1]] : [])
            if let value = candidates.lazy.compactMap(largestNumber).first { total = value; break }
        }
        guard let amount = total ?? lines.compactMap(largestNumber).max(), amount > 0 else { return nil }
        let merchant = lines.first { line in
            line.count >= 2 && line.count <= 30 && line.contains(where: \.isLetter) && !line.contains(where: \.isNumber)
        }
        return .init(amount: amount, currency: "KRW", merchant: merchant, card: nil, occurredAt: nil, isCancel: false)
    }

    static func largestNumber(_ line: String) -> Double? {
        line.matches(of: /[0-9]{1,3}(?:,[0-9]{3})+|[0-9]{3,8}/).compactMap { LedgerMessageParser.number(String($0.output)) }.max()
    }
}
