import Foundation

/// The first product surface is an automatic life log. Manual planning data
/// remains in storage for compatibility, but is intentionally kept out of the
/// primary iPhone and widget surfaces until the automatic timeline is stable.
enum TaptionProductScope {
    static let automaticLoggingOnly = true
}

// MARK: - Shared domain vocabulary

enum TimelineLevel: String, Codable, CaseIterable, Sendable {
    case day
    case week
    case month
    case year
}

/// The automatic timeline rows.  Row identifier, Korean label and symbol live
/// together here so every scale, every detail card and every widget reads the
/// same vocabulary. Duplicating the label tables per surface is what produced
/// English identifiers leaking into the week timetable.
enum TimelineRowKind: String, CaseIterable, Sendable {
    case calendar
    case location
    case movement
    case sleep
    case activity
    case appUsage
    case weather
    case photo

    var title: String {
        switch self {
        case .calendar: "일정"
        case .location: "위치"
        case .movement: "이동"
        case .sleep: "수면"
        case .activity: "활동"
        case .appUsage: "어플"
        case .weather: "날씨"
        case .photo: "사진"
        }
    }

    var systemImage: String {
        switch self {
        case .calendar: "calendar"
        case .location: "mappin.and.ellipse"
        case .movement: "figure.walk.motion"
        case .sleep: "moon.zzz"
        case .activity: "figure.run"
        case .appUsage: "app.badge.clock"
        case .weather: "cloud.sun"
        case .photo: "photo"
        }
    }

    /// Records carry a category identifier, which is the row identifier for
    /// every automatic lane except the calendar lane.
    init?(categoryID: String) {
        switch categoryID {
        case "schedule": self = .calendar
        default:
            guard let value = TimelineRowKind(rawValue: categoryID) else {
                return nil
            }
            self = value
        }
    }

    static func title(forCategoryID id: String) -> String? {
        TimelineRowKind(categoryID: id)?.title
    }
}

/// Stable identifiers shared by the timeline row labels and detail cards.
/// Keeping this order in the model lets the UI persist one ordering for both
/// surfaces without coupling storage to SwiftUI view types.
enum TimelineRowOrder {
    static let defaults = TimelineRowKind.allCases.map(\.rawValue)

