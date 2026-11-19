import Foundation
import Synchronization
import Testing
@testable import SeasonPackKit

struct StoreTests {
    @Test func installIsAtomicVerifiedAndExcludedFromBackup() throws {
        let root = Fixture.tempDirectory()
        let store = SeasonPackStore(root: root)
        let built = Fixture.pack(id: "christmas")
        let pack = try store.install(manifestData: built.manifest, files: built.files, appBuild: 1, serverDate: Fixture.date(2026, 12, 1))
        #expect(pack.source == .installed)
        #expect(FileManager.default.fileExists(atPath: pack.directory.appendingPathComponent("a.png").path))
        #expect(store.record(id: "christmas", version: 1)?.serverDate == Fixture.date(2026, 12, 1))
        #expect(SeasonPackStore.isExcludedFromBackup(root))
        #expect(SeasonPackStore.isExcludedFromBackup(pack.directory))
        let leftovers = (try FileManager.default.contentsOfDirectory(atPath: root.path)).filter { $0.hasPrefix(".tmp") }
        #expect(leftovers.isEmpty)
        #expect(store.installedPacks(appBuild: 1).count == 1)
    }

    @Test func badHashLeavesNothingBehind() {
        let root = Fixture.tempDirectory()
        let store = SeasonPackStore(root: root)
        let built = Fixture.pack(id: "christmas")
        #expect(throws: SeasonPackStoreError.self) {
            try store.install(manifestData: built.manifest, files: ["a.png": Data("PNG-BYTES".utf8)], appBuild: 1)
        }
        #expect(store.installedPacks(appBuild: 1).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("christmas").path))
    }

    @Test func corruptedInstalledPackFallsBackToNothingNotACrash() throws {
        let store = SeasonPackStore(root: Fixture.tempDirectory())
        let built = Fixture.pack(id: "christmas")
        let pack = try store.install(manifestData: built.manifest, files: built.files, appBuild: 1)
        try Data("garbage!!".utf8).write(to: pack.directory.appendingPathComponent("a.png"))
        #expect(store.installedPacks(appBuild: 1).isEmpty)
        try Data("{".utf8).write(to: pack.directory.appendingPathComponent("manifest.json"))
        #expect(store.installedPacks(appBuild: 1).isEmpty)
    }

    @Test func keepsThreeVersionsPerPack() throws {
        let store = SeasonPackStore(root: Fixture.tempDirectory())
        for version in 1...5 {
            let built = Fixture.pack(id: "christmas", version: version)
            try store.install(manifestData: built.manifest, files: built.files, appBuild: 1, now: Fixture.date(2026, 1, version))
        }
        store.enforceLimits(protecting: [])
        #expect(Set(store.installedPacks(appBuild: 1).map(\.version)) == [3, 4, 5])
    }

    @Test func overTheByteCapEvictsLeastRecentlyUsedExceptProtected() throws {
        let store = SeasonPackStore(root: Fixture.tempDirectory())
        let bytes = Data(repeating: 9, count: 1000)
        for (index, id) in ["old", "mid", "active"].enumerated() {
            let built = Fixture.pack(id: id, fileBytes: bytes)
            try store.install(manifestData: built.manifest, files: built.files, appBuild: 1, now: Fixture.date(2026, 1, index + 1))
        }
        store.enforceLimits(protecting: ["active"], maxBytes: 4000)
        let ids = Set(store.installedPacks(appBuild: 1).map(\.id))
        #expect(ids.contains("active"))
        #expect(!ids.contains("old"))
        store.enforceLimits(protecting: ["active"], maxBytes: 1)
        #expect(Set(store.installedPacks(appBuild: 1).map(\.id)) == ["active"])
    }

    @Test func removeAllDeletesPacksAndMemos() throws {
        let root = Fixture.tempDirectory()
        let store = SeasonPackStore(root: root)
        let built = Fixture.pack(id: "christmas")
        try store.install(manifestData: built.manifest, files: built.files, appBuild: 1)
        let memos = SeasonPackMemoStore(directory: root.appendingPathComponent("memos"))
        try memos.save("hello", packID: "christmas", itemID: "goal", maxLength: 10, readOnlyAfter: nil)
        store.removeAll()
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func seedVersusInstalledPicksHigherThenBundle() {
        let seed = SeasonPack(manifest: Fixture.manifest(Fixture.pack(id: "x", version: 2).manifest), directory: URL(fileURLWithPath: "/s"), source: .seed)
        let sameInstalled = SeasonPack(manifest: Fixture.manifest(Fixture.pack(id: "x", version: 2).manifest), directory: URL(fileURLWithPath: "/i"), source: .installed)
        let newerInstalled = SeasonPack(manifest: Fixture.manifest(Fixture.pack(id: "x", version: 3).manifest), directory: URL(fileURLWithPath: "/i3"), source: .installed)
        #expect(SeasonPackSeed.merge(installed: [sameInstalled], seeds: [seed]).first?.source == .seed)
        #expect(SeasonPackSeed.merge(installed: [newerInstalled], seeds: [seed]).first?.version == 3)
    }

    @Test func bundledChristmasSeedPassesTheSameValidation() {
        let packs = SeasonPackSeed.bundledPacks(appBuild: 1)
        #expect(packs.contains { $0.id == "christmas" })
        #expect(packs.allSatisfy { $0.source == .seed })
    }
}

