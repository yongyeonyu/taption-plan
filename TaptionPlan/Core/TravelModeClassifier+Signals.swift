import Foundation
import TaptionPlanEngine

extension TravelModeClassifier {
    func motionTiePriority(_ motion: MotionKind) -> Int {
        switch motion {
        case .stationary, .unknown: 0
        case .walking: 1
        case .running: 2
        case .cycling: 3
        case .automotive: 4
        }
    }

    func ratio(
        _ readings: [SensorReading],
        where keyPath: KeyPath<SensorReading, Bool>
    ) -> Double {
        guard !readings.isEmpty else { return 0 }
        return Double(readings.filter { $0[keyPath: keyPath] }.count)
            / Double(readings.count)
    }

    struct AltitudeRecoveryProfile {
        var dropMeters: Double
        var recoveryMeters: Double
    }

    func altitudeDropAndRecovery(
        _ readings: [SensorReading]
    ) -> AltitudeRecoveryProfile? {
        let values = readings.compactMap { reading in
            reading.relativeAltitudeMeters.map { (reading.timestamp, $0) }
        }
        guard values.count >= 4,
              let minimum = values.enumerated().min(by: { $0.element.1 < $1.element.1 }),
              minimum.offset > 0,
              minimum.offset < values.count - 1,
              let first = values.first?.1,
              let last = values.last?.1 else { return nil }
        let drop = first - minimum.element.1
        let recovery = last - minimum.element.1
        guard drop.isFinite, recovery.isFinite else { return nil }
        return AltitudeRecoveryProfile(
            dropMeters: max(0, drop),
            recoveryMeters: max(0, recovery)
        )
    }

    /// 20분 창 안에서 가장 크게 바뀐 고도(m). 기압(kPa)은 센서 창이 끊겨도 절대값이라
    /// 창을 넘어 비교하고, 상대고도는 같은 기압계 세션 안에서만 비교한다(켤 때마다 0부터 다시 센다).
    static func altitudeChangeMeters(_ readings: [SensorReading]) -> Double {
        let ordered = readings.sorted { $0.timestamp < $1.timestamp }
        let pressure = ordered.compactMap { reading -> (Date, Double)? in
            guard let kPa = reading.pressureKilopascals, kPa.isFinite, kPa > 0 else { return nil }
            return (reading.timestamp, 44_330 * (1 - pow(kPa / 101.325, 0.1903)))
        }
        let relative = Dictionary(grouping: ordered.filter { $0.relativeAltitudeMeters?.isFinite == true },
                                  by: { $0.altimeterSessionID })
            .values.map { $0.map { ($0.timestamp, $0.relativeAltitudeMeters ?? 0) } }
        return ([pressure] + relative).map(windowedRange).max() ?? 0
    }

    static func windowedRange(_ values: [(Date, Double)]) -> Double {
        var best = 0.0
        var start = 0
        for end in values.indices {
            while values[end].0.timeIntervalSince(values[start].0) > subwayAltitudeWindow { start += 1 }
            let window = values[start...end].map(\.1)
            best = max(best, (window.max() ?? 0) - (window.min() ?? 0))
        }
        return best
    }

    func maxAltitudeDrop(_ readings: [SensorReading]) -> Double {
        let values = readings.compactMap(\.relativeAltitudeMeters)
        guard let first = values.first else { return 0 }
        var highest = first
        var maximumDrop = 0.0
        for value in values.dropFirst() {
            highest = max(highest, value)
            maximumDrop = max(maximumDrop, highest - value)
        }
        return maximumDrop
    }

    func firstLastDisplacement(_ readings: [SensorReading]) -> Double {
        let points = readings.compactMap { reading -> GeoPoint? in
            guard reading.gpsAvailable,
                  reading.locationFixQuality != .approximate,
                  let point = reading.point,
                  point.latitude.isFinite,
                  point.longitude.isFinite,
                  (-90...90).contains(point.latitude),
                  (-180...180).contains(point.longitude),
                  point.horizontalAccuracy.isFinite,
                  point.horizontalAccuracy >= 0,
                  point.horizontalAccuracy <= 150 else {
                return nil
            }
            return point
        }
        guard let first = points.first, let last = points.last else { return 0 }
        return distanceMeters(first, last)
    }

