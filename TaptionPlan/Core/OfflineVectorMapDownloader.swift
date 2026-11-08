import Foundation
@preconcurrency import MapLibre
import Network
import Observation
import Synchronization
import UIKit

protocol OfflineVectorFetching: Sendable {
    func data(from url: URL) async throws -> Data
}

/// OpenFreeMap 약관대로 앱을 밝히는 User-Agent를 붙인다. 개인 정보는 넣지 않는다.
struct OfflineVectorHTTPFetcher: OfflineVectorFetching {
    struct BadStatus: Error {}

    static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        return "BOKKIPlan-OfflineMap/\(version) (iOS)"
    }

    private let session: URLSession

    init(limits: OfflineVectorLimits = .standard) {
        // ephemeral: URLCache에 같은 타일을 한 번 더 쌓지 않는다.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = limits.maxParallel
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
    }

    func data(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw BadStatus() }
        return data
    }
}

/// 한 번의 내려받기. 이미 저장된 타일은 건너뛰어 끊긴 뒤 다시 누르면 이어 받는다.
enum OfflineVectorDownloadRun {
    struct Outcome: Equatable, Sendable {
        var fetched = 0
        var skipped = 0
        var failed = 0
        var bytes = 0
        var reachedByteCap = false
    }

    struct NoTileTemplate: Error {}

    static func run(
        plan: OfflineVectorDownloadPlan,
        store: OfflineVectorTileStore,
        fetcher: some OfflineVectorFetching,
        limits: OfflineVectorLimits = .standard,
        pause: Duration = .milliseconds(100),
        onProgress: @escaping @Sendable (Int, Int) async -> Void = { _, _ in }
    ) async throws -> Outcome {
        guard plan.problem == nil else { return Outcome() }
        defer { store.enforceLimit(maxBytes: limits.storeBytes, maxFiles: limits.storeFiles) }
        var outcome = Outcome()

        let tileJSON = try await fetcher.data(from: OfflineVectorResources.tileJSONURL)
        guard let template = tileTemplate(from: tileJSON) else { throw NoTileTemplate() }
        try store.write(tileJSON, for: .resource("planet"))
        outcome.bytes += tileJSON.count
        for url in OfflineVectorResources.urls.dropFirst() {
            try Task.checkCancellation()
            guard let key = OfflineVectorKey(url: url), let data = try? await fetcher.data(from: url) else {
                outcome.failed += 1
                continue
            }
            try store.write(data, for: key)
            outcome.bytes += data.count
        }

        let maxZoom = template.maxZoom ?? limits.maxZoom
        let ids = OfflineVectorTileMath.tileIDs(plan.bounds, zooms: plan.zooms).filter { $0.z <= maxZoom }
        let pending = ids.filter { !store.contains(.tile($0)) }
        outcome.skipped = ids.count - pending.count
        let total = ids.count
        await onProgress(outcome.skipped, total)

        try await withThrowingTaskGroup(of: Int?.self) { group in
            var iterator = pending.makeIterator()
            func addNext() -> Bool {
                guard let id = iterator.next() else { return false }
                group.addTask {
                    try Task.checkCancellation()
                    let data = try? await fetcher.data(from: template.url(for: id))
                    if let data { try store.write(data, for: .tile(id)) }
                    try await Task.sleep(for: pause)
                    return data?.count
                }
                return true
            }
            // 약관 상한(병렬 4개)을 넘지 않는다.
            for _ in 0..<max(1, min(limits.maxParallel, 4)) {
                guard addNext() else { break }
            }
            while let bytes = try await group.next() {
                if let bytes {
                    outcome.fetched += 1
                    outcome.bytes += bytes
                } else {
                    outcome.failed += 1
                }
                let done = outcome.skipped + outcome.fetched + outcome.failed
                if done % 10 == 0 || done == total { await onProgress(done, total) }
                if outcome.bytes > limits.perDownloadBytes {
                    outcome.reachedByteCap = true
                    group.cancelAll()
                    break
                }
                _ = addNext()
            }
        }
        return outcome
    }

    struct TileTemplate: Sendable {
        let template: String
        let maxZoom: Int?

        func url(for id: OfflineVectorTileID) -> URL {
            URL(string: template
                .replacingOccurrences(of: "{z}", with: "\(id.z)")
                .replacingOccurrences(of: "{x}", with: "\(id.x)")
                .replacingOccurrences(of: "{y}", with: "\(id.y)"))!
        }
    }

