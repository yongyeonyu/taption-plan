import Synchronization
import XCTest
@testable import TaptionPlan

/// 벡터 지도 자동 오프라인 저장(MAP1108A03): Wi-Fi에서만 저장, 저장본 우선, 기간·크기 정리, 재귀 방지. 실제 네트워크는 쓰지 않는다.
final class OfflineVectorTileTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "OfflineVectorTileTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func tileURL(z: Int = 14, x: Int = 13972, y: Int = 6342) -> URL {
        URL(string: "https://tiles.openfreemap.org/planet/20261101_080013_pt/\(z)/\(x)/\(y).pbf")!
    }

    private func makeCache(
        _ path: OfflineVectorNetworkPath,
        fetcher: FakeFetcher = FakeFetcher(),
        clock: TestClock = TestClock()
    ) -> (OfflineVectorTileCache, FakeNetwork, FakeFetcher) {
        let network = FakeNetwork(path)
        let store = OfflineVectorTileStore(root: root, now: { clock.now })
        return (OfflineVectorTileCache(store: store, network: network, fetcher: fetcher, now: { clock.now }), network, fetcher)
    }

    // MARK: 주소 → 저장 위치

    func testKeysFromProviderURLs() throws {
        XCTAssertEqual(OfflineVectorKey(url: tileURL()), .tile(OfflineVectorTileID(z: 14, x: 13972, y: 6342)))
        XCTAssertEqual(OfflineVectorKey(url: OfflineVectorResources.tileJSONURL), .resource("planet"))
        let font = try XCTUnwrap(URL(string: "https://tiles.openfreemap.org/fonts/Noto%20Sans%20Regular/0-255.pbf"))
        XCTAssertEqual(OfflineVectorKey(url: font), .resource("fonts_Noto Sans Regular_0-255.pbf"))
        XCTAssertNil(OfflineVectorKey(url: try XCTUnwrap(URL(string: "https://example.com/planet/v/1/2/3.pbf"))))
        XCTAssertFalse(OfflineVectorKey.tile(.init(z: 15, x: 0, y: 0)).isStorable(limits: .standard))
        XCTAssertTrue(OfflineVectorKey.tile(.init(z: 14, x: 0, y: 0)).isStorable(limits: .standard))
    }

    func testWifiOnlyPathRule() {
        XCTAssertTrue(OfflineVectorNetworkPath.wifi.allowsCaching)
        XCTAssertFalse(OfflineVectorNetworkPath(isOnline: true, isExpensive: true, isConstrained: false).allowsCaching)
        XCTAssertFalse(OfflineVectorNetworkPath(isOnline: true, isExpensive: false, isConstrained: true).allowsCaching)
        XCTAssertFalse(OfflineVectorNetworkPath(isOnline: false, isExpensive: false, isConstrained: false).allowsCaching)
        XCTAssertFalse(OfflineVectorNetworkPath.unknown.allowsCaching, "첫 갱신 전에는 저장하지 않는다")
    }

    // MARK: 가로채기·저장

    func testStoresTileOnWifiMissAndServesItNext() async throws {
        let (cache, _, fetcher) = makeCache(.wifi)
        let first = try await cache.load(URLRequest(url: tileURL()))
        XCTAssertFalse(first.fromStore)
        XCTAssertEqual(first.response.statusCode, 200)
        XCTAssertTrue(cache.store.contains(.tile(.init(z: 14, x: 13972, y: 6342))))

        // 판(버전)이 바뀐 주소도 같은 z/x/y 저장본을 쓴다.
        let other = URL(string: "https://tiles.openfreemap.org/planet/20261201_000000_pt/14/13972/6342.pbf")!
        let second = try await cache.load(URLRequest(url: other))
        XCTAssertTrue(second.fromStore)
        XCTAssertEqual(second.data, first.data)
        XCTAssertEqual(fetcher.requests.count, 1, "저장본이 있으면 네트워크로 가지 않는다")
    }

    func testDoesNotStoreOnExpensiveOrConstrainedButStillServes() async throws {
        for path in [
            OfflineVectorNetworkPath(isOnline: true, isExpensive: true, isConstrained: false),
            OfflineVectorNetworkPath(isOnline: true, isExpensive: false, isConstrained: true),
        ] {
            let (cache, _, fetcher) = makeCache(path)
            let loaded = try await cache.load(URLRequest(url: tileURL()))
            XCTAssertFalse(loaded.fromStore)
            XCTAssertEqual(loaded.data, FakeFetcher.body)
            XCTAssertFalse(cache.store.contains(.tile(.init(z: 14, x: 13972, y: 6342))), "셀룰러·저데이터에서는 저장하지 않는다")
            XCTAssertEqual(fetcher.requests.count, 1)
            try? FileManager.default.removeItem(at: root)
            cache.store.purgeMemory()
        }
    }

    func testServesStoredTileFirstOnCellular() async throws {
        let (cache, _, fetcher) = makeCache(OfflineVectorNetworkPath(isOnline: true, isExpensive: true, isConstrained: false))
        try cache.store.write(Data([7, 7]), for: .tile(.init(z: 14, x: 13972, y: 6342)))
        let loaded = try await cache.load(URLRequest(url: tileURL()))
        XCTAssertTrue(loaded.fromStore)
        XCTAssertEqual(loaded.data, Data([7, 7]))
        XCTAssertEqual(loaded.response.value(forHTTPHeaderField: "Content-Type"), "application/vnd.mapbox-vector-tile")
        XCTAssertTrue(fetcher.requests.isEmpty)
    }

    func testNonOKAndOverMaxZoomAreNotStored() async throws {
        let fetcher = FakeFetcher(status: 404)
        let (cache, _, _) = makeCache(.wifi, fetcher: fetcher)
        let missing = try await cache.load(URLRequest(url: tileURL()))
        XCTAssertEqual(missing.response.statusCode, 404, "실패 응답도 그대로 MapLibre에 넘긴다")
        XCTAssertFalse(cache.store.contains(.tile(.init(z: 14, x: 13972, y: 6342))))

        let (deep, _, _) = makeCache(.wifi)
        _ = try await deep.load(URLRequest(url: tileURL(z: 15, x: 1, y: 1)))
        XCTAssertFalse(deep.store.contains(.tile(.init(z: 15, x: 1, y: 1))))
    }

    func testResourceCachedOnWifiAndServedOnlyOffline() async throws {
        let (cache, network, fetcher) = makeCache(.wifi)
        let request = URLRequest(url: OfflineVectorResources.tileJSONURL)
        _ = try await cache.load(request)
        XCTAssertTrue(cache.store.contains(.resource("planet")))
        let online = try await cache.load(request)
        XCTAssertFalse(online.fromStore, "연결돼 있으면 판 정보는 새로 받는다")
        XCTAssertEqual(fetcher.requests.count, 2)

        network.set(OfflineVectorNetworkPath(isOnline: false, isExpensive: false, isConstrained: false))
        let offline = try await cache.load(request)
        XCTAssertTrue(offline.fromStore)
        XCTAssertEqual(fetcher.requests.count, 2)

        // 연결됐다고 나오지만 실제로 못 받으면 저장본으로 대신한다.
        network.set(.wifi)
        fetcher.fail(true)
        let fallback = try await cache.load(request)
        XCTAssertTrue(fallback.fromStore)
    }

    func testFetchFailureWithoutStoredCopyFails() async throws {
        let fetcher = FakeFetcher()
        fetcher.fail(true)
        let (cache, _, _) = makeCache(.wifi, fetcher: fetcher)
        do {
            _ = try await cache.load(URLRequest(url: tileURL()))
            XCTFail("저장본이 없으면 실패를 넘겨야 한다")
        } catch {}
    }

    func testPassthroughDropsEncodingHeaders() async throws {
        let fetcher = FakeFetcher(headers: ["Content-Encoding": "gzip", "Content-Length": "3", "ETag": "abc"])
        let (cache, _, _) = makeCache(.wifi, fetcher: fetcher)
        let loaded = try await cache.load(URLRequest(url: tileURL()))
        XCTAssertNil(loaded.response.value(forHTTPHeaderField: "Content-Encoding"), "URLSession이 이미 푼 본문이다")
        XCTAssertEqual(loaded.response.value(forHTTPHeaderField: "Content-Length"), "\(FakeFetcher.body.count)")
        XCTAssertEqual(loaded.response.value(forHTTPHeaderField: "ETag"), "abc")
    }

    // MARK: 재귀 방지·통과

    func testOnlyProviderGETRequestsAreHandled() throws {
        XCTAssertTrue(OfflineVectorTileCache.handles(URLRequest(url: tileURL())))
        XCTAssertTrue(OfflineVectorTileCache.handles(URLRequest(url: OfflineVectorResources.tileJSONURL)))
        XCTAssertFalse(OfflineVectorTileCache.handles(URLRequest(url: try XCTUnwrap(URL(string: "https://example.com/1/2/3.pbf")))))
        XCTAssertFalse(OfflineVectorTileCache.handles(URLRequest(url: try XCTUnwrap(URL(string: "https://tiles.openfreemap.org/styles/liberty")))))
        var post = URLRequest(url: tileURL())
        post.httpMethod = "POST"
        XCTAssertFalse(OfflineVectorTileCache.handles(post))
        XCTAssertFalse(OfflineVectorTileCache.handles(OfflineVectorTileCache.marked(URLRequest(url: tileURL()))))
    }

    func testFetchIsRecursionSafe() async throws {
        let (cache, _, fetcher) = makeCache(.wifi)
        var request = URLRequest(url: tileURL())
        request.setValue("\"etag\"", forHTTPHeaderField: "If-None-Match")
        request.setValue("Sun, 01 Nov 2026 00:00:00 GMT", forHTTPHeaderField: "If-Modified-Since")
        _ = try await cache.load(request)
        let sent = try XCTUnwrap(fetcher.requests.first)
        XCTAssertFalse(OfflineVectorTileCache.handles(sent), "내보낸 요청은 다시 가로채지 않는다")
        XCTAssertNil(sent.value(forHTTPHeaderField: "If-None-Match"), "Wi-Fi에서는 저장할 본문을 받는다")
        XCTAssertNil(sent.value(forHTTPHeaderField: "If-Modified-Since"))

        let classes = OfflineVectorHTTPFetcher.makeConfiguration().protocolClasses ?? []
        XCTAssertFalse(classes.contains { ObjectIdentifier($0) == ObjectIdentifier(OfflineVectorTileURLProtocol.self) })
        XCTAssertTrue(OfflineVectorHTTPFetcher.userAgent.hasPrefix("BOKKIPlan/"))
        XCTAssertTrue(OfflineVectorHTTPFetcher.userAgent.hasSuffix(" (iOS)"))
    }

    // MARK: 저장소 정리

    func testOfflineFirstLookup() throws {
        let store = OfflineVectorTileStore(root: root)
        let url = tileURL(x: 1, y: 2)
        XCTAssertFalse(store.shouldServe(url, isOnline: false))
        try store.write(Data([1, 2, 3]), for: .tile(OfflineVectorTileID(z: 14, x: 1, y: 2)))
        XCTAssertTrue(store.shouldServe(url, isOnline: true), "타일은 연결돼 있어도 저장본을 먼저 쓴다")
        XCTAssertEqual(store.data(for: .tile(OfflineVectorTileID(z: 14, x: 1, y: 2))), Data([1, 2, 3]))
        XCTAssertFalse(store.shouldServe(try XCTUnwrap(URL(string: "https://example.com/a.pbf")), isOnline: false))
    }

    func testUnusedTilesAreEvictedAfterMaxAge() throws {
        let clock = TestClock()
        let store = OfflineVectorTileStore(root: root, now: { clock.now })
        let used = OfflineVectorTileID(z: 10, x: 1, y: 1)
        let stale = OfflineVectorTileID(z: 10, x: 2, y: 1)
        try store.write(Data(count: 10), for: .tile(used))
        try store.write(Data(count: 10), for: .tile(stale))
        let day: TimeInterval = 24 * 3_600
        clock.advance(80 * day)
        _ = store.data(for: .tile(used))
        clock.advance(11 * day)
        XCTAssertEqual(store.evict(limits: .standard), 1)
        XCTAssertTrue(store.contains(.tile(used)))
        XCTAssertFalse(store.contains(.tile(stale)))

        // 색인을 버리고 파일 날짜에서 다시 읽어도 마지막 사용이 그대로다.
        store.purgeMemory()
        XCTAssertTrue(store.contains(.tile(used)))
        XCTAssertFalse(store.contains(.tile(stale)), "지운 파일은 디스크에서도 없다")
        clock.advance(85 * day)
        XCTAssertEqual(store.evict(limits: .standard), 1)
        XCTAssertFalse(store.contains(.tile(used)))
    }

    func testLeastRecentlyUsedTileIsEvictedFirstOverSizeCap() throws {
        let clock = TestClock()
        let store = OfflineVectorTileStore(root: root, now: { clock.now })
        let a = OfflineVectorTileID(z: 5, x: 1, y: 1)
        let b = OfflineVectorTileID(z: 5, x: 2, y: 1)
        let c = OfflineVectorTileID(z: 5, x: 3, y: 1)
        for id in [a, b, c] {
            try store.write(Data(count: 100), for: .tile(id))
            clock.advance(10)
        }
        clock.advance(OfflineVectorTileStore.touchInterval)
        _ = store.data(for: .tile(a))
        var limits = OfflineVectorLimits()
        limits.storeBytes = 200
        XCTAssertEqual(store.evict(limits: limits), 1)
        XCTAssertTrue(store.contains(.tile(a)))
        XCTAssertFalse(store.contains(.tile(b)))
        XCTAssertTrue(store.contains(.tile(c)))
    }

    func testFileCountCapEvicts() throws {
        let clock = TestClock()
        let store = OfflineVectorTileStore(root: root, now: { clock.now })
        for x in 0..<5 {
            try store.write(Data(count: 1), for: .tile(OfflineVectorTileID(z: 3, x: x, y: 0)))
            clock.advance(1)
        }
        var limits = OfflineVectorLimits()
        limits.storeFiles = 3
        XCTAssertEqual(store.evict(limits: limits), 2)
        XCTAssertFalse(store.contains(.tile(OfflineVectorTileID(z: 3, x: 0, y: 0))))
        XCTAssertTrue(store.contains(.tile(OfflineVectorTileID(z: 3, x: 4, y: 0))))
    }

    func testMemoryPressureDropsIndexAndMaintenanceDoesNotKeepIt() throws {
        let (cache, _, _) = makeCache(.wifi)
        try cache.store.write(Data(count: 1), for: .tile(.init(z: 1, x: 0, y: 0)))
        XCTAssertTrue(cache.store.isIndexLoaded)
        cache.handleMemoryPressure()
        XCTAssertFalse(cache.store.isIndexLoaded)
        XCTAssertEqual(cache.runMaintenance(), 0)
        XCTAssertFalse(cache.store.isIndexLoaded, "메모리 경고 직후 정리는 색인을 남기지 않는다")
        XCTAssertTrue(cache.store.contains(.tile(.init(z: 1, x: 0, y: 0))))
    }

    func testWriteSchedulesBackgroundMaintenance() async throws {
        var limits = OfflineVectorLimits()
        limits.storeFiles = 1
        let clock = TestClock()
        let store = OfflineVectorTileStore(root: root, now: { clock.now })
        try store.write(Data(count: 1), for: .tile(.init(z: 14, x: 0, y: 0)))
        clock.advance(1)
        let cache = OfflineVectorTileCache(store: store, network: FakeNetwork(.wifi), fetcher: FakeFetcher(), limits: limits, now: { clock.now })
        _ = try await cache.load(URLRequest(url: tileURL()))
        // 첫 저장은 정리 간격이 지난 것으로 보고 전역 큐에서 정리한다.
        for _ in 0..<100 where store.contains(.tile(.init(z: 14, x: 0, y: 0))) {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(store.contains(.tile(.init(z: 14, x: 0, y: 0))))
        XCTAssertTrue(store.contains(.tile(.init(z: 14, x: 13972, y: 6342))))
    }
}

private final class TestClock: Sendable {
    private let value = Mutex(Date(timeIntervalSince1970: 1_000_000))
    var now: Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 += seconds } }
}

private final class FakeNetwork: OfflineVectorNetworkPathProviding {
    private let path: Mutex<OfflineVectorNetworkPath>
    init(_ path: OfflineVectorNetworkPath) { self.path = Mutex(path) }
    var current: OfflineVectorNetworkPath { path.withLock { $0 } }
    func set(_ next: OfflineVectorNetworkPath) { path.withLock { $0 = next } }
}

private final class FakeFetcher: OfflineVectorFetching {
    static let body = Data([1, 2, 3, 4, 5])

    private let state = Mutex((requests: [URLRequest](), failing: false))
    let status: Int
    let headers: [String: String]

    init(status: Int = 200, headers: [String: String] = [:]) {
        self.status = status
        self.headers = headers
    }

    var requests: [URLRequest] { state.withLock { $0.requests } }
    func fail(_ value: Bool) { state.withLock { $0.failing = value } }

    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let failing = state.withLock { state -> Bool in
            state.requests.append(request)
            return state.failing
        }
        if failing { throw URLError(.notConnectedToInternet) }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        return (Self.body, response)
    }
}
