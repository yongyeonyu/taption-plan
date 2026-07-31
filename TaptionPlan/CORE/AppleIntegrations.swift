import AVFoundation
import CoreLocation
import CoreMotion
import EventKit
import Foundation
import HealthKit
import Photos
import UIKit
import UserNotifications
import WeatherKit

// MARK: - Calendar

@MainActor
final class AppleCalendarService {
    private let eventStore: EKEventStore

    init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
    }

    func permissionState() -> PermissionState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined:
            return .notDetermined
        case .denied, .restricted, .writeOnly:
            return .denied
        case .fullAccess, .authorized:
            return .authorized
        @unknown default:
            return .unavailable
        }
    }

    func requestFullAccess() async throws -> Bool {
        try await eventStore.requestFullAccessToEvents()
    }

    func calendars() -> [(id: String, title: String)] {
        eventStore.calendars(for: .event)
            .map { ($0.calendarIdentifier, $0.title) }
            .sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
    }

    func events(
        in span: TimeSpan,
        selectedCalendarIDs: Set<String>
    ) -> [CalendarRecord] {
        let calendars = eventStore.calendars(for: .event).filter {
            selectedCalendarIDs.isEmpty
                || selectedCalendarIDs.contains($0.calendarIdentifier)
        }
        let predicate = eventStore.predicateForEvents(
            withStart: span.start,
            end: span.end,
            calendars: calendars
        )
        return eventStore.events(matching: predicate).map { event in
            CalendarRecord(
                id: event.eventIdentifier ?? UUID().uuidString,
                calendarID: event.calendar.calendarIdentifier,
                title: event.title ?? "제목 없는 일정",
                span: TimeSpan(start: event.startDate, end: event.endDate),
                isAllDay: event.isAllDay,
                calendarTitle: event.calendar.title,
                calendarColorHex: Self.hex(event.calendar.cgColor)
            )
        }
    }

    func addPlan(
        _ plan: PlanRecord,
        to calendarID: String? = nil
    ) throws -> String {
        let event = EKEvent(eventStore: eventStore)
        event.title = plan.title
        event.startDate = plan.span.start
        event.endDate = plan.span.end
        event.calendar = calendarID.flatMap { id in
            eventStore.calendars(for: .event).first {
                $0.calendarIdentifier == id
            }
        } ?? eventStore.defaultCalendarForNewEvents
        try eventStore.save(event, span: .thisEvent, commit: true)
        return event.eventIdentifier
    }

    private static func hex(_ color: CGColor) -> String? {
        guard let components = color.components else { return nil }
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        if components.count >= 3 {
            red = components[0]
            green = components[1]
            blue = components[2]
        } else if let gray = components.first {
            red = gray
            green = gray
            blue = gray
        } else {
            return nil
        }
        return String(
            format: "#%02X%02X%02X",
            Int(red * 255),
            Int(green * 255),
            Int(blue * 255)
        )
    }
}

// MARK: - Photos

enum PhotoServiceError: Error {
    case imageUnavailable
    case requestCancelled
}

final class ApplePhotoLibraryService: @unchecked Sendable {
    private let imageManager: PHImageManager

    init(imageManager: PHImageManager = .default()) {
        self.imageManager = imageManager
    }

