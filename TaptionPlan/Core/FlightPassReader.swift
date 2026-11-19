import Compression
import Foundation

/// 탑승권(`.pkpass`, zip) 안의 `pass.json`을 읽어 항공 알림 글 한 줄로 바꾼다(FLT1119A01).
/// 지갑(Wallet)에 이미 추가된 탑승권을 앱이 읽는 공개 API는 없다. 공유·파일로 받은 `.pkpass`만 읽는다.
/// 서명은 검증하지 않고 표시용으로만 읽으며, 읽지 못하면 nil이다(「못 읽음」). 이름·좌석·바코드·예약번호는 읽지도 옮기지도 않는다.
/// 결과 글은 알림 파서가 그대로 읽는 모양(`03/07 AB123 ICN -> BKK 09:05`)이라 같은 병합·확인 길을 탄다.
enum FlightPassReader {
    static let maximumArchiveBytes = 2_000_000
    static let maximumPassJSONBytes = 512_000

    /// `.pkpass` 바이트 → 알림 글. 편명·출발·도착·날짜·시각을 모두 알 수 있을 때만 값이 나온다.
    static func text(from archive: Data) -> String? {
        guard archive.count <= maximumArchiveBytes, let json = entry(named: "pass.json", in: archive), json.count <= maximumPassJSONBytes,
              let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any], let boarding = object["boardingPass"] as? [String: Any] else { return nil }
        let fields = ["headerFields", "primaryFields", "secondaryFields", "auxiliaryFields"].flatMap { boarding[$0] as? [[String: Any]] ?? [] }
        func value(_ keys: [String], labels: [String] = []) -> String? {
            for field in fields {
                let key = (field["key"] as? String ?? "").lowercased(), label = (field["label"] as? String ?? "").lowercased()
                if keys.contains(key) || labels.contains(where: { label.contains($0) }) {
                    if let text = field["value"] as? String, !text.isEmpty { return text }
                }
            }
            return nil
        }
        let flightRaw = value(["flight", "flightnumber", "flight_number", "flightno"], labels: ["flight", "편명"])
        let flight = flightRaw?.replacingOccurrences(of: " ", with: "").uppercased()
        let origin = airport(value(["origin", "departure", "from", "departureairport"], labels: ["from", "출발"]))
        let destination = airport(value(["destination", "arrival", "to", "arrivalairport"], labels: ["to", "도착"]))
        guard let flight, flight.range(of: #"^[A-Z0-9]{2}\d{2,4}$"#, options: .regularExpression) != nil, let origin, let destination,
              let relevant = object["relevantDate"] as? String, let when = localDateTime(relevant) else { return nil }
        return String(format: "%02d/%02d %@ %@ -> %@ %02d:%02d", when.month, when.day, flight, origin, destination, when.hour, when.minute)
    }

    /// 3글자 대문자 공항 코드만 받는다. 「ICN」「ICN Incheon」 같은 값에서 앞 코드만 쓴다.
    static func airport(_ text: String?) -> String? {
        guard let first = text?.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init)?.uppercased(),
              first.range(of: #"^[A-Z]{3}$"#, options: .regularExpression) != nil else { return nil }
        return first
    }

    /// `2027-03-07T09:05+09:00` → 그 글에 적힌 오프셋의 현지 날짜·시각. 오프셋이 없으면 적힌 그대로.
    static func localDateTime(_ text: String) -> (month: Int, day: Int, hour: Int, minute: Int)? {
        guard let regex = try? NSRegularExpression(pattern: #"^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let numbers = (2...5).compactMap { Range(match.range(at: $0), in: text).flatMap { Int(text[$0]) } }
        guard numbers.count == 4, (1...12).contains(numbers[0]), (1...31).contains(numbers[1]), (0...23).contains(numbers[2]), (0...59).contains(numbers[3]) else { return nil }
        return (numbers[0], numbers[1], numbers[2], numbers[3])
    }

    // MARK: zip

    /// zip 보관본에서 한 파일을 꺼낸다(저장·deflate만, 암호·zip64·여러 디스크는 지원하지 않는다). 못 찾거나 깨졌으면 nil.
    static func entry(named name: String, in archive: Data) -> Data? {
        let bytes = [UInt8](archive)
        guard bytes.count >= 22, let end = endOfCentralDirectory(bytes) else { return nil }
        let count = Int(le16(bytes, end + 10)), directoryOffset = Int(le32(bytes, end + 16))
        var cursor = directoryOffset
        for _ in 0..<min(count, 2_000) {
            guard cursor + 46 <= bytes.count, le32(bytes, cursor) == 0x0201_4B50 else { return nil }
            let method = le16(bytes, cursor + 10), compressed = Int(le32(bytes, cursor + 20)), plain = Int(le32(bytes, cursor + 24))
            let nameLength = Int(le16(bytes, cursor + 28)), extraLength = Int(le16(bytes, cursor + 30)), commentLength = Int(le16(bytes, cursor + 32))
            let localOffset = Int(le32(bytes, cursor + 42))
            guard cursor + 46 + nameLength <= bytes.count else { return nil }
            let entryName = String(decoding: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)
            if entryName == name {
                guard plain <= maximumPassJSONBytes, compressed <= maximumArchiveBytes, localOffset + 30 <= bytes.count, le32(bytes, localOffset) == 0x0403_4B50 else { return nil }
                let start = localOffset + 30 + Int(le16(bytes, localOffset + 26)) + Int(le16(bytes, localOffset + 28))
                guard start >= 0, start + compressed <= bytes.count else { return nil }
                let body = Array(bytes[start..<(start + compressed)])
                switch method {
                case 0: return body.count == plain ? Data(body) : nil
                case 8: return inflate(body, expected: plain)
                default: return nil
                }
            }
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return nil
    }

    private static func endOfCentralDirectory(_ bytes: [UInt8]) -> Int? {
        var index = bytes.count - 22
        let lowest = max(0, bytes.count - 22 - 65_535)
        while index >= lowest {
            if le32(bytes, index) == 0x0605_4B50 { return index }
            index -= 1
        }
        return nil
    }

    private static func inflate(_ input: [UInt8], expected: Int) -> Data? {
        guard expected > 0, expected <= maximumPassJSONBytes else { return nil }
        var output = [UInt8](repeating: 0, count: expected)
        let written = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { target in
                compression_decode_buffer(target.baseAddress!, expected, source.baseAddress!, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        return written == expected ? Data(output) : nil
    }

    private static func le16(_ bytes: [UInt8], _ at: Int) -> UInt16 { at + 2 <= bytes.count ? UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 : 0 }
    private static func le32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        at + 4 <= bytes.count ? UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24 : 0
    }
}
