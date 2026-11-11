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

    static let cards = ["KB국민", "국민", "신한", "삼성", "현대", "롯데", "우리", "KEB하나", "하나", "BC", "비씨", "NH농협", "농협", "씨티", "카카오뱅크", "카카오페이",
                        "토스뱅크", "토스페이", "토스", "케이뱅크", "네이버페이", "IBK", "기업", "SC제일", "우체국", "새마을금고", "새마을", "신협", "수협", "KB", "NH", "MG"]
    /// 지방 은행은 가게 이름에도 흔한 지명이라 뒤에 카드·은행·BC가 붙을 때만 카드 이름이다(「부산BC」·「광주은행」).
    private static let regionalBanks = ["부산", "대구", "광주", "전북", "경남", "제주", "iM", "아이엠"]
    /// 결제가 아닌 카드사 안내(청구 예정·한도·쿠폰·광고). 이런 글은 기록 후보로 보지 않는다.
    static let notPayments = ["예정", "한도", "청구", "이용대금", "결제일", "쿠폰", "결제대금", "카드대금"]
    /// 결제가 되지 않았다는 글. 「승인」이 들어 있어도 지출이 아니다(「승인거절」).
    static let declined = ["거절", "한도초과", "잔액부족", "승인불가", "승인오류"]
    /// 「승인」이 있어도 결제 한 건이 아닌 글: 광고, 인증 번호, 나라 밖에서 온 사칭 문자, 가맹점 매출 집계.
    private static let neverPayments = ["(광고)", "[광고]", "인증번호", "국제발신", "집계"]

    /// 광고·거절·집계 문자는 늘 빼고, 안내 낱말은 「승인」이 없을 때만 뺀다(승인 문자 끝의 혜택·청구할인 홍보 줄은 결제다).
    static func isNotice(_ text: String) -> Bool {
        if neverPayments.contains(where: text.contains) || declined.contains(where: text.contains) { return true }
        // 「12건 340,000원」처럼 여러 건을 묶은 글. 「GS25건대점」의 「5건」은 아니다.
        if text.contains(/(?:^|\s)[0-9]+건(?:\s|$)/) { return true }
        return !text.contains("승인") && notPayments.contains(where: text.contains)
    }
    static let paymentWords = ["승인", "결제", "사용", "출금", "approved", "Approved"]
    /// 결제 낱말 없이 오는 카드 문자(KB·하나·롯데)는 카드 이름과 이 낱말로 알아본다.
    private static let cardSigns = ["일시불", "할부", "누적", "취소", "정상처리"]

    /// 결제를 알리는 글인가. 「입출금통장」의 「출금」은 세지 않는다.
    private static func hasPaymentSign(_ text: String) -> Bool {
        let plain = text.replacingOccurrences(of: "입출금", with: "")
        if paymentWords.contains(where: plain.contains) || plain.contains("W/D:") || plain.contains(/PAY\s+[0-9]/) { return true }
        // 옛 은행 문자의 「지급 20,000원」, 송금 알림의 「…에게 30,000원을 보냈어요」.
        if plain.contains(/(?:^|\n)지급\s*[0-9]/), !plain.contains("보험") { return true }
        if plain.contains(/에게\s+[0-9,]+원을?\s*보냈/) { return true }
        return card(text) != nil && cardSigns.contains(where: plain.contains)
    }

    /// 단축어 자동화가 모든 문자·알림을 넘겨도 가계부에 넣을 것만 고른다(SMA1111A01): 결제 낱말과 금액이 있고 안내·광고가 아닌 글.
    static func isPaymentCandidate(_ text: String) -> Bool {
        text.count <= 1_000 && hasPaymentSign(text) && !isNotice(text) && amount(text) != nil
    }

    /// 문자 자동화와 앱 알림 자동화가 같은 결제를 두 번 넘기면 하나만 남긴다. 같은 금액·통화·종류가 10분 안에 이미 있으면 같은 결제다.
    static func isDuplicate(_ entry: LedgerEntry, in entries: [LedgerEntry]) -> Bool {
        entries.contains {
            $0.source == .message && $0.amount == entry.amount && $0.currency == entry.currency && $0.kind == entry.kind
                && abs($0.occurredAt.timeIntervalSince(entry.occurredAt)) <= 600
        }
    }
    private static let currencies = ["USD", "JPY", "EUR", "CNY", "TWD", "HKD", "THB", "VND", "SGD", "PHP", "IDR", "GBP", "AUD", "CAD"]
    /// 해외 승인 문자에만 쓰는 통화. 「KRW 39,050 해외승인」은 원화다.
    private static let messageCurrencies = currencies + ["KRW", "RUB", "CHF", "MYR", "NZD", "MOP", "INR", "AED", "TRY", "MXN", "SEK", "NOK", "DKK"]
    private static let currencyWords = ["US$": "USD", "달러": "USD", "유로": "EUR", "엔": "JPY", "위안": "CNY"]

    static func parse(_ text: String, now: Date = .now, calendar: Calendar = .autoupdatingCurrent) -> Draft? {
        let flat = text.replacingOccurrences(of: "\r", with: "\n")
        // 은행 앱 알림은 「출금」으로 온다(SHT1111A01).
        guard flat.count <= 1_000, hasPaymentSign(flat), !isNotice(flat) else { return nil }
        guard let money = amount(flat) else { return nil }
        let time = when(flat, now: now, calendar: calendar)
        return Draft(
            amount: money.value, currency: money.currency, merchant: merchant(flat, after: time?.range),
            card: card(flat).map { cardLabel($0, in: flat) },
            occurredAt: time?.date, isCancel: flat.contains("취소")
        )
    }

    /// 「카카오뱅크」·「네이버페이」는 그대로, 은행 문자는 「○○은행」, 나머지는 체크·카드를 붙인다.
    private static func cardLabel(_ name: String, in text: String) -> String {
        if ["뱅크", "페이", "금고", "우체국"].contains(where: name.hasSuffix) { return name }
        if text.contains(name + "은행") || (text.contains("출금") && !text.contains("카드") && !text.contains("체크")) { return name + "은행" }
        return name + (text.contains("체크") ? "체크" : "카드")
    }

    /// `12,000원`·`USD 12.50`·`$12.50`. 누적·잔액 금액은 건너뛴다. 「원」 없는 은행 출금 금액은 다른 금액이 없을 때만 본다.
    static func amount(_ text: String) -> (value: Double, currency: String)? {
        let lines = strippingBalances(text).split(separator: "\n").map(String.init)
        for line in lines {
            if let value = wonAmounts(line).first?.value { return (value, "KRW") }
            if let foreign = foreignAmount(line) { return (foreign.value, foreign.currency) }
        }
        return lines.lazy.compactMap { bareAmounts($0).first?.value }.first.map { ($0, "KRW") }
    }

    /// 누적·잔액·가용액·잔여한도·포인트와 그 금액(다음 줄에 있어도)을 지운다. 날짜·시각 앞 숫자는 건드리지 않는다.
    private static func strippingBalances(_ text: String) -> String {
        text.replacing(/(?:계좌잔액|총누적|누적금액|누적|잔액|가용액|잔여한도|잔여|한도|포인트|\bBal\.?|\bBAL)\s*[:：]?\s*-?[0-9][0-9,]*(?:\.[0-9]+)?(?![\/:0-9])\s*(?:원|WON)?/, with: " ")
    }

    /// `USD 22.00`·`475.54(US$)`·`5.00 달러`·`$12.50` 가운데 줄에서 가장 앞에 나온 것.
    private static func foreignAmount(_ line: String) -> (value: Double, currency: String, range: Range<String.Index>)? {
        var found: [(value: Double, currency: String, range: Range<String.Index>)] = []
        for match in line.matches(of: /([A-Z]{3})\s*([0-9][0-9,]*(?:\.[0-9]+)?)/) where messageCurrencies.contains(String(match.1)) {
            // 「USD 11/10」의 11은 날짜다. 「XUSD」처럼 낱말 속 글자는 통화가 아니다.
            let next = line[match.range.upperBound...].first
            if next == "/" || next == ":" || character(before: match.range.lowerBound, in: line)?.isLetter == true { continue }
            if let value = number(String(match.2)), value > 0 { found.append((value, String(match.1), match.range)) }
        }
        for match in line.matches(of: /([0-9][0-9,]*(?:\.[0-9]+)?)\s*\(?(US\$|[A-Z]{3}|달러|유로|엔|위안)/) {
            let code = String(match.2), next = line[match.range.upperBound...].first
            guard let currency = currencyWords[code] ?? (messageCurrencies.contains(code) ? code : nil), !isNumberTail(match.range.lowerBound, in: line),
                  next.map({ !$0.isLetter }) ?? true, let value = number(String(match.1)), value > 0 else { continue }
            found.append((value, currency, match.range))
        }
        if let match = line.firstMatch(of: /\$\s*([0-9][0-9,]*(?:\.[0-9]+)?)/), let value = number(String(match.1)), value > 0 {
            found.append((value, "USD", match.range))
        }
        return found.min { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// 「원」 없이 온 원화 금액: `출금 10,450`·`W/D:1,000`·금액만 있는 줄 `4,350`·취소 `-109,650`.
    private static func bareAmounts(_ line: String) -> [(value: Double, range: Range<String.Index>)] {
        var ranges: [Range<String.Index>] = []
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.wholeMatch(of: /[0-9]{1,3}(?:,[0-9]{3})+/) != nil, let range = line.range(of: trimmed) { ranges.append(range) }
        for match in line.matches(of: /(?:출금|W\/D:)\s*([0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?=\s|$)/) {
            ranges.append(match.1.startIndex..<match.1.endIndex)
        }
        for match in line.matches(of: /(?:^|[\s(])(-[0-9]{1,3}(?:,[0-9]{3})+)(?=[\s)]|$)/) {
            ranges.append(match.1.startIndex..<match.1.endIndex)
        }
        return ranges.compactMap { range in
            number(line[range].trimmingCharacters(in: ["-"])).flatMap { $0 > 0 ? ($0, range) : nil }
        }
    }

    private static func character(before index: String.Index, in text: String) -> Character? {
        index > text.startIndex ? text[text.index(before: index)] : nil
    }

    /// 숫자에 이어진 조각인가. 「12:30 원조」의 30, 「1,234.50」의 50처럼 앞이 숫자나 숫자 뒤 구두점이면 금액의 시작이 아니다.
    private static func isNumberTail(_ index: String.Index, in line: String) -> Bool {
        guard let previous = character(before: index, in: line) else { return false }
        if previous.isNumber { return true }
        return [":", ".", ",", "/"].contains(previous) && character(before: line.index(before: index), in: line)?.isNumber == true
    }

    /// `11/10 12:30`·`04/08.23:07`·`09/11,02:37`·`07/29 [11:24]`·`2021/08/19 04:55`·`0401 13:00`. 날짜와 시각이 다 있을 때만 읽는다.
    /// 연도가 없으면 지금 기준이고, 미래가 되면 작년으로 본다.
    static func when(_ text: String, now: Date, calendar: Calendar) -> (date: Date, range: Range<String.Index>)? {
        for match in text.matches(of: /(?:(\d{4})[\/.-])?(\d{1,2})[\/.-](\d{1,2})(?:[\s.,]+\[?|\[)(\d{1,2}):(\d{2})/) {
            if character(before: match.range.lowerBound, in: text)?.isNumber == true { continue }
            if let date = date(year: match.1.flatMap { Int($0) }, [match.2, match.3, match.4, match.5], now: now, calendar: calendar) { return (date, match.range) }
        }
        for match in text.matches(of: /(?:^|[\s\]])((\d{2})(\d{2})\s+(\d{1,2}):(\d{2}))/) {
            if let date = date(year: nil, [match.2, match.3, match.4, match.5], now: now, calendar: calendar) { return (date, match.1.startIndex..<match.1.endIndex) }
        }
        return nil
    }

    private static func date(year: Int?, _ fields: [Substring], now: Date, calendar: Calendar) -> Date? {
        let values = fields.compactMap { Int($0) }
        guard values.count == 4, (1...12).contains(values[0]), (1...31).contains(values[1]), (0..<24).contains(values[2]), (0..<60).contains(values[3]) else { return nil }
        var parts = DateComponents(year: year ?? calendar.component(.year, from: now), month: values[0], day: values[1], hour: values[2], minute: values[3])
        guard var date = calendar.date(from: parts) else { return nil }
        if year == nil, date > now.addingTimeInterval(86_400) {
            parts.year = (parts.year ?? 0) - 1
            date = calendar.date(from: parts) ?? date
        }
        return date
    }

    /// 「사용처」 줄이 있으면 그것, 아니면 시각 뒤의 첫 이름, 그것도 없으면 시각 앞의 마지막 이름(롯데·KB처럼 가게가 먼저 오는 문자).
    /// 시각이 없으면 금액을 기준으로 같은 순서로 찾는다. 확실하지 않으면 nil이다.
    static func merchant(_ text: String, after range: Range<String.Index>?) -> String? {
        if let name = labelledMerchant(text) ?? sentenceMerchant(text) { return name }
        var before = marking(text), after = ""
        if let range {
            before = marking(String(text[..<range.lowerBound]))
            after = marking(String(text[range.upperBound...]))
        } else if let cut = before.firstIndex(of: mark) {
            after = String(before[before.index(after: cut)...])
            before = String(before[..<cut])
        } else {
            return nil
        }
        return names(in: after, afterAnchor: true).first ?? names(in: before, afterAnchor: false).last
    }

    // MARK: 읽기 규칙 (PLN1111A01 제안 8-1)

    /// 카드사 이름 뒤에 이것이 오면 가게가 아니라 카드·은행 이름이다(「롯데카드」·「삼성1234」). 「롯데마트」·「하나로마트」는 가게다.
    private static let cardFollowers = ["카드", "체크", "은행", "뱅크", "페이", "BC", "법인", "가족"]

    private static func isCardName(_ name: String, followedBy rest: Substring) -> Bool {
        if cardFollowers.contains(where: rest.hasPrefix) { return true }
        guard !regionalBanks.contains(name), let next = rest.first else { return !regionalBanks.contains(name) }
        return next.isNumber || next == "(" || next == "[" || next == "*"
    }

    static func startsWithCardName(_ line: String) -> Bool {
        (cards + regionalBanks).contains { line.hasPrefix($0) && isCardName($0, followedBy: line.dropFirst($0.count)) }
    }

    /// 글에서 가장 앞에 나온 카드사. 가게 이름 속 낱말(「삼성전자서비스」·「이삭토스트」)은 카드로 보지 않는다.
    /// 카드 이름이 맞는 자리: 뒤에 카드·체크·은행·숫자·괄호가 오거나, 줄 맨 앞·대괄호 안에서 낱말로 끝날 때.
    static func card(_ text: String) -> String? {
        var best: (index: String.Index, name: String)?
        for name in cards + regionalBanks {
            var from = text.startIndex
            while let range = text.range(of: name, range: from..<text.endIndex) {
                from = range.upperBound
                let rest = text[range.upperBound...], regional = regionalBanks.contains(name)
                let atStart = range.lowerBound == text.startIndex || ["\n", "[", "]"].contains(text[text.index(before: range.lowerBound)])
                    || (text[text.index(before: range.lowerBound)] == " " && text[..<range.lowerBound].last(where: { $0 != " " }) == "]")
                let endsWord = rest.first.map { $0 == " " || $0 == "]" || $0 == "\n" || $0 == "," } ?? true
                let masked = rest.first.map { $0.isNumber || $0 == "(" || $0 == "*" } == true
                guard cardFollowers.contains(where: rest.hasPrefix) || (!regional && (masked || (atStart && endsWord))) else { continue }
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

    /// 줄 안의 원화 금액(`12,000원`·`2,500 원`·`25,000WON`). 시각 `12:30` 뒤 「원조」처럼 앞이 시각·숫자이거나 뒤가 낱말이면 금액이 아니다.
    static func wonAmounts(_ line: String) -> [(value: Double, range: Range<String.Index>)] {
        line.matches(of: /([0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)\s*(?:원|WON)/).compactMap { match in
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
    /// 잔액·누적·금액·카드 이름·결제 낱말·시각을 뺀 나머지.
    static func inlineMerchant(_ text: String) -> String? {
        text.split(separator: "\n").map(String.init).lazy.filter { !wonAmounts($0).isEmpty }.compactMap { merchant($0, after: nil) }.first
    }

    // MARK: 가게 이름 찾기

    /// 금액이 있던 자리 표시. 가게를 금액 앞뒤로 나눠 찾는 데 쓴다.
    private static let mark: Character = "\u{1}"
    private static let sentenceEnds = ["어요", "습니다", "합니다", "입니다", "세요"]
    private static let merchantLabels = ["사용처", "가맹점명", "이용가맹점", "이용처", "가맹점"]
    /// 가게 이름이 아닌 문자 틀 낱말. 조각이 이 낱말과 카드 이름·숫자만으로 되어 있으면 가게가 아니다.
    private static let frameWords = (["승인", "취소", "결제", "사용", "출금", "지급", "이용건", "이용", "체크", "카드", "신용", "해외", "국내", "일시불", "할부", "개월",
                                      "완료", "자동", "접수", "정상", "처리", "되었습니다", "내역", "안내", "법인", "가족", "개인", "금액", "고객명", "손님명",
                                      "승인시각", "거래시간", "거래종류", "거래구분", "번호입력", "은행", "뱅크", "통장", "입출금", "계좌", "지원금", "지역화폐",
                                      "포인트", "적립", "예정", "할인", "누적", "잔액", "Web발신", "달러", "유로", "위안"]
        + cards.filter { !$0.hasSuffix("페이") } + regionalBanks.flatMap { name in cardFollowers.map { name + $0 } }).sorted { $0.count > $1.count }
    /// 틀 낱말을 지우고 남은 영문이 이것뿐이면 역시 틀이다(「NH카드」의 NH, 「(US$)」의 US, 「W/D:」).
    private static let frameLetters = Set(["KB", "NH", "MG", "IBK", "SC", "BC", "KEB", "WOORI", "HANABANK", "RE", "US", "WD"] + messageCurrencies)
    private static let bankLetters: Set = ["KB", "NH", "MG", "IBK", "SC", "BC", "KEB", "WOORI", "HANABANK"]

    /// 가게를 찾기 좋게 다듬는다: 대괄호 머리말·잔액·한글 날짜·나라 표시를 지우고 금액 자리에 표시를 둔다.
    private static func marking(_ text: String) -> String {
        let plain = strippingBalances(text.replacing(/\[[^\]\n]*\]/, with: " "))
            .replacing(/(?:\d{4}년\s*)?\d{1,2}월\s*\d{1,2}일|\([A-Z]{2}\)|\(￦\)/, with: " ")
        return plain.split(separator: "\n", omittingEmptySubsequences: false).map { part in
            var line = String(part)
            let ranges = (wonAmounts(line) + bareAmounts(line)).map(\.range) + [foreignAmount(line)?.range].compactMap { $0 }
            for range in ranges.sorted(by: { $0.lowerBound > $1.lowerBound }) where !ranges.contains(where: { $0 != range && $0.overlaps(range) && $0.lowerBound < range.lowerBound }) {
                line.replaceSubrange(range, with: " \(mark) ")
            }
            return line
        }.joined(separator: "\n")
    }

    /// 조각에서 이름 가림(「홍*동님」)과 틀 낱말을 지우고 남은 글자.
    private static func lettersLeft(_ token: String) -> String {
        var rest = token.replacing(/[가-힣]{1,2}\*[가-힣]{0,2}님?/, with: "")
        for word in frameWords { rest = rest.replacingOccurrences(of: word, with: "") }
        return rest.filter(\.isLetter)
    }

    private static func isFrame(_ token: String) -> Bool {
        if token == "PAY" || token.contains(mark) || token.wholeMatch(of: /[가-힣]{2,4}님[.,]?/) != nil { return true }
        // 말로 쓴 알림의 끝말(「출금되었어요.」)은 가게가 아니다.
        if sentenceEnds.contains(where: token.trimmingCharacters(in: .punctuationCharacters).hasSuffix) { return true }
        let left = lettersLeft(token)
        return left.isEmpty || frameLetters.contains(left)
    }

    /// 카드·은행 이름이 든 틀 조각(「현대카드」·「KB*카드」). 바로 뒤 글은 카드 상품 이름일 수 있다(「현대 ZERO」).
    private static func isCardFrame(_ token: String) -> Bool {
        isFrame(token) && ((cards + regionalBanks).contains(where: token.contains) || bankLetters.contains(lettersLeft(token)))
    }

    /// 줄마다 틀이 아닌 조각이 이어진 것을 이름으로 모은다. 기준(시각·금액) 앞에서는 카드 이름 바로 뒤의 글(상품 이름)을 빼고,
    /// 기준 뒤에서는 「현대 백화점」처럼 카드사 낱말로 시작하는 가게를 살린다.
    private static func names(in text: String, afterAnchor: Bool) -> [String] {
        var result: [String] = []
        for line in text.split(separator: "\n") {
            var words: [String] = [], product = false, afterMark = false
            func flush() {
                if !product, let name = tidy(words.joined(separator: " ")) { result.append(name) }
                words = []
                product = false
            }
            for token in line.split(whereSeparator: \.isWhitespace).map(String.init) {
                // 금액에 붙은 토씨(「5,000원이」의 「이」)는 이름이 아니다.
                let particle = afterMark && ["이", "을", "를", "은", "는", "에"].contains(token)
                afterMark = token.contains(mark)
                let isName = !particle && (!isFrame(token) || (afterAnchor && cards.contains(token)))
                if !isName, !token.contains(where: { $0.isLetter || $0.isNumber }), !token.contains(mark) {
                    // 「KCP - 쿠팡」의 줄표처럼 이름 사이 기호는 잇는다.
                    if !words.isEmpty { words.append(token) }
                } else if isName, let cut = gluedFrame(token) {
                    words.append(cut)
                    flush()
                } else if isName {
                    words.append(token)
                } else {
                    // 기준 앞에서 카드 번호가 바로 뒤따르는 글은 법인 이름이다(「가나다상사 1234 승인」).
                    if !afterAnchor, token.wholeMatch(of: /[0-9*]{4}/) != nil { product = true }
                    flush()
                    product = !afterAnchor && isCardFrame(token)
                }
            }
            flush()
        }
        return result
    }

    /// 「스타벅스출금」처럼 가게에 붙은 결제 낱말을 뗀다.
    private static func gluedFrame(_ token: String) -> String? {
        guard let word = ["출금", "승인", "취소"].first(where: token.hasSuffix), token.count >= word.count + 2 else { return nil }
        return String(token.dropLast(word.count))
    }

    /// 앞뒤 구두점을 떼고 「(홍길동)」의 괄호를 벗긴다. 「(주)이니」·「GOOGLE *」는 그대로 둔다. 카드사 낱말뿐이면 가게가 아니다(「네이버페이」 같은 간편결제는 가게로 온다).
    private static func tidy(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \u{3000},.:;/|║-·●→_~"))
        if name.hasPrefix("("), name.hasSuffix(")"), !name.dropFirst().dropLast().contains(where: { $0 == "(" || $0 == ")" }) {
            name = String(name.dropFirst().dropLast())
        }
        guard name.count >= 2, name.count <= 40, name.contains(where: \.isLetter), !cards.contains(name) || name.hasSuffix("페이") else { return nil }
        return name
    }

    /// 항목 이름이 붙은 문자(하나카드 새 형식): 「사용처」 다음 줄이나 「사용처 : 가게」.
    private static func labelledMerchant(_ text: String) -> String? {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        for (index, line) in lines.enumerated() {
            guard let label = merchantLabels.first(where: line.hasPrefix) else { continue }
            let rest = line.dropFirst(label.count).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty, lines.indices.contains(index + 1) { return names(in: marking(lines[index + 1]), afterAnchor: true).first }
            if rest.hasPrefix(":") { return names(in: marking(String(rest.dropFirst())), afterAnchor: true).first }
        }
        return nil
    }

    /// 말로 쓴 알림: 「가나다식당에서 12,000원 결제했어요」·「홍길동님에게 30,000원을 보냈어요」.
    private static func sentenceMerchant(_ text: String) -> String? {
        for line in text.split(separator: "\n") {
            if let match = line.firstMatch(of: /^\s*(.{2,30}?)(?:님에게|에게|에서)\s+[0-9,]+원을?\s*(?:보냈|결제|송금|이체)/) { return tidy(String(match.1)) }
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

/// 결제 화면 캡처(카드 앱 이용 내역·결제 문자 캡처)의 글자를 읽는다(OCR1112A01, 제안 8-10).
/// 합계 줄이 있으면 영수증, 날짜·시각이 붙은 금액 줄이 둘 이상이면 내역 목록, 아니면 결제 문자 규칙, 끝으로 영수증 규칙.
enum LedgerScreenshotReader {
    typealias Draft = LedgerMessageParser.Draft
    /// 결제 한 건이 아닌 금액 줄.
    static let skipWords = ["누적", "잔액", "합계", "총액", "총 ", "포인트", "적립", "한도", "청구", "예정", "할인", "이용금액"]
    private static let statusWords = ["승인", "일시불", "할부", "체크", "취소", "결제완료", "결제", "이용내역", "사용"]

    static func drafts(_ lines: [String], now: Date = .now, calendar: Calendar = .autoupdatingCurrent) -> [Draft] {
        if lines.contains(where: LedgerReceiptReader.isTotalLine), let receipt = LedgerReceiptReader.draft(lines) { return [receipt] }
        let rows = rows(lines, now: now, calendar: calendar)
        if rows.count >= 2 { return rows }
        if let message = LedgerMessageParser.parse(lines.joined(separator: "\n"), now: now, calendar: calendar) { return [message] }
        return rows.isEmpty ? (LedgerReceiptReader.draft(lines).map { [$0] } ?? []) : rows
    }

    /// 내역 목록의 줄들. 날짜 머리줄(「11월 10일」·「11.10」)이나 곁의 시각이 있는 원화 금액만 결제로 본다(영수증 품목 줄과 가른다).
    static func rows(_ lines: [String], now: Date = .now, calendar: Calendar = .autoupdatingCurrent) -> [Draft] {
        var day: (month: Int, day: Int)?
        var result: [Draft] = []
        for (index, line) in lines.enumerated() {
            if let found = dayHeader(line) { day = found }
            guard !skipWords.contains(where: line.contains), let amount = LedgerMessageParser.wonAmounts(line).first else { continue }
            let near = [index - 1, index, index + 1].filter(lines.indices.contains).map { lines[$0] }
            let time = near.lazy.compactMap(clock).first
            guard day != nil || time != nil else { continue }
            let above = [index - 1, index - 2].filter(lines.indices.contains).map { lines[$0] }
                .filter { LedgerMessageParser.wonAmounts($0).isEmpty }
            result.append(Draft(
                amount: amount.value, currency: "KRW", merchant: ([line] + above).lazy.compactMap(name).first, card: nil,
                occurredAt: date(day: day, time: time, now: now, calendar: calendar), isCancel: (near + above).contains { $0.contains("취소") }
            ))
        }
        return result
    }

    static func dayHeader(_ line: String) -> (month: Int, day: Int)? {
        let pair: (Substring, Substring)?
        if let match = line.firstMatch(of: /(\d{1,2})월\s*(\d{1,2})일/) { pair = (match.1, match.2) }
        else if let match = line.firstMatch(of: /(?:^|[^\d,.:])(\d{1,2})[\/.](\d{1,2})(?:$|[^\d,:])/) { pair = (match.1, match.2) }
        else { pair = nil }
        guard let pair, let month = Int(pair.0), let day = Int(pair.1), (1...12).contains(month), (1...31).contains(day) else { return nil }
        return (month, day)
    }

    static func clock(_ line: String) -> (hour: Int, minute: Int)? {
        guard let match = line.firstMatch(of: /(?:^|\D)(\d{1,2}):(\d{2})(?:$|\D)/), let hour = Int(match.1), let minute = Int(match.2),
              (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return (hour, minute)
    }

    /// 줄에서 금액·날짜·시각·상태 낱말을 뺀 가게 이름.
    static func name(_ line: String) -> String? {
        var text = LedgerMessageParser.strippingWon(line)
        text = text.replacing(/\d{1,2}월\s*\d{1,2}일|\d{1,2}[\/.]\d{1,2}|\d{1,2}:\d{2}/, with: " ")
        for word in statusWords { text = text.replacingOccurrences(of: word, with: " ") }
        text = text.split(separator: " ").joined(separator: " ").trimmingCharacters(in: .whitespaces.union(.punctuationCharacters).union(.symbols))
        guard text.count >= 2, text.count <= 30, text.contains(where: \.isLetter), !LedgerMessageParser.startsWithCardName(text) else { return nil }
        return text
    }

    /// 날짜가 없으면 오늘, 시각이 없으면 낮 12시. 내일보다 뒤가 되면 작년으로 본다.
    static func date(day: (month: Int, day: Int)?, time: (hour: Int, minute: Int)?, now: Date, calendar: Calendar) -> Date? {
        var parts = calendar.dateComponents([.year, .month, .day], from: now)
        if let day { parts.month = day.month; parts.day = day.day }
        parts.hour = time?.hour ?? 12
        parts.minute = time?.minute ?? 0
        guard let date = calendar.date(from: parts) else { return nil }
        guard date > now.addingTimeInterval(86_400) else { return date }
        parts.year = (parts.year ?? 0) - 1
        return calendar.date(from: parts) ?? date
    }
}

/// 캡처에서 읽은 여러 건. 이미 가계부에 있는 것으로 보이는 줄(같은 금액·통화·종류가 10분 안, 시각을 못 읽었으면 같은 날)은 꺼 둔다.
struct LedgerCaptureBatch: Identifiable {
    let id = UUID()
    var entries: [LedgerEntry]
    var selected: Set<LedgerEntry.ID>

    init(entries: [LedgerEntry], existing: [LedgerEntry], calendar: Calendar = .autoupdatingCurrent) {
        self.entries = entries
        selected = Set(entries.filter { !Self.exists($0, in: existing, calendar: calendar) }.map(\.id))
    }

    static func exists(_ entry: LedgerEntry, in existing: [LedgerEntry], calendar: Calendar = .autoupdatingCurrent) -> Bool {
        let hasClock = calendar.dateComponents([.hour, .minute], from: entry.occurredAt) != DateComponents(hour: 12, minute: 0)
        return existing.contains { other in
            guard other.amount == entry.amount, other.currency == entry.currency, other.kind == entry.kind else { return false }
            return hasClock ? abs(other.occurredAt.timeIntervalSince(entry.occurredAt)) <= 600
                : calendar.isDate(other.occurredAt, inSameDayAs: entry.occurredAt)
        }
    }
}