    func permissionState() -> PermissionState {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .notDetermined:
            return .notDetermined
        case .denied, .restricted:
            return .denied
        case .limited:
            return .limited
        case .authorized:
            return .authorized
        @unknown default:
            return .unavailable
        }
    }

    func requestAccess() async -> PermissionState {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        switch status {
        case .notDetermined:
            return .notDetermined
        case .denied, .restricted:
            return .denied
        case .limited:
            return .limited
        case .authorized:
            return .authorized
        @unknown default:
            return .unavailable
        }
    }

    func moments(in span: TimeSpan) -> [PhotoMoment] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate <= %@",
            span.start as NSDate,
            span.end as NSDate
        )
        options.sortDescriptors = [
            NSSortDescriptor(key: "creationDate", ascending: true)
        ]
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var moments: [PhotoMoment] = []
        result.enumerateObjects { asset, _, _ in
            guard let date = asset.creationDate else { return }
            moments.append(
                PhotoMoment(
                    id: asset.localIdentifier,
                    capturedAt: date,
                    pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight,
                    isFavorite: asset.isFavorite,
                    isHiddenFromTimeline: asset.isHidden,
                    linkedPlanID: nil,
                    linkedPlaceID: nil
                )
            )
        }
        return moments
    }

    func thumbnailJPEG(
        localIdentifier: String,
        size: CGSize,
        quality: CGFloat = 0.8
    ) async throws -> Data {
        let assets = PHAsset.fetchAssets(
            withLocalIdentifiers: [localIdentifier],
            options: nil
        )
        guard let asset = assets.firstObject else {
            throw PhotoServiceError.imageUnavailable
        }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true

        return try await withCheckedThrowingContinuation { continuation in
            imageManager.requestImage(
                for: asset,
                targetSize: size,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                if (info?[PHImageCancelledKey] as? Bool) == true {
                    continuation.resume(throwing: PhotoServiceError.requestCancelled)
                    return
                }
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                    return
                }
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true {
                    return
                }
                guard let data = image?.jpegData(compressionQuality: quality) else {
                    continuation.resume(throwing: PhotoServiceError.imageUnavailable)
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }
}

// MARK: - Health and Apple Watch data mirrored to iPhone

final class AppleHealthService: @unchecked Sendable {
    private let store: HKHealthStore
    private let sleepEngine: SleepAnalysisEngine

    init(
        store: HKHealthStore = HKHealthStore(),
        sleepEngine: SleepAnalysisEngine = SleepAnalysisEngine()
    ) {
        self.store = store
        self.sleepEngine = sleepEngine
    }

    func permissionState() -> PermissionState {
        HKHealthStore.isHealthDataAvailable() ? .notDetermined : .unavailable
    }

    func requestReadAccess() async throws -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        let readTypes = Set(readTypes())
        return try await withCheckedThrowingContinuation { continuation in
            store.requestAuthorization(toShare: [], read: readTypes) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: success)
                }
            }
        }
    }

    func authorizationRequestState() async throws -> PermissionState {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        let readTypes = Set(readTypes())
        return try await withCheckedThrowingContinuation { continuation in
            store.getRequestStatusForAuthorization(
                toShare: [],
                read: readTypes
            ) { status, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                switch status {
                case .shouldRequest:
                    continuation.resume(returning: .notDetermined)
                case .unnecessary:
                    continuation.resume(returning: .authorized)
                case .unknown:
                    continuation.resume(returning: .notDetermined)
                @unknown default:
                    continuation.resume(returning: .unavailable)
                }
            }
        }
    }

    func actuals(in span: TimeSpan) async throws -> [ActualRecord] {
        async let workouts = workoutActuals(in: span)
        async let sleeps = sleepActuals(in: span)
        return try await workouts + sleeps
    }

    func sleepSegments(in span: TimeSpan) async throws -> [SleepSegment] {
        guard let type = HKObjectType.categoryType(
            forIdentifier: .sleepAnalysis
        ) else {
            return []
        }
        let samples = try await samples(type: type, span: span)
        return samples.compactMap { sample in
            guard let category = sample as? HKCategorySample,
                  let healthStage = HKCategoryValueSleepAnalysis(
                    rawValue: category.value
                  ),
                  let stage = healthStage.taptionStage,
                  let overlap = TimeSpan(
                    start: category.startDate,
                    end: category.endDate
                  ).intersection(with: span) else {
                return nil
            }
            return SleepSegment(
                id: category.uuid,
                stage: stage,
                span: overlap,
                sourceName: category.sourceRevision.source.name,
                sourceBundleIdentifier: category.sourceRevision.source.bundleIdentifier,
                deviceName: category.device?.name,
                timeZoneIdentifier: category.metadata?[HKMetadataKeyTimeZone] as? String,
                isUserEntered: category.metadata?[HKMetadataKeyWasUserEntered] as? Bool ?? false
            )
        }
    }

    func sleepSessions(in span: TimeSpan) async throws -> [SleepSession] {
        sleepEngine.sessions(
            from: try await sleepSegments(in: span),
            inside: span
        )
    }

    func healthDetails(in span: TimeSpan) async throws -> [HealthActual] {
        async let workouts = workoutDetails(in: span)
        async let sleeps = sleepDetails(in: span)
        return try await workouts + sleeps
    }

    private func workoutActuals(in span: TimeSpan) async throws -> [ActualRecord] {
        try await workoutDetails(in: span).map { detail in
            ActualRecord(
                id: detail.id,
                planID: nil,
                title: detail.kind,
                categoryID: "exercise",
                startedAt: detail.span.start,
                endedAt: detail.span.end,
                source: .healthKit,
                confidence: .high
            )
        }
    }

    private func sleepActuals(in span: TimeSpan) async throws -> [ActualRecord] {
        try await sleepSessions(in: span).map { session in
            ActualRecord(
                id: session.id,
                planID: nil,
                title: "수면",
                categoryID: "sleep",
                startedAt: session.span.start,
                endedAt: session.span.end,
                source: .healthKit,
                confidence: .high
            )
        }
    }

    private func workoutDetails(in span: TimeSpan) async throws -> [HealthActual] {
        let type = HKObjectType.workoutType()
        let samples = try await samples(type: type, span: span)
        return samples.compactMap { sample in
            guard let workout = sample as? HKWorkout else { return nil }
            let distanceType = HKQuantityType.quantityType(
                forIdentifier: workout.workoutActivityType == .cycling
                    ? .distanceCycling
                    : .distanceWalkingRunning
            )
            let energyType = HKQuantityType.quantityType(
                forIdentifier: .activeEnergyBurned
            )
            return HealthActual(
                id: UUID(uuidString: workout.uuid.uuidString) ?? UUID(),
                kind: workout.workoutActivityType.displayName,
                span: TimeSpan(start: workout.startDate, end: workout.endDate),
                duration: workout.duration,
                distanceMeters: distanceType
                    .flatMap { workout.statistics(for: $0)?.sumQuantity() }
                    .map { $0.doubleValue(for: .meter()) },
                energyKilocalories: energyType
                    .flatMap { workout.statistics(for: $0)?.sumQuantity() }
                    .map { $0.doubleValue(for: .kilocalorie()) },
                sourceName: workout.sourceRevision.source.name
            )
        }
    }

    private func sleepDetails(in span: TimeSpan) async throws -> [HealthActual] {
        try await sleepSessions(in: span).map { session in
            return HealthActual(
                id: session.id,
                kind: "수면",
                span: session.span,
                duration: session.asleepDuration,
                distanceMeters: nil,
                energyKilocalories: nil,
                sourceName: session.sourceNames.joined(separator: ", ")
            )
        }
    }

    private func samples(
        type: HKSampleType,
        span: TimeSpan
    ) async throws -> [HKSample] {
        let predicate = HKQuery.predicateForSamples(
            withStart: span.start,
            end: span.end,
            options: []
        )
        let sort = NSSortDescriptor(
            key: HKSampleSortIdentifierStartDate,
            ascending: true
        )
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples ?? [])
                }
            }
            store.execute(query)
        }
    }

    private func readTypes() -> [HKObjectType] {
        [
            HKObjectType.workoutType(),
            HKObjectType.categoryType(forIdentifier: .sleepAnalysis),
            HKObjectType.quantityType(forIdentifier: .stepCount),
            HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning),
            HKObjectType.quantityType(forIdentifier: .flightsClimbed)
        ].compactMap { $0 }
    }
}

