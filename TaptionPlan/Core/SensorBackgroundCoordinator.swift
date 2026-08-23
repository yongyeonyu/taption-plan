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

@MainActor
final class SensorBackgroundCoordinator {
    static let shared = SensorBackgroundCoordinator()

    private(set) var sessionState: SensorCollectionSessionState = .stopped
    private(set) var lastSavedAt: Date?
    private(set) var lastWakeReason: SensorWakeReason?
    private(set) var saveToken = 0
    private(set) var sessionStartedAt: Date?
    private(set) var sessionExpiresAt: Date?

    private var recentWakes: [SensorWakeReason: Date] = [:]
    private let wakeDeduplicationWindow: TimeInterval
    private let defaultSessionLifetime: TimeInterval

    init(
        wakeDeduplicationWindow: TimeInterval = 5,
        defaultSessionLifetime: TimeInterval = 8 * 60 * 60
    ) {
        self.wakeDeduplicationWindow = max(0, wakeDeduplicationWindow)
        self.defaultSessionLifetime = max(1, defaultSessionLifetime)
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
        return true
    }

    @discardableResult
    func beginAutomaticSession(
        at date: Date = .now,
        expiresAfter lifetime: TimeInterval? = nil
    ) -> Bool {
        guard sessionState != .collecting else { return false }
        sessionState = .collecting
        sessionStartedAt = date
        sessionExpiresAt = date.addingTimeInterval(
            max(1, lifetime ?? defaultSessionLifetime)
        )
        return true
    }

    @discardableResult
    func markSaved(
        at date: Date = .now,
        persistedToken: Int? = nil
    ) -> Int {
        saveToken = max(saveToken + 1, persistedToken ?? 0)
        lastSavedAt = max(lastSavedAt ?? date, date)
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
        transition(to: .stopped)
        sessionStartedAt = nil
        sessionExpiresAt = nil
    }

    func cancel() {
        endSession()
        recentWakes.removeAll()
        lastWakeReason = nil
    }

    private func transition(to state: SensorCollectionSessionState) {
        sessionState = state
    }
}