    static func ordered<T>(
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

    static func moved(
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

enum PlanStatus: String, Codable, CaseIterable, Sendable {
    case planned
    case running
    case completed
    case skipped
}

enum PlanOrigin: String, Codable, CaseIterable, Sendable {
    case user
    case repeatRule
    case calendar
    case health
    case photo
    case location
    case motion
}

enum GoalCategoryPolicy {
    static let systemSelectableCategoryIDs: Set<String> = [
        "movement",
        "location",
        "sleep",
        "activity",
    ]
}

enum ActualSource: String, Codable, CaseIterable, Sendable {
    case manual
    case timer
    case healthKit
    case appleWatch
    /// Passive iPhone Core Motion classification. These records are derived
    /// from the immutable motion history and are not user-editable.
    case motion
    case calendar
    case location
    case photo
    /// Playback observed while an AirPods route is connected.
    case media
    /// An active phone/FaceTime call observed through CallKit while an
    /// AirPods route is connected. CallKit does not expose call history.
    case call
    /// Screen Time usage reported through the Family Controls report.
    case appUsage
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

/// A single presentation source for movement results.  Automatic movement
/// records can arrive with a generic title (for example "차량 탑승") while
/// their classifier evidence contains the actual mode.  Keeping the mapping
/// here prevents the timeline and 기록 화면 from choosing different icons.
enum MovementPresentation {
    static func mode(for actual: ActualRecord) -> TravelMode? {
        if let behavior = actual.behavior.flatMap(WatchBehaviorKind.init(rawValue:)) {
            switch behavior {
            case .walking: return .walking
            case .running: return .running
            case .cycling: return .cycling
            case .automotive: return .car
            case .publicTransit: return .bus
            case .subway: return .subway
            case .stairsUp, .stairsDown, .elevator, .stationary, .sitting,
                 .standing, .lying, .unknown:
                break
            default:
                break
            }
        }

        let text = ([actual.title, actual.behavior] + actual.evidence)
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        let keywords: [(TravelMode, [String])] = [
            (.subway, ["지하철", "subway", "metro"]),
            (.bus, ["버스", "대중교통", "정류장", "bus", "transit"]),
            (.taxi, ["택시", "taxi"]),
            (.car, ["자동차", "자가용", "차량", "차량 탑승", "car", "automotive", "driving"]),
            (.train, ["기차", "열차", "train", "rail"]),
            (.airplane, ["비행기", "항공", "airplane", "flight"]),
            (.ship, ["배", "선박", "ship", "ferry"]),
            (.cycling, ["자전거", "cycling", "bike"]),
            (.running, ["달리기", "달리", "running", "run"]),
            (.walking, ["걷기", "걷", "walking", "walk"]),
        ]
        return keywords.first { _, terms in
            terms.contains { text.contains($0) }
        }?.0
    }

    static func symbol(for actual: ActualRecord) -> String {
        if let mode = mode(for: actual) { return symbol(for: mode) }
        switch actual.behavior.flatMap(WatchBehaviorKind.init(rawValue:)) {
        case .stairsUp, .stairsDown: return "stairs"
        case .elevator: return "arrow.up.and.down"
        default: return "figure.walk.motion"
        }
    }

    static func symbol(for mode: TravelMode) -> String {
        switch mode {
        case .walking: "figure.walk.motion"
        case .running: "figure.run"
        case .cycling: "bicycle"
        case .bus: "bus.fill"
        case .subway: "tram.fill"
        case .taxi: "car.side.fill"
        case .car: "car.fill"
        case .train: "train.side.front.car"
        case .airplane: "airplane"
        case .ship: "ferry.fill"
        }
    }

    static func title(for mode: TravelMode) -> String {
        switch mode {
        case .walking: "걷기"
        case .running: "달리기"
        case .cycling: "자전거"
        case .bus: "버스"
        case .subway: "지하철"
        case .taxi: "택시"
        case .car: "자동차"
        case .train: "기차"
        case .airplane: "비행기"
        case .ship: "배"
        }
    }

    static func title(for actual: ActualRecord) -> String {
        if let behavior = actual.behavior.flatMap(WatchBehaviorKind.init(rawValue:)),
           behavior.isMovement {
            return behavior.title
        }
        return mode(for: actual).map(title(for:)) ?? actual.title
    }
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
    case event
    case memo
    case movement
    case activity
    case relationship
    case work
    case community
    case student
    case exam
    case military
    case athlete
    case pregnancy
    case caregiver
    case government
    case food
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
    case appUsage
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
    var middleCategoryName: String?
    var subCategoryName: String?
    var repeatRules: [GoalRepeatRule]?
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
        middleCategoryName: String? = nil,
        subCategoryName: String? = nil,
        repeatRules: [GoalRepeatRule]? = nil,
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
        self.middleCategoryName = middleCategoryName
        self.subCategoryName = subCategoryName
        self.repeatRules = repeatRules?.isEmpty == false ? repeatRules : nil
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

struct GoalRepeatRule: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String?
    var weekdays: Set<Int>
    var startMinuteOfDay: Int
    var endMinuteOfDay: Int

    init(
        id: UUID = UUID(),
        name: String? = nil,
        weekdays: Set<Int>,
        startMinuteOfDay: Int,
        endMinuteOfDay: Int
    ) {
        self.id = id
        self.name = name
        self.weekdays = weekdays
        self.startMinuteOfDay = startMinuteOfDay
        self.endMinuteOfDay = endMinuteOfDay
    }
}

struct ActualRecord: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var planID: UUID?
    /// The routine context for an action/automatic record.  `planID` remains
    /// the concrete action or repeat segment; this second link keeps the
    /// routine and action layers independently addressable.
    var routineID: UUID?
    var title: String
    var categoryID: String
    var startedAt: Date
    var endedAt: Date?
    var source: ActualSource
    var confidence: ConfidenceLevel
    var createdAt: Date
    /// Optional provenance from the sensor-fusion pipeline.  These fields
    /// were added after the first archive format, so older records decode with
    /// their empty defaults and remain immutable.
    var behavior: String?
    var evidence: [String]
    var routeID: UUID?
    var sensorChunkID: UUID?
    var modelVersion: String?
    var manuallyCorrected: Bool

    private enum CodingKeys: String, CodingKey {
        case id, planID, routineID, title, categoryID, startedAt, endedAt
        case source, confidence, createdAt, behavior, evidence, routeID
        case sensorChunkID, modelVersion, manuallyCorrected
    }

    init(
        id: UUID = UUID(),
        planID: UUID?,
        routineID: UUID? = nil,
        title: String,
        categoryID: String,
        startedAt: Date,
        endedAt: Date? = nil,
        source: ActualSource,
        confidence: ConfidenceLevel = .high,
        createdAt: Date = .now,
        behavior: String? = nil,
        evidence: [String] = [],
        routeID: UUID? = nil,
        sensorChunkID: UUID? = nil,
        modelVersion: String? = nil,
        manuallyCorrected: Bool = false
    ) {
        self.id = id
        self.planID = planID
        self.routineID = routineID
        self.title = title
        self.categoryID = categoryID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.source = source
        self.confidence = confidence
        self.createdAt = createdAt
        self.behavior = behavior
        self.evidence = evidence
        self.routeID = routeID
        self.sensorChunkID = sensorChunkID
        self.modelVersion = modelVersion
        self.manuallyCorrected = manuallyCorrected
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        planID = try values.decodeIfPresent(UUID.self, forKey: .planID)
        routineID = try values.decodeIfPresent(UUID.self, forKey: .routineID)
        title = try values.decode(String.self, forKey: .title)
        categoryID = try values.decode(String.self, forKey: .categoryID)
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        endedAt = try values.decodeIfPresent(Date.self, forKey: .endedAt)
        source = try values.decode(ActualSource.self, forKey: .source)
        confidence = try values.decode(
            ConfidenceLevel.self,
            forKey: .confidence
        )
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        behavior = try values.decodeIfPresent(String.self, forKey: .behavior)
        evidence = try values.decodeIfPresent([String].self, forKey: .evidence)
            ?? []
        routeID = try values.decodeIfPresent(UUID.self, forKey: .routeID)
        sensorChunkID = try values.decodeIfPresent(
            UUID.self,
            forKey: .sensorChunkID
        )
        modelVersion = try values.decodeIfPresent(
            String.self,
            forKey: .modelVersion
        )
        manuallyCorrected = try values.decodeIfPresent(
            Bool.self,
            forKey: .manuallyCorrected
        ) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encodeIfPresent(planID, forKey: .planID)
        try values.encodeIfPresent(routineID, forKey: .routineID)
        try values.encode(title, forKey: .title)
        try values.encode(categoryID, forKey: .categoryID)
        try values.encode(startedAt, forKey: .startedAt)
        try values.encodeIfPresent(endedAt, forKey: .endedAt)
        try values.encode(source, forKey: .source)
        try values.encode(confidence, forKey: .confidence)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encodeIfPresent(behavior, forKey: .behavior)
        try values.encode(evidence, forKey: .evidence)
        try values.encodeIfPresent(routeID, forKey: .routeID)
        try values.encodeIfPresent(sensorChunkID, forKey: .sensorChunkID)
        try values.encodeIfPresent(modelVersion, forKey: .modelVersion)
        try values.encode(manuallyCorrected, forKey: .manuallyCorrected)
    }

    func span(asOf date: Date = .now) -> TimeSpan {
        guard startedAt < date else {
            return TimeSpan(start: startedAt, end: startedAt)
        }
        let observedEnd = min(endedAt ?? date, date)
        return TimeSpan(start: startedAt, end: max(startedAt, observedEnd))
    }
}

/// A user-created relationship between two timeline records. The node IDs
/// use the stable prefixes emitted by `RecordRelationshipEngine`, allowing
/// calendar/place/travel records to be linked without changing their source
/// models.
struct RecordLink: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var fromNodeID: String
    var toNodeID: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        fromNodeID: String,
        toNodeID: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.fromNodeID = fromNodeID
        self.toNodeID = toNodeID
        self.createdAt = createdAt
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
    /// Stable timeline item key. Plan-backed memos keep using `planID`, while
    /// automatic records (location, travel, health, weather, photos, etc.)
    /// use this key so two records in the same category never share notes.
    var targetID: String?
    var kind: MemoKind
    var text: String
    var attachments: [MemoAttachment]
    var isHighlightedInReview: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        planID: UUID,
        targetID: String? = nil,
        kind: MemoKind,
        text: String,
        attachments: [MemoAttachment] = [],
        isHighlightedInReview: Bool = true,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.planID = planID
        self.targetID = targetID
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

// MARK: - Calendar, photo, health, weather

struct CalendarRecord: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var calendarID: String
    var title: String
    var span: TimeSpan
    var isAllDay: Bool
    var calendarTitle: String
    var calendarColorHex: String?
    var sourceTitle: String?
    /// 정지 구간 문맥 추론에서 쓰는 EventKit 부가 정보. 이전 보관본은 값이
    /// 없으므로 옵셔널로 둔다.
    var attendeeCount: Int? = nil
    var isCancelled: Bool? = nil
}

struct PhotoMoment: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var capturedAt: Date
    var pixelWidth: Int
    var pixelHeight: Int
    var isFavorite: Bool
    var isHiddenFromTimeline: Bool
    var location: GeoPoint?
    var linkedPlanID: UUID?
    var linkedPlaceID: UUID?

    init(
        id: String,
        capturedAt: Date,
        pixelWidth: Int,
        pixelHeight: Int,
        isFavorite: Bool,
        isHiddenFromTimeline: Bool,
        location: GeoPoint? = nil,
        linkedPlanID: UUID? = nil,
        linkedPlaceID: UUID? = nil
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isFavorite = isFavorite
        self.isHiddenFromTimeline = isHiddenFromTimeline
        self.location = location
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

enum AirQualityGrade: Int, Codable, CaseIterable, Comparable, Hashable, Sendable {
    case good = 0
    case moderate
    case bad
    case veryBad

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var displayName: String {
        switch self {
        case .good: "좋음"
        case .moderate: "보통"
        case .bad: "나쁨"
        case .veryBad: "매우 나쁨"
        }
    }

    static func pm10(_ value: Double) -> Self {
        switch value {
        case ...30: .good
        case ...80: .moderate
        case ...150: .bad
        default: .veryBad
        }
    }

    static func pm25(_ value: Double) -> Self {
        switch value {
        case ...15: .good
        case ...35: .moderate
        case ...75: .bad
        default: .veryBad
        }
    }
}

struct AirQualityContext: Codable, Hashable, Sendable {
    var pm10MicrogramsPerCubicMeter: Double
    var pm25MicrogramsPerCubicMeter: Double
    var pm10Grade: AirQualityGrade
    var pm25Grade: AirQualityGrade
    var overallGrade: AirQualityGrade
    var observedAt: Date
    var stationName: String?
    var providerName: String
    var isFallback: Bool

    init(
        pm10MicrogramsPerCubicMeter: Double,
        pm25MicrogramsPerCubicMeter: Double,
        observedAt: Date,
        stationName: String? = nil,
        providerName: String,
        isFallback: Bool
    ) {
        self.pm10MicrogramsPerCubicMeter = pm10MicrogramsPerCubicMeter
        self.pm25MicrogramsPerCubicMeter = pm25MicrogramsPerCubicMeter
        pm10Grade = .pm10(pm10MicrogramsPerCubicMeter)
        pm25Grade = .pm25(pm25MicrogramsPerCubicMeter)
        overallGrade = max(pm10Grade, pm25Grade)
        self.observedAt = observedAt
        self.stationName = stationName
        self.providerName = providerName
        self.isFallback = isFallback
    }
}

struct WeatherContext: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var observedAt: Date
    /// End of the displayed weather run. Raw samples remain in the device
    /// archive while equal consecutive values share one timeline segment.
    var validUntil: Date?
    /// Time at which the provider actually supplied this observation.
    var fetchedAt: Date?
    /// True when this is the last known value after a failed refresh.
    var isStale: Bool?
    var condition: String
    var symbolName: String
    var temperatureCelsius: Double
    var precipitationChance: Double?
    var placeID: UUID?
    var placeName: String?
    var point: GeoPoint?
    var isContextOnly: Bool
    var airQuality: AirQualityContext?

    init(
        id: UUID = UUID(),
        observedAt: Date,
        validUntil: Date? = nil,
        fetchedAt: Date? = nil,
        isStale: Bool? = false,
        condition: String,
        symbolName: String,
        temperatureCelsius: Double,
        precipitationChance: Double? = nil,
        placeID: UUID? = nil,
        placeName: String? = nil,
        point: GeoPoint? = nil,
        isContextOnly: Bool = true,
        airQuality: AirQualityContext? = nil
    ) {
        self.id = id
        self.observedAt = observedAt
        self.validUntil = validUntil
        self.fetchedAt = fetchedAt
        self.isStale = isStale
        self.condition = condition
        self.symbolName = symbolName
        self.temperatureCelsius = temperatureCelsius
        self.precipitationChance = precipitationChance
        self.placeID = placeID
        self.placeName = placeName
        self.point = point
        self.isContextOnly = isContextOnly
        self.airQuality = airQuality
    }

    var freshnessLabel: String {
        guard let fetchedAt else {
            return isStale == true ? "이전" : "확인됨"
        }
        let minutes = max(0, Int(Date.now.timeIntervalSince(fetchedAt) / 60))
        if minutes < 1 { return "방금" }
        if minutes < 60 { return "\(minutes)분 전" }
        let hours = minutes / 60
        return "\(hours)시간 전"
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

struct FloorCalibrationPoint: Codable, Hashable, Sendable {
    var floor: Int
    var point: GeoPoint
    var relativeAltitudeMeters: Double?
    var pressureKilopascals: Double?
    var altimeterSessionID: UUID?
    var capturedAt: Date
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
    var referencePoints: [FloorCalibrationPoint]

    static let homeTwentiethFloor = FloorCalibration(
        placeName: "집",
        referenceFloor: 20,
        floorHeightMeters: 3,
        referencePoint: nil,
        referenceRelativeAltitudeMeters: nil,
        referencePressureKilopascals: nil,
        referenceAltimeterSessionID: nil,
        capturedAt: nil,
        referencePoints: []
    )

    init(
        placeName: String,
        referenceFloor: Int,
        floorHeightMeters: Double,
        referencePoint: GeoPoint?,
        referenceRelativeAltitudeMeters: Double?,
        referencePressureKilopascals: Double?,
        referenceAltimeterSessionID: UUID?,
        capturedAt: Date?,
        referencePoints: [FloorCalibrationPoint] = []
    ) {
        self.placeName = placeName
        self.referenceFloor = referenceFloor
        self.floorHeightMeters = floorHeightMeters
        self.referencePoint = referencePoint
        self.referenceRelativeAltitudeMeters = referenceRelativeAltitudeMeters
        self.referencePressureKilopascals = referencePressureKilopascals
        self.referenceAltimeterSessionID = referenceAltimeterSessionID
        self.capturedAt = capturedAt
        self.referencePoints = referencePoints
    }

    private enum CodingKeys: String, CodingKey {
        case placeName, referenceFloor, floorHeightMeters, referencePoint
        case referenceRelativeAltitudeMeters, referencePressureKilopascals
        case referenceAltimeterSessionID, capturedAt, referencePoints
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        placeName = try values.decode(String.self, forKey: .placeName)
        referenceFloor = try values.decode(Int.self, forKey: .referenceFloor)
        floorHeightMeters = try values.decodeIfPresent(
            Double.self,
            forKey: .floorHeightMeters
        ) ?? 3
        referencePoint = try values.decodeIfPresent(
            GeoPoint.self,
            forKey: .referencePoint
        )
        referenceRelativeAltitudeMeters = try values.decodeIfPresent(
            Double.self,
            forKey: .referenceRelativeAltitudeMeters
        )
        referencePressureKilopascals = try values.decodeIfPresent(
            Double.self,
            forKey: .referencePressureKilopascals
        )
        referenceAltimeterSessionID = try values.decodeIfPresent(
            UUID.self,
            forKey: .referenceAltimeterSessionID
        )
        capturedAt = try values.decodeIfPresent(Date.self, forKey: .capturedAt)
        referencePoints = try values.decodeIfPresent(
            [FloorCalibrationPoint].self,
            forKey: .referencePoints
        ) ?? []
    }

    var isCaptured: Bool {
        (referencePoint != nil && capturedAt != nil) || !referencePoints.isEmpty
    }

    var knownFloors: Set<Int> {
        Set([referenceFloor] + referencePoints.map(\.floor))
    }
}

struct CalibratedAltitudeEstimate: Codable, Hashable, Sendable {
    var floor: Int
    var seaLevelAltitudeMeters: Double
    var verticalAccuracyMeters: Double
    var confidence: ConfidenceLevel
    var evidence: [String]
}

/// 자동·수동 층수 보정이 적용될 때마다 남는 이력. 층별 기준점과 달리
/// 덮어쓰지 않고 시간순으로 쌓인다.
struct FloorCalibrationEvent: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var placeID: UUID
    var placeName: String
    var floor: Int
    var seaLevelAltitudeMeters: Double?
    var isAutomatic: Bool
    var capturedAt: Date

    init(
        id: UUID = UUID(),
        placeID: UUID,
        placeName: String,
        floor: Int,
        seaLevelAltitudeMeters: Double? = nil,
        isAutomatic: Bool,
        capturedAt: Date
    ) {
        self.id = id
        self.placeID = placeID
        self.placeName = placeName
        self.floor = floor
        self.seaLevelAltitudeMeters = seaLevelAltitudeMeters
        self.isAutomatic = isAutomatic
        self.capturedAt = capturedAt
    }
}

enum FrequentPlaceKind: String, Codable, CaseIterable, Sendable {
    case home
    case school
    case academy
    case company
    case hobby
    case exercise
    case custom

    var defaultName: String {
        switch self {
        case .home: "집"
        case .school: "학교"
        case .academy: "학원"
        case .company: "회사"
        case .hobby: "취미"
        case .exercise: "운동"
        case .custom: "사용자 추가"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house.fill"
        case .school: "graduationcap.fill"
        case .academy: "book.closed.fill"
        case .company: "building.2.fill"
        case .hobby: "paintpalette.fill"
        case .exercise: "figure.run"
        case .custom: "plus.circle.fill"
        }
    }
}

struct FrequentPlace: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var kind: FrequentPlaceKind
    var name: String
    var point: GeoPoint?
    var floor: Int?
    var referenceRelativeAltitudeMeters: Double?
    var referencePressureKilopascals: Double?
    var referenceAltimeterSessionID: UUID?
    var floorCapturedAt: Date?
    var floorReferencePoints: [FloorCalibrationPoint]
    var radiusMeters: Double
    /// 건물마다 다른 층 높이를 고도 보정에 사용합니다. 기본값은 3m입니다.
    var floorHeightMeters: Double
    /// 장소로 확정하기 위해 머물러야 하는 최소 시간입니다.
    var minimumDwellMinutes: Int
    /// 끄면 이 장소는 자동 위치 분석에서 제외하고 수동 기록만 사용합니다.
    var isAutomaticRecordingEnabled: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        kind: FrequentPlaceKind,
        name: String? = nil,
        point: GeoPoint? = nil,
        floor: Int? = nil,
        referenceRelativeAltitudeMeters: Double? = nil,
        referencePressureKilopascals: Double? = nil,
        referenceAltimeterSessionID: UUID? = nil,
        floorCapturedAt: Date? = nil,
        floorReferencePoints: [FloorCalibrationPoint] = [],
        radiusMeters: Double = 120,
        floorHeightMeters: Double = 3,
        minimumDwellMinutes: Int = 10,
        isAutomaticRecordingEnabled: Bool = true,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.kind = kind
        self.name = name ?? kind.defaultName
        self.point = point
        self.floor = floor
        self.referenceRelativeAltitudeMeters =
            referenceRelativeAltitudeMeters
        self.referencePressureKilopascals =
            referencePressureKilopascals
        self.referenceAltimeterSessionID = referenceAltimeterSessionID
        self.floorCapturedAt = floorCapturedAt
        self.floorReferencePoints = floorReferencePoints
        self.radiusMeters = radiusMeters
        self.floorHeightMeters = min(max(floorHeightMeters, 2.2), 5.0)
        self.minimumDwellMinutes = min(max(minimumDwellMinutes, 1), 240)
        self.isAutomaticRecordingEnabled = isAutomaticRecordingEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case name
        case point
        case floor
        case referenceRelativeAltitudeMeters
        case referencePressureKilopascals
        case referenceAltimeterSessionID
        case floorCapturedAt
        case floorReferencePoints
        case radiusMeters
        case floorHeightMeters
        case minimumDwellMinutes
        case isAutomaticRecordingEnabled
        case createdAt
        case updatedAt
    }

    /// 새 필드가 추가된 이전 저장 파일도 읽을 수 있도록 기본값을 적용합니다.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedKind = try values.decodeIfPresent(
            FrequentPlaceKind.self,
            forKey: .kind
        ) ?? .custom
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = decodedKind
        name = try values.decodeIfPresent(String.self, forKey: .name)
            ?? decodedKind.defaultName
        point = try values.decodeIfPresent(GeoPoint.self, forKey: .point)
        floor = try values.decodeIfPresent(Int.self, forKey: .floor)
        referenceRelativeAltitudeMeters = try values.decodeIfPresent(
            Double.self,
            forKey: .referenceRelativeAltitudeMeters
        )
        referencePressureKilopascals = try values.decodeIfPresent(
            Double.self,
            forKey: .referencePressureKilopascals
        )
        referenceAltimeterSessionID = try values.decodeIfPresent(
            UUID.self,
            forKey: .referenceAltimeterSessionID
        )
        floorCapturedAt = try values.decodeIfPresent(
            Date.self,
            forKey: .floorCapturedAt
        )
        floorReferencePoints = try values.decodeIfPresent(
            [FloorCalibrationPoint].self,
            forKey: .floorReferencePoints
        ) ?? []
        radiusMeters = min(
            max(
                try values.decodeIfPresent(Double.self, forKey: .radiusMeters)
                    ?? 120,
                30
            ),
            500
        )
        floorHeightMeters = min(
            max(
                try values.decodeIfPresent(
                    Double.self,
                    forKey: .floorHeightMeters
                ) ?? 3,
                2.2
            ),
            5.0
        )
        minimumDwellMinutes = min(
            max(
                try values.decodeIfPresent(
                    Int.self,
                    forKey: .minimumDwellMinutes
                ) ?? 10,
                1
            ),
            240
        )
        isAutomaticRecordingEnabled = try values.decodeIfPresent(
            Bool.self,
            forKey: .isAutomaticRecordingEnabled
        ) ?? true
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt)
            ?? .now
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt)
            ?? createdAt
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(kind, forKey: .kind)
        try values.encode(name, forKey: .name)
        try values.encodeIfPresent(point, forKey: .point)
        try values.encodeIfPresent(floor, forKey: .floor)
        try values.encodeIfPresent(
            referenceRelativeAltitudeMeters,
            forKey: .referenceRelativeAltitudeMeters
        )
        try values.encodeIfPresent(
            referencePressureKilopascals,
            forKey: .referencePressureKilopascals
        )
        try values.encodeIfPresent(
            referenceAltimeterSessionID,
            forKey: .referenceAltimeterSessionID
        )
        try values.encodeIfPresent(floorCapturedAt, forKey: .floorCapturedAt)
        try values.encode(floorReferencePoints, forKey: .floorReferencePoints)
        try values.encode(radiusMeters, forKey: .radiusMeters)
        try values.encode(floorHeightMeters, forKey: .floorHeightMeters)
        try values.encode(minimumDwellMinutes, forKey: .minimumDwellMinutes)
        try values.encode(
            isAutomaticRecordingEnabled,
            forKey: .isAutomaticRecordingEnabled
        )
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(updatedAt, forKey: .updatedAt)
    }

    static let defaults: [FrequentPlace] = [
        FrequentPlace(kind: .home),
        FrequentPlace(kind: .school),
        FrequentPlace(kind: .academy),
        FrequentPlace(kind: .company),
        FrequentPlace(kind: .hobby),
        FrequentPlace(kind: .exercise),
    ]

    var stablePlaceKey: String {
        "frequent-\(id.uuidString.lowercased())"
    }

    var floorCalibration: FloorCalibration? {
        guard let point, let floor else { return nil }
        return FloorCalibration(
            placeName: name,
            referenceFloor: floor,
            floorHeightMeters: floorHeightMeters,
            referencePoint: point,
            referenceRelativeAltitudeMeters:
                referenceRelativeAltitudeMeters,
            referencePressureKilopascals:
                referencePressureKilopascals,
            referenceAltimeterSessionID: referenceAltimeterSessionID,
            capturedAt: floorCapturedAt ?? updatedAt,
            referencePoints: floorReferencePoints
        )
    }

    mutating func setLocation(
        from reading: SensorReading,
        floor: Int
    ) {
        guard let point = reading.point else { return }
        self.point = point
        self.floor = floor
        referenceRelativeAltitudeMeters = reading.relativeAltitudeMeters
        referencePressureKilopascals = reading.pressureKilopascals
        referenceAltimeterSessionID = reading.altimeterSessionID
        floorCapturedAt = reading.timestamp
        let reference = FloorCalibrationPoint(
            floor: floor,
            point: point,
            relativeAltitudeMeters: reading.relativeAltitudeMeters,
            pressureKilopascals: reading.pressureKilopascals,
            altimeterSessionID: reading.altimeterSessionID,
            capturedAt: reading.timestamp
        )
        // 같은 건물에서 다시 지정한 경우 다른 층 기준을 유지한다.
        // 위치를 멀리 옮겼다면 이전 층 기준은 더 이상 맞지 않으므로 버린다.
        floorReferencePoints = floorReferencePoints.filter {
            $0.floor != floor
                && distanceMeters($0.point, point)
                    <= Self.sameBuildingRadiusMeters
        } + [reference]
        floorReferencePoints.sort { $0.floor < $1.floor }
        updatedAt = .now
    }

    static let sameBuildingRadiusMeters = 120.0

    mutating func addFloorCalibration(
        from reading: SensorReading,
        floor: Int
    ) {
        guard let point = reading.point else { return }
        let reference = FloorCalibrationPoint(
            floor: floor,
            point: point,
            relativeAltitudeMeters: reading.relativeAltitudeMeters,
            pressureKilopascals: reading.pressureKilopascals,
            altimeterSessionID: reading.altimeterSessionID,
            capturedAt: reading.timestamp
        )
        if let index = floorReferencePoints.firstIndex(where: {
            $0.floor == floor
        }) {
            floorReferencePoints[index] = reference
        } else {
            floorReferencePoints.append(reference)
        }
        updatedAt = .now
    }

    mutating func clearLocation() {
        point = nil
        floor = nil
        referenceRelativeAltitudeMeters = nil
        referencePressureKilopascals = nil
        referenceAltimeterSessionID = nil
        floorCapturedAt = nil
        floorReferencePoints = []
        updatedAt = .now
    }
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

