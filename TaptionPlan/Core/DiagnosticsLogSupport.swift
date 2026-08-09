import Foundation

enum TaptionDiagnosticsLevel: String {
    case info
    case notice
    case error
}

final class TaptionPlanDiagnosticsLogger: @unchecked Sendable {
    static let shared = TaptionPlanDiagnosticsLogger()

    private let fileManager: FileManager
    private let directoryURL: URL
    private let maximumBytes: Int
    private let lock = NSLock()

    init(
        directoryURL: URL? = nil,
        maximumBytes: Int = 1_000_000,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.maximumBytes = max(8_000, maximumBytes)
        self.directoryURL = directoryURL ?? Self.defaultDirectory(
            fileManager: fileManager
        )
    }

    func record(
        _ event: String,
        level: TaptionDiagnosticsLevel = .info,
        fields: [String: String] = [:]
    ) {
        lock.lock()
        defer { lock.unlock() }
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            try rotateIfNeeded()
            let entry: [String: Any] = [
                "timestamp": ISO8601DateFormatter().string(from: .now),
                "level": level.rawValue,
                "event": event,
                "fields": fields,
            ]
            var data = try JSONSerialization.data(
                withJSONObject: entry,
                options: [.sortedKeys]
            )
            data.append(0x0A)
            if let handle = FileHandle(forWritingAtPath: currentURL.path) {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(
                    to: currentURL,
                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
                )
            }
        } catch {
            // 진단 기록 실패가 앱 기능을 막으면 안 된다.
        }
    }

    func combinedLog() -> String {
        lock.lock()
        defer { lock.unlock() }
        return [previousURL, currentURL]
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private var currentURL: URL {
        directoryURL.appendingPathComponent("iphone.jsonl")
    }

    private var previousURL: URL {
        directoryURL.appendingPathComponent("iphone-previous.jsonl")
    }

    private func rotateIfNeeded() throws {
        let size = (try? currentURL.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize) ?? 0
        guard size >= maximumBytes else { return }
        try? fileManager.removeItem(at: previousURL)
        try fileManager.moveItem(at: currentURL, to: previousURL)
    }

    private static func defaultDirectory(
        fileManager: FileManager
    ) -> URL {
        let root = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.taption.plan"
        ) ?? (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        return root.appendingPathComponent(
            "TaptionPlan/Diagnostics",
            isDirectory: true
        )
    }
}

struct WatchDiagnosticsLogStore {
    private static let reportKey = "taption.watch.diagnostics.report.v1"
    private static let dateKey = "taption.watch.diagnostics.received-at.v1"

    static func save(_ report: String, defaults: UserDefaults = .standard) {
        guard !report.isEmpty else { return }
        defaults.set(report, forKey: reportKey)
        defaults.set(Date.now, forKey: dateKey)
    }

    static func read(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: reportKey)
    }
}

struct TaptionPlanDiagnosticsLogPackageBuilder {
    let packageDirectoryURL: URL
    var fileManager: FileManager = .default

    static func applicationSupport(
        fileManager: FileManager = .default
    ) throws -> TaptionPlanDiagnosticsLogPackageBuilder {
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return TaptionPlanDiagnosticsLogPackageBuilder(
            packageDirectoryURL: root.appendingPathComponent(
                "TaptionPlan/Diagnostics/Packages",
                isDirectory: true
            ),
            fileManager: fileManager
        )
    }

    func makePackage(
        summary: [String: String],
        iphoneLog: String,
        watchLog: String?
    ) throws -> URL {
        try fileManager.createDirectory(
            at: packageDirectoryURL,
            withIntermediateDirectories: true
        )
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = packageDirectoryURL.appendingPathComponent(
            "TaptionLogs-\(formatter.string(from: .now)).txt"
        )
        let environment = summary
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
        let resolvedWatchLog = watchLog.flatMap { value in
            value.isEmpty ? nil : value
        } ?? "(unavailable)"
        let text = """
        Taption Plan diagnostics
        created_at: \(ISO8601DateFormatter().string(from: .now))
        privacy: titles, memo text, coordinates and raw health values are excluded

        ## environment
        \(environment)

        ## iphone_log
        \(iphoneLog.isEmpty ? "(empty)" : iphoneLog)

        ## apple_watch_log
        \(resolvedWatchLog)
        """
        try text.write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
        try retainNewestPackages(limit: 6)
        return url
    }

    private func retainNewestPackages(limit: Int) throws {
        let files = try fileManager.contentsOfDirectory(
            at: packageDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ).filter { $0.lastPathComponent.hasPrefix("TaptionLogs-") }
        let sorted = files.sorted {
            let lhs = try? $0.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
            let rhs = try? $1.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
            return (lhs ?? .distantPast) > (rhs ?? .distantPast)
        }
        for file in sorted.dropFirst(limit) {
            try? fileManager.removeItem(at: file)
        }
    }
}

enum TaptionPlanDiagnosticsICloudError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "iCloud Drive를 사용할 수 없습니다. iCloud Drive가 켜져 있는지 확인해 주세요."
    }
}

struct TaptionPlanDiagnosticsICloudExporter {
    typealias Transfer = (URL, URL) throws -> Void

    var fileManager: FileManager = .default
    var ubiquityContainerURL: () -> URL?
    var transferItem: Transfer

    init(
        fileManager: FileManager = .default,
        ubiquityContainerURL: (() -> URL?)? = nil,
        transferItem: Transfer? = nil
    ) {
        self.fileManager = fileManager
        self.ubiquityContainerURL = ubiquityContainerURL ?? {
            fileManager.url(
                forUbiquityContainerIdentifier: "iCloud.com.taption.plan"
            )
        }
        self.transferItem = transferItem ?? { source, destination in
            try fileManager.setUbiquitous(
                true,
                itemAt: source,
                destinationURL: destination
            )
        }
    }

    func export(_ packageURL: URL) throws -> URL {
        guard let container = ubiquityContainerURL() else {
            throw TaptionPlanDiagnosticsICloudError.unavailable
        }
        let destinationDirectory = container
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("TaptionLogs", isDirectory: true)
        try fileManager.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )
        let stagingDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        let staged = stagingDirectory.appendingPathComponent(
            packageURL.lastPathComponent
        )
        try fileManager.copyItem(at: packageURL, to: staged)
        let destination = availableDestination(
            named: packageURL.lastPathComponent,
            in: destinationDirectory
        )
        do {
            try transferItem(staged, destination)
            try? fileManager.removeItem(at: stagingDirectory)
            return destination
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            throw error
        }
    }

    private func availableDestination(
        named fileName: String,
        in directory: URL
    ) -> URL {
        let original = directory.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: original.path) else {
            return original
        }
        let source = URL(fileURLWithPath: fileName)
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        for suffix in 2...999 {
            let name = ext.isEmpty
                ? "\(base)-\(suffix)"
                : "\(base)-\(suffix).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return directory.appendingPathComponent(
            "\(base)-\(UUID().uuidString).\(ext)"
        )
    }
}