    func stationAltitudeDropSignal(_ readings: [SensorReading]) -> Bool {
        let ordered = readings
            .filter { RouteTimelineTimestamp.isValid($0.timestamp) }
            .sorted { $0.timestamp < $1.timestamp }
        for pair in zip(ordered, ordered.dropFirst()) {
            let first = pair.0
            let second = pair.1
            guard second.timestamp.timeIntervalSince(first.timestamp) <= 10 * 60,
                  first.nearbyStation || second.nearbyStation,
                  let start = first.relativeAltitudeMeters,
                  let end = second.relativeAltitudeMeters,
                  start.isFinite,
                  end.isFinite,
                  start - end >= 1.5 else { continue }
            return true
        }
        return false
    }

    func subwayWiFiEvidence(
        family: String,
        streak: Int,
        observedAt: Date?
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul") ?? .current
        let time = observedAt.map {
            let values = calendar.dateComponents([.hour, .minute], from: $0)
            return String(format: "%02d:%02d", values.hour ?? 0, values.minute ?? 0)
        } ?? "시각 미확인"
        return "지하철 Wi-Fi \(family) 계열 연속 \(streak)회 \(time)"
    }

    func subwayWiFiFamily(for ssid: String?) -> String? {
        guard let ssid, SubwayWiFiSSID.isAllowed(ssid) else { return nil }
        let normalized = SubwayWiFiSSID.normalized(ssid)
        if normalized.hasPrefix("t ") || normalized == "t" {
            return "T"
        }
        if normalized.hasPrefix("kt ") || normalized == "kt" {
            return "KT"
        }
        if normalized.contains("u+") || normalized.contains("utzone") {
            return "U+"
        }
        return nil
    }

    func speedSeries(for readings: [SensorReading]) -> [Double] {
        let validReadings = readings.filter {
            RouteTimelineTimestamp.isValid($0.timestamp)
        }
        var values = validReadings.compactMap { reading -> Double? in
            guard reading.gpsAvailable,
                  reading.locationFixQuality != .approximate else {
                return nil
            }
            if let point = reading.point {
                guard point.latitude.isFinite,
                      point.longitude.isFinite,
                      (-90...90).contains(point.latitude),
                      (-180...180).contains(point.longitude),
                      point.horizontalAccuracy.isFinite,
                      point.horizontalAccuracy >= 0,
                      point.horizontalAccuracy <= 150 else {
                    return nil
                }
            }
            guard let speed = reading.speedMetersPerSecond,
                  speed >= 0,
                  speed.isFinite else {
                return nil
            }
            if let accuracy = reading.speedAccuracyMetersPerSecond,
               accuracy > max(3, speed * 0.75) {
                return nil
            }
            if let horizontalAccuracy = reading.point?.horizontalAccuracy,
               horizontalAccuracy > 150 {
                return nil
            }
            return speed
        }

        let pointReadings = validReadings
            .filter { reading in
                guard reading.gpsAvailable,
                      reading.locationFixQuality != .approximate,
                      let point = reading.point else {
                    return false
                }
                return point.latitude.isFinite
                    && point.longitude.isFinite
                    && (-90...90).contains(point.latitude)
                    && (-180...180).contains(point.longitude)
                    && point.horizontalAccuracy.isFinite
                    && point.horizontalAccuracy >= 0
                    && point.horizontalAccuracy <= 150
            }
            .sorted { $0.timestamp < $1.timestamp }
        for pair in zip(pointReadings, pointReadings.dropFirst()) {
            guard let from = pair.0.point,
                  let to = pair.1.point else {
                continue
            }
            guard from.horizontalAccuracy <= 150,
                  to.horizontalAccuracy <= 150 else {
                continue
            }
            let elapsed = pair.1.timestamp.timeIntervalSince(pair.0.timestamp)
            guard elapsed >= 5 else { continue }
            let distance = distanceMeters(from, to)
            guard distance >= 8 else { continue }
            values.append(distance / elapsed)
        }
        guard values.count >= 5,
              let median = percentile(values, fraction: 0.5) else {
            return values
        }
        let deviations = values.map { abs($0 - median) }
        let medianDeviation = percentile(deviations, fraction: 0.5) ?? 0
        let upperBound = median + max(4, medianDeviation * 4)
        return values.filter { $0 <= upperBound }
    }

