import Synchronization
import XCTest
@testable import TaptionPlan

/// 벡터 지도 오프라인 저장(MAP1108A02): 타일 범위·추정, 약관 상한, LRU, 오프라인 우선 조회. 실제 네트워크는 쓰지 않는다.
final class OfflineVectorTileTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "OfflineVectorTileTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let seoul = OfflineVectorBounds(south: 37.56, west: 126.97, north: 37.57, east: 126.98)

    // MARK: 범위·추정

    func testSeoulTileCoordinates() {
        XCTAssertEqual(OfflineVectorTileMath.tileX(longitude: 126.978, zoom: 14), 13970)
        XCTAssertEqual(OfflineVectorTileMath.tileY(latitude: 37.5665, zoom: 14), 6344)
        XCTAssertEqual(OfflineVectorTileMath.tileX(longitude: 180, zoom: 3), 7)
        XCTAssertEqual(OfflineVectorTileMath.tileY(latitude: -90, zoom: 3), 7)
    }

    func testWorldTileCountPerZoom() {
        let world = OfflineVectorBounds(south: -90, west: -180, north: 90, east: 180)
        XCTAssertEqual(OfflineVectorTileMath.tileCount(world, zooms: 0...2), 1 + 4 + 16)
        XCTAssertEqual(OfflineVectorTileMath.tileIDs(world, zooms: 0...2).count, 21)
        XCTAssertEqual(Set(OfflineVectorTileMath.tileIDs(world, zooms: 1...1)).count, 4)
    }

    func testPlanEstimateUsesPerZoomSize() {
        let plan = OfflineVectorDownloadPlan(bounds: seoul, zooms: 10...10)
        XCTAssertEqual(plan.tileCount, 1)
        XCTAssertEqual(plan.estimatedBytes, 150 * 1_024)
        XCTAssertNil(plan.problem)
        XCTAssertEqual(plan.requestCount, 1 + OfflineVectorResources.urls.count)
    }

    func testPlanClampsZoomToProviderMax() {
        let plan = OfflineVectorDownloadPlan(bounds: seoul, zooms: 12...18)
        XCTAssertEqual(plan.zooms, 12...14)
    }

    func testPlanRejectsOverTileCap() {
        let korea = OfflineVectorBounds(south: 33, west: 124, north: 39, east: 131)
        let plan = OfflineVectorDownloadPlan(bounds: korea, zooms: 0...14)
        XCTAssertGreaterThan(plan.tileCount, 3_000)
        XCTAssertEqual(plan.problem, .tooManyTiles)
    }

    func testPlanRejectsOverByteCapUnderTileCap() {
        let city = OfflineVectorBounds(south: 37.4, west: 126.8, north: 37.7, east: 127.2)
        let plan = OfflineVectorDownloadPlan(bounds: city, zooms: 14...14)
        XCTAssertLessThan(plan.requestCount, 3_000)
        XCTAssertGreaterThan(plan.estimatedBytes, 50 * 1_024 * 1_024)
        XCTAssertEqual(plan.problem, .tooLarge)
    }

    // MARK: 주소 → 저장 위치

    func testKeysFromProviderURLs() throws {
        let tile = try XCTUnwrap(URL(string: "https://tiles.openfreemap.org/planet/20261101_080013_pt/14/13972/6342.pbf"))
        XCTAssertEqual(OfflineVectorKey(url: tile), .tile(OfflineVectorTileID(z: 14, x: 13972, y: 6342)))
        XCTAssertEqual(OfflineVectorKey(url: OfflineVectorResources.tileJSONURL), .resource("planet"))
        let font = try XCTUnwrap(URL(string: "https://tiles.openfreemap.org/fonts/Noto%20Sans%20Regular/0-255.pbf"))
        XCTAssertEqual(OfflineVectorKey(url: font), .resource("fonts_Noto Sans Regular_0-255.pbf"))
        XCTAssertNil(OfflineVectorKey(url: try XCTUnwrap(URL(string: "https://example.com/planet/v/1/2/3.pbf"))))
        XCTAssertEqual(OfflineVectorResources.urls.compactMap(OfflineVectorKey.init(url:)).count, OfflineVectorResources.urls.count)
    }

    // MARK: 저장소

    func testOfflineFirstLookup() throws {
        let store = OfflineVectorTileStore(root: root)
        let tileURL = try XCTUnwrap(URL(string: "https://tiles.openfreemap.org/planet/v1/14/1/2.pbf"))
        XCTAssertFalse(store.shouldServe(tileURL, isOnline: false))
        try store.write(Data([1, 2, 3]), for: .tile(OfflineVectorTileID(z: 14, x: 1, y: 2)))
        XCTAssertTrue(store.shouldServe(tileURL, isOnline: true), "타일은 연결돼 있어도 저장본을 먼저 쓴다")
        XCTAssertEqual(store.data(for: .tile(OfflineVectorTileID(z: 14, x: 1, y: 2))), Data([1, 2, 3]))

        try store.write(Data("{}".utf8), for: .resource("planet"))
        XCTAssertFalse(store.shouldServe(OfflineVectorResources.tileJSONURL, isOnline: true), "판 정보는 연결되면 새로 받는다")
        XCTAssertTrue(store.shouldServe(OfflineVectorResources.tileJSONURL, isOnline: false))
        XCTAssertFalse(store.shouldServe(try XCTUnwrap(URL(string: "https://example.com/a.pbf")), isOnline: false))
    }

    func testSummaryAndRemoveAllAndMemoryPurge() throws {
        let store = OfflineVectorTileStore(root: root)
        try store.write(Data(count: 100), for: .tile(OfflineVectorTileID(z: 1, x: 0, y: 0)))
        try store.write(Data(count: 50), for: .resource("planet"))
        XCTAssertEqual(store.summary(), .init(bytes: 150, tiles: 1))
        store.purgeMemory()
        XCTAssertTrue(store.contains(.tile(OfflineVectorTileID(z: 1, x: 0, y: 0))), "색인을 버려도 파일에서 다시 읽는다")
        XCTAssertEqual(store.summary(), .init(bytes: 150, tiles: 1))
        store.removeAll()
        XCTAssertEqual(store.summary(), .init())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testLeastRecentlyUsedTileIsEvictedFirst() throws {
        let clock = TestClock()
        let store = OfflineVectorTileStore(root: root, now: { clock.now })
        let a = OfflineVectorTileID(z: 5, x: 1, y: 1)
        let b = OfflineVectorTileID(z: 5, x: 2, y: 1)
        let c = OfflineVectorTileID(z: 5, x: 3, y: 1)
        for id in [a, b, c] {
            try store.write(Data(count: 100), for: .tile(id))
            clock.advance(10)
        }
        _ = store.data(for: .tile(a))
        XCTAssertEqual(store.enforceLimit(maxBytes: 200, maxFiles: 10), 1)
        XCTAssertTrue(store.contains(.tile(a)))
        XCTAssertFalse(store.contains(.tile(b)))
        XCTAssertTrue(store.contains(.tile(c)))
        store.purgeMemory()
        XCTAssertFalse(store.contains(.tile(b)), "지운 파일은 디스크에서도 없다")
    }

    func testFileCountCapEvicts() throws {
        let clock = TestClock()
        let store = OfflineVectorTileStore(root: root, now: { clock.now })
        for x in 0..<5 {
            try store.write(Data(count: 1), for: .tile(OfflineVectorTileID(z: 3, x: x, y: 0)))
            clock.advance(1)
        }
        XCTAssertEqual(store.enforceLimit(maxBytes: .max, maxFiles: 3), 2)
        XCTAssertEqual(store.summary().tiles, 3)
        XCTAssertFalse(store.contains(.tile(OfflineVectorTileID(z: 3, x: 0, y: 0))))
    }

    // MARK: 내려받기(가짜 네트워크)

    func testDownloadStoresTilesAndResumesBySkipping() async throws {
        let store = OfflineVectorTileStore(root: root)
        let fetcher = FakeFetcher(tileBytes: 1_000)
        let plan = OfflineVectorDownloadPlan(bounds: seoul, zooms: 12...13)
        let first = try await OfflineVectorDownloadRun.run(plan: plan, store: store, fetcher: fetcher, pause: .zero)
        XCTAssertEqual(first.fetched, plan.tileCount)
        XCTAssertEqual(first.skipped, 0)
        XCTAssertEqual(store.summary().tiles, plan.tileCount)
        XCTAssertTrue(store.contains(.resource("planet")))

        let tileRequests = fetcher.tileRequests
        let second = try await OfflineVectorDownloadRun.run(plan: plan, store: store, fetcher: fetcher, pause: .zero)
        XCTAssertEqual(second.fetched, 0)
        XCTAssertEqual(second.skipped, plan.tileCount)
        XCTAssertEqual(fetcher.tileRequests, tileRequests, "이미 받은 타일은 다시 요청하지 않는다")
    }

    func testDownloadStopsAtByteCap() async throws {
        let store = OfflineVectorTileStore(root: root)
        let fetcher = FakeFetcher(tileBytes: 10_000)
        var limits = OfflineVectorLimits()
        limits.perDownloadBytes = 25_000
        let wide = OfflineVectorBounds(south: 37.5, west: 126.9, north: 37.6, east: 127.0)
        let plan = OfflineVectorDownloadPlan(bounds: wide, zooms: 14...14)
        XCTAssertGreaterThan(plan.tileCount, 5)
        let outcome = try await OfflineVectorDownloadRun.run(plan: plan, store: store, fetcher: fetcher, limits: limits, pause: .zero)
        XCTAssertTrue(outcome.reachedByteCap)
        XCTAssertLessThan(store.summary().tiles, plan.tileCount)
    }

    func testDownloadRefusesPlanOverCapWithoutNetwork() async throws {
        let store = OfflineVectorTileStore(root: root)
        let fetcher = FakeFetcher(tileBytes: 1)
        let world = OfflineVectorBounds(south: -80, west: -170, north: 80, east: 170)
        let plan = OfflineVectorDownloadPlan(bounds: world, zooms: 0...10)
        let outcome = try await OfflineVectorDownloadRun.run(plan: plan, store: store, fetcher: fetcher, pause: .zero)
        XCTAssertEqual(outcome, .init())
        XCTAssertEqual(fetcher.totalRequests, 0)
    }

    func testDownloadEnforcesStoreLimitAfterward() async throws {
        let store = OfflineVectorTileStore(root: root)
        var limits = OfflineVectorLimits()
        limits.storeFiles = 4
        let plan = OfflineVectorDownloadPlan(bounds: seoul, zooms: 12...14)
        _ = try await OfflineVectorDownloadRun.run(plan: plan, store: store, fetcher: FakeFetcher(tileBytes: 10), limits: limits, pause: .zero)
        store.purgeMemory()
        let files = (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? [])
            .filter { $0.hasSuffix(".pbf") || $0.hasSuffix(".png") || $0.hasSuffix(".json") || $0.hasSuffix("planet") }
        XCTAssertLessThanOrEqual(files.count, 4)
    }

    func testTileTemplateParsing() throws {
        let json = Data(#"{"tiles":["https://tiles.openfreemap.org/planet/v9/{z}/{x}/{y}.pbf"],"maxzoom":14}"#.utf8)
        let template = try XCTUnwrap(OfflineVectorDownloadRun.tileTemplate(from: json))
        XCTAssertEqual(template.maxZoom, 14)
        XCTAssertEqual(template.url(for: .init(z: 3, x: 4, y: 5)).absoluteString, "https://tiles.openfreemap.org/planet/v9/3/4/5.pbf")
        XCTAssertNil(OfflineVectorDownloadRun.tileTemplate(from: Data(#"{"tiles":["https://other.example/{z}/{x}/{y}.pbf"]}"#.utf8)))
    }
}

private final class TestClock: Sendable {
    private let value = Mutex(Date(timeIntervalSince1970: 1_000_000))
    var now: Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 += seconds } }
}

private final class FakeFetcher: OfflineVectorFetching {
    private let counts = Mutex((tiles: 0, total: 0))
    let tileBytes: Int

    init(tileBytes: Int) { self.tileBytes = tileBytes }

    var tileRequests: Int { counts.withLock { $0.tiles } }
    var totalRequests: Int { counts.withLock { $0.total } }

    func data(from url: URL) async throws -> Data {
        let isTile: Bool
        if case .tile = OfflineVectorKey(url: url) { isTile = true } else { isTile = false }
        counts.withLock { value in
            value.total += 1
            if isTile { value.tiles += 1 }
        }
        if url == OfflineVectorResources.tileJSONURL {
            return Data(#"{"tiles":["https://tiles.openfreemap.org/planet/test/{z}/{x}/{y}.pbf"],"maxzoom":14}"#.utf8)
        }
        return Data(count: isTile ? tileBytes : 10)
    }
}
