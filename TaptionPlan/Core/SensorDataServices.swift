import Foundation
import OSLog

enum RawDeviceDataSource: String, Codable, Sendable {
    case gps
    case iPhoneSensor
    case iPhoneMotion
    case iPhonePedometer
    case healthKit
    case appleWatch
}

struct RawDeviceDataEnvelope: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var capturedAt: Date
    var source: RawDeviceDataSource
    var kind: String
    var schemaVersion: Int
    var payloadJSON: String

    init<T: Encodable>(
        id: UUID = UUID(),
        capturedAt: Date = .now,
        source: RawDeviceDataSource,
        kind: String,
        schemaVersion: Int = 1,
        payload: T,
        encoder: JSONEncoder = RawDeviceDataMonthlyArchive.payloadEncoder()
    ) throws {
        self.id = id
        self.capturedAt = capturedAt
        self.source = source
        self.kind = kind
        self.schemaVersion = schemaVersion
        let data = try encoder.encode(payload)
        self.payloadJSON = String(decoding: data, as: UTF8.self)
    }
}

final class RawDeviceDataMonthlyArchive: @unchecked Sendable {
    private static let logger = Logger(
        subsystem: "com.taption.plan",
        category: "RawDeviceDataArchive"
    )
    private let rootDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let calendar: Calendar
    private let lock = NSLock()
    private let compressionQueue = DispatchQueue(
        label: "com.taption.plan.raw-archive-compression",
        qos: .utility
    )
    private let flushDelay: TimeInterval
    private var scheduledMonths = Set<String>()

    init(
        rootDirectory: URL,
        calendar: Calendar = .autoupdatingCurrent,
        flushDelay: TimeInterval = 5 * 60
    ) {
        self.rootDirectory = rootDirectory
        self.calendar = calendar
        self.flushDelay = max(0, flushDelay)
        self.encoder = Self.payloadEncoder()
        self.decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
    }

    static func applicationSupport(
        fileManager: FileManager = .default
    ) throws -> RawDeviceDataMonthlyArchive {
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return RawDeviceDataMonthlyArchive(
            rootDirectory: root.appendingPathComponent(
                "TaptionPlan/RawData",
                isDirectory: true
            )
        )
    }

    static func payloadEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    func append<T: Encodable>(
        source: RawDeviceDataSource,
        kind: String,
        payload: T,
        capturedAt: Date = .now
    ) throws {
        let envelope = try RawDeviceDataEnvelope(
            capturedAt: capturedAt,
            source: source,
            kind: kind,
            payload: payload,
            encoder: encoder
        )
        try append(envelopes: [envelope])
    }

