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
    case memo

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
        case .memo: "메모"
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
        case .memo: "note.text"
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

/// A memo stands on its own. It may point at a plan or at an automatic
/// record, but it never requires one: a note left on a category row keeps that
/// category and the instant it belongs to, so no placeholder plan is needed.
struct ActionMemo: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    /// Optional link to a user plan. `nil` for standalone memos.
    var planID: UUID?
    /// Stable timeline item key. Plan-backed memos keep using `planID`, while
    /// automatic records (location, travel, health, weather, photos, etc.)
    /// use this key so two records in the same category never share notes.
    var targetID: String?
    /// Category the memo belongs to. Always set for standalone memos.
    var categoryID: String?
    /// Instant on the timeline the memo belongs to, which is not necessarily
    /// when it was typed: a note added to yesterday stays on yesterday.
    var occurredAt: Date
    var kind: MemoKind
    var text: String
    var attachments: [MemoAttachment]
    var isHighlightedInReview: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        planID: UUID? = nil,
        targetID: String? = nil,
        categoryID: String? = nil,
        occurredAt: Date? = nil,
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
        self.categoryID = categoryID
        self.occurredAt = occurredAt ?? createdAt
        self.kind = kind
        self.text = text
        self.attachments = attachments
        self.isHighlightedInReview = isHighlightedInReview
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, planID, targetID, categoryID, occurredAt, kind, text
        case attachments, isHighlightedInReview, createdAt, updatedAt
    }

    /// `categoryID` and `occurredAt` arrived after the first archive format,
    /// so records saved by older builds decode with their plan-derived values.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        planID = try values.decodeIfPresent(UUID.self, forKey: .planID)
        targetID = try values.decodeIfPresent(String.self, forKey: .targetID)
        categoryID = try values.decodeIfPresent(String.self, forKey: .categoryID)
        kind = try values.decode(MemoKind.self, forKey: .kind)
        text = try values.decode(String.self, forKey: .text)
        attachments = try values.decodeIfPresent(
            [MemoAttachment].self,
            forKey: .attachments
        ) ?? []
        isHighlightedInReview = try values.decodeIfPresent(
            Bool.self,
            forKey: .isHighlightedInReview
        ) ?? true
        let decodedCreatedAt = try values.decodeIfPresent(
            Date.self,
            forKey: .createdAt
        ) ?? .now
        createdAt = decodedCreatedAt
        updatedAt = try values.decodeIfPresent(
            Date.self,
            forKey: .updatedAt
        ) ?? decodedCreatedAt
        occurredAt = try values.decodeIfPresent(
            Date.self,
            forKey: .occurredAt
        ) ?? decodedCreatedAt
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
    /// 사용자가 "지금 이 층"이라고 직접 확인한 기준점. 자동 추정은 이 기준을
    /// 덮거나 지우지 못한다. 그래야 사용자가 자기 데이터를 고칠 수 있다.
    var isManual: Bool

    init(
        floor: Int,
        point: GeoPoint,
        relativeAltitudeMeters: Double?,
        pressureKilopascals: Double?,
        altimeterSessionID: UUID?,
        capturedAt: Date,
        isManual: Bool = false
    ) {
        self.floor = floor
        self.point = point
        self.relativeAltitudeMeters = relativeAltitudeMeters
        self.pressureKilopascals = pressureKilopascals
        self.altimeterSessionID = altimeterSessionID
        self.capturedAt = capturedAt
        self.isManual = isManual
    }

    /// 이전 저장 파일에는 `isManual` 이 없다. 알 수 없는 출처는 자동으로 본다.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        floor = try values.decode(Int.self, forKey: .floor)
        point = try values.decode(GeoPoint.self, forKey: .point)
        relativeAltitudeMeters = try values.decodeIfPresent(
            Double.self,
            forKey: .relativeAltitudeMeters
        )
        pressureKilopascals = try values.decodeIfPresent(
            Double.self,
            forKey: .pressureKilopascals
        )
        altimeterSessionID = try values.decodeIfPresent(
            UUID.self,
            forKey: .altimeterSessionID
        )
        capturedAt = try values.decode(Date.self, forKey: .capturedAt)
        isManual = try values.decodeIfPresent(Bool.self, forKey: .isManual)
            ?? false
    }
}

