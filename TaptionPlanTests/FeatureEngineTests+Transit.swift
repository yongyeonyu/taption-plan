import XCTest
import UIKit
import CoreLocation
import StoreKit
import StoreKitTest
import TaptionPlanCore
@testable import TaptionPlan

extension FeatureEngineTests {
    func testIslandStopsAutomaticMovementOnlyWithFreshPersistedStrongStationaryEvidence() {
        let now = Date()
        let moving = ActualRecord(planID: nil, title: "걷기", categoryID: "movement", startedAt: now.addingTimeInterval(-600), source: .motion)
        var reading = SensorReading(timestamp: now.addingTimeInterval(-1), speedMetersPerSecond: 0, motion: .stationary, motionConfidence: .high)
        let savedAt = reading.timestamp
        func resolve(_ record: ActualRecord, _ sample: SensorReading) -> String? {
            TaptionCurrentActivityPolicy.categoryID(actuals: [record], plans: [], at: now, latestSavedAt: savedAt, latestReading: sample)
        }
        XCTAssertEqual(resolve(moving, reading), "activity")
        var confirmed = moving
        confirmed.manuallyCorrected = true
        XCTAssertEqual(resolve(confirmed, reading), "movement")
        reading.speedMetersPerSecond = 8
        XCTAssertEqual(resolve(moving, reading), "movement")
        reading.speedMetersPerSecond = 0
        reading.motionConfidence = .low
        XCTAssertEqual(resolve(moving, reading), "movement")
        reading.motionConfidence = .high
        reading.timestamp = now.addingTimeInterval(-100)
        XCTAssertEqual(resolve(moving, reading), "movement")
        reading.timestamp = now
        XCTAssertEqual(resolve(moving, reading), "movement")
    }

    func testTransitPOIRefreshRequiresBootstrappedActiveScene() {
        XCTAssertFalse(
            MapHomeTransitPOIRefreshPolicy.canStart(
                isBootstrapped: false,
                isSceneActive: true
            )
        )
        XCTAssertFalse(
            MapHomeTransitPOIRefreshPolicy.canStart(
                isBootstrapped: true,
                isSceneActive: false
            )
        )
        XCTAssertTrue(
            MapHomeTransitPOIRefreshPolicy.canStart(
                isBootstrapped: true,
                isSceneActive: true
            )
        )
    }

    func testSubwayWiFiSSIDAllowListNormalizesCarrierNames() {
        XCTAssertTrue(SubwayWiFiSSID.isAllowed("  T WIFI  "))
        XCTAssertTrue(SubwayWiFiSSID.isAllowed("t wifi_secure"))
        XCTAssertTrue(SubwayWiFiSSID.isAllowed(" KT_WiFi_secure "))
        XCTAssertTrue(SubwayWiFiSSID.isAllowed("U+   ZONE"))
        XCTAssertTrue(SubwayWiFiSSID.isAllowed("T wifi zone_secure"))
        XCTAssertTrue(SubwayWiFiSSID.isAllowed("FREE_U+zone"))
        XCTAssertTrue(SubwayWiFiSSID.isAllowed("FREE_Utzone_2.4GHz"))
        XCTAssertTrue(SubwayWiFiSSID.isAllowed("KT GiGA WiFi"))
        XCTAssertTrue(SubwayWiFiSSID.isAllowed("KT WiFi"))
        XCTAssertTrue(SubwayWiFiSSID.isAllowed("KT_Free_WiFi"))
        XCTAssertTrue(SubwayWiFiSSID.isAllowed("T Free WiFi Zone"))
        XCTAssertTrue(SubwayWiFiSSID.isAllowed("T wifi zone"))
        XCTAssertFalse(SubwayWiFiSSID.isAllowed("ollehWiFi"))
        XCTAssertFalse(SubwayWiFiSSID.isAllowed("SKT_WiFi"))
    }

    func testSubwayWiFiSSIDRequiresContinuousCurrentNetworkObservations() {
        XCTAssertFalse(
            SubwayWiFiSSID.hasContinuousEvidence(["T wifi", nil])
        )
        XCTAssertTrue(
            SubwayWiFiSSID.hasContinuousEvidence([
                "T wifi", "T wifi_secure", "KT_WiFi"
            ])
        )
        XCTAssertFalse(
            SubwayWiFiSSID.hasContinuousEvidence([
                "T wifi", "ollehWiFi", "KT_WiFi"
            ])
        )
    }

    func testSubwayWiFiEvidenceKeepsSSIDStreakAndTime() {
        let base = makeDate(2026, 8, 18, 7, 0)
        let samples: [(Double, Double, Double, String, String, Int)] = [
            (0, 37.5248, 126.6744, "가정역", "T wifi", 1),
            (10, 37.5692, 126.6737, "검암역", "T wifi_secure", 2),
            (20, 37.5667, 126.8273, "마곡나루역", "KT_WiFi", 3),
        ]
        let readings = samples.map { minute, latitude, longitude, station, ssid, streak in
            SensorReading(
                timestamp: base.addingTimeInterval(minute * 60),
                point: GeoPoint(
                    latitude: latitude,
                    longitude: longitude,
                    altitude: 20,
                    horizontalAccuracy: 10,
                    verticalAccuracy: 8
                ),
                speedMetersPerSecond: 12,
                motion: .automotive,
                motionConfidence: .high,
                connectedWiFiSSID: ssid,
                subwayWiFiObservationStreak: streak,
                nearbyStation: true,
                nearbyStationName: station,
                matchesRailRoute: true
            )
        }

        let inference = TravelModeClassifier().classify(readings: readings)

        XCTAssertEqual(inference.mode, .subway)
        XCTAssertTrue(inference.evidence.contains(
            "지하철 Wi-Fi KT 계열 연속 3회 16:20"
        ))
        XCTAssertFalse(inference.evidence.contains { $0.contains("KT_WiFi") })
    }

    func testMapHomeSubwayOverlayUsesConfirmedRouteBeforeEstimatedRoute() throws {
        let base = makeDate(2026, 8, 18, 7, 0)
        let readings = [
            (0.0, 37.5248, 126.6744, "가정역"),
            (10.0, 37.5692, 126.6737, "검암역"),
            (20.0, 37.5667, 126.8273, "마곡나루역"),
        ].map { minute, latitude, longitude, station in
            SensorReading(
                timestamp: base.addingTimeInterval(minute * 60),
                point: GeoPoint(
                    latitude: latitude,
                    longitude: longitude,
                    altitude: 20,
                    horizontalAccuracy: 10,
                    verticalAccuracy: 8
                ),
                speedMetersPerSecond: 12,
                motion: .automotive,
                motionConfidence: .high,
                nearbyStation: true,
                nearbyStationName: station,
                matchesRailRoute: true
            )
        }
        let span = TimeSpan(
            start: base,
            end: base.addingTimeInterval(30 * 60)
        )
        let route = try XCTUnwrap(
            SubwayStationCatalog.route(for: ["가정역", "검암역", "마곡나루역"])
        )
        let estimated = TravelSegment(
            mode: .subway,
            span: span,
            distanceMeters: 18_000,
            confidence: .low,
            evidence: ["철도 경로"],
            isConfirmed: false
        )
        let confirmed = TravelSegment(
            mode: .subway,
            span: span,
            distanceMeters: 18_000,
            confidence: .high,
            evidence: ["사용자 확인"],
            isConfirmed: true,
            subwayRoute: route
        )

        let overlays = MapHomeSubwayRouteOverlayEngine.overlays(
            travel: [estimated, confirmed],
            readings: readings,
            day: TimeSpan(
                start: base.addingTimeInterval(-60),
                end: base.addingTimeInterval(31 * 60)
            ),
            through: base.addingTimeInterval(31 * 60)
        )

        XCTAssertEqual(overlays.count, 1)
        XCTAssertEqual(overlays.first?.id, confirmed.id)
        XCTAssertFalse(try XCTUnwrap(overlays.first).estimated)
    }

    func testMapHomeSubwayOverlayDoesNotDrawUnconfirmedWholeRoute() {
        let base = makeDate(2026, 8, 18, 7, 0)
        let readings = [
            (0.0, 37.5248, 126.6744, "가정역"),
            (10.0, 37.5692, 126.6737, "검암역"),
            (20.0, 37.5667, 126.8273, "마곡나루역"),
        ].map { minute, latitude, longitude, station in
            SensorReading(
                timestamp: base.addingTimeInterval(minute * 60),
                point: GeoPoint(
                    latitude: latitude,
                    longitude: longitude,
                    altitude: 20,
                    horizontalAccuracy: 10,
                    verticalAccuracy: 8
                ),
                speedMetersPerSecond: 12,
                motion: .automotive,
                motionConfidence: .high,
                nearbyStation: true,
                nearbyStationName: station,
                matchesRailRoute: true
            )
        }
        let span = TimeSpan(
            start: base,
            end: base.addingTimeInterval(30 * 60)
        )
        let segment = TravelSegment(
            mode: .subway,
            span: span,
            distanceMeters: 18_000,
            confidence: .low,
            evidence: ["철도 경로"],
            isConfirmed: false
        )
        let day = TimeSpan(
            start: base.addingTimeInterval(-60),
            end: base.addingTimeInterval(31 * 60)
        )
        let partial = MapHomeSubwayRouteOverlayEngine.overlays(
            travel: [segment],
            readings: readings,
            day: day,
            through: base.addingTimeInterval(15 * 60)
        )
        let complete = MapHomeSubwayRouteOverlayEngine.overlays(
            travel: [segment],
            readings: readings,
            day: day,
            through: base.addingTimeInterval(31 * 60)
        )

        XCTAssertTrue(partial.isEmpty)
        XCTAssertTrue(complete.isEmpty)
        XCTAssertEqual(readings.count, 3)
    }

    func testTrainMovementDrawsEstimatedSubwayCatalogRouteOnlyWithRailEvidence()
        throws {
        let base = makeDate(2026, 8, 18, 7, 0)
        let readings = [
            SensorReading(
                timestamp: base,
                point: GeoPoint(
                    latitude: 37.5248,
                    longitude: 126.6744,
                    altitude: 20,
                    horizontalAccuracy: 12,
                    verticalAccuracy: 8
                ),
                speedMetersPerSecond: 12,
                motion: .automotive,
                motionConfidence: .high,
                nearbyStation: true,
                nearbyStationName: "가정역",
                matchesRailRoute: true
            ),
            SensorReading(
                timestamp: base.addingTimeInterval(20 * 60),
                point: GeoPoint(
                    latitude: 37.5667,
                    longitude: 126.8273,
                    altitude: 20,
                    horizontalAccuracy: 12,
                    verticalAccuracy: 8
                ),
                speedMetersPerSecond: 12,
                motion: .automotive,
                motionConfidence: .high,
                nearbyStation: true,
                nearbyStationName: "마곡나루역",
                matchesRailRoute: true
            ),
        ]
        let span = TimeSpan(
            start: base,
            end: base.addingTimeInterval(20 * 60)
        )
        let train = TravelSegment(
            mode: .train,
            span: span,
            distanceMeters: 18_000,
            confidence: .medium,
            evidence: ["철도 탑승"]
        )
        let day = TimeSpan(
            start: base.addingTimeInterval(-60),
            end: base.addingTimeInterval(30 * 60)
        )

        let overlays = MapHomeSubwayRouteOverlayEngine.overlays(
            travel: [train],
            readings: readings,
            day: day,
            through: base.addingTimeInterval(20 * 60)
        )

        let overlay = try XCTUnwrap(overlays.first)
        XCTAssertEqual(overlays.count, 1)
        XCTAssertEqual(overlay.id, train.id)
        XCTAssertTrue(overlay.estimated)
        XCTAssertGreaterThanOrEqual(overlay.coordinates.count, 2)

        let unrelatedReadings = [
            SensorReading(
                timestamp: base,
                point: GeoPoint(
                    latitude: 37.4,
                    longitude: 126.4,
                    altitude: 20,
                    horizontalAccuracy: 12,
                    verticalAccuracy: 8
                ),
                speedMetersPerSecond: 12,
                motion: .automotive,
                motionConfidence: .high,
                nearbyStation: true,
                nearbyStationName: "등록되지 않은 출발역",
                matchesRailRoute: true
            ),
            SensorReading(
                timestamp: base.addingTimeInterval(20 * 60),
                point: GeoPoint(
                    latitude: 37.5,
                    longitude: 126.5,
                    altitude: 20,
                    horizontalAccuracy: 12,
                    verticalAccuracy: 8
                ),
                speedMetersPerSecond: 12,
                motion: .automotive,
                motionConfidence: .high,
                nearbyStation: true,
                nearbyStationName: "등록되지 않은 도착역",
                matchesRailRoute: true
            ),
        ]
        XCTAssertTrue(MapHomeSubwayRouteOverlayEngine.overlays(
            travel: [train],
            readings: unrelatedReadings,
            day: day,
            through: base.addingTimeInterval(20 * 60)
        ).isEmpty)
        XCTAssertTrue(MapHomeSubwayRouteOverlayEngine.overlays(
            travel: [train],
            readings: readings,
            day: day,
            through: base.addingTimeInterval(10 * 60)
        ).isEmpty)
    }

    func testMapHomeTimeRailUsesOneNonOverlappingSegmentForEachCanonicalCategory() {
        let day = makeDate(2026, 8, 15)
        let records: [ActualRecord] = [
            ActualRecord(
                planID: nil,
                title: "집안일",
                categoryID: "activity",
                startedAt: day,
                endedAt: day.addingTimeInterval(3 * hour),
                source: .motion,
                behavior: WatchBehaviorKind.housework.rawValue
            ),
            ActualRecord(
                planID: nil,
                title: "업무",
                categoryID: "work",
                startedAt: day.addingTimeInterval(3 * hour),
                endedAt: day.addingTimeInterval(6 * hour),
                source: .location
            ),
            ActualRecord(
                planID: nil,
                title: "수업",
                categoryID: "study",
                startedAt: day.addingTimeInterval(6 * hour),
                endedAt: day.addingTimeInterval(9 * hour),
                source: .location
            ),
            ActualRecord(
                planID: nil,
                title: "취미",
                categoryID: "hobby",
                startedAt: day.addingTimeInterval(9 * hour),
                endedAt: day.addingTimeInterval(12 * hour),
                source: .location
            ),
            ActualRecord(
                planID: nil,
                title: "수면",
                categoryID: "sleep",
                startedAt: day.addingTimeInterval(12 * hour),
                endedAt: day.addingTimeInterval(15 * hour),
                source: .healthKit
            ),
            ActualRecord(
                planID: nil,
                title: "걷기",
                categoryID: "activity",
                startedAt: day.addingTimeInterval(15 * hour),
                endedAt: day.addingTimeInterval(18 * hour),
                source: .motion,
                behavior: WatchBehaviorKind.walking.rawValue
            ),
            ActualRecord(
                planID: nil,
                title: "식사",
                categoryID: "eating",
                startedAt: day.addingTimeInterval(18 * hour),
                endedAt: day.addingTimeInterval(20 * hour),
                source: .location,
                behavior: "meal"
            ),
            ActualRecord(
                planID: nil,
                title: "운동",
                categoryID: "exercise",
                startedAt: day.addingTimeInterval(20 * hour),
                endedAt: day.addingTimeInterval(22 * hour),
                source: .healthKit
            ),
            ActualRecord(
                planID: nil,
                title: "건강관리",
                categoryID: "health",
                startedAt: day.addingTimeInterval(22 * hour),
                endedAt: day.addingTimeInterval(23 * hour),
                source: .healthKit
            ),
            ActualRecord(
                planID: nil,
                title: "미확인",
                categoryID: "activity",
                startedAt: day.addingTimeInterval(23 * hour),
                endedAt: day.addingTimeInterval(24 * hour),
                source: .motion,
                behavior: "unconfirmed-activity"
            ),
        ]

        let segments = MapHomeTimeRailSegmentEngine.segments(
            from: records,
            on: day,
            asOf: day.addingTimeInterval(25 * hour),
            calendar: utcCalendar
        )

        XCTAssertEqual(segments.map(\.categoryID), CanonicalCategoryPalette.orderedIDs)
        XCTAssertEqual(segments.first?.startMinute, 0)
        XCTAssertEqual(segments.last?.endMinute, 1_440)
        XCTAssertTrue(
            zip(segments, segments.dropFirst()).allSatisfy {
                $0.endMinute == $1.startMinute
            }
        )
    }

