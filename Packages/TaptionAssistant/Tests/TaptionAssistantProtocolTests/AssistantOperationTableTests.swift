import Foundation
import XCTest
@testable import TaptionAssistantProtocol

/// 동작 등록부의 읽기 쪽(RMN1114A25). 목록의 차례와 이름은 「AI가 할 수 있는 일」·저장된 스위치·「AI가 한 일」에 그대로 쓰인다.
/// 서버 등록부와의 일치·적용은 앱 시험(`AssistantCommandEditTests`)이 본다.
final class AssistantOperationTableTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "AssistantOperationTableTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    private func fields(_ action: String, _ values: [String: AssistantJSON]) -> AssistantFields {
        AssistantFields(values: values.merging(["format": .text("bokki-command"), "version": .number(1), "action": .text(action)]) { first, _ in first })
    }

    private func parses(_ action: String, _ values: [String: AssistantJSON]) -> Bool { AssistantOperations.parse(fields(action, values)) != nil }

    func testOperationOrderAndNames() {
        XCTAssertEqual(AssistantOperations.all.map { $0.spec.name }, [
            "classifyInboxItem", "setFxRate", "setPaymentSource", "setSkipWords", "addLedgerTrip", "updateLedgerTrip", "deleteLedgerTrip",
            "planQuickAction", "addTripItem", "updateTripItem", "deleteTripItem",
            "deleteManualRecord", "linkRecordToPlan", "resolveBoarding",
            "setTripItemPhoto",
            "moveCategory", "deleteCategory", "setPlaceFloor", "addMyStop", "updateMyStop", "deleteMyStop",
            "setDayCardItems", "setDayCardTime", "setAlert", "setCatOutfit", "setPlaceKind", "setMapActivityColor",
            "refreshNow", "stopTracking", "disconnectCalendar", "restoreFromBackup",
            "lowerShareLevel", "raiseShareLevel", "shortenRetention", "extendRetention", "turnOffHealth", "openBackup",
        ])
        for type in AssistantOperations.all {
            XCTAssertEqual(AssistantOperations.spec(type.spec.name)?.fields, type.spec.fields)
            XCTAssertTrue(type.spec.guide.hasPrefix(type.spec.fields.isEmpty ? "}" : "\""), type.spec.name)
        }
        XCTAssertNil(AssistantOperations.spec("addMemo"))
    }

    func testKindsKeepTheirStoredNames() throws {
        XCTAssertEqual(AssistantActionKind.builtIn.count, 49)
        XCTAssertEqual(AssistantActionKind.builtIn.prefix(3).map(\.rawValue), ["addMemo", "addSchedule", "updateActivity"])
        XCTAssertEqual(AssistantActionKind.setTripBudget.rawValue, "setTripBudget")
        XCTAssertEqual(AssistantActionKind.allCases.count, 49 + AssistantOperations.all.count)
        XCTAssertEqual(Set(AssistantActionKind.allCases.map(\.rawValue)).count, AssistantActionKind.allCases.count, "예전 이름과 등록부 이름이 겹치지 않는다")
        XCTAssertTrue(AssistantActionKind.allCases.allSatisfy { AssistantActionKind(rawValue: $0.rawValue) == $0 })
        XCTAssertEqual(AssistantActionKind(rawValue: "setFxRate"), .operation("setFxRate"))
        XCTAssertNil(AssistantActionKind(rawValue: "laterAction"))

        // 로그는 모르는 이름도 읽고, 쓴 글자는 이름 그대로다.
        let stored = Data(#"["deleteMemo","setFxRate","laterAction"]"#.utf8)
        let kinds = try JSONDecoder().decode([AssistantActionKind].self, from: stored)
        XCTAssertEqual(kinds, [.deleteMemo, .operation("setFxRate"), .operation("laterAction")])
        XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(kinds)) as? [String], ["deleteMemo", "setFxRate", "laterAction"])
    }

    func testTogglesKeepTheirKeysAndDefaults() {
        let store = defaults()
        XCTAssertEqual(AssistantActionToggles.key(.deleteMemo), "assistantAction.deleteMemo")
        XCTAssertEqual(AssistantActionToggles.key(.operation("setFxRate")), "assistantAction.setFxRate")
        XCTAssertEqual(
            AssistantActionKind.allCases.filter { !AssistantActionToggles.isEnabled($0, defaults: store) }.map(\.rawValue),
            ["restoreFromBackup", "raiseShareLevel", "extendRetention", "turnOffHealth"]
        )
        AssistantActionToggles.set(.operation("turnOffHealth"), enabled: true, defaults: store)
        AssistantActionToggles.set(.addMemo, enabled: false, defaults: store)
        XCTAssertTrue(AssistantActionToggles.isEnabled(.operation("turnOffHealth"), defaults: store))
        XCTAssertFalse(AssistantActionToggles.isEnabled(.addMemo, defaults: store))
        XCTAssertEqual(store.object(forKey: "assistantAction.addMemo") as? Bool, false)
    }

    func testParseKeepsOnlyTheOperationFields() throws {
        let parsed = try XCTUnwrap(AssistantOperations.parse(fields("setFxRate", ["currency": .text("USD"), "krwPerUnit": .number(1_400), "extra": .flag(true), "keyId": .text("k")])))
        XCTAssertEqual(parsed.name, "setFxRate")
        XCTAssertEqual(parsed.values, ["currency": .text("USD"), "krwPerUnit": .number(1_400)])
        XCTAssertEqual(parsed.operation.changeCount, 1)
        XCTAssertFalse(parses("setFxRate", ["currency": .text("KRW"), "krwPerUnit": .number(1)]))
        XCTAssertNil(AssistantOperations.parse(AssistantFields(values: ["format": .text("bokki-command"), "version": .number(2), "action": .text("setFxRate")])))
        XCTAssertNil(AssistantOperations.parse(fields("addMemo", ["text": .text("a")])))
    }

    /// 앱 화면의 형 대신 이름 목록으로 읽는 칸들.
    func testNamedChoicesAreReadFromTheLists() throws {
        for name in AssistantOperations.alertKinds + [AssistantOperations.nearbyMemoAlert] {
            XCTAssertTrue(parses("setAlert", ["alert": .text(name), "enabled": .flag(false)]), name)
        }
        XCTAssertFalse(parses("setAlert", ["alert": .text("nope"), "enabled": .flag(false)]))
        XCTAssertFalse(parses("setAlert", ["alert": .text("wakeUp")]))
        let alert = try XCTUnwrap(AssistantOperations.parse(fields("setAlert", ["alert": .text("nearbyMemo"), "enabled": .flag(true)]))?.operation as? AssistantOperations.SetAlert)
        XCTAssertNil(alert.kindName)

        for name in AssistantOperations.accessoryKinds { XCTAssertTrue(parses("setCatOutfit", ["remove": .text(name)]), name) }
        XCTAssertFalse(parses("setCatOutfit", ["remove": .text("shoes")]))
        XCTAssertFalse(parses("setCatOutfit", ["remove": .text("hat"), "accessoryId": .text("cat.accessory.a")]))
        XCTAssertTrue(parses("setCatOutfit", ["accessoryId": .text("cat.accessory.a")]))
        XCTAssertFalse(parses("setCatOutfit", ["accessoryId": .text("other.a")]))

        for name in AssistantOperations.PlanQuickAction.actionNames {
            XCTAssertTrue(parses("planQuickAction", ["planId": .text(UUID().uuidString), "quickAction": .text(name)]), name)
        }
        XCTAssertFalse(parses("planQuickAction", ["planId": .text(UUID().uuidString), "quickAction": .text("delete")]))

        let item: [String: AssistantJSON] = ["tripId": .text("t"), "title": .text("Dinner"), "start": .text("2026-12-01T19:00+09:00"), "end": .text("2026-12-01T20:00+09:00")]
        let added = try XCTUnwrap(AssistantOperations.parse(fields("addTripItem", item))?.operation as? AssistantOperations.AddTripItem)
        XCTAssertEqual([added.kindName, "\(added.offset)"], ["activity", "32400"])
        for name in AssistantOperations.tripItemKinds { XCTAssertTrue(parses("addTripItem", item.merging(["kind": .text(name)]) { $1 }), name) }
        XCTAssertFalse(parses("addTripItem", item.merging(["kind": .text("party")]) { $1 }))
        XCTAssertFalse(parses("updateTripItem", ["tripId": .text("t"), "itemId": .text("i"), "kind": .text("party")]))
        XCTAssertTrue(parses("updateTripItem", ["tripId": .text("t"), "itemId": .text("i"), "kind": .text("meal")]))

        XCTAssertTrue(parses("setDayCardItems", ["items": .list([.text("sleep"), .text("memos")])]))
        XCTAssertTrue(parses("setDayCardItems", ["items": .list([])]))
        XCTAssertFalse(parses("setDayCardItems", ["items": .list([.text("nope")])]))
        XCTAssertFalse(parses("setDayCardItems", ["items": .list(AssistantOperations.dayCardItems.prefix(AssistantOperations.dayCardItemLimit + 1).map(AssistantJSON.text))]))

        XCTAssertTrue(parses("setTripItemPhoto", ["itemId": .text("i"), "photoUrl": .text("https://upload.wikimedia.org/a.jpg")]))
        XCTAssertFalse(parses("setTripItemPhoto", ["itemId": .text("i"), "photoUrl": .text("https://example.com/a.jpg")]))
        XCTAssertFalse(parses("setTripItemPhoto", ["itemId": .text("i"), "photoUrl": .text("http://upload.wikimedia.org/a.jpg")]))
        XCTAssertTrue(parses("setTripItemPhoto", ["itemId": .text("i"), "remove": .flag(true)]))

        XCTAssertEqual(AssistantOperations.paymentSourceName("  은행 앱 \n"), "은행 앱")
        XCTAssertNil(AssistantOperations.paymentSourceName(String(repeating: "a", count: 41)))
        XCTAssertNil(AssistantOperations.paymentSourceName("  "))
        XCTAssertEqual(AssistantOperations.offsetSeconds("2026-12-01T19:00-03:30"), -12_600)
    }

    func testSharingOperationsReadOneDirectionOnly() {
        XCTAssertTrue(parses("lowerShareLevel", ["level": .text("off")]))
        XCTAssertFalse(parses("lowerShareLevel", ["level": .text("visits")]))
        XCTAssertTrue(parses("raiseShareLevel", ["level": .text("visits")]))
        XCTAssertFalse(parses("raiseShareLevel", ["level": .text("off")]))
        XCTAssertTrue(parses("shortenRetention", ["days": .number(7)]))
        XCTAssertFalse(parses("shortenRetention", ["days": .number(30)]))
        XCTAssertTrue(parses("extendRetention", ["days": .number(30)]))
        XCTAssertFalse(parses("extendRetention", ["days": .number(1)]))
        XCTAssertTrue(parses("openBackup", [:]))
    }
}
