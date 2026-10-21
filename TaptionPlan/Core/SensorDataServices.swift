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
    var payloadChecksum: String?
    var payloadByteCount: Int?

    init<T: Encodable>(
        id: UUID? = nil,
        capturedAt: Date = .now,
        source: RawDeviceDataSource,
        kind: String,
        schemaVersion: Int = 1,
        payload: T,
        encoder: JSONEncoder = RawDeviceDataEnvelope.payloadEncoder()
    ) throws {
        self.capturedAt = capturedAt
        self.source = source
        self.kind = kind
        self.schemaVersion = schemaVersion
        let data = try encoder.encode(payload)
        self.payloadJSON = String(decoding: data, as: UTF8.self)
        let checksum = TaptionPlanCanonicalStorage.checksum(data)
        self.payloadChecksum = checksum
        self.payloadByteCount = data.count
        self.id = id ?? Self.stableID(
            capturedAt: capturedAt,
            source: source,
            kind: kind,
            schemaVersion: schemaVersion,
            payloadChecksum: checksum
        )
    }

    static func payloadEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    var hasValidPayload: Bool {
        guard let data = payloadJSON.data(using: .utf8) else { return false }
        if let payloadByteCount, payloadByteCount != data.count { return false }
        if let payloadChecksum,
           payloadChecksum != TaptionPlanCanonicalStorage.checksum(data) {
            return false
        }
        return true
    }

    private static func stableID(
        capturedAt: Date,
        source: RawDeviceDataSource,
        kind: String,
        schemaVersion: Int,
        payloadChecksum: String
    ) -> UUID {
        let seed = [
            source.rawValue,
            kind,
            String(schemaVersion),
            String(capturedAt.timeIntervalSince1970.bitPattern),
            payloadChecksum,
        ].joined(separator: "|")
        let hex = String(
            TaptionPlanCanonicalStorage.checksum(Data(seed.utf8)).prefix(32)
        )
        let first = String(hex.prefix(8))
        let second = String(hex.dropFirst(8).prefix(4))
        let third = String(hex.dropFirst(12).prefix(4))
        let fourth = String(hex.dropFirst(16).prefix(4))
        let fifth = String(hex.dropFirst(20).prefix(12))
        let value = "\(first)-\(second)-\(third)-\(fourth)-\(fifth)"
        return UUID(uuidString: value)!
    }
}

/// Keeps the small piece of state needed to recover an active workout after
/// the iPhone app is terminated or relaunched. Route samples themselves stay
/// in the compressed archive; this store only contains the session envelope.
enum TrackingSessionRecoveryStore {
    private static let key = "active-tracking-session-v1"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: TaptionPlanSharedContainer.appGroupIdentifier) ?? .standard
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