    func append(envelopes: [RawDeviceDataEnvelope]) throws {
        guard !envelopes.isEmpty else { return }
        var monthsToSchedule: [String] = []
        lock.lock()
        do {
            let grouped = Dictionary(grouping: envelopes) {
                monthKey(for: $0.capturedAt)
            }
            for (monthKey, values) in grouped {
                let journalURL = try journalFileURL(for: monthKey)
                var payload = Data()
                for envelope in values.sorted(by: {
                    $0.capturedAt < $1.capturedAt
                }) {
                    payload.append(try encoder.encode(envelope))
                    payload.append(0x0A)
                }
                try append(payload, to: journalURL)
                if scheduledMonths.insert(monthKey).inserted {
                    monthsToSchedule.append(monthKey)
                }
            }
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
        for monthKey in monthsToSchedule {
            compressionQueue.asyncAfter(
                deadline: .now() + flushDelay
            ) { [weak self] in
                do {
                    try self?.flush(monthKey: monthKey)
                } catch {
                    Self.logger.error(
                        "Raw archive chunk flush failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
    }

    func envelopes(inMonthContaining date: Date) throws
        -> [RawDeviceDataEnvelope] {
        lock.lock()
        defer { lock.unlock() }
        let monthKey = monthKey(for: date)
        let directory = try monthDirectory(for: monthKey)
        var payloads: [Data] = []
        let legacyURL = legacyCompressedFileURL(
            in: directory,
            monthKey: monthKey
        )
        if FileManager.default.fileExists(atPath: legacyURL.path),
           let payload = try? existingPayload(at: legacyURL) {
            payloads.append(payload)
        }
        let journalURL = journalFileURL(in: directory)
        if let payload = try? Data(contentsOf: journalURL) {
            payloads.append(payload)
        }
        let chunks = directory.appendingPathComponent(
            "chunks",
            isDirectory: true
        )
        if let files = try? FileManager.default.contentsOfDirectory(
            at: chunks,
            includingPropertiesForKeys: nil
        ) {
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let data = try? Data(contentsOf: file) else { continue }
                if file.pathExtension == "zlib",
                   let payload = try? decompress(data) {
                    payloads.append(payload)
                } else if file.lastPathComponent.hasSuffix(".jsonl.pending") {
                    payloads.append(data)
                }
            }
        }
        var seen = Set<UUID>()
        return payloads
            .flatMap { payload in
                payload.split(separator: 0x0A).compactMap {
                    try? decoder.decode(
                        RawDeviceDataEnvelope.self,
                        from: Data($0)
                    )
                }
            }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.capturedAt < $1.capturedAt }
    }

    func flushPendingWrites() throws {
        lock.lock()
        let months = Array(scheduledMonths)
        lock.unlock()
        for monthKey in months {
            try flush(monthKey: monthKey)
        }
        compressionQueue.sync {}
    }

    private func monthDirectory(for monthKey: String) throws -> URL {
        let directory = rootDirectory.appendingPathComponent(
            monthKey,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func legacyCompressedFileURL(
        in directory: URL,
        monthKey: String
    ) -> URL {
        directory.appendingPathComponent(
            "taption-raw-\(monthKey).jsonl.zlib"
        )
    }

    private func journalFileURL(for monthKey: String) throws -> URL {
        journalFileURL(in: try monthDirectory(for: monthKey))
    }

    private func journalFileURL(in directory: URL) -> URL {
        directory.appendingPathComponent("current.jsonl")
    }

    private func append(_ payload: Data, to fileURL: URL) throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: payload)
        } else {
            try payload.write(
                to: fileURL,
                options: [
                    .atomic,
                    .completeFileProtectionUntilFirstUserAuthentication,
                ]
            )
        }
    }

    private func flush(monthKey: String) throws {
        let pendingURL: URL?
        lock.lock()
        do {
            scheduledMonths.remove(monthKey)
            let directory = try monthDirectory(for: monthKey)
            let journalURL = journalFileURL(in: directory)
            guard FileManager.default.fileExists(atPath: journalURL.path) else {
                lock.unlock()
                return
            }
            let chunks = directory.appendingPathComponent(
                "chunks",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: chunks,
                withIntermediateDirectories: true
            )
            let name = String(
                format: "%013lld-%@.jsonl.pending",
                Int64(Date.now.timeIntervalSince1970 * 1_000),
                UUID().uuidString
            )
            let destination = chunks.appendingPathComponent(name)
            try FileManager.default.moveItem(
                at: journalURL,
                to: destination
            )
            pendingURL = destination
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
        guard let pendingURL else { return }
        let payload = try Data(contentsOf: pendingURL)
        let destination = pendingURL
            .deletingPathExtension()
            .deletingPathExtension()
            .appendingPathExtension("jsonl.zlib")
        try compress(payload).write(
            to: destination,
            options: [
                .atomic,
                .completeFileProtectionUntilFirstUserAuthentication,
            ]
        )
        try FileManager.default.removeItem(at: pendingURL)
    }

    private func existingPayload(at fileURL: URL) throws -> Data {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return Data()
        }
        let compressed = try Data(contentsOf: fileURL)
        guard !compressed.isEmpty else { return Data() }
        return try decompress(compressed)
    }

    private func monthKey(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        return String(format: "%04d-%02d", year, month)
    }

    private func compress(_ data: Data) throws -> Data {
        try (data as NSData).compressed(using: .zlib) as Data
    }

    private func decompress(_ data: Data) throws -> Data {
        try (data as NSData).decompressed(using: .zlib) as Data
    }
}

/// Stores active-session samples in small independent compressed files. A
/// damaged or partially transferred chunk therefore never invalidates the
/// rest of the month, while the legacy monthly archive remains readable.
final class TrackingSessionChunkArchive: @unchecked Sendable {
    private struct PendingChunk {
        var startedAt: Date
        var index: Int
        var readings: [SensorReading]
    }

    private let rootDirectory: URL
    private let lock = NSLock()
    private let encoder = RawDeviceDataMonthlyArchive.payloadEncoder()
    private var pending: [UUID: PendingChunk] = [:]
    private let calendar: Calendar

    init(rootDirectory: URL, calendar: Calendar = .autoupdatingCurrent) {
        self.rootDirectory = rootDirectory
        self.calendar = calendar
    }

    static func applicationSupport(
        fileManager: FileManager = .default
    ) throws -> TrackingSessionChunkArchive {
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return TrackingSessionChunkArchive(
            rootDirectory: root.appendingPathComponent(
                "TaptionPlan/RawData",
                isDirectory: true
            )
        )
    }

    func append(_ reading: SensorReading) throws {
        guard let sessionID = reading.trackingSessionID else { return }
        lock.lock()
        defer { lock.unlock() }
        var chunk = pending[sessionID] ?? PendingChunk(
            startedAt: reading.timestamp,
            index: 1,
            readings: []
        )
        if reading.timestamp.timeIntervalSince(chunk.startedAt) >= 30,
           !chunk.readings.isEmpty {
            try write(chunk, sessionID: sessionID)
            chunk = PendingChunk(
                startedAt: reading.timestamp,
                index: chunk.index + 1,
                readings: []
            )
        }
        if !chunk.readings.contains(where: { $0.id == reading.id }) {
            chunk.readings.append(reading)
        }
        pending[sessionID] = chunk
        if reading.trackingSessionEnded == true {
            try write(chunk, sessionID: sessionID)
            pending[sessionID] = nil
        }
    }

    func flushAll() throws {
        lock.lock()
        defer { lock.unlock() }
        for (sessionID, chunk) in pending where !chunk.readings.isEmpty {
            try write(chunk, sessionID: sessionID)
        }
        pending.removeAll()
    }

    private func write(_ chunk: PendingChunk, sessionID: UUID) throws {
        guard !chunk.readings.isEmpty else { return }
        let components = calendar.dateComponents(
            [.year, .month],
            from: chunk.startedAt
        )
        let month = String(
            format: "%04d-%02d",
            components.year ?? 1970,
            components.month ?? 1
        )
        let directory = rootDirectory
            .appendingPathComponent(month, isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let fileURL = directory.appendingPathComponent(
            String(format: "%06d.jsonl.zlib", chunk.index)
        )
        var payload = Data()
        for reading in chunk.readings.sorted(by: readingOrder) {
            payload.append(try encoder.encode(reading))
            payload.append(0x0A)
        }
        let compressed = try (payload as NSData).compressed(using: .zlib) as Data
        try compressed.write(
            to: fileURL,
            options: [
                .atomic,
                .completeFileProtectionUntilFirstUserAuthentication,
            ]
        )
    }

    private func readingOrder(_ lhs: SensorReading, _ rhs: SensorReading) -> Bool {
        if lhs.sequence != rhs.sequence {
            return (lhs.sequence ?? .max) < (rhs.sequence ?? .max)
        }
        return lhs.timestamp < rhs.timestamp
    }
}

/// Keeps the small piece of state needed to recover an active workout after
/// the iPhone app is terminated or relaunched. Route samples themselves stay
/// in the compressed archive; this store only contains the session envelope.
enum TrackingSessionRecoveryStore {
    private static let key = "active-tracking-session-v1"
    private static let appGroup = "group.com.taption.plan"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }

    static func read() -> TrackingSession? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(TrackingSession.self, from: data)
    }

    static func save(_ session: TrackingSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        defaults.set(data, forKey: key)
    }

    static func clear() {
        defaults.removeObject(forKey: key)
    }
}

actor SensorReadingArchive {
    private static let logger = Logger(
        subsystem: "com.taption.plan",
        category: "RawDeviceDataArchive"
    )
    private let fileURL: URL
    private let retentionInterval: TimeInterval
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let rawArchive: RawDeviceDataMonthlyArchive?
    private let trackingChunkArchive: TrackingSessionChunkArchive?
    private var lastCompactionAt: Date?

    init(
        fileURL: URL,
        retentionInterval: TimeInterval = 7 * 86_400,
        rawArchive: RawDeviceDataMonthlyArchive? = nil,
        trackingChunkArchive: TrackingSessionChunkArchive? = nil
    ) {
        self.fileURL = fileURL
        self.retentionInterval = max(86_400, retentionInterval)
        self.rawArchive = rawArchive
        self.trackingChunkArchive = trackingChunkArchive
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        decoder.dateDecodingStrategy = .secondsSince1970
    }

    static func applicationSupport(
        fileManager: FileManager = .default,
        rawArchive: RawDeviceDataMonthlyArchive? = nil
    ) throws -> SensorReadingArchive {
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = root.appendingPathComponent(
            "TaptionPlan/Sensors",
            isDirectory: true
        )
        return SensorReadingArchive(
            fileURL: directory.appendingPathComponent("sensor-readings-v1.jsonl"),
            rawArchive: rawArchive
                ?? (try? RawDeviceDataMonthlyArchive.applicationSupport()),
            trackingChunkArchive: try? TrackingSessionChunkArchive.applicationSupport()
        )
    }

    func append(_ reading: SensorReading, now: Date = .now) throws {
        try trackingChunkArchive?.append(reading)
        if let rawArchive, reading.trackingSessionID == nil {
            do {
                try rawArchive.append(
                    source: (
                        reading.locationFixQuality == .approximate
                            || reading.point == nil
                    )
                        ? .iPhoneSensor
                        : .gps,
                    kind: "sensor-reading",
                    payload: reading,
                    capturedAt: reading.timestamp
                )
            } catch {
                Self.logger.error(
                    "Raw sensor archive failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        if lastCompactionAt.map({ now.timeIntervalSince($0) >= 86_400 }) ?? true {
            try compact(now: now)
            lastCompactionAt = now
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try applyBackgroundFileProtectionIfNeeded()
        var line = try encoder.encode(reading)
        line.append(0x0A)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(
                to: fileURL,
                options: [
                    .atomic,
                    .completeFileProtectionUntilFirstUserAuthentication,
                ]
            )
        }
    }

    func readings(in span: TimeSpan) throws -> [SensorReading] {
        try allReadings()
            .filter { span.contains($0.timestamp) }
            .sorted { $0.timestamp < $1.timestamp }
    }

    func compact(now: Date = .now) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let cutoff = now.addingTimeInterval(-retentionInterval)
        let retained = try allReadings().filter { $0.timestamp >= cutoff }
        guard !retained.isEmpty else {
            try FileManager.default.removeItem(at: fileURL)
            return
        }
        let payload = try retained.reduce(into: Data()) { data, reading in
            data.append(try encoder.encode(reading))
            data.append(0x0A)
        }
        try payload.write(
            to: fileURL,
            options: [
                .atomic,
                .completeFileProtectionUntilFirstUserAuthentication,
            ]
        )
    }

    func deleteAll() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    func rawEnvelopes(inMonthContaining date: Date) throws
        -> [RawDeviceDataEnvelope] {
        guard let rawArchive else { return [] }
        return try rawArchive.envelopes(inMonthContaining: date)
    }

    private func allReadings() throws -> [SensorReading] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        return data.split(separator: 0x0A).compactMap {
            try? decoder.decode(SensorReading.self, from: Data($0))
        }
    }

    private func applyBackgroundFileProtectionIfNeeded() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        try FileManager.default.setAttributes(
            [
                .protectionKey:
                    FileProtectionType.completeUntilFirstUserAuthentication,
            ],
            ofItemAtPath: fileURL.path
        )
    }
}

