import Foundation
import TaptionPlanEngine

struct TravelModeClassifier: Sendable {
    /// 지하철은 고도 변화가 있어야 탑승으로 본다(대표 지시, SUB1029A01). 역 출입(계단·에스컬레이터)은
    /// 지하·고가 모두 몇 미터 이상 오르내린다. 20분 안에 5m 이상 바뀌지 않으면 지하철에서 뺀다.
    /// 필요조건일 뿐이다: 실제 기록에서 자동차 출근도 엘리베이터·지하 주차장으로 70m 넘게 오르내렸다.
    static let subwayAltitudeChangeMeters = 5.0
    static let subwayAltitudeWindow: TimeInterval = 20 * 60
    static let noAltitudeChangeEvidence = "고도 변화 없음 · 지하철 제외"
    /// iPhone 모션이 차량이라고 말한 고신뢰 자동차. 예전 자동 지하철이 이 판정을 덮지 못한다(EXP1029A01).
    /// 근거 문자열만으로 가르는 이유: 모션 없이 속도만 본 자동차(지하 GPS 튐)는 여전히 지하철이 이긴다.
    static func isMotionBackedCar(_ segment: TravelSegment) -> Bool {
        segment.mode == .car && segment.confidence == .high
            && segment.evidence.contains { $0.contains("Core Motion 자동차") }
    }
    /// 승차 전·하차 후로 고도를 함께 보는 여유.
    static let altitudeContextMargin: TimeInterval = 10 * 60

    static func altitudeContextSpan(_ span: TimeSpan) -> TimeSpan {
        TimeSpan(start: span.start.addingTimeInterval(-altitudeContextMargin),
                 end: span.end.addingTimeInterval(altitudeContextMargin))
    }

