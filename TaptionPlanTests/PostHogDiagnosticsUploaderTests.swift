import TaptionPlanCore
import XCTest
@testable import TaptionPlan

/// PHG1120A01: PostHog 진단 업로드. 네트워크는 타지 않고 전송은 가짜로 갈아끼운다. 좌표는 가짜 값만 쓴다.
final class PostHogDiagnosticsUploaderTests: XCTestCase {
    private let config = PostHogConfig(host: "example.test", apiKey: "test-key")
    private let day = Date(timeIntervalSinceReferenceDate: 700_000_000)

    private func readings(_ count: Int) -> [SensorReading] {
        (0..<count).map { index in
            SensorReading(
                timestamp: day.addingTimeInterval(Double(index)),
                point: GeoPoint(latitude: 12.3456 + Double(index) * 1e-6, longitude: 65.4321, altitude: 1, horizontalAccuracy: 5, verticalAccuracy: 5),
                motion: .walking, motionConfidence: .high)
        }
    }

    private func exports(_ count: Int) -> [TodaySensorRawExport] {
        [TodaySensorRawExport(day: day, isComplete: true, readings: readings(count), travel: [], places: [], actuals: [])]
    }

    private func object(_ event: PostHogEvent) throws -> [String: Any] {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: event.body) as? [String: Any])
        let batch = try XCTUnwrap(root["batch"] as? [[String: Any]])
        return try XCTUnwrap(batch.first?["properties"] as? [String: Any])
    }

    func testLogEventsCarryNoCoordinatesOrRawSensors() throws {
        let summary = ["app_version": "1", "travel_mode_counts": "subway:2", "subway_lines": "2호선"]
        let events = PostHogEvents.logEvents(summary: summary, logText: "{\"event\":\"a\"}\n{\"event\":\"b\"}", session: "s1", config: config, distinctID: "anon", now: day)
        XCTAssertEqual(events.count, 1)
        let text = String(decoding: events[0].body, as: UTF8.self)
        for banned in ["latitude", "longitude", "SensorReading", "\"lat\"", "\"lon\""] { XCTAssertFalse(text.contains(banned), banned) }
        let props = try object(events[0])
        XCTAssertEqual(props["travel_mode_counts"] as? String, "subway:2")
        XCTAssertEqual(props["subway_lines"] as? String, "2호선")
        XCTAssertEqual(props["app"] as? String, "bokki-plan")
        XCTAssertEqual(props["source"] as? String, "diagnostics")
        XCTAssertEqual(props["$process_person_profile"] as? Bool, false)
        XCTAssertEqual(props["$insert_id"] as? String, "s1-log-0")
        XCTAssertEqual(props["distinct_id"] as? String, "anon")
    }

    func testRawBatchesStayUnderLimitsAndKeepCoordinates() throws {
        let raw = PostHogEvents.rawEvents(exports(1_200), session: "s2", config: config, distinctID: "anon", now: day)
        XCTAssertEqual(raw.samples, 1_200)
        let batches = raw.events.filter { $0.insertID.contains("-raw-") && !$0.insertID.contains("meta") }
        XCTAssertEqual(batches.count, raw.batches)
        XCTAssertEqual(batches.count, 3, "500 + 500 + 200")
        var sampleSum = 0
        for event in batches {
            XCTAssertLessThanOrEqual(event.body.count, 1_000_000)
            let props = try object(event)
            let samples = try XCTUnwrap(props["samples"] as? [[String: Any]])
            XCTAssertLessThanOrEqual(samples.count, PostHogEvents.rawBatchSamples)
            sampleSum += samples.count
            XCTAssertEqual(props["source"] as? String, "sensor_raw")
        }
        XCTAssertEqual(sampleSum, 1_200)
        let first = try XCTUnwrap(try object(batches[0])["samples"] as? [[String: Any]]).first
        let point = try XCTUnwrap(first?["point"] as? [String: Any])
        XCTAssertEqual(point["longitude"] as? Double, 65.4321)
        XCTAssertEqual(raw.events.filter { $0.name == "plan_diagnostics_raw_meta" }.count, 1)
    }

    func testRawKeepsOnlyTheLatest20000Samples() {
        let raw = PostHogEvents.rawEvents(exports(20_050), session: "s3", config: config, distinctID: "anon", now: day)
        XCTAssertTrue(raw.truncated)
        XCTAssertEqual(raw.samples, PostHogEvents.rawMaxSamples)
    }

    func testMissingOrUnresolvedKeyMeansNotConfigured() {
        XCTAssertNil(PostHogConfig.from(info: ["POSTHOG_API_KEY": ""]))
        XCTAssertNil(PostHogConfig.from(info: ["POSTHOG_API_KEY": "$(POSTHOG_API_KEY)"]))
        XCTAssertNil(PostHogConfig.from(info: nil))
        XCTAssertEqual(PostHogConfig.from(info: ["POSTHOG_API_KEY": "k", "POSTHOG_HOST": "h.test"]), PostHogConfig(host: "h.test", apiKey: "k"))
        XCTAssertEqual(PostHogConfig.from(info: ["POSTHOG_API_KEY": "k"])?.host, "us.i.posthog.com")
    }

    func testFailureKeepsTheReasonVerbatimAndRetrySkipsSentEvents() async {
        let events = PostHogEvents.rawEvents(exports(1_200), session: "s4", config: config, distinctID: "anon", now: day).events
        let sentLog = SentLog()
        let failAt = FailPoint("s4-raw-1")
        let uploader = PostHogDiagnosticsUploader { body, _ in
            let id = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]).flatMap { ($0["batch"] as? [[String: Any]])?.first?["properties"] as? [String: Any] }?["$insert_id"] as? String ?? ""
            if await id == failAt.id { return .http(500, "boom") }
            await sentLog.add(id)
            return .ok
        }
        var job = PostHogDiagnosticsUploader.Job(session: "s4", events: events)
        let first = await uploader.run(&job, config: config)
        XCTAssertEqual(first, .failure(.http(500, "boom"), sent: 2), "meta + 첫 배치까지 보냈다")
        XCTAssertTrue(PostHogUploadText.failure(.http(500, "boom")).contains("500"))
        XCTAssertTrue(PostHogUploadText.failure(.http(500, "boom")).contains("boom"))
        await failAt.clear()
        let before = await sentLog.ids.count
        let second = await uploader.run(&job, config: config)
        XCTAssertEqual(second, .success(sent: 2))
        let ids = await sentLog.ids
        XCTAssertEqual(Array(ids[before...]), ["s4-raw-1", "s4-raw-2"], "성공한 것은 건너뛴다")
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testFailureTextsDifferByResponseCode() {
        let limit = PostHogUploadText.failure(.http(429, ""))
        let billing = PostHogUploadText.failure(.http(402, ""))
        let other = PostHogUploadText.failure(.http(500, ""))
        XCTAssertEqual(Set([limit, billing, other]).count, 3)
        XCTAssertTrue(PostHogUploadText.isPermanent(.http(401, "")))
        XCTAssertFalse(PostHogUploadText.isPermanent(.http(500, "")))
        XCTAssertFalse(PostHogUploadText.isPermanent(.network("offline")))
    }

    func testLogChunksStayUnderLimitAndJoinBackToTheOriginal() {
        let line = String(repeating: "가", count: 300)
        let text = (0..<2_000).map { "\($0) \(line)" }.joined(separator: "\n")
        XCTAssertGreaterThan(text.utf8.count, 500_000)
        let chunks = PostHogEvents.chunks(of: text)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.utf8.count <= PostHogEvents.logChunkBytes })
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertEqual(PostHogEvents.sha256(chunks.joined()), PostHogEvents.sha256(text))
    }

    func testPackageTextIsReturnedAlongsideTheLocalCopy() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("posthog-pkg-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let builder = TaptionPlanDiagnosticsLogPackageBuilder(packageDirectoryURL: directory)
        let result = try builder.makePackageText(summary: ["k": "v"], iphoneLog: "{\"event\":\"x\"}", watchLog: nil)
        XCTAssertTrue(result.text.contains("k: v"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.fileURL.path), "전송 전에 로컬 사본이 있다")
    }
}

private actor FailPoint {
    private(set) var id: String?
    init(_ id: String?) { self.id = id }
    func clear() { id = nil }
}

private actor SentLog {
    private(set) var ids: [String] = []
    func add(_ id: String) { ids.append(id) }
}
