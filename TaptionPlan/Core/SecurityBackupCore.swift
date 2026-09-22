import CryptoKit
import CloudKit
import CommonCrypto
import Foundation
import LocalAuthentication
import Security
import TaptionPlanCore

/// The local gate is deliberately separate from normal app use.  A PIN is a
/// cloud-backup credential; it is not an app-login credential unless the user
/// explicitly enables an app lock.
struct PlanPINVerifier: Codable, Equatable, Sendable {
    static let currentVersion = 2
    static let legacyIterations = 120_000
    static let pbkdf2Iterations = 600_000

    let version: Int
    let salt: Data
    let digest: Data

    init(pin: String, random: (Int) throws -> Data = { count in
        var data = Data(repeating: 0, count: count)
        let status = data.withUnsafeMutableBytes { buffer -> Int32 in
            guard let baseAddress = buffer.baseAddress else {
                return errSecParam
            }
            return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
        }
        guard status == errSecSuccess else {
            throw PlanSecurityError.invalidCredential
        }
        return data
    }) throws {
        guard Self.isValid(pin) else { throw PlanSecurityError.invalidPIN }
        let salt = try random(16)
        guard salt.count == 16 else { throw PlanSecurityError.invalidCredential }
        guard let digest = Self.derive(
            pin: pin,
            salt: salt,
            version: Self.currentVersion
        ) else {
            throw PlanSecurityError.invalidCredential
        }
        self.version = Self.currentVersion
        self.salt = salt
        self.digest = digest
    }

    func matches(_ pin: String) -> Bool {
        guard Self.isValid(pin),
              let candidate = Self.derive(
                pin: pin,
                salt: salt,
                version: version
              ) else { return false }
        return Self.constantTimeEqual(digest, candidate)
    }

    /// PBKDF output is retained only as a verifier and key-encryption key; the
    /// four digit PIN itself never leaves the call stack.
    var keyMaterial: Data { digest }

    static func isValid(_ pin: String) -> Bool {
        pin.utf8.count == 4 && pin.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }

    private static func derive(
        pin: String,
        salt: Data,
        version: Int
    ) -> Data? {
        switch version {
        case 1:
            legacyDigest(pin: pin, salt: salt)
        case currentVersion:
            pbkdf2Digest(pin: pin, salt: salt)
        default:
            nil
        }
    }

    private static func legacyDigest(pin: String, salt: Data) -> Data {
        var value = Data(pin.utf8) + salt
        for _ in 0..<legacyIterations {
            value = Data(SHA256.hash(data: value))
        }
        return value
    }

    private static func pbkdf2Digest(pin: String, salt: Data) -> Data? {
        let outputCount = 32
        var output = Data(repeating: 0, count: outputCount)
        let passwordLength = pin.lengthOfBytes(using: .utf8)
        let status = output.withUnsafeMutableBytes { outputBytes in
            salt.withUnsafeBytes { saltBytes in
                pin.withCString { password in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        password,
                        passwordLength,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(pbkdf2Iterations),
                        outputBytes.bindMemory(to: UInt8.self).baseAddress,
                        outputCount
                    )
                }
            }
        }
        return status == kCCSuccess ? output : nil
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(lhs, rhs) { difference |= a ^ b }
        return difference == 0
    }
}

enum PlanSecurityError: Error, Equatable {
    case invalidPIN
    case invalidCredential
    case pinRequiredForCloudBackup
    case invalidArchive
    case archiveNotFound
    case accountUnavailable
    case accountMismatch
    case biometricUnavailable
    case biometricRejected
    case tooManyAttempts(retryAfter: TimeInterval)
}

extension PlanSecurityError: LocalizedError {
    var errorDescription: String? {
        localizedDescription()
    }

    func localizedDescription(
        preference: AppLanguagePreference = .current
    ) -> String {
        switch self {
        case .invalidPIN:
            AppLanguagePreference.text(
                korean: "4자리 숫자 비밀번호를 다시 확인해 주세요.",
                english: "Check your 4-digit PIN and try again.",
                preference: preference
            )
        case .invalidCredential:
            AppLanguagePreference.text(
                korean: "보안 자격 증명을 확인하지 못했습니다.",
                english: "The security credential could not be verified.",
                preference: preference
            )
        case .pinRequiredForCloudBackup:
            AppLanguagePreference.text(
                korean: "이 기능을 사용하려면 4자리 비밀번호를 먼저 등록해 주세요.",
                english: "Set a 4-digit PIN before using this feature.",
                preference: preference
            )
        case .invalidArchive:
            AppLanguagePreference.text(
                korean: "백업 파일의 암호화 또는 무결성을 확인하지 못했습니다.",
                english: "The backup encryption or integrity check failed.",
                preference: preference
            )
        case .archiveNotFound:
            AppLanguagePreference.text(
                korean: "불러올 iCloud 백업이 없습니다.",
                english: "No iCloud backup is available to restore.",
                preference: preference
            )
        case .accountUnavailable:
            AppLanguagePreference.text(
                korean: "iCloud 계정을 확인한 뒤 다시 시도해 주세요.",
                english: "Check your iCloud account and try again.",
                preference: preference
            )
        case .accountMismatch:
            AppLanguagePreference.text(
                korean: "이 백업을 만든 iCloud 계정과 다릅니다.",
                english: "This is not the iCloud account that created the backup.",
                preference: preference
            )
        case .biometricUnavailable:
            AppLanguagePreference.text(
                korean: "Face ID 또는 Touch ID를 사용할 수 없습니다.",
                english: "Face ID or Touch ID is unavailable.",
                preference: preference
            )
        case .biometricRejected:
            AppLanguagePreference.text(
                korean: "생체 인증을 완료하지 못했습니다.",
                english: "Biometric authentication was not completed.",
                preference: preference
            )
        case .tooManyAttempts:
            AppLanguagePreference.text(
                korean: "입력 횟수가 많습니다. 잠시 뒤 다시 시도해 주세요.",
                english: "Too many attempts. Try again shortly.",
                preference: preference
            )
        }
    }
}

protocol PlanCredentialStore: AnyObject {
    func read() throws -> Data?
    func write(_ data: Data) throws
}

final class KeychainPlanCredentialStore: PlanCredentialStore {
    private let service: String
    private let account: String

    init(service: String = "com.taption.plan.security", account: String = "pin-verifier-v1") {
        self.service = service
        self.account = account
    }

    func read() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw PlanSecurityError.invalidCredential }
        return result as? Data
    }

    func write(_ data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String:
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] =
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
                throw PlanSecurityError.invalidCredential
            }
        } else if status != errSecSuccess {
            throw PlanSecurityError.invalidCredential
        }
    }
}

final class InMemoryPlanCredentialStore: PlanCredentialStore {
    private var value: Data?
    init(value: Data? = nil) { self.value = value }
    func read() throws -> Data? { value }
    func write(_ data: Data) throws { value = data }
}

private struct PlanCredentialRecord: Codable {
    let verifier: PlanPINVerifier
    var failedAttempts: Int
    var blockedUntil: Date?
}

protocol PlanLocalBiometricAuthenticator: AnyObject, Sendable {
    func authenticate(reason: String) async -> Bool
}

final class SystemPlanLocalBiometricAuthenticator: PlanLocalBiometricAuthenticator, @unchecked Sendable {
    func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return false
        }
        return (try? await context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: reason
        )) ?? false
    }
}

final class MockPlanLocalBiometricAuthenticator: PlanLocalBiometricAuthenticator, @unchecked Sendable {
    var result: Bool
    init(result: Bool = true) { self.result = result }
    func authenticate(reason: String) async -> Bool { result }
}

struct PlanAppLockSettings: Codable, Equatable, Sendable {
    var lockOnLaunch: Bool
    var lockOnForeground: Bool
    var biometricUnlockEnabled: Bool
    /// A backup is opt-in. Turning it on requires the four-digit recovery
    /// code, but does not force an app lock for ordinary use.
    var cloudBackupEnabled: Bool
    var midnightBackupEnabled: Bool

    init(
        lockOnLaunch: Bool = false,
        lockOnForeground: Bool = false,
        biometricUnlockEnabled: Bool = false,
        cloudBackupEnabled: Bool = false,
        midnightBackupEnabled: Bool = false
    ) {
        self.lockOnLaunch = lockOnLaunch
        self.lockOnForeground = lockOnForeground
        self.biometricUnlockEnabled = biometricUnlockEnabled
        self.cloudBackupEnabled = cloudBackupEnabled
        self.midnightBackupEnabled = midnightBackupEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case lockOnLaunch
        case lockOnForeground
        case biometricUnlockEnabled
        case cloudBackupEnabled
        case midnightBackupEnabled
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            lockOnLaunch: try values.decodeIfPresent(
                Bool.self,
                forKey: .lockOnLaunch
            ) ?? false,
            lockOnForeground: try values.decodeIfPresent(
                Bool.self,
                forKey: .lockOnForeground
            ) ?? false,
            biometricUnlockEnabled: try values.decodeIfPresent(
                Bool.self,
                forKey: .biometricUnlockEnabled
            ) ?? false,
            cloudBackupEnabled: try values.decodeIfPresent(
                Bool.self,
                forKey: .cloudBackupEnabled
            ) ?? false,
            midnightBackupEnabled: try values.decodeIfPresent(
                Bool.self,
                forKey: .midnightBackupEnabled
            ) ?? false
        )
    }
}

enum PlanAppLockState: Equatable, Sendable {
    case unlocked
    case locked(reason: PlanAppLockReason)
}

enum PlanAppLockReason: String, Codable, Sendable {
    case launch
    case foreground
}

struct PlanSecurityStatus: Equatable, Sendable {
    let settings: PlanAppLockSettings
    let state: PlanAppLockState
    let hasPIN: Bool
    let failedAttempts: Int
    let retryAfter: Date?
    let latestSuccessfulBackupDate: Date?

    init(
        settings: PlanAppLockSettings,
        state: PlanAppLockState,
        hasPIN: Bool,
        failedAttempts: Int,
        retryAfter: Date?,
        latestSuccessfulBackupDate: Date? = nil
    ) {
        self.settings = settings
        self.state = state
        self.hasPIN = hasPIN
        self.failedAttempts = failedAttempts
        self.retryAfter = retryAfter
        self.latestSuccessfulBackupDate = latestSuccessfulBackupDate
    }
}

struct PlanCloudBackupPath: Equatable, Sendable {
    let monthKey: String
    /// The user-visible location in Files. Each month is one encrypted file,
    /// rather than a folder containing an unprotected JSON payload.
    var components: [String] {
        ["iCloud Drive", "Taption Plan", "\(monthKey).taptionbackup"]
    }
    var relativePath: String { components.joined(separator: "/") }
    var storageComponents: [String] {
        ["Taption Plan", "\(monthKey).taptionbackup"]
    }
}

enum PlanCloudSensorReadingPolicy {
    static func locationOnly(_ reading: SensorReading) -> SensorReading? {
        guard reading.point != nil, reading.sourceDevice != .appleWatch else {
            return nil
        }
        return SensorReading(
            id: reading.id,
            timestamp: reading.timestamp,
            point: reading.point,
            locationFixQuality: reading.locationFixQuality,
            speedMetersPerSecond: reading.speedMetersPerSecond,
            speedAccuracyMetersPerSecond: reading.speedAccuracyMetersPerSecond,
            courseDegrees: reading.courseDegrees,
            courseAccuracyDegrees: reading.courseAccuracyDegrees,
            gpsAvailable: reading.gpsAvailable,
            nearbyStation: reading.nearbyStation,
            nearbyStationName: reading.nearbyStationName,
            matchesRailRoute: reading.matchesRailRoute,
            matchesPublicTransitRoute: reading.matchesPublicTransitRoute,
            frequentStops: reading.frequentStops,
            rideHailingHint: reading.rideHailingHint,
            nearAirport: reading.nearAirport,
            nearPort: reading.nearPort,
            onWater: reading.onWater,
            trackingSessionID: reading.trackingSessionID,
            sourceDevice: reading.sourceDevice,
            sequence: reading.sequence,
            trackingSessionEnded: reading.trackingSessionEnded
        )
    }
}

struct PlanBackupRoutePoint: Codable, Equatable, Sendable {
    let sensorReading: SensorReading

    init?(_ reading: SensorReading) {
        guard reading.point != nil else { return nil }
        sensorReading = reading
    }

    var id: UUID { sensorReading.id }
}

struct PlanCloudBackupPayload: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let snapshot: TaptionDataSnapshot
    let routePoints: [PlanBackupRoutePoint]
    let portableContent: TaptionPlanStorageEnvelopeV2?
    let appLog: String?

    init(
        snapshot: TaptionDataSnapshot,
        routePoints: [PlanBackupRoutePoint] = [],
        appLog: String? = nil
    ) {
        version = Self.currentVersion
        let safeSnapshot = PlanCloudSnapshotRecoveryPolicy.iCloudSafe(snapshot)
        self.snapshot = safeSnapshot
        self.routePoints = routePoints.compactMap {
            PlanCloudSensorReadingPolicy.locationOnly($0.sensorReading)
                .flatMap(PlanBackupRoutePoint.init)
        }
        portableContent = try? Self.makePortableContent(from: safeSnapshot)
        self.appLog = appLog.map {
            TaptionPlanDiagnosticsLogPolicy.redactingPersonalHealthFields(
                in: $0
            )
        }.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func makePortableContent(
        from snapshot: TaptionDataSnapshot
    ) throws -> TaptionPlanStorageEnvelopeV2 {
        var mediaByID: [String: TaptionPlanMediaReference] = [:]
        for photo in snapshot.photos {
            mediaByID[photo.id] = TaptionPlanMediaReference(
                id: photo.id,
                localIdentifier: photo.id,
                capturedAt: photo.capturedAt
            )
        }
        var links: [TaptionPlanContentLink] = []
        let memos = try snapshot.memos.map { memo in
            var linkedMediaIDs = Set<String>()
            let mediaIDs = memo.attachments.compactMap { attachment -> String? in
                guard attachment.kind == .photo else { return nil }
                let id = attachment.localIdentifier
                guard linkedMediaIDs.insert(id).inserted else { return nil }
                if mediaByID[id] == nil {
                    mediaByID[id] = TaptionPlanMediaReference(
                        id: id,
                        localIdentifier: id,
                        capturedAt: attachment.createdAt
                    )
                }
                links.append(
                    TaptionPlanContentLink(
                        from: .memo(memo.id),
                        to: .media(id)
                    )
                )
                return id
            }
            return try TaptionPlanMemoRecord(
                id: memo.id,
                occurredAt: memo.occurredAt,
                text: memo.text,
                mediaReferenceIDs: mediaIDs,
                createdAt: memo.createdAt,
                updatedAt: memo.updatedAt
            )
        }
        let sources = Dictionary(
            snapshot.calendarEvents.map {
                ($0.calendarID, ($0.sourceTitle, $0.sourceIdentifier))
            },
            uniquingKeysWith: { first, _ in first }
        )
        let calendars = snapshot.settings.selectedCalendarIDs.compactMap {
            calendarID -> TaptionPlanExternalCalendarIdentity? in
            guard let source = sources[calendarID],
                  let provider = calendarProvider(
                    title: source.0,
                    identifier: source.1
                  ) else { return nil }
            return TaptionPlanExternalCalendarIdentity(
                account: TaptionPlanExternalCalendarAccountIdentity(
                    provider: provider,
                    accountID: source.1 ?? source.0 ?? calendarID
                ),
                calendarID: calendarID
            )
        }
        let providers = Set(calendars.map(\.account.provider))
        return try TaptionPlanStorageEnvelopeV2(
            updatedAt: snapshot.updatedAt,
            userContent: TaptionPlanUserContent(memos: memos),
            externalCalendarPreferences: TaptionPlanExternalCalendarPreferences(
                preferredProvider: providers.count == 1
                    ? providers.first
                    : nil,
                selectedCalendars: calendars
            ),
            mediaReferences: mediaByID.values.sorted { $0.id < $1.id },
            contentLinks: links
        )
    }

    private static func calendarProvider(
        title: String?,
        identifier: String?
    ) -> TaptionPlanExternalCalendarProvider? {
        let source = [title, identifier]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        if source.contains("google") || source.contains("gmail") {
            return .google
        }
        if source.contains("naver") || source.contains("네이버") {
            return .naver
        }
        if source.contains("icloud") || source.contains("apple") {
            return .apple
        }
        return nil
    }
}

enum PlanCloudRawSensorExportPolicy {
    static func allows(_ envelope: RawDeviceDataEnvelope) -> Bool {
        switch envelope.source {
        case .gps:
            return envelope.kind == "weather-context"
                || envelope.kind == "weather-forecast-hourly"
        case .iPhoneSensor, .iPhoneMotion, .iPhonePedometer, .healthKit,
             .appleWatch:
            return false
        }
    }
}

enum PlanCloudRawSensorEnvelopeReducer {
    private struct StreamKey: Hashable {
        let isForecast: Bool
        let placeID: UUID?
        let latitude: Int?
        let longitude: Int?

        init(_ context: WeatherContext) {
            isForecast = context.isForecast == true
            placeID = context.placeID
            guard context.placeID == nil,
                  context.isForecast != true,
                  let point = context.point else {
                latitude = nil
                longitude = nil
                return
            }
            latitude = Int((point.latitude * 1_000).rounded())
            longitude = Int((point.longitude * 1_000).rounded())
        }
    }

    private struct DisplayKey: Hashable {
        let stream: StreamKey
        let observedAt: Date
        let symbolName: String
        let temperature: Int
        let airGrade: AirQualityGrade?

        init?(_ context: WeatherContext) {
            let roundedTemperature = context.temperatureCelsius.rounded()
            guard roundedTemperature.isFinite,
                  roundedTemperature >= Double(Int.min),
                  roundedTemperature < Double(Int.max) else { return nil }
            if context.placeID == nil, let point = context.point {
                let coordinateLimit = Double(Int.max) / 1_000
                guard point.latitude.isFinite,
                      point.longitude.isFinite,
                      abs(point.latitude) < coordinateLimit,
                      abs(point.longitude) < coordinateLimit else {
                    return nil
                }
            }
            stream = StreamKey(context)
            observedAt = context.observedAt
            symbolName = context.symbolName
            temperature = Int(roundedTemperature)
            airGrade = context.airQuality?.overallGrade
        }
    }

    private struct ObservationKey: Hashable {
        let stream: StreamKey
        let observedAt: Date
    }

    private struct Candidate {
        let envelope: RawDeviceDataEnvelope
        let context: WeatherContext
        let displayKey: DisplayKey
    }

