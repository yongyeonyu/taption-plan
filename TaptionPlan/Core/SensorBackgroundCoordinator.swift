import Foundation

enum SensorWakeReason: String, Codable, CaseIterable, Hashable, Sendable {
    case appLaunch
    case locationRelaunch
    case healthKitBackgroundDelivery
    case bgAppRefresh
    case foregroundResume
}

enum SensorCollectionSessionState: String, Codable, Hashable, Sendable {
    case waiting
    case collecting
    case stopped
}

enum SensorBackgroundRefreshPolicy {
    static let minimumDelay: TimeInterval = 15 * 60
    private static let intervalKey =
        "TaptionPlan.sensor-background-refresh-interval.v1"

    static func delay(for intervalSeconds: Int) -> TimeInterval {
        max(minimumDelay, TimeInterval(max(1, intervalSeconds)))
    }

    static func save(
        intervalSeconds: Int,
        defaults: UserDefaults? = UserDefaults(
            suiteName: AppLanguagePreference.appGroupIdentifier
        )
    ) {
        defaults?.set(max(1, intervalSeconds), forKey: intervalKey)
    }

    static func savedDelay(
        defaults: UserDefaults? = UserDefaults(
            suiteName: AppLanguagePreference.appGroupIdentifier
        )
    ) -> TimeInterval {
        delay(for: defaults?.integer(forKey: intervalKey) ?? 0)
    }
}

@MainActor
final class SensorBackgroundCoordinator {
    static let shared = SensorBackgroundCoordinator(
        defaults: UserDefaults(
            suiteName: AppLanguagePreference.appGroupIdentifier
        )
    )

    private(set) var sessionState: SensorCollectionSessionState = .stopped
    private(set) var sessionID: UUID?
    private(set) var lastSavedAt: Date?
    private(set) var lastWakeReason: SensorWakeReason?
    private(set) var saveToken = 0
    private(set) var sessionStartedAt: Date?
    private(set) var sessionExpiresAt: Date?

    private var recentWakes: [SensorWakeReason: Date] = [:]
    private let wakeDeduplicationWindow: TimeInterval
    private let defaultSessionLifetime: TimeInterval
    private let defaults: UserDefaults?
    private let storageKey: String

    private struct StoredState: Codable {
        var sessionState: SensorCollectionSessionState
        var sessionID: UUID?
        var lastSavedAt: Date?
        var lastWakeReason: SensorWakeReason?
        var saveToken: Int
        var sessionStartedAt: Date?
        var sessionExpiresAt: Date?
    }

    init(
        wakeDeduplicationWindow: TimeInterval = 5,
        defaultSessionLifetime: TimeInterval = 8 * 60 * 60,
        defaults: UserDefaults? = nil,
        storageKey: String = "TaptionPlan.sensor-background-session.v1"
    ) {
        self.wakeDeduplicationWindow = max(0, wakeDeduplicationWindow)
        self.defaultSessionLifetime = max(1, defaultSessionLifetime)
        self.defaults = defaults
        self.storageKey = storageKey
        restore()
    }

    @discardableResult
    func receiveWake(
        _ reason: SensorWakeReason,
        at date: Date = .now
    ) -> Bool {
        if let previous = recentWakes[reason],
           date >= previous,
           date.timeIntervalSince(previous) < wakeDeduplicationWindow {
            return false
        }
        recentWakes = recentWakes.filter {
            date.timeIntervalSince($0.value) < wakeDeduplicationWindow * 2
        }
        recentWakes[reason] = date
        lastWakeReason = reason
        if sessionState == .stopped {
            transition(to: .waiting)
        }
        persist()
        return true
    }

    @discardableResult
    func beginCollectionSession(
        id: UUID? = nil,
        at date: Date = .now
    ) -> Bool {
        if sessionState == .collecting {
            return false
        }
        sessionID = id ?? sessionID ?? UUID()
        sessionState = .collecting
        sessionStartedAt = date
        sessionExpiresAt = nil
        persist()
        return true
    }

    @discardableResult
    func beginAutomaticSession(
        at date: Date = .now,
        expiresAfter lifetime: TimeInterval? = nil
    ) -> Bool {
        guard sessionState != .collecting else { return false }
        sessionID = sessionID ?? UUID()
        sessionState = .collecting
        sessionStartedAt = date
        sessionExpiresAt = date.addingTimeInterval(
            max(1, lifetime ?? defaultSessionLifetime)
        )
        persist()
        return true
    }

    @discardableResult
    func markSaved(
        at date: Date = .now,
        persistedToken: Int? = nil
    ) -> Int {
        saveToken = max(saveToken + 1, persistedToken ?? 0)
        lastSavedAt = max(lastSavedAt ?? date, date)
        persist()
        return saveToken
    }

    @discardableResult
    func expireIfNeeded(at date: Date = .now) -> Bool {
        guard sessionState == .collecting,
              let sessionExpiresAt,
              date >= sessionExpiresAt else {
            return false
        }
        endSession()
        return true
    }

    func endSession() {
        guard sessionState != .stopped
                || sessionID != nil
                || sessionStartedAt != nil
                || sessionExpiresAt != nil else { return }
        transition(to: .stopped)
        sessionID = nil
        sessionStartedAt = nil
        sessionExpiresAt = nil
        persist()
    }

    func cancel() {
        endSession()
        guard !recentWakes.isEmpty || lastWakeReason != nil else { return }
        recentWakes.removeAll()
        lastWakeReason = nil
        persist()
    }

    private func transition(to state: SensorCollectionSessionState) {
        sessionState = state
    }

    private func restore() {
        guard let data = defaults?.data(forKey: storageKey),
              let value = try? JSONDecoder().decode(
                  StoredState.self,
                  from: data
              ) else { return }
        sessionState = value.sessionState
        sessionID = value.sessionID
        lastSavedAt = value.lastSavedAt
        lastWakeReason = value.lastWakeReason
        saveToken = value.saveToken
        sessionStartedAt = value.sessionStartedAt
        sessionExpiresAt = value.sessionExpiresAt
    }

    private func persist() {
        guard let defaults else { return }
        let value = StoredState(
            sessionState: sessionState,
            sessionID: sessionID,
            lastSavedAt: lastSavedAt,
            lastWakeReason: lastWakeReason,
            saveToken: saveToken,
            sessionStartedAt: sessionStartedAt,
            sessionExpiresAt: sessionExpiresAt
        )
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