final class DateBox: Sendable {
    private let dates = Mutex<[Date]>([])
    func append(_ date: Date) { dates.withLock { $0.append(date) } }
    var all: [Date] { dates.withLock { $0 } }
}

final class FakeTransport: SeasonPackTransport {
    private let log = Mutex<[String]>([])
    private let replies: Mutex<[String: SeasonPackReply]>
    init(_ replies: [String: SeasonPackReply]) { self.replies = Mutex(replies) }
    var requested: [String] { log.withLock { $0 } }
    func get(key: String, etag: String?) async -> SeasonPackReply? {
        log.withLock { $0.append(key) }
        return replies.withLock { $0[key] }
    }
}

struct FetcherTests {
    private func served(id: String = "christmas", version: Int = 1, big: Bool = false) -> (FakeTransport, String) {
        let bytes = big ? Data(repeating: 1, count: SeasonPackLimits.cellularBytes + 10) : Data("png-bytes".utf8)
        let built = Fixture.pack(id: id, version: version, fileBytes: bytes)
        let base = "packs/season/\(id)/\(version)"
        let index = "{\"format\":\"bokki-season-packs\",\"schema\":1,\"packs\":[{\"id\":\"\(id)\",\"version\":\(version),\"manifest\":\"\(base)/manifest.json\"}]}"
        let date = Fixture.date(2026, 12, 1)
        let transport = FakeTransport([
            "packs/season/index.json": SeasonPackReply(status: 200, data: Data(index.utf8), etag: "\"e1\"", serverDate: date),
            "\(base)/manifest.json": SeasonPackReply(status: 200, data: built.manifest, serverDate: date),
            "\(base)/a.png": SeasonPackReply(status: 200, data: bytes, serverDate: date),
        ])
        return (transport, base)
    }

    private func fetcher(_ transport: SeasonPackTransport, store: SeasonPackStore, suite: String, now: Date, large: Bool = true, known: Int = 0, servers: DateBox? = nil) -> SeasonPackFetcher {
        SeasonPackFetcher(
            store: store, transport: transport, defaults: SeasonPackDefaults(suiteName: suite), appBuild: { 1000 }, now: { now },
            windows: { Fixture.windows }, allowsLargeDownload: { large }, knownVersion: { _ in known },
            onServerDate: { date in servers?.append(date) }
        )
    }

    @Test func downloadsNearPackVerifiesAndReportsFreshInstall() async {
        let (transport, _) = served()
        let store = SeasonPackStore(root: Fixture.tempDirectory())
        let servers = DateBox()
        let result = await fetcher(transport, store: store, suite: Fixture.suite(), now: Fixture.date(2026, 12, 10), servers: servers).refresh()
        #expect(result.installed == [SeasonPackRef(id: "christmas", version: 1)])
        #expect(store.hasInstalled(id: "christmas", version: 1))
        #expect(servers.all.first == Fixture.date(2026, 12, 1))
        #expect(transport.requested.first == "packs/season/index.json")
    }

