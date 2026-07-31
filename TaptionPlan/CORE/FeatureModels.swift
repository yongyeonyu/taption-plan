import Foundation

// MARK: - Shared domain vocabulary

enum TimelineLevel: String, Codable, CaseIterable, Sendable {
    case day
    case week
    case month
    case year
}

enum PlanStatus: String, Codable, CaseIterable, Sendable {
    case planned
    case running
    case completed
    case skipped
}

enum PlanOrigin: String, Codable, CaseIterable, Sendable {
    case user
    case calendar
    case health
    case photo
    case location
    case motion
}

enum ActualSource: String, Codable, CaseIterable, Sendable {
    case manual
    case timer
    case healthKit
    case calendar
    case location
    case photo
}

enum ConfidenceLevel: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high

    init(score: Double) {
        switch score {
        case 0.75...:
            self = .high
        case 0.45..<0.75:
            self = .medium
        default:
            self = .low
        }
    }
}

enum MemoKind: String, Codable, CaseIterable, Sendable {
    case decision
    case idea
    case blocker
    case nextAction
}

enum AttachmentKind: String, Codable, CaseIterable, Sendable {
    case photo
    case audio
}

enum TravelMode: String, Codable, CaseIterable, Sendable {
    case walking
    case running
    case cycling
    case bus
    case subway
    case taxi
    case car
    case train
    case airplane
    case ship
}

enum CatStyle: String, Codable, CaseIterable, Sendable {
    case white
    case calico
    case mackerel
    case black
    case gray
    case cheese
    case cow
}

enum CategoryIcon: String, Codable, CaseIterable, Sendable {
    case briefcase
    case building
    case book
    case graduation
    case target
    case award
    case stroller
    case family
    case shield
    case health
    case exercise
    case sleep
    case performance
    case music
    case travel
    case location
    case photo
    case home
    case meal
    case cafe
    case pet
    case shopping
    case nature
    case calendar
    case memo
}

enum PermissionFeature: String, Codable, CaseIterable, Sendable {
    case photos
    case calendar
    case health
    case location
    case motion
    case weather
    case microphone
    case notifications
    case cloud
}

enum PermissionState: String, Codable, CaseIterable, Sendable {
    case notDetermined
    case denied
    case limited
    case authorized
    case unavailable
}

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

    func intersection(with other: TimeSpan) -> TimeSpan? {
        let lower = max(start, other.start)
        let upper = min(end, other.end)
        guard lower < upper else { return nil }
        return TimeSpan(start: lower, end: upper)
    }

    func contains(_ date: Date) -> Bool {
        start <= date && date <= end
    }
}

struct PlanRecord: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var span: TimeSpan
    var categoryID: String
    var parentID: UUID?
    var status: PlanStatus
    var origin: PlanOrigin
    var isFixed: Bool
    var isImportant: Bool
    var externalCalendarID: String?
    var externalEventID: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        span: TimeSpan,
        categoryID: String,
        parentID: UUID? = nil,
        status: PlanStatus = .planned,
        origin: PlanOrigin = .user,
        isFixed: Bool = false,
        isImportant: Bool = false,
        externalCalendarID: String? = nil,
        externalEventID: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.span = span
        self.categoryID = categoryID
        self.parentID = parentID
        self.status = status
        self.origin = origin
        self.isFixed = isFixed
        self.isImportant = isImportant
        self.externalCalendarID = externalCalendarID
        self.externalEventID = externalEventID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct ActualRecord: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var planID: UUID?
    var title: String
    var categoryID: String
    var startedAt: Date
    var endedAt: Date?
    var source: ActualSource
    var confidence: ConfidenceLevel
    var createdAt: Date

    init(
        id: UUID = UUID(),
        planID: UUID?,
        title: String,
        categoryID: String,
        startedAt: Date,
        endedAt: Date? = nil,
        source: ActualSource,
        confidence: ConfidenceLevel = .high,
        createdAt: Date = .now
    ) {
        self.id = id
        self.planID = planID
        self.title = title
        self.categoryID = categoryID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.source = source
        self.confidence = confidence
        self.createdAt = createdAt
    }

    func span(asOf date: Date = .now) -> TimeSpan {
        TimeSpan(start: startedAt, end: endedAt ?? max(startedAt, date))
    }
}

struct MemoAttachment: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var kind: AttachmentKind
    var localIdentifier: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        kind: AttachmentKind,
        localIdentifier: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.kind = kind
        self.localIdentifier = localIdentifier
        self.createdAt = createdAt
    }
}

