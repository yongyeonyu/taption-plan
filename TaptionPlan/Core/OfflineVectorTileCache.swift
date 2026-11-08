import Foundation
@preconcurrency import MapLibre
import Network
import Synchronization
import UIKit

/// iOS가 알려 준 연결 상태. 셀룰러·개인용 핫스폿(isExpensive)과 저데이터 모드(isConstrained)에서는 저장하지 않는다.
struct OfflineVectorNetworkPath: Equatable, Sendable {
    var isOnline: Bool
    var isExpensive: Bool
    var isConstrained: Bool

    /// Wi-Fi(또는 유선)처럼 비싸지 않고 제한되지 않은 연결일 때만 저장한다.
    var allowsCaching: Bool { isOnline && !isExpensive && !isConstrained }

    static let wifi = Self(isOnline: true, isExpensive: false, isConstrained: false)
    /// 첫 갱신 전: 지도는 받되 저장은 하지 않는다.
    static let unknown = Self(isOnline: true, isExpensive: true, isConstrained: false)
}

protocol OfflineVectorNetworkPathProviding: Sendable {
    var current: OfflineVectorNetworkPath { get }
}

final class OfflineVectorNetworkStatus: OfflineVectorNetworkPathProviding {
    static let shared = OfflineVectorNetworkStatus()

    private let path = Mutex(OfflineVectorNetworkPath.unknown)
    private let monitor = NWPathMonitor()

    var current: OfflineVectorNetworkPath { path.withLock { $0 } }

    func start() {
        monitor.pathUpdateHandler = { [weak self] update in
            let next = OfflineVectorNetworkPath(
                isOnline: update.status == .satisfied,
                isExpensive: update.isExpensive,
                isConstrained: update.isConstrained
            )
            self?.path.withLock { $0 = next }
        }
        monitor.start(queue: DispatchQueue(label: "OfflineVectorNetworkStatus"))
    }
}

protocol OfflineVectorFetching: Sendable {
    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse)
}

/// 가로채기 프로토콜을 끼우지 않은 별도 세션으로 받는다(재귀 방지). 앱을 밝히는 User-Agent만 붙이고 개인 정보는 넣지 않는다.
struct OfflineVectorHTTPFetcher: OfflineVectorFetching {
    static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        return "BOKKIPlan/\(version) (iOS)"
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        // ephemeral: MapLibre가 자체 캐시를 두므로 URLCache에 한 번 더 쌓지 않는다.
        let configuration = URLSessionConfiguration.ephemeral
        let ours = ObjectIdentifier(OfflineVectorTileURLProtocol.self)
        configuration.protocolClasses = (configuration.protocolClasses ?? []).filter { ObjectIdentifier($0) != ours }
        return configuration
    }

    private let session = URLSession(configuration: makeConfiguration())

    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var request = request
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        return try await session.data(for: request)
    }
}

/// MapLibre가 요청한 OpenFreeMap 자원을 저장본 우선으로 돌려주고, 없으면 받아 돌려주며 Wi-Fi일 때만 저장한다.
final class OfflineVectorTileCache: Sendable {
    struct Loaded: Sendable {
        let response: HTTPURLResponse
        let data: Data
        let fromStore: Bool
    }

    static let shared = OfflineVectorTileCache(
        store: .shared,
        network: OfflineVectorNetworkStatus.shared,
        fetcher: OfflineVectorHTTPFetcher()
    )

    /// 이 표시가 붙은 요청은 다시 가로채지 않는다.
    static let handledKey = "BOKKIPlanOfflineVectorHandled"
    /// 저장 뒤 정리는 이만큼 쓰거나 이 간격이 지났을 때만 돌린다.
    static let writesPerMaintenance = 200
    static let maintenanceInterval: TimeInterval = 600

    private struct Maintenance: Sendable {
        var isRunning = false
        var writesSinceRun = 0
        var lastRun = Date.distantPast
        /// 메모리 경고 뒤 이 시각까지는 저장 뒤 정리를 미룬다(색인을 다시 만들지 않는다).
        var deferredUntil = Date.distantPast
    }