struct TravelSegmentGroup: Identifiable, Hashable, Sendable {
    var id: UUID
    var segments: [TravelSegment]

    init(segments: [TravelSegment]) {
        self.segments = segments.sorted { $0.span.start < $1.span.start }
        id = self.segments.first?.id ?? UUID()
    }

    var segmentIDs: [UUID] {
        segments.map(\.id)
    }

    var mode: TravelMode {
        segments.first?.mode ?? .walking
    }

    var span: TimeSpan {
        let now = Date.now
        return TimeSpan(
            start: segments.first?.span.start ?? now,
            end: segments.last?.span.end ?? now
        )
    }

    var distanceMeters: Double {
        segments.reduce(0) { $0 + $1.distanceMeters }
    }

    var confidence: ConfidenceLevel {
        if segments.contains(where: { $0.confidence == .low }) {
            return .low
        }
        if segments.allSatisfy({ $0.confidence == .high }) {
            return .high
        }
        return .medium
    }

    var confirmedCount: Int {
        segments.filter(\.isConfirmed).count
    }

    var isConfirmed: Bool {
        !segments.isEmpty && confirmedCount == segments.count
    }

    var evidence: [String] {
        var seen = Set<String>()
        return segments.flatMap(\.evidence).filter {
            seen.insert($0).inserted
        }
    }

