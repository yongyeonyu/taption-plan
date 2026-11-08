import XCTest
@testable import TaptionPlan

final class LiveActivityDaySummaryTests: XCTestCase {
    private typealias State = SensorCollectionActivityAttributes.ContentState

    private func summary(
        _ seconds: [String: TimeInterval],
        steps: Int? = nil,
        meters: Double = 0
    ) -> SensorCollectionDaySummary {
        LiveActivityDaySummaryBuilder.make(
            categorySeconds: seconds,
            steps: steps,
            meters: meters,
            categoryColors: [:],
            language: .korean,
            distanceText: { "\(Int($0))m" }
        )
    }

    private func state(_ daySummary: SensorCollectionDaySummary? = nil) -> State {
        State(
            startedAt: Date(timeIntervalSinceReferenceDate: 1_000),
            lastSavedAt: nil,
            collectionKinds: ["location"],
            isCollecting: true,
            daySummary: daySummary
        )
    }

    func testKeepsTopFourByTimeWithStableTieOrder() {
        let value = summary([
            "work": 7_200, "study": 3_600, "hobby": 3_600, "exercise": 1_800,
            "eating": 600, "unconfirmed": 90_000,
        ])
        XCTAssertEqual(value.categories.map(\.id), ["work", "hobby", "study", "exercise"])
        XCTAssertEqual(value.categories.map(\.minutes), [120, 60, 60, 30])
        XCTAssertEqual(value.categories.first?.durationText, "2시간")
        XCTAssertTrue(value.categories.allSatisfy { !$0.hex.isEmpty })
    }

    func testUsesCounterColorOverrideAndDurationStyle() {
        let value = LiveActivityDaySummaryBuilder.make(
            categorySeconds: ["work": 11_520],
            steps: 1,
            meters: 1,
            categoryColors: ["work": "#123456"],
            language: .korean
        )
        XCTAssertEqual(value.categories.first?.hex, "#123456")
        XCTAssertEqual(value.categories.first?.durationText, "3시간 12분")
    }

    func testEmptyDayAndUnderOneMinuteHaveNoCategories() {
        let empty = summary([:])
        XCTAssertEqual(empty.categories, [])
        XCTAssertEqual(empty.steps, 0)
        XCTAssertEqual(empty.meters, 0)
        XCTAssertEqual(summary(["work": 59]).categories, [])
    }

    func testStepsAndDistanceValues() {
        let value = summary([:], steps: 8_231, meters: 3_456.6)
        XCTAssertEqual(value.steps, 8_231)
        XCTAssertEqual(value.meters, 3_457)
        XCTAssertEqual(value.distanceText, "3456m")
        XCTAssertEqual(summary([:], steps: -3, meters: -.infinity).steps, 0)
        XCTAssertEqual(summary([:], steps: -3, meters: -.infinity).meters, 0)
    }

    func testOldPayloadWithRemovedSensorFieldsDecodes() throws {
        var old = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(state())
        ) as? [String: Any])
        old["sensorMeterMasks"] = ["location": 3]
        old["sensorStatusRawValues"] = ["location": "receiving"]
        old["waveformScanStartedAt"] = 1_000.0
        old.removeValue(forKey: "daySummary")
        let decoded = try JSONDecoder().decode(State.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(decoded.daySummary)
        XCTAssertEqual(decoded.collectionKinds, ["location"])
    }

    func testSummaryRoundTripsAndWorstCasePayloadStaysUnderLimit() throws {
        let category = SensorCollectionDaySummary.Category(
            id: "exercise",
            title: String(repeating: "운동", count: 10),
            minutes: 1_439,
            durationText: "23시간 59분",
            hex: "#FFFFFF"
        )
        let daySummary = SensorCollectionDaySummary(
            categories: Array(repeating: category, count: 4),
            steps: 999_999,
            meters: 9_999_999,
            distanceText: "9999.9 km"
        )
        var worst = state(daySummary)
        worst.collectionKinds = ["location", "motion", "altitude", "steps", "health", "wifi"]
        worst.currentActivityTitle = String(repeating: "활동", count: 20)
        worst.currentActivityCategoryID = "movement.running"
        worst.currentActivitySystemImage = "figure.strengthtraining.traditional"
        worst.salaryText = "1,234,567원"
        let data = try JSONEncoder().encode(worst)
        XCTAssertLessThan(data.count, 4_096)
        XCTAssertEqual(try JSONDecoder().decode(State.self, from: data).daySummary, daySummary)
    }

    func testPublishesOnlyWhenStateChanged() {
        let base = summary(["work": 3_600], steps: 10)
        XCTAssertFalse(SensorCollectionActivityPolicy.shouldPublishUpdate(previous: state(base), next: state(base)))
        let changed = summary(["work": 3_660], steps: 10)
        XCTAssertTrue(SensorCollectionActivityPolicy.shouldPublishUpdate(previous: state(base), next: state(changed)))
    }

    @MainActor
    func testCacheHoldsForOneMinutePerDayAndLanguage() {
        let cache = LiveActivityDaySummaryCache()
        let day = Date(timeIntervalSinceReferenceDate: 0)
        let now = Date(timeIntervalSinceReferenceDate: 3_600)
        let value = summary(["work": 3_600])
        XCTAssertNil(cache.reusable(day: day, language: .korean, now: now))
        cache.store(value, day: day, language: .korean, now: now)
        XCTAssertEqual(cache.reusable(day: day, language: .korean, now: now.addingTimeInterval(59)), value)
        XCTAssertNil(cache.reusable(day: day, language: .korean, now: now.addingTimeInterval(60)))
        XCTAssertNil(cache.reusable(day: day, language: .english, now: now))
        XCTAssertNil(cache.reusable(day: day.addingTimeInterval(86_400), language: .korean, now: now))
    }

    func testSummaryShowsLifeCategoriesOnly() {
        let value = summary(["sleep": 28_800, "movement": 7_200, "activity": 9_000, "work": 3_600, "eating": 1_800])
        XCTAssertEqual(value.categories.map(\.id), ["work", "eating"])
    }

    func testExternalHeartOnlyForExternalSensor() {
        XCTAssertNil(SensorExternalHeartPolicy.text(isExternalSample: false, heartRate: 70))
        XCTAssertNil(SensorExternalHeartPolicy.text(isExternalSample: nil, heartRate: 70))
        XCTAssertEqual(SensorExternalHeartPolicy.text(isExternalSample: true, heartRate: 70.4), "♥︎ 70")
        XCTAssertEqual(SensorExternalHeartPolicy.text(isExternalSample: true, heartRate: nil), "♥︎")
    }
}
