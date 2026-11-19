import CryptoKit
import Foundation

/// 받기 상태. 설정 화면이 그대로 보여 준다.
public enum SeasonPackDownloadStatus: Sendable, Equatable {
    case idle
    case checking
    case downloading(received: Int64, total: Int64)
    case verifying
    case installing
    case installed(id: String, version: Int)
    /// 큰 팩이라 셀룰러·저데이터에서는 기다린다.
    case waitingForWiFi(bytes: Int)
    /// 끊겼다. 부분 파일이 남아 다음 실행에서 이어 받는다.
    case paused
    case failed(String)

    public func label(language: String) -> String {
        let ko = language.hasPrefix("ko")
        switch self {
        case .idle: return ko ? "최신 상태" : "Up to date"
        case .checking: return ko ? "업데이트 확인 중" : "Checking for updates"
        case .downloading(let received, let total):
            let percent = total > 0 ? Int(Double(received) / Double(total) * 100) : 0
            return ko ? "시즌 팩 받는 중 \(percent)%" : "Downloading season pack \(percent)%"
        case .verifying: return ko ? "확인 중" : "Verifying"
        case .installing: return ko ? "적용 중" : "Installing"
        case .installed: return ko ? "새 시즌 팩 적용됨" : "New season pack applied"
        case .waitingForWiFi: return ko ? "Wi-Fi에서 받을게요" : "Waiting for Wi-Fi"
        case .paused: return ko ? "중단됨 · 다음에 이어 받아요" : "Paused · will resume"
        case .failed: return ko ? "받지 못했어요 · 다음에 다시 시도해요" : "Couldn't download · will retry"
        }
    }
}

public enum SeasonPackEngineOutcome: Sendable, Equatable {
    case finished
    /// 취소·끊김. `resumeData`가 있으면 거기서 이어 받는다.
    case interrupted(resumeData: Data?)
    /// 서버가 거절(404·416 등)하거나 이어 받기가 맞지 않음.
    case failed(String)
}

/// 실제 내려받기 한 번. 운영에서는 백그라운드 `URLSession`(`SeasonPackBackgroundEngine`), 시험에서는 가짜.
/// `destination`에 완성 파일을 놓는다(못 놓으면 `finished`가 아니다).
public protocol SeasonPackDownloadEngine: Sendable {
    func download(from url: URL, resumeData: Data?, allowsCellular: Bool, to destination: URL,
                  progress: @escaping @Sendable (Int64, Int64) -> Void) async -> SeasonPackEngineOutcome
}

public enum SeasonPackDownloadResult: Sendable, Equatable {
    /// 크기와 SHA-256이 맞는 완성 파일.
    case ready(URL)
    case deferred(SeasonPackDownloadStatus)
    case interrupted
    case failed(String)
}

/// `.bpack` 하나를 받아 검증한다. 상태는 모두 디스크에 있어(앱이 죽어도) 다음 실행에서 이어 받는다.
/// - `<id>-<버전>.meta`   무엇을 받는 중인지(카탈로그 값). 카탈로그가 바뀌면 부분 파일을 버린다.
/// - `<id>-<버전>.resume` `URLSession`이 준 이어받기 데이터(서버의 ETag·Range 검증은 URLSession이 한다).
/// - `<id>-<버전>.bpack`  완성 파일.
public final class SeasonPackDownloader: Sendable {
    struct Meta: Codable, Equatable { var id: String; var version: Int; var bytes: Int; var sha256: String; var key: String }

    private let directory: URL
    private let engine: SeasonPackDownloadEngine
    private let urlForKey: @Sendable (String) -> URL?
    private let freeBytes: @Sendable () -> Int64?
    private let allowsLargeDownload: @Sendable () -> Bool
    private let onStatus: @Sendable (SeasonPackDownloadStatus) -> Void
    static let resumeLimit = 1_000_000

    public init(
        directory: URL,
        engine: SeasonPackDownloadEngine,
        urlForKey: @escaping @Sendable (String) -> URL?,
        freeBytes: @escaping @Sendable () -> Int64? = { SeasonPackDownloader.volumeFreeBytes() },
        allowsLargeDownload: @escaping @Sendable () -> Bool = { true },
        onStatus: @escaping @Sendable (SeasonPackDownloadStatus) -> Void = { _ in }
    ) {
        self.directory = directory; self.engine = engine; self.urlForKey = urlForKey; self.freeBytes = freeBytes
        self.allowsLargeDownload = allowsLargeDownload; self.onStatus = onStatus
    }