/// 기기 원시 봉투(`RawDeviceDataEnvelope`)의 저장소. 새 저장소의 `raw_events` 표에 종류 `device-envelope`로 둔다.
/// 같은 `id`에 다른 내용이 오면 거부하고, 자동 수집 출처(`source`)는 provenance 열에 남긴다.
actor RawDeviceDataDayArchive {
    private static let kind = TaptionRawEvent.Kind.deviceEnvelope
    private static let decodeBatchSize = 128
    private enum Error: Swift.Error {
        case invalidEnvelope
    }
    private let store: TaptionStoreV2
    private let writeLockURL: URL
    private var dataDeletionGeneration: UInt64

    init(databaseURL: URL) throws {
        try self.init(store: TaptionStoreV2(url: databaseURL))
    }

    init(store: TaptionStoreV2) throws {
        self.store = store
        writeLockURL = store.url.appendingPathExtension("lock")
        dataDeletionGeneration = TaptionDataDeletionFence.currentGeneration()
    }

    static func applicationSupport() throws -> RawDeviceDataDayArchive {
        try RawDeviceDataDayArchive(store: TaptionStoreV2.applicationSupport())
    }

    func append(_ envelope: RawDeviceDataEnvelope) async throws {
        try await append([envelope])
    }

    func append(_ envelopes: [RawDeviceDataEnvelope]) async throws {
        guard !envelopes.isEmpty else { return }
        let generation = dataDeletionGeneration
        let events = try events(for: envelopes)
        try await withProtectedLock { [self] in
            try await self.checkDataGeneration(generation)
            try await self.store.appendRawEvents(events)
        }
    }

    func validateAppend(_ envelopes: [RawDeviceDataEnvelope]) async throws {
        guard !envelopes.isEmpty else { return }
        let generation = dataDeletionGeneration
        let events = try events(for: envelopes)
        try await withProtectedLock { [self] in
            try await self.checkDataGeneration(generation)
            try await self.store.validateRawEvents(events)
        }
    }

    func backupDateRanges() async throws -> [ClosedRange<Date>] {
        let generation = dataDeletionGeneration
        try checkDataGeneration(generation)
        return try await store.rawEventDayRanges(kind: Self.kind)
    }

    func envelopes(in span: TimeSpan) async throws
        -> [RawDeviceDataEnvelope] {
        let generation = dataDeletionGeneration
        let events = try await withProtectedLock { [self] in
            try await self.checkDataGeneration(generation)
            return try await self.store.rawEvents(kind: Self.kind, from: span.start, through: span.end)
        }
        return try await decodedEnvelopes(events, generation: generation).filter {
            span.contains($0.capturedAt)
        }
    }

    func allEnvelopes() async throws -> [RawDeviceDataEnvelope] {
        let generation = dataDeletionGeneration
        let events = try await withProtectedLock { [self] in
            try await self.checkDataGeneration(generation)
            return try await self.store.rawEvents(kind: Self.kind)
        }
        return try await decodedEnvelopes(events, generation: generation)
    }

    private func decodedEnvelopes(
        _ events: [TaptionRawEvent],
        generation: UInt64
    ) async throws -> [RawDeviceDataEnvelope] {
        var values: [RawDeviceDataEnvelope] = []
        values.reserveCapacity(events.count)
        for (index, event) in events.enumerated() {
            if index > 0, index.isMultiple(of: Self.decodeBatchSize) {
                _ = await Task.yield()
            }
            if index.isMultiple(of: Self.decodeBatchSize) {
                try Task.checkCancellation()
                try checkDataGeneration(generation)
            }
            guard let value = try? TaptionRawPayloadCoding.decode(RawDeviceDataEnvelope.self, from: event.payload),
                  value.hasValidPayload, value.id.uuidString == event.id else {
                throw Error.invalidEnvelope
            }
            values.append(value)
        }
        try Task.checkCancellation()
        try checkDataGeneration(generation)
        return values
    }

    private func withProtectedLock<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let lockURL = writeLockURL
        return try await TaptionRepositoryBackgroundExecution.run {
            let lock = try await TaptionDataFileLock.acquire(url: lockURL)
            defer { lock.unlock() }
            return try await operation()
        }
    }

    private func events(for envelopes: [RawDeviceDataEnvelope]) throws -> [TaptionRawEvent] {
        guard envelopes.allSatisfy(\.hasValidPayload) else {
            throw Error.invalidEnvelope
        }
        var uniqueByID: [UUID: RawDeviceDataEnvelope] = [:]
        for envelope in envelopes {
            if let existing = uniqueByID[envelope.id], existing != envelope {
                throw TaptionStoreV2Error.rawEventConflict(kind: Self.kind, id: envelope.id.uuidString)
            }
            uniqueByID[envelope.id] = envelope
        }
        return try uniqueByID.values.map { envelope in
            TaptionRawEvent(
                kind: Self.kind,
                id: envelope.id.uuidString,
                timestamp: envelope.capturedAt,
                origin: envelope.source == .healthKit ? .imported : .auto,
                provenance: [
                    "source:\(envelope.source.rawValue)",
                    "kind:\(envelope.kind)",
                    "schema:\(envelope.schemaVersion)",
                ],
                payload: try TaptionRawPayloadCoding.encode(envelope)
            )
        }
    }

    func checkpoint() async throws {
        let generation = dataDeletionGeneration
        try await withProtectedLock { [self] in
            try await self.checkDataGeneration(generation)
            try await self.store.checkpoint()
        }
    }

    func deleteAll(generation: UInt64? = nil) async throws {
        let nextGeneration = generation
            ?? TaptionDataDeletionFence.currentGeneration()
        try await withProtectedLock { [self] in
            try await self.deleteProtected(generation: nextGeneration)
        }
    }

    private func deleteProtected(generation: UInt64) async throws {
        dataDeletionGeneration = generation
        try await store.deleteRawEvents(kind: Self.kind)
    }

    private func checkDataGeneration(_ generation: UInt64) throws {
        guard generation == dataDeletionGeneration,
              TaptionDataDeletionFence.allows(generation: generation) else {
            throw CancellationError()
        }
    }
}

