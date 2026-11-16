import XCTest
import TaptionPlanCore
@testable import TaptionPlan

/// 하루 센서 갱신(`refreshSensorTimeline` → `performSensorTimelineRefresh`)의 결과를 고정한다(RFT1116A03).
/// 가짜 원본은 주입한 `archivedReadingsLoader`가 돌려주고, 저장소는 메모리·임시 폴더만 쓴다.
/// 시뮬레이터에는 Core Motion 이력이 없어 동작 기록 분기는 여기서 다루지 않는다.
@MainActor
final class SensorTimelineRefreshTests: XCTestCase {
    /// 지하철역·정류장 카탈로그와 먼 가상의 시골 좌표. 개인 위치가 아니다.
    private let home = GeoPoint(latitude: 36.4300, longitude: 127.9500, altitude: 80,
                                horizontalAccuracy: 8, verticalAccuracy: 5)
    private let work = GeoPoint(latitude: 36.4500, longitude: 127.9500, altitude: 90,
                                horizontalAccuracy: 8, verticalAccuracy: 5)
    private let lunch = GeoPoint(latitude: 36.4560, longitude: 127.9500, altitude: 95,
                                 horizontalAccuracy: 8, verticalAccuracy: 5)

    private var day: Date {
        Calendar.autoupdatingCurrent.date(
            from: DateComponents(year: 2026, month: 6, day: 3, hour: 12)
        )!
    }

    private var span: TimeSpan {
        TimelineAggregationEngine().interval(for: .day, containing: day)
    }

    // MARK: - 가짜 원본

    /// 원본 읽기의 동작을 시험마다 바꾼다. `onRead`는 읽기가 돌려주기 직전에 불린다.
    @MainActor
    private final class Loader {
        var readings: [SensorReading] = []
        var failsDayRead = false
        var onSleepRead: (() async -> Void)?
        private(set) var reads: [TimeSpan] = []
        private let daySpan: TimeSpan

        init(daySpan: TimeSpan) { self.daySpan = daySpan }

        func load(_ requested: TimeSpan) async throws -> [SensorReading] {
            reads.append(requested)
            if requested == daySpan, failsDayRead { throw CocoaError(.fileReadCorruptFile) }
            if requested != daySpan, let onSleepRead { await onSleepRead() }
            return readings.filter {
                $0.timestamp >= requested.start && $0.timestamp < requested.end
            }
        }
    }

    private struct Harness {
        let model: AppModel
        let loader: Loader
    }

    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    private func makeHarness(_ snapshot: TaptionDataSnapshot) throws -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("taption-refresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        directories.append(root)
        let store = try TaptionStoreV2(url: root.appendingPathComponent("store.sqlite"))
        let archive = try SensorReadingArchive(
            fileURL: root.appendingPathComponent("readings.jsonl"), store: store
        )
        let loader = Loader(daySpan: span)
        let model = AppModel(
            repository: InMemoryPlanRepository(snapshot: snapshot),
            sensorService: AppleSensorDataService(
                archive: archive,
                archivedReadingsLoader: { [loader] span in try await loader.load(span) }
            ),
            cloudSyncService: nil,
            rawDeviceDataArchive: try RawDeviceDataDayArchive(store: store),
            registersHealthBackgroundHandler: false,
            dayDatabase: PlanDayDatabase(store: store)
        )
        model.snapshot = snapshot
        return Harness(model: model, loader: loader)
    }

    // MARK: - 견본

    private func baseSnapshot() -> TaptionDataSnapshot {
        var value = TaptionDataSnapshot.empty
        value.categories = CategoryCatalog.builtIn
        value.settings.locationEnabled = false
        value.settings.weatherEnabled = false
        value.settings.healthEnabled = false
        value.settings.frequentPlaces = [
            FrequentPlace(kind: .home, name: "집", point: home),
        ]
        return value
    }

