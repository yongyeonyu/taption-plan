import Foundation
import TaptionPlanCore
import WatchConnectivity

enum AppleWatchConnectionState: String, Sendable {
    case unsupported
    case notPaired
    case appNotInstalled
    case noRecentData
    case background
    case reachable

    var settingsLabel: String {
        settingsLabel(preference: .current)
    }

    func settingsLabel(preference: AppLanguagePreference) -> String {
        switch self {
        case .unsupported:
            AppLanguagePreference.text(
                korean: "이 iPhone에서 사용 불가",
                english: "Unavailable on this iPhone",
                preference: preference
            )
        case .notPaired:
            AppLanguagePreference.text(
                korean: "Apple Watch 미페어링",
                english: "Apple Watch not paired",
                preference: preference
            )
        case .appNotInstalled:
            AppLanguagePreference.text(
                korean: "워치 앱 설치 필요",
                english: "Watch app installation needed",
                preference: preference
            )
        case .noRecentData:
            AppLanguagePreference.text(
                korean: "연결됨 · 최근 데이터 없음",
                english: "Connected · No recent data",
                preference: preference
            )
        case .background:
            AppLanguagePreference.text(
                korean: "연결됨 · 백그라운드 동기화",
                english: "Connected · Background sync",
                preference: preference
            )
        case .reachable:
            AppLanguagePreference.text(
                korean: "연결됨 · 실시간",
                english: "Connected · Live",
                preference: preference
            )
        }
    }
}

enum AppleWatchDataKind: String, CaseIterable, Hashable, Sendable {
    case motion
    case heartRate
    case route
    case activity
    case health
}

struct AppleWatchDataReceipt: Equatable, Sendable {
    let measuredAtByKind: [AppleWatchDataKind: Date]
    let receivedAtByKind: [AppleWatchDataKind: Date]

    var latestDataAt: Date? {
        receivedAtByKind.values.max()
    }

    func recentKinds(
        at now: Date = .now,
        window: TimeInterval = AppleWatchConnectionPolicy.recentContactWindow
    ) -> Set<AppleWatchDataKind> {
        Set(receivedAtByKind.compactMap { kind, date in
            let age = now.timeIntervalSince(date)
            return age >= 0 && age <= window ? kind : nil
        })
    }
}

struct AppleWatchDataReceiptStore {
    private static let measuredKeyPrefix =
        "TaptionPlan.watchDataMeasuredAt.v1."
    private static let receivedKeyPrefix =
        "TaptionPlan.watchDataReceivedAt.v1."
    private let defaults: UserDefaults

    init(
        defaults: UserDefaults = UserDefaults(
            suiteName: TaptionPlanSharedContainer.appGroupIdentifier
        ) ?? .standard
    ) {
        self.defaults = defaults
    }

    func load() -> AppleWatchDataReceipt {
        let measuredAtByKind: [AppleWatchDataKind: Date] = Dictionary(
            uniqueKeysWithValues: AppleWatchDataKind.allCases.compactMap { kind in
                guard let date = defaults.object(
                    forKey: Self.measuredKeyPrefix + kind.rawValue
                ) as? Date else { return nil }
                return (kind, date)
            }
        )
        // Older builds only stored the measurement time. Treat that value as
        // the first known receipt time so the menu remains useful after an
        // upgrade, while every new delivery records its real arrival time.
        return AppleWatchDataReceipt(
            measuredAtByKind: measuredAtByKind,
            receivedAtByKind: Dictionary(
                uniqueKeysWithValues: AppleWatchDataKind.allCases.compactMap { kind in
                    let receivedAt = defaults.object(
                        forKey: Self.receivedKeyPrefix + kind.rawValue
                    ) as? Date
                    guard let date = receivedAt ?? measuredAtByKind[kind]
                    else { return nil }
                    return (kind, date)
                }
            )
        )
    }

