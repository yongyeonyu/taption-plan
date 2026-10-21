import Foundation
import zlib
import Dispatch
import TaptionPlanCore

enum TaptionLogGzip {
    enum Failure: Error { case invalidInputSize, compressionFailed }

    static func compress(_ data: Data) throws -> Data {
        guard data.count <= Int(UInt32.max) else { throw Failure.invalidInputSize }
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, MAX_WBITS + 16,
            8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw Failure.compressionFailed
        }
        defer { deflateEnd(&stream) }
        let chunkSize = 32 * 1_024
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var result = Data()
        try data.withUnsafeBytes { bytes in
            stream.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            var status: Int32 = Z_OK
            repeat {
                status = buffer.withUnsafeMutableBytes { output in
                    stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunkSize)
                    return deflate(&stream, Z_FINISH)
                }
                guard status == Z_OK || status == Z_STREAM_END else { throw Failure.compressionFailed }
                result.append(contentsOf: buffer.prefix(chunkSize - Int(stream.avail_out)))
            } while status != Z_STREAM_END
        }
        return result
    }
}

enum TaptionDiagnosticsLevel: String, Sendable {
    case info
    case notice
    case error
}

enum TaptionDiagnosticsWriteStatus: Equatable, Sendable {
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

    private static let personalHealthTokens = [
        "health", "sleep", "heart", "blood", "glucose", "oxygen",
        "respir", "workout", "exercise", "stand", "energy", "calorie",
        "step", "weight", "body",
    ]

    private static let technicalFields: Set<String> = [
        "duration_ms", "error_code", "error_description", "error_domain",
        "error_type", "operation", "operation_id", "outcome", "reason",
        "underlying_code", "underlying_domain",
    ]

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

    static func redactingPersonalHealthFields(in log: String) -> String {
        log.split(whereSeparator: \Character.isNewline).compactMap { line in
            guard let data = line.data(using: .utf8),
                  var entry = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any] else {
                let value = String(line)
                let lowered = value.lowercased()
                return personalHealthTokens.contains {
                    lowered.contains($0)
                } ? nil : value
            }
            let event = (entry["event"] as? String)?.lowercased() ?? ""
            let isHealthEvent = personalHealthTokens.contains {
                event.contains($0)
            }
            if let fields = entry["fields"] as? [String: Any] {
                entry["fields"] = fields.filter { key, _ in
                    let normalized = key.lowercased()
                    if isHealthEvent {
                        return technicalFields.contains(normalized)
                    }
                    return !personalHealthTokens.contains {
                        normalized.contains($0)
                    }
                }
            }
            if let metrics = entry["metrics"] as? [String: Any] {
                entry["metrics"] = metrics.filter { key, _ in
                    let normalized = key.lowercased()
                    return !personalHealthTokens.contains {
                        normalized.contains($0)
                    }
                }
            }
            guard let redacted = try? JSONSerialization.data(
                withJSONObject: entry,
                options: [.sortedKeys]
            ) else { return nil }
            return String(decoding: redacted, as: UTF8.self)
        }.joined(separator: "\n")
    }
}

struct TaptionPlanDiagnosticsSession: Sendable {
    enum Phase: String { case launching, active, inactive, background, terminated }
    private static let phaseKey = "taption.diagnostics.session.phase.v1"
    private static let phaseAtKey = "taption.diagnostics.session.phase-at.v1"
    private static let lastPhaseKey = "taption.diagnostics.session.last-phase.v1"
    private static let lastPhaseAtKey = "taption.diagnostics.session.last-phase-at.v1"
    private static let activeKey = "taption.diagnostics.session.active.v1"
    private static let startedAtKey = "taption.diagnostics.session.started-at.v1"
    private static let lastUnfinishedKey =
        "taption.diagnostics.session.last-unfinished.v1"
    private static let lastStartedAtKey =
        "taption.diagnostics.session.last-started-at.v1"

    let previousSessionWasUnfinished: Bool?
    let previousSessionStartedAt: Date?

