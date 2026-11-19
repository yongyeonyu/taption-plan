import Foundation
import Synchronization
import Testing
@testable import SeasonPackKit

/// 가짜 내려받기 엔진: 호출마다 미리 정한 결과를 돌려주고, 받은 `resumeData`를 기록한다.
final class FakeEngine: SeasonPackDownloadEngine {
    enum Step: Sendable {
        case finish(Data)                 // 완성 파일을 놓는다
        case interrupt(Data?)             // 끊김(이어받기 데이터)
        case fail(String)
    }
    private let state: Mutex<(steps: [Step], resumes: [Data?], urls: [URL], cellular: [Bool])>
    init(_ steps: [Step]) { state = Mutex((steps, [], [], [])) }
    var resumes: [Data?] { state.withLock { $0.resumes } }
    var calls: Int { state.withLock { $0.resumes.count } }
    var cellularFlags: [Bool] { state.withLock { $0.cellular } }
    var urls: [URL] { state.withLock { $0.urls } }

    func download(from url: URL, resumeData: Data?, allowsCellular: Bool, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async -> SeasonPackEngineOutcome {
        let step = state.withLock { state -> Step in
            state.resumes.append(resumeData); state.urls.append(url); state.cellular.append(allowsCellular)
            return state.steps.isEmpty ? .fail("no-step") : state.steps.removeFirst()
        }
        switch step {
        case .finish(let data):
            progress(Int64(data.count), Int64(data.count))
            try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: destination)
            return .finished
        case .interrupt(let resume): return .interrupted(resumeData: resume)
        case .fail(let reason): return .failed(reason)
        }
    }
}

final class StatusLog: Sendable {
    private let items = Mutex<[SeasonPackDownloadStatus]>([])
    func add(_ status: SeasonPackDownloadStatus) { items.withLock { $0.append(status) } }
    var all: [SeasonPackDownloadStatus] { items.withLock { $0 } }
}

struct ArchiveTests {
    private func built(files: [String: Data]? = nil) throws -> (data: Data, manifest: Data) {
        let pack = Fixture.pack(id: "christmas", version: 2)
        return (try SeasonPackArchive.encode(manifestData: pack.manifest, files: files ?? pack.files), pack.manifest)
    }

    private func write(_ data: Data) -> URL {
        let url = Fixture.tempDirectory().appendingPathComponent("p.bpack")
        try? data.write(to: url)
        return url
    }

    @Test func roundTripKeepsManifestAndFiles() throws {
        let (data, manifest) = try built()
        let unpacked = try SeasonPackArchive.decode(from: write(data))
        #expect(unpacked.manifestData == manifest)
        #expect(unpacked.files == ["a.png": Data("png-bytes".utf8)])
    }

    @Test func rejectsTruncatedTrailingAndForeignFiles() throws {
        let (data, _) = try built()
        #expect(throws: SeasonPackArchiveError.truncated) { try SeasonPackArchive.decode(from: write(data.dropLast(3))) }
        #expect(throws: SeasonPackArchiveError.trailingBytes) { try SeasonPackArchive.decode(from: write(data + Data([0]))) }
        var wrongMagic = data; wrongMagic[0] = 0x58
        #expect(throws: SeasonPackArchiveError.badMagic) { try SeasonPackArchive.decode(from: write(wrongMagic)) }
        var wrongVersion = data; wrongVersion[4] = 9
        #expect(throws: SeasonPackArchiveError.unsupportedVersion) { try SeasonPackArchive.decode(from: write(wrongVersion)) }
        #expect(throws: SeasonPackArchiveError.truncated) { try SeasonPackArchive.decode(from: write(Data("BS".utf8))) }
    }

