import Foundation
import TaptionPlanCore
import WidgetKit

enum TaptionWatchWidgetKind {
    // 이미 얹어 둔 컴플리케이션이 끊기지 않도록 이 값은 바꾸지 않는다.
    static let status = "TaptionWatchStatusWidget"
    static let nextPlan = "TaptionWatchNextPlanWidget"
    static let day = "TaptionWatchDayWidget"

    /// iPhone 값(일정·지금 활동·오늘 요약)이 바뀌면 세 위젯이 모두 달라진다.
    static func reloadForPayload() {
        for kind in [status, nextPlan, day] {
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
    }
}

enum TaptionWatchWidgetStore {
    static let appGroupIdentifier = TaptionPlanSharedContainer.appGroupIdentifier
    private static let payloadKey = "TaptionPlan.watchWidgetPayload"
    private static let cache = TaptionWatchDecodeCache<TaptionWatchPayload>()

    static func read() -> TaptionWatchPayload? {
        guard
            let defaults = UserDefaults(suiteName: appGroupIdentifier),
            let data = defaults.data(forKey: payloadKey)
        else {
            return nil
        }
        return cache.value(for: data)
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
    private static let cache = TaptionWatchDecodeCache<TaptionWatchMeasurementSnapshot>()

    static func read() -> TaptionWatchMeasurementSnapshot? {
        guard
            let defaults = UserDefaults(
                suiteName: TaptionWatchWidgetStore.appGroupIdentifier
            ),
            let data = defaults.data(forKey: key)
        else {
            return nil
        }
        return cache.value(for: data)
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
