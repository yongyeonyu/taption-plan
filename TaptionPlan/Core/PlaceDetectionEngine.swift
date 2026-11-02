import Foundation
import TaptionPlanEngine

struct PlaceDetectionEngine: Sendable {
    var minimumDwell: TimeInterval = 15 * 60
    var radiusMeters: Double = 70
    var maximumSampleGap: TimeInterval = 90 * 60

    func detectStays(
        readings: [SensorReading],
        knownNames: [String: String] = [:]
    ) -> [PlaceStay] {
        let sorted = readings
            .filter {
                RouteTimelineTimestamp.isValid($0.timestamp)
                    && $0.point != nil
            }
            .sorted { $0.timestamp < $1.timestamp }
        guard !sorted.isEmpty else { return [] }

        // Zheng/Li stay point: 기준은 첫 점이 아니라 지금까지 묶인 표본의 중심이다(ALG1101A01).
        // 첫 점이 GPS로 튀어 있으면 실제 자리에서 반경을 넘었다고 보고 체류가 쪼개졌다.
        var groups: [[SensorReading]] = []
        var current: [SensorReading] = []
        var sumLatitude = 0.0, sumLongitude = 0.0

        for reading in sorted {
            guard let point = reading.point else { continue }
            let sampleGapTooLarge = current.last.map {
                reading.timestamp.timeIntervalSince($0.timestamp)
                    > maximumSampleGap
            } ?? false
            let count = Double(current.count)
            let movedTooFar = !current.isEmpty && ClassifierPoint(
                latitude: sumLatitude / count, longitude: sumLongitude / count
            ).distance(to: ClassifierPoint(latitude: point.latitude, longitude: point.longitude)) > radiusMeters
            if sampleGapTooLarge || movedTooFar {
                if !current.isEmpty { groups.append(current) }
                current = []
                sumLatitude = 0
                sumLongitude = 0
            }
            current.append(reading)
            sumLatitude += point.latitude
            sumLongitude += point.longitude
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
            let key = Self.aliasKey(near: point, in: knownNames, radius: radiusMeters / 2)
                ?? placeKey(for: point)
            let floor = stableSystemFloor(in: group)
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

    private func placeKey(for point: GeoPoint) -> String {
        String(format: "%.4f,%.4f", point.latitude, point.longitude)
    }

    /// 예전 장소 키(소수 넷째 자리 좌표)를 별칭으로 지킨다. 중심점 기준으로 바뀌어 좌표가
    /// 조금 움직여도, 반경 안에 이미 아는 키가 있으면 그 키(와 이름)를 그대로 쓴다.
    static func aliasKey(near point: GeoPoint, in knownNames: [String: String], radius: Double) -> String? {
        let target = ClassifierPoint(latitude: point.latitude, longitude: point.longitude)
        return knownNames.keys.compactMap { key -> (String, Double)? in
            let parts = key.split(separator: ",")
            guard parts.count == 2, let latitude = Double(parts[0]), let longitude = Double(parts[1]) else { return nil }
            let distance = ClassifierPoint(latitude: latitude, longitude: longitude).distance(to: target)
            return distance <= radius ? (key, distance) : nil
        }.min { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }?.0
    }
}

private func stableSystemFloor(in readings: [SensorReading]) -> Int? {
    let counts = Dictionary(grouping: readings.compactMap(\.systemFloor), by: { $0 })
    return counts.max { lhs, rhs in
        if lhs.value.count != rhs.value.count {
            return lhs.value.count < rhs.value.count
        }
        return lhs.key > rhs.key
    }?.key
}

extension PlaceStay {
    var isWalkingLocation: Bool {
        placeKey.hasPrefix("walking:")
    }

    /// `FrequentPlaceResolutionEngine` 이 자주가는 곳으로 확정한 체류.
    var isRegisteredFrequentPlace: Bool {
        placeKey.hasPrefix("frequent-")
    }
}

struct WalkingLocationEngine: Sendable {
    var radiusMeters: Double = 100
    var maximumGap: TimeInterval = 2 * 60
    var minimumDuration: TimeInterval = 30
    var maximumAccuracy: Double = 50

    func build(readings: [SensorReading]) -> [PlaceStay] {
        let sorted = readings
            .filter {
                RouteTimelineTimestamp.isValid($0.timestamp)
                    && $0.trackingKind == .walking
                    && $0.point != nil
                    && $0.gpsAvailable
                    && $0.locationFixQuality != .approximate
                    && ($0.point?.latitude.isFinite ?? false)
                    && ($0.point?.longitude.isFinite ?? false)
                    && ($0.point?.latitude ?? .nan) >= -90
                    && ($0.point?.latitude ?? .nan) <= 90
                    && ($0.point?.longitude ?? .nan) >= -180
                    && ($0.point?.longitude ?? .nan) <= 180
                    && ($0.point?.horizontalAccuracy ?? .infinity)
                        >= 0
                    && ($0.point?.horizontalAccuracy ?? .infinity)
                        <= maximumAccuracy
            }
            .sorted { $0.timestamp < $1.timestamp }
        guard !sorted.isEmpty else { return [] }

        var groups: [[SensorReading]] = []
        var current: [SensorReading] = []
        for reading in sorted {
            let shouldSplit: Bool
            if let first = current.first,
               let anchor = first.point,
               let point = reading.point {
                shouldSplit = distanceMeters(anchor, point) > radiusMeters
                    || reading.timestamp.timeIntervalSince(
                        current.last?.timestamp ?? first.timestamp
                    ) > maximumGap
                    || (first.trackingSessionID != nil
                        && first.trackingSessionID
                            != reading.trackingSessionID)
            } else {
                shouldSplit = false
            }
            if shouldSplit, !current.isEmpty {
                groups.append(current)
                current = []
            }
            current.append(reading)
        }
        if !current.isEmpty { groups.append(current) }

        return groups.compactMap { group in
            guard let first = group.first,
                  let last = group.last,
                  let point = representativePoint(group),
                  last.timestamp.timeIntervalSince(first.timestamp)
                    >= minimumDuration else {
                return nil
            }
            let accuracy = group.map { $0.point?.horizontalAccuracy ?? 100 }
                .reduce(0, +) / Double(group.count)
            return PlaceStay(
                placeKey: "walking:\(placeKey(for: point))",
                displayName: "확인된 위치",
                floor: stableSystemFloor(in: group),
                span: TimeSpan(start: first.timestamp, end: last.timestamp),
                confidence: ConfidenceLevel(
                    score: accuracy <= 30 ? 0.95 : 0.78
                ),
                point: point,
                isConfirmed: true
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
            horizontalAccuracy: points.map(\.horizontalAccuracy)
                .reduce(0, +) / count,
            verticalAccuracy: points.map(\.verticalAccuracy)
                .reduce(0, +) / count
        )
    }

    private func placeKey(for point: GeoPoint) -> String {
        String(format: "%.4f,%.4f", point.latitude, point.longitude)
    }
}