    @Test func pathEscapeDuplicatesAndInflatedSizesAreRefused() throws {
        func archive(assets: [[String: Any]], payload: Data) -> Data {
            let root: [String: Any] = ["format": "bokki-season-pack", "schema": 1, "id": "x", "version": 1, "event": ["id": "x", "windows": []], "assets": assets]
            let manifest = try! JSONSerialization.data(withJSONObject: root)
            var out = SeasonPackArchive.magic
            out.append(SeasonPackArchive.formatVersion)
            withUnsafeBytes(of: UInt32(manifest.count).bigEndian) { out.append(contentsOf: $0) }
            out.append(manifest); out.append(payload)
            return out
        }
        func asset(_ path: String, _ bytes: Int) -> [String: Any] { ["id": "i", "path": path, "sha256": String(repeating: "0", count: 64), "bytes": bytes, "kind": "image"] }
        #expect(throws: SeasonPackArchiveError.badPath("../evil.png")) { try SeasonPackArchive.decode(from: write(archive(assets: [asset("../evil.png", 1)], payload: Data([1])))) }
        #expect(throws: SeasonPackArchiveError.badPath("/abs.png")) { try SeasonPackArchive.decode(from: write(archive(assets: [asset("/abs.png", 1)], payload: Data([1])))) }
        #expect(throws: SeasonPackArchiveError.duplicatePath("a.png")) { try SeasonPackArchive.decode(from: write(archive(assets: [asset("a.png", 1), asset("a.png", 1)], payload: Data([1, 2])))) }
        // 선언한 크기가 한도를 넘으면 읽기 전에 거절(압축이 없어 풀면서 부풀 수도 없다).
        #expect(throws: SeasonPackArchiveError.tooLarge) { try SeasonPackArchive.decode(from: write(archive(assets: [asset("a.png", SeasonPackLimits.packBytes + 1)], payload: Data()))) }
        let many = (0...SeasonPackLimits.filesPerPack).map { asset("f\($0).png", 0) }
        #expect(throws: SeasonPackArchiveError.tooManyFiles) { try SeasonPackArchive.decode(from: write(archive(assets: many, payload: Data()))) }
    }

    @Test func encodeRefusesFilesThatDisagreeWithTheManifest() throws {
        let pack = Fixture.pack()
        #expect(throws: SeasonPackArchiveError.sizeMismatch("a.png")) { try SeasonPackArchive.encode(manifestData: pack.manifest, files: ["a.png": Data("x".utf8)]) }
        #expect(throws: SeasonPackArchiveError.badManifest) { try SeasonPackArchive.encode(manifestData: Data("nope".utf8), files: [:]) }
    }
}

struct DownloaderTests {
    private func entry(for data: Data, id: String = "christmas", version: Int = 2) -> SeasonPackIndex.Entry {
        SeasonPackIndex.Entry(id: id, version: version, archive: .init(key: "packs/season/\(id)/\(version)/\(id)-\(version).bpack", bytes: data.count, sha256: SeasonPackValidation.sha256Hex(data)))
    }

    private func downloader(_ directory: URL, engine: FakeEngine, log: StatusLog = StatusLog(), free: Int64? = 1 << 40, large: Bool = true) -> SeasonPackDownloader {
        SeasonPackDownloader(directory: directory, engine: engine, urlForKey: { URL(string: "https://relay.example.invalid/public/assets/\($0)") },
                             freeBytes: { free }, allowsLargeDownload: { large }, onStatus: { log.add($0) })
    }

    private let payload = Data((0..<4096).map { UInt8($0 % 251) })

    @Test func completeDownloadIsVerifiedAndReady() async throws {
        let dir = Fixture.tempDirectory(), engine = FakeEngine([.finish(payload)]), log = StatusLog()
        let result = await downloader(dir, engine: engine, log: log).ensure(entry(for: payload))
        guard case .ready(let url) = result else { Issue.record("not ready: \(result)"); return }
        #expect(try Data(contentsOf: url) == payload)
        #expect(engine.urls.first?.absoluteString.hasSuffix("/christmas-2.bpack") == true)
        #expect(log.all.contains(.verifying))
    }

    @Test func interruptedDownloadKeepsResumeDataOnDiskAndAFreshProcessResumesFromIt() async throws {
        let dir = Fixture.tempDirectory(), item = entry(for: payload)
        let first = FakeEngine([.interrupt(Data("RESUME-1".utf8))])
        #expect(await downloader(dir, engine: first).ensure(item) == .interrupted)
        #expect(first.resumes == [nil])
        // 앱이 죽었다가 다시 뜬 것: 새 인스턴스가 같은 폴더의 resumeData로 이어 받는다.
        let second = FakeEngine([.finish(payload)])
        let revived = downloader(dir, engine: second)
        #expect(revived.hasPending)
        let result = await revived.ensure(item)
        #expect(second.resumes == [Data("RESUME-1".utf8)])
        guard case .ready = result else { Issue.record("not ready"); return }
    }

    @Test func interruptedAgainWithoutNewDataDropsTheStaleResumeData() async {
        let dir = Fixture.tempDirectory(), item = entry(for: payload)
        _ = await downloader(dir, engine: FakeEngine([.interrupt(Data("R".utf8))])).ensure(item)
        let engine = FakeEngine([.interrupt(nil), .finish(payload)])
        #expect(await downloader(dir, engine: engine).ensure(item) == .interrupted)
        _ = await downloader(dir, engine: engine).ensure(item)
        #expect(engine.resumes == [Data("R".utf8), nil]) // 쓸 수 없는 resumeData는 남기지 않아 처음부터
    }

