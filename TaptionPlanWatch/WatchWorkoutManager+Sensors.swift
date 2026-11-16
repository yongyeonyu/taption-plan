import CoreMotion
import CoreLocation
import HealthKit
import TaptionWatchBehaviorML
import WatchKit
import WidgetKit

extension WatchWorkoutManager {
    func startSensorCollection(
        sessionID: UUID,
        startedAt: Date
    ) {
        stopSensorHardware()
        sensorSessionID = sessionID
        sensorSequence = 0
        accelerometerSum = .zero
        accelerometerCount = 0
        peakAccelerationG = 0
        accelerationMagnitudeMean = 0
        accelerationMagnitudeM2 = 0
        accelerationJerkSum = 0
        previousAccelerationMagnitude = nil
        previousAccelerationSampleTime = nil
        gyroscopeSum = .zero
        gyroscopeCount = 0
        peakRotationRate = 0
        latestGravity = nil
        latestUserAcceleration = nil
        latestRotationRate = nil
        latestAttitude = nil
        latestRelativeAltitudeMeters = nil
        latestPressureKilopascals = nil
        latestStepCount = nil
        latestPedometerDistanceMeters = nil
        latestFloorsAscended = nil
        latestFloorsDescended = nil
        averageHeartRate = nil
        maximumHeartRate = nil
        pendingRoutePoints = []
        motionSamples = []
        nextBehaviorWindowEnd = nil
        lastWindowStepCount = 0
        lastWindowFloorsAscended = nil
        lastWindowFloorsDescended = nil
        lastWindowAltitudeMeters = nil
        lastGyroscopeSample = nil
        pendingBehaviorSegments = []
        behaviorStabilizer.reset()
        sensorSampleCount = 0
        pendingAccelerationSamples = []
        accelerationArchiveStride = 0
        accelerationArchiveSequence = 0

        // 명시적 운동은 실시간 값이 필요하므로 25Hz 라이브 업데이트를 쓴다.
        // 주변 기록은 CMSensorRecorder가 대신 맡는다.
        let updateInterval: TimeInterval = 0.04
        sensorHardwareGeneration &+= 1
        let generation = sensorHardwareGeneration
        didStartSensorHardware = true
        if motionManager.isAccelerometerAvailable
            && !motionManager.isDeviceMotionAvailable {
            motionManager.accelerometerUpdateInterval = updateInterval
            motionManager.startAccelerometerUpdates(
                to: .main
            ) { @Sendable [weak self] data, _ in
                guard let data else { return }
                let value = TaptionWatchSensorVector3(
                    x: data.acceleration.x,
                    y: data.acceleration.y,
                    z: data.acceleration.z
                )
                let timestamp = data.timestamp
                let capturedAt = Date.now
                MainActor.assumeIsolated {
                    guard let self,
                          self.didStartSensorHardware,
                          self.sensorHardwareGeneration == generation,
                          self.sensorSessionID == sessionID else { return }
                    self.recordAccelerometer(
                        value,
                        timestamp: timestamp,
                        capturedAt: capturedAt
                    )
                }
            }
        }
        if motionManager.isGyroAvailable
            && !motionManager.isDeviceMotionAvailable {
            motionManager.gyroUpdateInterval = updateInterval
            motionManager.startGyroUpdates(
                to: .main
            ) { @Sendable [weak self] data, _ in
                guard let data else { return }
                let value = TaptionWatchSensorVector3(
                    x: data.rotationRate.x,
                    y: data.rotationRate.y,
                    z: data.rotationRate.z
                )
                MainActor.assumeIsolated {
                    guard let self,
                          self.didStartSensorHardware,
                          self.sensorHardwareGeneration == generation,
                          self.sensorSessionID == sessionID else { return }
                    self.recordGyroscope(value)
                }
            }
        }
        if motionManager.isDeviceMotionAvailable {
            motionManager.deviceMotionUpdateInterval = updateInterval
            motionManager.startDeviceMotionUpdates(
                to: .main
            ) { @Sendable [weak self] data, _ in
                guard let data else { return }
                let gravity = TaptionWatchSensorVector3(
                    x: data.gravity.x,
                    y: data.gravity.y,
                    z: data.gravity.z
                )
                let acceleration = TaptionWatchSensorVector3(
                    x: data.userAcceleration.x,
                    y: data.userAcceleration.y,
                    z: data.userAcceleration.z
                )
                let totalAcceleration = TaptionWatchSensorVector3(
                    x: data.gravity.x + data.userAcceleration.x,
                    y: data.gravity.y + data.userAcceleration.y,
                    z: data.gravity.z + data.userAcceleration.z
                )
                let rotation = TaptionWatchSensorVector3(
                    x: data.rotationRate.x,
                    y: data.rotationRate.y,
                    z: data.rotationRate.z
                )
                let attitude = TaptionWatchSensorVector3(
                    x: data.attitude.roll,
                    y: data.attitude.pitch,
                    z: data.attitude.yaw
                )
                let timestamp = data.timestamp
                let capturedAt = Date.now
                MainActor.assumeIsolated {
                    guard let self,
                          self.didStartSensorHardware,
                          self.sensorHardwareGeneration == generation,
                          self.sensorSessionID == sessionID else { return }
                    self.latestGravity = gravity
                    self.latestUserAcceleration = acceleration
                    self.latestRotationRate = rotation
                    self.latestAttitude = attitude
                    self.recordAccelerometer(
                        totalAcceleration,
                        timestamp: timestamp,
                        capturedAt: capturedAt
                    )
                    self.recordGyroscope(rotation)
                }
            }
        }
        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(
                to: .main
            ) { @Sendable [weak self] data, _ in
                let altitude = data?.relativeAltitude.doubleValue
                let pressure = data?.pressure.doubleValue
                MainActor.assumeIsolated {
                    guard let self,
                          self.didStartSensorHardware,
                          self.sensorHardwareGeneration == generation,
                          self.sensorSessionID == sessionID else { return }
                    self.latestRelativeAltitudeMeters = altitude
                    self.latestPressureKilopascals = pressure
                }
            }
        }
        if CMPedometer.isStepCountingAvailable() {
            pedometer.startUpdates(from: startedAt) { @Sendable [weak self] data, _ in
                let steps = data?.numberOfSteps.intValue
                let distance = data?.distance?.doubleValue
                let up = data?.floorsAscended?.intValue
                let down = data?.floorsDescended?.intValue
                Task { @MainActor [weak self] in
                    guard let self,
                          self.didStartSensorHardware,
                          self.sensorHardwareGeneration == generation,
                          self.sensorSessionID == sessionID else { return }
                    self.latestStepCount = steps
                    self.latestPedometerDistanceMeters = distance
                    self.latestFloorsAscended = up
                    self.latestFloorsDescended = down
                }
            }
        }
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
        if locationManager.authorizationStatus == .authorizedAlways
            || locationManager.authorizationStatus == .authorizedWhenInUse {
            locationManager.startUpdatingLocation()
        }

        sensorSummaryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self else { break }
                guard self.sensorSessionID == sessionID else { break }
                self.emitSensorSummary(isFinal: false)
            }
        }
        emitSensorSummary(isFinal: false)
    }

    private func recordAccelerometer(
        _ value: TaptionWatchSensorVector3,
        timestamp: TimeInterval,
        capturedAt: Date
    ) {
        accelerometerSum.add(value)
        accelerometerCount += 1
        if accelerometerCount == 1 || accelerometerCount.isMultiple(of: 25) {
            sensorSampleCount = accelerometerCount
        }
        let magnitude = value.magnitude
        peakAccelerationG = max(peakAccelerationG, magnitude)
        let count = Double(accelerometerCount)
        let delta = magnitude - accelerationMagnitudeMean
        accelerationMagnitudeMean += delta / count
        accelerationMagnitudeM2 += delta * (magnitude - accelerationMagnitudeMean)
        if let previousAccelerationMagnitude,
           let previousAccelerationSampleTime {
            let elapsed = max(0.01, timestamp - previousAccelerationSampleTime)
            accelerationJerkSum += abs(magnitude - previousAccelerationMagnitude)
                / elapsed
        }
        previousAccelerationMagnitude = magnitude
        previousAccelerationSampleTime = timestamp
        accelerationArchiveStride += 1
        if accelerationArchiveStride >= 5 {
            accelerationArchiveStride = 0
            accelerationArchiveSequence += 1
            pendingAccelerationSamples.append(
                WatchAccelerationArchiveSample(
                    id: UUID(),
                    capturedAt: capturedAt,
                    acceleration: value,
                    sessionID: sensorSessionID,
                    sequence: accelerationArchiveSequence,
                    isAmbient: false
                )
            )
        }
        motionSamples.append(
            WatchMotionSample(
                capturedAt: capturedAt,
                acceleration: value,
                rotationRate: lastGyroscopeSample,
                gravity: latestGravity
            )
        )
        analyzeBehaviorWindows(at: capturedAt)
    }

    private func recordGyroscope(_ value: TaptionWatchSensorVector3) {
        gyroscopeSum.add(value)
        gyroscopeCount += 1
        peakRotationRate = max(peakRotationRate, value.magnitude)
        lastGyroscopeSample = value
    }

    private func analyzeBehaviorWindows(at capturedAt: Date) {
        if nextBehaviorWindowEnd == nil {
            nextBehaviorWindowEnd = capturedAt
                .addingTimeInterval(WatchBehaviorWindowAnalyzer.windowDuration)
        }
        var advancedWindow = false
        while let windowEnd = nextBehaviorWindowEnd,
              capturedAt >= windowEnd {
            advancedWindow = true
            let windowStart = windowEnd.addingTimeInterval(
                -WatchBehaviorWindowAnalyzer.windowDuration
            )
            let samples = motionSamples.filter {
                $0.capturedAt >= windowStart && $0.capturedAt <= windowEnd
            }
            if let features = WatchBehaviorWindowAnalyzer.features(
                from: samples
            ) {
                let steps = latestStepCount ?? 0
                let floorsUp = latestFloorsAscended
                let floorsDown = latestFloorsDescended
                let altitude = latestRelativeAltitudeMeters
                let stepDelta = max(0, steps - lastWindowStepCount)
                let floorUpDelta = floorsUp.map {
                    max(0, $0 - (lastWindowFloorsAscended ?? $0))
                }
                let floorDownDelta = floorsDown.map {
                    max(0, $0 - (lastWindowFloorsDescended ?? $0))
                }
                let altitudeDelta = altitude.flatMap { current in
                    lastWindowAltitudeMeters.map { current - $0 }
                }
                let speeds = pendingRoutePoints.compactMap(
                    \.speedMetersPerSecond
                ).filter { $0.isFinite && $0 >= 0 }
                let averageSpeed = speeds.isEmpty
                    ? nil
                    : speeds.reduce(0, +) / Double(speeds.count)
                let context = WatchBehaviorInput(
                    workoutKind: workoutKind,
                    duration: features.duration,
                    accelerometerSampleCount: features.sampleCount,
                    accelerometerStandardDeviationG:
                        features.accelerationStandardDeviationG,
                    accelerometerMeanJerkGPerSecond:
                        features.jerkRMSGPerSecond,
                    steps: stepDelta,
                    floorsAscended: floorUpDelta,
                    floorsDescended: floorDownDelta,
                    averageHeartRate: averageHeartRate,
                    gpsAverageSpeedMetersPerSecond: averageSpeed,
                    gpsAvailable: !pendingRoutePoints.isEmpty,
                    gpsLossRatio: pendingRoutePoints.isEmpty ? 1 : 0,
                    altitudeDeltaMeters: altitudeDelta,
                    accelerationBodyRMSG: features.bodyAccelerationRMSG,
                    accelerationZeroCrossingRateHz:
                        features.zeroCrossingRateHz,
                    dominantMotionFrequencyHz:
                        features.dominantFrequencyHz,
                    gyroscopeRMSG: features.gyroscopeRMSGPerSecond,
                    posturePitchRadians: features.posturePitchRadians,
                    postureRollRadians: features.postureRollRadians
                )
                let modelPrediction: WatchBehaviorInference?
#if canImport(CoreML)
                modelPrediction = behaviorModel?.predict(features: features)
#else
                modelPrediction = nil
#endif
                let inference = WatchBehaviorClassifier.classifyWindow(
                    features,
                    context: context,
                    modelPrediction: modelPrediction
                )
                appendBehaviorSegment(
                    inference,
                    startedAt: features.startedAt,
                    endedAt: features.endedAt
                )
                lastWindowStepCount = steps
                lastWindowFloorsAscended = floorsUp
                lastWindowFloorsDescended = floorsDown
                lastWindowAltitudeMeters = altitude
            }
            nextBehaviorWindowEnd = windowEnd.addingTimeInterval(
                WatchBehaviorWindowAnalyzer.strideDuration
            )
        }
        guard advancedWindow else { return }
        let cutoff = (nextBehaviorWindowEnd ?? capturedAt)
            .addingTimeInterval(-WatchBehaviorWindowAnalyzer.windowDuration * 2)
        motionSamples.removeAll { $0.capturedAt < cutoff }
    }

    private func appendBehaviorSegment(
        _ inference: WatchBehaviorInference,
        startedAt: Date,
        endedAt: Date
    ) {
        let stable = behaviorStabilizer.stabilize(inference)
        if let index = pendingBehaviorSegments.indices.last,
           pendingBehaviorSegments[index].behavior == stable.kind,
           startedAt.timeIntervalSince(
               pendingBehaviorSegments[index].endedAt
           ) <= WatchBehaviorWindowAnalyzer.strideDuration * 1.5 {
            pendingBehaviorSegments[index].endedAt = max(
                pendingBehaviorSegments[index].endedAt,
                endedAt
            )
            pendingBehaviorSegments[index].confidenceScore = max(
                pendingBehaviorSegments[index].confidenceScore,
                stable.confidenceScore
            )
            pendingBehaviorSegments[index].evidence = Array(
                Set(pendingBehaviorSegments[index].evidence + stable.evidence)
            ).sorted()
            return
        }
        pendingBehaviorSegments.append(
            WatchBehaviorSegment(
                startedAt: startedAt,
                endedAt: endedAt,
                behavior: stable.kind,
                confidenceScore: stable.confidenceScore,
                evidence: stable.evidence,
                modelVersion: stable.modelVersion
            )
        )
    }

    private func emitSensorSummary(isFinal: Bool) {
        guard let summary = makeSensorSummary(
            at: .now,
            isFinal: isFinal
        ) else {
            return
        }
        onSensorSummary?(summary)
        if let behavior = summary.behavior {
            latestObservation = WatchActivityObservation(
                behavior: behavior,
                confidenceScore: summary.behaviorConfidenceScore ?? 0,
                startedAt: summary.startedAt,
                endedAt: summary.endedAt
            )
        }
        publishMeasurement()
        flushAccelerationArchive(summary: summary)
        pendingRoutePoints.removeAll(keepingCapacity: true)
        pendingBehaviorSegments.removeAll(keepingCapacity: true)
    }

    func stopSensorCollection(
        at endedAt: Date,
        isFinal: Bool
    ) async -> TaptionWatchSensorSummary? {
        guard sensorSessionID != nil else { return nil }
        sensorSummaryTask?.cancel()
        sensorSummaryTask = nil
        stopSensorHardware()
        let summary = makeSensorSummary(at: endedAt, isFinal: isFinal)
        if let summary {
            flushAccelerationArchive(summary: summary)
        } else {
            flushAccelerationArchive(summary: nil)
        }
        let tasks = Array(accelerationFlushTasks.values)
        for task in tasks { await task.value }
        sensorSessionID = nil
        return summary
    }

    func stopSensorHardware() {
        sensorHardwareGeneration &+= 1
        // 한 번도 시작하지 않았다면 클라이언트를 만들지 않는다.
        guard didStartSensorHardware else { return }
        didStartSensorHardware = false
        motionManager.stopAccelerometerUpdates()
        motionManager.stopGyroUpdates()
        motionManager.stopDeviceMotionUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        pedometer.stopUpdates()
        locationManager.stopUpdatingLocation()
    }

    private func flushAccelerationArchive(summary: TaptionWatchSensorSummary?) {
        guard !pendingAccelerationSamples.isEmpty else { return }
        let samples = pendingAccelerationSamples
        pendingAccelerationSamples.removeAll(keepingCapacity: true)
        let archive = accelerationArchive
        guard let first = samples.first, let last = samples.last else { return }
        let chunk = TaptionWatchAccelerationChunk(
            id: first.id,
            sessionID: summary?.sessionID ?? first.sessionID,
            sequence: summary?.sequence ?? last.sequence,
            startedAt: first.capturedAt,
            endedAt: last.capturedAt,
            samples: samples,
            isFinal: summary?.isFinal ?? false
        )
        let taskID = UUID()
        let precedingTask = lastAccelerationFlushTaskID.flatMap {
            accelerationFlushTasks[$0]
        }
        let task = Task { @MainActor [weak self] in
            defer {
                self?.accelerationFlushTasks[taskID] = nil
                if self?.lastAccelerationFlushTaskID == taskID {
                    self?.lastAccelerationFlushTaskID = nil
                }
            }
            await precedingTask?.value
            guard !Task.isCancelled else { return }
            do {
                try await archive.append(samples)
            } catch {
                WatchLaunchDiagnostics.mark(
                    "workout archive append failed \(error.localizedDescription)"
                )
            }
            guard !Task.isCancelled else { return }
            guard let self, let onAccelerationChunk = self.onAccelerationChunk
            else { return }
            await onAccelerationChunk(chunk)
        }
        accelerationFlushTasks[taskID] = task
        lastAccelerationFlushTaskID = taskID
    }

    private func makeSensorSummary(
        at endedAt: Date,
        isFinal: Bool
    ) -> TaptionWatchSensorSummary? {
        guard let sensorSessionID,
              let startedAt,
              let workoutKind else {
            return nil
        }
        sensorSequence += 1
        let routeSpeeds = pendingRoutePoints.compactMap(\.speedMetersPerSecond)
            .filter { $0.isFinite && $0 >= 0 }
        let routeAverageSpeed = routeSpeeds.isEmpty
            ? nil
            : routeSpeeds.reduce(0, +) / Double(routeSpeeds.count)
        let input = WatchBehaviorInput(
            workoutKind: workoutKind,
            duration: endedAt.timeIntervalSince(startedAt),
            accelerometerSampleCount: accelerometerCount,
            accelerometerStandardDeviationG: accelerometerCount > 1
                ? sqrt(
                    max(0, accelerationMagnitudeM2)
                        / Double(accelerometerCount - 1)
                )
                : nil,
            accelerometerMeanJerkGPerSecond: accelerometerCount > 1
                ? accelerationJerkSum / Double(accelerometerCount - 1)
                : nil,
            peakAccelerationG: accelerometerCount > 0
                ? peakAccelerationG
                : nil,
            peakRotationRateRadiansPerSecond: gyroscopeCount > 0
                ? peakRotationRate
                : nil,
            steps: latestStepCount,
            distanceMeters: latestPedometerDistanceMeters
                ?? (distanceMeters > 0 ? distanceMeters : nil),
            floorsAscended: latestFloorsAscended,
            floorsDescended: latestFloorsDescended,
            averageHeartRate: averageHeartRate,
            gpsAverageSpeedMetersPerSecond: routeAverageSpeed,
            gpsAvailable: !pendingRoutePoints.isEmpty,
            gpsLossRatio: pendingRoutePoints.isEmpty ? 1 : 0
        )
        let fallback = WatchBehaviorClassifier.classify(input)
        let behavior = WatchBehaviorClassifier.aggregate(
            pendingBehaviorSegments,
            fallback: fallback
        )
        return TaptionWatchSensorSummary(
            sessionID: sensorSessionID,
            sequence: sensorSequence,
            workoutKind: workoutKind,
            linkedPlanID: linkedPlan?.id,
            linkedPlanTitle: linkedPlan?.title,
            linkedCategoryID: linkedPlan?.categoryID,
            startedAt: startedAt,
            endedAt: max(startedAt, endedAt),
            isFinal: isFinal,
            accelerometerSampleCount: accelerometerCount,
            accelerometerAverageG: accelerometerCount > 0
                ? accelerometerSum.divided(by: Double(accelerometerCount))
                : nil,
            peakAccelerationG: accelerometerCount > 0
                ? peakAccelerationG
                : nil,
            accelerometerStandardDeviationG: accelerometerCount > 1
                ? sqrt(
                    max(0, accelerationMagnitudeM2)
                        / Double(accelerometerCount - 1)
                )
                : nil,
            accelerometerMeanJerkGPerSecond: accelerometerCount > 1
                ? accelerationJerkSum / Double(accelerometerCount - 1)
                : nil,
            gyroscopeSampleCount: gyroscopeCount,
            gyroscopeAverageRadiansPerSecond: gyroscopeCount > 0
                ? gyroscopeSum.divided(by: Double(gyroscopeCount))
                : nil,
            peakRotationRateRadiansPerSecond: gyroscopeCount > 0
                ? peakRotationRate
                : nil,
            gravity: latestGravity,
            userAccelerationG: latestUserAcceleration,
            rotationRateRadiansPerSecond: latestRotationRate,
            attitudeRadians: latestAttitude,
            relativeAltitudeMeters: latestRelativeAltitudeMeters,
            pressureKilopascals: latestPressureKilopascals,
            stepCount: latestStepCount,
            distanceMeters: latestPedometerDistanceMeters
                ?? (distanceMeters > 0 ? distanceMeters : nil),
            floorsAscended: latestFloorsAscended,
            floorsDescended: latestFloorsDescended,
            latestHeartRate: heartRate > 0 ? heartRate : nil,
            averageHeartRate: averageHeartRate,
            maximumHeartRate: maximumHeartRate,
            activeEnergyKilocalories: activeEnergyKilocalories > 0
                ? activeEnergyKilocalories
                : nil,
            routePoints: pendingRoutePoints,
            behavior: behavior.kind,
            behaviorConfidenceScore: behavior.confidenceScore,
            behaviorEvidence: behavior.evidence,
            behaviorModelVersion: behavior.modelVersion,
            behaviorSegments: pendingBehaviorSegments,
            isAmbient: false,
            waterLockEnabled: WKInterfaceDevice.current().isWaterLockEnabled
        )
    }
}
