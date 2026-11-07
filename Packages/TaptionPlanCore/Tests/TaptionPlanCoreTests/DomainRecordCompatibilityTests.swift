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

    static func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }

    @Test func actualRecordStoredBytesAreUnchanged() throws {
        let full = ActualRecord(
            id: Self.id(1), planID: Self.id(2), routineID: Self.id(3), title: "걷기",
            categoryID: "movement", startedAt: Self.start, endedAt: Self.start.addingTimeInterval(900),
            source: .motion, confidence: .medium, createdAt: Self.start.addingTimeInterval(901),
            behavior: "walking", evidence: ["steps", "gps"], routeID: Self.id(4), sensorChunkID: Self.id(5),
            modelVersion: "m7", manuallyCorrected: true, isClassificationLocked: false,
            classificationScore: 0.625, lockReason: .user
        )
        try Self.roundTrip(
            ActualRecord.self,
            stored: #"{"behavior":"walking","categoryID":"movement","classificationScore":0.625,"confidence":"medium","createdAt":1762560901,"endedAt":1762560900,"evidence":["steps","gps"],"id":"00000000-0000-0000-0000-000000000001","isClassificationLocked":false,"lockReason":"user","manuallyCorrected":true,"modelVersion":"m7","planID":"00000000-0000-0000-0000-000000000002","routeID":"00000000-0000-0000-0000-000000000004","routineID":"00000000-0000-0000-0000-000000000003","sensorChunkID":"00000000-0000-0000-0000-000000000005","source":"motion","startedAt":1762560000,"title":"걷기"}"#,
            expected: full
        )
        let minimal = ActualRecord(
            id: Self.id(6), planID: nil, title: "메모", categoryID: "activity",
            startedAt: Self.start, source: .manual, createdAt: Self.start
        )
        try Self.roundTrip(
            ActualRecord.self,
            stored: #"{"categoryID":"activity","confidence":"high","createdAt":1762560000,"evidence":[],"id":"00000000-0000-0000-0000-000000000006","isClassificationLocked":false,"manuallyCorrected":false,"source":"manual","startedAt":1762560000,"title":"메모"}"#,
            expected: minimal
        )
    }

    /// 예전 기록(근거·교정·잠금 키 없음)은 기본값으로 읽히고, 자동 원천은 잠긴다.
    @Test func legacyActualRecordDecodesWithDefaults() throws {
        let legacy = #"{"categoryID":"location","confidence":"high","createdAt":1762560000,"id":"00000000-0000-0000-0000-000000000009","source":"location","startedAt":1762560000,"title":"집"}"#
        let decoded = try Self.storeDecoder.decode(ActualRecord.self, from: Data(legacy.utf8))
        let encoded = String(decoding: try Self.storeEncoder.encode(decoded), as: UTF8.self)
        #expect(encoded == #"{"categoryID":"location","confidence":"high","createdAt":1762560000,"evidence":[],"id":"00000000-0000-0000-0000-000000000009","isClassificationLocked":true,"manuallyCorrected":false,"source":"location","startedAt":1762560000,"title":"집"}"#)
    }

    @Test func planRecordStoredBytesAreUnchanged() throws {
        let rule = GoalRepeatRule(id: Self.id(4), name: "아침", weekdays: [2], startMinuteOfDay: 420, endMinuteOfDay: 480)
        let full = PlanRecord(
            id: Self.id(1), title: "루틴:운동",
            span: TimeSpan(start: Self.start, end: Self.start.addingTimeInterval(3_600)),
            categoryID: "activity", middleCategoryName: "운동", subCategoryName: "달리기",
            repeatRules: [rule], parentID: Self.id(2), status: .completed, origin: .repeatRule,
            isFixed: true, isImportant: true, externalCalendarID: "cal", externalEventID: "evt",
            createdAt: Self.start, updatedAt: Self.start.addingTimeInterval(60)
        )
        try Self.roundTrip(
            PlanRecord.self,
            stored: #"{"categoryID":"activity","createdAt":1762560000,"externalCalendarID":"cal","externalEventID":"evt","id":"00000000-0000-0000-0000-000000000001","isFixed":true,"isImportant":true,"middleCategoryName":"운동","origin":"repeatRule","parentID":"00000000-0000-0000-0000-000000000002","repeatRules":[{"endMinuteOfDay":480,"id":"00000000-0000-0000-0000-000000000004","name":"아침","startMinuteOfDay":420,"weekdays":[2]}],"span":{"end":1762563600,"start":1762560000},"status":"completed","subCategoryName":"달리기","title":"루틴:운동","updatedAt":1762560060}"#,
            expected: full
        )
        // 빈 반복 규칙은 저장하지 않는다(nil로 접는다).
        let plain = PlanRecord(
            id: Self.id(3), title: "회의", span: TimeSpan(start: Self.start, end: Self.start),
            categoryID: "work", repeatRules: [], createdAt: Self.start, updatedAt: Self.start
        )
        try Self.roundTrip(
            PlanRecord.self,
            stored: #"{"categoryID":"work","createdAt":1762560000,"id":"00000000-0000-0000-0000-000000000003","isFixed":false,"isImportant":false,"origin":"user","span":{"end":1762560000,"start":1762560000},"status":"planned","title":"회의","updatedAt":1762560000}"#,
            expected: plain
        )
    }
}
