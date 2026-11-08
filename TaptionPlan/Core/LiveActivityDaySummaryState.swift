import Foundation

/// 다이나믹 아일랜드에 실어 보내는 오늘 요약. ActivityKit payload 한도(4KB) 안에 들도록
/// 표시에 필요한 짧은 값만 담는다. 글자는 앱이 지도 카운터와 같은 표기로 만들어 넘긴다.
struct SensorCollectionDaySummary: Codable, Hashable, Sendable {
    struct Category: Codable, Hashable, Sendable {
        var id: String
        var title: String
        var minutes: Int
        var durationText: String
        var hex: String
    }

    var categories: [Category]
    var steps: Int
    var meters: Int
    var distanceText: String
}

extension SensorCollectionActivityPolicy {
    /// 표시 값이 실제로 바뀐 경우에만 ActivityKit으로 보낸다.
    static func shouldPublishUpdate(
        previous: SensorCollectionActivityAttributes.ContentState,
        next: SensorCollectionActivityAttributes.ContentState
    ) -> Bool {
        previous != next
    }
}
