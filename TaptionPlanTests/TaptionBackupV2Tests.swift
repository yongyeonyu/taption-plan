import Foundation
import XCTest
import CryptoKit
@testable import TaptionPlan

final class TaptionBackupV2Tests: XCTestCase {
    private let password = "482915"
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    // MARK: 도우미

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("taption-backup-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url)
        return url
    }

    private struct Harness {
        let store: TaptionStoreV2
        let storeURL: URL
        let backupDirectory: URL
        let temporaryDirectory: URL
        let destination: TaptionLocalFolderBackupDestination
    }

    private func makeHarness() throws -> Harness {
        let root = try makeDirectory()
        let storeURL = root.appendingPathComponent("store.sqlite")
        let backups = root.appendingPathComponent("backups", isDirectory: true)
        let temporary = root.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        return Harness(
            store: try TaptionStoreV2(url: storeURL, calendar: calendar),
            storeURL: storeURL,
            backupDirectory: backups,
            temporaryDirectory: temporary,
            destination: TaptionLocalFolderBackupDestination(directory: backups)
        )
    }

    private func engine(
        _ harness: Harness,
        destination: (any TaptionBackupDestination)? = nil,
        iterations: Int = 1_000,
        codec: TaptionBackupCodec = .zlib,
        chunkBytes: Int = 4 << 20,
        beforeVerify: (@Sendable (URL) throws -> Void)? = nil
    ) -> TaptionBackupEngine {
        var configuration = TaptionBackupEngine.Configuration()
        configuration.iterations = iterations
        configuration.codec = codec
        configuration.chunkBytes = chunkBytes
        configuration.temporaryDirectory = harness.temporaryDirectory
        configuration.beforeVerify = beforeVerify
        return TaptionBackupEngine(
            store: harness.store, destination: destination ?? harness.destination,
            calendar: calendar, configuration: configuration
        )
    }

    private func reading(_ time: Date, _ index: Int, ssid: String? = nil) -> SensorReading {
        SensorReading(
            timestamp: time,
            point: GeoPoint(
                latitude: 37.5665 + Double(index) * 0.000_031_7,
                longitude: 126.9780 + sin(Double(index) / 37) * 0.000_413,
                altitude: 20.25 + Double(index % 7) * 0.1,
                horizontalAccuracy: 5 + Double(index % 3),
                verticalAccuracy: 3
            ),
            speedMetersPerSecond: 1.2 + Double(index % 5) * 0.01,
            courseDegrees: Double(index % 360),
            motion: .walking,
            motionConfidence: .high,
            relativeAltitudeMeters: Double(index % 11) * 0.03,
            pressureKilopascals: 101.2 + Double(index % 13) * 0.001,
            stepCount: index * 2,
            connectedWiFiSSID: ssid,
            behavior: index % 50 == 0 ? "walking" : nil,
            behaviorEvidence: index % 50 == 0 ? ["gps", "pedometer"] : nil,
            sequence: index
        )
    }

    private func readings(day: Date, count: Int, startIndex: Int = 0) -> [SensorReading] {
        (0..<count).map { reading(day.addingTimeInterval(Double($0) * 7), startIndex + $0) }
    }

    private func record(
        _ id: String, kind: String = "memo", start: Date?, ord: Int = 0, updated: Date = Date(timeIntervalSince1970: 1_790_000_000),
        deleted: Bool = false, body: String? = nil
    ) -> TaptionStoreRecord {
        TaptionStoreRecord(
            id: id, kind: kind, start: start, end: start?.addingTimeInterval(60), updatedAt: updated,
            origin: .user, isDeleted: deleted, ord: ord,
            body: body ?? "{\"title\":\"메모 \\\"인용\\\"\\n둘째 줄 \u{1F600}\",\"n\":\(ord)}"
        )
    }

    private func fileBytes(_ url: URL) throws -> Data { try Data(contentsOf: url) }

    private func allReadings(_ store: TaptionStoreV2) async throws -> [SensorReading] {
        try await store.allReadingsLoadResult().readings
    }

    // MARK: 형식 보조

    func testMonthKeysAndFileNames() {
        let month = TaptionBackupMonth(year: 2026, month: 10)
        XCTAssertEqual(month.fileName, "2026-10.taptionbackup")
        XCTAssertEqual(TaptionBackupMonth(fileName: "2026-10.taptionbackup"), month)
        XCTAssertNil(TaptionBackupMonth(fileName: "2026-13.taptionbackup"))
        XCTAssertNil(TaptionBackupMonth(fileName: "2026-10.zip"))
        XCTAssertEqual(month.adding(months: 3), TaptionBackupMonth(year: 2027, month: 1))
        XCTAssertEqual(month.adding(months: -10), TaptionBackupMonth(year: 2025, month: 12))
        XCTAssertTrue(TaptionBackupMonth(year: 2026, month: 9) < month)
    }

