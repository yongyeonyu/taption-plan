@preconcurrency import CoreMotion
import Foundation
import TaptionPlanEngine

/// 층수를 저장할 때 그 자리의 높이를 함께 재는 규칙(HGT1103A01).
enum PlaceHeightCapture {
    static let sampleCount = 20
    static let maximumDuration: TimeInterval = 40

    /// 최솟값과 최댓값을 하나씩 버린 평균. 표본이 3개 미만이면 믿을 수 없어 nil이다.
    static func trimmedMean(_ values: [Double]) -> Double? {
        let finite = values.filter(\.isFinite).sorted()
        guard finite.count >= 3 else { return nil }
        let kept = finite.dropFirst().dropLast()
        return kept.reduce(0, +) / Double(kept.count)
    }

    /// 지금 지점 안에 있을 때만 그 자리의 높이다. 지도에서 멀리서 고치는 경우는 재지 않는다.
    static func isInside(_ place: FrequentPlace, reading: SensorReading?) -> Bool {
        guard let reading, reading.gpsAvailable, let current = reading.point, let point = place.point else { return false }
        let y = (current.latitude - point.latitude) * 111_320
        let x = (current.longitude - point.longitude) * 111_320 * cos(point.latitude * .pi / 180)
        return (x * x + y * y).squareRoot() <= place.radiusMeters
    }

    /// 측정값을 넣은 기준 표본. 이 측정의 상대 고도 세션은 끝나므로 남기지 않는다.
    static func reference(from base: SensorReading, pressures: [Double], altitudes: [Double]) -> SensorReading? {
        let pressure = trimmedMean(pressures)
        let altitude = trimmedMean(altitudes)
        guard pressure != nil || altitude != nil else { return nil }
        var value = base
        value.pressureKilopascals = pressure
        value.relativeAltitudeMeters = nil
        value.altimeterSessionID = nil
        if let altitude { value.point?.altitude = altitude } else { value.point?.verticalAccuracy = -1 }
        return value
    }
}

/// 기압을 `count`번 읽는다. 기압계가 없거나 시간이 다 되면 그때까지 읽은 값을 준다.
@MainActor
final class PlaceHeightSampler {
    private let altimeter = CMAltimeter()

    func pressures(count: Int, timeout: TimeInterval, onSample: @escaping @MainActor () -> Void) async -> [Double] {
        guard CMAltimeter.isRelativeAltitudeAvailable() else {
            // 기압계가 없어도 GPS 고도는 같은 시간 동안 읽는다.
            for _ in 0..<count where !Task.isCancelled {
                onSample()
                try? await Task.sleep(for: .seconds(1))
            }
            return []
        }
        let altimeter = self.altimeter
        let stream = AsyncStream<Double> { continuation in
            altimeter.startRelativeAltitudeUpdates(to: .main) { data, _ in
                if let pressure = data?.pressure.doubleValue { continuation.yield(pressure) }
            }
            let timer = Task {
                try? await Task.sleep(for: .seconds(timeout))
                continuation.finish()
            }
            continuation.onTermination = { _ in
                timer.cancel()
                altimeter.stopRelativeAltitudeUpdates()
            }
        }
        var values: [Double] = []
        for await pressure in stream {
            values.append(pressure)
            onSample()
            if values.count >= count { break }
        }
        return values
    }
}

extension FloorCalibration {
    /// 층별 기준점. 옛 형식은 기준점 하나를 층별 기준점으로 편다.
    var resolvedReferencePoints: [FloorCalibrationPoint] {
        if !referencePoints.isEmpty { return referencePoints }
        guard let referencePoint else { return [] }
        return [
            FloorCalibrationPoint(
                floor: referenceFloor,
                point: referencePoint,
                relativeAltitudeMeters: referenceRelativeAltitudeMeters,
                pressureKilopascals: referencePressureKilopascals,
                altimeterSessionID: referenceAltimeterSessionID,
                capturedAt: capturedAt ?? .now
            )
        ]
    }
}

