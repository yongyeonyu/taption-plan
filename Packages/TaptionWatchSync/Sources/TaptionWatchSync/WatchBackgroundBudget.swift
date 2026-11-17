import Foundation
import Synchronization

/// watchOS 백그라운드 작업 예산(WSY1117A01). 시스템은 작업마다 수 초~15초 안에 완료 보고를
/// 기대하고, 넘기면 앱을 끝내고 다음 예산을 줄인다. 다 못 한 일은 커밋하지 않은 채
/// 남겨 다음 실행이 잇는다(원본·outbox는 이미 저장돼 있다).
public enum TaptionWatchBackgroundBudget {
    /// 앱 새로고침에서 동기화에 쓰는 시간.
    public static let refresh: Duration = .seconds(10)
    /// 연결 새로고침에서 받을 내용이 남았는지 기다리는 시간.
    public static let connectivityWait: Duration = .seconds(10)
    /// 백그라운드 한 번에 비우는 30분 창 수. 화면이 켜져 있을 때는 더 비운다.
    public static let ambientWindowsPerBackgroundRun = 1

    /// 작업을 예산 안에서만 기다린다. 넘기면 작업에 취소를 알리고 끝나기를 기다리지 않고
    /// `false`로 돌아온다. 제때 끝나면 `true`.
    public static func run(
        within budget: Duration,
        _ work: @escaping @Sendable () async -> Void
    ) async -> Bool {
        let race = Race()
        return await withCheckedContinuation { continuation in
            race.start(continuation)
            let worker = Task {
                await work()
                race.finish(true)
            }
            let timer = Task {
                try? await Task.sleep(for: budget)
                if race.finish(false) { worker.cancel() }
            }
            race.onFinish { timer.cancel() }
        }
    }

    private final class Race: Sendable {
        private struct State {
            var continuation: CheckedContinuation<Bool, Never>?
            var finished = false
            var cleanup: (@Sendable () -> Void)?
        }

        private let state = Mutex(State())

        func start(_ continuation: CheckedContinuation<Bool, Never>) {
            state.withLock { $0.continuation = continuation }
        }

        func onFinish(_ action: @escaping @Sendable () -> Void) {
            let runNow = state.withLock { state -> Bool in
                if state.finished { return true }
                state.cleanup = action
                return false
            }
            if runNow { action() }
        }

        /// 먼저 부른 쪽만 결과를 정한다. 정했으면 `true`.
        @discardableResult
        func finish(_ value: Bool) -> Bool {
            let taken = state.withLock { state -> (CheckedContinuation<Bool, Never>?, (@Sendable () -> Void)?)? in
                guard !state.finished else { return nil }
                state.finished = true
                defer {
                    state.continuation = nil
                    state.cleanup = nil
                }
                return (state.continuation, state.cleanup)
            }
            guard let taken else { return false }
            taken.1?()
            taken.0?.resume(returning: value)
            return true
        }
    }
}
