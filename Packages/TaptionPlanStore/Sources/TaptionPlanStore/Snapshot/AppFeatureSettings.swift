import Foundation
import TaptionWatchSync
import TaptionPlanCore

public struct AppFeatureSettings: Codable, Hashable, Sendable {
    public var startScale: TimelineLevel
    public var rememberLastScale: Bool
    public var catStyle: CatStyle
    public var reduceMotion: Bool
    public var showsPhotos: Bool
    public var showsPhotosInWidgets: Bool
    public var selectedCalendarIDs: [String]
    public var healthEnabled: Bool
    public var locationEnabled: Bool
    public var backgroundPreciseLocationEnabled: Bool
    public var sensorCollectionProfile: SensorCollectionProfile
    public var gpsLoggingPreferences: GPSLoggingPreferences
    /// 장소 도감의 여행 일정(PLB1109A03). 옛 저장본에는 없다.
    /// 비어 있으면 저장하지 않는다. 예전 기록·백업과 저장 바이트를 똑같이 둔다(TRP1110A02).
    @OmitIfEmpty public var travelPlanStops: [TravelPlanStop]
    /// AI로 만든 여행의 시간 일정과 현지 시차(TRP1110A01). 시간 막대를 현지 벽시계로 그린다.
    /// 없으면 nil이라 저장하지 않는다(예전 기록·백업 바이트를 그대로 둔다).
    public var travelTripItems: [TravelTripItem]?
    /// 여행 단위(TVA1111A01): 이름·기간·여행지·통화. 일정·핀·가계부 여행 장부가 같은 번호를 쓴다.
    /// 없으면 nil이라 저장하지 않는다(예전 기록·백업 바이트를 그대로 둔다).
    public var travelTrips: [TravelTrip]?
    /// Optional user-selected overrides for the automatic major
    /// categories. Missing values intentionally keep the shared defaults.
    public var mapCategoryColors: [String: String]
    public var mapUserActivityCategories: [MapUserActivityCategory]
    // RPG 판타지 지도(무료 OpenFreeMap 벡터)를 기본으로 쓴다. 예전에는 벡터
    // 재생 경로가 준비되지 않아 항상 .standard(Apple)로 되돌렸으나, 이제
    // 벡터 스타일 선택을 허용한다. 알 수 없는 값만 안전값으로 보정.
    public var mapDisplayStyle: MapDisplayStyle
    public var mapMemoDisplayFilter: MapMemoDisplayFilter
    public var watchAccelerationProfile: TaptionWatchAccelerationProfile
    public var watchDataSyncProfile: TaptionWatchDataSyncProfile
    public var floorCalibration: FloorCalibration?
    public var floorCalibrationHistory: [FloorCalibrationEvent]
    public var frequentPlaces: [FrequentPlace]
    public var userTransitLocations: [UserTransitLocation]
    /// 지도상의 3분 이상 교통 장소 후보에 대한 사용자 확인·삭제 기록.
    /// 원본 센서와 지도 POI는 저장하지 않고 이 결정만 기기에 남긴다.
    public var transitBoardingDecisions: [TransitBoardingDecision]
    public var predictedRouteDecisions: [MapPredictedRouteDecision]
    /// 기기 위치 기록에서만 나오는 값이라 iCloud로 내보내지 않는다.
    public var dismissedPlaceSuggestions: [DismissedPlaceSuggestion]
    public var movementCorrections: [TravelModeCorrection]
    public var suppressedActualIDs: Set<UUID>
    /// 일정 제목(정규화)별 상세활동. 사용자가 고른 값이다. 기기에만 둔다(CAL1103A01).
    public var calendarTitleDetails: [String: CalendarTitleDetail]
    /// Prevents a deliberate deletion from being mistaken for local data loss
    /// when an older CloudKit snapshot is used as a recovery source.
    public var cloudDeletedRecordKeys: Set<String>
    /// A full reset invalidates every cloud record written before this time.
    public var cloudResetAt: Date?
    public var weatherEnabled: Bool
    public var weatherSidebarVisible: Bool
    public var notificationsEnabled: Bool
    public var permissions: [PermissionFeature: PermissionState]
    public var timelineRowOrder: [String]
    /// 사용자 교정은 원본 센서와 분리한 표시용 파생값이다.
    public var activityCorrections: [UUID: ActivityCorrection]
    public var customActivityLabels: [String]
    /// UUID가 바뀌는 자동 재분류 뒤에도 유지되는 사용자 확인 수면 구간.
    public var confirmedSleepSpans: [TimeSpan]
    /// 내 차로 등록한 차량 오디오 기기 이름. 연결된 이동은 자동차로 확정한다(CAR1029A01).
    public var registeredCarAudioNames: [String]
    /// 연결·해제가 이동과 맞아떨어진 미등록 기기, 최근 순 최대 10개.
    public var recentCarAudioNames: [String]
    /// 「내 차로 등록할까요?」에 아니요라고 한 기기. 다시 묻지 않는다(CAR1111A01).
    @OmitIfEmpty public var dismissedCarAudioNames: [String]

