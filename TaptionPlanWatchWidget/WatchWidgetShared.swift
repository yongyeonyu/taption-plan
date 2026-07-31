import Foundation

enum TaptionWatchWidgetKind {
    static let status = "TaptionWatchStatusWidget"
}

enum TaptionWatchWidgetStore {
    static let appGroupIdentifier = "group.com.taption.plan"
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
}
