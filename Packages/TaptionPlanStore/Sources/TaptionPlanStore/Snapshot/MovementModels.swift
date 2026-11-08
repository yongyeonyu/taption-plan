import Foundation
import TaptionPlanCore
import TaptionWatchSync

// `TravelMode`·`TravelSegment`·`SubwayRouteStop`·`SubwayRoutePath`는
// `TaptionPlanCore/Domain/TravelSegment.swift`에 있다.

/// A single presentation source for movement results.  Automatic movement
/// records can arrive with a generic title (for example "차량 탑승") while
/// their classifier evidence contains the actual mode.  Keeping the mapping
/// here prevents the timeline and 기록 화면 from choosing different icons.
extension TravelMode {
    /// 목록·상세에 쓰는 선 아이콘. 채운 아이콘은 `MovementPresentation.symbol`이다.
    public var outlineSymbolName: String {
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

public enum MovementPresentation {
    // TimeRail 세그먼트가 후보마다 키워드배열×contains를 반복하던 것을 캐시로
    // 없앤다(CRS0925W01). 순수 함수라 입력이 같으면 결과도 같다.
    private static let modeCacheLock = NSLock()
    nonisolated(unsafe) private static var modeCache: [String: TravelMode?] = [:]

    private static func modeCacheKey(_ actual: ActualRecord) -> String {
        "\(actual.id.uuidString)|\(actual.title)|\(actual.behavior ?? "")|\(actual.evidence.joined(separator: ","))"
    }

    public static func mode(for actual: ActualRecord) -> TravelMode? {
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

    public static func symbol(for actual: ActualRecord) -> String {
        if let mode = mode(for: actual) { return symbol(for: mode) }
        switch actual.behavior.flatMap(WatchBehaviorKind.init(rawValue:)) {
        case .stairsUp, .stairsDown: return "stairs"
        case .elevator: return "arrow.up.and.down"
        default: return "figure.walk.motion"
        }
    }

    public static func symbol(for mode: TravelMode) -> String {
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

    public static func title(for mode: TravelMode) -> String {
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

    public static func englishTitle(for mode: TravelMode) -> String {
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

    public static func title(for actual: ActualRecord) -> String {
        if let behavior = actual.behavior.flatMap(WatchBehaviorKind.init(rawValue:)),
           behavior.isMovement {
            return behavior.title
        }
        return mode(for: actual).map(title(for:)) ?? actual.title
    }
}

public struct MapPredictedRoute: Identifiable, Codable, Hashable, Sendable {
    public let source: String
    public let travelID: UUID?
    public let mode: TravelMode
    public let span: TimeSpan
    public let coordinates: [GeoPoint]

    // Identity survives regenerated travel IDs and a change in the displayed cutoff.
    public var id: String {
        let endpoints = [coordinates.first, coordinates.last].compactMap { $0 }.map {
            "\(($0.latitude * 1_000_000).rounded()):\(($0.longitude * 1_000_000).rounded())"
        }.joined(separator: ":")
        return "\(source):\(mode.rawValue):\(span.start.timeIntervalSince1970.rounded()):\(span.end.timeIntervalSince1970.rounded()):\(endpoints)"
    }

    public var isValid: Bool {
        span.start.timeIntervalSince1970.isFinite && span.end.timeIntervalSince1970.isFinite
            && span.duration > 0 && coordinates.count >= 2
            && coordinates.allSatisfy {
                $0.latitude.isFinite && $0.longitude.isFinite
                    && (-90...90).contains($0.latitude) && (-180...180).contains($0.longitude)
            }
    }

    public init(
        source: String,
        travelID: UUID? = nil,
        mode: TravelMode,
        span: TimeSpan,
        coordinates: [GeoPoint]
    ) {
        self.source = source
        self.travelID = travelID
        self.mode = mode
        self.span = span
        self.coordinates = coordinates
    }
}

public struct MapPredictedRouteDecision: Identifiable, Codable, Hashable, Sendable {
    public let route: MapPredictedRoute
    public let isDeleted: Bool
    public let updatedAt: Date
    public var id: String { route.id }

    public func matches(_ candidate: MapPredictedRoute) -> Bool {
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

    public init(
        route: MapPredictedRoute,
        isDeleted: Bool,
        updatedAt: Date
    ) {
        self.route = route
        self.isDeleted = isDeleted
        self.updatedAt = updatedAt
    }
}

public struct TravelSegmentGroup: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var segments: [TravelSegment]

    public init(segments: [TravelSegment]) {
        self.segments = segments.sorted { $0.span.start < $1.span.start }
        id = self.segments.first?.id ?? UUID()
    }

    public var segmentIDs: [UUID] {
        segments.map(\.id)
    }

    public var mode: TravelMode {
        segments.first?.mode ?? .walking
    }

    public var span: TimeSpan {
        let now = Date.now
        return TimeSpan(
            start: segments.first?.span.start ?? now,
            end: segments.last?.span.end ?? now
        )
    }

    public var distanceMeters: Double {
        segments.reduce(0) { $0 + $1.distanceMeters }
    }

    public var confidence: ConfidenceLevel {
        if segments.contains(where: { $0.confidence == .low }) {
            return .low
        }
        if segments.allSatisfy({ $0.confidence == .high }) {
            return .high
        }
        return .medium
    }

    public var confirmedCount: Int {
        segments.filter(\.isConfirmed).count
    }

    public var isConfirmed: Bool {
        !segments.isEmpty && confirmedCount == segments.count
    }

    public var evidence: [String] {
        var seen = Set<String>()
        return segments.flatMap(\.evidence).filter {
            seen.insert($0).inserted
        }
    }

    public var fromPlaceID: UUID? {
        segments.first?.fromPlaceID
    }

    public var toPlaceID: UUID? {
        segments.last?.toPlaceID
    }
}

public struct TravelModeCorrection: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var fromPlaceKey: String?
    public var toPlaceKey: String?
    public var span: TimeSpan
    public var mode: TravelMode
    public var inferredMode: TravelMode
    public var inferredConfidence: ConfidenceLevel
    public var updatedAt: Date

    public init(
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

// `MotionKind`·`TrackingKind`·`TrackingDevice`는 `TaptionPlanCore/Domain/SensorReading.swift`에 있다.

public struct TrackingSession: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var kind: TrackingKind
    public var startedAt: Date
    public var endedAt: Date?
    public var linkedPlanID: UUID?
    public var sourceDevice: TrackingDevice
    public var iPhoneActive: Bool
    public var watchActive: Bool
    public var wasAutomaticallyDetected: Bool

    public init(
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
public enum TrackingSessionRecordPolicy {
    public static let userStartedEvidence = "사용자가 시작한 추적"

    /// 자동 세션은 수집 구간일 뿐 활동이 아니다. 실제 걷기는 모션 기록이 따로 남긴다.
    public static func actual(
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
    public static func isAutomaticSessionArtifact(_ actual: ActualRecord) -> Bool {
        actual.source == .location
            && actual.planID == nil
            && actual.behavior == nil
            && actual.evidence.isEmpty
            && actual.categoryID == "activity"
            && ["걷기", "달리기"].contains(actual.title)
    }
}

public struct LiveRouteState: Hashable, Sendable {
    public var session: TrackingSession?
    public var readings: [SensorReading]
    public var lastUpdatedAt: Date?

    public static let empty = LiveRouteState(
        session: nil,
        readings: [],
        lastUpdatedAt: nil
    )

    public init(
        session: TrackingSession? = nil,
        readings: [SensorReading],
        lastUpdatedAt: Date? = nil
    ) {
        self.session = session
        self.readings = readings
        self.lastUpdatedAt = lastUpdatedAt
    }
}

public struct MovementInference: Codable, Hashable, Sendable {
    public var mode: TravelMode
    public var confidence: ConfidenceLevel
    public var score: Double
    public var evidence: [String]
    public var subwayRoute: SubwayRoutePath? = nil

    public init(
        mode: TravelMode,
        confidence: ConfidenceLevel,
        score: Double,
        evidence: [String],
        subwayRoute: SubwayRoutePath? = nil
    ) {
        self.mode = mode
        self.confidence = confidence
        self.score = score
        self.evidence = evidence
        self.subwayRoute = subwayRoute
    }
}