    public static let defaults = AppFeatureSettings(
        startScale: .day,
        rememberLastScale: false,
        catStyle: .calico,
        reduceMotion: false,
        showsPhotos: false,
        showsPhotosInWidgets: false,
        selectedCalendarIDs: [],
        healthEnabled: false,
        locationEnabled: false,
        backgroundPreciseLocationEnabled: false,
        sensorCollectionProfile: .balanced,
        gpsLoggingPreferences: .standard,
        mapCategoryColors: [:],
        mapUserActivityCategories: [],
        mapDisplayStyle: .mapLibreRPG,
        mapMemoDisplayFilter: .all,
        watchAccelerationProfile: .off,
        watchDataSyncProfile: .off,
        floorCalibration: nil,
        floorCalibrationHistory: [],
        frequentPlaces: FrequentPlace.defaults,
        userTransitLocations: [],
        transitBoardingDecisions: [],
        dismissedPlaceSuggestions: [],
        movementCorrections: [],
        suppressedActualIDs: [],
        calendarTitleDetails: [:],
        cloudDeletedRecordKeys: [],
        cloudResetAt: nil,
        weatherEnabled: false,
        weatherSidebarVisible: true,
        notificationsEnabled: false,
        permissions: Dictionary(
            uniqueKeysWithValues: PermissionFeature.allCases.map { ($0, .notDetermined) }
        ),
        timelineRowOrder: TimelineRowOrder.defaults,
        activityCorrections: [:],
        customActivityLabels: [],
        confirmedSleepSpans: [],
        registeredCarAudioNames: [],
        recentCarAudioNames: [],
        dismissedCarAudioNames: []
    )

