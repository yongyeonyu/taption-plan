import Foundation

/// 서버로 올리는 글에서 번호를 가린다.
public enum AssistantRedaction {
    /// 숫자가 9개 넘게 이어진 덩어리(카드·계좌·전화번호)는 끝 4자리만 남기고 가린다. 금액·날짜·시각은 그대로다.
    public static func mask(_ text: String) -> String {
        // 띄어 쓴 카드번호(4자리 묶음)와, 붙임표로 이은 번호. 아무 띄어쓰기나 받으면 번호 뒤 날짜까지 한 덩어리가 된다.
        let pattern = #"\d{4}(?: \d{4}){2,3}|\d[\d-]{7,}\d"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let run = String(result[range])
            let digits = run.filter(\.isNumber).count
            guard digits >= 9 else { continue }
            var remaining = digits
            let masked = String(run.map { character -> Character in
                guard character.isNumber else { return character }
                remaining -= 1
                return remaining < 4 ? character : "*"
            })
            result.replaceSubrange(range, with: masked)
        }
        return result
    }
}

public enum AssistantPIN {
    public static func isValid(_ pin: String) -> Bool {
        pin.count == 6 && pin.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
    }
}