    func testJSONLineRoundTripsStringsAndDoublesExactly() throws {
        var generator = SystemRandomNumberGenerator()
        var doubles: [Double] = [0, -0.0, 1, 0.1, 1e-9, 1.7e18, 37.566_535_123_456_78, .leastNonzeroMagnitude, .greatestFiniteMagnitude]
        for _ in 0..<2_000 { doubles.append(Double.random(in: -200...200, using: &generator)) }
        for _ in 0..<2_000 { doubles.append(Double(bitPattern: UInt64.random(in: 0...UInt64.max, using: &generator))) }
        let text = "a\"b\\c\nd\re\tf\u{0001}g\u{1F600}한글 \u{2028}"
        var builder = TaptionBackupJSONLine.Builder()
        builder.string(text)
        builder.null()
        builder.int(Int64.min)
        for value in doubles where value.isFinite { try builder.double(value) }
        let line = builder.finish()
        XCTAssertEqual(line.last, 0x0A)
        XCTAssertEqual(line.filter { $0 == 0x0A }.count, 1, "줄 안에 날 줄바꿈이 없어야 한다")
        let fields = try TaptionBackupJSONLine.parse(line.dropLast())
        XCTAssertEqual(fields[0].string, text)
        XCTAssertTrue(fields[1].isNull)
        XCTAssertEqual(fields[2].int64, Int64.min)
        let finite = doubles.filter(\.isFinite)
        for (offset, value) in finite.enumerated() {
            XCTAssertEqual(fields[3 + offset].double?.bitPattern, value.bitPattern, "\(value)")
        }
    }

    func testPBKDF2MatchesPublishedVectorAndRejectsEmptyPassword() throws {
        // PBKDF2-HMAC-SHA256 공개 시험 벡터(4096회)의 앞 32바이트. 파이썬 hashlib.pbkdf2_hmac으로도 같은 값을 확인했다.
        let key = try TaptionBackupCrypto.deriveKey(
            password: "passwordPASSWORDpassword",
            salt: Data("saltSALTsaltSALTsaltSALTsaltSALTsalt".utf8), iterations: 4_096
        )
        XCTAssertEqual(
            TaptionBackupCrypto.hex(key.withUnsafeBytes { Array($0) }),
            "348c89dbcbd32b2f32d814b8116e84cf2b17347ebc1800181c4e2a1fb8dd53e1"
        )
        XCTAssertThrowsError(try TaptionBackupCrypto.deriveKey(password: "", salt: Data(repeating: 1, count: 16), iterations: 1))
        let first = try TaptionBackupCrypto.deriveKey(password: "123456", salt: Data(repeating: 1, count: 16), iterations: 10)
        let second = try TaptionBackupCrypto.deriveKey(password: "123456", salt: Data(repeating: 2, count: 16), iterations: 10)
        XCTAssertNotEqual(first.withUnsafeBytes { Data($0) }, second.withUnsafeBytes { Data($0) }, "솔트가 다르면 키가 달라야 한다")
    }

    // MARK: 왕복

    func testRoundTripRestoresIdenticalReadingsAndRecordsIntoNewStore() async throws {
        let source = try makeHarness()
        var sample: [SensorReading] = []
        for day in 1...5 { sample += readings(day: date(2026, 10, day), count: 40, startIndex: day * 100) }
        sample.append(reading(date(2026, 10, 2, 15), 999, ssid: "카페 \"WiFi\"\n2층"))
        sample.append(SensorReading(timestamp: date(2026, 10, 3, 1), motion: .stationary))
        try await source.store.upsertReadings(sample)
        let records = [
            record("r1", start: date(2026, 10, 1, 9), ord: 0),
            record("r2", kind: "plan", start: date(2026, 10, 9, 9), ord: 1),
            record("r3", start: date(2026, 10, 12, 9), ord: 2, deleted: true),
            record("undated", kind: "category", start: nil, ord: 0),
            record("other-month", start: date(2026, 11, 2, 9), ord: 3),
        ]
        try await source.store.upsertRecords(records)

        let backupEngine = engine(source, chunkBytes: 4_096)
        let result = try await backupEngine.backup(month: TaptionBackupMonth(year: 2026, month: 10), password: password, now: date(2026, 10, 10))
        XCTAssertEqual(result.outcome, .written)
        let header = try XCTUnwrap(result.header)
        XCTAssertEqual(header.readingCount, sample.count)
        XCTAssertEqual(header.recordCount, 3, "시작 시각이 없거나 다른 달인 기록은 담지 않는다")
        XCTAssertGreaterThan(header.chunkCount, 1, "작은 청크로 여러 프레임을 만들었다")
        XCTAssertEqual(header.lastTimestamp, date(2026, 10, 12, 9).timeIntervalSince1970, "마지막 시각은 센서 원본과 기록의 시작 시각 중 가장 늦은 것")
        XCTAssertEqual(header.firstTimestamp, date(2026, 10, 1, 9).timeIntervalSince1970)

        let target = try makeHarness()
        let copy = TaptionBackupEngine(store: target.store, destination: source.destination, calendar: calendar)
        let summary = try await copy.restore(month: TaptionBackupMonth(year: 2026, month: 10), password: password)
        XCTAssertEqual(summary.newReadings, sample.count)
        let restored = try await allReadings(target.store)
        XCTAssertEqual(Set(restored), Set(sample))
        XCTAssertEqual(restored.map(\.timestamp), sample.map(\.timestamp).sorted())
        let restoredRecords = try await target.store.recordsForBackup(from: 0, to: .greatestFiniteMagnitude)
        let expected = records.filter { $0.id != "undated" && $0.id != "other-month" }
        XCTAssertEqual(restoredRecords.sorted { $0.id < $1.id }, expected.sorted { $0.id < $1.id })

        // 같은 파일을 다시 복원해도 변하지 않는다.
        let again = try await copy.restore(month: TaptionBackupMonth(year: 2026, month: 10), password: password)
        XCTAssertEqual(again.newReadings, 0)
        let count = try await target.store.readingCount()
        XCTAssertEqual(count, sample.count)
    }