private extension HKCategoryValueSleepAnalysis {
    var taptionStage: SleepStage? {
        switch self {
        case .inBed: .inBed
        case .awake: .awake
        case .asleepCore: .core
        case .asleepDeep: .deep
        case .asleepREM: .rem
        case .asleepUnspecified: .asleepUnspecified
        @unknown default: nil
        }
    }
}

private extension HKWorkoutActivityType {
    var displayName: String {
        switch self {
        case .running: "러닝"
        case .walking: "걷기"
        case .cycling: "자전거"
        case .swimming: "수영"
        case .traditionalStrengthTraining, .functionalStrengthTraining: "근력운동"
        default: "운동"
        }
    }
}

// MARK: - Weather

actor AppleWeatherContextService {
    private let service = WeatherKit.WeatherService.shared

    func context(
        latitude: Double,
        longitude: Double,
        at date: Date = .now
    ) async throws -> WeatherContext {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        let (current, hourly) = try await service.weather(
            for: location,
            including: .current,
            .hourly
        )
        let closestHour = hourly.forecast.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }
        return WeatherContext(
            observedAt: date,
            condition: String(describing: current.condition),
            symbolName: current.symbolName,
            temperatureCelsius: current.temperature.converted(to: .celsius).value,
            precipitationChance: closestHour?.precipitationChance
        )
    }
}