struct ActionMemo: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var planID: UUID
    var kind: MemoKind
    var text: String
    var attachments: [MemoAttachment]
    var isHighlightedInReview: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        planID: UUID,
        kind: MemoKind,
        text: String,
        attachments: [MemoAttachment] = [],
        isHighlightedInReview: Bool = true,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.planID = planID
        self.kind = kind
        self.text = text
        self.attachments = attachments
        self.isHighlightedInReview = isHighlightedInReview
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Categories and templates

struct CategoryDefinition: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    var icon: CategoryIcon
    var lightHex: String
    var darkHex: String
    var actualHex: String
    var sortOrder: Int
    var isHidden: Bool
    var isBuiltIn: Bool

    init(
        id: String,
        name: String,
        icon: CategoryIcon,
        lightHex: String,
        darkHex: String,
        actualHex: String,
        sortOrder: Int,
        isHidden: Bool = false,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.lightHex = lightHex
        self.darkHex = darkHex
        self.actualHex = actualHex
        self.sortOrder = sortOrder
        self.isHidden = isHidden
        self.isBuiltIn = isBuiltIn
    }
}

enum ProfileComponentKind: String, Codable, Sendable {
    case role
    case situation
    case goal
}

struct ProfileComponent: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var kind: ProfileComponentKind
    var name: String
    var categoryIDs: [String]
    var categoryDisplayNames: [String: String]
    var quickAdds: [String]
    var suggestedPermissions: [PermissionFeature: Bool]
    var reviewFocus: [String]
}

struct ProfileSelection: Codable, Hashable, Sendable {
    var roleID: String
    var situationIDs: [String]
    var goalIDs: [String]

    init(roleID: String, situationIDs: [String] = [], goalIDs: [String] = []) {
        self.roleID = roleID
        self.situationIDs = situationIDs
        self.goalIDs = goalIDs
    }
}

struct TemplateApplication: Codable, Hashable, Sendable {
    var selection: ProfileSelection
    var displayName: String
    var visibleCategoryIDs: [String]
    var categoryDisplayNames: [String: String]
    var quickAdds: [String]
    var suggestedPermissions: [PermissionFeature: Bool]
    var reviewFocus: [String]
}

// MARK: - Calendar, photo, health, weather

struct CalendarRecord: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var calendarID: String
    var title: String
    var span: TimeSpan
    var isAllDay: Bool
    var calendarTitle: String
    var calendarColorHex: String?
}

struct PhotoMoment: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var capturedAt: Date
    var pixelWidth: Int
    var pixelHeight: Int
    var isFavorite: Bool
    var isHiddenFromTimeline: Bool
    var linkedPlanID: UUID?
    var linkedPlaceID: UUID?

    init(
        id: String,
        capturedAt: Date,
        pixelWidth: Int,
        pixelHeight: Int,
        isFavorite: Bool,
        isHiddenFromTimeline: Bool,
        linkedPlanID: UUID? = nil,
        linkedPlaceID: UUID? = nil
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isFavorite = isFavorite
        self.isHiddenFromTimeline = isHiddenFromTimeline
        self.linkedPlanID = linkedPlanID
        self.linkedPlaceID = linkedPlaceID
    }
}

struct PhotoCluster: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var representative: PhotoMoment
    var photos: [PhotoMoment]

    var capturedAt: Date { representative.capturedAt }
    var additionalCount: Int { max(0, photos.count - 1) }
}

struct WeatherContext: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var observedAt: Date
    var condition: String
    var symbolName: String
    var temperatureCelsius: Double
    var precipitationChance: Double?
    var isContextOnly: Bool

    init(
        id: UUID = UUID(),
        observedAt: Date,
        condition: String,
        symbolName: String,
        temperatureCelsius: Double,
        precipitationChance: Double? = nil,
        isContextOnly: Bool = true
    ) {
        self.id = id
        self.observedAt = observedAt
        self.condition = condition
        self.symbolName = symbolName
        self.temperatureCelsius = temperatureCelsius
        self.precipitationChance = precipitationChance
        self.isContextOnly = isContextOnly
    }
}

struct HealthActual: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var kind: String
    var span: TimeSpan
    var duration: TimeInterval
    var distanceMeters: Double?
    var energyKilocalories: Double?
    var sourceName: String
    var linkedPlanID: UUID? = nil
    var linkedTitle: String? = nil
    var linkedCategoryID: String? = nil
}

