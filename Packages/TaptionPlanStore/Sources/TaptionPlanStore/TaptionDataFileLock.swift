import Darwin
import Foundation

public final class TaptionDataFileLock: @unchecked Sendable {
    public enum AcquireError: Error {
        case busy
    }

    private var descriptor: Int32

    private init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        descriptor = Darwin.open(
            url.path,
            O_CREAT | O_RDWR,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    public static func acquireIfAvailable(url: URL) throws -> TaptionDataFileLock {
        let lock = try TaptionDataFileLock(url: url)
        guard flock(lock.descriptor, LOCK_EX | LOCK_NB) != 0 else {
            return lock
        }
        do {
            let code = errno
            lock.unlock()
            if code == EWOULDBLOCK || code == EAGAIN {
                throw AcquireError.busy
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
    }

    public static func acquire(url: URL) async throws -> TaptionDataFileLock {
        while true {
            try Task.checkCancellation()
            do {
                return try acquireIfAvailable(url: url)
            } catch AcquireError.busy {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    public static func withLock<Value>(
        url: URL,
        _ operation: () throws -> Value
    ) throws -> Value {
        let lock = try acquireIfAvailable(url: url)
        defer { lock.unlock() }
        return try operation()
    }

    public func unlock() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit {
        unlock()
    }
}