    @Test func serverThatCannotResumeRestartsFromTheBeginningOnce() async {
        let dir = Fixture.tempDirectory(), item = entry(for: payload)
        _ = await downloader(dir, engine: FakeEngine([.interrupt(Data("OLD".utf8))])).ensure(item)
        let engine = FakeEngine([.fail("etag-changed"), .finish(payload)])
        let result = await downloader(dir, engine: engine).ensure(item)
        #expect(engine.resumes == [Data("OLD".utf8), nil]) // 이어받기 실패 → 처음부터
        guard case .ready = result else { Issue.record("not ready"); return }
        // 처음부터도 실패하면 더 되풀이하지 않는다.
        let dead = FakeEngine([.fail("404")])
        #expect(await downloader(Fixture.tempDirectory(), engine: dead).ensure(item) == .failed("404"))
        #expect(dead.calls == 1)
    }

    @Test func hashMismatchDiscardsTheFileAndRetriesOnceThenFails() async {
        let dir = Fixture.tempDirectory(), item = entry(for: payload)
        let bad = Data(repeating: 7, count: payload.count)
        let engine = FakeEngine([.finish(bad), .finish(bad)])
        #expect(await downloader(dir, engine: engine).ensure(item) == .failed("hash"))
        #expect(engine.calls == 2)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("christmas-2.bpack").path))
        // 한 번 틀렸다가 두 번째에 맞으면 성공.
        let recover = FakeEngine([.finish(bad), .finish(payload)])
        guard case .ready = await downloader(Fixture.tempDirectory(), engine: recover).ensure(item) else { Issue.record("not recovered"); return }
        #expect(recover.resumes == [nil, nil])
    }

    @Test func changedCatalogValuesDiscardOldPartialState() async {
        let dir = Fixture.tempDirectory(), item = entry(for: payload)
        _ = await downloader(dir, engine: FakeEngine([.interrupt(Data("OLD".utf8))])).ensure(item)
        let other = Data(repeating: 3, count: 2048)
        let engine = FakeEngine([.finish(other)])
        let result = await downloader(dir, engine: engine).ensure(entry(for: other)) // 같은 id·버전, 다른 파일
        #expect(engine.resumes == [nil])
        guard case .ready = result else { Issue.record("not ready"); return }
    }

    @Test func largePackWaitsForWiFiAndLowDiskFailsWithoutDownloading() async {
        let big = Data(repeating: 1, count: SeasonPackLimits.cellularBytes + 5)
        let engine = FakeEngine([.finish(big)])
        let waiting = await downloader(Fixture.tempDirectory(), engine: engine, large: false).ensure(entry(for: big))
        #expect(waiting == .deferred(.waitingForWiFi(bytes: big.count)))
        #expect(engine.calls == 0)
        let low = FakeEngine([.finish(payload)])
        #expect(await downloader(Fixture.tempDirectory(), engine: low, free: 1000).ensure(entry(for: payload)) == .failed("disk"))
        #expect(low.calls == 0)
        // 작은 팩은 셀룰러도 허용한다.
        let small = FakeEngine([.finish(payload)])
        _ = await downloader(Fixture.tempDirectory(), engine: small, large: false).ensure(entry(for: payload))
        #expect(small.cellularFlags == [true])
    }

    @Test func completedFileLeftWhileTheAppWasDeadIsVerifiedWithoutDownloadingAgain() async throws {
        let dir = Fixture.tempDirectory(), item = entry(for: payload)
        _ = await downloader(dir, engine: FakeEngine([.interrupt(nil)])).ensure(item) // meta만 남음
        try payload.write(to: dir.appendingPathComponent("christmas-2.bpack"))           // 백그라운드에서 끝난 파일
        let engine = FakeEngine([])
        guard case .ready = await downloader(dir, engine: engine).ensure(item) else { Issue.record("not ready"); return }
        #expect(engine.calls == 0)
        // 깨진 완성 파일은 버리고 다시 받는다.
        try Data("broken".utf8).write(to: dir.appendingPathComponent("christmas-2.bpack"))
        let again = FakeEngine([.finish(payload)])
        guard case .ready = await downloader(dir, engine: again).ensure(item) else { Issue.record("not ready"); return }
        #expect(again.calls == 1)
    }