/// 두 관측 사이의 고도 차이를 구하는 단 하나의 규칙. 같은 기압 세션의
/// 상대고도가 가장 정확하고, 기압차, GPS 고도 순으로 내려간다. 층 추정과 층
/// 높이 계산이 이 규칙을 함께 쓴다.
enum AltitudeDelta {
    enum Source: Sendable {
        case relativeAltitude
        case pressure
        case gps
    }

    struct Sample: Sendable {
        var altimeterSessionID: UUID?
        var relativeAltitudeMeters: Double?
        var pressureKilopascals: Double?
        var altitudeMeters: Double?

        init(_ reading: SensorReading) {
            altimeterSessionID = reading.altimeterSessionID
            relativeAltitudeMeters = reading.relativeAltitudeMeters
            pressureKilopascals = reading.pressureKilopascals
            altitudeMeters = reading.point?.altitude
        }

        init(_ reference: FloorCalibrationPoint) {
            altimeterSessionID = reference.altimeterSessionID
            relativeAltitudeMeters = reference.relativeAltitudeMeters
            pressureKilopascals = reference.pressureKilopascals
            altitudeMeters = reference.point.altitude
        }

        /// 기록이 스스로 지닌 근거. GPS 고도는 기록에 남은 대표 좌표에서
        /// 가져온다.
        init(_ evidence: FloorEvidence, altitudeMeters: Double?) {
            altimeterSessionID = evidence.altimeterSessionID
            relativeAltitudeMeters = evidence.relativeAltitudeMeters
            pressureKilopascals = evidence.pressureKilopascals
            self.altitudeMeters = altitudeMeters
        }
    }

    static func between(
        _ baseline: Sample,
        and current: Sample
    ) -> (meters: Double, source: Source)? {
        // 상대고도의 0점은 기압 세션마다 새로 잡힌다. 세션을 모르는 표본끼리
        // (양쪽 다 nil) 비교하면 서로 다른 0점을 같은 기준으로 착각해 수십
        // 미터가 그대로 층수 오차가 된다. 그때는 절대 기압으로 내려간다.
        if let session = baseline.altimeterSessionID,
           session == current.altimeterSessionID,
           let start = baseline.relativeAltitudeMeters,
           let end = current.relativeAltitudeMeters {
            return (end - start, .relativeAltitude)
        }
        if let start = baseline.pressureKilopascals,
           let end = current.pressureKilopascals,
           start > 0,
           end > 0 {
            return (44_330 * (1 - pow(end / start, 0.1903)), .pressure)
        }
        if let start = baseline.altitudeMeters,
           let end = current.altitudeMeters {
            return (end - start, .gps)
        }
        return nil
    }
}

/// 기록에 남은 층수는 관측에서 파생된 값이다. 그 관측의 원본 표본은 7일 뒤
/// 지워지므로, 파생된 층수 옆에 근거가 된 숫자 몇 개를 함께 남긴다. 그래야
/// 기준점을 뒤늦게 고쳐도 보관 기간과 상관없이 다시 매길 수 있다.
///
/// 상대고도의 0점은 기압 세션마다 새로 잡힌다. 세션 식별자를 함께 남겨야
/// 다른 세션의 값을 같은 기준으로 착각해 빼는 일이 없다.
struct FloorEvidence: Codable, Hashable, Sendable {
    var measuredAt: Date
    var relativeAltitudeMeters: Double?
    var pressureKilopascals: Double?
    var altimeterSessionID: UUID?
    /// 잰 자리에서 이 기록까지의 층수 차이. 한 체류가 층 이동으로 쪼개지면
    /// 뒤쪽 조각은 잰 자리보다 이만큼 위에 있다.
    var floorOffset: Int