    @discardableResult
    static func begin(defaults: UserDefaults = .standard) -> Self {
        let hadActiveSession = defaults.object(forKey: activeKey) as? Bool
        let previousStartedAt = defaults.object(forKey: startedAtKey) as? Date
        defaults.set(defaults.string(forKey: phaseKey), forKey: lastPhaseKey)
        defaults.set(defaults.object(forKey: phaseAtKey) as? Date, forKey: lastPhaseAtKey)
        if let hadActiveSession {
            defaults.set(hadActiveSession, forKey: lastUnfinishedKey)
            defaults.set(previousStartedAt, forKey: lastStartedAtKey)
        }
        defaults.set(true, forKey: activeKey)
        defaults.set(Date.now, forKey: startedAtKey)
        recordPhase(.launching, defaults: defaults)
        return Self(
            previousSessionWasUnfinished: hadActiveSession,
            previousSessionStartedAt: previousStartedAt
        )
    }

    static func markCleanTermination(defaults: UserDefaults = .standard) {
        defaults.set(false, forKey: activeKey)
        recordPhase(.terminated, defaults: defaults)
    }

    static func recordPhase(_ phase: Phase, at date: Date = .now, defaults: UserDefaults = .standard) {
        guard defaults.string(forKey: phaseKey) != phase.rawValue else { return }
        defaults.set(phase.rawValue, forKey: phaseKey)
        defaults.set(date, forKey: phaseAtKey)
    }

    static func latestSummary(
        defaults: UserDefaults = .standard
    ) -> [String: String] {
        var values: [String: String] = [:]
        if let unfinished = defaults.object(forKey: lastUnfinishedKey) as? Bool {
            values["previous_session_unfinished"] = String(unfinished)
        }
        if let startedAt = defaults.object(forKey: lastStartedAtKey) as? Date {
            values["previous_session_started_at"] =
                String(startedAt.timeIntervalSince1970)
        }
        if let phase = defaults.string(forKey: lastPhaseKey) {
            values["previous_session_last_phase"] = phase
        }
        if let date = defaults.object(forKey: lastPhaseAtKey) as? Date {
            values["previous_session_last_phase_at"] = String(date.timeIntervalSince1970)
        }
        return values
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
        let routeModeMismatches = travel.filter {
            $0.mode != .subway && $0.subwayRoute != nil
        }
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
            "subway_route_mode_mismatch_count": String(
                routeModeMismatches.count
            ),
            "classification_locked_count": String(
                travel.filter { $0.isClassificationLocked }.count
            ),
            "subway_route_lines": routeLines,
            "subway_route_stations": routeStations,
            "subway_transfer_stations": transfers,
        ]
    }

    private static func uniqueJoined(_ values: [String]) -> String {
        Array(Set(values.filter { !$0.isEmpty })).sorted().joined(separator: ";")
    }
}

/// 반복이 심한 이벤트가 로그를 채워 중요한 기록이 밀려나지 않도록 이벤트별 최소 간격을 둔다.
/// 건너뛴 개수는 다음에 남는 기록에 `suppressed_since_last`로 붙어, 얼마나 반복됐는지 알 수 있다.
struct TaptionDiagnosticsNoiseGate: Sendable {
    static let defaultIntervals: [String: TimeInterval] = [
        "day_load_invalidated": 30,
        "transit_boarding_candidates_evaluated": 60,
        "fmap_route_projection": 30,
        "map_viewport_performance": 30,
        "watch_payload_skipped": 60,
        "widget_payload_published": 60,
        "playback_zoom_sample": 5,
        "map_camera_command": 1,
        "gps_fix": 1,
    ]

    private let intervals: [String: TimeInterval]
    private var lastWritten: [String: Date] = [:]
    private var suppressed: [String: Int] = [:]

    init(intervals: [String: TimeInterval] = Self.defaultIntervals) {
        self.intervals = intervals
    }

    /// 쓰면 그동안 건너뛴 개수를, 건너뛰어야 하면 nil을 돌려준다.
    mutating func admit(_ event: String, at date: Date) -> Int? {
        guard let interval = intervals[event] else { return 0 }
        if let last = lastWritten[event], date.timeIntervalSince(last) < interval,
           date >= last {
            suppressed[event, default: 0] += 1
            return nil
        }
        lastWritten[event] = date
        return suppressed.removeValue(forKey: event) ?? 0
    }
}

