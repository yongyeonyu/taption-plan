import Foundation

/// 서버로 올리는 글에서 번호를 가린다.
public enum AssistantRedaction {
    /// 숫자가 9개 넘게 이어진 덩어리(카드·계좌·전화번호)는 끝 4자리만 남기고 가린다. 금액·날짜·시각은 그대로다.
    public static func mask(_ text: String) -> String {
        var result = text
        for (range, run) in numberRuns(text).reversed() {
            guard let range = Range(range, in: result) else { continue }
            result.replaceSubrange(range, with: masked(run))
        }
        return result
    }

    /// REV1117A02: 가린 사본을 AI가 고쳐 돌려보내면, 원문의 번호를 가린 모양 그대로 남은 자리를 원문 번호로 되돌린다.
    public static func restore(_ text: String, original: String) -> String {
        var result = text
        for (_, run) in numberRuns(original) {
            let hidden = masked(run)
            guard hidden != run else { continue }
            result = result.replacingOccurrences(of: hidden, with: run)
        }
        return result
    }

    /// 숫자가 9개 넘는 번호 덩어리. 띄어 쓴 카드번호(4자리 묶음)와, 붙임표로 이은 번호.
    /// 아무 띄어쓰기나 받으면 번호 뒤 날짜까지 한 덩어리가 된다.
    private static func numberRuns(_ text: String) -> [(NSRange, String)] {
        let pattern = #"\d{4}(?: \d{4}){2,3}|\d[\d-]{7,}\d"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let run = String(text[range])
            return run.filter(\.isNumber).count >= 9 ? (match.range, run) : nil
        }
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