    func classify(
        readings: [SensorReading],
        inside requestedSpan: TimeSpan? = nil,
        healthEvidence: [AppleMovementEvidence] = [],
        correctedMode: TravelMode? = nil,
        userTransitLocations: [UserTransitLocation] = [],
        altitudeContext: [SensorReading] = [],
        registeredCarAudioNames: Set<String> = []
    ) -> MovementInference {
        if let correctedMode {
            return MovementInference(
                mode: correctedMode,
                confidence: .high,
                score: 1,
                evidence: ["사용자 교정"]
            )
        }
        let validReadings = readings.filter {
            RouteTimelineTimestamp.isValid($0.timestamp)
        }
        guard !validReadings.isEmpty || !healthEvidence.isEmpty else {
            return MovementInference(
                mode: .walking,
                confidence: .low,
                score: 0,
                evidence: ["센서 데이터 부족"]
            )
        }

        let ordered = validReadings.sorted { $0.timestamp < $1.timestamp }
        let inferenceSpan = requestedSpan ?? sensorSpan(for: ordered)
        // 차량 오디오 연결은 사용자 교정 다음으로 강한 근거다(CAR1029A01).
        if let carAudio = CarAudioTravelConfirmation.evaluate(
            readings: ordered,
            context: altitudeContext,
            span: inferenceSpan,
            registered: registeredCarAudioNames
        ) {
            return MovementInference(
                mode: .car,
                confidence: .high,
                score: carAudio.isRegistered ? 1 : 0.95,
                evidence: [carAudio.evidence]
            )
        }
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

        // A Watch behavior chunk may be the only source when HealthKit has
        // not finished publishing the workout.  Respect explicit transit and
        // vehicle labels before falling back to the broader score fusion.
        let explicitWatchBehavior = ordered
            .reversed()
            .compactMap { (reading: SensorReading) -> WatchBehaviorKind? in
                guard reading.sourceDevice == .appleWatch,
                      let behavior = reading.behavior.flatMap(
                          WatchBehaviorKind.init(rawValue:)
                      ),
                      reading.behaviorConfidenceScore.map({ $0 >= 0.55 })
                          ?? false else {
                    return nil
                }
                return behavior
            }
            .first
        let speeds = speedSeries(for: ordered)
        let averageSpeed = trimmedMean(speeds)
        let maxSpeed = percentile(speeds, fraction: 0.9) ?? 0
        let hasVehicleSpeed = averageSpeed > 5.5 || maxSpeed > 8
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
            if $0.value != $1.value {
                return $0.value < $1.value
            }
            let leftPriority = motionTiePriority($0.key)
            let rightPriority = motionTiePriority($1.key)
            if leftPriority != rightPriority {
                return leftPriority > rightPriority
            }
            return $0.key.rawValue > $1.key.rawValue
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

        switch explicitWatchBehavior {
        case .subway:
            add(.subway, 0.7, "Apple Watch 행동 분류: 지하철")
        case .publicTransit:
            add(.bus, 0.48, "Apple Watch 행동 분류: 대중교통")
        case .automotive:
            add(.car, 0.52, "Apple Watch 행동 분류: 자동차")
        default:
            break
        }

        switch dominantMotion {
        case .walking:
            add(
                .walking,
                (hasVehicleSpeed ? 0.2 : 0.75) * dominantMotionWeight,
                hasVehicleSpeed
                    ? "Core Motion 보행 · 차량 속도와 불일치"
                    : "Core Motion 보행"
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
            } else if hasVehicleSpeed {
                add(.car, 0.56, "보행 불가능 속도와 걸음 신호 불일치")
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
        let watchAcceleration = watchAccelerationSignal(ordered)
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
        let railMatchCount = ordered.filter(\.matchesRailRoute).count
        let railRatio = ratio(ordered, where: \.matchesRailRoute)
        let repeatedRailMatch = railMatchCount >= 2 && railRatio >= 0.25
        let transitRatio = ratio(ordered, where: \.matchesPublicTransitRoute)
        let stopRatio = ratio(ordered, where: \.frequentStops)
        let taxiHintRatio = ratio(ordered, where: \.rideHailingHint)
        let airportRatio = ratio(ordered, where: \.nearAirport)
        let portRatio = ratio(ordered, where: \.nearPort)
        let waterRatio = ratio(ordered, where: \.onWater)
        let roadRatio = ordered.isEmpty ? 0 : Double(ordered.filter {
            $0.behaviorEvidence?.contains("Apple 지도 도로 인접") == true
        }.count) / Double(ordered.count)

        let watchVibration = watchAcceleration.sampleCount >= 2
            && watchAcceleration.standardDeviationG >= 0.012
            && watchAcceleration.meanJerkGPerSecond >= 0.04
        let lowStepSignal = !stepSignal.hasCoverage
            || stepsPerMinute <= 5
        let railSpeedSignal = averageSpeed >= 4
            && averageSpeed <= 35
            || maxSpeed >= 8
                && maxSpeed <= 40
        let signaledRailStations = SubwayStationCatalog.stationNames(
            from: ordered
        )
        let strictCoordinateTrajectory = SubwayStationCatalog.coordinateTrajectory(
            from: ordered
        )
        let stationJourney = SubwayStationCatalog.stationJourney(
            from: ordered
        )
        let stationStateConfirmation = stationJourney?.hasRailEvidence == true
        // 지하 구간에서는 출발·도착역 두 개만 GPS에 남을 수 있다. 이 보조
        // 궤적은 철도 지도 신호가 충분한 경우에만 허용해 도로 주행을 막는다.
        let coordinateTrajectory = strictCoordinateTrajectory
            ?? (repeatedRailMatch
                ? SubwayStationCatalog.sparseEndpointTrajectory(from: ordered)
                : nil)
        let signaledSubwayRoute = signaledRailStations.count >= 2
            ? SubwayStationCatalog.route(for: signaledRailStations)
            : nil
        let userStationNames = SubwayStationCatalog.userStationNames(
            from: ordered,
            locations: userTransitLocations
        )
        let userSubwayRoute = userStationNames.count >= 2
            ? SubwayStationCatalog.route(for: userStationNames)
            : nil
        // 원본 좌표로 복원한 역 순서는 하루 전체의 역 이름을 이어 붙인
        // 보강값보다 우선한다. 보강값만 고르면 출근·퇴근이 한 경로로
        // 합쳐져 환승역을 다시 통과하는 순환 노선이 선택될 수 있다.
        let resolvedSubwayRoute = stationJourney?.route
            ?? coordinateTrajectory?.route
            ?? signaledSubwayRoute
            ?? userSubwayRoute
        let userStationRouteMatches = resolvedSubwayRoute.map {
            SubwayStationCatalog.userStationRouteMatches(
                route: $0,
                locations: userTransitLocations
            )
        } ?? []
        let userStationRouteConfirmation = userSubwayRoute != nil
            || userStationRouteMatches.count >= 1
        let usesCoordinateRoute = coordinateTrajectory != nil
        let railStations = stationJourney?.stationNames
            ?? (usesCoordinateRoute
            ? coordinateTrajectory?.observedStationNames ?? signaledRailStations
            : (signaledRailStations.isEmpty ? userStationNames : signaledRailStations))
        let coordinateRailContext = usesCoordinateRoute
        let confirmedRailContext = repeatedRailMatch
            || coordinateRailContext
            || stationStateConfirmation
            || userStationRouteConfirmation
        let railContext = stationRatio >= 0.2 || confirmedRailContext
        let subwayWiFiStreak = ordered.compactMap {
            $0.subwayWiFiObservationStreak
        }.max() ?? 0
        let latestSubwayWiFi = ordered.last {
            SubwayWiFiSSID.isAllowed($0.connectedWiFiSSID)
        }
        let subwayWiFiFamily = subwayWiFiFamily(
            for: latestSubwayWiFi?.connectedWiFiSSID
        )
        let subwayWiFiSignal = subwayWiFiFamily != nil
            && SubwayWiFiSSID.hasContinuousEvidence(
                streak: subwayWiFiStreak
            )
            && railSpeedSignal
            && railContext
        let stationStopPattern = resolvedSubwayRoute.map {
            SubwayStationCatalog.stationStopPattern(
                from: ordered,
                route: $0
            )
        }
        let routeHasTransferPattern = stationJourney.map {
            stationStateConfirmation && !$0.transferStationNames.isEmpty
        } ?? resolvedSubwayRoute.map {
            !$0.transferStationNames.isEmpty
                && Set(railStations).count >= 3
        } ?? false
        let stationStopConfirmation = routeHasTransferPattern
            && stationStopPattern?.isStrong == true
        let routeTrajectoryConfirmation = coordinateRailContext
            && railSpeedSignal
            && hasVehicleSpeed
            && (
                Set(railStations).count >= 3
                || coordinateTrajectory?.isSparseEndpointTrajectory == true
                    && repeatedRailMatch
            )
        // 역 출입의 오르내림은 승차 전·하차 후에 일어나므로 앞뒤 표본도 함께 본다.
        // 기압계 표본이 하나도 없으면 "변화 없음"이 아니라 "확인 불가"라 막지 않는다.
        let altitudeSamples = ordered + altitudeContext
        let hasAltitudeData = altitudeSamples.contains {
            $0.pressureKilopascals != nil || $0.relativeAltitudeMeters != nil
        }
        let hasSubwayAltitudeChange = !hasAltitudeData
            || Self.altitudeChangeMeters(altitudeSamples) >= Self.subwayAltitudeChangeMeters
        let undergroundSignal = gpsLossRatio >= 0.35
            || altitudeDelta <= -2
        let displacementMeters = firstLastDisplacement(ordered)
        let deepUndergroundRecovery = altitudeDropAndRecovery(ordered)
        let altitudeDropMeters = maxAltitudeDrop(ordered)
        let undergroundDescent = altitudeDropMeters >= 8
            || altitudeDelta <= -8
            || gpsLossRatio >= 0.45
        let stationAltitudeDrop = stationAltitudeDropSignal(ordered)
        let lowStepsForTransit = !stepSignal.hasCoverage
            || stepsPerMinute <= 5
                && stepSignal.cadenceStepsPerSecond <= 0.2
        let observedLowStepsSignal = stepSignal.hasCoverage
            && stepsPerMinute <= 5
            && stepSignal.cadenceStepsPerSecond <= 0.2
        let userStationMatchCount = Set(
            userStationNames.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
        ).count
        let userStationIndependentSignals = [
            repeatedRailMatch,
            gpsLossRatio >= 0.35 || altitudeDelta <= -2,
            observedLowStepsSignal,
            watchVibration,
            subwayWiFiFamily != nil && subwayWiFiStreak >= 2,
        ].filter { $0 }.count
        let prioritizedSingleUserStation = userStationMatchCount == 1
            && userStationIndependentSignals >= 1
        let watchVibrationUnavailable = watchAcceleration.sampleCount < 2
        let watchVibrationAbsent = watchAcceleration.sampleCount >= 2
            && watchAcceleration.standardDeviationG < 0.012
            && watchAcceleration.meanJerkGPerSecond < 0.04
        let coordinateTrajectorySignal = routeTrajectoryConfirmation
        let trustedStationSequence = repeatedRailMatch
            || coordinateRailContext
            || stationStateConfirmation
            || userStationRouteConfirmation
            || stationStopConfirmation
            || subwayWiFiSignal
        let stationToStationSubway = railStations.count >= 2
            && resolvedSubwayRoute != nil
            && railContext
            && trustedStationSequence
            && (
                stationStateConfirmation
                ||
                coordinateTrajectorySignal
                || stationStopConfirmation
                || subwayWiFiSignal
                || undergroundDescent
                    && lowStepsForTransit
                    && (watchVibrationAbsent || watchVibrationUnavailable)
                || userStationRouteConfirmation
            )

        if stationRatio >= 0.25 {
            add(.subway, 0.16, "역 접근")
            add(.train, 0.1, "역 접근")
        }
        if repeatedRailMatch, railRatio >= 0.5 {
            add(.subway, 0.2, "철도 경로 일치")
            add(.train, 0.28, "철도 경로 일치")
        }
        if coordinateRailContext {
            add(.subway, 0.42, "역 좌표 궤적 일치")
            add(.train, 0.12, "철도역 순차 통과")
        }
        if gpsLossRatio >= 0.45 && confirmedRailContext {
            add(.subway, 0.18, "GPS 약화")
        }
        if altitudeDelta <= -2 && railContext {
            add(.subway, 0.16, "상대고도 하강")
        }
        if stationAltitudeDrop && confirmedRailContext {
            add(.subway, 0.24, "지하철역 주변 고도 하강")
        }
        if subwayWiFiSignal, let subwayWiFiFamily {
            add(
                .subway,
                0.82,
                subwayWiFiEvidence(
                    family: subwayWiFiFamily,
                    streak: subwayWiFiStreak,
                    observedAt: latestSubwayWiFi?.timestamp
                )
            )
        }
        if stationRatio >= 0.25,
           repeatedRailMatch,
           railRatio >= 0.5,
           gpsLossRatio >= 0.45,
           altitudeDelta <= -2 {
            add(.subway, 0.3, "지하철 복합 신호 충족")
        }

        if let profile = deepUndergroundRecovery,
           profile.dropMeters >= 100,
           profile.recoveryMeters >= 80,
           displacementMeters >= 100,
           lowStepSignal,
           railContext {
            add(.subway, 0.9, "상대고도 100m 이상 하강 후 회복")
            add(.subway, 0.24, "지하 구간 위치 변화 \(Int(displacementMeters.rounded()))m")
        }

        if watchVibration && lowStepSignal && undergroundSignal
            && railContext && railSpeedSignal {
            add(.subway, 0.62, "Apple Watch 3축 가속도 철도 진동")
            add(.subway, 0.18, "걸음 거의 없음 · 지하 구간")
            if railContext {
                add(.subway, 0.18, "역·철도·반복 정차 패턴")
            }
        }

        // 지도 보강값이 있으면 역·역 이동과 지하 신호를 함께 확인한다.
        // 과거처럼 보강값이 비어 있으면 세 역 이상의 좌표 순서와 철도 속도가
        // 일치할 때만 복원해, 환승 보행 때문에 전체 걸음 수가 늘어도 놓치지 않는다.
        if stationToStationSubway, hasSubwayAltitudeChange {
            let first = stationJourney?.startStationName
                ?? railStations.first
                ?? "출발역"
            let last = stationJourney?.destinationStationName
                ?? railStations.last
                ?? "도착역"
            let subwayRoute = resolvedSubwayRoute
            var routeEvidence: [String] = []
            if let stationJourney {
                routeEvidence.append(contentsOf: stationJourney.evidence)
            }
            if let subwayRoute {
                routeEvidence.append(
                    "노선 " + subwayRoute.lineNames.joined(separator: " → ")
                )
                if !subwayRoute.transferStationNames.isEmpty {
                    routeEvidence.append(
                        "환승 " + subwayRoute.transferStationNames.joined(separator: ", ")
                    )
                }
            }
            add(
                .subway,
                1.35,
                "지하철역 \(first) → \(last)"
            )
            add(.subway, 0.42, "역·역 이동 구간")
            if undergroundDescent {
                add(.subway, 0.32, "지하 하강·GPS 약화")
            }
            if lowStepsForTransit {
                add(.subway, 0.18, "걸음 거의 없음")
            } else if coordinateTrajectorySignal {
                add(.subway, 0.18, "환승 보행 포함")
            }
            if coordinateRailContext {
                add(.subway, 0.28, "원본 좌표로 역 순서 복원")
            }
            if routeHasTransferPattern {
                add(.subway, 0.36, "출발역·환승역·도착역 순서")
            }
            if userStationRouteConfirmation {
                let names = userStationRouteMatches.isEmpty
                    ? userStationNames
                    : userStationRouteMatches
                add(
                    .subway,
                    0.55,
                    "사용자 지정 지하철역 일치"
                        + (names.isEmpty ? "" : " (" + names.joined(separator: ", ") + ")")
                )
            }
            if stationStopConfirmation {
                add(.subway, 0.5, "역별 가다·서다 정차 패턴")
            }
            if watchVibrationAbsent {
                add(.subway, 0.12, "Apple Watch 진동 없음")
            }
            let evidence = Array(
                Set((candidates[.subway]?.1 ?? []) + routeEvidence)
            ).sorted()
            return MovementInference(
                mode: .subway,
                confidence: .high,
                score: 0.96,
                evidence: Array(Set(evidence)).sorted(),
                subwayRoute: subwayRoute
            )
        }

        // 역 이름·노선이 두 곳 이상 확인됐지만 아직 5분 체류/이탈
        // 상태가 끝나지 않은 실시간 구간도 지하철 노선을 유지한다.
        // 그렇지 않으면 철도 경로의 일반적인 속도 점수가 `.train`을
        // 앞서면서 이미 확인한 지하철 노선이 표시에서 사라질 수 있다.
        if let resolvedSubwayRoute,
           SubwayStationCatalog.isValid(resolvedSubwayRoute),
           railContext,
           trustedStationSequence,
           railStations.count >= 2,
           hasSubwayAltitudeChange,
           (repeatedRailMatch || stationAltitudeDrop || undergroundDescent) {
            var evidence = [
                "지하철 노선 후보 확정",
                "노선 " + resolvedSubwayRoute.lineNames.joined(separator: " → "),
            ]
            if !resolvedSubwayRoute.transferStationNames.isEmpty {
                evidence.append(
                    "환승 " + resolvedSubwayRoute.transferStationNames.joined(separator: ", ")
                )
            }
            if stationAltitudeDrop {
                evidence.append("지하철역 주변 고도 하강")
            }
            return MovementInference(
                mode: .subway,
                confidence: .high,
                score: 0.92,
                evidence: Array(Set(evidence)).sorted(),
                subwayRoute: resolvedSubwayRoute
            )
        }

        // 사용자 등록 역 하나는 역 자체만으로 확정하지 않는다. 독립적인
        // 철도 신호가 하나 이상 붙은 경우에만 자동차 후보보다 먼저 처리한다.
        // 두 역 이상 경로는 위의 노선·역 순서 판정에서 높은 신뢰도로 확정한다.
        if prioritizedSingleUserStation, hasSubwayAltitudeChange {
            var evidence = [
                "사용자 지정 지하철역 일치 1곳",
                "독립 철도 신호 \(userStationIndependentSignals)개",
            ]
            if let subwayWiFiFamily, subwayWiFiStreak >= 2 {
                evidence.append(
                    subwayWiFiEvidence(
                        family: subwayWiFiFamily,
                        streak: subwayWiFiStreak,
                        observedAt: latestSubwayWiFi?.timestamp
                    )
                )
            }
            return MovementInference(
                mode: .subway,
                confidence: .medium,
                score: 0.88,
                evidence: evidence,
                subwayRoute: nil
            )
        }

        let busStopPathSignal = transitRatio >= 0.5
            && stopRatio >= 0.35
            && stationRatio >= 0.2
            && railRatio < 0.5
        if busStopPathSignal {
            add(.bus, 0.7, "버스정류장 인접 경로·정차")
        } else if transitRatio >= 0.5 {
            add(.bus, 0.35, "대중교통 도로 경로 일치")
        }
        if stopRatio >= 0.35 {
            add(.bus, 0.22, "정류장형 반복 정차")
        }
        if roadRatio >= 0.5,
           hasVehicleSpeed || dominantMotion == .automotive {
            if transitRatio >= 0.3 && stopRatio >= 0.2 {
                add(.bus, 0.64, "도로·버스정류장·반복 정차 일치")
            } else {
                add(.car, 0.7, "도로 위 차량 속도·자동차 모션 우선")
                add(.bus, 0.16, "도로 위 동력 이동")
            }
        }
        if taxiHintRatio >= 0.5 {
            add(.taxi, 0.55, "택시 이용 단서")
        }
        let endpointAirportSignal = ordered.first?.nearAirport == true
            || ordered.last?.nearAirport == true
        let maximumAltitude = ordered.compactMap { $0.point?.altitude }.max() ?? 0
        if endpointAirportSignal,
           maxSpeed > 55 || displacementMeters >= 50_000 {
            add(.airplane, 0.82, "공항 출도착·장거리 고속 경로")
        }
        if maximumAltitude >= 1_500, maxSpeed > 45, lowStepSignal {
            add(.airplane, 0.72, "고고도·항공 속도·걸음 없음")
        } else if airportRatio >= 0.25, averageSpeed > 35 {
            add(.airplane, 0.32, "공항 인접 고속 이동")
        }
        if waterRatio >= 0.4, lowStepSignal,
           averageSpeed >= 1, averageSpeed <= 20 {
            add(.ship, 0.88, "수상 경로·선박 속도·걸음 없음")
        } else if portRatio >= 0.2 || waterRatio >= 0.4 {
            add(.ship, 0.55, "항구·수상 경로")
        }

        // 직선 변위만으로 계산한 최소 속도는 실제 경로보다 항상 과소평가된다.
        // 이 값으로도 불가능한 수단은 어떤 신호보다 우선해 배제한다.
        let displacementSpeed = inferenceSpan.duration >= 120
            ? displacementMeters / inferenceSpan.duration
            : 0
        let displacementNote =
            "직선 변위 최소 속도 \(Int((displacementSpeed * 3.6).rounded()))km/h"
        // 걸음이 실제로 늘어나면 차량 안일 수 없고, 걸음 없이 차량 속도가
        // 지속되면 보행일 수 없다. Core Motion 라벨을 뒤집는 유일한 근거다.
        let pedestrianEvidence = hasPedestrianCadence || stepsPerMinute >= 40
        let vehicleSpeedEvidence = hasVehicleSpeed && !pedestrianEvidence
        var impossibleModes: Set<TravelMode> = []
        if displacementSpeed > 2.6 || vehicleSpeedEvidence {
            impossibleModes.insert(.walking)
        }
        if displacementSpeed > 5.5 || vehicleSpeedEvidence {
            impossibleModes.insert(.running)
        }
        if displacementSpeed > 8.5
            || (averageSpeed > 12 && !pedestrianEvidence) {
            impossibleModes.insert(.cycling)
        }

        // Core Motion 라벨을 최종 권위로 사용한다. 점수 융합이 실제 기록과
        // 다른 수단을 만들어 내는 문제가 있어, 물리적으로 불가능할 때만
        // 무시한다. 자동차 라벨은 계열만 고정하고 세부 수단은 유지한다.
        let coreMotionMode: TravelMode? = switch dominantMotion {
        case .walking: .walking
        case .running: .running
        case .cycling: .cycling
        case .automotive: .car
        case .stationary, .unknown: nil
        }
        if let motionMode = coreMotionMode,
           dominantMotionWeight >= 0.4,
           !impossibleModes.contains(motionMode) {
            switch dominantMotion {
            case .walking, .running, .cycling:
                let score = min(1, 0.7 + 0.3 * dominantMotionWeight)
                return MovementInference(
                    mode: motionMode,
                    confidence: ConfidenceLevel(score: score),
                    score: score,
                    evidence: ["iPhone Core Motion \(modeName(motionMode))"]
                )
            case .automotive:
                // 걸음이 계속 늘고 있으면 차량 라벨이 틀린 것이므로
                // 계열을 고정하지 않는다.
                if !pedestrianEvidence {
                    let vehicles: Set<TravelMode> = [
                        .car, .bus, .taxi, .subway, .train, .airplane, .ship,
                    ]
                    candidates = candidates.filter { vehicles.contains($0.key) }
                    if candidates.isEmpty {
                        add(.car, 0.62, "iPhone Core Motion 자동차")
                    }
                }
            case .stationary, .unknown:
                break
            }
        }

        for mode in impossibleModes {
            candidates.removeValue(forKey: mode)
        }
        let rejectedSubway = !hasSubwayAltitudeChange
            && candidates.removeValue(forKey: .subway) != nil
        let routeEnds = resolvedSubwayRoute?.coordinates
        let dwellReadings = altitudeContext.isEmpty ? [] : ordered + altitudeContext.filter { reading in
            !ordered.contains { $0.id == reading.id }
        }
        func stationDwell(_ station: GeoPoint?) -> TimeInterval? {
            guard !dwellReadings.isEmpty, let station else { return nil }
            return SubwayEvidenceGate.stationDwell(readings: dwellReadings, station: station)
        }
        let missingSubwayConditions = SubwayEvidenceGate.missingConditions(.init(
            hasBoardingToAlightingRoute: resolvedSubwayRoute.map(SubwayStationCatalog.isValid) == true,
            sensedStationCount: Set(railStations).count,
            hasAltitudeChange: hasSubwayAltitudeChange,
            transitSpecificSignals: [
                gpsLossRatio >= 0.35, subwayWiFiSignal, stationStopConfirmation, stationStateConfirmation,
                stationAltitudeDrop, userStationRouteConfirmation,
            ].filter { $0 }.count,
            supportingSignals: [repeatedRailMatch, observedLowStepsSignal, watchVibration].filter { $0 }.count,
            boardingDwell: stationDwell(routeEnds?.first),
            alightingDwell: stationDwell(routeEnds?.last)
        ))
        let subwayNotProven = !missingSubwayConditions.isEmpty
            && candidates.removeValue(forKey: .subway) != nil
        if candidates.isEmpty {
            add(
                displacementSpeed > 8.5 ? .car : .cycling,
                0.4,
                displacementNote
            )
        }

        let ranked = candidates.sorted {
            if $0.value.0 != $1.value.0 {
                return $0.value.0 > $1.value.0
            }
            let leftOrder = TravelMode.allCases.firstIndex(of: $0.key) ?? Int.max
            let rightOrder = TravelMode.allCases.firstIndex(of: $1.key) ?? Int.max
            return leftOrder < rightOrder
        }
        let winner = ranked.first
            ?? (.walking, (0.2, ["기본 저신뢰 보행 후보"]))
        let runnerUpScore = ranked.dropFirst().first?.value.0 ?? 0
        let margin = max(0, winner.value.0 - runnerUpScore)
        let score = min(
            1,
            min(1, winner.value.0) * (0.82 + min(0.18, margin))
        )
        let subwayRoute = winner.key == .subway ? resolvedSubwayRoute : nil
        var winnerEvidence = winner.value.1
        if rejectedSubway || stationToStationSubway && !hasSubwayAltitudeChange {
            winnerEvidence.append(Self.noAltitudeChangeEvidence)
        }
        if subwayNotProven, !rejectedSubway {
            winnerEvidence.append("지하철 조건 부족: " + missingSubwayConditions.joined(separator: ", "))
        }
        if let subwayRoute {
            winnerEvidence.append(
                "노선 " + subwayRoute.lineNames.joined(separator: " → ")
            )
            if !subwayRoute.transferStationNames.isEmpty {
                winnerEvidence.append(
                    "환승 " + subwayRoute.transferStationNames.joined(separator: ", ")
                )
            }
        }
        return MovementInference(
            mode: winner.key,
            confidence: ConfidenceLevel(score: score),
            score: score,
            evidence: Array(Set(winnerEvidence)).sorted(),
            subwayRoute: subwayRoute
        )
    }

    private func motionTiePriority(_ motion: MotionKind) -> Int {
        switch motion {
        case .stationary, .unknown: 0
        case .walking: 1
        case .running: 2
        case .cycling: 3
        case .automotive: 4
        }
    }

    private func ratio(
        _ readings: [SensorReading],
        where keyPath: KeyPath<SensorReading, Bool>
    ) -> Double {
        guard !readings.isEmpty else { return 0 }
        return Double(readings.filter { $0[keyPath: keyPath] }.count)
            / Double(readings.count)
    }

    private struct AltitudeRecoveryProfile {
        var dropMeters: Double
        var recoveryMeters: Double
    }

    private func altitudeDropAndRecovery(
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

    private static func windowedRange(_ values: [(Date, Double)]) -> Double {
        var best = 0.0
        var start = 0
        for end in values.indices {
            while values[end].0.timeIntervalSince(values[start].0) > subwayAltitudeWindow { start += 1 }
            let window = values[start...end].map(\.1)
            best = max(best, (window.max() ?? 0) - (window.min() ?? 0))
        }
        return best
    }

    private func maxAltitudeDrop(_ readings: [SensorReading]) -> Double {
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

    private func firstLastDisplacement(_ readings: [SensorReading]) -> Double {
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

    private func stationAltitudeDropSignal(_ readings: [SensorReading]) -> Bool {
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

    private func subwayWiFiEvidence(
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

    private func subwayWiFiFamily(for ssid: String?) -> String? {
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

    private func speedSeries(for readings: [SensorReading]) -> [Double] {
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

    private struct WatchAccelerationSignal {
        var sampleCount: Int
        var standardDeviationG: Double
        var meanJerkGPerSecond: Double
    }

    private func watchAccelerationSignal(
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

    private func modeName(_ mode: TravelMode?) -> String {
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
        case nil: "이동"
        }
    }
}
