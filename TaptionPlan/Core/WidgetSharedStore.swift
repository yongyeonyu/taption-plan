import ActivityKit
import Foundation
import OSLog
import SwiftUI
import TaptionPlanCore

enum TaptionExternalPrivacyStore {
    private static let key = "taption.externalPrivacy.isLocked"

    static var isLocked: Bool {
        UserDefaults(
            suiteName: TaptionWidgetSharedStore.appGroupIdentifier
        )?.bool(forKey: key) ?? false
    }

    static func setLocked(_ isLocked: Bool) {
        UserDefaults(
            suiteName: TaptionWidgetSharedStore.appGroupIdentifier
        )?.set(isLocked, forKey: key)
    }
}

enum TaptionLocationTrackingRequestStore {
    private static let key = "TaptionPlan.pendingLocationTrackingRequest"
    private static let guidanceKey =
        "TaptionPlan.pendingLocationTrackingGuidance"

    static func write(_ enabled: Bool) {
        UserDefaults(
            suiteName: TaptionWidgetSharedStore.appGroupIdentifier
        )?.set(enabled, forKey: key)
    }

    static func take() -> Bool? {
        guard let defaults = UserDefaults(
            suiteName: TaptionWidgetSharedStore.appGroupIdentifier
        ), defaults.object(forKey: key) != nil else {
            return nil
        }
        let value = defaults.bool(forKey: key)
        defaults.removeObject(forKey: key)
        return value
    }

    static func requestGuidance() {
        UserDefaults(
            suiteName: TaptionWidgetSharedStore.appGroupIdentifier
        )?.set(true, forKey: guidanceKey)
    }

    static func takeGuidanceRequest() -> Bool {
        guard let defaults = UserDefaults(
            suiteName: TaptionWidgetSharedStore.appGroupIdentifier
        ) else { return false }
        let requested = defaults.bool(forKey: guidanceKey)
        defaults.removeObject(forKey: guidanceKey)
        return requested
    }
}

