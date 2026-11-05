import Foundation
import TaptionPlanCore

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
extension TravelMode {
    /// 목록·상세에 쓰는 선 아이콘. 채운 아이콘은 `MovementPresentation.symbol`이다.
    var outlineSymbolName: String {
        switch self {
        case .walking: "figure.walk"
        case .running: "figure.run"
        case .cycling: "bicycle"
        case .bus: "bus"
        case .subway: "tram"
        case .taxi: "car.side"
        case .car: "car"
        case .train: "train.side.front.car"
        case .airplane: "airplane"
        case .ship: "ferry"
        }
    }
}

enum MovementPresentation {
    // TimeRail 세그먼트가 후보마다 키워드배열×contains를 반복하던 것을 캐시로
    // 없앤다(CRS0925W01). 순수 함수라 입력이 같으면 결과도 같다.
    private static let modeCacheLock = NSLock()
    nonisolated(unsafe) private static var modeCache: [String: TravelMode?] = [:]

    private static func modeCacheKey(_ actual: ActualRecord) -> String {
        "\(actual.id.uuidString)|\(actual.title)|\(actual.behavior ?? "")|\(actual.evidence.joined(separator: ","))"
    }

    static func mode(for actual: ActualRecord) -> TravelMode? {
        let key = modeCacheKey(actual)
        modeCacheLock.lock()
        if let cached = modeCache[key] {
            modeCacheLock.unlock()
            return cached
        }
        modeCacheLock.unlock()
        let result = _computeMode(for: actual)
        modeCacheLock.lock()
        if modeCache.count >= 4_096 { modeCache.removeAll(keepingCapacity: true) }
        modeCache[key] = result
        modeCacheLock.unlock()
        return result
    }