    let store: OfflineVectorTileStore
    let network: any OfflineVectorNetworkPathProviding
    let fetcher: any OfflineVectorFetching
    let limits: OfflineVectorLimits
    private let now: @Sendable () -> Date
    private let maintenance = Mutex(Maintenance())

    init(
        store: OfflineVectorTileStore,
        network: any OfflineVectorNetworkPathProviding,
        fetcher: any OfflineVectorFetching,
        limits: OfflineVectorLimits = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.network = network
        self.fetcher = fetcher
        self.limits = limits
        self.now = now
    }

    /// OpenFreeMap GET 요청만 맡는다. 다른 주소와 이미 맡은 요청은 그대로 지나간다.
    static func handles(_ request: URLRequest) -> Bool {
        guard let url = request.url, request.httpMethod ?? "GET" == "GET",
              OfflineVectorKey(url: url) != nil else { return false }
        return URLProtocol.property(forKey: handledKey, in: request) == nil
    }

    static func marked(_ request: URLRequest) -> URLRequest {
        let mutable = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(true, forKey: handledKey, in: mutable)
        return mutable as URLRequest
    }

    func load(_ request: URLRequest) async throws -> Loaded {
        guard let url = request.url, let key = OfflineVectorKey(url: url) else { throw URLError(.unsupportedURL) }
        if store.shouldServe(url, isOnline: network.current.isOnline), let stored = stored(key, url: url) {
            return stored
        }
        do {
            var outgoing = Self.marked(request)
            if network.current.allowsCaching {
                // 저장할 200 본문을 받도록 MapLibre 자체 캐시의 조건부 요청 머리를 뺀다.
                outgoing.setValue(nil, forHTTPHeaderField: "If-None-Match")
                outgoing.setValue(nil, forHTTPHeaderField: "If-Modified-Since")
            }
            let (data, response) = try await fetcher.fetch(outgoing)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            // 받는 사이 연결이 바뀌었을 수 있어 저장 직전에 다시 본다.
            if http.statusCode == 200, !data.isEmpty, key.isStorable(limits: limits), network.current.allowsCaching,
               (try? store.write(data, for: key)) != nil {
                noteWrite()
            }
            return Loaded(response: Self.passthrough(http, url: url, bytes: data.count), data: data, fromStore: false)
        } catch {
            // 연결은 있다고 나오지만 실제로 못 받으면 저장본(판 정보·글꼴 포함)으로 대신한다.
            if !(error is CancellationError), let stored = stored(key, url: url) { return stored }
            throw error
        }
    }

    /// 상한·기간 정리. 메인 스레드 밖에서 돌리고, 이미 돌고 있으면 건너뛴다.
    func scheduleMaintenance(after delay: TimeInterval = 0) {
        let shouldStart = maintenance.withLock { state -> Bool in
            guard !state.isRunning else { return false }
            state.isRunning = true
            return true
        }
        guard shouldStart else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [self] in
            runMaintenance()
        }
    }

    /// 지금 바로 정리한다(시험·백그라운드 큐용). 지운 개수를 돌려준다.
    @discardableResult
    func runMaintenance() -> Int {
        let removed = store.evict(limits: limits)
        let date = now()
        let pressured = maintenance.withLock { state -> Bool in
            state.isRunning = false
            state.writesSinceRun = 0
            state.lastRun = date
            return date < state.deferredUntil
        }
        // 메모리 경고 직후라면 정리하며 만든 색인을 다시 버린다.
        if pressured { store.purgeMemory() }
        return removed
    }

    func handleMemoryPressure() {
        let date = now()
        maintenance.withLock { $0.deferredUntil = date.addingTimeInterval(Self.maintenanceInterval) }
        store.purgeMemory()
    }

    private func noteWrite() {
        let date = now()
        let due = maintenance.withLock { state -> Bool in
            state.writesSinceRun += 1
            guard !state.isRunning, date >= state.deferredUntil else { return false }
            return state.writesSinceRun >= Self.writesPerMaintenance
                || date.timeIntervalSince(state.lastRun) >= Self.maintenanceInterval
        }
        if due { scheduleMaintenance() }
    }

    private func stored(_ key: OfflineVectorKey, url: URL) -> Loaded? {
        guard let data = store.data(for: key),
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": key.contentType, "Content-Length": "\(data.count)"]
              )
        else { return nil }
        return Loaded(response: response, data: data, fromStore: true)
    }

    /// URLSession이 이미 압축을 풀었으므로 압축·길이 머리는 실제 본문에 맞춘다.
    private static func passthrough(_ response: HTTPURLResponse, url: URL, bytes: Int) -> HTTPURLResponse {
        var headers: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            guard let name = name as? String, let value = value as? String else { continue }
            let lower = name.lowercased()
            guard lower != "content-encoding", lower != "content-length" else { continue }
            headers[name] = value
        }
        headers["Content-Length"] = "\(bytes)"
        return HTTPURLResponse(url: url, statusCode: response.statusCode, httpVersion: "HTTP/1.1", headerFields: headers)
            ?? response
    }
}

