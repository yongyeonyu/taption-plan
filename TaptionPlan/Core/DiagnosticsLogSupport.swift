import Foundation
import TaptionPlanCore

enum TaptionDiagnosticsLevel: String {
    case info
    case notice
    case error
}

enum TaptionDiagnosticsWriteStatus: Equatable {
    case neverAttempted
    case primarySucceeded
    case fallbackSucceeded
    case failed
}

enum TaptionDiagnosticError {
    static func fields(for error: Error) -> [String: String] {
        let value = error as NSError
        var fields = [
            "error_type": String(reflecting: type(of: error)),
            "error_domain": value.domain,
            "error_code": String(value.code),
            "error_value": String(describing: error),
            "error_description": value.localizedDescription,
        ]
        if let underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError {
            fields["underlying_domain"] = underlying.domain
            fields["underlying_code"] = String(underlying.code)
        }
        return fields
    }

    static func compactFields(for error: Error) -> [String: String] {
        let value = error as NSError
        var fields = [
            "error_type": String(reflecting: type(of: error)),
            "error_domain": value.domain,
            "error_code": String(value.code),
            "error_description": value.localizedDescription,
        ]
        if let underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError {
            fields["underlying_domain"] = underlying.domain
            fields["underlying_code"] = String(underlying.code)
        }
        return fields
    }
}

struct TaptionDiagnosticsOperation: Equatable, Sendable {
    let id: UUID
    let name: String
    let startedAtUptime: TimeInterval
}

enum TaptionPlanDiagnosticsLogPolicy {
    static let maximumBackupBytes = 512_000

    static func bounded(
        _ log: String,
        maximumBytes: Int = maximumBackupBytes
    ) -> String {
        let limit = max(1, maximumBytes)
        let data = Data(log.utf8)
        guard data.count > limit else { return log }

        let suffix = data.suffix(limit)
        guard let newline = suffix.firstIndex(of: 0x0A) else {
            return ""
        }
        let start = suffix.index(after: newline)
        return String(decoding: suffix[start...], as: UTF8.self)
    }
}

/// Safe, compact movement metadata for support packages. Coordinates and raw
/// sensor samples stay out of the export, while mode and subway-route names
/// make a transit inference auditable from the iCloud log alone.
enum TaptionPlanDiagnosticsTravelSummary {
    static func fields(for travel: [TravelSegment]) -> [String: String] {
        let modeCounts = travel.reduce(into: [TravelMode: Int]()) {
            counts,
            segment in
            counts[segment.mode, default: 0] += 1
        }
        let modeText = TravelMode.allCases
            .compactMap { mode -> String? in
                guard let count = modeCounts[mode], count > 0 else {
                    return nil
                }
                return "\(mode.rawValue)=\(count)"
            }
            .joined(separator: ",")
        let subwaySegments = travel.filter { $0.mode == .subway }
        let routes = subwaySegments.compactMap { $0.subwayRoute }
        let routeLines = uniqueJoined(
            routes.map { $0.lineNames.joined(separator: "+") }
        )
        let routeStations = uniqueJoined(
            routes.map { route in
                route.stops
                    .sorted { $0.order < $1.order }
                    .map { $0.stationName }
                    .joined(separator: "→")
            }
        )
        let transfers = uniqueJoined(
            routes.flatMap { $0.transferStationNames }
        )
        return [
            "travel_mode_counts": modeText,
            "travel_confirmed_count": String(
                travel.filter { $0.isConfirmed }.count
            ),
            "travel_high_confidence_count": String(
                travel.filter { $0.confidence == .high }.count
            ),
            "subway_segment_count": String(subwaySegments.count),
            "subway_route_count": String(routes.count),
            "subway_route_lines": routeLines,
            "subway_route_stations": routeStations,
            "subway_transfer_stations": transfers,
        ]
    }

    private static func uniqueJoined(_ values: [String]) -> String {
        Array(Set(values.filter { !$0.isEmpty })).sorted().joined(separator: ";")
    }
}

final class TaptionPlanDiagnosticsLogger: @unchecked Sendable {
    static let shared = TaptionPlanDiagnosticsLogger()

    private let fileManager: FileManager
    private let primaryDirectoryURL: URL
    private let fallbackDirectoryURL: URL?
    private let maximumBytes: Int
    private let lock = NSLock()
    private var writeStatus = TaptionDiagnosticsWriteStatus.neverAttempted

    var lastWriteStatus: TaptionDiagnosticsWriteStatus {
        lock.lock()
        defer { lock.unlock() }
        return writeStatus
    }

    init(
        directoryURL: URL? = nil,
        fallbackDirectoryURL: URL? = nil,
        maximumBytes: Int = 1_000_000,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.maximumBytes = max(8_000, maximumBytes)
        let directories = Self.defaultDirectories(fileManager: fileManager)
        self.primaryDirectoryURL = directoryURL ?? directories.primary
        self.fallbackDirectoryURL = fallbackDirectoryURL ?? directories.fallback
    }

    func record(
        _ event: String,
        level: TaptionDiagnosticsLevel = .info,
        fields: [String: String] = [:]
    ) {
        lock.lock()
        defer { lock.unlock() }

        do {
            let data = try makeEntryData(
                event: event,
                level: level,
                fields: fields
            )
            try write(data, to: primaryDirectoryURL)
            writeStatus = .primarySucceeded
            return
        } catch {
            guard let fallbackDirectoryURL,
                  fallbackDirectoryURL != primaryDirectoryURL else {
                writeStatus = .failed
                return
            }
            do {
                let data = try makeEntryData(
                    event: event,
                    level: level,
                    fields: fields
                )
                try write(data, to: fallbackDirectoryURL)
                writeStatus = .fallbackSucceeded
            } catch {
                writeStatus = .failed
            }
        }
    }