    func testMapHomeTimeRailResolvesOverlapsAndIgnoresManualRecords() {
        let day = makeDate(2026, 8, 15)
        let records = [
            ActualRecord(
                planID: nil,
                title: "수면",
                categoryID: "sleep",
                startedAt: day,
                endedAt: day.addingTimeInterval(3 * hour),
                source: .healthKit
            ),
            ActualRecord(
                planID: nil,
                title: "걷기",
                categoryID: "activity",
                startedAt: day.addingTimeInterval(hour),
                endedAt: day.addingTimeInterval(2 * hour),
                source: .motion,
                behavior: WatchBehaviorKind.walking.rawValue
            ),
            ActualRecord(
                planID: nil,
                title: "집에서 휴식",
                categoryID: "activity",
                startedAt: day.addingTimeInterval(2 * hour),
                endedAt: day.addingTimeInterval(4 * hour),
                source: .location
            ),
            ActualRecord(
                planID: nil,
                title: "수동 업무",
                categoryID: "work",
                startedAt: day,
                endedAt: day.addingTimeInterval(24 * hour),
                source: .manual
            ),
        ]

        let segments = MapHomeTimeRailSegmentEngine.segments(
            from: records,
            on: day,
            asOf: day.addingTimeInterval(25 * hour),
            calendar: utcCalendar
        )

        XCTAssertEqual(
            MapHomeTimeRailSegmentEngine.segment(at: 90, in: segments)?.categoryID,
            "sleep"
        )
        XCTAssertEqual(
            MapHomeTimeRailSegmentEngine.segment(at: 210, in: segments)?.categoryID,
            "activity"
        )
        XCTAssertEqual(
            MapHomeTimeRailSegmentEngine.segment(at: 500, in: segments)?.categoryID,
            "unconfirmed"
        )
        XCTAssertFalse(segments.contains { $0.categoryID == "work" })
    }

    func testMapHomeTimeRailLetsManualDisplayOverrideWinWithoutMutatingSensorRecord() {
        let day = makeDate(2026, 8, 15)
        let sensor = ActualRecord(
            planID: nil,
            title: "지하철",
            categoryID: "movement",
            startedAt: day.addingTimeInterval(hour),
            endedAt: day.addingTimeInterval(2 * hour),
            source: .motion,
            behavior: "subway"
        )
        let override = ActualRecord(
            planID: nil,
            title: "식사",
            categoryID: "eating",
            startedAt: day.addingTimeInterval(hour),
            endedAt: day.addingTimeInterval(2 * hour),
            source: .manual,
            confidence: .high,
            behavior: "meal",
            manuallyCorrected: true
        )

        let segments = MapHomeTimeRailSegmentEngine.segments(
            from: [sensor, override],
            on: day,
            asOf: day.addingTimeInterval(25 * hour),
            calendar: utcCalendar
        )

        XCTAssertEqual(
            MapHomeTimeRailSegmentEngine.segment(at: 90, in: segments)?.categoryID,
            "eating"
        )
        XCTAssertEqual(sensor.categoryID, "movement")
        XCTAssertEqual(sensor.behavior, "subway")
    }

    func testMapHomeTimeRailIncludesPersistedSubwayTravel() {
        let day = makeDate(2026, 8, 12)
        let subway = TravelSegment(
            mode: .subway,
            span: TimeSpan(
                start: day.addingTimeInterval(21 * hour),
                end: day.addingTimeInterval(21 * hour + 35 * 60)
            ),
            distanceMeters: 18_000,
            confidence: .high,
            evidence: ["사용자 지정 지하철역 일치"]
        )

        let segments = MapHomeTimeRailSegmentEngine.segments(
            from: [],
            travel: [subway],
            on: day,
            asOf: day.addingTimeInterval(24 * hour),
            calendar: utcCalendar
        )
        let segment = MapHomeTimeRailSegmentEngine.segment(
            at: 21 * 60 + 10,
            in: segments
        )

        XCTAssertEqual(segment?.categoryID, "movement")
        XCTAssertEqual(segment?.title, "지하철 탑승")
        XCTAssertEqual(segment?.sourceID, subway.id)
    }

    func testMapHomeTimeRailUserOverrideWinsConfirmedTravel() {
        let day = makeDate(2026, 8, 12)
        let subway = TravelSegment(
            mode: .subway,
            span: TimeSpan(
                start: day.addingTimeInterval(hour),
                end: day.addingTimeInterval(2 * hour)
            ),
            distanceMeters: 12_000,
            confidence: .high,
            evidence: ["사용자 확인"],
            isConfirmed: true
        )
        let override = ActualRecord(
            planID: nil,
            title: "미확인",
            categoryID: "unconfirmed",
            startedAt: subway.span.start,
            endedAt: subway.span.end,
            source: .manual,
            behavior: "unconfirmed-gap",
            modelVersion: ActivitySectionOverrideEngine.modelVersion,
            manuallyCorrected: true
        )

        let segments = MapHomeTimeRailSegmentEngine.segments(
            from: [override],
            travel: [subway],
            on: day,
            asOf: day.addingTimeInterval(24 * hour),
            calendar: utcCalendar
        )

        XCTAssertEqual(
            MapHomeTimeRailSegmentEngine.segment(at: 90, in: segments)?.categoryID,
            "unconfirmed"
        )
    }

    func testMapHomeTimeRailMergesSameCategoryAndKeepsAllSources() {
        let day = makeDate(2026, 8, 12)
        let first = ActualRecord(
            planID: nil,
            title: "오전 업무",
            categoryID: "work",
            startedAt: day.addingTimeInterval(9 * hour),
            endedAt: day.addingTimeInterval(10 * hour),
            source: .location
        )
        let second = ActualRecord(
            planID: nil,
            title: "회의",
            categoryID: "work",
            startedAt: day.addingTimeInterval(10 * hour),
            endedAt: day.addingTimeInterval(11 * hour),
            source: .appUsage
        )

        let segments = MapHomeTimeRailSegmentEngine.segments(
            from: [first, second],
            on: day,
            asOf: day.addingTimeInterval(24 * hour),
            calendar: utcCalendar
        )
        let work = segments.first { $0.categoryID == "work" }

        XCTAssertEqual(work?.startMinute, 540)
        XCTAssertEqual(work?.endMinute, 660)
        XCTAssertEqual(Set(work?.sourceIDs ?? []), Set([first.id, second.id]))
    }

