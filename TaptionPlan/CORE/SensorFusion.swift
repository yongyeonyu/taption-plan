import Foundation

struct TravelModeClassifier: Sendable {
    func classify(
        readings: [SensorReading],
        correctedMode: TravelMode? = nil
    ) -> MovementInference {
        guard !readings.isEmpty else {
            return MovementInference(
                mode: .walking,
                confidence: .low,
                score: 0,
                evidence: ["센서 데이터 부족"]
            )
        }
        if let correctedMode {
            return MovementInference(
                mode: correctedMode,
                confidence: .high,
                score: 1,
                evidence: ["사용자 교정"]
            )
        }

        let speeds = readings.compactMap(\.speedMetersPerSecond).filter { $0 >= 0 }
        let averageSpeed = speeds.isEmpty ? 0 : speeds.reduce(0, +) / Double(speeds.count)
        let gpsLossRatio = Double(readings.filter { !$0.gpsAvailable }.count)
            / Double(readings.count)
        let relativeAltitudes = readings.compactMap(\.relativeAltitudeMeters)
        let altitudeDelta = (relativeAltitudes.last ?? 0) - (relativeAltitudes.first ?? 0)
        let dominantMotion = Dictionary(grouping: readings, by: \.motion)
            .max(by: { $0.value.count < $1.value.count })?.key ?? .unknown

        var candidates: [TravelMode: (Double, [String])] = [:]
        func add(_ mode: TravelMode, _ score: Double, _ evidence: String) {
            var current = candidates[mode] ?? (0, [])
            current.0 += score
            current.1.append(evidence)
            candidates[mode] = current
        }

        switch dominantMotion {
        case .walking:
            add(.walking, 0.75, "Core Motion 보행")
        case .running:
            add(.running, 0.82, "Core Motion 달리기")
        case .cycling:
            add(.cycling, 0.82, "Core Motion 자전거")
        case .automotive:
            add(.car, 0.35, "Core Motion 자동차 후보")
            add(.bus, 0.2, "동력 이동")
            add(.taxi, 0.2, "동력 이동")
        case .stationary, .unknown:
            break
        }

        for workout in readings.compactMap(\.watchWorkoutKind).map({
            $0.localizedLowercase
        }) {
            if workout.contains("run") || workout.contains("달리") {
                add(.running, 0.25, "Apple Watch 달리기 운동")
            } else if workout.contains("walk") || workout.contains("걷") {
                add(.walking, 0.25, "Apple Watch 걷기 운동")
            } else if workout.contains("cycl") || workout.contains("자전거") {
                add(.cycling, 0.25, "Apple Watch 자전거 운동")
            }
        }

        if averageSpeed < 2.2 {
            add(.walking, 0.14, "평균 저속")
        } else if averageSpeed < 5.5 {
            add(.running, 0.12, "달리기 속도대")
            add(.cycling, 0.14, "자전거 속도대")
        } else if averageSpeed > 55 {
            add(.airplane, 0.65, "고속 이동")
        } else if averageSpeed > 18 {
            add(.train, 0.2, "철도 가능 속도")
            add(.car, 0.16, "도로 이동 가능 속도")
        }

        let stationRatio = ratio(readings, where: \.nearbyStation)
        let railRatio = ratio(readings, where: \.matchesRailRoute)
        let transitRatio = ratio(readings, where: \.matchesPublicTransitRoute)
        let stopRatio = ratio(readings, where: \.frequentStops)
        let taxiHintRatio = ratio(readings, where: \.rideHailingHint)
        let airportRatio = ratio(readings, where: \.nearAirport)
        let portRatio = ratio(readings, where: \.nearPort)
        let waterRatio = ratio(readings, where: \.onWater)

        if stationRatio >= 0.25 {
            add(.subway, 0.16, "역 접근")
            add(.train, 0.1, "역 접근")
        }
        if railRatio >= 0.5 {
            add(.subway, 0.2, "철도 경로 일치")
            add(.train, 0.28, "철도 경로 일치")
        }
        if gpsLossRatio >= 0.45 {
            add(.subway, 0.18, "GPS 약화")
        }
        if altitudeDelta <= -2 {
            add(.subway, 0.16, "상대고도 하강")
        }
        if stationRatio >= 0.25,
           railRatio >= 0.5,
           gpsLossRatio >= 0.45,
           altitudeDelta <= -2 {
            add(.subway, 0.3, "지하철 복합 신호 충족")
        }

        if transitRatio >= 0.5 {
            add(.bus, 0.35, "대중교통 도로 경로 일치")
        }
        if stopRatio >= 0.35 {
            add(.bus, 0.22, "정류장형 반복 정차")
        }
        if taxiHintRatio >= 0.5 {
            add(.taxi, 0.55, "택시 이용 단서")
        }
        if airportRatio >= 0.25, averageSpeed > 35 {
            add(.airplane, 0.32, "공항 인접 고속 이동")
        }
        if portRatio >= 0.2 || waterRatio >= 0.4 {
            add(.ship, 0.55, "항구·수상 경로")
        }

        let winner = candidates.max { lhs, rhs in lhs.value.0 < rhs.value.0 }
            ?? (.walking, (0.2, ["기본 저신뢰 보행 후보"]))
        let score = min(1, winner.value.0)
        return MovementInference(
            mode: winner.key,
            confidence: ConfidenceLevel(score: score),
            score: score,
            evidence: Array(Set(winner.value.1)).sorted()
        )
    }