@MainActor
final class AppleSensorDataService {
    private static let logger = Logger(
        subsystem: "com.taption.plan",
        category: "SensorArchive"
    )
    private let collector: AppleSensorCollector
    private let archive: SensorReadingArchive
    private let history: AppleMotionHistoryService
    private var collectionTask: Task<Void, Never>?
    private var activeConfiguration: SensorCollectionConfiguration?
    private var collectionGeneration = 0
    private var isCollectionStreamLive = false

    private(set) var lastPersistenceErrorDescription: String?
    var onReadingPersisted: ((SensorReading) -> Void)?

    init(
        collector: AppleSensorCollector? = nil,
        archive: SensorReadingArchive,
        history: AppleMotionHistoryService = AppleMotionHistoryService()
    ) {
        self.collector = collector ?? AppleSensorCollector()
        self.archive = archive
        self.history = history
    }

    static func applicationSupport(
        rawArchive: RawDeviceDataMonthlyArchive? = nil
    ) throws -> AppleSensorDataService {
        AppleSensorDataService(
            archive: try SensorReadingArchive.applicationSupport(
                rawArchive: rawArchive
            )
        )
    }

    func hardwareAvailability() -> SensorHardwareAvailability {
        collector.hardwareAvailability()
    }

    func locationPermissionState() -> PermissionState {
        collector.permissionState()
    }