    private static func _computeMode(for actual: ActualRecord) -> TravelMode? {
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
        let words = Set(
            text.split { !($0.isASCII && $0.isLetter) }.map(String.init)
        )
        return keywords.first { _, terms in
            terms.contains {
                $0.count <= 4 && $0.allSatisfy(\.isASCII)
                    ? words.contains($0) : text.contains($0)
            }
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

    static func englishTitle(for mode: TravelMode) -> String {
        switch mode {
        case .walking: "Walking"
        case .running: "Running"
        case .cycling: "Cycling"
        case .bus: "Bus"
        case .subway: "Subway"
        case .taxi: "Taxi"
        case .car: "Car"
        case .train: "Train"
        case .airplane: "Airplane"
        case .ship: "Ship"
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
    var subwayRoute: SubwayRoutePath?
    /// Persisted automatic mode classification. User confirmation is still
    /// represented by `isConfirmed`; this flag protects inferred modes from
    /// changing during a later archive refresh.
    var isClassificationLocked: Bool

    private enum CodingKeys: String, CodingKey {
        case id, fromPlaceID, toPlaceID, mode, span, distanceMeters,
             confidence, evidence, isConfirmed, subwayRoute,
             isClassificationLocked
    }

    init(
        id: UUID = UUID(),
        fromPlaceID: UUID? = nil,
        toPlaceID: UUID? = nil,
        mode: TravelMode,
        span: TimeSpan,
        distanceMeters: Double,
        confidence: ConfidenceLevel,
        evidence: [String],
        isConfirmed: Bool = false,
        subwayRoute: SubwayRoutePath? = nil,
        isClassificationLocked: Bool = false
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
        self.subwayRoute = subwayRoute
        self.isClassificationLocked = isClassificationLocked
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        fromPlaceID = try values.decodeIfPresent(UUID.self, forKey: .fromPlaceID)
        toPlaceID = try values.decodeIfPresent(UUID.self, forKey: .toPlaceID)
        mode = try values.decode(TravelMode.self, forKey: .mode)
        span = try values.decode(TimeSpan.self, forKey: .span)
        distanceMeters = max(
            0,
            try values.decodeIfPresent(Double.self, forKey: .distanceMeters) ?? 0
        )
        confidence = try values.decode(ConfidenceLevel.self, forKey: .confidence)
        evidence = try values.decodeIfPresent([String].self, forKey: .evidence) ?? []
        isConfirmed = try values.decodeIfPresent(Bool.self, forKey: .isConfirmed) ?? false
        subwayRoute = try values.decodeIfPresent(SubwayRoutePath.self, forKey: .subwayRoute)
        isClassificationLocked = try values.decodeIfPresent(
            Bool.self,
            forKey: .isClassificationLocked
        ) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encodeIfPresent(fromPlaceID, forKey: .fromPlaceID)
        try values.encodeIfPresent(toPlaceID, forKey: .toPlaceID)
        try values.encode(mode, forKey: .mode)
        try values.encode(span, forKey: .span)
        try values.encode(distanceMeters, forKey: .distanceMeters)
        try values.encode(confidence, forKey: .confidence)
        try values.encode(evidence, forKey: .evidence)
        try values.encode(isConfirmed, forKey: .isConfirmed)
        try values.encodeIfPresent(subwayRoute, forKey: .subwayRoute)
        try values.encode(isClassificationLocked, forKey: .isClassificationLocked)
    }
}

struct MapPredictedRoute: Identifiable, Codable, Hashable, Sendable {
    let source: String
    let travelID: UUID?
    let mode: TravelMode
    let span: TimeSpan
    let coordinates: [GeoPoint]

    // Identity survives regenerated travel IDs and a change in the displayed cutoff.
    var id: String {
        let endpoints = [coordinates.first, coordinates.last].compactMap { $0 }.map {
            "\(($0.latitude * 1_000_000).rounded()):\(($0.longitude * 1_000_000).rounded())"
        }.joined(separator: ":")
        return "\(source):\(mode.rawValue):\(span.start.timeIntervalSince1970.rounded()):\(span.end.timeIntervalSince1970.rounded()):\(endpoints)"
    }

    var isValid: Bool {
        span.start.timeIntervalSince1970.isFinite && span.end.timeIntervalSince1970.isFinite
            && span.duration > 0 && coordinates.count >= 2
            && coordinates.allSatisfy {
                $0.latitude.isFinite && $0.longitude.isFinite
                    && (-90...90).contains($0.latitude) && (-180...180).contains($0.longitude)
            }
    }
}

struct MapPredictedRouteDecision: Identifiable, Codable, Hashable, Sendable {
    let route: MapPredictedRoute
    let isDeleted: Bool
    let updatedAt: Date
    var id: String { route.id }

    func matches(_ candidate: MapPredictedRoute) -> Bool {
        if let id = route.travelID, id == candidate.travelID,
           let overlap = route.span.intersection(with: candidate.span),
           overlap.duration >= min(route.span.duration, candidate.span.duration) * 0.9 {
            return true
        }
        guard route.source == candidate.source,
              abs(route.span.start.timeIntervalSince(candidate.span.start)) <= 1,
              abs(route.span.end.timeIntervalSince(candidate.span.end)) <= 1,
              let first = route.coordinates.first, let last = route.coordinates.last,
              let candidateFirst = candidate.coordinates.first, let candidateLast = candidate.coordinates.last else { return false }
        func close(_ lhs: GeoPoint, _ rhs: GeoPoint) -> Bool {
            let dx = (lhs.longitude - rhs.longitude) * cos(lhs.latitude * .pi / 180)
            return hypot(lhs.latitude - rhs.latitude, dx) * 111_320 <= 50
        }
        return close(first, candidateFirst) && close(last, candidateLast)
    }
}

struct SubwayRouteStop: Codable, Hashable, Sendable {
    var lineName: String
    var order: Int
    var stationName: String
    var latitude: Double?
    var longitude: Double?

    var coordinate: GeoPoint? {
        guard let latitude, let longitude else { return nil }
        return GeoPoint(
            latitude: latitude,
            longitude: longitude,
            altitude: 0,
            horizontalAccuracy: -1,
            verticalAccuracy: -1
        )
    }
}

struct SubwayRoutePath: Codable, Hashable, Sendable {
    var stops: [SubwayRouteStop]
    var lineNames: [String]
    var transferStationNames: [String]

    var coordinates: [GeoPoint] {
        stops.compactMap(\.coordinate)
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

/// 추적 세션을 활동 기록으로 남길지 정한다(WLK1105A01).
enum TrackingSessionRecordPolicy {
    static let userStartedEvidence = "사용자가 시작한 추적"

    /// 자동 세션은 수집 구간일 뿐 활동이 아니다. 실제 걷기는 모션 기록이 따로 남긴다.
    static func actual(
        for session: TrackingSession,
        endedAt: Date,
        planID: UUID?,
        planTitle: String?,
        planCategoryID: String?
    ) -> ActualRecord? {
        guard !session.wasAutomaticallyDetected else { return nil }
        return ActualRecord(
            id: session.id,
            planID: planID,
            title: planTitle ?? (session.kind == .running ? "달리기" : "걷기"),
            categoryID: planCategoryID ?? "activity",
            startedAt: session.startedAt,
            endedAt: endedAt,
            source: session.sourceDevice == .appleWatch ? .appleWatch : .location,
            confidence: .high,
            evidence: [userStartedEvidence]
        )
    }

    /// 예전 버전이 자동 세션으로 저장한 근거 없는 기록.
    static func isAutomaticSessionArtifact(_ actual: ActualRecord) -> Bool {
        actual.source == .location
            && actual.planID == nil
            && actual.behavior == nil
            && actual.evidence.isEmpty
            && actual.categoryID == "activity"
            && ["걷기", "달리기"].contains(actual.title)
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

struct MovementInference: Codable, Hashable, Sendable {
    var mode: TravelMode
    var confidence: ConfidenceLevel
    var score: Double
    var evidence: [String]
    var subwayRoute: SubwayRoutePath? = nil
}