    var fromPlaceID: UUID? {
        segments.first?.fromPlaceID
    }

    var toPlaceID: UUID? {
        segments.last?.toPlaceID
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

    var activityTitle: String? {
        switch self {
        case .stationary: "정지·휴식"
        case .walking: "걷기"
        case .running: "달리기"
        case .cycling: "자전거"
        case .automotive: "자동차"
        case .unknown: nil
        }
    }

    var isMovement: Bool {
        switch self {
        case .walking, .running, .cycling, .automotive:
            true
        case .stationary, .unknown:
            false
        }
    }
}

enum TrackingKind: String, Codable, CaseIterable, Hashable, Sendable {
    case automatic
    case walking
    case running

    var displayName: String {
        switch self {
        case .automatic: "자동 감지"
        case .walking: "걷기"
        case .running: "달리기"
        }
    }
}

enum TrackingDevice: String, Codable, Hashable, Sendable {
    case iPhone
    case appleWatch
}

struct TrackingSession: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var kind: TrackingKind
    var startedAt: Date
    var endedAt: Date?
    var linkedPlanID: UUID?
    var sourceDevice: TrackingDevice
    var iPhoneActive: Bool
    var watchActive: Bool
    var wasAutomaticallyDetected: Bool

    init(
        id: UUID = UUID(),
        kind: TrackingKind,
        startedAt: Date = .now,
        endedAt: Date? = nil,
        linkedPlanID: UUID? = nil,
        sourceDevice: TrackingDevice = .iPhone,
        iPhoneActive: Bool = true,
        watchActive: Bool = false,
        wasAutomaticallyDetected: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.linkedPlanID = linkedPlanID
        self.sourceDevice = sourceDevice
        self.iPhoneActive = iPhoneActive
        self.watchActive = watchActive
        self.wasAutomaticallyDetected = wasAutomaticallyDetected
    }
}