    func trimmedMean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let ordered = values.sorted()
        let trim = ordered.count >= 10 ? ordered.count / 10 : 0
        let range = trim..<(ordered.count - trim)
        let kept = ordered[range]
        return kept.reduce(0, +) / Double(kept.count)
    }

    func percentile(
        _ values: [Double],
        fraction: Double
    ) -> Double? {
        guard !values.isEmpty else { return nil }
        let ordered = values.sorted()
        let index = Int(
            (Double(ordered.count - 1) * min(1, max(0, fraction))).rounded()
        )
        return ordered[index]
    }

    func confidenceWeight(_ confidence: ConfidenceLevel) -> Double {
        switch confidence {
        case .high: 1
        case .medium: 0.72
        case .low: 0.4
        }
    }

    struct DeviceMotionSignal {
        var sampleCount: Int
        var meanAccelerationG: Double
        var accelerationDeviationG: Double
        var meanRotationRate: Double
    }

    func deviceMotionSignal(
        _ readings: [SensorReading]
    ) -> DeviceMotionSignal {
        let summaries = readings.compactMap(\.deviceMotionSummary)
        if !summaries.isEmpty {
            let count = summaries.reduce(0) { $0 + $1.sampleCount }
            let divisor = Double(max(1, count))
            return DeviceMotionSignal(
                sampleCount: count,
                meanAccelerationG: summaries.reduce(0) {
                    $0 + $1.meanUserAccelerationG * Double($1.sampleCount)
                } / divisor,
                accelerationDeviationG: summaries.reduce(0) {
                    $0 + $1.userAccelerationStandardDeviationG
                        * Double($1.sampleCount)
                } / divisor,
                meanRotationRate: summaries.reduce(0) {
                    $0 + $1.meanRotationRateRadiansPerSecond
                        * Double($1.sampleCount)
                } / divisor
            )
        }

        let snapshots = readings.compactMap(\.deviceMotion)
        let accelerations = snapshots.map {
            magnitude($0.userAcceleration)
        }
        let rotations = snapshots.map { magnitude($0.rotationRate) }
        return DeviceMotionSignal(
            sampleCount: snapshots.count,
            meanAccelerationG: mean(accelerations),
            accelerationDeviationG: standardDeviation(accelerations),
            meanRotationRate: mean(rotations)
        )
    }

    func magnitude(_ vector: SensorVector3) -> Double {
        sqrt(vector.x * vector.x + vector.y * vector.y + vector.z * vector.z)
    }

    func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    func standardDeviation(_ values: [Double]) -> Double {
        guard values.count >= 2 else { return 0 }
        let average = mean(values)
        let variance = values.reduce(0) {
            $0 + pow($1 - average, 2)
        } / Double(values.count - 1)
        return sqrt(max(0, variance))
    }

    func sensorSpan(for readings: [SensorReading]) -> TimeSpan {
        guard let first = readings.first,
              let last = readings.last else {
            return TimeSpan(start: .distantPast, end: .distantPast)
        }
        return TimeSpan(
            start: first.timestamp,
            end: max(
                last.timestamp,
                first.timestamp.addingTimeInterval(60)
            )
        )
    }

    func authoritativeWatchWorkout(
        in span: TimeSpan,
        evidence: [AppleMovementEvidence]
    ) -> AppleMovementEvidence? {
        guard span.duration > 0 else { return nil }
        return evidence
            .filter {
                $0.source == .appleWatch
                    && $0.kind == .workout
                    && $0.workoutMode != nil
            }
            .compactMap { record -> (AppleMovementEvidence, TimeInterval)? in
                guard let overlap = record.span.intersection(with: span) else {
                    return nil
                }
                return (record, overlap.duration)
            }
            .filter {
                $0.1 >= 60 && $0.1 / span.duration >= 0.5
            }
            .max {
                if $0.1 != $1.1 {
                    return $0.1 < $1.1
                }
                let leftOrder = TravelMode.allCases.firstIndex(
                    of: $0.0.workoutMode ?? .walking
                ) ?? Int.max
                let rightOrder = TravelMode.allCases.firstIndex(
                    of: $1.0.workoutMode ?? .walking
                ) ?? Int.max
                return leftOrder > rightOrder
            }?
            .0
    }

    struct StepSignal {
        var livePhoneCount: Int
        var healthPhoneCount: Int
        var watchCount: Int
        var otherCount: Int
        var hasCoverage: Bool
        var cadenceStepsPerSecond: Double
        var paceSecondsPerMeter: Double
        var distanceMeters: Double

        var bestCount: Int {
            max(livePhoneCount, healthPhoneCount, watchCount, otherCount)
        }

        var primaryEvidence: String {
            if watchCount == bestCount, watchCount > 0 {
                return "Apple Watch 걸음 \(watchCount)보"
            }
            if livePhoneCount == bestCount, livePhoneCount > 0 {
                return "iPhone 실시간 걸음 \(livePhoneCount)보"
            }
            if healthPhoneCount == bestCount, healthPhoneCount > 0 {
                return "iPhone HealthKit 걸음 \(healthPhoneCount)보"
            }
            return "HealthKit 걸음 \(otherCount)보"
        }

        var gaitEvidence: String {
            if cadenceStepsPerSecond > 0 {
                let stepsPerMinute = Int(
                    (cadenceStepsPerSecond * 60).rounded()
                )
                return "\(primaryEvidence) · cadence \(stepsPerMinute)보/분"
            }
            if paceSecondsPerMeter > 0 {
                return String(
                    format: "%@ · pace %.2f초/m",
                    primaryEvidence,
                    paceSecondsPerMeter
                )
            }
            return primaryEvidence
        }
    }

    func stepSignal(
        readings: [SensorReading],
        evidence: [AppleMovementEvidence],
        inside span: TimeSpan
    ) -> StepSignal {
        let stepReadings = readings.compactMap { reading in
            reading.stepCount.map { (reading.timestamp, $0) }
        }
        // 아이폰과 워치의 누적 계수기는 따로 잰다. 한 줄로 이으면 값이 오갈 때마다 가짜 증가가 생긴다.
        let liveSteps = DeviceStepCounter.increases(in: readings)
        let livePhoneCount = liveSteps[.iPhone] ?? 0
        var groupedCounts: [String: (AppleMovementEvidenceSource, Int)] = [:]
        for record in evidence where record.kind == .steps {
            guard let count = record.stepCount,
                  count >= 0,
                  let overlap = record.span.intersection(with: span) else {
                continue
            }
            let fraction = min(
                1,
                overlap.duration / max(1, record.span.duration)
            )
            let allocated = Int((Double(count) * fraction).rounded())
            let key = "\(record.source.rawValue)|\(record.sourceName)|\(record.deviceName ?? "")"
            let existing = groupedCounts[key] ?? (record.source, 0)
            groupedCounts[key] = (record.source, existing.1 + allocated)
        }

        func maximum(for source: AppleMovementEvidenceSource) -> Int {
            groupedCounts.values
                .filter { $0.0 == source }
                .map(\.1)
                .max() ?? 0
        }

        let cadence = readings
            .compactMap(\.currentCadenceStepsPerSecond)
            .filter { $0.isFinite && $0 >= 0 }
            .max() ?? 0
        let pace = readings
            .compactMap(\.currentPaceSecondsPerMeter)
            .filter { $0.isFinite && $0 > 0 }
            .min() ?? 0
        let liveDistance = DeviceStepCounter.distanceIncrease(in: readings)
        let healthDistance = evidence
            .filter {
                $0.kind == .steps
                    && $0.span.intersection(with: span) != nil
            }
            .compactMap(\.distanceMeters)
            .max() ?? 0

        return StepSignal(
            livePhoneCount: livePhoneCount,
            healthPhoneCount: maximum(for: .iPhone),
            watchCount: max(maximum(for: .appleWatch), liveSteps[.appleWatch] ?? 0),
            otherCount: maximum(for: .other),
            hasCoverage: stepReadings.count >= 2
                || !groupedCounts.isEmpty
                || cadence > 0
                || pace > 0,
            cadenceStepsPerSecond: cadence,
            paceSecondsPerMeter: pace,
            distanceMeters: max(liveDistance, healthDistance)
        )
    }

    struct WatchAccelerationSignal {
        var sampleCount: Int
        var standardDeviationG: Double
        var meanJerkGPerSecond: Double
    }

    func watchAccelerationSignal(
        _ readings: [SensorReading]
    ) -> WatchAccelerationSignal {
        let deviations = readings.compactMap(\.watchAccelerationStandardDeviationG)
            .filter { $0.isFinite && $0 >= 0 }
        let jerks = readings.compactMap(\.watchAccelerationMeanJerkGPerSecond)
            .filter { $0.isFinite && $0 >= 0 }
        let sampleCount = max(deviations.count, jerks.count)
        return WatchAccelerationSignal(
            sampleCount: sampleCount,
            standardDeviationG: mean(deviations),
            meanJerkGPerSecond: mean(jerks)
        )
    }

    func modeName(_ mode: TravelMode?) -> String {
        mode.map { MovementPresentation.title(for: $0) } ?? "이동"
    }
}