    func motionPermissionState() -> PermissionState {
        history.permissionState()
    }

    func hasAlwaysLocationAuthorization() -> Bool {
        collector.hasAlwaysLocationAuthorization()
    }

    func requestLocationPermission(always: Bool = false) {
        collector.requestLocationPermission(always: always)
    }

    func startCollection(
        configuration: SensorCollectionConfiguration = .standard
    ) {
        // A finished stream leaves a completed task behind. Restart in that
        // case, otherwise recording never resumes after the reading stream
        // ends (for example when location permission was revoked).
        if collectionTask != nil,
           isCollectionStreamLive,
           activeConfiguration == configuration {
            return
        }
        stopCollection()
        lastPersistenceErrorDescription = nil
        activeConfiguration = configuration
        collectionGeneration += 1
        let generation = collectionGeneration
        isCollectionStreamLive = true
        let stream = collector.readings(configuration: configuration)
        collectionTask = Task { [weak self] in
            for await reading in stream {
                guard !Task.isCancelled, let self else { break }
                do {
                    try await self.archive.append(reading)
                    self.onReadingPersisted?(reading)
                } catch {
                    self.lastPersistenceErrorDescription = error.localizedDescription
                    Self.logger.error(
                        "Sensor archive append failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            guard let self, self.collectionGeneration == generation else {
                return
            }
            self.isCollectionStreamLive = false
        }
    }

    func stopCollection() {
        collectionGeneration += 1
        isCollectionStreamLive = false
        collectionTask?.cancel()
        collectionTask = nil
        activeConfiguration = nil
        collector.stop()
    }

    @discardableResult
    func beginTracking(
        kind: TrackingKind,
        linkedPlanID: UUID? = nil,
        sessionID: UUID = UUID(),
        preferences: GPSLoggingPreferences = .standard
    ) -> TrackingSession {
        collector.beginTracking(
            kind: kind,
            linkedPlanID: linkedPlanID,
            sessionID: sessionID,
            preferences: preferences
        )
    }

    @discardableResult
    func resumeTracking(
        _ session: TrackingSession,
        preferences: GPSLoggingPreferences = .standard
    ) -> TrackingSession {
        collector.resumeTracking(session, preferences: preferences)
    }

    func updateTrackingPreferences(_ preferences: GPSLoggingPreferences) {
        collector.updateTrackingPreferences(preferences)
    }

    /// 층 보정용 기압 표본 묶음. 기록 스트림과 달리 듀티사이클을 기다리지
    /// 않고 그 자리에서 잰다.
    func captureAltitudeBurst(
        count: Int = AltitudeBurstReducer.requestedSampleCount,
        timeout: TimeInterval = 20,
        onProgress: @MainActor (Int) -> Void = { _ in }
    ) async -> [AltitudeBurstSample] {
        await collector.captureAltitudeBurst(
            count: count,
            timeout: timeout,
            onProgress: onProgress
        )
    }

    @discardableResult
    func endTracking() -> TrackingSession? {
        collector.endTracking()
    }

    func archivedReadings(in span: TimeSpan) async throws -> [SensorReading] {
        try await archive.readings(in: span)
    }

    func archivedReadings(
        for session: TrackingSession,
        through date: Date = .now
    ) async throws -> [SensorReading] {
        let end = max(session.startedAt, session.endedAt ?? date)
        return try await archive.readings(
            in: TimeSpan(start: session.startedAt, end: end)
        ).filter { $0.trackingSessionID == session.id }
    }

    func recordExternalReadings(_ readings: [SensorReading]) async throws {
        guard let first = readings.min(by: { $0.timestamp < $1.timestamp }),
              let last = readings.max(by: { $0.timestamp < $1.timestamp }) else {
            return
        }
        let existingIDs = Set(
            try await archive.readings(
                in: TimeSpan(
                    start: first.timestamp.addingTimeInterval(-1),
                    end: last.timestamp.addingTimeInterval(1)
                )
            ).map(\.id)
        )
        var seen = Set<UUID>()
        for reading in readings
            .sorted(by: { $0.timestamp < $1.timestamp })
            where !existingIDs.contains(reading.id)
                && seen.insert(reading.id).inserted {
            try await archive.append(reading)
            onReadingPersisted?(reading)
        }
    }

    func motionActivities(
        in span: TimeSpan
    ) async throws -> [MotionActivityRecord] {
        try await history.activities(in: span)
    }

    func pedometerSummary(
        in span: TimeSpan
    ) async throws -> PedometerSummary? {
        try await history.pedometerSummary(in: span)
    }

    func pedometerEvidence(
        for activities: [MotionActivityRecord]
    ) async -> [AppleMovementEvidence] {
        var result: [AppleMovementEvidence] = []
        let eligible = activities
            .filter {
                $0.span.duration >= 2 * 60
                    && $0.motion != .stationary
                    && $0.motion != .unknown
            }
            .prefix(64)
        for activity in eligible {
            guard let summary = try? await history.pedometerSummary(
                in: activity.span
            ) else {
                continue
            }
            result.append(
                AppleMovementEvidence(
                    span: activity.span,
                    source: .iPhone,
                    kind: .steps,
                    stepCount: summary.stepCount,
                    distanceMeters: summary.distanceMeters,
                    sourceName: "iPhone CMPedometer",
                    deviceName: "iPhone"
                )
            )
        }
        return result
    }

    func deleteArchivedReadings() async throws {
        try await archive.deleteAll()
    }
}