// MARK: - Location and movement

struct GeoPoint: Codable, Hashable, Sendable {
    var latitude: Double
    var longitude: Double
    var altitude: Double
    var horizontalAccuracy: Double
    var verticalAccuracy: Double
}

struct FloorCalibration: Codable, Hashable, Sendable {
    var placeName: String
    var referenceFloor: Int
    var floorHeightMeters: Double
    var referencePoint: GeoPoint?
    var referenceRelativeAltitudeMeters: Double?
    var referencePressureKilopascals: Double?
    var referenceAltimeterSessionID: UUID?
    var capturedAt: Date?

    static let homeTwentiethFloor = FloorCalibration(
        placeName: "집",
        referenceFloor: 20,
        floorHeightMeters: 3,
        referencePoint: nil,
        referenceRelativeAltitudeMeters: nil,
        referencePressureKilopascals: nil,
        referenceAltimeterSessionID: nil,
        capturedAt: nil
    )

    var isCaptured: Bool {
        referencePoint != nil && capturedAt != nil
    }
}

struct CalibratedAltitudeEstimate: Codable, Hashable, Sendable {
    var floor: Int
    var seaLevelAltitudeMeters: Double
    var verticalAccuracyMeters: Double
    var confidence: ConfidenceLevel
    var evidence: [String]
}

struct PlaceStay: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var placeKey: String
    var displayName: String
    var buildingName: String?
    var floor: Int?
    var span: TimeSpan
    var confidence: ConfidenceLevel
    var point: GeoPoint?
    var isConfirmed: Bool

    init(
        id: UUID = UUID(),
        placeKey: String,
        displayName: String,
        buildingName: String? = nil,
        floor: Int? = nil,
        span: TimeSpan,
        confidence: ConfidenceLevel,
        point: GeoPoint? = nil,
        isConfirmed: Bool = false
    ) {
        self.id = id
        self.placeKey = placeKey
        self.displayName = displayName
        self.buildingName = buildingName
        self.floor = floor
        self.span = span
        self.confidence = confidence
        self.point = point
        self.isConfirmed = isConfirmed
    }
}

struct TravelSegment: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var fromPlaceID: UUID?
    var toPlaceID: UUID?
    var mode: TravelMode
    var span: TimeSpan
    var distanceMeters: Double
    var confidence: ConfidenceLevel
    var evidence: [String]
    var isConfirmed: Bool

    init(
        id: UUID = UUID(),
        fromPlaceID: UUID? = nil,
        toPlaceID: UUID? = nil,
        mode: TravelMode,
        span: TimeSpan,
        distanceMeters: Double,
        confidence: ConfidenceLevel,
        evidence: [String],
        isConfirmed: Bool = false
    ) {
        self.id = id
        self.fromPlaceID = fromPlaceID
        self.toPlaceID = toPlaceID
        self.mode = mode
        self.span = span
        self.distanceMeters = max(0, distanceMeters)
        self.confidence = confidence
        self.evidence = evidence
        self.isConfirmed = isConfirmed
    }
}

struct TravelModeCorrection: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var fromPlaceKey: String?
    var toPlaceKey: String?
    var span: TimeSpan
    var mode: TravelMode
    var inferredMode: TravelMode
    var inferredConfidence: ConfidenceLevel
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        fromPlaceKey: String? = nil,
        toPlaceKey: String? = nil,
        span: TimeSpan,
        mode: TravelMode,
        inferredMode: TravelMode,
        inferredConfidence: ConfidenceLevel,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.fromPlaceKey = fromPlaceKey
        self.toPlaceKey = toPlaceKey
        self.span = span
        self.mode = mode
        self.inferredMode = inferredMode
        self.inferredConfidence = inferredConfidence
        self.updatedAt = updatedAt
    }
}

struct FloorTransition: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var placeKey: String
    var fromFloor: Int?
    var toFloor: Int?
    var relativeAltitudeMeters: Double
    var span: TimeSpan
    var confidence: ConfidenceLevel
    var evidence: [String]
}

enum MotionKind: String, Codable, CaseIterable, Sendable {
    case stationary
    case walking
    case running
    case cycling
    case automotive
    case unknown
}

