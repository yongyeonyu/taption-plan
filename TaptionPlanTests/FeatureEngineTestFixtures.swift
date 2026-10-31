import XCTest
import UIKit
import CoreLocation
import StoreKit
import StoreKitTest
import TaptionPlanCore
@testable import TaptionPlan

/// FeatureEngineTests와 OfficeStayAbsorptionTests가 함께 쓰는 UTC 달력·날짜 생성 도우미.
protocol UTCDateFixture {}

extension UTCDateFixture {
    var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        return calendar
    }

    func makeDate(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 0,
        _ minute: Int = 0
    ) -> Date {
        utcCalendar.date(
            from: DateComponents(
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute
            )
        )!
    }
}

final class ClassificationRevisionAdvanceGate: @unchecked Sendable {
    private let fence: ActivityClassificationRevisionFence
    private let advanceAtCheckpoint: Int
    private let lock = NSLock()
    private var checkpoints = 0

    init(fence: ActivityClassificationRevisionFence, advanceAtCheckpoint: Int) {
        self.fence = fence
        self.advanceAtCheckpoint = advanceAtCheckpoint
    }

    func check(_ expectedRevision: UInt64) throws {
        lock.lock()
        checkpoints += 1
        let shouldAdvance = checkpoints == advanceAtCheckpoint
        lock.unlock()
        if shouldAdvance { fence.advance(to: expectedRevision &+ 1) }
        try fence.check(expectedRevision)
    }
}

private struct RawArchiveWatchFixture: Codable, Hashable {
    var sampleCount: Int
    var mode: String
}

actor PermissionCountingPlanRepository: PlanDataRepository {
    private var value = TaptionDataSnapshot.empty
    private(set) var saveCount = 0

    func load() async throws -> TaptionDataSnapshot { value }

    func save(_ snapshot: TaptionDataSnapshot) async throws {
        saveCount += 1
        value = snapshot
    }
}

actor RejectingSavePlanRepository: PlanDataRepository {
    private let snapshot: TaptionDataSnapshot

    init(snapshot: TaptionDataSnapshot = .empty) {
        self.snapshot = snapshot
    }

    func load() async throws -> TaptionDataSnapshot {
        snapshot
    }

    func save(_ snapshot: TaptionDataSnapshot) async throws {
        throw RepositoryError.invalidSnapshot
    }
}

actor RecoveringLoadPlanRepository: PlanDataRepository {
    private var snapshot: TaptionDataSnapshot
    private var shouldFailNextLoad = true

    init(snapshot: TaptionDataSnapshot) {
        self.snapshot = snapshot
    }

    func load() async throws -> TaptionDataSnapshot {
        if shouldFailNextLoad {
            shouldFailNextLoad = false
            throw PlanRepositoryAvailabilityError.unavailable
        }
        return snapshot
    }

    func save(_ snapshot: TaptionDataSnapshot) async throws {
        self.snapshot = snapshot
    }
}

