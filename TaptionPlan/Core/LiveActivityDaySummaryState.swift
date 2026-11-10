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

/// 잠금 화면의 빨간 심박 표시(대표 결정 2026-11-08). 외부 수신 센서(Apple Watch)일 때만 보인다.
enum SensorExternalHeartPolicy {
    static let freshSeconds: TimeInterval = 180

    /// 받은 지 3분이 넘은 심박은 숨긴다(REV1110A04).
    static func text(
        isExternalSample: Bool?,
        heartRate: Double?,
        updatedAt: Date? = nil,
        now: Date = .now
    ) -> String? {
        guard isExternalSample == true else { return nil }
        if heartRate != nil, let updatedAt, now.timeIntervalSince(updatedAt) > freshSeconds { return nil }
        guard let heartRate, heartRate.isFinite, heartRate > 0, heartRate < 1000 else { return "♥︎" }
        return "♥︎ \(Int(heartRate.rounded()))"
    }
}