// MARK: - Live sensor collection

@MainActor
final class AppleSensorCollector: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    private let activityManager = CMMotionActivityManager()
    private let deviceMotionManager = CMMotionManager()
    private let altimeter = CMAltimeter()
    private let pedometer = CMPedometer()

    private var continuation: AsyncStream<SensorReading>.Continuation?
    private var configuration: SensorCollectionConfiguration = .standard
    private var isCollecting = false
    private var lastEmissionAt: Date?
    private var latestLocation: CLLocation?
    private var latestMotion: MotionKind = .unknown
    private var latestMotionConfidence: ConfidenceLevel = .low
    private var latestRelativeAltitude: Double?
    private var latestFloorsAscended: Int?
    private var latestFloorsDescended: Int?
    private var latestStepCount: Int?
    private var latestWalkingRunningDistance: Double?
    private var latestDeviceMotion: DeviceMotionSnapshot?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.activityType = .other
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = 50
        locationManager.pausesLocationUpdatesAutomatically = true
    }

    func hardwareAvailability() -> SensorHardwareAvailability {
        SensorHardwareAvailability(
            location: CLLocationManager.locationServicesEnabled(),
            motionActivity: CMMotionActivityManager.isActivityAvailable(),
            deviceMotion: deviceMotionManager.isDeviceMotionAvailable,
            relativeAltitude: CMAltimeter.isRelativeAltitudeAvailable(),
            stepCounting: CMPedometer.isStepCountingAvailable(),
            distance: CMPedometer.isDistanceAvailable(),
            floorCounting: CMPedometer.isFloorCountingAvailable()
        )
    }

    func permissionState() -> PermissionState {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .restricted, .denied:
            return .denied
        case .authorizedAlways, .authorizedWhenInUse:
            return .authorized
        @unknown default:
            return .unavailable
        }
    }

    func motionPermissionState() -> PermissionState {
        switch CMMotionActivityManager.authorizationStatus() {
        case .notDetermined:
            return .notDetermined
        case .restricted, .denied:
            return .denied
        case .authorized:
            return .authorized
        @unknown default:
            return .unavailable
        }
    }

    func requestLocationPermission(always: Bool = false) {
        if always, locationManager.authorizationStatus == .authorizedWhenInUse {
            locationManager.requestAlwaysAuthorization()
        } else {
            locationManager.requestWhenInUseAuthorization()
        }
    }

    func readings(highAccuracyDuringMovement: Bool = true) -> AsyncStream<SensorReading> {
        var configuration = SensorCollectionConfiguration.standard
        configuration.highAccuracyDuringMovement = highAccuracyDuringMovement
        return readings(configuration: configuration)
    }

    func readings(
        configuration: SensorCollectionConfiguration
    ) -> AsyncStream<SensorReading> {
        AsyncStream { continuation in
            self.continuation = continuation
            self.configuration = configuration
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.stop() }
            }
            start()
        }
    }

    func stop() {
        locationManager.stopUpdatingLocation()
        locationManager.stopMonitoringVisits()
        locationManager.stopMonitoringSignificantLocationChanges()
        locationManager.allowsBackgroundLocationUpdates = false
        activityManager.stopActivityUpdates()
        deviceMotionManager.stopDeviceMotionUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        pedometer.stopUpdates()
        isCollecting = false
        lastEmissionAt = nil
        continuation?.finish()
        continuation = nil
    }

    private func start() {
        guard !isCollecting else { return }
        isCollecting = true
        locationManager.allowsBackgroundLocationUpdates =
            configuration.allowsBackgroundLocation
            && locationManager.authorizationStatus == .authorizedAlways
        if CLLocationManager.isMonitoringAvailable(for: CLVisit.self) {
            locationManager.startMonitoringVisits()
        }
        if CLLocationManager.significantLocationChangeMonitoringAvailable() {
            locationManager.startMonitoringSignificantLocationChanges()
        }
        if permissionState() == .authorized {
            locationManager.startUpdatingLocation()
        }

        if CMMotionActivityManager.isActivityAvailable() {
            activityManager.startActivityUpdates(to: .main) { [weak self] activity in
                guard let activity else { return }
                Task { @MainActor in
                    guard let self else { return }
                    self.latestMotion = Self.motionKind(activity)
                    self.latestMotionConfidence = Self.confidence(activity.confidence)
                    if self.configuration.highAccuracyDuringMovement {
                        self.locationManager.desiredAccuracy = activity.stationary
                            ? kCLLocationAccuracyHundredMeters
                            : kCLLocationAccuracyBest
                        self.locationManager.distanceFilter = activity.stationary ? 50 : 10
                    }
                    self.emit()
                }
            }
        }

        if configuration.collectsDeviceMotion,
           deviceMotionManager.isDeviceMotionAvailable {
            deviceMotionManager.deviceMotionUpdateInterval = max(
                0.25,
                min(2, configuration.minimumEmissionInterval)
            )
            deviceMotionManager.startDeviceMotionUpdates(
                to: .main
            ) { [weak self] motion, _ in
                guard let motion else { return }
                let snapshot = DeviceMotionSnapshot(
                    gravity: SensorVector3(
                        x: motion.gravity.x,
                        y: motion.gravity.y,
                        z: motion.gravity.z
                    ),
                    userAcceleration: SensorVector3(
                        x: motion.userAcceleration.x,
                        y: motion.userAcceleration.y,
                        z: motion.userAcceleration.z
                    ),
                    rotationRate: SensorVector3(
                        x: motion.rotationRate.x,
                        y: motion.rotationRate.y,
                        z: motion.rotationRate.z
                    ),
                    attitudeRadians: SensorVector3(
                        x: motion.attitude.roll,
                        y: motion.attitude.pitch,
                        z: motion.attitude.yaw
                    )
                )
                Task { @MainActor in
                    self?.latestDeviceMotion = snapshot
                    self?.emit()
                }
            }
        }

        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
                Task { @MainActor in
                    self?.latestRelativeAltitude = data?.relativeAltitude.doubleValue
                    self?.emit()
                }
            }
        }

        if CMPedometer.isStepCountingAvailable() {
            pedometer.startUpdates(from: .now) { [weak self] data, _ in
                Task { @MainActor in
                    self?.latestFloorsAscended = data?.floorsAscended?.intValue
                    self?.latestFloorsDescended = data?.floorsDescended?.intValue
                    self?.latestStepCount = data?.numberOfSteps.intValue
                    self?.latestWalkingRunningDistance = data?.distance?.doubleValue
                    self?.emit()
                }
            }
        }
    }

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        latestLocation = locations.last {
            $0.horizontalAccuracy >= 0
                && abs($0.timestamp.timeIntervalSinceNow) < 5 * 60
        }
        emit(force: true)
    }

    func locationManager(
        _ manager: CLLocationManager,
        didVisit visit: CLVisit
    ) {
        let date = visit.departureDate == .distantFuture
            ? visit.arrivalDate
            : visit.departureDate
        let location = CLLocation(
            coordinate: visit.coordinate,
            altitude: 0,
            horizontalAccuracy: visit.horizontalAccuracy,
            verticalAccuracy: -1,
            timestamp: date
        )
        latestLocation = location
        latestMotion = .stationary
        latestMotionConfidence = .high
        emit(force: true)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if permissionState() == .authorized {
            manager.allowsBackgroundLocationUpdates =
                configuration.allowsBackgroundLocation
                && manager.authorizationStatus == .authorizedAlways
            manager.startUpdatingLocation()
        }
    }

    func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        if (error as? CLError)?.code == .denied {
            stop()
        }
    }

    private func emit(force: Bool = false) {
        guard continuation != nil else { return }
        let now = Date.now
        if !force,
           let lastEmissionAt,
           now.timeIntervalSince(lastEmissionAt)
            < max(0.25, configuration.minimumEmissionInterval) {
            return
        }
        lastEmissionAt = now
        let location = latestLocation
        let point = location.map {
            GeoPoint(
                latitude: $0.coordinate.latitude,
                longitude: $0.coordinate.longitude,
                altitude: $0.altitude,
                horizontalAccuracy: $0.horizontalAccuracy,
                verticalAccuracy: $0.verticalAccuracy
            )
        }
        continuation?.yield(
            SensorReading(
                timestamp: location?.timestamp ?? .now,
                point: point,
                speedMetersPerSecond: location.flatMap { $0.speed >= 0 ? $0.speed : nil },
                courseDegrees: location.flatMap { $0.course >= 0 ? $0.course : nil },
                motion: latestMotion,
                motionConfidence: latestMotionConfidence,
                relativeAltitudeMeters: latestRelativeAltitude,
                floorsAscended: latestFloorsAscended,
                floorsDescended: latestFloorsDescended,
                stepCount: latestStepCount,
                walkingRunningDistanceMeters: latestWalkingRunningDistance,
                deviceMotion: latestDeviceMotion,
                systemFloor: location?.floor?.level,
                gpsAvailable: location != nil
            )
        )
    }

    private static func motionKind(_ activity: CMMotionActivity) -> MotionKind {
        if activity.stationary { return .stationary }
        if activity.walking { return .walking }
        if activity.running { return .running }
        if activity.cycling { return .cycling }
        if activity.automotive { return .automotive }
        return .unknown
    }

    private static func confidence(
        _ confidence: CMMotionActivityConfidence
    ) -> ConfidenceLevel {
        switch confidence {
        case .high: .high
        case .medium: .medium
        case .low: .low
        @unknown default: .low
        }
    }
}

