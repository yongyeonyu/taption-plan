import XCTest
@testable import TaptionPlan
import TaptionPlanCore
import TaptionPlanStore

/// PLB1114A18: 일반 일정의 장소·예상 지출 — 저장·백업·동기화 호환, 도착 카드, 「계획과 실제」. 좌표는 꾸민 값이다.
@MainActor
final class PlanSpotTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_792_300_000)
    private var directories: [URL] = []
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Seoul") ?? .gmt
        return value
    }

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("plan-spot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url)
        return url
    }

    private func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }
    private func span(_ from: Double, _ to: Double) -> TimeSpan { TimeSpan(start: at(from), end: at(to)) }
    private var day: TimeSpan { TimeSpan(start: at(-600), end: at(840)) }

    private func plan(_ title: String = "저녁", _ from: Double = 0, _ to: Double = 60, place: PlanPlace? = PlanPlace(name: "식당", latitude: 0.5, longitude: 0.5), spend: Double? = 30_000) -> PlanRecord {
        PlanRecord(title: title, span: span(from, to), categoryID: "activity", createdAt: base, updatedAt: base, place: place, plannedSpendKRW: spend)
    }

    /// 이 칸이 생기기 전 빌드가 쓴 일정 행의 본문.
    private func legacyBody(_ id: UUID) -> String {
        #"{"categoryID":"work","createdAt":1792300000,"id":"\#(id.uuidString)","isFixed":false,"isImportant":false,"origin":"user","span":{"end":1792303600,"start":1792300000},"status":"planned","title":"회의","updatedAt":1792300000}"#
    }

    // MARK: 값 다듬기

    func testSpotKeepsOnlyStorableValues() {
        XCTAssertEqual(PlanSpot(place: PlanPlace(name: "  식당 ", latitude: 0.5, longitude: 0.5), spendText: "30,000원").place?.name, "식당")
        XCTAssertEqual(PlanSpot(place: nil, spendText: "30,000원").plannedSpendKRW, 30_000)
        XCTAssertNil(PlanSpot(place: nil, spendText: "").plannedSpendKRW)
        XCTAssertNil(PlanSpot(place: nil, spendText: "0").plannedSpendKRW)
        XCTAssertNil(PlanSpot(place: nil, plannedSpendKRW: .infinity).plannedSpendKRW)
        XCTAssertNil(PlanSpot(place: PlanPlace(name: " ", latitude: 0.5, longitude: 0.5), plannedSpendKRW: nil).place)
        XCTAssertNil(PlanSpot(place: PlanPlace(name: "곳", latitude: 91, longitude: 0), plannedSpendKRW: nil).place)
        XCTAssertNil(PlanSpot(place: PlanPlace(name: "곳", latitude: .nan, longitude: 0), plannedSpendKRW: nil).place)
    }

    func testPickerListsRegisteredPlacesWithCoordinatesAndFiltersByName() {
        let point = GeoPoint(latitude: 0.5, longitude: 0.5, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10)
        var gym = FrequentPlace.defaults[0], cafe = FrequentPlace.defaults[0], empty = FrequentPlace.defaults[0]
        gym.name = "체육관"; gym.point = point
        cafe.name = "카페"; cafe.point = point
        empty.name = "좌표 없음"; empty.point = nil
        XCTAssertEqual(PlanPlacePicker.registered([gym, cafe, empty], matching: "").map(\.name), ["체육관", "카페"])
        XCTAssertEqual(PlanPlacePicker.registered([gym, cafe, empty], matching: "카").map(\.name), ["카페"])
    }

    // MARK: 저장소·백업·동기화

    func testStoreRoundTripKeepsPlaceAndSpendAndLeavesLegacyRowsUntouched() async throws {
        let store = try TaptionStoreV2(url: try makeDirectory().appendingPathComponent("taption.sqlite"))
        let repository = TaptionStoreRepository(store: store)
        var snapshot = TaptionDataSnapshot.empty
        snapshot.updatedAt = base
        let old = plan("회의", place: nil, spend: nil)
        snapshot.plans = [old]
        try await repository.save(snapshot)
        let legacy = try await store.records(kind: "plan").first?.body
        XCTAssertEqual(legacy?.contains("place"), false, "값이 없으면 키를 쓰지 않는다")
        XCTAssertEqual(legacy?.contains("plannedSpendKRW"), false)

        // 새 일정을 더해도 예전 일정 행은 다시 쓰지 않는다.
        let dinner = plan()
        snapshot.plans.append(dinner)
        snapshot.updatedAt = base.addingTimeInterval(10)
        try await repository.save(snapshot)
        let rows = Dictionary(uniqueKeysWithValues: try await store.records(kind: "plan").map { ($0.id, $0) })
        XCTAssertEqual(rows["\(old.id)"]?.body, legacy)
        XCTAssertEqual(rows["\(old.id)"]?.updatedAt, base)

        let reloaded = try await TaptionStoreRepository(store: store).load()
        XCTAssertEqual(reloaded.plans, snapshot.plans)
        XCTAssertEqual(reloaded.plans.last?.place, PlanPlace(name: "식당", latitude: 0.5, longitude: 0.5))
        XCTAssertEqual(reloaded.plans.last?.plannedSpendKRW, 30_000)
    }

    /// 예전 빌드가 쓴 행(키 없음)이 든 기존 DB를 열어 읽고, 다른 것을 저장해도 그 행의 바이트가 그대로다.
    func testExistingDatabaseWithLegacyPlanRowsLoadsAndIsNotRewritten() async throws {
        let url = try makeDirectory().appendingPathComponent("taption.sqlite")
        let id = UUID()
        var seeded = TaptionDataSnapshot.empty
        seeded.updatedAt = base
        do {
            let store = try TaptionStoreV2(url: url)
            try await TaptionStoreRepository(store: store).save(seeded)
            try await store.upsertRecords([TaptionStoreRecord(
                id: "\(id)", kind: "plan", start: base, end: base.addingTimeInterval(3_600), updatedAt: base, origin: .user, ord: 0, body: legacyBody(id)
            )])
        }
        let store = try TaptionStoreV2(url: url)
        let repository = TaptionStoreRepository(store: store)
        var loaded = try await repository.load()
        XCTAssertEqual(loaded.plans.map(\.id), [id])
        XCTAssertNil(loaded.plans[0].place)
        loaded.plans.append(plan())
        loaded.updatedAt = base.addingTimeInterval(10)
        try await repository.save(loaded)
        let stored = try await store.records(kind: "plan").first { $0.id == "\(id)" }
        XCTAssertEqual(stored?.body, legacyBody(id))
    }

    /// 새 백업(TAPTBK03)과 옛 형식(TAPTBK02) 모두 일정 행을 그대로 싣는다: 장소·지출이 든 행도, 키가 없는 예전 행도.
    func testBackupRoundTripInBothFormatsKeepsNewAndLegacyPlanRows() async throws {
        let root = try makeDirectory()
        let source = try TaptionStoreV2(url: root.appendingPathComponent("source.sqlite"), calendar: calendar)
        var snapshot = TaptionDataSnapshot.empty
        snapshot.updatedAt = base
        let dinner = plan()
        snapshot.plans = [dinner]
        try await TaptionStoreRepository(store: source).save(snapshot)
        let legacyID = UUID()
        try await source.upsertRecords([TaptionStoreRecord(
            id: "\(legacyID)", kind: "plan", start: base, end: base.addingTimeInterval(3_600), updatedAt: base, origin: .user, ord: 1, body: legacyBody(legacyID)
        )])
        let components = calendar.dateComponents([.year, .month], from: base)
        let month = TaptionBackupMonth(year: components.year ?? 0, month: components.month ?? 0)
        let temporary = root.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)

        for version in [2, 3] {
            let destination = TaptionLocalFolderBackupDestination(directory: root.appendingPathComponent("v\(version)", isDirectory: true))
            var configuration = TaptionBackupEngine.Configuration()
            configuration.iterations = 1_000
            configuration.minimumIterations = 1
            configuration.temporaryDirectory = temporary
            var writing = configuration
            writing.formatVersion = version
            let written = try await TaptionBackupEngine(store: source, destination: destination, calendar: calendar, configuration: writing)
                .backup(month: month, password: "482915", now: base.addingTimeInterval(86_400))
            XCTAssertEqual(written.header?.version, version)

            let target = try TaptionStoreV2(url: root.appendingPathComponent("target-\(version).sqlite"), calendar: calendar)
            _ = try await TaptionBackupEngine(store: target, destination: destination, calendar: calendar, configuration: configuration)
                .restore(month: month, password: "482915")
            let rows = Dictionary(uniqueKeysWithValues: try await target.records(kind: "plan").map { ($0.id, $0.body) })
            XCTAssertEqual(rows["\(legacyID)"], legacyBody(legacyID), "v\(version): 예전 행은 바이트 그대로")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            let restored = try decoder.decode(PlanRecord.self, from: Data(try XCTUnwrap(rows["\(dinner.id)"]).utf8))
            XCTAssertEqual(restored, dinner, "v\(version): 장소·예상 지출이 돌아온다")
            XCTAssertNil(try decoder.decode(PlanRecord.self, from: Data(legacyBody(legacyID).utf8)).place)
        }
    }

    /// 이 칸을 모르는 빌드가 다시 저장한 사본(같은 수정 시각, 칸 없음)이 어느 쪽에서 와도 값을 잃지 않는다.
    /// 그 빌드가 일정을 고쳐 수정 시각이 더 늦으면 그 사본이 이긴다(지운 것과 구분할 수 없다).
    func testCloudMergeKeepsPlaceAndSpendAgainstAStrippedCopyOfTheSameEdit() {
        let dinner = plan()
        var stripped = dinner
        stripped.place = nil
        stripped.plannedSpendKRW = nil
        var mine = TaptionDataSnapshot.empty, theirs = TaptionDataSnapshot.empty
        mine.plans = [dinner]; mine.updatedAt = base
        theirs.plans = [stripped]; theirs.updatedAt = base.addingTimeInterval(60)
        for merged in [CloudSnapshotRecoveryEngine.merge(local: mine, remote: theirs), CloudSnapshotRecoveryEngine.merge(local: theirs, remote: mine)] {
            XCTAssertEqual(merged.plans.first?.place, dinner.place)
            XCTAssertEqual(merged.plans.first?.plannedSpendKRW, 30_000)
        }
        var edited = stripped
        edited.title = "고친 저녁"
        edited.updatedAt = base.addingTimeInterval(30)
        theirs.plans = [edited]
        let merged = CloudSnapshotRecoveryEngine.merge(local: mine, remote: theirs)
        XCTAssertEqual(merged.plans.first?.title, "고친 저녁")
        XCTAssertNil(merged.plans.first?.place)
    }

    func testSnapshotJSONExportRoundTripKeepsPlaceAndSpend() throws {
        var snapshot = TaptionDataSnapshot.empty
        snapshot.plans = [plan()]
        let decoded = try SnapshotExporter.decodeJSON(try SnapshotExporter.jsonData(snapshot))
        XCTAssertEqual(decoded.plans, snapshot.plans)
    }

    // MARK: 모델

    func testAddAndUpdatePlanCarryTheSpotAndCallsWithoutItLeaveItAlone() async throws {
        var stored = TaptionDataSnapshot.empty
        stored.categories = CategoryCatalog.builtIn
        stored.settings.locationEnabled = false
        stored.settings.weatherEnabled = false
        stored.settings.healthEnabled = false
        let model = AppModel(repository: InMemoryPlanRepository(snapshot: stored), cloudSyncService: nil, registersHealthBackgroundHandler: false)
        await model.bootstrap()
        let spot = PlanSpot(place: PlanPlace(name: "식당", latitude: 0.5, longitude: 0.5), spendText: "30000")
        let id = try XCTUnwrap(model.addPlan(title: "저녁", categoryID: "activity", startAt: base, duration: 3_600, spot: spot))
        func saved() -> PlanRecord? { model.snapshot.plans.first { $0.id == id } }
        XCTAssertEqual(saved()?.place?.name, "식당")
        XCTAssertEqual(saved()?.plannedSpendKRW, 30_000)

        model.updatePlan(id, title: "늦은 저녁", categoryID: "activity", span: span(30, 90), parentID: nil, isImportant: false)
        XCTAssertEqual(saved()?.title, "늦은 저녁")
        XCTAssertEqual(saved()?.place?.name, "식당", "칸을 넘기지 않은 호출은 지우지 않는다")
        XCTAssertEqual(saved()?.plannedSpendKRW, 30_000)

        model.updatePlan(id, title: "늦은 저녁", categoryID: "activity", span: span(30, 90), parentID: nil, isImportant: false, spot: PlanSpot(place: nil, spendText: ""))
        XCTAssertNil(saved()?.place)
        XCTAssertNil(saved()?.plannedSpendKRW)
    }

    // MARK: 도착 카드

    private func fix(latitude: Double = 0.5, at time: Date) -> ArrivalFix {
        ArrivalFix(latitude: latitude, longitude: 0.5, horizontalAccuracy: 20, timestamp: time.addingTimeInterval(-1))
    }

    func testPlanWithPlaceBecomesAnArrivalCandidateInsideItsOwnTimeWindow() {
        let dinner = plan("저녁", 120, 180)
        let memo = ActionMemo(planID: dinner.id, kind: .idea, text: " 창가 자리 ", createdAt: base, updatedAt: base)
        let other = ActionMemo(planID: UUID(), kind: .idea, text: "다른 메모", createdAt: base, updatedAt: base)
        let candidates = ArrivalDetector.candidates(stops: [], items: [], plans: [dinner, plan("장소 없음", place: nil)], memos: [memo, other])
        XCTAssertEqual(candidates.map(\.stopID), [dinner.id])
        XCTAssertEqual(ArrivalDetector.arrival(fix: fix(at: at(0)), now: at(0), candidates: candidates, shown: [])?.stopID, dinner.id, "시작 2시간 전부터")
        XCTAssertNil(ArrivalDetector.arrival(fix: fix(at: at(-1)), now: at(-1), candidates: candidates, shown: []))
        XCTAssertNotNil(ArrivalDetector.arrival(fix: fix(at: at(180)), now: at(180), candidates: candidates, shown: []))
        XCTAssertNil(ArrivalDetector.arrival(fix: fix(at: at(181)), now: at(181), candidates: candidates, shown: []), "일정이 끝나면 보지 않는다")
        XCTAssertNil(ArrivalDetector.arrival(fix: fix(latitude: 0.502, at: at(130)), now: at(130), candidates: candidates, shown: []), "약 222m는 반경 밖")
        XCTAssertNil(ArrivalDetector.arrival(fix: fix(at: at(130)), now: at(130), candidates: candidates, shown: [dinner.id]), "한 번만")

        let card = ArrivalCard.make(candidate: candidates[0], items: [], tripBudgetKRW: nil)
        XCTAssertEqual(card.id, dinner.id)
        XCTAssertEqual(card.title, "식당")
        XCTAssertEqual(card.note, "창가 자리")
        XCTAssertEqual(card.plannedSpendKRW, 30_000)
        XCTAssertEqual(card.start, dinner.span.start)
        XCTAssertEqual(card.end, dinner.span.end)
        XCTAssertTrue(card.checklist.isEmpty)
        XCTAssertNil(card.tripBudgetKRW)
    }

    func testRoutinesSkippedPlansAndPlansWithATravelPinAreNotDoubled() {
        var skipped = plan("건너뜀")
        skipped.status = .skipped
        let routine = plan("루틴: 운동")
        let pinned = plan("핀 있는 일정")
        let pin = TravelPlanStop(id: UUID(), title: "핀", latitude: 0.5, longitude: 0.5, day: base, order: 0, planID: pinned.id)
        let candidates = ArrivalDetector.candidates(stops: [pin], items: [], plans: [skipped, routine, pinned])
        XCTAssertEqual(candidates.map(\.stopID), [pin.id], "여행 핀이 이어진 일정은 핀 하나만 후보다")
        XCTAssertNil(candidates[0].plannedSpendKRW)
    }

    // MARK: 계획과 실제

    private func stay(_ from: Double, _ to: Double, latitude: Double) -> PlaceStay {
        PlaceStay(placeKey: "k\(from)", displayName: "머문 곳", span: span(from, to), confidence: .high,
                  point: GeoPoint(latitude: latitude, longitude: 0.5, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10))
    }

    private func expense(_ amount: Double, _ minute: Double, tripID: String? = nil) -> LedgerEntry {
        LedgerEntry(occurredAt: at(minute), amount: amount, amountKRW: amount, title: "지출", tripID: tripID)
    }

    func testPlanPlaceMatchesAStayWithin200MetersAndCountsEverySpendInTheActualTime() {
        let dinner = plan("저녁", 0, 60)
        // 위도 0.001도는 약 111m.
        let input = PlanRealityGap.Input(
            plans: [dinner], places: [stay(20, 95, latitude: 0.5015), stay(0, 10, latitude: 0.6)],
            entries: [expense(18_000, 30), expense(9_000, 90), expense(4_000, 10), expense(7_000, 100)],
            day: day, now: at(300)
        )
        let result = PlanRealityGap.day(input)
        let row = result.items[0]
        XCTAssertEqual(row.match, .place)
        XCTAssertEqual(row.actual, span(20, 95))
        XCTAssertEqual(row.plannedKRW, 30_000)
        XCTAssertEqual(row.spentKRW, 27_000, "계획 시간이 아니라 실제로 한 시간(20~95분) 안의 지출 전부")
        XCTAssertTrue(row.isSpendEstimated)
        XCTAssertEqual(row.costDelta, -3_000)
        XCTAssertEqual(result.plannedKRW, 30_000)
        XCTAssertEqual(result.spentKRW, 27_000)

        var farInput = input
        farInput.places = [stay(20, 95, latitude: 0.503)]
        XCTAssertNil(PlanRealityGap.day(farInput).items[0].actual, "약 333m는 짝짓지 않는다")
    }

    func testPlanWithoutAnActualRecordGetsNoSpentAmount() {
        let result = PlanRealityGap.day(.init(plans: [plan("저녁", 0, 60)], entries: [expense(18_000, 30)], day: day, now: at(300)))
        XCTAssertEqual(result.items[0].plannedKRW, 30_000)
        XCTAssertNil(result.items[0].spentKRW, "실제 기록이 없으면 쓴 돈을 세지 않는다")
        XCTAssertNil(result.items[0].costDelta)
        XCTAssertEqual(result.spentKRW, 0)
    }

    func testLinkedRecordWindowOverlapAndTripSpendingRules() {
        let lunch = plan("점심", 0, 60, place: nil, spend: 10_000), coffee = plan("커피", 60, 90, place: nil, spend: 5_000)
        let free = plan("산책", 200, 230, place: nil, spend: nil)
        let actuals = [
            ActualRecord(planID: lunch.id, title: "a", categoryID: "c", startedAt: at(0), endedAt: at(70), source: .manual),
            ActualRecord(planID: coffee.id, title: "a", categoryID: "c", startedAt: at(60), endedAt: at(95), source: .manual),
            ActualRecord(planID: free.id, title: "a", categoryID: "c", startedAt: at(200), endedAt: at(230), source: .manual),
        ]
        let item = TravelTripItem(tripID: "t1", itemID: "a", kind: "sight", title: "곳", start: at(40), end: at(50), startOffsetSeconds: 0, endOffsetSeconds: 0, planID: nil, plannedSpendKRW: 1_000)
        var canceled = expense(50_000, 20)
        canceled.canceledAt = at(21)
        var income = expense(50_000, 22)
        income.kind = .income
        let entries = [
            expense(8_000, 30), expense(3_000, 65), expense(2_000, 45, tripID: "t1"), expense(1_500, 55, tripID: "t1"),
            expense(6_000, 210), canceled, income,
        ]
        let result = PlanRealityGap.day(.init(plans: [lunch, coffee, free], actuals: actuals, tripItems: [item], entries: entries, day: day, now: at(300)))
        let rows = Dictionary(uniqueKeysWithValues: result.items.map { ($0.title, $0) })
        XCTAssertEqual(rows["점심"]?.spentKRW, 9_500, "여행 일정이 가져간 2,000원과 취소·수입은 빼고, 여행 장부라도 여행 일정 밖 시각의 1,500원은 센다")
        XCTAssertEqual(rows["커피"]?.spentKRW, 3_000, "겹치는 65분의 지출은 늦게 시작한 쪽의 것")
        XCTAssertNil(rows["산책"]?.plannedKRW)
        XCTAssertNil(rows["산책"]?.spentKRW, "예상 지출을 넣지 않은 일정은 쓴 돈도 세지 않는다")
        XCTAssertEqual(rows["곳"]?.spentKRW, 2_000)
        XCTAssertEqual(rows["곳"]?.isSpendEstimated, false)
    }

    func testOngoingPlanWithNoSpendingYetShowsNoDifference() {
        let dinner = plan("저녁", 0, 60, place: nil)
        let running = ActualRecord(planID: dinner.id, title: "a", categoryID: "c", startedAt: at(5), endedAt: nil, source: .manual)
        let result = PlanRealityGap.day(.init(plans: [dinner], actuals: [running], day: day, now: at(30)))
        XCTAssertTrue(result.items[0].isOngoing)
        XCTAssertNil(result.items[0].spentKRW)
    }

    func testMapStopsListPlacedPlansOfTheDayInTimeOrderWithoutPinnedOnes() {
        let late = plan("늦은", 120, 180), early = plan("이른", 0, 60), pinned = plan("핀", 30, 40)
        let otherDay = plan("다른 날", 3_000, 3_060), none = plan("없음", 10, 20, place: nil)
        let stops = PlanSpot.mapStops(plans: [late, early, pinned, otherDay, none], day: day, pinned: [pinned.id], after: 2)
        XCTAssertEqual(stops.map(\.id), [early.id, late.id])
        XCTAssertEqual(stops.map(\.order), [2, 3])
    }
}