    func testDefaultConfigurationUses600000IterationsAnd16ByteSalt() async throws {
        let harness = try makeHarness()
        try await harness.store.upsertReadings(readings(day: date(2026, 10, 4), count: 20))
        let defaultEngine = TaptionBackupEngine(store: harness.store, destination: harness.destination, calendar: calendar)
        let result = try await defaultEngine.backup(month: TaptionBackupMonth(year: 2026, month: 10), password: password, now: date(2026, 10, 5))
        let header = try XCTUnwrap(result.header)
        XCTAssertEqual(header.kdf.iterations, 600_000)
        XCTAssertEqual(header.kdf.algorithm, "PBKDF2-HMAC-SHA256")
        XCTAssertEqual(Data(base64Encoded: header.kdf.salt)?.count, 16)
        let url = harness.backupDirectory.appendingPathComponent("2026-10.taptionbackup")
        let listing = try await defaultEngine.listBackups()
        XCTAssertEqual(listing.first?.header, header, "비밀번호 없이 헤더를 읽을 수 있다")
        // 파일마다 솔트가 새로 정해진다.
        try await harness.store.upsertReadings(readings(day: date(2026, 10, 6), count: 5, startIndex: 500))
        let second = try await defaultEngine.backup(month: TaptionBackupMonth(year: 2026, month: 10), password: password, now: date(2026, 10, 7))
        XCTAssertNotEqual(second.header?.kdf.salt, header.kdf.salt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        // 평문 내용이 파일에 그대로 드러나지 않는다.
        let bytes = try fileBytes(url)
        XCTAssertNil(bytes.range(of: Data("latitude".utf8)))
        XCTAssertNil(bytes.range(of: Data("37.56".utf8)))
    }

    // MARK: 덮어쓰기 규칙

    func testOverwriteHappensOnlyForSupersetAndUnchangedDataIsNotRewritten() async throws {
        let harness = try makeHarness()
        let month = TaptionBackupMonth(year: 2026, month: 10)
        let backupEngine = engine(harness)
        let url = harness.backupDirectory.appendingPathComponent(month.fileName)

        try await harness.store.upsertReadings(readings(day: date(2026, 10, 1), count: 30))
        let first = try await backupEngine.backup(month: month, password: password, now: date(2026, 10, 10))
        XCTAssertEqual(first.outcome, .written)
        XCTAssertEqual(first.header?.readingCount, 30)

        let unchanged = try await backupEngine.backup(month: month, password: password, now: date(2026, 10, 11))
        XCTAssertEqual(unchanged.outcome, .unchanged)
        let afterUnchanged = try fileBytes(url)

        // 데이터가 늘면 상위 집합이므로 교체한다.
        try await harness.store.upsertReadings(readings(day: date(2026, 10, 20), count: 10, startIndex: 300))
        let grown = try await backupEngine.backup(month: month, password: password, now: date(2026, 10, 21))
        XCTAssertEqual(grown.outcome, .written)
        XCTAssertEqual(grown.header?.readingCount, 40)
        XCTAssertNotEqual(try fileBytes(url), afterUnchanged)

        // 로컬에서 지운 뒤 다시 백업하면 기존 파일을 지킨다.
        let fullBytes = try fileBytes(url)
        try await harness.store.deleteAll()
        let empty = try await backupEngine.backup(month: month, password: password, now: date(2026, 10, 22))
        XCTAssertEqual(empty.outcome, .skippedNoData)
        try await harness.store.upsertReadings(readings(day: date(2026, 10, 1), count: 5))
        let fewer = try await backupEngine.backup(month: month, password: password, now: date(2026, 10, 23))
        XCTAssertEqual(fewer.outcome, .keptExisting(.fewerRows(existing: 40, new: 5)))
        XCTAssertFalse(fewer.message.isEmpty)
        XCTAssertEqual(try fileBytes(url), fullBytes, "기존 백업은 한 바이트도 바뀌지 않아야 한다")
    }

    func testOverwriteRejectedWhenLastTimestampIsEarlierEvenWithMoreRows() async throws {
        let harness = try makeHarness()
        let month = TaptionBackupMonth(year: 2026, month: 10)
        let backupEngine = engine(harness)
        let late = readings(day: date(2026, 10, 25), count: 10)
        try await harness.store.upsertReadings(late)
        _ = try await backupEngine.backup(month: month, password: password, now: date(2026, 10, 26))
        let url = harness.backupDirectory.appendingPathComponent(month.fileName)
        let original = try fileBytes(url)

        try await harness.store.deleteReadings(ids: late.map { $0.id.uuidString })
        try await harness.store.upsertReadings(readings(day: date(2026, 10, 2), count: 50, startIndex: 1000))
        let result = try await backupEngine.backup(month: month, password: password, now: date(2026, 10, 27))
        guard case .keptExisting(.earlierLastTimestamp) = result.outcome else {
            return XCTFail("마지막 시각이 앞선 파일은 거부해야 한다: \(result.outcome)")
        }
        XCTAssertEqual(try fileBytes(url), original)
    }

    func testUnreadableExistingFileIsNeverOverwritten() async throws {
        let harness = try makeHarness()
        let month = TaptionBackupMonth(year: 2026, month: 10)
        try FileManager.default.createDirectory(at: harness.backupDirectory, withIntermediateDirectories: true)
        let url = harness.backupDirectory.appendingPathComponent(month.fileName)
        try Data("not a backup".utf8).write(to: url)
        try await harness.store.upsertReadings(readings(day: date(2026, 10, 1), count: 5))
        let result = try await engine(harness).backup(month: month, password: password, now: date(2026, 10, 3))
        XCTAssertEqual(result.outcome, .keptExisting(.existingUnreadable))
        XCTAssertEqual(try fileBytes(url), Data("not a backup".utf8))
    }

    // MARK: 쓰기 실패

    private struct FailingDestination: TaptionBackupDestination {
        let base: TaptionLocalFolderBackupDestination
        func list() async throws -> [TaptionBackupFileInfo] { try await base.list() }
        func fetch(name: String) async throws -> URL { try await base.fetch(name: name) }
        func replace(name: String, with localFile: URL) async throws { throw TaptionBackupError.destinationUnavailable("offline") }
        func remove(name: String) async throws { try await base.remove(name: name) }
    }

    func testFailuresBeforeAndDuringReplaceKeepExistingBackupAndLeaveNoTemporaryFiles() async throws {
        let harness = try makeHarness()
        let month = TaptionBackupMonth(year: 2026, month: 10)
        try await harness.store.upsertReadings(readings(day: date(2026, 10, 1), count: 20))
        _ = try await engine(harness).backup(month: month, password: password, now: date(2026, 10, 5))
        let url = harness.backupDirectory.appendingPathComponent(month.fileName)
        let original = try fileBytes(url)
        try await harness.store.upsertReadings(readings(day: date(2026, 10, 9), count: 20, startIndex: 200))

        // 1) 임시 파일이 쓰는 도중 깨진 경우: 검증이 잡고 기존 파일은 그대로다.
        let corrupting = engine(harness, beforeVerify: { temporary in
            let handle = try FileHandle(forUpdating: temporary)
            try handle.seek(toOffset: TaptionBackupLayout.bodyOffset + 40)
            let byte = try handle.read(upToCount: 1) ?? Data([0])
            try handle.seek(toOffset: TaptionBackupLayout.bodyOffset + 40)
            try handle.write(contentsOf: Data([byte[0] ^ 0xFF]))
            try handle.close()
        })
        do {
            _ = try await corrupting.backup(month: month, password: password, now: date(2026, 10, 10))
            XCTFail("손상된 임시 파일은 교체되면 안 된다")
        } catch {
            XCTAssertEqual(error as? TaptionBackupError, .checksumMismatch)
        }
        XCTAssertEqual(try fileBytes(url), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: harness.temporaryDirectory.path), [])

        // 2) 목적지 교체가 실패한 경우.
        let failing = engine(harness, destination: FailingDestination(base: harness.destination))
        do {
            _ = try await failing.backup(month: month, password: password, now: date(2026, 10, 10))
            XCTFail("교체 실패는 오류로 알려야 한다")
        } catch {
            XCTAssertEqual(error as? TaptionBackupError, .destinationUnavailable("offline"))
        }
        XCTAssertEqual(try fileBytes(url), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: harness.temporaryDirectory.path), [])

