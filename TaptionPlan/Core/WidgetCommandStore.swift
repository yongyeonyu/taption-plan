import Foundation

/// 위젯 명령 파일은 앱·위젯 두 프로세스가 같은 잠금 안에서만 읽고 쓴다(REV1110A04).
extension TaptionWidgetSharedStore {
    static func appendCommand(_ command: TaptionWidgetCommand) throws {
        let url = fileURL(commandsFileName)
        try withCommandLock(url) {
            var commands = decodeCommands(try? Data(contentsOf: url))
            commands.removeAll {
                $0.planID == command.planID
                    && $0.kind == command.kind
                    && command.requestedAt.timeIntervalSince($0.requestedAt) < 2
            }
            commands.append(command)
            try write(encoder.encode(commands), to: url)
        }
    }

    static func takeCommands() throws -> [TaptionWidgetCommand] {
        let url = fileURL(commandsFileName)
        let data: Data? = try withCommandLock(url) {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let data = try? Data(contentsOf: url)
            try FileManager.default.removeItem(at: url)
            return data
        }
        return decodeCommands(data).sorted { $0.requestedAt < $1.requestedAt }
    }

    /// 새 payload를 먼저 쓰고, payload가 없을 때만 옛 공유 스냅샷으로 만든다(REV1110A04).
    static func readWidgetPayload(now: Date = .now) -> TaptionWidgetPayload {
        if let payload = decodePayload(try? Data(contentsOf: fileURL(payloadFileName))).value {
            return payload
        }
        return readGroundTruthPayload(now: now)
    }

    private static func decodeCommands(_ data: Data?) -> [TaptionWidgetCommand] {
        guard let data else { return [] }
        return (try? decoder.decode([TaptionWidgetCommand].self, from: data)) ?? []
    }

    private static func withCommandLock<T>(_ url: URL, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = open(url.path + ".lock", O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { return try body() }
        defer { close(descriptor) }
        flock(descriptor, LOCK_EX)
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}

/// 이미 반영한 위젯 명령 id. 같은 명령이 다시 와도 두 번 적용하지 않는다(REV1110A04).
enum TaptionWidgetCommandReceipts {
    private static let key = "taption.widget.appliedCommandIDs"
    private static let limit = 64

    static func unapplied(
        _ commands: [TaptionWidgetCommand],
        defaults: UserDefaults = .standard
    ) -> [TaptionWidgetCommand] {
        var seen = Set(defaults.stringArray(forKey: key) ?? [])
        let fresh = commands.filter { seen.insert($0.id.uuidString).inserted }
        guard !fresh.isEmpty else { return [] }
        let stored = (defaults.stringArray(forKey: key) ?? []) + fresh.map(\.id.uuidString)
        defaults.set(Array(stored.suffix(limit)), forKey: key)
        return fresh
    }
}
