import Foundation

/// 응답과 시간 초과처럼 여러 쪽이 끝낼 수 있는 일을 먼저 온 한 번만 전달한다.
final class OneShotReply<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var deliver: ((Value) -> Void)?

    init(_ deliver: @escaping (Value) -> Void) {
        self.deliver = deliver
    }

    convenience init(_ continuation: CheckedContinuation<Value, Never>) {
        self.init { continuation.resume(returning: $0) }
    }

    func finish(_ value: Value) {
        lock.lock()
        let pending = deliver
        deliver = nil
        lock.unlock()
        pending?(value)
    }
}