    public init(
        startScale: TimelineLevel,
        rememberLastScale: Bool,
        catStyle: CatStyle,
        reduceMotion: Bool,
        showsPhotos: Bool,
        showsPhotosInWidgets: Bool,
        selectedCalendarIDs: [String],
        healthEnabled: Bool,
        locationEnabled: Bool,
        backgroundPreciseLocationEnabled: Bool,
        sensorCollectionProfile: SensorCollectionProfile,
        gpsLoggingPreferences: GPSLoggingPreferences = .standard,
        travelPlanStops: [TravelPlanStop] = [],
        mapCategoryColors: [String: String] = [:],
        mapUserActivityCategories: [MapUserActivityCategory] = [],
        mapDisplayStyle: MapDisplayStyle = .standard,
        mapMemoDisplayFilter: MapMemoDisplayFilter = .all,
        watchAccelerationProfile: TaptionWatchAccelerationProfile = .off,
        watchDataSyncProfile: TaptionWatchDataSyncProfile = .off,
        floorCalibration: FloorCalibration? = nil,
        floorCalibrationHistory: [FloorCalibrationEvent] = [],
        frequentPlaces: [FrequentPlace] = FrequentPlace.defaults,
        userTransitLocations: [UserTransitLocation] = [],
        transitBoardingDecisions: [TransitBoardingDecision] = [],
        predictedRouteDecisions: [MapPredictedRouteDecision] = [],
        dismissedPlaceSuggestions: [DismissedPlaceSuggestion] = [],
        movementCorrections: [TravelModeCorrection] = [],
        suppressedActualIDs: Set<UUID> = [],
        calendarTitleDetails: [String: CalendarTitleDetail] = [:],
        cloudDeletedRecordKeys: Set<String> = [],
        cloudResetAt: Date? = nil,
        weatherEnabled: Bool,
        weatherSidebarVisible: Bool = true,
        notificationsEnabled: Bool,
        permissions: [PermissionFeature: PermissionState],
        timelineRowOrder: [String] = TimelineRowOrder.defaults,
        activityCorrections: [UUID: ActivityCorrection] = [:],
        customActivityLabels: [String] = [],
        confirmedSleepSpans: [TimeSpan] = [],
        registeredCarAudioNames: [String] = [],
        recentCarAudioNames: [String] = [],
        dismissedCarAudioNames: [String] = []
    ) {
        self.startScale = startScale
        self.rememberLastScale = rememberLastScale
        self.catStyle = catStyle
        self.reduceMotion = reduceMotion
        self.showsPhotos = showsPhotos
        self.showsPhotosInWidgets = showsPhotosInWidgets
        self.selectedCalendarIDs = selectedCalendarIDs
        self.healthEnabled = healthEnabled
        self.locationEnabled = locationEnabled
        self.backgroundPreciseLocationEnabled = backgroundPreciseLocationEnabled
        self.sensorCollectionProfile = sensorCollectionProfile
        self.gpsLoggingPreferences = gpsLoggingPreferences
        self.travelPlanStops = travelPlanStops
        self.mapCategoryColors = Self.normalizedMapCategoryColors(
            mapCategoryColors
        )
        self.mapUserActivityCategories = Self.normalizedMapUserActivityCategories(
            mapUserActivityCategories
        )
        self.mapDisplayStyle = mapDisplayStyle.runtimeStyle
        self.mapMemoDisplayFilter = mapMemoDisplayFilter
        self.watchAccelerationProfile = watchAccelerationProfile
        self.watchDataSyncProfile = watchDataSyncProfile
        self.floorCalibration = floorCalibration
        self.floorCalibrationHistory = floorCalibrationHistory
        self.frequentPlaces = Self.mergedFrequentPlaces(frequentPlaces)
        self.userTransitLocations = userTransitLocations.map {
            var value = $0
            value.radiusMeters = 100
            return value
        }
        self.transitBoardingDecisions = transitBoardingDecisions
        self.predictedRouteDecisions = predictedRouteDecisions
        self.dismissedPlaceSuggestions = dismissedPlaceSuggestions
        self.movementCorrections = movementCorrections
        self.suppressedActualIDs = suppressedActualIDs
        self.calendarTitleDetails = calendarTitleDetails
        self.cloudDeletedRecordKeys = cloudDeletedRecordKeys
        self.cloudResetAt = cloudResetAt
        self.weatherEnabled = weatherEnabled
        self.weatherSidebarVisible = weatherSidebarVisible
        self.notificationsEnabled = notificationsEnabled
        self.permissions = permissions
        self.timelineRowOrder = Self.normalizedTimelineRowOrder(timelineRowOrder)
        self.activityCorrections = activityCorrections
        self.customActivityLabels = Self.normalizedActivityLabels(customActivityLabels)
        self.confirmedSleepSpans = Self.normalizedConfirmedSleepSpans(
            confirmedSleepSpans
        )
        self.registeredCarAudioNames = Self.normalizedCarAudioNames(registeredCarAudioNames)
        self.recentCarAudioNames = Self.normalizedCarAudioNames(recentCarAudioNames)
        self.dismissedCarAudioNames = Self.normalizedCarAudioNames(dismissedCarAudioNames)
    }

