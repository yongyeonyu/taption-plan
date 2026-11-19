import XCTest
@testable import TaptionPlan
import TaptionPlanCore

/// 오분류 교정 표본 「서버로 보내기」(MSC1119B01). 가짜 서버·가짜 키만 쓴다.
@MainActor
final class MisclassificationUploaderTests: XCTestCase {
    private let host = "relay.example.com"
    private let master = String(repeating: "M", count: 21) + String(repeating: "m", count: 22)

    private func defaults(name: String = "MisclassificationUploaderTests") -> UserDefaults {
        let suite = "\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func collector(enabled: Bool = true, count: Int) -> MisclassificationCollector {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MisclassificationUploaderTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let result = MisclassificationCollector(directory: url, defaults: defaults(name: "Collector"))
        result.setEnabled(true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 9, minute: 5))!
        for index in 0..<count {
            result.capture(
                kind: index % 4 == 0 ? .travel : .activity, span: TimeSpan(start: start, end: start.addingTimeInterval(1_200)), readings: [],
                predicted: "rest", predictedDetail: nil, predictedConfidence: "medium", predictedScore: 0.5,
                corrected: "work", correctedDetail: nil, correctedIsCustom: false, calendar: calendar
            )
        }
        result.setEnabled(enabled)
        return result
    }

    /// 등록을 마친 주 키가 든 환경. `/classifier-samples`의 응답 상태를 `status`로 고른다.
    private func environment(status: @escaping (URLRequest) -> Int = { _ in 201 }) -> AssistantRegistration.Environment {
        Phase3RelayStub.reset(status: status)
        Phase3RelayStub.body = #"{"ok":true,"accepted":1,"duplicates":0,"rejected":0}"#
        let store = defaults(name: "Env")
        store.set(AssistantRegistration.rotationTag, forKey: AssistantRegistration.rotationKey)
        store.set(AssistantKeyStore.keyID(master), forKey: AssistantRegistration.registeredKey)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Phase3RelayStub.self]
        return AssistantRegistration.Environment(
            secrets: AssistantMemorySecrets([.master: master]), defaults: store, session: URLSession(configuration: configuration),
            host: host, clearConnections: {}, client: { .live }
        )
    }

    private func uploads() -> [Phase3RelayStub.Seen] { Phase3RelayStub.requests.filter { $0.path == "/classifier-samples" } }

    private func sampleCount(_ seen: Phase3RelayStub.Seen) throws -> Int {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: seen.body) as? [String: Any])
        XCTAssertEqual(object["format"] as? String, "bokki-misclassification")
        return try XCTUnwrap(object["samples"] as? [Any]).count
    }

    func testSendsInBatchesOf200WithMasterKeyAndClearsSentSamples() async throws {
        let c = collector(count: 450)
        let result = await MisclassificationUploader.send(collector: c, env: environment())
        XCTAssertNil(result.failure)
        XCTAssertEqual(try uploads().map(sampleCount), [200, 200, 50])
        XCTAssertTrue(uploads().allSatisfy { $0.method == "POST" && $0.token == master })
        XCTAssertEqual(result.removed, 450)
        XCTAssertEqual(c.summary().total, 0, "보낸 표본은 기기에서 비운다")
    }

    func testOffSendsNothingAndKeepsSamples() async {
        let c = collector(enabled: false, count: 3)
        let result = await MisclassificationUploader.send(collector: c, env: environment())
        XCTAssertEqual(result.failure, .disabled)
        XCTAssertTrue(Phase3RelayStub.requests.isEmpty)
        XCTAssertEqual(c.samples().count, 3)
    }

    func testDailyLimitKeepsUnsentBatchesAndRemovesSentOnes() async {
        let c = collector(count: 450)
        var calls = 0
        let env = environment { _ in calls += 1; return calls == 2 ? 429 : 201 }
        let result = await MisclassificationUploader.send(collector: c, env: env)
        XCTAssertEqual(result.failure, .dailyLimit)
        XCTAssertEqual(uploads().count, 2, "한도에 걸리면 더 보내지 않는다")
        XCTAssertEqual(result.removed, 200)
        XCTAssertEqual(c.samples().count, 250)
    }

    func testServerErrorKeepsEverything() async {
        let c = collector(count: 5)
        let result = await MisclassificationUploader.send(collector: c, env: environment { _ in 500 })
        XCTAssertEqual(result.failure, .server(500))
        XCTAssertEqual(result.removed, 0)
        XCTAssertEqual(c.samples().count, 5)
    }

    func testNoHostMeansNotReadyAndKeepsSamples() async {
        let c = collector(count: 2)
        var env = environment()
        env.host = nil
        let result = await MisclassificationUploader.send(collector: c, env: env)
        XCTAssertEqual(result.failure, .notReady)
        XCTAssertEqual(c.samples().count, 2)
    }

    func testEmptyDeviceSendsNothing() async {
        let result = await MisclassificationUploader.send(collector: collector(count: 0), env: environment())
        XCTAssertEqual(result, MisclassificationUploader.Result())
        XCTAssertTrue(uploads().isEmpty)
    }

    func testPreviewShowsCountsAndTheExactWireShapeWithoutDates() throws {
        let samples = collector(count: 8).samples()
        let preview = MisclassificationUploader.preview(samples, ruleVersion: "classifier-test")
        XCTAssertEqual(preview.total, 8)
        XCTAssertEqual(preview.activity + preview.travel, 8)
        XCTAssertEqual(preview.travel, 2)
        XCTAssertEqual(preview.lines.count, 5)
        XCTAssertEqual(preview.lines.first, "09:05 · 20m · rest → work")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(preview.example.utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(MisclassificationFeatureSchema.sampleKeys))
        for forbidden in ["2026", "latitude", "longitude"] { XCTAssertFalse(preview.example.contains(forbidden), forbidden) }
        XCTAssertEqual(MisclassificationUploader.preview([], ruleVersion: "x").example, "")
    }

    func testRemoveByIDKeepsOthersInOrder() {
        let c = collector(count: 4)
        let all = c.samples()
        XCTAssertEqual(c.remove(ids: [all[1].id, all[2].id, UUID()]), 2)
        XCTAssertEqual(c.samples().map(\.id), [all[0].id, all[3].id])
        XCTAssertEqual(c.remove(ids: []), 0)
    }
}
