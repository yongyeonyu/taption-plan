import Foundation
import TaptionPlanCore
import TaptionWatchSync

/// 앱 전체 기록의 한 장 묶음. 저장소·백업·iCloud가 이 Codable 모양을 그대로 쓴다.
public struct TaptionDataSnapshot: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var updatedAt: Date
    public var plans: [PlanRecord]
    public var actuals: [ActualRecord]
    public var recordLinks: [RecordLink]
    public var memos: [ActionMemo]
    public var stickers: [MapSticker]
    public var categories: [CategoryDefinition]
    public var photos: [PhotoMoment]
    public var calendarEvents: [CalendarRecord]
    public var weather: [WeatherContext]
    public var places: [PlaceStay]
    public var travel: [TravelSegment]
    public var floorTransitions: [FloorTransition]
    public var yearlyReports: [YearlyReviewArchive]
    public var settings: AppFeatureSettings

    public init(
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

    public init(from decoder: Decoder) throws {
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

    public static let empty = TaptionDataSnapshot(
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
