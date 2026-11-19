import XCTest
@testable import TaptionPlan
import TaptionPlanCore
import TaptionPlanStore

/// 오분류 교정 표본(MSC1119A01). 가짜 좌표·가짜 이름만 쓴다.
final class MisclassificationCollectorTests: XCTestCase {
    private func calendar(_ zone: String = "Asia/Seoul") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func date(_ hour: Int, _ minute: Int = 0, day: Int = 18, zone: String = "Asia/Seoul") -> Date {
        calendar(zone).date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MisclassificationTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func defaults() -> UserDefaults {
        let name = "MisclassificationCollectorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    private func collector(enabled: Bool = true, maximum: Int = 5_000, directory: URL? = nil) -> MisclassificationCollector {
        let result = MisclassificationCollector(directory: directory ?? self.directory(), defaults: defaults(), maximumSamples: maximum)
        result.setEnabled(enabled)
        return result
    }

    /// 가짜 좌표·가짜 와이파이 이름이 든 원본.
    private func readings(from start: Date, count: Int = 6, watch: Bool = false, motion: MotionKind = .walking) -> [SensorReading] {
        (0..<count).map { index in
            var reading = SensorReading(
                timestamp: start.addingTimeInterval(Double(index) * 60),
                point: GeoPoint(latitude: 37.5123 + Double(index) * 0.0001, longitude: 127.0456, altitude: 0, horizontalAccuracy: 12, verticalAccuracy: 5),
                speedMetersPerSecond: 1.4,
                motion: motion,
                stepCount: 100 * (index + 1),
                walkingRunningDistanceMeters: 70.0 * Double(index),
                currentCadenceStepsPerSecond: 1.8,
                connectedWiFiSSID: "가짜카페와이파이"
            )
            if watch { reading.sourceDevice = .appleWatch }
            return reading
        }
    }

    @discardableResult
    private func capture(_ collector: MisclassificationCollector, predicted: String = "rest", corrected: String = "work", detail: String? = nil,
                         custom: Bool = false, readings: [SensorReading]? = nil, hour: Int = 14, minutes: Int = 20, kind: MisclassificationSample.Kind = .activity) -> MisclassificationSample? {
        let span = TimeSpan(start: date(hour, 30), end: date(hour, 30).addingTimeInterval(Double(minutes) * 60))
        return collector.capture(
            kind: kind, span: span, readings: readings ?? self.readings(from: span.start),
            predicted: predicted, predictedDetail: "가짜-상세", predictedConfidence: "medium", predictedScore: 0.523,
            corrected: corrected, correctedDetail: detail, correctedIsCustom: custom, calendar: calendar()
        )
    }

    // 1. 기본값 OFF
    func testDefaultOffWritesNothing() {
        let dir = directory()
        let off = MisclassificationCollector(directory: dir, defaults: defaults())
        XCTAssertFalse(off.isEnabled)
        XCTAssertNil(capture(off))
        XCTAssertEqual(off.summary().total, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "꺼져 있으면 폴더도 만들지 않는다")
    }

    // 2. 켜면 한 건
    func testEnabledCapturesOneSample() throws {
        let c = collector()
        let sample = try XCTUnwrap(capture(c))
        XCTAssertEqual(c.summary().total, 1)
        let stored = try XCTUnwrap(c.samples().first)
        XCTAssertEqual(stored, sample)
        XCTAssertEqual(stored.kind, .activity)
        XCTAssertEqual([stored.predicted, stored.corrected], ["rest", "work"])
        XCTAssertEqual(stored.minuteOfDay, 14 * 60 + 30)
        XCTAssertEqual(stored.durationSeconds, 20 * 60)
        XCTAssertEqual(stored.weekdayIndex, 3, "2026-11-18은 수요일")
        XCTAssertEqual(stored.predictedScore, 0.5, "0.05 단위")
        XCTAssertEqual(stored.schemaVersion, 1)
        XCTAssertEqual(stored.ruleVersion, ClassificationRules.version)
    }

    // 3. 개인정보·좌표 미포함
    func testEncodedSampleHasNoPersonalValuesAndExactKeys() throws {
        let c = collector()
        let sample = try XCTUnwrap(capture(c, readings: readings(from: date(14, 30))))
        let data = try JSONEncoder().encode(sample)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        for forbidden in ["37.51", "127.04", "가짜카페와이파이", "가짜-상세", "2026", "11-18", "evidence", "title"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(MisclassificationFeatureSchema.sampleKeys), "모르는 열쇠가 늘면 실패")
        let features = try XCTUnwrap(object["features"] as? [String: Any])
        XCTAssertEqual(Set(features.keys), Set(MisclassificationFeatureSchema.featureNames))
        XCTAssertNil(sample.predictedDetail, "분류표에 없는 상세 코드는 떨어진다")
        let behavior = try XCTUnwrap(MisclassificationCollector.catalogBehaviors.first)
        XCTAssertEqual(try XCTUnwrap(capture(c, detail: behavior)).correctedDetail, behavior)
    }

    // 4. 사용자 지정 분류
    func testCustomCorrectionStoresNoName() throws {
        let c = collector()
        let sample = try XCTUnwrap(capture(c, corrected: "나만의 취미", detail: "hobby", custom: true))
        XCTAssertEqual(sample.corrected, "custom")
        XCTAssertTrue(sample.correctedIsCustom)
        XCTAssertNil(sample.correctedDetail)
        let text = String(decoding: try JSONEncoder().encode(sample), as: UTF8.self)
        XCTAssertFalse(text.contains("나만의 취미"))
    }

    // 5. 특징값 없음
    func testNoReadingsLeavesFeaturesEmpty() throws {
        let c = collector()
        let sample = try XCTUnwrap(capture(c, readings: []))
        XCTAssertEqual(sample.features, MisclassificationFeatures.none)
        XCTAssertEqual(sample.features.sampleCount, 0)
        XCTAssertNil(sample.features.averageSpeedKmh); XCTAssertNil(sample.features.steps); XCTAssertNil(sample.features.distanceMeters)
        XCTAssertNil(sample.features.dominantMotion); XCTAssertFalse(sample.features.watchCovered)
    }

    func testFeaturesAreRoundedAndDerivedFromReadings() throws {
        let c = collector()
        let sample = try XCTUnwrap(capture(c, readings: readings(from: date(14, 30), watch: true)))
        let f = sample.features
        XCTAssertEqual(f.averageSpeedKmh, 5.0, "1.4 m/s = 5.04 km/h를 0.5 단위로")
        XCTAssertEqual(f.stepCadencePerMinute, 108)
        XCTAssertEqual(f.gpsAccuracyMeters, 10, "12m를 5m 단위로")
        XCTAssertEqual(f.dominantMotion, "walking")
        XCTAssertTrue(f.watchCovered)
        XCTAssertEqual(f.sampleCount, 6)
        XCTAssertEqual(f.distanceMeters, 350, "누적 70m 증가분 합")
        XCTAssertNotNil(f.steps)
        let tie = MisclassificationSample.features(readings: readings(from: date(14, 30), count: 2, motion: .automotive) + readings(from: date(14, 40), count: 2, motion: .stationary),
                                                   span: TimeSpan(start: date(14, 30), end: date(14, 50)), travelDistanceMeters: 1_234)
        XCTAssertEqual(tie.dominantMotion, "stationary", "동수면 더 조용한 쪽")
        XCTAssertEqual(tie.distanceMeters, 1_230, "이동 구간 거리는 10m 단위")
    }

    // 6. 직렬화·파싱, 깨진 줄
    func testAppendReadBackAndBrokenLineIsSkipped() throws {
        let dir = directory()
        let c = collector(directory: dir)
        let made = (0..<3).compactMap { capture(c, corrected: "work\($0)") }
        XCTAssertEqual(c.samples(), made)
        let file = dir.appendingPathComponent("samples.jsonl")
        var lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
        lines.insert("{깨진 줄", at: 1)
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(c.samples(), made, "깨진 줄만 건너뛰고 나머지 3건을 읽는다")
        XCTAssertEqual(c.summary().total, 3)
    }

    // 7. 상한
    func testMaximumDropsTheOldest() throws {
        let c = collector(maximum: 4)
        let first = try XCTUnwrap(capture(c, corrected: "first"))
        for index in 0..<4 { capture(c, corrected: "next\(index)") }
        let all = c.samples()
        XCTAssertEqual(all.count, 4)
        XCTAssertFalse(all.contains { $0.id == first.id })
        XCTAssertEqual(all.map(\.corrected), ["next0", "next1", "next2", "next3"])
        XCTAssertEqual(c.samples(limit: 2).map(\.corrected), ["next2", "next3"])
    }

    // 8. 초기화
    func testRemoveAllDeletesTheFileAndRecreates() throws {
        let dir = directory()
        let c = collector(directory: dir)
        capture(c)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("samples.jsonl").path))
        c.removeAll()
        XCTAssertEqual(c.summary().total, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("samples.jsonl").path))
        XCTAssertNotNil(capture(c))
        XCTAssertEqual(c.summary().total, 1)
    }

    // 9. 요약
    func testSummaryCountsKindsAndTopFive() {
        let c = collector()
        for (code, count) in [("a", 5), ("b", 4), ("c", 3), ("d", 2), ("e", 1), ("f", 1), ("g", 1)] {
            for _ in 0..<count { capture(c, corrected: code) }
        }
        capture(c, corrected: "walking", kind: .travel)
        let summary = c.summary()
        XCTAssertEqual(summary.total, 18)
        XCTAssertEqual(summary.activity, 17); XCTAssertEqual(summary.travel, 1)
        XCTAssertEqual(summary.topCorrected.count, 5)
        XCTAssertEqual(summary.topCorrected.map(\.code), ["a", "b", "c", "d", "e"])
        XCTAssertEqual(summary.topCorrected.map(\.count), [5, 4, 3, 2, 1])
    }

    // 10. 내보내기
    func testExportPayloadMatchesTheDocumentedShapeWithoutDates() throws {
        let c = collector()
        capture(c); capture(c, corrected: "study")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: c.exportPayload()) as? [String: Any])
        XCTAssertEqual(object["format"] as? String, "bokki-misclassification")
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["ruleVersion"] as? String, ClassificationRules.version)
        XCTAssertEqual((object["samples"] as? [Any])?.count, c.summary().total)
        XCTAssertEqual(Set(object.keys), ["format", "version", "ruleVersion", "samples"])
        let text = String(decoding: c.exportPayload(), as: UTF8.self)
        XCTAssertNil(text.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression), "연월일 문자열이 없다")
    }

    // 11. 시각 경계
    func testMidnightAndTimeZoneBoundaries() throws {
        let c = collector()
        let overnight = TimeSpan(start: date(23, 50), end: date(23, 50).addingTimeInterval(40 * 60))
        let sample = try XCTUnwrap(c.capture(kind: .activity, span: overnight, readings: [], predicted: "rest", predictedDetail: nil, predictedConfidence: nil, predictedScore: nil,
                                             corrected: "sleep", correctedDetail: nil, correctedIsCustom: false, calendar: calendar()))
        XCTAssertEqual(sample.minuteOfDay, 23 * 60 + 50, "자정 기준 분")
        XCTAssertEqual(sample.durationSeconds, 40 * 60, "구간 길이는 잘리지 않는다")
        let newYork = TimeSpan(start: date(0, 5, zone: "America/New_York"), end: date(1, 0, zone: "America/New_York"))
        let other = try XCTUnwrap(c.capture(kind: .activity, span: newYork, readings: [], predicted: "rest", predictedDetail: nil, predictedConfidence: nil, predictedScore: nil,
                                            corrected: "sleep", correctedDetail: nil, correctedIsCustom: false, calendar: calendar("America/New_York")))
        XCTAssertEqual(other.minuteOfDay, 5)
        XCTAssertTrue((0...1_439).contains(other.minuteOfDay) && (0...6).contains(other.weekdayIndex))
    }

    // 12. 바뀌지 않은 교정
    func testUnchangedCorrectionIsNotASample() {
        XCTAssertFalse(MisclassificationSample.isChange(predicted: "work", predictedDetail: "work.meeting", corrected: "work", correctedDetail: "work.meeting"))
        XCTAssertFalse(MisclassificationSample.isChange(predicted: "walking", predictedDetail: nil, corrected: "walking", correctedDetail: nil))
        XCTAssertTrue(MisclassificationSample.isChange(predicted: "work", predictedDetail: nil, corrected: "rest", correctedDetail: nil))
        XCTAssertTrue(MisclassificationSample.isChange(predicted: "work", predictedDetail: "work.meeting", corrected: "work", correctedDetail: nil), "상세만 바뀌어도 바뀐 것")
    }

    // 여행 표본
    func testTravelSampleUsesSegmentDistanceAndModeRaw() throws {
        let c = collector()
        let span = TimeSpan(start: date(9), end: date(9, 30))
        let sample = try XCTUnwrap(c.capture(kind: .travel, span: span, readings: readings(from: span.start), predicted: TravelMode.bus.rawValue, predictedDetail: nil, predictedConfidence: "low",
                                             predictedScore: nil, corrected: TravelMode.subway.rawValue, correctedDetail: nil, correctedIsCustom: false, travelDistanceMeters: 8_432, calendar: calendar()))
        XCTAssertEqual([sample.predicted, sample.corrected], ["bus", "subway"])
        XCTAssertEqual(sample.features.distanceMeters, 8_430)
        XCTAssertEqual(sample.kind, .travel)
    }
}