    static func compact(_ envelopes: [RawDeviceDataEnvelope])
        -> [RawDeviceDataEnvelope] {
        let candidates = envelopes.filter {
            $0.source == .gps
                && ($0.kind == "weather-context"
                    || $0.kind == "weather-forecast-hourly")
        }
        guard !candidates.isEmpty else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        var weatherIDs = Set<UUID>()
        var latestByObservation = [ObservationKey: Candidate]()
        for envelope in candidates {
            weatherIDs.insert(envelope.id)
            guard let data = envelope.payloadJSON.data(using: .utf8),
                  let context = try? decoder.decode(
                      WeatherContext.self,
                      from: data
                  ) else {
                continue
            }
            guard let displayKey = DisplayKey(context) else {
                continue
            }
            let candidate = Candidate(
                envelope: envelope,
                context: context,
                displayKey: displayKey
            )
            let observationKey = ObservationKey(
                stream: displayKey.stream,
                observedAt: displayKey.observedAt
            )
            if let existing = latestByObservation[observationKey],
               !isPreferred(candidate, over: existing) { continue }
            latestByObservation[observationKey] = candidate
        }

        // Equivalent to WeatherTimelineEngine.changedRawContexts, but keeps
        // cloud export O(n log n) instead of its quadratic scan on large raw
        // months.
        var lastDisplayByStream: [StreamKey: DisplayKey] = [:]
        let compactedWeather = latestByObservation.values
            .sorted(by: candidateOrder)
            .compactMap { candidate -> RawDeviceDataEnvelope? in
                let stream = candidate.displayKey.stream
                if let previous = lastDisplayByStream[stream],
                   sameDisplay(previous, candidate.displayKey) {
                    return nil
                }
                lastDisplayByStream[stream] = candidate.displayKey
                return candidate.envelope
            }
        return (envelopes.filter { !weatherIDs.contains($0.id) }
            + compactedWeather).sorted(by: envelopeOrder)
    }

    private static func sameDisplay(
        _ lhs: DisplayKey,
        _ rhs: DisplayKey
    ) -> Bool {
        lhs.symbolName == rhs.symbolName
            && lhs.temperature == rhs.temperature
            && lhs.airGrade == rhs.airGrade
    }

    private static func isPreferred(
        _ candidate: Candidate,
        over existing: Candidate
    ) -> Bool {
        let candidateFetchedAt = candidate.context.fetchedAt
            ?? candidate.envelope.capturedAt
        let existingFetchedAt = existing.context.fetchedAt
            ?? existing.envelope.capturedAt
        if candidateFetchedAt != existingFetchedAt {
            return candidateFetchedAt > existingFetchedAt
        }
        if candidate.envelope.capturedAt != existing.envelope.capturedAt {
            return candidate.envelope.capturedAt > existing.envelope.capturedAt
        }
        return candidate.envelope.id.uuidString > existing.envelope.id.uuidString
    }

    private static func candidateOrder(
        _ lhs: Candidate,
        _ rhs: Candidate
    ) -> Bool {
        if lhs.context.observedAt != rhs.context.observedAt {
            return lhs.context.observedAt < rhs.context.observedAt
        }
        return lhs.context.id.uuidString < rhs.context.id.uuidString
    }

