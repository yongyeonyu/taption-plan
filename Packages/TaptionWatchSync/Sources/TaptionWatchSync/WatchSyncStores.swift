import Foundation
import TaptionPlanCore

// 워치·아이폰 기기별 공유 상태 저장(UserDefaults). (WatchSyncModels.swift에서 나눴다.)

public enum TaptionWatchDeviceLocalDefaults {
    private static var protectedStore: UserDefaults? {
        UserDefaults(
            suiteName: TaptionPlanSharedContainer.appGroupIdentifier
        )
    }

    public static func data(forKey key: String) -> Data? {
        guard let store = protectedStore else {
            UserDefaults.standard.removeObject(forKey: key)
            return nil
        }
        if let data = store.data(forKey: key) { return data }
        guard let legacy = UserDefaults.standard.data(forKey: key) else {
            return nil
        }
        store.set(legacy, forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        return legacy
    }

    public static func set(_ data: Data, forKey key: String) {
        protectedStore?.set(data, forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
    }

    public static func removeObject(forKey key: String) {
        protectedStore?.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
    }
}

public enum TaptionWatchCommandCapabilityStore {
    private static let key = "TaptionPlan.watchCommandCapabilities.v1"
    private static let lock = NSLock()

    public static func reconcile(
        planIDs: Set<UUID>,
        now: Date,
        lifetime: TimeInterval = 24 * 3_600,
        defaults: UserDefaults = UserDefaults(
            suiteName: TaptionPlanSharedContainer.appGroupIdentifier
        ) ?? .standard
    ) -> [TaptionWatchCommandCapability] {
        lock.lock()
        defer { lock.unlock() }
        let stored = readUnlocked(defaults: defaults)
        let current = stored.filter {
            planIDs.contains($0.planID) && $0.expiresAt > now
        }
        var result = current
        for planID in planIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            for kind in TaptionWatchCommandKind.allCases where !result.contains(where: {
                $0.planID == planID && $0.kind == kind
            }) {
                result.append(
                    TaptionWatchCommandCapability(
                        commandID: UUID(),
                        token: UUID(),
                        planID: planID,
                        kind: kind,
                        expiresAt: now.addingTimeInterval(lifetime)
                    )
                )
            }
        }
        guard result != stored else { return result }
        return writeUnlocked(result, defaults: defaults) ? result : current
    }

    public static func consume(
        _ command: TaptionWatchCommand,
        at date: Date,
        defaults: UserDefaults = UserDefaults(
            suiteName: TaptionPlanSharedContainer.appGroupIdentifier
        ) ?? .standard
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var values = readUnlocked(defaults: defaults)
        guard let index = values.firstIndex(where: {
            $0.accepts(command, at: date)
        }) else { return false }
        values.remove(at: index)
        return writeUnlocked(values, defaults: defaults)
    }

    public static func clear(
        defaults: UserDefaults = UserDefaults(
            suiteName: TaptionPlanSharedContainer.appGroupIdentifier
        ) ?? .standard
    ) {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: key)
    }

    private static func readUnlocked(
        defaults: UserDefaults
    ) -> [TaptionWatchCommandCapability] {
        guard let data = defaults.data(forKey: key),
              let values = try? JSONDecoder().decode(
                  [TaptionWatchCommandCapability].self,
                  from: data
              ) else { return [] }
        return values
    }

    private static func writeUnlocked(
        _ values: [TaptionWatchCommandCapability],
        defaults: UserDefaults
    ) -> Bool {
        guard let data = try? JSONEncoder().encode(values) else { return false }
        defaults.set(data, forKey: key)
        return defaults.data(forKey: key) == data
    }
}

