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

    init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
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

    func actuals(in span: TimeSpan) async throws -> [ActualRecord] {
        async let workouts = workoutActuals(in: span)
        async let sleeps = sleepActuals(in: span)
        return try await workouts + sleeps
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
        try await sleepDetails(in: span).map { detail in
            ActualRecord(
                id: detail.id,
                planID: nil,
                title: "수면",
                categoryID: "sleep",
                startedAt: detail.span.start,
                endedAt: detail.span.end,
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
        guard let type = HKObjectType.categoryType(
            forIdentifier: .sleepAnalysis
        ) else {
            return []
        }
        let samples = try await samples(type: type, span: span)
        return samples.compactMap { sample in
            guard let category = sample as? HKCategorySample,
                  let value = HKCategoryValueSleepAnalysis(rawValue: category.value),
                  value != .inBed else {
                return nil
            }
            let recordSpan = TimeSpan(
                start: category.startDate,
                end: category.endDate
            )
            return HealthActual(
                id: UUID(uuidString: category.uuid.uuidString) ?? UUID(),
                kind: "수면",
                span: recordSpan,
                duration: recordSpan.duration,
                distanceMeters: nil,
                energyKilocalories: nil,
                sourceName: category.sourceRevision.source.name
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
            options: .strictStartDate
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
    private let motionManager = CMMotionActivityManager()
    private let altimeter = CMAltimeter()
    private let pedometer = CMPedometer()

    private var continuation: AsyncStream<SensorReading>.Continuation?
    private var latestLocation: CLLocation?
    private var latestMotion: MotionKind = .unknown
    private var latestMotionConfidence: ConfidenceLevel = .low
    private var latestRelativeAltitude: Double?
    private var latestFloorsAscended: Int?
    private var latestFloorsDescended: Int?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.activityType = .other
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = 50
        locationManager.pausesLocationUpdatesAutomatically = true
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

    func requestLocationPermission(always: Bool = false) {
        if always {
            locationManager.requestAlwaysAuthorization()
        } else {
            locationManager.requestWhenInUseAuthorization()
        }
    }

    func readings(highAccuracyDuringMovement: Bool = true) -> AsyncStream<SensorReading> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.stop() }
            }
            start(highAccuracyDuringMovement: highAccuracyDuringMovement)
        }
    }

    func stop() {
        locationManager.stopUpdatingLocation()
        locationManager.stopMonitoringVisits()
        motionManager.stopActivityUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        pedometer.stopUpdates()
        continuation?.finish()
        continuation = nil
    }

    private func start(highAccuracyDuringMovement: Bool) {
        locationManager.startMonitoringVisits()
        locationManager.startMonitoringSignificantLocationChanges()
        if permissionState() == .authorized {
            locationManager.startUpdatingLocation()
        }

        if CMMotionActivityManager.isActivityAvailable() {
            motionManager.startActivityUpdates(to: .main) { [weak self] activity in
                guard let activity else { return }
                Task { @MainActor in
                    guard let self else { return }
                    self.latestMotion = Self.motionKind(activity)
                    self.latestMotionConfidence = Self.confidence(activity.confidence)
                    if highAccuracyDuringMovement {
                        self.locationManager.desiredAccuracy = activity.stationary
                            ? kCLLocationAccuracyHundredMeters
                            : kCLLocationAccuracyBest
                        self.locationManager.distanceFilter = activity.stationary ? 50 : 10
                    }
                    self.emit()
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
                    self?.emit()
                }
            }
        }
    }

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        latestLocation = locations.last
        emit()
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
        emit()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if permissionState() == .authorized {
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

    private func emit() {
        guard continuation != nil else { return }
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

actor PlanNotificationScheduler {
    private let center = UNUserNotificationCenter.current()

    func requestPermission() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .badge, .sound])
    }

    func scheduleStartReminder(for plan: PlanRecord) async throws {
        guard plan.span.start > .now else { return }
        let content = UNMutableNotificationContent()
        content.title = plan.title
        content.body = "계획 시작 시간입니다."
        content.sound = .default
        content.userInfo = ["planID": plan.id.uuidString]
        let components = Calendar.autoupdatingCurrent.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: plan.span.start
        )
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: components,
            repeats: false
        )
        try await center.add(
            UNNotificationRequest(
                identifier: "plan-start-\(plan.id.uuidString)",
                content: content,
                trigger: trigger
            )
        )
    }

    func cancel(for planID: UUID) {
        center.removePendingNotificationRequests(
            withIdentifiers: ["plan-start-\(planID.uuidString)"]
        )
    }
}