struct LiveRouteState: Hashable, Sendable {
    var session: TrackingSession?
    var readings: [SensorReading]
    var lastUpdatedAt: Date?

    static let empty = LiveRouteState(
        session: nil,
        readings: [],
        lastUpdatedAt: nil
    )
}

struct SensorReading: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var timestamp: Date
    var point: GeoPoint?
    var speedMetersPerSecond: Double?
    var speedAccuracyMetersPerSecond: Double?
    var courseDegrees: Double?
    var courseAccuracyDegrees: Double?
    var motion: MotionKind
    var motionConfidence: ConfidenceLevel
    var relativeAltitudeMeters: Double?
    var pressureKilopascals: Double?
    var altimeterSessionID: UUID?
    var floorsAscended: Int?
    var floorsDescended: Int?
    var stepCount: Int?
    var walkingRunningDistanceMeters: Double?
    var currentPaceSecondsPerMeter: Double?
    var currentCadenceStepsPerSecond: Double?
    var averageActivePaceSecondsPerMeter: Double?
    var deviceMotion: DeviceMotionSnapshot?
    var deviceMotionSummary: DeviceMotionSummary?
    var watchAccelerationAverageG: SensorVector3?
    var watchAccelerationStandardDeviationG: Double?
    var watchAccelerationMeanJerkGPerSecond: Double?
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
    /// Fine-grained behavior emitted by the Watch rule/model layer.  The
    /// coarse `motion` value is retained for existing travel inference.
    var behavior: String?
    var behaviorConfidenceScore: Double?
    var behaviorEvidence: [String]?
    var behaviorModelVersion: String?
    var trackingSessionID: UUID?
    var trackingKind: TrackingKind?
    var sourceDevice: TrackingDevice?
    var sequence: Int?
    var trackingSessionEnded: Bool?

    init(
        id: UUID = UUID(),
        timestamp: Date,
        point: GeoPoint? = nil,
        speedMetersPerSecond: Double? = nil,
        speedAccuracyMetersPerSecond: Double? = nil,
        courseDegrees: Double? = nil,
        courseAccuracyDegrees: Double? = nil,
        motion: MotionKind = .unknown,
        motionConfidence: ConfidenceLevel = .low,
        relativeAltitudeMeters: Double? = nil,
        pressureKilopascals: Double? = nil,
        altimeterSessionID: UUID? = nil,
        floorsAscended: Int? = nil,
        floorsDescended: Int? = nil,
        stepCount: Int? = nil,
        walkingRunningDistanceMeters: Double? = nil,
        currentPaceSecondsPerMeter: Double? = nil,
        currentCadenceStepsPerSecond: Double? = nil,
        averageActivePaceSecondsPerMeter: Double? = nil,
        deviceMotion: DeviceMotionSnapshot? = nil,
        deviceMotionSummary: DeviceMotionSummary? = nil,
        watchAccelerationAverageG: SensorVector3? = nil,
        watchAccelerationStandardDeviationG: Double? = nil,
        watchAccelerationMeanJerkGPerSecond: Double? = nil,
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
        watchWorkoutKind: String? = nil,
        behavior: String? = nil,
        behaviorConfidenceScore: Double? = nil,
        behaviorEvidence: [String]? = nil,
        behaviorModelVersion: String? = nil,
        trackingSessionID: UUID? = nil,
        trackingKind: TrackingKind? = nil,
        sourceDevice: TrackingDevice? = nil,
        sequence: Int? = nil,
        trackingSessionEnded: Bool? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.point = point
        self.speedMetersPerSecond = speedMetersPerSecond
        self.speedAccuracyMetersPerSecond = speedAccuracyMetersPerSecond
        self.courseDegrees = courseDegrees
        self.courseAccuracyDegrees = courseAccuracyDegrees
        self.motion = motion
        self.motionConfidence = motionConfidence
        self.relativeAltitudeMeters = relativeAltitudeMeters
        self.pressureKilopascals = pressureKilopascals
        self.altimeterSessionID = altimeterSessionID
        self.floorsAscended = floorsAscended
        self.floorsDescended = floorsDescended
        self.stepCount = stepCount
        self.walkingRunningDistanceMeters = walkingRunningDistanceMeters
        self.currentPaceSecondsPerMeter = currentPaceSecondsPerMeter
        self.currentCadenceStepsPerSecond = currentCadenceStepsPerSecond
        self.averageActivePaceSecondsPerMeter =
            averageActivePaceSecondsPerMeter
        self.deviceMotion = deviceMotion
        self.deviceMotionSummary = deviceMotionSummary
        self.watchAccelerationAverageG = watchAccelerationAverageG
        self.watchAccelerationStandardDeviationG =
            watchAccelerationStandardDeviationG
        self.watchAccelerationMeanJerkGPerSecond =
            watchAccelerationMeanJerkGPerSecond
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
        self.behavior = behavior
        self.behaviorConfidenceScore = behaviorConfidenceScore
        self.behaviorEvidence = behaviorEvidence
        self.behaviorModelVersion = behaviorModelVersion
        self.trackingSessionID = trackingSessionID
        self.trackingKind = trackingKind
        self.sourceDevice = sourceDevice
        self.sequence = sequence
        self.trackingSessionEnded = trackingSessionEnded
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
    var watchAccelerationProfile: TaptionWatchAccelerationProfile
    var watchDataSyncProfile: TaptionWatchDataSyncProfile
    var floorCalibration: FloorCalibration?
    var floorCalibrationHistory: [FloorCalibrationEvent]
    var frequentPlaces: [FrequentPlace]
    var movementCorrections: [TravelModeCorrection]
    var suppressedActualIDs: Set<UUID>
    var weatherEnabled: Bool
    var notificationsEnabled: Bool
    var permissions: [PermissionFeature: PermissionState]
    var timelineRowOrder: [String]

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
        watchAccelerationProfile: .off,
        watchDataSyncProfile: .off,
        floorCalibration: nil,
        floorCalibrationHistory: [],
        frequentPlaces: FrequentPlace.defaults,
        movementCorrections: [],
        suppressedActualIDs: [],
        weatherEnabled: false,
        notificationsEnabled: false,
        permissions: Dictionary(
            uniqueKeysWithValues: PermissionFeature.allCases.map { ($0, .notDetermined) }
        ),
        timelineRowOrder: TimelineRowOrder.defaults
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
        watchAccelerationProfile: TaptionWatchAccelerationProfile = .off,
        watchDataSyncProfile: TaptionWatchDataSyncProfile = .off,
        floorCalibration: FloorCalibration? = nil,
        floorCalibrationHistory: [FloorCalibrationEvent] = [],
        frequentPlaces: [FrequentPlace] = FrequentPlace.defaults,
        movementCorrections: [TravelModeCorrection] = [],
        suppressedActualIDs: Set<UUID> = [],
        weatherEnabled: Bool,
        notificationsEnabled: Bool,
        permissions: [PermissionFeature: PermissionState],
        timelineRowOrder: [String] = TimelineRowOrder.defaults
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
        self.watchAccelerationProfile = watchAccelerationProfile
        self.watchDataSyncProfile = watchDataSyncProfile
        self.floorCalibration = floorCalibration
        self.floorCalibrationHistory = floorCalibrationHistory
        self.frequentPlaces = Self.mergedFrequentPlaces(frequentPlaces)
        self.movementCorrections = movementCorrections
        self.suppressedActualIDs = suppressedActualIDs
        self.weatherEnabled = weatherEnabled
        self.notificationsEnabled = notificationsEnabled
        self.permissions = permissions
        self.timelineRowOrder = Self.normalizedTimelineRowOrder(timelineRowOrder)
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
        case watchAccelerationProfile
        case watchDataSyncProfile
        case floorCalibration
        case floorCalibrationHistory
        case frequentPlaces
        case movementCorrections
        case suppressedActualIDs
        case weatherEnabled
        case notificationsEnabled
        case permissions
        case timelineRowOrder
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
        movementCorrections = try values.decodeIfPresent(
            [TravelModeCorrection].self,
            forKey: .movementCorrections
        ) ?? defaults.movementCorrections
        suppressedActualIDs = try values.decodeIfPresent(
            Set<UUID>.self,
            forKey: .suppressedActualIDs
        ) ?? defaults.suppressedActualIDs
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
        timelineRowOrder = Self.normalizedTimelineRowOrder(
            try values.decodeIfPresent(
                [String].self,
                forKey: .timelineRowOrder
            ) ?? defaults.timelineRowOrder
        )
        for feature in PermissionFeature.allCases
        where permissions[feature] == nil {
            permissions[feature] = .notDetermined
        }
    }

    static func mergedFrequentPlaces(
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

    static func normalizedTimelineRowOrder(_ ids: [String]) -> [String] {
        var result: [String] = []
        for id in ids + TimelineRowOrder.defaults
        where !id.isEmpty && !result.contains(id) {
            result.append(id)
        }
        return result
    }
}

