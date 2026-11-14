import XCTest
import TaptionPlanCore
import TaptionPlanStore
@testable import TaptionPlan

/// RMN1114A22: 일정의 장소·예상 지출 읽고 쓰기, 장소 종류, 지도 활동 색, 근처 메모 알림, 장식 벗기, 기록이 바뀐 알림.
/// 좌표는 0~1도의 꾸민 값이다.
@MainActor
final class AssistantMoreActionTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: hour, minute: minute))!
    }

    private func defaults() -> UserDefaults {
        let name = "AssistantMoreActionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    private func makeModel(_ seed: TaptionDataSnapshot = .empty) async -> AppModel {
        let model = AppModel(repository: InMemoryPlanRepository(snapshot: seed), cloudSyncService: nil)
        await model.bootstrap()
        return model
    }

    private func batch(_ action: String, _ extra: [String: Any]) throws -> AssistantCommandBatch {
        let item: [String: Any] = ["format": "bokki-command", "version": 1, "id": "c-\(UUID().uuidString)", "action": action, "keyId": "aaaa1111"]
        let data = try JSONSerialization.data(withJSONObject: ["commands": [item.merging(extra) { $1 }]])
        return try XCTUnwrap(AssistantCommandParser.parse(data, now: at(15), calendar: calendar))
    }

    private func invalid(_ action: String, _ extra: [String: Any]) throws -> Bool { try !batch(action, extra).invalidIDs.isEmpty }

    private func send(_ model: AppModel, _ action: String, _ extra: [String: Any] = [:], store: UserDefaults) async throws -> (reason: String?, entry: AssistantLogEntry?) {
        let applied = await model.applyAssistantCommands(try batch(action, extra), defaults: store)
        let outcome = try XCTUnwrap(applied)
        return (outcome.results.first?.reason, outcome.entries.first)
    }

    private func undo(_ model: AppModel, _ entry: AssistantLogEntry?, store: UserDefaults, file: StaticString = #filePath, line: UInt = #line) async throws {
        let undone = await model.undoAssistantEntry(try XCTUnwrap(entry, file: file, line: line), preferences: .test(store))
        XCTAssertTrue(undone, file: file, line: line)
    }

    private let spot: [String: Any] = ["placeName": "꾸민 식당", "latitude": 0.5, "longitude": 0.25]
    private let start = "2026-11-14T19:00+09:00"

    // MARK: 일정의 장소·예상 지출

    func testSchedulePlaceAndSpendParseWithTheServerRules() throws {
        let base: [String: Any] = ["title": "저녁", "start": start]
        let target: [String: Any] = ["planId": UUID().uuidString]
        XCTAssertFalse(try invalid("addSchedule", base.merging(spot) { $1 }.merging(["plannedSpend": 30_000]) { $1 }))
        XCTAssertFalse(try invalid("addSchedule", base.merging(["plannedSpend": 0.4]) { $1 }))
        XCTAssertFalse(try invalid("updateSchedule", target.merging(spot) { $1 }))
        XCTAssertFalse(try invalid("updateSchedule", target.merging(["plannedSpend": 12_000]) { $1 }), "예상 지출만 고쳐도 된다")
        XCTAssertFalse(try invalid("updateSchedule", target.merging(["clearPlace": true]) { $1 }), "장소 지우기만 보내도 된다")
        let bad: [(String, [String: Any])] = [
            ("addSchedule", base.merging(["placeName": "꾸민 식당"]) { $1 }),
            ("addSchedule", base.merging(["latitude": 0.5, "longitude": 0.25]) { $1 }),
            ("addSchedule", base.merging(["placeName": "꾸민 식당", "latitude": 0.5]) { $1 }),
            ("addSchedule", base.merging(spot) { $1 }.merging(["latitude": 91]) { $1 }),
            ("addSchedule", base.merging(spot) { $1 }.merging(["placeName": String(repeating: "가", count: 101)]) { $1 }),
            ("addSchedule", base.merging(["plannedSpend": 0]) { $1 }),
            ("addSchedule", base.merging(["plannedSpend": 1e10 + 1]) { $1 }),
            ("addSchedule", base.merging(["clearPlace": true]) { $1 }),
            ("updateSchedule", target.merging(["clearPlace": false]) { $1 }),
            ("updateSchedule", target.merging(spot) { $1 }.merging(["clearPlace": true]) { $1 }),
            ("updateSchedule", target.merging(["plannedSpend": -5]) { $1 }),
        ]
        for (action, extra) in bad { XCTAssertTrue(try invalid(action, extra), "\(action) \(extra)") }
    }

    func testAddScheduleKeepsThePlaceAndSpendAndUndoRemovesThePlan() async throws {
        let store = defaults()
        let model = await makeModel()
        let added = try await send(model, "addSchedule", ["title": "저녁", "start": start, "plannedSpend": 30_000].merging(spot) { $1 }, store: store)
        XCTAssertNil(added.reason)
        let plan = try XCTUnwrap(model.snapshot.plans.first)
        XCTAssertEqual(plan.place, PlanPlace(name: "꾸민 식당", latitude: 0.5, longitude: 0.25))
        XCTAssertEqual(plan.plannedSpendKRW, 30_000)
        XCTAssertEqual(added.entry?.after.contains("꾸민 식당"), true, "전·후 글에 장소가 보인다")
        XCTAssertEqual(added.entry?.after.contains("0.5"), false, "좌표는 글에 넣지 않는다")

        let plain = try await send(model, "addSchedule", ["title": "산책", "start": "2026-11-14T21:00+09:00"], store: store)
        XCTAssertNil(plain.reason)
        let walk = try XCTUnwrap(model.snapshot.plans.first { $0.title == "산책" })
        XCTAssertNil(walk.place)
        XCTAssertNil(walk.plannedSpendKRW, "보내지 않으면 칸을 만들지 않는다")

        try await undo(model, added.entry, store: store)
        XCTAssertEqual(model.snapshot.plans.map(\.title), ["산책"])
    }

    func testUpdateScheduleChangesOnlyTheSentSpotFieldsAndUndoes() async throws {
        let store = defaults()
        let model = await makeModel()
        _ = try await send(model, "addSchedule", ["title": "저녁", "start": start], store: store)
        let planID = try XCTUnwrap(model.snapshot.plans.first?.id)
        let target: [String: Any] = ["planId": planID.uuidString]
        func plan() throws -> PlanRecord { try XCTUnwrap(model.snapshot.plans.first { $0.id == planID }) }

        let nothing = try await send(model, "updateSchedule", target.merging(["clearPlace": true]) { $1 }, store: store)
        XCTAssertEqual(nothing.reason, "no_place", "장소가 없는 일정에서 지울 것은 없다")

        let placed = try await send(model, "updateSchedule", target.merging(spot) { $1 }, store: store)
        XCTAssertNil(placed.reason)
        XCTAssertEqual(try plan().place?.name, "꾸민 식당")
        XCTAssertNil(try plan().plannedSpendKRW)
        XCTAssertNotEqual(placed.entry?.before, placed.entry?.after)

        let priced = try await send(model, "updateSchedule", target.merging(["plannedSpend": 12_000.4]) { $1 }, store: store)
        XCTAssertNil(priced.reason)
        XCTAssertEqual(try plan().plannedSpendKRW, 12_000)
        XCTAssertEqual(try plan().place?.latitude, 0.5, "보내지 않은 장소는 그대로다")

        let retitled = try await send(model, "updateSchedule", target.merging(["title": "늦은 저녁"]) { $1 }, store: store)
        XCTAssertNil(retitled.reason)
        XCTAssertEqual(try plan().place?.name, "꾸민 식당", "다른 칸만 고쳐도 장소·예상 지출이 남는다")
        XCTAssertEqual(try plan().plannedSpendKRW, 12_000)

        let cleared = try await send(model, "updateSchedule", target.merging(["clearPlace": true]) { $1 }, store: store)
        XCTAssertNil(cleared.reason)
        XCTAssertNil(try plan().place)
        XCTAssertEqual(try plan().plannedSpendKRW, 12_000, "장소만 지운다")

        try await undo(model, cleared.entry, store: store)
        XCTAssertEqual(try plan().place, PlanPlace(name: "꾸민 식당", latitude: 0.5, longitude: 0.25))
        try await undo(model, retitled.entry, store: store)
        try await undo(model, priced.entry, store: store)
        XCTAssertNil(try plan().plannedSpendKRW)
        try await undo(model, placed.entry, store: store)
        XCTAssertNil(try plan().place)
    }

    func testPlansCarryThePlaceNameOnlyAtThePlaceLevelAndNeverCoordinates() throws {
        func plan(_ title: String, _ hour: Int, place: String?, spend: Double?) -> PlanRecord {
            PlanRecord(
                title: title, span: TimeSpan(start: at(hour), end: at(hour + 1)), categoryID: "activity",
                place: place.map { PlanPlace(name: $0, latitude: 0.123456, longitude: 0.654321) }, plannedSpendKRW: spend
            )
        }
        let plans = [plan("저녁", 19, place: "꾸민 식당", spend: 30_000), plan("배달", 20, place: "꾸민구 꾸민로 12", spend: nil), plan("산책", 21, place: nil, spend: nil)]
        let input = AssistantActivityInput(
            day: at(0), calendar: calendar, language: .korean, categories: [], steps: nil, plansScheduled: 3, plansCompleted: 0,
            actuals: [], categoryTitles: [:], memos: [], stays: [], travel: [], registeredNames: [:], now: at(23), plans: plans
        )
        let visits = try XCTUnwrap(AssistantActivityBuilder.make(input, level: .visits))
        XCTAssertEqual(visits.plans.map(\.placeName), ["꾸민 식당", nil, nil], "주소처럼 보이는 이름은 뺀다")
        XCTAssertEqual(visits.plans.map(\.plannedSpend), [30_000, nil, nil])
        let summary = try XCTUnwrap(AssistantActivityBuilder.make(input, level: .summary))
        XCTAssertEqual(summary.plans.map(\.placeName), [nil, nil, nil], "하루 요약 수준에서는 장소 이름을 싣지 않는다")
        XCTAssertEqual(summary.plans.first?.plannedSpend, 30_000)
        for day in [visits, summary] {
            let json = String(decoding: try AssistantActivityUploadGate.encoder.encode(day), as: UTF8.self)
            XCTAssertFalse(json.contains("0.123456") || json.contains("0.654321") || json.contains("latitude") || json.contains("꾸민로"))
        }
        let bare = String(decoding: try AssistantActivityUploadGate.encoder.encode(summary.plans[2]), as: UTF8.self)
        XCTAssertFalse(bare.contains("placeName") || bare.contains("plannedSpend"), "없는 칸은 키째 뺀다")
    }

    // MARK: 장소 종류

    func testPlaceKindFollowsTheOnePlaceRuleAndUndoes() async throws {
        let store = defaults()
        let model = await makeModel()
        _ = try await send(model, "addPlace", ["name": "꾸민 사무실", "latitude": 0.1, "longitude": 0.1], store: store)
        _ = try await send(model, "addPlace", ["name": "꾸민 지점", "latitude": 0.6, "longitude": 0.6], store: store)
        func places() -> [FrequentPlace] { model.snapshot.settings.frequentPlaces }
        let office = try XCTUnwrap(places().first { $0.name == "꾸민 사무실" }), branch = try XCTUnwrap(places().first { $0.name == "꾸민 지점" })
        XCTAssertEqual(office.kind, .custom)
        let emptySlot = try XCTUnwrap(places().first { $0.kind == .company && $0.point == nil })

        XCTAssertTrue(try invalid("setPlaceKind", ["placeId": office.id.uuidString, "kind": "office"]))
        XCTAssertTrue(try invalid("setPlaceKind", ["placeId": "p1", "kind": "home"]))
        let missing = try await send(model, "setPlaceKind", ["placeId": UUID().uuidString, "kind": "home"], store: store)
        XCTAssertEqual(missing.reason, "no_place")
        let same = try await send(model, "setPlaceKind", ["placeId": office.id.uuidString, "kind": "custom"], store: store)
        XCTAssertEqual(same.reason, "no_change")
        let slot = try await send(model, "setPlaceKind", ["placeId": emptySlot.id.uuidString, "kind": "custom"], store: store)
        XCTAssertEqual(slot.reason, "place_not_located", "위치가 없는 기본 칸은 바꾸지 않는다")

        let before = places()
        let changed = try await send(model, "setPlaceKind", ["placeId": office.id.uuidString, "kind": "company"], store: store)
        XCTAssertNil(changed.reason)
        XCTAssertEqual(places().filter { $0.kind == .company }.map(\.id), [office.id], "빈 기본 칸을 이 장소가 대신한다")
        XCTAssertEqual(places().count, before.count - 1)
        XCTAssertEqual(changed.entry?.before, "꾸민 사무실 · 기타")
        XCTAssertEqual(changed.entry?.after, "꾸민 사무실 · 회사")

        let taken = try await send(model, "setPlaceKind", ["placeId": branch.id.uuidString, "kind": "company"], store: store)
        XCTAssertEqual(taken.reason, "kind_taken", "회사는 한 곳만 둔다")
        XCTAssertEqual(places().first { $0.id == branch.id }?.kind, .custom)
        let many = try await send(model, "setPlaceKind", ["placeId": branch.id.uuidString, "kind": "restaurant"], store: store)
        XCTAssertNil(many.reason, "식당은 여러 곳을 둔다")

        let stale = await model.undoAssistantEntry(try XCTUnwrap(changed.entry), preferences: .test(store))
        XCTAssertFalse(stale, "그 뒤 장소 목록이 바뀌었으면 되돌리지 않는다")
        try await undo(model, many.entry, store: store)
        try await undo(model, changed.entry, store: store)
        XCTAssertEqual(places().map(\.id), before.map(\.id))
        XCTAssertEqual(places().first { $0.id == office.id }?.kind, .custom)

        // 회사였던 장소가 다른 종류가 되면 빈 회사 칸이 다시 생긴다.
        _ = try await send(model, "setPlaceKind", ["placeId": office.id.uuidString, "kind": "company"], store: store)
        let left = try await send(model, "setPlaceKind", ["placeId": office.id.uuidString, "kind": "hobby"], store: store)
        XCTAssertNil(left.reason)
        XCTAssertEqual(places().filter { $0.kind == .company }.map { $0.point == nil }, [true])
        XCTAssertEqual(places().filter { $0.kind == .hobby }.map(\.id), [office.id])
    }

    // MARK: 지도 활동 색

    func testMapActivityColorChangesShowsInTheAppStateAndUndoes() async throws {
        let store = defaults()
        let model = await makeModel()
        let icon = try XCTUnwrap(MapUserActivityIconCatalog.available(for: []).first)
        XCTAssertTrue(model.addMapUserActivityCategory(title: "꾸민 활동", systemImage: icon, hex: "#112233"))
        await model.persist()
        let customID = try XCTUnwrap(model.snapshot.settings.mapUserActivityCategories.first?.id.uuidString)
        func colors() async -> [AssistantAppState.MapColor] {
            let input = await AssistantAppStateSync.input(model: model, preferences: .test(store), now: at(15), calendar: calendar)
            return AssistantAppStateSync.make(input).settings.mapColors ?? []
        }
        let listed = await colors()
        let work = try XCTUnwrap(listed.first { $0.id == "work" })
        XCTAssertFalse(work.custom)
        XCTAssertEqual(listed.last, .init(id: customID, name: "꾸민 활동", color: "#112233", custom: true))

        XCTAssertTrue(try invalid("setMapActivityColor", ["categoryId": "work", "color": "red"]))
        XCTAssertTrue(try invalid("setMapActivityColor", ["categoryId": "work", "color": "#12345"]))
        XCTAssertTrue(try invalid("setMapActivityColor", ["color": "#123456"]))
        let unknown = try await send(model, "setMapActivityColor", ["categoryId": "nope", "color": "#123456"], store: store)
        XCTAssertEqual(unknown.reason, "unknown_category")
        let same = try await send(model, "setMapActivityColor", ["categoryId": "work", "color": work.color.lowercased()], store: store)
        XCTAssertEqual(same.reason, "no_change")

        let builtIn = try await send(model, "setMapActivityColor", ["categoryId": "work", "color": "#12abef"], store: store)
        XCTAssertNil(builtIn.reason)
        XCTAssertEqual(model.snapshot.settings.mapCategoryColors["work"], "#12ABEF")
        let after = await colors()
        XCTAssertEqual(after.first { $0.id == "work" }?.color, "#12ABEF")
        let again = try await send(model, "setMapActivityColor", ["categoryId": "work", "color": "#445566"], store: store)
        XCTAssertNil(again.reason)
        let stale = await model.undoAssistantEntry(try XCTUnwrap(builtIn.entry), preferences: .test(store))
        XCTAssertFalse(stale, "그 뒤 색이 바뀌었으면 되돌리지 않는다")
        try await undo(model, again.entry, store: store)
        XCTAssertEqual(model.snapshot.settings.mapCategoryColors["work"], "#12ABEF")
        try await undo(model, builtIn.entry, store: store)
        XCTAssertNil(model.snapshot.settings.mapCategoryColors["work"], "고른 적이 없던 색은 기본 색으로 돌아간다")
        XCTAssertEqual(model.mapActivityColor(for: "work"), work.color)

        let custom = try await send(model, "setMapActivityColor", ["categoryId": customID, "color": "#abcdef"], store: store)
        XCTAssertNil(custom.reason)
        XCTAssertEqual(model.snapshot.settings.mapUserActivityCategories.first?.hex, "#ABCDEF")
        XCTAssertEqual(custom.entry?.before, "꾸민 활동 #112233")
        XCTAssertEqual(custom.entry?.after, "꾸민 활동 #ABCDEF")
        try await undo(model, custom.entry, store: store)
        XCTAssertEqual(model.snapshot.settings.mapUserActivityCategories.first?.hex, "#112233")
    }

    // MARK: 근처 메모 알림·장식 벗기

    func testNearbyMemoAlertSwitchIsOneMoreAlertValue() async throws {
        let store = defaults()
        let model = await makeModel()
        XCTAssertTrue(AssistantOperations.alertsOn(store).contains("nearbyMemo"), "정하기 전에는 켜져 있다")
        XCTAssertTrue(try invalid("setAlert", ["alert": "nearbyMemos", "enabled": false]))
        XCTAssertTrue(try invalid("setAlert", ["alert": "nearbyMemo"]))
        let on = try await send(model, "setAlert", ["alert": "nearbyMemo", "enabled": true], store: store)
        XCTAssertEqual(on.reason, "no_change")
        let off = try await send(model, "setAlert", ["alert": "nearbyMemo", "enabled": false], store: store)
        XCTAssertNil(off.reason)
        XCTAssertEqual(store.object(forKey: NearbyMemoPolicy.enabledKey) as? Bool, false)
        XCTAssertFalse(AssistantOperations.alertsOn(store).contains("nearbyMemo"))
        XCTAssertEqual(MapHomeAlarmSettings.stored(store).enabled, MapHomeAlarmSettings.defaultEnabled, "다른 알림은 그대로다")
        XCTAssertEqual(off.entry?.after, "근처에 남긴 메모: 끔")
        let offAgain = try await send(model, "setAlert", ["alert": "nearbyMemo", "enabled": false], store: store)
        XCTAssertEqual(offAgain.reason, "no_change")
        try await undo(model, off.entry, store: store)
        XCTAssertNil(store.object(forKey: NearbyMemoPolicy.enabledKey), "정하기 전으로 돌아간다")
        XCTAssertTrue(AssistantOperations.spec("setAlert")?.guide.contains("|nearbyMemo\"") ?? false)
    }

    func testCatOutfitTakesOneAccessoryOffAndUndoPutsItBack() async throws {
        let store = defaults()
        let model = await makeModel()
        let landmark = try XCTUnwrap(MapHomeLandmarkCatalog.candidates.first)
        let kind = MapHomeGrowthAccessoryCatalog.kind(for: landmark.accessoryID)
        XCTAssertTrue(try invalid("setCatOutfit", ["remove": "shoes"]))
        XCTAssertTrue(try invalid("setCatOutfit", ["remove": kind.rawValue, "accessoryId": landmark.accessoryID]), "입히기와 벗기기를 함께 받지 않는다")
        XCTAssertTrue(try invalid("setCatOutfit", [:]))
        let noHistory = try await send(model, "setCatOutfit", ["remove": kind.rawValue], store: store)
        XCTAssertEqual(noHistory.reason, "no_change")

        var history = MapHomeGrowthHistory.initial(for: at(9))
        history.season.accessories = [landmark.accessoryID]
        store.set(try JSONEncoder().encode(history), forKey: MapHomeGrowthPolicy.storageKey)
        let bare = try await send(model, "setCatOutfit", ["remove": kind.rawValue], store: store)
        XCTAssertEqual(bare.reason, "no_change", "걸친 것이 없으면 벗길 것도 없다")
        let worn = try await send(model, "setCatOutfit", ["accessoryId": landmark.accessoryID], store: store)
        XCTAssertNil(worn.reason)

        let removed = try await send(model, "setCatOutfit", ["remove": kind.rawValue], store: store)
        XCTAssertNil(removed.reason)
        let season = try XCTUnwrap(AssistantOperations.growthHistory(store)?.season)
        XCTAssertNil(season.equipped(kind))
        XCTAssertNil(season.equippedAccessory)
        XCTAssertEqual(season.accessories, [landmark.accessoryID], "받은 장식은 그대로다")
        XCTAssertEqual(removed.entry?.after, "없음")
        try await undo(model, removed.entry, store: store)
        XCTAssertEqual(AssistantOperations.growthHistory(store)?.season.isEquipped(landmark.accessoryID), true)

        var other = MapHomeGrowthHistory.initial(for: at(9)).season
        XCTAssertFalse(MapHomeGrowthPolicy.unequip(kind: .hat, in: &other))
    }

    // MARK: 기록이 바뀐 알림

    func testTheLogAnnouncesNewEntriesAndUndoMarks() async throws {
        let store = defaults()
        let model = await makeModel()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("AssistantMoreActionTests-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let sent = try await send(model, "addSchedule", ["title": "저녁", "start": start], store: store)
        let entry = try XCTUnwrap(sent.entry)

        final class Counter: @unchecked Sendable { var value = 0 }
        let counter = Counter()
        var count: Int { counter.value }
        let token = NotificationCenter.default.addObserver(forName: AssistantActionLog.didChange, object: nil, queue: nil) { _ in
            XCTAssertTrue(Thread.isMainThread)
            counter.value += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }
        AssistantActionLog.append([], to: file)
        XCTAssertEqual(count, 0, "더한 것이 없으면 알리지 않는다")
        AssistantActionLog.append([entry], to: file)
        XCTAssertEqual(count, 1)
        AssistantActionLog.markUndone(UUID(), file: file)
        XCTAssertEqual(count, 1, "없는 항목이면 알리지 않는다")
        AssistantActionLog.markUndone(entry.id, file: file)
        XCTAssertEqual(count, 2)
        XCTAssertNotNil(AssistantActionLog.load(from: file).first?.undoneAt)
        XCTAssertEqual(AssistantActionLog.load(from: file).map(\.id), [entry.id], "저장 형식은 그대로다")
    }
}