    @discardableResult
    func record(
        _ kinds: Set<AppleWatchDataKind>,
        measuredAt: Date,
        receivedAt: Date = .now
    ) -> AppleWatchDataReceipt {
        let safeMeasuredAt = min(measuredAt, receivedAt)
        for kind in kinds {
            let measuredKey = Self.measuredKeyPrefix + kind.rawValue
            if let previous = defaults.object(forKey: measuredKey) as? Date {
                if safeMeasuredAt > previous {
                    defaults.set(safeMeasuredAt, forKey: measuredKey)
                }
            } else {
                defaults.set(safeMeasuredAt, forKey: measuredKey)
            }
            let receivedKey = Self.receivedKeyPrefix + kind.rawValue
            if let previous = defaults.object(forKey: receivedKey) as? Date {
                if receivedAt > previous {
                    defaults.set(receivedAt, forKey: receivedKey)
                }
            } else {
                defaults.set(receivedAt, forKey: receivedKey)
            }
        }
        return load()
    }

    func clear() {
        for kind in AppleWatchDataKind.allCases {
            defaults.removeObject(
                forKey: Self.measuredKeyPrefix + kind.rawValue
            )
            defaults.removeObject(
                forKey: Self.receivedKeyPrefix + kind.rawValue
            )
        }
    }
}

enum AppleWatchConnectionPolicy {
    static let recentContactWindow: TimeInterval = 15 * 60

    static func state(
        isSupported: Bool,
        isPaired: Bool,
        isWatchAppInstalled: Bool,
        isReachable: Bool,
        lastContactAt: Date?,
        now: Date = .now
    ) -> AppleWatchConnectionState {
        guard isSupported else { return .unsupported }
        guard isPaired else { return .notPaired }
        let hasRecentContact = lastContactAt.map {
            now.timeIntervalSince($0) >= 0
                && now.timeIntervalSince($0) <= recentContactWindow
        } ?? false
        if hasRecentContact {
            return isReachable ? .reachable : .background
        }
        guard isWatchAppInstalled else { return .appNotInstalled }
        return .noRecentData
    }
}

struct AppleWatchCompanionRow: Sendable, Equatable {
    let subtitle: String
    let value: String
    let detail: String?
}

enum AppleWatchDataSyncRequestStatus: Sendable, Equatable {
    case pending
    case backgroundQueued
    case noResponse
    case rejected
}

enum AppleWatchDataSyncReceiptPolicy {
    static func satisfiesPendingRequest(
        requestedAt: Date,
        expectedRequestID: String?,
        receivedRequestID: String?,
        measuredAt: Date,
        receivedAt: Date
    ) -> Bool {
        guard receivedAt >= requestedAt else { return false }
        if let receivedRequestID {
            return receivedRequestID == expectedRequestID
        }
        return measuredAt >= requestedAt
    }
}

enum AppleWatchAutomaticSyncPolicy {
    static let minimumInterval: TimeInterval = 10

    static func shouldRequest(
        lastRequestUptime: TimeInterval?,
        nowUptime: TimeInterval
    ) -> Bool {
        guard let lastRequestUptime else { return true }
        return nowUptime < lastRequestUptime
            || nowUptime - lastRequestUptime >= minimumInterval
    }
}

/// 안내를 닫은 기록. 워치를 가진 기기가 어느 것인지는 계정이 아니라 기기의
/// 성질이라서 iCloud 스냅샷이 아니라 기기 저장소에 남긴다. 덕분에
/// `cloudPortableSnapshot` / `mergeDeviceLocalData`의 손으로 적은 목록에
/// 새 항목을 더할 일이 없다.
struct AppleWatchOnboardingStore {
    private let defaults: UserDefaults
    private let dismissedKey = "taption.apple-watch-onboarding.dismissed.v1"
    private let installedKey = "taption.apple-watch-onboarding.installed.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var dismissed: Set<AppleWatchOnboardingPrompt> {
        Set(
            (defaults.stringArray(forKey: dismissedKey) ?? [])
                .compactMap(AppleWatchOnboardingPrompt.init(rawValue:))
        )
    }

    var hasSeenWatchAppInstalled: Bool {
        defaults.bool(forKey: installedKey)
    }

    func dismiss(_ prompt: AppleWatchOnboardingPrompt) {
        var values = dismissed
        values.insert(prompt)
        defaults.set(
            values.map(\.rawValue).sorted(),
            forKey: dismissedKey
        )
    }

    func markWatchAppInstalled() {
        defaults.set(true, forKey: installedKey)
    }
}