    private func ratio(
        _ readings: [SensorReading],
        where keyPath: KeyPath<SensorReading, Bool>
    ) -> Double {
        Double(readings.filter { $0[keyPath: keyPath] }.count) / Double(readings.count)
    }
}

struct FloorEstimator: Sendable {
    var defaultFloorHeightMeters: Double = 3

    func estimate(
        readings: [SensorReading],
        placeKey: String,
        baselineFloor: Int?,
        floorHeightMeters: Double? = nil
    ) -> FloorTransition? {
        guard let first = readings.first, let last = readings.last,
              first.timestamp < last.timestamp else {
            return nil
        }

        let systemFloors = readings.compactMap(\.systemFloor)
        if let from = systemFloors.first,
           let to = systemFloors.last,
           from != to {
            return FloorTransition(
                id: UUID(),
                placeKey: placeKey,
                fromFloor: from,
                toFloor: to,
                relativeAltitudeMeters: Double(to - from) * defaultFloorHeightMeters,
                span: TimeSpan(start: first.timestamp, end: last.timestamp),
                confidence: .high,
                evidence: ["시스템 실내 층 정보"]
            )
        }

        let altitudeValues = readings.compactMap(\.relativeAltitudeMeters)
        guard let altitudeStart = altitudeValues.first,
              let altitudeEnd = altitudeValues.last else {
            return nil
        }
        let delta = altitudeEnd - altitudeStart
        let floorHeight = max(2.2, floorHeightMeters ?? defaultFloorHeightMeters)
        let floorDelta = Int((delta / floorHeight).rounded())
        guard floorDelta != 0 else { return nil }

        let firstAscended = readings.first?.floorsAscended ?? 0
        let lastAscended = readings.last?.floorsAscended ?? firstAscended
        let firstDescended = readings.first?.floorsDescended ?? 0
        let lastDescended = readings.last?.floorsDescended ?? firstDescended
        let pedometerDelta = (lastAscended - firstAscended)
            - (lastDescended - firstDescended)
        let evidence = [
            "상대고도 \(String(format: "%+.1f", delta))m",
            pedometerDelta == 0 ? nil : "층계 \(pedometerDelta > 0 ? "+" : "")\(pedometerDelta)"
        ].compactMap { $0 }
        let confidence: ConfidenceLevel = baselineFloor == nil
            ? .low
            : (pedometerDelta == floorDelta || systemFloors.count > 1 ? .high : .medium)

        return FloorTransition(
            id: UUID(),
            placeKey: placeKey,
            fromFloor: baselineFloor,
            toFloor: baselineFloor.map { $0 + floorDelta },
            relativeAltitudeMeters: delta,
            span: TimeSpan(start: first.timestamp, end: last.timestamp),
            confidence: confidence,
            evidence: evidence
        )
    }
}

struct PlaceDetectionEngine: Sendable {
    var minimumDwell: TimeInterval = 15 * 60
    var radiusMeters: Double = 70

    func detectStays(
        readings: [SensorReading],
        knownNames: [String: String] = [:]
    ) -> [PlaceStay] {
        let sorted = readings
            .filter { $0.point != nil }
            .sorted { $0.timestamp < $1.timestamp }
        guard !sorted.isEmpty else { return [] }

        var groups: [[SensorReading]] = []
        var current: [SensorReading] = []

        for reading in sorted {
            guard let point = reading.point else { continue }
            if let anchor = current.first?.point,
               distanceMeters(anchor, point) > radiusMeters {
                if !current.isEmpty { groups.append(current) }
                current = [reading]
            } else {
                current.append(reading)
            }
        }
        if !current.isEmpty { groups.append(current) }

        return groups.compactMap { group in
            guard let first = group.first,
                  let last = group.last,
                  let point = representativePoint(group) else {
                return nil
            }
            let span = TimeSpan(start: first.timestamp, end: last.timestamp)
            guard span.duration >= minimumDwell else { return nil }
            let key = placeKey(for: point)
            let floor = stableFloor(in: group)
            let displayName = knownNames[key]
                ?? (floor.map { "장소 · \($0)층 추정" } ?? "자동 감지 장소")
            let accuracy = group.map { $0.point?.horizontalAccuracy ?? 100 }.reduce(0, +)
                / Double(group.count)
            return PlaceStay(
                placeKey: key,
                displayName: displayName,
                floor: floor,
                span: span,
                confidence: ConfidenceLevel(score: accuracy <= 30 ? 0.82 : 0.55),
                point: point
            )
        }
    }