/// MapLibre 세션의 OpenFreeMap 요청을 모두 맡아 `OfflineVectorTileCache`로 처리한다.
/// 클라이언트 알림은 Apple 예제처럼 불러 준 스레드의 런루프에서 보낸다.
final class OfflineVectorTileURLProtocol: URLProtocol {
    private var loadTask: Task<Void, Never>?
    private var clientRunLoop: CFRunLoop?
    private var clientMode: CFRunLoopMode = .defaultMode
    private let stopped = Mutex(false)

    override class func canInit(with request: URLRequest) -> Bool {
        OfflineVectorTileCache.handles(request)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        clientRunLoop = CFRunLoopGetCurrent()
        clientMode = CFRunLoopMode((RunLoop.current.currentMode ?? .default).rawValue as CFString)
        let request = request
        // URLProtocol은 iOS에서 Sendable이 아니라, 결과는 한 번만 전하는 상자로 넘긴다.
        let reply = OneShotReply<Result<OfflineVectorTileCache.Loaded, any Error>> { [self] in deliver($0) }
        loadTask = Task(priority: .userInitiated) {
            do {
                reply.finish(.success(try await OfflineVectorTileCache.shared.load(request)))
            } catch {
                reply.finish(.failure(error))
            }
        }
    }

    private func deliver(_ result: Result<OfflineVectorTileCache.Loaded, any Error>) {
        guard let runLoop = clientRunLoop else { return }
        CFRunLoopPerformBlock(runLoop, clientMode.rawValue) { [self] in finish(result) }
        CFRunLoopWakeUp(runLoop)
    }

    override func stopLoading() {
        stopped.withLock { $0 = true }
        loadTask?.cancel()
    }

    private func finish(_ result: Result<OfflineVectorTileCache.Loaded, any Error>) {
        guard !stopped.withLock({ $0 }), let client else { return }
        switch result {
        case .success(let loaded):
            client.urlProtocol(self, didReceive: loaded.response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: loaded.data)
            client.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client.urlProtocol(self, didFailWithError: error)
        }
    }
}

enum OfflineVectorMap {
    /// 지도 화면이 만들어지기 전에 한 번 부른다. MapLibre 세션에만 끼우고 Apple 지도(MapKit)는 건드리지 않는다.
    @MainActor
    static func install() {
        OfflineVectorNetworkStatus.shared.start()
        let manager = MLNNetworkConfiguration.sharedManager
        let configuration: URLSessionConfiguration = manager.sessionConfiguration
        let existing = configuration.protocolClasses ?? []
        let ours = ObjectIdentifier(OfflineVectorTileURLProtocol.self)
        guard !existing.contains(where: { ObjectIdentifier($0) == ours }) else { return }
        configuration.protocolClasses = [OfflineVectorTileURLProtocol.self] + existing
        manager.sessionConfiguration = configuration

        let cache = OfflineVectorTileCache.shared
        // 시작 직후 화면을 방해하지 않도록 조금 뒤에 정리한다.
        cache.scheduleMaintenance(after: 10)
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in
            cache.scheduleMaintenance()
        }
        center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { _ in
            cache.handleMemoryPressure()
        }
    }
}