    init(
        measuredAt: Date,
        relativeAltitudeMeters: Double? = nil,
        pressureKilopascals: Double? = nil,
        altimeterSessionID: UUID? = nil,
        floorOffset: Int = 0
    ) {
        self.measuredAt = measuredAt
        self.relativeAltitudeMeters = relativeAltitudeMeters
        self.pressureKilopascals = pressureKilopascals
        self.altimeterSessionID = altimeterSessionID
        self.floorOffset = floorOffset
    }

    /// 기압을 재지 못한 관측은 근거가 되지 못한다. 없는 근거를 남겨 두면
    /// 나중에 그 기록을 고칠 수 있다고 착각한다.
    init?(_ reading: SensorReading) {
        guard reading.relativeAltitudeMeters != nil
                || reading.pressureKilopascals != nil else {
            return nil
        }
        self.init(
            measuredAt: reading.timestamp,
            relativeAltitudeMeters: reading.relativeAltitudeMeters,
            pressureKilopascals: reading.pressureKilopascals,
            altimeterSessionID: reading.altimeterSessionID
        )
    }

    func offset(by floors: Int) -> FloorEvidence {
        var value = self
        value.floorOffset += floors
        return value
    }
}

/// 층 높이는 사용자가 맞추는 값이 아니다. "지금 몇 층인지"는 사람이 알고
/// 미터는 기기가 잰다. 서로 다른 층에서 받아 둔 기준점의 고도 차이를 층수로
/// 나눠 이 건물의 층 높이를 구한다. 기준이 한 층뿐이면 잴 것이 없으므로 nil을
/// 돌려주고 쓰던 값을 그대로 둔다.
enum FloorHeightEstimator {
    static let minimumMeters = 2.2
    static let maximumMeters = 5.0

    static func metersPerFloor(
        from references: [FloorCalibrationPoint]
    ) -> Double? {
        let sorted = newestPerFloor(references).sorted { $0.floor < $1.floor }
        var heights: [Double] = []
        for (index, base) in sorted.enumerated() {
            for target in sorted.dropFirst(index + 1) {
                let floors = target.floor - base.floor
                guard floors > 0,
                      let delta = AltitudeDelta.between(
                        AltitudeDelta.Sample(base),
                        and: AltitudeDelta.Sample(target)
                      ) else {
                    continue
                }
                // 위층은 아래층보다 높아야 한다. 부호가 뒤집힌 짝은 둘 중
                // 하나가 오염된 것이므로, abs로 부호를 감춰 멀쩡한 값처럼
                // 만들지 않는다.
                guard delta.meters > 0 else { continue }
                let height = delta.meters / Double(floors)
                // 범위를 벗어난 짝은 잘못 잰 것이다. 억지로 끌어다 맞추면
                // 멀쩡한 다른 기준까지 망가지므로 그냥 버린다.
                guard height >= minimumMeters, height <= maximumMeters else {
                    continue
                }
                heights.append(height)
            }
        }
        guard !heights.isEmpty else { return nil }
        return median(heights)
    }

    /// 같은 층 기준이 여러 개 남아 있으면 최근 것만 쓴다. 오래된 중복은 같은
    /// 층을 두 번 세어 중앙값을 한쪽으로 끌어당긴다.
    private static func newestPerFloor(
        _ references: [FloorCalibrationPoint]
    ) -> [FloorCalibrationPoint] {
        var newest: [Int: FloorCalibrationPoint] = [:]
        for reference in references {
            if let held = newest[reference.floor],
               held.capturedAt >= reference.capturedAt {
                continue
            }
            newest[reference.floor] = reference
        }
        return Array(newest.values)
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let ordered = values.sorted()
        let middle = ordered.count / 2
        return ordered.count.isMultiple(of: 2)
            ? (ordered[middle - 1] + ordered[middle]) / 2
            : ordered[middle]
    }
}