final class TaptionPlanDiagnosticsLogger: @unchecked Sendable {
    static let shared = TaptionPlanDiagnosticsLogger()
    static let schemaVersion = 2

    private let fileManager: FileManager
    private let primaryDirectoryURL: URL
    private let fallbackDirectoryURL: URL?
    private let maximumBytes: Int
    private let appVersion: String
    private let buildNumber: String
    private let queue = DispatchQueue(
        label: "com.taption.plan.diagnostics",
        qos: .utility
    )
    private var writeStatus = TaptionDiagnosticsWriteStatus.neverAttempted
    private let sessionID = String(UUID().uuidString.prefix(8))
    private var sequence = 0
    private var noiseGate = TaptionDiagnosticsNoiseGate()

    var lastWriteStatus: TaptionDiagnosticsWriteStatus {
        queue.sync { writeStatus }
    }

    init(
        directoryURL: URL? = nil,
        fallbackDirectoryURL: URL? = nil,
        maximumBytes: Int = 1_000_000,
        fileManager: FileManager = .default,
        appVersion: String? = nil,
        buildNumber: String? = nil
    ) {
        self.fileManager = fileManager
        self.maximumBytes = max(8_000, maximumBytes)
        self.appVersion = appVersion
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown"
        self.buildNumber = buildNumber
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "unknown"
        let directories = Self.defaultDirectories(fileManager: fileManager)
        self.primaryDirectoryURL = directoryURL ?? directories.primary
        self.fallbackDirectoryURL = fallbackDirectoryURL ?? directories.fallback
    }

    /// `fields`는 문자열 값, `metrics`는 분석에 바로 쓰는 숫자 값이다(JSON 숫자로 기록).
    static let mirrorsToStandardOutput = ProcessInfo.processInfo.arguments.contains("-TaptionDiagnosticsStdout")

    func record(
        _ event: String,
        level: TaptionDiagnosticsLevel = .info,
        fields: [String: String] = [:],
        metrics: [String: Double] = [:]
    ) {
        if level == .error {
            queue.sync {
                writeRecord(event, level: level, fields: fields, metrics: metrics)
            }
            return
        }
        queue.async { [self] in
            writeRecord(event, level: level, fields: fields, metrics: metrics)
        }
    }

