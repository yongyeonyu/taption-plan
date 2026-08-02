import CoreMotion
import CoreLocation
import Foundation
import HealthKit

@MainActor
final class WatchWorkoutManager: NSObject, ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var heartRate = 0.0
    @Published private(set) var distanceMeters = 0.0
    @Published private(set) var activeEnergyKilocalories = 0.0
    @Published private(set) var sensorSampleCount = 0
    @Published private(set) var latestRelativeAltitudeMeters: Double?
    @Published private(set) var errorMessage: String?

    private let healthStore = HKHealthStore()
    private let motionManager = CMMotionManager()
    private let altimeter = CMAltimeter()
    private let pedometer = CMPedometer()
    private let locationManager = CLLocationManager()
    private let sensorQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.taption.plan.watch-sensors"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private(set) var linkedPlan: TaptionWatchPlanItem?
    private(set) var workoutKind: TaptionWatchWorkoutKind?
    var onSensorSummary: ((TaptionWatchSensorSummary) -> Void)?

    private var sensorSessionID: UUID?
    private var sensorSequence = 0
    private var sensorSummaryTask: Task<Void, Never>?
    private var accelerometerSum = TaptionWatchSensorVector3.zero
    private var accelerometerCount = 0
    private var peakAccelerationG = 0.0
    private var accelerationMagnitudeMean = 0.0
    private var accelerationMagnitudeM2 = 0.0
    private var accelerationJerkSum = 0.0
    private var previousAccelerationMagnitude: Double?
    private var previousAccelerationSampleTime: TimeInterval?
    private var gyroscopeSum = TaptionWatchSensorVector3.zero
    private var gyroscopeCount = 0
    private var peakRotationRate = 0.0
    private var latestGravity: TaptionWatchSensorVector3?
    private var latestUserAcceleration: TaptionWatchSensorVector3?
    private var latestRotationRate: TaptionWatchSensorVector3?
    private var latestAttitude: TaptionWatchSensorVector3?
    private var latestPressureKilopascals: Double?
    private var latestStepCount: Int?
    private var latestPedometerDistanceMeters: Double?
    private var latestFloorsAscended: Int?
    private var latestFloorsDescended: Int?
    private var averageHeartRate: Double?
    private var maximumHeartRate: Double?
    private var pendingRoutePoints: [TaptionWatchLocationPoint] = []
    private var motionSamples: [WatchMotionSample] = []
    private var nextBehaviorWindowEnd: Date?
    private var lastWindowStepCount = 0
    private var lastWindowFloorsAscended: Int?
    private var lastWindowFloorsDescended: Int?
    private var lastWindowAltitudeMeters: Double?
    private var lastGyroscopeSample: TaptionWatchSensorVector3?
    private var pendingBehaviorSegments: [WatchBehaviorSegment] = []
    private var lastBehaviorKind: WatchBehaviorKind?
    private var lastBehaviorConfidence = 0.0

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.activityType = .fitness
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 5
    }

    func dismissError() {
        errorMessage = nil
    }

    func start(
        kind: TaptionWatchWorkoutKind,
        linkedPlan: TaptionWatchPlanItem?,
        sessionID requestedSessionID: UUID? = nil
    ) async -> Bool {
        guard !isActive, HKHealthStore.isHealthDataAvailable() else {
            return false
        }
        do {
            try await requestAuthorization()
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = kind.healthKitActivityType
            configuration.locationType = .outdoor

            let newSession = try HKWorkoutSession(
                healthStore: healthStore,
                configuration: configuration
            )
            let newBuilder = newSession.associatedWorkoutBuilder()
            newBuilder.dataSource = HKLiveWorkoutDataSource(
                healthStore: healthStore,
                workoutConfiguration: configuration
            )
            newSession.delegate = self
            newBuilder.delegate = self

            let start = Date.now
            let sensorSessionID = requestedSessionID ?? UUID()
            session = newSession
            builder = newBuilder
            self.linkedPlan = linkedPlan
            workoutKind = kind
            startedAt = start
            heartRate = 0
            distanceMeters = 0
            activeEnergyKilocalories = 0

            newSession.startActivity(with: start)
            try await newBuilder.beginCollection(at: start)
            var metadata: [String: Any] = [
                TaptionWatchHealthMetadata.sensorSessionID:
                    sensorSessionID.uuidString,
                HKMetadataKeyWorkoutBrandName: "Taption Plan",
            ]
            if let linkedPlan {
                metadata.merge([
                    TaptionWatchHealthMetadata.planID: linkedPlan.id.uuidString,
                    TaptionWatchHealthMetadata.planTitle: linkedPlan.title,
                    TaptionWatchHealthMetadata.categoryID: linkedPlan.categoryID,
                ]) { _, new in new }
            }
            try await newBuilder.addMetadata(metadata)
            isActive = true
            startSensorCollection(
                sessionID: sensorSessionID,
                startedAt: start
            )
            return true
        } catch {
            reset(with: "운동을 시작하지 못했습니다. \(error.localizedDescription)")
            return false
        }
    }

    func stop() async -> TaptionWatchPlanItem? {
        guard let session, let builder else { return nil }
        let linkedPlan = linkedPlan
        let end = Date.now
        if let summary = stopSensorCollection(at: end, isFinal: true) {
            onSensorSummary?(summary)
        }
        session.end()
        do {
            try await builder.endCollection(at: end)
            _ = try await builder.finishWorkout()
            reset()
        } catch {
            reset(with: "운동 저장을 완료하지 못했습니다. \(error.localizedDescription)")
        }
        return linkedPlan
    }

    private func requestAuthorization() async throws {
        guard let heartRate = HKQuantityType.quantityType(
            forIdentifier: .heartRate
        ),
        let walkingRunningDistance = HKQuantityType.quantityType(
            forIdentifier: .distanceWalkingRunning
        ),
        let cyclingDistance = HKQuantityType.quantityType(
            forIdentifier: .distanceCycling
        ),
        let activeEnergy = HKQuantityType.quantityType(
            forIdentifier: .activeEnergyBurned
        ) else {
            return
        }
        let workout = HKObjectType.workoutType()
        var readTypes: Set<HKObjectType> = [
            workout,
            heartRate,
            walkingRunningDistance,
            cyclingDistance,
            activeEnergy,
        ]
        if let stepCount = HKQuantityType.quantityType(
            forIdentifier: .stepCount
        ) {
            readTypes.insert(stepCount)
        }
        if let flightsClimbed = HKQuantityType.quantityType(
            forIdentifier: .flightsClimbed
        ) {
            readTypes.insert(flightsClimbed)
        }
        try await healthStore.requestAuthorization(
            toShare: [workout],
            read: readTypes
        )
    }

    private func updateStatistics(for types: Set<HKSampleType>) {
        guard let builder else { return }
        for type in types {
            guard let quantityType = type as? HKQuantityType,
                  let statistics = builder.statistics(for: quantityType) else {
                continue
            }
            switch quantityType.identifier {
            case HKQuantityTypeIdentifier.heartRate.rawValue:
                let unit = HKUnit.count().unitDivided(by: .minute())
                heartRate = statistics.mostRecentQuantity()?.doubleValue(
                    for: unit
                ) ?? heartRate
                averageHeartRate = statistics.averageQuantity()?.doubleValue(
                    for: unit
                ) ?? averageHeartRate
                maximumHeartRate = statistics.maximumQuantity()?.doubleValue(
                    for: unit
                ) ?? maximumHeartRate
            case HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue,
                 HKQuantityTypeIdentifier.distanceCycling.rawValue:
                distanceMeters = statistics.sumQuantity()?.doubleValue(
                    for: .meter()
                ) ?? distanceMeters
            case HKQuantityTypeIdentifier.activeEnergyBurned.rawValue:
                activeEnergyKilocalories = statistics.sumQuantity()?.doubleValue(
                    for: .kilocalorie()
                ) ?? activeEnergyKilocalories
            default:
                break
            }
        }
    }

    private func reset(with message: String? = nil) {
        if let summary = stopSensorCollection(at: .now, isFinal: true) {
            onSensorSummary?(summary)
        }
        session = nil
        builder = nil
        linkedPlan = nil
        workoutKind = nil
        startedAt = nil
        isActive = false
        sensorSampleCount = 0
        latestRelativeAltitudeMeters = nil
        errorMessage = message
    }

    private func startSensorCollection(
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
        lastBehaviorKind = nil
        lastBehaviorConfidence = 0
        sensorSampleCount = 0

        // Activity-classifier windows need at least 25 Hz.  This is only
        // enabled inside HKWorkoutSession; normal background collection keeps
        // the app's configured low-power interval.
        let updateInterval: TimeInterval = 0.04
        if motionManager.isAccelerometerAvailable {
            motionManager.accelerometerUpdateInterval = updateInterval
            motionManager.startAccelerometerUpdates(
                to: sensorQueue
            ) { [weak self] data, _ in
                guard let data else { return }
                let value = TaptionWatchSensorVector3(
                    x: data.acceleration.x,
                    y: data.acceleration.y,
                    z: data.acceleration.z
                )
                let timestamp = data.timestamp
                let capturedAt = Date.now
                Task { @MainActor [weak self] in
                    self?.recordAccelerometer(
                        value,
                        timestamp: timestamp,
                        capturedAt: capturedAt
                    )
                }
            }
        }
        if motionManager.isGyroAvailable {
            motionManager.gyroUpdateInterval = updateInterval
            motionManager.startGyroUpdates(
                to: sensorQueue
            ) { [weak self] data, _ in
                guard let data else { return }
                let value = TaptionWatchSensorVector3(
                    x: data.rotationRate.x,
                    y: data.rotationRate.y,
                    z: data.rotationRate.z
                )
                Task { @MainActor [weak self] in
                    self?.recordGyroscope(value)
                }
            }
        }
        if motionManager.isDeviceMotionAvailable {
            motionManager.deviceMotionUpdateInterval = updateInterval
            motionManager.startDeviceMotionUpdates(
                to: sensorQueue
            ) { [weak self] data, _ in
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
                Task { @MainActor [weak self] in
                    self?.latestGravity = gravity
                    self?.latestUserAcceleration = acceleration
                    self?.latestRotationRate = rotation
                    self?.latestAttitude = attitude
                }
            }
        }
        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(
                to: sensorQueue
            ) { [weak self] data, _ in
                let altitude = data?.relativeAltitude.doubleValue
                let pressure = data?.pressure.doubleValue
                Task { @MainActor [weak self] in
                    self?.latestRelativeAltitudeMeters = altitude
                    self?.latestPressureKilopascals = pressure
                }
            }
        }
        if CMPedometer.isStepCountingAvailable() {
            pedometer.startUpdates(from: startedAt) { [weak self] data, _ in
                let steps = data?.numberOfSteps.intValue
                let distance = data?.distance?.doubleValue
                let up = data?.floorsAscended?.intValue
                let down = data?.floorsDescended?.intValue
                Task { @MainActor [weak self] in
                    self?.latestStepCount = steps
                    self?.latestPedometerDistanceMeters = distance
                    self?.latestFloorsAscended = up
                    self?.latestFloorsDescended = down
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
        sensorSampleCount = accelerometerCount
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
        while let windowEnd = nextBehaviorWindowEnd,
              capturedAt >= windowEnd {
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
                let inference = WatchBehaviorClassifier.classifyWindow(
                    features,
                    context: context
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
        let cutoff = (nextBehaviorWindowEnd ?? capturedAt)
            .addingTimeInterval(-WatchBehaviorWindowAnalyzer.windowDuration * 2)
        motionSamples.removeAll { $0.capturedAt < cutoff }
    }

    private func appendBehaviorSegment(
        _ inference: WatchBehaviorInference,
        startedAt: Date,
        endedAt: Date
    ) {
        var stable = inference
        if let lastBehaviorKind,
           lastBehaviorKind != inference.kind,
           inference.confidenceScore < lastBehaviorConfidence + 0.08 {
            stable = WatchBehaviorInference(
                kind: lastBehaviorKind,
                confidenceScore: lastBehaviorConfidence,
                evidence: inference.evidence + ["시간적 안정화"],
                modelVersion: inference.modelVersion
            )
        }
        lastBehaviorKind = stable.kind
        lastBehaviorConfidence = stable.confidenceScore
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
        pendingRoutePoints.removeAll(keepingCapacity: true)
        pendingBehaviorSegments.removeAll(keepingCapacity: true)
    }

    private func stopSensorCollection(
        at endedAt: Date,
        isFinal: Bool
    ) -> TaptionWatchSensorSummary? {
        guard sensorSessionID != nil else { return nil }
        let summary = makeSensorSummary(at: endedAt, isFinal: isFinal)
        sensorSummaryTask?.cancel()
        sensorSummaryTask = nil
        stopSensorHardware()
        sensorSessionID = nil
        return summary
    }

    private func stopSensorHardware() {
        motionManager.stopAccelerometerUpdates()
        motionManager.stopGyroUpdates()
        motionManager.stopDeviceMotionUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        pedometer.stopUpdates()
        locationManager.stopUpdatingLocation()
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
            behaviorSegments: pendingBehaviorSegments
        )
    }
}

extension WatchWorkoutManager: CLLocationManagerDelegate {
    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        let points = locations
            .filter {
                $0.horizontalAccuracy >= 0
                    && $0.horizontalAccuracy <= 50
                    && abs($0.timestamp.timeIntervalSinceNow) < 5 * 60
            }
            .map {
                TaptionWatchLocationPoint(
                    id: UUID(),
                    capturedAt: $0.timestamp,
                    latitude: $0.coordinate.latitude,
                    longitude: $0.coordinate.longitude,
                    altitude: $0.altitude,
                    horizontalAccuracy: $0.horizontalAccuracy,
                    verticalAccuracy: $0.verticalAccuracy,
                    speedMetersPerSecond: $0.speed >= 0 ? $0.speed : nil,
                    courseDegrees: $0.course >= 0 ? $0.course : nil
                )
            }
        Task { @MainActor [weak self] in
            guard let self else { return }
            for point in points where !self.pendingRoutePoints.contains(
                where: { $0.capturedAt == point.capturedAt }
            ) {
                self.pendingRoutePoints.append(point)
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(
        _ manager: CLLocationManager
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.isActive else { return }
            if self.locationManager.authorizationStatus == .authorizedAlways
                || self.locationManager.authorizationStatus == .authorizedWhenInUse {
                self.locationManager.startUpdatingLocation()
            }
        }
    }
}

extension WatchWorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {}

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didFailWithError error: any Error
    ) {
        Task { @MainActor [weak self] in
            self?.reset(with: "운동 측정이 중단됐습니다. \(error.localizedDescription)")
        }
    }
}

extension WatchWorkoutManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(
        _ workoutBuilder: HKLiveWorkoutBuilder
    ) {}

    nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        Task { @MainActor [weak self] in
            self?.updateStatistics(for: collectedTypes)
        }
    }
}

private extension TaptionWatchWorkoutKind {
    var healthKitActivityType: HKWorkoutActivityType {
        switch self {
        case .walking: .walking
        case .running: .running
        case .cycling: .cycling
        }
    }
}

private extension TaptionWatchSensorVector3 {
    static let zero = TaptionWatchSensorVector3(x: 0, y: 0, z: 0)

    var magnitude: Double {
        sqrt(x * x + y * y + z * z)
    }

    mutating func add(_ other: TaptionWatchSensorVector3) {
        x += other.x
        y += other.y
        z += other.z
    }

    func divided(by divisor: Double) -> TaptionWatchSensorVector3 {
        guard divisor != 0 else { return .zero }
        return TaptionWatchSensorVector3(
            x: x / divisor,
            y: y / divisor,
            z: z / divisor
        )
    }
}