    @Test func badCatalogEntriesAreRefused() async {
        let engine = FakeEngine([.finish(payload)])
        var item = entry(for: payload)
        item.archive?.sha256 = "short"
        #expect(await downloader(Fixture.tempDirectory(), engine: engine).ensure(item) == .failed("bad-entry"))
        var escape = entry(for: payload)
        escape.archive?.key = "packs/season/../../secret"
        #expect(await downloader(Fixture.tempDirectory(), engine: engine).ensure(escape) == .failed("bad-entry"))
        #expect(engine.calls == 0)
    }
}

struct ArchiveFetchAndRollbackTests {
    private let when = Fixture.date(2026, 12, 10)

    private func serve(version: Int, files: [String: Data]? = nil, pack: (manifest: Data, files: [String: Data])? = nil) throws -> (archive: Data, transport: FakeTransport, entry: SeasonPackIndex.Entry) {
        let built = pack ?? Fixture.pack(id: "christmas", version: version)
        let archive = try SeasonPackArchive.encode(manifestData: built.manifest, files: files ?? built.files)
        let entry = SeasonPackIndex.Entry(id: "christmas", version: version,
                                          archive: .init(key: "packs/season/christmas/\(version)/christmas-\(version).bpack", bytes: archive.count, sha256: SeasonPackValidation.sha256Hex(archive)),
                                          windows: Fixture.manifest(built.manifest).event.windows)
        let index = SeasonPackIndex(format: SeasonPackIndex.format, schema: 1, packs: [entry])
        let transport = FakeTransport(["packs/season/index.json": SeasonPackReply(status: 200, data: try JSONEncoder().encode(index), etag: "\"e\"", serverDate: when)])
        return (archive, transport, entry)
    }

    private func make(_ transport: FakeTransport, engine: FakeEngine, store: SeasonPackStore, suite: String, now: Date? = nil, log: StatusLog = StatusLog()) -> SeasonPackFetcher {
        let downloader = SeasonPackDownloader(directory: store.root.appendingPathComponent(".downloads"), engine: engine, urlForKey: { URL(string: "https://relay.example.invalid/\($0)") },
                                              freeBytes: { 1 << 40 }, onStatus: { log.add($0) })
        let date = now ?? when
        return SeasonPackFetcher(store: store, transport: transport, defaults: SeasonPackDefaults(suiteName: suite), appBuild: { 1000 }, now: { date },
                                 windows: { Fixture.windows }, downloader: downloader, onStatus: { log.add($0) })
    }

    @Test func downloadsOneFileUnpacksAndInstallsAtomically() async throws {
        let (archive, transport, _) = try serve(version: 2)
        let store = SeasonPackStore(root: Fixture.tempDirectory()), log = StatusLog()
        let result = await make(transport, engine: FakeEngine([.finish(archive)]), store: store, suite: Fixture.suite(), log: log).refresh()
        #expect(result.installed == [SeasonPackRef(id: "christmas", version: 2)])
        #expect(store.hasInstalled(id: "christmas", version: 2))
        #expect(log.all.contains(.installing) && log.all.contains(.installed(id: "christmas", version: 2)))
        #expect(!FileManager.default.fileExists(atPath: store.root.appendingPathComponent(".downloads/christmas-2.bpack").path)) // 설치 뒤 임시 파일은 정리
    }

    @Test func resumesAcrossRelaunchEvenInsideTheCatalogCooldown() async throws {
        let (archive, transport, _) = try serve(version: 2)
        let store = SeasonPackStore(root: Fixture.tempDirectory()), suite = Fixture.suite()
        let first = FakeEngine([.interrupt(Data("RESUME".utf8))])
        let interrupted = await make(transport, engine: first, store: store, suite: suite).refresh()
        #expect(interrupted.installed.isEmpty)
        #expect(!store.hasInstalled(id: "christmas", version: 2))
        // 곧바로 다시 실행(30분 쿨다운 안): 받다 만 것이 있어 건너뛰지 않고 이어 받는다. 카탈로그는 다시 묻지 않는다.
        let second = FakeEngine([.finish(archive)])
        let resumed = await make(transport, engine: second, store: store, suite: suite).refresh()
        #expect(second.resumes == [Data("RESUME".utf8)])
        #expect(resumed.installed == [SeasonPackRef(id: "christmas", version: 2)])
        #expect(transport.requested.filter { $0 == "packs/season/index.json" }.count == 1)
        // 이제 받을 것이 없으면 쿨다운이 지켜진다.
        let third = await make(transport, engine: FakeEngine([]), store: store, suite: suite).refresh()
        #expect(third.skippedReason == "cooldown")
    }

