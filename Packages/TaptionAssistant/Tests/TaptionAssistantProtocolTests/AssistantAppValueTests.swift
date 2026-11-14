import Foundation
import TaptionLedgerCore
import TaptionRules
import XCTest
@testable import TaptionAssistantProtocol

/// 앱에서 옮겨 온 값 타입의 저장 값(RMN1114A25). 이름이 기기 설정·저장 본문·서버 명령에 그대로 쓰이므로 바뀌면 안 된다.
final class AssistantAppValueTests: XCTestCase {
    func testRawValuesAreUnchanged() {
        XCTAssertEqual(TripItemStatus.allCases.map(\.rawValue), ["booked", "planned", "tentative"])
        XCTAssertEqual(AssistantDisplayOption.allCases.map(\.rawValue), ["mapPhotos", "mapRoutes", "mapFootprints", "sidebar", "vehicles"])
        XCTAssertEqual(AssistantScreen.allCases.map(\.rawValue), [
            "paymentAutomation", "shortcuts", "aiConnection", "ledger", "dataProtection", "settings",
            "salary", "carAudio", "alarm", "placeBook", "passport", "unconfirmedReview", "travel",
            "dayCard", "calendarConnect", "categoryAdd", "paymentAlerts", "aiRules",
        ])
        XCTAssertEqual(AssistantSetting.allCases.map(\.rawValue), [
            "tollVehicle", "salaryMode", "annualPay", "monthlyPay", "payIsNet", "showsNetPay", "hourlyPay", "hourlyPayIsNet", "hourlyTax", "weeklyHolidayPay",
            "reduceMotion", "weather", "weatherSidebar", "gpsIntervalSeconds", "cat", "notifications",
            "memoDisplay", "strideCentimeters", "watchAcceleration", "watchDataSync", "location", "photos",
        ])
        XCTAssertEqual([AssistantBubbleKind.routine.rawValue, AssistantBubbleKind.event.rawValue], ["routine", "event"])
        XCTAssertEqual(AssistantSetting.watchProfiles, ["off", "batterySaver", "balanced", "accuracy"])
    }

    func testTripItemStatusReadsAndStores() {
        XCTAssertEqual(TripItemStatus(raw: " Booked "), .booked)
        XCTAssertEqual(TripItemStatus(raw: nil), .planned)
        XCTAssertEqual(TripItemStatus(raw: "unknown"), .planned)
        XCTAssertNil(TripItemStatus(explicit: "unknown"))
        XCTAssertEqual(TripItemStatus(explicit: "TENTATIVE"), .tentative)
        XCTAssertNil(TripItemStatus.planned.stored)
        XCTAssertEqual(TripItemStatus.booked.stored, "booked")
    }

    func testSettingGroups() {
        XCTAssertEqual(AssistantSetting.allCases.filter(\.isSalary).map(\.rawValue), [
            "salaryMode", "annualPay", "monthlyPay", "payIsNet", "showsNetPay", "hourlyPay", "hourlyPayIsNet", "hourlyTax", "weeklyHolidayPay",
        ])
        XCTAssertEqual(AssistantSetting.allCases.filter(\.isModelBacked).map(\.rawValue), [
            "reduceMotion", "weather", "weatherSidebar", "gpsIntervalSeconds", "cat", "notifications", "watchAcceleration", "watchDataSync", "location", "photos",
        ])
    }

    /// 기기에 저장된 결제 문자 규칙(`ledgerMessageRules`)을 그대로 읽고, 다시 쓰면 같은 키가 나온다.
    func testStoredPaymentRuleDecodesAndKeepsItsKeys() throws {
        let stored = Data(#"[{"id":"11111111-2222-3333-4444-555555555555","name":"AI","pattern":"(?<amount>\\d+)","sample":"1000","kind":"ignore","createdAt":700000000}]"#.utf8)
        let rules = try JSONDecoder().decode([LedgerMessageRule].self, from: stored)
        XCTAssertEqual(rules.first?.id.uuidString, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(rules.first?.kind, .ignore)
        XCTAssertEqual(rules.first?.createdAt, Date(timeIntervalSinceReferenceDate: 700_000_000))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(rules)) as? [[String: Any]])
        XCTAssertEqual(object.first.map { Set($0.keys) }, ["id", "name", "pattern", "sample", "kind", "createdAt"])
        XCTAssertEqual(try JSONDecoder().decode([LedgerMessageRule].self, from: JSONEncoder().encode(rules)), rules)
    }

    func testExpenseChangeAppliesOnlyGivenFields() {
        let entry = LedgerEntry(
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000), amount: 10, currency: "KRW", kind: .expense, category: .food,
            title: "A", tripID: "t1", shareNames: ["B"]
        )
        XCTAssertEqual(AssistantExpenseChange().applied(to: entry), entry)
        let changed = AssistantExpenseChange(amount: 20, title: "C", tripID: "").applied(to: entry)
        XCTAssertEqual([changed.amount, 20], [20, 20])
        XCTAssertEqual(changed.title, "C")
        XCTAssertNil(changed.tripID)
        XCTAssertNil(changed.shareNames)
        XCTAssertTrue(AssistantExpenseChange(shareNames: []).touchesTrip)
        XCTAssertNil(AssistantExpenseChange.sharers(["a", "a"], minimum: 1))
        XCTAssertEqual(AssistantExpenseChange.sharers([" a ", "b"], minimum: 1), ["a", "b"])
    }
}