struct FloorCalibrationEngine: Sendable {
    var maximumReferenceDistanceMeters: Double = 120

    func capturing(
        _ calibration: FloorCalibration,
        from reading: SensorReading
    ) -> FloorCalibration {
        guard !calibration.isCaptured,
              let point = reading.point,
              point.altitude.isFinite else {
            return calibration
        }
        var value = calibration
        value.referencePoint = point
        value.referenceRelativeAltitudeMeters =
            reading.relativeAltitudeMeters
        value.referencePressureKilopascals =
            reading.pressureKilopascals
        value.referenceAltimeterSessionID =
            reading.altimeterSessionID
        value.capturedAt = reading.timestamp
        return value
    }

    func estimate(
        reading: SensorReading,
        calibration: FloorCalibration
    ) -> CalibratedAltitudeEstimate? {
        estimate(
            sample: AltitudeDelta.Sample(reading),
            at: reading.point,
            calibration: calibration
        )
    }

    /// 같은 체류의 표본 중앙값으로 층을 추정한다. 한 번의 기압/GPS 값이
    /// 흔들려도 등록된 층이 바로 바뀌지 않으며, 상대고도는 동일 세션만 쓴다.
    func estimate(
        readings: [SensorReading],
        calibration: FloorCalibration
    ) -> CalibratedAltitudeEstimate? {
        let usable = readings
            .filter { reading in
                RouteTimelineTimestamp.isValid(reading.timestamp)
                    && reading.point != nil
                    && (reading.relativeAltitudeMeters != nil
                        || reading.pressureKilopascals != nil
                        || reading.point?.altitude.isFinite == true)
            }
            .sorted { $0.timestamp < $1.timestamp }
        guard !usable.isEmpty else { return nil }

        var representative = usable.min {
            qualityScore($0) < qualityScore($1)
        } ?? usable[0]
        let points = usable.compactMap(\.point)
        if !points.isEmpty, var point = representative.point {
            point.latitude = median(points.map(\.latitude))
            point.longitude = median(points.map(\.longitude))
            let altitudes = points.map(\.altitude).filter(\.isFinite)
            if !altitudes.isEmpty {
                point.altitude = median(altitudes)
            }
            representative.point = point
        }

        let pressureReadings: [SensorReading] = if let session = representative.altimeterSessionID {
            usable.filter { $0.altimeterSessionID == session }
        } else {
            usable
        }
        let pressures = pressureReadings.compactMap(\.pressureKilopascals)
            .filter { $0.isFinite && $0 > 0 }
        if !pressures.isEmpty {
            representative.pressureKilopascals = median(pressures)
        }

        if let session = representative.altimeterSessionID {
            let relative = usable
                .filter { $0.altimeterSessionID == session }
                .compactMap(\.relativeAltitudeMeters)
                .filter(\.isFinite)
            if relative.count >= 3 {
                representative.relativeAltitudeMeters = median(relative)
            } else {
                representative.relativeAltitudeMeters = nil
                representative.altimeterSessionID = nil
            }
        } else {
            representative.relativeAltitudeMeters = nil
        }
        return estimate(reading: representative, calibration: calibration)
    }

    /// 기록이 스스로 지닌 근거로 다시 매기는 입구. 원본 표본이 지워진 뒤에도
    /// 살아 있는 표본과 똑같은 규칙을 태운다.
    func estimate(
        evidence: FloorEvidence,
        at point: GeoPoint?,
        calibration: FloorCalibration
    ) -> CalibratedAltitudeEstimate? {
        guard var result = estimate(
            sample: AltitudeDelta.Sample(
                evidence,
                altitudeMeters: point?.altitude
            ),
            at: point,
            calibration: calibration
        ) else {
            return nil
        }
        result.floor = min(max(result.floor + evidence.floorOffset, -20), 200)
        return result
    }

