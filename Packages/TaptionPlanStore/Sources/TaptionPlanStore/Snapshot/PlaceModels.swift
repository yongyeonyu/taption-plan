import Foundation
import TaptionPlanCore

public enum FrequentPlaceKind: String, Codable, CaseIterable, Sendable {
    case home
    case school
    case academy
    case company
    case hobby
    case exercise
    case restaurant
    case custom

    public var defaultName: String {
        switch self {
        case .home: "집"
        case .school: "학교"
        case .academy: "학원"
        case .company: "회사"
        case .hobby: "취미"
        case .exercise: "운동"
        case .restaurant: "식당"
        case .custom: "사용자 추가"
        }
    }

    public var systemImage: String {
        switch self {
        case .home: "house.fill"
        case .school: "graduationcap.fill"
        case .academy: "book.closed.fill"
        case .company: "building.2.fill"
        case .hobby: "paintpalette.fill"
        case .exercise: "figure.run"
        case .restaurant: "storefront.fill"
        case .custom: "plus.circle.fill"
        }
    }
}

public enum UserTransitLocationKind: String, Codable, CaseIterable, Hashable, Sendable {
    case subwayStation
    case busStop
    case trainStation
    case airport
    case harbor

    public var title: String {
        switch self {
        case .subwayStation: "지하철역"
        case .busStop: "버스정류장"
        case .trainStation: "기차역"
        case .airport: "공항"
        case .harbor: "항구"
        }
    }

    public var englishTitle: String {
        switch self {
        case .subwayStation: "Subway station"
        case .busStop: "Bus stop"
        case .trainStation: "Train station"
        case .airport: "Airport"
        case .harbor: "Harbor"
        }
    }

    public var systemImage: String {
        switch self {
        case .subwayStation: "tram.fill"
        case .busStop: "bus.fill"
        case .trainStation: "train.side.front.car"
        case .airport: "airplane"
        case .harbor: "ferry.fill"
        }
    }

    public var boardingMode: TravelMode {
        switch self {
        case .subwayStation: .subway
        case .busStop: .bus
        case .trainStation: .train
        case .airport: .airplane
        case .harbor: .ship
        }
    }

    public var mapKitQueries: [String] {
        switch self {
        case .subwayStation: ["지하철역", "subway station"]
        case .busStop: ["버스정류장", "bus stop"]
        case .trainStation: ["기차역", "train station"]
        case .airport: ["공항", "airport"]
        case .harbor: ["항구", "여객터미널", "harbor"]
        }
    }

    public var mapKitSearchRadiusMeters: Double {
        switch self {
        case .subwayStation: 450
        case .busStop: 140
        case .trainStation: 500
        case .airport: 1_200
        case .harbor: 600
        }
    }
}

public struct UserTransitLocation: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: UserTransitLocationKind
    public var point: GeoPoint
    public var floor: Int?
    public var radiusMeters: Double
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        kind: UserTransitLocationKind,
        point: GeoPoint,
        floor: Int? = nil,
        radiusMeters: Double = 100,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.point = point
        self.floor = floor
        self.radiusMeters = radiusMeters
        self.createdAt = createdAt
    }
}

public enum TransitBoardingPlaceSource: String, Codable, Hashable, Sendable {
    case registered
    case catalog
    case mapKit
}

public struct TransitBoardingPlace: Hashable, Sendable {
    public let id: String
    public let name: String
    public let kind: UserTransitLocationKind
    public let point: GeoPoint
    public let radiusMeters: Double
    public let source: TransitBoardingPlaceSource
    public let userLocationID: UUID?

    public init(registered location: UserTransitLocation) {
        id = "registered-\(location.id.uuidString)"
        name = location.name
        kind = location.kind
        point = location.point
        radiusMeters = max(1, location.radiusMeters)
        source = .registered
        userLocationID = location.id
    }

    public init(
        mapKitIdentifier: String? = nil,
        mapKitName name: String,
        kind: UserTransitLocationKind,
        point: GeoPoint
    ) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanIdentifier = mapKitIdentifier?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if let cleanIdentifier, !cleanIdentifier.isEmpty {
            id = "mapkit-\(kind.rawValue)-\(cleanIdentifier)"
        } else {
            let latitudeKey = Int((point.latitude * 1_000).rounded())
            let longitudeKey = Int((point.longitude * 1_000).rounded())
            id = "mapkit-\(kind.rawValue)-\(latitudeKey):\(longitudeKey)"
        }
        self.name = cleanName
        self.kind = kind
        self.point = point
        radiusMeters = kind.mapKitSearchRadiusMeters
        source = .mapKit
        userLocationID = nil
    }

    public init(catalogSubwayName name: String, point: GeoPoint) {
        let latitudeKey = Int((point.latitude * 10_000).rounded())
        let longitudeKey = Int((point.longitude * 10_000).rounded())
        id = "catalog-subway-\(latitudeKey):\(longitudeKey)"
        self.name = name
        kind = .subwayStation
        self.point = point
        radiusMeters = 250
        source = .catalog
        userLocationID = nil
    }
}