struct TaptionDataSnapshot: Codable, Hashable, Sendable {
    var schemaVersion: Int
    var updatedAt: Date
    var plans: [PlanRecord]
    var actuals: [ActualRecord]
    var recordLinks: [RecordLink]
    var memos: [ActionMemo]
    var categories: [CategoryDefinition]
    var photos: [PhotoMoment]
    var calendarEvents: [CalendarRecord]
    var weather: [WeatherContext]
    var places: [PlaceStay]
    var travel: [TravelSegment]
    var floorTransitions: [FloorTransition]
    var settings: AppFeatureSettings

    init(
        schemaVersion: Int,
        updatedAt: Date,
        plans: [PlanRecord],
        actuals: [ActualRecord],
        recordLinks: [RecordLink] = [],
        memos: [ActionMemo],
        categories: [CategoryDefinition],
        photos: [PhotoMoment],
        calendarEvents: [CalendarRecord],
        weather: [WeatherContext],
        places: [PlaceStay],
        travel: [TravelSegment],
        floorTransitions: [FloorTransition],
        settings: AppFeatureSettings
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.plans = plans
        self.actuals = actuals
        self.recordLinks = recordLinks
        self.memos = memos
        self.categories = categories
        self.photos = photos
        self.calendarEvents = calendarEvents
        self.weather = weather
        self.places = places
        self.travel = travel
        self.floorTransitions = floorTransitions
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
        categories: [],
        photos: [],
        calendarEvents: [],
        weather: [],
        places: [],
        travel: [],
        floorTransitions: [],
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