actor GatedStartupPlanRepository: PlanDataRepository {
    private enum FixtureError: Error { case invalidHistory }
    private var value: TaptionDataSnapshot
    private let failsHistory: Bool
    private var holdsStartup: Bool
    private var startupStarted = false
    private var startupWaiters: [CheckedContinuation<Void, Never>] = []
    private var startupStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var saves = 0

    init(snapshot: TaptionDataSnapshot, failsHistory: Bool = false, holdsStartup: Bool = false) {
        value = snapshot
        self.failsHistory = failsHistory
        self.holdsStartup = holdsStartup
    }

    func loadStartupSnapshot() async throws -> TaptionDataSnapshot? {
        var startup = TaptionDataSnapshot.empty
        startup.settings = value.settings
        startup.updatedAt = value.updatedAt
        startupStarted = true
        let startWaiters = startupStartWaiters
        startupStartWaiters.removeAll()
        startWaiters.forEach { $0.resume() }
        if holdsStartup { await withCheckedContinuation { startupWaiters.append($0) } }
        try Task.checkCancellation()
        return startup
    }

    func load() async throws -> TaptionDataSnapshot {
        let captured = value
        if !released { await withCheckedContinuation { waiters.append($0) } }
        try Task.checkCancellation()
        if failsHistory { throw FixtureError.invalidHistory }
        return captured
    }

    func waitUntilStartupStarted() async {
        if !startupStarted { await withCheckedContinuation { startupStartWaiters.append($0) } }
    }

    func releaseStartup() {
        holdsStartup = false
        let pending = startupWaiters
        startupWaiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func releaseHistory() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func save(_ snapshot: TaptionDataSnapshot) async throws { saves += 1; value = snapshot }
    func deleteAll() async throws { value = .empty }
}

actor GatedSavePlanRepository: PlanDataRepository {
    private var storedSnapshot: TaptionDataSnapshot
    private var saveCount = 0
    private var firstSaveWaiter: CheckedContinuation<Void, Never>?
    private var firstSaveRelease: CheckedContinuation<Void, Never>?
    private var saveCountWaiters: [Int: CheckedContinuation<Void, Never>] = [:]

    init(snapshot: TaptionDataSnapshot) {
        storedSnapshot = snapshot
    }

    func load() async throws -> TaptionDataSnapshot {
        storedSnapshot
    }

    func save(_ snapshot: TaptionDataSnapshot) async throws {
        saveCount += 1
        let readyTargets = saveCountWaiters.keys.filter { $0 <= saveCount }
        for target in readyTargets {
            saveCountWaiters.removeValue(forKey: target)?.resume()
        }
        firstSaveWaiter?.resume()
        firstSaveWaiter = nil
        if saveCount == 1 {
            await withCheckedContinuation { continuation in
                firstSaveRelease = continuation
            }
        }
        storedSnapshot = snapshot
    }

    func waitForFirstSave() async {
        guard saveCount == 0 else { return }
        await withCheckedContinuation { continuation in
            firstSaveWaiter = continuation
        }
    }

    func releaseFirstSave() {
        firstSaveRelease?.resume()
        firstSaveRelease = nil
    }

    func waitForSaveCount(_ target: Int) async {
        guard saveCount < target else { return }
        await withCheckedContinuation { continuation in
            saveCountWaiters[target] = continuation
        }
    }
}

actor CancellationSavePlanRepository: PlanDataRepository {
    private let snapshot: TaptionDataSnapshot

    init(snapshot: TaptionDataSnapshot) {
        self.snapshot = snapshot
    }

    func load() async throws -> TaptionDataSnapshot {
        snapshot
    }

    func save(_ snapshot: TaptionDataSnapshot) async throws {
        throw CancellationError()
    }
}

final class AirQualityURLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler:
        ((URLRequest) throws -> (Int, Data))?
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requestCount += 1
        guard let handler = Self.handler else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

actor HealthRefreshCallCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

actor ControlledTransitBoardingRepository: PlanDataRepository {
    private var value: TaptionDataSnapshot
    private var rejects = false
    private var holds = false
    private var pending = false
    private var release: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?

    init(snapshot: TaptionDataSnapshot) { value = snapshot }
    func load() async throws -> TaptionDataSnapshot { value }
    func save(_ snapshot: TaptionDataSnapshot) async throws {
        if !snapshot.settings.transitBoardingDecisions.isEmpty || !snapshot.settings.predictedRouteDecisions.isEmpty {
            if rejects { throw RepositoryError.invalidSnapshot }
            if holds {
                pending = true
                arrival?.resume()
                arrival = nil
                await withCheckedContinuation { release = $0 }
            }
        }
        value = snapshot
    }
    func rejectConfirmations() { rejects = true }
    func holdConfirmations() { holds = true }
    func waitForConfirmationWrite() async {
        if !pending { await withCheckedContinuation { arrival = $0 } }
    }
    func releaseConfirmation() {
        holds = false
        release?.resume()
        release = nil
    }
}

final class StubWeatherAttributionProvider:
    WeatherAttributionProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let result: Result<WeatherAttributionInfo, Error>

    init(result: Result<WeatherAttributionInfo, Error>) {
        self.result = result
    }

    var callCount: Int { lock.withLock { calls } }

    func attribution() async throws -> WeatherAttributionInfo {
        lock.withLock { calls += 1 }
        return try result.get()
    }
}

/// 적재가 늘 실패하는 저장소. 배경 갱신이 "새로 선 오류"를 실패로 보고하는지 본다.
actor FailingPlanRepository: PlanDataRepository {
    func load() async throws -> TaptionDataSnapshot {
        throw CocoaError(.fileReadCorruptFile)
    }

    func save(_ snapshot: TaptionDataSnapshot) async throws {}

    func deleteAll() async throws {}
}

/// 저장 횟수를 세는 저장소. 배경 갱신이 무거운 경로(저장까지)를 돌았는지 본다.
actor CountingPlanRepository: PlanDataRepository {
    private let snapshot: TaptionDataSnapshot
    private(set) var saveCount = 0

    init(snapshot: TaptionDataSnapshot) {
        self.snapshot = snapshot
    }

    func load() async throws -> TaptionDataSnapshot {
        snapshot
    }

    func save(_ snapshot: TaptionDataSnapshot) async throws {
        saveCount += 1
    }

    func deleteAll() async throws {}
}
