import Foundation

/// 항공 알림 글 정규화(FLT1119A01). 파서가 읽기 쉽게 모양만 맞추고, 내용은 바꾸지 않는다.
/// 전각→반각, 공백·줄바꿈 정리, 따옴표 통일, 공항 코드 사이의 화살표(`->`·`→`·`~`·`-`)를 `→` 하나로, 머리표(`[Web발신]` 등)를 떼어 따로 돌려준다.
public enum FlightAlertText {
    public struct Normalized: Equatable, Sendable {
        /// 정리된 본문(머리표 없음). 대소문자는 그대로다.
        public var text: String
        /// 앞에서 뗀 머리표(`Web발신`·`국제발신`). 없으면 nil.
        public var marker: String?
        /// 본문에서 한글 아닌 부분(편명·공항 코드·예약번호)을 읽기 쉽게 대문자로 바꾼 사본.
        public var upper: String { text.uppercased() }
    }

    /// 문자 앞에 붙는 발신 머리표.
    private static let markers = ["Web발신", "국제발신", "국외발신", "광고", "발신"]

    /// 이보다 긴 글은 항공 알림이 아니다. 정규식이 길이에 따라 느려지지 않게 먼저 자른다(앞부분만 읽는다).
    public static let maximumCharacters = 6_000

    public static func normalize(_ raw: String) -> Normalized {
        var text = halfWidth(String(raw.prefix(maximumCharacters + 1)))
        // 따옴표·긴 줄표 통일, 보이지 않는 공백 제거
        for (from, to) in [("“", "\""), ("”", "\""), ("‘", "'"), ("’", "'"), ("‐", "-"), ("‑", "-"), ("–", "-"), ("—", "-"), ("−", "-"),
                           ("\u{00A0}", " "), ("\u{200B}", ""), ("\u{FEFF}", ""), ("\u{3000}", " "), ("\r\n", "\n"), ("\r", "\n")] {
            text = text.replacingOccurrences(of: from, with: to)
        }
        let (body, marker) = splitMarker(text)
        text = body
        text = arrows(text)
        // 줄 안의 공백을 하나로, 줄 앞뒤 공백 제거, 빈 줄은 한 줄까지만
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            line.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        }
        var out: [String] = []
        for line in lines {
            if line.isEmpty, out.last?.isEmpty != false { continue }
            out.append(line)
        }
        while out.last?.isEmpty == true { out.removeLast() }
        return Normalized(text: out.joined(separator: "\n"), marker: marker)
    }

    /// 전각 숫자·영문·기호(`！`~`～`)를 반각으로. 한글·한자는 건드리지 않는다.
    static func halfWidth(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar -> Unicode.Scalar in
            if scalar.value >= 0xFF01, scalar.value <= 0xFF5E, let narrow = Unicode.Scalar(scalar.value - 0xFEE0) { return narrow }
            return scalar
        }))
    }

    /// 맨 앞 `[Web발신]`·`(광고)` 같은 머리표를 뗀다. 항공사 이름 머리표(`[대한항공]`)는 본문에 둔다.
    static func splitMarker(_ text: String) -> (body: String, marker: String?) {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var found: String?
        while body.hasPrefix("[") || body.hasPrefix("(") {
            let close: Character = body.hasPrefix("[") ? "]" : ")"
            guard let end = body.firstIndex(of: close) else { break }
            let name = String(body[body.index(after: body.startIndex)..<end]).replacingOccurrences(of: " ", with: "")
            guard markers.contains(where: { name.contains($0) }) else { break }
            if found == nil { found = name }
            body = String(body[body.index(after: end)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (body, found)
    }

    /// `ICN -> BKK`·`ICN~BKK`·`ICN-BKK`·`ICN⇒BKK` → `ICN→BKK`. 한글 도시 사이(`다낭-인천`)도 같은 모양으로 맞춘다.
    static func arrows(_ text: String) -> String {
        var out = text
        let patterns: [(String, String)] = [
            (#"\b([A-Za-z]{3})\s*(?:->|→|➝|⇒|=>|~|-)\s*([A-Za-z]{3})\b"#, "$1→$2"),
            (#"([가-힣]{2,12})\s{0,3}(?:->|→|➝|⇒|=>|~|-)\s{0,3}([가-힣]{2,12})"#, "$1→$2"),
        ]
        for (pattern, template) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        return out
    }
}