    private func estimate(
        sample: AltitudeDelta.Sample,
        at point: GeoPoint?,
        calibration: FloorCalibration
    ) -> CalibratedAltitudeEstimate? {
        let candidates = calibration.resolvedReferencePoints.compactMap { reference -> CalibratedAltitudeEstimate? in
            guard isNearReference(
                point,
                referencePoint: reference.point
            ) else { return nil }

            guard let measured = AltitudeDelta.between(
                AltitudeDelta.Sample(reference),
                and: sample
            ) else { return nil }
            let delta = measured.meters
            let confidence: ConfidenceLevel
            let source: String
            switch measured.source {
            case .relativeAltitude:
                confidence = .high
                source = "기압 상대고도"
            case .pressure:
                confidence = .medium
                source = "기압차 보정"
            case .gps:
                confidence = .low
                source = "GPS 고도"
            }

            let floorHeight = max(2.2, calibration.floorHeightMeters)
            let rawFloor = reference.floor + Int((delta / floorHeight).rounded())
            let floor = min(
                max(rawFloor == 0 ? (delta < 0 ? -1 : 1) : rawFloor, -20),
                200
            )
            let verticalAccuracy = max(
                3,
                point.flatMap {
                    $0.verticalAccuracy >= 0 ? $0.verticalAccuracy : nil
                } ?? (reference.point.verticalAccuracy >= 0
                    ? reference.point.verticalAccuracy
                    : 20)
            )
            return CalibratedAltitudeEstimate(
                floor: floor,
                seaLevelAltitudeMeters: reference.point.altitude + delta,
                verticalAccuracyMeters: verticalAccuracy,
                confidence: confidence,
                evidence: [
                    "\(calibration.placeName) \(reference.floor)층 사용자 기준",
                    source,
                ]
            )
        }
        guard !candidates.isEmpty else { return nil }
        let grouped = Dictionary(grouping: candidates, by: \.floor)
        let winner = grouped.max { lhs, rhs in
            if lhs.value.count != rhs.value.count {
                return lhs.value.count < rhs.value.count
            }
            return lhs.key < rhs.key
        }?.value ?? [candidates[0]]
        var result = winner.max { confidenceRank($0.confidence) < confidenceRank($1.confidence) }
            ?? candidates[0]
        if calibration.resolvedReferencePoints.count > 1 {
            result.evidence.append("\(calibration.resolvedReferencePoints.count)개 층 기준 교차 검증")
        }
        return result
    }

    private func confidenceRank(_ confidence: ConfidenceLevel) -> Int {
        switch confidence {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }

    private func qualityScore(_ reading: SensorReading) -> Double {
        let vertical = reading.point?.verticalAccuracy ?? 1_000
        let horizontal = reading.point?.horizontalAccuracy ?? 1_000
        return max(0, vertical) * 10_000 + max(0, horizontal)
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    func applying(
        _ calibration: FloorCalibration?,
        to places: [PlaceStay],
        readings: [SensorReading]
    ) -> [PlaceStay] {
        guard let calibration, calibration.isCaptured else {
            return places
        }
        let readingIndex = SensorEvidenceTimeIndex(readings: readings)
        return places.map { place in
            guard let reading = readingIndex.readings(in: place.span).min(
                by: { $0.timestamp < $1.timestamp }
            ),
                  let estimate = estimate(
                    reading: reading,
                    calibration: calibration
                  ) else {
                return place
            }
            var calibrated = place
            calibrated.displayName = calibration.placeName
            calibrated.floor = estimate.floor
            calibrated.confidence = estimate.confidence
            calibrated.isConfirmed = true
            return calibrated
        }
    }

    private func isNearReference(
        _ point: GeoPoint?,
        referencePoint: GeoPoint
    ) -> Bool {
        guard let point else { return true }
        let accuracyRadius = max(
            maximumReferenceDistanceMeters,
            max(0, point.horizontalAccuracy)
                + max(0, referencePoint.horizontalAccuracy)
        )
        return distanceMeters(point, referencePoint)
            <= accuracyRadius
    }
}