/// 위치·센서 원본의 유일한 저장소. `TaptionStoreV2`의 `readings` 표만 쓴다.
/// 이전 형식(JSONL, 일자 DB 이벤트)은 옮기지 않고 버린다.
actor SensorReadingArchive {
    private enum Error: Swift.Error {
        case conflictingReading
    }

    private let store: TaptionStoreV2
    private let legacyFileURL: URL
    private let writeLockURL: URL
    private let beforeValidateAppend: @Sendable () async throws -> Void
    private var dataDeletionGeneration: UInt64

    /// - Parameters:
    ///   - fileURL: 이전 JSONL 파일 위치. 비어 있을 때만 지우고 내용이 있으면 보존한다.
    ///   - storeURL: 새 저장소 파일. 없으면 `fileURL` 옆의 `taption-store.sqlite`.
    init(
        fileURL: URL,
        storeURL: URL? = nil,
        store: TaptionStoreV2? = nil,
        beforeValidateAppend: @escaping @Sendable () async throws -> Void = {}
    ) throws {
        let resolvedStoreURL = storeURL ?? fileURL
            .deletingLastPathComponent()
            .appendingPathComponent(TaptionStoreV2.fileName)
        self.store = try store ?? TaptionStoreV2(url: resolvedStoreURL)
        self.legacyFileURL = fileURL
        self.writeLockURL = resolvedStoreURL.appendingPathExtension("lock")
        self.beforeValidateAppend = beforeValidateAppend
        self.dataDeletionGeneration = TaptionDataDeletionFence.currentGeneration()
        let legacySize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        if legacySize == 0 { try? FileManager.default.removeItem(at: fileURL) }
    }

    static func applicationSupport(
        fileManager: FileManager = .default
    ) throws -> SensorReadingArchive {
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let shared = try TaptionStoreV2.applicationSupport(fileManager: fileManager)
        return try SensorReadingArchive(
            fileURL: root.appendingPathComponent("TaptionPlan/Sensors/sensor-readings-v1.jsonl"),
            store: shared
        )
    }

    func append(_ reading: SensorReading, now: Date = .now) async throws {
        try await append([reading], now: now)
    }

    func append(_ readings: [SensorReading], now: Date = .now) async throws {
        guard !readings.isEmpty else { return }
        _ = now
        let generation = dataDeletionGeneration
        try Self.rejectConflicts(within: readings)
        try await withLock {
            try await self.checkDataGeneration(generation)
            try await self.store.appendImmutableReadings(readings)
        }
    }

    /// 같은 `id`인데 내용이 다른 기록이 함께 오거나 이미 저장돼 있으면 거부한다.
    func validateAppend(_ readings: [SensorReading]) async throws {
        guard !readings.isEmpty else { return }
        let generation = dataDeletionGeneration
        try Self.rejectConflicts(within: readings)
        try await beforeValidateAppend()
        try checkDataGeneration(generation)
        let existing = try await store.readings(ids: readings.map(\.id.uuidString))
        let incoming = Dictionary(readings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for reading in existing {
            guard let sent = incoming[reading.id],
                  TaptionReadingRowCodec.sameStoredContent(sent, reading) else {
                throw Error.conflictingReading
            }
        }
    }

    func readings(in span: TimeSpan) async throws -> [SensorReading] {
        try await readingsLoadResult(in: span).readings
    }

    func readingsLoadResult(
        in span: TimeSpan
    ) async throws -> (readings: [SensorReading], isComplete: Bool) {
        let generation = dataDeletionGeneration
        guard span.start <= span.end else { return ([], true) }
        let result = try await store.readingsLoadResult(from: span.start, through: span.end)
        try checkDataGeneration(generation)
        reportIncomplete(result.isComplete)
        return result
    }

    func routeReadings(in span: TimeSpan) async throws -> [SensorReading] {
        try await routeReadingsLoadResult(in: span).readings
    }

    func routeReadingsLoadResult(
        in span: TimeSpan
    ) async throws -> (readings: [SensorReading], isComplete: Bool) {
        try await readingsLoadResult(in: span)
    }

    func backupDateRanges() async throws -> [ClosedRange<Date>] {
        let generation = dataDeletionGeneration
        let ranges = try await store.dayRanges()
        try checkDataGeneration(generation)
        return ranges
    }

    func allReadings() async throws -> [SensorReading] {
        try await store.allReadingsLoadResult().readings
    }

    func allReadingsForMigration() async throws -> [SensorReading] {
        let result = try await store.allReadingsLoadResult()
        guard result.isComplete else { throw Error.conflictingReading }
        return result.readings
    }

    /// 새 저장소는 보존 기간 정리를 하지 않는다(백업 단계에서 다룬다).
    func compact(now: Date = .now) async throws {
        _ = now
    }

    func deleteAll(generation: UInt64? = nil) async throws {
        let lock = try await TaptionDataFileLock.acquire(url: writeLockURL)
        defer { lock.unlock() }
        dataDeletionGeneration = generation
            ?? TaptionDataDeletionFence.currentGeneration()
        // 데이터 삭제 요청은 한 파일 안의 모든 사본(위치·원시 봉투·워치·HealthKit·기록)을 지운다.
        // 삭제 세대(fence)가 바뀌므로 이전에 만든 저장소 객체의 저장은 거부된다.
        try await store.deleteAll()
        try? FileManager.default.removeItem(at: legacyFileURL)
    }

    private func checkDataGeneration(_ generation: UInt64) throws {
        guard generation == dataDeletionGeneration,
              TaptionDataDeletionFence.allows(generation: generation) else {
            throw CancellationError()
        }
    }

    private func withLock<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let lockURL = writeLockURL
        return try await TaptionRepositoryBackgroundExecution.run {
            let lock = try await TaptionDataFileLock.acquire(url: lockURL)
            defer { lock.unlock() }
            return try await operation()
        }
    }

    private static func rejectConflicts(within readings: [SensorReading]) throws {
        var byID: [UUID: SensorReading] = [:]
        for reading in readings {
            if let existing = byID[reading.id], existing != reading {
                throw Error.conflictingReading
            }
            byID[reading.id] = reading
        }
    }

    private func reportIncomplete(_ isComplete: Bool) {
        guard !isComplete else { return }
        TaptionPlanDiagnosticsLogger.shared.record(
            "sensor_store_unreadable_rows",
            level: .error
        )
    }
}