        // 3) 폴더 목적지는 원본 파일이 없으면 교체하지 않고, 업로드 임시 파일도 남기지 않는다.
        do {
            try await harness.destination.replace(name: month.fileName, with: harness.temporaryDirectory.appendingPathComponent("missing"))
            XCTFail()
        } catch {}
        XCTAssertEqual(try fileBytes(url), original)
        let names = try FileManager.default.contentsOfDirectory(atPath: harness.backupDirectory.path)
        XCTAssertEqual(names, [month.fileName])
        let listed = try await harness.destination.list()
        XCTAssertEqual(listed.map(\.name), [month.fileName])
    }

    // MARK: 비밀번호·변조

    func testWrongPasswordFailsClearlyWithoutTouchingTheStore() async throws {
        let harness = try makeHarness()
        let month = TaptionBackupMonth(year: 2026, month: 10)
        try await harness.store.upsertReadings(readings(day: date(2026, 10, 1), count: 10))
        let backupEngine = engine(harness)
        _ = try await backupEngine.backup(month: month, password: password, now: date(2026, 10, 5))

        let target = try makeHarness()
        let restorer = TaptionBackupEngine(store: target.store, destination: harness.destination, calendar: calendar)
        do {
            _ = try await restorer.restore(month: month, password: "000000")
            XCTFail("틀린 비밀번호는 복원되면 안 된다")
        } catch {
            XCTAssertEqual(error as? TaptionBackupError, .wrongPassword)
        }
        let count = try await target.store.readingCount()
        XCTAssertEqual(count, 0)
        do {
            _ = try await restorer.restore(month: month, password: "")
            XCTFail()
        } catch {
            XCTAssertEqual(error as? TaptionBackupError, .emptyPassword)
        }
    }

    func testTamperedFilesAreDetected() async throws {
        let harness = try makeHarness()
        let month = TaptionBackupMonth(year: 2026, month: 10)
        try await harness.store.upsertReadings(readings(day: date(2026, 10, 1), count: 60))
        try await harness.store.upsertRecords([record("m", start: date(2026, 10, 2), ord: 0)])
        let backupEngine = engine(harness, chunkBytes: 2_048)
        _ = try await backupEngine.backup(month: month, password: password, now: date(2026, 10, 5))
        let url = harness.backupDirectory.appendingPathComponent(month.fileName)
        let original = try fileBytes(url)
        let header = try TaptionBackupFileReader.readHeader(at: url)
        XCTAssertGreaterThan(header.chunkCount, 2)
        let target = try makeHarness()
        let restorer = TaptionBackupEngine(store: target.store, destination: harness.destination, calendar: calendar)

        func expect(_ expected: TaptionBackupError, _ label: String) async throws {
            do {
                _ = try await restorer.restore(month: month, password: password)
                XCTFail("\(label): 변조된 파일이 복원됨")
            } catch {
                XCTAssertEqual(error as? TaptionBackupError, expected, label)
            }
            let count = try await target.store.readingCount()
            XCTAssertEqual(count, 0, "\(label): 변조 파일은 아무것도 쓰지 않아야 한다")
        }

        // 1) 본문 바이트 하나 바꿈: 비밀번호 없이도 체크섬이 잡는다.
        var flipped = original
        flipped[Int(TaptionBackupLayout.bodyOffset) + 100] ^= 0x01
        try flipped.write(to: url)
        try await expect(.checksumMismatch, "본문 비트 반전")

        // 2) 공격자가 헤더의 체크섬까지 고쳐 놓아도 AES-GCM 태그가 잡는다.
        try flipped.write(to: url)
        try rewriteHeader(at: url) { header in
            let body = try Data(contentsOf: url).dropFirst(Int(TaptionBackupLayout.bodyOffset))
            header.bodySHA256 = TaptionBackupCrypto.hex(SHA256Helper.hash(Data(body)))
        }
        try await expect(.authenticationFailed, "체크섬을 고친 본문 변조")

        // 3) 헤더의 행 수만 고침: 트레일러·내용 해시와 맞지 않는다.
        try original.write(to: url)
        try rewriteHeader(at: url) { $0.readingCount += 1; $0.rowCount += 1 }
        try await expect(.verificationFailed("trailer does not match header or content"), "헤더 행 수 변조")

        // 4) 프레임 순서 바꿈(두 번째·세 번째 프레임 교환)과 5) 잘림(마지막 프레임 제거, 헤더를 맞춰도).
        try original.write(to: url)
        try swapFrames(at: url, 1, 2)
        try await expect(.authenticationFailed, "프레임 순서 교환")

        try original.write(to: url)
        try dropLastFrame(at: url)
        try await expect(.authenticationFailed, "마지막 프레임 제거")

        // 6) 월 이름을 바꿔치기한 파일.
        try original.write(to: url)
        try rewriteHeader(at: url) { $0.month = "2026-09" }
        try await expect(.malformed("month does not match file name"), "월 바꿔치기")

        // 원본은 정상 복원된다.
        try original.write(to: url)
        let ok = try await restorer.restore(month: month, password: password)
        XCTAssertEqual(ok.newReadings, 60)
    }

    // MARK: 센서 원본 변경 금지

    func testRestoreRefusesToChangeAnExistingReadingWithTheSameID() async throws {
        let source = try makeHarness()
        let original = reading(date(2026, 10, 3), 5)
        try await source.store.upsertReadings([original])
        let month = TaptionBackupMonth(year: 2026, month: 10)
        _ = try await engine(source).backup(month: month, password: password, now: date(2026, 10, 5))

        let target = try makeHarness()
        var changed = original
        changed.stepCount = 12_345
        try await target.store.upsertReadings([changed])
        let restorer = TaptionBackupEngine(store: target.store, destination: source.destination, calendar: calendar)
        do {
            _ = try await restorer.restore(month: month, password: password)
            XCTFail("같은 id가 다른 내용이면 거부해야 한다")
        } catch {
            XCTAssertEqual(error as? TaptionStoreV2Error, .readingConflict(original.id.uuidString))
        }
        let stored = try await target.store.readings(ids: [original.id.uuidString])
        XCTAssertEqual(stored, [changed], "로컬 원본은 그대로")
    }

    // MARK: 봉인·오프로드

    func testOffloadSealsOnlyVerifiedFinishedMonthsAndRestoreBringsThemBack() async throws {
        let harness = try makeHarness()
        let september = TaptionBackupMonth(year: 2026, month: 9)
        let october = TaptionBackupMonth(year: 2026, month: 10)
        let sepData = readings(day: date(2026, 9, 12), count: 50)
        let octData = readings(day: date(2026, 10, 5), count: 30, startIndex: 100)
        try await harness.store.upsertReadings(sepData + octData)
        try await harness.store.upsertRecords([
            record("sep-memo", start: date(2026, 9, 20), ord: 0), record("oct-memo", start: date(2026, 10, 6), ord: 1),
        ])
        let backupEngine = engine(harness)

        // 달이 끝나기 전에 만든 9월 백업은 근거가 되지 못한다.
        _ = try await backupEngine.backup(month: september, password: password, now: date(2026, 9, 28))
        var offload = try await backupEngine.offloadSealedMonths(password: password, now: date(2026, 11, 3))
        XCTAssertEqual(offload.count, 1)
        guard case .skipped(let early) = offload[0].outcome else { return XCTFail("달 끝나기 전 백업은 거부해야 한다") }
        XCTAssertTrue(early.contains("달이 끝나기 전"))
        var sepCount = try await harness.store.rangeStats(from: 0, to: .greatestFiniteMagnitude).readings
        XCTAssertEqual(sepCount, 80)

        // 달이 끝난 뒤 다시 백업하면 봉인·정리된다. 10월(이번 달에서 직전 달)은 남는다.
        _ = try await backupEngine.backup(month: september, password: password, now: date(2026, 10, 2))
        _ = try await backupEngine.backup(month: october, password: password, now: date(2026, 11, 1))
        offload = try await backupEngine.offloadSealedMonths(password: password, now: date(2026, 11, 3))
        XCTAssertEqual(offload, [.init(month: september, outcome: .sealed(readings: 50, records: 1))])
        let sealed = try await backupEngine.isSealed(september)
        XCTAssertTrue(sealed)
        let remaining = try await allReadings(harness.store)
        XCTAssertEqual(Set(remaining), Set(octData), "진행 중이거나 최근 달은 지우지 않는다")
        sepCount = try await harness.store.recordCount()
        XCTAssertEqual(sepCount, 1)

        // 봉인된 달은 다시 쓰지 않는다.
        try await harness.store.upsertReadings([reading(date(2026, 9, 30, 23), 7)])
        let sealedBackup = try await backupEngine.backup(month: september, password: password, now: date(2026, 11, 4))
        XCTAssertEqual(sealedBackup.outcome, .skippedSealed)
        let late = try await backupEngine.offloadSealedMonths(password: password, now: date(2026, 11, 5))
        XCTAssertEqual(late.count, 1, "봉인 뒤 늦게 들어온 행은 검증이 맞지 않아 지우지 않는다")
        if case .sealed = late[0].outcome { XCTFail() }

        // 지운 달 불러오기.
        let lateRows = try await harness.store.readings(from: date(2026, 9, 30), to: date(2026, 10, 1))
        try await harness.store.deleteReadings(ids: lateRows.map { $0.id.uuidString })
        let restored = try await backupEngine.restore(month: september, password: password)
        XCTAssertEqual(restored.newReadings, 50)
        let sealedAfter = try await backupEngine.isSealed(september)
        XCTAssertFalse(sealedAfter, "복원하면 봉인이 풀린다")
        let all = try await allReadings(harness.store)
        XCTAssertEqual(Set(all), Set(sepData + octData))
    }

    func testOffloadDoesNotDeleteWhenTheUploadedFileFailsVerification() async throws {
        let harness = try makeHarness()
        let september = TaptionBackupMonth(year: 2026, month: 9)
        let data = readings(day: date(2026, 9, 12), count: 40)
        try await harness.store.upsertReadings(data)
        let backupEngine = engine(harness)
        _ = try await backupEngine.backup(month: september, password: password, now: date(2026, 10, 2))
        let url = harness.backupDirectory.appendingPathComponent(september.fileName)
        let original = try fileBytes(url)

        // 올라간 파일이 손상된 경우.
        var damaged = original
        damaged[Int(TaptionBackupLayout.bodyOffset) + 50] ^= 0x10
        try damaged.write(to: url)
        var results = try await backupEngine.offloadSealedMonths(password: password, now: date(2026, 12, 1))
        guard case .skipped(let message) = results.first?.outcome else { return XCTFail("손상된 파일 뒤에 지우면 안 된다") }
        XCTAssertTrue(message.contains("검증 실패"), message)
        var local = try await allReadings(harness.store)
        XCTAssertEqual(Set(local), Set(data))

        // 틀린 비밀번호로는 검증할 수 없어 지우지 않는다.
        try original.write(to: url)
        results = try await backupEngine.offloadSealedMonths(password: "999999", now: date(2026, 12, 1))
        guard case .skipped = results.first?.outcome else { return XCTFail("틀린 비밀번호로 지우면 안 된다") }
        local = try await allReadings(harness.store)
        XCTAssertEqual(Set(local), Set(data))

        // 백업이 없는 달은 지우지 않는다.
        try FileManager.default.removeItem(at: url)
        results = try await backupEngine.offloadSealedMonths(password: password, now: date(2026, 12, 1))
        guard case .skipped = results.first?.outcome else { return XCTFail("백업 없는 달을 지우면 안 된다") }
        local = try await allReadings(harness.store)
        XCTAssertEqual(Set(local), Set(data))

        // 내용이 로컬과 다르면(검증 뒤 편집) 지우지 않는다.
        try original.write(to: url)
        try await harness.store.upsertReadings([reading(date(2026, 9, 13), 777)])
        results = try await backupEngine.offloadSealedMonths(password: password, now: date(2026, 12, 1))
        guard case .skipped(let mismatch) = results.first?.outcome else { return XCTFail() }
        XCTAssertTrue(mismatch.contains("달라"), mismatch)
        local = try await allReadings(harness.store)
        XCTAssertEqual(local.count, 41)
    }

    func testBackupAllMonthsCreatesFilesForEveryMonthWithData() async throws {
        let harness = try makeHarness()
        try await harness.store.upsertReadings(
            readings(day: date(2026, 8, 31, 23), count: 5) + readings(day: date(2026, 10, 2), count: 5, startIndex: 50)
        )
        let results = try await engine(harness).backupAllMonths(password: password, now: date(2026, 10, 19))
        XCTAssertEqual(results.map(\.month.key), ["2026-08", "2026-09", "2026-10"])
        XCTAssertEqual(results.map(\.outcome), [.written, .skippedNoData, .written])
        let names = try await harness.destination.list().map(\.name)
        XCTAssertEqual(names, ["2026-08.taptionbackup", "2026-10.taptionbackup"])
    }

    // MARK: 압축률

    func testCompressionRatioOnSyntheticLocationHistory() async throws {
        let harness = try makeHarness()
        let month = TaptionBackupMonth(year: 2026, month: 10)
        var sample: [SensorReading] = []
        var generator = SeededGenerator(seed: 7)
        var latitude = 37.5665
        var longitude = 126.9780
        for index in 0..<5_000 {
            latitude += Double.random(in: -0.000_03...0.000_05, using: &generator)
            longitude += Double.random(in: -0.000_04...0.000_04, using: &generator)
            sample.append(SensorReading(
                timestamp: date(2026, 10, 1 + index / 1_000, 8).addingTimeInterval(Double(index % 1_000) * 3 + Double.random(in: 0..<0.5, using: &generator)),
                point: GeoPoint(
                    latitude: latitude, longitude: longitude,
                    altitude: 30 + Double.random(in: -1...1, using: &generator),
                    horizontalAccuracy: [5, 5, 10, 65].randomElement(using: &generator)!,
                    verticalAccuracy: 3
                ),
                locationFixQuality: .precise,
                speedMetersPerSecond: Double.random(in: 0...2.5, using: &generator),
                courseDegrees: Double.random(in: 0..<360, using: &generator),
                motion: .walking, motionConfidence: .high,
                stepCount: index,
                powerState: nil,
                behavior: "walking",
                sourceDevice: nil,
                sequence: index
            ))
        }
        try await harness.store.upsertReadings(sample)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let originalJSON = try encoder.encode(sample).count
        var jsonLines = 0
        for item in sample { jsonLines += try encoder.encode(item).count + 1 }
        try await harness.store.reclaimSpace()
        let sqliteSize = (try FileManager.default.attributesOfItem(atPath: harness.storeURL.path)[.size] as? Int) ?? 0

        var sizes: [String: Int] = [:]
        for codec in [TaptionBackupCodec.none, .lzfse, .zlib] {
            let local = try makeHarness()
            try await local.store.upsertReadings(sample)
            let result = try await engine(local, codec: codec).backup(month: month, password: password, now: date(2026, 11, 1))
            let header = try XCTUnwrap(result.header)
            let url = local.backupDirectory.appendingPathComponent(month.fileName)
            sizes[codec.name] = try fileBytes(url).count
            if codec == .lzfse {
                print("[압축률] 행 \(sample.count)건, JSONL 평문(표 단위 배열) \(header.plaintextBytes)B")
            }
        }
        print("[압축률] 원본 JSON(SensorReading 배열) \(originalJSON)B, 행마다 JSON Lines \(jsonLines)B, SQLite 파일 \(sqliteSize)B")
        for name in ["none", "lzfse", "zlib"] {
            let size = sizes[name]!
            print("[압축률] 백업 파일(\(name)) \(size)B = 원본 JSON의 \(String(format: "%.1f", Double(size) / Double(originalJSON) * 100))%, 건당 \(String(format: "%.1f", Double(size) / Double(sample.count)))B")
        }
        XCTAssertLessThan(sizes["lzfse"]!, originalJSON / 3)
        XCTAssertLessThan(sizes["zlib"]!, originalJSON / 3)
        XCTAssertLessThan(sizes["lzfse"]!, sizes["none"]!)
    }

    // MARK: 파이썬 도구 검증용 파일

    func testAttachBackupForExternalDecoder() async throws {
        let harness = try makeHarness()
        let month = TaptionBackupMonth(year: 2026, month: 10)
        try await harness.store.upsertReadings(
            readings(day: date(2026, 10, 3), count: 300) + [reading(date(2026, 10, 3, 20), 4_000, ssid: "카페 \"WiFi\"\n2층")]
        )
        try await harness.store.upsertRecords([record("memo-1", start: date(2026, 10, 3, 9), ord: 0)])
        let defaultEngine = TaptionBackupEngine(store: harness.store, destination: harness.destination, calendar: calendar)
        let result = try await defaultEngine.backup(month: month, password: "123456", now: date(2026, 10, 19))
        XCTAssertEqual(result.outcome, .written)
        let attachment = XCTAttachment(contentsOfFile: harness.backupDirectory.appendingPathComponent(month.fileName))
        attachment.name = "external-decoder-2026-10.taptionbackup"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: 변조 도우미

    private func rewriteHeader(at url: URL, _ change: (inout TaptionBackupHeader) throws -> Void) throws {
        var header = try TaptionBackupFileReader.readHeader(at: url)
        try change(&header)
        let region = try TaptionBackupHeaderCoding.encode(header)
        let handle = try FileHandle(forUpdating: url)
        try handle.seek(toOffset: UInt64(TaptionBackupLayout.magic.count + 4))
        try handle.write(contentsOf: region)
        try handle.close()
    }

    private func frameRanges(of data: Data) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var offset = Int(TaptionBackupLayout.bodyOffset)
        while offset < data.count {
            let sealed = Int(TaptionBackupCrypto.readUInt32(data, at: offset + 5))
            ranges.append(offset..<(offset + 9 + sealed))
            offset += 9 + sealed
        }
        return ranges
    }

    private func swapFrames(at url: URL, _ first: Int, _ second: Int) throws {
        let data = try fileBytes(url)
        let ranges = frameRanges(of: data)
        var rebuilt = data.prefix(Int(TaptionBackupLayout.bodyOffset))
        var order = Array(ranges.indices)
        order.swapAt(first, second)
        for index in order { rebuilt.append(data[ranges[index]]) }
        try rebuilt.write(to: url)
        try rewriteHeader(at: url) { header in
            header.bodySHA256 = TaptionBackupCrypto.hex(SHA256Helper.hash(Data(rebuilt.dropFirst(Int(TaptionBackupLayout.bodyOffset)))))
        }
    }

    private func dropLastFrame(at url: URL) throws {
        let data = try fileBytes(url)
        let last = try XCTUnwrap(frameRanges(of: data).last)
        let rebuilt = data.prefix(last.lowerBound)
        try Data(rebuilt).write(to: url)
        try rewriteHeader(at: url) { header in
            let body = Data(rebuilt.dropFirst(Int(TaptionBackupLayout.bodyOffset)))
            header.bodySHA256 = TaptionBackupCrypto.hex(SHA256Helper.hash(body))
            header.bodyBytes = body.count
            header.chunkCount -= 1
        }
    }
}

private enum SHA256Helper {
    static func hash(_ data: Data) -> [UInt8] { Array(SHA256.hash(data: data)) }
}

/// 재현 가능한 난수(압축률 수치를 매번 같게).
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
