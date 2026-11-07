import Foundation
import Testing
@testable import TaptionPlanCore

/// 앱 타깃에서 옮겨 온 도메인 타입의 저장 바이트 계약.
/// 기대 JSON은 옮기기 전 앱 선언으로 인코딩한 결과다(`build/validation/RFA1102A01/phase2`).
/// 저장소·백업과 같은 설정(`secondsSince1970`, `sortedKeys`)과 기본 설정을 함께 고정한다.
struct DomainRecordCompatibilityTests {
    static let storeEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let storeDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    static func defaultEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// 기대 바이트를 읽고 다시 쓰면 바이트가 같아야 한다.
    static func roundTrip<T: Codable & Equatable>(
        _ type: T.Type, stored json: String, expected value: T
    ) throws {
        let decoded = try storeDecoder.decode(T.self, from: Data(json.utf8))
        #expect(decoded == value)
        let encoded = String(decoding: try storeEncoder.encode(decoded), as: UTF8.self)
        #expect(encoded == json)
    }

    static let start = Date(timeIntervalSince1970: 1_762_560_000)

    @Test func timeSpanStoredBytesAreUnchanged() throws {
        let span = TimeSpan(start: Self.start, end: Self.start.addingTimeInterval(3_600))
        try Self.roundTrip(TimeSpan.self, stored: #"{"end":1762563600,"start":1762560000}"#, expected: span)
        let deferred = String(decoding: try Self.defaultEncoder().encode(span), as: UTF8.self)
        #expect(deferred == #"{"end":784256400,"start":784252800}"#)
    }

    @Test func timeSpanKeepsEndNotBeforeStart() {
        let span = TimeSpan(start: Self.start, end: Self.start.addingTimeInterval(-10))
        #expect(span.end == span.start)
        #expect(span.duration == 0)
    }

    @Test func activityCorrectionStoredBytesAreUnchanged() throws {
        try Self.roundTrip(
            ActivityCorrection.self,
            stored: #"{"behavior":"brushing","categoryID":"activity","endedAt":1762560120,"startedAt":1762560000,"title":"양치"}"#,
            expected: ActivityCorrection(
                title: "양치", behavior: "brushing", categoryID: "activity",
                startedAt: Self.start, endedAt: Self.start.addingTimeInterval(120)
            )
        )
        try Self.roundTrip(
            ActivityCorrection.self,
            stored: #"{"categoryID":"activity","title":"독서"}"#,
            expected: ActivityCorrection(title: "독서")
        )
    }
}