    func testMapHomeTimeRailDoesNotMergeDifferentMovementModes() {
        let day = makeDate(2026, 8, 12)
        let bus = TravelSegment(
            mode: .bus,
            span: TimeSpan(
                start: day.addingTimeInterval(hour),
                end: day.addingTimeInterval(2 * hour)
            ),
            distanceMeters: 8_000,
            confidence: .high,
            evidence: []
        )
        let subway = TravelSegment(
            mode: .subway,
            span: TimeSpan(
                start: day.addingTimeInterval(2 * hour),
                end: day.addingTimeInterval(3 * hour)
            ),
            distanceMeters: 12_000,
            confidence: .high,
            evidence: []
        )

        let segments = MapHomeTimeRailSegmentEngine.segments(
            from: [],
            travel: [bus, subway],
            on: day,
            asOf: day.addingTimeInterval(24 * hour),
            calendar: utcCalendar
        ).filter { $0.categoryID == "movement" }

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.map(\.behavior), ["bus", "subway"])
    }

    func testMapHomeTimeRailClipsOngoingAutomaticRecordWithoutMutatingIt() {
        let day = makeDate(2026, 8, 15)
        let ongoing = ActualRecord(
            planID: nil,
            title: "걷기",
            categoryID: "activity",
            startedAt: day.addingTimeInterval(10 * hour),
            source: .motion,
            behavior: WatchBehaviorKind.walking.rawValue
        )

        let segments = MapHomeTimeRailSegmentEngine.segments(
            from: [ongoing],
            on: day,
            asOf: day.addingTimeInterval(10 * hour + 20 * 60),
            calendar: utcCalendar
        )

        XCTAssertNil(ongoing.endedAt)
        XCTAssertEqual(
            MapHomeTimeRailSegmentEngine.segment(at: 619, in: segments)?.categoryID,
            "movement"
        )
        XCTAssertEqual(
            MapHomeTimeRailSegmentEngine.segment(at: 620, in: segments)?.categoryID,
            "unconfirmed"
        )
    }

    func testCanonicalMovementLabelsKeepCarDistinctFromSubway() {
        XCTAssertEqual(
            RecordAnalysisCategoryNormalizer.categoryID(
                for: "activity",
                title: "car"
            ),
            "movement"
        )
        XCTAssertEqual(RecordAnalysisCategoryPolicy.movementTitle(for: .car), "자동차")
        XCTAssertEqual(RecordAnalysisCategoryPolicy.movementTitle(for: .subway), "지하철")
    }

    func testSubwayNeedsCombinedSignals() {
        let base = makeDate(2026, 7, 30, 8, 0)
        let readings: [SensorReading] = (0..<6).map { index -> SensorReading in
            SensorReading(
                timestamp: base.addingTimeInterval(Double(index) * 60),
                speedMetersPerSecond: 12,
                motion: .automotive,
                motionConfidence: .high,
                // 지하철은 고도 변화가 5m 이상이어야 한다(SUB1029A01). 실제 역 출입은 13~31m였다.
                relativeAltitudeMeters: Double(index) * -2,
                gpsAvailable: index < 2,
                nearbyStation: true,
                matchesRailRoute: true
            )
        }
        let result = TravelModeClassifier().classify(readings: readings)
        XCTAssertEqual(result.mode, .subway)
        XCTAssertEqual(result.confidence, .high)
        XCTAssertTrue(result.evidence.contains("지하철 복합 신호 충족"))
    }

    func testStationToStationUndergroundTravelIdentifiesSubwayWithoutVibration() {
        let base = makeDate(2026, 8, 8, 8, 0)
        let altitudes = [0.0, -2, -8, -12, -10, -6, -2, 0]
        let readings = (0..<altitudes.count).map { index in
            let stationName: String?
            if index < 2 {
                stationName = "강남역"
            } else if index >= 6 {
                stationName = "홍대입구역"
            } else {
                stationName = nil
            }
            return SensorReading(
                timestamp: base.addingTimeInterval(Double(index) * 60),
                speedMetersPerSecond: 11,
                motion: .automotive,
                motionConfidence: .high,
                relativeAltitudeMeters: altitudes[index],
                stepCount: 200 + index,
                watchAccelerationStandardDeviationG: 0.004,
                watchAccelerationMeanJerkGPerSecond: 0.01,
                gpsAvailable: index < 2 || index >= 6,
                nearbyStation: stationName != nil,
                nearbyStationName: stationName,
                matchesRailRoute: true
            )
        }

        let result = TravelModeClassifier().classify(readings: readings)
        XCTAssertEqual(result.mode, .subway)
        XCTAssertEqual(result.confidence, .high)
        XCTAssertTrue(
            result.evidence.contains("지하철역 강남역 → 홍대입구역"),
            "실제 근거: \(result.evidence)"
        )
        XCTAssertTrue(
            result.evidence.contains("Apple Watch 진동 없음"),
            "실제 근거: \(result.evidence)"
        )
    }

    func testUndergroundVibrationWithoutStationContextDoesNotBecomeSubway() {
        let base = makeDate(2026, 7, 30, 8, 0)
        let readings = (0..<6).map { index in
            SensorReading(
                timestamp: base.addingTimeInterval(Double(index) * 60),
                speedMetersPerSecond: 12,
                motion: .automotive,
                motionConfidence: .high,
                relativeAltitudeMeters: Double(index) * -1,
                stepCount: 20,
                watchAccelerationStandardDeviationG: 0.04,
                watchAccelerationMeanJerkGPerSecond: 0.16,
                gpsAvailable: index < 2,
                frequentStops: true
            )
        }

        let inference = TravelModeClassifier().classify(readings: readings)
        XCTAssertNotEqual(
            inference.mode,
            .subway,
            "실제 근거: \(inference.evidence)"
        )
    }

    func testRoadContextPrioritizesCarWithoutBusStops() {
        let base = makeDate(2026, 7, 30, 8, 0)
        let readings = (0..<6).map { index in
            SensorReading(
                timestamp: base.addingTimeInterval(Double(index) * 60),
                speedMetersPerSecond: 13,
                motion: .automotive,
                motionConfidence: .high,
                stepCount: 10,
                behaviorEvidence: ["Apple 지도 도로 인접"]
            )
        }

        let result = TravelModeClassifier().classify(readings: readings)
        XCTAssertEqual(result.mode, .car)
        XCTAssertTrue(
            result.evidence.contains("도로 위 차량 속도·자동차 모션 우선")
        )
    }

    func testSubwayModeRemainsLockedAcrossRefresh() {
        let start = makeDate(2026, 8, 12, 10, 0)
        let old = TravelSegment(
            mode: .subway,
            span: TimeSpan(start: start, end: start.addingTimeInterval(hour)),
            distanceMeters: 5_000,
            confidence: .high,
            evidence: ["철도 경로"],
            isConfirmed: true,
            isClassificationLocked: true
        )
        let fresh = TravelSegment(
            mode: .car,
            span: TimeSpan(
                start: start.addingTimeInterval(60),
                end: start.addingTimeInterval(hour + 60)
            ),
            distanceMeters: 5_100,
            confidence: .medium,
            evidence: ["차량 후보"]
        )

        let result = ActivityClassificationLockEngine.mergingLockedTravel(
            existing: [old],
            fresh: [fresh],
            inside: TimeSpan(start: start, end: start.addingTimeInterval(2 * hour))
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].mode, .subway)
        XCTAssertTrue(result[0].isClassificationLocked)
    }

    /// 다른 날 확인한 보정이 옮겨 와 "확정"으로 저장된 지하철은, 새 판정이 자동차면 잠겨 있어도 물려받지 않는다(ARC1030A04).
    func testRememberedOnlyLockedSubwayYieldsToFreshCar() {
        let start = makeDate(2026, 10, 30, 9, 30)
        let remembered = TravelSegment(
            mode: .subway, span: TimeSpan(start: start, end: start.addingTimeInterval(hour)),
            distanceMeters: 20_000, confidence: .high, evidence: ["사용자 확인 기억"],
            isConfirmed: true, isClassificationLocked: true
        )
        let railBacked = TravelSegment(
            mode: .subway, span: TimeSpan(start: start, end: start.addingTimeInterval(hour)),
            distanceMeters: 20_000, confidence: .high, evidence: ["사용자 확인 기억", "철도 경로"],
            isConfirmed: true, isClassificationLocked: true
        )
        let fresh = TravelSegment(
            mode: .car, span: TimeSpan(start: start, end: start.addingTimeInterval(hour)),
            distanceMeters: 21_000, confidence: .medium, evidence: ["iPhone Core Motion 자동차"]
        )
        let inside = TimeSpan(start: start, end: start.addingTimeInterval(2 * hour))

        let result = ActivityClassificationLockEngine.mergingLockedTravel(existing: [remembered], fresh: [fresh], inside: inside)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].mode, .car)

        let kept = ActivityClassificationLockEngine.mergingLockedTravel(existing: [railBacked], fresh: [fresh], inside: inside)
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept[0].mode, .subway)
    }

    func testUnvalidatedLockedSubwayIsReevaluatedFromFreshTravel() {
        let start = makeDate(2026, 8, 12, 10, 0)
        let old = TravelSegment(
            mode: .subway,
            span: TimeSpan(start: start, end: start.addingTimeInterval(hour)),
            distanceMeters: 5_000,
            confidence: .high,
            evidence: ["자동 추정"],
            isClassificationLocked: true
        )
        let fresh = TravelSegment(
            mode: .car,
            span: TimeSpan(
                start: start.addingTimeInterval(60),
                end: start.addingTimeInterval(hour + 60)
            ),
            distanceMeters: 5_100,
            confidence: .medium,
            evidence: ["차량 후보"]
        )

        let result = ActivityClassificationLockEngine.mergingLockedTravel(
            existing: [old],
            fresh: [fresh],
            inside: TimeSpan(start: start, end: start.addingTimeInterval(2 * hour))
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].mode, .car)
        XCTAssertTrue(result[0].isClassificationLocked)
    }

    func testIPhoneBehaviorLabelDoesNotPromoteSubwayWithoutRailEvidence() {
        let start = makeDate(2026, 8, 12, 10, 0)
        let readings = [
            SensorReading(
                timestamp: start,
                motion: .stationary,
                gpsAvailable: false,
                behavior: WatchBehaviorKind.subway.rawValue,
                behaviorConfidenceScore: 0.9,
                behaviorEvidence: ["Watch"],
                sourceDevice: .iPhone
            ),
            SensorReading(
                timestamp: start.addingTimeInterval(10 * 60),
                motion: .stationary,
                gpsAvailable: false,
                behavior: WatchBehaviorKind.subway.rawValue,
                behaviorConfidenceScore: 0.9,
                behaviorEvidence: ["Watch"],
                sourceDevice: .iPhone
            ),
        ]

        let inference = TravelModeClassifier().classify(readings: readings)

        XCTAssertFalse(inference.mode == TravelMode.subway)
    }

    func testResolvedSubwayReplacesLockedWalkingClassification() {
        let start = makeDate(2026, 9, 4, 9, 30)
        let old = TravelSegment(
            mode: .walking,
            span: TimeSpan(start: start, end: start.addingTimeInterval(15 * 60)),
            distanceMeters: 5_000,
            confidence: .high,
            evidence: ["걷기"],
            isClassificationLocked: true
        )
        let route = SubwayRoutePath(
            stops: [
                SubwayRouteStop(
                    lineName: "인천2호선",
                    order: 11,
                    stationName: "가정",
                    latitude: 37.5248,
                    longitude: 126.6744
                ),
                SubwayRouteStop(
                    lineName: "인천2호선",
                    order: 10,
                    stationName: "서구청",
                    latitude: 37.5441,
                    longitude: 126.6770
                ),
            ],
            lineNames: ["인천2호선"],
            transferStationNames: []
        )
        let fresh = TravelSegment(
            mode: .subway,
            span: TimeSpan(
                start: start.addingTimeInterval(60),
                end: start.addingTimeInterval(16 * 60)
            ),
            distanceMeters: 5_100,
            confidence: .high,
            evidence: ["역 좌표 궤적 일치"],
            subwayRoute: route
        )

        let result = ActivityClassificationLockEngine.mergingLockedTravel(
            existing: [old],
            fresh: [fresh],
            inside: TimeSpan(start: start, end: start.addingTimeInterval(hour))
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].mode, TravelMode.subway)
        XCTAssertEqual(result[0].subwayRoute, route)
        XCTAssertTrue(result[0].isClassificationLocked)
    }

    func testAutomotivePersistsWhenCoreMotionAlsoReportsStationary() {
        XCTAssertEqual(
            MotionKindResolver.resolve(
                stationary: true,
                walking: false,
                running: false,
                cycling: false,
                automotive: true
            ),
            .automotive
        )
        XCTAssertEqual(
            MotionKindResolver.resolve(
                stationary: false,
                walking: true,
                running: true,
                cycling: false,
                automotive: false
            ),
            .running
        )
        XCTAssertEqual(
            MotionKindResolver.resolve(
                stationary: false,
                walking: true,
                running: false,
                cycling: false,
                automotive: true
            ),
            .automotive
        )
    }

    /// 과거에 "집→회사 = 지하철"로 확인한 기억이, 센서가 자동차 모션이고 철도 신호가 없는 날에는 덮어쓰지 않는다(ARC1030A04).
    func testRememberedSubwayCorrectionDoesNotOverrideAutomotiveEvidence() throws {
        let base = makeDate(2026, 10, 30, 9, 0)
        let places = [
            PlaceStay(placeKey: "home", displayName: "집",
                span: TimeSpan(start: base.addingTimeInterval(-hour), end: base), confidence: .high),
            PlaceStay(placeKey: "office", displayName: "회사",
                span: TimeSpan(start: base.addingTimeInterval(hour), end: base.addingTimeInterval(2 * hour)), confidence: .high),
        ]
        let segment = TravelSegment(
            fromPlaceID: places[0].id, toPlaceID: places[1].id, mode: .car,
            span: TimeSpan(start: base, end: base.addingTimeInterval(hour)),
            distanceMeters: 21_000, confidence: .medium, evidence: ["iPhone Core Motion 자동차"]
        )
        // 어제 같은 두 장소 사이를 지하철로 확인해 둔 보정(다른 날의 구간).
        var yesterday = segment
        yesterday.mode = .subway
        yesterday.span = TimeSpan(
            start: segment.span.start.addingTimeInterval(-24 * hour),
            end: segment.span.end.addingTimeInterval(-24 * hour)
        )
        let corrections = MovementCorrectionEngine.recording(
            mode: .subway, for: yesterday, places: places, existing: [], at: base.addingTimeInterval(-12 * hour)
        )
        func reading(_ minute: Int, motion: MotionKind, rail: Bool = false) -> SensorReading {
            var value = SensorReading(timestamp: base.addingTimeInterval(Double(minute) * 60), motion: motion)
            value.matchesRailRoute = rail
            return value
        }
        let automotive = (0..<40).map { reading($0, motion: .automotive) }
        // 자동차 모션뿐이고 철도 신호가 없으면 기억을 적용하지 않는다.
        let vetoed = try XCTUnwrap(MovementCorrectionEngine.applying(
            corrections, to: [segment], places: places, readings: automotive).first)
        XCTAssertEqual(vetoed.mode, .car)
        XCTAssertFalse(vetoed.evidence.contains("사용자 확인 기억"))
        // 센서 근거가 없으면 예전처럼 기억을 적용한다.
        let applied = try XCTUnwrap(MovementCorrectionEngine.applying(
            corrections, to: [segment], places: places, readings: []).first)
        XCTAssertEqual(applied.mode, .subway)
        // 철도 경로가 맞는 기록이 하나라도 있으면 기억을 적용한다.
        let withRail = automotive + [reading(41, motion: .automotive, rail: true)]
        let appliedWithRail = try XCTUnwrap(MovementCorrectionEngine.applying(
            corrections, to: [segment], places: places, readings: withRail).first)
        XCTAssertEqual(appliedWithRail.mode, .subway)
    }

    func testSubwayCatalogBuildsMagongnaruTransferToGajeong() {
        let route = SubwayStationCatalog.route(
            for: ["마곡나루역", "검암역", "가정역"]
        )

        XCTAssertEqual(route?.transferStationNames, ["검암"])
        XCTAssertEqual(route?.lineNames, ["공항철도", "인천2호선"])
        XCTAssertGreaterThan(route?.coordinates.count ?? 0, 2)
        XCTAssertEqual(route?.stops.first?.stationName, "마곡나루")
        XCTAssertEqual(route?.stops.last?.stationName, "가정")
    }

    func testUserSubwayLocationsConfirmDepartureTransferArrivalRoute() {
        let base = makeDate(2026, 8, 12, 8, 0)
        let stationData: [(String, Double)] = [
            ("가정역", 0),
            ("검암역", 0.01),
            ("마곡나루역", 0.02),
        ]
        let locations = stationData.map { value in
            UserTransitLocation(
                name: value.0,
                kind: .subwayStation,
                point: GeoPoint(
                    latitude: 0,
                    longitude: value.1,
                    altitude: 0,
                    horizontalAccuracy: -1,
                    verticalAccuracy: -1
                ),
                radiusMeters: 100
            )
        }
        let readings = stationData.enumerated().map { index, value in
            SensorReading(
                timestamp: base.addingTimeInterval(Double(index) * 60),
                point: GeoPoint(
                    latitude: 0,
                    longitude: value.1,
                    altitude: 0,
                    horizontalAccuracy: 10,
                    verticalAccuracy: 10
                ),
                speedMetersPerSecond: 12,
                motion: .automotive,
                motionConfidence: .high
            )
        }

        let result = TravelModeClassifier().classify(
            readings: readings,
            userTransitLocations: locations
        )

        XCTAssertEqual(result.mode, .subway)
        XCTAssertEqual(result.confidence, .high)
        XCTAssertEqual(result.subwayRoute?.stops.first?.stationName, "가정")
        XCTAssertEqual(result.subwayRoute?.stops.last?.stationName, "마곡나루")
        XCTAssertTrue(
            result.evidence.contains {
                $0.hasPrefix("사용자 지정 지하철역 일치")
            }
        )
    }

    func testApproximateGPSDoesNotUseRegisteredSubwayEndpoints() {
        let base = makeDate(2026, 8, 12, 8, 0)
        let stationData: [(String, Double, Double)] = [
            ("가정역", 37.5248, 126.6744),
            ("마곡나루역", 37.5667, 126.8273),
        ]
        let locations = stationData.map { name, latitude, longitude in
            UserTransitLocation(
                name: name,
                kind: .subwayStation,
                point: GeoPoint(
                    latitude: latitude,
                    longitude: longitude,
                    altitude: 0,
                    horizontalAccuracy: -1,
                    verticalAccuracy: -1
                ),
                radiusMeters: 100
            )
        }
        let readings = stationData.enumerated().map { index, value in
            SensorReading(
                timestamp: base.addingTimeInterval(Double(index) * 10 * 60),
                point: GeoPoint(
                    latitude: value.1,
                    longitude: value.2,
                    altitude: 0,
                    horizontalAccuracy: 10,
                    verticalAccuracy: 10
                ),
                locationFixQuality: .approximate,
                speedMetersPerSecond: 12,
                motion: .automotive,
                motionConfidence: .high,
                gpsAvailable: false
            )
        }

        let result = TravelModeClassifier().classify(
            readings: readings,
            userTransitLocations: locations
        )

        XCTAssertNotEqual(result.mode, .subway)
    }

    func testSingleUserSubwayStationAndCarrierWiFiOverrideAutomotive() {
        let base = makeDate(2026, 8, 12, 21, 0)
        let point = GeoPoint(
            latitude: 37.5667,
            longitude: 126.8273,
            altitude: 20,
            horizontalAccuracy: 10,
            verticalAccuracy: 8
        )
        let location = UserTransitLocation(
            name: "마곡나루역",
            kind: .subwayStation,
            point: point,
            radiusMeters: 150
        )
        let readings = [1, 2].map { streak in
            SensorReading(
                timestamp: base.addingTimeInterval(Double(streak - 1) * 10),
                point: point,
                speedMetersPerSecond: 11,
                motion: .automotive,
                motionConfidence: .high,
                connectedWiFiSSID: streak == 1 ? "T wifi" : "T wifi_secure",
                subwayWiFiObservationStreak: streak
            )
        }

        let result = TravelModeClassifier().classify(
            readings: readings,
            userTransitLocations: [location]
        )

        XCTAssertEqual(result.mode, .subway)
        XCTAssertEqual(result.confidence, .medium)
        XCTAssertTrue(result.evidence.contains("사용자 지정 지하철역 일치 1곳"))
        XCTAssertTrue(result.evidence.contains { $0.contains("T 계열 연속 2회") })
        XCTAssertFalse(result.evidence.contains { $0.contains("T wifi_secure") })
    }

    func testSubwayCatalogRejectsRoundTripRoute() {
        let route = SubwayStationCatalog.route(
            for: [
                "김포공항역", "공항시장역", "신방화역", "마곡나루역",
                "김포공항역", "계양역",
            ]
        )

        XCTAssertNil(route)
    }

    func testStationStopPatternOverridesAutomotiveForTransferCommute() {
        let base = makeDate(2026, 8, 12, 8, 0)
        let samples: [(Double, Double, Double, String)] = [
            (0, 37.5248, 126.6744, "가정역"),
            (60, 37.5692, 126.6737, "검암역"),
            (120, 37.5667, 126.8273, "마곡나루역"),
        ]
        let readings = samples.map { minute, latitude, longitude, name in
            SensorReading(
                timestamp: base.addingTimeInterval(minute * 60),
                point: GeoPoint(
                    latitude: latitude,
                    longitude: longitude,
                    altitude: 20,
                    horizontalAccuracy: 12,
                    verticalAccuracy: 8
                ),
                speedMetersPerSecond: 0,
                motion: .stationary,
                motionConfidence: .high,
                nearbyStation: true,
                nearbyStationName: name,
                matchesRailRoute: true
            )
        }

        let result = TravelModeClassifier().classify(readings: readings)

        XCTAssertEqual(result.mode, .subway)
        XCTAssertEqual(result.confidence, .high)
        XCTAssertTrue(result.evidence.contains("출발역·환승역·도착역 순서"))
        XCTAssertTrue(result.evidence.contains("역별 가다·서다 정차 패턴"))
    }

    func testCoordinateRouteWinsConflictingStationEnrichment() throws {
        let base = makeDate(2026, 8, 12, 8, 0)
        let samples: [(Double, Double, Double, String)] = [
            (0, 37.5248, 126.6744, "김포공항역"),
            (12, 37.5692, 126.6737, "공항시장역"),
            (24, 37.57127, 126.7359, "신방화역"),
            (36, 37.5667, 126.8273, "마곡나루역"),
        ]
        let readings = samples.map { minute, latitude, longitude, name in
            SensorReading(
                timestamp: base.addingTimeInterval(minute * 60),
                point: GeoPoint(
                    latitude: latitude,
                    longitude: longitude,
                    altitude: 20,
                    horizontalAccuracy: 12,
                    verticalAccuracy: 8
                ),
                speedMetersPerSecond: 12,
                motion: .automotive,
                motionConfidence: .high,
                nearbyStation: true,
                nearbyStationName: name,
                matchesRailRoute: true
            )
        }

        let result = TravelModeClassifier().classify(readings: readings)

        XCTAssertEqual(result.mode, .subway)
        XCTAssertEqual(result.subwayRoute?.stops.first?.stationName, "가정")
        XCTAssertEqual(result.subwayRoute?.stops.last?.stationName, "마곡나루")
        XCTAssertEqual(result.subwayRoute?.transferStationNames, ["검암"])
    }

    func testSHE905H001DenseSubwayTrajectoryStaysBounded() {
        let base = makeDate(2026, 8, 11, 0, 0)
        let stations = [
            (37.5248, 126.6744),
            (37.5692, 126.6737),
            (37.57127, 126.7359),
            (37.5667, 126.8273),
        ]
        let readings = (0..<96).map { index in
            let coordinate = stations[index % stations.count]
            return SensorReading(
                timestamp: base.addingTimeInterval(Double(index) * 180),
                point: GeoPoint(
                    latitude: coordinate.0,
                    longitude: coordinate.1,
                    altitude: 20,
                    horizontalAccuracy: 12,
                    verticalAccuracy: 8
                ),
                speedMetersPerSecond: 12,
                motion: .automotive,
                motionConfidence: .high
            )
        }

        measure {
            XCTAssertNotNil(
                SubwayStationCatalog.coordinateTrajectory(from: readings)
            )
        }
    }

    func testCoordinateTrajectoryCreatesSubwaySegmentAcrossUnknownMotion() throws {
        let base = makeDate(2026, 8, 11, 21, 54)
        let samples: [(Double, Double, Double, MotionKind)] = [
            (0, 37.5667, 126.8273, .unknown),
            (10, 37.57127, 126.7359, .unknown),
            (20, 37.5692, 126.6737, .unknown),
            (30, 37.5248, 126.6744, .automotive),
        ]
        let readings = samples.map { minute, latitude, longitude, motion in
            SensorReading(
                timestamp: base.addingTimeInterval(minute * 60),
                point: GeoPoint(
                    latitude: latitude,
                    longitude: longitude,
                    altitude: 20,
                    horizontalAccuracy: 12,
                    verticalAccuracy: 8
                ),
                speedMetersPerSecond: 12,
                motion: motion,
                motionConfidence: .medium,
                stepCount: 400 + Int(minute * 8)
            )
        }
        let car = TravelSegment(
            mode: .car,
            span: TimeSpan(
                start: base,
                end: base.addingTimeInterval(30 * 60)
            ),
            distanceMeters: 18_000,
            confidence: .medium,
            evidence: ["iPhone Core Motion 자동차"]
        )

        let merged = AppleDeviceGroundTruthEngine.mergingTravel(
            gpsSegments: [car],
            motionActivities: [],
            pedometer: nil,
            readings: readings
        )
        let subway = try XCTUnwrap(merged.first)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(subway.mode, .subway)
        XCTAssertEqual(subway.subwayRoute?.lineNames, ["공항철도", "인천2호선"])
        XCTAssertEqual(subway.subwayRoute?.transferStationNames, ["검암"])
        XCTAssertTrue(subway.evidence.contains("원본 GPS 철도 궤적 복원"))
    }

    func testSubwayTravelSegmentAllowsBatterySaverReadingCadence() throws {
        let base = makeDate(2026, 8, 11, 9, 35)
        let samples: [(Double, Double, Double)] = [
            (0, 37.5248, 126.6744),
            (15, 37.5692, 126.6737),
            (30, 37.57127, 126.7359),
            (45, 37.5667, 126.8273),
        ]
        let readings = samples.map { minute, latitude, longitude in
            SensorReading(
                timestamp: base.addingTimeInterval(minute * 60),
                point: GeoPoint(
                    latitude: latitude,
                    longitude: longitude,
                    altitude: 20,
                    horizontalAccuracy: 12,
                    verticalAccuracy: 8
                ),
                speedMetersPerSecond: 12,
                motion: .automotive,
                motionConfidence: .high
            )
        }

        let result = try XCTUnwrap(
            SubwayTravelSegmentEngine.segments(from: readings).first
        )

        XCTAssertEqual(result.mode, .subway)
        XCTAssertEqual(result.subwayRoute?.transferStationNames, ["검암"])
        XCTAssertEqual(result.span.duration, 45 * 60)
    }

    func testSubwayTravelSegmentClampsInvalidReadingGap() {
        let base = makeDate(2026, 8, 11, 9, 35)
        let samples: [(Double, Double, Double)] = [
            (0, 37.5248, 126.6744),
            (15, 37.5692, 126.6737),
            (30, 37.57127, 126.7359),
            (45, 37.5667, 126.8273),
        ]
        let readings = samples.map { minute, latitude, longitude in
            SensorReading(
                timestamp: base.addingTimeInterval(minute * 60),
                point: GeoPoint(
                    latitude: latitude,
                    longitude: longitude,
                    altitude: 20,
                    horizontalAccuracy: 12,
                    verticalAccuracy: 8
                ),
                speedMetersPerSecond: 12,
                motion: .automotive,
                motionConfidence: .high
            )
        }

        XCTAssertEqual(
            SubwayTravelSegmentEngine.segments(
                from: readings,
                maximumReadingGap: .nan
            ).count,
            1
        )
    }

    func testTwoStationRoadMovementDoesNotCreateSubwayTrajectory() {
        let base = makeDate(2026, 8, 11, 9, 35)
        let readings = [
            SensorReading(
                timestamp: base,
                point: GeoPoint(
                    latitude: 37.5248,
                    longitude: 126.6744,
                    altitude: 20,
                    horizontalAccuracy: 10,
                    verticalAccuracy: 8
                ),
                speedMetersPerSecond: 12,
                motion: .automotive,
                motionConfidence: .high
            ),
            SensorReading(
                timestamp: base.addingTimeInterval(10 * 60),
                point: GeoPoint(
                    latitude: 37.5692,
                    longitude: 126.6737,
                    altitude: 20,
                    horizontalAccuracy: 10,
                    verticalAccuracy: 8
                ),
                speedMetersPerSecond: 12,
                motion: .automotive,
                motionConfidence: .high
            ),
        ]

        XCTAssertNil(SubwayStationCatalog.coordinateTrajectory(from: readings))
        XCTAssertTrue(SubwayTravelSegmentEngine.segments(from: readings).isEmpty)
    }

    func testSingleRailMatchDoesNotPromoteTwoStationCarToSubway() {
        let base = makeDate(2026, 8, 11, 9, 35)
        let readings = [
            SensorReading(
                timestamp: base,
                point: GeoPoint(
                    latitude: 37.5248,
                    longitude: 126.6744,
                    altitude: 20,
                    horizontalAccuracy: 10,
                    verticalAccuracy: 8
                ),
                speedMetersPerSecond: 12,
                motion: .automotive,
                motionConfidence: .high,
                nearbyStation: true,
                nearbyStationName: "가정역",
                matchesRailRoute: true
            ),
            SensorReading(
                timestamp: base.addingTimeInterval(5 * 60),
                point: nil,
                speedMetersPerSecond: 12,
                motion: .automotive,
                motionConfidence: .high,
                gpsAvailable: false
            ),
            SensorReading(
                timestamp: base.addingTimeInterval(10 * 60),
                point: nil,
                speedMetersPerSecond: 12,
                motion: .automotive,
                motionConfidence: .high,
                gpsAvailable: false
            ),
            SensorReading(
                timestamp: base.addingTimeInterval(15 * 60),
                point: GeoPoint(
                    latitude: 37.5667,
                    longitude: 126.8273,
                    altitude: 20,
                    horizontalAccuracy: 10,
                    verticalAccuracy: 8
                ),
                speedMetersPerSecond: 12,
                motion: .automotive,
                motionConfidence: .high,
                nearbyStation: true,
                nearbyStationName: "마곡나루역"
            ),
        ]

        XCTAssertNotNil(
            SubwayStationCatalog.sparseEndpointTrajectory(from: readings)
        )
        XCTAssertNotEqual(
            TravelModeClassifier().classify(readings: readings).mode,
            .subway
        )
        XCTAssertTrue(SubwayTravelSegmentEngine.segments(from: readings).isEmpty)
    }

    func testSparseRailEndpointsRestoreSubwayWithoutRoadFalsePositive() throws {
        let base = makeDate(2026, 8, 11, 7, 0)
        let readings = [
            SensorReading(
                timestamp: base,
                point: GeoPoint(
                    latitude: 37.5248,
                    longitude: 126.6744,
                    altitude: 20,
                    horizontalAccuracy: 12,
                    verticalAccuracy: 8
                ),
                speedMetersPerSecond: 12,
                motion: .automotive,
                motionConfidence: .high,
                nearbyStation: true,
                nearbyStationName: "가정역",
                matchesRailRoute: true
            ),
            SensorReading(
                timestamp: base.addingTimeInterval(10 * 60),
                point: nil,
                speedMetersPerSecond: nil,
                motion: .automotive,
                motionConfidence: .high,
                gpsAvailable: false
            ),
            SensorReading(
                timestamp: base.addingTimeInterval(20 * 60),
                point: GeoPoint(
                    latitude: 37.5667,
                    longitude: 126.8273,
                    altitude: 20,
                    horizontalAccuracy: 12,
                    verticalAccuracy: 8
                ),
                speedMetersPerSecond: 12,
                motion: .automotive,
                motionConfidence: .high,
                nearbyStation: true,
                nearbyStationName: "마곡나루역",
                matchesRailRoute: true
            ),
        ]

        let trajectory = try XCTUnwrap(
            SubwayStationCatalog.sparseEndpointTrajectory(from: readings)
        )
        let result = TravelModeClassifier().classify(readings: readings)

        XCTAssertTrue(trajectory.isSparseEndpointTrajectory)
        XCTAssertEqual(result.mode, .subway)
        XCTAssertEqual(result.subwayRoute?.transferStationNames, ["검암"])
        let segment = try XCTUnwrap(
            SubwayTravelSegmentEngine.segments(from: readings).first
        )
        XCTAssertEqual(segment.mode, .subway)
        XCTAssertEqual(segment.subwayRoute?.stops.first?.stationName, "가정")
        XCTAssertEqual(segment.subwayRoute?.stops.last?.stationName, "마곡나루")
    }

    func testRailEndpointsBridgeThirtyMinuteGPSGapOnlyOnCatalogRoute() throws {
        let base = makeDate(2026, 8, 25, 7, 0)
        let readings = [
            SensorReading(
                timestamp: base,
                point: GeoPoint(
                    latitude: 37.5248,
                    longitude: 126.6744,
                    altitude: 20,
                    horizontalAccuracy: 12,
                    verticalAccuracy: 8
                ),
                speedMetersPerSecond: 12,
                motion: .automotive,
                motionConfidence: .high,
                nearbyStation: true,
                nearbyStationName: "가정역",
                matchesRailRoute: true
            ),
            SensorReading(
                timestamp: base.addingTimeInterval(20 * 60),
                point: GeoPoint(
                    latitude: 37.5667,
                    longitude: 126.8273,
                    altitude: 20,
                    horizontalAccuracy: 12,
                    verticalAccuracy: 8
                ),
                speedMetersPerSecond: 12,
                motion: .automotive,
                motionConfidence: .high,
                nearbyStation: true,
                nearbyStationName: "마곡나루역",
                matchesRailRoute: true
            ),
        ]

        let segment = try XCTUnwrap(
            SubwayTravelSegmentEngine.segments(from: readings).first
        )
        XCTAssertEqual(segment.mode, .subway)
        XCTAssertEqual(
            segment.subwayRoute?.transferStationNames,
            ["검암"]
        )
        XCTAssertEqual(segment.subwayRoute?.stops.first?.stationName, "가정")
        XCTAssertEqual(segment.subwayRoute?.stops.last?.stationName, "마곡나루")
        XCTAssertTrue(
            SubwayTravelSegmentEngine.segments(
                from: [
                    readings[0],
                    SensorReading(
                        timestamp: base.addingTimeInterval(31 * 60),
                        point: readings[1].point,
                        speedMetersPerSecond: 12,
                        motion: .automotive,
                        motionConfidence: .high,
                        nearbyStation: true,
                        nearbyStationName: "마곡나루역",
                        matchesRailRoute: true
                    ),
                ]
            ).isEmpty
        )

        let day = TimeSpan(
            start: makeDate(2026, 8, 25),
            end: makeDate(2026, 8, 26)
        )
        let overlays = MapHomeSubwayRouteOverlayEngine.overlays(
            travel: [segment],
            readings: readings,
            day: day,
            through: base.addingTimeInterval(20 * 60)
        )
        XCTAssertTrue(overlays.isEmpty)
        let requests = ExpectedRouteRequestEngine.requests(
            travel: [segment], places: [], readings: readings,
            in: day, through: base.addingTimeInterval(20 * 60)
        )
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.departureDate, readings[0].timestamp)
        XCTAssertEqual(request.arrivalDate, readings[1].timestamp)
        let firstCoordinate = request.start
        let lastCoordinate = request.end
        XCTAssertEqual(
            firstCoordinate.latitude,
            37.5248,
            accuracy: 0.000001
        )
        XCTAssertEqual(
            lastCoordinate.longitude,
            126.8273,
            accuracy: 0.000001
        )
    }

    func testStationJourneyRequiresFiveMinuteStaysAndFiftyMeterExit() throws {
        let base = makeDate(2026, 8, 18, 7, 0)
        let samples: [(Double, Double, Double, Bool)] = [
            (0, 37.5248, 126.6744, true),
            (5, 37.5248, 126.6744, true),
            (6, 37.5500, 126.7500, false),
            (10, 37.5500, 126.7500, false),
            (20, 37.5667, 126.8273, true),
            (25, 37.5667, 126.8273, true),
            (26, 37.5600, 126.8273, false),
            (27, 37.5590, 126.8273, false),
        ]
        let readings = samples.map { minute, latitude, longitude, rail in
            SensorReading(
                timestamp: base.addingTimeInterval(minute * 60),
                point: GeoPoint(
                    latitude: latitude,
                    longitude: longitude,
                    altitude: 20,
                    horizontalAccuracy: 10,
                    verticalAccuracy: 8
                ),
                motion: .automotive,
                motionConfidence: .high,
                matchesRailRoute: rail
            )
        }

        let journey = try XCTUnwrap(
            SubwayStationCatalog.stationJourney(from: readings)
        )

        XCTAssertTrue(journey.isConfirmed)
        XCTAssertTrue(journey.hasRailEvidence)
        XCTAssertEqual(journey.startStationName, "가정")
        XCTAssertEqual(journey.destinationStationName, "마곡나루")
        XCTAssertEqual(journey.transferStationNames, ["검암"])
        XCTAssertEqual(journey.stays.map(\.stationName), ["가정", "마곡나루"])
        XCTAssertTrue(journey.stays.allSatisfy(\.exitConfirmed))
        XCTAssertEqual(journey.route.transferStationNames, ["검암"])
        XCTAssertTrue(journey.evidence.contains("역 이탈 50m 이상 지속"))

        let inference = TravelModeClassifier().classify(readings: readings)
        XCTAssertEqual(inference.mode, .subway)
        let segment = try XCTUnwrap(
            SubwayTravelSegmentEngine.segments(from: readings).first
        )
        XCTAssertEqual(segment.mode, .subway)
        XCTAssertEqual(segment.subwayRoute?.transferStationNames, ["검암"])
        XCTAssertTrue(segment.evidence.contains("출발역·환승역·도착역 상태 확정"))
    }

    func testStationJourneyDoesNotBridgeMissingSampleGap() {
        let base = makeDate(2026, 8, 18, 7, 0)
        let samples: [(Double, Double, Double, Bool)] = [
            (0, 37.5248, 126.6744, true),
            (5, 37.5248, 126.6744, true),
            (6, 37.5500, 126.7500, false),
            (10, 37.5500, 126.7500, false),
            // The 50-minute gap has no observed route continuity.
            (60, 37.5667, 126.8273, true),
            (65, 37.5667, 126.8273, true),
            (66, 37.5600, 126.8273, false),
            (67, 37.5590, 126.8273, false),
        ]
        let readings = samples.map { minute, latitude, longitude, rail in
            SensorReading(
                timestamp: base.addingTimeInterval(minute * 60),
                point: GeoPoint(
                    latitude: latitude,
                    longitude: longitude,
                    altitude: 20,
                    horizontalAccuracy: 10,
                    verticalAccuracy: 8
                ),
                motion: .automotive,
                motionConfidence: .high,
                matchesRailRoute: rail
            )
        }

        XCTAssertNil(SubwayStationCatalog.stationJourney(from: readings))
    }

    func testSubwayRoutePriorityKeepsExactLineDuringLiveGPSWindow() throws {
        let base = makeDate(2026, 8, 18, 7, 0)
        let readings = [
            SensorReading(
                timestamp: base,
                point: GeoPoint(
                    latitude: 37.5248,
                    longitude: 126.6744,
                    altitude: 20,
                    horizontalAccuracy: 10,
                    verticalAccuracy: 8
                ),
                speedMetersPerSecond: 11,
                motion: .automotive,
                motionConfidence: .high,
                nearbyStation: true,
                nearbyStationName: "가정역",
                matchesRailRoute: true
            ),
            SensorReading(
                timestamp: base.addingTimeInterval(60),
                speedMetersPerSecond: 11,
                motion: .automotive,
                motionConfidence: .high,
                gpsAvailable: false,
                nearbyStation: true,
                nearbyStationName: "검암역",
                matchesRailRoute: true
            ),
            SensorReading(
                timestamp: base.addingTimeInterval(120),
                speedMetersPerSecond: 11,
                motion: .automotive,
                motionConfidence: .high,
                gpsAvailable: false,
                nearbyStation: true,
                nearbyStationName: "마곡나루역",
                matchesRailRoute: true
            ),
        ]

        let result = TravelModeClassifier().classify(readings: readings)

        XCTAssertEqual(result.mode, .subway)
        XCTAssertEqual(result.subwayRoute?.lineNames, ["인천2호선", "공항철도"])
        XCTAssertEqual(result.subwayRoute?.transferStationNames, ["검암"])
        XCTAssertTrue(result.evidence.contains("노선 인천2호선 → 공항철도"))
    }

    func testStationAltitudeChangeAddsSubwayEvidenceNearStation() throws {
        let base = makeDate(2026, 8, 18, 7, 0)
        let readings = [
            SensorReading(
                timestamp: base,
                point: GeoPoint(
                    latitude: 37.5248,
                    longitude: 126.6744,
                    altitude: 20,
                    horizontalAccuracy: 10,
                    verticalAccuracy: 8
                ),
                speedMetersPerSecond: 3,
                motion: .automotive,
                motionConfidence: .high,
                relativeAltitudeMeters: 5,
                nearbyStation: true,
                nearbyStationName: "가정역",
                matchesRailRoute: true
            ),
            SensorReading(
                timestamp: base.addingTimeInterval(60),
                point: GeoPoint(
                    latitude: 37.5667,
                    longitude: 126.8273,
                    altitude: 12,
                    horizontalAccuracy: 10,
                    verticalAccuracy: 8
                ),
                speedMetersPerSecond: 11,
                motion: .automotive,
                motionConfidence: .high,
                relativeAltitudeMeters: -5,
                nearbyStation: true,
                nearbyStationName: "마곡나루역",
                matchesRailRoute: true
            ),
        ]

        let result = TravelModeClassifier().classify(readings: readings)

        XCTAssertEqual(result.mode, .subway)
        XCTAssertTrue(result.evidence.contains("지하철역 주변 고도 하강"))
        XCTAssertNotNil(result.subwayRoute)
    }

    func testStationAltitudeChangeDoesNotOverrideAutomotiveWithoutRailContext() {
        let base = makeDate(2026, 9, 6, 0, 17)
        var readings: [SensorReading] = []
        for index in 0..<5 {
            let offset = Double(index)
            let isNearStation = index < 2
            readings.append(SensorReading(
                timestamp: base.addingTimeInterval(Double(index) * 60),
                point: GeoPoint(
                    latitude: 37.5 + offset * 0.001,
                    longitude: 126.9,
                    altitude: 20 - offset,
                    horizontalAccuracy: 10,
                    verticalAccuracy: 8
                ),
                speedMetersPerSecond: 9,
                motion: isNearStation ? .automotive : .unknown,
                motionConfidence: .high,
                relativeAltitudeMeters: 5 - offset * 2,
                nearbyStation: isNearStation,
                nearbyStationName: isNearStation ? "가정역" : nil
            ))
        }

        let result = TravelModeClassifier().classify(readings: readings)

        XCTAssertEqual(result.mode, TravelMode.car)
        XCTAssertFalse(result.evidence.contains("지하철역 주변 고도 하강"))
    }

    func testTemporarySubwayLocationsUseArrivalTimeWithoutRewritingRawGPS() throws {
        let base = makeDate(2026, 8, 18, 7, 0)
        let readings = [
            SensorReading(
                timestamp: base,
                point: GeoPoint(
                    latitude: 37.5248,
                    longitude: 126.6744,
                    altitude: 20,
                    horizontalAccuracy: 10,
                    verticalAccuracy: 8
                ),
                nearbyStation: true,
                nearbyStationName: "가정역",
                matchesRailRoute: true
            ),
            SensorReading(
                timestamp: base.addingTimeInterval(60),
                gpsAvailable: false,
                nearbyStation: true,
                nearbyStationName: "검암역",
                matchesRailRoute: true
            ),
            SensorReading(
                timestamp: base.addingTimeInterval(120),
                locationFixQuality: .approximate,
                gpsAvailable: false,
                nearbyStation: true,
                nearbyStationName: "마곡나루역",
                matchesRailRoute: true
            ),
        ]

        let temporary = SubwayStationCatalog.temporaryLocations(from: readings)

        XCTAssertEqual(temporary.map(\.stationName), ["검암", "마곡나루"])
        XCTAssertEqual(temporary.map(\.timestamp), [
            base.addingTimeInterval(60),
            base.addingTimeInterval(120),
        ])
        XCTAssertTrue(temporary.allSatisfy { $0.reason.contains("도착 시각") })
        XCTAssertNil(readings[1].point)
        XCTAssertEqual(readings[2].locationFixQuality, .approximate)
    }

    func testRealtimeMapProjectionFallsBackToTemporaryStationWhenGPSIsMissing() throws {
        let timestamp = makeDate(2026, 8, 18, 7, 1)
        let readings = [
            SensorReading(
                timestamp: timestamp,
                nearbyStation: true,
                nearbyStationName: "검암역",
                matchesRailRoute: true
            )
        ]

        let temporary = SubwayStationCatalog.temporaryLocations(from: readings)
        let projection = try XCTUnwrap(
            RealtimeSensorMapProjection.project(
                readings: readings,
                at: timestamp.addingTimeInterval(60),
                temporaryLocations: temporary
            )
        )

        XCTAssertTrue(projection.isEstimated)
        XCTAssertEqual(projection.source, "지하철역 도착 시각 기반 임시 위치")
        XCTAssertEqual(projection.point.latitude, 37.5692, accuracy: 0.0001)
        XCTAssertEqual(projection.point.longitude, 126.6737, accuracy: 0.0001)
        XCTAssertNil(readings[0].point)
    }

    func testSubwayStationOrderingIgnoresInvalidTimestamps() {
        let first = SensorReading(
            timestamp: makeDate(2026, 8, 18, 7, 0),
            nearbyStation: true,
            nearbyStationName: "검암역",
            matchesRailRoute: true
        )
        let second = SensorReading(
            timestamp: makeDate(2026, 8, 18, 7, 1),
            nearbyStation: true,
            nearbyStationName: "마곡나루역",
            matchesRailRoute: true
        )
        let invalid = SensorReading(
            timestamp: Date(timeIntervalSinceReferenceDate: 1e100),
            nearbyStation: true,
            nearbyStationName: "검암역",
            matchesRailRoute: true
        )
        let valid = [first, second]

        XCTAssertEqual(
            SubwayStationCatalog.stationNames(from: [first, second, invalid]),
            SubwayStationCatalog.stationNames(from: valid)
        )
        XCTAssertEqual(
            SubwayStationCatalog.temporaryLocations(from: [first, second, invalid])
                .map(\.stationName),
            SubwayStationCatalog.temporaryLocations(from: valid).map(\.stationName)
        )
    }

    func testSubwayRequiresAltitudeChangeEvenOnStationTrajectory() {
        let flat = TravelModeClassifier().classify(readings: seoulDrive { _ in 101.0 })

        XCTAssertNotEqual(flat.mode, .subway, "\(flat.evidence)")
        XCTAssertTrue(flat.evidence.contains(TravelModeClassifier.noAltitudeChangeEvidence), "\(flat.evidence)")
    }

    func testSubwayStaysWhenPressureShowsStationDescent() {
        // 출발 4분 사이 기압이 0.15kPa 올라간다(약 12m 하강 — 지하 승강장).
        let descended = TravelModeClassifier().classify(readings: seoulDrive { $0 < 4 ? 101.0 : 101.15 })

        XCTAssertGreaterThanOrEqual(
            TravelModeClassifier.altitudeChangeMeters(seoulDrive { $0 < 4 ? 101.0 : 101.15 }), 10
        )
        XCTAssertEqual(descended.mode, .subway, "\(descended.evidence)")
    }

    func testAppleTransportContextUsesItsOwnTransitSearchRadius() {
        let transitContext = AppleTransportContext(
            subwayStationName: "역",
            busStopName: "정류장"
        )

        let busRange = transitContext.propagated(toDistanceFromAnchor: 140)
        XCTAssertEqual(busRange?.busStopName, "정류장")
        XCTAssertEqual(busRange?.subwayStationName, "역")

        let stationOnlyRange = transitContext.propagated(
            toDistanceFromAnchor: 300
        )
        XCTAssertNil(stationOnlyRange?.busStopName)
        XCTAssertEqual(stationOnlyRange?.subwayStationName, "역")

        XCTAssertNil(transitContext.propagated(toDistanceFromAnchor: 451))
        XCTAssertNil(transitContext.propagated(toDistanceFromAnchor: .infinity))
    }

    func testStationJourneyDoesNotConfirmBeforeDestinationExit() {
        let base = makeDate(2026, 8, 18, 7, 0)
        let readings = [
            SensorReading(
                timestamp: base,
                point: GeoPoint(
                    latitude: 37.5248,
                    longitude: 126.6744,
                    altitude: 20,
                    horizontalAccuracy: 10,
                    verticalAccuracy: 8
                )
            ),
            SensorReading(
                timestamp: base.addingTimeInterval(5 * 60),
                point: GeoPoint(
                    latitude: 37.5248,
                    longitude: 126.6744,
                    altitude: 20,
                    horizontalAccuracy: 10,
                    verticalAccuracy: 8
                )
            ),
            SensorReading(
                timestamp: base.addingTimeInterval(20 * 60),
                point: GeoPoint(
                    latitude: 37.5667,
                    longitude: 126.8273,
                    altitude: 20,
                    horizontalAccuracy: 10,
                    verticalAccuracy: 8
                )
            ),
            SensorReading(
                timestamp: base.addingTimeInterval(25 * 60),
                point: GeoPoint(
                    latitude: 37.5667,
                    longitude: 126.8273,
                    altitude: 20,
                    horizontalAccuracy: 10,
                    verticalAccuracy: 8
                )
            ),
        ]

        XCTAssertNil(SubwayStationCatalog.stationJourney(from: readings))
    }

    func testSubwayRouteSurvivesTravelPresentationMerge() throws {
        let base = makeDate(2026, 8, 11, 9, 35)
        let route = try XCTUnwrap(
            SubwayStationCatalog.route(for: ["가정역", "검암역", "마곡나루역"])
        )
        let first = TravelSegment(
            mode: .subway,
            span: TimeSpan(start: base, end: base.addingTimeInterval(20 * 60)),
            distanceMeters: 10_000,
            confidence: .high,
            evidence: ["GPS"]
        )
        let second = TravelSegment(
            mode: .subway,
            span: TimeSpan(
                start: base.addingTimeInterval(10 * 60),
                end: base.addingTimeInterval(40 * 60)
            ),
            distanceMeters: 18_000,
            confidence: .medium,
            evidence: ["철도 노선"],
            subwayRoute: route
        )

        let result = TravelSegmentPresentationEngine.consolidated([first, second])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.subwayRoute, route)
    }

    func testUserTransitLocationPersistsSelectedFloor() throws {
        let location = UserTransitLocation(
            name: "시청역",
            kind: .subwayStation,
            point: GeoPoint(
                latitude: 37.5657,
                longitude: 126.9769,
                altitude: 0,
                horizontalAccuracy: 25,
                verticalAccuracy: -1
            ),
            floor: -2
        )

        let decoded = try JSONDecoder().decode(
            UserTransitLocation.self,
            from: JSONEncoder().encode(location)
        )

        XCTAssertEqual(decoded.floor, -2)
    }

    func testMergingTravelRetainsStableSubwayWhenNextRefreshDropsCandidate() throws {
        let base = makeDate(2026, 8, 11, 9, 35)
        let span = TimeSpan(
            start: base,
            end: base.addingTimeInterval(45 * 60)
        )
        let route = try XCTUnwrap(
            SubwayStationCatalog.route(for: ["가정역", "검암역", "마곡나루역"])
        )
        let car = TravelSegment(
            mode: .car,
            span: span,
            distanceMeters: 18_000,
            confidence: .high,
            evidence: ["도로 이동"]
        )
        let subway = TravelSegment(
            mode: .subway,
            span: TimeSpan(
                start: base.addingTimeInterval(5 * 60),
                end: base.addingTimeInterval(40 * 60)
            ),
            distanceMeters: 18_000,
            confidence: .high,
            evidence: ["원본 GPS 철도 궤적 복원"],
            subwayRoute: route
        )

        let result = AppleDeviceGroundTruthEngine.mergingTravel(
            gpsSegments: [car],
            motionActivities: [],
            pedometer: nil,
            readings: [],
            preservedSubwaySegments: [subway]
        )

        XCTAssertEqual(result.map(\.mode), [.subway])
        XCTAssertEqual(result.first?.subwayRoute?.transferStationNames, ["검암"])
    }

    // EXP1029A01: iPhone 모션이 차량이라고 한 고신뢰 자동차는 예전 자동 지하철이 덮지 않는다(오늘 아침 자차 출근).
    func testMotionBackedCarIsNotOverriddenByPreservedAutomaticSubway() throws {
        let base = makeDate(2026, 10, 29, 9, 3)
        let span = TimeSpan(start: base, end: base.addingTimeInterval(64 * 60))
        let route = try XCTUnwrap(SubwayStationCatalog.route(for: ["가정역", "검암역", "마곡나루역"]))
        let car = TravelSegment(mode: .car, span: span, distanceMeters: 18_000, confidence: .high,
                                evidence: ["Core Motion 자동차 후보", "차량 가능 속도"])
        let subway = TravelSegment(mode: .subway, span: span, distanceMeters: 18_000, confidence: .high,
                                   evidence: ["원본 GPS 철도 궤적 복원"], subwayRoute: route, isClassificationLocked: true)

        let merged = AppleDeviceGroundTruthEngine.mergingTravel(
            gpsSegments: [car], motionActivities: [], pedometer: nil, readings: [], preservedSubwaySegments: [subway]
        )
        let locked = ActivityClassificationLockEngine.mergingLockedTravel(existing: [subway], fresh: [car], inside: span)

        XCTAssertEqual(merged.map(\.mode), [.car])
        XCTAssertEqual(locked.map(\.mode), [.car])
    }

    func testMergingTravelKeepsFirstGPSOnEqualSubwayOverlap() throws {
        let base = makeDate(2026, 8, 11, 9, 35)
        let span = TimeSpan(
            start: base,
            end: base.addingTimeInterval(45 * 60)
        )
        let firstFrom = UUID()
        let firstTo = UUID()
        let secondFrom = UUID()
        let secondTo = UUID()
        let first = TravelSegment(
            fromPlaceID: firstFrom,
            toPlaceID: firstTo,
            mode: .car,
            span: span,
            distanceMeters: 18_000,
            confidence: .high,
            evidence: ["first GPS"]
        )
        let second = TravelSegment(
            fromPlaceID: secondFrom,
            toPlaceID: secondTo,
            mode: .car,
            span: span,
            distanceMeters: 18_000,
            confidence: .high,
            evidence: ["second GPS"]
        )
        let subway = TravelSegment(
            mode: .subway,
            span: span,
            distanceMeters: 18_000,
            confidence: .high,
            evidence: ["원본 GPS 철도 궤적 복원"],
            subwayRoute: try XCTUnwrap(
                SubwayStationCatalog.route(
                    for: ["가정역", "검암역", "마곡나루역"]
                )
            )
        )

        let result = AppleDeviceGroundTruthEngine.mergingTravel(
            gpsSegments: [first, second],
            motionActivities: [],
            pedometer: nil,
            preservedSubwaySegments: [subway]
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].fromPlaceID, firstFrom)
        XCTAssertEqual(result[0].toPlaceID, firstTo)
    }

    func testMergingTravelRetainsLockedMediumSubwayWhenCluesDisappear() throws {
        let base = makeDate(2026, 9, 4, 9, 35)
        let span = TimeSpan(
            start: base,
            end: base.addingTimeInterval(45 * 60)
        )
        let route = try XCTUnwrap(
            SubwayStationCatalog.route(for: ["가정역", "검암역", "마곡나루역"])
        )
        let car = TravelSegment(
            mode: .car,
            span: span,
            distanceMeters: 18_000,
            confidence: .high,
            evidence: ["후속 센서 자동차"]
        )
        let subway = TravelSegment(
            mode: .subway,
            span: span,
            distanceMeters: 18_000,
            confidence: .medium,
            evidence: ["원본 GPS 철도 궤적 복원"],
            subwayRoute: route,
            isClassificationLocked: true
        )

        let result = AppleDeviceGroundTruthEngine.mergingTravel(
            gpsSegments: [car],
            motionActivities: [],
            pedometer: nil,
            readings: [],
            preservedSubwaySegments: [subway]
        )

        XCTAssertEqual(result.map(\.mode), [.subway])
        XCTAssertEqual(result.first?.subwayRoute, route)
    }

    func testMergingTravelKeepsValidatedSubwayOutsideNewGPSCandidates() throws {
        let base = makeDate(2026, 8, 11, 9, 35)
        let route = try XCTUnwrap(
            SubwayStationCatalog.route(for: ["가정역", "검암역", "마곡나루역"])
        )
        let preserved = TravelSegment(
            mode: .subway,
            span: TimeSpan(
                start: base.addingTimeInterval(60 * 60),
                end: base.addingTimeInterval(90 * 60)
            ),
            distanceMeters: 18_000,
            confidence: .high,
            evidence: [
                "출발역·환승역·도착역 순서",
                "역별 가다·서다 정차 패턴",
            ],
            subwayRoute: route
        )
        let unrelatedCar = TravelSegment(
            mode: .car,
            span: TimeSpan(
                start: base,
                end: base.addingTimeInterval(15 * 60)
            ),
            distanceMeters: 4_000,
            confidence: .high,
            evidence: ["도로 이동"]
        )

        let result = AppleDeviceGroundTruthEngine.mergingTravel(
            gpsSegments: [unrelatedCar],
            motionActivities: [],
            pedometer: nil,
            readings: [],
            preservedSubwaySegments: [preserved]
        )

        XCTAssertEqual(result.map(\.mode), [.car, .subway])
        XCTAssertEqual(
            result.last?.subwayRoute?.transferStationNames,
            ["검암"]
        )
    }

    func testValidatedSubwayDisplacesPartiallyOverlappingAutomotiveCandidate() throws {
        let base = makeDate(2026, 8, 11, 9, 35)
        let route = try XCTUnwrap(
            SubwayStationCatalog.route(for: ["가정역", "검암역", "마곡나루역"])
        )
        let car = TravelSegment(
            mode: .car,
            span: TimeSpan(
                start: base,
                end: base.addingTimeInterval(60 * 60)
            ),
            distanceMeters: 20_000,
            confidence: .high,
            evidence: ["Core Motion 자동차"]
        )
        let preserved = TravelSegment(
            mode: .subway,
            span: TimeSpan(
                start: base.addingTimeInterval(45 * 60),
                end: base.addingTimeInterval(105 * 60)
            ),
            distanceMeters: 18_000,
            confidence: .high,
            evidence: ["역별 가다·서다 정차 패턴"],
            subwayRoute: route
        )

        let result = AppleDeviceGroundTruthEngine.mergingTravel(
            gpsSegments: [car],
            motionActivities: [],
            pedometer: nil,
            readings: [],
            preservedSubwaySegments: [preserved]
        )

        XCTAssertEqual(result.map(\.mode), [.subway])
        XCTAssertEqual(result.first?.subwayRoute, route)
    }

    func testAirKoreaUsesNearestStationAndCachesContext() async throws {
        AirQualityURLProtocolStub.requestCount = 0
        AirQualityURLProtocolStub.handler = { request in
            let path = try XCTUnwrap(request.url?.path)
            let json: String
            XCTAssertEqual(request.url?.host, "air.example.com")
            XCTAssertFalse(request.url?.absoluteString.contains("serviceKey") == true)
            if path.hasSuffix("/airkorea/stations") {
                json = """
                {"response":{"body":{"items":[
                  {"stationName":"가까운역","dmX":"37.5001","dmY":"127.0001"},
                  {"stationName":"먼역","dmX":"35.1000","dmY":"129.0000"}
                ]}}}
                """
            } else {
                XCTAssertTrue(
                    request.url?.absoluteString.contains(
                        "stationName=%EA%B0%80%EA%B9%8C%EC%9A%B4%EC%97%AD"
                    ) == true
                )
                json = """
                {"response":{"body":{"items":[
                  {"dataTime":"2026-08-01 18:00","pm10Value":"42","pm25Value":"18"}
                ]}}}
                """
            }
            return (200, Data(json.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AirQualityURLProtocolStub.self]
        let service = AirQualityContextService(
            session: URLSession(configuration: configuration),
            proxyBaseURL: URL(string: "https://air.example.com")
        )
        let first = try await service.context(
            latitude: 37.5,
            longitude: 127,
            at: makeDate(2026, 8, 1, 18)
        )
        let second = try await service.context(
            latitude: 37.5002,
            longitude: 127.0002,
            at: first.observedAt.addingTimeInterval(10 * 60)
        )
        XCTAssertEqual(first.stationName, "가까운역")
        XCTAssertEqual(first.providerName, "에어코리아")
        XCTAssertFalse(first.isFallback)
        XCTAssertEqual(first.pm10MicrogramsPerCubicMeter, 42)
        XCTAssertEqual(first.pm25MicrogramsPerCubicMeter, 18)
        XCTAssertEqual(second, first)
        XCTAssertEqual(AirQualityURLProtocolStub.requestCount, 2)
    }

    func testStationaryContextNeverAppearsAsMovementInActualRecords() {
        let start = makeDate(2026, 8, 6, 10)
        let legacyStay = makeActual(
            "머무름",
            "movement",
            start: start,
            minutes: 30,
            source: .location,
            behavior: StationaryContextKind.unknownStay.rawValue
        )
        let titledLegacyStay = makeActual(
            "머무름",
            "movement",
            start: start.addingTimeInterval(hour),
            minutes: 20,
            source: .location
        )

        XCTAssertEqual(
            ActualRecordCategoryResolver.categoryID(for: legacyStay),
            "activity"
        )
        XCTAssertEqual(
            ActualRecordCategoryResolver.categoryID(for: titledLegacyStay),
            "activity"
        )
    }

    func testStationaryContextCallOutranksCalendarAndPlaceSignals() {
        // 2026-08-04는 화요일이다.
        let start = makeDate(2026, 8, 4, 10, 0)
        let end = start.addingTimeInterval(105 * 60)
        let stay = makeContextStay(start: start, end: end)
        let inference = StationaryContextClassifier().classify(
            StationaryContextInput(
                stay: stay,
                placeKind: .company,
                calendarEvents: [
                    makeContextEvent(title: "주간 회의", start: start, end: end)
                ],
                actuals: [
                    makeContextActual(
                        source: .call,
                        start: start,
                        end: end
                    )
                ],
                calendar: utcCalendar,
                now: end.addingTimeInterval(hour)
            )
        )

        XCTAssertEqual(inference.kind, .call)
        XCTAssertEqual(inference.kind.title, "통화")
        XCTAssertEqual(inference.confidence, .high)
        XCTAssertTrue(inference.evidence.contains("CallKit 통화 기록"))
    }

    func testStationaryContextMeetingNeverReachesHighConfidence() {
        let start = makeDate(2026, 8, 4, 10, 0)
        let end = start.addingTimeInterval(2 * hour)
        let inference = StationaryContextClassifier().classify(
            StationaryContextInput(
                stay: makeContextStay(start: start, end: end),
                placeKind: .company,
                readings: [
                    makeContextReading(at: start, flat: true),
                    makeContextReading(
                        at: start.addingTimeInterval(hour),
                        flat: true
                    ),
                    makeContextReading(
                        at: start.addingTimeInterval(90 * 60),
                        flat: true
                    ),
                ],
                calendarEvents: [
                    makeContextEvent(
                        title: "분기 리뷰",
                        start: start,
                        end: end,
                        attendeeCount: 5
                    )
                ],
                calendar: utcCalendar,
                now: end.addingTimeInterval(hour)
            )
        )

        XCTAssertEqual(inference.kind, .meeting)
        XCTAssertEqual(inference.kind.title, "회의")
        XCTAssertGreaterThan(inference.score, 0.75)
        XCTAssertEqual(inference.confidence, .medium)
    }

    func testStationaryContextSelectsSameCalendarEventRegardlessOfInputOrder() {
        let start = makeDate(2026, 8, 4, 10, 0)
        let end = start.addingTimeInterval(hour)
        var meal = makeContextEvent(
            title: "점심",
            start: start,
            end: end,
            attendeeCount: 3
        )
        meal.id = "a-meal"
        var meeting = makeContextEvent(
            title: "주간 회의",
            start: start,
            end: end,
            attendeeCount: 3
        )
        meeting.id = "z-meeting"
        let classifier = StationaryContextClassifier()

        func classify(_ events: [CalendarRecord]) -> StationaryContextInference {
            classifier.classify(
                StationaryContextInput(
                    stay: makeContextStay(start: start, end: end),
                    calendarEvents: events,
                    calendar: utcCalendar,
                    now: end
                )
            )
        }

        let forward = classify([meeting, meal])
        let reversed = classify([meal, meeting])

        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(forward.kind, .mealPlace)
        XCTAssertTrue(forward.evidence.contains("식사 일정 '점심'"))
    }

    func testStationaryContextCompanyPlaceOnWeekdayBecomesWork() {
        let start = makeDate(2026, 8, 4, 10, 0)
        let end = start.addingTimeInterval(2 * hour)
        let inference = StationaryContextClassifier().classify(
            StationaryContextInput(
                stay: makeContextStay(start: start, end: end),
                placeKind: .company,
                calendar: utcCalendar,
                now: end.addingTimeInterval(hour)
            )
        )

        XCTAssertEqual(inference.kind, .work)
        XCTAssertEqual(inference.kind.title, "근무")
        XCTAssertEqual(inference.kind.categoryID, "work")
        XCTAssertEqual(inference.confidence, .medium)
        XCTAssertTrue(inference.evidence.contains("평일 09–18시"))
    }

    func testStationaryContextShortStayBetweenTravelsBecomesWaiting() {
        let start = makeDate(2026, 8, 4, 10, 0)
        let end = start.addingTimeInterval(10 * 60)
        let inference = StationaryContextClassifier().classify(
            StationaryContextInput(
                stay: makeContextStay(start: start, end: end),
                placeKind: nil,
                travel: [
                    TravelSegment(
                        mode: .walking,
                        span: TimeSpan(
                            start: start.addingTimeInterval(-10 * 60),
                            end: start
                        ),
                        distanceMeters: 500,
                        confidence: .medium,
                        evidence: ["걸음 수"]
                    ),
                    TravelSegment(
                        mode: .subway,
                        span: TimeSpan(
                            start: end,
                            end: end.addingTimeInterval(20 * 60)
                        ),
                        distanceMeters: 6_000,
                        confidence: .medium,
                        evidence: ["역 근처"]
                    ),
                ],
                calendar: utcCalendar,
                now: end.addingTimeInterval(hour)
            )
        )

        XCTAssertEqual(inference.kind, .waiting)
        XCTAssertEqual(inference.kind.title, "대기")
        XCTAssertTrue(inference.evidence.contains("이동 사이 정지"))
    }

    func testStationaryContextWithoutEvidenceStaysUnknownAtLowConfidence() {
        // 2026-08-08은 토요일이라 평일 근무 가중치가 붙지 않는다.
        let start = makeDate(2026, 8, 8, 14, 0)
        let end = start.addingTimeInterval(30 * 60)
        let inference = StationaryContextClassifier().classify(
            StationaryContextInput(
                stay: makeContextStay(start: start, end: end),
                placeKind: nil,
                calendar: utcCalendar,
                now: end.addingTimeInterval(hour)
            )
        )

        XCTAssertEqual(inference.kind, .unknownStay)
        XCTAssertEqual(inference.kind.title, "머무름")
        XCTAssertEqual(inference.confidence, .low)
        XCTAssertEqual(inference.evidence, ["장소 문맥 근거 부족"])
    }

    func testStationaryContextModifiersAttachWithoutChangingTheKind() {
        let start = makeDate(2026, 8, 8, 13, 0)
        let end = start.addingTimeInterval(2 * hour)
        let inference = StationaryContextClassifier().classify(
            StationaryContextInput(
                stay: makeContextStay(start: start, end: end),
                placeKind: .home,
                readings: [
                    makeContextReading(at: start, flat: true),
                    makeContextReading(
                        at: start.addingTimeInterval(hour),
                        flat: true
                    ),
                    makeContextReading(
                        at: start.addingTimeInterval(90 * 60),
                        flat: true
                    ),
                ],
                actuals: [
                    makeContextActual(
                        source: .appUsage,
                        start: start,
                        end: start.addingTimeInterval(hour)
                    ),
                    makeContextActual(
                        source: .media,
                        start: start,
                        end: start.addingTimeInterval(90)
                    ),
                ],
                calendar: utcCalendar,
                now: end.addingTimeInterval(hour)
            )
        )

        XCTAssertEqual(inference.kind, .homeRest)
        XCTAssertEqual(inference.kind.title, "집에서 휴식")
        XCTAssertTrue(inference.modifiers.contains(.screenUse))
        XCTAssertTrue(inference.modifiers.contains(.mediaPlayback))
        XCTAssertTrue(inference.modifiers.contains(.onDesk))
        XCTAssertFalse(inference.modifiers.contains(.inPocket))
    }

    func testStationaryContextRecordsUseExistingCategoriesAndStableIDs() {
        let start = makeDate(2026, 8, 4, 10, 0)
        let end = start.addingTimeInterval(2 * hour)
        let span = TimeSpan(start: start, end: end.addingTimeInterval(hour))
        let stay = makeContextStay(
            start: start,
            end: end,
            placeKey: "frequent-office"
        )
        let makeRecords = {
            StationaryContextActualEngine.records(
                stays: [stay],
                placeKinds: ["frequent-office": .company],
                inside: span,
                calendar: self.utcCalendar,
                now: span.end
            )
        }
        let records = makeRecords()

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.title, "근무")
        XCTAssertEqual(records.first?.source, .location)
        XCTAssertEqual(records.first?.behavior, "work")
        XCTAssertEqual(
            records.first?.modelVersion,
            StationaryContextClassifier.modelVersion
        )
        XCTAssertEqual(records.first?.id, makeRecords().first?.id)

        let catalogIDs = Set(CategoryCatalog.builtIn.map(\.id))
        for kind in StationaryContextKind.allCases {
            XCTAssertTrue(
                catalogIDs.contains(kind.categoryID),
                "\(kind.rawValue) → \(kind.categoryID) 가 카탈로그에 없다"
            )
        }
    }

    /// 실기기에서 종일 "정지·휴식"만 보이던 원인. 실내에서는 GPS가 끊겨
    /// 장소 체류가 하나도 만들어지지 않는데, 예전에는 체류가 있어야만
    /// 문맥 기록을 만들었다.
    func testStationaryContextReplacesMotionRestWithoutAnyPlaceStay() {
        let dayStart = makeDate(2026, 8, 4, 0, 0)
        let day = TimeSpan(
            start: dayStart,
            end: dayStart.addingTimeInterval(24 * hour)
        )
        let restStart = makeDate(2026, 8, 4, 19, 0)
        let restSpan = TimeSpan(
            start: restStart,
            end: restStart.addingTimeInterval(3 * hour)
        )
        let motionActuals = MotionActivityActualEngine.records(
            from: [
                MotionActivityRecord(
                    span: restSpan,
                    motion: .stationary,
                    confidence: .high
                )
            ],
            existing: [],
            inside: day
        )
        XCTAssertEqual(motionActuals.map(\.title), ["정지·휴식"])

        let contextRecords = StationaryContextActualEngine.records(
            stays: [],
            placeKinds: [:],
            stationarySpans: [restSpan],
            inside: day,
            calendar: utcCalendar,
            now: day.end
        )

        XCTAssertEqual(contextRecords.map(\.title), ["머무름"])
        XCTAssertEqual(contextRecords.first?.confidence, .low)
        XCTAssertEqual(contextRecords.first?.categoryID, "activity")
        XCTAssertEqual(contextRecords.first?.startedAt, restSpan.start)
        XCTAssertEqual(contextRecords.first?.endedAt, restSpan.end)

        let merged = StationaryContextActualEngine.suppressingStationaryMotion(
            motionActuals,
            coveredBy: contextRecords,
            asOf: day.end
        ) + contextRecords
        XCTAssertFalse(merged.contains { $0.title == "정지·휴식" })
    }

    func testStationaryContextFillsTheStationaryTimeAroundAPlaceStay() {
        let dayStart = makeDate(2026, 8, 4, 0, 0)
        let day = TimeSpan(
            start: dayStart,
            end: dayStart.addingTimeInterval(24 * hour)
        )
        let officeStart = makeDate(2026, 8, 4, 10, 0)
        let stay = makeContextStay(
            start: officeStart,
            end: officeStart.addingTimeInterval(2 * hour),
            placeKey: "frequent-office"
        )
        let records = StationaryContextActualEngine.records(
            stays: [stay],
            placeKinds: ["frequent-office": .company],
            stationarySpans: [
                TimeSpan(
                    start: officeStart.addingTimeInterval(-hour),
                    end: officeStart.addingTimeInterval(3 * hour)
                )
            ],
            inside: day,
            calendar: utcCalendar,
            now: day.end
        )

        XCTAssertEqual(records.map(\.title), ["머무름", "근무", "머무름"])
        XCTAssertEqual(records.first?.endedAt, stay.span.start)
        XCTAssertEqual(records.last?.startedAt, stay.span.end)
        XCTAssertEqual(
            Set(records.map(\.id)).count,
            records.count,
            "같은 갱신에서 만든 기록의 식별자가 겹친다"
        )
    }

    /// 시간대만으로는 근무를 만들지 않는다. 평일 낮의 집이 "근무"가 되면
    /// 안 된다.
    func testStationaryContextDoesNotInventWorkFromWeekdayHoursAlone() {
        let start = makeDate(2026, 8, 4, 14, 0)
        let inference = StationaryContextClassifier().classify(
            StationaryContextInput(
                stay: makeContextStay(
                    start: start,
                    end: start.addingTimeInterval(2 * hour)
                ),
                placeKind: nil,
                calendar: utcCalendar,
                now: start.addingTimeInterval(3 * hour)
            )
        )

        XCTAssertEqual(inference.kind, .unknownStay)
        XCTAssertEqual(inference.confidence, .low)
    }

    /// 문맥 기록은 "정지·휴식"만 대신한다. 같은 시간에 잡힌 걷기는 남는다.
    func testStationaryContextDoesNotSwallowWalkingActivities() {
        let dayStart = makeDate(2026, 8, 4, 0, 0)
        let day = TimeSpan(
            start: dayStart,
            end: dayStart.addingTimeInterval(24 * hour)
        )
        let officeStart = makeDate(2026, 8, 4, 10, 0)
        let context = StationaryContextActualEngine.records(
            stays: [
                makeContextStay(
                    start: officeStart,
                    end: officeStart.addingTimeInterval(3 * hour),
                    placeKey: "frequent-office"
                )
            ],
            placeKinds: ["frequent-office": .company],
            inside: day,
            calendar: utcCalendar,
            now: day.end
        )
        XCTAssertEqual(context.map(\.title), ["근무"])

        let regenerated = MotionActivityActualEngine.records(
            from: [
                MotionActivityRecord(
                    span: TimeSpan(
                        start: officeStart.addingTimeInterval(30 * 60),
                        end: officeStart.addingTimeInterval(34 * 60)
                    ),
                    motion: .walking,
                    confidence: .high
                ),
                MotionActivityRecord(
                    span: TimeSpan(
                        start: officeStart.addingTimeInterval(40 * 60),
                        end: officeStart.addingTimeInterval(2 * hour)
                    ),
                    motion: .stationary,
                    confidence: .high
                ),
            ],
            existing: context,
            inside: day
        )

        XCTAssertEqual(regenerated.map(\.title), ["걷기"])
    }

    // MARK: - 한 곳에 머문 시간 잇기

    /// 층 이동으로 쪼개진 기록과 이동 자체도 기준 층에 얹혀 있다. 기준을
    /// 고치면 오르내린 층수는 그대로 둔 채 함께 따라와야 한다.
    func testRecalibrationMovesSplitStaysAndFloorTransitionTogether() {
        let base = makeDate(2026, 8, 1, 9)
        let session = UUID()
        let anchor = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 60,
            horizontalAccuracy: 6,
            verticalAccuracy: 5
        )
        var frequent = FrequentPlace(
            kind: .company,
            name: "회사",
            point: anchor,
            floor: 9,
            referenceRelativeAltitudeMeters: 0,
            referencePressureKilopascals: 100.5,
            referenceAltimeterSessionID: session,
            floorCapturedAt: base
        )
        let detected = PlaceStay(
            placeKey: "gps-cluster-1",
            displayName: "자동 감지 장소",
            span: TimeSpan(start: base, end: base.addingTimeInterval(30 * 60)),
            confidence: .medium,
            point: anchor
        )
        let readings = [0, 0.1, 3.0, 3.1, 3.1].enumerated().map {
            index, altitude in
            SensorReading(
                timestamp: base.addingTimeInterval(Double(index) * 5 * 60),
                point: anchor,
                relativeAltitudeMeters: altitude,
                pressureKilopascals: 100.5 - altitude * 0.012,
                altimeterSessionID: session
            )
        }

        let engine = FrequentPlaceResolutionEngine()
        let result = FloorTimelineEngine().apply(
            readings: readings,
            to: engine.applying([frequent], to: [detected], readings: readings),
            knownPlaces: []
        )

        XCTAssertEqual(result.places.map(\.floor), [9, 10])
        // 근거는 체류가 시작된 자리에서 잰다. 한 층 올라간 뒷조각은 그 자리
        // 보다 한 층 위다.
        XCTAssertEqual(result.places.map(\.floorEvidence?.floorOffset), [0, 1])
        XCTAssertEqual(result.transitions.first?.floorEvidence?.floorOffset, 0)

        // 사용자가 "여기는 1층"이라고 고쳐 준다.
        frequent.calibrateCurrentFloor(to: 1, from: readings[0])
        let places = engine.reapplyingFloors(
            of: frequent,
            to: result.places,
            readings: []
        )
        let transitions = engine.reapplyingFloors(
            of: frequent,
            to: result.transitions
        )

        XCTAssertEqual(places.map(\.floor), [1, 2])
        XCTAssertEqual(transitions.first?.fromFloor, 1)
        XCTAssertEqual(transitions.first?.toFloor, 2)
    }

    /// 사용자가 직접 고른 도착 층은 기준을 고쳐도 덮지 않는다.
    func testReapplyingFloorsKeepsUserConfirmedTransition() {
        let base = makeDate(2026, 8, 5, 9, 0)
        var place = FrequentPlace(kind: .company)
        place.calibrateCurrentFloor(
            to: 2,
            from: makeAltitudeReading(at: base, pressureKilopascals: 101.0)
        )
        let confirmed = FloorTransition(
            id: UUID(),
            placeKey: place.stablePlaceKey,
            fromFloor: 19,
            toFloor: 20,
            relativeAltitudeMeters: 3,
            span: TimeSpan(start: base, end: base.addingTimeInterval(60)),
            confidence: .high,
            evidence: [
                "기압 고도 센서",
                FloorTransition.userConfirmedEvidence,
            ],
            floorEvidence: FloorEvidence(
                measuredAt: base,
                pressureKilopascals: 101.0
            )
        )

        XCTAssertEqual(
            FrequentPlaceResolutionEngine().reapplyingFloors(
                of: place,
                to: [confirmed]
            ),
            [confirmed]
        )
    }

    func testTransitBoardingSupportsFivePlaceKindsAndRequiresThreeMinutes() {
        let start = makeDate(2026, 8, 28, 9)
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 10
        )
        let expected: [(UserTransitLocationKind, TravelMode)] = [
            (.subwayStation, .subway),
            (.busStop, .bus),
            (.trainStation, .train),
            (.airport, .airplane),
            (.harbor, .ship),
        ]

        for (kind, mode) in expected {
            let location = UserTransitLocation(
                name: kind.title,
                kind: kind,
                point: point
            )
            let candidates = TransitBoardingCandidateEngine.candidates(
                readings: transitReadings(at: start, point: point, duration: 180),
                registeredLocations: [location],
                travel: [uncertainTransitTravel(at: start)]
            )

            XCTAssertEqual(candidates.count, 1, kind.rawValue)
            XCTAssertEqual(candidates.first?.mode, mode, kind.rawValue)
            XCTAssertEqual(candidates.first?.source, .registered, kind.rawValue)
        }

        let shortStay = UserTransitLocation(
            name: "짧은 체류",
            kind: .subwayStation,
            point: point
        )
        XCTAssertTrue(
            TransitBoardingCandidateEngine.candidates(
                readings: transitReadings(at: start, point: point, duration: 179),
                registeredLocations: [shortStay],
                travel: [uncertainTransitTravel(at: start)]
            ).isEmpty
        )
    }

    func testTransitBoardingUsesMapKitPlaceAndRejectsApproximateOrInterruptedStay() {
        let start = makeDate(2026, 8, 28, 10)
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 10
        )
        let place = TransitBoardingPlace(
            mapKitName: "서울역",
            kind: .trainStation,
            point: point
        )

        let mapKitCandidate = TransitBoardingCandidateEngine.candidates(
            readings: transitReadings(at: start, point: point, duration: 180),
            registeredLocations: [],
            nearbyPlaces: [place],
            travel: [uncertainTransitTravel(at: start)]
        )
        XCTAssertEqual(mapKitCandidate.first?.source, .mapKit)
        XCTAssertEqual(mapKitCandidate.first?.name, "서울역")

        let approximate = transitReadings(
            at: start,
            point: point,
            duration: 180,
            locationFixQuality: .approximate
        )
        XCTAssertTrue(
            TransitBoardingCandidateEngine.candidates(
                readings: approximate,
                registeredLocations: [],
                nearbyPlaces: [place],
                travel: [uncertainTransitTravel(at: start)]
            ).isEmpty
        )

        let outside = GeoPoint(
            latitude: 37.52,
            longitude: 127,
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 10
        )
        let interrupted = [
            transitReading(at: start, point: point),
            transitReading(at: start.addingTimeInterval(60), point: outside),
            transitReading(at: start.addingTimeInterval(180), point: point),
        ]
        XCTAssertTrue(
            TransitBoardingCandidateEngine.candidates(
                readings: interrupted,
                registeredLocations: [],
                nearbyPlaces: [place],
                travel: [uncertainTransitTravel(at: start)]
            ).isEmpty
        )
    }

    func testTransitBoardingUsesStaticSubwayCatalogWithoutRegisteredOrMapKitPlace()
        throws {
        let start = makeDate(2026, 8, 31, 9)
        let origin = try XCTUnwrap(
            SubwayStationCatalog.stations.first {
                $0.stationName == "가정" && $0.coordinate != nil
            }?.coordinate
        )
        let station = try XCTUnwrap(
            SubwayStationCatalog.stations.first {
                $0.stationName == "검암" && $0.coordinate != nil
            }
        )
        let point = try XCTUnwrap(station.coordinate)
        let destination = try XCTUnwrap(
            SubwayStationCatalog.stations.first {
                $0.stationName == "마곡나루" && $0.coordinate != nil
            }?.coordinate
        )
        let readings = [
            transitReading(
                at: start.addingTimeInterval(2 * 60),
                point: origin
            ),
        ] + transitReadings(
            at: start.addingTimeInterval(5 * 60),
            point: point,
            duration: 3 * 60
        ) + [
            transitReading(
                at: start.addingTimeInterval(18 * 60),
                point: destination
            ),
        ]

        let candidates = TransitBoardingCandidateEngine.candidates(
            readings: readings,
            registeredLocations: [],
            travel: [uncertainTransitTravel(at: start)]
        )

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.name, "검암")
        XCTAssertEqual(candidates.first?.kind, .subwayStation)
        XCTAssertEqual(candidates.first?.source, .catalog)
        XCTAssertEqual(candidates.first?.mode, .subway)
    }

    func testTransitBoardingRejectsUnknownLocationAccuracy() throws {
        let start = makeDate(2026, 8, 31, 9)
        let point = try XCTUnwrap(
            SubwayStationCatalog.stations.first {
                $0.stationName == "검암" && $0.coordinate != nil
            }?.coordinate
        )
        let readings = [0, 3].map { minute in
            SensorReading(
                timestamp: start.addingTimeInterval(Double(minute) * 60),
                point: point,
                gpsAvailable: true
            )
        }

        XCTAssertTrue(
            TransitBoardingCandidateEngine.candidates(
                readings: readings,
                registeredLocations: [],
                travel: [uncertainTransitTravel(at: start)]
            ).isEmpty
        )
    }

    func testStaticSubwayCatalogRejectsTwoStationCarFallbackWithoutRailEvidence()
        throws {
        let start = makeDate(2026, 8, 31, 9)
        let station = try XCTUnwrap(
            SubwayStationCatalog.stations.first {
                $0.stationName == "검암" && $0.coordinate != nil
            }?.coordinate
        )
        let destination = try XCTUnwrap(
            SubwayStationCatalog.stations.first {
                $0.stationName == "마곡나루" && $0.coordinate != nil
            }?.coordinate
        )
        var readings = transitReadings(
            at: start,
            point: station,
            duration: 3 * 60
        )
        readings[0].matchesRailRoute = true
        readings += [
            transitReading(
                at: start.addingTimeInterval(15 * 60),
                point: destination
            ),
        ]

        XCTAssertTrue(
            TransitBoardingCandidateEngine.candidates(
                readings: readings,
                registeredLocations: [],
                travel: [uncertainTransitTravel(at: start)]
            ).isEmpty
        )
    }

    func testStaticSubwayCatalogDoesNotPromptForSingleRoadStop() throws {
        let start = makeDate(2026, 8, 31, 9)
        let station = try XCTUnwrap(
            SubwayStationCatalog.stations.first {
                $0.stationName == "검암" && $0.coordinate != nil
            }?.coordinate
        )

        let candidates = TransitBoardingCandidateEngine.candidates(
            readings: transitReadings(
                at: start,
                point: station,
                duration: 3 * 60
            ),
            registeredLocations: [],
            travel: [uncertainTransitTravel(at: start)]
        )

        XCTAssertTrue(candidates.isEmpty)
    }

    func testTransitBoardingRequiresPoweredMovementAndUncertainOrIncompleteRoute() {
        let start = makeDate(2026, 8, 28, 10, 30)
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 10
        )
        let station = TransitBoardingPlace(
            mapKitName: "서울역",
            kind: .trainStation,
            point: point
        )
        let dwell = transitReadings(at: start, point: point, duration: 180)
        let span = TimeSpan(
            start: start.addingTimeInterval(3 * 60),
            end: start.addingTimeInterval(12 * 60)
        )
        let walking = TravelSegment(
            mode: .walking,
            span: span,
            distanceMeters: 1_000,
            confidence: .low,
            evidence: ["도보"]
        )
        XCTAssertTrue(
            TransitBoardingCandidateEngine.candidates(
                readings: dwell,
                registeredLocations: [],
                nearbyPlaces: [station],
                travel: [walking]
            ).isEmpty
        )

        let uncertain = uncertainTransitTravel(at: start)
        XCTAssertTrue(
            TransitBoardingCandidateEngine.candidates(
                readings: dwell,
                registeredLocations: [],
                nearbyPlaces: [station],
                travel: [uncertain],
                through: start.addingTimeInterval(10 * 60)
            ).isEmpty
        )
        XCTAssertEqual(
            TransitBoardingCandidateEngine.candidates(
                readings: dwell,
                registeredLocations: [],
                nearbyPlaces: [station],
                travel: [uncertain],
                through: uncertain.span.end
            ).count,
            1
        )

        let highConfidence = TravelSegment(
            mode: .train,
            span: span,
            distanceMeters: 3_000,
            confidence: .high,
            evidence: ["철도 경로 일치"],
            isClassificationLocked: true
        )
        let routeReadings = dwell + [6, 9, 12].map { minute in
            transitReading(
                at: start.addingTimeInterval(Double(minute) * 60),
                point: GeoPoint(
                    latitude: 37.5 + Double(minute) / 1_000,
                    longitude: 127,
                    altitude: 0,
                    horizontalAccuracy: 10,
                    verticalAccuracy: 10
                )
            )
        }
        XCTAssertTrue(
            TransitBoardingCandidateEngine.candidates(
                readings: routeReadings,
                registeredLocations: [],
                nearbyPlaces: [station],
                travel: [highConfidence]
            ).isEmpty
        )
        XCTAssertEqual(
            TransitBoardingCandidateEngine.candidates(
                readings: dwell,
                registeredLocations: [],
                nearbyPlaces: [station],
                travel: [highConfidence]
            ).count,
            1
        )

        var confirmed = highConfidence
        confirmed.confidence = .low
        confirmed.isConfirmed = true
        XCTAssertTrue(
            TransitBoardingCandidateEngine.candidates(
                readings: dwell,
                registeredLocations: [],
                nearbyPlaces: [station],
                travel: [confirmed]
            ).isEmpty
        )
    }

    func testTransitBoardingDecisionDeletesCandidateAndConfirmsTravel() throws {
        let start = makeDate(2026, 8, 28, 11)
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 10
        )
        let location = UserTransitLocation(
            name: "서울역",
            kind: .trainStation,
            point: point
        )
        let segment = TravelSegment(
            mode: .car,
            span: TimeSpan(
                start: start.addingTimeInterval(180),
                end: start.addingTimeInterval(20 * 60)
            ),
            distanceMeters: 1_000,
            confidence: .low,
            evidence: ["자동 추정"]
        )
        let candidate = try XCTUnwrap(
            TransitBoardingCandidateEngine.candidates(
                readings: transitReadings(at: start, point: point, duration: 180),
                registeredLocations: [location],
                travel: [segment]
            ).first
        )

        let deleted = TransitBoardingDecision(
            candidateKey: candidate.id,
            span: candidate.span,
            mode: nil,
            travelSegmentIDs: candidate.travelSegmentIDs,
            updatedAt: start.addingTimeInterval(30 * 60)
        )
        XCTAssertTrue(
            TransitBoardingCandidateEngine.candidates(
                readings: transitReadings(at: start, point: point, duration: 180),
                registeredLocations: [location],
                travel: [segment],
                decisions: [deleted]
            ).isEmpty
        )

        let boarding = TransitBoardingDecision(
            candidateKey: candidate.id,
            span: candidate.span,
            mode: .train,
            travelSegmentIDs: candidate.travelSegmentIDs,
            updatedAt: start.addingTimeInterval(30 * 60)
        )
        let applied = try XCTUnwrap(
            TransitBoardingDecisionEngine.applying([boarding], to: [segment]).first
        )
        XCTAssertEqual(applied.mode, .train)
        XCTAssertEqual(applied.confidence, .high)
        XCTAssertTrue(applied.isConfirmed)
        XCTAssertTrue(applied.evidence.contains("사용자 확인 · 기차 탑승"))

        var settings = AppFeatureSettings.defaults
        settings.transitBoardingDecisions = [deleted]
        let restored = try JSONDecoder().decode(
            AppFeatureSettings.self,
            from: JSONEncoder().encode(settings)
        )
        XCTAssertEqual(restored.transitBoardingDecisions, [deleted])
    }

    @MainActor
    func testDeletingTransitBoardingCandidatePersistsBeforeReload() async throws {
        let start = makeDate(2026, 8, 28, 11)
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 10
        )
        let location = UserTransitLocation(
            name: "서울역",
            kind: .trainStation,
            point: point
        )
        let travel = [uncertainTransitTravel(at: start)]
        let candidate = try XCTUnwrap(
            TransitBoardingCandidateEngine.candidates(
                readings: transitReadings(at: start, point: point, duration: 180),
                registeredLocations: [location],
                travel: travel
            ).first
        )
        let repository = InMemoryPlanRepository()
        let model = AppModel(
            repository: repository,
            cloudSyncService: nil
        )
        await model.bootstrap()

        await model.deleteTransitBoardingCandidate(candidate)

        let reloaded = AppModel(
            repository: repository,
            cloudSyncService: nil
        )
        await reloaded.bootstrap()

        XCTAssertEqual(
            reloaded.snapshot.settings.transitBoardingDecisions.count,
            1
        )
        XCTAssertTrue(
            TransitBoardingCandidateEngine.candidates(
                readings: transitReadings(
                    at: start,
                    point: point,
                    duration: 180
                ),
                registeredLocations: [location],
                travel: travel,
                decisions: reloaded.snapshot.settings.transitBoardingDecisions
            ).isEmpty
        )
    }

    func testTransitBoardingDeletionSuppressesNearbyRegeneratedCandidates() throws {
        let start = makeDate(2026, 8, 28, 12)
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 10
        )
        let nearbyPoint = GeoPoint(
            latitude: 37.5005,
            longitude: 127,
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 10
        )
        let firstPlace = TransitBoardingPlace(
            mapKitName: "서울역",
            kind: .trainStation,
            point: point
        )
        let nearbyPlace = TransitBoardingPlace(
            mapKitName: "서울역 2번 출구",
            kind: .trainStation,
            point: nearbyPoint
        )
        let readings = transitReadings(
            at: start,
            point: point,
            duration: 180
        )
        let travel = [uncertainTransitTravel(at: start)]
        let candidates = TransitBoardingCandidateEngine.candidates(
            readings: readings,
            registeredLocations: [],
            nearbyPlaces: [firstPlace, nearbyPlace],
            travel: travel
        )
        let deleted = try XCTUnwrap(candidates.first)
        let decision = TransitBoardingDecision(
            candidateKey: deleted.id,
            placeID: deleted.placeID,
            kind: deleted.kind,
            point: deleted.point,
            span: deleted.span,
            mode: nil
        )

        XCTAssertTrue(
            TransitBoardingCandidateEngine.candidates(
                readings: readings,
                registeredLocations: [],
                nearbyPlaces: [firstPlace, nearbyPlace],
                travel: travel,
                decisions: [decision]
            ).isEmpty
        )
    }

    func testTransitBoardingDeletionSuppressesStablePlaceAfterPOIRefresh() throws {
        let start = makeDate(2026, 8, 28, 13)
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 10
        )
        let originalPlace = TransitBoardingPlace(
            mapKitName: "서울역",
            kind: .trainStation,
            point: point
        )
        let originalTravel = [uncertainTransitTravel(at: start)]
        let originalCandidate = try XCTUnwrap(
            TransitBoardingCandidateEngine.candidates(
                readings: transitReadings(
                    at: start,
                    point: point,
                    duration: 180
                ),
                registeredLocations: [],
                nearbyPlaces: [originalPlace],
                travel: originalTravel
            ).first
        )
        let decision = TransitBoardingDecision(
            candidateKey: originalCandidate.id,
            placeID: originalCandidate.placeID,
            kind: originalCandidate.kind,
            point: originalCandidate.point,
            span: originalCandidate.span,
            mode: nil
        )

        let refreshedPlace = TransitBoardingPlace(
            mapKitName: "서울역 2번 출구",
            kind: .trainStation,
            point: GeoPoint(
                latitude: point.latitude + 0.0002,
                longitude: point.longitude,
                altitude: 0,
                horizontalAccuracy: 10,
                verticalAccuracy: 10
            )
        )
        let refreshedCandidate = try XCTUnwrap(
            TransitBoardingCandidateEngine.candidates(
                readings: transitReadings(
                    at: start.addingTimeInterval(4 * 60),
                    point: point,
                    duration: 180
                ),
                registeredLocations: [],
                nearbyPlaces: [refreshedPlace],
                travel: [
                    uncertainTransitTravel(
                        at: start.addingTimeInterval(4 * 60)
                    )
                ]
            ).first
        )
        let nearbyBusPlace = TransitBoardingPlace(
            mapKitName: "서울역 버스정류장",
            kind: .busStop,
            point: GeoPoint(
                latitude: point.latitude + 0.0003,
                longitude: point.longitude,
                altitude: 0,
                horizontalAccuracy: 10,
                verticalAccuracy: 10
            )
        )

        XCTAssertNotEqual(refreshedCandidate.id, originalCandidate.id)
        XCTAssertEqual(refreshedCandidate.placeID, originalCandidate.placeID)
        XCTAssertTrue(
            TransitBoardingCandidateEngine.candidates(
                readings: transitReadings(
                    at: start.addingTimeInterval(4 * 60),
                    point: point,
                    duration: 180
                ),
                registeredLocations: [],
                nearbyPlaces: [refreshedPlace, nearbyBusPlace],
                travel: [
                    uncertainTransitTravel(
                        at: start.addingTimeInterval(4 * 60)
                    )
                ],
                decisions: [decision]
            ).isEmpty
        )
    }

    func testTransitBoardingMapKitIdentifierRemainsStableAcrossRefresh() {
        let first = TransitBoardingPlace(
            mapKitIdentifier: "map-item-123",
            mapKitName: "서울역",
            kind: .trainStation,
            point: GeoPoint(
                latitude: 37.5547,
                longitude: 126.9707,
                altitude: 0,
                horizontalAccuracy: 0,
                verticalAccuracy: 0
            )
        )
        let refreshed = TransitBoardingPlace(
            mapKitIdentifier: "map-item-123",
            mapKitName: "서울역 2번 출구",
            kind: .trainStation,
            point: GeoPoint(
                latitude: 37.5549,
                longitude: 126.9708,
                altitude: 0,
                horizontalAccuracy: 0,
                verticalAccuracy: 0
            )
        )

        XCTAssertEqual(first.id, refreshed.id)
        XCTAssertNotEqual(first.name, refreshed.name)
        XCTAssertNotEqual(first.point, refreshed.point)
    }

    func testTransitBoardingDeduplicatesSameStationLocation() {
        let start = makeDate(2026, 8, 28, 14)
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 10
        )
        let nearbyPoint = GeoPoint(
            latitude: 37.5003,
            longitude: 127,
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 10
        )
        let readings = [
            transitReading(at: start, point: point),
            transitReading(at: start.addingTimeInterval(3 * 60), point: point),
            transitReading(at: start.addingTimeInterval(10 * 60), point: point),
            transitReading(at: start.addingTimeInterval(13 * 60), point: point),
        ]
        let candidates = TransitBoardingCandidateEngine.candidates(
            readings: readings,
            registeredLocations: [],
            nearbyPlaces: [
                TransitBoardingPlace(
                    mapKitIdentifier: "train-station-main",
                    mapKitName: "서울역",
                    kind: .trainStation,
                    point: point
                ),
                TransitBoardingPlace(
                    mapKitIdentifier: "train-station-entrance",
                    mapKitName: "서울역 2번 출구",
                    kind: .trainStation,
                    point: nearbyPoint
                ),
                TransitBoardingPlace(
                    mapKitIdentifier: "bus-stop-main",
                    mapKitName: "서울역 버스정류장",
                    kind: .busStop,
                    point: point
                ),
            ],
            travel: [uncertainTransitTravel(at: start)]
        )

        XCTAssertEqual(candidates.filter { $0.kind == .trainStation }.count, 1)
        XCTAssertEqual(candidates.filter { $0.kind == .busStop }.count, 1)
    }

}