    public static func volumeFreeBytes() -> Int64? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    private func path(_ entry: SeasonPackIndex.Entry, _ ext: String) -> URL { directory.appendingPathComponent("\(entry.id)-\(entry.version).\(ext)") }

    /// 받다 만 것이 남아 있는가(쿨다운을 건너뛰고 이어 받을 근거).
    public var hasPending: Bool { pendingMetas().isEmpty == false }

    func pendingMetas() -> [Meta] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "meta" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? JSONDecoder().decode(Meta.self, from: $0) } }
    }

    public func purge(_ entry: SeasonPackIndex.Entry) {
        for ext in ["meta", "resume", "bpack"] { try? FileManager.default.removeItem(at: path(entry, ext)) }
    }

    /// 설치까지 끝난 뒤(또는 못 쓸 파일을 버릴 때) 부른다.
    public func finish(_ entry: SeasonPackIndex.Entry) { purge(entry) }

    public func ensure(_ entry: SeasonPackIndex.Entry) async -> SeasonPackDownloadResult {
        guard let archive = entry.archive, SeasonPackURLSessionTransport.isValidKey(archive.key), archive.bytes > 0,
              archive.bytes <= SeasonPackLimits.packBytes + SeasonPackArchive.maxManifestBytes + 16, archive.sha256.count == 64,
              let url = urlForKey(archive.key) else { return .failed("bad-entry") }
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let meta = Meta(id: entry.id, version: entry.version, bytes: archive.bytes, sha256: archive.sha256, key: archive.key)
        // 카탈로그가 바뀌었으면 옛 부분 파일은 다른 파일이다.
        if let old = (try? Data(contentsOf: path(entry, "meta"))).flatMap({ try? JSONDecoder().decode(Meta.self, from: $0) }), old != meta { purge(entry) }
        if let data = try? JSONEncoder().encode(meta) { try? data.write(to: path(entry, "meta"), options: .atomic) }

        if fm.fileExists(atPath: path(entry, "bpack").path) {
            if verify(path(entry, "bpack"), archive) { return .ready(path(entry, "bpack")) }
            try? fm.removeItem(at: path(entry, "bpack"))
        }
        let cellularOK = archive.bytes <= SeasonPackLimits.cellularBytes || allowsLargeDownload()
        guard cellularOK else { onStatus(.waitingForWiFi(bytes: archive.bytes)); return .deferred(.waitingForWiFi(bytes: archive.bytes)) }
        // 완성 파일 + 임시 + 풀 때 여유.
        if let free = freeBytes(), free < Int64(archive.bytes) * 3 + 4_000_000 { onStatus(.failed("disk")); return .failed("disk") }

        var resume = (try? Data(contentsOf: path(entry, "resume"))).flatMap { $0.count <= Self.resumeLimit ? $0 : nil }
        for attempt in 0..<2 {
            let received = Int64(0)
            onStatus(.downloading(received: received, total: Int64(archive.bytes)))
            let status = onStatus
            let outcome = await engine.download(from: url, resumeData: resume, allowsCellular: cellularOK, to: path(entry, "bpack")) { got, total in
                status(.downloading(received: got, total: total > 0 ? total : Int64(archive.bytes)))
            }
            switch outcome {
            case .finished:
                onStatus(.verifying)
                if verify(path(entry, "bpack"), archive) { try? fm.removeItem(at: path(entry, "resume")); return .ready(path(entry, "bpack")) }
                // 해시·크기 불일치: 이 파일을 버리고 처음부터 한 번 더.
                try? fm.removeItem(at: path(entry, "bpack")); try? fm.removeItem(at: path(entry, "resume"))
                resume = nil
                if attempt == 1 { onStatus(.failed("hash")); return .failed("hash") }
            case .interrupted(let data):
                if let data, !data.isEmpty, data.count <= Self.resumeLimit { try? data.write(to: path(entry, "resume"), options: .atomic) }
                else { try? fm.removeItem(at: path(entry, "resume")) }
                onStatus(.paused)
                return .interrupted
            case .failed(let reason):
                // 이어 받기가 맞지 않으면(서버가 바뀜·Range 미지원) 처음부터 한 번 더.
                try? fm.removeItem(at: path(entry, "resume"))
                if resume != nil, attempt == 0 { resume = nil; continue }
                onStatus(.failed(reason)); return .failed(reason)
            }
        }
        return .failed("retry")
    }

    private func verify(_ file: URL, _ archive: SeasonPackIndex.Archive) -> Bool {
        guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size == archive.bytes else { return false }
        return Self.sha256Hex(of: file) == archive.sha256.lowercased()
    }

    static func sha256Hex(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