    @Test func corruptArchiveKeepsThePreviousPackAndNeverInstallsHalfAPack() async throws {
        let old = SeasonPackStore(root: Fixture.tempDirectory())
        let v1 = Fixture.pack(id: "christmas", version: 1)
        _ = try old.install(manifestData: v1.manifest, files: v1.files, appBuild: 1000)
        // 해시는 맞는데 내용이 매니페스트와 다른 팩(자산 해시 불일치).
        var tampered = Fixture.pack(id: "christmas", version: 2)
        tampered.files = ["a.png": Data("png-BYTES".utf8)]
        let archive = try SeasonPackArchive.encode(manifestData: tampered.manifest, files: tampered.files)
        let entry = SeasonPackIndex.Entry(id: "christmas", version: 2, archive: .init(key: "packs/season/christmas/2/christmas-2.bpack", bytes: archive.count, sha256: SeasonPackValidation.sha256Hex(archive)))
        let index = SeasonPackIndex(format: SeasonPackIndex.format, schema: 1, packs: [entry])
        let transport = FakeTransport(["packs/season/index.json": SeasonPackReply(status: 200, data: try JSONEncoder().encode(index), serverDate: when)])
        let result = await make(transport, engine: FakeEngine([.finish(archive)]), store: old, suite: Fixture.suite()).refresh()
        #expect(result.installed.isEmpty)
        #expect(old.hasInstalled(id: "christmas", version: 1) && !old.hasInstalled(id: "christmas", version: 2))
        #expect(old.installedPacks(appBuild: 1000).map(\.version) == [1])
        #expect(!FileManager.default.fileExists(atPath: old.root.appendingPathComponent(".downloads/christmas-2.bpack").path)) // 못 쓰는 파일은 버림
    }

    @Test func farOffPacksAreNotDownloadedAndNewerAppRequirementsAreDeferred() async throws {
        let (archive, transport, _) = try serve(version: 2)
        let store = SeasonPackStore(root: Fixture.tempDirectory())
        let engine = FakeEngine([.finish(archive)])
        let far = await make(transport, engine: engine, store: store, suite: Fixture.suite(), now: Fixture.date(2026, 6, 1)).refresh()
        #expect(far.installed.isEmpty && engine.calls == 0)
    }

    @Test func rollbackRemovesTheBadVersionAndTheOlderOneIsUsedAgain() throws {
        let store = SeasonPackStore(root: Fixture.tempDirectory())
        for version in [1, 2] { let p = Fixture.pack(id: "christmas", version: version); _ = try store.install(manifestData: p.manifest, files: p.files, appBuild: 1000) }
        #expect(store.installedPacks(appBuild: 1000).map(\.version).sorted() == [1, 2])
        #expect(store.discard(id: "christmas", version: 2))
        #expect(store.installedPacks(appBuild: 1000).map(\.version) == [1])
        #expect(!store.discard(id: "christmas", version: 2))
        #expect(!store.discard(id: "../x", version: 1))
    }

    @Test func statusLabelsExistInKoreanAndEnglishAndShowProgress() {
        let all: [SeasonPackDownloadStatus] = [.idle, .checking, .downloading(received: 50, total: 100), .verifying, .installing, .installed(id: "a", version: 1), .waitingForWiFi(bytes: 5), .paused, .failed("x")]
        for status in all { #expect(!status.label(language: "ko").isEmpty && !status.label(language: "en").isEmpty) }
        #expect(SeasonPackDownloadStatus.downloading(received: 50, total: 100).label(language: "en").contains("50%"))
    }
}

struct RealSeedArchiveTests {
    @Test func theShippedChristmasPackFitsTheArchiveLimitsAndSurvivesARoundTrip() throws {
        let pack = Fixture.seedPack("christmas")
        var files: [String: Data] = [:]
        for asset in pack.manifest.assets { files[asset.path] = try Data(contentsOf: pack.directory.appendingPathComponent(asset.path)) }
        let manifestData = try Data(contentsOf: pack.directory.appendingPathComponent("manifest.json"))
        let blob = try SeasonPackArchive.encode(manifestData: manifestData, files: files)
        #expect(blob.count < SeasonPackLimits.packBytes)
        let url = Fixture.tempDirectory().appendingPathComponent("c.bpack")
        try blob.write(to: url)
        let unpacked = try SeasonPackArchive.decode(from: url)
        let store = SeasonPackStore(root: Fixture.tempDirectory())
        _ = try store.install(manifestData: unpacked.manifestData, files: unpacked.files, appBuild: 1000)
        #expect(store.hasInstalled(id: "christmas", version: pack.version))
    }
}