/// Apple Watch가 보내온 직전 실행 기록. 워치 앱이 실행 중 종료될 때 어느
/// 단계까지 갔는지 iPhone 설정 화면에서 확인하기 위한 저장소다.
/// 워치에서 받은 "맞아요 / 아니에요" 응답을 원본과 별개로 모아 둔다.
/// 자동 센서 기록은 원본을 보존해야 하므로 기록을 고치지 않고, 사용자가
/// 붙인 라벨로만 쌓아 나중에 학습·교정에 쓴다.
public enum WatchActivityConfirmationStore {
    private static let key = "TaptionPlan.watchActivityConfirmations"
    private static let limit = 500

    public static func append(_ value: TaptionWatchActivityConfirmation) {
        var all = read()
        guard !all.contains(where: { $0.id == value.id }) else { return }
        all.append(value)
        if all.count > limit {
            all.removeFirst(all.count - limit)
        }
        guard let data = try? JSONEncoder().encode(all) else { return }
        TaptionWatchDeviceLocalDefaults.set(data, forKey: key)
    }

    public static func read() -> [TaptionWatchActivityConfirmation] {
        guard let data = TaptionWatchDeviceLocalDefaults.data(forKey: key),
              let values = try? JSONDecoder().decode(
                [TaptionWatchActivityConfirmation].self,
                from: data
              ) else {
            return []
        }
        return values
    }

    public static func clear() {
        TaptionWatchDeviceLocalDefaults.removeObject(forKey: key)
    }
}

public enum WatchActivityLearningStore {
    private static let key = "TaptionPlan.watchActivityLearningSamples"
    private static let limit = 1_000

    public static func append(_ value: WatchActivityPatternSample) {
        var all = read()
        guard !all.contains(where: { $0.id == value.id }) else { return }
        all.append(value)
        if all.count > limit { all.removeFirst(all.count - limit) }
        guard let data = try? JSONEncoder().encode(all) else { return }
        TaptionWatchDeviceLocalDefaults.set(data, forKey: key)
    }

    public static func read() -> [WatchActivityPatternSample] {
        guard let data = TaptionWatchDeviceLocalDefaults.data(forKey: key),
              let values = try? JSONDecoder().decode(
                [WatchActivityPatternSample].self,
                from: data
              ) else { return [] }
        return values
    }

    public static func clear() {
        TaptionWatchDeviceLocalDefaults.removeObject(forKey: key)
    }
}

public enum TaptionWatchDiagnosticsPrivacy {
    private static let personalHealthTokens = [
        "health", "sleep", "heart", "blood", "glucose", "oxygen",
        "respir", "workout", "exercise", "stand", "energy", "calorie",
        "step", "weight", "body",
    ]

    public static func redacted(_ report: String) -> String {
        report.split(whereSeparator: \Character.isNewline).filter { line in
            let value = line.lowercased()
            return !personalHealthTokens.contains { value.contains($0) }
        }.joined(separator: "\n")
    }
}

public enum WatchLaunchReportStore {
    private static let key = "TaptionPlan.watchLaunchReport"
    private static let dateKey = "TaptionPlan.watchLaunchReportDate"

    public static func save(_ report: String) {
        let safe = TaptionWatchDiagnosticsPrivacy.redacted(report)
        guard !safe.isEmpty else { return }
        UserDefaults.standard.set(safe, forKey: key)
        UserDefaults.standard.set(Date.now, forKey: dateKey)
    }

    public static func read() -> (report: String, receivedAt: Date)? {
        guard let report = UserDefaults.standard.string(forKey: key),
              !report.isEmpty else {
            return nil
        }
        let date = UserDefaults.standard.object(forKey: dateKey) as? Date
        return (report, date ?? .now)
    }

    public static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: dateKey)
    }
}

public enum TaptionWatchHealthMetadata {
    public static let planID = "com.taption.plan.planID"
    public static let planTitle = "com.taption.plan.planTitle"
    public static let categoryID = "com.taption.plan.categoryID"
    public static let sensorSessionID = "com.taption.plan.sensorSessionID"
    public static let workoutPurgeIdentifier = "com.taption.plan.workoutPurgeIdentifier"
}
