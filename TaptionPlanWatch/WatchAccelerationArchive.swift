import CoreMotion
import CoreLocation
import HealthKit
import TaptionWatchBehaviorML
import WatchKit
import WidgetKit

enum WatchWorkoutDeletionError: Error {
    case unsuccessful
}

final class WatchHealthQueryCancellation<Value: Sendable>: @unchecked Sendable {
    let healthStore: HKHealthStore
    private let cancellationValue: Value
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var query: HKQuery?
    private var finished = false

    init(healthStore: HKHealthStore, cancellationValue: Value) {
        self.healthStore = healthStore
        self.cancellationValue = cancellationValue
    }

    func setContinuation(
        _ continuation: CheckedContinuation<Value, Never>
    ) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            continuation.resume(returning: cancellationValue)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func setQuery(_ query: HKQuery) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        self.query = query
        return true
    }

    func execute() {
        lock.lock()
        guard !finished, let query else {
            lock.unlock()
            return
        }
        lock.unlock()
        healthStore.execute(query)
    }

    func finish(_ value: Value) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = continuation
        self.continuation = nil
        query = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }

    func cancel() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let query = query
        self.query = nil
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        if let query {
            healthStore.stop(query)
        }
        continuation?.resume(returning: cancellationValue)
    }
}

typealias WatchAccelerationArchiveSample = TaptionWatchAccelerationSample

actor WatchAccelerationArchive {
    private let directoryURL: URL
    let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let calendar = Calendar(identifier: .gregorian)
    private let retentionInterval: TimeInterval = 31 * 86_400
    private var appendIndexes: [String: TaptionWatchAccelerationArchiveAppendIndex] = [:]
    private var filesNeedLineSeparator = Set<String>()

    init(fileManager: FileManager = .default) {
        let root = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? URL.temporaryDirectory
        directoryURL = root.appendingPathComponent(
            "TaptionPlan/Acceleration",
            isDirectory: true
        )
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
    }

    func append(_ samples: [WatchAccelerationArchiveSample]) throws {
        guard !samples.isEmpty else { return }
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directoryURL.path
        )
        let grouped = Dictionary(grouping: samples) {
            monthKey(for: $0.capturedAt)
        }
        for (month, values) in grouped {
            let url = directoryURL.appendingPathComponent(
                "watch-acceleration-\(month).jsonl"
            )
            let ambientSessions = Set(values.compactMap {
                $0.isAmbient ? $0.sessionID : nil
            })
            var index = try appendIndexes[month]
                ?? loadAppendIndex(
                    for: month,
                    at: url,
                    trackingAmbientSessions: ambientSessions
                )
            index.trackAmbientSessions(ambientSessions)
            let ordered = values.sorted {
                if $0.capturedAt == $1.capturedAt {
                    return $0.sequence < $1.sequence
                }
                return $0.capturedAt < $1.capturedAt
            }
            let unique = ordered.filter { index.insert($0) }
            guard !unique.isEmpty else {
                appendIndexes[month] = index
                continue
            }
            let lines = try unique.map { sample in
                var data = try encoder.encode(sample)
                data.append(0x0A)
                return data
            }
            var payload = lines.reduce(into: Data()) { result, line in
                result.append(line)
            }
            if filesNeedLineSeparator.contains(month) {
                payload.insert(0x0A, at: 0)
            }
            do {
                if fileManager.fileExists(atPath: url.path) {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try fileManager.setAttributes(
                        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                        ofItemAtPath: url.path
                    )
                    handle.seekToEndOfFile()
                    try handle.write(contentsOf: payload)
                } else {
                    try payload.write(
                        to: url,
                        options: [
                            .atomic,
                            .completeFileProtectionUntilFirstUserAuthentication,
                        ]
                    )
                }
                try fileManager.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: url.path
                )
            } catch {
                appendIndexes[month] = nil
                filesNeedLineSeparator.remove(month)
                throw error
            }
            appendIndexes[month] = index
            filesNeedLineSeparator.remove(month)
        }
        try prune()
    }

    func deleteAll() throws {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: directoryURL)
        appendIndexes.removeAll(keepingCapacity: false)
        filesNeedLineSeparator.removeAll(keepingCapacity: false)
    }

    private func loadAppendIndex(
        for month: String,
        at url: URL,
        trackingAmbientSessions: Set<UUID>
    ) throws -> TaptionWatchAccelerationArchiveAppendIndex {
        guard FileManager.default.fileExists(atPath: url.path) else {
            filesNeedLineSeparator.remove(month)
            return TaptionWatchAccelerationArchiveAppendIndex()
        }
        let (data, endsWithNewline) = try WatchFileTail.read(url) // 끝부분만 읽는다(WCH1110A01)
        if endsWithNewline { filesNeedLineSeparator.remove(month) } else { filesNeedLineSeparator.insert(month) }
        var index = TaptionWatchAccelerationArchiveAppendIndex()
        index.trackAmbientSessions(trackingAmbientSessions)
        for line in data.split(separator: 0x0A) {
            guard let sample = try? decoder.decode(
                TaptionWatchAccelerationSample.self,
                from: Data(line)
            ) else { continue }
            _ = index.insert(sample)
        }
        return index
    }

    private func monthKey(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
    }

    private func prune() throws {
        let cutoff = Date.now.addingTimeInterval(-retentionInterval)
        let files = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )
        let parser = DateFormatter()
        parser.calendar = calendar
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        for file in files where file.pathExtension == "jsonl" {
            let name = file.deletingPathExtension().lastPathComponent
            let parts = name.split(separator: "-")
            guard parts.count >= 2 else { continue }
            let month = "\(parts[parts.count - 2])-\(parts[parts.count - 1])"
            guard let date = parser.date(from: "\(month)-01") else {
                continue
            }
            let monthEnd = calendar.date(byAdding: .month, value: 1, to: date) ?? date
            if monthEnd < cutoff {
                try FileManager.default.removeItem(at: file)
                appendIndexes.removeValue(forKey: month)
                filesNeedLineSeparator.remove(month)
            }
        }
    }
}

/// 시스템이 지금 무엇을 하고 있다고 보는지. 워치 화면의 확인 카드가 이
/// 값을 그대로 보여주고, 사용자의 정정 결과를 iPhone으로 돌려보낸다.
struct WatchActivityObservation: Hashable, Sendable {
    var behavior: WatchBehaviorKind
    var confidenceScore: Double
    var startedAt: Date
    var endedAt: Date
}