    private enum CodingKeys: String, CodingKey {
        case startScale
        case rememberLastScale
        case catStyle
        case reduceMotion
        case showsPhotos
        case showsPhotosInWidgets
        case selectedCalendarIDs
        case healthEnabled
        case locationEnabled
        case backgroundPreciseLocationEnabled
        case sensorCollectionProfile
        case gpsLoggingPreferences
        case travelPlanStops
        case travelTripItems
        case travelTrips
        case mapCategoryColors
        case mapUserActivityCategories
        case mapDisplayStyle
        case mapMemoDisplayFilter
        case watchAccelerationProfile
        case watchDataSyncProfile
        case floorCalibration
        case floorCalibrationHistory
        case frequentPlaces
        case userTransitLocations
        case transitBoardingDecisions
        case predictedRouteDecisions
        case dismissedPlaceSuggestions
        case movementCorrections
        case suppressedActualIDs
        case calendarTitleDetails
        case cloudDeletedRecordKeys
        case cloudResetAt
        case weatherEnabled
        case weatherSidebarVisible
        case notificationsEnabled
        case permissions
        case timelineRowOrder
        case activityCorrections
        case customActivityLabels
        case confirmedSleepSpans
        case registeredCarAudioNames
        case recentCarAudioNames
        case dismissedCarAudioNames
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.defaults
        startScale = try values.decodeIfPresent(
            TimelineLevel.self,
            forKey: .startScale
        ) ?? defaults.startScale
        rememberLastScale = try values.decodeIfPresent(
            Bool.self,
            forKey: .rememberLastScale
        ) ?? defaults.rememberLastScale
        catStyle = try values.decodeIfPresent(
            CatStyle.self,
            forKey: .catStyle
        ) ?? defaults.catStyle
        reduceMotion = try values.decodeIfPresent(
            Bool.self,
            forKey: .reduceMotion
        ) ?? defaults.reduceMotion
        showsPhotos = try values.decodeIfPresent(
            Bool.self,
            forKey: .showsPhotos
        ) ?? defaults.showsPhotos
        showsPhotosInWidgets = try values.decodeIfPresent(
            Bool.self,
            forKey: .showsPhotosInWidgets
        ) ?? defaults.showsPhotosInWidgets
        selectedCalendarIDs = try values.decodeIfPresent(
            [String].self,
            forKey: .selectedCalendarIDs
        ) ?? defaults.selectedCalendarIDs
        healthEnabled = try values.decodeIfPresent(
            Bool.self,
            forKey: .healthEnabled
        ) ?? defaults.healthEnabled
        locationEnabled = try values.decodeIfPresent(
            Bool.self,
            forKey: .locationEnabled
        ) ?? defaults.locationEnabled
        backgroundPreciseLocationEnabled = try values.decodeIfPresent(
            Bool.self,
            forKey: .backgroundPreciseLocationEnabled
        ) ?? defaults.backgroundPreciseLocationEnabled
        // 기록 간격 메뉴를 없애고 값을 고정했다(대표 결정 2026-11-09). 옛 저장 값과 백업의 값은 읽지 않는다.
        sensorCollectionProfile = defaults.sensorCollectionProfile
        gpsLoggingPreferences = defaults.gpsLoggingPreferences
        travelPlanStops = try values.decodeIfPresent([TravelPlanStop].self, forKey: .travelPlanStops) ?? []
        travelTripItems = try values.decodeIfPresent([TravelTripItem].self, forKey: .travelTripItems)
        travelTrips = try values.decodeIfPresent([TravelTrip].self, forKey: .travelTrips)
        mapCategoryColors = Self.normalizedMapCategoryColors(
            try values.decodeIfPresent(
                [String: String].self,
                forKey: .mapCategoryColors
            ) ?? defaults.mapCategoryColors
        )
        mapUserActivityCategories = Self.normalizedMapUserActivityCategories(
            try values.decodeIfPresent(
                [MapUserActivityCategory].self,
                forKey: .mapUserActivityCategories
            ) ?? defaults.mapUserActivityCategories
        )
        mapDisplayStyle = (try values.decodeIfPresent(
            MapDisplayStyle.self,
            forKey: .mapDisplayStyle
        ) ?? defaults.mapDisplayStyle).runtimeStyle
        mapMemoDisplayFilter = try values.decodeIfPresent(
            MapMemoDisplayFilter.self,
            forKey: .mapMemoDisplayFilter
        ) ?? defaults.mapMemoDisplayFilter
        watchAccelerationProfile = try values.decodeIfPresent(
            TaptionWatchAccelerationProfile.self,
            forKey: .watchAccelerationProfile
        ) ?? defaults.watchAccelerationProfile
        watchDataSyncProfile = try values.decodeIfPresent(
            TaptionWatchDataSyncProfile.self,
            forKey: .watchDataSyncProfile
        ) ?? defaults.watchDataSyncProfile
        floorCalibration = try values.decodeIfPresent(
            FloorCalibration.self,
            forKey: .floorCalibration
        ) ?? defaults.floorCalibration
        floorCalibrationHistory = try values.decodeIfPresent(
            [FloorCalibrationEvent].self,
            forKey: .floorCalibrationHistory
        ) ?? defaults.floorCalibrationHistory
        frequentPlaces = Self.mergedFrequentPlaces(
            try values.decodeIfPresent(
                [FrequentPlace].self,
                forKey: .frequentPlaces
            ) ?? defaults.frequentPlaces
        )
        userTransitLocations = try values.decodeIfPresent(
            [UserTransitLocation].self,
            forKey: .userTransitLocations
        ) ?? defaults.userTransitLocations
        transitBoardingDecisions = try values.decodeIfPresent(
            [TransitBoardingDecision].self,
            forKey: .transitBoardingDecisions
        ) ?? defaults.transitBoardingDecisions
        predictedRouteDecisions = try values.decodeIfPresent(
            [MapPredictedRouteDecision].self, forKey: .predictedRouteDecisions
        ) ?? defaults.predictedRouteDecisions
        dismissedPlaceSuggestions = try values.decodeIfPresent(
            [DismissedPlaceSuggestion].self,
            forKey: .dismissedPlaceSuggestions
        ) ?? defaults.dismissedPlaceSuggestions
        movementCorrections = try values.decodeIfPresent(
            [TravelModeCorrection].self,
            forKey: .movementCorrections
        ) ?? defaults.movementCorrections
        suppressedActualIDs = try values.decodeIfPresent(
            Set<UUID>.self,
            forKey: .suppressedActualIDs
        ) ?? defaults.suppressedActualIDs
        calendarTitleDetails = try values.decodeIfPresent(
            [String: CalendarTitleDetail].self,
            forKey: .calendarTitleDetails
        ) ?? defaults.calendarTitleDetails
        cloudDeletedRecordKeys = try values.decodeIfPresent(
            Set<String>.self,
            forKey: .cloudDeletedRecordKeys
        ) ?? defaults.cloudDeletedRecordKeys
        cloudResetAt = try values.decodeIfPresent(
            Date.self,
            forKey: .cloudResetAt
        ) ?? defaults.cloudResetAt
        weatherEnabled = try values.decodeIfPresent(
            Bool.self,
            forKey: .weatherEnabled
        ) ?? defaults.weatherEnabled
        weatherSidebarVisible = try values.decodeIfPresent(
            Bool.self,
            forKey: .weatherSidebarVisible
        ) ?? defaults.weatherSidebarVisible
        notificationsEnabled = try values.decodeIfPresent(
            Bool.self,
            forKey: .notificationsEnabled
        ) ?? defaults.notificationsEnabled
        permissions = try values.decodeIfPresent(
            [PermissionFeature: PermissionState].self,
            forKey: .permissions
        ) ?? defaults.permissions
        timelineRowOrder = Self.normalizedTimelineRowOrder(
            try values.decodeIfPresent(
                [String].self,
                forKey: .timelineRowOrder
            ) ?? defaults.timelineRowOrder
        )
        activityCorrections = try values.decodeIfPresent(
            [UUID: ActivityCorrection].self,
            forKey: .activityCorrections
        ) ?? defaults.activityCorrections
        customActivityLabels = Self.normalizedActivityLabels(
            try values.decodeIfPresent(
                [String].self,
                forKey: .customActivityLabels
            ) ?? defaults.customActivityLabels
        )
        confirmedSleepSpans = Self.normalizedConfirmedSleepSpans(
            try values.decodeIfPresent(
                [TimeSpan].self,
                forKey: .confirmedSleepSpans
            ) ?? defaults.confirmedSleepSpans
        )
        registeredCarAudioNames = Self.normalizedCarAudioNames(
            try values.decodeIfPresent([String].self, forKey: .registeredCarAudioNames)
                ?? defaults.registeredCarAudioNames
        )
        recentCarAudioNames = Self.normalizedCarAudioNames(
            try values.decodeIfPresent([String].self, forKey: .recentCarAudioNames)
                ?? defaults.recentCarAudioNames
        )
        dismissedCarAudioNames = Self.normalizedCarAudioNames(
            try values.decodeIfPresent([String].self, forKey: .dismissedCarAudioNames)
                ?? defaults.dismissedCarAudioNames
        )
        for feature in PermissionFeature.allCases
        where permissions[feature] == nil {
            permissions[feature] = .notDetermined
        }
    }

