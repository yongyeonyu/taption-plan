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
        configuration.minimumIterations = 1
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

    private var fastConfiguration: TaptionBackupEngine.Configuration {
        var configuration = TaptionBackupEngine.Configuration()
        configuration.iterations = 1_000
        configuration.minimumIterations = 1
        return configuration
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
            salt: Data("saltSALTsaltSALTsaltSALTsaltSALTsalt".utf8), iterations: 4_096, minimumIterations: 1
        )
        XCTAssertEqual(
            TaptionBackupCrypto.hex(key.withUnsafeBytes { Array($0) }),
            "348c89dbcbd32b2f32d814b8116e84cf2b17347ebc1800181c4e2a1fb8dd53e1"
        )
        XCTAssertThrowsError(try TaptionBackupCrypto.deriveKey(password: "", salt: Data(repeating: 1, count: 16), iterations: 1, minimumIterations: 1))
        let first = try TaptionBackupCrypto.deriveKey(password: "123456", salt: Data(repeating: 1, count: 16), iterations: 10, minimumIterations: 1)
        let second = try TaptionBackupCrypto.deriveKey(password: "123456", salt: Data(repeating: 2, count: 16), iterations: 10, minimumIterations: 1)
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
        let copy = TaptionBackupEngine(store: target.store, destination: source.destination, calendar: calendar, configuration: fastConfiguration)
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
        let locked = try await defaultEngine.listBackups()
        XCTAssertEqual(locked.first?.state, .locked)
        XCTAssertNil(locked.first?.header, "비밀번호 없이는 메타데이터가 보이지 않는다")
        XCTAssertEqual(locked.first?.scope, .month(TaptionBackupMonth(year: 2026, month: 10)))
        let listing = try await defaultEngine.listBackups(password: password)
        XCTAssertEqual(listing.first?.header, header)
        XCTAssertEqual(listing.first?.summary?.rowCount, 20)
        // 파일마다 솔트가 새로 정해진다.
        try await harness.store.upsertReadings(readings(day: date(2026, 10, 6), count: 5, startIndex: 500))
        let second = try await defaultEngine.backup(month: TaptionBackupMonth(year: 2026, month: 10), password: password, now: date(2026, 10, 7))
        XCTAssertNotEqual(second.header?.kdf.salt, header.kdf.salt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        // 평문 내용이 파일에 그대로 드러나지 않는다.
        let bytes = try fileBytes(url)
        XCTAssertNil(bytes.range(of: Data("latitude".utf8)))
        XCTAssertNil(bytes.range(of: Data("37.56".utf8)))
        // 헤더 메타데이터도 암호화돼 있다: 평문에는 행 수·시각·해시 이름이 없다.
        let region = String(decoding: bytes.prefix(TaptionBackupFileReader.headerPrefixBytes), as: UTF8.self)
        for forbidden in ["readingCount", "rowCount", "contentSHA256", "bodySHA256", "createdAt", "timeZone", "Asia/Seoul", "keyCheck", "lastTimestamp"] {
            XCTAssertFalse(region.contains(forbidden), forbidden)
        }
        XCTAssertTrue(region.contains("PBKDF2-HMAC-SHA256"))
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
        XCTAssertEqual(fewer.outcome, .keptExisting(.staleAfterDataWipe), "전체 삭제 이전의 백업은 합치지도 덮어쓰지도 않는다")
        XCTAssertFalse(fewer.message.isEmpty)
        XCTAssertEqual(try fileBytes(url), fullBytes, "기존 백업은 한 바이트도 바뀌지 않아야 한다")
    }

    func testHardDeletedReadingsComeBackFromTheBackupUnion() async throws {
        let harness = try makeHarness()
        let month = TaptionBackupMonth(year: 2026, month: 10)
        let backupEngine = engine(harness)
        let late = readings(day: date(2026, 10, 25), count: 10)
        try await harness.store.upsertReadings(late)
        _ = try await backupEngine.backup(month: month, password: password, now: date(2026, 10, 26))

        // 센서 원본에는 삭제 표시가 없다. 하드 삭제한 행은 다음 백업이 파일에서 합집합으로 되살린다(문서화된 동작).
        try await harness.store.deleteReadings(ids: late.map { $0.id.uuidString })
        try await harness.store.upsertReadings(readings(day: date(2026, 10, 2), count: 50, startIndex: 1000))
        let result = try await backupEngine.backup(month: month, password: password, now: date(2026, 10, 27))
        XCTAssertEqual(result.outcome, .written)
        XCTAssertEqual(result.header?.readingCount, 60)
        let local = try await allReadings(harness.store)
        XCTAssertEqual(local.count, 60)
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
        let restorer = TaptionBackupEngine(store: target.store, destination: harness.destination, calendar: calendar, configuration: fastConfiguration)
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
        let header = try TaptionBackupFileReader.open(at: url, scopeKey: month.key, password: password, minimumIterations: 1).header
        XCTAssertGreaterThan(header.chunkCount, 2)
        let target = try makeHarness()
        let restorer = TaptionBackupEngine(store: target.store, destination: harness.destination, calendar: calendar, configuration: fastConfiguration)

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
        try await expect(.wrongPassword, "월 바꿔치기(헤더 블록 AAD가 월을 묶는다)")

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
        let restorer = TaptionBackupEngine(store: target.store, destination: source.destination, calendar: calendar, configuration: fastConfiguration)
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

        // 봉인된 달이 비어 있으면 다시 쓰지 않는다.
        let sealedBackup = try await backupEngine.backup(month: september, password: password, now: date(2026, 11, 4))
        XCTAssertEqual(sealedBackup.outcome, .skippedSealed)

        // 봉인 뒤 늦게 도착한 행: 그대로는 지우지 않고, 백업하면 합집합으로 다시 만든 뒤 재봉인된다.
        let lateReading = reading(date(2026, 9, 30, 23), 7)
        try await harness.store.upsertReadings([lateReading])
        let blocked = try await backupEngine.offloadSealedMonths(password: password, now: date(2026, 11, 5))
        XCTAssertEqual(blocked.count, 1)
        if case .sealed = blocked[0].outcome { XCTFail("늦게 도착한 행이 있는 달을 그대로 지우면 안 된다") }
        let merged = try await backupEngine.backup(month: september, password: password, now: date(2026, 11, 4))
        XCTAssertEqual(merged.outcome, .written)
        XCTAssertEqual(merged.header?.readingCount, 51, "기존 파일 50건 + 늦은 1건")
        XCTAssertEqual(merged.header?.recordCount, 1)
        let unsealed = try await backupEngine.isSealed(september)
        XCTAssertFalse(unsealed)
        let resealed = try await backupEngine.offloadSealedMonths(password: password, now: date(2026, 11, 5))
        XCTAssertEqual(resealed, [.init(month: september, outcome: .sealed(readings: 51, records: 1))])

        // 지운 달 불러오기.
        let restored = try await backupEngine.restore(month: september, password: password)
        XCTAssertEqual(restored.newReadings, 51)
        let sealedAfter = try await backupEngine.isSealed(september)
        XCTAssertFalse(sealedAfter, "복원하면 봉인이 풀린다")
        let all = try await allReadings(harness.store)
        XCTAssertEqual(Set(all), Set(sepData + octData + [lateReading]))
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
        XCTAssertEqual(results.map(\.scope.key), ["2026-08", "2026-10", "settings"], "데이터가 있는 달만 순회한다")
        XCTAssertEqual(results.map(\.outcome), [.written, .written, .skippedNoData])
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

    // MARK: 삭제 표시(톰스톤)

    private func plan(_ title: String, at seconds: TimeInterval) -> PlanRecord {
        let start = Date(timeIntervalSince1970: 1_792_300_000 + seconds)
        return PlanRecord(title: title, span: TimeSpan(start: start, end: start.addingTimeInterval(1_800)), categoryID: "activity")
    }

    func testUserDeletedRecordBecomesTombstoneThatBackupCarriesAndRestoreApplies() async throws {
        let source = try makeHarness()
        let month = TaptionBackupMonth(year: 2026, month: 10)
        let repository = TaptionStoreRepository(store: source.store)
        let keep = plan("남길 계획", at: 0)
        let remove = plan("지울 계획", at: 3_600)
        var snapshot = TaptionDataSnapshot.empty
        snapshot.updatedAt = Date(timeIntervalSince1970: 1_792_300_100)
        snapshot.plans = [keep, remove]
        try await repository.save(snapshot)
        let backupEngine = engine(source)
        let first = try await backupEngine.backup(month: month, password: password, now: date(2026, 10, 19))
        XCTAssertEqual(first.outcome, .written)
        XCTAssertEqual(first.header?.recordCount, 2)

        // 복원해 둔 다른 기기(삭제 전 상태).
        let target = try makeHarness()
        let restorer = TaptionBackupEngine(store: target.store, destination: source.destination, calendar: calendar, configuration: fastConfiguration)
        _ = try await restorer.restore(month: month, password: password)
        let before = try await target.store.records(kind: "plan")
        XCTAssertEqual(before.count, 2)

        // 사용자가 계획 하나를 지움 → 저장소는 삭제 표시로 바꾼다.
        snapshot.updatedAt = Date(timeIntervalSince1970: 1_792_300_200)
        snapshot.plans = [keep]
        try await repository.save(snapshot)
        let loaded = try await repository.load()
        XCTAssertEqual(loaded.plans.map(\.id), [keep.id], "삭제된 행은 불러오지 않는다")
        let rows = try await source.store.recordsForBackup(from: 0, to: .greatestFiniteMagnitude)
        let tombstone = try XCTUnwrap(rows.first { $0.id == "\(remove.id)" })
        XCTAssertTrue(tombstone.isDeleted)
        XCTAssertEqual(tombstone.body, "{}", "삭제 표시에는 내용이 남지 않는다")
        XCTAssertNotNil(tombstone.start, "어느 달의 삭제인지 알 수 있게 시작 시각은 남긴다")
        XCTAssertGreaterThan(tombstone.updatedAt, Date(timeIntervalSince1970: 1_792_300_100))

        // 삭제된 달의 새 백업은 거부되지 않는다(행 수는 그대로, 삭제 표시가 추가됨).
        let second = try await backupEngine.backup(month: month, password: password, now: date(2026, 10, 20))
        XCTAssertEqual(second.outcome, .written, second.message)
        XCTAssertEqual(second.header?.rowCount, 2)
        XCTAssertGreaterThan(second.header?.latestRecordUpdate ?? 0, first.header?.latestRecordUpdate ?? 0)

        // 복원하면 더 오래된 로컬 행에 삭제가 적용된다.
        _ = try await restorer.restore(month: month, password: password)
        let after = try await target.store.records(kind: "plan")
        XCTAssertEqual(after.map(\.id), ["\(keep.id)"])

        // 로컬이 삭제 시각보다 나중에 고친 행은 지키고 삭제를 적용하지 않는다.
        let guarded = try makeHarness()
        let guardedEngine = TaptionBackupEngine(store: guarded.store, destination: source.destination, calendar: calendar, configuration: fastConfiguration)
        let newerLocal = TaptionStoreRecord(
            id: "\(remove.id)", kind: "plan", start: remove.span.start, end: nil,
            updatedAt: Date().addingTimeInterval(3_600), origin: .user, body: "{\"edited\":true}"
        )
        try await guarded.store.upsertRecords([newerLocal])
        _ = try await guardedEngine.restore(month: month, password: password)
        let kept = try await guarded.store.records(kind: "plan").first { $0.id == "\(remove.id)" }
        XCTAssertEqual(kept?.body, "{\"edited\":true}")
    }

    func testOffloadedMonthEmptyOrShrunkenLocalDataNeverOverwritesTheFullFile() async throws {
        let harness = try makeHarness()
        let september = TaptionBackupMonth(year: 2026, month: 9)
        try await harness.store.upsertReadings(readings(day: date(2026, 9, 12), count: 40))
        try await harness.store.upsertRecords([record("m", start: date(2026, 9, 13), ord: 0)])
        let backupEngine = engine(harness)
        _ = try await backupEngine.backup(month: september, password: password, now: date(2026, 10, 2))
        let offload = try await backupEngine.offloadSealedMonths(password: password, now: date(2026, 11, 3))
        XCTAssertEqual(offload.first?.outcome, .sealed(readings: 40, records: 1))
        let url = harness.backupDirectory.appendingPathComponent(september.fileName)
        let full = try fileBytes(url)

        // 로컬이 비어 있으면 봉인 표시와 상관없이 쓰지 않는다.
        let empty = try await backupEngine.backup(month: september, password: password, now: date(2026, 11, 4))
        XCTAssertEqual(empty.outcome, .skippedSealed)
        // 봉인 표시를 잃은 기기(예: 새 설치)에서도 빈 로컬은 쓰지 않는다.
        try await harness.store.setMeta("backup.sealed.2026-09", "")
        let lost = try await backupEngine.backup(month: september, password: password, now: date(2026, 11, 4))
        XCTAssertEqual(lost.outcome, .skippedNoData)
        // 봉인 표시 없이 일부만 남은 로컬도 파일을 지우지 않는다: 읽히는 파일과 합집합으로 다시 쓴다.
        try await harness.store.upsertReadings([reading(date(2026, 9, 2), 1)])
        let partial = try await backupEngine.backup(month: september, password: password, now: date(2026, 11, 5))
        XCTAssertEqual(partial.outcome, .written)
        XCTAssertEqual(partial.header?.readingCount, 41)
        XCTAssertEqual(partial.header?.recordCount, 1)
        XCTAssertGreaterThanOrEqual(try fileBytes(url).count, full.count - 64, "파일이 줄지 않는다")
    }

    // MARK: 설정 파일

    func testSettingsFileHoldsUndatedRecordsAndFollowsTheSameRules() async throws {
        let source = try makeHarness()
        let october = TaptionBackupMonth(year: 2026, month: 10)
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        try await source.store.upsertRecords([
            record("snapshot", kind: "header", start: nil, ord: 0, updated: base, body: "{\"theme\":\"dark\"}"),
            record("c1", kind: "category", start: nil, ord: 0, updated: base),
            record("c2", kind: "category", start: nil, ord: 1, updated: base, deleted: true, body: "{}"),
            record("dated", start: date(2026, 10, 2), ord: 0),
        ])
        try await source.store.upsertReadings(readings(day: date(2026, 10, 2), count: 5))
        let backupEngine = engine(source)
        let results = try await backupEngine.backupAllMonths(password: password, now: date(2026, 10, 19))
        XCTAssertEqual(results.map(\.scope.key), ["2026-10", "settings"])
        XCTAssertEqual(results.map(\.outcome), [.written, .written])
        let settings = try XCTUnwrap(results.last?.header)
        XCTAssertEqual(settings.recordCount, 3, "시작 시각이 없는 기록(삭제 표시 포함)만")
        XCTAssertEqual(settings.readingCount, 0)
        XCTAssertEqual(settings.month, "settings")
        XCTAssertEqual(results.first?.header?.recordCount, 1, "월 파일에는 시작 시각이 있는 기록만")
        let names = try await source.destination.list().map(\.name)
        XCTAssertEqual(names, ["2026-10.taptionbackup", "taption-settings.taptionbackup"])
        let listing = try await backupEngine.listBackups()
        XCTAssertEqual(listing.map(\.scope), [.month(october), .settings])

        // 같은 규칙: 변경 없으면 그대로, 로컬이 비면 지키고, 더 적으면 거부.
        let again = try await backupEngine.backupSettings(password: password, now: date(2026, 10, 20))
        XCTAssertEqual(again.outcome, .unchanged)
        // 오프로드는 설정 기록(시작 시각 없음)을 지우지 않는다.
        _ = try await backupEngine.backup(month: october, password: password, now: date(2026, 11, 2))
        let offloaded = try await backupEngine.offloadSealedMonths(password: password, now: date(2026, 12, 15))
        XCTAssertEqual(offloaded, [.init(month: october, outcome: .sealed(readings: 5, records: 1))])
        let kept = try await source.store.undatedRecordCount()
        XCTAssertEqual(kept, 3)
        let url = source.backupDirectory.appendingPathComponent(TaptionBackupScope.settingsFileName)
        let original = try fileBytes(url)
        try await source.store.deleteAllRecords()
        let emptied = try await backupEngine.backupSettings(password: password, now: date(2026, 10, 21))
        XCTAssertEqual(emptied.outcome, .skippedNoData)
        try await source.store.upsertRecords([record("c1", kind: "category", start: nil, ord: 0, updated: base)])
        let fewer = try await backupEngine.backupSettings(password: password, now: date(2026, 10, 22))
        XCTAssertEqual(fewer.outcome, .keptExisting(.staleAfterDataWipe))
        XCTAssertEqual(try fileBytes(url), original)

        // 복원은 파일이 더 새로울 때만 덮어쓴다.
        let target = try makeHarness()
        let restorer = TaptionBackupEngine(store: target.store, destination: source.destination, calendar: calendar, configuration: fastConfiguration)
        try await target.store.upsertRecords([
            record("c1", kind: "category", start: nil, ord: 0, updated: base.addingTimeInterval(500), body: "{\"local\":true}"),
        ])
        let summary = try await restorer.restoreSettings(password: password)
        XCTAssertEqual(summary.scope, .settings)
        let categories = try await target.store.records(kind: "category")
        XCTAssertEqual(categories.map(\.body), ["{\"local\":true}"], "로컬이 더 새로우면 유지")
        let headers = try await target.store.records(kind: "header")
        XCTAssertEqual(headers.map(\.body), ["{\"theme\":\"dark\"}"])
        let undated = try await target.store.undatedRecordCount()
        XCTAssertEqual(undated, 3)
    }

    // MARK: 봉인된 달에 늦게 도착한 행

    func testLateRowsInSealedMonthNeverOverwriteAnUnreadableOrDifferentlyKeyedFile() async throws {
        let harness = try makeHarness()
        let september = TaptionBackupMonth(year: 2026, month: 9)
        try await harness.store.upsertReadings(readings(day: date(2026, 9, 12), count: 30))
        let backupEngine = engine(harness)
        _ = try await backupEngine.backup(month: september, password: password, now: date(2026, 10, 2))
        _ = try await backupEngine.offloadSealedMonths(password: password, now: date(2026, 11, 3))
        let url = harness.backupDirectory.appendingPathComponent(september.fileName)
        let sealedBytes = try fileBytes(url)
        let late = reading(date(2026, 9, 29), 5)
        try await harness.store.upsertReadings([late])

        // 다른 비밀번호: 합집합을 만들 수 없으므로 오류로 멈추고 파일을 건드리지 않는다.
        do {
            _ = try await backupEngine.backup(month: september, password: "111111", now: date(2026, 11, 4))
            XCTFail()
        } catch {
            XCTAssertEqual(error as? TaptionBackupError, .passwordDiffersFromExistingBackup(september.fileName))
        }
        XCTAssertEqual(try fileBytes(url), sealedBytes)
        let stillSealed = try await backupEngine.isSealed(september)
        XCTAssertTrue(stillSealed)

        // 본문이 손상된 기존 파일: 합칠 수 없고 로컬(늦은 1행)이 파일의 주장을 넘지 못하므로 덮어쓰지 않는다.
        var damaged = sealedBytes
        damaged[Int(TaptionBackupLayout.bodyOffset) + 30] ^= 0x04
        try damaged.write(to: url)
        let kept = try await backupEngine.backup(month: september, password: password, now: date(2026, 11, 4))
        XCTAssertEqual(kept.outcome, .keptExisting(.existingCorrupted))
        XCTAssertEqual(try fileBytes(url), damaged)

        // 헤더도 읽을 수 없는 파일.
        try Data("garbage".utf8).write(to: url)
        let unreadable = try await backupEngine.backup(month: september, password: password, now: date(2026, 11, 4))
        XCTAssertEqual(unreadable.outcome, .keptExisting(.existingUnreadable))
        XCTAssertEqual(try fileBytes(url), Data("garbage".utf8))
        let local = try await allReadings(harness.store)
        XCTAssertEqual(local, [late], "늦게 도착한 행은 로컬에 그대로 있다")
    }

    // MARK: 전체 삭제

    private final class RecordingDestination: TaptionBackupDestination, @unchecked Sendable {
        let base: TaptionLocalFolderBackupDestination
        let failingName: String?
        private let lock = NSLock()
        private var removed: [String] = []
        var removeCalls: [String] { lock.withLock { removed } }

        init(base: TaptionLocalFolderBackupDestination, failingName: String? = nil) {
            self.base = base
            self.failingName = failingName
        }

        func list() async throws -> [TaptionBackupFileInfo] { try await base.list() }
        func fetch(name: String) async throws -> URL { try await base.fetch(name: name) }
        func replace(name: String, with localFile: URL) async throws { try await base.replace(name: name, with: localFile) }
        func remove(name: String) async throws {
            lock.withLock { removed.append(name) }
            if name == failingName { throw TaptionBackupError.destinationUnavailable("busy") }
            try await base.remove(name: name)
        }
    }

    func testNoOperationDeletesBackupsExceptDeleteAllBackupsAndPartialFailureIsReported() async throws {
        let harness = try makeHarness()
        let recording = RecordingDestination(base: harness.destination, failingName: "2026-10.taptionbackup")
        let backupEngine = engine(harness, destination: recording)
        try await harness.store.upsertReadings(
            readings(day: date(2026, 9, 12), count: 10) + readings(day: date(2026, 10, 3), count: 10, startIndex: 20)
        )
        try await harness.store.upsertRecords([record("c", kind: "category", start: nil)])

        // 백업·재백업·오프로드·복원·실패 경로를 모두 거쳐도 삭제는 한 번도 호출되지 않는다.
        _ = try await backupEngine.backupAllMonths(password: password, now: date(2026, 10, 19))
        _ = try await backupEngine.backupAllMonths(password: password, now: date(2026, 10, 20))
        _ = try await backupEngine.offloadSealedMonths(password: password, now: date(2026, 12, 1))
        _ = try await backupEngine.restore(month: TaptionBackupMonth(year: 2026, month: 9), password: password)
        _ = try? await backupEngine.restore(month: TaptionBackupMonth(year: 2026, month: 9), password: "000000")
        let namesBefore = try await harness.destination.list().map(\.name)
        XCTAssertEqual(namesBefore, ["2026-09.taptionbackup", "2026-10.taptionbackup", "taption-settings.taptionbackup"])
        XCTAssertEqual(recording.removeCalls, [], "사용자가 전체 삭제를 요청하기 전에는 아무것도 지우지 않는다")

        // 일부 실패: 실패한 파일만 남고 결과에 표시된다.
        let result = try await backupEngine.deleteAllBackups()
        XCTAssertEqual(Set(result.removed), ["2026-09.taptionbackup", "taption-settings.taptionbackup"])
        XCTAssertEqual(result.failed.map(\.name), ["2026-10.taptionbackup"])
        XCTAssertEqual(result.remaining, ["2026-10.taptionbackup"])
        let sealed = try await backupEngine.isSealed(TaptionBackupMonth(year: 2026, month: 9))
        XCTAssertFalse(sealed, "지운 월 파일의 봉인 표시는 푼다")

        // 실패 없는 경우 모두 지운다. 로컬 데이터는 건드리지 않는다.
        let clean = engine(harness)
        let all = try await clean.deleteAllBackups()
        XCTAssertEqual(all.removed, ["2026-10.taptionbackup"])
        XCTAssertTrue(all.failed.isEmpty)
        XCTAssertEqual(all.remaining, [])
        let localCount = try await harness.store.readingCount()
        XCTAssertEqual(localCount, 20, "로컬 데이터는 그대로(9월은 복원으로 되돌아왔다)")
    }

    // MARK: BKP1019C01 결함 수정

    private func timestamp(_ date: Date) -> Double { date.timeIntervalSince1970 }

    // A1: 검증 뒤 삭제 사이의 편집·삭제 표시를 지문이 잡고, 봉인 표시는 같은 트랜잭션에 기록된다.
    func testDeleteRangeRefusesAnyChangeAfterVerificationAndWritesSealInTheSameTransaction() async throws {
        let harness = try makeHarness()
        let from = timestamp(date(2026, 9, 1, 0))
        let to = timestamp(date(2026, 10, 1, 0))
        let sample = readings(day: date(2026, 9, 12), count: 5)
        try await harness.store.upsertReadings(sample)
        let memo = record("m", start: date(2026, 9, 13), ord: 0)
        try await harness.store.upsertRecords([memo])
        let seal = (key: "backup.sealed.2026-09", value: "sealed")

        // (a) 수정 시각이 같은 채 본문만 바뀐 편집
        var fingerprint = try await harness.store.rangeFingerprint(from: from, to: to)
        var edited = memo
        edited.body = "{\"edited\":true}"
        try await harness.store.upsertRecords([edited])
        var outcome = try await harness.store.deleteRange(from: from, to: to, expected: fingerprint, sealedMeta: seal)
        XCTAssertNil(outcome, "같은 수정 시각의 본문 편집도 놓치면 안 된다")

        // (b) 센서 원본이 같은 id로 다시 쓰여 내용이 바뀜(행 수는 같다)
        fingerprint = try await harness.store.rangeFingerprint(from: from, to: to)
        var changed = sample[0]
        changed.stepCount = 99_999
        try await harness.store.upsertReadings([changed])
        outcome = try await harness.store.deleteRange(from: from, to: to, expected: fingerprint, sealedMeta: seal)
        XCTAssertNil(outcome, "행 수가 같아도 다시 쓴 원본을 잡아야 한다")

        // (c) 삭제 표시
        fingerprint = try await harness.store.rangeFingerprint(from: from, to: to)
        try await harness.store.applyRecordChanges(upserts: [], deletes: [(kind: "memo", id: "m")])
        outcome = try await harness.store.deleteRange(from: from, to: to, expected: fingerprint, sealedMeta: seal)
        XCTAssertNil(outcome, "검증 뒤 생긴 삭제 표시를 놓치면 안 된다")
        let sealAfterRefusals = try await harness.store.meta(seal.key)
        XCTAssertNil(sealAfterRefusals, "거부되면 봉인 표시도 남지 않는다")
        let rows = try await harness.store.rangeStats(from: from, to: to)
        XCTAssertEqual(rows.readings, 5)
        XCTAssertEqual(rows.records, 1)

        // (d) 그대로면 지우고, 같은 트랜잭션에서 봉인 표시를 남긴다.
        fingerprint = try await harness.store.rangeFingerprint(from: from, to: to)
        let removed = try await harness.store.deleteRange(from: from, to: to, expected: fingerprint, sealedMeta: seal)
        XCTAssertEqual(removed?.readings, 5)
        XCTAssertEqual(removed?.records, 1)
        let sealValue = try await harness.store.meta(seal.key)
        XCTAssertEqual(sealValue, "sealed")
    }

    // A2: 봉인 표시가 없는 기기(재설치)에서도 읽히는 기존 파일을 버리지 않고 합집합으로 쓴다.
    func testNewInstallWithOnlyLateRowsMergesIntoTheExistingSealedFileInsteadOfReplacingIt() async throws {
        let source = try makeHarness()
        let september = TaptionBackupMonth(year: 2026, month: 9)
        let original = readings(day: date(2026, 9, 12), count: 30)
        try await source.store.upsertReadings(original)
        try await source.store.upsertRecords([record("old-memo", start: date(2026, 9, 14), ord: 0)])
        let first = engine(source)
        _ = try await first.backup(month: september, password: password, now: date(2026, 10, 2))
        let offload = try await first.offloadSealedMonths(password: password, now: date(2026, 11, 3))
        XCTAssertEqual(offload.first?.outcome, .sealed(readings: 30, records: 1))

        // 새 기기: 봉인 표시도 로컬 데이터도 없고, 늦은 행 3개만 있다.
        let fresh = try makeHarness()
        let late = readings(day: date(2026, 9, 29), count: 3, startIndex: 700)
        try await fresh.store.upsertReadings(late)
        let result = try await engine(fresh, destination: source.destination)
            .backup(month: september, password: password, now: date(2026, 11, 4))
        XCTAssertEqual(result.outcome, .written, "상위 집합 판정으로 거부하거나 통째로 교체하면 안 된다")
        XCTAssertEqual(result.header?.readingCount, 33)
        XCTAssertEqual(result.header?.recordCount, 1)

        let verifier = try makeHarness()
        _ = try await engine(verifier, destination: source.destination).restore(month: september, password: password)
        let restored = try await allReadings(verifier.store)
        XCTAssertEqual(Set(restored), Set(original + late))
    }

    // A3: 다른 비밀번호는 쓰기·오프로드 전에 거부하고, 한 달의 실패가 나머지를 멈추지 않는다.
    func testDifferentPasswordIsRefusedBeforeWritingOrOffloadingAndOneMonthFailureDoesNotStopTheRest() async throws {
        let harness = try makeHarness()
        let september = TaptionBackupMonth(year: 2026, month: 9)
        try await harness.store.upsertReadings(readings(day: date(2026, 9, 12), count: 20))
        let backupEngine = engine(harness)
        _ = try await backupEngine.backup(month: september, password: password, now: date(2026, 10, 2))
        let url = harness.backupDirectory.appendingPathComponent(september.fileName)
        let original = try fileBytes(url)

        do {
            _ = try await backupEngine.backup(month: september, password: "654321", now: date(2026, 10, 3))
            XCTFail("다른 비밀번호로 읽을 수 없는 새 파일을 만들면 안 된다")
        } catch {
            XCTAssertEqual(error as? TaptionBackupError, .passwordDiffersFromExistingBackup(september.fileName))
            XCTAssertNotEqual(error as? TaptionBackupError, .wrongPassword)
        }
        XCTAssertEqual(try fileBytes(url), original)

        let offload = try await backupEngine.offloadSealedMonths(password: "654321", now: date(2026, 12, 1))
        guard case .skipped(let message) = offload.first?.outcome else { return XCTFail("다른 비밀번호로 지우면 안 된다") }
        XCTAssertTrue(message.contains("비밀번호"), message)
        let kept = try await allReadings(harness.store)
        XCTAssertEqual(kept.count, 20)

        try await harness.store.upsertReadings(readings(day: date(2026, 10, 2), count: 5, startIndex: 90))
        let results = try await backupEngine.backupAllMonths(password: "654321", now: date(2026, 10, 19))
        XCTAssertEqual(results.map(\.scope.key), ["2026-09", "2026-10", "settings"])
        guard case .failed = results[0].outcome else { return XCTFail("실패한 달은 .failed로 모은다: \(results[0].outcome)") }
        XCTAssertEqual(results[1].outcome, .written)
        XCTAssertEqual(results[2].outcome, .skippedNoData)
        XCTAssertEqual(try fileBytes(url), original)
    }

    // A4: 작업은 서로 겹치지 않는다.
    private final class OperationLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ item: String) { lock.withLock { items.append(item) } }
        var events: [String] { lock.withLock { items } }
    }

    private struct SlowDestination: TaptionBackupDestination {
        let base: TaptionLocalFolderBackupDestination
        func list() async throws -> [TaptionBackupFileInfo] { try await base.list() }
        func fetch(name: String) async throws -> URL {
            try await Task.sleep(nanoseconds: 60_000_000)
            return try await base.fetch(name: name)
        }
        func replace(name: String, with localFile: URL) async throws { try await base.replace(name: name, with: localFile) }
        func remove(name: String) async throws {
            try await Task.sleep(nanoseconds: 30_000_000)
            try await base.remove(name: name)
        }
    }

    func testEngineOperationsAreSerializedAgainstActorReentrancy() async throws {
        let harness = try makeHarness()
        let september = TaptionBackupMonth(year: 2026, month: 9)
        try await harness.store.upsertReadings(readings(day: date(2026, 9, 12), count: 20))
        let log = OperationLog()
        var configuration = fastConfiguration
        configuration.temporaryDirectory = harness.temporaryDirectory
        configuration.operationHook = { name, started in log.add((started ? "+" : "-") + name) }
        let backupEngine = TaptionBackupEngine(
            store: harness.store, destination: SlowDestination(base: harness.destination),
            calendar: calendar, configuration: configuration
        )
        _ = try await backupEngine.backup(month: september, password: password, now: date(2026, 10, 2))
        async let offload = backupEngine.offloadSealedMonths(password: password, now: date(2026, 12, 1))
        async let deletion = backupEngine.deleteAllBackups()
        async let again = backupEngine.backup(month: september, password: password, now: date(2026, 10, 3))
        async let restoration = backupEngine.restore(month: september, password: password)
        _ = try? await (offload, deletion, again, restoration)

        let events = log.events
        XCTAssertGreaterThanOrEqual(events.count, 10)
        for index in stride(from: 0, to: events.count - 1, by: 2) {
            XCTAssertTrue(events[index].hasPrefix("+"), "\(events)")
            XCTAssertEqual(events[index + 1], "-" + events[index].dropFirst(), "작업이 겹쳤다: \(events)")
        }
    }

    // A6: 달이 끝난 뒤에도 끝나지 않는 긴 기록은 오프로드에서 남는다.
    func testOffloadKeepsRecordsThatEndAfterTheMonthBoundary() async throws {
        let harness = try makeHarness()
        let september = TaptionBackupMonth(year: 2026, month: 9)
        try await harness.store.upsertReadings(readings(day: date(2026, 9, 12), count: 10))
        let long = TaptionStoreRecord(
            id: "long", kind: "memo", start: date(2026, 9, 30, 20), end: date(2026, 10, 3, 9),
            updatedAt: Date(timeIntervalSince1970: 1_790_000_000), origin: .user, body: "{\"trip\":true}"
        )
        try await harness.store.upsertRecords([long, record("short", start: date(2026, 9, 5), ord: 1)])
        let backupEngine = engine(harness)
        _ = try await backupEngine.backup(month: september, password: password, now: date(2026, 10, 2))
        let results = try await backupEngine.offloadSealedMonths(password: password, now: date(2026, 11, 3))
        XCTAssertEqual(results.first?.outcome, .sealed(readings: 10, records: 1), "짧은 기록 1건만 지운다")
        let remaining = try await harness.store.records(kind: "memo").map(\.id)
        XCTAssertEqual(remaining, ["long"])
        // 남은 긴 기록은 파일에도 그대로 있어 다음 백업에서 합집합이 줄지 않는다.
        let next = try await backupEngine.backup(month: september, password: password, now: date(2026, 11, 4))
        XCTAssertEqual(next.header?.recordCount, 2)
        XCTAssertEqual(next.header?.readingCount, 10)
    }

    // A7: 전체 삭제는 오래된 백업을 무효화하고, 종류 삭제는 삭제 표시로 남는다.
    func testWholeDeletionInvalidatesOldBackupsAndPerKindDeletionLeavesTombstones() async throws {
        let harness = try makeHarness()
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        try await harness.store.upsertRecords([
            record("c1", kind: "category", start: nil, ord: 0, updated: base),
            record("h1", kind: "header", start: nil, ord: 0, updated: base),
        ])
        let backupEngine = engine(harness)
        let first = try await backupEngine.backupSettings(password: password, now: date(2026, 10, 19))
        XCTAssertEqual(first.outcome, .written)

        // 종류 삭제: 하드 삭제가 아니라 삭제 표시라서 다음 백업이 담고, 다른 기기 복원에서도 부활하지 않는다.
        try await harness.store.deleteRecords(kinds: ["category"])
        let categories = try await harness.store.records(kind: "category")
        XCTAssertTrue(categories.isEmpty)
        let afterKind = try await backupEngine.backupSettings(password: password, now: date(2026, 10, 20))
        XCTAssertEqual(afterKind.outcome, .written, afterKind.message)
        XCTAssertEqual(afterKind.header?.recordCount, 2)
        let other = try makeHarness()
        try await other.store.upsertRecords([record("c1", kind: "category", start: nil, ord: 0, updated: base)])
        _ = try await engine(other, destination: harness.destination).restoreSettings(password: password)
        let otherCategories = try await other.store.records(kind: "category")
        XCTAssertTrue(otherCategories.isEmpty, "삭제 표시가 오래된 로컬 행에 적용된다")

        // 전체 삭제: 이전 백업은 합치지도 덮어쓰지도 않고 알린다. 백업 전체 삭제 뒤에는 다시 쓴다.
        try await harness.store.deleteAllRecords()
        try await harness.store.upsertRecords([record("new", kind: "category", start: nil, ord: 0, updated: base.addingTimeInterval(9_000))])
        let url = harness.backupDirectory.appendingPathComponent(TaptionBackupScope.settingsFileName)
        let before = try fileBytes(url)
        let stale = try await backupEngine.backupSettings(password: password, now: date(2026, 10, 21))
        XCTAssertEqual(stale.outcome, .keptExisting(.staleAfterDataWipe))
        XCTAssertEqual(try fileBytes(url), before)
        let local = try await harness.store.records(kind: "category").map(\.id)
        XCTAssertEqual(local, ["new"], "오래된 백업의 행이 되살아나면 안 된다")
        _ = try await backupEngine.deleteAllBackups()
        let fresh = try await backupEngine.backupSettings(password: password, now: date(2026, 10, 22))
        XCTAssertEqual(fresh.outcome, .written)
        XCTAssertEqual(fresh.header?.recordCount, 1)
    }

    // A9: 수정 시각은 줄어들지 않고, 병합 순서는 결정적이다.
    func testRecordUpdateTimeNeverDecreasesAndMergeOrderIsDeterministic() async throws {
        let harness = try makeHarness()
        let newer = Date(timeIntervalSince1970: 2_000)
        let older = Date(timeIntervalSince1970: 1_000)
        try await harness.store.upsertRecords([record("a", start: date(2026, 10, 1), updated: newer, body: "{\"v\":1}")])
        try await harness.store.upsertRecords([record("a", start: date(2026, 10, 1), updated: older, body: "{\"v\":2}")])
        let stored = try await harness.store.recordsForBackup(from: 0, to: .greatestFiniteMagnitude)
        XCTAssertEqual(stored.first?.updatedAt, newer)
        XCTAssertEqual(stored.first?.body, "{\"v\":2}")

        func existing(_ record: TaptionStoreRecord) -> TaptionRecordMerge.Existing {
            .init(updated: record.updatedAt.timeIntervalSince1970, isDeleted: record.isDeleted, body: record.body)
        }
        let live = record("x", start: nil, updated: newer, body: "{\"a\":1}")
        let tomb = record("x", start: nil, updated: newer, deleted: true, body: "{}")
        let later = record("x", start: nil, updated: newer.addingTimeInterval(1), body: "{\"b\":1}")
        XCTAssertTrue(TaptionRecordMerge.incomingWins(existing: existing(live), incoming: tomb), "같은 시각이면 삭제 표시가 이긴다")
        XCTAssertFalse(TaptionRecordMerge.incomingWins(existing: existing(tomb), incoming: live))
        XCTAssertTrue(TaptionRecordMerge.incomingWins(existing: existing(live), incoming: later))
        XCTAssertFalse(TaptionRecordMerge.incomingWins(existing: existing(later), incoming: live))
        let left = record("x", start: nil, updated: newer, body: "{\"p\":1}")
        let right = record("x", start: nil, updated: newer, body: "{\"q\":2}")
        let leftWins = TaptionRecordMerge.incomingWins(existing: existing(right), incoming: left)
        let rightWins = TaptionRecordMerge.incomingWins(existing: existing(left), incoming: right)
        XCTAssertNotEqual(leftWins, rightWins, "동점이어도 정확히 한쪽만 이긴다(본문 해시)")
        XCTAssertFalse(TaptionRecordMerge.incomingWins(existing: existing(left), incoming: left))
    }

    // A11: 불교력 같은 달력 설정과 무관하게 그레고리력·고정 시간대로 달을 나눈다.
    func testCalendarIsGregorianWithAFixedStoredTimeZone() async throws {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let harness = try makeHarness()
        try await harness.store.upsertReadings([reading(date(2026, 10, 31, 23, 30), 1)])
        var configuration = fastConfiguration
        configuration.temporaryDirectory = harness.temporaryDirectory
        let buddhistEngine = TaptionBackupEngine(
            store: harness.store, destination: harness.destination, calendar: buddhist, configuration: configuration
        )
        let results = try await buddhistEngine.backupAllMonths(password: password, now: date(2026, 11, 2))
        XCTAssertEqual(results.map(\.scope.key), ["2026-10", "settings"], "불교력 2569-10이 아니어야 한다")
        XCTAssertEqual(results.first?.header?.timeZone, "Asia/Seoul")
        let storedZone = try await harness.store.meta(TaptionBackupEngine.timeZoneKey)
        XCTAssertEqual(storedZone, "Asia/Seoul")
        let names = try await harness.destination.list().map(\.name)
        XCTAssertEqual(names, ["2026-10.taptionbackup"])

        // 저장된 시간대가 있으면 다른 후보 시간대가 와도 저장된 값을 쓴다.
        let other = try makeHarness()
        try await other.store.setMeta(TaptionBackupEngine.timeZoneKey, "Asia/Seoul")
        try await other.store.upsertReadings([reading(date(2026, 11, 1, 0, 30), 2)])
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let laEngine = TaptionBackupEngine(
            store: other.store, destination: other.destination, calendar: losAngeles, configuration: configuration
        )
        _ = try await laEngine.backupAllMonths(password: password, now: date(2026, 11, 5))
        let otherNames = try await other.destination.list().map(\.name)
        XCTAssertEqual(otherNames, ["2026-11.taptionbackup"], "서울 기준 11월 1일 00:30은 11월 파일이다")
    }

    // B3/D2: 같은 내용이어도 손상된 파일은 그대로 두지 않고, 로컬이 넘을 때 다시 쓴다.
    func testUnchangedDataWithCorruptedExistingFileIsRewritten() async throws {
        let harness = try makeHarness()
        let month = TaptionBackupMonth(year: 2026, month: 10)
        try await harness.store.upsertReadings(readings(day: date(2026, 10, 3), count: 40))
        let backupEngine = engine(harness)
        _ = try await backupEngine.backup(month: month, password: password, now: date(2026, 10, 5))
        let url = harness.backupDirectory.appendingPathComponent(month.fileName)
        var damaged = try fileBytes(url)
        damaged[Int(TaptionBackupLayout.bodyOffset) + 60] ^= 0x01
        try damaged.write(to: url)

        let result = try await backupEngine.backup(month: month, password: password, now: date(2026, 10, 6))
        XCTAssertEqual(result.outcome, .written, ".unchanged로 손상을 못 본 척하면 안 된다")
        let header = try TaptionBackupFileReader.open(at: url, scopeKey: month.key, password: password, minimumIterations: 1).header
        try TaptionBackupFileReader.verifyBodyChecksum(at: url, header: header)
        XCTAssertEqual(header.readingCount, 40)
        let again = try await backupEngine.backup(month: month, password: password, now: date(2026, 10, 7))
        XCTAssertEqual(again.outcome, .unchanged)
    }

    // C1/C7: 업로드 임시 파일은 대상 폴더 밖에 만들고, 이전 실행이 남긴 것은 시작할 때 치운다.
    private final class StagingProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var stagingParent: String?
        private var folderNames: [String] = []
        func record(parent: String, names: [String]) { lock.withLock { stagingParent = parent; folderNames = names } }
        var observed: (parent: String?, names: [String]) { lock.withLock { (stagingParent, folderNames) } }
    }

    func testUploadStagingLivesOutsideTheDestinationFolderAndStaleLeftoversAreRemoved() async throws {
        let harness = try makeHarness()
        let probe = StagingProbe()
        let backups = harness.backupDirectory
        let destination = TaptionLocalFolderBackupDestination(directory: backups, beforeCommit: { staging in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? []
            probe.record(parent: staging.deletingLastPathComponent().standardizedFileURL.path, names: names)
        })
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let old = backups.appendingPathComponent(".2026-08.taptionbackup.uploading-OLD")
        let recent = backups.appendingPathComponent(".2026-08.taptionbackup.uploading-RECENT")
        try Data("x".utf8).write(to: old)
        try Data("y".utf8).write(to: recent)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7_200)], ofItemAtPath: old.path)

        try await harness.store.upsertReadings(readings(day: date(2026, 10, 3), count: 5))
        let result = try await engine(harness, destination: destination)
            .backup(month: TaptionBackupMonth(year: 2026, month: 10), password: password, now: date(2026, 10, 5))
        XCTAssertEqual(result.outcome, .written)
        let observed = probe.observed
        XCTAssertNotNil(observed.parent)
        XCTAssertNotEqual(observed.parent, backups.standardizedFileURL.path, "임시 파일은 대상 폴더 밖이다")
        XCTAssertFalse(observed.names.contains { $0.contains("2026-10") && $0.contains("uploading") }, "\(observed.names)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "오래된 업로드 임시 파일은 치운다")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path), "최근 것은 다른 기기가 올리는 중일 수 있어 둔다")
    }

    // B6/B7: KDF 반복 횟수와 프레임 크기 상한.
    func testIterationBoundsAndFrameSizeLimits() async throws {
        let salt = Data(repeating: 3, count: 16)
        XCTAssertThrowsError(try TaptionBackupCrypto.deriveKey(password: "123456", salt: salt, iterations: 99_999))
        XCTAssertThrowsError(try TaptionBackupCrypto.deriveKey(password: "123456", salt: salt, iterations: 5_000_001))
        XCTAssertNoThrow(try TaptionBackupCrypto.deriveKey(password: "123456", salt: salt, iterations: 100_000))

        // 약한 반복 횟수로는 파일을 만들 수 없다(기본 하한).
        let harness = try makeHarness()
        try await harness.store.upsertReadings(readings(day: date(2026, 10, 3), count: 5))
        var weak = TaptionBackupEngine.Configuration()
        weak.iterations = 1_000
        weak.temporaryDirectory = harness.temporaryDirectory
        let weakEngine = TaptionBackupEngine(store: harness.store, destination: harness.destination, calendar: calendar, configuration: weak)
        let month = TaptionBackupMonth(year: 2026, month: 10)
        do {
            _ = try await weakEngine.backup(month: month, password: password, now: date(2026, 10, 5))
            XCTFail("하한 미만의 반복 횟수는 거부해야 한다")
        } catch {
            XCTAssertEqual(error as? TaptionBackupError, .malformed("kdf parameters"))
        }

        // 프레임이 헤더 chunkBytes의 몇 배를 넘으면 큰 메모리를 잡기 전에 거부한다.
        let big = try makeHarness()
        try await big.store.upsertReadings(readings(day: date(2026, 10, 3), count: 2_500))
        _ = try await engine(big).backup(month: month, password: password, now: date(2026, 10, 5))
        let url = big.backupDirectory.appendingPathComponent(month.fileName)
        let original = try fileBytes(url)
        let restorer = TaptionBackupEngine(
            store: try makeHarness().store, destination: big.destination, calendar: calendar, configuration: fastConfiguration
        )
        try rewriteHeader(at: url) { $0.chunkBytes = 1_024 }
        do {
            _ = try await restorer.restore(month: month, password: password)
            XCTFail()
        } catch {
            XCTAssertEqual(error as? TaptionBackupError, .malformed("frame size"))
        }
        try original.write(to: url)
        try rewriteHeader(at: url) { $0.chunkBytes = 1 << 30 }
        do {
            _ = try await restorer.restore(month: month, password: password)
            XCTFail()
        } catch {
            XCTAssertEqual(error as? TaptionBackupError, .malformed("header sizes"))
        }
    }

    // D1: 비정상으로 먼 시각이 있어도 월 순회가 폭주하지 않는다.
    func testFarAwayTimestampsDoNotMakeMonthIterationRunAway() async throws {
        let harness = try makeHarness()
        try await harness.store.upsertReadings(
            [SensorReading(timestamp: .distantPast, motion: .stationary)] + readings(day: date(2026, 10, 3), count: 5)
        )
        try await harness.store.upsertRecords([
            record("far", start: .distantFuture, ord: 0), record("near", start: date(2026, 10, 4), ord: 1),
        ])
        let started = Date()
        let results = try await engine(harness).backupAllMonths(password: password, now: date(2026, 10, 19))
        XCTAssertLessThan(Date().timeIntervalSince(started), 30)
        XCTAssertEqual(results.map(\.scope.key), ["2026-10", "settings"])
        let offload = try await engine(harness).offloadSealedMonths(password: password, now: date(2027, 1, 1))
        XCTAssertLessThanOrEqual(offload.count, 1)
    }

    // 암호화된 헤더: 목록은 비밀번호 없이는 이름·크기만, 비밀번호로는 요약을 준다.
    func testListingNeedsThePasswordForMetadata() async throws {
        let harness = try makeHarness()
        let month = TaptionBackupMonth(year: 2026, month: 10)
        try await harness.store.upsertReadings(readings(day: date(2026, 10, 3), count: 12))
        let backupEngine = engine(harness)
        _ = try await backupEngine.backup(month: month, password: password, now: date(2026, 10, 5))
        let locked = try await backupEngine.listBackups()
        XCTAssertEqual(locked.map(\.state), [.locked])
        XCTAssertNil(locked[0].summary)
        XCTAssertGreaterThan(locked[0].info.size, 0)
        let opened = try await backupEngine.listBackups(password: password)
        XCTAssertEqual(opened[0].state, .ok)
        XCTAssertEqual(opened[0].summary?.rowCount, 12)
        XCTAssertEqual(opened[0].summary?.month, "2026-10")
        let wrong = try await backupEngine.listBackups(password: "000000")
        XCTAssertEqual(wrong[0].state, .wrongPassword)
        XCTAssertNil(wrong[0].header)
    }

    // MARK: 목적지 규약(로컬 폴더와 iCloud 흉내가 같은 규약을 지킨다)

    private final class FakeUbiquity: TaptionUbiquityFileSystem, @unchecked Sendable {
        let container: URL
        private let lock = NSLock()
        private var stash: [String: Data] = [:]
        private var polls: [String: Int] = [:]
        private(set) var started: [String] = []
        var conflicts = Set<String>()
        var materializeAfterPolls = 2
        var neverMaterialize = false
        var copies = 0

        init(container: URL) { self.container = container }

        func evict(name: String, in folder: URL) throws {
            let url = folder.appendingPathComponent(name)
            lock.withLock { stash[name] = try? Data(contentsOf: url) }
            try FileManager.default.removeItem(at: url)
            try Data().write(to: folder.appendingPathComponent(".\(name).icloud"))
        }

        func containerURL(identifier: String?) async -> URL? { container }

        func state(of url: URL) -> TaptionUbiquityItemState {
            lock.withLock {
                if FileManager.default.fileExists(atPath: url.path) { return .current }
                let name = url.lastPathComponent
                guard let data = stash[name] else { return .missing }
                guard started.contains(name), !neverMaterialize else { return .notDownloaded }
                polls[name, default: 0] += 1
                guard polls[name]! >= materializeAfterPolls else { return .notDownloaded }
                try? data.write(to: url)
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent().appendingPathComponent(".\(name).icloud"))
                stash[name] = nil
                return .current
            }
        }

        func startDownloading(_ url: URL) throws { lock.withLock { started.append(url.lastPathComponent) } }
        func hasUnresolvedConflicts(at url: URL) -> Bool { lock.withLock { conflicts.contains(url.lastPathComponent) } }

        func coordinatedCopy(from url: URL, to destination: URL) throws {
            lock.withLock { copies += 1 }
            try FileManager.default.copyItem(at: url, to: destination)
        }

        func coordinatedReadPrefix(of url: URL, length: Int) throws -> Data {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return try handle.read(upToCount: length) ?? Data()
        }

        func coordinatedReplace(target: URL, with staging: URL) throws {
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: target)
            }
        }

        func coordinatedRemove(_ url: URL) throws { try FileManager.default.removeItem(at: url) }
    }

    private func makeICloudDestination(
        fake: FakeUbiquity, timeout: TimeInterval = 5
    ) throws -> (destination: TaptionICloudDriveBackupDestination, folder: URL, fetchDirectory: URL) {
        let fetchDirectory = try makeDirectory()
        let staging = try makeDirectory()
        let destination = TaptionICloudDriveBackupDestination(
            downloadTimeout: timeout, pollInterval: 0.01, fileSystem: fake,
            temporaryDirectory: fetchDirectory, stagingDirectory: staging
        )
        let folder = fake.container.appendingPathComponent("Documents/TaptionBackup", isDirectory: true)
        return (destination, folder, fetchDirectory)
    }

    /// 어떤 목적지든 같은 규약: 백업→목록→변경 없음→복원→전체 삭제.
    private func exerciseDestinationContract(_ destination: any TaptionBackupDestination) async throws {
        let source = try makeHarness()
        let month = TaptionBackupMonth(year: 2026, month: 10)
        let sample = readings(day: date(2026, 10, 3), count: 25)
        try await source.store.upsertReadings(sample)
        let backupEngine = engine(source, destination: destination)
        let first = try await backupEngine.backup(month: month, password: password, now: date(2026, 10, 5))
        XCTAssertEqual(first.outcome, .written)
        let names = try await destination.list().map(\.name)
        XCTAssertEqual(names, [month.fileName])
        let prefix = try await destination.fetchPrefix(name: month.fileName, length: TaptionBackupFileReader.headerPrefixBytes)
        XCTAssertEqual(prefix.count, TaptionBackupFileReader.headerPrefixBytes)
        XCTAssertNoThrow(try TaptionBackupFileReader.parsePublicHeader(prefix))
        let second = try await backupEngine.backup(month: month, password: password, now: date(2026, 10, 6))
        XCTAssertEqual(second.outcome, .unchanged)

        let target = try makeHarness()
        let summary = try await engine(target, destination: destination).restore(month: month, password: password)
        XCTAssertEqual(summary.newReadings, 25)
        let restored = try await allReadings(target.store)
        XCTAssertEqual(Set(restored), Set(sample))
        let deletion = try await backupEngine.deleteAllBackups()
        XCTAssertEqual(deletion.removed, [month.fileName])
        XCTAssertEqual(deletion.remaining, [])
    }

    func testLocalFolderDestinationFollowsTheDestinationContract() async throws {
        let harness = try makeHarness()
        try await exerciseDestinationContract(harness.destination)
    }

    func testICloudDestinationLogicFollowsTheSameContractOnALocalFolder() async throws {
        let fake = FakeUbiquity(container: try makeDirectory())
        let made = try makeICloudDestination(fake: fake)
        try await exerciseDestinationContract(made.destination)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: made.fetchDirectory.path)
        XCTAssertEqual(leftovers, [], "내려받아 만든 임시 사본은 모두 돌려줬다")
        let staged = try FileManager.default.contentsOfDirectory(atPath: made.folder.path)
        XCTAssertFalse(staged.contains { $0.contains("uploading") })
    }

    func testICloudPlaceholderIsListedDownloadedWaitedForAndReadFromACoordinatedCopy() async throws {
        let fake = FakeUbiquity(container: try makeDirectory())
        let made = try makeICloudDestination(fake: fake)
        let source = try makeHarness()
        let month = TaptionBackupMonth(year: 2026, month: 10)
        let sample = readings(day: date(2026, 10, 3), count: 15)
        try await source.store.upsertReadings(sample)
        _ = try await engine(source, destination: made.destination).backup(month: month, password: password, now: date(2026, 10, 5))
        try fake.evict(name: month.fileName, in: made.folder)

        let listed = try await made.destination.list()
        XCTAssertEqual(listed.map(\.name), [month.fileName], ".icloud 자리표시자도 실제 이름으로 목록에 보인다")
        XCTAssertEqual(TaptionICloudDriveBackupDestination.realName(fromPlaceholder: ".2026-10.taptionbackup.icloud"), month.fileName)
        XCTAssertNil(TaptionICloudDriveBackupDestination.realName(fromPlaceholder: ".notes.txt.icloud"))

        let target = try makeHarness()
        let summary = try await engine(target, destination: made.destination).restore(month: month, password: password)
        XCTAssertEqual(summary.newReadings, 15)
        XCTAssertFalse(fake.started.isEmpty, "다운로드를 요청해야 한다")
        XCTAssertGreaterThan(fake.copies, 0, "조정된 읽기로 임시 사본을 만든다")
    }

    func testICloudDownloadTimeoutAndConflictsAreRefusedWithoutTouchingTheFile() async throws {
        let fake = FakeUbiquity(container: try makeDirectory())
        fake.neverMaterialize = true
        let made = try makeICloudDestination(fake: fake, timeout: 0.15)
        let source = try makeHarness()
        let month = TaptionBackupMonth(year: 2026, month: 10)
        try await source.store.upsertReadings(readings(day: date(2026, 10, 3), count: 8))
        let backupEngine = engine(source, destination: made.destination)
        _ = try await backupEngine.backup(month: month, password: password, now: date(2026, 10, 5))
        try fake.evict(name: month.fileName, in: made.folder)

        do {
            _ = try await made.destination.fetch(name: month.fileName)
            XCTFail("끝내 내려받지 못하면 시간 초과여야 한다")
        } catch {
            XCTAssertEqual(error as? TaptionBackupError, .destinationUnavailable("download timed out: \(month.fileName)"))
        }

        // 충돌 버전: 읽기·쓰기 모두 거부하고 파일은 그대로 둔다.
        fake.neverMaterialize = false
        fake.materializeAfterPolls = 1
        _ = try await made.destination.fetch(name: month.fileName)
        let url = made.folder.appendingPathComponent(month.fileName)
        let before = try fileBytes(url)
        fake.conflicts = [month.fileName]
        do {
            _ = try await made.destination.fetch(name: month.fileName)
            XCTFail()
        } catch {
            XCTAssertEqual(error as? TaptionBackupError, .conflictingVersions(month.fileName))
        }
        try await source.store.upsertReadings(readings(day: date(2026, 10, 9), count: 3, startIndex: 500))
        do {
            _ = try await backupEngine.backup(month: month, password: password, now: date(2026, 10, 6))
            XCTFail("충돌 중인 파일 위에 쓰면 안 된다")
        } catch {
            XCTAssertEqual(error as? TaptionBackupError, .conflictingVersions(month.fileName))
        }
        XCTAssertEqual(try fileBytes(url), before)
    }

    // MARK: 변조 도우미

    /// 헤더 블록을 열어 고친 뒤 같은 키로 다시 봉인한다(체크섬까지 고쳐 놓은 공격을 흉내 낸다).
    private func rewriteHeader(at url: URL, _ change: (inout TaptionBackupHeader) throws -> Void) throws {
        let publicHeader = try TaptionBackupFileReader.readPublicHeader(at: url)
        let opened = try TaptionBackupFileReader.open(
            public: publicHeader, scopeKey: "2026-10", password: password, minimumIterations: 1
        )
        var header = opened.header
        try change(&header)
        let salt = try XCTUnwrap(Data(base64Encoded: header.kdf.salt))
        let region = try TaptionBackupHeaderCoding.encode(header, key: opened.key, salt: salt)
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