// MARK: - Historical iPhone motion data

final class AppleMotionHistoryService: @unchecked Sendable {
    private let activityManager: CMMotionActivityManager
    private let pedometer: CMPedometer

    init(
        activityManager: CMMotionActivityManager = CMMotionActivityManager(),
        pedometer: CMPedometer = CMPedometer()
    ) {
        self.activityManager = activityManager
        self.pedometer = pedometer
    }

    func permissionState() -> PermissionState {
        switch CMMotionActivityManager.authorizationStatus() {
        case .notDetermined:
            return .notDetermined
        case .restricted, .denied:
            return .denied
        case .authorized:
            return .authorized
        @unknown default:
            return .unavailable
        }
    }

    func activities(in span: TimeSpan) async throws -> [MotionActivityRecord] {
        guard CMMotionActivityManager.isActivityAvailable() else { return [] }
        return try await withCheckedThrowingContinuation { continuation in
            activityManager.queryActivityStarting(
                from: span.start,
                to: span.end,
                to: .main
            ) { activities, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    let ordered = (activities ?? [])
                        .filter { $0.startDate < span.end }
                        .sorted { $0.startDate < $1.startDate }
                    let records = ordered.enumerated().compactMap {
                        index, activity -> MotionActivityRecord? in
                        let start = max(span.start, activity.startDate)
                        let nextStart = ordered.indices.contains(index + 1)
                            ? ordered[index + 1].startDate
                            : span.end
                        let end = min(span.end, max(start, nextStart))
                        guard start < end else { return nil }
                        return MotionActivityRecord(
                            span: TimeSpan(start: start, end: end),
                            motion: Self.motionKind(activity),
                            confidence: Self.confidence(activity.confidence)
                        )
                    }
                    continuation.resume(returning: records)
                }
            }
        }
    }

    func pedometerSummary(in span: TimeSpan) async throws -> PedometerSummary? {
        guard CMPedometer.isStepCountingAvailable() else { return nil }
        return try await withCheckedThrowingContinuation { continuation in
            pedometer.queryPedometerData(
                from: span.start,
                to: span.end
            ) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(
                        returning: PedometerSummary(
                            span: TimeSpan(
                                start: data.startDate,
                                end: data.endDate
                            ),
                            stepCount: data.numberOfSteps.intValue,
                            distanceMeters: data.distance?.doubleValue,
                            floorsAscended: data.floorsAscended?.intValue,
                            floorsDescended: data.floorsDescended?.intValue,
                            averageActivePaceSecondsPerMeter:
                                data.averageActivePace?.doubleValue
                        )
                    )
                } else {
                    continuation.resume(
                        throwing: CocoaError(.fileReadUnknown)
                    )
                }
            }
        }
    }

    private static func motionKind(_ activity: CMMotionActivity) -> MotionKind {
        if activity.stationary { return .stationary }
        if activity.walking { return .walking }
        if activity.running { return .running }
        if activity.cycling { return .cycling }
        if activity.automotive { return .automotive }
        return .unknown
    }

    private static func confidence(
        _ confidence: CMMotionActivityConfidence
    ) -> ConfidenceLevel {
        switch confidence {
        case .high: .high
        case .medium: .medium
        case .low: .low
        @unknown default: .low
        }
    }
}