    private func representativePoint(_ readings: [SensorReading]) -> GeoPoint? {
        let points = readings.compactMap(\.point)
        guard !points.isEmpty else { return nil }
        let count = Double(points.count)
        return GeoPoint(
            latitude: points.map(\.latitude).reduce(0, +) / count,
            longitude: points.map(\.longitude).reduce(0, +) / count,
            altitude: points.map(\.altitude).reduce(0, +) / count,
            horizontalAccuracy: points.map(\.horizontalAccuracy).reduce(0, +) / count,
            verticalAccuracy: points.map(\.verticalAccuracy).reduce(0, +) / count
        )
    }

    private func stableFloor(in readings: [SensorReading]) -> Int? {
        let counts = Dictionary(grouping: readings.compactMap(\.systemFloor), by: { $0 })
        return counts.max { $0.value.count < $1.value.count }?.key
    }

    private func placeKey(for point: GeoPoint) -> String {
        String(format: "%.4f,%.4f", point.latitude, point.longitude)
    }
}

struct MovementRouteBuilder: Sendable {
    var classifier = TravelModeClassifier()

    func build(
        stays: [PlaceStay],
        readings: [SensorReading],
        correctedModes: [String: TravelMode] = [:]
    ) -> [TravelSegment] {
        let orderedStays = stays.sorted { $0.span.start < $1.span.start }
        guard orderedStays.count >= 2 else { return [] }

        return zip(orderedStays, orderedStays.dropFirst()).compactMap { from, to in
            let span = TimeSpan(start: from.span.end, end: to.span.start)
            guard span.duration > 0 else { return nil }
            let segmentReadings = readings.filter {
                span.contains($0.timestamp)
            }
            let signature = "\(from.placeKey)->\(to.placeKey)"
            let inference = classifier.classify(
                readings: segmentReadings,
                correctedMode: correctedModes[signature]
            )
            let distance = pathDistance(segmentReadings.compactMap(\.point))
            return TravelSegment(
                fromPlaceID: from.id,
                toPlaceID: to.id,
                mode: inference.mode,
                span: span,
                distanceMeters: distance,
                confidence: inference.confidence,
                evidence: inference.evidence,
                isConfirmed: correctedModes[signature] != nil
            )
        }
    }

    private func pathDistance(_ points: [GeoPoint]) -> Double {
        zip(points, points.dropFirst()).reduce(0) {
            $0 + distanceMeters($1.0, $1.1)
        }
    }
}

enum RouteElement: Identifiable, Hashable, Sendable {
    case place(PlaceStay)
    case travel(TravelSegment)
    case floor(FloorTransition)

    var id: String {
        switch self {
        case .place(let value): "place-\(value.id.uuidString)"
        case .travel(let value): "travel-\(value.id.uuidString)"
        case .floor(let value): "floor-\(value.id.uuidString)"
        }
    }

    var span: TimeSpan {
        switch self {
        case .place(let value): value.span
        case .travel(let value): value.span
        case .floor(let value): value.span
        }
    }
}

enum RouteTimelineEngine {
    static func orderedElements(
        places: [PlaceStay],
        travel: [TravelSegment],
        floors: [FloorTransition]
    ) -> [RouteElement] {
        (
            places.map(RouteElement.place)
                + travel.map(RouteElement.travel)
                + floors.map(RouteElement.floor)
        )
        .sorted { $0.span.start < $1.span.start }
    }

    static func horizontalRange(
        of element: RouteElement,
        viewport: TimelineViewport
    ) -> ClosedRange<Double> {
        let lower = TimelineCoordinateMapper.fraction(
            for: element.span.start,
            in: viewport
        )
        let upper = TimelineCoordinateMapper.fraction(
            for: element.span.end,
            in: viewport
        )
        return lower...upper
    }

    static func currentElement(
        at date: Date,
        elements: [RouteElement]
    ) -> RouteElement? {
        elements.first { $0.span.contains(date) }
    }
}

actor MovementCorrectionStore {
    private var corrections: [String: TravelMode]

    init(corrections: [String: TravelMode] = [:]) {
        self.corrections = corrections
    }

    func correctedMode(
        from placeKey: String,
        to nextPlaceKey: String
    ) -> TravelMode? {
        corrections["\(placeKey)->\(nextPlaceKey)"]
    }

    func set(
        _ mode: TravelMode,
        from placeKey: String,
        to nextPlaceKey: String
    ) {
        corrections["\(placeKey)->\(nextPlaceKey)"] = mode
    }

    func all() -> [String: TravelMode] {
        corrections
    }
}

enum LocationPrivacyFilter {
    static func timelineSafe(_ place: PlaceStay) -> PlaceStay {
        var value = place
        value.point = nil
        return value
    }

    static func widgetSafe(
        places: [PlaceStay],
        travel: [TravelSegment]
    ) -> (places: [PlaceStay], travel: [TravelSegment]) {
        (
            places.map(timelineSafe),
            travel.map { segment in
                var value = segment
                value.evidence = []
                return value
            }
        )
    }
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