    static func tileTemplate(from tileJSON: Data) -> TileTemplate? {
        guard let object = try? JSONSerialization.jsonObject(with: tileJSON) as? [String: Any],
              let template = (object["tiles"] as? [String])?.first,
              template.hasPrefix("https://\(OfflineVectorResources.host)/planet/")
        else { return nil }
        return TileTemplate(template: template, maxZoom: object["maxzoom"] as? Int)
    }
}

/// iOS가 알려 준 네트워크 연결 상태. 판 정보·글꼴은 끊겼을 때만 저장본을 쓴다.
final class OfflineVectorNetworkStatus: Sendable {
    static let shared = OfflineVectorNetworkStatus()

    private let online = Mutex(true)
    private let monitor = NWPathMonitor()

    var isOnline: Bool { online.withLock { $0 } }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.online.withLock { $0 = path.status == .satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "OfflineVectorNetworkStatus"))
    }
}

/// MapLibre 요청 중 저장본이 있는 것만 가로채 파일에서 돌려준다. 없으면 MapLibre가 그대로 네트워크로 받는다.
final class OfflineVectorTileURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url, request.httpMethod ?? "GET" == "GET" else { return false }
        return OfflineVectorTileStore.shared.shouldServe(url, isOnline: OfflineVectorNetworkStatus.shared.isOnline)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let key = OfflineVectorKey(url: url),
              let data = OfflineVectorTileStore.shared.data(for: key),
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": key.contentType, "Content-Length": "\(data.count)"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
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
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { _ in
            OfflineVectorTileStore.shared.purgeMemory()
        }
    }
}

/// 메뉴 시트가 닫혀도 내려받기를 이어 가도록 하나만 둔다.
@MainActor
@Observable
final class OfflineVectorMapController {
    enum Phase: Equatable {
        case idle
        case downloading(done: Int, total: Int)
        case finished(OfflineVectorDownloadRun.Outcome)
        case cancelled
        case failed
    }

    static let shared = OfflineVectorMapController()

    private(set) var phase: Phase = .idle
    private(set) var summary = OfflineVectorTileStore.Summary()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored let store: OfflineVectorTileStore
    @ObservationIgnored let fetcher: any OfflineVectorFetching

    init(store: OfflineVectorTileStore = .shared, fetcher: any OfflineVectorFetching = OfflineVectorHTTPFetcher()) {
        self.store = store
        self.fetcher = fetcher
    }

    var isDownloading: Bool {
        if case .downloading = phase { return true }
        return false
    }

    func refreshSummary() async {
        let next = await Self.loadSummary(store)
        if next != summary { summary = next }
    }

    func start(_ plan: OfflineVectorDownloadPlan) {
        guard !isDownloading, plan.problem == nil else { return }
        phase = .downloading(done: 0, total: plan.tileCount)
        let store = store, fetcher = fetcher
        task = Task {
            do {
                let outcome = try await Self.download(plan, store: store, fetcher: fetcher) { [weak self] done, total in
                    await self?.showProgress(done: done, total: total)
                }
                phase = .finished(outcome)
            } catch is CancellationError {
                phase = .cancelled
            } catch {
                phase = Task.isCancelled ? .cancelled : .failed
            }
            task = nil
            await refreshSummary()
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func showProgress(done: Int, total: Int) {
        guard isDownloading else { return }
        phase = .downloading(done: done, total: total)
    }

    func deleteAll() async {
        cancel()
        await Self.removeAll(store)
        phase = .idle
        await refreshSummary()
    }

    // 메인 스레드 밖(전역 실행기)에서 디렉터리를 훑고 파일을 쓴다.
    private nonisolated static func loadSummary(_ store: OfflineVectorTileStore) async -> OfflineVectorTileStore.Summary {
        store.summary()
    }

    private nonisolated static func removeAll(_ store: OfflineVectorTileStore) async {
        store.removeAll()
    }

    private nonisolated static func download(
        _ plan: OfflineVectorDownloadPlan,
        store: OfflineVectorTileStore,
        fetcher: any OfflineVectorFetching,
        onProgress: @escaping @Sendable (Int, Int) async -> Void
    ) async throws -> OfflineVectorDownloadRun.Outcome {
        try await OfflineVectorDownloadRun.run(plan: plan, store: store, fetcher: fetcher, onProgress: onProgress)
    }
}