actor PlaceNameResolver {
    func displayName(
        latitude: Double,
        longitude: Double
    ) async -> String? {
        await withCheckedContinuation { continuation in
            CLGeocoder().reverseGeocodeLocation(
                CLLocation(latitude: latitude, longitude: longitude)
            ) { placemarks, _ in
                let place = placemarks?.first
                let name = place?.areasOfInterest?.first
                    ?? place?.name
                    ?? place?.locality
                continuation.resume(returning: name)
            }
        }
    }
}

// MARK: - Voice memo and notifications

@MainActor
final class VoiceMemoRecorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var activeURL: URL?

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission {
                continuation.resume(returning: $0)
            }
        }
    }

    func start(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent(
            "memo-\(UUID().uuidString).m4a"
        )
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .spokenAudio)
        try session.setActive(true)
        let recorder = try AVAudioRecorder(
            url: url,
            settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
        )
        recorder.delegate = self
        recorder.record()
        self.recorder = recorder
        activeURL = url
        return url
    }

    func stop() -> URL? {
        recorder?.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        defer { activeURL = nil }
        return activeURL
    }
}

@MainActor
final class VoiceMemoPlayer: NSObject, @preconcurrency AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    var onFinish: (() -> Void)?

    var isPlaying: Bool {
        player?.isPlaying == true
    }

    func play(filePath: String) throws {
        stop()
        let url = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VoiceMemoPlaybackError.fileMissing
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        player.prepareToPlay()
        guard player.play() else {
            throw VoiceMemoPlaybackError.couldNotStart
        }
        self.player = player
    }

    func stop() {
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        self.player = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        onFinish?()
    }
}

