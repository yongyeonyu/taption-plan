import Foundation
import Synchronization

/// 백그라운드 `URLSession` 다운로드. 앱이 멈추거나 죽어도 시스템이 이어 받고, 끊기면 `resumeData`를 돌려준다.
/// 요청은 인증·쿠키·쿼리·식별자 없는 `GET` 하나이며 이어 받기는 `URLSession`이 `Range`·`If-Range`(ETag)로 서버와 맞춘다.
/// 앱이 죽은 사이에 끝난 파일도 `taskDescription`에 적어 둔 경로로 옮겨 두어 다음 실행이 곧바로 검증한다.
public final class SeasonPackBackgroundEngine: NSObject, SeasonPackDownloadEngine, URLSessionDownloadDelegate, Sendable {
    private struct Pending {
        var continuation: CheckedContinuation<SeasonPackEngineOutcome, Never>
        var progress: @Sendable (Int64, Int64) -> Void
    }
    private struct State {
        var pending: [Int: Pending] = [:]
        var finishedFor: [Int: SeasonPackEngineOutcome] = [:]
        var systemCompletion: (@MainActor @Sendable () -> Void)?
    }

    private let identifier: String
    private let state = Mutex(State())
    private let sessionBox = Mutex<URLSession?>(nil)

    public init(identifier: String) {
        self.identifier = identifier
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.timeoutIntervalForRequest = 30
        sessionBox.withLock { $0 = URLSession(configuration: configuration, delegate: self, delegateQueue: nil) }
    }

    /// 앱 델리게이트 `handleEventsForBackgroundURLSession`에서 부른다.
    public func handleEvents(forIdentifier id: String, completion: @escaping @MainActor @Sendable () -> Void) {
        guard id == identifier else { Task { @MainActor in completion() }; return }
        state.withLock { $0.systemCompletion = completion }
    }

    public func download(from url: URL, resumeData: Data?, allowsCellular: Bool, to destination: URL,
                         progress: @escaping @Sendable (Int64, Int64) -> Void) async -> SeasonPackEngineOutcome {
        guard let session = sessionBox.withLock({ $0 }) else { return .failed("no-session") }
        let task: URLSessionDownloadTask
        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            request.httpMethod = "GET"
            request.httpShouldHandleCookies = false
            request.allowsCellularAccess = allowsCellular
            task = session.downloadTask(with: request)
        }
        task.taskDescription = destination.path
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<SeasonPackEngineOutcome, Never>) in
                state.withLock { $0.pending[task.taskIdentifier] = Pending(continuation: continuation, progress: progress) }
                task.resume()
            }
        } onCancel: {
            task.cancel(byProducingResumeData: { [weak self] data in
                self?.complete(task.taskIdentifier, .interrupted(resumeData: data))
            })
        }
    }

    private func complete(_ id: Int, _ outcome: SeasonPackEngineOutcome) {
        let pending = state.withLock { $0.pending.removeValue(forKey: id) }
        pending?.continuation.resume(returning: outcome)
    }

    // MARK: URLSessionDownloadDelegate

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let progress = state.withLock { $0.pending[downloadTask.taskIdentifier]?.progress }
        progress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || status == 206, let path = downloadTask.taskDescription else {
            state.withLock { $0.finishedFor[downloadTask.taskIdentifier] = .failed("status \(status)") }
            return
        }
        // 이 콜백이 끝나면 임시 파일이 지워지므로 여기서 옮긴다.
        let destination = URL(fileURLWithPath: path)
        let fm = FileManager.default
        try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: destination)
        let outcome: SeasonPackEngineOutcome = (try? fm.moveItem(at: location, to: destination)) != nil ? .finished : .failed("move")
        state.withLock { $0.finishedFor[downloadTask.taskIdentifier] = outcome }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier
        if let finished = state.withLock({ $0.finishedFor.removeValue(forKey: id) }) {
            complete(id, error == nil ? finished : .interrupted(resumeData: nil))
            return
        }
        let resume = ((error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData]) as? Data
        complete(id, .interrupted(resumeData: resume))
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = state.withLock { state -> (@MainActor @Sendable () -> Void)? in defer { state.systemCompletion = nil }; return state.systemCompletion }
        if let completion { Task { @MainActor in completion() } }
    }
}