@MainActor
final class AppleSensorDataService {
    private static let persistenceBatchSize = 5
    private static let persistenceBatchDelay: Duration = .seconds(5)
    private static let logger = Logger(
        subsystem: "com.taption.plan",
        category: "SensorArchive"
    )
    private let collector: AppleSensorCollector
    private let archive: SensorReadingArchive
    private let history: AppleMotionHistoryService
    private let streamFactory:
        ((SensorCollectionConfiguration) -> AsyncStream<SensorReading>)?
    private let appendReadings: ([SensorReading]) async throws -> Void
    private let archivedReadingsLoader:
        (TimeSpan) async throws -> [SensorReading]
    private var collectionTask: Task<Void, Never>?
    private var activeConfiguration: SensorCollectionConfiguration?
    private var collectionGeneration = 0
    private var isCollectionStreamLive = false
    private var isDataDeletionActive = false
    private var isForegroundLiveLocationTrackingEnabled = false
    private var persistedReadingCount = 0
    private var lastPersistedReadingAt: Date?
    private var pendingReadings: [SensorReading] = []
    private var inFlightReadings: [SensorReading] = []
    private var inFlightGeneration: Int?
    private var pendingFlushTask: Task<Void, Never>?
    private var trailingFlushTask: Task<Void, Never>?
    private var lastFlushedCollectionGeneration: Int?

