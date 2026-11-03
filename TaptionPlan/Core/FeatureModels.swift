import Foundation
import TaptionPlanCore

/// The first product surface is an automatic life log. Manual planning data
/// remains in storage for compatibility, but is intentionally kept out of the
/// primary iPhone and widget surfaces until the automatic timeline is stable.
enum TaptionProductScope {
    static let automaticLoggingOnly = true
}

// MARK: - Shared domain vocabulary

// MARK: - Plan and actual records

struct TimeSpan: Codable, Hashable, Sendable {
    var start: Date
    var end: Date

    init(start: Date, end: Date) {
        self.start = start
        self.end = max(start, end)
    }

    var duration: TimeInterval {
        max(0, end.timeIntervalSince(start))
    }

    /// 겹치는 구간을 병합한 총 시간(같은 초를 두 번 세지 않는다).
    static func unionDuration(_ spans: [TimeSpan]) -> TimeInterval {
        let ordered = spans
            .filter { $0.duration > 0 }
            .sorted { $0.start < $1.start }
        guard var current = ordered.first else { return 0 }
        var total: TimeInterval = 0
        for span in ordered.dropFirst() {
            if span.start <= current.end {
                current.end = max(current.end, span.end)
            } else {
                total += current.duration
                current = span
            }
        }
        return total + current.duration
    }

    func intersection(with other: TimeSpan) -> TimeSpan? {
        let lower = max(start, other.start)
        let upper = min(end, other.end)
        guard lower < upper else { return nil }
        return TimeSpan(start: lower, end: upper)
    }

    /// NaN 시각이나 NaN 경계는 어떤 구간에도 속하지 않는다. Date 비교의 NaN 결과는 기기 런타임마다 다르다.
    func contains(_ date: Date) -> Bool {
        guard !date.timeIntervalSinceReferenceDate.isNaN, !isNaNBounded else { return false }
        return start <= date && date <= end
    }

    var isNaNBounded: Bool {
        start.timeIntervalSinceReferenceDate.isNaN || end.timeIntervalSinceReferenceDate.isNaN
    }
}

// MARK: - Categories and templates

// MARK: - Calendar, photo, health, weather

// MARK: - Location and movement

// MARK: - Summaries, review, widget, and settings

enum WidgetAction: String, Codable, CaseIterable, Sendable {
    case complete
    case postponeThirtyMinutes
    case moveToNextFreeTime
    case stopCurrentActivity
}

struct TaptionDataSnapshot: Codable, Hashable, Sendable {
    var schemaVersion: Int
    var updatedAt: Date
    var plans: [PlanRecord]
    var actuals: [ActualRecord]
    var recordLinks: [RecordLink]
    var memos: [ActionMemo]
    var stickers: [MapSticker]
    var categories: [CategoryDefinition]
    var photos: [PhotoMoment]
    var calendarEvents: [CalendarRecord]
    var weather: [WeatherContext]
    var places: [PlaceStay]
    var travel: [TravelSegment]
    var floorTransitions: [FloorTransition]
    var yearlyReports: [YearlyReviewArchive]
    var settings: AppFeatureSettings

    init(
        schemaVersion: Int,
        updatedAt: Date,
        plans: [PlanRecord],
        actuals: [ActualRecord],
        recordLinks: [RecordLink] = [],
        memos: [ActionMemo],
        stickers: [MapSticker] = [],
        categories: [CategoryDefinition],
        photos: [PhotoMoment],
        calendarEvents: [CalendarRecord],
        weather: [WeatherContext],
        places: [PlaceStay],
        travel: [TravelSegment],
        floorTransitions: [FloorTransition],
        yearlyReports: [YearlyReviewArchive] = [],
        settings: AppFeatureSettings
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.plans = plans
        self.actuals = actuals
        self.recordLinks = recordLinks
        self.memos = memos
        self.stickers = stickers
        self.categories = categories
        self.photos = photos
        self.calendarEvents = calendarEvents
        self.weather = weather
        self.places = places
        self.travel = travel
        self.floorTransitions = floorTransitions
        self.yearlyReports = yearlyReports
        self.settings = settings
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.empty
        schemaVersion = try values.decodeIfPresent(
            Int.self,
            forKey: .schemaVersion
        ) ?? defaults.schemaVersion
        updatedAt = try values.decodeIfPresent(
            Date.self,
            forKey: .updatedAt
        ) ?? defaults.updatedAt
        plans = try values.decodeIfPresent(
            [PlanRecord].self,
            forKey: .plans
        ) ?? defaults.plans
        actuals = try values.decodeIfPresent(
            [ActualRecord].self,
            forKey: .actuals
        ) ?? defaults.actuals
        recordLinks = try values.decodeIfPresent(
            [RecordLink].self,
            forKey: .recordLinks
        ) ?? defaults.recordLinks
        memos = try values.decodeIfPresent(
            [ActionMemo].self,
            forKey: .memos
        ) ?? defaults.memos
        stickers = try values.decodeIfPresent(
            [MapSticker].self,
            forKey: .stickers
        ) ?? defaults.stickers
        categories = try values.decodeIfPresent(
            [CategoryDefinition].self,
            forKey: .categories
        ) ?? defaults.categories
        photos = try values.decodeIfPresent(
            [PhotoMoment].self,
            forKey: .photos
        ) ?? defaults.photos
        calendarEvents = try values.decodeIfPresent(
            [CalendarRecord].self,
            forKey: .calendarEvents
        ) ?? defaults.calendarEvents
        weather = try values.decodeIfPresent(
            [WeatherContext].self,
            forKey: .weather
        ) ?? defaults.weather
        places = try values.decodeIfPresent(
            [PlaceStay].self,
            forKey: .places
        ) ?? defaults.places
        travel = try values.decodeIfPresent(
            [TravelSegment].self,
            forKey: .travel
        ) ?? defaults.travel
        floorTransitions = try values.decodeIfPresent(
            [FloorTransition].self,
            forKey: .floorTransitions
        ) ?? defaults.floorTransitions
        yearlyReports = try values.decodeIfPresent(
            [YearlyReviewArchive].self,
            forKey: .yearlyReports
        ) ?? defaults.yearlyReports
        settings = try values.decodeIfPresent(
            AppFeatureSettings.self,
            forKey: .settings
        ) ?? defaults.settings
    }

    static let empty = TaptionDataSnapshot(
        schemaVersion: 1,
        updatedAt: .distantPast,
        plans: [],
        actuals: [],
        recordLinks: [],
        memos: [],
        stickers: [],
        categories: [],
        photos: [],
        calendarEvents: [],
        weather: [],
        places: [],
        travel: [],
        floorTransitions: [],
        yearlyReports: [],
        settings: .defaults
    )
}

func distanceMeters(_ lhs: GeoPoint, _ rhs: GeoPoint) -> Double {
    let earthRadius = 6_371_000.0
    let lat1 = lhs.latitude * .pi / 180
    let lat2 = rhs.latitude * .pi / 180
    let deltaLat = (rhs.latitude - lhs.latitude) * .pi / 180
    let deltaLon = (rhs.longitude - lhs.longitude) * .pi / 180
    let a = sin(deltaLat / 2) * sin(deltaLat / 2)
        + cos(lat1) * cos(lat2)
        * sin(deltaLon / 2) * sin(deltaLon / 2)
    return earthRadius * 2 * atan2(sqrt(a), sqrt(1 - a))
}