struct SensorReading: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var timestamp: Date
    var point: GeoPoint?
    var speedMetersPerSecond: Double?
    var courseDegrees: Double?
    var motion: MotionKind
    var motionConfidence: ConfidenceLevel
    var relativeAltitudeMeters: Double?
    var pressureKilopascals: Double?
    var altimeterSessionID: UUID?
    var floorsAscended: Int?
    var floorsDescended: Int?
    var stepCount: Int?
    var walkingRunningDistanceMeters: Double?
    var deviceMotion: DeviceMotionSnapshot?
    var systemFloor: Int?
    var gpsAvailable: Bool
    var nearbyStation: Bool
    var matchesRailRoute: Bool
    var matchesPublicTransitRoute: Bool
    var frequentStops: Bool
    var rideHailingHint: Bool
    var nearAirport: Bool
    var nearPort: Bool
    var onWater: Bool
    var watchWorkoutKind: String?

    init(
        id: UUID = UUID(),
        timestamp: Date,
        point: GeoPoint? = nil,
        speedMetersPerSecond: Double? = nil,
        courseDegrees: Double? = nil,
        motion: MotionKind = .unknown,
        motionConfidence: ConfidenceLevel = .low,
        relativeAltitudeMeters: Double? = nil,
        pressureKilopascals: Double? = nil,
        altimeterSessionID: UUID? = nil,
        floorsAscended: Int? = nil,
        floorsDescended: Int? = nil,
        stepCount: Int? = nil,
        walkingRunningDistanceMeters: Double? = nil,
        deviceMotion: DeviceMotionSnapshot? = nil,
        systemFloor: Int? = nil,
        gpsAvailable: Bool = true,
        nearbyStation: Bool = false,
        matchesRailRoute: Bool = false,
        matchesPublicTransitRoute: Bool = false,
        frequentStops: Bool = false,
        rideHailingHint: Bool = false,
        nearAirport: Bool = false,
        nearPort: Bool = false,
        onWater: Bool = false,
        watchWorkoutKind: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.point = point
        self.speedMetersPerSecond = speedMetersPerSecond
        self.courseDegrees = courseDegrees
        self.motion = motion
        self.motionConfidence = motionConfidence
        self.relativeAltitudeMeters = relativeAltitudeMeters
        self.pressureKilopascals = pressureKilopascals
        self.altimeterSessionID = altimeterSessionID
        self.floorsAscended = floorsAscended
        self.floorsDescended = floorsDescended
        self.stepCount = stepCount
        self.walkingRunningDistanceMeters = walkingRunningDistanceMeters
        self.deviceMotion = deviceMotion
        self.systemFloor = systemFloor
        self.gpsAvailable = gpsAvailable
        self.nearbyStation = nearbyStation
        self.matchesRailRoute = matchesRailRoute
        self.matchesPublicTransitRoute = matchesPublicTransitRoute
        self.frequentStops = frequentStops
        self.rideHailingHint = rideHailingHint
        self.nearAirport = nearAirport
        self.nearPort = nearPort
        self.onWater = onWater
        self.watchWorkoutKind = watchWorkoutKind
    }
}

struct MovementInference: Codable, Hashable, Sendable {
    var mode: TravelMode
    var confidence: ConfidenceLevel
    var score: Double
    var evidence: [String]
}

// MARK: - Summaries, review, widget, and settings

struct CategoryDuration: Identifiable, Codable, Hashable, Sendable {
    var id: String { categoryID }
    var categoryID: String
    var planned: TimeInterval
    var actual: TimeInterval
}

struct SummaryBucket: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var span: TimeSpan
    var categories: [CategoryDuration]
    var photoCount: Int
    var representativePhotoID: String?

    var plannedDuration: TimeInterval {
        categories.reduce(0) { $0 + $1.planned }
    }

    var actualDuration: TimeInterval {
        categories.reduce(0) { $0 + $1.actual }
    }
}

struct GoalRollup: Codable, Hashable, Sendable {
    var goalID: UUID
    var descendantCount: Int
    var plannedDuration: TimeInterval
    var actualDuration: TimeInterval
    var categories: [CategoryDuration]
}

struct ReviewContext: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var date: Date
    var symbolName: String
    var text: String
    var linkedPlanID: UUID?
}

struct ReviewReport: Codable, Hashable, Sendable {
    var span: TimeSpan
    var plannedDuration: TimeInterval
    var actualDuration: TimeInterval
    var categories: [CategoryDuration]
    var unplannedActualDuration: TimeInterval
    var contexts: [ReviewContext]
}

struct TimelineViewport: Codable, Hashable, Sendable {
    var dayStart: Date
    var visibleSpan: TimeInterval
    var horizontalOffset: TimeInterval
    var currentTime: Date
    var followsCurrentTime: Bool

