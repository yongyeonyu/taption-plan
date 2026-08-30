import CoreLocation
import Foundation
import OSLog
import TaptionPlanCore

struct PhoneScreenSnapshot: Codable, Hashable, Sendable {
    var brightness: Double
    var isOn: Bool

    init(brightness: Double, isOn: Bool) {
        self.brightness = min(1, max(0, brightness))
        self.isOn = isOn
    }
}

/// Keeps the last display observation available to a background sensor wake.
/// iOS does not provide a general-purpose ambient-light/lux API to apps.
enum PhoneScreenActivityStore {
    private static let brightnessKey = "TaptionPlan.screenBrightness"
    private static let isOnKey = "TaptionPlan.screenIsOn"

    static func update(brightness: Double, isOn: Bool) {
        let defaults = UserDefaults.standard
        defaults.set(min(1, max(0, brightness)), forKey: brightnessKey)
        defaults.set(isOn, forKey: isOnKey)
    }

    static func snapshot() -> PhoneScreenSnapshot {
        let defaults = UserDefaults.standard
        return PhoneScreenSnapshot(
            brightness: defaults.object(forKey: brightnessKey) as? Double ?? 0,
            isOn: defaults.object(forKey: isOnKey) as? Bool ?? false
        )
    }
}

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
    private enum ArchiveError: Swift.Error {
        case invalidEnvelope
        case conflictingEnvelope
    }
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
    private var monthEnvelopeCache: [String: [RawDeviceDataEnvelope]] = [:]
    private var monthEnvelopeCacheOrder: [String] = []
    private static let monthEnvelopeCacheLimit = 2

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
                invalidateCachedMonth(monthKey)
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

    func envelopes(
        inMonthContaining date: Date,
        strict: Bool = false
    ) throws -> [RawDeviceDataEnvelope] {
        lock.lock()
        defer { lock.unlock() }
        let monthKey = monthKey(for: date)
        if !strict, let cached = cachedEnvelopes(for: monthKey) {
            return cached
        }
        let directory: URL
        if strict {
            directory = rootDirectory.appendingPathComponent(
                monthKey,
                isDirectory: true
            )
            guard FileManager.default.fileExists(atPath: directory.path) else {
                return []
            }
        } else {
            directory = try monthDirectory(for: monthKey)
        }
        var payloads: [Data] = []
        let legacyURL = legacyCompressedFileURL(
            in: directory,
            monthKey: monthKey
        )
        if FileManager.default.fileExists(atPath: legacyURL.path) {
            do {
                payloads.append(try existingPayload(at: legacyURL))
            } catch {
                if strict { throw error }
            }
        }
        let journalURL = journalFileURL(in: directory)
        if FileManager.default.fileExists(atPath: journalURL.path) {
            do {
                payloads.append(try Data(contentsOf: journalURL))
            } catch {
                if strict { throw error }
            }
        }
        let chunks = directory.appendingPathComponent(
            "chunks",
            isDirectory: true
        )
        if FileManager.default.fileExists(atPath: chunks.path) {
            let files: [URL]
            do {
                files = try FileManager.default.contentsOfDirectory(
                    at: chunks,
                    includingPropertiesForKeys: nil
                )
            } catch {
                if strict { throw error }
                return []
            }
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                do {
                    let data = try Data(contentsOf: file)
                    if file.pathExtension == "zlib" {
                        payloads.append(try decompress(data))
                    } else if file.lastPathComponent.hasSuffix(".jsonl.pending") {
                        payloads.append(data)
                    }
                } catch {
                    if strict { throw error }
                }
            }
        }
        var decoded: [RawDeviceDataEnvelope] = []
        for payload in payloads {
            for line in payload.split(separator: 0x0A) {
                do {
                    decoded.append(
                        try decoder.decode(
                            RawDeviceDataEnvelope.self,
                            from: Data(line)
                        )
                    )
                } catch {
                    if strict { throw ArchiveError.invalidEnvelope }
                }
            }
        }
        var byID: [UUID: RawDeviceDataEnvelope] = [:]
        for envelope in decoded {
            if let existing = byID[envelope.id] {
                if strict, existing != envelope {
                    throw ArchiveError.conflictingEnvelope
                }
            } else {
                byID[envelope.id] = envelope
            }
        }
        let envelopes = byID.values
            .sorted {
                if $0.capturedAt != $1.capturedAt {
                    return $0.capturedAt < $1.capturedAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
        cache(envelopes, for: monthKey)
        return envelopes
    }

    private func cachedEnvelopes(
        for monthKey: String
    ) -> [RawDeviceDataEnvelope]? {
        guard let cached = monthEnvelopeCache[monthKey] else { return nil }
        monthEnvelopeCacheOrder.removeAll { $0 == monthKey }
        monthEnvelopeCacheOrder.append(monthKey)
        return cached
    }

    private func cache(
        _ envelopes: [RawDeviceDataEnvelope],
        for monthKey: String
    ) {
        monthEnvelopeCache[monthKey] = envelopes
        monthEnvelopeCacheOrder.removeAll { $0 == monthKey }
        monthEnvelopeCacheOrder.append(monthKey)
        while monthEnvelopeCacheOrder.count > Self.monthEnvelopeCacheLimit {
            monthEnvelopeCache[monthEnvelopeCacheOrder.removeFirst()] = nil
        }
    }

    private func invalidateCachedMonth(_ monthKey: String) {
        monthEnvelopeCache[monthKey] = nil
        monthEnvelopeCacheOrder.removeAll { $0 == monthKey }
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

    func sensorReadings() throws -> [SensorReading] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        var result: [SensorReading] = []
        var seen = Set<UUID>()
        for directory in directories where directory.lastPathComponent.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression) != nil {
            let parts = directory.lastPathComponent.split(separator: "-")
            guard parts.count == 2,
                  let year = Int(parts[0]),
                  let month = Int(parts[1]),
                  let date = Calendar.autoupdatingCurrent.date(from: DateComponents(year: year, month: month, day: 1)) else { continue }
            for envelope in try envelopes(inMonthContaining: date) where envelope.kind == "sensor-reading" {
                guard let payload = envelope.payloadJSON.data(using: .utf8),
                      let reading = try? decoder.decode(SensorReading.self, from: payload),
                      seen.insert(reading.id).inserted else { continue }
                result.append(reading)
            }
        }
        return result.sorted { $0.timestamp < $1.timestamp }
    }

    func allEnvelopes() throws -> [RawDeviceDataEnvelope] {
        guard FileManager.default.fileExists(atPath: rootDirectory.path) else {
            return []
        }
        let directories = try FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        var byID: [UUID: RawDeviceDataEnvelope] = [:]
        for directory in directories
        where directory.lastPathComponent.range(
            of: #"^\d{4}-\d{2}$"#,
            options: .regularExpression
        ) != nil {
            let parts = directory.lastPathComponent.split(separator: "-")
            guard parts.count == 2,
                  let year = Int(parts[0]),
                  let month = Int(parts[1]),
                  let date = calendar.date(
                    from: DateComponents(year: year, month: month, day: 1)
                  ) else { continue }
            for envelope in try envelopes(inMonthContaining: date, strict: true) {
                if let existing = byID[envelope.id], existing != envelope {
                    throw ArchiveError.conflictingEnvelope
                }
                byID[envelope.id] = envelope
            }
        }
        return byID.values.sorted {
            if $0.capturedAt != $1.capturedAt {
                return $0.capturedAt < $1.capturedAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
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

    func readings(in span: TimeSpan) throws -> [SensorReading] {
        lock.lock()
        let pendingReadings = pending.values.flatMap(\.readings)
        lock.unlock()

        var values = pendingReadings.filter {
            span.contains($0.timestamp)
        }
        var seen = Set(values.map(\.id))
        var month = calendar.dateInterval(of: .month, for: span.start)?.start
            ?? span.start
        let lastMonth = calendar.dateInterval(of: .month, for: span.end)?.start
            ?? span.end
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        while month <= lastMonth {
            let components = calendar.dateComponents([.year, .month], from: month)
            let monthKey = String(
                format: "%04d-%02d",
                components.year ?? 1970,
                components.month ?? 1
            )
            let monthDirectory = rootDirectory.appendingPathComponent(
                monthKey,
                isDirectory: true
            )
            let sessionDirectories = (
                try? FileManager.default.contentsOfDirectory(
                    at: monthDirectory,
                    includingPropertiesForKeys: nil
                )
            ) ?? []
            for sessionDirectory in sessionDirectories
            where UUID(uuidString: sessionDirectory.lastPathComponent) != nil {
                let files = (
                    try? FileManager.default.contentsOfDirectory(
                        at: sessionDirectory,
                        includingPropertiesForKeys: nil
                    )
                ) ?? []
                for file in files where file.lastPathComponent.hasSuffix(
                    ".jsonl.zlib"
                ) {
                    guard let compressed = try? Data(contentsOf: file),
                          let data = try? (compressed as NSData).decompressed(
                              using: .zlib
                          ) as Data else { continue }
                    for line in data.split(separator: 0x0A) {
                        guard let reading = try? decoder.decode(
                            SensorReading.self,
                            from: Data(line)
                        ),
                        span.contains(reading.timestamp),
                        seen.insert(reading.id).inserted else { continue }
                        values.append(reading)
                    }
                }
            }
            guard let next = calendar.date(
                byAdding: .month,
                value: 1,
                to: month
            ), next > month else { break }
            month = next
        }
        return values.sorted { $0.timestamp < $1.timestamp }
    }

    func allPersistedReadings() throws -> [SensorReading] {
        lock.lock()
        let files = FileManager.default.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: nil
        )?.compactMap { $0 as? URL } ?? []
        lock.unlock()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        var result: [SensorReading] = []
        var seen = Set<UUID>()
        for file in files where file.pathExtension == "zlib" {
            guard let compressed = try? Data(contentsOf: file),
                  let data = try? (compressed as NSData).decompressed(using: .zlib) as Data else { continue }
            for line in data.split(separator: 0x0A) {
                guard let reading = try? decoder.decode(SensorReading.self, from: Data(line)),
                      seen.insert(reading.id).inserted else { continue }
                result.append(reading)
            }
        }
        return result.sorted { $0.timestamp < $1.timestamp }
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

actor RawDeviceDataDayArchive {
    private static let domain = "raw-device-data"
    private enum Error: Swift.Error {
        case invalidEnvelope
    }
    private let store: TaptionPlanDayStore

    init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        store = try TaptionPlanDayStore(url: databaseURL)
    }

    static func applicationSupport() throws -> RawDeviceDataDayArchive {
        try RawDeviceDataDayArchive(
            databaseURL: TaptionLocalDatabaseLocation
                .sharedOrApplicationSupport()
        )
    }

    func append(_ envelope: RawDeviceDataEnvelope) async throws {
        try await store.appendEvents([
            .init(
                day: TaptionPlanDayKey(date: envelope.capturedAt),
                timestamp: envelope.capturedAt,
                sequence: 0,
                id: envelope.id.uuidString,
                domain: Self.domain,
                payload: TaptionPlanCanonicalStorage.envelope(
                    for: try TaptionPlanCanonicalStorage.encode(envelope)
                )
            )
        ])
    }

    func envelopes(in span: TimeSpan) async throws
        -> [RawDeviceDataEnvelope] {
        let events = try await store.events(
            from: TaptionPlanDayKey(date: span.start),
            through: TaptionPlanDayKey(date: span.end),
            domain: Self.domain
        )
        return events.compactMap { event in
            guard let encoded = try? TaptionPlanCanonicalStorage.encodedPayload(
                from: event.payload
            ), let value = try? TaptionPlanCanonicalStorage.decode(
                RawDeviceDataEnvelope.self,
                from: encoded
            ), span.contains(value.capturedAt) else { return nil }
            return value
        }
    }

    func allEnvelopes() async throws -> [RawDeviceDataEnvelope] {
        try await store.allEvents(domain: Self.domain).map { event in
            guard let encoded = try? TaptionPlanCanonicalStorage.encodedPayload(
                from: event.payload
            ), let value = try? TaptionPlanCanonicalStorage.decode(
                RawDeviceDataEnvelope.self,
                from: encoded
            ) else {
                throw Error.invalidEnvelope
            }
            return value
        }
    }

    func checkpoint() async throws {
        try await store.checkpoint()
    }
}

actor SensorReadingArchive {
    private static let logger = Logger(
        subsystem: "com.taption.plan",
        category: "RawDeviceDataArchive"
    )
    private enum Error: Swift.Error {
        case dayStoreUnavailable
        case invalidReading
    }

    private static let migrationKey = "sensor-reading-v1-to-day-store-v2"
    private let fileURL: URL
    private let dayStore: TaptionPlanDayStore?
    private let retentionInterval: TimeInterval
    private let legacyDecoder: JSONDecoder
    private let rawArchive: RawDeviceDataMonthlyArchive?
    private let trackingChunkArchive: TrackingSessionChunkArchive?

    init(
        fileURL: URL,
        retentionInterval: TimeInterval = 7 * 86_400,
        rawArchive: RawDeviceDataMonthlyArchive? = nil,
        trackingChunkArchive: TrackingSessionChunkArchive? = nil,
        dayStoreURL: URL? = nil
    ) throws {
        self.fileURL = fileURL
        self.retentionInterval = max(86_400, retentionInterval)
        self.rawArchive = rawArchive
        self.trackingChunkArchive = trackingChunkArchive
        let storeURL = dayStoreURL ?? fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("taption-plan-v2.sqlite")
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        self.dayStore = try TaptionPlanDayStore(url: storeURL)
        self.legacyDecoder = JSONDecoder()
        legacyDecoder.dateDecodingStrategy = .secondsSince1970
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
        let storeRoot = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.taption.plan"
        ) ?? root.appendingPathComponent("TaptionPlan", isDirectory: true)
        let storeURL = storeRoot.appendingPathComponent(
            "taption-data-v2.sqlite",
            isDirectory: false
        )
        return try SensorReadingArchive(
            fileURL: directory.appendingPathComponent("sensor-readings-v1.jsonl"),
            rawArchive: rawArchive
                ?? (try? RawDeviceDataMonthlyArchive.applicationSupport()),
            trackingChunkArchive: try? TrackingSessionChunkArchive.applicationSupport(),
            dayStoreURL: storeURL
        )
    }

    func append(_ reading: SensorReading, now: Date = .now) async throws {
        try await append([reading], now: now)
    }

    func append(_ readings: [SensorReading], now: Date = .now) async throws {
        guard !readings.isEmpty else { return }
        try await ensureMigrated()
        guard let dayStore else { throw Error.dayStoreUnavailable }
        let unique = Dictionary(grouping: readings, by: \.id).compactMap { $0.value.first }
        var knownIDs = Set<String>()
        let days = unique.map { TaptionPlanDayKey(date: $0.timestamp) }
        if let start = days.min(), let end = days.max() {
            let events = try await dayStore.events(from: start, through: end, domain: "sensor-reading")
            knownIDs.formUnion(events.map(\.id))
        }
        let events = try unique
            .filter { !knownIDs.contains($0.id.uuidString) }
            .map { reading in
                TaptionPlanDayStore.Event(
                    day: TaptionPlanDayKey(date: reading.timestamp),
                    timestamp: reading.timestamp,
                    sequence: UInt64(max(0, reading.sequence ?? 0)),
                    id: reading.id.uuidString,
                    domain: "sensor-reading",
                    payload: TaptionPlanCanonicalStorage.envelope(
                        for: try TaptionPlanCanonicalStorage.encode(reading)
                    )
                )
            }
        try await dayStore.appendEvents(events)
        _ = now
    }

    func readings(in span: TimeSpan) async throws -> [SensorReading] {
        try await ensureMigrated()
        let values = try await loadEvents(in: span)
        return values.sorted(by: readingOrder)
    }

    func routeReadings(in span: TimeSpan) async throws -> [SensorReading] {
        try await ensureMigrated()
        return try await loadEvents(in: span).sorted(by: readingOrder)
    }

    func allReadings() async throws -> [SensorReading] {
        try await ensureMigrated()
        guard let dayStore else { throw Error.dayStoreUnavailable }
        return try await dayStore.allEvents(domain: "sensor-reading").map { event in
            guard let encoded = try? TaptionPlanCanonicalStorage.encodedPayload(
                from: event.payload
            ), let reading = try? TaptionPlanCanonicalStorage.decode(
                SensorReading.self,
                from: encoded
            ) else {
                throw Error.invalidReading
            }
            return reading
        }
            .sorted(by: readingOrder)
    }

    func compact(now: Date = .now) async throws {
        _ = now
        try await ensureMigrated()
    }

    func deleteAll() async throws {
        try await ensureMigrated()
    }

    func rawEnvelopes(inMonthContaining date: Date) async throws
        -> [RawDeviceDataEnvelope] {
        guard let rawArchive else { return [] }
        return try rawArchive.envelopes(inMonthContaining: date)
    }

    private func ensureMigrated() async throws {
        guard let dayStore else { throw Error.dayStoreUnavailable }
        if try await dayStore.migrationCompleted(Self.migrationKey) { return }
        var migrated = readLegacyFile()
        if let rawArchive { migrated.append(contentsOf: try rawArchive.sensorReadings()) }
        if let trackingChunkArchive { migrated.append(contentsOf: try trackingChunkArchive.allPersistedReadings()) }
        var seen = Set<UUID>()
        let unique = migrated.filter { seen.insert($0.id).inserted }
        let days = unique.map { TaptionPlanDayKey(date: $0.timestamp) }
        var existingIDs = Set<String>()
        if let start = days.min(), let end = days.max() {
            let existing = try await dayStore.events(
                from: start,
                through: end,
                domain: "sensor-reading"
            )
            existingIDs.formUnion(existing.map(\.id))
        }
        let events = try unique.filter { !existingIDs.contains($0.id.uuidString) }.map { reading in
            TaptionPlanDayStore.Event(
                day: TaptionPlanDayKey(date: reading.timestamp),
                timestamp: reading.timestamp,
                sequence: UInt64(max(0, reading.sequence ?? 0)),
                id: reading.id.uuidString,
                domain: "sensor-reading",
                payload: TaptionPlanCanonicalStorage.envelope(
                    for: try TaptionPlanCanonicalStorage.encode(reading)
                )
            )
        }
        if !events.isEmpty { try await dayStore.appendEvents(events) }
        _ = try await dayStore.markMigrationCompleted(Self.migrationKey)
    }

    private func loadEvents(in span: TimeSpan) async throws -> [SensorReading] {
        guard let dayStore else { throw Error.dayStoreUnavailable }
        let start = TaptionPlanDayKey(date: span.start)
        let end = TaptionPlanDayKey(date: span.end)
        return try await dayStore.events(from: start, through: end, domain: "sensor-reading")
            .compactMap { event in
                guard let encoded = try? TaptionPlanCanonicalStorage.encodedPayload(
                    from: event.payload
                ), let reading = try? TaptionPlanCanonicalStorage.decode(
                    SensorReading.self,
                    from: encoded
                ), span.contains(reading.timestamp) else { return nil }
                return reading
            }
    }

    private func readLegacyFile() -> [SensorReading] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return data.split(separator: 0x0A).compactMap {
            try? legacyDecoder.decode(SensorReading.self, from: Data($0))
        }
    }

    private func readingOrder(_ lhs: SensorReading, _ rhs: SensorReading) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        if lhs.sequence != rhs.sequence { return (lhs.sequence ?? .max) < (rhs.sequence ?? .max) }
        return lhs.id.uuidString < rhs.id.uuidString
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
    private var persistedReadingCount = 0
    private var lastPersistedReadingAt: Date?

    private(set) var lastPersistenceErrorDescription: String?
    var onReadingPersisted: ((SensorReading) -> Void)?
    var onPersistenceFailed: ((String) -> Void)?

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

    func locationAuthorizationStatus() -> CLAuthorizationStatus {
        collector.locationAuthorizationStatus()
    }

    func hasPreciseLocationAuthorization() -> Bool {
        collector.hasPreciseLocationAuthorization()
    }

    func requestLocationPermission(always: Bool = false) {
        collector.requestLocationPermission(always: always)
    }

    func requestMotionPermission() async -> PermissionState {
        await history.requestAuthorization()
    }

    func startCollection(
        configuration: SensorCollectionConfiguration = .standard
    ) {
        let configuration = configuration.normalized
        // A finished stream leaves a completed task behind. Restart in that
        // case, otherwise recording never resumes after the reading stream
        // ends (for example when location permission was revoked).
        if collectionTask != nil,
           isCollectionStreamLive,
           activeConfiguration == configuration {
            return
        }
        stopCollection()
        activeConfiguration = configuration
        collectionGeneration += 1
        let generation = collectionGeneration
        isCollectionStreamLive = true
        TaptionPlanDiagnosticsLogger.shared.record(
            "sensor_collection_started",
            fields: [
                "generation": String(generation),
                "minimum_interval": String(
                    configuration.minimumEmissionInterval
                ),
                "background_location": String(
                    configuration.allowsBackgroundLocation
                ),
            ]
        )
        let stream = collector.readings(configuration: configuration)
        collectionTask = Task { [weak self] in
            for await reading in stream {
                guard !Task.isCancelled, let self else { break }
                do {
                    try await self.archive.append(reading)
                    self.persistedReadingCount += 1
                    self.lastPersistedReadingAt = reading.timestamp
                    self.lastPersistenceErrorDescription = nil
                    self.onReadingPersisted?(reading)
                } catch {
                    let description = error.localizedDescription
                    if self.lastPersistenceErrorDescription != description {
                        TaptionPlanDiagnosticsLogger.shared.record(
                            "sensor_archive_append_failed",
                            level: .error,
                            fields: TaptionDiagnosticError.fields(for: error)
                        )
                    }
                    self.lastPersistenceErrorDescription = description
                    self.onPersistenceFailed?(description)
                    Self.logger.error(
                        "Sensor archive append failed: \(error.localizedDescription, privacy: .public)"
                    )
                    self.stopCollection()
                    return
                }
            }
            guard let self, self.collectionGeneration == generation else {
                return
            }
            self.isCollectionStreamLive = false
            self.collectionTask = nil
            self.activeConfiguration = nil
            TaptionPlanDiagnosticsLogger.shared.record(
                "sensor_collection_stream_ended",
                level: .notice,
                fields: [
                    "generation": String(generation),
                    "last_persisted_at": self.lastPersistedReadingAt.map {
                        String($0.timeIntervalSince1970)
                    } ?? "none",
                ]
            )
        }
    }

    /// Returns a monotonic token for waiting on the next archived sample.
    /// Background refresh uses this instead of assuming that a sampling window
    /// elapsed means the archive consumer finished its write.
    func persistenceToken() -> Int {
        persistedReadingCount
    }

    func latestPersistedReadingDate() -> Date? {
        lastPersistedReadingAt
    }

    func isCollectionLive() -> Bool {
        isCollectionStreamLive
    }

    func waitForPersistedReading(
        after token: Int,
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = Date.now.addingTimeInterval(max(0, timeout))
        while !Task.isCancelled, Date.now < deadline {
            if persistedReadingCount > token {
                return true
            }
            if !isCollectionStreamLive {
                return false
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return persistedReadingCount > token
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

    func archivedRouteReadings(
        in span: TimeSpan
    ) async throws -> [SensorReading] {
        try await archive.routeReadings(in: span)
    }

    func allArchivedRouteReadings() async throws -> [SensorReading] {
        try await archive.allReadings()
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

    func archivedRouteReadings(
        for session: TrackingSession,
        through date: Date = .now
    ) async throws -> [SensorReading] {
        let end = max(session.startedAt, session.endedAt ?? date)
        return try await archive.routeReadings(
            in: TimeSpan(start: session.startedAt, end: end)
        ).filter { $0.trackingSessionID == session.id }
    }

    func recordExternalReadings(_ readings: [SensorReading]) async throws {
        guard let first = readings.min(by: { $0.timestamp < $1.timestamp }),
              let last = readings.max(by: { $0.timestamp < $1.timestamp }) else {
            return
        }
        let existingIDs = Set(
            try await archive.routeReadings(
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
