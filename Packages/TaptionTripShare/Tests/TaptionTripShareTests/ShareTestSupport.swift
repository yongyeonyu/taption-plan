import Foundation
import XCTest
@testable import TaptionTripShare
import TaptionTripShareTesting

/// 세션에 넣는 시계와 기다림. 기다림은 시험이 `release`로 풀어 줄 때까지 멈춰 있다.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var nowMs: Int
    private var nextID = 0
    private var waiting: [(id: Int, wait: ShareWait, continuation: CheckedContinuation<Void, any Error>)] = []
    private var history: [(wait: ShareWait, seconds: TimeInterval)] = []

    init(nowMs: Int = 1_900_000_000_000) { self.nowMs = nowMs }

    var environment: ShareSessionEnvironment {
        ShareSessionEnvironment(
            now: { Date(timeIntervalSince1970: Double(self.now) / 1000) },
            sleep: { wait, seconds in try await self.sleep(wait, seconds) },
            jitter: { 0 }
        )
    }

    var now: Int { lock.withLock { nowMs } }
    func advance(milliseconds: Int) { lock.withLock { nowMs += milliseconds } }

    /// 지금까지 청한 기다림의 길이들.
    func requested(_ wait: ShareWait) -> [TimeInterval] {
        lock.withLock { history.filter { $0.wait == wait }.map(\.seconds) }
    }

    func pending(_ wait: ShareWait) -> Int {
        lock.withLock { waiting.filter { $0.wait == wait }.count }
    }

    /// 그 종류의 기다림을 하나 끝낸다.
    @discardableResult
    func release(_ wait: ShareWait) -> Bool {
        let found: CheckedContinuation<Void, any Error>? = lock.withLock {
            guard let index = waiting.firstIndex(where: { $0.wait == wait }) else { return nil }
            return waiting.remove(at: index).continuation
        }
        found?.resume()
        return found != nil
    }

    private func sleep(_ wait: ShareWait, _ seconds: TimeInterval) async throws {
        let id: Int = lock.withLock {
            nextID += 1
            history.append((wait, seconds))
            return nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let cancelled = lock.withLock {
                    if Task.isCancelled { return true }
                    waiting.append((id, wait, continuation))
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let found: CheckedContinuation<Void, any Error>? = lock.withLock {
                guard let index = waiting.firstIndex(where: { $0.id == id }) else { return nil }
                return waiting.remove(at: index).continuation
            }
            found?.resume(throwing: CancellationError())
        }
    }
}

/// 메모리 안의 비밀 저장소(앱에서는 키체인).
final class MemorySecretStore: ShareSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var table: [String: ShareRoomSecrets] = [:]

    func secrets(roomID: String) throws -> ShareRoomSecrets? { lock.withLock { table[roomID] } }
    func save(_ secrets: ShareRoomSecrets, roomID: String) throws { lock.withLock { table[roomID] = secrets } }
    func remove(roomID: String) throws { lock.withLock { table[roomID] = nil } }
}

/// 가짜 서버 위의 방 하나와 거기 붙는 사람들.
struct TestRoom {
    static let appKey = "app-registration-key-for-tests"
    static let password = "가을여행-2031"

    let server: ShareFakeServer
    let invite: ShareInvite
    let keys: ShareKeys
    let ownerKey: String
    let owner: ShareEntry

    /// 방을 만든다. 키 유도는 시험이 빨리 돌게 반복을 줄인다(60만 회는 벡터 시험이 본다).
    static func make(server: ShareFakeServer = ShareFakeServer()) async throws -> TestRoom {
        let invite = ShareInvite.make()
        let keys = try derive(invite, password)
        let ownerKey = ShareIdentifiers.ownerKey()
        let request = ShareCreateRequest(roomID: invite.roomID, proof: keys.proof, ownerKey: ownerKey, expiresAt: await server.now + 30 * 86_400_000)
        let entry = try await ShareRoomClient.createRoom(transport: server.transport, appKey: appKey, request: request)
        return TestRoom(server: server, invite: invite, keys: keys, ownerKey: ownerKey, owner: entry)
    }

    static func derive(_ invite: ShareInvite, _ password: String) throws -> ShareKeys {
        try ShareKeys.derive(roomID: invite.roomID, linkSecret: invite.linkSecret, password: password, iterations: 20)
    }

    var roomID: String { invite.roomID }

    func join() async throws -> ShareEntry {
        try await ShareRoomClient.join(transport: server.transport, roomID: roomID, proof: keys.proof)
    }

    func client(_ entry: ShareEntry) -> ShareRoomClient {
        ShareRoomClient(transport: server.transport, roomID: roomID, token: entry.token, ownerKey: entry.member == 1 ? ownerKey : nil, socketTimeout: 2)
    }

    func session(_ entry: ShareEntry, clock: TestClock, keys: ShareKeys? = nil, snapshot: ShareRoomSnapshot? = nil) -> ShareRoomSession {
        ShareRoomSession(roomID: roomID, member: entry.member, epoch: entry.epoch, keys: keys ?? self.keys, client: client(entry),
                         snapshot: snapshot, environment: clock.environment)
    }

    /// 세션을 시작하고 `live`가 될 때까지 기다린다.
    func liveSession(_ entry: ShareEntry, clock: TestClock, file: StaticString = #filePath, line: UInt = #line) async throws -> ShareRoomSession {
        let session = session(entry, clock: clock)
        await session.start()
        try await eventually(file: file, line: line) { await session.view().status == .live }
        return session
    }
}

/// 조건이 참이 될 때까지 잠깐씩 기다린다.
func eventually(_ what: String = "", timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
                _ condition: () async throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("기다린 일이 일어나지 않았다 \(what)", file: file, line: line)
    throw CancellationError()
}

/// 던진 오류가 기대한 `ShareError`인지 본다.
func assertThrows<T: Sendable>(_ expected: ShareError, file: StaticString = #filePath, line: UInt = #line, _ work: () async throws -> T) async {
    do {
        _ = try await work()
        XCTFail("오류가 나야 한다: \(expected)", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? ShareError, expected, file: file, line: line)
    }
}

/// 서버 오류의 코드만 본다. 오류를 돌려준다.
@discardableResult
func assertServerError<T: Sendable>(_ code: ShareErrorCode, file: StaticString = #filePath, line: UInt = #line, _ work: () async throws -> T) async -> ShareServerError? {
    do {
        _ = try await work()
        XCTFail("서버 오류가 나야 한다: \(code)", file: file, line: line)
    } catch ShareError.server(let error) {
        XCTAssertEqual(error.code, code, file: file, line: line)
        return error
    } catch {
        XCTFail("다른 오류: \(error)", file: file, line: line)
    }
    return nil
}

func plan(_ title: String, day: String = "2031-05-06") -> ShareContent {
    .plan(SharePlanContent(day: day, title: title))
}

extension ShareRoomView {
    var titles: [String] {
        items.compactMap { item -> String? in
            if case .plan(let plan) = item.content { return plan.title }
            return nil
        }.sorted()
    }
}