/// 기압계 한 표본은 흔들린다. 그 한 번을 영구 기준점으로 박으면 흔들림이
/// 이 건물의 모든 층 추정에 그대로 남는다. 그래서 수동 보정은 여러 표본을
/// 모아 하나로 줄인 뒤에만 기준을 남긴다.
struct AltitudeBurstSample: Hashable, Sendable {
    var relativeAltitudeMeters: Double?
    var pressureKilopascals: Double?
    var altimeterSessionID: UUID?
    var timestamp: Date

    init(
        relativeAltitudeMeters: Double? = nil,
        pressureKilopascals: Double? = nil,
        altimeterSessionID: UUID? = nil,
        timestamp: Date
    ) {
        self.relativeAltitudeMeters = relativeAltitudeMeters
        self.pressureKilopascals = pressureKilopascals
        self.altimeterSessionID = altimeterSessionID
        self.timestamp = timestamp
    }

    var isUsable: Bool {
        relativeAltitudeMeters != nil || pressureKilopascals != nil
    }
}

/// 표본 묶음을 기준점 하나로 줄이는 규칙. CoreMotion을 모른다.
enum AltitudeBurstReducer {
    /// 기압계 상대고도는 약 1초에 한 번 도착한다. 12개면 약 12초, 사용자가
    /// 가만히 서 있기를 요구할 수 있는 상한이다.
    static let requestedSampleCount = 12
    /// 절반 넘게 모이면 중앙값이 흔들림을 이긴다. 그보다 적으면 버린다.
    static let minimumSampleCount = 7
    /// 한 층은 최소 2.2m다. 그 절반보다 넉넉히 아래로 잡는다. 가만히 선
    /// 기기의 기압계 잡음은 수십 cm이므로, 이보다 벌어졌다면 사람이
    /// 움직였거나 센서를 믿을 수 없다는 뜻이다.
    static let maximumSpreadMeters = 1.0

    enum Outcome: Equatable, Sendable {
        case reduced(AltitudeBurstSample, spreadMeters: Double)
        case tooFewSamples(collected: Int)
        case tooNoisy(spreadMeters: Double)
    }

    /// 평균 대신 중앙값을 쓴다. 최대·최소를 버린 뒤 남는 표본이 열 개뿐이라
    /// 그 위에 다시 이상치 규칙을 얹으면 임계값 하나에 결과가 흔들린다.
    /// 중앙값은 조정할 값 없이 같은 강건함을 한 번에 얻는다. 버린 양끝은
    /// 값 대신 품질 판정에 쓴다.
    static func reduce(_ samples: [AltitudeBurstSample]) -> Outcome {
        let ordered = samples.filter(\.isUsable).sorted {
            $0.timestamp < $1.timestamp
        }
        // 기압 세션이 중간에 끊기면 상대고도의 0점이 새로 잡힌다. 그 앞뒤를
        // 섞어 평균 내면 없던 층이 생긴다. 마지막 세션만 남긴다.
        let session = ordered.last?.altimeterSessionID
        let usable = ordered.filter { $0.altimeterSessionID == session }
        guard usable.count >= minimumSampleCount else {
            return .tooFewSamples(collected: usable.count)
        }
        let spread = trimmedSpreadMeters(usable)
        guard spread <= maximumSpreadMeters else {
            return .tooNoisy(spreadMeters: spread)
        }
        let reduced = AltitudeBurstSample(
            relativeAltitudeMeters: FloorHeightEstimator.median(
                usable.compactMap(\.relativeAltitudeMeters)
            ),
            pressureKilopascals: FloorHeightEstimator.median(
                usable.compactMap(\.pressureKilopascals)
            ),
            altimeterSessionID: session,
            timestamp: usable[usable.count / 2].timestamp
        )
        return .reduced(reduced, spreadMeters: spread)
    }

    /// 최대·최소 하나씩을 덜어 낸 뒤 남는 폭. 표본이 얼마나 서로 맞는지를
    /// 미터로 말한다.
    static func trimmedSpreadMeters(_ samples: [AltitudeBurstSample]) -> Double {
        let ordered = metersSeries(samples).sorted()
        guard ordered.count > 2 else {
            return (ordered.last ?? 0) - (ordered.first ?? 0)
        }
        return ordered[ordered.count - 2] - ordered[1]
    }