    public static func mergedFrequentPlaces(
        _ places: [FrequentPlace]
    ) -> [FrequentPlace] {
        var result = places
        for item in FrequentPlace.defaults where !result.contains(where: {
            $0.kind == item.kind && $0.kind != .custom
        }) {
            result.append(item)
        }
        return result
    }

    public static func normalizedTimelineRowOrder(_ ids: [String]) -> [String] {
        var result: [String] = []
        for id in ids + TimelineRowOrder.defaults
        where !id.isEmpty && !result.contains(id) {
            result.append(id)
        }
        return result
    }

    public static func normalizedActivityLabels(_ labels: [String]) -> [String] {
        var result: [String] = []
        for label in labels {
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !result.contains(where: {
                      $0.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
                  }) else { continue }
            result.append(trimmed)
        }
        return result
    }

    /// 기기 이름은 iOS가 보고한 그대로 두고 공백·중복만 거른다.
    public static func normalizedCarAudioNames(_ names: [String]) -> [String] {
        var result: [String] = []
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !result.contains(trimmed) else { continue }
            result.append(trimmed)
        }
        return result
    }

    public static func normalizedConfirmedSleepSpans(
        _ spans: [TimeSpan]
    ) -> [TimeSpan] {
        let ordered = spans
            .filter { $0.duration > 0 }
            .sorted { $0.start < $1.start }
        var result: [TimeSpan] = []
        for span in ordered {
            guard let previous = result.last,
                  span.start <= previous.end else {
                result.append(span)
                continue
            }
            result[result.count - 1] = TimeSpan(
                start: previous.start,
                end: max(previous.end, span.end)
            )
        }
        return result
    }

    public static func normalizedMapUserActivityCategories(
        _ categories: [MapUserActivityCategory]
    ) -> [MapUserActivityCategory] {
        var result: [MapUserActivityCategory] = []
        for category in categories {
            var value = category
            value.title = value.title.trimmingCharacters(in: .whitespacesAndNewlines)
            value.systemImage = value.systemImage.trimmingCharacters(in: .whitespacesAndNewlines)
            value.hex = value.hex.uppercased()
            guard !value.title.isEmpty,
                  !value.systemImage.isEmpty,
                  value.hex.count == 7,
                  value.hex.first == "#",
                  value.hex.dropFirst().allSatisfy({ $0.isHexDigit }),
                  !result.contains(where: {
                      $0.title.localizedCaseInsensitiveCompare(value.title) == .orderedSame
                  })
            else { continue }
            result.append(value)
        }
        return result
    }

    public static func normalizedMapCategoryColors(
        _ values: [String: String]
    ) -> [String: String] {
        let allowed = Set(RecordClassificationCatalog.categories.map(\.id))
        return values.reduce(into: [:]) { result, item in
            let hex = item.value.uppercased()
            guard allowed.contains(item.key),
                  hex.count == 7,
                  hex.first == "#",
                  hex.dropFirst().allSatisfy({ $0.isHexDigit }) else {
                return
            }
            result[item.key] = hex
        }
    }
}