enum VoiceMemoPlaybackError: LocalizedError {
    case fileMissing
    case couldNotStart

    var errorDescription: String? {
        switch self {
        case .fileMissing:
            "음성 메모 파일을 찾지 못했습니다."
        case .couldNotStart:
            "음성 메모 재생을 시작하지 못했습니다."
        }
    }
}

actor PlanNotificationScheduler {
    static let identifierPrefix = "plan-start-"

    private let center = UNUserNotificationCenter.current()

    func authorizationState() async -> PermissionState {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized, .provisional, .ephemeral:
            return .authorized
        @unknown default:
            return .unavailable
        }
    }

    func requestPermission() async throws -> PermissionState {
        _ = try await center.requestAuthorization(
            options: [.alert, .badge, .sound]
        )
        return await authorizationState()
    }

    func scheduleStartReminder(for plan: PlanRecord) async throws {
        guard plan.span.start > .now, plan.status == .planned else { return }
        let content = UNMutableNotificationContent()
        content.title = plan.title
        content.body = "계획 시작 시간입니다."
        content.sound = .default
        content.userInfo = ["planID": plan.id.uuidString]
        let components = Calendar.autoupdatingCurrent.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: plan.span.start
        )
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: components,
            repeats: false
        )
        try await center.add(
            UNNotificationRequest(
                identifier: Self.identifier(for: plan.id),
                content: content,
                trigger: trigger
            )
        )
    }

    func synchronize(
        plans: [PlanRecord],
        now: Date = .now
    ) async throws {
        guard await authorizationState().isGranted else { return }

        let desired = PlanNotificationPolicy.reminderPlans(
            from: plans,
            now: now
        )
        let desiredIDs = Set(desired.map { Self.identifier(for: $0.id) })
        let current = await center.pendingNotificationRequests()
        let managed = current.filter {
            $0.identifier.hasPrefix(Self.identifierPrefix)
        }
        let obsolete = managed
            .map(\.identifier)
            .filter { !desiredIDs.contains($0) }
        if !obsolete.isEmpty {
            center.removePendingNotificationRequests(
                withIdentifiers: obsolete
            )
        }

        let existingByID = Dictionary(
            uniqueKeysWithValues: managed.map { ($0.identifier, $0) }
        )
        for plan in desired {
            let identifier = Self.identifier(for: plan.id)
            let existingDate = (
                existingByID[identifier]?.trigger
                    as? UNCalendarNotificationTrigger
            )?.nextTriggerDate()
            if let existingDate,
               abs(existingDate.timeIntervalSince(plan.span.start)) < 1 {
                continue
            }
            if existingByID[identifier] != nil {
                center.removePendingNotificationRequests(
                    withIdentifiers: [identifier]
                )
            }
            try await scheduleStartReminder(for: plan)
        }
    }

    func cancel(for planID: UUID) {
        center.removePendingNotificationRequests(
            withIdentifiers: [Self.identifier(for: planID)]
        )
    }

    func cancelAllPlanReminders() async {
        let requests = await center.pendingNotificationRequests()
        let identifiers = requests
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.identifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    nonisolated static func identifier(for planID: UUID) -> String {
        "\(identifierPrefix)\(planID.uuidString)"
    }
}

enum PlanNotificationPolicy {
    static let maximumPendingPlanReminders = 60

    static func reminderPlans(
        from plans: [PlanRecord],
        now: Date,
        limit: Int = maximumPendingPlanReminders
    ) -> [PlanRecord] {
        plans
            .filter {
                $0.status == .planned
                    && $0.span.start > now
            }
            .sorted { lhs, rhs in
                if lhs.span.start == rhs.span.start {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.span.start < rhs.span.start
            }
            .prefix(max(0, limit))
            .map { $0 }
    }
}
