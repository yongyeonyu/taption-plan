import Compression
import XCTest
@testable import TaptionPlan
import TaptionPlanEngine
import TaptionPlanStore

/// FLT1119A01: 공유 확장 보관함·탑승권 읽기·앱 수신. 샘플은 전부 가짜다.
final class FlightShareTests: XCTestCase {
    private var container: URL!

    override func setUpWithError() throws {
        container = FileManager.default.temporaryDirectory.appendingPathComponent("FlightShareTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        UserDefaults.standard.removeObject(forKey: FlightInbox.key)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: container)
        UserDefaults.standard.removeObject(forKey: FlightInbox.key)
    }

    private let now = Date(timeIntervalSince1970: 1_803_600_000) // 2027-03-01
    private let booking = "[가상항공] HONG/GILDONG 님, 예약번호 ABC123. 03월 07일 09:05 인천 출발, 방콕 도착 예정입니다."

    // MARK: 보관함

    func testStoreQueuesTextAndPassAndClearsThemAfterProcessing() throws {
        XCTAssertTrue(FlightShareStore.enqueue(text: "  \(booking)  ", now: now, container: container))
        XCTAssertTrue(FlightShareStore.enqueue(passData: Data("zip".utf8), now: now.addingTimeInterval(1), container: container))
        let entries = FlightShareStore.pending(now: now.addingTimeInterval(2), container: container)
        XCTAssertEqual(entries.map(\.kind), [.text, .pass])
        XCTAssertEqual(entries[0].text, booking, "앞뒤 공백은 뗀다")
        XCTAssertEqual(FlightShareStore.passData(for: entries[1], container: container), Data("zip".utf8))
        FlightShareStore.remove(entries.map(\.id), now: now.addingTimeInterval(3), container: container)
        XCTAssertTrue(FlightShareStore.pending(now: now.addingTimeInterval(3), container: container).isEmpty)
        let folder = try XCTUnwrap(FlightShareStore.directory(container: container))
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".pkpass") }
        XCTAssertTrue(files.isEmpty, "처리한 탑승권 파일도 지운다")
    }

    func testStoreRejectsEmptyOversizedAndDedupesAndCapsAndExpires() throws {
        XCTAssertFalse(FlightShareStore.enqueue(text: "   ", container: container))
        XCTAssertFalse(FlightShareStore.enqueue(text: String(repeating: "가", count: FlightShareStore.maximumTextBytes), container: container), "바이트 한도")
        XCTAssertFalse(FlightShareStore.enqueue(passData: Data(), container: container))
        XCTAssertFalse(FlightShareStore.enqueue(passData: Data(count: FlightShareStore.maximumPassBytes + 1), container: container))
        XCTAssertTrue(FlightShareStore.enqueue(text: "same", now: now, container: container))
        XCTAssertTrue(FlightShareStore.enqueue(text: "same", now: now.addingTimeInterval(5), container: container))
        XCTAssertEqual(FlightShareStore.pending(now: now.addingTimeInterval(6), container: container).count, 1, "같은 글은 한 번만")
        for index in 0..<30 { XCTAssertTrue(FlightShareStore.enqueue(text: "t\(index)", now: now.addingTimeInterval(Double(10 + index)), container: container)) }
        XCTAssertEqual(FlightShareStore.pending(now: now.addingTimeInterval(100), container: container).count, FlightShareStore.maximumEntries)
        XCTAssertTrue(FlightShareStore.pending(now: now.addingTimeInterval(FlightShareStore.lifetime + 1_000), container: container).isEmpty, "30일이 지나면 버린다")
    }

    func testStoreIsSafeWithoutContainerAndWithPathTraversalNames() throws {
        let entry = FlightShareStore.Entry(id: "x", kind: .pass, text: nil, file: "../escape.pkpass", at: now)
        XCTAssertNil(FlightShareStore.passData(for: entry, container: container), "폴더 밖 이름은 읽지 않는다")
        FlightShareStore.remove(["x"], container: container)
    }

    // MARK: 탑승권

    private func zip(_ files: [(String, Data, Bool)]) -> Data {
        var out = Data(), central = Data()
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
        for (name, content, deflate) in files {
            var body = content
            if deflate {
                var buffer = [UInt8](repeating: 0, count: content.count + 512)
                let size = content.withUnsafeBytes { compression_encode_buffer(&buffer, buffer.count, $0.bindMemory(to: UInt8.self).baseAddress!, content.count, nil, COMPRESSION_ZLIB) }
                body = Data(buffer[0..<size])
            }
            let method = deflate ? 8 : 0, offset = out.count, nameBytes = Array(name.utf8)
            out += Data([0x50, 0x4B, 0x03, 0x04] + le16(20) + le16(0) + le16(method) + le16(0) + le16(0) + le32(0) + le32(body.count) + le32(content.count) + le16(nameBytes.count) + le16(0) + nameBytes)
            out += body
            central += Data([0x50, 0x4B, 0x01, 0x02] + le16(20) + le16(20) + le16(0) + le16(method) + le16(0) + le16(0) + le32(0) + le32(body.count) + le32(content.count)
                            + le16(nameBytes.count) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset) + nameBytes)
        }
        let directoryOffset = out.count
        out += central
        out += Data([0x50, 0x4B, 0x05, 0x06] + le16(0) + le16(0) + le16(files.count) + le16(files.count) + le32(central.count) + le32(directoryOffset) + le16(0))
        return out
    }

    private func passJSON(flight: String = "AB 123", origin: String = "ICN", destination: String = "BKK", relevant: String = "2027-03-07T09:05:00+09:00") -> Data {
        Data("""
        {"formatVersion":1,"relevantDate":"\(relevant)","boardingPass":{"transitType":"PKTransitTypeAir",
         "headerFields":[{"key":"flight","label":"FLIGHT","value":"\(flight)"}],
         "primaryFields":[{"key":"origin","label":"FROM","value":"\(origin)"},{"key":"destination","label":"TO","value":"\(destination)"}],
         "secondaryFields":[{"key":"passenger","label":"PASSENGER","value":"HONG/GILDONG"}],
         "auxiliaryFields":[{"key":"gate","label":"GATE","value":"252"}]}}
        """.utf8)
    }

    func testPassReaderReadsStoredAndDeflatedPassJSONIntoParserText() throws {
        for deflate in [false, true] {
            let archive = zip([("icon.png", Data(count: 20), false), ("pass.json", passJSON(), deflate)])
            XCTAssertEqual(FlightPassReader.text(from: archive), "03/07 AB123 ICN -> BKK 09:05", "deflate=\(deflate)")
        }
        let text = try XCTUnwrap(FlightPassReader.text(from: zip([("pass.json", passJSON(), true)])))
        XCTAssertFalse(text.contains("GILDONG"), "이름은 옮기지 않는다")
        XCTAssertFalse(text.contains("252"))
        // 알림 파서가 그대로 읽는다.
        guard case .alert(let alert) = FlightAlertParser.parse(text, receivedAt: now) else { return XCTFail("파서가 읽어야 한다") }
        XCTAssertEqual(alert.segments.first?.flight, "AB123")
    }

    func testPassReaderRejectsBrokenOrIncompleteArchives() {
        XCTAssertNil(FlightPassReader.text(from: Data()))
        XCTAssertNil(FlightPassReader.text(from: Data("not a zip".utf8)))
        XCTAssertNil(FlightPassReader.text(from: zip([("other.json", passJSON(), false)])), "pass.json이 없다")
        XCTAssertNil(FlightPassReader.text(from: zip([("pass.json", Data("{}".utf8), false)])))
        XCTAssertNil(FlightPassReader.text(from: zip([("pass.json", passJSON(flight: "??"), false)])))
        XCTAssertNil(FlightPassReader.text(from: zip([("pass.json", passJSON(origin: "Incheon Intl"), false)])), "3글자 공항 코드가 아니면 읽지 않는다")
        XCTAssertNil(FlightPassReader.text(from: zip([("pass.json", passJSON(relevant: "tomorrow"), false)])))
        var truncated = zip([("pass.json", passJSON(), false)])
        truncated.removeLast(10)
        XCTAssertNil(FlightPassReader.text(from: truncated))
        XCTAssertNil(FlightPassReader.text(from: Data(count: FlightPassReader.maximumArchiveBytes + 1)))
        XCTAssertEqual(FlightPassReader.airport("icn Incheon"), "ICN")
        XCTAssertNil(FlightPassReader.airport("서울"))
    }

    // MARK: 앱 수신

    @MainActor
    func testIntakeAppliesSharedTextAndPassThenClearsTheStore() async throws {
        let model = AppModel(repository: InMemoryPlanRepository(), cloudSyncService: nil)
        await model.bootstrapLocalSnapshot()
        let saved = await model.saveTravelTrip(TravelTrip(id: "t1", title: "방콕", startDay: "2027-03-07", endDay: "2027-03-11"))
        XCTAssertTrue(saved)
        XCTAssertTrue(FlightShareStore.enqueue(text: booking, now: now, container: container))
        XCTAssertTrue(FlightShareStore.enqueue(passData: zip([("pass.json", passJSON(flight: "AB 124", origin: "BKK", destination: "ICN", relevant: "2027-03-11T01:00:00+07:00"), true)]), now: now.addingTimeInterval(60), container: container))
        await FlightShareIntake.drain(into: model, now: now.addingTimeInterval(120), container: container)
        let flights = (model.settings.travelTripItems ?? []).filter(\.isFlight)
        XCTAssertEqual(flights.count, 2, "출국 안내문과 귀국 탑승권이 각각 카드가 된다")
        XCTAssertTrue(FlightShareStore.pending(now: now.addingTimeInterval(121), container: container).isEmpty)
        XCTAssertNotNil(FlightAlertCenter.shared.message)
    }

    @MainActor
    func testIntakeDropsUnreadableItemsAndTellsTheUser() async throws {
        let model = AppModel(repository: InMemoryPlanRepository(), cloudSyncService: nil)
        await model.bootstrapLocalSnapshot()
        FlightAlertCenter.shared.clearMessage()
        // 읽을 수 없는 탑승권 파일만 있으면 「못 읽음」이고 보관함은 비운다.
        XCTAssertTrue(FlightShareStore.enqueue(passData: Data("garbage".utf8), now: now, container: container))
        await FlightShareIntake.drain(into: model, now: now.addingTimeInterval(5), container: container)
        XCTAssertTrue(FlightShareStore.pending(now: now.addingTimeInterval(6), container: container).isEmpty, "못 읽은 것도 지운다")
        XCTAssertEqual(FlightAlertCenter.shared.message, FlightIngest.message(for: .unreadable))
        XCTAssertTrue((model.settings.travelTripItems ?? []).isEmpty)
        // 날짜·시각이 없는 일반 글은 AI 연결이 없으면 메모로 남긴다(글이 사라지지 않는다).
        FlightAlertCenter.shared.clearMessage()
        XCTAssertTrue(FlightShareStore.enqueue(text: "안녕하세요 점심 뭐 드실래요", now: now, container: container))
        await FlightShareIntake.drain(into: model, now: now.addingTimeInterval(10), container: container)
        XCTAssertEqual(FlightAlertCenter.shared.message, FlightIngest.message(for: .savedAsMemo))
    }

    // MARK: 항공편이 아닌 공유 글

    @MainActor
    private func tripModel() async throws -> AppModel {
        let model = AppModel(repository: InMemoryPlanRepository(), cloudSyncService: nil)
        await model.bootstrapLocalSnapshot()
        let saved = await model.saveTravelTrip(TravelTrip(id: "t1", title: "방콕", startDay: "2027-03-07", endDay: "2027-03-11"))
        XCTAssertTrue(saved)
        return model
    }

    @MainActor
    func testSharedPlainScheduleTextBecomesADayPlanOnDevice() async throws {
        let model = try await tripModel()
        let before = model.snapshot.plans.count
        let reply = await model.routeSharedText("내일 오후 3시 치과 예약", now: now)
        XCTAssertEqual(reply, .planAdded)
        XCTAssertEqual(model.snapshot.plans.count, before + 1)
        let plan = try XCTUnwrap(model.snapshot.plans.last)
        XCTAssertTrue(plan.title.contains("치과"))
        XCTAssertTrue((model.settings.travelTripItems ?? []).isEmpty, "여행 기간 밖이라 하루 일정이다")
    }

    @MainActor
    func testSharedTextInsideATripBecomesATripItemWithoutSendingAnythingOut() async throws {
        let model = try await tripModel()
        let reply = await model.routeSharedText("3월 8일 오후 2시 박물관 관람", now: now)
        XCTAssertEqual(reply, .planAdded)
        let item = try XCTUnwrap((model.settings.travelTripItems ?? []).first)
        XCTAssertEqual(item.tripID, "t1")
        XCTAssertTrue(item.title.contains("박물관"))
        XCTAssertNotNil(item.note, "원문은 메모로 남는다")
    }

    @MainActor
    func testTextWithoutDateAndTimeFallsBackToAMemoWhenNoAIIsConnected() async throws {
        let model = try await tripModel()
        let reply = await model.routeSharedText("다음에 같이 점심 먹자", now: now)
        XCTAssertEqual(reply, .savedAsMemo, "연결된 AI가 없으면 보내지 않고 메모로 남긴다")
    }

    @MainActor
    func testIntakeRoutesNonFlightSharedTextAndKeepsFlightAlertsOnTheFlightPath() async throws {
        let model = try await tripModel()
        XCTAssertTrue(FlightShareStore.enqueue(text: "내일 오후 3시 치과 예약", now: now, container: container))
        await FlightShareIntake.drain(into: model, now: now.addingTimeInterval(5), container: container)
        XCTAssertEqual(FlightAlertCenter.shared.message, FlightIngest.message(for: .planAdded))
        XCTAssertTrue(FlightShareStore.pending(now: now.addingTimeInterval(6), container: container).isEmpty)
        XCTAssertTrue(FlightShareStore.enqueue(text: booking, now: now, container: container))
        await FlightShareIntake.drain(into: model, now: now.addingTimeInterval(10), container: container)
        XCTAssertEqual((model.settings.travelTripItems ?? []).filter(\.isFlight).count, 1)
    }

    @MainActor
    func testShortcutRunnerQueuesWhenTheAppIsNotReady() async {
        AppModel.live = nil
        let reply = await SharedTextIntentRunner.run("내일 오후 3시 치과 예약", now: now, container: container)
        XCTAssertFalse(reply.isEmpty)
        XCTAssertEqual(FlightShareStore.pending(now: now.addingTimeInterval(1), container: container).count, 1)
    }

    @MainActor
    func testBetterPrefersConfirmationThenAttachedThenHold() {
        let confirm = FlightIngest.Reply.needsConfirmation(.init(text: "x", candidates: [], allowsNew: false))
        XCTAssertEqual(FlightShareIntake.better(.unreadable, .noTrip), .noTrip)
        XCTAssertEqual(FlightShareIntake.better(.noTrip, .attached(created: 1, merged: 0)), .attached(created: 1, merged: 0))
        XCTAssertEqual(FlightShareIntake.better(.attached(created: 1, merged: 0), confirm), confirm)
        XCTAssertEqual(FlightShareIntake.better(confirm, .unreadable), confirm)
        XCTAssertEqual(FlightShareIntake.better(nil, .deferred), .deferred)
    }
}
