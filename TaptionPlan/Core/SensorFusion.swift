import Foundation

struct TravelModeClassifier: Sendable {
    func classify(
        readings: [SensorReading],
        inside requestedSpan: TimeSpan? = nil,
        healthEvidence: [AppleMovementEvidence] = [],
        correctedMode: TravelMode? = nil,
        userTransitLocations: [UserTransitLocation] = []
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

        // A Watch behavior chunk may be the only source when HealthKit has
        // not finished publishing the workout.  Respect explicit transit and
        // vehicle labels before falling back to the broader score fusion.
        let explicitWatchBehavior = ordered
            .reversed()
            .compactMap({ reading in
                reading.behavior.flatMap(WatchBehaviorKind.init(rawValue:))
            })
            .first
        if let explicitWatchBehavior {
            switch explicitWatchBehavior {
            case .subway:
                // Keep the sensor fusion pass alive so altitude/route evidence
                // can confirm or reject the Watch hint below.
                break
            case .publicTransit, .automotive:
                break
            default:
                break
            }
        }

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
        let railRatio = ratio(ordered, where: \.matchesRailRoute)
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
            ?? (railRatio >= 0.25
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
        let railContext = stationRatio >= 0.2
            || railRatio >= 0.25
            || coordinateRailContext
            || stationStateConfirmation
            || userStationRouteConfirmation
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
            && subwayWiFiStreak >= 2
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
                    && railRatio >= 0.25
            )
        let undergroundSignal = gpsLossRatio >= 0.35
            || altitudeDelta <= -2
        let displacementMeters = firstLastDisplacement(ordered)
        let deepUndergroundRecovery = altitudeDropAndRecovery(ordered)
        let altitudeDropMeters = maxAltitudeDrop(ordered)
        let undergroundDescent = altitudeDropMeters >= 8
            || altitudeDelta <= -8
            || gpsLossRatio >= 0.45
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
            railRatio >= 0.25,
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
        let stationToStationSubway = railStations.count >= 2
            && resolvedSubwayRoute != nil
            && railContext
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
        if railRatio >= 0.5 {
            add(.subway, 0.2, "철도 경로 일치")
            add(.train, 0.28, "철도 경로 일치")
        }
        if coordinateRailContext {
            add(.subway, 0.42, "역 좌표 궤적 일치")
            add(.train, 0.12, "철도역 순차 통과")
        }
        if gpsLossRatio >= 0.45 && railContext {
            add(.subway, 0.18, "GPS 약화")
        }
        if altitudeDelta <= -2 && railContext {
            add(.subway, 0.16, "상대고도 하강")
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
        if stationToStationSubway {
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

        // 사용자 등록 역 하나는 역 자체만으로 확정하지 않는다. 독립적인
        // 철도 신호가 하나 이상 붙은 경우에만 자동차 후보보다 먼저 처리한다.
        // 두 역 이상 경로는 위의 노선·역 순서 판정에서 높은 신뢰도로 확정한다.
        if prioritizedSingleUserStation {
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
        if candidates.isEmpty {
            add(
                displacementSpeed > 8.5 ? .car : .cycling,
                0.4,
                displacementNote
            )
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
        let subwayRoute = winner.key == .subway ? resolvedSubwayRoute : nil
        var winnerEvidence = winner.value.1
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
        let points = readings.compactMap(\.point)
        guard let first = points.first, let last = points.last else { return 0 }
        return distanceMeters(first, last)
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

struct FloorEstimator: Sendable {
    var defaultFloorHeightMeters: Double = 3
    /// Timeline segmentation needs a persistent target floor. Two samples
    /// are enough for direct one-off estimates, but three consecutive samples
    /// prevent barometer drift from creating a false floor change.
    var minimumStableSampleCount: Int = 2

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
           let from = firstSystemReading.systemFloor {
            // CLFloor는 실내에서 한두 번 튈 수 있으므로 새 층이 연속해서
            // 확인된 경우에만 전이를 확정한다.
            for index in systemReadings.indices.dropFirst() {
                guard let to = systemReadings[index].systemFloor,
                      to != from else { continue }
                let confirmed = systemReadings[index...].prefix {
                    $0.systemFloor == to
                }.count
                guard confirmed >= minimumStableSampleCount else { continue }
                let previousIndex = systemReadings.index(before: index)
                return FloorTransition(
                    id: UUID(),
                    placeKey: placeKey,
                    fromFloor: from,
                    toFloor: to,
                    relativeAltitudeMeters: Double(to - from)
                        * defaultFloorHeightMeters,
                    span: TimeSpan(
                        start: systemReadings[previousIndex].timestamp,
                        end: systemReadings[index].timestamp
                    ),
                    confidence: .high,
                    evidence: ["시스템 실내 층 정보 \(confirmed)회 연속"]
                )
            }
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
        guard stableSampleCount >= minimumStableSampleCount
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

/// 연속 고도 표본 사이의 급격한 점프를 이상치로 걸러낸다. 실제 층 이동은
/// 다음 표본이 같은 수준을 다시 확인하므로 한 표본 지연 후 수용된다.
struct AltitudeSpikeGate: Sendable {
    static let maximumJumpMeters = 12.0
    static let confirmationCount = 2

    private var lastAcceptedMeters: Double?
    private var pending: (meters: Double, count: Int)?

    mutating func reset() {
        lastAcceptedMeters = nil
        pending = nil
    }

    /// 표본이 사용 가능하면 true. 스파이크로 판정되면 false를 돌려주고
    /// 같은 수준이 연속 확인될 때까지 보류한다.
    mutating func accept(_ meters: Double) -> Bool {
        guard meters.isFinite else { return false }
        guard let last = lastAcceptedMeters else {
            lastAcceptedMeters = meters
            return true
        }
        if abs(meters - last) <= Self.maximumJumpMeters {
            lastAcceptedMeters = meters
            pending = nil
            return true
        }
        if let held = pending,
           abs(held.meters - meters) <= Self.maximumJumpMeters {
            let count = held.count + 1
            if count >= Self.confirmationCount {
                lastAcceptedMeters = meters
                pending = nil
                return true
            }
            pending = (meters, count)
        } else {
            pending = (meters, 1)
        }
        return false
    }
}

/// HealthKit 운동 경로 표본을 기기 표본과 합친다. 우리 앱이 이미 같은 시각의
/// 위치를 남겼다면 중복이므로 버리고, 비어 있는 구간만 채운다.
enum HealthRouteMergeEngine {
    static let minimumSpacingSeconds: TimeInterval = 20

    static func merging(
        _ routeReadings: [SensorReading],
        into existing: [SensorReading]
    ) -> [SensorReading] {
        guard !routeReadings.isEmpty else { return [] }
        let existingTimes = existing
            .filter { $0.point != nil }
            .map(\.timestamp)
            .sorted()
        var accepted: [Date] = []
        var result: [SensorReading] = []
        for reading in routeReadings.sorted(by: {
            $0.timestamp < $1.timestamp
        }) {
            guard !hasNeighbor(reading.timestamp, in: existingTimes),
                  !hasNeighbor(reading.timestamp, in: accepted) else {
                continue
            }
            accepted.append(reading.timestamp)
            result.append(reading)
        }
        return result
    }

    private static func hasNeighbor(
        _ date: Date,
        in sorted: [Date]
    ) -> Bool {
        sorted.contains {
            abs($0.timeIntervalSince(date)) < minimumSpacingSeconds
        }
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
                reading.point != nil
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
        let references: [FloorCalibrationPoint] = {
            if !calibration.referencePoints.isEmpty {
                return calibration.referencePoints
            }
            guard let point = calibration.referencePoint else { return [] }
            return [
                FloorCalibrationPoint(
                    floor: calibration.referenceFloor,
                    point: point,
                    relativeAltitudeMeters:
                        calibration.referenceRelativeAltitudeMeters,
                    pressureKilopascals:
                        calibration.referencePressureKilopascals,
                    altimeterSessionID:
                        calibration.referenceAltimeterSessionID,
                    capturedAt: calibration.capturedAt ?? .now
                )
            ]
        }()
        let candidates = references.compactMap { reference -> CalibratedAltitudeEstimate? in
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
        if references.count > 1 {
            result.evidence.append("\(references.count)개 층 기준 교차 검증")
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
        let candidates = frequentPlaces.filter {
            $0.point != nil && $0.isAutomaticRecordingEnabled
        }
        guard !candidates.isEmpty else { return detectedPlaces }

        return detectedPlaces.map { place in
            guard let point = place.point,
                  let match = nearestMatch(
                    to: point,
                    candidates: candidates
                  ) else {
                return place
            }

            // 짧은 방문은 일반 장소로 남겨 두고, 설정한 체류 시간 이상일
            // 때만 자주가는 곳으로 확정합니다.
            guard place.span.duration
                    >= TimeInterval(match.minimumDwellMinutes * 60) else {
                return place
            }

            var updated = place
            updated.placeKey = match.stablePlaceKey
            updated.displayName = match.name
            updated.buildingName = match.name

            let anchor = readings
                .filter { place.span.contains($0.timestamp) }
                .min { $0.timestamp < $1.timestamp }
            // 층수는 이 관측에서 파생된다. 표본은 7일 뒤 지워지므로 근거가
            // 된 숫자를 기록 옆에 남겨 둔다. 이번 새로고침에 표본이 없다면
            // 이미 적어 둔 근거를 지우지 않는다.
            if let evidence = anchor.flatMap({ FloorEvidence($0) }) {
                updated.floorEvidence = evidence
            }

            // A user-confirmed floor is the building anchor. GPS altitude and
            // barometric altitude drift by several metres while standing in
            // one place, so recalculating from the first sample made a fixed
            // home/company floor jump on every refresh. Real floor changes
            // are handled separately by FloorTimelineEngine after they remain
            // stable across multiple samples.
            if let floor = match.floor {
                // 등록된 기준 층은 날씨·문 개폐·사람 움직임에 따른
                // 기압/GPS drift로 덮지 않는다. 실제 층 이동은 여러 표본을
                // 본 FloorTimelineEngine이 별도로 확정한다.
                updated.floor = floor
                updated.confidence = .high
            } else if let calibration = match.floorCalibration,
                      let estimate = FloorCalibrationEngine().estimate(
                          readings: readings.filter {
                              place.span.contains($0.timestamp)
                          },
                          calibration: calibration
                      ) {
                updated.floor = estimate.floor
                updated.confidence = estimate.confidence
            }
            updated.isConfirmed = true
            return updated
        }
    }

    /// 기준점을 고친 뒤, 이미 저장된 이 장소의 체류를 새 기준으로 다시
    /// 매긴다. 기록이 스스로 지닌 근거를 먼저 쓰고, 그것이 없는 옛 기록은
    /// 7일 보관분과 대표 GPS 고도 순으로 보완한다. 어느 근거도 없을 때만
    /// 있던 층수를 그대로 둔다.
    func reapplyingFloors(
        of place: FrequentPlace,
        to places: [PlaceStay],
        readings: [SensorReading]
    ) -> [PlaceStay] {
        guard let calibration = place.floorCalibration else { return places }
        let key = place.stablePlaceKey
        let ordered = readings.sorted { $0.timestamp < $1.timestamp }
        let engine = FloorCalibrationEngine()
        return places.map { stay in
            guard stay.placeKey == key else { return stay }
            let estimate: CalibratedAltitudeEstimate?
            if let evidence = stay.floorEvidence {
                estimate = engine.estimate(
                    evidence: evidence,
                    at: stay.point ?? place.point,
                    calibration: calibration
                )
            } else if ordered.contains(where: {
                stay.span.contains($0.timestamp)
            }) {
                estimate = engine.estimate(
                    readings: ordered.filter {
                        stay.span.contains($0.timestamp)
                    },
                    calibration: calibration
                )
            } else if let point = stay.point,
                      point.altitude.isFinite {
                // 예전 기록도 대표 GPS 고도는 자체 보관한다. 기압 원본이
                // 만료됐더라도 이 낮은 신뢰도의 근거로 현재 보정값을 다시
                // 적용할 수 있으며, 저장된 좌표와 원본 센서는 바꾸지 않는다.
                estimate = engine.estimate(
                    evidence: FloorEvidence(measuredAt: stay.span.start),
                    at: point,
                    calibration: calibration
                )
            } else {
                estimate = nil
            }
            guard let estimate else { return stay }
            var updated = stay
            updated.floor = estimate.floor
            updated.confidence = estimate.confidence
            return updated
        }
    }

    /// 층 이동 기록도 기준 층 위에 얹혀 있다. 오르내린 층수는 그대로 두고
    /// 출발 층만 새 기준으로 다시 매겨 도착 층까지 함께 옮긴다. 사용자가
    /// 직접 고른 도착 층은 건드리지 않는다.
    func reapplyingFloors(
        of place: FrequentPlace,
        to transitions: [FloorTransition]
    ) -> [FloorTransition] {
        guard let calibration = place.floorCalibration else {
            return transitions
        }
        let key = place.stablePlaceKey
        let engine = FloorCalibrationEngine()
        return transitions.map { transition in
            guard transition.placeKey == key,
                  !transition.isUserConfirmed,
                  let evidence = transition.floorEvidence,
                  let from = transition.fromFloor,
                  let estimate = engine.estimate(
                    evidence: evidence,
                    at: place.point,
                    calibration: calibration
                  ) else {
                return transition
            }
            var updated = transition
            updated.fromFloor = estimate.floor
            updated.toFloor = transition.toFloor.map {
                $0 - from + estimate.floor
            }
            return updated
        }
    }

    /// `applying` 은 확정된 체류의 `placeKey` 를 자주가는 곳의 안정 키로
    /// 바꾼다. 그 키로 장소 종류를 되찾아 정지 구간 문맥 추론에 넘긴다.
    func kindsByPlaceKey(
        _ frequentPlaces: [FrequentPlace]
    ) -> [String: FrequentPlaceKind] {
        frequentPlaces.reduce(into: [:]) { $0[$1.stablePlaceKey] = $1.kind }
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

/// 등록되지 않았는데 반복해서 머문 자리. 앱은 이름을 지어내지 않고, 이미
/// 역지오코딩으로 받아 둔 이름이 있으면 그것만 제안한다. 등록은 사용자가 한다.
struct FrequentPlaceSuggestion: Identifiable, Hashable, Sendable {
    enum Reason: Hashable, Sendable {
        /// 한 주 안에 세 번 이상.
        case weekly
        /// 한 달 안에 열 번 이상.
        case monthly
    }

    var id: String
    var point: GeoPoint
    var suggestedName: String?
    var visitCount: Int
    var firstVisitedAt: Date
    var lastVisitedAt: Date
    var reason: Reason
}

/// 저장된 체류에서 "자주 가는데 등록만 안 한 곳"을 찾는다. 새 위치 수집은
/// 하지 않고 `PlaceDetectionEngine` 이 이미 만들어 둔 체류만 센다.
struct UnregisteredPlaceSuggestionEngine: Sendable {
    /// 한 번의 도착이 한 번의 방문이다. `PlaceDetectionEngine` 이 표본 묶음
    /// 하나를 체류 하나로 이미 줄여 두므로 GPS 표본 수는 세지 않는다.
    /// 층 이동으로 한 체류가 둘로 갈라진 경우와 잠깐 나갔다 곧 돌아온 경우만
    /// 다시 한 번의 방문으로 합친다.
    var sameVisitGap: TimeInterval = 30 * 60
    /// 방문으로 인정할 최소 체류. 체류를 만들 때 쓴 기준을 그대로 따른다.
    var minimumStayDuration: TimeInterval = PlaceDetectionEngine().minimumDwell
    /// 같은 장소로 볼 반경. 체류를 묶을 때 쓴 반경과 같아야 한 자리가 두
    /// 군집으로 갈라지지 않는다.
    var clusterRadiusMeters: Double = PlaceDetectionEngine().radiusMeters
    /// 거절은 건물 단위로 기억한다. 다음 주 중심점이 몇 미터 흔들렸다고
    /// 같은 커피숍을 다시 묻지 않는다.
    var dismissalRadiusMeters = FrequentPlace.sameBuildingRadiusMeters
    var weeklyWindow: TimeInterval = 7 * 86_400
    var weeklyThreshold = 3
    /// 되돌아보는 범위이자 "한 달" 조건의 창. 반년 전에 세 번 갔던 곳을
    /// 이제 와서 묻지 않는다.
    var monthlyWindow: TimeInterval = 30 * 86_400
    var monthlyThreshold = 10

    /// 화면에는 한 번에 하나만 띄운다. 조건을 넘긴 자리가 여럿이면 가장 많이
    /// 간 곳, 그다음 가장 최근에 간 곳을 고른다.
    func suggestion(
        places: [PlaceStay],
        frequentPlaces: [FrequentPlace],
        dismissed: [DismissedPlaceSuggestion],
        now: Date = .now
    ) -> FrequentPlaceSuggestion? {
        suggestions(
            places: places,
            frequentPlaces: frequentPlaces,
            dismissed: dismissed,
            now: now
        )
        .max {
            ($0.visitCount, $0.lastVisitedAt) < ($1.visitCount, $1.lastVisitedAt)
        }
    }

    private func suggestions(
        places: [PlaceStay],
        frequentPlaces: [FrequentPlace],
        dismissed: [DismissedPlaceSuggestion],
        now: Date
    ) -> [FrequentPlaceSuggestion] {
        let cutoff = now.addingTimeInterval(-monthlyWindow)
        let candidates = places
            .filter {
                $0.point != nil
                    && !$0.isWalkingLocation
                    && !$0.isRegisteredFrequentPlace
                    && $0.span.end > cutoff
                    && $0.span.start <= now
            }
            .sorted { $0.span.start < $1.span.start }
        guard !candidates.isEmpty else { return [] }

        return clusters(of: candidates)
            .filter { !isKnown($0, frequentPlaces: frequentPlaces) }
            .filter { !isDismissed($0, dismissed: dismissed) }
            .compactMap(suggestion(from:))
    }

    // MARK: - 군집

    /// 같은 장소라도 방문마다 GPS 평균이 조금씩 달라져 `placeKey` 가 바뀐다.
    /// 그래서 키가 아니라 거리로 묶는다.
    private struct Cluster {
        var stays: [PlaceStay] = []
        var center = GeoPoint(
            latitude: 0,
            longitude: 0,
            altitude: 0,
            horizontalAccuracy: 0,
            verticalAccuracy: 0
        )
    }

    private func clusters(of stays: [PlaceStay]) -> [Cluster] {
        var result: [Cluster] = []
        for stay in stays {
            guard let point = stay.point else { continue }
            let nearest = result.indices
                .map { ($0, distanceMeters(result[$0].center, point)) }
                .filter { $0.1 <= clusterRadiusMeters }
                .min { $0.1 < $1.1 }?
                .0
            if let nearest {
                result[nearest].stays.append(stay)
                result[nearest].center = centroid(of: result[nearest].stays)
            } else {
                result.append(Cluster(stays: [stay], center: point))
            }
        }
        return result
    }

    private func centroid(of stays: [PlaceStay]) -> GeoPoint {
        let points = stays.compactMap(\.point)
        let count = Double(max(points.count, 1))
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

    // MARK: - 제외

    private func isKnown(
        _ cluster: Cluster,
        frequentPlaces: [FrequentPlace]
    ) -> Bool {
        frequentPlaces.contains { place in
            guard let point = place.point else { return false }
            return distanceMeters(point, cluster.center)
                <= max(place.radiusMeters, clusterRadiusMeters)
        }
    }

    private func isDismissed(
        _ cluster: Cluster,
        dismissed: [DismissedPlaceSuggestion]
    ) -> Bool {
        dismissed.contains {
            distanceMeters($0.point, cluster.center) <= dismissalRadiusMeters
        }
    }

    // MARK: - 방문 세기

    private func suggestion(from cluster: Cluster) -> FrequentPlaceSuggestion? {
        let visits = self.visits(in: cluster.stays)
        guard let first = visits.first, let last = visits.last else {
            return nil
        }
        let starts = visits.map(\.start)
        let reason: FrequentPlaceSuggestion.Reason
        if hasWindow(starts, count: weeklyThreshold, within: weeklyWindow) {
            reason = .weekly
        } else if hasWindow(
            starts,
            count: monthlyThreshold,
            within: monthlyWindow
        ) {
            reason = .monthly
        } else {
            return nil
        }
        return FrequentPlaceSuggestion(
            id: String(
                format: "suggested-%.4f,%.4f",
                cluster.center.latitude,
                cluster.center.longitude
            ),
            point: cluster.center,
            suggestedName: suggestedName(in: cluster.stays),
            visitCount: visits.count,
            firstVisitedAt: first.start,
            lastVisitedAt: last.end,
            reason: reason
        )
    }

    private func visits(in stays: [PlaceStay]) -> [TimeSpan] {
        var merged: [TimeSpan] = []
        for stay in stays.sorted(by: { $0.span.start < $1.span.start }) {
            if let last = merged.last,
               stay.span.start.timeIntervalSince(last.end) <= sameVisitGap {
                merged[merged.count - 1] = TimeSpan(
                    start: last.start,
                    end: max(last.end, stay.span.end)
                )
            } else {
                merged.append(stay.span)
            }
        }
        return merged.filter { $0.duration >= minimumStayDuration }
    }

    /// 정렬된 시각에서 `count` 번이 `window` 안에 들어가는 구간이 있는지 본다.
    private func hasWindow(
        _ times: [Date],
        count: Int,
        within window: TimeInterval
    ) -> Bool {
        guard count > 0 else { return true }
        guard times.count >= count else { return false }
        for index in 0...(times.count - count)
        where times[index + count - 1].timeIntervalSince(times[index])
            <= window {
            return true
        }
        return false
    }

    // MARK: - 이름

    /// 이름은 지어내지 않는다. 역지오코딩이 이미 붙여 준 이름만 쓰고, 자동
    /// 생성 자리표시자는 이름으로 치지 않는다.
    private func suggestedName(in stays: [PlaceStay]) -> String? {
        var counts: [String: Int] = [:]
        for stay in stays where !Self.isPlaceholderName(stay.displayName) {
            counts[stay.displayName, default: 0] += 1
        }
        return counts
            .sorted {
                $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
            }
            .first?
            .key
    }

    static func isPlaceholderName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            || trimmed == "자동 감지 장소"
            || trimmed == "확인된 위치"
            || trimmed.hasPrefix("장소 · ")
    }
}

struct FloorTimelineEngine: Sendable {
    var estimator = FloorEstimator(minimumStableSampleCount: 3)
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
            guard var transition = estimator.estimate(
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

            // 이동의 출발 층은 이 체류의 기준 층이다. 그 기준을 만든 근거를
            // 함께 남겨야 나중에 기준을 고쳤을 때 출발·도착 층이 따라온다.
            transition.floorEvidence = place.floorEvidence
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
                place.floorEvidence = place.floorEvidence?
                    .offset(by: toFloor - fromFloor)
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
        // 근거를 잰 자리는 체류가 시작된 앞 조각이다. 뒤 조각은 그보다
        // 오르내린 만큼 위에 있다.
        after.floorEvidence = place.floorEvidence?
            .offset(by: toFloor - fromFloor)
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
                $0.trackingKind == .walking
                    && $0.point != nil
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
                    || reading.timestamp.timeIntervalSince(first.timestamp)
                        > maximumGap
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
                floor: stableFloor(in: group),
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
        correctedModes: [String: TravelMode] = [:],
        userTransitLocations: [UserTransitLocation] = []
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
                correctedMode: correctedModes[signature],
                userTransitLocations: userTransitLocations
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
                isConfirmed: correctedModes[signature] != nil,
                subwayRoute: inference.subwayRoute
            )
        }
    }

    private func pathDistance(_ points: [GeoPoint]) -> Double {
        zip(points, points.dropFirst()).reduce(0) {
            $0 + distanceMeters($1.0, $1.1)
        }
    }
}

/// 지도 보강값과 Core Motion 라벨이 비어 있던 과거 기록에서도 원본 GPS가
/// 철도역을 순서대로 통과했다면 이동 세그먼트를 복원한다. 원본 표본은 바꾸지
/// 않고, 파생 구간만 만들어 자동차 조각과 `unknown` 공백을 대체한다.
enum SubwayTravelSegmentEngine {
    /// 배터리 절약 프로필은 15분 간격으로 표본을 남긴다. 예약 실행의
    /// 지연까지 감안해 한 번의 표본 공백은 18분까지 같은 이동으로 잇는다.
    static let defaultMaximumReadingGap: TimeInterval = 18 * 60

    static func segments(
        from readings: [SensorReading],
        maximumReadingGap: TimeInterval = defaultMaximumReadingGap,
        userTransitLocations: [UserTransitLocation] = []
    ) -> [TravelSegment] {
        let maximumGap = maximumReadingGap.isFinite
            ? max(0, maximumReadingGap)
            : defaultMaximumReadingGap
        return inferSegments(
            from: groups(from: readings, maximumGap: maximumGap),
            userTransitLocations: userTransitLocations
        )
    }

    /// Prefer the movement windows already found between known places. A
    /// whole-day coordinate pass can join morning and evening commutes and
    /// then choose an unrelated rail path, even though each individual move
    /// contains enough station evidence.
    static func segments(
        from readings: [SensorReading],
        within candidateSpans: [TimeSpan],
        maximumReadingGap: TimeInterval = defaultMaximumReadingGap,
        userTransitLocations: [UserTransitLocation] = []
    ) -> [TravelSegment] {
        guard !candidateSpans.isEmpty else {
            return segments(
                from: readings,
                maximumReadingGap: maximumReadingGap,
                userTransitLocations: userTransitLocations
            )
        }
        let maximumGap = maximumReadingGap.isFinite
            ? max(0, maximumReadingGap)
            : defaultMaximumReadingGap
        let candidateGroups = candidateSpans.flatMap { span -> [[SensorReading]] in
            let context = TimeSpan(
                start: span.start.addingTimeInterval(-10 * 60),
                end: span.end.addingTimeInterval(10 * 60)
            )
            return groups(
                from: readings.filter { context.contains($0.timestamp) },
                maximumGap: maximumGap
            )
        }
        return inferSegments(
            from: candidateGroups,
            userTransitLocations: userTransitLocations
        )
            .filter { segment in
                candidateSpans.contains { span in
                    segment.span.intersection(with: span) != nil
                }
            }
    }

    private static func inferSegments(
        from groups: [[SensorReading]],
        userTransitLocations: [UserTransitLocation]
    ) -> [TravelSegment] {
        var result: [TravelSegment] = []
        for group in groups {
            let stationJourney = SubwayStationCatalog.stationJourney(
                from: group
            )
            let strictTrajectory = SubwayStationCatalog.coordinateTrajectory(
                from: group
            )
            let hasRailConfirmation = !group.isEmpty
                && Double(group.filter(\.matchesRailRoute).count)
                    / Double(group.count) >= 0.25
            let trajectory = strictTrajectory
                ?? (hasRailConfirmation
                    ? SubwayStationCatalog.sparseEndpointTrajectory(from: group)
                    : nil)
            guard let span = stationJourney?.span ?? trajectory?.span else {
                continue
            }
            let contextSpan = TimeSpan(
                start: span.start.addingTimeInterval(-2 * 60),
                end: span.end.addingTimeInterval(2 * 60)
            )
            let context = group.filter { contextSpan.contains($0.timestamp) }
            let inference = TravelModeClassifier().classify(
                readings: context,
                inside: span,
                userTransitLocations: userTransitLocations
            )
            guard inference.mode == .subway else { continue }
            guard let route = inference.subwayRoute
                ?? stationJourney?.route
                ?? trajectory?.route else {
                continue
            }
            let sparseEndpointEvidence = trajectory?.isSparseEndpointTrajectory == true
                ? ["철도 지도 신호·출발역·도착역 복원"]
                : []
            let stationStateEvidence = stationJourney?.evidence ?? []
            let routeSourceEvidence = trajectory == nil
                ? ["역 체류 상태로 지하철 구간 확정"]
                : ["원본 GPS 철도 궤적 복원"]
            result.append(TravelSegment(
                mode: .subway,
                span: span,
                distanceMeters: pathDistance(route.coordinates),
                confidence: stationJourney?.isConfirmed == true
                    ? .high
                    : (trajectory?.isSparseEndpointTrajectory == true
                        ? .medium
                        : .high),
                evidence: Array(
                    Set(
                        inference.evidence
                            + sparseEndpointEvidence
                            + stationStateEvidence
                            + routeSourceEvidence
                    )
                ).sorted(),
                subwayRoute: route
            ))
        }
        return result
    }

    private static func groups(
        from readings: [SensorReading],
        maximumGap: TimeInterval
    ) -> [[SensorReading]] {
        var result: [[SensorReading]] = []
        for reading in readings.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard var current = result.popLast() else {
                result.append([reading])
                continue
            }
            if let previous = current.last,
               reading.timestamp.timeIntervalSince(previous.timestamp) <= maximumGap {
                current.append(reading)
                result.append(current)
            } else {
                result.append(current)
                result.append([reading])
            }
        }
        return result
    }

    private static func pathDistance(_ points: [GeoPoint]) -> Double {
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
        healthEvidence: [AppleMovementEvidence] = [],
        readings: [SensorReading] = [],
        preservedSubwaySegments: [TravelSegment] = [],
        userTransitLocations: [UserTransitLocation] = []
    ) -> [TravelSegment] {
        let candidateSpans = gpsSegments.map(\.span)
        let detectedSubwaySegments = SubwayTravelSegmentEngine
            .segments(
                from: readings,
                within: candidateSpans,
                userTransitLocations: userTransitLocations
            )
        let trajectorySubwaySegments = stabilizedSubwaySegments(
            detected: detectedSubwaySegments,
            preserved: preservedSubwaySegments
        )
            .map { segment in
                guard let matched = gpsSegments
                    .filter({ overlappingEnough($0.span, segment.span) })
                    .max(by: {
                        overlapDuration($0.span, segment.span)
                            < overlapDuration($1.span, segment.span)
                    }) else { return segment }
                var value = segment
                value.fromPlaceID = matched.fromPlaceID
                value.toPlaceID = matched.toPlaceID
                if matched.span.duration <= segment.span.duration + 30 * 60 {
                    value.span = TimeSpan(
                        start: min(matched.span.start, segment.span.start),
                        end: max(matched.span.end, segment.span.end)
                    )
                }
                return value
            }
        let primarySegments = gpsSegments.filter { gps in
            !trajectorySubwaySegments.contains {
                subwayDisplaces($0, gps)
            }
        } + trajectorySubwaySegments
        let watchSegments = healthEvidence
            .filter {
                $0.source == .appleWatch
                    && $0.kind == .workout
                    && $0.workoutMode != nil
                    && $0.span.duration >= 60
            }
            .filter { workout in
                !primarySegments.contains {
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
                !primarySegments.contains {
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
                // 구간 안의 실제 표본을 함께 넘겨야 분류기가 속도를 볼 수 있다.
                // 모션 라벨만 주면 차량 이동도 보행으로 남는다.
                let inside = readings.filter {
                    activity.span.contains($0.timestamp)
                }
                let context = inside.isEmpty
                    ? [
                        SensorReading(
                            timestamp: activity.span.start,
                            motion: activity.motion,
                            motionConfidence: activity.confidence,
                            gpsAvailable: false
                        ),
                    ]
                    : inside
                let inference = TravelModeClassifier().classify(
                    readings: context,
                    inside: activity.span,
                    healthEvidence: healthEvidence,
                    userTransitLocations: userTransitLocations
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
                evidence: Array(Set(evidence)).sorted(),
                subwayRoute: inference.subwayRoute
            )
        }

        return (primarySegments + watchSegments + motionSegments)
            .sorted { $0.span.start < $1.span.start }
    }

    private static func stabilizedSubwaySegments(
        detected: [TravelSegment],
        preserved: [TravelSegment]
    ) -> [TravelSegment] {
        var result = detected
        for segment in preserved where segment.mode == .subway {
            guard let route = segment.subwayRoute,
                  segment.confidence == .high,
                  SubwayStationCatalog.isValid(route) else {
                continue
            }
            guard let index = result.firstIndex(where: {
                overlappingEnough($0.span, segment.span)
            }) else {
                result.append(segment)
                continue
            }
            result[index] = preferredSubwaySegment(
                result[index],
                over: segment
            )
        }
        return result
    }

    /// 확인된 지하철 구간은 GPS·Core Motion의 자동차 후보보다 우선한다.
    /// 두 구간이 같은 시각을 조금이라도 공유하는 경우에도 역 순서·환승·
    /// 정차 패턴으로 확정된 지하철을 자동차가 덮어쓰지 않게 한다.
    private static func subwayDisplaces(
        _ subway: TravelSegment,
        _ candidate: TravelSegment
    ) -> Bool {
        guard subway.mode == .subway,
              subway.confidence == .high,
              let route = subway.subwayRoute,
              SubwayStationCatalog.isValid(route) else {
            return overlappingEnough(candidate.span, subway.span)
        }
        let overlap = overlapDuration(candidate.span, subway.span)
        guard overlap > 0 else { return false }
        let shorter = max(
            1,
            min(candidate.span.duration, subway.span.duration)
        )
        return overlap / shorter >= 0.2
    }

    private static func preferredSubwaySegment(
        _ lhs: TravelSegment,
        over rhs: TravelSegment
    ) -> TravelSegment {
        let lhsStops = lhs.subwayRoute?.stops.count ?? 0
        let rhsStops = rhs.subwayRoute?.stops.count ?? 0
        let preferred: TravelSegment
        if lhsStops != rhsStops {
            preferred = lhsStops > rhsStops ? lhs : rhs
        } else if lhs.confidence != rhs.confidence {
            preferred = lhs.confidence == .high ? lhs : rhs
        } else {
            preferred = lhs.span.duration >= rhs.span.duration ? lhs : rhs
        }
        var value = preferred
        value.span = TimeSpan(
            start: min(lhs.span.start, rhs.span.start),
            end: max(lhs.span.end, rhs.span.end)
        )
        value.evidence = Array(Set(lhs.evidence + rhs.evidence)).sorted()
        value.isConfirmed = lhs.isConfirmed || rhs.isConfirmed
        value.fromPlaceID = lhs.fromPlaceID ?? rhs.fromPlaceID
        value.toPlaceID = lhs.toPlaceID ?? rhs.toPlaceID
        value.distanceMeters = max(lhs.distanceMeters, rhs.distanceMeters)
        value.subwayRoute = preferred.subwayRoute
            ?? lhs.subwayRoute
            ?? rhs.subwayRoute
        return value
    }

    private static func overlappingEnough(
        _ lhs: TimeSpan,
        _ rhs: TimeSpan
    ) -> Bool {
        let shorter = max(1, min(lhs.duration, rhs.duration))
        return overlapDuration(lhs, rhs) / shorter >= 0.5
    }

    private static func overlapDuration(
        _ lhs: TimeSpan,
        _ rhs: TimeSpan
    ) -> TimeInterval {
        lhs.intersection(with: rhs)?.duration ?? 0
    }

    /// Core Motion이 자동차로 본 구간은 최종 결과에서도 동력 이동으로 남긴다.
    /// 분류기 내부 점수 융합이 자전거·보행을 만들어 내는 일이 있어, 기록
    /// 상세와 시간표가 서로 다른 수단을 보여주는 문제를 여기서 끊는다.
    /// 걸음이 실제로 늘어난 구간은 라벨이 틀린 것이므로 건드리지 않는다.
    static func enforcingMotionFamily(
        _ segments: [TravelSegment],
        activities: [MotionActivityRecord],
        readings: [SensorReading]
    ) -> [TravelSegment] {
        let pedestrianModes: Set<TravelMode> = [.walking, .running, .cycling]
        return segments.map { segment in
            guard pedestrianModes.contains(segment.mode) else { return segment }
            let automotive = activities
                .filter { $0.motion == .automotive }
                .compactMap { $0.span.intersection(with: segment.span)?.duration }
                .reduce(0, +)
            guard automotive >= segment.span.duration * 0.6,
                  segment.span.duration >= 120 else {
                return segment
            }
            let steps = readings
                .filter { segment.span.contains($0.timestamp) }
                .compactMap(\.stepCount)
            let stepDelta = (steps.max() ?? 0) - (steps.min() ?? 0)
            let minutes = max(1, segment.span.duration / 60)
            guard Double(stepDelta) / minutes < 20 else { return segment }
            var value = segment
            value.mode = .car
            value.evidence = Array(
                Set(value.evidence + ["iPhone Core Motion 자동차"])
            ).sorted()
            return value
        }
    }

    /// 같은 시각에 두 개 이상의 이동이 겹치면 시간표가 여러 줄로 쪼개져
    /// 보인다. 신뢰도가 높고 긴 구간을 남기고, 나머지는 잘라내거나 버린다.
    static func resolvingOverlaps(
        _ segments: [TravelSegment]
    ) -> [TravelSegment] {
        let ordered = segments.sorted {
            if $0.span.start == $1.span.start {
                return $0.span.duration > $1.span.duration
            }
            return $0.span.start < $1.span.start
        }
        var result: [TravelSegment] = []
        for segment in ordered {
            guard let last = result.last,
                  last.span.intersection(with: segment.span) != nil else {
                result.append(segment)
                continue
            }
            let keepsExisting = confidenceRank(last.confidence)
                > confidenceRank(segment.confidence)
                || (confidenceRank(last.confidence)
                    == confidenceRank(segment.confidence)
                    && last.span.duration >= segment.span.duration)
            if keepsExisting {
                // 뒤쪽만 남겨 이어 붙일 수 있으면 잘라서 유지한다.
                guard segment.span.end.timeIntervalSince(last.span.end) >= 60
                else { continue }
                var trimmed = segment
                trimmed.span = TimeSpan(
                    start: last.span.end,
                    end: segment.span.end
                )
                let retained = trimmed.span.duration
                    / max(1, segment.span.duration)
                trimmed.distanceMeters = segment.distanceMeters * retained
                result.append(trimmed)
            } else {
                guard last.span.end.timeIntervalSince(segment.span.start) < 60
                        || last.span.duration < 60 else {
                    var trimmedLast = last
                    trimmedLast.span = TimeSpan(
                        start: last.span.start,
                        end: segment.span.start
                    )
                    let retained = trimmedLast.span.duration
                        / max(1, last.span.duration)
                    trimmedLast.distanceMeters = last.distanceMeters * retained
                    result[result.count - 1] = trimmedLast
                    result.append(segment)
                    continue
                }
                result[result.count - 1] = segment
            }
        }
        return result
    }

    /// 듀티사이클 샘플링이 만든 같은 모드의 이동 조각을 하나로 잇는다.
    /// 조각 사이에 체류가 감지되어 있으면 실제로 멈춘 것이므로 잇지 않는다.
    static func coalescingTravel(
        _ segments: [TravelSegment],
        stays: [PlaceStay],
        maximumGap: TimeInterval
    ) -> [TravelSegment] {
        var result: [TravelSegment] = []
        for segment in segments.sorted(by: { $0.span.start < $1.span.start }) {
            guard var last = result.last,
                  last.mode == segment.mode,
                  segment.span.start.timeIntervalSince(last.span.end)
                      <= maximumGap,
                  !stays.contains(where: { stay in
                      let gap = TimeSpan(
                          start: last.span.end,
                          end: segment.span.start
                      )
                      let overlap = stay.span.intersection(with: gap)
                      return (overlap?.duration ?? 0) >= 180
                  }) else {
                result.append(segment)
                continue
            }
            last.span = TimeSpan(
                start: last.span.start,
                end: max(last.span.end, segment.span.end)
            )
            last.distanceMeters += segment.distanceMeters
            if confidenceRank(segment.confidence)
                > confidenceRank(last.confidence) {
                last.confidence = segment.confidence
            }
            last.evidence = Array(Set(last.evidence + segment.evidence))
                .sorted()
            last.isConfirmed = last.isConfirmed || segment.isConfirmed
            last.toPlaceID = segment.toPlaceID ?? last.toPlaceID
            last.subwayRoute = last.subwayRoute ?? segment.subwayRoute
            result[result.count - 1] = last
        }
        return result
    }

    private static func confidenceRank(_ level: ConfidenceLevel) -> Int {
        switch level {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }

    static func replacingHealthKitActuals(
        existing: [ActualRecord],
        with fresh: [ActualRecord],
        inside span: TimeSpan
    ) -> [ActualRecord] {
        var seen = Set<UUID>()
        let uniqueFresh = fresh.filter {
            ($0.source == .healthKit || $0.source == .appleWatch)
                && seen.insert($0.id).inserted
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
        linkedPlan: PlanRecord?,
        atHome: Bool = false
    ) -> [ActualRecord] {
        if summary.isAmbient == true {
            return upsertingAmbientActivity(
                summary,
                into: existing,
                atHome: atHome
            )
        }
        let previous = existing.first {
            $0.id == summary.sessionID
                && ($0.source == .healthKit || $0.source == .appleWatch)
        }
        let segments = summary.behaviorSegments ?? []
        let planID = linkedPlan?.id ?? summary.linkedPlanID ?? previous?.planID
        let behaviorTitle = summary.behavior?.title
            ?? "Apple Watch \(summary.workoutKind.title)"
        var evidence = summary.behaviorEvidence ?? []
        if evidence.isEmpty {
            evidence = ["Apple Watch 센서 청크"]
        }
        evidence.append(AutomaticRecordTimelineEngine.watchWorkoutEvidence)
        if summary.latestHeartRate != nil {
            evidence.append("심박수")
        }
        if summary.stepCount != nil {
            evidence.append("걸음·거리")
        }
        if !segments.isEmpty {
            let segmentIDs = Set(segments.map(\.id))
            let kept = existing.filter { actual in
                guard actual.source == .appleWatch else { return true }
                if actual.id == summary.sessionID { return false }
                guard actual.sensorChunkID == summary.sessionID else {
                    return true
                }
                return !segmentIDs.contains(actual.id)
            }
            let records = segments.map { segment in
                let categoryID: String = {
                    if segment.behavior.isMovement { return "movement" }
                    if segment.behavior == .sleep { return "sleep" }
                    return linkedPlan?.categoryID == "sleep"
                        || summary.linkedCategoryID == "sleep"
                        ? "sleep"
                        : "activity"
                }()
                let title = linkedPlan?.title
                    ?? summary.linkedPlanTitle
                    ?? segment.behavior.title
                let segmentEvidence = Array(
                    Set(evidence + segment.evidence + ["2.56초 IMU 창"])
                ).sorted()
                let previousSegment = existing.first { $0.id == segment.id }
                return ActualRecord(
                    id: segment.id,
                    planID: planID,
                    title: title,
                    categoryID: categoryID,
                    startedAt: segment.startedAt,
                    endedAt: segment.endedAt,
                    source: .appleWatch,
                    confidence: ConfidenceLevel(
                        score: segment.confidenceScore
                    ),
                    createdAt: previousSegment?.createdAt
                        ?? segment.startedAt,
                    behavior: segment.behavior.rawValue,
                    evidence: segmentEvidence,
                    sensorChunkID: summary.sessionID,
                    modelVersion: segment.modelVersion
                )
            }
            return (kept + records).sorted {
                $0.startedAt < $1.startedAt
            }
        }

        // Keep the existing window records when a final short chunk has no
        // complete 2.56-second window yet.
        if existing.contains(where: {
            $0.source == .appleWatch
                && $0.sensorChunkID == summary.sessionID
                && $0.id != summary.sessionID
        }) {
            return existing.sorted { $0.startedAt < $1.startedAt }
        }
        let title = linkedPlan?.title
            ?? summary.linkedPlanTitle
            ?? behaviorTitle
        let categoryID: String = {
            if summary.behavior?.isMovement == true { return "movement" }
            if summary.behavior == .sleep { return "sleep" }
            return linkedPlan?.categoryID == "sleep"
                || summary.linkedCategoryID == "sleep"
                ? "sleep"
                : "activity"
        }()
        let confidence = summary.behaviorConfidenceScore.map {
            ConfidenceLevel(score: $0)
        } ?? (summary.accelerometerSampleCount > 0 ? .high : .medium)
        let record = ActualRecord(
            id: summary.sessionID,
            planID: planID,
            title: title,
            categoryID: categoryID,
            startedAt: summary.startedAt,
            endedAt: max(summary.startedAt, summary.endedAt),
            source: .appleWatch,
            confidence: confidence,
            createdAt: previous?.createdAt ?? summary.startedAt,
            behavior: summary.behavior?.rawValue,
            evidence: Array(Set(evidence)).sorted(),
            sensorChunkID: summary.sessionID,
            modelVersion: summary.behaviorModelVersion
                ?? WatchBehaviorClassifier.rulesVersion
        )
        return (
            existing.filter { $0.id != summary.sessionID }
                + [record]
        ).sorted { $0.startedAt < $1.startedAt }
    }

    private static func upsertingAmbientActivity(
        _ summary: TaptionWatchSensorSummary,
        into existing: [ActualRecord],
        atHome: Bool
    ) -> [ActualRecord] {
        let previous = existing.first {
            $0.id == summary.sessionID && $0.source == .appleWatch
        }
        guard atHome, sustainedMotion(summary) else {
            return existing.sorted { $0.startedAt < $1.startedAt }
        }
        if var confirmed = previous, confirmed.manuallyCorrected {
            confirmed.endedAt = max(
                confirmed.endedAt ?? confirmed.startedAt,
                summary.endedAt
            )
            return (
                existing.filter { $0.id != summary.sessionID } + [confirmed]
            ).sorted { $0.startedAt < $1.startedAt }
        }

        let behavior: WatchBehaviorKind = switch summary.behavior {
        case .showering, .brushingTeeth, .eating, .typing, .housework:
            summary.behavior ?? .housework
        default:
            .housework
        }

        var evidence = summary.behaviorEvidence ?? []
        evidence.append("Apple Watch 가속도 원시 기록")
        evidence.append("집 위치 내 지속 움직임")
        if let standardDeviation = summary.accelerometerStandardDeviationG {
            evidence.append(String(format: "가속도 변동 %.2fg", standardDeviation))
        }
        let record = ActualRecord(
            id: summary.sessionID,
            planID: nil,
            routineID: nil,
            title: behavior.title,
            categoryID: behavior == .sleep ? "sleep" : "activity",
            startedAt: previous?.startedAt ?? summary.startedAt,
            endedAt: max(previous?.endedAt ?? summary.startedAt, summary.endedAt),
            source: .appleWatch,
            confidence: summary.behaviorConfidenceScore.map {
                ConfidenceLevel(score: max(0.55, $0))
            } ?? .medium,
            createdAt: previous?.createdAt ?? summary.startedAt,
            behavior: behavior.rawValue,
            evidence: Array(Set(evidence)).sorted(),
            sensorChunkID: summary.sessionID,
            modelVersion: summary.behaviorModelVersion
                ?? WatchBehaviorClassifier.rulesVersion
        )
        return (
            existing.filter { $0.id != summary.sessionID }
                + [record]
        ).sorted { $0.startedAt < $1.startedAt }
    }

    /// 집안일 판정과 정지 구간 문맥 추론이 같은 기준을 쓰도록 공개한다.
    static func sustainedMotion(
        _ summary: TaptionWatchSensorSummary
    ) -> Bool {
        let duration = summary.endedAt.timeIntervalSince(summary.startedAt)
        guard duration >= 20, summary.accelerometerSampleCount >= 40 else {
            return false
        }
        let acceleration = max(
            summary.accelerometerStandardDeviationG ?? 0,
            summary.accelerometerMeanJerkGPerSecond ?? 0
        )
        let behaviorIsMotion = summary.behaviorSegments?.contains {
            switch $0.behavior {
            case .stationary, .standing, .sitting, .lying, .sleep, .unknown:
                false
            default:
                true
            }
        } ?? false
        return acceleration >= 0.018 || behaviorIsMotion
    }
}

/// Apple Watch가 없는 경우에만 충전 중인 iPhone의 무활동을 수면 후보로 쓴다.
/// 원본 센서와 앱 사용 기록은 그대로 두고, 한 시간 이상 이어진 구간만
/// 수정 불가 파생 기록으로 만든다.
enum ChargingInactivitySleepEngine {
    static let modelVersion = "charging-inactivity-sleep-v1"
    static let minimumDuration: TimeInterval = 60 * 60

    static func records(
        readings: [SensorReading],
        actuals: [ActualRecord],
        inside span: TimeSpan,
        watchAvailable: Bool,
        maximumSampleGap: TimeInterval,
        asOf: Date = .now
    ) -> [ActualRecord] {
        guard !watchAvailable else { return [] }
        let observed = TimeSpan(start: span.start, end: min(span.end, asOf))
        guard observed.duration >= minimumDuration else { return [] }
        let samples = readings
            .filter { observed.contains($0.timestamp) && isInactiveCharging($0) }
            .sorted { $0.timestamp < $1.timestamp }
        guard samples.count >= 3 else { return [] }

        let allowedGap = max(20 * 60, maximumSampleGap)
        var runs: [[SensorReading]] = []
        for sample in samples {
            if let last = runs.last?.last,
               sample.timestamp.timeIntervalSince(last.timestamp) <= allowedGap {
                runs[runs.count - 1].append(sample)
            } else {
                runs.append([sample])
            }
        }
        let blockers = actuals.compactMap { actual -> TimeSpan? in
            guard actual.source == .appUsage
                    || AutomaticRecordTimelineEngine.isSleep(actual)
                    || AutomaticRecordTimelineEngine.isConfirmedWorkout(actual)
                    || ActualRecordCategoryResolver.categoryID(for: actual)
                        == "movement" else {
                return nil
            }
            return actual.span(asOf: asOf).intersection(with: observed)
        }

        return runs.flatMap { run -> [TimeSpan] in
            guard run.count >= 3,
                  let first = run.first?.timestamp,
                  let last = run.last?.timestamp,
                  last.timeIntervalSince(first) >= minimumDuration else {
                return []
            }
            return ActualIntervalMergeEngine.subtracting(
                blockers,
                from: TimeSpan(start: first, end: last)
            ).filter { $0.duration >= minimumDuration }
        }.map { value in
            ActualRecord(
                id: stableID(value),
                planID: nil,
                title: "수면",
                categoryID: "sleep",
                startedAt: value.start,
                endedAt: value.end,
                source: .motion,
                confidence: .medium,
                createdAt: value.end,
                behavior: "charging-inactivity-sleep",
                evidence: ["iPhone 충전 중", "가속도·걸음·앱 사용 없음", "1시간 이상 지속"],
                modelVersion: modelVersion
            )
        }
    }

    private static func isInactiveCharging(_ reading: SensorReading) -> Bool {
        guard reading.powerState?.isCharging == true,
              (reading.stepCount ?? 0) <= 2 else { return false }
        if reading.motion == .stationary { return true }
        guard reading.motion == .unknown,
              let summary = reading.deviceMotionSummary,
              summary.sampleCount >= 2 else { return false }
        return summary.userAccelerationStandardDeviationG <= 0.01
            && summary.meanRotationRateRadiansPerSecond <= 0.03
    }

    private static func stableID(_ span: TimeSpan) -> UUID {
        let key = "\(modelVersion)|\(Int(span.start.timeIntervalSince1970))|\(Int(span.end.timeIntervalSince1970))"
        var hash: UInt64 = 14_695_981_039_346_656_037
        var bytes = [UInt8](repeating: 0, count: 16)
        for byte in key.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        for index in bytes.indices {
            hash = (hash ^ UInt64(index + 1)) &* 1_099_511_628_211
            bytes[index] = UInt8(truncatingIfNeeded: hash >> ((index % 8) * 8))
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

enum PhoneSleepWakePhase: String, Codable, Hashable, Sendable {
    case awake
    case sleepExpected
    case sleeping
    case wakeExpected
}

struct PhoneSleepWakeStatus: Equatable, Sendable {
    var phase: PhoneSleepWakePhase
    var expectedAt: Date?
    var sleepStartedAt: Date?
    var charging: Bool
}

/// Infers sleep and wake transitions from iPhone-only observations. A sleep
/// candidate needs five minutes of inactivity while the display is dark/off;
/// the candidate is confirmed after one hour (or thirty minutes when charging)
/// and starts at the expected-sleep timestamp. A wake candidate follows the
/// same explicit one-hour confirmation and is cancelled when the phone settles
/// again, allowing an interrupted sleep to continue.
enum PhoneSleepWakeEngine {
    static let modelVersion = "iphone-sleep-wake-v1"
    static let inactivityDuration: TimeInterval = 5 * 60
    static let confirmationDuration: TimeInterval = 60 * 60
    static let chargingConfirmationDuration: TimeInterval = 30 * 60
    static let wakeConfirmationDuration: TimeInterval = 60 * 60
    static let darkBrightness = 0.25
    static let brightBrightness = 0.60

    static func status(
        readings: [SensorReading],
        maximumSampleGap: TimeInterval = 20 * 60,
        asOf: Date = .now
    ) -> PhoneSleepWakeStatus {
        let ordered = readings
            .filter { $0.timestamp <= asOf }
            .sorted { $0.timestamp < $1.timestamp }
        var state = InferenceState()
        for (index, reading) in ordered.enumerated() {
            let previous = index > 0 ? ordered[index - 1] : nil
            advance(&state, reading: reading, previous: previous, maximumSampleGap: maximumSampleGap)
        }
        return state.status
    }

    static func records(
        readings: [SensorReading],
        actuals: [ActualRecord],
        inside span: TimeSpan,
        watchAvailable: Bool,
        maximumSampleGap: TimeInterval,
        asOf: Date = .now
    ) -> [ActualRecord] {
        guard !watchAvailable else { return [] }
        let observed = readings
            .filter { span.contains($0.timestamp) && $0.timestamp <= asOf }
            .sorted { $0.timestamp < $1.timestamp }
        guard observed.count >= 2 else { return [] }

        let blockers = actuals.compactMap { actual -> TimeSpan? in
            guard actual.source == .appUsage
                    || AutomaticRecordTimelineEngine.isSleep(actual)
                    || ActualRecordCategoryResolver.categoryID(for: actual) == "movement" else {
                return nil
            }
            return actual.span(asOf: asOf).intersection(with: span)
        }
        var state = InferenceState()
        var sleepSpans: [TimeSpan] = []
        var previous: SensorReading?
        for reading in observed {
            if let previous,
               reading.timestamp.timeIntervalSince(previous.timestamp) > maximumSampleGap {
                state.sleepCandidateStart = nil
                state.wakeCandidateStart = nil
            }
            let wasSleeping = state.sleepStartedAt
            advance(
                &state,
                reading: reading,
                previous: previous,
                maximumSampleGap: maximumSampleGap,
                blocked: blockers.contains { $0.contains(reading.timestamp) }
            )
            if let started = wasSleeping,
               state.sleepStartedAt == nil,
               let wakeExpected = state.lastWakeExpectedAt,
               wakeExpected > started {
                sleepSpans.append(TimeSpan(start: started, end: wakeExpected))
                state.lastWakeExpectedAt = nil
            }
            previous = reading
        }
        if let started = state.sleepStartedAt,
           let last = observed.last?.timestamp,
           last > started {
            sleepSpans.append(TimeSpan(start: started, end: min(last, asOf)))
        }

        return sleepSpans
            .filter { $0.duration >= chargingConfirmationDuration }
            .map { span in
                ActualRecord(
                    id: stableID(for: span),
                    planID: nil,
                    title: "수면",
                    categoryID: "sleep",
                    startedAt: span.start,
                    endedAt: span.end,
                    source: .motion,
                    confidence: .medium,
                    createdAt: span.end,
                    behavior: "iphone-sleep",
                    evidence: [
                        "iPhone 가속도·걸음 무활동",
                        "화면 꺼짐·어두움",
                        "수면 예상 1시간 확인",
                    ],
                    modelVersion: modelVersion
                )
            }
    }

    private struct InferenceState {
        var sleepCandidateStart: Date?
        var sleepExpectedAt: Date?
        var sleepStartedAt: Date?
        var sleepCharging = false
        var wakeCandidateStart: Date?
        var lastWakeExpectedAt: Date?

        var status: PhoneSleepWakeStatus {
            if sleepStartedAt != nil {
                return PhoneSleepWakeStatus(
                    phase: wakeCandidateStart == nil ? .sleeping : .wakeExpected,
                    expectedAt: wakeCandidateStart,
                    sleepStartedAt: sleepStartedAt,
                    charging: sleepCharging
                )
            }
            return PhoneSleepWakeStatus(
                phase: sleepExpectedAt == nil ? .awake : .sleepExpected,
                expectedAt: sleepExpectedAt,
                sleepStartedAt: nil,
                charging: sleepCharging
            )
        }
    }

    private static func advance(
        _ state: inout InferenceState,
        reading: SensorReading,
        previous: SensorReading?,
        maximumSampleGap: TimeInterval,
        blocked: Bool = false
    ) {
        if let previous,
           reading.timestamp.timeIntervalSince(previous.timestamp) > maximumSampleGap {
            state.sleepCandidateStart = nil
            state.wakeCandidateStart = nil
        }

        if state.sleepStartedAt != nil {
            if isWakeSignal(reading) {
                state.wakeCandidateStart = state.wakeCandidateStart ?? reading.timestamp
                state.lastWakeExpectedAt = state.wakeCandidateStart
                if reading.timestamp.timeIntervalSince(state.wakeCandidateStart ?? reading.timestamp)
                    >= wakeConfirmationDuration {
                    state.sleepStartedAt = nil
                    state.sleepExpectedAt = nil
                    state.sleepCandidateStart = nil
                    state.sleepCharging = false
                    state.wakeCandidateStart = nil
                }
            } else if isSleepSignal(reading) || blocked {
                // A brief awakening that settles before confirmation is part
                // of the same sleep session; a later movement can start a new
                // wake candidate.
                state.wakeCandidateStart = nil
                state.lastWakeExpectedAt = nil
            }
            return
        }

        guard !blocked, isSleepSignal(reading) else {
            state.sleepCandidateStart = nil
            state.sleepExpectedAt = nil
            state.sleepCharging = false
            return
        }
        let candidateStart = state.sleepCandidateStart ?? reading.timestamp
        state.sleepCandidateStart = candidateStart
        let expectedAt = candidateStart.addingTimeInterval(inactivityDuration)
        guard reading.timestamp >= expectedAt else { return }
        if state.sleepExpectedAt == nil {
            state.sleepExpectedAt = expectedAt
            state.sleepCharging = reading.powerState?.isCharging == true
        }
        let confirmation = state.sleepCharging
            ? chargingConfirmationDuration
            : confirmationDuration
        guard reading.timestamp.timeIntervalSince(expectedAt) >= confirmation else {
            return
        }
        state.sleepStartedAt = expectedAt
        state.wakeCandidateStart = nil
    }

    private static func isSleepSignal(_ reading: SensorReading) -> Bool {
        let inactive: Bool
        switch reading.motion {
        case .stationary: inactive = true
        case .unknown:
            let summary = reading.deviceMotionSummary
            inactive = (reading.stepCount ?? 0) <= 2
                && (summary == nil
                    || (summary?.userAccelerationStandardDeviationG ?? 1) <= 0.01
                    && (summary?.meanRotationRateRadiansPerSecond ?? 1) <= 0.03)
        default: inactive = false
        }
        let screenOff = reading.screenIsOn == false
        let dark = reading.screenBrightness.map { $0 <= darkBrightness } ?? false
        return inactive && screenOff && dark
    }

    private static func isWakeSignal(_ reading: SensorReading) -> Bool {
        reading.motion.isMovement
            || reading.stepCount.map { $0 > 0 } == true
            || reading.screenIsOn == true
            || reading.screenBrightness.map { $0 >= brightBrightness } == true
    }

    private static func stableID(for span: TimeSpan) -> UUID {
        let key = "(modelVersion)|(Int(span.start.timeIntervalSince1970))|(Int(span.end.timeIntervalSince1970))"
        var hash: UInt64 = 14_695_981_039_346_656_037
        var bytes = [UInt8](repeating: 0, count: 16)
        for byte in key.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        for index in bytes.indices {
            hash = (hash ^ UInt64(index + 1)) &* 1_099_511_628_211
            bytes[index] = UInt8(truncatingIfNeeded: hash >> ((index % 8) * 8))
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
            bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

/// Turns the iPhone's passive Core Motion intervals into immutable activity
/// records. A HealthKit workout or an explicit tracking session wins when it
/// covers the same interval, so the activity lane never shows two copies of
/// one workout.
enum MotionActivityActualEngine {
    static func records(
        from activities: [MotionActivityRecord],
        existing: [ActualRecord],
        inside: TimeSpan,
        minimumDuration: TimeInterval = 30
    ) -> [ActualRecord] {
        merged(activities, inside: inside)
            .filter { $0.span.duration >= minimumDuration }
            .compactMap { activity in
                guard let title = activity.motion.activityTitle else {
                    return nil
                }
                let covered = existing.contains { actual in
                    guard isCompetingAutomaticRecord(
                              actual,
                              against: activity.motion
                          ),
                          let overlap = actual.span(asOf: inside.end)
                              .intersection(with: activity.span) else {
                        return false
                    }
                    return overlap.duration >= min(
                        activity.span.duration * 0.5,
                        30
                    )
                }
                guard !covered else { return nil }
                return ActualRecord(
                    id: stableID(for: activity),
                    planID: nil,
                    routineID: nil,
                    title: title,
                    categoryID: activity.motion.isMovement
                        ? "movement"
                        : "activity",
                    startedAt: activity.span.start,
                    endedAt: activity.span.end,
                    source: .motion,
                    confidence: activity.confidence,
                    createdAt: activity.span.start,
                    behavior: activity.motion.rawValue,
                    evidence: [
                        "iPhone Core Motion",
                        "행동 구간 \(Int(activity.span.duration))초",
                    ],
                    modelVersion: "iphone-core-motion-v1"
                )
            }
    }

    private static func merged(
        _ activities: [MotionActivityRecord],
        inside: TimeSpan
    ) -> [MotionActivityRecord] {
        let clipped = activities.compactMap { activity -> MotionActivityRecord? in
            guard let span = activity.span.intersection(with: inside),
                  activity.motion != .unknown else { return nil }
            return MotionActivityRecord(
                id: activity.id,
                span: span,
                motion: activity.motion,
                confidence: activity.confidence
            )
        }.sorted { $0.span.start < $1.span.start }

        var result: [MotionActivityRecord] = []
        for activity in clipped {
            guard var last = result.last,
                  last.motion == activity.motion,
                  activity.span.start.timeIntervalSince(last.span.end) <= 30 else {
                result.append(activity)
                continue
            }
            last.span.end = max(last.span.end, activity.span.end)
            last.confidence = stronger(last.confidence, activity.confidence)
            result[result.count - 1] = last
        }
        return result
    }

    private static func isCompetingAutomaticRecord(
        _ actual: ActualRecord,
        against motion: MotionKind
    ) -> Bool {
        guard actual.source == .healthKit
                || actual.source == .appleWatch
                || actual.source == .location else {
            return false
        }
        // 장소 문맥 기록이 덮은 구간은 "정지·휴식" 으로 다시 만들지 않는다.
        // 대신 같은 시간에 걷기·달리기가 잡혔다면 그 기록은 남긴다.
        if actual.source == .location,
           let behavior = actual.behavior,
           StationaryContextKind(rawValue: behavior) != nil {
            return motion == .stationary
        }
        return actual.categoryID == "exercise"
            || actual.categoryID == "activity"
            || actual.title.localizedCaseInsensitiveContains("걷")
            || actual.title.localizedCaseInsensitiveContains("달리")
            || actual.title.localizedCaseInsensitiveContains("자전거")
            || actual.title.localizedCaseInsensitiveContains("러닝")
    }

    private static func stronger(
        _ lhs: ConfidenceLevel,
        _ rhs: ConfidenceLevel
    ) -> ConfidenceLevel {
        let rank: [ConfidenceLevel: Int] = [.low: 0, .medium: 1, .high: 2]
        return (rank[lhs] ?? 0) >= (rank[rhs] ?? 0) ? lhs : rhs
    }

    private static func stableID(for activity: MotionActivityRecord) -> UUID {
        let key = [
            activity.motion.rawValue,
            String(Int(activity.span.start.timeIntervalSinceReferenceDate.rounded())),
            String(Int(activity.span.end.timeIntervalSinceReferenceDate.rounded()))
        ].joined(separator: "|")
        var hash: UInt64 = 14_695_981_039_346_656_037
        var bytes = [UInt8](repeating: 0, count: 16)
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        for index in bytes.indices {
            hash ^= UInt64(index + 1) * 0x9E37_79B9
            hash = hash &* 1_099_511_628_211
            bytes[index] = UInt8(truncatingIfNeeded: hash >> ((index % 8) * 8))
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
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