    @Test func farFromTheWindowOnlyReadsTheManifestAndDownloadsNoFiles() async {
        let (transport, base) = served()
        let store = SeasonPackStore(root: Fixture.tempDirectory())
        let result = await fetcher(transport, store: store, suite: Fixture.suite(), now: Fixture.date(2026, 6, 1)).refresh()
        #expect(result.installed.isEmpty)
        #expect(!transport.requested.contains("\(base)/a.png"))
    }

    @Test func cooldownThirtyMinutesSkipsTheSecondCall() async {
        let (transport, _) = served()
        let store = SeasonPackStore(root: Fixture.tempDirectory())
        let f = fetcher(transport, store: store, suite: Fixture.suite(), now: Fixture.date(2026, 12, 10))
        _ = await f.refresh()
        let count = transport.requested.count
        let again = await f.refresh()
        #expect(again.skippedReason == "cooldown")
        #expect(transport.requested.count == count)
    }

    @Test func alreadyKnownOrInstalledVersionIsNotDownloadedAgain() async {
        let (transport, base) = served()
        let store = SeasonPackStore(root: Fixture.tempDirectory())
        _ = await fetcher(transport, store: store, suite: Fixture.suite(), now: Fixture.date(2026, 12, 10), known: 1).refresh()
        #expect(!transport.requested.contains("\(base)/manifest.json"))
        let first = await fetcher(transport, store: store, suite: Fixture.suite(), now: Fixture.date(2026, 12, 10)).refresh()
        #expect(first.installed.count == 1)
        let third = await fetcher(transport, store: store, suite: Fixture.suite(), now: Fixture.date(2026, 12, 10)).refresh()
        #expect(third.installed.isEmpty)
    }

    @Test func largePackIsNotFetchedOnCellularOrLowData() async {
        let (transport, base) = served(big: true)
        let store = SeasonPackStore(root: Fixture.tempDirectory())
        let result = await fetcher(transport, store: store, suite: Fixture.suite(), now: Fixture.date(2026, 12, 10), large: false).refresh()
        #expect(result.installed.isEmpty)
        #expect(!transport.requested.contains("\(base)/a.png"))
    }

    @Test func offlineOrBadIndexIsSilentAndChangesNothing() async {
        let store = SeasonPackStore(root: Fixture.tempDirectory())
        let offline = await fetcher(FakeTransport([:]), store: store, suite: Fixture.suite(), now: Fixture.date(2026, 12, 10)).refresh()
        #expect(offline.skippedReason == "offline")
        let bad = FakeTransport(["packs/season/index.json": SeasonPackReply(status: 200, data: Data("nope".utf8))])
        let result = await fetcher(bad, store: store, suite: Fixture.suite(), now: Fixture.date(2026, 12, 10)).refresh()
        #expect(result.skippedReason == "bad-index")
        #expect(store.installedPacks(appBuild: 1).isEmpty)
    }

    @Test func requestCarriesNoCoordinatesIdentifiersOrAccountAndStaysInTheKeyShape() throws {
        let transport = SeasonPackURLSessionTransport(urlForKey: { URL(string: "https://relay.example.invalid/public/assets/\($0)") })
        let request = try #require(transport.request(key: "packs/season/index.json", etag: nil))
        #expect(request.httpMethod == "GET")
        #expect(request.url?.query == nil)
        #expect(request.httpBody == nil)
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.allHTTPHeaderFields?["Authorization"] == nil)
        #expect(request.allHTTPHeaderFields?["Cookie"] == nil)
        #expect(request.timeoutInterval == 8)
        #expect(SeasonPackURLSessionTransport.isValidKey("packs/season/christmas/1/audio/jingle-bells.m4a"))
        for bad in ["packs/season/../x", "packs//x", "packs/ a", "packs/.x", "a/b/c/d/e/f/g/h/i", "packs/a%2Fb"] {
            #expect(!SeasonPackURLSessionTransport.isValidKey(bad), "\(bad)")
        }
    }
}