    /// 상대고도가 있으면 그대로, 없으면 절대 기압을 미터로 바꿔 비교한다.
    private static func metersSeries(
        _ samples: [AltitudeBurstSample]
    ) -> [Double] {
        let relative = samples.compactMap(\.relativeAltitudeMeters)
        if relative.count >= minimumSampleCount { return relative }
        let pressures = samples.compactMap(\.pressureKilopascals).filter {
            $0 > 0
        }
        guard let reference = pressures.first else { return relative }
        return pressures.map {
            44_330 * (1 - pow($0 / reference, 0.1903))
        }
    }
}

extension SensorReading {
    /// 묶음에서 줄인 고도로 이 표본의 고도만 바꾼다. 위치는 그대로 두고
    /// 시각은 실제로 잰 때로 맞춘다.
    func replacingAltitude(with sample: AltitudeBurstSample) -> SensorReading {
        var value = self
        value.relativeAltitudeMeters = sample.relativeAltitudeMeters
        value.pressureKilopascals = sample.pressureKilopascals
        value.altimeterSessionID = sample.altimeterSessionID
        value.timestamp = sample.timestamp
        return value
    }
}

/// 층 보정은 사용자가 실제로 고른 값에만 적용한다. 화면이 미리 채워 둔 값을
/// 그대로 확인해 버리면 고치려던 오차가 영구 기준으로 굳는다. 그래서 값을
/// 한 번 더 눌러 확인하기 전에는 보정이 잠겨 있다.
struct FloorCalibrationPrompt: Equatable, Sendable {
    static let range = -10...100

    private(set) var floor: Int
    /// 사용자가 화면에 뜬 층수를 눈으로 확인하고 한 번 더 누른 상태.
    private(set) var isArmed = false

    /// 미리 채우는 값은 이 장소에서 사용자가 마지막으로 확인한 층뿐이다.
    /// 앱이 추정한 층을 넣으면 고치려는 값이 곧 기본값이 된다.
    init(lastConfirmedFloor: Int? = nil) {
        floor = Self.clamped(lastConfirmedFloor ?? 1)
    }

    var canCommit: Bool { isArmed }

    mutating func select(_ value: Int) {
        let next = Self.clamped(value)
        guard next != floor else { return }
        floor = next
        // 값이 바뀌면 확인은 무효다. 확인한 값과 보정할 값은 늘 같아야 한다.
        isArmed = false
    }

    mutating func arm() { isArmed = true }

    mutating func disarm() { isArmed = false }

    private static func clamped(_ value: Int) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

/// 보정 표본을 모으는 동안의 진행 상태. 다 모이기 전에는 아무것도 기록되지
/// 않는다.
struct FloorCalibrationSampling: Equatable, Sendable {
    var placeID: UUID
    var floor: Int
    var collected: Int
    var target: Int