    private(set) var lastPersistenceErrorDescription: String?
    var onReadingsPersisted: (([SensorReading]) -> Void)?
    /// 저장 전에 전달되는 표시 전용 실시간 위치. 저장·분석 경로와 무관하다.
    var onLiveReadingPreview: ((SensorReading) -> Void)?
    var onPersistenceFailed: ((String) -> Void)?

    init(
        collector: AppleSensorCollector? = nil,
        archive: SensorReadingArchive,
        history: AppleMotionHistoryService = AppleMotionHistoryService(),
        streamFactory:
            ((SensorCollectionConfiguration) -> AsyncStream<SensorReading>)? = nil,
        appendReadings:
            (([SensorReading]) async throws -> Void)? = nil,
        archivedReadingsLoader:
            ((TimeSpan) async throws -> [SensorReading])? = nil
    ) {
        self.collector = collector ?? AppleSensorCollector()
        self.archive = archive
        self.history = history
        self.streamFactory = streamFactory
        self.appendReadings = appendReadings ?? { readings in
            try await archive.append(readings)
        }
        self.archivedReadingsLoader = archivedReadingsLoader ?? { span in
            try await archive.readings(in: span)
        }
    }

    static func applicationSupport() throws -> AppleSensorDataService {
        AppleSensorDataService(archive: try SensorReadingArchive.applicationSupport())
    }

