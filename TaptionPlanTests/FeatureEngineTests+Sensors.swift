import XCTest
import UIKit
import CoreLocation
import StoreKit
import StoreKitTest
import TaptionPlanCore
@testable import TaptionPlan

extension FeatureEngineTests {
    /// 배경 갱신은 전역 배너가 아니라 "이번 작업이 오류를 새로 세웠는가"로 성패를
    /// 가른다. 앞서 화면에 남은 배너 때문에 iOS에 실패를 보고하면 안 된다.
    @MainActor
    func testBackgroundRefreshDoesNotTreatALeftoverBannerAsFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try SensorReadingArchive(
            fileURL: directory.appendingPathComponent("readings.jsonl")
        )
        let model = AppModel(
            repository: InMemoryPlanRepository(snapshot: .empty),
            sensorService: AppleSensorDataService(
                archive: archive,
                archivedReadingsLoader: { _ in [] }
            ),
            cloudSyncService: nil
        )
        model.userFacingError = "기존 오류"
        let success = await model.performBackgroundRefresh(
            wakeReason: .bgAppRefresh
        )
        XCTAssertTrue(success)
        XCTAssertEqual(model.userFacingError, "기존 오류")
    }

    /// 반대로 이번 작업이 오류를 새로 세우면 실패로 보고해야 한다.
    @MainActor
    func testBackgroundRefreshReportsANewError() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try SensorReadingArchive(
            fileURL: directory.appendingPathComponent("readings.jsonl")
        )
        let model = AppModel(
            repository: FailingPlanRepository(),
            sensorService: AppleSensorDataService(
                archive: archive,
                archivedReadingsLoader: { _ in [] }
            ),
            cloudSyncService: nil
        )
        let success = await model.performBackgroundRefresh(
            wakeReason: .bgAppRefresh
        )
        XCTAssertFalse(success)
        XCTAssertNotNil(model.userFacingError)
    }

    /// 화면이 떠 있는 동안에는 배경 갱신이 무거운 작업을 다시 하지 않는다.
    ///
    /// 콜드 스타트에서 BGAppRefresh가 앱을 깨우고 곧바로 사용자가 앱을 열면 두 경로가
    /// 같은 저장소·센서·통합 갱신을 나눠 써 시작이 느려졌다(2026-10-28 실기기 로그:
    /// `bootstrap_local_snapshot` 517 → 1,946ms, 첫 화면 1,158 → 3,142ms).
    /// 화면 쪽이 같은 일을 곧바로 하므로 배경 갱신은 물러난다.
    @MainActor
    func testBackgroundRefreshYieldsWhileTheSceneIsActive() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try SensorReadingArchive(
            fileURL: directory.appendingPathComponent("readings.jsonl")
        )
        let repository = CountingPlanRepository(snapshot: .empty)
        let model = AppModel(
            repository: repository,
            sensorService: AppleSensorDataService(
                archive: archive,
                archivedReadingsLoader: { _ in [] }
            ),
            cloudSyncService: nil
        )

        // 대조군: 화면이 없을 때는 저장까지 간다(무거운 경로를 실제로 돈다).
        let background = await model.performBackgroundRefresh(
            wakeReason: .bgAppRefresh
        )
        XCTAssertTrue(background)
        let savesWhileBackground = await repository.saveCount
        XCTAssertGreaterThan(savesWhileBackground, 0, "배경에서는 저장까지 간다")

        // 화면이 떠 있으면 같은 갱신을 다시 하지 않는다.
        await model.sceneBecameActive()
        let foreground = await model.performBackgroundRefresh(
            wakeReason: .bgAppRefresh
        )
        XCTAssertTrue(foreground)
        let savesAfterForeground = await repository.saveCount
        XCTAssertEqual(
            savesAfterForeground,
            savesWhileBackground,
            "화면이 떠 있는데 배경 갱신이 저장까지 갔다"
        )
    }

    func testLocationUpdatesWaitUntilFreshLocationRequestCompletes() {
        XCTAssertFalse(
            MapHomeUserTrackingPolicy.focusesLocationUpdates(in: .locating)
        )
        XCTAssertTrue(
            MapHomeUserTrackingPolicy.focusesLocationUpdates(in: .following)
        )
    }

    @MainActor
    func testImmediateSensorAnalysisKeepsEveryPendingDay() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            TrackingSessionRecoveryStore.clear()
            TaptionPlanDiagnosticsLogger.shared.clear()
        }
        let archive = try SensorReadingArchive(
            fileURL: directory.appendingPathComponent("readings.jsonl")
        )
        let sensorService = AppleSensorDataService(archive: archive)
        var stored = TaptionDataSnapshot.empty
        stored.settings.locationEnabled = false
        stored.settings.weatherEnabled = false
        stored.settings.healthEnabled = false
        let repository = InMemoryPlanRepository(snapshot: stored)
        let model = AppModel(
            repository: repository,
            sensorService: sensorService,
            cloudSyncService: nil,
            registersHealthBackgroundHandler: false
        )
        await model.sceneBecameActive()
        await waitForInitialForegroundWorkToSettle(model)
        let persistedBefore = try await repository.load().updatedAt
        let calendar = Calendar.autoupdatingCurrent
        let firstDay = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: .now)
        )!
        let secondDay = calendar.date(
            byAdding: .day,
            value: 1,
            to: firstDay
        )!
        let readings = [firstDay, secondDay].map { day in
            SensorReading(
                timestamp: day.addingTimeInterval(hour),
                trackingSessionID: UUID(),
                trackingKind: .automatic,
                sourceDevice: .iPhone,
                trackingSessionEnded: true
            )
        }
        for reading in readings {
            try await archive.append(
                reading,
                now: secondDay.addingTimeInterval(2 * hour)
            )
        }
        TaptionPlanDiagnosticsLogger.shared.clear()

        sensorService.onReadingsPersisted?(readings)

        let expectedStarts = [firstDay, secondDay].map {
            String($0.timeIntervalSinceReferenceDate)
        }
        let deadline = Date.now.addingTimeInterval(20)  // 전체 실행 부하에서 5초로는 저장이 끝나기 전에 끊겨 간헐 실패했다.
        var log = ""
        var persistedAfter = persistedBefore
        while Date.now < deadline {
            log = TaptionPlanDiagnosticsLogger.shared.combinedLog()
            persistedAfter = try await repository.load().updatedAt
            let loadedDays = log.components(
                separatedBy: "sensor_timeline_evidence_loaded"
            ).count - 1
            if expectedStarts.allSatisfy({ log.contains($0) }),
               loadedDays >= 2,
               persistedAfter > persistedBefore { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(expectedStarts.allSatisfy { log.contains($0) })
        XCTAssertGreaterThanOrEqual(
            log.components(
                separatedBy: "sensor_timeline_evidence_loaded"
            ).count - 1,
            2
        )
        XCTAssertGreaterThan(persistedAfter, persistedBefore)
        await model.sceneEnteredBackground()
    }

    @MainActor
    func testSensorAnalysisKeepsFailedDayForRetry() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let archiveDirectory = root.appendingPathComponent(
            "archive",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: root)
            TrackingSessionRecoveryStore.clear()
            TaptionPlanDiagnosticsLogger.shared.clear()
        }
        let archive = try SensorReadingArchive(
            fileURL: archiveDirectory.appendingPathComponent("readings.jsonl"),
            storeURL: archiveDirectory.appendingPathComponent("data.sqlite")
        )
        let sensorService = AppleSensorDataService(
            archive: archive,
            archivedReadingsLoader: { _ in
                throw CocoaError(.fileReadCorruptFile)
            }
        )
        var stored = TaptionDataSnapshot.empty
        stored.settings.locationEnabled = false
        stored.settings.weatherEnabled = false
        stored.settings.healthEnabled = false
        let model = AppModel(
            repository: InMemoryPlanRepository(snapshot: stored),
            sensorService: sensorService,
            cloudSyncService: nil,
            registersHealthBackgroundHandler: false
        )
        await model.sceneBecameActive()
        await waitForInitialForegroundWorkToSettle(model)
        TaptionPlanDiagnosticsLogger.shared.clear()

        sensorService.onReadingsPersisted?([
            SensorReading(
                timestamp: .now,
                trackingSessionID: UUID(),
                trackingKind: .automatic,
                sourceDevice: .iPhone,
                trackingSessionEnded: true
            )
        ])

        let deadline = Date.now.addingTimeInterval(3)
        var log = ""
        while Date.now < deadline {
            log = TaptionPlanDiagnosticsLogger.shared.combinedLog()
            if log.contains("sensor_analysis_retry_scheduled") { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(log.contains("sensor_timeline_read_failed"))
        XCTAssertTrue(log.contains("sensor_analysis_retry_scheduled"))
        await model.sceneEnteredBackground()
    }

    @MainActor
    func testDaySourcePreparationKeepsOnlyCurrentDayBeforeSensorRead() async throws {
        let date = Date(timeIntervalSince1970: 1_791_250_000)
        var source = TaptionDataSnapshot.empty
        source.settings.locationEnabled = false
        source.settings.healthEnabled = false
        source.settings.weatherEnabled = false
        let active = ActualRecord(planID: nil, title: "합성 현재", categoryID: "eating",
            startedAt: date.addingTimeInterval(-30), endedAt: date.addingTimeInterval(30),
            source: .motion, isClassificationLocked: true)
        source.actuals = (0..<524_953).map { index in
            ActualRecord(planID: nil, title: "합성 과거", categoryID: "activity",
                startedAt: date.addingTimeInterval(-172_800 - Double(index)*30),
                endedAt: date.addingTimeInterval(-172_780 - Double(index)*30),
                source: .motion, isClassificationLocked: true)
        } + [active]
        let model = AppModel(repository: InMemoryPlanRepository(snapshot: source),
            cloudSyncService: nil, registersHealthBackgroundHandler: false)
        await model.prepareLocalDataForDisplay()
        let start = ProcessInfo.processInfo.systemUptime
        let prepared = await model.planDaySourceSnapshot(for: date, reusing: nil)
        let day = try XCTUnwrap(prepared)
        let preparationMS = (ProcessInfo.processInfo.systemUptime - start)*1000
        XCTAssertEqual(day.actuals, [active])
        XCTAssertFalse(day.isComplete)
        let lookupStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<8 {
            XCTAssertEqual(MapHomeStickmanActionResolver.action(at: date,
                actuals: day.actuals, travel: day.travel, places: day.places, frequentPlaces: []), .eating)
        }
        print("MAP1006G01 map records=\(source.actuals.count) day_records=\(day.actuals.count) preparation_ms=\(preparationMS) eight_lookups_ms=\((ProcessInfo.processInfo.systemUptime - lookupStart)*1000)")
        await model.sceneEnteredBackground()
    }

    @MainActor
    func testSelectedDateAssignmentWhileBackgroundDoesNotRefresh()
        async {
        let model = await makeActiveIntegrationModel(
            selectedDate: makeDate(2026, 8, 18, 12)
        )
        defer { TaptionPlanDiagnosticsLogger.shared.clear() }

        await model.sceneEnteredBackground()
        TaptionPlanDiagnosticsLogger.shared.clear()

        model.selectedDate = makeDate(2026, 8, 19, 12)
        try? await Task.sleep(for: .milliseconds(350))

        XCTAssertTrue(integrationRefreshStartLines().isEmpty)
    }

    @MainActor
    func testSensorAnalysisDefersBackgroundReadingsAndCoalescesOnForeground()
        async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "sensor-analysis-foreground-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: directory)
            TaptionPlanDiagnosticsLogger.shared.clear()
        }

        let date = Date.now
        let archive = try SensorReadingArchive(
            fileURL: directory.appendingPathComponent("readings.jsonl")
        )
        let sensorService = AppleSensorDataService(archive: archive)
        var stored = TaptionDataSnapshot.empty
        stored.settings.locationEnabled = false
        stored.settings.healthEnabled = false
        stored.settings.weatherEnabled = false
        let model = AppModel(
            repository: InMemoryPlanRepository(snapshot: stored),
            sensorService: sensorService,
            cloudSyncService: nil,
            registersHealthBackgroundHandler: false,
            sensorAnalysisDebounceDelay: .milliseconds(300)
        )

        await model.sceneBecameActive()
        try await Task.sleep(for: .milliseconds(200))
        TaptionPlanDiagnosticsLogger.shared.clear()
        try await sensorService.recordExternalReadings([
            SensorReading(timestamp: date),
        ])
        try await Task.sleep(for: .milliseconds(40))
        await model.sceneEnteredBackground()

        try await sensorService.recordExternalReadings([
            SensorReading(timestamp: date.addingTimeInterval(60)),
            SensorReading(timestamp: date.addingTimeInterval(120)),
        ])
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertTrue(sensorAnalysisBatchStartLines().isEmpty)
        XCTAssertTrue(
            sensorTimelineRefreshStartLines().isEmpty,
            sensorTimelineRefreshStartLines().joined(separator: "\n")
        )

        await model.sceneBecameActive()
        let starts = await waitForSensorAnalysisBatch()
        XCTAssertEqual(
            starts.count,
            1,
            TaptionPlanDiagnosticsLogger.shared.combinedLog()
        )
        XCTAssertTrue(starts.first?.contains("\"days\":\"1\"") == true)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(sensorAnalysisBatchStartLines().count, 1)

        await model.sceneEnteredBackground()
    }

    func testOneMinuteGanttPrioritizesTimeActualAndSensorConfidence() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = makeDate(2026, 7, 31, 9, 4)
        let end = makeDate(2026, 7, 31, 9, 36)

        XCTAssertEqual(
            GanttPrecisionPresentation.label(
                title: "자가용",
                startsAt: start,
                endsAt: end,
                detailText: "센서 추정 · 높은 신뢰",
                visibleDuration: 60,
                calendar: calendar
            ),
            "09:04–09:36 · 센서 추정 · 높은 신뢰"
        )
        XCTAssertEqual(
            GanttPrecisionPresentation.label(
                title: "러닝",
                startsAt: start,
                endsAt: end,
                detailText: "실제 · Apple 건강 · 높은 신뢰",
                visibleDuration: 15 * 60,
                calendar: calendar
            ),
            "러닝"
        )
    }

    func testPoorAccuracyGPSSpikeDoesNotBecomeAirplane() {
        let base = makeDate(2026, 8, 1, 8, 0)
        let speeds: [(Double, Double)] = [
            (1.2, 0.4),
            (1.4, 0.5),
            (95, 80),
            (1.3, 0.4),
            (1.5, 0.5),
        ]
        let readings = speeds.enumerated().map { index, item in
            SensorReading(
                timestamp: base.addingTimeInterval(Double(index) * 60),
                speedMetersPerSecond: item.0,
                speedAccuracyMetersPerSecond: item.1,
                motion: .walking,
                motionConfidence: .high,
                stepCount: index * 80,
                currentCadenceStepsPerSecond: 1.5
            )
        }

        let result = TravelModeClassifier().classify(readings: readings)

        XCTAssertEqual(result.mode, .walking)
        XCTAssertNotEqual(result.mode, .airplane)
    }

    func testCoordinateTrajectoryRejectsUnknownLocationAccuracy() {
        let base = makeDate(2026, 8, 11, 9, 35)
        let readings = [
            (37.5248, 126.6744),
            (37.5692, 126.6737),
            (37.5667, 126.8273),
        ].enumerated().map { index, coordinate in
            SensorReading(
                timestamp: base.addingTimeInterval(Double(index) * 10 * 60),
                point: GeoPoint(
                    latitude: coordinate.0,
                    longitude: coordinate.1,
                    altitude: 0,
                    horizontalAccuracy: -1,
                    verticalAccuracy: -1
                )
            )
        }

        XCTAssertNil(
            SubwayStationCatalog.coordinateTrajectory(from: readings)
        )
    }

    func testCoordinateTrajectoryRejectsNonGPSAndApproximateLocations() {
        let base = makeDate(2026, 8, 11, 9, 35)
        let points = [
            (37.5248, 126.6744),
            (37.5692, 126.6737),
            (37.5667, 126.8273),
        ]
        func readings(
            gpsAvailable: Bool,
            quality: LocationFixQuality?
        ) -> [SensorReading] {
            points.enumerated().map { index, coordinate in
                SensorReading(
                    timestamp: base.addingTimeInterval(
                        Double(index) * 10 * 60
                    ),
                    point: GeoPoint(
                        latitude: coordinate.0,
                        longitude: coordinate.1,
                        altitude: 0,
                        horizontalAccuracy: 10,
                        verticalAccuracy: 10
                    ),
                    locationFixQuality: quality,
                    gpsAvailable: gpsAvailable
                )
            }
        }

        XCTAssertNil(
            SubwayStationCatalog.coordinateTrajectory(
                from: readings(gpsAvailable: false, quality: .precise)
            )
        )
        XCTAssertNil(
            SubwayStationCatalog.coordinateTrajectory(
                from: readings(gpsAvailable: true, quality: .approximate)
            )
        )
    }

    func testSensorCollectionProfilesUseRequestedIntervalsAndPowerPolicy() {
        XCTAssertEqual(
            SensorCollectionProfile.batterySaver.interval,
            15 * 60
        )
        XCTAssertEqual(
            SensorCollectionProfile.balanced.interval,
            5 * 60
        )
        XCTAssertEqual(
            SensorCollectionProfile.accuracy.interval,
            60
        )
        XCTAssertEqual(
            SensorCollectionProfile.batterySaver.samplingWindowDuration,
            8
        )
        XCTAssertEqual(
            SensorCollectionProfile.balanced.samplingWindowDuration,
            10
        )
        XCTAssertEqual(
            SensorCollectionProfile.accuracy.samplingWindowDuration,
            12
        )

        let batterySaver = SensorCollectionConfiguration.configured(
            for: .batterySaver,
            allowsBackgroundLocation: false
        )
        XCTAssertFalse(batterySaver.highAccuracyDuringMovement)
        XCTAssertFalse(batterySaver.collectsDeviceMotion)
        XCTAssertEqual(batterySaver.minimumEmissionInterval, 15 * 60)

        let accuracy = SensorCollectionConfiguration.configured(
            for: .accuracy,
            allowsBackgroundLocation: true
        )
        XCTAssertTrue(accuracy.highAccuracyDuringMovement)
        XCTAssertTrue(accuracy.collectsDeviceMotion)
        XCTAssertTrue(accuracy.allowsBackgroundLocation)
        XCTAssertEqual(accuracy.minimumEmissionInterval, 60)
        XCTAssertEqual(
            AppFeatureSettings.defaults.sensorCollectionProfile,
            .balanced
        )
        let balanced = SensorCollectionConfiguration.configured(
            for: .balanced,
            allowsBackgroundLocation: true
        )
        XCTAssertTrue(balanced.collectsDeviceMotion)
        XCTAssertEqual(balanced.minimumEmissionInterval, 5 * 60)
    }

    func testBackgroundCollectionKeepsEachProfileCadence() {
        for profile in SensorCollectionProfile.allCases {
            let configuration = SensorCollectionConfiguration.configured(
                for: profile,
                allowsBackgroundLocation: true
            )

            XCTAssertTrue(configuration.allowsBackgroundLocation)
            XCTAssertEqual(
                configuration.minimumEmissionInterval,
                profile.interval
            )
        }
    }

    func testGPSLoggingPreferencesClampCadenceAndKeepApproximateFixes() throws {
        XCTAssertEqual(GPSLoggingPreferences.standard.intervalSeconds, 300)
        XCTAssertFalse(GPSLoggingPreferences.standard.isBatteryMinimal)
        XCTAssertEqual(GPSLoggingPreferences(intervalSeconds: 0).intervalSeconds, 30)
        XCTAssertEqual(GPSLoggingPreferences(intervalSeconds: 30).interval, 30)
        XCTAssertEqual(GPSLoggingPreferences(intervalSeconds: 9_999).intervalSeconds, 1_800)
        XCTAssertEqual(
            GPSLoggingPreferences.supportedIntervalSeconds,
            Array(stride(from: 30, through: 1_800, by: 30))
        )
        // 30-second steps with no pull toward the major ticks.
        XCTAssertEqual(GPSLoggingPreferences(intervalSeconds: 44).intervalSeconds, 30)
        XCTAssertEqual(GPSLoggingPreferences(intervalSeconds: 45).intervalSeconds, 60)
        XCTAssertEqual(GPSLoggingPreferences(intervalSeconds: 240).intervalSeconds, 240)
        XCTAssertEqual(GPSLoggingPreferences(intervalSeconds: 270).intervalSeconds, 270)
        XCTAssertFalse(GPSLoggingPreferences(intervalSeconds: 870).isBatteryMinimal)
        XCTAssertTrue(GPSLoggingPreferences(intervalSeconds: 900).isBatteryMinimal)
        let thirtyMinutes = GPSLoggingPreferences(intervalSeconds: 1_800)
        XCTAssertEqual(thirtyMinutes.effectiveIntervalSeconds, 1_800)
        XCTAssertEqual(thirtyMinutes.interval, 1_800)
        var legacyConfiguration = SensorCollectionConfiguration.standard
        legacyConfiguration.minimumEmissionInterval = 1
        XCTAssertEqual(legacyConfiguration.normalized.minimumEmissionInterval, 60)
        XCTAssertTrue(
            TrackingSessionPolicy.allowsPersistingLocation(
                horizontalAccuracy: 800,
                batteryMinimal: true
            )
        )
        XCTAssertFalse(
            TrackingSessionPolicy.allowsPersistingLocation(
                horizontalAccuracy: 800,
                batteryMinimal: false
            )
        )
        XCTAssertTrue(
            TrackingSessionPolicy.allowsPersistingLocation(
                horizontalAccuracy: 50,
                batteryMinimal: false
            )
        )

        let encoded = try JSONEncoder().encode(
            GPSLoggingPreferences.standard
        )
        XCTAssertEqual(
            try JSONDecoder().decode(GPSLoggingPreferences.self, from: encoded),
                GPSLoggingPreferences.standard
        )
        let legacy = Data(#"{"isBatteryMinimal":false,"intervalMinutes":5}"#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(GPSLoggingPreferences.self, from: legacy)
                .intervalSeconds,
            300
        )
        // Saved by earlier builds: minimum mode always collected every 15 minutes.
        let cases: [(String, Int)] = [
            (#"{"isBatteryMinimal":true,"intervalSeconds":900}"#, 900),
            (#"{"isBatteryMinimal":true,"intervalSeconds":60}"#, 900),
            (#"{"isBatteryMinimal":false,"intervalSeconds":420}"#, 420),
            (#"{"isBatteryMinimal":false,"intervalSeconds":1}"#, 60),
            (#"{"isBatteryMinimal":true,"intervalSeconds":1200}"#, 1_200),
        ]
        for (json, seconds) in cases {
            XCTAssertEqual(
                try JSONDecoder().decode(GPSLoggingPreferences.self, from: Data(json.utf8))
                    .intervalSeconds,
                seconds,
                json
            )
        }
        let saved = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(GPSLoggingPreferences(intervalSeconds: 1_200))
        ) as? [String: Any]
        XCTAssertEqual(saved?["isBatteryMinimal"] as? Bool, true)

        let approximate = SensorReading(
            timestamp: makeDate(2026, 8, 18, 12),
            point: GeoPoint(
                latitude: 37.483,
                longitude: 126.902,
                altitude: 0,
                horizontalAccuracy: 800,
                verticalAccuracy: -1
            ),
            locationFixQuality: .approximate,
            gpsAvailable: false
        )
        XCTAssertNotNil(approximate.point)
        XCTAssertEqual(approximate.locationFixQuality, .approximate)
        XCTAssertFalse(approximate.gpsAvailable)
    }

    func testGPSLoggingSliderMapsEveryIntervalAndMajorTicks() {
        for (seconds, position) in zip(
            GPSLoggingPreferences.majorTickSeconds,
            GPSLoggingPreferences.majorTickPositions
        ) {
            XCTAssertEqual(GPSLoggingPreferences.sliderPosition(forSeconds: seconds), position)
            XCTAssertEqual(GPSLoggingPreferences.seconds(forSliderPosition: position), seconds)
        }
        XCTAssertEqual(GPSLoggingPreferences.majorTickSeconds, [30, 60, 300, 600, 900, 1_800])
        var previous = -1.0
        for seconds in GPSLoggingPreferences.supportedIntervalSeconds {
            let position = GPSLoggingPreferences.sliderPosition(forSeconds: seconds)
            XCTAssertGreaterThan(position, previous)
            XCTAssertEqual(GPSLoggingPreferences.seconds(forSliderPosition: position), seconds)
            previous = position
        }
        XCTAssertEqual(GPSLoggingPreferences.seconds(forSliderPosition: -1), 30)
        XCTAssertEqual(GPSLoggingPreferences.seconds(forSliderPosition: 99), 1_800)
    }

    @MainActor
    func testGPSLoggingIntervalSelectsCollectionProfile() {
        let model = AppModel(
            repository: InMemoryPlanRepository(),
            cloudSyncService: nil
        )
        let expected: [(Int, SensorCollectionProfile)] = [
            (30, .accuracy), (60, .accuracy), (90, .accuracy),
            (120, .balanced), (300, .balanced), (660, .balanced), (870, .balanced),
            (900, .batterySaver), (1_800, .batterySaver),
        ]
        for (seconds, profile) in expected {
            model.setGPSLoggingIntervalSeconds(seconds)
            XCTAssertEqual(model.settings.gpsLoggingPreferences.intervalSeconds, seconds)
            XCTAssertEqual(model.settings.sensorCollectionProfile, profile, "\(seconds)")
        }
    }

    func testGPSLoggingIntervalTextUsesSecondsAndMinutes() {
        let expect = { (korean: String, english: String) in
            AppLanguagePreference.runtimeText(korean, english)
        }
        XCTAssertEqual(GPSLoggingPreferences.intervalText(30), expect("30초", "30s"))
        XCTAssertEqual(GPSLoggingPreferences.intervalText(60), expect("1분", "1m"))
        XCTAssertEqual(GPSLoggingPreferences.intervalText(150), expect("2분 30초", "2m 30s"))
    }

    func testSensorCollectionProgressUsesHalfIntervalIncludingOneSecond() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 22_000)
        XCTAssertEqual(
            SensorCollectionProgressPolicy.halfWindowDuration(
                intervalSeconds: 900
            ),
            450
        )
        XCTAssertEqual(
            SensorCollectionProgressPolicy.halfWindowDuration(
                intervalSeconds: 60
            ),
            30
        )
        XCTAssertEqual(
            SensorCollectionProgressPolicy.halfWindowDuration(
                intervalSeconds: 1
            ),
            0.5
        )
        XCTAssertEqual(
            SensorCollectionProgressPolicy.progress(
                at: startedAt.addingTimeInterval(225),
                startedAt: startedAt,
                lastSavedAt: nil,
                intervalSeconds: 900
            ) ?? -1,
            0.5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            SensorCollectionProgressPolicy.progress(
                at: startedAt.addingTimeInterval(30),
                startedAt: startedAt,
                lastSavedAt: startedAt,
                intervalSeconds: 60
            ) ?? -1,
            1,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            SensorCollectionProgressPolicy.progress(
                at: startedAt.addingTimeInterval(0.5),
                startedAt: startedAt,
                lastSavedAt: nil,
                intervalSeconds: 1
            ) ?? -1,
            1,
            accuracy: 0.000_001
        )
    }

    func testSensorCollectionCompactHUDExpiresAfterTenSeconds() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let until = SensorCollectionActivityPolicy.sensorHUDUntil(
            startedAt: startedAt
        )

        XCTAssertEqual(until.timeIntervalSince(startedAt), 10)
        XCTAssertTrue(startedAt.addingTimeInterval(9.999) < until)
        XCTAssertFalse(startedAt.addingTimeInterval(10) < until)
    }

    func testSensorCollectionWaveformProgressAdvancesFromRightToLeft() {
        XCTAssertEqual(
            SensorCollectionWaveformMath.rightToLeftEndpoint(
                progress: 0,
                width: 24
            ),
            24
        )
        XCTAssertEqual(
            SensorCollectionWaveformMath.rightToLeftEndpoint(
                progress: 0.25,
                width: 24
            ),
            18
        )
        XCTAssertEqual(
            SensorCollectionWaveformMath.rightToLeftEndpoint(
                progress: 1.5,
                width: 24
            ),
            0
        )
        XCTAssertEqual(
            SensorCollectionWaveformMath.rightToLeftEndpoint(
                progress: -0.5,
                width: 24
            ),
            24
        )
        XCTAssertEqual(
            SensorCollectionWaveformMath.leftToRightEndpoint(
                progress: 0,
                width: 24
            ),
            0
        )
        XCTAssertEqual(
            SensorCollectionWaveformMath.leftToRightEndpoint(
                progress: 0.5,
                width: 24
            ),
            12
        )
        XCTAssertEqual(
            SensorCollectionWaveformMath.leftToRightEndpoint(
                progress: 1.5,
                width: 24
            ),
            24
        )
    }

    func testSensorCollectionWaveformHeartbeatIsPeriodicAndHasQRS() {
        XCTAssertEqual(
            SensorCollectionWaveformMath.heartbeat(at: 0.405),
            SensorCollectionWaveformMath.heartbeat(at: 1.405),
            accuracy: 0.000_001
        )
        XCTAssertGreaterThan(
            SensorCollectionWaveformMath.heartbeat(at: 0.405),
            0.9
        )
        XCTAssertLessThan(
            SensorCollectionWaveformMath.heartbeat(at: 0.37),
            0
        )
    }

    func testPermissionOnboardingDoesNotAdvanceWhenRequestDidNotComplete() {
        var progress = PermissionOnboardingProgress(index: 1)

        progress.completeRequest(false)
        XCTAssertEqual(progress.index, 1)

        progress.completeRequest(true)
        XCTAssertEqual(progress.index, 2)

        progress.skipCurrentStep()
        XCTAssertEqual(progress.index, 3)
    }

}