    init(
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

enum WidgetAction: String, Codable, CaseIterable, Sendable {
    case complete
    case postponeThirtyMinutes
    case moveToNextFreeTime
    case stopCurrentActivity
}

struct WidgetTimelineItem: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var span: TimeSpan
    var categoryID: String
    var isCurrent: Bool
}

struct WidgetSnapshot: Codable, Hashable, Sendable {
    var generatedAt: Date
    var viewport: TimeSpan
    var items: [WidgetTimelineItem]
    var availableActions: [WidgetAction]
    var catStyle: CatStyle
    var catIsRunning: Bool
    var hidesSensitiveContent: Bool
}

struct AppFeatureSettings: Codable, Hashable, Sendable {
    var startScale: TimelineLevel
    var rememberLastScale: Bool
    var catStyle: CatStyle
    var reduceMotion: Bool
    var showsPhotos: Bool
    var showsPhotosInWidgets: Bool
    var selectedCalendarIDs: [String]
    var healthEnabled: Bool
    var locationEnabled: Bool
    var backgroundPreciseLocationEnabled: Bool
    var sensorCollectionProfile: SensorCollectionProfile
    var floorCalibration: FloorCalibration?
    var movementCorrections: [TravelModeCorrection]
    var weatherEnabled: Bool
    var notificationsEnabled: Bool
    var permissions: [PermissionFeature: PermissionState]

    static let defaults = AppFeatureSettings(
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
        floorCalibration: .homeTwentiethFloor,
        movementCorrections: [],
        weatherEnabled: false,
        notificationsEnabled: false,
        permissions: Dictionary(
            uniqueKeysWithValues: PermissionFeature.allCases.map { ($0, .notDetermined) }
        )
    )

    init(
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
        floorCalibration: FloorCalibration? = .homeTwentiethFloor,
        movementCorrections: [TravelModeCorrection] = [],
        weatherEnabled: Bool,
        notificationsEnabled: Bool,
        permissions: [PermissionFeature: PermissionState]
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
        self.floorCalibration = floorCalibration
        self.movementCorrections = movementCorrections
        self.weatherEnabled = weatherEnabled
        self.notificationsEnabled = notificationsEnabled
        self.permissions = permissions
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
        case floorCalibration
        case movementCorrections
        case weatherEnabled
        case notificationsEnabled
        case permissions
    }

    init(from decoder: Decoder) throws {
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
        sensorCollectionProfile = try values.decodeIfPresent(
            SensorCollectionProfile.self,
            forKey: .sensorCollectionProfile
        ) ?? defaults.sensorCollectionProfile
        floorCalibration = try values.decodeIfPresent(
            FloorCalibration.self,
            forKey: .floorCalibration
        ) ?? defaults.floorCalibration
        movementCorrections = try values.decodeIfPresent(
            [TravelModeCorrection].self,
            forKey: .movementCorrections
        ) ?? defaults.movementCorrections
        weatherEnabled = try values.decodeIfPresent(
            Bool.self,
            forKey: .weatherEnabled
        ) ?? defaults.weatherEnabled
        notificationsEnabled = try values.decodeIfPresent(
            Bool.self,
            forKey: .notificationsEnabled
        ) ?? defaults.notificationsEnabled
        permissions = try values.decodeIfPresent(
            [PermissionFeature: PermissionState].self,
            forKey: .permissions
        ) ?? defaults.permissions
        for feature in PermissionFeature.allCases
        where permissions[feature] == nil {
            permissions[feature] = .notDetermined
        }
    }
}

struct TaptionDataSnapshot: Codable, Hashable, Sendable {
    var schemaVersion: Int
    var updatedAt: Date
    var plans: [PlanRecord]
    var actuals: [ActualRecord]
    var memos: [ActionMemo]
    var categories: [CategoryDefinition]
    var photos: [PhotoMoment]
    var calendarEvents: [CalendarRecord]
    var weather: [WeatherContext]
    var places: [PlaceStay]
    var travel: [TravelSegment]
    var floorTransitions: [FloorTransition]
    var profile: ProfileSelection?
    var settings: AppFeatureSettings

    static let empty = TaptionDataSnapshot(
        schemaVersion: 1,
        updatedAt: .distantPast,
        plans: [],
        actuals: [],
        memos: [],
        categories: [],
        photos: [],
        calendarEvents: [],
        weather: [],
        places: [],
        travel: [],
        floorTransitions: [],
        profile: nil,
        settings: .defaults
    )
}