    /// 숨긴 자동 기록 하나. 갱신은 맨 앞(Watch 요약 다시 붙이기)에서 이것을 걸러 내므로,
    /// 갱신이 실패·취소되면 다시 나타나야 한다.
    private func hiddenRecord() -> ActualRecord {
        ActualRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
            planID: nil, title: "숨긴 기록", categoryID: "activity",
            startedAt: span.start.addingTimeInterval(20 * 3_600),
            endedAt: span.start.addingTimeInterval(20.5 * 3_600),
            source: .motion
        )
    }

    private func stay(at point: GeoPoint, from start: Double, to end: Double, floor: Int,
                      screenOn: Bool = false, charging: Bool = false) -> [SensorReading] {
        stride(from: start, to: end, by: 5.0 / 60).map { hour in
            SensorReading(
                timestamp: span.start.addingTimeInterval(hour * 3_600),
                point: point, speedMetersPerSecond: 0,
                motion: .stationary, motionConfidence: .high,
                systemFloor: floor,
                powerState: charging ? .charging : .unplugged,
                screenBrightness: screenOn ? 0.6 : 0, screenIsOn: screenOn
            )
        }
    }

    private func walk(from a: GeoPoint, to b: GeoPoint, from start: Double, to end: Double) -> [SensorReading] {
        let steps = Int(((end - start) * 3_600) / 30)
        return (0...steps).map { step in
            let t = Double(step) / Double(steps)
            return SensorReading(
                timestamp: span.start.addingTimeInterval(start * 3_600 + Double(step) * 30),
                point: GeoPoint(
                    latitude: a.latitude + (b.latitude - a.latitude) * t,
                    longitude: a.longitude + (b.longitude - a.longitude) * t,
                    altitude: 85, horizontalAccuracy: 6, verticalAccuracy: 5
                ),
                speedMetersPerSecond: 1.3, courseDegrees: 0,
                motion: .walking, motionConfidence: .high,
                screenIsOn: true
            )
        }
    }

    /// 집에서 자고(충전·화면 꺼짐) → 걸어서 출근 → 점심 → 복귀 → 걸어서 귀가.
    private func fixtureDay() -> [SensorReading] {
        // 전날 밤부터 집에 있어 밤 구간 읽기에도 표본이 있다.
        let previousNight = stay(at: home, from: -3, to: 0, floor: 3, charging: true)
        return previousNight
            + stay(at: home, from: 0, to: 7.5, floor: 3, charging: true)
            + stay(at: home, from: 7.5, to: 8, floor: 3, screenOn: true)
            + walk(from: home, to: work, from: 8, to: 8.5)
            + stay(at: work, from: 8.5, to: 12, floor: 5, screenOn: true)
            + walk(from: work, to: lunch, from: 12, to: 12.15)
            + stay(at: lunch, from: 12.15, to: 13, floor: 1, screenOn: true)
            + walk(from: lunch, to: work, from: 13, to: 13.15)
            + stay(at: work, from: 13.15, to: 18, floor: 5, screenOn: true)
            + walk(from: work, to: home, from: 18, to: 18.5)
            + stay(at: home, from: 18.5, to: 23.9, floor: 3, screenOn: true)
    }

    // MARK: - 결과 요약

    private func minutes(_ date: Date) -> Int {
        Int((date.timeIntervalSince(span.start) / 60).rounded())
    }

    /// 식별자·생성 시각처럼 실행마다 바뀌는 값을 빼고, 분류 결과를 한 줄씩 적는다.
    private func digest(_ snapshot: TaptionDataSnapshot) -> [String] {
        let actuals = snapshot.actuals.map { actual -> String in
            let s = actual.span(asOf: span.end)
            return "A \(minutes(s.start))-\(minutes(s.end)) \(actual.title) [\(actual.categoryID)] "
                + "\(actual.source.rawValue) \(actual.modelVersion ?? "-") \(actual.behavior ?? "-") "
                + "\(actual.confidence.rawValue)"
        }.sorted()
        let travel = snapshot.travel.map {
            "T \(minutes($0.span.start))-\(minutes($0.span.end)) \($0.mode.rawValue)"
        }.sorted()
        let places = snapshot.places.map {
            "P \(minutes($0.span.start))-\(minutes($0.span.end)) \($0.displayName)"
        }.sorted()
        let floors = ["F \(snapshot.floorTransitions.count)"]
        let sleep = snapshot.settings.confirmedSleepSpans.map {
            "S \(minutes($0.start))-\(minutes($0.end))"
        }.sorted()
        return actuals + travel + places + floors + sleep
    }

    private struct State: Equatable {
        var snapshot: TaptionDataSnapshot
        var snapshotRevision: UInt64
        var dayProjectionRevision: UInt64
        var timelineRevision: UInt64
        var needsLocalRecordNormalization: Bool
        var fingerprint: AppModel.SensorRefreshFingerprint?
        var latestSensorReading: SensorReading?
    }

    private func state(_ model: AppModel) -> State {
        State(
            snapshot: model.snapshot,
            snapshotRevision: model.snapshotRevision,
            dayProjectionRevision: model.dayProjectionRevision,
            timelineRevision: model.timelineRevision,
            needsLocalRecordNormalization: model.needsLocalRecordNormalization,
            fingerprint: model.sensorRefreshFingerprints[span.start],
            latestSensorReading: model.latestSensorReading
        )
    }

    private func assertIdle(_ model: AppModel, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(model.isSensorTimelineRefreshing, file: file, line: line)
        XCTAssertFalse(model.userEditedDuringSensorRefresh, file: file, line: line)
        XCTAssertEqual(model.activeDataMutationCount, 0, file: file, line: line)
    }

    // MARK: - 고정 결과

    /// 지금 코드가 만든 결과(RFT1116A03 이전 커밋에서 기록). 분류 엔진을 일부러 바꾸면 이 표도 함께 고친다.
    private let goldenFullRefresh: [String] = [
        "A -150-445 수면 [sleep] motion classifier-v1/sleep-rule sleep-rule high",
        "A 0-481 집에서 휴식 [rest] location classifier-v1/context homeRest medium",
        "A 1081-1110 걷기 [movement] motion classifier-v1/gap walking high",
        "A 1110-1430 집에서 휴식 [rest] location classifier-v1/context homeRest medium",
        "A 1430-1440 휴식 [activity] motion classifier-v1/gap stationary medium",
        "A 481-510 걷기 [movement] motion classifier-v1/gap walking high",
        "A 510-721 머무름 [activity] location classifier-v1/context unknownStay low",
        "A 721-729 걷기 [movement] motion classifier-v1/gap walking high",
        "A 729-781 머무름 [activity] location classifier-v1/context unknownStay low",
        "A 781-789 걷기 [movement] motion classifier-v1/gap walking high",
        "A 789-1081 머무름 [activity] location classifier-v1/context unknownStay low",
        "T 1081-1110 walking",
        "T 481-510 walking",
        "T 721-729 walking",
        "T 781-789 walking",
        "P 0-481 집",
        "P 1110-1430 집",
        "P 510-721 장소 · 5층 추정",
        "P 729-781 장소 · 1층 추정",
        "P 789-1081 장소 · 5층 추정",
        "F 0",
    ]

    // MARK: - 시험

    func testFullRefreshPinsClassificationTravelAndPlaces() async throws {
        let harness = try makeHarness(baseSnapshot())
        harness.loader.readings = fixtureDay()

        let result = await harness.model.refreshSensorTimeline(containing: day)

        XCTAssertTrue(result)
        assertIdle(harness.model)
        let lines = digest(harness.model.snapshot)
        XCTAssertEqual(lines, goldenFullRefresh)
        XCTAssertNotNil(harness.model.sensorRefreshFingerprints[span.start])
        // 지난 날 갱신은 지금 위치 표시를 바꾸지 않는다.
        XCTAssertNil(harness.model.latestSensorReading)
        XCTAssertEqual(harness.loader.reads.first, span)
        XCTAssertEqual(harness.loader.reads.count, 2, "하루 구간과 밤 구간을 한 번씩 읽는다")
    }

    func testSameDayRunsTwiceWithTheSameResult() async throws {
        let first = try makeHarness(baseSnapshot())
        first.loader.readings = fixtureDay()
        _ = await first.model.refreshSensorTimeline(containing: day)
        let second = try makeHarness(baseSnapshot())
        second.loader.readings = fixtureDay()
        _ = await second.model.refreshSensorTimeline(containing: day)
        XCTAssertEqual(digest(first.model.snapshot), digest(second.model.snapshot))
    }

    /// 입력 지문이 같으면 경로·장소를 다시 만들지 않고, 지문이 바뀌면 다시 만든다.
    func testUnchangedFingerprintSkipsRebuildAndChangedInputRebuilds() async throws {
        let harness = try makeHarness(baseSnapshot())
        harness.loader.readings = fixtureDay()
        let result1 = await harness.model.refreshSensorTimeline(containing: day)
        XCTAssertTrue(result1)
        let fingerprint = harness.model.sensorRefreshFingerprints[span.start]
        let travelCount = harness.model.snapshot.travel.count
        XCTAssertGreaterThan(travelCount, 0)

        // 갱신 밖에서 이동을 지워도, 지문이 같으면 이동을 다시 만들지 않는다.
        harness.model.snapshot.travel = []
        let result2 = await harness.model.refreshSensorTimeline(containing: day)
        XCTAssertTrue(result2)
        XCTAssertEqual(harness.model.snapshot.travel.count, 0)
        XCTAssertEqual(harness.model.sensorRefreshFingerprints[span.start], fingerprint)
        assertIdle(harness.model)

        // 원본이 하나 늘면 지문이 바뀌어 처음과 같은 결과를 다시 만든다.
        harness.loader.readings += stay(at: home, from: 23.9, to: 23.95, floor: 3, screenOn: true)
        let result3 = await harness.model.refreshSensorTimeline(containing: day)
        XCTAssertTrue(result3)
        XCTAssertEqual(harness.model.snapshot.travel.count, travelCount)
        XCTAssertNotEqual(harness.model.sensorRefreshFingerprints[span.start], fingerprint)
        XCTAssertEqual(
            digest(harness.model.snapshot).filter { $0.hasPrefix("T ") },
            goldenFullRefresh.filter { $0.hasPrefix("T ") }
        )
    }

    /// 근거가 전혀 없는 날은 기록을 건드리지 않고 지문만 남긴다.
    func testNoEvidenceDayKeepsRecordsAndStoresFingerprint() async throws {
        var snapshot = baseSnapshot()
        let manual = ActualRecord(
            planID: nil, title: "직접 적은 일", categoryID: "work",
            startedAt: span.start.addingTimeInterval(9 * 3_600),
            endedAt: span.start.addingTimeInterval(10 * 3_600), source: .manual
        )
        snapshot.actuals = [manual]
        let harness = try makeHarness(snapshot)

        let result4 = await harness.model.refreshSensorTimeline(containing: day)
        XCTAssertTrue(result4)

        XCTAssertEqual(harness.model.snapshot.actuals, [manual])
        XCTAssertTrue(harness.model.snapshot.travel.isEmpty)
        XCTAssertTrue(harness.model.snapshot.places.isEmpty)
        XCTAssertNotNil(harness.model.sensorRefreshFingerprints[span.start])
        assertIdle(harness.model)
    }

    /// 원본 읽기가 실패하면 갱신이 앞에서 바꾼 것(숨긴 기록 걸러 내기)을 되돌리고 오류를 알린다.
    func testReadFailureRollsBackOwnChangesAndReportsError() async throws {
        var snapshot = baseSnapshot()
        let hidden = hiddenRecord()
        snapshot.actuals = [hidden]
        snapshot.settings.suppressedActualIDs = [hidden.id]
        let harness = try makeHarness(snapshot)
        harness.loader.failsDayRead = true
        let before = state(harness.model)

        let result5 = await harness.model.refreshSensorTimeline(containing: day)
        XCTAssertFalse(result5)

        XCTAssertEqual(state(harness.model), before)
        XCTAssertEqual(harness.model.snapshot.actuals.map(\.id), [hidden.id])
        XCTAssertTrue(
            harness.model.userFacingError?.hasPrefix(AppModelMessage.locationReadFailed("").lead()) == true
        )
        assertIdle(harness.model)
    }

    /// 밤 구간 읽기 중에 취소되면, 갱신이 바꾼 것만 있으니 전부 갱신 전으로 되돌린다.
    /// 앞선 갱신의 지문도 그대로 남는다.
    func testCancellationRestoresSnapshotRevisionsAndPreviousFingerprint() async throws {
        let harness = try makeHarness(baseSnapshot())
        harness.loader.readings = fixtureDay()
        let result6 = await harness.model.refreshSensorTimeline(containing: day)
        XCTAssertTrue(result6)
        let previousFingerprint = harness.model.sensorRefreshFingerprints[span.start]
        XCTAssertNotNil(previousFingerprint)

        let hidden = hiddenRecord()
        harness.model.snapshot.actuals.append(hidden)
        harness.model.snapshot.settings.suppressedActualIDs.insert(hidden.id)
        harness.model.needsLocalRecordNormalization = false
        let before = state(harness.model)
        harness.loader.onSleepRead = {
            withUnsafeCurrentTask { $0?.cancel() }
        }

        let result7 = await harness.model.refreshSensorTimeline(containing: day)
        XCTAssertFalse(result7)

        XCTAssertEqual(state(harness.model), before)
        XCTAssertTrue(harness.model.snapshot.actuals.contains { $0.id == hidden.id })
        XCTAssertEqual(harness.model.sensorRefreshFingerprints[span.start], previousFingerprint)
        XCTAssertNil(harness.model.userFacingError)
        assertIdle(harness.model)
    }

    /// 갱신 도중 다른 작업이 기록을 바꾸고 갱신이 취소되면, 그 변경을 지키려고 되돌리지 않는다.
    /// 대신 지문을 지워 다음 갱신이 다시 계산하게 하고, 정리 표시를 켠다(REV1110A04).
    func testCancellationAfterOutsideEditKeepsEditAndClearsFingerprint() async throws {
        let harness = try makeHarness(baseSnapshot())
        harness.loader.readings = fixtureDay()
        let result8 = await harness.model.refreshSensorTimeline(containing: day)
        XCTAssertTrue(result8)
        XCTAssertNotNil(harness.model.sensorRefreshFingerprints[span.start])

        let hidden = hiddenRecord()
        harness.model.snapshot.actuals.append(hidden)
        harness.model.snapshot.settings.suppressedActualIDs.insert(hidden.id)
        harness.model.needsLocalRecordNormalization = false
        let revisionBefore = harness.model.snapshotRevision
        let plan = PlanRecord(
            title: "갱신 중 더한 계획",
            span: TimeSpan(start: span.start.addingTimeInterval(15 * 3_600),
                           end: span.start.addingTimeInterval(16 * 3_600)),
            categoryID: "work"
        )
        let model = harness.model
        harness.loader.onSleepRead = {
            // 갱신 작업 밖(작업 지역 값을 물려받지 않는 분리 작업)에서 바꾼다.
            await Task.detached { @MainActor in model.snapshot.plans.append(plan) }.value
            withUnsafeCurrentTask { $0?.cancel() }
        }

        let result9 = await harness.model.refreshSensorTimeline(containing: day)
        XCTAssertFalse(result9)

        XCTAssertTrue(harness.model.snapshot.plans.contains { $0.id == plan.id })
        // 갱신이 앞에서 걸러 낸 숨긴 기록도 되돌리지 않는다.
        XCTAssertFalse(harness.model.snapshot.actuals.contains { $0.id == hidden.id })
        XCTAssertNil(harness.model.sensorRefreshFingerprints[span.start])
        XCTAssertTrue(harness.model.needsLocalRecordNormalization)
        XCTAssertGreaterThan(harness.model.snapshotRevision, revisionBefore)
        assertIdle(harness.model)
    }
}