    private func writeRecord(
        _ event: String,
        level: TaptionDiagnosticsLevel,
        fields: [String: String],
        metrics: [String: Double]
    ) {
        var fields = fields
        if level != .error {
            guard let suppressedCount = noiseGate.admit(event, at: .now) else { return }
            if suppressedCount > 0 {
                fields["suppressed_since_last"] = String(suppressedCount)
            }
        }
        sequence += 1
        let currentSequence = sequence
        do {
            let data = try makeEntryData(
                event: event,
                level: level,
                fields: fields,
                metrics: metrics,
                sequence: currentSequence
            )
            if Self.mirrorsToStandardOutput, let line = String(data: data, encoding: .utf8) {
                // 개발 도구에서 앱을 콘솔 연결로 실행할 때만 켠다(`-TaptionDiagnosticsStdout`). 파일 기록과 내용이 같다.
                print("TAPTIONDIAG " + line.trimmingCharacters(in: .newlines))
            }
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
                    fields: fields,
                    metrics: metrics,
                    sequence: currentSequence
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
        queue.sync {
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
            let redacted = TaptionPlanDiagnosticsLogPolicy
                .redactingPersonalHealthFields(in: combined)
            guard let maximumBytes else { return redacted }
            return TaptionPlanDiagnosticsLogPolicy.bounded(
                redacted,
                maximumBytes: maximumBytes
            )
        }
    }

    func clear() {
        queue.sync {
            let directories = [primaryDirectoryURL, fallbackDirectoryURL]
                .compactMap { $0 }
            for directory in directories {
                for name in ["iphone.jsonl", "iphone-previous.jsonl"] {
                    try? fileManager.removeItem(
                        at: directory.appendingPathComponent(name)
                    )
                }
            }
            writeStatus = .neverAttempted
        }
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
        fields: [String: String],
        metrics: [String: Double],
        sequence: Int
    ) throws -> Data {
        var entry: [String: Any] = [
            "schema": Self.schemaVersion,
            "session_id": sessionID,
            "seq": sequence,
            "timestamp": ISO8601DateFormatter().string(from: .now),
            "app_version": appVersion,
            "build": buildNumber,
            "level": level.rawValue,
            "event": event,
            "fields": fields,
        ]
        let finiteMetrics = metrics.filter { $0.value.isFinite }
        if !finiteMetrics.isEmpty { entry["metrics"] = finiteMetrics }
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
        let safe = TaptionWatchDiagnosticsPrivacy.redacted(report)
        guard !safe.isEmpty else { return }
        defaults.set(safe, forKey: reportKey)
        defaults.set(Date.now, forKey: dateKey)
    }

    static func read(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: reportKey)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: reportKey)
        defaults.removeObject(forKey: dateKey)
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
            "TaptionLogs-\(formatter.string(from: .now))-\(UUID().uuidString.prefix(8)).txt.gz"
        )
        let environment = summary
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
        let safeIPhoneLog = TaptionPlanDiagnosticsLogPolicy
            .redactingPersonalHealthFields(in: iphoneLog)
        let resolvedWatchLog = watchLog.map(
            TaptionWatchDiagnosticsPrivacy.redacted
        ).flatMap { value in
            value.isEmpty ? nil : value
        } ?? "(unavailable)"
        let text = """
        Taption Plan diagnostics
        created_at: \(ISO8601DateFormatter().string(from: .now))
        log_schema: \(TaptionPlanDiagnosticsLogger.schemaVersion)
        log_format: one JSON object per line under iphone_log (keys: schema, session_id, seq, timestamp, build, level, event, fields, metrics)
        log_sampling: noisy events are rate limited; suppressed_since_last in fields counts the skipped ones
        privacy: titles, memo text, coordinates and raw health values are excluded; detected station names and lines may be included for transit debugging

        ## environment
        \(environment)

        ## iphone_log
        \(safeIPhoneLog.isEmpty ? "(empty)" : safeIPhoneLog)

        ## apple_watch_log
        \(resolvedWatchLog)
        """
        let compressed = try TaptionLogGzip.compress(Data(text.utf8))
        try compressed.write(to: url, options: [.atomic, .completeFileProtection])
        try retainNewestPackages(limit: 6)
        return url
    }

    func deleteAll() throws {
        guard fileManager.fileExists(atPath: packageDirectoryURL.path) else {
            return
        }
        try fileManager.removeItem(at: packageDirectoryURL)
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
        message()
    }

    func message(preference: AppLanguagePreference = .current) -> String {
        AppLanguagePreference.text(
            korean: "iCloud Drive를 사용할 수 없습니다. iCloud Drive가 켜져 있는지 확인해 주세요.",
            english: "iCloud Drive is unavailable. Check that iCloud Drive is turned on.",
            preference: preference
        )
    }
}

/// A small, replace-in-place pointer lets the Settings screen and iCloud
/// Drive users find the newest exported package without changing the
/// immutable, collision-safe history of `TaptionLogs-*.txt.gz` files (older `.txt` files remain readable).
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
    private static let legacyHealthLogCleanupKey =
        "TaptionPlan.diagnosticsLegacyHealthLogCleanup.v1"

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
        do {
            try fileManager.copyItem(at: packageURL, to: staged)
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            throw error
        }
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

    @discardableResult
    func deleteAll() throws -> Bool {
        guard let container = ubiquityContainerURL() else {
            throw TaptionPlanDiagnosticsICloudError.unavailable
        }
        let directory = container
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("TaptionLogs", isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else {
            return false
        }
        try fileManager.removeItem(at: directory)
        return true
    }

    func removeLegacyPersonalHealthLogsIfNeeded(
        defaults: UserDefaults = .standard
    ) throws {
        guard !defaults.bool(forKey: Self.legacyHealthLogCleanupKey) else {
            return
        }
        _ = try deleteAll()
        defaults.set(true, forKey: Self.legacyHealthLogCleanupKey)
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