public struct TransitBoardingCandidate: Identifiable, Hashable, Sendable {
    public let id: String
    public let placeID: String
    public let locationID: UUID?
    public let name: String
    public let kind: UserTransitLocationKind
    public let point: GeoPoint
    public let span: TimeSpan
    public let dwellDuration: TimeInterval
    public let source: TransitBoardingPlaceSource
    public let travelSegmentIDs: [UUID]
    public var subwayRoutes: [TransitBoardingSubwayRoute] = []

    public var mode: TravelMode {
        kind.boardingMode
    }

    public init(
        id: String,
        placeID: String,
        locationID: UUID? = nil,
        name: String,
        kind: UserTransitLocationKind,
        point: GeoPoint,
        span: TimeSpan,
        dwellDuration: TimeInterval,
        source: TransitBoardingPlaceSource,
        travelSegmentIDs: [UUID],
        subwayRoutes: [TransitBoardingSubwayRoute] = []
    ) {
        self.id = id
        self.placeID = placeID
        self.locationID = locationID
        self.name = name
        self.kind = kind
        self.point = point
        self.span = span
        self.dwellDuration = dwellDuration
        self.source = source
        self.travelSegmentIDs = travelSegmentIDs
        self.subwayRoutes = subwayRoutes
    }
}

public struct TransitBoardingSubwayRoute: Codable, Hashable, Sendable {
    public var travelSegmentID: UUID
    public var span: TimeSpan
    public var route: SubwayRoutePath

    public init(
        travelSegmentID: UUID,
        span: TimeSpan,
        route: SubwayRoutePath
    ) {
        self.travelSegmentID = travelSegmentID
        self.span = span
        self.route = route
    }
}

public struct TransitBoardingDecision: Identifiable, Codable, Hashable, Sendable {
    public var candidateKey: String
    /// Stable enough to match the same registered or nearby logical place
    /// after MapKit changes its display name or coordinate slightly.
    public var placeID: String?
    public var kind: UserTransitLocationKind?
    public var point: GeoPoint?
    public var span: TimeSpan
    public var mode: TravelMode?
    public var travelSegmentIDs: [UUID]
    public var subwayRoutes: [TransitBoardingSubwayRoute]?
    public var updatedAt: Date

    public var id: String { candidateKey }

    public init(
        candidateKey: String,
        placeID: String? = nil,
        kind: UserTransitLocationKind? = nil,
        point: GeoPoint? = nil,
        span: TimeSpan,
        mode: TravelMode?,
        travelSegmentIDs: [UUID] = [],
        subwayRoutes: [TransitBoardingSubwayRoute]? = nil,
        updatedAt: Date = .now
    ) {
        self.candidateKey = candidateKey
        self.placeID = placeID
        self.kind = kind
        self.point = point
        self.span = span
        self.mode = mode
        self.travelSegmentIDs = travelSegmentIDs
        self.subwayRoutes = subwayRoutes
        self.updatedAt = updatedAt
    }
}

public struct FrequentPlace: Identifiable, Codable, Hashable, Sendable {
    /// 지도에서 바로 식당으로 등록하면 이름이 기본 문구로 남을 수 있어 화면에는 식당으로 보여 준다.
    public var displayName: String {
        guard kind == .restaurant else { return name }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "사용자 지점"
            || trimmed.caseInsensitiveCompare("User location") == .orderedSame {
            return "식당"
        }
        return trimmed
    }

    public var id: UUID
    public var kind: FrequentPlaceKind
    public var name: String
    public var point: GeoPoint?
    public var floor: Int?
    public var referenceRelativeAltitudeMeters: Double?
    public var referencePressureKilopascals: Double?
    public var referenceAltimeterSessionID: UUID?
    public var floorCapturedAt: Date?
    public var floorReferencePoints: [FloorCalibrationPoint]
    public var radiusMeters: Double
    /// 건물마다 다른 층 높이를 고도 보정에 사용합니다. 기본값은 3m입니다.
    public var floorHeightMeters: Double
    /// 장소로 확정하기 위해 머물러야 하는 최소 시간입니다.
    public var minimumDwellMinutes: Int
    /// 끄면 이 장소는 자동 위치 분석에서 제외하고 수동 기록만 사용합니다.
    public var isAutomaticRecordingEnabled: Bool
    public var createdAt: Date
    public var updatedAt: Date

