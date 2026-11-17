import Foundation

/// 서버로 올리는 글에서 번호를 가린다.
public enum AssistantRedaction {
    /// 숫자가 9개 넘게 이어진 덩어리(카드·계좌·전화번호)는 끝 4자리만 남기고, 메일 주소는 이름의 첫 글자와 도메인만 남기고 가린다.
    /// 금액·날짜·시각은 그대로다.
    public static func mask(_ text: String) -> String {
        var result = text
        for (range, _, hidden) in secrets(text).reversed() {
            guard let range = Range(range, in: result) else { continue }
            result.replaceSubrange(range, with: hidden)
        }
        return result
    }

    /// REV1117A02: 가린 사본을 AI가 고쳐 돌려보내면, 원문의 번호를 가린 모양 그대로 남은 자리를 원문 번호로 되돌린다.
    /// AIF1118A01: 서로 다른 원문이 같은 모양으로 가려졌으면 어느 쪽인지 몰라 되돌리지 않는다.
    public static func restore(_ text: String, original: String) -> String {
        var runs: [String: Set<String>] = [:]
        for (_, run, hidden) in secrets(original) where hidden != run { runs[hidden, default: []].insert(run) }
        var result = text
        for (hidden, found) in runs where found.count == 1 {
            result = result.replacingOccurrences(of: hidden, with: found.first!)
        }
        return result
    }

    /// 가릴 덩어리와 가린 모양. 번호는 숫자가 9개 넘는 것만: 붙임표로 이은 번호, 띄어 쓴 카드번호(4자리 묶음·Amex 4-6-5),
    /// 띄어 쓰거나 점으로 나눈 국내 전화(0으로 시작), `+`로 시작하는 국제 번호(AIF1118A01).
    /// 아무 띄어쓰기나 받으면 번호 뒤 날짜까지 한 덩어리가 되므로 정해 둔 모양만 받는다.
    private static func secrets(_ text: String) -> [(NSRange, String, String)] {
        let numbers = #"(?<![\d+])(?:\+\d{1,3}[ .-]?\d{1,4}(?:[ .-]?\d{2,4}){2,3}|\d{4}[ -]\d{6}[ -]\d{5}|\d{4}(?:[ -]\d{4}){2,3}|0\d{1,2}[ .-]\d{3,4}[ .-]\d{4}|\d[\d-]{7,}\d)(?!\d)"#
        let emails = #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
        func matches(_ pattern: String) -> [(NSRange, String)] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
                Range(match.range, in: text).map { (match.range, String(text[$0])) }
            }
        }
        let mails = matches(emails).map { ($0.0, $0.1, maskedEmail($0.1)) }
        let runs = matches(numbers).filter { number in
            number.1.filter(\.isNumber).count >= 9 && !mails.contains { NSIntersectionRange($0.0, number.0).length > 0 }
        }
        return (mails + runs.map { ($0.0, $0.1, masked($0.1)) }).sorted { $0.0.location < $1.0.location }
    }

    private static func maskedEmail(_ address: String) -> String {
        guard let at = address.firstIndex(of: "@"), at > address.startIndex else { return address }
        let name = address[..<at]
        return String(name.prefix(1)) + String(repeating: "*", count: name.count - 1) + address[at...]
    }

    private static func masked(_ run: String) -> String {
        var remaining = run.filter(\.isNumber).count
        return String(run.map { character -> Character in
            guard character.isNumber else { return character }
            remaining -= 1
            return remaining < 4 ? character : "*"
        })
    }
}

public enum AssistantPIN {
    public static func isValid(_ pin: String) -> Bool {
        pin.count == 6 && pin.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
    }
}