/// 일정 제목에 붙인 상세활동. `detailID`가 nil이면 "분류 안 함"이다.
public struct CalendarTitleDetail: Codable, Hashable, Sendable {
    public var detailID: String?

    public init(
        detailID: String? = nil
    ) {
        self.detailID = detailID
    }
}

/// AI로 만든 여행의 일정 한 칸. 시작·끝마다 그곳의 UTC 차(초)를 함께 둔다.
public struct TravelTripItem: Codable, Hashable, Sendable {
    public var tripID: String
    public var itemID: String
    public var kind: String
    public var title: String
    public var start: Date
    public var end: Date
    public var startOffsetSeconds: Int
    public var endOffsetSeconds: Int
    public var planID: UUID?
    /// 예약 "booked"·미정 "tentative"만 둔다. 계획은 nil이라 키가 없고 예전 바이트가 그대로다(TRP1110A09).
    public var status: String?
    /// 일정 메모(TVY1112A01). 없으면 키를 쓰지 않아 예전 바이트가 그대로다.
    public var note: String?
    /// 일정 색(TVU1113A01, `#RRGGBB`). 없으면 종류 기본 색이고 키를 쓰지 않아 예전 바이트가 그대로다.
    public var colorHex: String?
    /// 예상 지출(원, 0보다 큰 값만). 없으면 키를 쓰지 않는다.
    public var plannedSpendKRW: Double?