    /// 새로 등록하는 장소의 반경(대표 지시 2026-11-12: 기본 200m). 저장된 장소는 저장된 값을 그대로 쓴다.
    public static let defaultRadiusMeters = 200.0
    static let legacyDefaultRadiusMeters = 120.0

    public init(
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
        radiusMeters: Double = FrequentPlace.defaultRadiusMeters,
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
        let minimumDwell = kind == .restaurant
            ? max(15, minimumDwellMinutes)
            : minimumDwellMinutes
        self.minimumDwellMinutes = min(max(minimumDwell, 1), 240)
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
    public init(from decoder: Decoder) throws {
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
                    ?? Self.legacyDefaultRadiusMeters,
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
        let decodedMinimumDwell = try values.decodeIfPresent(
            Int.self,
            forKey: .minimumDwellMinutes
        ) ?? 10
        let minimumDwell = decodedKind == .restaurant
            ? max(15, decodedMinimumDwell)
            : decodedMinimumDwell
        minimumDwellMinutes = min(max(minimumDwell, 1), 240)
        isAutomaticRecordingEnabled = try values.decodeIfPresent(
            Bool.self,
            forKey: .isAutomaticRecordingEnabled
        ) ?? true
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt)
            ?? .now
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt)
            ?? createdAt
    }

    public func encode(to encoder: Encoder) throws {
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

    public static let defaults: [FrequentPlace] = [
        FrequentPlace(kind: .home),
        FrequentPlace(kind: .school),
        FrequentPlace(kind: .academy),
        FrequentPlace(kind: .company),
        FrequentPlace(kind: .hobby),
        FrequentPlace(kind: .exercise),
    ]

    public var stablePlaceKey: String {
        "frequent-\(id.uuidString.lowercased())"
    }

    public var floorCalibration: FloorCalibration? {
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

    public mutating func setLocation(
        from reading: SensorReading,
        floor: Int,
        isManual: Bool = false
    ) {
        guard let point = reading.point else { return }
        adoptDefaultRadiusIfUnplaced()
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

    /// 아직 위치를 정하지 않은 칸은 예전 기본값(120m)으로 저장돼 있을 수 있다. 처음 등록할 때 지금 기본값으로 맞춘다.
    private mutating func adoptDefaultRadiusIfUnplaced() {
        if point == nil, radiusMeters == Self.legacyDefaultRadiusMeters { radiusMeters = Self.defaultRadiusMeters }
    }

    public mutating func setMapLocation(_ newPoint: GeoPoint) {
        adoptDefaultRadiusIfUnplaced()
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

    public static let sameBuildingRadiusMeters = 120.0
    public static let defaultFloorHeightMeters = 3.0

    /// 서로 다른 층이라면 최소 층 높이(2.2m)만큼은 떨어져 있어야 한다. 그
    /// 절반보다 가까운 두 기준점은 같은 높이를 가리키므로 둘 다 참일 수 없다.
    /// 가만히 선 기기의 기압계 잡음(수십 cm)보다는 넉넉하다.
    public static let conflictingAltitudeToleranceMeters = 1.0

    @discardableResult
    public mutating func addFloorCalibration(
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
    public mutating func calibrateCurrentFloor(
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
    public mutating func removeFloorReference(floor target: Int) -> Bool {
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

    public mutating func clearLocation() {
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
public struct DismissedPlaceSuggestion: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var point: GeoPoint
    public var dismissedAt: Date

    public init(id: UUID = UUID(), point: GeoPoint, dismissedAt: Date = .now) {
        self.id = id
        self.point = point
        self.dismissedAt = dismissedAt
    }
}

public struct PlaceStay: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var placeKey: String
    public var displayName: String
    public var buildingName: String?
    public var floor: Int?
    public var span: TimeSpan
    public var confidence: ConfidenceLevel
    public var point: GeoPoint?
    public var isConfirmed: Bool
    /// `floor` 를 만든 관측. 예전 빌드가 쓴 기록에는 없으므로 Optional 이다.
    /// 없으면 그 기록은 다시 매기지 않고 있던 층수를 그대로 둔다.
    public var floorEvidence: FloorEvidence?

    public init(
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
