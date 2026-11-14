import Foundation

enum ShareChannelError: Error {
    /// 보내지 못했다(닫혔거나 너무 큼). HTTP로 다시 해도 된다.
    case unavailable
    /// 보낸 뒤 응답 전에 끊기거나 시간이 지났다.
    case interrupted
}

/// 소켓 하나의 읽기 고리. 응답(`res`)은 기다리는 요청에 돌려주고, 나머지는 `events`로 내보낸다.
actor ShareSocketChannel {
    nonisolated let events: AsyncStream<ShareSocketEvent>
    private let continuation: AsyncStream<ShareSocketEvent>.Continuation
    private let socket: any ShareSocket
    private let timeout: TimeInterval
    private var pending: [Int: CheckedContinuation<ShareSocketResponse, any Error>] = [:]
    private var timers: [Int: Task<Void, Never>] = [:]
    private var nextID = 1
    private var reader: Task<Void, Never>?
    private(set) var isOpen = true

    init(socket: any ShareSocket, timeout: TimeInterval) {
        self.socket = socket
        self.timeout = timeout
        (events, continuation) = AsyncStream.makeStream(of: ShareSocketEvent.self)
    }

    func start() {
        guard reader == nil, isOpen else { return }
        reader = Task { [weak self, socket] in
            while true {
                do {
                    let text = try await socket.receive()
                    guard let self else { return }
                    await self.accept(text)
                } catch {
                    await self?.finish(code: (error as? ShareSocketClosed)?.code ?? 1006)
                    return
                }
            }
        }
    }

    func request(op: String, body: some Encodable & Sendable) async throws -> ShareSocketResponse {
        guard isOpen else { throw ShareChannelError.unavailable }
        let id = nextID
        nextID += 1
        let text = try ShareJSON.string(ShareSocketRequest(id: id, op: op, body: body))
        guard text.utf8.count <= ShareConstants.bodyBytes else { throw ShareChannelError.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timers[id] = Task { [socket, timeout] in
                do { try await socket.send(text) } catch {
                    self.fail(id, .unavailable)
                    return
                }
                try? await Task.sleep(for: .seconds(timeout))
                if !Task.isCancelled { self.fail(id, .interrupted) }
            }
        }
    }

    /// 글자 `ping`. 서버가 `pong`으로 답한다(읽기 고리가 삼킨다).
    func ping() async {
        guard isOpen else { return }
        do { try await socket.send("ping") } catch { finish(code: 1006) }
    }

    func close() async {
        guard isOpen else { return }
        shut(.other(1000), notify: false)
        await socket.close(code: 1000)
    }

    private func accept(_ text: String) {
        guard isOpen, let message = try? ShareSocketMessage.parse(text) else { return }
        switch message {
        case .pong:
            break
        case .response(let response):
            guard let id = response.id, let waiter = pending.removeValue(forKey: id) else { return }
            timers.removeValue(forKey: id)?.cancel()
            waiter.resume(returning: response)
        default:
            continuation.yield(.message(message))
        }
    }

    private func finish(code: Int) {
        guard isOpen else { return }
        shut(ShareSocketClose(code: code), notify: true)
    }

    private func shut(_ close: ShareSocketClose, notify: Bool) {
        isOpen = false
        reader?.cancel()
        for id in Array(pending.keys) { fail(id, .interrupted) }
        if notify { continuation.yield(.closed(close)) }
        continuation.finish()
    }

    private func fail(_ id: Int, _ error: ShareChannelError) {
        timers.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }
}