    func beginOperation(
        _ name: String,
        fields: [String: String] = [:]
    ) -> TaptionDiagnosticsOperation {
        let operation = TaptionDiagnosticsOperation(
            id: UUID(),
            name: name,
            startedAtUptime: ProcessInfo.processInfo.systemUptime
        )
        var values = fields
        values["operation"] = name
        values["operation_id"] = operation.id.uuidString
        record("operation_started", fields: values)
        return operation
    }

    func finishOperation(
        _ operation: TaptionDiagnosticsOperation,
        outcome: String,
        fields: [String: String] = [:],
        error: Error? = nil
    ) {
        var values = fields
        values["operation"] = operation.name
        values["operation_id"] = operation.id.uuidString
        values["outcome"] = outcome
        values["duration_ms"] = String(
            Int(
                max(
                    0,
                    ProcessInfo.processInfo.systemUptime
                        - operation.startedAtUptime
                ) * 1_000
            )
        )
        if let error {
            for (key, value) in TaptionDiagnosticError.compactFields(for: error)
                where values[key] == nil {
                values[key] = value
            }
        }
        record(
            "operation_finished",
            level: outcome == "failure" ? .error : .info,
            fields: values
        )
    }

    func combinedLog(maximumBytes: Int? = nil) -> String {
        lock.lock()
        defer { lock.unlock() }
        var urls = [previousURL, currentURL]
        if let fallbackDirectoryURL,
           fallbackDirectoryURL != primaryDirectoryURL {
            urls.append(
                fallbackDirectoryURL.appendingPathComponent(
                    "iphone-previous.jsonl"
                )
            )
            urls.append(
                fallbackDirectoryURL.appendingPathComponent("iphone.jsonl")
            )
        }
        let combined = urls
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard let maximumBytes else { return combined }
        return TaptionPlanDiagnosticsLogPolicy.bounded(
            combined,
            maximumBytes: maximumBytes
        )
    }

    private var currentURL: URL {
        primaryDirectoryURL.appendingPathComponent("iphone.jsonl")
    }

    private var previousURL: URL {
        primaryDirectoryURL.appendingPathComponent("iphone-previous.jsonl")
    }

    private func makeEntryData(
        event: String,
        level: TaptionDiagnosticsLevel,
        fields: [String: String]
    ) throws -> Data {
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
        return data
    }

    private func write(_ data: Data, to directoryURL: URL) throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try rotateIfNeeded(in: directoryURL)
        let currentURL = directoryURL.appendingPathComponent("iphone.jsonl")
        if fileManager.fileExists(atPath: currentURL.path) {
            let handle = try FileHandle(forWritingTo: currentURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(
                to: currentURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
        }
    }

    private func rotateIfNeeded(in directoryURL: URL) throws {
        let currentURL = directoryURL.appendingPathComponent("iphone.jsonl")
        let size = (try? currentURL.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize) ?? 0
        guard size >= maximumBytes else { return }
        let previousURL = directoryURL.appendingPathComponent(
            "iphone-previous.jsonl"
        )
        try? fileManager.removeItem(at: previousURL)
        try fileManager.moveItem(at: currentURL, to: previousURL)
    }

    private static func defaultDirectories(
        fileManager: FileManager
    ) -> (primary: URL, fallback: URL?) {
        let applicationSupportDirectory = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ))?.appendingPathComponent(
            "TaptionPlan/Diagnostics",
            isDirectory: true
        )
        guard let appGroupRoot = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: TaptionPlanSharedContainer.appGroupIdentifier
        ) else {
            return (
                primary: applicationSupportDirectory
                    ?? fileManager.temporaryDirectory.appendingPathComponent(
                        "TaptionPlan/Diagnostics",
                        isDirectory: true
                    ),
                fallback: nil
            )
        }
        return (
            primary: appGroupRoot.appendingPathComponent(
                "TaptionPlan/Diagnostics",
                isDirectory: true
            ),
            fallback: applicationSupportDirectory
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
        privacy: titles, memo text, coordinates and raw health values are excluded; detected station names and lines may be included for transit debugging

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

/// A small, replace-in-place pointer lets the Settings screen and iCloud
/// Drive users find the newest exported package without changing the
/// immutable, collision-safe history of `TaptionLogs-*.txt` files.
struct TaptionDiagnosticsLatestLogManifest: Codable, Equatable, Sendable {
    static let fileName = "latest.json"

    var fileName: String
    var savedAt: Date
    var byteCount: Int

    init(fileName: String, savedAt: Date = .now, byteCount: Int) {
        self.fileName = fileName
        self.savedAt = savedAt
        self.byteCount = max(0, byteCount)
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
            try exportLatestManifest(
                TaptionDiagnosticsLatestLogManifest(
                    fileName: destination.lastPathComponent,
                    byteCount: (try? packageURL.resourceValues(
                        forKeys: [.fileSizeKey]
                    ).fileSize) ?? 0
                ),
                to: destinationDirectory
            )
            try? fileManager.removeItem(at: stagingDirectory)
            return destination
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            throw error
        }
    }

    private func exportLatestManifest(
        _ manifest: TaptionDiagnosticsLatestLogManifest,
        to directory: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(
            at: staging,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: staging) }
        let source = staging.appendingPathComponent(
            TaptionDiagnosticsLatestLogManifest.fileName
        )
        try data.write(to: source, options: [.atomic])
        let destination = directory.appendingPathComponent(
            TaptionDiagnosticsLatestLogManifest.fileName
        )
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try transferItem(source, destination)
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