    private static func envelopeOrder(
        _ lhs: RawDeviceDataEnvelope,
        _ rhs: RawDeviceDataEnvelope
    ) -> Bool {
        if lhs.capturedAt != rhs.capturedAt {
            return lhs.capturedAt < rhs.capturedAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

struct PlanCloudRawSensorBackupPath: Equatable, Sendable {
    let monthKey: String
    let generationID: UUID?

    init(monthKey: String, generationID: UUID? = nil) {
        self.monthKey = monthKey
        self.generationID = generationID
    }

    private var fileName: String {
        let generation = generationID.map { ".\($0.uuidString)" } ?? ""
        return "\(monthKey)\(generation).rawsensorbackup"
    }

    var components: [String] {
        [
            "iCloud Drive",
            "Taption Plan",
            "Raw Sensors",
            fileName,
        ]
    }

    var relativePath: String { components.joined(separator: "/") }

    var storageComponents: [String] {
        [
            "Taption Plan",
            "Raw Sensors",
            fileName,
        ]
    }
}

struct PlanCloudRawSensorPayload: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let monthKey: String
    let createdAt: Date
    let sensorReadings: [SensorReading]
    let envelopes: [RawDeviceDataEnvelope]
    let watchAccelerationChunks: [TaptionWatchAccelerationChunk]?

    init(
        monthKey: String,
        sensorReadings: [SensorReading] = [],
        envelopes: [RawDeviceDataEnvelope] = [],
        watchAccelerationChunks: [TaptionWatchAccelerationChunk] = [],
        createdAt: Date = .now
    ) {
        version = Self.currentVersion
        self.monthKey = monthKey
        self.createdAt = createdAt
        self.sensorReadings = sensorReadings.compactMap(
            PlanCloudSensorReadingPolicy.locationOnly
        ).sorted {
            if $0.timestamp != $1.timestamp {
                return $0.timestamp < $1.timestamp
            }
            return $0.id.uuidString < $1.id.uuidString
        }
        self.envelopes = PlanCloudRawSensorEnvelopeReducer.compact(
            envelopes.filter(PlanCloudRawSensorExportPolicy.allows)
        )
        self.watchAccelerationChunks = watchAccelerationChunks.sorted {
            if $0.startedAt != $1.startedAt {
                return $0.startedAt < $1.startedAt
            }
            return $0.sequence < $1.sequence
        }
    }

    var isEmpty: Bool {
        sensorReadings.isEmpty
            && envelopes.isEmpty
            && (watchAccelerationChunks?.isEmpty ?? true)
    }
}

enum PlanBackupRoutePointReducer {
    static let minimumInterval: TimeInterval = 10
    static let maximumCount = 60_000
    /// A route point is a display projection of the raw archive.  Keep the
    /// raw `SensorReading` untouched, but do not let a bad fix become a
    /// backup route anchor.
    static let maximumRouteSpeedMetersPerSecond: Double = 120
    static let maximumRouteAccuracyMeters: Double = 150

    static func backupSpan(
        containing date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> TimeSpan {
        let start = calendar.dateInterval(of: .month, for: date)?.start
            ?? date.addingTimeInterval(-31 * 86_400)
        return TimeSpan(
            start: start,
            end: date.addingTimeInterval(5 * 60)
        )
    }

    static func reduce(_ readings: [SensorReading]) -> [PlanBackupRoutePoint] {
        var candidates = filteredReadings(readings)
            .sorted { $0.timestamp < $1.timestamp }
        if let terminal = readings
            .filter(isEligibleEndpoint)
            .max(by: readingOrder),
           candidates.last?.id != terminal.id,
           let previous = candidates.last,
           let previousPoint = previous.point,
           let terminalPoint = terminal.point,
           isPlausible(
               from: previous,
               to: terminal,
               distance: distanceMeters(previousPoint, terminalPoint)
           ) {
            candidates.append(terminal)
        }
        guard !candidates.isEmpty else { return [] }

        var retained: [SensorReading] = []
        retained.reserveCapacity(min(candidates.count, maximumCount))
        for reading in candidates {
            guard let previous = retained.last else {
                retained.append(reading)
                continue
            }
            guard let previousPoint = previous.point,
                  let point = reading.point else { continue }
            let elapsed = reading.timestamp.timeIntervalSince(previous.timestamp)
            let moved = distanceMeters(previousPoint, point) >= 25
            if elapsed >= minimumInterval || moved
                || reading.behavior != previous.behavior {
                retained.append(reading)
            }
        }
        if let last = candidates.last,
           retained.last?.id != last.id,
           let previous = retained.last,
           let previousPoint = previous.point,
           let lastPoint = last.point,
           isPlausible(
               from: previous,
               to: last,
               distance: distanceMeters(previousPoint, lastPoint)
           ) {
            retained.append(last)
        }
        if retained.count > maximumCount {
            let stride = Double(retained.count - 1) / Double(maximumCount - 1)
            retained = (0..<maximumCount).map {
                retained[Int((Double($0) * stride).rounded())]
            }
        }
        return retained.compactMap(PlanBackupRoutePoint.init)
    }

    /// Filters only the route projection.  Sensor readings are an audit
    /// record and must remain available for later reclassification.
    static func filteredReadings(_ readings: [SensorReading]) -> [SensorReading] {
        TaptionRouteEngineAdapter.filteredReadings(
            from: readings,
            includeLowConfidenceBoundaries: false
        )
    }

    private static func isPlausible(
        from: SensorReading,
        to: SensorReading,
        distance: Double
    ) -> Bool {
        let elapsed = to.timestamp.timeIntervalSince(from.timestamp)
        guard elapsed > 0, elapsed.isFinite, distance.isFinite else {
            return false
        }
        let modeLimit: Double = {
            switch to.motion == .unknown ? from.motion : to.motion {
            case .walking: 4.5
            case .running: 9
            case .cycling: 25
            case .automotive: 90
            case .stationary: 1
            case .unknown: 55
            }
        }()
        let reportedSpeed = [from, to].compactMap { reading -> Double? in
            guard let speed = reading.speedMetersPerSecond,
                  speed.isFinite, speed >= 0 else { return nil }
            let accuracy = reading.speedAccuracyMetersPerSecond ?? 0
            guard accuracy.isFinite, accuracy >= 0 else { return nil }
            return speed + 3 * accuracy
        }.max() ?? 0
        let maximumSpeed = min(
            maximumRouteSpeedMetersPerSecond,
            max(modeLimit, reportedSpeed)
        )
        return distance <= maximumSpeed * elapsed
            + from.point!.horizontalAccuracy
            + to.point!.horizontalAccuracy
    }

    private static func isEligibleEndpoint(_ reading: SensorReading) -> Bool {
        guard reading.gpsAvailable,
              reading.locationFixQuality != .approximate,
              let point = reading.point,
              point.latitude.isFinite,
              point.longitude.isFinite,
              (-90...90).contains(point.latitude),
              (-180...180).contains(point.longitude),
              point.horizontalAccuracy.isFinite,
              (0...maximumRouteAccuracyMeters)
                .contains(point.horizontalAccuracy) else {
            return false
        }
        return true
    }

    private static func readingOrder(
        _ lhs: SensorReading,
        _ rhs: SensorReading
    ) -> Bool {
        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp < rhs.timestamp
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    static func merging(
        existing: [PlanBackupRoutePoint],
        incoming: [PlanBackupRoutePoint]
    ) -> [PlanBackupRoutePoint] {
        var readingsByID: [UUID: SensorReading] = [:]
        for point in existing {
            readingsByID[point.id] = point.sensorReading
        }
        for point in incoming {
            readingsByID[point.id] = point.sensorReading
        }
        return reduce(Array(readingsByID.values))
    }

    static func restoring(
        _ archives: [[PlanBackupRoutePoint]]
    ) -> [PlanBackupRoutePoint] {
        var pointsByID: [UUID: PlanBackupRoutePoint] = [:]
        for points in archives {
            for point in points {
                pointsByID[point.id] = point
            }
        }
        return reduce(pointsByID.values.map(\.sensorReading))
    }
}

enum PlanArchiveMetadata {
    private struct Envelope: Encodable {
        let version: Int
        let monthKey: String
        let accountIdentifier: String
        let createdAt: Date
        let generationID: UUID?
        let hasRawSensorArchive: Bool?
    }

    static func authenticatedData(
        version: Int,
        monthKey: String,
        accountIdentifier: String,
        createdAt: Date,
        generationID: UUID?,
        hasRawSensorArchive: Bool? = nil
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(
            Envelope(
                version: version,
                monthKey: monthKey,
                accountIdentifier: accountIdentifier,
                createdAt: createdAt,
                generationID: generationID,
                hasRawSensorArchive: hasRawSensorArchive
            )
        )
    }
}

struct PlanMonthlyArchive: Codable, Equatable, Sendable {
    static let currentVersion = 3
    let version: Int
    let monthKey: String
    let accountIdentifier: String
    let createdAt: Date
    let encryptedPayload: Data
    let wrappedPayloadKey: Data
    let accountWrappedPayloadKey: Data
    let payloadDigest: Data
    let generationID: UUID?
    let hasRawSensorArchive: Bool?

    init(
        monthKey: String,
        accountIdentifier: String,
        encryptedPayload: Data,
        wrappedPayloadKey: Data,
        accountWrappedPayloadKey: Data,
        createdAt: Date = .now,
        generationID: UUID? = nil,
        hasRawSensorArchive: Bool? = nil
    ) {
        self.version = Self.currentVersion
        self.monthKey = monthKey
        self.accountIdentifier = accountIdentifier
        self.createdAt = createdAt
        self.encryptedPayload = encryptedPayload
        self.wrappedPayloadKey = wrappedPayloadKey
        self.accountWrappedPayloadKey = accountWrappedPayloadKey
        self.payloadDigest = Data(SHA256.hash(data: encryptedPayload))
        self.generationID = generationID
        self.hasRawSensorArchive = hasRawSensorArchive
    }

    func decodedPayload(
        pinKeyData: Data? = nil,
        accountKeyData: Data? = nil
    ) throws -> PlanCloudBackupPayload {
        guard (1...Self.currentVersion).contains(version),
              payloadDigest == Data(SHA256.hash(data: encryptedPayload)) else {
            throw PlanSecurityError.invalidArchive
        }
        var archiveKeys: [Data] = []
        if let pinKeyData,
           let key = try? Self.openKey(wrappedPayloadKey, with: pinKeyData) {
            archiveKeys.append(key)
        }
        if let accountKeyData,
           let key = try? Self.openKey(
               accountWrappedPayloadKey,
               with: accountKeyData
           ), !archiveKeys.contains(key) {
            archiveKeys.append(key)
        }
        for archiveKey in archiveKeys where archiveKey.count == 32 {
            guard let payload = try? decodePayload(archiveKey: archiveKey) else {
                continue
            }
            return payload
        }
        throw PlanSecurityError.invalidArchive
    }

    private func decodePayload(
        archiveKey: Data
    ) throws -> PlanCloudBackupPayload {
        let sealed = try AES.GCM.SealedBox(combined: encryptedPayload)
        let compressed: Data
        if version == 1 {
            // Version 1 authenticated only the GCM payload and its digest.
            compressed = try AES.GCM.open(
                sealed,
                using: SymmetricKey(data: archiveKey)
            )
        } else {
            let authenticatedData = try PlanArchiveMetadata.authenticatedData(
                version: version,
                monthKey: monthKey,
                accountIdentifier: accountIdentifier,
                createdAt: createdAt,
                generationID: generationID,
                hasRawSensorArchive: version >= 3 ? hasRawSensorArchive : nil
            )
            compressed = try AES.GCM.open(
                sealed,
                using: SymmetricKey(data: archiveKey),
                authenticating: authenticatedData
            )
        }
        guard compressed.count <= TaptionSnapshotCompression.maximumRawSensorUncompressedSize else {
            throw TaptionSnapshotCompressionError.uncompressedSizeExceedsLimit(
                actual: UInt64(compressed.count),
                maximum: TaptionSnapshotCompression.maximumRawSensorUncompressedSize
            )
        }
        let data = try TaptionSnapshotCompression.decodeChecked(
            compressed,
            maximumSize: TaptionSnapshotCompression.maximumRawSensorUncompressedSize
        )
        if let payload = try? JSONDecoder.taptionPlan.decode(
            PlanCloudBackupPayload.self,
            from: data
        ), payload.version == PlanCloudBackupPayload.currentVersion {
            return payload
        }
        return PlanCloudBackupPayload(
            snapshot: try JSONDecoder.taptionPlan.decode(
                TaptionDataSnapshot.self,
                from: data
            )
        )
    }

    func decodedSnapshot(
        pinKeyData: Data? = nil,
        accountKeyData: Data? = nil
    ) throws -> TaptionDataSnapshot {
        try decodedPayload(
            pinKeyData: pinKeyData,
            accountKeyData: accountKeyData
        ).snapshot
    }

    private static func openKey(_ wrapped: Data, with keyData: Data) throws -> Data {
        guard keyData.count == 32 else { throw PlanSecurityError.invalidArchive }
        let sealed = try AES.GCM.SealedBox(combined: wrapped)
        return try AES.GCM.open(sealed, using: SymmetricKey(data: keyData))
    }
}

struct PlanRawSensorMonthlyArchive: Codable, Equatable, Sendable {
    static let currentVersion = 2

    let version: Int
    let monthKey: String
    let accountIdentifier: String
    let createdAt: Date
    let encryptedPayload: Data
    let wrappedPayloadKey: Data
    let accountWrappedPayloadKey: Data
    let payloadDigest: Data
    let generationID: UUID?

    init(
        monthKey: String,
        accountIdentifier: String,
        encryptedPayload: Data,
        wrappedPayloadKey: Data,
        accountWrappedPayloadKey: Data,
        createdAt: Date = .now,
        generationID: UUID? = nil
    ) {
        version = Self.currentVersion
        self.monthKey = monthKey
        self.accountIdentifier = accountIdentifier
        self.createdAt = createdAt
        self.encryptedPayload = encryptedPayload
        self.wrappedPayloadKey = wrappedPayloadKey
        self.accountWrappedPayloadKey = accountWrappedPayloadKey
        payloadDigest = Data(SHA256.hash(data: encryptedPayload))
        self.generationID = generationID
    }

    init(
        decodedVersion version: Int,
        monthKey: String,
        accountIdentifier: String,
        createdAt: Date,
        encryptedPayload: Data,
        wrappedPayloadKey: Data,
        accountWrappedPayloadKey: Data,
        payloadDigest: Data,
        generationID: UUID?
    ) {
        self.version = version
        self.monthKey = monthKey
        self.accountIdentifier = accountIdentifier
        self.createdAt = createdAt
        self.encryptedPayload = encryptedPayload
        self.wrappedPayloadKey = wrappedPayloadKey
        self.accountWrappedPayloadKey = accountWrappedPayloadKey
        self.payloadDigest = payloadDigest
        self.generationID = generationID
    }

    static func decodeForRestore(
        _ data: Data,
        cancellationCheck: @escaping () throws -> Void
    ) throws -> PlanRawSensorMonthlyArchive {
        var decoder = PlanRawSensorMonthlyArchiveRestoreDecoder(
            data: data,
            cancellationCheck: cancellationCheck
        )
        return try decoder.decode()
    }

    func decodedPayload(
        pinKeyData: Data? = nil,
        accountKeyData: Data? = nil,
        cancellationCheck: () throws -> Void = {}
    ) throws -> PlanCloudRawSensorPayload {
        try cancellationCheck()
        guard version == 1 || version == Self.currentVersion,
              payloadDigest == Data(SHA256.hash(data: encryptedPayload)) else {
            throw PlanSecurityError.invalidArchive
        }
        try cancellationCheck()
        var archiveKeys: [Data] = []
        if let pinKeyData {
            do {
                let key = try Self.openKey(wrappedPayloadKey, with: pinKeyData)
                try cancellationCheck()
                archiveKeys.append(key)
            } catch is CancellationError {
                throw CancellationError()
            } catch { }
        }
        if let accountKeyData {
            do {
                let key = try Self.openKey(
                    accountWrappedPayloadKey,
                    with: accountKeyData
                )
                try cancellationCheck()
                if !archiveKeys.contains(key) {
                    archiveKeys.append(key)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch { }
        }
        for archiveKey in archiveKeys where archiveKey.count == 32 {
            do {
                return try decodePayload(
                    archiveKey: archiveKey,
                    cancellationCheck: cancellationCheck
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                TaptionPlanDiagnosticsLogger.shared.record(
                    "raw_sensor_archive_decode_failed",
                    level: .error,
                    fields: [
                        "month_key": monthKey,
                        "error_type": String(reflecting: type(of: error)),
                        "error_value": String(describing: error),
                    ]
                )
            }
        }
        throw PlanSecurityError.invalidArchive
    }

    private func decodePayload(
        archiveKey: Data,
        cancellationCheck: () throws -> Void
    ) throws -> PlanCloudRawSensorPayload {
        try cancellationCheck()
        let sealed = try AES.GCM.SealedBox(combined: encryptedPayload)
        let compressed: Data
        if version == 1 {
            // Version 1 authenticated only the GCM payload and its digest.
            compressed = try AES.GCM.open(
                sealed,
                using: SymmetricKey(data: archiveKey)
            )
        } else {
            let authenticatedData = try PlanArchiveMetadata.authenticatedData(
                version: version,
                monthKey: monthKey,
                accountIdentifier: accountIdentifier,
                createdAt: createdAt,
                generationID: generationID
            )
            compressed = try AES.GCM.open(
                sealed,
                using: SymmetricKey(data: archiveKey),
                authenticating: authenticatedData
            )
        }
        try cancellationCheck()
        guard compressed.count
            <= TaptionSnapshotCompression.maximumRawSensorUncompressedSize
        else {
            throw TaptionSnapshotCompressionError.uncompressedSizeExceedsLimit(
                actual: UInt64(compressed.count),
                maximum: TaptionSnapshotCompression.maximumRawSensorUncompressedSize
            )
        }
        let data = try TaptionSnapshotCompression.decodeChecked(
            compressed,
            maximumSize: TaptionSnapshotCompression.maximumRawSensorUncompressedSize
        )
        try cancellationCheck()
        let payload = try JSONDecoder.taptionPlan.decode(
            PlanCloudRawSensorPayload.self,
            from: data
        )
        try cancellationCheck()
        guard payload.version == PlanCloudRawSensorPayload.currentVersion else {
            throw PlanSecurityError.invalidArchive
        }
        guard payload.monthKey == monthKey else {
            throw PlanSecurityError.invalidArchive
        }
        return payload
    }

    private static func openKey(_ wrapped: Data, with keyData: Data) throws -> Data {
        guard keyData.count == 32 else { throw PlanSecurityError.invalidArchive }
        let sealed = try AES.GCM.SealedBox(combined: wrapped)
        return try AES.GCM.open(sealed, using: SymmetricKey(data: keyData))
    }
}

private struct PlanRawSensorMonthlyArchiveRestoreDecoder {
    private let data: Data
    private let cancellationCheck: () throws -> Void
    private var index = 0
    private static let cancellationStride = 65_536
    private static let cancellationValueStride = 4_096
    private static let base64ChunkSize = 1_048_576
    private var scannedValueCount = 0

    init(
        data: Data,
        cancellationCheck: @escaping () throws -> Void
    ) {
        self.data = data
        self.cancellationCheck = cancellationCheck
    }

    mutating func decode() throws -> PlanRawSensorMonthlyArchive {
        try cancellationCheck()
        try skipWhitespace()
        try expect(0x7B)

        var version: Int?
        var monthKey: String?
        var accountIdentifier: String?
        var createdAt: Date?
        var encryptedPayload: Data?
        var wrappedPayloadKey: Data?
        var accountWrappedPayloadKey: Data?
        var payloadDigest: Data?
        var generationID: UUID?

        try skipWhitespace()
        if !consume(0x7D) {
            while true {
                let keyRange = try scanString()
                let key = try decode(String.self, from: keyRange)
                try skipWhitespace()
                try expect(0x3A)
                try skipWhitespace()

                if key == "encryptedPayload" {
                    encryptedPayload = try decodeBase64String()
                } else {
                    let valueRange = try scanValue(depth: 0)
                    switch key {
                    case "version": version = try decode(Int.self, from: valueRange)
                    case "monthKey": monthKey = try decode(String.self, from: valueRange)
                    case "accountIdentifier":
                        accountIdentifier = try decode(String.self, from: valueRange)
                    case "createdAt": createdAt = try decode(Date.self, from: valueRange)
                    case "wrappedPayloadKey":
                        wrappedPayloadKey = try decode(Data.self, from: valueRange)
                    case "accountWrappedPayloadKey":
                        accountWrappedPayloadKey = try decode(Data.self, from: valueRange)
                    case "payloadDigest":
                        payloadDigest = try decode(Data.self, from: valueRange)
                    case "generationID":
                        generationID = isNull(valueRange)
                            ? nil
                            : try decode(UUID.self, from: valueRange)
                    default:
                        break
                    }
                }
                try cancellationCheck()
                try skipWhitespace()
                if consume(0x2C) {
                    try skipWhitespace()
                    continue
                }
                try expect(0x7D)
                break
            }
        }
        try skipWhitespace()
        guard index == data.count,
              let version,
              let monthKey,
              let accountIdentifier,
              let createdAt,
              let encryptedPayload,
              let wrappedPayloadKey,
              let accountWrappedPayloadKey,
              let payloadDigest else {
            throw invalidJSON
        }
        return PlanRawSensorMonthlyArchive(
            decodedVersion: version,
            monthKey: monthKey,
            accountIdentifier: accountIdentifier,
            createdAt: createdAt,
            encryptedPayload: encryptedPayload,
            wrappedPayloadKey: wrappedPayloadKey,
            accountWrappedPayloadKey: accountWrappedPayloadKey,
            payloadDigest: payloadDigest,
            generationID: generationID
        )
    }

    private mutating func decodeBase64String() throws -> Data {
        try expect(0x22)
        var result = Data()
        var chunk: [UInt8] = []
        chunk.reserveCapacity(Self.base64ChunkSize)
        var scannedCount = 0
        var paddingCount = 0
        while index < data.count {
            if scannedCount.isMultiple(of: Self.cancellationStride) {
                try cancellationCheck()
            }
            let byte = data[index]
            if byte == 0x22 {
                index += 1
                if !chunk.isEmpty {
                    guard chunk.count.isMultiple(of: 4),
                          let string = String(bytes: chunk, encoding: .ascii),
                          let decoded = Data(base64Encoded: string) else {
                        throw invalidJSON
                    }
                    result.append(decoded)
                }
                try cancellationCheck()
                return result
            }
            let decodedByte: UInt8
            if byte == 0x5C {
                guard index + 1 < data.count, data[index + 1] == 0x2F else {
                    throw invalidJSON
                }
                decodedByte = 0x2F
                index += 2
            } else {
                decodedByte = byte
                index += 1
            }
            if paddingCount > 0 {
                guard decodedByte == 0x3D, paddingCount < 2 else {
                    throw invalidJSON
                }
                paddingCount += 1
            } else if decodedByte == 0x3D {
                paddingCount = 1
            }
            chunk.append(decodedByte)
            scannedCount += 1

            if chunk.count == Self.base64ChunkSize, paddingCount == 0 {
                guard let string = String(bytes: chunk, encoding: .ascii),
                      let decoded = Data(base64Encoded: string) else {
                    throw invalidJSON
                }
                result.append(decoded)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        throw invalidJSON
    }

    private mutating func scanValue(depth: Int) throws -> Range<Int> {
        guard depth <= 128, index < data.count else { throw invalidJSON }
        scannedValueCount += 1
        if scannedValueCount.isMultiple(of: Self.cancellationValueStride) {
            try cancellationCheck()
        }
        let start = index
        switch data[index] {
        case 0x22:
            let range = try scanString()
            _ = try decode(String.self, from: range)
        case 0x7B:
            index += 1
            try skipWhitespace()
            if !consume(0x7D) {
                while true {
                    let keyRange = try scanString()
                    _ = try decode(String.self, from: keyRange)
                    try skipWhitespace()
                    try expect(0x3A)
                    try skipWhitespace()
                    _ = try scanValue(depth: depth + 1)
                    try skipWhitespace()
                    if consume(0x2C) {
                        try skipWhitespace()
                        continue
                    }
                    try expect(0x7D)
                    break
                }
            }
        case 0x5B:
            index += 1
            try skipWhitespace()
            if !consume(0x5D) {
                while true {
                    _ = try scanValue(depth: depth + 1)
                    try skipWhitespace()
                    if consume(0x2C) {
                        try skipWhitespace()
                        continue
                    }
                    try expect(0x5D)
                    break
                }
            }
        case 0x74: try scanLiteral([0x74, 0x72, 0x75, 0x65])
        case 0x66: try scanLiteral([0x66, 0x61, 0x6C, 0x73, 0x65])
        case 0x6E: try scanLiteral([0x6E, 0x75, 0x6C, 0x6C])
        default: try scanNumber()
        }
        return start..<index
    }

    private mutating func scanString() throws -> Range<Int> {
        let start = index
        try expect(0x22)
        while index < data.count {
            if (index - start).isMultiple(of: Self.cancellationStride) {
                try cancellationCheck()
            }
            let byte = data[index]
            if byte == 0x22 {
                index += 1
                return start..<index
            }
            if byte == 0x5C {
                index += 1
                guard index < data.count else { throw invalidJSON }
                if data[index] == 0x75 {
                    index += 1
                    for _ in 0..<4 {
                        guard index < data.count, isHex(data[index]) else {
                            throw invalidJSON
                        }
                        index += 1
                    }
                } else {
                    guard [0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74]
                        .contains(data[index]) else {
                        throw invalidJSON
                    }
                    index += 1
                }
                continue
            }
            guard byte >= 0x20 else { throw invalidJSON }
            index += 1
        }
        throw invalidJSON
    }

    private mutating func scanNumber() throws {
        if consume(0x2D), index == data.count { throw invalidJSON }
        if consume(0x30) {
            if index < data.count, isDigit(data[index]) { throw invalidJSON }
        } else {
            guard index < data.count, (0x31...0x39).contains(data[index]) else {
                throw invalidJSON
            }
            try scanDigits()
        }
        if consume(0x2E) {
            guard index < data.count, isDigit(data[index]) else { throw invalidJSON }
            try scanDigits()
        }
        if consume(0x65) || consume(0x45) {
            if !consume(0x2B) { _ = consume(0x2D) }
            guard index < data.count, isDigit(data[index]) else { throw invalidJSON }
            try scanDigits()
        }
    }

    private mutating func scanDigits() throws {
        while index < data.count, isDigit(data[index]) {
            if index.isMultiple(of: Self.cancellationStride) { try cancellationCheck() }
            index += 1
        }
    }

    private mutating func scanLiteral(_ literal: [UInt8]) throws {
        guard index + literal.count <= data.count else { throw invalidJSON }
        for byte in literal {
            if index.isMultiple(of: Self.cancellationStride) {
                try cancellationCheck()
            }
            guard data[index] == byte else { throw invalidJSON }
            index += 1
        }
    }

    private mutating func skipWhitespace() throws {
        while index < data.count,
              [0x20, 0x09, 0x0A, 0x0D].contains(data[index]) {
            if index.isMultiple(of: Self.cancellationStride) {
                try cancellationCheck()
            }
            index += 1
        }
    }

    private mutating func expect(_ byte: UInt8) throws {
        guard consume(byte) else { throw invalidJSON }
    }

    @discardableResult
    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < data.count, data[index] == byte else { return false }
        index += 1
        return true
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        from range: Range<Int>
    ) throws -> Value {
        try JSONDecoder.taptionPlan.decode(
            type,
            from: data.subdata(in: range)
        )
    }

    private func isNull(_ range: Range<Int>) -> Bool {
        data[range].elementsEqual([0x6E, 0x75, 0x6C, 0x6C])
    }

    private var invalidJSON: DecodingError {
        .dataCorrupted(.init(
            codingPath: [],
            debugDescription: "Invalid raw sensor archive JSON."
        ))
    }

    private func isDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
    }

    private func isHex(_ byte: UInt8) -> Bool {
        isDigit(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }
}

protocol PlanCloudAccountKeyProvider: AnyObject {
    /// Implementations must bind the key to the authenticated iCloud account.
    /// A different account must throw instead of generating a new key.
    func key(for accountIdentifier: String) throws -> Data
}

/// iCloud Drive carries the encrypted monthly archive. The recovery key lives
/// in the account's private CloudKit database, with an account-scoped hidden
/// iCloud Drive fallback for production-schema recovery.
@MainActor
protocol PlanCloudRecoveryKeyProvider: AnyObject {
    func key() async throws -> Data
}

private struct PlanCloudRecoveryKeyEnvelope: Codable {
    let accountIdentifier: String
    let key: Data
}

private struct PlanCloudRecoveryKeyBundle: Codable {
    var keys: [String: Data]
}

@MainActor
final class CloudKitPlanCloudRecoveryKeyProvider: PlanCloudRecoveryKeyProvider {
    static let privateAccountScope = "icloud-private-v1"
    private static let recordType = "TaptionBackupRecoveryKey"
    private static let recordName = "taption-backup-recovery-key-v1"
    private static let valueKey = "keyEnvelopeBytes"
    private let container: CKContainer?
    private let documentFallback: UbiquitousPlanCloudRecoveryKeyStore
    private let localFallback: PlanCredentialStore

    init(
        container: CKContainer? = nil,
        documentFallback: UbiquitousPlanCloudRecoveryKeyStore = .init(),
        localFallback: PlanCredentialStore = KeychainPlanCredentialStore(
            service: "com.taption.plan.security",
            account: "cloud-recovery-key-v1"
        )
    ) {
        self.container = container
        self.documentFallback = documentFallback
        self.localFallback = localFallback
    }

    func key() async throws -> Data {
        let container = container ?? CKContainer(identifier: "iCloud.com.taption.plan")
        let database = container.privateCloudDatabase
        let accountStatus: CKAccountStatus
        do {
            accountStatus = try await container.accountStatus()
        } catch {
            throw PlanSecurityError.accountUnavailable
        }
        guard accountStatus == .available else {
            throw PlanSecurityError.accountUnavailable
        }
        let accountIdentifier: String
        do {
            let recordID = try await container.userRecordID()
            accountIdentifier = recordID.recordName
        } catch {
            throw PlanSecurityError.accountUnavailable
        }
        guard !accountIdentifier.isEmpty else {
            throw PlanSecurityError.accountUnavailable
        }
        if let local = try? localFallbackKey(for: accountIdentifier) {
            return local
        }
        let scopedDocumentKey = try? documentFallback.existingScopedKey(
            for: accountIdentifier
        )
        let recordID = CKRecord.ID(recordName: Self.recordName)
        do {
            let record = try await database.record(for: recordID)
            guard let existing = record[Self.valueKey] as? Data,
                  existing.count == 32 else {
                throw PlanSecurityError.accountUnavailable
            }
            return try cacheResolvedKey(
                existing,
                forAccountIdentifier: accountIdentifier
            )
        } catch let error as CKError where error.code == .unknownItem {
            let generated: Data
            if let scopedDocumentKey {
                generated = scopedDocumentKey
            } else {
                generated = try Self.randomKey()
            }
            let record = CKRecord(recordType: Self.recordType, recordID: recordID)
            record[Self.valueKey] = generated as CKRecordValue
            do {
                _ = try await database.save(record)
                return try cacheResolvedKey(
                    generated,
                    forAccountIdentifier: accountIdentifier
                )
            } catch let saveError as CKError
            where saveError.code == .serverRecordChanged {
                let existing = try await database.record(for: recordID)
                guard let value = existing[Self.valueKey] as? Data,
                      value.count == 32 else {
                    throw PlanSecurityError.accountUnavailable
                }
                return try cacheResolvedKey(
                    value,
                    forAccountIdentifier: accountIdentifier
                )
            } catch {
                if Self.isProductionSchemaRejection(error) {
                    let value = try localFallbackKey(
                        or: generated,
                        for: accountIdentifier
                    )
                    try? documentFallback.removeExistingKey(
                        for: accountIdentifier
                    )
                    return value
                }
                throw error
            }
        } catch {
            if Self.isProductionSchemaRejection(error) {
                let value = try localFallbackKey(
                    or: scopedDocumentKey ?? Self.randomKey(),
                    for: accountIdentifier
                )
                try? documentFallback.removeExistingKey(
                    for: accountIdentifier
                )
                return value
            }
            throw error
        }
    }

    private func localFallbackKey(
        for accountIdentifier: String
    ) throws -> Data? {
        let keys = try localRecoveryKeys()
        guard let key = keys[accountIdentifier], key.count == 32 else {
            return nil
        }
        return key
    }

    private func localFallbackKey(
        or generated: Data,
        for accountIdentifier: String
    ) throws -> Data {
        if let data = try localFallbackKey(for: accountIdentifier) {
            return data
        }
        guard generated.count == 32 else {
            throw PlanSecurityError.accountUnavailable
        }
        var keys = try localRecoveryKeys()
        keys[accountIdentifier] = generated
        try localFallback.write(
            try JSONEncoder().encode(PlanCloudRecoveryKeyBundle(keys: keys))
        )
        return generated
    }

    private func localRecoveryKeys() throws -> [String: Data] {
        guard let data = try localFallback.read() else { return [:] }
        if let bundle = try? JSONDecoder().decode(
            PlanCloudRecoveryKeyBundle.self,
            from: data
        ) {
            return bundle.keys.filter { !$0.key.isEmpty && $0.value.count == 32 }
        }
        if let envelope = try? JSONDecoder().decode(
            PlanCloudRecoveryKeyEnvelope.self,
            from: data
        ), envelope.key.count == 32, !envelope.accountIdentifier.isEmpty {
            return [envelope.accountIdentifier: envelope.key]
        }
        // A 32-byte legacy key has no account provenance and must never be
        // reused after an iCloud account change.
        return [:]
    }

    private func cacheResolvedKey(
        _ key: Data,
        forAccountIdentifier accountIdentifier: String
    ) throws -> Data {
        guard key.count == 32, !accountIdentifier.isEmpty else {
            throw PlanSecurityError.accountUnavailable
        }
        var keys = try localRecoveryKeys()
        keys[accountIdentifier] = key
        try localFallback.write(
            try JSONEncoder().encode(PlanCloudRecoveryKeyBundle(keys: keys))
        )
        try? documentFallback.removeExistingKey(for: accountIdentifier)
        return key
    }

    func cacheResolvedKey(_ key: Data) throws -> Data {
        try localFallback.write(key)
        try? documentFallback.removeExistingKey()
        return key
    }

    private static func isProductionSchemaRejection(_ error: Error) -> Bool {
        let value = diagnosticMessage(for: error).lowercased()
        return value.contains("production schema")
            && value.contains(valueKey.lowercased())
    }

    private static func diagnosticMessage(for error: Error) -> String {
        let nsError = error as NSError
        var values = [
            error.localizedDescription,
            nsError.localizedFailureReason ?? "",
            nsError.userInfo[NSLocalizedRecoverySuggestionErrorKey] as? String
                ?? "",
        ]
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            values.append(diagnosticMessage(for: underlying))
        }
        if let partial = nsError.userInfo[CKPartialErrorsByItemIDKey]
            as? [AnyHashable: Any] {
            values.append(contentsOf: partial.values.compactMap { value in
                guard let error = value as? Error else { return nil }
                return diagnosticMessage(for: error)
            })
        }
        return values.joined(separator: " ")
    }

    private static func randomKey() throws -> Data {
        var key = Data(repeating: 0, count: 32)
        guard key.withUnsafeMutableBytes({
            guard let baseAddress = $0.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, 32, baseAddress)
        }) == errSecSuccess else {
            throw PlanSecurityError.accountUnavailable
        }
        return key
    }
}

final class UbiquitousPlanCloudRecoveryKeyStore {
    private let containerIdentifier: String
    private let fileManager: FileManager
    private let containerURL: URL?
    private let fileName = ".recovery-key-v1"

    init(
        containerIdentifier: String = "iCloud.com.taption.plan",
        fileManager: FileManager = .default,
        containerURL: URL? = nil
    ) {
        self.containerIdentifier = containerIdentifier
        self.fileManager = fileManager
        self.containerURL = containerURL
    }

    func existingKey() throws -> Data? {
        guard let fileURL = try recoveryKeyURL(createDirectory: false) else { return nil }
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        let value = try Data(contentsOf: fileURL)
        if value.count == 32 { return value }
        if let bundle = try? JSONDecoder().decode(
            PlanCloudRecoveryKeyBundle.self,
            from: value
        ) {
            return bundle.keys.count == 1
                ? bundle.keys.values.first
                : nil
        }
        guard let envelope = try? JSONDecoder().decode(
            PlanCloudRecoveryKeyEnvelope.self,
            from: value
        ), envelope.key.count == 32 else {
            throw PlanSecurityError.invalidArchive
        }
        return envelope.key
    }

    func existingScopedKey(for accountIdentifier: String) throws -> Data? {
        guard !accountIdentifier.isEmpty,
              let fileURL = try recoveryKeyURL(createDirectory: false),
              fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let value = try Data(contentsOf: fileURL)
        guard value.count != 32 else { return nil }
        if let bundle = try? JSONDecoder().decode(
            PlanCloudRecoveryKeyBundle.self,
            from: value
        ), let key = bundle.keys[accountIdentifier], key.count == 32 {
            return key
        }
        guard let envelope = try? JSONDecoder().decode(
            PlanCloudRecoveryKeyEnvelope.self,
            from: value
        ), envelope.accountIdentifier == accountIdentifier,
            envelope.key.count == 32 else {
            return nil
        }
        return envelope.key
    }

    func save(_ key: Data) throws {
        guard key.count == 32,
               let fileURL = try recoveryKeyURL(createDirectory: true) else {
            throw PlanSecurityError.accountUnavailable
        }
        try write(key, to: fileURL)
    }

    func save(_ key: Data, accountIdentifier: String) throws {
        guard key.count == 32, !accountIdentifier.isEmpty else {
            throw PlanSecurityError.accountUnavailable
        }
        var keys: [String: Data] = [:]
        if let fileURL = try recoveryKeyURL(createDirectory: false),
           fileManager.fileExists(atPath: fileURL.path),
           let value = try? Data(contentsOf: fileURL) {
            if let bundle = try? JSONDecoder().decode(
                PlanCloudRecoveryKeyBundle.self,
                from: value
            ) {
                keys = bundle.keys
            } else if let envelope = try? JSONDecoder().decode(
                PlanCloudRecoveryKeyEnvelope.self,
                from: value
            ), envelope.key.count == 32, !envelope.accountIdentifier.isEmpty {
                keys[envelope.accountIdentifier] = envelope.key
            }
        }
        keys[accountIdentifier] = key
        guard let fileURL = try recoveryKeyURL(createDirectory: true) else {
            throw PlanSecurityError.accountUnavailable
        }
        try write(
            JSONEncoder().encode(PlanCloudRecoveryKeyBundle(keys: keys)),
            to: fileURL
        )
    }

    func removeExistingKey(for accountIdentifier: String) throws {
        guard !accountIdentifier.isEmpty,
              let fileURL = try recoveryKeyURL(createDirectory: false),
              fileManager.fileExists(atPath: fileURL.path),
              let value = try? Data(contentsOf: fileURL) else { return }
        guard var bundle = try? JSONDecoder().decode(
            PlanCloudRecoveryKeyBundle.self,
            from: value
        ), bundle.keys.removeValue(forKey: accountIdentifier) != nil else {
            if let envelope = try? JSONDecoder().decode(
                PlanCloudRecoveryKeyEnvelope.self,
                from: value
            ), envelope.accountIdentifier == accountIdentifier {
                try removeExistingKey()
            }
            return
        }
        if bundle.keys.isEmpty {
            try removeExistingKey()
        } else {
            guard let fileURL = try recoveryKeyURL(createDirectory: true) else {
                throw PlanSecurityError.accountUnavailable
            }
            try write(try JSONEncoder().encode(bundle), to: fileURL)
        }
    }

    func removeExistingKey() throws {
        guard let fileURL = try recoveryKeyURL(createDirectory: false),
              fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }

    private func write(_ data: Data, to fileURL: URL) throws {
        try data.write(
            to: fileURL,
            options: [
                .atomic,
                .completeFileProtectionUntilFirstUserAuthentication,
            ]
        )
    }

    private func recoveryKeyURL(createDirectory: Bool) throws -> URL? {
        guard let container = containerURL ?? fileManager.url(
            forUbiquityContainerIdentifier: containerIdentifier
        ) else { return nil }
        let directory = container
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Taption Plan", isDirectory: true)
        if createDirectory {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        return directory.appendingPathComponent(fileName, isDirectory: false)
    }
}

@MainActor
final class InMemoryPlanCloudRecoveryKeyProvider: PlanCloudRecoveryKeyProvider {
    private var value: Data?

    func key() async throws -> Data {
        if let value { return value }
        let generated = Data(repeating: 9, count: 32)
        value = generated
        return generated
    }
}

final class InMemoryPlanCloudAccountKeyProvider: PlanCloudAccountKeyProvider {
    private var keys: [String: Data] = [:]
    func key(for accountIdentifier: String) throws -> Data {
        guard !accountIdentifier.isEmpty else { throw PlanSecurityError.accountUnavailable }
        if let key = keys[accountIdentifier] { return key }
        var key = Data(repeating: 0, count: 32)
        let status = key.withUnsafeMutableBytes { buffer -> Int32 in
            guard let baseAddress = buffer.baseAddress else {
                return errSecParam
            }
            return SecRandomCopyBytes(kSecRandomDefault, 32, baseAddress)
        }
        guard status == errSecSuccess else {
            throw PlanSecurityError.accountUnavailable
        }
        keys[accountIdentifier] = key
        return key
    }
}

protocol PlanCloudBackupStore: AnyObject {
    func save(_ archive: PlanMonthlyArchive, at path: PlanCloudBackupPath) throws
    func delete(at path: PlanCloudBackupPath) throws
    func latest() throws -> PlanMonthlyArchive?
    func allArchives() throws -> [PlanMonthlyArchive]
    func deleteAll() throws
}

private enum PlanCloudArchiveFileReadResult {
    case data(Data)
    case unavailable
    case rejected
}

final class PlanCloudArchiveRestoreByteBudget: @unchecked Sendable {
    static let defaultMaximumBytes = 2 * 1_024 * 1_024 * 1_024

    private let lock = NSLock()
    private let maximumBytes: Int
    private var totalBytes = 0

    init(
        maximumBytes: Int = PlanCloudArchiveRestoreByteBudget.defaultMaximumBytes
    ) {
        self.maximumBytes = max(0, maximumBytes)
    }

    func read<Value>(
        fileSize: Int,
        _ operation: () throws -> (Value, Int)
    ) throws -> Value {
        lock.lock()
        defer { lock.unlock() }
        guard fileSize >= 0,
              fileSize <= maximumBytes,
              totalBytes <= maximumBytes - fileSize else {
            throw PlanSecurityError.invalidArchive
        }
        let (value, bytesRead) = try operation()
        guard bytesRead >= 0, bytesRead <= fileSize else {
            throw PlanSecurityError.invalidArchive
        }
        totalBytes += bytesRead
        return value
    }
}

private enum PlanCloudArchiveFilePolicy {
    static let maximumFileCount = 120
    static let maximumFileBytes = 512 * 1_024 * 1_024
    static let maximumTotalBytes = PlanCloudArchiveRestoreByteBudget
        .defaultMaximumBytes

    static func candidates(
        in directory: URL,
        pathExtension: String,
        fileManager: FileManager
    ) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == pathExtension }
        .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    static func read(
        _ url: URL,
        totalBytes: inout Int,
        fileManager: FileManager
    ) -> PlanCloudArchiveFileReadResult {
        let resourceKeys: Set<URLResourceKey> = [
            .fileSizeKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
        ]
        guard let values = try? url.resourceValues(forKeys: resourceKeys) else {
            return .unavailable
        }
        if values.isUbiquitousItem == true,
           values.ubiquitousItemDownloadingStatus != .current {
            try? fileManager.startDownloadingUbiquitousItem(at: url)
            return .unavailable
        }
        guard let size = values.fileSize else {
            return .unavailable
        }
        guard size >= 0,
              size <= maximumFileBytes,
              totalBytes <= maximumTotalBytes - size else {
            return .rejected
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .unavailable
        }
        guard data.count <= maximumFileBytes,
              totalBytes <= maximumTotalBytes - data.count else {
            return .rejected
        }
        guard let finalValues = try? url.resourceValues(forKeys: [.fileSizeKey]),
              data.count == size,
              finalValues.fileSize == size else {
            return .unavailable
        }
        totalBytes += data.count
        return .data(data)
    }

    static func readForRestore(
        _ url: URL,
        byteBudget: PlanCloudArchiveRestoreByteBudget,
        fileManager: FileManager,
        cancellationCheck: () throws -> Void
    ) throws -> PlanCloudArchiveFileReadResult {
        try cancellationCheck()
        let resourceKeys: Set<URLResourceKey> = [
            .fileSizeKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
        ]
        guard let values = try? url.resourceValues(forKeys: resourceKeys) else {
            return .unavailable
        }
        if values.isUbiquitousItem == true,
           values.ubiquitousItemDownloadingStatus != .current {
            try? fileManager.startDownloadingUbiquitousItem(at: url)
            return .unavailable
        }
        guard let size = values.fileSize else { return .unavailable }
        guard size >= 0, size <= maximumFileBytes else {
            return .rejected
        }

        return try byteBudget.read(fileSize: size) {
            try cancellationCheck()
            let file: FileHandle
            do {
                file = try FileHandle(forReadingFrom: url)
            } catch {
                return (.unavailable, 0)
            }
            defer { try? file.close() }

            var data = Data()
            while data.count < size {
                try cancellationCheck()
                let chunk: Data
                do {
                    chunk = try file.read(
                        upToCount: min(1_048_576, size - data.count)
                    ) ?? Data()
                } catch {
                    return (.unavailable, data.count)
                }
                guard !chunk.isEmpty else { break }
                data.append(chunk)
            }
            try cancellationCheck()
            guard data.count <= maximumFileBytes else {
                return (.rejected, data.count)
            }
            guard let finalValues = try? url.resourceValues(
                forKeys: [.fileSizeKey]
            ), data.count == size, finalValues.fileSize == size else {
                return (.unavailable, data.count)
            }
            return (.data(data), data.count)
        }
    }
}

extension PlanCloudBackupStore {
    func allArchives() throws -> [PlanMonthlyArchive] {
        try latest().map { [$0] } ?? []
    }
}

final class FilePlanCloudBackupStore: PlanCloudBackupStore {
    private let root: URL
    private let fileManager: FileManager

    init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    func save(_ archive: PlanMonthlyArchive, at path: PlanCloudBackupPath) throws {
        let destination = path.storageComponents.reduce(root) {
            $0.appendingPathComponent($1, isDirectory: false)
        }
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.taptionPlan.encode(archive)
        try data.write(
            to: destination,
            options: [.atomic, .completeFileProtection]
        )
    }

    func delete(at path: PlanCloudBackupPath) throws {
        let destination = path.storageComponents.reduce(root) {
            $0.appendingPathComponent($1, isDirectory: false)
        }
        guard fileManager.fileExists(atPath: destination.path) else { return }
        try fileManager.removeItem(at: destination)
    }

    func latest() throws -> PlanMonthlyArchive? {
        try allArchives().max { $0.monthKey < $1.monthKey }
    }

    func allArchives() throws -> [PlanMonthlyArchive] {
        let root = root.appendingPathComponent("Taption Plan", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: root.path,
            isDirectory: &isDirectory
        ) else { return [] }
        guard isDirectory.boolValue else {
            throw PlanSecurityError.invalidArchive
        }
        let months = try PlanCloudArchiveFilePolicy.candidates(
            in: root,
            pathExtension: "taptionbackup",
            fileManager: fileManager
        )
        var archives: [PlanMonthlyArchive] = []
        var archiveCount = 0
        var totalBytes = 0
        var unavailableCount = 0
        var rejectedCount = 0
        var invalidCount = 0
        let boundedMonths = months.prefix(
            PlanCloudArchiveFilePolicy.maximumFileCount
        )
        for month in boundedMonths {
            archiveCount += 1
            switch PlanCloudArchiveFilePolicy.read(
                month,
                totalBytes: &totalBytes,
                fileManager: fileManager
            ) {
            case let .data(data):
                guard let archive = try? JSONDecoder.taptionPlan.decode(
                    PlanMonthlyArchive.self,
                    from: data
                ) else {
                    invalidCount += 1
                    continue
                }
                archives.append(archive)
            case .unavailable:
                unavailableCount += 1
            case .rejected:
                rejectedCount += 1
            }
        }
        let skippedByLimit = months.count - boundedMonths.count
        if archiveCount > archives.count || skippedByLimit > 0 {
            TaptionPlanDiagnosticsLogger.shared.record(
                "cloud_backup_files_skipped",
                level: archives.isEmpty && unavailableCount == 0
                    ? .error
                    : .notice,
                fields: [
                    "invalid": String(invalidCount),
                    "unavailable": String(unavailableCount),
                    "rejected": String(rejectedCount),
                    "bounded": String(skippedByLimit),
                    "valid": String(archives.count),
                ]
            )
        }
        if unavailableCount > 0 {
            throw PlanSecurityError.accountUnavailable
        }
        guard archiveCount == 0 || !archives.isEmpty else {
            throw PlanSecurityError.invalidArchive
        }
        return archives
    }

    func deleteAll() throws {
        let directory = root.appendingPathComponent(
            "Taption Plan",
            isDirectory: true
        )
        guard fileManager.fileExists(atPath: directory.path) else { return }
        for file in try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) where file.pathExtension == "taptionbackup" {
            try fileManager.removeItem(at: file)
        }
    }
}

/// Cloud Documents is the authoritative monthly-backup location. There is no
/// local fallback: if the iCloud account is unavailable, backup and recovery
/// report that state instead of claiming a device-only file is cloud data.
final class UbiquitousPlanCloudBackupStore: PlanCloudBackupStore {
    private let containerIdentifier: String
    private let fileManager: FileManager

    init(
        containerIdentifier: String = "iCloud.com.taption.plan",
        fileManager: FileManager = .default
    ) {
        self.containerIdentifier = containerIdentifier
        self.fileManager = fileManager
    }

    func save(_ archive: PlanMonthlyArchive, at path: PlanCloudBackupPath) throws {
        try fileStore().save(archive, at: path)
    }

    func delete(at path: PlanCloudBackupPath) throws {
        try fileStore().delete(at: path)
    }

    func latest() throws -> PlanMonthlyArchive? {
        try fileStore().latest()
    }

    func allArchives() throws -> [PlanMonthlyArchive] {
        try fileStore().allArchives()
    }

    func deleteAll() throws {
        try fileStore().deleteAll()
    }

    private func fileStore() throws -> FilePlanCloudBackupStore {
        guard let container = fileManager.url(
            forUbiquityContainerIdentifier: containerIdentifier
        ) else {
            throw PlanSecurityError.accountUnavailable
        }
        let documents = container.appendingPathComponent(
            "Documents",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: documents,
            withIntermediateDirectories: true
        )
        return FilePlanCloudBackupStore(root: documents, fileManager: fileManager)
    }
}

final class InMemoryPlanCloudBackupStore: PlanCloudBackupStore {
    private(set) var archives: [String: PlanMonthlyArchive] = [:]
    func save(_ archive: PlanMonthlyArchive, at path: PlanCloudBackupPath) throws { archives[path.monthKey] = archive }
    func delete(at path: PlanCloudBackupPath) throws {
        archives[path.monthKey] = nil
    }
    func latest() throws -> PlanMonthlyArchive? {
        archives.values.max { $0.monthKey < $1.monthKey }
    }

    func allArchives() throws -> [PlanMonthlyArchive] {
        Array(archives.values)
    }

    func deleteAll() throws {
        archives.removeAll()
    }
}

protocol PlanCloudRawSensorBackupStore: AnyObject {
    func save(
        _ archive: PlanRawSensorMonthlyArchive,
        at path: PlanCloudRawSensorBackupPath
    ) throws
    func delete(at path: PlanCloudRawSensorBackupPath) throws
    func latest() throws -> PlanRawSensorMonthlyArchive?
    func allArchives() throws -> [PlanRawSensorMonthlyArchive]
    func legacyArchiveMonthKeys() throws -> [String]
    func load(
        monthKey: String,
        generationID: UUID?
    ) throws -> PlanRawSensorMonthlyArchive?
    @MainActor
    func loadForRestore(
        monthKey: String,
        generationID: UUID?,
        byteBudget: PlanCloudArchiveRestoreByteBudget
    ) async throws -> PlanRawSensorMonthlyArchive?
    func deleteAll() throws
}

extension PlanCloudRawSensorBackupStore {
    func allArchives() throws -> [PlanRawSensorMonthlyArchive] {
        try latest().map { [$0] } ?? []
    }

    func legacyArchiveMonthKeys() throws -> [String] {
        try allArchives().filter { $0.generationID == nil }.map(\.monthKey)
    }

    func load(
        monthKey: String,
        generationID: UUID?
    ) throws -> PlanRawSensorMonthlyArchive? {
        try allArchives().first {
            $0.monthKey == monthKey && $0.generationID == generationID
        }
    }

    @MainActor
    func loadForRestore(
        monthKey: String,
        generationID: UUID?
    ) async throws -> PlanRawSensorMonthlyArchive? {
        try await loadForRestore(
            monthKey: monthKey,
            generationID: generationID,
            byteBudget: PlanCloudArchiveRestoreByteBudget()
        )
    }

    @MainActor
    func loadForRestore(
        monthKey: String,
        generationID: UUID?,
        byteBudget: PlanCloudArchiveRestoreByteBudget
    ) async throws -> PlanRawSensorMonthlyArchive? {
        try Task.checkCancellation()
        guard let archive = try load(
            monthKey: monthKey,
            generationID: generationID
        ) else {
            return nil
        }
        let fileSize = try JSONEncoder.taptionPlan.encode(archive).count
        try Task.checkCancellation()
        return try byteBudget.read(fileSize: fileSize) {
            (archive, fileSize)
        }
    }
}

final class FilePlanCloudRawSensorBackupStore:
    PlanCloudRawSensorBackupStore, @unchecked Sendable {
    private let root: URL
    private let fileManager: FileManager

    init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    func save(
        _ archive: PlanRawSensorMonthlyArchive,
        at path: PlanCloudRawSensorBackupPath
    ) throws {
        let destination = path.storageComponents.reduce(root) {
            $0.appendingPathComponent($1, isDirectory: false)
        }
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder.taptionPlan.encode(archive)
        try data.write(
            to: destination,
            options: [.atomic, .completeFileProtection]
        )
    }

    func delete(at path: PlanCloudRawSensorBackupPath) throws {
        let destination = path.storageComponents.reduce(root) {
            $0.appendingPathComponent($1, isDirectory: false)
        }
        guard fileManager.fileExists(atPath: destination.path) else { return }
        try fileManager.removeItem(at: destination)
    }

    func latest() throws -> PlanRawSensorMonthlyArchive? {
        try allArchives().max {
            $0.monthKey == $1.monthKey
                ? $0.createdAt < $1.createdAt
                : $0.monthKey < $1.monthKey
        }
    }

    func load(
        monthKey: String,
        generationID: UUID?
    ) throws -> PlanRawSensorMonthlyArchive? {
        let path = PlanCloudRawSensorBackupPath(
            monthKey: monthKey,
            generationID: generationID
        )
        let destination = path.storageComponents.reduce(root) {
            $0.appendingPathComponent($1, isDirectory: false)
        }
        if fileManager.fileExists(atPath: destination.path) {
            return try readArchive(
                at: destination,
                monthKey: monthKey,
                generationID: generationID
            )
        }
        guard let generationID else { return nil }
        let legacyPath = PlanCloudRawSensorBackupPath(monthKey: monthKey)
        let legacyDestination = legacyPath.storageComponents.reduce(root) {
            $0.appendingPathComponent($1, isDirectory: false)
        }
        guard fileManager.fileExists(atPath: legacyDestination.path) else {
            return nil
        }
        let legacy = try readArchive(
            at: legacyDestination,
            monthKey: monthKey,
            generationID: generationID,
            enforceGenerationMatch: false
        )
        return legacy?.generationID == generationID ? legacy : nil
    }

    func loadForRestore(
        monthKey: String,
        generationID: UUID?,
        byteBudget: PlanCloudArchiveRestoreByteBudget
    ) async throws -> PlanRawSensorMonthlyArchive? {
        try await loadForRestore(
            monthKey: monthKey,
            generationID: generationID,
            byteBudget: byteBudget,
            cancellationCheck: { try Task.checkCancellation() }
        )
    }

    func loadForRestore(
        monthKey: String,
        generationID: UUID?,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> PlanRawSensorMonthlyArchive? {
        try await loadForRestore(
            monthKey: monthKey,
            generationID: generationID,
            byteBudget: PlanCloudArchiveRestoreByteBudget(),
            cancellationCheck: cancellationCheck
        )
    }

    func loadForRestore(
        monthKey: String,
        generationID: UUID?,
        byteBudget: PlanCloudArchiveRestoreByteBudget,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> PlanRawSensorMonthlyArchive? {
        let task = Task.detached(priority: .utility) {
            let archive = try self.loadForRestoreSync(
                monthKey: monthKey,
                generationID: generationID,
                byteBudget: byteBudget,
                cancellationCheck: cancellationCheck
            )
            try Task.checkCancellation()
            return archive
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func legacyArchiveMonthKeys() throws -> [String] {
        let directory = root.appendingPathComponent(
            "Taption Plan/Raw Sensors",
            isDirectory: true
        )
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: directory.path,
            isDirectory: &isDirectory
        ) else { return [] }
        guard isDirectory.boolValue else {
            throw PlanSecurityError.invalidArchive
        }
        let files = try PlanCloudArchiveFilePolicy.candidates(
            in: directory,
            pathExtension: "rawsensorbackup",
            fileManager: fileManager
        )
        let legacyMonthKeys = files.compactMap { file -> String? in
            let monthKey = file.deletingPathExtension().lastPathComponent
            guard let separator = monthKey.lastIndex(of: "."),
                  UUID(uuidString: String(monthKey[monthKey.index(after: separator)...])) != nil else {
                return monthKey
            }
            return nil
        }
        guard legacyMonthKeys.count
            <= PlanCloudArchiveFilePolicy.maximumFileCount else {
            throw PlanSecurityError.invalidArchive
        }
        return legacyMonthKeys
    }

    private func loadForRestoreSync(
        monthKey: String,
        generationID: UUID?,
        byteBudget: PlanCloudArchiveRestoreByteBudget,
        cancellationCheck: @escaping () throws -> Void
    ) throws -> PlanRawSensorMonthlyArchive? {
        let path = PlanCloudRawSensorBackupPath(
            monthKey: monthKey,
            generationID: generationID
        )
        let destination = path.storageComponents.reduce(root) {
            $0.appendingPathComponent($1, isDirectory: false)
        }
        if fileManager.fileExists(atPath: destination.path) {
            return try readArchive(
                at: destination,
                monthKey: monthKey,
                generationID: generationID,
                byteBudget: byteBudget,
                cancellationCheck: cancellationCheck
            )
        }
        guard let generationID else { return nil }
        let legacyPath = PlanCloudRawSensorBackupPath(monthKey: monthKey)
        let legacyDestination = legacyPath.storageComponents.reduce(root) {
            $0.appendingPathComponent($1, isDirectory: false)
        }
        guard fileManager.fileExists(atPath: legacyDestination.path) else {
            return nil
        }
        let legacy = try readArchive(
            at: legacyDestination,
            monthKey: monthKey,
            generationID: generationID,
            enforceGenerationMatch: false,
            byteBudget: byteBudget,
            cancellationCheck: cancellationCheck
        )
        return legacy?.generationID == generationID ? legacy : nil
    }

    private func readArchive(
        at destination: URL,
        monthKey: String,
        generationID: UUID?,
        enforceGenerationMatch: Bool = true,
        byteBudget: PlanCloudArchiveRestoreByteBudget? = nil,
        cancellationCheck: (() throws -> Void)? = nil
    ) throws -> PlanRawSensorMonthlyArchive? {
        var totalBytes = 0
        let readResult: PlanCloudArchiveFileReadResult
        if let cancellationCheck {
            readResult = try PlanCloudArchiveFilePolicy.readForRestore(
                destination,
                byteBudget: byteBudget ?? PlanCloudArchiveRestoreByteBudget(),
                fileManager: fileManager,
                cancellationCheck: cancellationCheck
            )
        } else {
            readResult = PlanCloudArchiveFilePolicy.read(
                destination,
                totalBytes: &totalBytes,
                fileManager: fileManager
            )
        }
        switch readResult {
        case let .data(data):
            try cancellationCheck?()
            let archive: PlanRawSensorMonthlyArchive
            if let cancellationCheck {
                do {
                    archive = try PlanRawSensorMonthlyArchive.decodeForRestore(
                        data,
                        cancellationCheck: cancellationCheck
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw PlanSecurityError.invalidArchive
                }
            } else {
                guard let decoded = try? JSONDecoder.taptionPlan.decode(
                    PlanRawSensorMonthlyArchive.self,
                    from: data
                ) else {
                    throw PlanSecurityError.invalidArchive
                }
                archive = decoded
            }
            try cancellationCheck?()
            guard archive.monthKey == monthKey,
                  !enforceGenerationMatch
                    || archive.generationID == generationID else {
                throw PlanSecurityError.invalidArchive
            }
            return archive
        case .unavailable:
            throw PlanSecurityError.accountUnavailable
        case .rejected:
            throw PlanSecurityError.invalidArchive
        }
    }

    func allArchives() throws -> [PlanRawSensorMonthlyArchive] {
        let directory = root.appendingPathComponent(
            "Taption Plan/Raw Sensors",
            isDirectory: true
        )
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: directory.path,
            isDirectory: &isDirectory
        ) else { return [] }
        guard isDirectory.boolValue else {
            throw PlanSecurityError.invalidArchive
        }
        let files = try PlanCloudArchiveFilePolicy.candidates(
            in: directory,
            pathExtension: "rawsensorbackup",
            fileManager: fileManager
        )
        var archives: [PlanRawSensorMonthlyArchive] = []
        var archiveCount = 0
        var totalBytes = 0
        var unavailableCount = 0
        var rejectedCount = 0
        var invalidCount = 0
        let boundedFiles = files.prefix(
            PlanCloudArchiveFilePolicy.maximumFileCount
        )
        for file in boundedFiles {
            archiveCount += 1
            switch PlanCloudArchiveFilePolicy.read(
                file,
                totalBytes: &totalBytes,
                fileManager: fileManager
            ) {
            case let .data(data):
                guard let archive = try? JSONDecoder.taptionPlan.decode(
                    PlanRawSensorMonthlyArchive.self,
                    from: data
                ) else {
                    invalidCount += 1
                    continue
                }
                archives.append(archive)
            case .unavailable:
                unavailableCount += 1
            case .rejected:
                rejectedCount += 1
            }
        }
        let skippedByLimit = files.count - boundedFiles.count
        if archiveCount > archives.count || skippedByLimit > 0 {
            TaptionPlanDiagnosticsLogger.shared.record(
                "cloud_raw_backup_files_skipped",
                level: archives.isEmpty && unavailableCount == 0
                    ? .error
                    : .notice,
                fields: [
                    "invalid": String(invalidCount),
                    "unavailable": String(unavailableCount),
                    "rejected": String(rejectedCount),
                    "bounded": String(skippedByLimit),
                    "valid": String(archives.count),
                ]
            )
        }
        if unavailableCount > 0 {
            throw PlanSecurityError.accountUnavailable
        }
        guard invalidCount == 0, rejectedCount == 0, skippedByLimit == 0 else {
            throw PlanSecurityError.invalidArchive
        }
        guard archiveCount == 0 || !archives.isEmpty else {
            throw PlanSecurityError.invalidArchive
        }
        return archives
    }

    func deleteAll() throws {
        let directory = root.appendingPathComponent(
            "Taption Plan/Raw Sensors",
            isDirectory: true
        )
        guard fileManager.fileExists(atPath: directory.path) else { return }
        for file in try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) where file.pathExtension == "rawsensorbackup" {
            try fileManager.removeItem(at: file)
        }
    }
}

final class UbiquitousPlanCloudRawSensorBackupStore:
    PlanCloudRawSensorBackupStore, @unchecked Sendable {
    private let containerIdentifier: String
    private let fileManager: FileManager

    init(
        containerIdentifier: String = "iCloud.com.taption.plan",
        fileManager: FileManager = .default
    ) {
        self.containerIdentifier = containerIdentifier
        self.fileManager = fileManager
    }

    func save(
        _ archive: PlanRawSensorMonthlyArchive,
        at path: PlanCloudRawSensorBackupPath
    ) throws {
        try fileStore().save(archive, at: path)
    }

    func delete(at path: PlanCloudRawSensorBackupPath) throws {
        try fileStore().delete(at: path)
    }

    func latest() throws -> PlanRawSensorMonthlyArchive? {
        try fileStore().latest()
    }

    func allArchives() throws -> [PlanRawSensorMonthlyArchive] {
        try fileStore().allArchives()
    }

    func legacyArchiveMonthKeys() throws -> [String] {
        try fileStore().legacyArchiveMonthKeys()
    }

    func load(
        monthKey: String,
        generationID: UUID?
    ) throws -> PlanRawSensorMonthlyArchive? {
        try fileStore().load(
            monthKey: monthKey,
            generationID: generationID
        )
    }

    func loadForRestore(
        monthKey: String,
        generationID: UUID?,
        byteBudget: PlanCloudArchiveRestoreByteBudget
    ) async throws -> PlanRawSensorMonthlyArchive? {
        try await fileStore().loadForRestore(
            monthKey: monthKey,
            generationID: generationID,
            byteBudget: byteBudget
        )
    }

    func deleteAll() throws {
        try fileStore().deleteAll()
    }

    private func fileStore() throws -> FilePlanCloudRawSensorBackupStore {
        guard let container = fileManager.url(
            forUbiquityContainerIdentifier: containerIdentifier
        ) else {
            throw PlanSecurityError.accountUnavailable
        }
        let documents = container.appendingPathComponent(
            "Documents",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: documents,
            withIntermediateDirectories: true
        )
        return FilePlanCloudRawSensorBackupStore(
            root: documents,
            fileManager: fileManager
        )
    }
}

final class InMemoryPlanCloudRawSensorBackupStore:
    PlanCloudRawSensorBackupStore {
    private var storedArchives: [String: PlanRawSensorMonthlyArchive] = [:]
    private var latestByMonth: [String: PlanRawSensorMonthlyArchive] = [:]

    var archives: [String: PlanRawSensorMonthlyArchive] { latestByMonth }

    func save(
        _ archive: PlanRawSensorMonthlyArchive,
        at path: PlanCloudRawSensorBackupPath
    ) throws {
        storedArchives[path.relativePath] = archive
        latestByMonth[path.monthKey] = archive
    }

    func delete(at path: PlanCloudRawSensorBackupPath) throws {
        let removed = storedArchives.removeValue(forKey: path.relativePath)
        guard latestByMonth[path.monthKey] == removed else { return }
        latestByMonth[path.monthKey] = storedArchives.values
            .filter { $0.monthKey == path.monthKey }
            .max {
                $0.monthKey == $1.monthKey
                    ? $0.createdAt < $1.createdAt
                    : $0.monthKey < $1.monthKey
            }
    }

    func latest() throws -> PlanRawSensorMonthlyArchive? {
        storedArchives.values.max {
            $0.monthKey == $1.monthKey
                ? $0.createdAt < $1.createdAt
                : $0.monthKey < $1.monthKey
        }
    }

    func allArchives() throws -> [PlanRawSensorMonthlyArchive] {
        Array(storedArchives.values)
    }

    func load(
        monthKey: String,
        generationID: UUID?
    ) throws -> PlanRawSensorMonthlyArchive? {
        let exact = PlanCloudRawSensorBackupPath(
            monthKey: monthKey,
            generationID: generationID
        )
        if let archive = storedArchives[exact.relativePath] {
            return archive
        }
        guard let generationID else { return nil }
        let legacy = PlanCloudRawSensorBackupPath(monthKey: monthKey)
        guard let archive = storedArchives[legacy.relativePath],
              archive.generationID == generationID else {
            return nil
        }
        return archive
    }

    func deleteAll() throws {
        storedArchives.removeAll()
        latestByMonth.removeAll()
    }
}

enum PlanArchiveSchedule {
    static func monthKey(for date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let components = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
    }

    static func monthsBetween(_ start: Date, _ end: Date, calendar: Calendar = .autoupdatingCurrent) -> [String] {
        let startMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: start)) ?? start
        let endMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: end)) ?? end
        guard startMonth <= endMonth else { return [] }
        var result: [String] = []
        var cursor = startMonth
        while cursor <= endMonth {
            result.append(monthKey(for: cursor, calendar: calendar))
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }
}

struct PlanCloudBackupGeneration {
    let snapshot: PlanMonthlyArchive
    let rawSensors: PlanRawSensorMonthlyArchive?
    let generationID: UUID
}

enum PlanCloudRawSensorRestoreState: Equatable, Sendable {
    case unavailable
    case available(PlanCloudRawSensorPayload)
    case invalidArchive
}

struct PlanCloudBackupRestorePackage: Equatable, Sendable {
    let backup: PlanCloudBackupPayload
    let rawSensorState: PlanCloudRawSensorRestoreState

    init(
        backup: PlanCloudBackupPayload,
        rawSensorState: PlanCloudRawSensorRestoreState = .unavailable
    ) {
        self.backup = backup
        self.rawSensorState = rawSensorState
    }
}

private struct PlanCloudRawSensorPayloadBuffer<
    Value: Identifiable & Equatable & Encodable
> where Value.ID == UUID {
    private var indicesByID: [UUID: Int] = [:]
    private(set) var values: [Value] = []

    mutating func append(contentsOf incoming: [Value]) throws {
        for value in incoming {
            if let index = indicesByID[value.id] {
                let existing = values[index]
                if existing != value {
                    let existingData = try JSONEncoder.taptionPlan.encode(existing)
                    let incomingData = try JSONEncoder.taptionPlan.encode(value)
                    guard existingData == incomingData else {
                        TaptionPlanDiagnosticsLogger.shared.record(
                            "raw_sensor_archive_merge_conflict",
                            level: .error,
                            fields: [
                                "record_type": String(describing: Value.self),
                            ]
                        )
                        throw PlanSecurityError.invalidArchive
                    }
                }
                values[index] = value
            } else {
                indicesByID[value.id] = values.count
                values.append(value)
            }
        }
    }

    mutating func takeValues() -> [Value] {
        indicesByID.removeAll(keepingCapacity: false)
        let result = values
        values = []
        return result
    }
}

private struct PlanRawSensorAccountKeyFallbackNeeded: Error, Sendable {}

private struct PlanRawSensorRecoveryKeyLookupFailure: Error, Sendable {
    let underlying: any Error
}

private actor PlanRawSensorRestoreAccumulator {
    private var readings = PlanCloudRawSensorPayloadBuffer<SensorReading>()
    private var envelopes = PlanCloudRawSensorPayloadBuffer<RawDeviceDataEnvelope>()
    private var chunks = PlanCloudRawSensorPayloadBuffer<TaptionWatchAccelerationChunk>()
    private var latestMonthKey: String?
    private var latestCreatedAt: Date?

    func append(
        _ archive: PlanRawSensorMonthlyArchive,
        pinKeyData: Data?,
        accountKeyData: Data?
    ) throws {
        try Task.checkCancellation()
        let payload: PlanCloudRawSensorPayload
        do {
            payload = try archive.decodedPayload(
                pinKeyData: pinKeyData,
                accountKeyData: accountKeyData,
                cancellationCheck: { try Task.checkCancellation() }
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard accountKeyData == nil else { throw error }
            throw PlanRawSensorAccountKeyFallbackNeeded()
        }
        try Task.checkCancellation()
        try readings.append(contentsOf: payload.sensorReadings)
        try envelopes.append(contentsOf: payload.envelopes)
        try chunks.append(contentsOf: payload.watchAccelerationChunks ?? [])
        latestMonthKey = payload.monthKey
        latestCreatedAt = payload.createdAt
    }

    func restoreState() -> PlanCloudRawSensorRestoreState {
        guard let latestMonthKey, let latestCreatedAt else {
            return .unavailable
        }
        let sensorReadings = readings.takeValues()
        let rawEnvelopes = envelopes.takeValues()
        let accelerationChunks = chunks.takeValues()
        return .available(
            PlanCloudRawSensorPayload(
                monthKey: latestMonthKey,
                sensorReadings: sensorReadings,
                envelopes: rawEnvelopes,
                watchAccelerationChunks: accelerationChunks,
                createdAt: latestCreatedAt
            )
        )
    }
}

private struct PlanMonthlyArchivePreparationInput: Sendable {
    let payload: PlanCloudBackupPayload
    let monthKey: String
    let accountIdentifier: String
    let pinKeyData: Data
    let accountKeyData: Data?
    let date: Date
    let generationID: UUID?
    let hasRawSensorArchive: Bool?
    let previousArchive: PlanMonthlyArchive?
}

private struct PlanMonthlyArchiveIdentity: Equatable, Sendable {
    let monthKey: String
    let accountIdentifier: String
    let createdAt: Date
    let payloadDigest: Data
    let generationID: UUID?
    let hasRawSensorArchive: Bool?

    init(_ archive: PlanMonthlyArchive) {
        monthKey = archive.monthKey
        accountIdentifier = archive.accountIdentifier
        createdAt = archive.createdAt
        payloadDigest = archive.payloadDigest
        generationID = archive.generationID
        hasRawSensorArchive = archive.hasRawSensorArchive
    }
}

private enum PlanArchiveCrypto {
    static func randomKey() throws -> Data {
        var key = Data(repeating: 0, count: 32)
        let status = key.withUnsafeMutableBytes { buffer -> Int32 in
            guard let baseAddress = buffer.baseAddress else {
                return errSecParam
            }
            return SecRandomCopyBytes(kSecRandomDefault, 32, baseAddress)
        }
        guard status == errSecSuccess else {
            throw PlanSecurityError.invalidArchive
        }
        return key
    }
}

private enum PlanMonthlyArchivePreparation {
    static func prepare(
        _ input: PlanMonthlyArchivePreparationInput
    ) throws -> PlanMonthlyArchive {
        let payload: PlanCloudBackupPayload
        let inheritedGenerationID: UUID?
        if let previousArchive = input.previousArchive {
            guard previousArchive.accountIdentifier == input.accountIdentifier else {
                throw PlanSecurityError.accountMismatch
            }
            let existing: PlanCloudBackupPayload?
            do {
                existing = try previousArchive.decodedPayload(
                    pinKeyData: input.pinKeyData
                )
            } catch {
                if let accountKeyData = input.accountKeyData,
                   let opened = try? previousArchive.decodedPayload(
                       accountKeyData: accountKeyData
                   ) {
                    existing = opened
                } else {
                    // 기기 이전(예: iPhone 14→18)으로 이번 기기의 PIN·계정 키가
                    // 기존 달 아카이브를 봉인한 키와 달라 복호할 수 없다. 예전에는
                    // 여기서 invalidArchive 를 던져 백업이 매번 실패했다. 병합을
                    // 건너뛰고 이번 기기 데이터를 이번 기기 키로 새로 봉인해 저장한다
                    // (옛 아카이브 내용은 병합되지 않지만 삭제 요청이 아니며,
                    //  같은 키 문제 계열의 HealthKit 미이관과 동일하게 다룬다).
                    existing = nil
                }
            }
            if let existing {
                payload = PlanCloudBackupPayload(
                    snapshot: CloudSnapshotRecoveryEngine.merge(
                        local: input.payload.snapshot,
                        remote: existing.snapshot
                    ),
                    routePoints: PlanBackupRoutePointReducer.merging(
                        existing: existing.routePoints,
                        incoming: input.payload.routePoints
                    ),
                    appLog: input.payload.appLog ?? existing.appLog
                )
                inheritedGenerationID = previousArchive.generationID
            } else {
                // 복호 불가 → 병합 없이 새 generation 으로 재시작.
                payload = input.payload
                inheritedGenerationID = nil
            }
        } else {
            payload = input.payload
            inheritedGenerationID = nil
        }

        let encoded = try JSONEncoder.taptionPlan.encode(payload)
        guard encoded.count
            <= TaptionSnapshotCompression.maximumRawSensorUncompressedSize
        else {
            throw TaptionSnapshotCompressionError.uncompressedSizeExceedsLimit(
                actual: UInt64(encoded.count),
                maximum: TaptionSnapshotCompression.maximumRawSensorUncompressedSize
            )
        }
        let compressed = TaptionSnapshotCompression.encode(encoded)
        let archiveKey = try PlanArchiveCrypto.randomKey()
        let archiveGenerationID = input.generationID ?? inheritedGenerationID
        let authenticatedData = try PlanArchiveMetadata.authenticatedData(
            version: PlanMonthlyArchive.currentVersion,
            monthKey: input.monthKey,
            accountIdentifier: input.accountIdentifier,
            createdAt: input.date,
            generationID: archiveGenerationID,
            hasRawSensorArchive: input.hasRawSensorArchive
        )
        let encryptedPayload = try AES.GCM.seal(
            compressed,
            using: SymmetricKey(data: archiveKey),
            authenticating: authenticatedData
        ).combined ?? { throw PlanSecurityError.invalidArchive }()
        let wrappedPayloadKey = try AES.GCM.seal(
            archiveKey,
            using: SymmetricKey(data: input.pinKeyData)
        ).combined ?? { throw PlanSecurityError.invalidArchive }()
        let accountWrappedPayloadKey: Data
        if let accountKeyData = input.accountKeyData {
            guard accountKeyData.count == 32 else {
                throw PlanSecurityError.accountUnavailable
            }
            accountWrappedPayloadKey = try AES.GCM.seal(
                archiveKey,
                using: SymmetricKey(data: accountKeyData)
            ).combined ?? { throw PlanSecurityError.invalidArchive }()
        } else {
            accountWrappedPayloadKey = Data()
        }
        return PlanMonthlyArchive(
            monthKey: input.monthKey,
            accountIdentifier: input.accountIdentifier,
            encryptedPayload: encryptedPayload,
            wrappedPayloadKey: wrappedPayloadKey,
            accountWrappedPayloadKey: accountWrappedPayloadKey,
            createdAt: input.date,
            generationID: archiveGenerationID,
            hasRawSensorArchive: input.hasRawSensorArchive
        )
    }
}

@MainActor
final class PlanSecurityBackupService {
    private let credentialStore: PlanCredentialStore
    private let backupStore: PlanCloudBackupStore
    private let rawSensorBackupStore: PlanCloudRawSensorBackupStore
    private let accountKeyProvider: PlanCloudAccountKeyProvider
    private let cloudRecoveryKeyProvider: PlanCloudRecoveryKeyProvider?
    private let biometricAuthenticator: PlanLocalBiometricAuthenticator
    private let settingsDefaults: UserDefaults
    private let settingsKey = "TaptionPlan.security.app-lock-settings-v1"
    private let latestSuccessfulBackupDateKey =
        "TaptionPlan.security.latest-successful-backup-date-v1"
    private var verifier: PlanPINVerifier?
    private var preparationRevision: UInt64 = 0
    private var failedAttempts = 0
    private var blockedUntil: Date?
    private(set) var settings: PlanAppLockSettings
    private(set) var state: PlanAppLockState = .unlocked
    private(set) var latestSuccessfulBackupDate: Date?

    private struct RestorePreparationFence {
        let preparationRevision: UInt64
        let verifier: PlanPINVerifier
        let dataGeneration: UInt64
    }

    init(
        credentialStore: PlanCredentialStore = KeychainPlanCredentialStore(),
        backupStore: PlanCloudBackupStore,
        rawSensorBackupStore: PlanCloudRawSensorBackupStore =
            InMemoryPlanCloudRawSensorBackupStore(),
        accountKeyProvider: PlanCloudAccountKeyProvider = InMemoryPlanCloudAccountKeyProvider(),
        cloudRecoveryKeyProvider: PlanCloudRecoveryKeyProvider? = nil,
        biometricAuthenticator: PlanLocalBiometricAuthenticator = SystemPlanLocalBiometricAuthenticator(),
        settingsDefaults: UserDefaults = .standard
    ) {
        self.credentialStore = credentialStore
        self.backupStore = backupStore
        self.rawSensorBackupStore = rawSensorBackupStore
        self.accountKeyProvider = accountKeyProvider
        self.cloudRecoveryKeyProvider = cloudRecoveryKeyProvider
        self.biometricAuthenticator = biometricAuthenticator
        self.settingsDefaults = settingsDefaults
        if let data = try? credentialStore.read() {
            if let record = try? JSONDecoder().decode(PlanCredentialRecord.self, from: data) {
                self.verifier = record.verifier
                self.failedAttempts = max(0, record.failedAttempts)
                self.blockedUntil = record.blockedUntil
            } else {
                self.verifier = try? JSONDecoder().decode(PlanPINVerifier.self, from: data)
            }
        }
        if let data = settingsDefaults.data(forKey: settingsKey),
           let value = try? JSONDecoder().decode(PlanAppLockSettings.self, from: data) {
            self.settings = value
        } else {
            self.settings = PlanAppLockSettings()
        }
        self.latestSuccessfulBackupDate = settingsDefaults.object(
            forKey: latestSuccessfulBackupDateKey
        ) as? Date
    }

    static func applicationSupport(fileManager: FileManager = .default) throws -> PlanSecurityBackupService {
        let backupStore = UbiquitousPlanCloudBackupStore(fileManager: fileManager)
        let rawSensorBackupStore = UbiquitousPlanCloudRawSensorBackupStore(
            fileManager: fileManager
        )
#if targetEnvironment(simulator)
        return PlanSecurityBackupService(
            backupStore: backupStore,
            rawSensorBackupStore: rawSensorBackupStore
        )
#else
        return PlanSecurityBackupService(
            backupStore: backupStore,
            rawSensorBackupStore: rawSensorBackupStore,
            cloudRecoveryKeyProvider: CloudKitPlanCloudRecoveryKeyProvider()
        )
#endif
    }

    var hasPIN: Bool { verifier != nil }
    var status: PlanSecurityStatus {
        .init(
            settings: settings,
            state: state,
            hasPIN: hasPIN,
            failedAttempts: failedAttempts,
            retryAfter: blockedUntil,
            latestSuccessfulBackupDate: latestSuccessfulBackupDate
        )
    }

    func setPIN(_ pin: String) throws {
        let value = try PlanPINVerifier(pin: pin)
        let data = try JSONEncoder().encode(
            PlanCredentialRecord(
                verifier: value,
                failedAttempts: 0,
                blockedUntil: nil
            )
        )
        try credentialStore.write(data)
        verifier = value
        preparationRevision &+= 1
        failedAttempts = 0
        blockedUntil = nil
    }

    func deleteAllBackups() throws {
        preparationRevision &+= 1
        var firstError: Error?
        do {
            try backupStore.deleteAll()
        } catch {
            firstError = error
        }
        do {
            try rawSensorBackupStore.deleteAll()
        } catch {
            if firstError == nil { firstError = error }
        }
        if let firstError { throw firstError }
        latestSuccessfulBackupDate = nil
        persistLatestSuccessfulBackupDate()
    }

    private func checkRestorePreparation(
        _ fence: RestorePreparationFence
    ) throws {
        guard !Task.isCancelled,
              preparationRevision == fence.preparationRevision,
              verifier == fence.verifier,
              TaptionDataDeletionFence.allows(
                  generation: fence.dataGeneration
              ) else {
            throw CancellationError()
        }
    }

    func verifyPIN(_ pin: String, now: Date = .now) throws {
        if let blockedUntil, blockedUntil > now { throw PlanSecurityError.tooManyAttempts(retryAfter: blockedUntil.timeIntervalSince(now)) }
        guard let verifier, verifier.matches(pin) else {
            failedAttempts += 1
            if failedAttempts >= 5 { blockedUntil = now.addingTimeInterval(30) }
            try persistCredentialState()
            throw PlanSecurityError.invalidPIN
        }
        failedAttempts = 0
        blockedUntil = nil
        try persistCredentialState()
        state = .unlocked
    }

    private func persistCredentialState() throws {
        guard let verifier else { return }
        try credentialStore.write(
            JSONEncoder().encode(
                PlanCredentialRecord(
                    verifier: verifier,
                    failedAttempts: failedAttempts,
                    blockedUntil: blockedUntil
                )
            )
        )
    }

    func setAppLockSettings(_ value: PlanAppLockSettings) throws {
        if (value.lockOnLaunch || value.lockOnForeground || value.cloudBackupEnabled)
            && !hasPIN {
            throw PlanSecurityError.pinRequiredForCloudBackup
        }
        settings = value
        settingsDefaults.set(try? JSONEncoder().encode(value), forKey: settingsKey)
    }

    func handleLaunch() { if settings.lockOnLaunch { state = .locked(reason: .launch) } }
    func handleForeground() { if settings.lockOnForeground { state = .locked(reason: .foreground) } }

    func unlock(withPIN pin: String) throws { try verifyPIN(pin) }

    func unlockWithBiometrics() async throws {
        guard settings.biometricUnlockEnabled else { throw PlanSecurityError.biometricUnavailable }
        let reason = AppLanguagePreference.text(
            korean: "Taption Plan 잠금 해제",
            english: "Unlock Taption Plan"
        )
        guard await biometricAuthenticator.authenticate(reason: reason) else {
            throw PlanSecurityError.biometricRejected
        }
        state = .unlocked
    }

    func saveMonthlyArchive(_ snapshot: TaptionDataSnapshot, accountIdentifier: String, date: Date = .now) throws -> PlanMonthlyArchive {
        try saveMonthlyArchive(
            PlanCloudBackupPayload(snapshot: snapshot),
            accountIdentifier: accountIdentifier,
            date: date
        )
    }

    func saveMonthlyArchive(
        _ payload: PlanCloudBackupPayload,
        accountIdentifier: String,
        date: Date = .now
    ) throws -> PlanMonthlyArchive {
        guard hasPIN else { throw PlanSecurityError.pinRequiredForCloudBackup }
        guard !accountIdentifier.isEmpty else { throw PlanSecurityError.accountUnavailable }
        let accountKey = try accountKeyProvider.key(for: accountIdentifier)
        return try saveMonthlyArchive(
            payload,
            accountIdentifier: accountIdentifier,
            accountKey: accountKey,
            date: date
        )
    }

    func saveMonthlyArchive(
        _ snapshot: TaptionDataSnapshot,
        date: Date = .now
    ) async throws -> PlanMonthlyArchive {
        try await saveMonthlyArchive(
            PlanCloudBackupPayload(snapshot: snapshot),
            date: date
        )
    }

    func saveMonthlyArchive(
        _ payload: PlanCloudBackupPayload,
        date: Date = .now,
        dataGeneration: UInt64? = nil
    ) async throws -> PlanMonthlyArchive {
        guard !Task.isCancelled else { throw CancellationError() }
        guard hasPIN else { throw PlanSecurityError.pinRequiredForCloudBackup }
        guard let cloudRecoveryKeyProvider else {
            throw PlanSecurityError.accountUnavailable
        }
        guard let verifier else {
            throw PlanSecurityError.pinRequiredForCloudBackup
        }
        let capturedPreparationRevision = preparationRevision
        let capturedVerifier = verifier
        let capturedDataGeneration = dataGeneration
            ?? TaptionDataDeletionFence.currentGeneration()
        guard TaptionDataDeletionFence.allows(
            generation: capturedDataGeneration
        ) else {
            throw CancellationError()
        }
        let accountKey = try await cloudRecoveryKeyProvider.key()
        guard !Task.isCancelled,
              preparationRevision == capturedPreparationRevision,
              self.verifier == capturedVerifier,
              TaptionDataDeletionFence.allows(
                  generation: capturedDataGeneration
              ) else {
            throw CancellationError()
        }
        let accountIdentifier =
            CloudKitPlanCloudRecoveryKeyProvider.privateAccountScope
        let monthKey = PlanArchiveSchedule.monthKey(for: date)
        let previousArchive = try monthlyArchive(
            for: monthKey,
            accountIdentifier: accountIdentifier
        )
        let hasRawSensorArchive = try rawSensorArchivePresence(
            for: previousArchive,
            monthKey: monthKey,
            accountIdentifier: accountIdentifier
        )
        let input = PlanMonthlyArchivePreparationInput(
            payload: payload,
            monthKey: monthKey,
            accountIdentifier: accountIdentifier,
            pinKeyData: capturedVerifier.keyMaterial,
            accountKeyData: accountKey,
            date: date,
            generationID: nil,
            hasRawSensorArchive: hasRawSensorArchive,
            previousArchive: previousArchive
        )
        let preparationTask = Task.detached(priority: .utility) {
            guard !Task.isCancelled else { throw CancellationError() }
            let archive = try PlanMonthlyArchivePreparation.prepare(input)
            guard !Task.isCancelled else { throw CancellationError() }
            return archive
        }
        let prepared: PlanMonthlyArchive
        do {
            prepared = try await withTaskCancellationHandler(operation: {
                try await preparationTask.value
            }, onCancel: {
                preparationTask.cancel()
            })
        } catch {
            preparationTask.cancel()
            throw error
        }
        guard !Task.isCancelled else { throw CancellationError() }
        return try commitMonthlyArchive(
            prepared,
            accountIdentifier: accountIdentifier,
            expectedPreviousArchive: previousArchive,
            preparationRevision: capturedPreparationRevision,
            dataGeneration: capturedDataGeneration
        )
    }

    func saveMonthlyGeneration(
        _ payload: PlanCloudBackupPayload,
        rawSensorPayload: PlanCloudRawSensorPayload?,
        date: Date = .now,
        dataGeneration: UInt64? = nil
    ) async throws -> PlanCloudBackupGeneration {
        guard let capturedVerifier = verifier else {
            throw PlanSecurityError.pinRequiredForCloudBackup
        }
        guard let cloudRecoveryKeyProvider else {
            throw PlanSecurityError.accountUnavailable
        }
        let capturedPreparationRevision = preparationRevision
        let capturedDataGeneration = dataGeneration
            ?? TaptionDataDeletionFence.currentGeneration()
        guard TaptionDataDeletionFence.allows(
            generation: capturedDataGeneration
        ) else {
            throw CancellationError()
        }
        let accountKey = try await cloudRecoveryKeyProvider.key()
        guard !Task.isCancelled,
              preparationRevision == capturedPreparationRevision,
              verifier == capturedVerifier,
              TaptionDataDeletionFence.allows(
                  generation: capturedDataGeneration
              ) else {
            throw CancellationError()
        }
        let accountIdentifier =
            CloudKitPlanCloudRecoveryKeyProvider.privateAccountScope
        let monthKey = PlanArchiveSchedule.monthKey(for: date)
        let previousSnapshot = try monthlyArchive(
            for: monthKey,
            accountIdentifier: accountIdentifier
        )
        let hasCommittedRawArchive: Bool
        if rawSensorPayload?.isEmpty != false {
            let existing: PlanRawSensorMonthlyArchive?
            if previousSnapshot?.hasRawSensorArchive == false {
                existing = nil
            } else {
                existing = try rawSensorBackupStore.load(
                    monthKey: monthKey,
                    generationID: previousSnapshot?.generationID
                )
            }
            if let existing,
               existing.accountIdentifier != accountIdentifier {
                throw PlanSecurityError.accountMismatch
            }
            hasCommittedRawArchive = existing.map {
                Self.isCommitted($0, snapshot: previousSnapshot)
            } ?? false
            if previousSnapshot?.hasRawSensorArchive == true,
               !hasCommittedRawArchive {
                throw PlanSecurityError.accountUnavailable
            }
        } else {
            hasCommittedRawArchive = false
        }
        let generationID = UUID()
        let rawSave: PlanRawSensorMonthlyArchive?
        if let rawSensorPayload, !rawSensorPayload.isEmpty {
            rawSave = try saveRawSensorArchive(
                rawSensorPayload,
                accountIdentifier: accountIdentifier,
                accountKey: accountKey,
                date: date,
                generationID: generationID,
                dataGeneration: capturedDataGeneration
            )
        } else if hasCommittedRawArchive {
            rawSave = try saveRawSensorArchive(
                PlanCloudRawSensorPayload(
                    monthKey: monthKey,
                    sensorReadings: [],
                    envelopes: [],
                    watchAccelerationChunks: [],
                    createdAt: date
                ),
                accountIdentifier: accountIdentifier,
                accountKey: accountKey,
                date: date,
                generationID: generationID,
                dataGeneration: capturedDataGeneration
            )
        } else {
            rawSave = nil
        }
        let snapshotArchive: PlanMonthlyArchive
        let hasRawSensorArchive: Bool?
        if rawSave != nil {
            hasRawSensorArchive = true
        } else if let previousSnapshot {
            hasRawSensorArchive = previousSnapshot.hasRawSensorArchive
        } else {
            hasRawSensorArchive = false
        }
        do {
            snapshotArchive = try saveMonthlyArchive(
                payload,
                accountIdentifier: accountIdentifier,
                accountKey: accountKey,
                date: date,
                recordsSuccessfulBackup: false,
                generationID: generationID,
                hasRawSensorArchive: hasRawSensorArchive,
                preparationRevision: capturedPreparationRevision,
                dataGeneration: capturedDataGeneration
            )
        } catch {
            if let rawSave {
                let path = PlanCloudRawSensorBackupPath(
                    monthKey: rawSave.monthKey,
                    generationID: rawSave.generationID
                )
                if !TaptionDataDeletionFence.allows(
                    generation: capturedDataGeneration
                ) {
                    try? rawSensorBackupStore.delete(at: path)
                } else {
                    let snapshotReferencesRaw: Bool?
                    do {
                        let currentSnapshot = try monthlyArchive(
                            for: rawSave.monthKey,
                            accountIdentifier: accountIdentifier
                        )
                        snapshotReferencesRaw = Self.isCommitted(
                            rawSave,
                            snapshot: currentSnapshot
                        )
                    } catch {
                        snapshotReferencesRaw = nil
                    }
                    if snapshotReferencesRaw == false {
                        try? rawSensorBackupStore.delete(at: path)
                    }
                }
            }
            throw error
        }
        recordSuccessfulBackup(at: date)
        return PlanCloudBackupGeneration(
            snapshot: snapshotArchive,
            rawSensors: rawSave,
            generationID: generationID
        )
    }

    func saveRawSensorArchive(
        _ payload: PlanCloudRawSensorPayload,
        accountIdentifier: String,
        date: Date = .now
    ) throws -> PlanRawSensorMonthlyArchive {
        guard hasPIN else { throw PlanSecurityError.pinRequiredForCloudBackup }
        guard !accountIdentifier.isEmpty else {
            throw PlanSecurityError.accountUnavailable
        }
        let dataGeneration = TaptionDataDeletionFence.currentGeneration()
        guard TaptionDataDeletionFence.allows(generation: dataGeneration) else {
            throw CancellationError()
        }
        let accountKey = try accountKeyProvider.key(for: accountIdentifier)
        guard TaptionDataDeletionFence.allows(generation: dataGeneration) else {
            throw CancellationError()
        }
        return try saveRawSensorArchive(
            payload,
            accountIdentifier: accountIdentifier,
            accountKey: accountKey,
            date: date,
            dataGeneration: dataGeneration
        )
    }

    func saveRawSensorArchive(
        _ payload: PlanCloudRawSensorPayload,
        date: Date = .now
    ) async throws -> PlanRawSensorMonthlyArchive {
        guard let capturedVerifier = verifier else {
            throw PlanSecurityError.pinRequiredForCloudBackup
        }
        guard let cloudRecoveryKeyProvider else {
            throw PlanSecurityError.accountUnavailable
        }
        let capturedPreparationRevision = preparationRevision
        let capturedDataGeneration = TaptionDataDeletionFence.currentGeneration()
        guard TaptionDataDeletionFence.allows(
            generation: capturedDataGeneration
        ) else {
            throw CancellationError()
        }
        let accountKey = try await cloudRecoveryKeyProvider.key()
        guard !Task.isCancelled,
              preparationRevision == capturedPreparationRevision,
              verifier == capturedVerifier,
              TaptionDataDeletionFence.allows(
                  generation: capturedDataGeneration
              ) else {
            throw CancellationError()
        }
        return try saveRawSensorArchive(
            payload,
            accountIdentifier: CloudKitPlanCloudRecoveryKeyProvider.privateAccountScope,
            accountKey: accountKey,
            date: date,
            dataGeneration: capturedDataGeneration
        )
    }

    private func saveMonthlyArchive(
        _ payload: PlanCloudBackupPayload,
        accountIdentifier: String,
        accountKey: Data?,
        date: Date,
        recordsSuccessfulBackup: Bool = true,
        generationID: UUID? = nil,
        hasRawSensorArchive: Bool? = nil,
        preparationRevision: UInt64? = nil,
        dataGeneration: UInt64? = nil
    ) throws -> PlanMonthlyArchive {
        guard let verifier else {
            throw PlanSecurityError.pinRequiredForCloudBackup
        }
        let monthKey = PlanArchiveSchedule.monthKey(for: date)
        let previousArchive = try monthlyArchive(
            for: monthKey,
            accountIdentifier: accountIdentifier
        )
        let resolvedRawSensorPresence: Bool?
        if let hasRawSensorArchive {
            resolvedRawSensorPresence = hasRawSensorArchive
        } else {
            resolvedRawSensorPresence = try rawSensorArchivePresence(
                for: previousArchive,
                monthKey: monthKey,
                accountIdentifier: accountIdentifier
            )
        }
        let prepared = try PlanMonthlyArchivePreparation.prepare(
            PlanMonthlyArchivePreparationInput(
                payload: payload,
                monthKey: monthKey,
                accountIdentifier: accountIdentifier,
                pinKeyData: verifier.keyMaterial,
                accountKeyData: accountKey,
                date: date,
                generationID: generationID,
                hasRawSensorArchive: resolvedRawSensorPresence,
                previousArchive: previousArchive
            )
        )
        return try commitMonthlyArchive(
            prepared,
            accountIdentifier: accountIdentifier,
            expectedPreviousArchive: previousArchive,
            preparationRevision: preparationRevision,
            dataGeneration: dataGeneration,
            recordsSuccessfulBackup: recordsSuccessfulBackup
        )
    }

    private func rawSensorArchivePresence(
        for snapshot: PlanMonthlyArchive?,
        monthKey: String,
        accountIdentifier: String
    ) throws -> Bool? {
        guard let snapshot else {
            guard let archive = try rawSensorBackupStore.load(
                monthKey: monthKey,
                generationID: nil
            ) else {
                return false
            }
            guard archive.accountIdentifier == accountIdentifier else {
                throw PlanSecurityError.accountMismatch
            }
            guard Self.isCommitted(archive, snapshot: nil) else {
                throw PlanSecurityError.invalidArchive
            }
            return true
        }
        if let presence = snapshot.hasRawSensorArchive {
            if presence {
                guard let archive = try rawSensorBackupStore.load(
                    monthKey: snapshot.monthKey,
                    generationID: snapshot.generationID
                ) else {
                    throw PlanSecurityError.accountUnavailable
                }
                guard archive.accountIdentifier == snapshot.accountIdentifier,
                      Self.isCommitted(archive, snapshot: snapshot) else {
                    throw PlanSecurityError.invalidArchive
                }
            }
            return presence
        }
        guard let archive = try rawSensorBackupStore.load(
            monthKey: snapshot.monthKey,
            generationID: snapshot.generationID
        ) else {
            return nil
        }
        guard archive.accountIdentifier == snapshot.accountIdentifier else {
            throw PlanSecurityError.accountMismatch
        }
        return Self.isCommitted(archive, snapshot: snapshot) ? true : nil
    }

    private func monthlyArchive(
        for monthKey: String,
        accountIdentifier: String
    ) throws -> PlanMonthlyArchive? {
        guard let archive = try backupStore.allArchives()
            .filter({ $0.monthKey == monthKey })
            .max(by: Self.archivePrecedes) else {
            return nil
        }
        guard archive.accountIdentifier == accountIdentifier else {
            throw PlanSecurityError.accountMismatch
        }
        return archive
    }

    private func commitMonthlyArchive(
        _ archive: PlanMonthlyArchive,
        accountIdentifier: String,
        expectedPreviousArchive: PlanMonthlyArchive?,
        preparationRevision: UInt64? = nil,
        dataGeneration: UInt64? = nil,
        recordsSuccessfulBackup: Bool = true
    ) throws -> PlanMonthlyArchive {
        if let preparationRevision,
           self.preparationRevision != preparationRevision {
            throw CancellationError()
        }
        if let dataGeneration,
           !TaptionDataDeletionFence.allows(generation: dataGeneration) {
            throw CancellationError()
        }
        let currentArchive = try monthlyArchive(
            for: archive.monthKey,
            accountIdentifier: accountIdentifier
        )
        guard currentArchive.map(PlanMonthlyArchiveIdentity.init)
            == expectedPreviousArchive.map(PlanMonthlyArchiveIdentity.init) else {
            throw CancellationError()
        }
        if Task.isCancelled
            || (preparationRevision.map {
                self.preparationRevision != $0
            } ?? false)
            || (dataGeneration.map {
                !TaptionDataDeletionFence.allows(generation: $0)
            } ?? false) {
            throw CancellationError()
        }
        let path = PlanCloudBackupPath(monthKey: archive.monthKey)
        try backupStore.save(archive, at: path)
        let deletionAdvanced = dataGeneration.map {
            !TaptionDataDeletionFence.allows(generation: $0)
        } ?? false
        if Task.isCancelled
            || preparationRevision.map({ self.preparationRevision != $0 }) == true
            || deletionAdvanced {
            if let current = try? monthlyArchive(
                for: archive.monthKey,
                accountIdentifier: accountIdentifier
            ), PlanMonthlyArchiveIdentity(current)
                == PlanMonthlyArchiveIdentity(archive) {
                if !deletionAdvanced, let expectedPreviousArchive {
                    try? backupStore.save(expectedPreviousArchive, at: path)
                    if let dataGeneration,
                       !TaptionDataDeletionFence.allows(
                           generation: dataGeneration
                       ),
                       let restoredArchive = try? monthlyArchive(
                           for: archive.monthKey,
                           accountIdentifier: accountIdentifier
                       ) {
                        let restoredIdentity = PlanMonthlyArchiveIdentity(
                            restoredArchive
                        )
                        if restoredIdentity
                            == PlanMonthlyArchiveIdentity(expectedPreviousArchive)
                            || restoredIdentity == PlanMonthlyArchiveIdentity(archive) {
                            try? backupStore.delete(at: path)
                        }
                    }
                } else {
                    try? backupStore.delete(at: path)
                }
            }
            throw CancellationError()
        }
        if recordsSuccessfulBackup {
            recordSuccessfulBackup(at: archive.createdAt)
        }
        return archive
    }

    private func saveRawSensorArchive(
        _ payload: PlanCloudRawSensorPayload,
        accountIdentifier: String,
        accountKey: Data?,
        date: Date,
        generationID: UUID? = nil,
        dataGeneration: UInt64
    ) throws -> PlanRawSensorMonthlyArchive {
        guard let verifier else {
            throw PlanSecurityError.pinRequiredForCloudBackup
        }
        let monthKey = PlanArchiveSchedule.monthKey(for: date)
        let normalizedPayload = PlanCloudRawSensorPayload(
            monthKey: monthKey,
            sensorReadings: payload.sensorReadings,
            envelopes: payload.envelopes,
            watchAccelerationChunks: payload.watchAccelerationChunks ?? [],
            createdAt: payload.createdAt
        )
        let payload = try payloadPreservingCurrentMonthRawData(
            normalizedPayload,
            monthKey: monthKey,
            accountIdentifier: accountIdentifier,
            pinKeyData: verifier.keyMaterial,
            accountKeyData: accountKey
        )
        let encoded = try JSONEncoder.taptionPlan.encode(payload)
        guard encoded.count
            <= TaptionSnapshotCompression.maximumRawSensorUncompressedSize
        else {
            TaptionPlanDiagnosticsLogger.shared.record(
                "raw_sensor_archive_encode_rejected",
                level: .error,
                fields: [
                    "month_key": monthKey,
                    "encoded_bytes": String(encoded.count),
                    "maximum_bytes": String(
                        TaptionSnapshotCompression
                            .maximumRawSensorUncompressedSize
                    ),
                ]
            )
            throw PlanSecurityError.invalidArchive
        }
        let compressed = TaptionSnapshotCompression.encode(
            encoded,
            maximumSize: TaptionSnapshotCompression.maximumRawSensorUncompressedSize
        )
        let archiveKey = try PlanArchiveCrypto.randomKey()
        let authenticatedData = try PlanArchiveMetadata.authenticatedData(
            version: PlanRawSensorMonthlyArchive.currentVersion,
            monthKey: monthKey,
            accountIdentifier: accountIdentifier,
            createdAt: date,
            generationID: generationID
        )
        let encryptedPayload = try AES.GCM.seal(
            compressed,
            using: SymmetricKey(data: archiveKey),
            authenticating: authenticatedData
        ).combined ?? { throw PlanSecurityError.invalidArchive }()
        let pinKey = SymmetricKey(data: verifier.keyMaterial)
        let wrappedPayloadKey = try AES.GCM.seal(
            archiveKey,
            using: pinKey
        ).combined ?? { throw PlanSecurityError.invalidArchive }()
        let accountWrappedPayloadKey: Data
        if let accountKey {
            guard accountKey.count == 32 else {
                throw PlanSecurityError.accountUnavailable
            }
            accountWrappedPayloadKey = try AES.GCM.seal(
                archiveKey,
                using: SymmetricKey(data: accountKey)
            ).combined ?? { throw PlanSecurityError.invalidArchive }()
        } else {
            accountWrappedPayloadKey = Data()
        }
        let archive = PlanRawSensorMonthlyArchive(
            monthKey: monthKey,
            accountIdentifier: accountIdentifier,
            encryptedPayload: encryptedPayload,
            wrappedPayloadKey: wrappedPayloadKey,
            accountWrappedPayloadKey: accountWrappedPayloadKey,
            createdAt: date,
            generationID: generationID
        )
        let path = PlanCloudRawSensorBackupPath(
            monthKey: monthKey,
            generationID: generationID
        )
        guard !Task.isCancelled,
              TaptionDataDeletionFence.allows(generation: dataGeneration) else {
            throw CancellationError()
        }
        try rawSensorBackupStore.save(archive, at: path)
        let deletionAdvanced = !TaptionDataDeletionFence.allows(
            generation: dataGeneration
        )
        guard !Task.isCancelled, !deletionAdvanced else {
            // Ordinary cancellation preserves merged legacy data; deletion does not.
            if generationID != nil || deletionAdvanced {
                try? rawSensorBackupStore.delete(at: path)
            }
            throw CancellationError()
        }
        return archive
    }

    private func recordSuccessfulBackup(at date: Date) {
        guard latestSuccessfulBackupDate == nil || date > latestSuccessfulBackupDate! else {
            return
        }
        latestSuccessfulBackupDate = date
        persistLatestSuccessfulBackupDate()
    }

    private func persistLatestSuccessfulBackupDate() {
        if let latestSuccessfulBackupDate {
            settingsDefaults.set(latestSuccessfulBackupDate, forKey: latestSuccessfulBackupDateKey)
        } else {
            settingsDefaults.removeObject(forKey: latestSuccessfulBackupDateKey)
        }
    }

    private func payloadPreservingCurrentMonthRawData(
        _ incoming: PlanCloudRawSensorPayload,
        monthKey: String,
        accountIdentifier: String,
        pinKeyData: Data,
        accountKeyData: Data?
    ) throws -> PlanCloudRawSensorPayload {
        let snapshot = try monthlyArchive(
            for: monthKey,
            accountIdentifier: accountIdentifier
        )
        let existingArchive = try rawSensorBackupStore.load(
            monthKey: monthKey,
            generationID: snapshot?.generationID
        )
        guard existingArchive != nil
                || snapshot?.hasRawSensorArchive != true else {
            throw PlanSecurityError.accountUnavailable
        }
        guard let existingArchive else {
            return incoming
        }
        guard existingArchive.accountIdentifier == accountIdentifier else {
            throw PlanSecurityError.accountMismatch
        }

        let existing: PlanCloudRawSensorPayload
        do {
            existing = try existingArchive.decodedPayload(
                pinKeyData: pinKeyData
            )
        } catch {
            guard let accountKeyData else { throw error }
            existing = try existingArchive.decodedPayload(
                accountKeyData: accountKeyData
            )
        }

        var readings = PlanCloudRawSensorPayloadBuffer<SensorReading>()
        try readings.append(contentsOf: existing.sensorReadings)
        try readings.append(contentsOf: incoming.sensorReadings)
        var envelopes = PlanCloudRawSensorPayloadBuffer<RawDeviceDataEnvelope>()
        try envelopes.append(contentsOf: existing.envelopes)
        try envelopes.append(contentsOf: incoming.envelopes)
        var chunks = PlanCloudRawSensorPayloadBuffer<TaptionWatchAccelerationChunk>()
        try chunks.append(contentsOf: existing.watchAccelerationChunks ?? [])
        try chunks.append(contentsOf: incoming.watchAccelerationChunks ?? [])
        return PlanCloudRawSensorPayload(
            monthKey: monthKey,
            sensorReadings: readings.takeValues(),
            envelopes: envelopes.takeValues(),
            watchAccelerationChunks: chunks.takeValues(),
            createdAt: incoming.createdAt
        )
    }

    func loadLatestArchive(accountIdentifier: String) throws -> TaptionDataSnapshot {
        try loadLatestBackup(accountIdentifier: accountIdentifier).snapshot
    }

    func loadLatestBackup(
        accountIdentifier: String
    ) throws -> PlanCloudBackupPayload {
        guard hasPIN else { throw PlanSecurityError.pinRequiredForCloudBackup }
        guard let verifier else { throw PlanSecurityError.pinRequiredForCloudBackup }
        return try loadLatestBackup(
            accountIdentifier: accountIdentifier,
            pinKeyData: verifier.keyMaterial
        )
    }

    func loadLatestBackupPackage(
        accountIdentifier: String,
        rawSensorRestoreMaximumBytes: Int =
            PlanCloudArchiveRestoreByteBudget.defaultMaximumBytes
    ) async throws -> PlanCloudBackupRestorePackage {
        guard hasPIN else { throw PlanSecurityError.pinRequiredForCloudBackup }
        guard let capturedVerifier = verifier else {
            throw PlanSecurityError.pinRequiredForCloudBackup
        }
        let preparationFence = RestorePreparationFence(
            preparationRevision: preparationRevision,
            verifier: capturedVerifier,
            dataGeneration: TaptionDataDeletionFence.currentGeneration()
        )
        try checkRestorePreparation(preparationFence)
        let snapshotArchives = try selectedSnapshotArchives(
            accountIdentifier: accountIdentifier
        )
        let backup = try loadLatestBackup(
            from: snapshotArchives,
            accountIdentifier: accountIdentifier,
            pinKeyData: capturedVerifier.keyMaterial
        )
        try checkRestorePreparation(preparationFence)
        let rawSensorState = try await loadRawSensorRestoreStateOffMain(
            accountIdentifier: accountIdentifier,
            pinKeyData: capturedVerifier.keyMaterial,
            snapshotArchives: snapshotArchives,
            preparationFence: preparationFence,
            maximumBytes: rawSensorRestoreMaximumBytes
        )
        try checkRestorePreparation(preparationFence)
        return PlanCloudBackupRestorePackage(
            backup: backup,
            rawSensorState: rawSensorState
        )
    }

    func loadLatestArchive() async throws -> TaptionDataSnapshot {
        try await loadLatestBackup().snapshot
    }

    func loadLatestBackup() async throws -> PlanCloudBackupPayload {
        guard !Task.isCancelled else { throw CancellationError() }
        guard let capturedVerifier = verifier else {
            throw PlanSecurityError.pinRequiredForCloudBackup
        }
        let capturedPreparationRevision = preparationRevision
        let capturedDataGeneration = TaptionDataDeletionFence.currentGeneration()
        guard TaptionDataDeletionFence.allows(
            generation: capturedDataGeneration
        ) else {
            throw CancellationError()
        }
        let accountIdentifier =
            CloudKitPlanCloudRecoveryKeyProvider.privateAccountScope
        let snapshotArchives = try selectedSnapshotArchives(
            accountIdentifier: accountIdentifier
        )
        do {
            return try loadLatestBackup(
                from: snapshotArchives,
                accountIdentifier: accountIdentifier,
                pinKeyData: capturedVerifier.keyMaterial
            )
        } catch PlanSecurityError.invalidArchive {
            guard let cloudRecoveryKeyProvider else {
                throw PlanSecurityError.accountUnavailable
            }
            let accountKey = try await cloudRecoveryKeyProvider.key()
            guard !Task.isCancelled,
                  preparationRevision == capturedPreparationRevision,
                  verifier == capturedVerifier,
                  TaptionDataDeletionFence.allows(
                      generation: capturedDataGeneration
                  ) else {
                throw CancellationError()
            }
            let payload = try loadLatestBackup(
                from: snapshotArchives,
                accountIdentifier: accountIdentifier,
                accountKeyData: accountKey
            )
            let currentMonth = PlanBackupRoutePointReducer.backupSpan(
                containing: .now
            )
            let currentMonthKey = PlanArchiveSchedule.monthKey(for: .now)
            _ = try? saveMonthlyArchive(
                PlanCloudBackupPayload(
                    snapshot: payload.snapshot,
                    routePoints: payload.routePoints.filter {
                        currentMonth.contains($0.sensorReading.timestamp)
                    },
                    appLog: payload.appLog
                ),
                accountIdentifier: accountIdentifier,
                accountKey: accountKey,
                date: .now,
                recordsSuccessfulBackup: false,
                generationID: snapshotArchives.first {
                    $0.monthKey == currentMonthKey
                }?.generationID
            )
            return payload
        }
    }

    func loadLatestBackupPackage() async throws
        -> PlanCloudBackupRestorePackage {
        guard hasPIN else { throw PlanSecurityError.pinRequiredForCloudBackup }
        guard let capturedVerifier = verifier else {
            throw PlanSecurityError.pinRequiredForCloudBackup
        }
        let preparationFence = RestorePreparationFence(
            preparationRevision: preparationRevision,
            verifier: capturedVerifier,
            dataGeneration: TaptionDataDeletionFence.currentGeneration()
        )
        try checkRestorePreparation(preparationFence)
        let accountIdentifier =
            CloudKitPlanCloudRecoveryKeyProvider.privateAccountScope
        let pinKeyData = capturedVerifier.keyMaterial
        let backup: PlanCloudBackupPayload
        var snapshotArchives = try selectedSnapshotArchives(
            accountIdentifier: accountIdentifier
        )
        var accountKeyData: Data?
        do {
            backup = try loadLatestBackup(
                from: snapshotArchives,
                accountIdentifier: accountIdentifier,
                pinKeyData: pinKeyData
            )
        } catch PlanSecurityError.invalidArchive {
            guard let cloudRecoveryKeyProvider else {
                throw PlanSecurityError.accountUnavailable
            }
            let accountKey = try await cloudRecoveryKeyProvider.key()
            try checkRestorePreparation(preparationFence)
            accountKeyData = accountKey
            snapshotArchives = try selectedSnapshotArchives(
                accountIdentifier: accountIdentifier
            )
            backup = try loadLatestBackup(
                from: snapshotArchives,
                accountIdentifier: accountIdentifier,
                accountKeyData: accountKey
            )
            try checkRestorePreparation(preparationFence)
            let currentMonth = PlanBackupRoutePointReducer.backupSpan(
                containing: .now
            )
            let currentMonthKey = PlanArchiveSchedule.monthKey(for: .now)
            _ = try? saveMonthlyArchive(
                PlanCloudBackupPayload(
                    snapshot: backup.snapshot,
                    routePoints: backup.routePoints.filter {
                        currentMonth.contains($0.sensorReading.timestamp)
                    },
                    appLog: backup.appLog
                ),
                accountIdentifier: accountIdentifier,
                accountKey: accountKey,
                date: .now,
                recordsSuccessfulBackup: false,
                generationID: snapshotArchives.first {
                    $0.monthKey == currentMonthKey
                }?.generationID
            )
        }

        try checkRestorePreparation(preparationFence)
        let rawSensorState = try await loadRawSensorRestoreStateOffMain(
            accountIdentifier: accountIdentifier,
            pinKeyData: pinKeyData,
            accountKeyData: accountKeyData,
            snapshotArchives: snapshotArchives,
            preparationFence: preparationFence
        )
        try checkRestorePreparation(preparationFence)
        return PlanCloudBackupRestorePackage(
            backup: backup,
            rawSensorState: rawSensorState
        )
    }

    /// PIN loss and biometric changes are recoverable only when iCloud still
    /// identifies the same account. Recovery writes a replacement verifier;
    /// it never silently clears data or resets the account.
    func recoverLatestArchive(accountIdentifier: String, newPIN: String) throws -> TaptionDataSnapshot {
        guard !accountIdentifier.isEmpty else { throw PlanSecurityError.accountUnavailable }
        let snapshot = try loadLatestBackup(
            accountIdentifier: accountIdentifier,
            accountKeyData: try accountKeyProvider.key(for: accountIdentifier)
        ).snapshot
        try setPIN(newPIN)
        return snapshot
    }

    func recoverLatestArchive(newPIN: String) async throws -> TaptionDataSnapshot {
        guard let cloudRecoveryKeyProvider else {
            throw PlanSecurityError.accountUnavailable
        }
        let accountKey = try await cloudRecoveryKeyProvider.key()
        let snapshot: TaptionDataSnapshot
        do {
            snapshot = try loadLatestBackup(
                accountIdentifier: CloudKitPlanCloudRecoveryKeyProvider.privateAccountScope,
                accountKeyData: accountKey
            ).snapshot
        } catch PlanSecurityError.invalidArchive {
            throw PlanSecurityError.accountMismatch
        }
        try setPIN(newPIN)
        return snapshot
    }

    private func loadLatestBackup(
        accountIdentifier: String,
        pinKeyData: Data? = nil,
        accountKeyData: Data? = nil
    ) throws -> PlanCloudBackupPayload {
        try loadLatestBackup(
            from: selectedSnapshotArchives(
                accountIdentifier: accountIdentifier
            ),
            accountIdentifier: accountIdentifier,
            pinKeyData: pinKeyData,
            accountKeyData: accountKeyData
        )
    }

    private func loadLatestBackup(
        from archives: [PlanMonthlyArchive],
        accountIdentifier: String,
        pinKeyData: Data? = nil,
        accountKeyData: Data? = nil
    ) throws -> PlanCloudBackupPayload {
        guard let latest = archives.last else {
            throw PlanSecurityError.archiveNotFound
        }
        let latestPayload = try latest.decodedPayload(
            pinKeyData: pinKeyData,
            accountKeyData: accountKeyData
        )
        let routeArchives = try archives.map { archive -> [PlanBackupRoutePoint] in
            guard archive.accountIdentifier == accountIdentifier else {
                throw PlanSecurityError.accountMismatch
            }
            if archive == latest {
                return latestPayload.routePoints
            }
            return try archive.decodedPayload(
                pinKeyData: pinKeyData,
                accountKeyData: accountKeyData
            ).routePoints
        }
        return PlanCloudBackupPayload(
            snapshot: latestPayload.snapshot,
            routePoints: PlanBackupRoutePointReducer.restoring(routeArchives),
            appLog: latestPayload.appLog
        )
    }

    private func selectedSnapshotArchives(
        accountIdentifier: String
    ) throws -> [PlanMonthlyArchive] {
        guard !accountIdentifier.isEmpty else {
            throw PlanSecurityError.accountUnavailable
        }
        let archives = try backupStore.allArchives()
        guard archives.allSatisfy({
            $0.accountIdentifier == accountIdentifier
        }) else {
            throw PlanSecurityError.accountMismatch
        }
        var latestByMonth: [String: PlanMonthlyArchive] = [:]
        for archive in archives {
            if let current = latestByMonth[archive.monthKey],
               !Self.archivePrecedes(current, archive) {
                continue
            }
            latestByMonth[archive.monthKey] = archive
        }
        return latestByMonth.values.sorted(by: Self.archivePrecedes)
    }

    private func loadRawSensorRestoreStateOffMain(
        accountIdentifier: String,
        pinKeyData: Data? = nil,
        accountKeyData: Data? = nil,
        snapshotArchives: [PlanMonthlyArchive],
        preparationFence: RestorePreparationFence,
        maximumBytes: Int =
            PlanCloudArchiveRestoreByteBudget.defaultMaximumBytes
    ) async throws -> PlanCloudRawSensorRestoreState {
        do {
            try checkRestorePreparation(preparationFence)
            let accumulator = PlanRawSensorRestoreAccumulator()
            var resolvedAccountKeyData = accountKeyData
            let byteBudget = PlanCloudArchiveRestoreByteBudget(
                maximumBytes: maximumBytes
            )
            let snapshotsByMonth = Dictionary(uniqueKeysWithValues:
                snapshotArchives.map { ($0.monthKey, $0) }
            )
            let snapshotMonths = Set(snapshotsByMonth.keys)
            let legacyMonths = try rawSensorBackupStore
                .legacyArchiveMonthKeys()
                .filter { !snapshotMonths.contains($0) }
            for monthKey in snapshotMonths.union(legacyMonths).sorted() {
                try checkRestorePreparation(preparationFence)
                let snapshot = snapshotsByMonth[monthKey]
                if snapshot?.hasRawSensorArchive == false {
                    continue
                }
                let loadedArchive = try await rawSensorBackupStore.loadForRestore(
                    monthKey: monthKey,
                    generationID: snapshot?.generationID,
                    byteBudget: byteBudget
                )
                try checkRestorePreparation(preparationFence)
                guard let archive = loadedArchive else {
                    if snapshot?.hasRawSensorArchive == true {
                        throw PlanSecurityError.accountUnavailable
                    }
                    continue
                }
                try Task.checkCancellation()
                guard archive.accountIdentifier == accountIdentifier else {
                    return .invalidArchive
                }
                guard Self.isCommitted(archive, snapshot: snapshot) else {
                    if snapshot?.hasRawSensorArchive == true {
                        return .invalidArchive
                    }
                    continue
                }
                do {
                    try await accumulator.append(
                        archive,
                        pinKeyData: pinKeyData,
                        accountKeyData: resolvedAccountKeyData
                    )
                } catch is PlanRawSensorAccountKeyFallbackNeeded {
                    guard let cloudRecoveryKeyProvider else {
                        throw PlanSecurityError.invalidArchive
                    }
                    guard resolvedAccountKeyData == nil else {
                        throw PlanSecurityError.invalidArchive
                    }
                    let accountKey: Data
                    do {
                        accountKey = try await cloudRecoveryKeyProvider.key()
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        throw PlanRawSensorRecoveryKeyLookupFailure(
                            underlying: error
                        )
                    }
                    try checkRestorePreparation(preparationFence)
                    try await accumulator.append(
                        archive,
                        pinKeyData: pinKeyData,
                        accountKeyData: accountKey
                    )
                    resolvedAccountKeyData = accountKey
                }
                try checkRestorePreparation(preparationFence)
            }
            let restoredState = await accumulator.restoreState()
            try checkRestorePreparation(preparationFence)
            return restoredState
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as PlanRawSensorRecoveryKeyLookupFailure {
            throw failure.underlying
        } catch PlanSecurityError.accountUnavailable {
            throw PlanSecurityError.accountUnavailable
        } catch {
            return .invalidArchive
        }
    }

    private static func isCommitted(
        _ rawArchive: PlanRawSensorMonthlyArchive,
        snapshot: PlanMonthlyArchive?
    ) -> Bool {
        guard let snapshot else {
            return rawArchive.generationID == nil
        }
        if snapshot.hasRawSensorArchive == false {
            return false
        }
        return rawArchive.generationID == snapshot.generationID
    }

    private static func archivePrecedes(
        _ lhs: PlanMonthlyArchive,
        _ rhs: PlanMonthlyArchive
    ) -> Bool {
        if lhs.monthKey != rhs.monthKey {
            return lhs.monthKey < rhs.monthKey
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        let lhsGeneration = lhs.generationID?.uuidString ?? ""
        let rhsGeneration = rhs.generationID?.uuidString ?? ""
        if lhsGeneration != rhsGeneration {
            return lhsGeneration < rhsGeneration
        }
        return lhs.payloadDigest.lexicographicallyPrecedes(rhs.payloadDigest)
    }

    private static func archivePrecedes(
        _ lhs: PlanRawSensorMonthlyArchive,
        _ rhs: PlanRawSensorMonthlyArchive
    ) -> Bool {
        if lhs.monthKey != rhs.monthKey {
            return lhs.monthKey < rhs.monthKey
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        let lhsGeneration = lhs.generationID?.uuidString ?? ""
        let rhsGeneration = rhs.generationID?.uuidString ?? ""
        if lhsGeneration != rhsGeneration {
            return lhsGeneration < rhsGeneration
        }
        return lhs.payloadDigest.lexicographicallyPrecedes(rhs.payloadDigest)
    }

}

private extension JSONEncoder {
    static var taptionPlan: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }
}

private extension JSONDecoder {
    static var taptionPlan: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