    var progress: Double {
        guard target > 0 else { return 0 }
        return min(1, Double(collected) / Double(target))
    }
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

/// 지하는 음수 층으로 저장하고 화면에는 "지하 N층"으로 적는다.
enum FloorLabel {
    static func korean(_ floor: Int) -> String {
        floor < 0 ? "지하 \(-floor)층" : "\(floor)층"
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
        floor: Int,
        isManual: Bool = false
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
            capturedAt: reading.timestamp,
            isManual: isManual
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

    mutating func setMapLocation(_ newPoint: GeoPoint) {
        let previousPoint = point
        let keepsFloorCalibration = previousPoint.map {
            distanceMeters($0, newPoint) <= Self.sameBuildingRadiusMeters
        } ?? false
        if keepsFloorCalibration,
           newPoint.verticalAccuracy < 0,
           let previousPoint {
            point = GeoPoint(
                latitude: newPoint.latitude,
                longitude: newPoint.longitude,
                altitude: previousPoint.altitude,
                horizontalAccuracy: newPoint.horizontalAccuracy,
                verticalAccuracy: previousPoint.verticalAccuracy
            )
        } else {
            point = newPoint
        }
        if !keepsFloorCalibration {
            floor = nil
            referenceRelativeAltitudeMeters = nil
            referencePressureKilopascals = nil
            referenceAltimeterSessionID = nil
            floorCapturedAt = nil
            floorReferencePoints = []
            floorHeightMeters = Self.defaultFloorHeightMeters
        }
        updatedAt = .now
    }

    static let sameBuildingRadiusMeters = 120.0
    static let defaultFloorHeightMeters = 3.0

    /// 서로 다른 층이라면 최소 층 높이(2.2m)만큼은 떨어져 있어야 한다. 그
    /// 절반보다 가까운 두 기준점은 같은 높이를 가리키므로 둘 다 참일 수 없다.
    /// 가만히 선 기기의 기압계 잡음(수십 cm)보다는 넉넉하다.
    static let conflictingAltitudeToleranceMeters = 1.0

    @discardableResult
    mutating func addFloorCalibration(
        from reading: SensorReading,
        floor: Int,
        isManual: Bool = false
    ) -> Bool {
        guard let point = reading.point else { return false }
        let reference = FloorCalibrationPoint(
            floor: floor,
            point: point,
            relativeAltitudeMeters: reading.relativeAltitudeMeters,
            pressureKilopascals: reading.pressureKilopascals,
            altimeterSessionID: reading.altimeterSessionID,
            capturedAt: reading.timestamp,
            isManual: isManual
        )
        let conflicts = conflictingReferenceIndices(with: reference)
        // 사용자가 확인한 기준을 자동 추정이 밀어내면, 틀린 추정이 사용자의
        // 정정을 곧바로 되돌린다. 그때는 이번 자동 기준을 버린다.
        if !isManual,
           conflicts.contains(where: { floorReferencePoints[$0].isManual }) {
            return false
        }
        var kept = floorReferencePoints.enumerated()
            .filter { !conflicts.contains($0.offset) }
            .map(\.element)
        if let index = kept.firstIndex(where: { $0.floor == floor }) {
            kept[index] = reference
        } else {
            kept.append(reference)
        }
        kept.sort { $0.floor < $1.floor }
        floorReferencePoints = kept
        updatedAt = .now
        return true
    }

    /// 같은 높이에서 잰 다른 층 기준은 이번 기준과 함께 참일 수 없다. 층수만
    /// 맞춰 덮어쓰면 0m 떨어진 17층 차이 같은 모순이 그대로 남는다.
    private func conflictingReferenceIndices(
        with reference: FloorCalibrationPoint
    ) -> Set<Int> {
        var indices: Set<Int> = []
        for (index, existing) in floorReferencePoints.enumerated()
        where existing.floor != reference.floor {
            guard let delta = AltitudeDelta.between(
                AltitudeDelta.Sample(existing),
                and: AltitudeDelta.Sample(reference)
            ) else { continue }
            if abs(delta.meters) <= Self.conflictingAltitudeToleranceMeters {
                indices.insert(index)
            }
        }
        return indices
    }

    /// 사용자가 알려 주는 값은 "지금 몇 층인지" 하나뿐이다. 층 높이는 묻지
    /// 않고, 서로 다른 층 기준이 둘 이상 모이면 그 사이의 고도 차이로 앱이
    /// 다시 구한다. 위치나 기준 층이 아직 없으면 이번 기준으로 자리를 잡고,
    /// 있으면 자리는 두고 이 층만 더한다.
    mutating func calibrateCurrentFloor(
        to floor: Int,
        from reading: SensorReading
    ) {
        guard reading.point != nil else { return }
        if point == nil || self.floor == nil {
            setLocation(from: reading, floor: floor, isManual: true)
        } else {
            addFloorCalibration(from: reading, floor: floor, isManual: true)
            // 방금 확인한 층이 이 장소의 기준 층이 된다. 새 보정값을 넣었으면
            // 그 뒤의 모든 계산이 그것을 기준으로 다시 서야 한다.
            self.floor = floor
            referenceRelativeAltitudeMeters = reading.relativeAltitudeMeters
            referencePressureKilopascals = reading.pressureKilopascals
            referenceAltimeterSessionID = reading.altimeterSessionID
            floorCapturedAt = reading.timestamp
        }
        refreshFloorHeight()
        updatedAt = .now
    }

    /// 잘못 들어간 기준점 하나만 지운다. 나머지 기준과 이 장소의 위치는
    /// 그대로 둔다.
    @discardableResult
    mutating func removeFloorReference(floor target: Int) -> Bool {
        let kept = floorReferencePoints.filter { $0.floor != target }
        guard kept.count != floorReferencePoints.count else { return false }
        floorReferencePoints = kept
        if self.floor == target {
            let anchor = kept.last(where: \.isManual) ?? kept.last
            self.floor = anchor?.floor
            referenceRelativeAltitudeMeters = anchor?.relativeAltitudeMeters
            referencePressureKilopascals = anchor?.pressureKilopascals
            referenceAltimeterSessionID = anchor?.altimeterSessionID
            floorCapturedAt = anchor?.capturedAt
        }
        refreshFloorHeight()
        updatedAt = .now
        return true
    }

    /// 층 높이는 기준점에서 나온 파생값이다. 기준이 바뀌면 다시 구하고, 잴
    /// 짝이 하나도 남지 않으면 기본값으로 되돌린다. 지운 기준점에서 나온
    /// 값을 계속 쓰는 것이 더 위험하다.
    private mutating func refreshFloorHeight() {
        floorHeightMeters = FloorHeightEstimator.metersPerFloor(
            from: floorReferencePoints
        ) ?? Self.defaultFloorHeightMeters
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

/// 사용자가 "등록하지 않겠다"고 답한 자리. 같은 커피숍을 매주 다시 묻는 것이
/// 한 번도 묻지 않는 것보다 나쁘므로 만료 없이 남긴다. 자주가는 곳에서 지운
/// 자리도 같은 목록에 들어간다.
struct DismissedPlaceSuggestion: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var point: GeoPoint
    var dismissedAt: Date

    init(id: UUID = UUID(), point: GeoPoint, dismissedAt: Date = .now) {
        self.id = id
        self.point = point
        self.dismissedAt = dismissedAt
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
    /// `floor` 를 만든 관측. 예전 빌드가 쓴 기록에는 없으므로 Optional 이다.
    /// 없으면 그 기록은 다시 매기지 않고 있던 층수를 그대로 둔다.
    var floorEvidence: FloorEvidence?

    init(
        id: UUID = UUID(),
        placeKey: String,
        displayName: String,
        buildingName: String? = nil,
        floor: Int? = nil,
        span: TimeSpan,
        confidence: ConfidenceLevel,
        point: GeoPoint? = nil,
        isConfirmed: Bool = false,
        floorEvidence: FloorEvidence? = nil
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
        self.floorEvidence = floorEvidence
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
    /// 사용자가 직접 고른 도착 층. 자동 재계산은 이것을 덮지 않는다.
    static let userConfirmedEvidence = "사용자 확인"

    var id: UUID
    var placeKey: String
    var fromFloor: Int?
    var toFloor: Int?
    var relativeAltitudeMeters: Double
    var span: TimeSpan
    var confidence: ConfidenceLevel
    var evidence: [String]
    /// `fromFloor` 를 만든 관측. 예전 빌드가 쓴 기록에는 없다.
    var floorEvidence: FloorEvidence?

    var isUserConfirmed: Bool {
        evidence.contains(Self.userConfirmedEvidence)
    }
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
    /// 기기 위치 기록에서만 나오는 값이라 iCloud로 내보내지 않는다.
    var dismissedPlaceSuggestions: [DismissedPlaceSuggestion]
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
        dismissedPlaceSuggestions: [],
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
        dismissedPlaceSuggestions: [DismissedPlaceSuggestion] = [],
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
        self.dismissedPlaceSuggestions = dismissedPlaceSuggestions
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
        case dismissedPlaceSuggestions
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
