import Foundation

/// 워치 앱이 실행 도중 죽으면 기기에는 크래시 로그만 남고, 회사·외출 중에는
/// 그 파일을 꺼내기 어렵다. 실행 단계를 파일에 먼저 적어두고 다음 실행 때
/// iPhone으로 보내면, 앱이 어느 단계에서 멈췄는지 설정 화면에서 바로 볼 수
/// 있다. 마지막으로 기록된 단계가 곧 실패 지점이다.
enum WatchLaunchDiagnostics {
    private static let fileName = "watch-launch-log.txt"
    private static let maximumBytes = 64_000
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handle: FileHandle?

    private static var fileURL: URL {
        let root = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL.temporaryDirectory
        return root.appendingPathComponent(fileName)
    }

    /// 실행 단계를 즉시 파일에 남긴다. 프로세스가 곧바로 죽어도 남아야 하므로
    /// 버퍼링 없이 쓰고 닫지 않는다.
    static func mark(_ stage: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "\(Date.now.timeIntervalSince1970.rounded()) \(stage)\n"
        guard let data = line.data(using: .utf8) else { return }
        let size = (try? fileURL.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize) ?? 0
        if size >= maximumBytes {
            try? handle?.close()
            handle = nil
            if let existing = try? Data(contentsOf: fileURL) {
                try? Data(existing.suffix(maximumBytes / 2)).write(
                    to: fileURL,
                    options: .atomic
                )
            }
        }
        if handle == nil {
            let url = fileURL
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
            try? handle?.seekToEnd()
        }
        try? handle?.write(contentsOf: data)
        try? handle?.synchronize()
    }

    // 신호 핸들러 설치는 시도했다가 앱 시작 자체를 죽여서 제거했다.
    // 단계 기록만으로 실패 지점을 좁히기에 충분하다.

    /// 이전 실행에서 남은 기록. 새 실행 단계가 섞이지 않도록 먼저 읽는다.
    static func pendingReport() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return report()
    }

    static func currentReport() -> String? {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.synchronize()
        return report()
    }

    private static func report() -> String? {
        guard let data = try? Data(contentsOf: fileURL),
              !data.isEmpty else {
            return nil
        }
        let trimmed = data.count > maximumBytes
            ? data.suffix(maximumBytes)
            : data
        return String(data: trimmed, encoding: .utf8)
    }

    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
        handle = nil
        try? Data().write(to: fileURL)
    }
}
