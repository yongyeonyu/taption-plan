import Foundation

struct TravelModeClassifier: Sendable {
    func classify(
        readings: [SensorReading],
        inside requestedSpan: TimeSpan? = nil,
        healthEvidence: [AppleMovementEvidence] = [],
        correctedMode: TravelMode? = nil
    ) -> MovementInference {
        if let correctedMode {
            return MovementInference(
                mode: correctedMode,
                confidence: .high,
                score: 1,
                evidence: ["사용자 교정"]
            )
        }
        guard !readings.isEmpty || !healthEvidence.isEmpty else {
            return MovementInference(
                mode: .walking,
                confidence: .low,
                score: 0,
                evidence: ["센서 데이터 부족"]
            )
        }

        let ordered = readings.sorted { $0.timestamp < $1.timestamp }
        let inferenceSpan = requestedSpan ?? sensorSpan(for: ordered)
        if let watchWorkout = authoritativeWatchWorkout(
            in: inferenceSpan,
            evidence: healthEvidence
        ) {
            return MovementInference(
                mode: watchWorkout.workoutMode ?? .walking,
                confidence: .high,
                score: 0.98,
                evidence: [
                    "Apple Watch \(modeName(watchWorkout.workoutMode)) 운동",
                    "HealthKit 기기 출처 확인",
                ]
            )
        }

        let speeds = speedSeries(for: ordered)
        let averageSpeed = trimmedMean(speeds)
        let maxSpeed = percentile(speeds, fraction: 0.9) ?? 0
        let gpsLossRatio = ordered.isEmpty
            ? 0
            : Double(ordered.filter { !$0.gpsAvailable }.count)
                / Double(ordered.count)
        let relativeAltitudes = ordered.compactMap(\.relativeAltitudeMeters)
        let altitudeDelta = (relativeAltitudes.last ?? 0) - (relativeAltitudes.first ?? 0)
        let motionScores = ordered.reduce(into: [MotionKind: Double]()) {
            scores,
            reading in
            scores[reading.motion, default: 0] += confidenceWeight(
                reading.motionConfidence
            )
        }
        let dominantMotionEntry = motionScores.max {
            $0.value < $1.value
        }
        let dominantMotion = dominantMotionEntry?.key ?? .unknown
        let dominantMotionWeight = min(
            1,
            (dominantMotionEntry?.value ?? 0)
                / Double(max(1, ordered.count))
        )

        var candidates: [TravelMode: (Double, [String])] = [:]
        func add(_ mode: TravelMode, _ score: Double, _ evidence: String) {
            var current = candidates[mode] ?? (0, [])
            current.0 += score
            current.1.append(evidence)
            candidates[mode] = current
        }

        switch dominantMotion {
        case .walking:
            add(
                .walking,
                0.75 * dominantMotionWeight,
                "Core Motion 보행"
            )
        case .running:
            add(
                .running,
                0.82 * dominantMotionWeight,
                "Core Motion 달리기"
            )
        case .cycling:
            add(
                .cycling,
                0.82 * dominantMotionWeight,
                "Core Motion 자전거"
            )
        case .automotive:
            add(
                .car,
                0.48 * dominantMotionWeight,
                "Core Motion 자동차 후보"
            )
            add(.bus, 0.2 * dominantMotionWeight, "동력 이동")
            add(.taxi, 0.2 * dominantMotionWeight, "동력 이동")
        case .stationary, .unknown:
            break
        }

        for workout in ordered.compactMap(\.watchWorkoutKind).map({
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

        for workout in healthEvidence where workout.kind == .workout {
            guard workout.span.intersection(with: inferenceSpan) != nil,
                  let mode = workout.workoutMode else {
                continue
            }
            let sourceName = workout.source == .appleWatch
                ? "Apple Watch"
                : "HealthKit"
            add(
                mode,
                workout.source == .appleWatch ? 0.62 : 0.42,
                "\(sourceName) \(modeName(mode)) 운동"
            )
        }

        let stepSignal = stepSignal(
            readings: ordered,
            evidence: healthEvidence,
            inside: inferenceSpan
        )
        let durationMinutes = max(1, inferenceSpan.duration / 60)
        let stepsPerMinute = Double(stepSignal.bestCount) / durationMinutes
        let gaitSpeed = stepSignal.distanceMeters
            / max(1, inferenceSpan.duration)
        let walkingStepThreshold = max(12, Int(durationMinutes * 10))
        let hasPedestrianCadence = stepSignal.cadenceStepsPerSecond >= 0.75
        if (stepSignal.bestCount >= walkingStepThreshold
            && stepsPerMinute >= 10)
            || hasPedestrianCadence {
            let hasVehicleSpeed = averageSpeed > 5.5 || maxSpeed > 8
            let stepScore = hasVehicleSpeed ? 0.18 : 0.58
            add(.walking, stepScore, stepSignal.gaitEvidence)
            if stepSignal.cadenceStepsPerSecond >= 2.15
                || stepSignal.paceSecondsPerMeter > 0
                    && stepSignal.paceSecondsPerMeter <= 0.52
                || averageSpeed >= 2.2
                    && averageSpeed < 6
                    && stepsPerMinute >= 100 {
                add(.running, 0.42, "빠른 보행 cadence·pace")
            }
            if dominantMotion == .automotive, averageSpeed <= 5.5 {
                add(.walking, 0.12, "차량 진동보다 지속적인 걸음 우선")
            }
            if dominantMotion == .automotive, hasVehicleSpeed {
                add(.car, 0.56, "차량 속도대와 자동차 모션 우선")
                add(.taxi, 0.18, "차량 속도대와 자동차 모션 우선")
            }
        } else if stepSignal.hasCoverage,
                  inferenceSpan.duration >= 2 * 60,
                  stepsPerMinute <= 2.5,
                  stepSignal.cadenceStepsPerSecond <= 0.2,
                  dominantMotion == .automotive || averageSpeed > 4 {
            add(.car, 0.42, "iPhone·Apple Watch 걸음 증가 거의 없음")
            add(.bus, 0.2, "보행이 아닌 동력 이동")
            add(.taxi, 0.2, "보행이 아닌 동력 이동")
            add(.train, 0.1, "보행이 아닌 동력 이동")
        } else if !stepSignal.hasCoverage,
                  inferenceSpan.duration >= 2 * 60,
                  dominantMotion == .automotive || averageSpeed > 5.5 || maxSpeed > 8 {
            add(.car, 0.24, "걸음 데이터 미수집 · 차량/속도 신호 우선")
            add(.bus, 0.12, "걸음 데이터 미수집 · 동력 이동 후보")
            add(.taxi, 0.12, "걸음 데이터 미수집 · 동력 이동 후보")
        }

        if gaitSpeed >= 0.5, gaitSpeed < 2.2 {
            add(.walking, 0.14, "걸음 거리·시간 보행 속도 일치")
        } else if gaitSpeed >= 2.2, gaitSpeed < 6 {
            add(.running, 0.16, "걸음 거리·시간 달리기 속도 일치")
        }

        let motionSignal = deviceMotionSignal(ordered)
        if motionSignal.sampleCount >= 3 {
            if hasPedestrianCadence,
               motionSignal.meanAccelerationG >= 0.025,
               averageSpeed < 5.5 {
                add(.walking, 0.12, "걸음 cadence와 3축 가속도 일치")
            }
            if dominantMotion == .running,
               motionSignal.accelerationDeviationG >= 0.08 {
                add(.running, 0.12, "달리기 가속도 변동")
            }
            if dominantMotion == .automotive,
               stepsPerMinute <= 5,
               motionSignal.accelerationDeviationG >= 0.015 {
                add(.car, 0.12, "저걸음 차량 진동 패턴")
            }
            if dominantMotion == .cycling,
               stepSignal.cadenceStepsPerSecond <= 0.35,
               motionSignal.meanRotationRate >= 0.02,
               averageSpeed >= 2,
               averageSpeed <= 15 {
                add(.cycling, 0.14, "저걸음·자전거 속도·회전 센서 일치")
            }
        }

        if !speeds.isEmpty {
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
            } else if averageSpeed > 5.5 || maxSpeed > 8 {
                add(.car, 0.24, "차량 가능 속도")
                add(.taxi, 0.12, "차량 가능 속도")
            }
        }

        let stationRatio = ratio(ordered, where: \.nearbyStation)
        let railRatio = ratio(ordered, where: \.matchesRailRoute)
        let transitRatio = ratio(ordered, where: \.matchesPublicTransitRoute)
        let stopRatio = ratio(ordered, where: \.frequentStops)
        let taxiHintRatio = ratio(ordered, where: \.rideHailingHint)
        let airportRatio = ratio(ordered, where: \.nearAirport)
        let portRatio = ratio(ordered, where: \.nearPort)
        let waterRatio = ratio(ordered, where: \.onWater)

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

        let ranked = candidates.sorted { $0.value.0 > $1.value.0 }
        let winner = ranked.first
            ?? (.walking, (0.2, ["기본 저신뢰 보행 후보"]))
        let runnerUpScore = ranked.dropFirst().first?.value.0 ?? 0
        let margin = max(0, winner.value.0 - runnerUpScore)
        let score = min(
            1,
            min(1, winner.value.0) * (0.82 + min(0.18, margin))
        )
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
        guard !readings.isEmpty else { return 0 }
        return Double(readings.filter { $0[keyPath: keyPath] }.count)
            / Double(readings.count)
    }

    private func speedSeries(for readings: [SensorReading]) -> [Double] {
        var values = readings.compactMap { reading -> Double? in
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

        let pointReadings = readings
            .filter { $0.point != nil }
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

    private func trimmedMean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let ordered = values.sorted()
        let trim = ordered.count >= 10 ? ordered.count / 10 : 0
        let range = trim..<(ordered.count - trim)
        let kept = ordered[range]
        return kept.reduce(0, +) / Double(kept.count)
    }

    private func percentile(
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

    private func confidenceWeight(_ confidence: ConfidenceLevel) -> Double {
        switch confidence {
        case .high: 1
        case .medium: 0.72
        case .low: 0.4
        }
    }

    private struct DeviceMotionSignal {
        var sampleCount: Int
        var meanAccelerationG: Double
        var accelerationDeviationG: Double
        var meanRotationRate: Double
    }

    private func deviceMotionSignal(
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

    private func magnitude(_ vector: SensorVector3) -> Double {
        sqrt(vector.x * vector.x + vector.y * vector.y + vector.z * vector.z)
    }

    private func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private func standardDeviation(_ values: [Double]) -> Double {
        guard values.count >= 2 else { return 0 }
        let average = mean(values)
        let variance = values.reduce(0) {
            $0 + pow($1 - average, 2)
        } / Double(values.count - 1)
        return sqrt(max(0, variance))
    }

    private func sensorSpan(for readings: [SensorReading]) -> TimeSpan {
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

    private func authoritativeWatchWorkout(
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
            .max { $0.1 < $1.1 }?
            .0
    }

    private struct StepSignal {
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

    private func stepSignal(
        readings: [SensorReading],
        evidence: [AppleMovementEvidence],
        inside span: TimeSpan
    ) -> StepSignal {
        let stepReadings = readings.compactMap { reading in
            reading.stepCount.map { (reading.timestamp, $0) }
        }
        let livePhoneCount = cumulativeIncrease(
            stepReadings.sorted { $0.0 < $1.0 }.map(\.1)
        )
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
        let liveDistance = cumulativeIncrease(
            readings.compactMap(\.walkingRunningDistanceMeters)
        )
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
            watchCount: maximum(for: .appleWatch),
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

    private func cumulativeIncrease(_ values: [Int]) -> Int {
        guard values.count >= 2 else { return 0 }
        return zip(values, values.dropFirst()).reduce(0) { total, pair in
            total + (pair.1 >= pair.0 ? pair.1 - pair.0 : pair.1)
        }
    }

    private func cumulativeIncrease(_ values: [Double]) -> Double {
        guard values.count >= 2 else { return 0 }
        return zip(values, values.dropFirst()).reduce(0) { total, pair in
            total + (pair.1 >= pair.0 ? pair.1 - pair.0 : pair.1)
        }
    }

    private func modeName(_ mode: TravelMode?) -> String {
        switch mode {
        case .walking: "걷기"
        case .running: "달리기"
        case .cycling: "자전거"
        case .bus: "버스"
        case .subway: "지하철"
        case .taxi: "택시"
        case .car: "자가용"
        case .train: "기차"
        case .airplane: "비행기"
        case .ship: "배"
        case nil: "이동"
        }
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
        let ordered = readings.sorted { $0.timestamp < $1.timestamp }
        guard let first = ordered.first, let last = ordered.last,
              first.timestamp < last.timestamp else {
            return nil
        }

        let systemReadings = ordered.filter { $0.systemFloor != nil }
        if let firstSystemReading = systemReadings.first,
           let lastSystemReading = systemReadings.last,
           let from = firstSystemReading.systemFloor,
           let to = lastSystemReading.systemFloor,
           from != to {
            let crossingIndex = systemReadings.firstIndex {
                $0.systemFloor == to
            } ?? systemReadings.index(before: systemReadings.endIndex)
            let transitionStart = crossingIndex > systemReadings.startIndex
                ? systemReadings[
                    systemReadings.index(before: crossingIndex)
                ].timestamp
                : firstSystemReading.timestamp
            return FloorTransition(
                id: UUID(),
                placeKey: placeKey,
                fromFloor: from,
                toFloor: to,
                relativeAltitudeMeters: Double(to - from) * defaultFloorHeightMeters,
                span: TimeSpan(
                    start: transitionStart,
                    end: systemReadings[crossingIndex].timestamp
                ),
                confidence: .high,
                evidence: ["시스템 실내 층 정보"]
            )
        }

        let floorHeight = max(
            2.2,
            floorHeightMeters ?? defaultFloorHeightMeters
        )
        let candidates = altitudeGroups(in: ordered).compactMap { group in
            altitudeCandidate(
                from: group,
                floorHeight: floorHeight
            )
        }
        guard let candidate = candidates.max(by: {
            if abs($0.floorDelta) == abs($1.floorDelta) {
                return $0.span.end < $1.span.end
            }
            return abs($0.floorDelta) < abs($1.floorDelta)
        }) else {
            return nil
        }

        let evidence = [
            "기압 고도 센서",
            "상대고도 \(String(format: "%+.1f", candidate.altitudeDelta))m",
            candidate.pedometerDelta == 0
                ? nil
                : "층계 \(candidate.pedometerDelta > 0 ? "+" : "")\(candidate.pedometerDelta)",
        ].compactMap { $0 }
        let confidence: ConfidenceLevel = baselineFloor == nil
            ? .low
            : (candidate.pedometerDelta == candidate.floorDelta
                ? .high
                : .medium)

        return FloorTransition(
            id: UUID(),
            placeKey: placeKey,
            fromFloor: baselineFloor,
            toFloor: baselineFloor.map {
                $0 + candidate.floorDelta
            },
            relativeAltitudeMeters: candidate.altitudeDelta,
            span: candidate.span,
            confidence: confidence,
            evidence: evidence
        )
    }

    private func altitudeGroups(
        in readings: [SensorReading]
    ) -> [[SensorReading]] {
        let altitudeReadings = readings.filter {
            $0.relativeAltitudeMeters != nil
        }
        guard !altitudeReadings.isEmpty else { return [] }

        var groups: [[SensorReading]] = []
        var current: [SensorReading] = []
        for reading in altitudeReadings {
            if let previous = current.last,
               previous.altimeterSessionID != reading.altimeterSessionID
                || reading.timestamp.timeIntervalSince(previous.timestamp)
                    > 30 * 60 {
                groups.append(current)
                current = []
            }
            current.append(reading)
        }
        if !current.isEmpty {
            groups.append(current)
        }
        return groups.filter { $0.count >= 2 }
    }

    private func altitudeCandidate(
        from readings: [SensorReading],
        floorHeight: Double
    ) -> AltitudeFloorCandidate? {
        guard let first = readings.first,
              let last = readings.last,
              let altitudeStart = first.relativeAltitudeMeters,
              let altitudeEnd = last.relativeAltitudeMeters else {
            return nil
        }
        let altitudeDelta = altitudeEnd - altitudeStart
        let floorDelta = Int((altitudeDelta / floorHeight).rounded())
        guard floorDelta != 0 else { return nil }

        let offsets = readings.map {
            Int(
                (
                    (($0.relativeAltitudeMeters ?? altitudeStart)
                        - altitudeStart)
                    / floorHeight
                ).rounded()
            )
        }
        let firstAscended = first.floorsAscended ?? 0
        let lastAscended = last.floorsAscended ?? firstAscended
        let firstDescended = first.floorsDescended ?? 0
        let lastDescended = last.floorsDescended ?? firstDescended
        let pedometerDelta = (lastAscended - firstAscended)
            - (lastDescended - firstDescended)
        let stableSampleCount = offsets.reversed().prefix {
            $0 == floorDelta
        }.count
        guard stableSampleCount >= 2
                || pedometerDelta == floorDelta else {
            return nil
        }

        let crossingIndex = offsets.firstIndex {
            $0 == floorDelta
        } ?? offsets.index(before: offsets.endIndex)
        let transitionStart = crossingIndex > offsets.startIndex
            ? readings[crossingIndex - 1].timestamp
            : first.timestamp
        return AltitudeFloorCandidate(
            floorDelta: floorDelta,
            altitudeDelta: altitudeDelta,
            pedometerDelta: pedometerDelta,
            span: TimeSpan(
                start: transitionStart,
                end: readings[crossingIndex].timestamp
            )
        )
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
        guard let referencePoint = calibration.referencePoint,
              isNearReference(
                reading.point,
                referencePoint: referencePoint
              ) else {
            return nil
        }

        let delta: Double
        let confidence: ConfidenceLevel
        let evidence: [String]
        if reading.altimeterSessionID
                == calibration.referenceAltimeterSessionID,
           let current = reading.relativeAltitudeMeters,
           let reference =
                calibration.referenceRelativeAltitudeMeters {
            delta = current - reference
            confidence = .high
            evidence = [
                "\(calibration.placeName) \(calibration.referenceFloor)층 사용자 기준",
                "기압 상대고도",
            ]
        } else if let currentPressure =
                    reading.pressureKilopascals,
                  let referencePressure =
                    calibration.referencePressureKilopascals,
                  currentPressure > 0,
                  referencePressure > 0 {
            delta = 44_330
                * (
                    1
                    - pow(
                        currentPressure / referencePressure,
                        0.1903
                    )
                )
            confidence = .medium
            evidence = [
                "\(calibration.placeName) \(calibration.referenceFloor)층 사용자 기준",
                "기압차 보정",
            ]
        } else if let point = reading.point {
            delta = point.altitude - referencePoint.altitude
            confidence = .low
            evidence = [
                "\(calibration.placeName) \(calibration.referenceFloor)층 사용자 기준",
                "GPS 고도",
            ]
        } else {
            return nil
        }

        let floorHeight = max(2.2, calibration.floorHeightMeters)
        let floor = max(
            1,
            calibration.referenceFloor
                + Int((delta / floorHeight).rounded())
        )
        let verticalAccuracy = max(
            3,
            reading.point.flatMap {
                $0.verticalAccuracy >= 0
                    ? $0.verticalAccuracy
                    : nil
            }
                ?? (
                    referencePoint.verticalAccuracy >= 0
                        ? referencePoint.verticalAccuracy
                        : 20
                )
        )
        return CalibratedAltitudeEstimate(
            floor: floor,
            seaLevelAltitudeMeters:
                referencePoint.altitude + delta,
            verticalAccuracyMeters: verticalAccuracy,
            confidence: confidence,
            evidence: evidence
        )
    }

    func applying(
        _ calibration: FloorCalibration?,
        to places: [PlaceStay],
        readings: [SensorReading]
    ) -> [PlaceStay] {
        guard let calibration, calibration.isCaptured else {
            return places
        }
        return places.map { place in
            guard let reading = readings
                .filter({ place.span.contains($0.timestamp) })
                .sorted(by: { $0.timestamp < $1.timestamp })
                .first,
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

private struct AltitudeFloorCandidate {
    var floorDelta: Int
    var altitudeDelta: Double
    var pedometerDelta: Int
    var span: TimeSpan
}

struct FloorTimelineResult: Sendable {
    var places: [PlaceStay]
    var transitions: [FloorTransition]
}

struct FrequentPlaceResolutionEngine: Sendable {
    func applying(
        _ frequentPlaces: [FrequentPlace],
        to detectedPlaces: [PlaceStay],
        readings: [SensorReading]
    ) -> [PlaceStay] {
        let candidates = frequentPlaces.filter { $0.point != nil }
        guard !candidates.isEmpty else { return detectedPlaces }

        return detectedPlaces.map { place in
            guard let point = place.point,
                  let match = nearestMatch(
                    to: point,
                    candidates: candidates
                  ) else {
                return place
            }

            var updated = place
            updated.placeKey = match.stablePlaceKey
            updated.displayName = match.name
            updated.buildingName = match.name

            if let calibration = match.floorCalibration,
               let reading = readings
                .filter({ place.span.contains($0.timestamp) })
                .sorted(by: { $0.timestamp < $1.timestamp })
                .first,
               let estimate = FloorCalibrationEngine().estimate(
                    reading: reading,
                    calibration: calibration
               ) {
                updated.floor = estimate.floor
                updated.confidence = estimate.confidence
            } else if let floor = match.floor {
                updated.floor = floor
                updated.confidence = .high
            }
            updated.isConfirmed = true
            return updated
        }
    }

    private func nearestMatch(
        to point: GeoPoint,
        candidates: [FrequentPlace]
    ) -> FrequentPlace? {
        candidates.compactMap { frequent -> (FrequentPlace, Double)? in
            guard let frequentPoint = frequent.point else { return nil }
            let distance = distanceMeters(point, frequentPoint)
            return distance <= frequent.radiusMeters
                ? (frequent, distance)
                : nil
        }
        .min(by: { $0.1 < $1.1 })?
        .0
    }
}

struct FloorTimelineEngine: Sendable {
    var estimator = FloorEstimator()
    var minimumPlaceSegmentDuration: TimeInterval = 60

    func apply(
        readings: [SensorReading],
        to detectedPlaces: [PlaceStay],
        knownPlaces: [PlaceStay]
    ) -> FloorTimelineResult {
        var floorByPlaceKey = knownFloorMap(knownPlaces)
        var resolvedPlaces: [PlaceStay] = []
        var transitions: [FloorTransition] = []

        for var place in detectedPlaces.sorted(by: {
            $0.span.start < $1.span.start
        }) {
            let relevant = readings.filter {
                place.span.contains($0.timestamp)
            }
            let baselineFloor =
                place.floor ?? floorByPlaceKey[place.placeKey]
            guard let transition = estimator.estimate(
                readings: relevant,
                placeKey: place.placeKey,
                baselineFloor: baselineFloor
            ) else {
                if place.floor == nil {
                    place.floor = baselineFloor
                }
                resolvedPlaces.append(place)
                continue
            }

            transitions.append(transition)
            guard let fromFloor = transition.fromFloor,
                  let toFloor = transition.toFloor else {
                resolvedPlaces.append(place)
                continue
            }
            floorByPlaceKey[place.placeKey] = toFloor

            if let segments = split(
                place,
                transition: transition,
                fromFloor: fromFloor,
                toFloor: toFloor
            ) {
                resolvedPlaces.append(contentsOf: segments)
            } else {
                place.floor = toFloor
                place.confidence = transition.confidence
                place.isConfirmed = false
                resolvedPlaces.append(place)
            }
        }

        return FloorTimelineResult(
            places: resolvedPlaces,
            transitions: transitions
        )
    }

    private func knownFloorMap(
        _ places: [PlaceStay]
    ) -> [String: Int] {
        let grouped = Dictionary(grouping: places) {
            $0.placeKey
        }
        return grouped.reduce(into: [String: Int]()) {
            values, entry in
            let ordered = entry.value.sorted {
                $0.span.end < $1.span.end
            }
            let known = ordered.last {
                $0.floor != nil && $0.isConfirmed
            } ?? ordered.last { $0.floor != nil }
            if let floor = known?.floor {
                values[entry.key] = floor
            }
        }
    }

    private func split(
        _ place: PlaceStay,
        transition: FloorTransition,
        fromFloor: Int,
        toFloor: Int
    ) -> [PlaceStay]? {
        guard fromFloor != toFloor,
              transition.span.start.timeIntervalSince(place.span.start)
                >= minimumPlaceSegmentDuration,
              place.span.end.timeIntervalSince(transition.span.end)
                >= minimumPlaceSegmentDuration else {
            return nil
        }

        var before = place
        before.id = UUID()
        before.floor = fromFloor
        before.span = TimeSpan(
            start: place.span.start,
            end: transition.span.start
        )

        var after = place
        after.id = UUID()
        after.floor = toFloor
        after.span = TimeSpan(
            start: transition.span.end,
            end: place.span.end
        )
        after.confidence = transition.confidence
        after.isConfirmed = false
        return [before, after]
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
        healthEvidence: [AppleMovementEvidence] = [],
        correctedModes: [String: TravelMode] = [:]
    ) -> [TravelSegment] {
        let orderedStays = stays.sorted { $0.span.start < $1.span.start }
        guard orderedStays.count >= 2 else { return [] }

        return zip(orderedStays, orderedStays.dropFirst()).compactMap { from, to in
            guard from.placeKey != to.placeKey else { return nil }
            let span = TimeSpan(start: from.span.end, end: to.span.start)
            guard span.duration > 0 else { return nil }
            let segmentReadings = readings.filter {
                span.contains($0.timestamp)
            }
            let signature = "\(from.placeKey)->\(to.placeKey)"
            let inference = classifier.classify(
                readings: segmentReadings,
                inside: span,
                healthEvidence: healthEvidence,
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

enum TravelSegmentGroupingEngine {
    static let defaultMaximumGap: TimeInterval = 5 * 60

    static func groups(
        from segments: [TravelSegment],
        maximumGap: TimeInterval = defaultMaximumGap
    ) -> [TravelSegmentGroup] {
        let ordered = segments.sorted { $0.span.start < $1.span.start }
        var grouped: [[TravelSegment]] = []

        for segment in ordered {
            guard var current = grouped.popLast() else {
                grouped.append([segment])
                continue
            }
            if canMerge(
                segment,
                after: current.last,
                maximumGap: maximumGap
            ) {
                current.append(segment)
                grouped.append(current)
            } else {
                grouped.append(current)
                grouped.append([segment])
            }
        }

        return grouped.map(TravelSegmentGroup.init)
    }

    private static func canMerge(
        _ next: TravelSegment,
        after previous: TravelSegment?,
        maximumGap: TimeInterval
    ) -> Bool {
        guard let previous,
              previous.mode == next.mode else {
            return false
        }
        let gap = next.span.start.timeIntervalSince(previous.span.end)
        guard gap <= maximumGap else { return false }
        if let previousDestination = previous.toPlaceID,
           let nextOrigin = next.fromPlaceID,
           previousDestination != nextOrigin {
            return false
        }
        return true
    }
}

enum MovementCorrectionEngine {
    private static let maximumRememberedCorrections = 200

    static func recording(
        mode: TravelMode,
        for segment: TravelSegment,
        places: [PlaceStay],
        existing: [TravelModeCorrection],
        at date: Date = .now
    ) -> [TravelModeCorrection] {
        let placeKeys = placeKeys(for: segment, places: places)
        let previous = bestCorrection(
            for: segment,
            places: places,
            in: existing
        )
        let correction = TravelModeCorrection(
            id: previous?.id ?? UUID(),
            fromPlaceKey: placeKeys.from,
            toPlaceKey: placeKeys.to,
            span: segment.span,
            mode: mode,
            inferredMode: previous?.inferredMode ?? segment.mode,
            inferredConfidence:
                previous?.inferredConfidence ?? segment.confidence,
            updatedAt: date
        )

        var result = existing.filter { value in
            guard let previous else {
                return !matchesSameTarget(
                    value,
                    segment: segment,
                    places: places
                )
            }
            return value.id != previous.id
        }
        result.append(correction)
        result.sort { $0.updatedAt < $1.updatedAt }
        if result.count > maximumRememberedCorrections {
            result.removeFirst(result.count - maximumRememberedCorrections)
        }
        return result
    }

    static func applying(
        _ corrections: [TravelModeCorrection],
        to segments: [TravelSegment],
        places: [PlaceStay]
    ) -> [TravelSegment] {
        segments.map { segment in
            guard let correction = bestCorrection(
                for: segment,
                places: places,
                in: corrections
            ) else {
                return segment
            }
            var value = segment
            value.mode = correction.mode
            value.confidence = .high
            value.isConfirmed = true
            value.evidence.removeAll { $0.hasPrefix("사용자 확인") }
            value.evidence.append("사용자 확인 기억")
            return value
        }
    }

    static func correction(
        for segment: TravelSegment,
        places: [PlaceStay],
        in corrections: [TravelModeCorrection]
    ) -> TravelModeCorrection? {
        bestCorrection(
            for: segment,
            places: places,
            in: corrections
        )
    }

    static func removingCorrection(
        for segment: TravelSegment,
        places: [PlaceStay],
        from corrections: [TravelModeCorrection]
    ) -> [TravelModeCorrection] {
        guard let matched = bestCorrection(
            for: segment,
            places: places,
            in: corrections
        ) else {
            return corrections
        }
        return corrections.filter { $0.id != matched.id }
    }

    private static func bestCorrection(
        for segment: TravelSegment,
        places: [PlaceStay],
        in corrections: [TravelModeCorrection]
    ) -> TravelModeCorrection? {
        corrections
            .compactMap { correction -> (TravelModeCorrection, Double)? in
                guard let score = matchScore(
                    correction,
                    segment: segment,
                    places: places
                ) else {
                    return nil
                }
                return (correction, score)
            }
            .max {
                if $0.1 == $1.1 {
                    return $0.0.updatedAt < $1.0.updatedAt
                }
                return $0.1 < $1.1
            }?
            .0
    }

    private static func matchesSameTarget(
        _ correction: TravelModeCorrection,
        segment: TravelSegment,
        places: [PlaceStay]
    ) -> Bool {
        matchScore(
            correction,
            segment: segment,
            places: places
        ) != nil
    }

    private static func matchScore(
        _ correction: TravelModeCorrection,
        segment: TravelSegment,
        places: [PlaceStay]
    ) -> Double? {
        let segmentKeys = placeKeys(for: segment, places: places)
        if let correctionFrom = correction.fromPlaceKey,
           let correctionTo = correction.toPlaceKey,
           correctionFrom == segmentKeys.from,
           correctionTo == segmentKeys.to {
            return 3
        }

        guard let intersection = correction.span.intersection(
            with: segment.span
        ) else {
            return nil
        }
        let shorterDuration = max(
            1,
            min(correction.span.duration, segment.span.duration)
        )
        let overlapRatio = intersection.duration / shorterDuration
        guard overlapRatio >= 0.5 else { return nil }
        return 1 + overlapRatio
    }

    private static func placeKeys(
        for segment: TravelSegment,
        places: [PlaceStay]
    ) -> (from: String?, to: String?) {
        let keysByID = Dictionary(
            uniqueKeysWithValues: places.map { ($0.id, $0.placeKey) }
        )
        return (
            segment.fromPlaceID.flatMap { keysByID[$0] },
            segment.toPlaceID.flatMap { keysByID[$0] }
        )
    }
}

/// Reconciles records that already exist in Apple's device stores with
/// Taption's own in-app estimates. Plans and user-entered records are retained;
/// only records from the same Apple source are replaced.
enum AppleDeviceGroundTruthEngine {
    static func applyingMotionHistory(
        to readings: [SensorReading],
        activities: [MotionActivityRecord]
    ) -> [SensorReading] {
        let orderedActivities = activities.sorted {
            $0.span.start < $1.span.start
        }
        return readings
            .map { reading in
                guard let activity = orderedActivities.last(where: {
                    $0.motion != .unknown
                        && $0.span.contains(reading.timestamp)
                }) else {
                    return reading
                }
                var value = reading
                value.motion = activity.motion
                value.motionConfidence = activity.confidence
                return value
            }
            .sorted { $0.timestamp < $1.timestamp }
    }

    static func mergingTravel(
        gpsSegments: [TravelSegment],
        motionActivities: [MotionActivityRecord],
        pedometer: PedometerSummary?,
        healthEvidence: [AppleMovementEvidence] = []
    ) -> [TravelSegment] {
        let watchSegments = healthEvidence
            .filter {
                $0.source == .appleWatch
                    && $0.kind == .workout
                    && $0.workoutMode != nil
                    && $0.span.duration >= 60
            }
            .filter { workout in
                !gpsSegments.contains {
                    $0.span.intersection(with: workout.span) != nil
                }
            }
            .map { workout in
                TravelSegment(
                    mode: workout.workoutMode ?? .walking,
                    span: workout.span,
                    distanceMeters: workout.distanceMeters ?? 0,
                    confidence: .high,
                    evidence: [
                        "Apple Watch 운동 기록",
                        "HealthKit 기기 출처 확인",
                    ]
                )
            }
        let candidates = motionActivities
            .filter { $0.span.duration >= 60 }
            .filter { activity in
                !gpsSegments.contains {
                    $0.span.intersection(with: activity.span) != nil
                }
                    && !watchSegments.contains {
                        $0.span.intersection(with: activity.span) != nil
                    }
            }
            .compactMap { activity -> (MotionActivityRecord, MovementInference)? in
                guard travelMode(for: activity.motion) != nil else {
                    return nil
                }
                let reading = SensorReading(
                    timestamp: activity.span.start,
                    motion: activity.motion,
                    motionConfidence: activity.confidence,
                    gpsAvailable: false
                )
                let inference = TravelModeClassifier().classify(
                    readings: [reading],
                    inside: activity.span,
                    healthEvidence: healthEvidence
                )
                return (activity, inference)
            }

        let walkingRunningDuration = candidates.reduce(0) { result, candidate in
            switch candidate.1.mode {
            case .walking, .running:
                result + candidate.0.span.duration
            default:
                result
            }
        }

        let motionSegments = candidates.map { activity, inference in
            let mode = inference.mode
            let usesPedometerDistance =
                (mode == .walking || mode == .running)
                && walkingRunningDuration > 0
            let distance = usesPedometerDistance
                ? (pedometer?.distanceMeters ?? 0)
                    * activity.span.duration / walkingRunningDuration
                : 0
            var evidence = ["iPhone Core Motion 기록"]
            if usesPedometerDistance, pedometer?.distanceMeters != nil {
                evidence.append("iPhone 걸음·거리 기록")
            }
            if activity.motion == .automotive {
                evidence.append("차량 종류는 사용자 확인 필요")
            }
            evidence.append(contentsOf: inference.evidence)
            return TravelSegment(
                mode: mode,
                span: activity.span,
                distanceMeters: distance,
                confidence: inference.confidence,
                evidence: Array(Set(evidence)).sorted()
            )
        }

        return (gpsSegments + watchSegments + motionSegments)
            .sorted { $0.span.start < $1.span.start }
    }

    static func replacingHealthKitActuals(
        existing: [ActualRecord],
        with fresh: [ActualRecord],
        inside span: TimeSpan
    ) -> [ActualRecord] {
        var seen = Set<UUID>()
        let uniqueFresh = fresh.filter {
            $0.source == .healthKit && seen.insert($0.id).inserted
        }
        let freshIDs = Set(uniqueFresh.map(\.id))
        let linkedWorkouts = uniqueFresh.filter { $0.planID != nil }
        return (
            existing.filter { existingActual in
                if existingActual.source == .healthKit,
                   existingActual.span().intersection(with: span) != nil {
                    return false
                }
                if existingActual.source == .appleWatch,
                   freshIDs.contains(existingActual.id) {
                    return false
                }
                guard existingActual.source == .timer,
                      let planID = existingActual.planID else {
                    return true
                }
                let supersededByWatchWorkout = linkedWorkouts.contains { workout in
                    guard workout.planID == planID else { return false }
                    let endsAt = workout.endedAt ?? workout.startedAt
                    let timerSpan = existingActual.span(asOf: endsAt)
                    let startsTogether = abs(
                        existingActual.startedAt.timeIntervalSince(workout.startedAt)
                    ) <= 5 * 60
                    return startsTogether
                        || timerSpan.intersection(with: workout.span()) != nil
                }
                return !supersededByWatchWorkout
            }
            + uniqueFresh
        )
        .sorted { $0.startedAt < $1.startedAt }
    }

    private static func travelMode(for motion: MotionKind) -> TravelMode? {
        switch motion {
        case .walking:
            .walking
        case .running:
            .running
        case .cycling:
            .cycling
        case .automotive:
            .car
        case .stationary, .unknown:
            nil
        }
    }
}

enum AppleWatchSensorActivityEngine {
    static func upserting(
        _ summary: TaptionWatchSensorSummary,
        into existing: [ActualRecord],
        linkedPlan: PlanRecord?
    ) -> [ActualRecord] {
        if existing.contains(where: {
            $0.id == summary.sessionID && $0.source == .healthKit
        }) {
            return existing
        }

        let title = linkedPlan?.title
            ?? summary.linkedPlanTitle
            ?? "Apple Watch \(summary.workoutKind.title)"
        let categoryID = linkedPlan?.categoryID
            ?? summary.linkedCategoryID
            ?? "exercise"
        let record = ActualRecord(
            id: summary.sessionID,
            planID: linkedPlan?.id ?? summary.linkedPlanID,
            title: title,
            categoryID: categoryID,
            startedAt: summary.startedAt,
            endedAt: max(summary.startedAt, summary.endedAt),
            source: .appleWatch,
            confidence: summary.accelerometerSampleCount > 0
                ? .high
                : .medium,
            createdAt: summary.startedAt
        )
        return (
            existing.filter { $0.id != summary.sessionID }
                + [record]
        ).sorted { $0.startedAt < $1.startedAt }
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