    public init(tripID: String, itemID: String, kind: String, title: String, start: Date, end: Date, startOffsetSeconds: Int, endOffsetSeconds: Int, planID: UUID?, status: String? = nil, note: String? = nil, colorHex: String? = nil, plannedSpendKRW: Double? = nil) {
        self.tripID = tripID
        self.itemID = itemID
        self.kind = kind
        self.title = title
        self.start = start
        self.end = end
        self.startOffsetSeconds = startOffsetSeconds
        self.endOffsetSeconds = endOffsetSeconds
        self.planID = planID
        self.status = status
        self.note = note
        self.colorHex = colorHex
        self.plannedSpendKRW = plannedSpendKRW
    }

    /// 저장할 색: `#RRGGBB`(대문자)만. 그 밖의 글은 nil(기본 색).
    public static func cleanColorHex(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespaces).uppercased(), text.count == 7, text.hasPrefix("#"),
              text.dropFirst().allSatisfy({ $0.isHexDigit }) else { return nil }
        return text
    }

    /// 저장할 예상 지출: 0보다 크고 유한한 값만(원 단위로 반올림).
    public static func cleanPlannedSpend(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0.5 else { return nil }
        return value.rounded()
    }
}

/// 여행 일정 한 곳. 하루 안에서 `order` 순서로 잇는다.
public struct TravelPlanStop: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var latitude: Double
    public var longitude: Double
    public var day: Date
    public var order: Int
    public var planID: UUID?
    /// AI로 만든 여행의 번호와 항목 번호(TRP1110A01). 같은 여행을 다시 붙이면 이 번호로 찾아 바꾼다. 예전 기록에는 없다.
    public var tripID: String?
    public var itemID: String?
    /// 여행 일정 상태(TRP1110A09). 계획은 nil로 둬 키를 쓰지 않는다.
    public var status: String?

    public init(id: UUID, title: String, latitude: Double, longitude: Double, day: Date, order: Int, planID: UUID?, tripID: String? = nil, itemID: String? = nil, status: String? = nil) {
        self.id = id
        self.title = title
        self.latitude = latitude
        self.longitude = longitude
        self.day = day
        self.order = order
        self.planID = planID
        self.tripID = tripID
        self.itemID = itemID
        self.status = status
    }
}

/// 비어 있으면 키째 저장하지 않는 배열. 나중에 더한 항목이 예전 저장 바이트를 바꾸지 않게 한다.
@propertyWrapper
public struct OmitIfEmpty<Element: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    public var wrappedValue: [Element]

    public init(wrappedValue: [Element]) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: Decoder) throws {
        wrappedValue = try [Element](from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try wrappedValue.encode(to: encoder)
    }
}

extension KeyedEncodingContainer {
    mutating func encode<Element>(_ value: OmitIfEmpty<Element>, forKey key: Key) throws {
        guard !value.wrappedValue.isEmpty else { return }
        try encode(value.wrappedValue, forKey: key)
    }
}

extension KeyedDecodingContainer {
    func decode<Element>(_ type: OmitIfEmpty<Element>.Type, forKey key: Key) throws -> OmitIfEmpty<Element> {
        OmitIfEmpty(wrappedValue: try decodeIfPresent([Element].self, forKey: key) ?? [])
    }
}
