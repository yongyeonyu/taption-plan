import Foundation

public enum WatchHealthSnapshotRetryPolicy {
    public static let minimumRetryInterval: TimeInterval = 60

    public static func accepts(
        capturedAt: Date,
        fingerprint: String?,
        receivedAt: Date,
        lastAppliedAt: Date?,
        rawRetryAt: Date?,
        rawRetryFingerprint: String?,
        lastRawRetryAttemptAt: Date?
    ) -> Bool {
        guard let lastAppliedAt else { return true }
        if capturedAt > lastAppliedAt { return true }
        guard capturedAt == lastAppliedAt,
              capturedAt == rawRetryAt,
              let fingerprint,
              fingerprint == rawRetryFingerprint else {
            return false
        }
        return lastRawRetryAttemptAt.map {
            receivedAt.timeIntervalSince($0) >= minimumRetryInterval
        } ?? true
    }
}
