import Foundation
import TaptionPlanCore

enum TaptionWatchWidgetKind {
    static let status = "TaptionWatchStatusWidget"
}

enum TaptionWatchWidgetStore {
    static let appGroupIdentifier = TaptionPlanSharedContainer.appGroupIdentifier
    private static let payloadKey = "TaptionPlan.watchWidgetPayload"

    static func read() -> TaptionWatchPayload? {
        guard
            let defaults = UserDefaults(suiteName: appGroupIdentifier),
            let data = defaults.data(forKey: payloadKey)
        else {
            return nil
        }
        return try? JSONDecoder().decode(TaptionWatchPayload.self, from: data)
    }

    static func write(_ payload: TaptionWatchPayload) throws {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try JSONEncoder().encode(payload)
        defaults.set(data, forKey: payloadKey)
    }

    static func clear() {
        UserDefaults(suiteName: appGroupIdentifier)?
            .removeObject(forKey: payloadKey)
    }
}

/// 워치 앱이 남기고 워치 위젯이 읽는 "지금 재고 있는 것".
enum TaptionWatchMeasurementStore {
    private static let key = "TaptionPlan.watchMeasurementSnapshot"

    static func read() -> TaptionWatchMeasurementSnapshot? {
        guard
            let defaults = UserDefaults(
                suiteName: TaptionWatchWidgetStore.appGroupIdentifier
            ),
            let data = defaults.data(forKey: key)
        else {
            return nil
        }
        return try? JSONDecoder().decode(
            TaptionWatchMeasurementSnapshot.self,
            from: data
        )
    }

    static func write(_ snapshot: TaptionWatchMeasurementSnapshot) throws {
        guard let defaults = UserDefaults(
            suiteName: TaptionWatchWidgetStore.appGroupIdentifier
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        defaults.set(try JSONEncoder().encode(snapshot), forKey: key)
    }

    static func clear() {
        UserDefaults(suiteName: TaptionWatchWidgetStore.appGroupIdentifier)?
            .removeObject(forKey: key)
    }
}