enum TaptionWidgetSyncFingerprint {
    static func make(items: [TaptionWidgetItem]) -> String {
        let canonical = items
            .sorted {
                if $0.resolvedLane == $1.resolvedLane {
                    if $0.startsAt == $1.startsAt {
                        return $0.id.uuidString < $1.id.uuidString
                    }
                    return $0.startsAt < $1.startsAt
                }
                return $0.resolvedLane.rawValue < $1.resolvedLane.rawValue
            }
            .map { item in
                // Open HealthKit/Watch records use the render time as their
                // end.  Including that moving value made the app's freshly
                // rebuilt ground-truth fingerprint differ from the cached
                // payload every few seconds while an activity was running.
                // The source snapshot revision still detects a real save;
                // the fingerprint should describe the record, not the clock.
                let end = switch item.resolvedLane {
                case .sleep, .activity:
                    "open-ended"
                default:
                    String(Int64(item.endsAt.timeIntervalSince1970 * 1_000))
                }
                return [
                    item.id.uuidString,
                    item.resolvedLane.rawValue,
                    item.title,
                    item.categoryID,
                    String(Int64(item.startsAt.timeIntervalSince1970 * 1_000)),
                    end,
                    item.status,
                ].joined(separator: "|")
            }
            .joined(separator: "\n")

        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in canonical.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

enum TaptionWidgetPayloadSyncPolicy {
    static func freshest(
        groundTruth: TaptionWidgetPayload,
        cached: TaptionWidgetPayload
    ) -> TaptionWidgetPayload {
        switch selectionReason(groundTruth: groundTruth, cached: cached) {
        case .groundTruth:
            return groundTruth
        case .cached:
            return cached
        }
    }

    enum SelectionReason: String, Sendable {
        case groundTruth
        case cached
    }

    static func selectionReason(
        groundTruth: TaptionWidgetPayload,
        cached: TaptionWidgetPayload
    ) -> SelectionReason {
        // The app-group snapshot is the canonical source.  A cached payload
        // is allowed to win only when it was built from a strictly newer
        // snapshot (for example, a widget action was applied while the app
        // was suspended).  Comparing generatedAt alone was the old bug: a
        // stale cache could be newer simply because the widget rendered it.
        guard groundTruth.sourceFingerprint != nil else {
            return cached.sourceFingerprint == nil ? .groundTruth : .cached
        }
        guard cached.sourceFingerprint != nil else {
            return .groundTruth
        }
        if groundTruth.sourceFingerprint == cached.sourceFingerprint {
            if let groundTruthUpdatedAt = groundTruth.sourceSnapshotUpdatedAt,
               let cachedUpdatedAt = cached.sourceSnapshotUpdatedAt,
               cachedUpdatedAt != groundTruthUpdatedAt {
                return cachedUpdatedAt > groundTruthUpdatedAt
                    ? .cached
                    : .groundTruth
            }
            return cached.generatedAt >= groundTruth.generatedAt
                ? .cached
                : .groundTruth
        }
        guard let groundTruthUpdatedAt = groundTruth.sourceSnapshotUpdatedAt else {
            return .groundTruth
        }
        guard let cachedUpdatedAt = cached.sourceSnapshotUpdatedAt else {
            return .groundTruth
        }
        return cachedUpdatedAt > groundTruthUpdatedAt
            ? .cached
            : .groundTruth
    }
}

enum TaptionWidgetSharedStore {
    static let appGroupIdentifier = TaptionPlanSharedContainer.appGroupIdentifier

    private static let logger = Logger(
        subsystem: "com.taption.plan",
        category: "WidgetSyncStore"
    )

    static let payloadFileName = "widget-payload-v1.json"
    static let commandsFileName = "widget-commands-v1.json"
    private static let snapshotFileName = "taption-data-v1.json"

    struct Diagnostics: Equatable, Sendable {
        var appGroupAvailable: Bool
        var snapshotExists: Bool
        var payloadExists: Bool
        var commandsExists: Bool
        var snapshotBytes: Int
        var payloadBytes: Int
        var commandsBytes: Int
        var snapshotUpdatedAt: Date?
        var payloadGeneratedAt: Date?
        var payloadSourceSnapshotUpdatedAt: Date?
        var groundTruthFingerprint: String?
        var payloadFingerprint: String?
        var groundTruthItemCount: Int
        var payloadItemCount: Int
        var snapshotReadError: String?
        var payloadReadError: String?

        var summary: String {
            let group = appGroupAvailable ? "App Group 정상" : "App Group 불가"
            let snapshot = snapshotExists
                ? "snapshot \(snapshotBytes)B"
                : "snapshot 없음"
            let payload = payloadExists
                ? "payload \(payloadBytes)B"
                : "payload 없음"
            let fingerprints = [
                shortFingerprint(groundTruthFingerprint),
                shortFingerprint(payloadFingerprint),
            ]
            .joined(separator: "/")
            return "\(group) · \(snapshot) · \(payload) · fp \(fingerprints)"
        }

        private func shortFingerprint(_ fingerprint: String?) -> String {
            guard let fingerprint, !fingerprint.isEmpty else { return "-" }
            return String(fingerprint.prefix(8))
        }
    }

    static func diagnostics(
        now: Date = .now
    ) -> Diagnostics {
        let snapshotURL = fileURL(snapshotFileName)
        let payloadURL = fileURL(payloadFileName)
        let commandsURL = fileURL(commandsFileName)
        let snapshotData = try? Data(contentsOf: snapshotURL)
        let payloadData = try? Data(contentsOf: payloadURL)
        let commandsData = try? Data(contentsOf: commandsURL)
        let snapshotResult = decodeSnapshot(snapshotData)
        let payloadResult = decodePayload(payloadData)
        let groundTruth = snapshotResult.value.map {
            TaptionWidgetPayloadFactory.make(
                from: $0,
                now: now,
                hidesSensitiveContent: TaptionExternalPrivacyStore.isLocked
            )
        }
        let result = Diagnostics(
            appGroupAvailable: appGroupContainerURL() != nil,
            snapshotExists: FileManager.default.fileExists(
                atPath: snapshotURL.path
            ),
            payloadExists: FileManager.default.fileExists(
                atPath: payloadURL.path
            ),
            commandsExists: FileManager.default.fileExists(
                atPath: commandsURL.path
            ),
            snapshotBytes: snapshotData?.count ?? 0,
            payloadBytes: payloadData?.count ?? 0,
            commandsBytes: commandsData?.count ?? 0,
            snapshotUpdatedAt: snapshotResult.value?.updatedAt,
            payloadGeneratedAt: payloadResult.value?.generatedAt,
            payloadSourceSnapshotUpdatedAt:
                payloadResult.value?.sourceSnapshotUpdatedAt,
            groundTruthFingerprint: groundTruth?.sourceFingerprint,
            payloadFingerprint: payloadResult.value?.sourceFingerprint,
            groundTruthItemCount: groundTruth?.items.count ?? 0,
            payloadItemCount: payloadResult.value?.items.count ?? 0,
            snapshotReadError: snapshotResult.error,
            payloadReadError: payloadResult.error
        )
        let diagnosticMessage =
            "Widget diagnostics: group="
            + String(result.appGroupAvailable)
            + ", snapshot="
            + String(result.snapshotExists)
            + "/"
            + String(result.snapshotBytes)
            + "B, payload="
            + String(result.payloadExists)
            + "/"
            + String(result.payloadBytes)
            + "B, snapshotUpdated="
            + String(result.snapshotUpdatedAt?.timeIntervalSince1970 ?? 0)
            + ", payloadGenerated="
            + String(result.payloadGeneratedAt?.timeIntervalSince1970 ?? 0)
            + ", groundItems="
            + String(result.groundTruthItemCount)
            + ", payloadItems="
            + String(result.payloadItemCount)
            + ", groundFP="
            + (result.groundTruthFingerprint ?? "none")
            + ", payloadFP="
            + (result.payloadFingerprint ?? "none")
        logger.notice("\(diagnosticMessage, privacy: .public)")
        return result
    }

    static func readGroundTruthPayload(
        now: Date = .now
    ) -> TaptionWidgetPayload {
        guard let snapshot = readGroundTruthSnapshot() else {
            logger.error("Widget ground-truth snapshot unavailable; using cached payload")
            return readPayload()
        }
        let payload = TaptionWidgetPayloadFactory.make(
            from: snapshot,
            now: now,
            hidesSensitiveContent: TaptionExternalPrivacyStore.isLocked
        )
        logger.debug(
            "Ground-truth payload built: updated=\(snapshot.updatedAt.timeIntervalSince1970, privacy: .public), items=\(payload.items.count, privacy: .public), fingerprint=\(payload.sourceFingerprint ?? "none", privacy: .public)"
        )
        return payload
    }

    static func readPayload() -> TaptionWidgetPayload {
        let data = try? Data(contentsOf: fileURL(payloadFileName))
        guard let payload = decodePayload(data).value else {
            logger.error("Widget cached payload unavailable")
            return .empty
        }
        logger.debug(
            "Cached widget payload read: generated=\(payload.generatedAt.timeIntervalSince1970, privacy: .public), items=\(payload.items.count, privacy: .public), fingerprint=\(payload.sourceFingerprint ?? "none", privacy: .public)"
        )
        return payload
    }

    static func writePayload(_ payload: TaptionWidgetPayload) throws {
        do {
            try write(encoder.encode(payload), to: fileURL(payloadFileName))
            logger.notice(
                "Widget payload written: generated=\(payload.generatedAt.timeIntervalSince1970, privacy: .public), sourceUpdated=\(payload.sourceSnapshotUpdatedAt?.timeIntervalSince1970 ?? 0, privacy: .public), items=\(payload.items.count, privacy: .public), fingerprint=\(payload.sourceFingerprint ?? "none", privacy: .public)"
            )
        } catch {
            logger.error(
                "Widget payload write failed: \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }

    static func deleteAll() throws {
        for name in [payloadFileName, commandsFileName, snapshotFileName] {
            let url = fileURL(name)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func readGroundTruthSnapshot() -> TaptionDataSnapshot? {
        let data = try? Data(contentsOf: fileURL(snapshotFileName))
        let result = decodeSnapshot(data)
        guard let snapshot = result.value,
              snapshot.updatedAt != .distantPast else {
            logger.error(
                "Ground-truth snapshot read failed: bytes=\(data?.count ?? 0, privacy: .public), error=\(result.error ?? "empty", privacy: .public)"
            )
            return nil
        }
        logger.debug(
            "Ground-truth snapshot read: updated=\(snapshot.updatedAt.timeIntervalSince1970, privacy: .public), plans=\(snapshot.plans.count, privacy: .public), places=\(snapshot.places.count, privacy: .public), travel=\(snapshot.travel.count, privacy: .public)"
        )
        return snapshot
    }

    private static func decodeSnapshot(
        _ data: Data?
    ) -> (value: TaptionDataSnapshot?, error: String?) {
        guard let data else { return (nil, "missing") }
        do {
            let snapshot = try decoder.decode(
                TaptionDataSnapshot.self,
                from: try TaptionSnapshotCompression.decode(data)
            )
            guard snapshot.updatedAt != .distantPast else {
                return (nil, "uninitialized")
            }
            return (snapshot, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    static func decodePayload(
        _ data: Data?
    ) -> (value: TaptionWidgetPayload?, error: String?) {
        guard let data else { return (nil, "missing") }
        do {
            return (try decoder.decode(TaptionWidgetPayload.self, from: data), nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    private static func appGroupContainerURL() -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        )
    }

    static func fileURL(_ name: String) -> URL {
        let fileManager = FileManager.default
        if let container = appGroupContainerURL() {
            return container.appendingPathComponent(name)
        }
        let fallback = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return fallback
            .appendingPathComponent("TaptionPlanWidget", isDirectory: true)
            .appendingPathComponent(name)
    }

    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(
            to: url,
            options: [
                .atomic,
                .completeFileProtectionUntilFirstUserAuthentication,
            ]
        )
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
