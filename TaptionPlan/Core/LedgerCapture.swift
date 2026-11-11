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
    private static let noise = ["누적", "잔액", "일시불", "할부", "Web발신", "web발신", "승인", "결제", "사용", "출금", "카드", "체크", "님", "*"]
    /// 결제가 아닌 카드사 안내(청구 예정·한도·쿠폰·광고). 이런 글은 기록 후보로 보지 않는다.
    static let notPayments = ["예정", "한도", "청구", "이용대금", "결제일", "쿠폰", "결제대금", "카드대금"]
    /// 결제가 되지 않았다는 글. 「승인」이 들어 있어도 지출이 아니다(「승인거절」).
    static let declined = ["거절", "한도초과", "잔액부족", "승인불가"]

    /// 광고 문자는 늘 빼고, 안내 낱말은 「승인」이 없을 때만 뺀다(승인 문자 끝의 혜택·청구할인 홍보 줄은 결제다).
    static func isNotice(_ text: String) -> Bool {
        if text.contains("(광고)") || text.contains("[광고]") || declined.contains(where: text.contains) { return true }
        return !text.contains("승인") && notPayments.contains(where: text.contains)
    }
    static let paymentWords = ["승인", "결제", "사용", "출금", "approved", "Approved"]

    /// 단축어 자동화가 모든 문자·알림을 넘겨도 가계부에 넣을 것만 고른다(SMA1111A01): 결제 낱말과 금액이 있고 안내·광고가 아닌 글.
    static func isPaymentCandidate(_ text: String) -> Bool {
        text.count <= 1_000 && paymentWords.contains(where: text.contains) && !isNotice(text) && amount(text) != nil
    }

    /// 문자 자동화와 앱 알림 자동화가 같은 결제를 두 번 넘기면 하나만 남긴다. 같은 금액·통화·종류가 10분 안에 이미 있으면 같은 결제다.
    static func isDuplicate(_ entry: LedgerEntry, in entries: [LedgerEntry]) -> Bool {
        entries.contains {
            $0.source == .message && $0.amount == entry.amount && $0.currency == entry.currency && $0.kind == entry.kind
                && abs($0.occurredAt.timeIntervalSince(entry.occurredAt)) <= 600
        }
    }
    private static let currencies = ["USD", "JPY", "EUR", "CNY", "TWD", "HKD", "THB", "VND", "SGD", "PHP", "IDR", "GBP", "AUD", "CAD"]

    static func parse(_ text: String, now: Date = .now, calendar: Calendar = .autoupdatingCurrent) -> Draft? {
        let flat = text.replacingOccurrences(of: "\r", with: "\n")
        // 은행 앱 알림은 「출금」으로 온다(SHT1111A01).
        guard flat.count <= 1_000, paymentWords.contains(where: flat.contains),
              !isNotice(flat) else { return nil }
        guard let money = amount(flat) else { return nil }
        let time = when(flat, now: now, calendar: calendar)
        return Draft(
            amount: money.value, currency: money.currency, merchant: merchant(flat, after: time?.range),
            card: card(flat).map { $0 + (flat.contains("체크") ? "체크" : "카드") },
            occurredAt: time?.date, isCancel: flat.contains("취소")
        )
    }

    /// `12,000원`·`USD 12.50`·`$12.50`. 누적·잔액 금액은 건너뛴다.
    static func amount(_ text: String) -> (value: Double, currency: String)? {
        for raw in text.split(separator: "\n").map(String.init) {
            // 같은 줄 뒤에 붙은 누적·잔액 금액은 앞까지만 본다.
            let line = ["누적", "잔액"].compactMap { raw.range(of: $0)?.lowerBound }.min().map { String(raw[..<$0]) } ?? raw
            if let value = wonAmounts(line).first?.value {
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
            line = strippingWon(line)
            line = line.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
            guard line.count >= 2, line.count <= 40, !noise.contains(where: line.contains), !startsWithCardName(line),
                  line.contains(where: \.isLetter) else { continue }
            return line
        }
        return inlineMerchant(text)
    }

    // MARK: 읽기 규칙 (PLN1111A01 제안 8-1)

    /// 카드사 이름 뒤에 이것이 오면 가게가 아니라 카드·은행 이름이다(「롯데카드」·「삼성1234」). 「롯데마트」·「하나로마트」는 가게다.
    private static let cardFollowers = ["카드", "체크", "은행", "뱅크", "페이"]

    private static func isCardName(_ name: String, followedBy rest: Substring) -> Bool {
        guard let next = rest.first else { return true }
        return next.isNumber || next == "(" || next == "[" || cardFollowers.contains(where: rest.hasPrefix)
    }

    static func startsWithCardName(_ line: String) -> Bool {
        cards.contains { line.hasPrefix($0) && isCardName($0, followedBy: line.dropFirst($0.count)) }
    }

    /// 글에서 가장 앞에 나온 카드사. 가게 이름 속 낱말(「삼성전자서비스」·「이삭토스트」)은 카드로 보지 않는다.
    /// 카드 이름이 맞는 자리: 뒤에 카드·체크·은행·숫자·괄호가 오거나, 줄 맨 앞·대괄호 안에서 낱말로 끝날 때.
    static func card(_ text: String) -> String? {
        var best: (index: String.Index, name: String)?
        for name in cards {
            var from = text.startIndex
            while let range = text.range(of: name, range: from..<text.endIndex) {
                from = range.upperBound
                let rest = text[range.upperBound...]
                let atStart = range.lowerBound == text.startIndex || ["\n", "[", "]"].contains(text[text.index(before: range.lowerBound)])
                    || (text[text.index(before: range.lowerBound)] == " " && text[..<range.lowerBound].last(where: { $0 != " " }) == "]")
                let endsWord = rest.first.map { $0 == " " || $0 == "]" || $0 == "\n" } ?? true
                guard cardFollowers.contains(where: rest.hasPrefix) || rest.first.map({ $0.isNumber || $0 == "(" }) == true || (atStart && endsWord) else { continue }
                if best == nil || range.lowerBound < best!.index || (range.lowerBound == best!.index && name.count > best!.name.count) {
                    best = (range.lowerBound, name)
                }
                break
            }
        }
        return best?.name
    }

    /// 「원」 뒤에 올 수 있는 말. 그 밖의 한글이 이어지면 금액이 아니라 낱말이다(「원조국밥」·「원효로점」).
    private static let wonParticles = ["입니다", "을", "이 ", "에 ", "어치", "이며", "으로", "의 ", "짜리", "정", "만 ", "씩",
                                       "승인", "결제", "사용", "출금", "입금", "취소", "일시불", "할부"]

    /// 줄 안의 원화 금액. 시각 `12:30` 뒤 「원조」처럼 앞이 시각·숫자이거나 뒤가 낱말이면 금액이 아니다.
    static func wonAmounts(_ line: String) -> [(value: Double, range: Range<String.Index>)] {
        line.matches(of: /([0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)\s*원/).compactMap { match in
            if match.range.lowerBound > line.startIndex {
                // 「12:30 원조」의 30처럼 숫자에 이어진 조각만 거른다. 「금액:12,000원」의 쌍점은 금액 앞 구두점이다.
                let before = line.index(before: match.range.lowerBound), previous = line[before]
                if previous.isNumber { return nil }
                if [":", ".", ","].contains(previous), before > line.startIndex, line[line.index(before: before)].isNumber { return nil }
            }
            let rest = line[match.range.upperBound...]
            if let next = rest.first, ("가"..."힣").contains(next), !wonParticles.contains(where: rest.hasPrefix) { return nil }
            guard let value = number(String(match.1)), value > 0 else { return nil }
            return (value, match.range)
        }
    }

    static func strippingWon(_ line: String) -> String {
        var result = line
        for amount in wonAmounts(line).reversed() { result.removeSubrange(amount.range) }
        return result
    }

    /// 한 줄짜리 앱 알림(「KB국민은행 출금 12,000원 스타벅스강남 잔액 …」)의 가게: 금액이 있는 줄에서
    /// 잔액·누적 뒤를 자르고 금액·카드 이름·결제 낱말·시각을 뺀 나머지.
    static func inlineMerchant(_ text: String) -> String? {
        for raw in text.split(separator: "\n").map(String.init) where !wonAmounts(raw).isEmpty {
            let head = ["누적", "잔액"].compactMap { raw.range(of: $0)?.lowerBound }.min().map { String(raw[..<$0]) } ?? raw
            let words = strippingWon(head).split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters) }.filter { word in
                word.contains(where: \.isLetter) && !noise.contains(where: word.contains) && !startsWithCardName(word)
            }
            let name = words.joined(separator: " ")
            if name.count >= 2, name.count <= 40 { return name }
        }
        return nil
    }

    /// 결제로 보이는 글인가(금액을 못 읽었더라도). 붙여넣기·영수증에서 AI에게 맡기기 전에 본다: 결제 아닌 글은 보내지 않는다.
    static func looksLikePayment(_ text: String) -> Bool {
        guard text.count <= 4_000, !isNotice(text), text.contains(where: \.isNumber) else { return false }
        let upper = text.uppercased()
        return paymentWords.contains(where: text.contains)
            || LedgerReceiptReader.totalWords.contains { upper.contains($0.uppercased()) }
            || (["₩", "$", "¥", "円", "€", "£", "元", "SUMME", "SUMA", "TOTALE"] + currencies).contains(where: upper.contains)
            || text.split(separator: "\n").contains { !wonAmounts(String($0)).isEmpty }
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

    static func isTotalLine(_ line: String) -> Bool {
        let upper = line.uppercased()
        return totalWords.contains(where: line.contains) && !upper.contains("SUBTOTAL") && !upper.contains("SUB TOTAL") && !line.contains("소계")
    }

    /// 글자 속 통화 표시. 없으면 원.
    static func currency(_ lines: [String]) -> String {
        let text = lines.joined(separator: " ")
        if text.contains("¥") || text.contains("円") || text.contains("合計") { return "JPY" }
        if text.contains("€") { return "EUR" }
        if text.contains("$") || text.contains("USD") { return "USD" }
        if text.contains("合计") || text.contains("元") { return "CNY" }
        return "KRW"
    }

    static func recognize(_ image: CGImage) async -> [String] {
        // perform은 동기라 끝나면 결과가 request에 있다. 완료 처리기 없이 읽어 이어 받기를 한 번만 한다.
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ko-KR", "en-US", "ja-JP", "zh-Hans"]
        request.usesLanguageCorrection = false
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return [] }
        return request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
    }

    /// 합계 줄의 금액(그 줄에 없으면 다음 줄). 합계 줄이 없으면 가장 큰 금액. 가게 이름은 첫 글자 줄.
    static func draft(_ lines: [String]) -> LedgerMessageParser.Draft? {
        var total: Double?
        for (index, line) in lines.enumerated() where isTotalLine(line) {
            let candidates = [line] + (lines.indices.contains(index + 1) ? [lines[index + 1]] : [])
            if let value = candidates.lazy.compactMap(largestNumber).first { total = value; break }
        }
        // 합계 줄이 없으면 「원」이 붙은 금액 가운데 가장 큰 것만. 승인 번호·사업자 번호·날짜를 금액으로 잡지 않는다.
        let fallback = lines.compactMap { line in line.firstMatch(of: /([0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)\s*원/).flatMap { LedgerMessageParser.number(String($0.1)) } }.max()
        guard let amount = total ?? fallback, amount > 0 else { return nil }
        let merchant = lines.first { line in
            line.count >= 2 && line.count <= 30 && line.contains(where: \.isLetter) && !line.contains(where: \.isNumber)
        }
        return .init(amount: amount, currency: currency(lines), merchant: merchant, card: nil, occurredAt: nil, isCancel: false)
    }

    static func largestNumber(_ line: String) -> Double? {
        // 소수 둘째 자리 금액(45.99)도 읽는다. 아홉 자리 넘는 번호는 금액이 아니다.
        line.matches(of: /[0-9]{1,3}(?:,[0-9]{3})+(?:\.[0-9]{2})?|[0-9]{1,8}\.[0-9]{2}|[0-9]{3,8}/)
            .compactMap { LedgerMessageParser.number(String($0.output)) }.max()
    }
}
