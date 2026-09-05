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

    var components: [String] {
        [
            "iCloud Drive",
            "Taption Plan",
            "Raw Sensors",
            "\(monthKey).rawsensorbackup",
        ]
    }

    var relativePath: String { components.joined(separator: "/") }

    var storageComponents: [String] {
        [
            "Taption Plan",
            "Raw Sensors",
            "\(monthKey).rawsensorbackup",
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
        self.watchAccelerationChunks = []
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

struct PlanMonthlyArchive: Codable, Equatable, Sendable {
    static let currentVersion = 1
    let version: Int
    let monthKey: String
    let accountIdentifier: String
    let createdAt: Date
    let encryptedPayload: Data
    let wrappedPayloadKey: Data
    let accountWrappedPayloadKey: Data
    let payloadDigest: Data
    let generationID: UUID?

    init(monthKey: String, accountIdentifier: String, encryptedPayload: Data, wrappedPayloadKey: Data, accountWrappedPayloadKey: Data, createdAt: Date = .now, generationID: UUID? = nil) {
        self.version = Self.currentVersion
        self.monthKey = monthKey
        self.accountIdentifier = accountIdentifier
        self.createdAt = createdAt
        self.encryptedPayload = encryptedPayload
        self.wrappedPayloadKey = wrappedPayloadKey
        self.accountWrappedPayloadKey = accountWrappedPayloadKey
        self.payloadDigest = Data(SHA256.hash(data: encryptedPayload))
        self.generationID = generationID
    }

    func decodedPayload(
        pinKeyData: Data? = nil,
        accountKeyData: Data? = nil
    ) throws -> PlanCloudBackupPayload {
        guard version == Self.currentVersion,
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
        let compressed = try AES.GCM.open(
            sealed,
            using: SymmetricKey(data: archiveKey)
        )
        let data = TaptionSnapshotCompression.decode(compressed)
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
    static let currentVersion = 1

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

    func decodedPayload(
        pinKeyData: Data? = nil,
        accountKeyData: Data? = nil
    ) throws -> PlanCloudRawSensorPayload {
        guard version == Self.currentVersion,
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
            do {
                return try decodePayload(archiveKey: archiveKey)
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
        archiveKey: Data
    ) throws -> PlanCloudRawSensorPayload {
        let sealed = try AES.GCM.SealedBox(combined: encryptedPayload)
        let compressed = try AES.GCM.open(
            sealed,
            using: SymmetricKey(data: archiveKey)
        )
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
        let payload = try JSONDecoder.taptionPlan.decode(
            PlanCloudRawSensorPayload.self,
            from: data
        )
        guard payload.version == PlanCloudRawSensorPayload.currentVersion else {
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

@MainActor
final class CloudKitPlanCloudRecoveryKeyProvider: PlanCloudRecoveryKeyProvider {
    static let privateAccountScope = "icloud-private-v1"
    private static let recordType = "TaptionBackupRecoveryKey"
    private static let recordName = "taption-backup-recovery-key-v1"
    private static let valueKey = "keyEnvelopeBytes"
    private let container: CKContainer
    private let database: CKDatabase
    private let documentFallback: UbiquitousPlanCloudRecoveryKeyStore

    init(
        container: CKContainer = CKContainer(identifier: "iCloud.com.taption.plan"),
        documentFallback: UbiquitousPlanCloudRecoveryKeyStore = .init()
    ) {
        self.container = container
        database = container.privateCloudDatabase
        self.documentFallback = documentFallback
    }

    func key() async throws -> Data {
        let accountStatus: CKAccountStatus
        do {
            accountStatus = try await container.accountStatus()
        } catch {
            throw PlanSecurityError.accountUnavailable
        }
        guard accountStatus == .available else {
            throw PlanSecurityError.accountUnavailable
        }
        let fallbackKey = try? documentFallback.existingKey()
        let recordID = CKRecord.ID(recordName: Self.recordName)
        do {
            let record = try await database.record(for: recordID)
            guard let existing = record[Self.valueKey] as? Data,
                  existing.count == 32 else {
                throw PlanSecurityError.accountUnavailable
            }
            try? documentFallback.save(existing)
            return existing
        } catch let error as CKError where error.code == .unknownItem {
            let generated = try fallbackKey ?? Self.randomKey()
            let record = CKRecord(recordType: Self.recordType, recordID: recordID)
            record[Self.valueKey] = generated as CKRecordValue
            do {
                _ = try await database.save(record)
                try? documentFallback.save(generated)
                return generated
            } catch let saveError as CKError
            where saveError.code == .serverRecordChanged {
                let existing = try await database.record(for: recordID)
                guard let value = existing[Self.valueKey] as? Data,
                      value.count == 32 else {
                    throw PlanSecurityError.accountUnavailable
                }
                try? documentFallback.save(value)
                return value
            } catch {
                if Self.isProductionSchemaRejection(error) {
                    try documentFallback.save(generated)
                    return generated
                }
                throw error
            }
        } catch {
            if Self.isProductionSchemaRejection(error) {
                let generated = try fallbackKey ?? Self.randomKey()
                try documentFallback.save(generated)
                return generated
            }
            throw error
        }
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
        guard value.count == 32 else { throw PlanSecurityError.invalidArchive }
        return value
    }

    func save(_ key: Data) throws {
        guard key.count == 32,
              let fileURL = try recoveryKeyURL(createDirectory: true) else {
            throw PlanSecurityError.accountUnavailable
        }
        try key.write(
            to: fileURL,
            options: [
                .atomic,
                .completeFileProtectionUntilFirstUserAuthentication,
            ]
        )
    }

    func removeExistingKey() throws {
        guard let fileURL = try recoveryKeyURL(createDirectory: false),
              fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
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
        let months = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        var archives: [PlanMonthlyArchive] = []
        var archiveCount = 0
        for month in months where month.pathExtension == "taptionbackup" {
            archiveCount += 1
            guard let data = try? Data(contentsOf: month),
                  let archive = try? JSONDecoder.taptionPlan.decode(
                      PlanMonthlyArchive.self,
                      from: data
                  ) else { continue }
            archives.append(archive)
        }
        if archiveCount > archives.count {
            TaptionPlanDiagnosticsLogger.shared.record(
                "cloud_backup_files_skipped",
                level: .error,
                fields: [
                    "invalid": String(archiveCount - archives.count),
                    "valid": String(archives.count),
                ]
            )
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
    func deleteAll() throws
}

extension PlanCloudRawSensorBackupStore {
    func allArchives() throws -> [PlanRawSensorMonthlyArchive] {
        try latest().map { [$0] } ?? []
    }
}

final class FilePlanCloudRawSensorBackupStore: PlanCloudRawSensorBackupStore {
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
        try allArchives().max { $0.monthKey < $1.monthKey }
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
        let files = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        var archives: [PlanRawSensorMonthlyArchive] = []
        var archiveCount = 0
        for file in files where file.pathExtension == "rawsensorbackup" {
            archiveCount += 1
            guard let data = try? Data(contentsOf: file),
                  let archive = try? JSONDecoder.taptionPlan.decode(
                      PlanRawSensorMonthlyArchive.self,
                      from: data
                  ) else { continue }
            archives.append(archive)
        }
        if archiveCount > archives.count {
            TaptionPlanDiagnosticsLogger.shared.record(
                "cloud_raw_backup_files_skipped",
                level: .error,
                fields: [
                    "invalid": String(archiveCount - archives.count),
                    "valid": String(archives.count),
                ]
            )
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
    PlanCloudRawSensorBackupStore {
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
    private(set) var archives: [String: PlanRawSensorMonthlyArchive] = [:]

    func save(
        _ archive: PlanRawSensorMonthlyArchive,
        at path: PlanCloudRawSensorBackupPath
    ) throws {
        archives[path.monthKey] = archive
    }

    func delete(at path: PlanCloudRawSensorBackupPath) throws {
        archives[path.monthKey] = nil
    }

    func latest() throws -> PlanRawSensorMonthlyArchive? {
        archives.values.max { $0.monthKey < $1.monthKey }
    }

    func allArchives() throws -> [PlanRawSensorMonthlyArchive] {
        Array(archives.values)
    }

    func deleteAll() throws {
        archives.removeAll()
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
    private var failedAttempts = 0
    private var blockedUntil: Date?
    private(set) var settings: PlanAppLockSettings
    private(set) var state: PlanAppLockState = .unlocked
    private(set) var latestSuccessfulBackupDate: Date?

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
        self.verifier = (try? credentialStore.read()).flatMap { try? JSONDecoder().decode(PlanPINVerifier.self, from: $0) }
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
        let data = try JSONEncoder().encode(value)
        try credentialStore.write(data)
        verifier = value
        failedAttempts = 0
        blockedUntil = nil
    }

    func deleteAllBackups() throws {
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

    func verifyPIN(_ pin: String, now: Date = .now) throws {
        if let blockedUntil, blockedUntil > now { throw PlanSecurityError.tooManyAttempts(retryAfter: blockedUntil.timeIntervalSince(now)) }
        guard let verifier, verifier.matches(pin) else {
            failedAttempts += 1
            if failedAttempts >= 5 { blockedUntil = now.addingTimeInterval(30) }
            throw PlanSecurityError.invalidPIN
        }
        failedAttempts = 0
        blockedUntil = nil
        state = .unlocked
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
        guard hasPIN else { throw PlanSecurityError.pinRequiredForCloudBackup }
        guard let cloudRecoveryKeyProvider else {
            throw PlanSecurityError.accountUnavailable
        }
        let accountKey = try await cloudRecoveryKeyProvider.key()
        if let dataGeneration,
           !TaptionDataDeletionFence.allows(generation: dataGeneration) {
            throw CancellationError()
        }
        return try saveMonthlyArchive(
            payload,
            accountIdentifier: CloudKitPlanCloudRecoveryKeyProvider.privateAccountScope,
            accountKey: accountKey,
            date: date
        )
    }

    func saveMonthlyGeneration(
        _ payload: PlanCloudBackupPayload,
        rawSensorPayload: PlanCloudRawSensorPayload?,
        date: Date = .now,
        dataGeneration: UInt64? = nil
    ) async throws -> PlanCloudBackupGeneration {
        guard hasPIN else {
            throw PlanSecurityError.pinRequiredForCloudBackup
        }
        guard let cloudRecoveryKeyProvider else {
            throw PlanSecurityError.accountUnavailable
        }
        let accountKey = try await cloudRecoveryKeyProvider.key()
        if let dataGeneration,
           !TaptionDataDeletionFence.allows(generation: dataGeneration) {
            throw CancellationError()
        }
        let accountIdentifier =
            CloudKitPlanCloudRecoveryKeyProvider.privateAccountScope
        let generationID = UUID()
        let rawSave: (
            archive: PlanRawSensorMonthlyArchive,
            previous: PlanRawSensorMonthlyArchive?
        )?
        if let rawSensorPayload, !rawSensorPayload.isEmpty {
            rawSave = try saveRawSensorArchive(
                rawSensorPayload,
                accountIdentifier: accountIdentifier,
                accountKey: accountKey,
                date: date,
                generationID: generationID
            )
        } else {
            rawSave = nil
        }
        let snapshotArchive: PlanMonthlyArchive
        do {
            snapshotArchive = try saveMonthlyArchive(
                payload,
                accountIdentifier: accountIdentifier,
                accountKey: accountKey,
                date: date,
                recordsSuccessfulBackup: false,
                generationID: generationID
            )
        } catch {
            if let rawSave {
                let path = PlanCloudRawSensorBackupPath(
                    monthKey: rawSave.archive.monthKey
                )
                if let previous = rawSave.previous {
                    try rawSensorBackupStore.save(previous, at: path)
                } else {
                    try rawSensorBackupStore.delete(at: path)
                }
            }
            throw error
        }
        recordSuccessfulBackup(at: date)
        return PlanCloudBackupGeneration(
            snapshot: snapshotArchive,
            rawSensors: rawSave?.archive,
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
        let accountKey = try accountKeyProvider.key(for: accountIdentifier)
        return try saveRawSensorArchive(
            payload,
            accountIdentifier: accountIdentifier,
            accountKey: accountKey,
            date: date
        ).archive
    }

    func saveRawSensorArchive(
        _ payload: PlanCloudRawSensorPayload,
        date: Date = .now
    ) async throws -> PlanRawSensorMonthlyArchive {
        guard hasPIN else { throw PlanSecurityError.pinRequiredForCloudBackup }
        guard let cloudRecoveryKeyProvider else {
            throw PlanSecurityError.accountUnavailable
        }
        let accountKey = try await cloudRecoveryKeyProvider.key()
        return try saveRawSensorArchive(
            payload,
            accountIdentifier: CloudKitPlanCloudRecoveryKeyProvider.privateAccountScope,
            accountKey: accountKey,
            date: date
        ).archive
    }

    private func saveMonthlyArchive(
        _ payload: PlanCloudBackupPayload,
        accountIdentifier: String,
        accountKey: Data?,
        date: Date,
        recordsSuccessfulBackup: Bool = true,
        generationID: UUID? = nil
    ) throws -> PlanMonthlyArchive {
        guard let verifier else {
            throw PlanSecurityError.pinRequiredForCloudBackup
        }
        let monthKey = PlanArchiveSchedule.monthKey(for: date)
        let preserved = try payloadPreservingCurrentMonthRoutes(
            payload,
            monthKey: monthKey,
            accountIdentifier: accountIdentifier,
            pinKeyData: verifier.keyMaterial,
            accountKeyData: accountKey
        )
        let payload = preserved.payload
        let encoded = try JSONEncoder.taptionPlan.encode(payload)
        let compressed = TaptionSnapshotCompression.encode(encoded)
        let archiveKey = try Self.randomKey()
        let encryptedPayload = try AES.GCM.seal(
            compressed,
            using: SymmetricKey(data: archiveKey)
        ).combined ?? { throw PlanSecurityError.invalidArchive }()
        let pinKey = SymmetricKey(data: verifier.keyMaterial)
        let wrappedPayloadKey = try AES.GCM.seal(archiveKey, using: pinKey).combined ?? { throw PlanSecurityError.invalidArchive }()
        let accountWrappedPayloadKey: Data
        if let accountKey {
            guard accountKey.count == 32 else { throw PlanSecurityError.accountUnavailable }
            accountWrappedPayloadKey = try AES.GCM.seal(archiveKey, using: SymmetricKey(data: accountKey)).combined ?? { throw PlanSecurityError.invalidArchive }()
        } else {
            accountWrappedPayloadKey = Data()
        }
        let archive = PlanMonthlyArchive(
            monthKey: monthKey,
            accountIdentifier: accountIdentifier,
            encryptedPayload: encryptedPayload,
            wrappedPayloadKey: wrappedPayloadKey,
            accountWrappedPayloadKey: accountWrappedPayloadKey,
            createdAt: date,
            generationID: generationID != nil
                ? generationID
                : preserved.generationID
        )
        try backupStore.save(archive, at: PlanCloudBackupPath(monthKey: archive.monthKey))
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
        generationID: UUID? = nil
    ) throws -> (
        archive: PlanRawSensorMonthlyArchive,
        previous: PlanRawSensorMonthlyArchive?
    ) {
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
        let preserved = try payloadPreservingCurrentMonthRawData(
            normalizedPayload,
            monthKey: monthKey,
            accountIdentifier: accountIdentifier,
            pinKeyData: verifier.keyMaterial,
            accountKeyData: accountKey
        )
        let payload = preserved.payload
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
        let archiveKey = try Self.randomKey()
        let encryptedPayload = try AES.GCM.seal(
            compressed,
            using: SymmetricKey(data: archiveKey)
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
        try rawSensorBackupStore.save(
            archive,
            at: PlanCloudRawSensorBackupPath(monthKey: monthKey)
        )
        return (archive, preserved.archive)
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

    private func payloadPreservingCurrentMonthRoutes(
        _ incoming: PlanCloudBackupPayload,
        monthKey: String,
        accountIdentifier: String,
        pinKeyData: Data,
        accountKeyData: Data?
    ) throws -> (payload: PlanCloudBackupPayload, generationID: UUID?) {
        guard let existingArchive = try backupStore.allArchives()
            .filter({ $0.monthKey == monthKey })
            .max(by: Self.archivePrecedes) else {
            return (incoming, nil)
        }
        guard existingArchive.accountIdentifier == accountIdentifier else {
            throw PlanSecurityError.accountMismatch
        }

        let existing: PlanCloudBackupPayload
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
        return (
            PlanCloudBackupPayload(
                snapshot: CloudSnapshotRecoveryEngine.merge(
                    local: incoming.snapshot,
                    remote: existing.snapshot
                ),
                routePoints: PlanBackupRoutePointReducer.merging(
                    existing: existing.routePoints,
                    incoming: incoming.routePoints
                ),
                appLog: incoming.appLog ?? existing.appLog
            ),
            existingArchive.generationID
        )
    }

    private func payloadPreservingCurrentMonthRawData(
        _ incoming: PlanCloudRawSensorPayload,
        monthKey: String,
        accountIdentifier: String,
        pinKeyData: Data,
        accountKeyData: Data?
    ) throws -> (
        payload: PlanCloudRawSensorPayload,
        archive: PlanRawSensorMonthlyArchive?
    ) {
        guard let existingArchive = try rawSensorBackupStore.allArchives()
            .filter({ $0.monthKey == monthKey })
            .max(by: Self.archivePrecedes) else {
            return (incoming, nil)
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

        var readingsByID: [UUID: SensorReading] = [:]
        try Self.mergeRaw(
            existing.sensorReadings + incoming.sensorReadings,
            into: &readingsByID
        )
        var envelopesByID: [UUID: RawDeviceDataEnvelope] = [:]
        try Self.mergeRaw(
            existing.envelopes + incoming.envelopes,
            into: &envelopesByID
        )
        var chunksByID: [UUID: TaptionWatchAccelerationChunk] = [:]
        try Self.mergeRaw(
            (existing.watchAccelerationChunks ?? [])
                + (incoming.watchAccelerationChunks ?? []),
            into: &chunksByID
        )
        return (
            PlanCloudRawSensorPayload(
                monthKey: monthKey,
                sensorReadings: Array(readingsByID.values),
                envelopes: Array(envelopesByID.values),
                watchAccelerationChunks: Array(chunksByID.values),
                createdAt: incoming.createdAt
            ),
            existingArchive
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
        accountIdentifier: String
    ) throws -> PlanCloudBackupRestorePackage {
        guard hasPIN else { throw PlanSecurityError.pinRequiredForCloudBackup }
        guard let verifier else { throw PlanSecurityError.pinRequiredForCloudBackup }
        let snapshotArchives = try selectedSnapshotArchives(
            accountIdentifier: accountIdentifier
        )
        return PlanCloudBackupRestorePackage(
            backup: try loadLatestBackup(
                from: snapshotArchives,
                accountIdentifier: accountIdentifier,
                pinKeyData: verifier.keyMaterial
            ),
            rawSensorState: loadRawSensorRestoreState(
                accountIdentifier: accountIdentifier,
                pinKeyData: verifier.keyMaterial,
                snapshotArchives: snapshotArchives
            )
        )
    }

    func loadLatestArchive() async throws -> TaptionDataSnapshot {
        try await loadLatestBackup().snapshot
    }

    func loadLatestBackup() async throws -> PlanCloudBackupPayload {
        guard hasPIN else { throw PlanSecurityError.pinRequiredForCloudBackup }
        let accountIdentifier =
            CloudKitPlanCloudRecoveryKeyProvider.privateAccountScope
        let snapshotArchives = try selectedSnapshotArchives(
            accountIdentifier: accountIdentifier
        )
        do {
            return try loadLatestBackup(
                from: snapshotArchives,
                accountIdentifier: accountIdentifier,
                pinKeyData: verifier?.keyMaterial
            )
        } catch PlanSecurityError.invalidArchive {
            guard let cloudRecoveryKeyProvider else {
                throw PlanSecurityError.accountUnavailable
            }
            let accountKey = try await cloudRecoveryKeyProvider.key()
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
        let accountIdentifier =
            CloudKitPlanCloudRecoveryKeyProvider.privateAccountScope
        let pinKeyData = verifier?.keyMaterial
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
            accountKeyData = accountKey
            snapshotArchives = try selectedSnapshotArchives(
                accountIdentifier: accountIdentifier
            )
            backup = try loadLatestBackup(
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

        var rawSensorState = loadRawSensorRestoreState(
            accountIdentifier: accountIdentifier,
            pinKeyData: pinKeyData,
            accountKeyData: accountKeyData,
            snapshotArchives: snapshotArchives
        )
        if rawSensorState == .invalidArchive,
           accountKeyData == nil,
           let cloudRecoveryKeyProvider {
            let accountKey = try await cloudRecoveryKeyProvider.key()
            rawSensorState = loadRawSensorRestoreState(
                accountIdentifier: accountIdentifier,
                accountKeyData: accountKey,
                snapshotArchives: snapshotArchives
            )
        }
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

    private func loadRawSensorRestoreState(
        accountIdentifier: String,
        pinKeyData: Data? = nil,
        accountKeyData: Data? = nil,
        snapshotArchives: [PlanMonthlyArchive]
    ) -> PlanCloudRawSensorRestoreState {
        do {
            let allArchives = try rawSensorBackupStore.allArchives()
            guard allArchives.allSatisfy({
                $0.accountIdentifier == accountIdentifier
            }) else { return .invalidArchive }
            let snapshotsByMonth = Dictionary(
                uniqueKeysWithValues: snapshotArchives.map {
                    ($0.monthKey, $0)
                }
            )
            var latestByMonth: [String: PlanRawSensorMonthlyArchive] = [:]
            for archive in allArchives where Self.isCommitted(
                archive,
                snapshot: snapshotsByMonth[archive.monthKey]
            ) {
                if let current = latestByMonth[archive.monthKey],
                   !Self.archivePrecedes(current, archive) {
                    continue
                }
                latestByMonth[archive.monthKey] = archive
            }
            let archives = latestByMonth.values.sorted(
                by: Self.archivePrecedes
            )
            guard !archives.isEmpty else { return .unavailable }
            var readingsByID: [UUID: SensorReading] = [:]
            var envelopesByID: [UUID: RawDeviceDataEnvelope] = [:]
            var chunksByID: [UUID: TaptionWatchAccelerationChunk] = [:]
            var latestPayload: PlanCloudRawSensorPayload?
            for archive in archives {
                let payload = try archive.decodedPayload(
                    pinKeyData: pinKeyData,
                    accountKeyData: accountKeyData
                )
                latestPayload = payload
                try Self.mergeRaw(
                    payload.sensorReadings,
                    into: &readingsByID
                )
                try Self.mergeRaw(
                    payload.envelopes,
                    into: &envelopesByID
                )
                try Self.mergeRaw(
                    payload.watchAccelerationChunks ?? [],
                    into: &chunksByID
                )
            }
            guard let latestPayload else { return .unavailable }
            return .available(
                PlanCloudRawSensorPayload(
                    monthKey: latestPayload.monthKey,
                    sensorReadings: Array(readingsByID.values),
                    envelopes: Array(envelopesByID.values),
                    watchAccelerationChunks: Array(chunksByID.values),
                    createdAt: latestPayload.createdAt
                )
            )
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

    private static func mergeRaw<Value: Identifiable & Equatable>(
        _ values: [Value],
        into index: inout [UUID: Value]
    ) throws where Value.ID == UUID {
        for value in values {
            if let existing = index[value.id], existing != value {
                throw PlanSecurityError.invalidArchive
            }
            index[value.id] = value
        }
    }

    private static func randomKey() throws -> Data {
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
