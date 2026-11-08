import Foundation
import TaptionPlanCore

public enum TimelineLevel: String, Codable, CaseIterable, Sendable {
    case day
    case week
    case month
    case year
}

/// The semantic hierarchy shown by the timetable.  Record origin is kept
/// separate in `TimelineSourceKind`; it is a badge, not another parent row.
public enum TimelineSemanticLevel: String, Codable, CaseIterable, Sendable {
    case dayPhase = "일과"
    case activity = "활동"
}

public enum TimelineSourceKind: String, Codable, CaseIterable, Sendable {
    case automatic = "자동"
    case routine = "루틴"
    case action = "액션"
}

/// The automatic timeline rows.  Row identifier, Korean label and symbol live
/// together here so every scale, every detail card and every widget reads the
/// same vocabulary. Duplicating the label tables per surface is what produced
/// English identifiers leaking into the week timetable.
public enum TimelineRowKind: String, CaseIterable, Sendable {
    case calendar
    case location
    case movement
    case sleep
    case activity
    case unconfirmed
    case appUsage
    case weather
    case photo
    case memo

    public var title: String {
        switch self {
        case .calendar: "일정"
        case .location: "위치"
        case .movement: "이동"
        case .sleep: "수면"
        case .activity: "활동"
        case .unconfirmed: "미확인"
        case .appUsage: "어플"
        case .weather: "날씨"
        case .photo: "사진"
        case .memo: "메모"
        }
    }

    public var systemImage: String {
        switch self {
        case .calendar: "calendar"
        case .location: "mappin.and.ellipse"
        case .movement: "figure.walk.motion"
        case .sleep: "moon.zzz"
        case .activity: "figure.run"
        case .unconfirmed: "questionmark.circle"
        case .appUsage: "app.badge.clock"
        case .weather: "cloud.sun"
        case .photo: "photo"
        case .memo: "note.text"
        }
    }

    /// Records carry a category identifier, which is the row identifier for
    /// every automatic lane except the calendar lane.
    public init?(categoryID: String) {
        switch categoryID {
        case "schedule": self = .calendar
        default:
            guard let value = TimelineRowKind(rawValue: categoryID) else {
                return nil
            }
            self = value
        }
    }

    public static func title(forCategoryID id: String) -> String? {
        TimelineRowKind(categoryID: id)?.title
    }
}

/// Stable identifiers shared by the timeline row labels and detail cards.
/// Keeping this order in the model lets the UI persist one ordering for both
/// surfaces without coupling storage to SwiftUI view types.
public enum TimelineRowOrder {
    public static let defaults = [
        TimelineRowKind.calendar.rawValue,
        TimelineRowKind.location.rawValue,
        TimelineRowKind.movement.rawValue,
        TimelineRowKind.sleep.rawValue,
        TimelineRowKind.activity.rawValue,
        TimelineRowKind.appUsage.rawValue,
        TimelineRowKind.weather.rawValue,
        TimelineRowKind.photo.rawValue,
        TimelineRowKind.memo.rawValue,
    ]

    public static func ordered<T>(
        _ values: [T],
        id: (T) -> String,
        savedIDs: [String]
    ) -> [T] {
        let rank = Dictionary(
            uniqueKeysWithValues: savedIDs.enumerated().map { ($1, $0) }
        )
        return values.enumerated().sorted { lhs, rhs in
            let left = rank[id(lhs.element)] ?? savedIDs.count + lhs.offset
            let right = rank[id(rhs.element)] ?? savedIDs.count + rhs.offset
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    public static func moved(
        _ values: [String],
        sourceID: String,
        targetID: String,
        savedIDs: [String]
    ) -> [String]? {
        let current = ordered(values, id: { $0 }, savedIDs: savedIDs)
        guard sourceID != targetID,
              let source = current.firstIndex(of: sourceID),
              let target = current.firstIndex(of: targetID) else {
            return nil
        }
        var result = current
        let value = result.remove(at: source)
        // A drop on a row means "place before this row". Removing an item
        // above the target shifts that target one slot to the left.
        let destination = target > source ? target - 1 : target
        result.insert(value, at: min(destination, result.count))
        return result
    }
}

public struct TimelineViewport: Codable, Hashable, Sendable {
    public var dayStart: Date
    public var visibleSpan: TimeInterval
    public var horizontalOffset: TimeInterval
    public var currentTime: Date
    public var followsCurrentTime: Bool

    public init(
        dayStart: Date,
        visibleSpan: TimeInterval = 15 * 3_600,
        horizontalOffset: TimeInterval = 6 * 3_600,
        currentTime: Date = .now,
        followsCurrentTime: Bool = true
    ) {
        self.dayStart = dayStart
        self.visibleSpan = max(60, visibleSpan)
        self.horizontalOffset = max(0, horizontalOffset)
        self.currentTime = currentTime
        self.followsCurrentTime = followsCurrentTime
    }
}