    func hardwareAvailability() async -> SensorHardwareAvailability {
        await collector.hardwareAvailability()
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

    func requestImmediateSample() {
        collector.requestImmediateSample()
    }

    func setForegroundLiveLocationTrackingEnabled(_ enabled: Bool) {
        guard isForegroundLiveLocationTrackingEnabled != enabled else { return }
        isForegroundLiveLocationTrackingEnabled = enabled
        collector.setForegroundLiveLocationTrackingEnabled(enabled)
    }

    func startCollection(
        configuration: SensorCollectionConfiguration = .standard
    ) {
        guard !isDataDeletionActive else { return }
        let configuration = configuration.normalized
        // A finished stream leaves a completed task behind. Restart in that
        // case, otherwise recording never resumes after the reading stream
        // ends (for example when location permission was revoked).
        if collectionTask != nil,
           isCollectionStreamLive,
           activeConfiguration == configuration {
            return
        }
        let resumeForegroundLocationTracking =
            isForegroundLiveLocationTrackingEnabled
        let previousCollectionTask = collectionTask
        stopCollection()
        let previousFlushTask = trailingFlushTask
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
        setForegroundLiveLocationTrackingEnabled(
            resumeForegroundLocationTracking
        )
        let stream = streamFactory?(configuration)
            ?? collector.readings(configuration: configuration)
        collectionTask = Task { [weak self] in
            await previousCollectionTask?.value
            await previousFlushTask?.value
            for await reading in stream {
                guard !Task.isCancelled, let self,
                      self.collectionGeneration == generation else { break }
                guard await self.enqueue(reading, generation: generation) else {
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
        isForegroundLiveLocationTrackingEnabled = false
        collector.setForegroundLiveLocationTrackingEnabled(false)
        let generation = collectionGeneration
        let activeTask = collectionTask
        let activeFlushTask = pendingFlushTask
        pendingFlushTask?.cancel()
        pendingFlushTask = nil
        collectionGeneration += 1
        isCollectionStreamLive = false
        collectionTask?.cancel()
        collectionTask = nil
        activeConfiguration = nil
        collector.stop()
        guard (!pendingReadings.isEmpty || !inFlightReadings.isEmpty),
              !isDataDeletionActive else { return }
        let previous = trailingFlushTask
        trailingFlushTask = Task { [weak self] in
            await previous?.value
            await activeTask?.value
            await activeFlushTask?.value
            guard let self else { return }
            var saved = false
            for attempt in 0..<3 where !Task.isCancelled {
                saved = await self.flushPendingReadings(generation: generation)
                if saved || self.isDataDeletionActive { break }
                if attempt < 2 {
                    try? await Task.sleep(for: .seconds(1 << attempt))
                }
            }
        }
    }

    func stopCollectionAndWait() async {
        let pending = collectionTask
        let pendingFlush = pendingFlushTask
        stopCollection()
        let trailing = trailingFlushTask
        await pending?.value
        await pendingFlush?.value
        await trailing?.value
    }

    func prepareForDataDeletion() async {
        isDataDeletionActive = true
        await stopCollectionAndWait()
        pendingReadings.removeAll(keepingCapacity: true)
    }

    func finishDataDeletion() {
        isDataDeletionActive = false
    }

    private func enqueue(
        _ reading: SensorReading,
        generation: Int
    ) async -> Bool {
        if isForegroundLiveLocationTrackingEnabled, reading.point != nil {
            onLiveReadingPreview?(reading)
        }
        pendingReadings.append(reading)
        guard inFlightReadings.isEmpty else { return true }
        if lastFlushedCollectionGeneration != generation
            || pendingReadings.count >= Self.persistenceBatchSize
            || (isForegroundLiveLocationTrackingEnabled
                && reading.point != nil)
            || reading.trackingSessionEnded == true {
            return await flushPendingReadings(generation: generation)
        }
        schedulePendingFlush(generation: generation)
        return true
    }

    private func flushPendingReadings(generation: Int) async -> Bool {
        guard inFlightReadings.isEmpty else { return true }
        pendingFlushTask?.cancel()
        pendingFlushTask = nil
        let readings = pendingReadings
        guard !readings.isEmpty else { return true }
        inFlightReadings = readings
        inFlightGeneration = generation
        let saved = await persist(readings, generation: generation)
        if inFlightGeneration == generation {
            if saved {
                pendingReadings.removeFirst(
                    min(readings.count, pendingReadings.count)
                )
            }
            inFlightReadings.removeAll(keepingCapacity: true)
            inFlightGeneration = nil
        }
        if !saved,
           collectionGeneration == generation,
           !isDataDeletionActive {
            stopCollection()
        }
        guard saved,
              collectionGeneration == generation,
              !pendingReadings.isEmpty else { return saved }
        if pendingReadings.count >= Self.persistenceBatchSize
            || (isForegroundLiveLocationTrackingEnabled
                && pendingReadings.contains(where: { $0.point != nil }))
            || pendingReadings.contains(where: { $0.trackingSessionEnded == true }) {
            return await flushPendingReadings(generation: generation)
        }
        schedulePendingFlush(generation: generation)
        return true
    }

    private func schedulePendingFlush(generation: Int) {
        guard pendingFlushTask == nil,
              inFlightReadings.isEmpty,
              !pendingReadings.isEmpty else { return }
        pendingFlushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.persistenceBatchDelay)
            guard !Task.isCancelled,
                  let self,
                  self.collectionGeneration == generation else { return }
            self.pendingFlushTask = nil
            _ = await self.flushPendingReadings(generation: generation)
        }
    }

    private func persist(
        _ readings: [SensorReading],
        generation: Int
    ) async -> Bool {
        guard !readings.isEmpty else { return true }
        do {
            try await appendReadings(readings)
            guard !isDataDeletionActive else { return false }
            persistedReadingCount += readings.count
            if let latest = readings.map(\.timestamp).max() {
                lastPersistedReadingAt = max(
                    lastPersistedReadingAt ?? latest,
                    latest
                )
            }
            lastPersistenceErrorDescription = nil
            if collectionGeneration == generation {
                lastFlushedCollectionGeneration = generation
            }
            onReadingsPersisted?(readings)
            return true
        } catch {
            guard !isDataDeletionActive else { return false }
            let description = error.localizedDescription
            if lastPersistenceErrorDescription != description {
                TaptionPlanDiagnosticsLogger.shared.record(
                    "sensor_archive_append_failed",
                    level: .error,
                    fields: TaptionDiagnosticError.fields(for: error)
                )
            }
            lastPersistenceErrorDescription = description
            Self.logger.error(
                "Sensor archive append failed: \(error.localizedDescription, privacy: .public)"
            )
            if collectionGeneration == generation {
                onPersistenceFailed?(description)
            }
            return false
        }
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

    func backupDateRanges() async throws -> [ClosedRange<Date>] {
        try await archive.backupDateRanges()
    }

    func archivedReadings(in span: TimeSpan) async throws -> [SensorReading] {
        try await archivedReadingsLoader(span)
    }

    func archivedReadingsLoadResult(
        in span: TimeSpan
    ) async throws -> (readings: [SensorReading], isComplete: Bool) {
        try await archive.readingsLoadResult(in: span)
    }

    func archivedRouteReadings(
        in span: TimeSpan
    ) async throws -> [SensorReading] {
        try await archive.routeReadings(in: span)
    }

    func archivedRouteReadingsLoadResult(
        in span: TimeSpan
    ) async throws -> (readings: [SensorReading], isComplete: Bool) {
        try await archive.routeReadingsLoadResult(in: span)
    }

    func allArchivedRouteReadings() async throws -> [SensorReading] {
        try await archive.allReadingsForMigration()
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
        guard !isDataDeletionActive else { throw CancellationError() }
        guard let first = readings.min(by: { $0.timestamp < $1.timestamp }),
              let last = readings.max(by: { $0.timestamp < $1.timestamp }) else {
            return
        }
        let existingReadings = try await archive.routeReadings(
                in: TimeSpan(
                    start: first.timestamp.addingTimeInterval(-1),
                    end: last.timestamp.addingTimeInterval(1)
                )
            )
        let existingIDs = Set(existingReadings.map(\.id))
        guard !isDataDeletionActive else { throw CancellationError() }
        let ordered = readings.sorted { $0.timestamp < $1.timestamp }
        try await archive.append(ordered)
        guard !isDataDeletionActive else { throw CancellationError() }
        var notified = Set<UUID>()
        let inserted = ordered.filter {
            !existingIDs.contains($0.id)
                && notified.insert($0.id).inserted
        }
        if !inserted.isEmpty {
            onReadingsPersisted?(inserted)
        }
    }

    func validateExternalReadings(_ readings: [SensorReading]) async throws {
        guard !isDataDeletionActive else { throw CancellationError() }
        try await archive.validateAppend(readings)
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

    func deleteArchivedReadings(generation: UInt64? = nil) async throws {
        try await archive.deleteAll(generation: generation)
    }
}
