import XCTest
import UIKit
import CoreLocation
import StoreKit
import StoreKitTest
import TaptionPlanCore
@testable import TaptionPlan

extension FeatureEngineTests {
    /// 확정 경로는 꺾은점만 남기고 좌표를 1e-7도 정수로 담는다. 직선 위의 점은 버리고 양 끝은 지킨다.
    func testSealedPolylineKeepsOnlyCornersAndRoundTrips() {
        var points: [GeoPoint] = []
        for step in 0...20 {
            points.append(
                GeoPoint(
                    latitude: 37.5 + Double(step) * 0.0002,
                    longitude: 127.0,
                    altitude: 0,
                    horizontalAccuracy: 0,
                    verticalAccuracy: 0
                )
            )
        }
        points.append(
            GeoPoint(
                latitude: 37.5 + 20 * 0.0002,
                longitude: 127.001,
                altitude: 0,
                horizontalAccuracy: 0,
                verticalAccuracy: 0
            )
        )

        let packed = TaptionSealedPolyline.encode(points: points, toleranceMeters: 8)
        XCTAssertEqual(packed.count % 2, 0)
        // 22점 → 시작·꺾은점·끝 3점.
        XCTAssertEqual(packed.count / 2, 3)
        XCTAssertLessThan(packed.count, points.count * 2)

        let restored = TaptionSealedPolyline.decode(packed)
        XCTAssertEqual(restored.count, 3)
        XCTAssertEqual(restored.first?.latitude ?? 0, points.first?.latitude ?? -1, accuracy: 1e-6)
        XCTAssertEqual(restored.first?.longitude ?? 0, points.first?.longitude ?? -1, accuracy: 1e-6)
        XCTAssertEqual(restored.last?.latitude ?? 0, points.last?.latitude ?? -1, accuracy: 1e-6)
        XCTAssertEqual(restored.last?.longitude ?? 0, points.last?.longitude ?? -1, accuracy: 1e-6)
        XCTAssertTrue(TaptionSealedPolyline.decode([]).isEmpty)
        XCTAssertEqual(TaptionSealedPolyline.encode(points: []).count, 0)
    }

    @MainActor
    func testActivityClassificationRetryReturnsClassificationFromLatestTravel()
        async {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let span = TimeSpan(start: start, end: start.addingTimeInterval(10 * 60))
        let latestTravel = TravelSegment(
            mode: .subway,
            span: span,
            distanceMeters: 1_000,
            confidence: .high,
            evidence: ["test"]
        )
        let readings = (0...9).map { index in
            SensorReading(
                timestamp: start.addingTimeInterval(Double(index * 60)),
                motion: .stationary,
                behavior: "subway",
                behaviorConfidenceScore: 0.9,
                behaviorEvidence: ["Watch"],
                sourceDevice: .appleWatch
            )
        }
        var snapshot = TaptionDataSnapshot.empty
        var revision: UInt64 = 1
        var attempts = 0
        var firstAttemptClassification: [ActualRecord]?
        var committedRevision: UInt64?
        var committedClassification: [ActualRecord]?

        let applied = await ActivityClassificationRetry.apply(
            capture: {
                ActivityClassificationSourceSnapshot(
                    revision: revision,
                    snapshot: snapshot
                )
            },
            currentRevision: { revision },
            classify: { source -> [ActualRecord]? in
                attempts += 1
                let result = TaptionActivityEngineAdapter.classifiedActivityActuals(
                    readings: readings,
                    travel: source.travel,
                    corrections: source.corrections,
                    actuals: source.actuals,
                    inside: span,
                    createdAt: start
                )
                if attempts == 1 {
                    firstAttemptClassification = result
                    snapshot.travel = [latestTravel]
                    revision = 2
                }
                return result
            },
            commit: { source, result in
                committedRevision = source.revision
                committedClassification = result
            }
        )

        let latestClassification = TaptionActivityEngineAdapter.classifiedActivityActuals(
            readings: readings,
            travel: [latestTravel],
            corrections: [:],
            actuals: [],
            inside: span,
            createdAt: start
        )
        XCTAssertTrue(applied)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(firstAttemptClassification?.first?.categoryID, "activity")
        XCTAssertEqual(committedRevision, 2)
        XCTAssertEqual(committedClassification, latestClassification)
        XCTAssertTrue(committedClassification?.isEmpty == true)
        XCTAssertEqual(
            TaptionActivityEngineAdapter.classify(
                readings: readings,
                travel: [latestTravel]
            ).segments.first?.majorCategoryID,
            "movement"
        )
    }

    func testCurrentActivityPolicyPrefersCurrentAutomaticAndRunningOvertime() throws {
        let now = Date()
        let old = ActualRecord(planID: nil, title: "old", categoryID: "work", startedAt: now.addingTimeInterval(-3 * hour), endedAt: now.addingTimeInterval(-2 * hour), source: .motion)
        let current = ActualRecord(planID: nil, title: "current", categoryID: "movement", startedAt: now.addingTimeInterval(-hour), source: .motion)
        let plan = PlanRecord(title: "plan", span: TimeSpan(start: now.addingTimeInterval(-2 * hour), end: now.addingTimeInterval(-hour)), categoryID: "work", status: .running)
        XCTAssertEqual(TaptionCurrentActivityPolicy.categoryID(actuals: [old, current], plans: [plan], at: now), "movement")
        XCTAssertEqual(TaptionCurrentActivityPolicy.categoryID(actuals: [old], plans: [plan], at: now), "work")
        XCTAssertNil(TaptionCurrentActivityPolicy.categoryID(actuals: [], plans: [], at: now))
    }

    @MainActor
    func testLiveActivityBitmapIsSmallNonemptyAndUsesDifferentMotionFrames() throws {
        let walking = try XCTUnwrap(TaptionCatAtlasBitmap.image(style: "white", action: .walking, frame: 0))
        let next = try XCTUnwrap(TaptionCatAtlasBitmap.image(style: "white", action: .walking, frame: 1))
        let sleep = try XCTUnwrap(TaptionCatAtlasBitmap.image(style: "white", action: .sleeping, frame: 0))
        XCTAssertEqual(walking.size.width, 52)
        XCTAssertEqual(walking.size.height, 32)
        XCTAssertNotEqual(walking.pngData(), next.pngData())
        XCTAssertNotEqual(walking.pngData(), sleep.pngData())
        XCTAssertTrue(walking === TaptionCatAtlasBitmap.image(style: "white", action: .walking, frame: 6))
    }

    func testIslandCatKeepsCurrentSemanticPoseAndExplicitMovementDetails() throws {
        let expected: [(String, TaptionCatAnimationAction)] = [("sleep", .sleeping), ("eating", .eating), ("movement", .walking), ("movement.running", .running), ("work", .kneading), ("study", .kneading), ("unconfirmed", .startled)]
        for (category, action) in expected {
            XCTAssertEqual(TaptionLiveActivityCatPolicy.action(categoryID: category, title: ""), action)
            let pose = TaptionCatAnimationEngine.pose(from: action.rawValue, progress: 0.5, phase: 0, facesLeft: false, tailSwing: 0, headTiltDegrees: 0)
            XCTAssertEqual(pose.action, action)
        }
        var state = SensorCollectionActivityAttributes.ContentState(startedAt: .now, lastSavedAt: nil, collectionKinds: [], isCollecting: true)
        state.currentActivityCatStyle = "white"
        state.currentActivityFrame = 5
        XCTAssertEqual(try JSONDecoder().decode(type(of: state), from: JSONEncoder().encode(state)).currentActivityCatStyle, "white")
        XCTAssertEqual(try JSONDecoder().decode(type(of: state), from: JSONEncoder().encode(state)).currentActivityFrame, 5)
        var oldPayload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        oldPayload.removeValue(forKey: "currentActivityFrame")
        oldPayload.removeValue(forKey: "currentActivityCatStyle")
        XCTAssertNil(try JSONDecoder().decode(type(of: state), from: JSONSerialization.data(withJSONObject: oldPayload)).currentActivityFrame)
    }

    func testLiveActivityContentStateOptionalFieldsDecodeAndRoundTrip() throws {
        let now = Date()
        let sensor = SensorCollectionActivityAttributes.ContentState(startedAt: now, lastSavedAt: nil, collectionKinds: ["location"], isCollecting: true, currentActivityTitle: "이동", currentActivityCategoryID: "movement")
        let decodedSensor = try JSONDecoder().decode(type(of: sensor), from: JSONEncoder().encode(sensor))
        XCTAssertEqual(decodedSensor.currentActivityTitle, "이동")
        let plan = TaptionActivityAttributes.ContentState(title: "업무", categoryID: "work", startedAt: now, endsAt: now.addingTimeInterval(hour), catStyle: "default", isRunning: true, compactActivityTitle: "이동", compactActivityCategoryID: "movement")
        let decodedPlan = try JSONDecoder().decode(type(of: plan), from: JSONEncoder().encode(plan))
        XCTAssertEqual(decodedPlan.compactActivityCategoryID, "movement")
        var oldSensor = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(sensor)
        ) as? [String: Any])
        oldSensor.removeValue(forKey: "currentActivityTitle")
        oldSensor.removeValue(forKey: "currentActivityCategoryID")
        oldSensor.removeValue(forKey: "currentActivitySystemImage")
        let legacySensor = try JSONDecoder().decode(type(of: sensor),
            from: JSONSerialization.data(withJSONObject: oldSensor))
        XCTAssertNil(legacySensor.currentActivityTitle)
        var oldPlan = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(plan)
        ) as? [String: Any])
        oldPlan.removeValue(forKey: "compactActivityTitle")
        oldPlan.removeValue(forKey: "compactActivityCategoryID")
        let legacyPlan = try JSONDecoder().decode(type(of: plan),
            from: JSONSerialization.data(withJSONObject: oldPlan))
        XCTAssertNil(legacyPlan.compactActivityCategoryID)
        XCTAssertEqual(legacyPlan.majorCategoryTitle, plan.majorCategoryTitle)
    }

    func testRouteReadingsTaskRestartsOnlyForBootstrapDayOrRawDataChange() {
        let day = makeDate(2026, 8, 25, 8)
        let sameDay = makeDate(2026, 8, 25, 20)

        XCTAssertNotEqual(
            MapHomeRouteReadingsTaskKey(
                date: day,
                isBootstrapped: false,
                calendar: utcCalendar
            ),
            MapHomeRouteReadingsTaskKey(
                date: day,
                isBootstrapped: true,
                calendar: utcCalendar
            )
        )
        XCTAssertEqual(
            MapHomeRouteReadingsTaskKey(
                date: day,
                isBootstrapped: true,
                calendar: utcCalendar
            ),
            MapHomeRouteReadingsTaskKey(
                date: sameDay,
                isBootstrapped: true,
                calendar: utcCalendar
            )
        )
        XCTAssertNotEqual(
            MapHomeRouteReadingsTaskKey(
                date: day,
                isBootstrapped: true,
                rawDataRevision: 1,
                calendar: utcCalendar
            ),
            MapHomeRouteReadingsTaskKey(
                date: day,
                isBootstrapped: true,
                rawDataRevision: 2,
                calendar: utcCalendar
            )
        )
        XCTAssertNotEqual(
            MapHomeRouteReadingsTaskKey(
                date: day,
                isBootstrapped: true,
                rawDataRevision: 3,
                isSceneActive: false,
                calendar: utcCalendar
            ),
            MapHomeRouteReadingsTaskKey(
                date: day,
                isBootstrapped: true,
                rawDataRevision: 3,
                isSceneActive: true,
                calendar: utcCalendar
            )
        )
    }

    func testEatingCategoryIsStableAndFollowsMovement() {
        let ids = RecordClassificationCatalog.categories.map(\.id)
        XCTAssertEqual(ids.firstIndex(of: "eating"), ids.firstIndex(of: "movement")! + 1)
        XCTAssertEqual(
            RecordAnalysisCategoryNormalizer.categoryID(
                for: "meal",
                title: "점심 식사"
            ),
            "eating"
        )
        XCTAssertEqual(
            RecordAnalysisCategoryNormalizer.categoryID(
                for: "activity",
                title: "밥"
            ),
            "eating"
        )
        XCTAssertEqual(
            RecordAnalysisCategoryNormalizer.categoryID(
                for: "activity",
                behavior: "cooking"
            ),
            "housework"
        )
        XCTAssertEqual(
            RecordAnalysisCategoryNormalizer.categoryID(
                for: "eating",
                behavior: "meal"
            ),
            "eating"
        )
    }

    func testMapUserActivityCategoriesNormalizeAndRoundTrip() throws {
        let id = UUID()
        var settings = AppFeatureSettings.defaults
        settings.mapUserActivityCategories =
            AppFeatureSettings.normalizedMapUserActivityCategories([
                MapUserActivityCategory(
                    id: id,
                    title: "  독서  ",
                    systemImage: "book.fill",
                    hex: "#29a383"
                ),
                MapUserActivityCategory(
                    id: UUID(),
                    title: "독서",
                    systemImage: "star.fill",
                    hex: "#FFFFFF"
                ),
            ])

        XCTAssertEqual(settings.mapUserActivityCategories.count, 1)
        XCTAssertEqual(settings.mapUserActivityCategories.first?.title, "독서")
        XCTAssertEqual(settings.mapUserActivityCategories.first?.hex, "#29A383")

        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(AppFeatureSettings.self, from: data)
        XCTAssertEqual(restored.mapUserActivityCategories, settings.mapUserActivityCategories)
    }

    func testActivityCorrectionSettingsRoundTrip() throws {
        let id = UUID()
        var settings = AppFeatureSettings.defaults
        settings.activityCorrections[id] = ActivityCorrection(
            title: "집안일",
            behavior: WatchBehaviorKind.housework.rawValue,
            categoryID: "activity"
        )
        settings.customActivityLabels = ["집안일"]

        let restored = try JSONDecoder().decode(
            AppFeatureSettings.self,
            from: JSONEncoder().encode(settings)
        )

        XCTAssertEqual(restored.activityCorrections[id]?.title, "집안일")
        XCTAssertEqual(restored.customActivityLabels, ["집안일"])
    }

    @MainActor
    func testActivitySectionSaveOverridesTravelAndSupportsImmediateReedit()
        async throws {
        let day = makeDate(2026, 8, 12)
        let span = TimeSpan(
            start: day.addingTimeInterval(9 * hour),
            end: day.addingTimeInterval(10 * hour)
        )
        let travel = TravelSegment(
            mode: .subway,
            span: span,
            distanceMeters: 12_000,
            confidence: .high,
            evidence: ["사용자 확인"],
            isConfirmed: true
        )
        var stored = TaptionDataSnapshot.empty
        stored.updatedAt = day
        stored.travel = [travel]
        stored.settings.locationEnabled = false
        stored.settings.weatherEnabled = false
        stored.settings.healthEnabled = false
        let repository = InMemoryPlanRepository(snapshot: stored)
        let model = AppModel(
            repository: repository,
            cloudSyncService: nil,
            registersHealthBackgroundHandler: false
        )
        await model.bootstrap()

        let firstResult = await model.saveActivitySectionEdit(
            ActivitySectionEditRequest(
                sourceIDs: [travel.id],
                originalSpan: span,
                originalOption: phaseOption("movement", title: "지하철 탑승"),
                mode: .replace(
                    editedSpan: span,
                    option: phaseOption("eating", title: "식사")
                )
            )
        )
        XCTAssertNotNil(firstResult)

        let firstRail = MapHomeTimeRailSegmentEngine.segments(
            from: model.snapshot.actuals,
            travel: model.snapshot.travel,
            on: day,
            asOf: day.addingTimeInterval(24 * hour),
            calendar: utcCalendar
        )
        let firstSegment = try XCTUnwrap(
            MapHomeTimeRailSegmentEngine.segment(
                at: 9 * 60 + 30,
                in: firstRail
            )
        )
        XCTAssertEqual(firstSegment.categoryID, "eating")
        XCTAssertFalse(firstSegment.sourceIDs.isEmpty)

        let secondResult = await model.saveActivitySectionEdit(
            ActivitySectionEditRequest(
                sourceIDs: firstSegment.sourceIDs,
                originalSpan: span,
                originalOption: phaseOption("eating", title: "식사"),
                mode: .replace(
                    editedSpan: span,
                    option: phaseOption("work", title: "업무")
                )
            )
        )
        XCTAssertNotNil(secondResult)

        let secondRail = MapHomeTimeRailSegmentEngine.segments(
            from: model.snapshot.actuals,
            travel: model.snapshot.travel,
            on: day,
            asOf: day.addingTimeInterval(24 * hour),
            calendar: utcCalendar
        )
        XCTAssertEqual(
            MapHomeTimeRailSegmentEngine.segment(
                at: 9 * 60 + 30,
                in: secondRail
            )?.categoryID,
            "work"
        )
        let persisted = try await repository.load()
        XCTAssertEqual(
            persisted.actuals.filter {
                $0.modelVersion == ActivitySectionOverrideEngine.modelVersion
            }.map(\.categoryID),
            ["work"]
        )
    }

    func testPlayheadMapUsesOnlyMovementContainingExactPlayheadTime() {
        let playhead = makeDate(2026, 8, 1, 9, 0)
        let nearby = TravelSegment(
            mode: .car,
            span: TimeSpan(
                start: playhead.addingTimeInterval(-30 * 60),
                end: playhead.addingTimeInterval(-10 * 60)
            ),
            distanceMeters: 4_000,
            confidence: .high,
            evidence: ["GPS"]
        )
        let containing = TravelSegment(
            mode: .walking,
            span: TimeSpan(
                start: playhead.addingTimeInterval(-5 * 60),
                end: playhead.addingTimeInterval(5 * 60)
            ),
            distanceMeters: 600,
            confidence: .high,
            evidence: ["걸음 수"]
        )
        let focusSpan = TimeSpan(
            start: playhead.addingTimeInterval(-15 * 60),
            end: playhead.addingTimeInterval(15 * 60)
        )

        let exact = TimelineRouteDisplayPolicy.segments(
            from: [nearby, containing],
            intersecting: focusSpan,
            at: playhead
        )
        XCTAssertEqual(exact.map(\.id), [containing.id])
        XCTAssertTrue(
            TimelineRouteDisplayPolicy.allowsFallbackPath(
                at: playhead,
                routeSegments: exact
            )
        )

        let noMovement = TimelineRouteDisplayPolicy.segments(
            from: [nearby],
            intersecting: focusSpan,
            at: playhead
        )
        XCTAssertTrue(noMovement.isEmpty)
        XCTAssertFalse(
            TimelineRouteDisplayPolicy.allowsFallbackPath(
                at: playhead,
                routeSegments: noMovement
            )
        )

        let rangeSelection = TimelineRouteDisplayPolicy.segments(
            from: [nearby, containing],
            intersecting: focusSpan,
            at: nil
        )
        XCTAssertEqual(Set(rangeSelection.map(\.id)), Set([nearby.id, containing.id]))

        let tappedSegment = TimelineRouteDisplayPolicy.segments(
            from: [nearby, containing],
            intersecting: focusSpan,
            at: nil,
            selectedTravelID: nearby.id
        )
        XCTAssertEqual(tappedSegment.map(\.id), [nearby.id])
    }

    func testRouteMapContextFollowsTheVisiblePeriodExceptAtYearScale() {
        let day = TimeSpan(
            start: makeDate(2026, 8, 1),
            end: makeDate(2026, 8, 2)
        )
        for level in [TimelineLevel.day, .week, .month] {
            XCTAssertEqual(
                TimelineRouteDisplayPolicy.contextSpan(
                    for: level,
                    visibleSpan: day
                ),
                day,
                "\(level) 눈금은 보이는 기간 전체를 지도에 깔아야 한다"
            )
        }
        XCTAssertNil(
            TimelineRouteDisplayPolicy.contextSpan(
                for: .year,
                visibleSpan: day
            ),
            "년 눈금은 배경 경로를 깔지 않는다"
        )
    }

    func testRouteMapViewportFitsVerticalRouteInsideEdgePadding() throws {
        let viewport = CGSize(width: 390, height: 216)
        let padding = RouteMapViewport.Padding(
            top: 34,
            leading: 22,
            bottom: 28,
            trailing: 22
        )
        let region = try XCTUnwrap(
            RouteMapViewport.region(
                for: [
                    CLLocationCoordinate2D(latitude: 37.50, longitude: 126.98),
                    CLLocationCoordinate2D(latitude: 37.62, longitude: 126.98),
                ],
                viewport: viewport,
                padding: padding
            )
        )

        XCTAssertEqual(region.center.latitude, 37.56, accuracy: 0.000_001)
        XCTAssertEqual(region.center.longitude, 126.98, accuracy: 0.000_001)
        XCTAssertEqual(
            0.12 / region.span.latitudeDelta,
            (216 - 34 - 28) / 216,
            accuracy: 0.001
        )
    }

    func testRouteMapViewportFitsHorizontalRouteInsideEdgePadding() throws {
        let viewport = CGSize(width: 390, height: 216)
        let padding = RouteMapViewport.Padding(
            top: 34,
            leading: 22,
            bottom: 28,
            trailing: 22
        )
        let region = try XCTUnwrap(
            RouteMapViewport.region(
                for: [
                    CLLocationCoordinate2D(latitude: 37.56, longitude: 126.72),
                    CLLocationCoordinate2D(latitude: 37.56, longitude: 127.18),
                ],
                viewport: viewport,
                padding: padding
            )
        )

        XCTAssertEqual(region.center.latitude, 37.56, accuracy: 0.000_001)
        XCTAssertEqual(region.center.longitude, 126.95, accuracy: 0.000_001)
        XCTAssertEqual(
            0.46 / region.span.longitudeDelta,
            (390 - 22 - 22) / 390,
            accuracy: 0.001
        )
    }

    func testRouteMapViewportFitsShortDateLineCrossingRoute() throws {
        let region = try XCTUnwrap(
            RouteMapViewport.region(
                for: [
                    CLLocationCoordinate2D(latitude: 10, longitude: 179.9),
                    CLLocationCoordinate2D(latitude: 10, longitude: -179.9),
                ],
                viewport: CGSize(width: 390, height: 216),
                padding: .timeline
            )
        )

        XCTAssertLessThan(abs(abs(region.center.longitude) - 180), 0.001)
        XCTAssertLessThan(region.span.longitudeDelta, 1)
    }

    func testRouteMapViewportUsesMinimumCircularRangeAcrossDistantPaths() throws {
        let region = try XCTUnwrap(
            RouteMapViewport.region(
                for: [
                    [CLLocationCoordinate2D(latitude: 10, longitude: 0)],
                    [CLLocationCoordinate2D(latitude: 10, longitude: 179.9)],
                    [CLLocationCoordinate2D(latitude: 10, longitude: -179.9)],
                ],
                viewport: CGSize(width: 390, height: 216),
                padding: .timeline
            )
        )

        XCTAssertLessThan(region.span.longitudeDelta, 220)
    }

    func testRouteContextKeepsEveryTripInOrderAndCapsTheLongestOnes() {
        let day = makeDate(2026, 8, 1)
        let span = TimeSpan(start: day, end: day.addingTimeInterval(24 * hour))
        let trips = (0..<10).map { index in
            TravelSegment(
                mode: .walking,
                span: TimeSpan(
                    start: day.addingTimeInterval(Double(index) * hour),
                    end: day.addingTimeInterval(Double(index) * hour + 600)
                ),
                distanceMeters: Double(index) * 100,
                confidence: .high,
                evidence: ["GPS"]
            )
        }
        let outside = TravelSegment(
            mode: .car,
            span: TimeSpan(
                start: day.addingTimeInterval(-4 * hour),
                end: day.addingTimeInterval(-3 * hour)
            ),
            distanceMeters: 50_000,
            confidence: .high,
            evidence: ["GPS"]
        )

        let all = TimelineRouteDisplayPolicy.contextSegments(
            from: trips + [outside],
            intersecting: span
        )
        XCTAssertEqual(all.map(\.id), trips.map(\.id))

        let capped = TimelineRouteDisplayPolicy.contextSegments(
            from: trips,
            intersecting: span,
            limit: 3
        )
        XCTAssertEqual(capped.count, 3)
        XCTAssertEqual(
            Set(capped.map(\.id)),
            Set(trips.suffix(3).map(\.id)),
            "상한을 넘으면 이동 거리가 긴 구간이 남는다"
        )
        XCTAssertEqual(
            capped.map(\.span.start),
            capped.map(\.span.start).sorted(),
            "남은 구간은 시간 순서를 지킨다"
        )
    }

    func testRouteReadingSpanStopsAtTheSensorRetentionWindow() {
        let now = makeDate(2026, 8, 25, 15, 30)
        let month = TimeSpan(
            start: makeDate(2026, 8, 1),
            end: makeDate(2026, 9, 1)
        )
        let fallback = TimeSpan(
            start: makeDate(2026, 8, 25),
            end: makeDate(2026, 8, 26)
        )

        let clamped = TimelineRouteDisplayPolicy.readingSpan(
            context: month,
            fallback: fallback,
            now: now
        )
        XCTAssertEqual(clamped.end, month.end)
        XCTAssertGreaterThan(clamped.start, month.start)
        XCTAssertLessThanOrEqual(
            now.timeIntervalSince(clamped.start),
            TimelineRouteDisplayPolicy.readingRetentionWindow + 86_400
        )

        // 화면을 다시 그려도 구간이 흔들리면 기록 읽기가 끝없이 다시
        // 시작한다. 같은 날 안에서는 같은 값이 나와야 한다.
        XCTAssertEqual(
            clamped,
            TimelineRouteDisplayPolicy.readingSpan(
                context: month,
                fallback: fallback,
                now: now.addingTimeInterval(7 * 60)
            )
        )

        let ancient = TimeSpan(
            start: makeDate(2025, 1, 1),
            end: makeDate(2025, 2, 1)
        )
        XCTAssertEqual(
            TimelineRouteDisplayPolicy.readingSpan(
                context: ancient,
                fallback: fallback,
                now: now
            ),
            fallback,
            "좌표가 남아 있지 않은 기간은 예전 구간 그대로 읽는다"
        )
        XCTAssertEqual(
            TimelineRouteDisplayPolicy.readingSpan(
                context: nil,
                fallback: fallback,
                now: now
            ),
            fallback
        )
    }

    func testRouteDecimationNeverDrawsMoreThanTheCap() {
        // 5m 오차로는 하나도 못 줄이는 톱니 경로. 상한이 없으면 그대로
        // 수천 점을 그리게 된다.
        let zigzag = (0..<5_000).map { index in
            CLLocationCoordinate2D(
                latitude: 37.5 + Double(index) * 0.0005,
                longitude: 127.0 + (index % 2 == 0 ? 0.0005 : -0.0005)
            )
        }
        let simplified = RoutePolylineDecimator.decimate(
            zigzag,
            toleranceMeters: 5,
            limit: 400
        )
        XCTAssertLessThanOrEqual(simplified.count, 400)
        XCTAssertEqual(simplified.first?.latitude, zigzag.first?.latitude)
        XCTAssertEqual(simplified.last?.latitude, zigzag.last?.latitude)
    }

    func testRouteDecimationPreservesSharpDetourBetweenUniformSamples() {
        let detourIndex = 1_233
        let detour = CLLocationCoordinate2D(latitude: 37.51, longitude: 127 + Double(detourIndex) * 0.00001)
        let dense = (0..<5_000).map { index in
            index == detourIndex
                ? detour
                : CLLocationCoordinate2D(
                    latitude: 37.5,
                    longitude: 127 + Double(index) * 0.00001
                )
        }

        let simplified = RoutePolylineDecimator.decimate(
            dense,
            toleranceMeters: 5,
            limit: 400
        )

        XCTAssertLessThanOrEqual(simplified.count, 400)
        XCTAssertTrue(
            simplified.contains {
                $0.latitude == detour.latitude && $0.longitude == detour.longitude
            },
            "a sharp detour between uniform sampling slots must remain in the route"
        )
    }

    func testRouteSpacingDropsStandingJitterButKeepsArrival() {
        var points = [CLLocationCoordinate2D](
            repeating: CLLocationCoordinate2D(latitude: 37.5, longitude: 127.0),
            count: 40
        )
        points.append(
            CLLocationCoordinate2D(latitude: 37.5008, longitude: 127.0)
        )
        let spaced = RoutePolylineDecimator.spaced(points, minimumMeters: 3)
        XCTAssertEqual(spaced.count, 2)
        XCTAssertEqual(spaced.first?.latitude, points.first?.latitude)
        XCTAssertEqual(spaced.last?.latitude, points.last?.latitude)
    }

    func testRouteHitTestMeasuresDistanceToTheDrawnLine() {
        let line = [
            CLLocationCoordinate2D(latitude: 37.5000, longitude: 127.0000),
            CLLocationCoordinate2D(latitude: 37.5000, longitude: 127.0020),
        ]
        let onLine = RoutePolylineDecimator.distanceMeters(
            from: CLLocationCoordinate2D(latitude: 37.5, longitude: 127.001),
            to: line
        ) ?? .infinity
        XCTAssertLessThan(onLine, 1)

        let offLine = RoutePolylineDecimator.distanceMeters(
            from: CLLocationCoordinate2D(latitude: 37.5009, longitude: 127.001),
            to: line
        ) ?? 0
        XCTAssertEqual(offLine, 100, accuracy: 5)
        XCTAssertNil(RoutePolylineDecimator.distanceMeters(from: line[0], to: []))
    }

    func testRoutePolylineGeometryUsesShortestLongitudeAcrossDateLine() throws {
        let line = [
            CLLocationCoordinate2D(latitude: 10, longitude: 179.9),
            CLLocationCoordinate2D(latitude: 10, longitude: 180),
            CLLocationCoordinate2D(latitude: 10, longitude: -179.9),
        ]
        let simplified = RoutePolylineDecimator.decimate(
            line,
            toleranceMeters: 10,
            limit: 10
        )
        let distance = try XCTUnwrap(
            RoutePolylineDecimator.distanceMeters(
                from: CLLocationCoordinate2D(latitude: 10, longitude: 180),
                to: [line[0], line[2]]
            )
        )

        XCTAssertEqual(simplified.count, 2)
        XCTAssertLessThan(distance, 1)
    }

    func testMovementDisplayHidesRawRecordWhenTravelCoversIt() {
        let start = makeDate(2026, 8, 1, 9)
        let end = start.addingTimeInterval(20 * 60)
        let raw = ActualRecord(
            planID: nil,
            title: "걷기",
            categoryID: "movement",
            startedAt: start,
            endedAt: end,
            source: .motion
        )
        let travel = TravelSegment(
            mode: .walking,
            span: TimeSpan(start: start, end: end),
            distanceMeters: 1_200,
            confidence: .high,
            evidence: ["GPS"]
        )

        XCTAssertTrue(
            MovementDisplayEngine.visibleActuals(
                [raw],
                travel: [travel],
                asOf: end
            ).isEmpty
        )
        XCTAssertEqual(
            MovementDisplayEngine.visibleActuals(
                [raw],
                travel: [],
                asOf: end
            ).map(\.id),
            [raw.id]
        )
    }

    func testMovementDisplayKeepsManualClassificationOverCanonicalTravel() {
        let start = makeDate(2026, 8, 1, 9)
        let end = start.addingTimeInterval(20 * 60)
        let manual = ActualRecord(
            planID: nil,
            title: "걷기",
            categoryID: "movement",
            startedAt: start,
            endedAt: end,
            source: .manual,
            confidence: .high,
            behavior: "walking",
            manuallyCorrected: true
        )
        let travel = TravelSegment(
            mode: .car,
            span: TimeSpan(start: start, end: end),
            distanceMeters: 1_200,
            confidence: .high,
            evidence: ["GPS"]
        )

        XCTAssertEqual(
            MovementDisplayEngine.visibleActuals(
                [manual],
                travel: [travel],
                asOf: end
            ).map(\.id),
            [manual.id]
        )
    }

    func testConfirmedCanonicalTravelIsNotMarkedAsManualCorrection() {
        let start = makeDate(2026, 8, 1, 9)
        let segment = TravelSegment(
            mode: .car,
            span: TimeSpan(start: start, end: start.addingTimeInterval(20 * 60)),
            distanceMeters: 1_200,
            confidence: .high,
            evidence: ["GPS"],
            isConfirmed: true
        )

        let result = MovementDisplayEngine.reviewActuals(
            [],
            travel: [segment],
            asOf: segment.span.end
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertFalse(result[0].manuallyCorrected)
    }

    func testMovementDisplayRejectsLocationWalkingAndKeepsCanonicalCar() {
        let start = makeDate(2026, 8, 5, 10)
        let raw = ActualRecord(
            planID: nil,
            title: "걷기",
            categoryID: "activity",
            startedAt: start,
            endedAt: start.addingTimeInterval(12 * hour),
            source: .location,
            confidence: .high,
            behavior: "walking",
            evidence: ["위치 변화"]
        )
        let car = TravelSegment(
            mode: .car,
            span: TimeSpan(
                start: start.addingTimeInterval(9 * hour),
                end: start.addingTimeInterval(11 * hour)
            ),
            distanceMeters: 20_100,
            confidence: .high,
            evidence: ["도로 위 차량 속도"]
        )

        XCTAssertTrue(
            MovementDisplayEngine.visibleActuals(
                [raw],
                travel: [car],
                asOf: start.addingTimeInterval(12 * hour)
            ).isEmpty
        )
        let review = MovementDisplayEngine.reviewActuals(
            [raw],
            travel: [car],
            asOf: start.addingTimeInterval(12 * hour)
        )
        XCTAssertEqual(review.map(\.title), ["자동차"])
        XCTAssertEqual(review.map(\.categoryID), ["movement"])
    }

    func testMovementDisplayKeepsOnlyCertainWalkingOutsideCanonicalTravel() {
        let start = makeDate(2026, 8, 5, 9)
        let uncertain = ActualRecord(
            planID: nil,
            title: "걷기",
            categoryID: "movement",
            startedAt: start,
            endedAt: start.addingTimeInterval(hour),
            source: .motion,
            confidence: .medium
        )
        let certain = ActualRecord(
            planID: nil,
            title: "걷기",
            categoryID: "movement",
            startedAt: start,
            endedAt: start.addingTimeInterval(hour),
            source: .motion,
            confidence: .high,
            evidence: ["iPhone 걸음·거리 기록"]
        )
        let car = TravelSegment(
            mode: .car,
            span: TimeSpan(
                start: start.addingTimeInterval(20 * 60),
                end: start.addingTimeInterval(40 * 60)
            ),
            distanceMeters: 5_000,
            confidence: .high,
            evidence: ["GPS"]
        )

        XCTAssertTrue(
            MovementDisplayEngine.visibleActuals(
                [uncertain], travel: [], asOf: start.addingTimeInterval(hour)
            ).isEmpty
        )
        let visible = MovementDisplayEngine.visibleActuals(
            [certain],
            travel: [car],
            asOf: start.addingTimeInterval(hour)
        )
        XCTAssertEqual(visible.count, 2)
        XCTAssertEqual(visible.reduce(0) { $0 + $1.span().duration }, 40 * 60)
        XCTAssertTrue(visible.allSatisfy {
            $0.span().intersection(with: car.span) == nil
        })
    }

    func testHierarchyRejectsCycle() throws {
        let base = makeDate(2026, 1, 1)
        var first = PlanRecord(
            title: "A",
            span: TimeSpan(start: base, end: base.addingTimeInterval(hour)),
            categoryID: "project"
        )
        let second = PlanRecord(
            title: "B",
            span: first.span,
            categoryID: "project",
            parentID: first.id
        )
        first.parentID = second.id
        XCTAssertThrowsError(try PlanHierarchy.validate([first, second])) {
            XCTAssertEqual($0 as? PlanningError, .parentCycle)
        }
    }

    func testBackgroundLocationPromotesUnscheduledMovement() {
        XCTAssertTrue(
            TrackingSessionPolicy.shouldPromoteBackgroundMovement(
                speedMetersPerSecond: 8,
                displacementMeters: 0,
                elapsed: 0
            )
        )
        XCTAssertTrue(
            TrackingSessionPolicy.shouldPromoteBackgroundMovement(
                speedMetersPerSecond: -1,
                displacementMeters: 120,
                elapsed: 120
            )
        )
        XCTAssertFalse(
            TrackingSessionPolicy.shouldPromoteBackgroundMovement(
                speedMetersPerSecond: -1,
                displacementMeters: 20,
                elapsed: 120
            )
        )
        XCTAssertFalse(
            TrackingSessionPolicy.shouldPromoteBackgroundMovement(
                speedMetersPerSecond: 8,
                displacementMeters: 120,
                elapsed: 120,
                horizontalAccuracy: 500,
                speedAccuracy: 1
            )
        )
        XCTAssertFalse(
            TrackingSessionPolicy.shouldPromoteBackgroundMovement(
                speedMetersPerSecond: 8,
                displacementMeters: 120,
                elapsed: 120,
                horizontalAccuracy: 10,
                speedAccuracy: -1
            )
        )
    }

    func testLiveRouteRequiresPreciseAvailableGPS() {
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 126.9,
            altitude: 20,
            horizontalAccuracy: 8,
            verticalAccuracy: 10
        )
        XCTAssertTrue(TrackingSessionPolicy.isPreciseRouteReading(
            SensorReading(timestamp: .now, point: point)
        ))
        XCTAssertFalse(TrackingSessionPolicy.isPreciseRouteReading(
            SensorReading(
                timestamp: .now,
                point: point,
                locationFixQuality: .approximate
            )
        ))
        XCTAssertFalse(TrackingSessionPolicy.isPreciseRouteReading(
            SensorReading(timestamp: .now, point: point, gpsAvailable: false)
        ))
    }

    func testDirectMotionAndShipClassification() {
        let base = makeDate(2026, 7, 30)
        let running = SensorReading(
            timestamp: base,
            speedMetersPerSecond: 3,
            motion: .running,
            motionConfidence: .high
        )
        XCTAssertEqual(
            TravelModeClassifier().classify(readings: [running]).mode,
            .running
        )

        let ship = SensorReading(
            timestamp: base,
            speedMetersPerSecond: 8,
            motion: .unknown,
            motionConfidence: .medium,
            nearPort: true,
            onWater: true
        )
        XCTAssertEqual(
            TravelModeClassifier().classify(readings: [ship]).mode,
            .ship
        )

        let flight = (0..<4).map { index in
            SensorReading(
                timestamp: base.addingTimeInterval(Double(index) * 5 * 60),
                speedMetersPerSecond: 70,
                motion: .unknown,
                motionConfidence: .medium,
                stepCount: 0,
                nearAirport: true
            )
        }
        XCTAssertEqual(
            TravelModeClassifier().classify(readings: flight).mode,
            .airplane
        )
    }

    func testTravelModeTiesPreferConservativeStableEvidenceOrder() {
        let base = makeDate(2026, 8, 10, 9, 0)
        let motionReadings = [
            SensorReading(
                timestamp: base,
                speedMetersPerSecond: 1,
                motion: .automotive,
                motionConfidence: .high
            ),
            SensorReading(
                timestamp: base.addingTimeInterval(2 * 60),
                speedMetersPerSecond: 1,
                motion: .stationary,
                motionConfidence: .high
            ),
        ]
        let classifier = TravelModeClassifier()
        let motionForward = classifier.classify(readings: motionReadings)
        let motionReverse = classifier.classify(
            readings: Array(motionReadings.reversed())
        )

        XCTAssertEqual(motionForward.mode, .walking)
        XCTAssertEqual(motionReverse.mode, motionForward.mode)

        let span = TimeSpan(start: base, end: base.addingTimeInterval(2 * 60))
        let workoutEvidence = [
            AppleMovementEvidence(
                span: span,
                source: .iPhone,
                kind: .workout,
                workoutMode: .walking,
                sourceName: "iPhone"
            ),
            AppleMovementEvidence(
                span: span,
                source: .iPhone,
                kind: .workout,
                workoutMode: .running,
                sourceName: "iPhone"
            ),
        ]
        let workoutForward = classifier.classify(
            readings: [],
            inside: span,
            healthEvidence: workoutEvidence
        )
        let workoutReverse = classifier.classify(
            readings: [],
            inside: span,
            healthEvidence: Array(workoutEvidence.reversed())
        )

        XCTAssertEqual(workoutForward.mode, .walking)
        XCTAssertEqual(workoutReverse.mode, workoutForward.mode)
    }

    func testLockedTravelMergeBoundsDisjointCandidateInspection() {
        let start = makeDate(2026, 8, 1, 0, 0)
        let count = 1_000
        let locked = (0..<count).map { index in
            let itemStart = start.addingTimeInterval(Double(index) * 60)
            return TravelSegment(
                mode: .walking,
                span: TimeSpan(
                    start: itemStart,
                    end: itemStart.addingTimeInterval(30)
                ),
                distanceMeters: 50,
                confidence: .high,
                evidence: ["기존"],
                isConfirmed: true,
                isClassificationLocked: true
            )
        }
        let fresh = (0..<count).map { index in
            let itemStart = start.addingTimeInterval(
                7 * 24 * hour + Double(index) * 60
            )
            return TravelSegment(
                mode: .walking,
                span: TimeSpan(
                    start: itemStart,
                    end: itemStart.addingTimeInterval(30)
                ),
                distanceMeters: 50,
                confidence: .high,
                evidence: ["신규"]
            )
        }
        var candidateInspectionCount = 0

        let result = ActivityClassificationLockEngine.mergingLockedTravel(
            existing: locked,
            fresh: fresh,
            inside: TimeSpan(
                start: start,
                end: start.addingTimeInterval(8 * 24 * hour)
            ),
            candidateInspectionCount: &candidateInspectionCount
        )

        XCTAssertEqual(result.count, count * 2)
        XCTAssertLessThan(candidateInspectionCount, count * count / 20)
    }

    /// MOV1110A01: 앱이 꺼진 공백까지 덮던 예전 잠긴 자동차 구간은, 겹치는 새 짧은 구간이 오면 남지 않는다.
    /// 사용자가 탑승 확인으로 고른 구간은 남는다.
    func testStaleLockedTravelOverlappingAFreshSegmentIsReplaced() {
        let base = makeDate(2026, 11, 10, 0)
        func at(_ hour: Double) -> Date { base.addingTimeInterval(hour * 3_600) }
        let old = TravelSegment(
            mode: .car, span: TimeSpan(start: at(16.73), end: at(20.74)), distanceMeters: 19_403, confidence: .high,
            evidence: ["사용자 확인 차량 블루투스 · CarPlay"], isConfirmed: true, isClassificationLocked: true
        )
        let fresh = TravelSegment(
            mode: .car, span: TimeSpan(start: at(19.96), end: at(20.74)), distanceMeters: 19_403, confidence: .high,
            evidence: ["사용자 확인 차량 블루투스 · CarPlay"], isConfirmed: true
        )
        let whole = TimeSpan(start: base, end: at(24))
        let result = ActivityClassificationLockEngine.mergingLockedTravel(existing: [old], fresh: [fresh], inside: whole)
        XCTAssertEqual(result.map(\.span.start), [at(19.96)], "only the fresh trip; 16:44–19:57 is no longer travel")

        var picked = old
        picked.evidence = ["사용자 확인 · 자동차"]
        // 겹침이 짧은 쪽의 20% 안 되는 예전 구간(새 판정과 짝이 안 지어짐)도 남지 않는다.
        let farOld = TravelSegment(
            mode: .car, span: TimeSpan(start: at(12), end: at(20.0)), distanceMeters: 19_403, confidence: .high,
            evidence: ["차량 오디오"], isConfirmed: true, isClassificationLocked: true
        )
        let shortFresh = TravelSegment(mode: .car, span: TimeSpan(start: at(19.9), end: at(20.74)), distanceMeters: 19_403, confidence: .high, evidence: [])
        XCTAssertEqual(ActivityClassificationLockEngine.mergingLockedTravel(existing: [farOld], fresh: [shortFresh], inside: whole).map(\.span.start), [at(19.9)])
        var pickedFar = farOld
        pickedFar.evidence = ["사용자 확인 · 자동차"]
        XCTAssertEqual(ActivityClassificationLockEngine.mergingLockedTravel(existing: [pickedFar], fresh: [shortFresh], inside: whole).count, 2,
                       "a span the user confirmed on a boarding card stays")
        _ = picked
    }

    /// MOV1110A01: 긴 잠긴 자동차 구간 안의 짧은 걷기는 자동차를 물려받지 않고, 그렇게 잘못 남은 「걷기 근거 자동차」도 걷기로 돌아온다.
    func testShortWalkInsideALockedCarDoesNotInheritCar() {
        let base = makeDate(2026, 11, 10, 0)
        func at(_ hour: Double) -> Date { base.addingTimeInterval(hour * 3_600) }
        let whole = TimeSpan(start: base, end: at(24))
        let longCar = TravelSegment(mode: .car, span: TimeSpan(start: at(16.73), end: at(20.74)), distanceMeters: 19_403, confidence: .high,
                                    evidence: ["사용자 확인 차량 블루투스 · CarPlay"], isConfirmed: true, isClassificationLocked: true)
        let walk = TravelSegment(mode: .walking, span: TimeSpan(start: at(18.11), end: at(18.22)), distanceMeters: 250, confidence: .high,
                                 evidence: ["iPhone Core Motion 걷기", "iPhone Core Motion 기록"])
        let merged = ActivityClassificationLockEngine.mergingLockedTravel(existing: [longCar], fresh: [walk], inside: whole)
        XCTAssertEqual(merged.map(\.mode), [.walking])
        XCTAssertEqual(merged.first?.isConfirmed, false)

        var wrong = walk
        wrong.mode = .car
        wrong.isConfirmed = true
        wrong.isClassificationLocked = true
        let repaired = ActivityClassificationLockEngine.mergingLockedTravel(existing: [wrong], fresh: [walk], inside: whole)
        XCTAssertEqual(repaired.map(\.mode), [.walking], "a car lock with only walking evidence is not passed on")
        let alone = ActivityClassificationLockEngine.mergingLockedTravel(existing: [wrong], fresh: [], inside: whole)
        XCTAssertEqual(alone.map(\.mode), [.walking], "kept on its own, it goes back to walking")
        XCTAssertEqual(alone.first?.isConfirmed, false)
    }

    func testMotionActivityActualsExposeEveryPassiveBehaviorWithoutDuplicates() {
        let base = makeDate(2026, 8, 1, 8)
        let span = TimeSpan(
            start: base,
            end: base.addingTimeInterval(30 * 60)
        )
        let activities = [
            MotionActivityRecord(
                span: TimeSpan(start: base, end: base.addingTimeInterval(5 * 60)),
                motion: .stationary,
                confidence: .high
            ),
            MotionActivityRecord(
                span: TimeSpan(
                    start: base.addingTimeInterval(5 * 60),
                    end: base.addingTimeInterval(10 * 60)
                ),
                motion: .walking,
                confidence: .high
            ),
            MotionActivityRecord(
                span: TimeSpan(
                    start: base.addingTimeInterval(10 * 60),
                    end: base.addingTimeInterval(15 * 60)
                ),
                motion: .running,
                confidence: .medium
            ),
            MotionActivityRecord(
                span: TimeSpan(
                    start: base.addingTimeInterval(15 * 60),
                    end: base.addingTimeInterval(20 * 60)
                ),
                motion: .cycling,
                confidence: .high
            ),
            MotionActivityRecord(
                span: TimeSpan(
                    start: base.addingTimeInterval(20 * 60),
                    end: base.addingTimeInterval(25 * 60)
                ),
                motion: .automotive,
                confidence: .medium
            ),
        ]

        let first = MotionActivityActualEngine.records(
            from: activities,
            existing: [],
            inside: span
        )
        let second = MotionActivityActualEngine.records(
            from: activities,
            existing: [],
            inside: span
        )

        XCTAssertEqual(
            first.map(\.title),
            ["정지·휴식", "걷기", "달리기", "자전거", "자동차"]
        )
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertTrue(first.allSatisfy { $0.source == .motion })

        let workout = ActualRecord(
            planID: nil,
            title: "걷기",
            categoryID: "exercise",
            startedAt: base.addingTimeInterval(5 * 60),
            endedAt: base.addingTimeInterval(10 * 60),
            source: .appleWatch
        )
        let withoutDuplicate = MotionActivityActualEngine.records(
            from: activities,
            existing: [workout],
            inside: span
        )
        XCTAssertFalse(withoutDuplicate.contains { $0.title == "걷기" })
    }

    func testMotionActivityActualsTreatExactOverlapThresholdAsCovered() {
        let base = makeDate(2026, 8, 1, 8)
        let span = TimeSpan(
            start: base,
            end: base.addingTimeInterval(10 * 60)
        )
        let activity = MotionActivityRecord(
            span: TimeSpan(
                start: base,
                end: base.addingTimeInterval(40)
            ),
            motion: .walking,
            confidence: .high
        )
        let workout = ActualRecord(
            planID: nil,
            title: "걷기",
            categoryID: "exercise",
            startedAt: base.addingTimeInterval(20),
            endedAt: base.addingTimeInterval(60),
            source: .appleWatch
        )

        let records = MotionActivityActualEngine.records(
            from: [activity],
            existing: [workout],
            inside: span
        )

        XCTAssertTrue(records.isEmpty)
    }

    func testMotionActivityActualsKeepsTouchingExistingRecordOutsideOverlap() {
        let base = makeDate(2026, 8, 1, 8)
        let activity = MotionActivityRecord(
            span: TimeSpan(
                start: base,
                end: base.addingTimeInterval(40)
            ),
            motion: .walking,
            confidence: .high
        )
        let workout = ActualRecord(
            planID: nil,
            title: "걷기",
            categoryID: "exercise",
            startedAt: base.addingTimeInterval(40),
            endedAt: base.addingTimeInterval(80),
            source: .appleWatch
        )

        let records = MotionActivityActualEngine.records(
            from: [activity],
            existing: [workout],
            inside: TimeSpan(
                start: base,
                end: base.addingTimeInterval(2 * 60)
            )
        )

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].title, "걷기")
        XCTAssertEqual(records[0].source, .motion)
        XCTAssertEqual(records[0].startedAt, base)
        XCTAssertEqual(records[0].endedAt, base.addingTimeInterval(40))
    }

    func testMotionActivityActualsBoundDisjointExistingRecordInspection() {
        let base = makeDate(2026, 8, 1, 0, 0)
        let count = 1_000
        let activities = (0..<count).map { index in
            let start = base.addingTimeInterval(TimeInterval(index * 5 * 60))
            return MotionActivityRecord(
                span: TimeSpan(
                    start: start,
                    end: start.addingTimeInterval(2 * 60)
                ),
                motion: .walking,
                confidence: .high
            )
        }
        let existing = (0..<count).map { index in
            let start = base.addingTimeInterval(
                30 * 24 * hour + TimeInterval(index * 5 * 60)
            )
            return ActualRecord(
                planID: nil,
                title: "걷기",
                categoryID: "exercise",
                startedAt: start,
                endedAt: start.addingTimeInterval(2 * 60),
                source: .appleWatch
            )
        }
        let inside = TimeSpan(
            start: base,
            end: base.addingTimeInterval(40 * 24 * hour)
        )
        var inspectionCount = 0

        let records = MotionActivityActualEngine.records(
            from: activities,
            existing: existing,
            inside: inside,
            candidateInspectionCount: &inspectionCount
        )

        XCTAssertEqual(records.count, count)
        XCTAssertLessThan(inspectionCount, count * count / 10)
    }

    func testIPhoneStepIncreaseSeparatesWalkingFromAutomotiveMotion() {
        let base = makeDate(2026, 7, 30, 9, 0)
        let span = TimeSpan(
            start: base,
            end: base.addingTimeInterval(3 * 60)
        )
        let walkingReadings = (0..<4).map { index in
            SensorReading(
                timestamp: base.addingTimeInterval(Double(index) * 60),
                speedMetersPerSecond: 1.4,
                motion: .automotive,
                motionConfidence: .medium,
                stepCount: index * 90
            )
        }
        let walking = TravelModeClassifier().classify(
            readings: walkingReadings,
            inside: span
        )

        XCTAssertEqual(walking.mode, .walking)
        XCTAssertTrue(
            walking.evidence.contains("iPhone 실시간 걸음 270보")
        )

        let automotiveReadings = (0..<4).map { index in
            SensorReading(
                timestamp: base.addingTimeInterval(Double(index) * 60),
                speedMetersPerSecond: 12,
                motion: .automotive,
                motionConfidence: .high,
                stepCount: 100 + min(index, 1)
            )
        }
        let automotive = TravelModeClassifier().classify(
            readings: automotiveReadings,
            inside: span
        )

        XCTAssertEqual(automotive.mode, .car)
        XCTAssertTrue(
            automotive.evidence.contains(
                "iPhone·Apple Watch 걸음 증가 거의 없음"
            )
        )
    }

    func testAutomotiveMotionWithVehicleSpeedBeatsIncidentalSteps() {
        let base = makeDate(2026, 7, 31, 19, 0)
        let span = TimeSpan(
            start: base,
            end: base.addingTimeInterval(10 * 60)
        )
        let readings = (0..<3).map { index in
            SensorReading(
                timestamp: base.addingTimeInterval(Double(index) * 5 * 60),
                point: GeoPoint(
                    latitude: 37.50 + Double(index) * 0.01,
                    longitude: 126.90 + Double(index) * 0.01,
                    altitude: 20,
                    horizontalAccuracy: 12,
                    verticalAccuracy: 30
                ),
                motion: .automotive,
                motionConfidence: .high,
                stepCount: 420 + index * 8
            )
        }

        let result = TravelModeClassifier().classify(
            readings: readings,
            inside: span
        )

        XCTAssertEqual(result.mode, .car)
        XCTAssertTrue(
            result.evidence.contains("차량 속도대와 자동차 모션 우선")
                || result.evidence.contains("차량 가능 속도")
                || result.evidence.contains("Core Motion 자동차 후보")
        )
    }

    func testVehicleSpeedAndLowStepsOverrideWalkingMotionHistory() {
        let base = makeDate(2026, 8, 2, 18, 0)
        let span = TimeSpan(
            start: base,
            end: base.addingTimeInterval(90 * 60)
        )
        let readings = (0..<7).map { index in
            SensorReading(
                timestamp: base.addingTimeInterval(Double(index) * 15 * 60),
                speedMetersPerSecond: 11,
                speedAccuracyMetersPerSecond: 0.8,
                motion: .walking,
                motionConfidence: .high,
                stepCount: 200 + index
            )
        }

        let result = TravelModeClassifier().classify(
            readings: readings,
            inside: span
        )

        XCTAssertEqual(result.mode, .car)
        XCTAssertTrue(
            result.evidence.contains("iPhone·Apple Watch 걸음 증가 거의 없음")
                || result.evidence.contains("보행 불가능 속도와 걸음 신호 불일치")
        )
    }

    func testCadenceAndMotionWindowIdentifyWalkingWithoutGPS() {
        let base = makeDate(2026, 8, 1, 8, 0)
        let readings = (0..<3).map { index in
            SensorReading(
                timestamp: base.addingTimeInterval(Double(index) * 60),
                speedMetersPerSecond: nil,
                motion: .unknown,
                motionConfidence: .low,
                currentPaceSecondsPerMeter: 0.72,
                currentCadenceStepsPerSecond: 1.75,
                deviceMotionSummary: DeviceMotionSummary(
                    sampleCount: 60,
                    meanUserAccelerationG: 0.12,
                    userAccelerationStandardDeviationG: 0.09,
                    peakUserAccelerationG: 0.42,
                    meanRotationRateRadiansPerSecond: 0.24,
                    rotationRateStandardDeviationRadiansPerSecond: 0.11,
                    peakRotationRateRadiansPerSecond: 0.72
                ),
                gpsAvailable: false
            )
        }

        let result = TravelModeClassifier().classify(
            readings: readings,
            inside: TimeSpan(
                start: base,
                end: base.addingTimeInterval(3 * 60)
            )
        )

        XCTAssertEqual(result.mode, .walking)
        XCTAssertTrue(
            result.evidence.contains {
                $0.contains("cadence 105보/분")
            }
        )
        XCTAssertTrue(
            result.evidence.contains("걸음 cadence와 3축 가속도 일치")
        )
    }

    func testLowStepAutomotiveMotionUsesVehicleVibrationWindow() {
        let base = makeDate(2026, 8, 1, 18, 0)
        let readings = (0..<4).map { index in
            SensorReading(
                timestamp: base.addingTimeInterval(Double(index) * 60),
                speedMetersPerSecond: 13,
                speedAccuracyMetersPerSecond: 0.8,
                motion: .automotive,
                motionConfidence: .high,
                stepCount: 20 + index,
                currentCadenceStepsPerSecond: 0,
                deviceMotionSummary: DeviceMotionSummary(
                    sampleCount: 30,
                    meanUserAccelerationG: 0.08,
                    userAccelerationStandardDeviationG: 0.04,
                    peakUserAccelerationG: 0.31,
                    meanRotationRateRadiansPerSecond: 0.09,
                    rotationRateStandardDeviationRadiansPerSecond: 0.03,
                    peakRotationRateRadiansPerSecond: 0.2
                )
            )
        }

        let result = TravelModeClassifier().classify(
            readings: readings,
            inside: TimeSpan(
                start: base,
                end: base.addingTimeInterval(4 * 60)
            )
        )

        XCTAssertEqual(result.mode, .car)
        XCTAssertTrue(result.evidence.contains("저걸음 차량 진동 패턴"))
    }

    func testMovementCorrectionSurvivesRefreshAndCanBeForgotten() throws {
        let base = makeDate(2026, 7, 30, 9, 0)
        let originalPlaces = [
            PlaceStay(
                placeKey: "home",
                displayName: "집",
                span: TimeSpan(
                    start: base.addingTimeInterval(-hour),
                    end: base
                ),
                confidence: .high
            ),
            PlaceStay(
                placeKey: "office",
                displayName: "회사",
                span: TimeSpan(
                    start: base.addingTimeInterval(hour),
                    end: base.addingTimeInterval(2 * hour)
                ),
                confidence: .high
            ),
        ]
        let original = TravelSegment(
            fromPlaceID: originalPlaces[0].id,
            toPlaceID: originalPlaces[1].id,
            mode: .car,
            span: TimeSpan(
                start: base,
                end: base.addingTimeInterval(hour)
            ),
            distanceMeters: 12_000,
            confidence: .medium,
            evidence: ["iPhone 자동차 활동"]
        )
        let corrections = MovementCorrectionEngine.recording(
            mode: .subway,
            for: original,
            places: originalPlaces,
            existing: [],
            at: base.addingTimeInterval(2 * hour)
        )

        let nextDay = base.addingTimeInterval(24 * hour)
        let refreshedPlaces = [
            PlaceStay(
                placeKey: "home",
                displayName: "집",
                span: TimeSpan(
                    start: nextDay.addingTimeInterval(-hour),
                    end: nextDay
                ),
                confidence: .high
            ),
            PlaceStay(
                placeKey: "office",
                displayName: "회사",
                span: TimeSpan(
                    start: nextDay.addingTimeInterval(hour),
                    end: nextDay.addingTimeInterval(2 * hour)
                ),
                confidence: .high
            ),
        ]
        var refreshed = TravelSegment(
            fromPlaceID: refreshedPlaces[0].id,
            toPlaceID: refreshedPlaces[1].id,
            mode: .bus,
            span: TimeSpan(
                start: nextDay,
                end: nextDay.addingTimeInterval(hour)
            ),
            distanceMeters: 12_100,
            confidence: .low,
            evidence: ["새 센서 판정"]
        )
        refreshed.subwayRoute = SubwayStationCatalog.route(for: ["마곡나루역", "검암역", "가정역"])

        let applied = try XCTUnwrap(
            MovementCorrectionEngine.applying(
                corrections,
                to: [refreshed],
                places: refreshedPlaces
            ).first
        )

        XCTAssertEqual(applied.mode, .subway)
        XCTAssertEqual(applied.confidence, .high)
        XCTAssertTrue(applied.isConfirmed)
        XCTAssertTrue(applied.evidence.contains("사용자 확인 기억"))
        XCTAssertEqual(corrections.first?.inferredMode, .car)
        XCTAssertTrue(
            MovementCorrectionEngine.removingCorrection(
                for: applied,
                places: refreshedPlaces,
                from: corrections
            ).isEmpty
        )
    }

    func testMovementCorrectionTieUsesStableIDRegardlessOfInputOrder() throws {
        let base = makeDate(2026, 8, 10, 9, 0)
        let start = base
        let end = base.addingTimeInterval(hour)
        let span = TimeSpan(start: start, end: end)
        let places = [
            PlaceStay(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
                placeKey: "home",
                displayName: "집",
                span: TimeSpan(start: start.addingTimeInterval(-hour), end: start),
                confidence: .high
            ),
            PlaceStay(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!,
                placeKey: "office",
                displayName: "회사",
                span: TimeSpan(start: end, end: end.addingTimeInterval(hour)),
                confidence: .high
            ),
        ]
        let segment = TravelSegment(
            fromPlaceID: places[0].id,
            toPlaceID: places[1].id,
            mode: .walking,
            span: span,
            distanceMeters: 5_000,
            confidence: .low,
            evidence: []
        )
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let corrections = [
            TravelModeCorrection(
                id: firstID,
                fromPlaceKey: "home",
                toPlaceKey: "office",
                span: span,
                mode: .car,
                inferredMode: .walking,
                inferredConfidence: .low,
                updatedAt: base
            ),
            TravelModeCorrection(
                id: secondID,
                fromPlaceKey: "home",
                toPlaceKey: "office",
                span: span,
                mode: .subway,
                inferredMode: .walking,
                inferredConfidence: .low,
                updatedAt: base
            ),
        ]
        let reversed = Array(corrections.reversed())

        let forwardApplied = try XCTUnwrap(
            MovementCorrectionEngine.applying(
                corrections,
                to: [segment],
                places: places
            ).first
        )
        let reversedApplied = try XCTUnwrap(
            MovementCorrectionEngine.applying(
                reversed,
                to: [segment],
                places: places
            ).first
        )
        XCTAssertEqual(forwardApplied.mode, .car)
        XCTAssertEqual(reversedApplied.mode, forwardApplied.mode)
        XCTAssertEqual(
            MovementCorrectionEngine.correction(
                for: segment,
                places: places,
                in: reversed
            )?.id,
            firstID
        )

        for input in [corrections, reversed] {
            let remaining = MovementCorrectionEngine.removingCorrection(
                for: segment,
                places: places,
                from: input
            )
            XCTAssertEqual(remaining.map(\.id), [secondID])
        }
    }

    func testAdjacentSimilarTravelSegmentsAreGrouped() throws {
        let base = makeDate(2026, 7, 31, 18, 21)
        let first = TravelSegment(
            mode: .car,
            span: TimeSpan(
                start: base,
                end: base.addingTimeInterval(4 * 60)
            ),
            distanceMeters: 1_100,
            confidence: .medium,
            evidence: ["Core Motion 자동차 후보"]
        )
        let second = TravelSegment(
            mode: .car,
            span: TimeSpan(
                start: base.addingTimeInterval(4 * 60),
                end: base.addingTimeInterval(7 * 60)
            ),
            distanceMeters: 900,
            confidence: .medium,
            evidence: ["iPhone Core Motion 기록"]
        )

        let group = try XCTUnwrap(
            TravelSegmentGroupingEngine.groups(from: [second, first]).first
        )

        XCTAssertEqual(group.segmentIDs, [first.id, second.id])
        XCTAssertEqual(group.mode, .car)
        XCTAssertEqual(group.span.start, first.span.start)
        XCTAssertEqual(group.span.end, second.span.end)
        XCTAssertEqual(group.distanceMeters, 2_000)
        XCTAssertEqual(group.evidence.count, 2)
    }

    func testTravelPresentationCollapsesOverlappingWalkingDuplicates() throws {
        let base = makeDate(2026, 8, 9, 18, 16)
        let inferred = TravelSegment(
            mode: .walking,
            span: TimeSpan(
                start: base,
                end: base.addingTimeInterval(78 * 60)
            ),
            distanceMeters: 5_600,
            confidence: .medium,
            evidence: ["iPhone Core Motion 기록"]
        )
        let confirmed = TravelSegment(
            mode: .walking,
            span: TimeSpan(
                start: base,
                end: base.addingTimeInterval(78 * 60)
            ),
            distanceMeters: 5_590,
            confidence: .high,
            evidence: ["iPhone 걸음·거리 기록"],
            isConfirmed: true
        )

        let values = TravelSegmentPresentationEngine.consolidated([
            inferred, confirmed, inferred, confirmed,
        ])
        XCTAssertEqual(values.count, 1)
        let result = try XCTUnwrap(values.first)

        XCTAssertEqual(result.id, confirmed.id)
        XCTAssertEqual(result.span, confirmed.span)
        XCTAssertEqual(result.distanceMeters, 5_600)
        XCTAssertEqual(result.confidence, .high)
        XCTAssertTrue(result.isConfirmed)
        XCTAssertEqual(result.evidence.count, 2)
    }

    func testTravelGroupingKeepsDifferentOrDistantSegmentsSeparate() {
        let base = makeDate(2026, 7, 31, 15, 42)
        let walking = TravelSegment(
            mode: .walking,
            span: TimeSpan(
                start: base,
                end: base.addingTimeInterval(21 * 60)
            ),
            distanceMeters: 1_000,
            confidence: .high,
            evidence: []
        )
        let laterWalking = TravelSegment(
            mode: .walking,
            span: TimeSpan(
                start: base.addingTimeInterval(38 * 60),
                end: base.addingTimeInterval(79 * 60)
            ),
            distanceMeters: 2_500,
            confidence: .medium,
            evidence: []
        )
        let car = TravelSegment(
            mode: .car,
            span: TimeSpan(
                start: base.addingTimeInterval(79 * 60),
                end: base.addingTimeInterval(83 * 60)
            ),
            distanceMeters: 900,
            confidence: .medium,
            evidence: []
        )

        XCTAssertEqual(
            TravelSegmentGroupingEngine.groups(
                from: [walking, laterWalking, car]
            ).map(\.segments.count),
            [1, 1, 1]
        )
    }

    func testApproximateGPSDoesNotCreateVehicleSpeedSignal() {
        let base = makeDate(2026, 8, 12, 8, 0)
        let readings = (0..<2).map { index in
            SensorReading(
                timestamp: base.addingTimeInterval(Double(index) * 60),
                point: GeoPoint(
                    latitude: 37.5 + Double(index) * 0.01,
                    longitude: 126.9,
                    altitude: 0,
                    horizontalAccuracy: 10,
                    verticalAccuracy: 10
                ),
                locationFixQuality: .approximate,
                speedMetersPerSecond: 12,
                motion: .walking,
                gpsAvailable: false
            )
        }

        XCTAssertEqual(TravelModeClassifier().classify(readings: readings).mode, .walking)
    }

    func testCoordinateTrajectoryRestoresGajeongCommuteWithTransferWalking() throws {
        let base = makeDate(2026, 8, 11, 9, 35)
        let samples: [(Double, Double, Double, Int)] = [
            (0, 37.5248, 126.6744, 100),
            (12, 37.5692, 126.6737, 320),
            (24, 37.57127, 126.7359, 520),
            (36, 37.5667, 126.8273, 720),
        ]
        let readings = samples.map { minute, latitude, longitude, steps in
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
                // 검암 환승 구간은 지하 승강장(-12m)을 지난다(SUB1029A01 고도 조건).
                relativeAltitudeMeters: minute == 12 || minute == 24 ? -12 : 0,
                stepCount: steps
            )
        }

        let result = TravelModeClassifier().classify(readings: readings)
        let route = try XCTUnwrap(result.subwayRoute)

        XCTAssertEqual(result.mode, .subway)
        XCTAssertEqual(result.confidence, .high)
        XCTAssertEqual(route.lineNames, ["인천2호선", "공항철도"])
        XCTAssertEqual(route.transferStationNames, ["검암"])
        XCTAssertTrue(result.evidence.contains("원본 좌표로 역 순서 복원"))
        XCTAssertTrue(result.evidence.contains("환승 보행 포함"))
    }

    func testCoordinateTrajectoryTrimsWalkingPastMagongnaru() throws {
        let base = makeDate(2026, 8, 11, 9, 35)
        let samples: [(Double, Double, Double)] = [
            (0, 37.5248, 126.6744),
            (12, 37.5692, 126.6737),
            (24, 37.57127, 126.7359),
            (36, 37.5667, 126.8273),
            (46, 37.5599, 126.8250),
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
                speedMetersPerSecond: minute == 46 ? 1.2 : 12,
                motion: minute == 46 ? .walking : .automotive,
                motionConfidence: .high
            )
        }

        let trajectory = try XCTUnwrap(
            SubwayStationCatalog.coordinateTrajectory(from: readings)
        )

        XCTAssertEqual(trajectory.route.stops.first?.stationName, "가정")
        XCTAssertEqual(trajectory.route.stops.last?.stationName, "마곡나루")
        XCTAssertEqual(trajectory.route.transferStationNames, ["검암"])
        XCTAssertEqual(
            trajectory.span.end,
            base.addingTimeInterval(36 * 60)
        )
    }

    func testCoordinateTrajectoryChoosesLongestSimpleRouteAcrossDayNoise() throws {
        let base = makeDate(2026, 8, 11, 9, 35)
        let samples: [(Double, Double, Double)] = [
            (0, 37.5248, 126.6744),
            (12, 37.5692, 126.6737),
            (24, 37.57127, 126.7359),
            (36, 37.5667, 126.8273),
            (52, 37.5692, 126.6737),
            (64, 37.5248, 126.6744),
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

        let trajectory = try XCTUnwrap(
            SubwayStationCatalog.coordinateTrajectory(from: readings)
        )

        XCTAssertEqual(trajectory.route.lineNames, ["인천2호선", "공항철도"])
        XCTAssertEqual(trajectory.route.transferStationNames, ["검암"])
        XCTAssertEqual(trajectory.route.stops.first?.stationName, "가정")
        XCTAssertEqual(trajectory.route.stops.last?.stationName, "마곡나루")
    }

    func testTravelModeClassifierIgnoresInvalidTimestampBeforeSorting() {
        let valid = SensorReading(
            timestamp: makeDate(2026, 8, 18, 7, 30),
            motion: .walking,
            motionConfidence: .medium
        )
        let invalidWatchHint = SensorReading(
            timestamp: Date(timeIntervalSinceReferenceDate: .nan),
            motion: .automotive,
            motionConfidence: .high,
            behavior: WatchBehaviorKind.automotive.rawValue,
            behaviorConfidenceScore: 0.95,
            sourceDevice: .appleWatch
        )

        let expected = TravelModeClassifier().classify(readings: [valid])
        let actual = TravelModeClassifier().classify(
            readings: [invalidWatchHint, valid]
        )

        XCTAssertEqual(actual, expected)
    }

    func testMovementRouteBuilderPreservesReadingOrderAndInclusiveBoundaries() {
        let start = makeDate(2026, 8, 18, 9)
        let movementStart = start.addingTimeInterval(30 * 60)
        let stays = [
            PlaceStay(
                placeKey: "home",
                displayName: "집",
                span: TimeSpan(start: start, end: movementStart),
                confidence: .high
            ),
            PlaceStay(
                placeKey: "office",
                displayName: "회사",
                span: TimeSpan(
                    start: start.addingTimeInterval(60 * 60),
                    end: start.addingTimeInterval(90 * 60)
                ),
                confidence: .high
            ),
        ]
        func point(_ longitude: Double) -> GeoPoint {
            GeoPoint(
                latitude: 0,
                longitude: longitude,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5
            )
        }
        let readings = [
            SensorReading(
                timestamp: start.addingTimeInterval(45 * 60),
                point: point(0.002),
                motion: .walking,
                motionConfidence: .high
            ),
            SensorReading(
                timestamp: movementStart,
                point: point(0),
                motion: .walking,
                motionConfidence: .high,
                nearAirport: true
            ),
            SensorReading(
                timestamp: start.addingTimeInterval(40 * 60),
                point: point(0.001),
                motion: .walking,
                motionConfidence: .high
            ),
        ]

        let result = MovementRouteBuilder().build(
            stays: stays,
            readings: readings
        )

        XCTAssertEqual(result.count, 1)
        // 공항 근처 표시만으로는 비행기가 아니다(ALG1101A01). 222m 걷기는 걷기다.
        XCTAssertEqual(result[0].mode, .walking)
        // 거리는 시간순(0 → 0.001 → 0.002도, 약 222m)으로 센다. 입력 순서대로 더하면 되돌아간 거리까지 333m로 부풀어
        // 실제 이동보다 크게 나온다(ARC1030A08, 지터에 강한 거리 계산).
        XCTAssertEqual(result[0].distanceMeters, 222, accuracy: 6)
    }

    func testMovementRouteBuilderBoundsDisjointEvidenceInspection() {
        let start = makeDate(2026, 8, 1, 0, 0)
        let count = 1_000
        let stays = (0..<count).map { index in
            let stayStart = start.addingTimeInterval(Double(index) * 60)
            return PlaceStay(
                placeKey: "place-\(index)",
                displayName: "장소 \(index)",
                span: TimeSpan(
                    start: stayStart,
                    end: stayStart.addingTimeInterval(30)
                ),
                confidence: .high
            )
        }
        let readings = (0..<count).map { index in
            SensorReading(
                timestamp: start.addingTimeInterval(
                    30 * 24 * hour + Double(index) * 60
                ),
                motion: .walking,
                motionConfidence: .high
            )
        }
        let healthEvidence = (0..<count).map { index in
            let evidenceStart = start.addingTimeInterval(
                60 * 24 * hour + Double(index) * 60
            )
            return AppleMovementEvidence(
                span: TimeSpan(
                    start: evidenceStart,
                    end: evidenceStart.addingTimeInterval(30)
                ),
                source: .iPhone,
                kind: .steps,
                stepCount: 10,
                sourceName: "Health"
            )
        }
        var candidateInspectionCount = 0

        let result = MovementRouteBuilder().build(
            stays: stays,
            readings: readings,
            healthEvidence: healthEvidence,
            candidateInspectionCount: &candidateInspectionCount
        )

        XCTAssertTrue(result.isEmpty)
        XCTAssertLessThan(candidateInspectionCount, count * count / 10)
    }

    func testMovementRouteBuilderAppliesWBSAirportEndpointWithoutFlightGPS() {
        let start = makeDate(2026, 9, 9, 9)
        let origin = GeoPoint(
            latitude: 37.4602,
            longitude: 126.4407,
            altitude: 0,
            horizontalAccuracy: 20,
            verticalAccuracy: 20
        )
        let destination = GeoPoint(
            latitude: 13.6900,
            longitude: 100.7501,
            altitude: 0,
            horizontalAccuracy: 20,
            verticalAccuracy: 20
        )
        let stays = [
            PlaceStay(
                placeKey: "icn",
                displayName: "인천국제공항",
                span: TimeSpan(
                    start: start,
                    end: start.addingTimeInterval(30 * 60)
                ),
                confidence: .high,
                point: origin
            ),
            PlaceStay(
                placeKey: "bkk",
                displayName: "Suvarnabhumi Airport",
                span: TimeSpan(
                    start: start.addingTimeInterval(8 * 60 * 60),
                    end: start.addingTimeInterval(8 * 60 * 60 + 30 * 60)
                ),
                confidence: .high,
                point: destination
            ),
        ]

        let result = MovementRouteBuilder().build(
            stays: stays,
            readings: []
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.mode, .airplane)
        XCTAssertEqual(
            result.first?.evidence,
            ["체류 사이 점프: 지상 불가 속도 · 비행"]
        )
        XCTAssertGreaterThan(result.first?.distanceMeters ?? 0, 3_000_000)
        XCTAssertFalse(result.first?.isConfirmed ?? true)
    }

    /// 끝점 이름(공항·항구)만으로는 비행기·배가 되지 않는다(ALG1101A01).
    func testWBSMovementTransportPolicyIgnoresEndpointNamesWithoutJump() {
        let start = makeDate(2026, 9, 9, 9)
        let stays = [
            PlaceStay(
                placeKey: "airport-marina",
                displayName: "Airport Marina",
                span: TimeSpan(
                    start: start,
                    end: start.addingTimeInterval(30 * 60)
                ),
                confidence: .high
            ),
            PlaceStay(
                placeKey: "destination",
                displayName: "도착지",
                span: TimeSpan(
                    start: start.addingTimeInterval(60 * 60),
                    end: start.addingTimeInterval(90 * 60)
                ),
                confidence: .high
            ),
        ]

        XCTAssertNil(
            WBSMovementTransportPolicy.recommendedMode(
                from: stays[0],
                to: stays[1]
            )
        )
    }

    func testCoreMotionWalkingLabelLosesToImpossibleDisplacementSpeed() {
        let base = makeDate(2026, 8, 4, 9, 24)
        let span = TimeSpan(start: base, end: base.addingTimeInterval(46 * 60))
        // 부천 → 계양 약 8km. Core Motion은 보행으로 라벨링한 상태.
        let readings = [
            SensorReading(
                timestamp: base,
                point: GeoPoint(
                    latitude: 37.4870,
                    longitude: 126.7830,
                    altitude: 30,
                    horizontalAccuracy: 12,
                    verticalAccuracy: 8
                ),
                motion: .walking,
                motionConfidence: .medium
            ),
            SensorReading(
                timestamp: span.end,
                point: GeoPoint(
                    latitude: 37.5385,
                    longitude: 126.8580,
                    altitude: 25,
                    horizontalAccuracy: 12,
                    verticalAccuracy: 8
                ),
                motion: .walking,
                motionConfidence: .medium
            ),
        ]

        let inference = TravelModeClassifier().classify(
            readings: readings,
            inside: span
        )

        XCTAssertNotEqual(inference.mode, .walking)
        XCTAssertNotEqual(inference.mode, .running)
    }

    func testEnforcingMotionFamilyRewritesCyclingOverAutomotiveWindow() {
        let base = makeDate(2026, 8, 4, 9, 26)
        let span = TimeSpan(start: base, end: base.addingTimeInterval(42 * 60))
        let cycling = TravelSegment(
            mode: .cycling,
            span: span,
            distanceMeters: 8_000,
            confidence: .medium,
            evidence: ["자전거 속도대"]
        )
        let activity = MotionActivityRecord(
            span: span,
            motion: .automotive,
            confidence: .high
        )
        let readings = [
            SensorReading(timestamp: base, stepCount: 120),
            SensorReading(timestamp: span.end, stepCount: 128),
        ]

        let result = AppleDeviceGroundTruthEngine.enforcingMotionFamily(
            [cycling],
            activities: [activity],
            readings: readings
        )

        XCTAssertEqual(result.first?.mode, .car)
    }

    func testEnforcingMotionFamilyKeepsWalkingWhenStepsIncrease() {
        let base = makeDate(2026, 8, 4, 9, 26)
        let span = TimeSpan(start: base, end: base.addingTimeInterval(10 * 60))
        let walking = TravelSegment(
            mode: .walking,
            span: span,
            distanceMeters: 800,
            confidence: .high,
            evidence: ["Core Motion 보행"]
        )
        let activity = MotionActivityRecord(
            span: span,
            motion: .automotive,
            confidence: .medium
        )
        let readings = [
            SensorReading(timestamp: base, stepCount: 100),
            SensorReading(timestamp: span.end, stepCount: 1_000),
        ]

        let result = AppleDeviceGroundTruthEngine.enforcingMotionFamily(
            [walking],
            activities: [activity],
            readings: readings
        )

        XCTAssertEqual(result.first?.mode, .walking)
    }

    func testEnforcingMotionFamilyPreservesOverlappingActivityDurationSum() {
        let base = makeDate(2026, 8, 4, 9, 26)
        let span = TimeSpan(start: base, end: base.addingTimeInterval(10 * 60))
        let cycling = TravelSegment(
            mode: .cycling,
            span: span,
            distanceMeters: 2_000,
            confidence: .medium,
            evidence: ["자전거 속도대"]
        )
        let activities = [
            MotionActivityRecord(
                span: TimeSpan(
                    start: base,
                    end: base.addingTimeInterval(3 * 60)
                ),
                motion: .automotive,
                confidence: .high
            ),
            MotionActivityRecord(
                span: TimeSpan(
                    start: base.addingTimeInterval(2 * 60),
                    end: base.addingTimeInterval(5 * 60)
                ),
                motion: .automotive,
                confidence: .high
            ),
        ]

        let result = AppleDeviceGroundTruthEngine.enforcingMotionFamily(
            [cycling],
            activities: activities,
            readings: [
                SensorReading(timestamp: span.start, stepCount: 10),
                SensorReading(timestamp: span.end, stepCount: 12),
            ]
        )

        XCTAssertEqual(result.first?.mode, .car)
    }

    func testEnforcingMotionFamilyBoundsDisjointEvidenceInspection() {
        let base = makeDate(2026, 8, 1, 0, 0)
        let count = 1_000
        let segments = (0..<count).map { index in
            let start = base.addingTimeInterval(TimeInterval(index * 5 * 60))
            return TravelSegment(
                mode: .cycling,
                span: TimeSpan(
                    start: start,
                    end: start.addingTimeInterval(2 * 60)
                ),
                distanceMeters: 500,
                confidence: .medium,
                evidence: ["자전거 속도대"]
            )
        }
        let activities = segments.map { segment in
            MotionActivityRecord(
                span: segment.span,
                motion: .automotive,
                confidence: .high
            )
        }
        let readings = (0..<count).map { index in
            SensorReading(
                timestamp: base.addingTimeInterval(
                    30 * 24 * hour + TimeInterval(index * 60)
                ),
                stepCount: index
            )
        }
        var inspectionCount = 0

        let result = AppleDeviceGroundTruthEngine.enforcingMotionFamily(
            segments,
            activities: activities,
            readings: readings,
            candidateInspectionCount: &inspectionCount
        )

        XCTAssertTrue(result.allSatisfy { $0.mode == .car })
        XCTAssertLessThan(inspectionCount, count * count / 10)
    }

    func testCoalescingTravelMergesSameModeFragmentsAcrossSamplingGaps() {
        let base = makeDate(2026, 8, 4, 11, 40)
        let first = TravelSegment(
            mode: .walking,
            span: TimeSpan(start: base, end: base.addingTimeInterval(120)),
            distanceMeters: 100,
            confidence: .medium,
            evidence: ["iPhone Core Motion 기록"]
        )
        let second = TravelSegment(
            mode: .walking,
            span: TimeSpan(
                start: base.addingTimeInterval(360),
                end: base.addingTimeInterval(480)
            ),
            distanceMeters: 150,
            confidence: .high,
            evidence: ["iPhone 걸음·거리 기록"]
        )
        let car = TravelSegment(
            mode: .car,
            span: TimeSpan(
                start: base.addingTimeInterval(600),
                end: base.addingTimeInterval(900)
            ),
            distanceMeters: 2_000,
            confidence: .high,
            evidence: ["GPS"]
        )

        let merged = AppleDeviceGroundTruthEngine.coalescingTravel(
            [first, second, car],
            stays: [],
            maximumGap: 6 * 60
        )

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].id, first.id)
        XCTAssertEqual(
            merged[0].span,
            TimeSpan(start: base, end: base.addingTimeInterval(480))
        )
        XCTAssertEqual(merged[0].distanceMeters, 250)
        XCTAssertEqual(merged[0].confidence, .high)
        XCTAssertEqual(merged[1].mode, .car)
    }

    func testCoalescingTravelTreatsExactThreeMinuteOverlapAsInterruption() {
        let base = makeDate(2026, 8, 4, 11, 40)
        let segments = [
            TravelSegment(
                mode: .walking,
                span: TimeSpan(
                    start: base,
                    end: base.addingTimeInterval(2 * 60)
                ),
                distanceMeters: 100,
                confidence: .medium,
                evidence: ["GPS"]
            ),
            TravelSegment(
                mode: .walking,
                span: TimeSpan(
                    start: base.addingTimeInterval(6 * 60),
                    end: base.addingTimeInterval(8 * 60)
                ),
                distanceMeters: 100,
                confidence: .medium,
                evidence: ["GPS"]
            ),
        ]
        let stays = [
            PlaceStay(
                placeKey: "short-decoy",
                displayName: "짧은 체류",
                span: TimeSpan(
                    start: base.addingTimeInterval(2 * 60),
                    end: base.addingTimeInterval(4 * 60)
                ),
                confidence: .medium
            ),
            PlaceStay(
                placeKey: "exact-boundary",
                displayName: "경계 체류",
                span: TimeSpan(
                    start: base.addingTimeInterval(2.5 * 60),
                    end: base.addingTimeInterval(5.5 * 60)
                ),
                confidence: .high
            ),
        ].reversed()

        let merged = AppleDeviceGroundTruthEngine.coalescingTravel(
            segments,
            stays: Array(stays),
            maximumGap: 6 * 60
        )

        XCTAssertEqual(merged, segments)
    }

    func testRouteReadingsAndDayReadingsUseTheSameUnprunedDatabase()
        async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("taption-route-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try SensorReadingArchive(
            fileURL: directory.appendingPathComponent("readings.jsonl")
        )
        let now = makeDate(2026, 8, 24, 12)
        let historical = SensorReading(
            timestamp: now.addingTimeInterval(-3 * 86_400),
            point: GeoPoint(
                latitude: 37.524,
                longitude: 126.673,
                altitude: 20,
                horizontalAccuracy: 8,
                verticalAccuracy: 10
            ),
            locationFixQuality: .precise,
            gpsAvailable: true
        )
        let sessionID = UUID()
        let tracked = SensorReading(
            timestamp: historical.timestamp.addingTimeInterval(30),
            point: GeoPoint(
                latitude: 37.525,
                longitude: 126.674,
                altitude: 20,
                horizontalAccuracy: 7,
                verticalAccuracy: 10
            ),
            locationFixQuality: .precise,
            gpsAvailable: true,
            trackingSessionID: sessionID,
            trackingSessionEnded: true
        )
        try await archive.append(historical, now: now)
        try await archive.append(tracked, now: now)
        try await archive.compact(now: now)

        let span = TimeSpan(
            start: historical.timestamp.addingTimeInterval(-60),
            end: historical.timestamp.addingTimeInterval(60)
        )
        let indexed = try await archive.readings(in: span)
        let recovered = try await archive.routeReadings(in: span)
        XCTAssertEqual(indexed.map(\.id), [historical.id, tracked.id])
        XCTAssertEqual(recovered.map(\.id), [historical.id, tracked.id])
    }

    func testSensorLiveActivityWaveformScanUsesOneSecondCycle() {
        XCTAssertEqual(SensorCollectionActivityPolicy.waveformScanDuration, 1)
        let origin = Date(timeIntervalSinceReferenceDate: 24_000)
        XCTAssertEqual(
            SensorCollectionWaveformMath.cycleProgress(
                at: origin.addingTimeInterval(0.25),
                origin: origin,
                duration: SensorCollectionActivityPolicy.waveformScanDuration
            ),
            0.25,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            SensorCollectionWaveformMath.cycleProgress(
                at: origin.addingTimeInterval(1),
                origin: origin,
                duration: SensorCollectionActivityPolicy.waveformScanDuration
            ),
            0,
            accuracy: 0.000_001
        )
    }

    func testSensorCollectionWaveformCycleProgressWrapsAtHalfInterval() {
        let origin = Date(timeIntervalSinceReferenceDate: 22_000)
        XCTAssertEqual(
            SensorCollectionWaveformMath.cycleProgress(
                at: origin,
                origin: origin,
                duration: 0.5
            ),
            0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            SensorCollectionWaveformMath.cycleProgress(
                at: origin.addingTimeInterval(0.25),
                origin: origin,
                duration: 0.5
            ),
            0.5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            SensorCollectionWaveformMath.cycleProgress(
                at: origin.addingTimeInterval(0.5),
                origin: origin,
                duration: 0.5
            ),
            0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            SensorCollectionWaveformMath.cycleProgress(
                at: origin.addingTimeInterval(-0.1),
                origin: origin,
                duration: 0.5
            ),
            0,
            accuracy: 0.000_001
        )
    }

    func testAppleDeviceMotionHistoryProjectsWithoutMutatingSource() {
        let base = makeDate(2026, 7, 30, 9, 0)
        let readings = [
            SensorReading(
                timestamp: base.addingTimeInterval(10 * 60),
                motion: .unknown,
                motionConfidence: .low
            ),
            SensorReading(
                timestamp: base.addingTimeInterval(70 * 60),
                motion: .walking,
                motionConfidence: .low
            ),
        ]
        let activities = [
            MotionActivityRecord(
                span: TimeSpan(
                    start: base,
                    end: base.addingTimeInterval(30 * 60)
                ),
                motion: .running,
                confidence: .high
            ),
        ]
        let sourceReadings = readings

        let result = AppleDeviceGroundTruthEngine.applyingMotionHistory(
            to: readings,
            activities: activities
        )

        XCTAssertEqual(result[0].motion, .running)
        XCTAssertEqual(result[0].motionConfidence, .high)
        XCTAssertEqual(result[1].motion, .walking)
        XCTAssertEqual(readings, sourceReadings)
    }

    func testAppleDeviceMotionHistoryUsesLatestInclusiveActivity() {
        let base = makeDate(2026, 7, 30, 9, 0)
        let readings = [30, 0, 21, 10, 20, 31].map { minute in
            SensorReading(
                timestamp: base.addingTimeInterval(TimeInterval(minute * 60)),
                motion: .automotive,
                motionConfidence: .low
            )
        }
        let activities = [
            MotionActivityRecord(
                span: TimeSpan(
                    start: base,
                    end: base.addingTimeInterval(30 * 60)
                ),
                motion: .walking,
                confidence: .medium
            ),
            MotionActivityRecord(
                span: TimeSpan(
                    start: base.addingTimeInterval(10 * 60),
                    end: base.addingTimeInterval(20 * 60)
                ),
                motion: .running,
                confidence: .high
            ),
            MotionActivityRecord(
                span: TimeSpan(
                    start: base.addingTimeInterval(15 * 60),
                    end: base.addingTimeInterval(25 * 60)
                ),
                motion: .unknown,
                confidence: .high
            ),
            MotionActivityRecord(
                span: TimeSpan(
                    start: base.addingTimeInterval(10 * 60),
                    end: base.addingTimeInterval(20 * 60)
                ),
                motion: .cycling,
                confidence: .medium
            ),
        ]
        let sourceReadings = readings

        let result = AppleDeviceGroundTruthEngine.applyingMotionHistory(
            to: readings,
            activities: activities
        )

        XCTAssertEqual(
            result.map(\.motion),
            [.walking, .cycling, .cycling, .walking, .walking, .automotive]
        )
        XCTAssertEqual(
            result.map(\.timestamp),
            [0, 10, 20, 21, 30, 31].map {
                base.addingTimeInterval(TimeInterval($0 * 60))
            }
        )
        XCTAssertEqual(result[1].motionConfidence, .medium)
        XCTAssertEqual(readings, sourceReadings)
    }

    func testAppleDeviceMotionHistoryBoundsDisjointInspection() {
        let base = makeDate(2026, 7, 1, 0, 0)
        let count = 1_000
        let readings = (0..<count).map { index in
            SensorReading(
                timestamp: base.addingTimeInterval(TimeInterval(index * 60)),
                motion: .stationary,
                motionConfidence: .low
            )
        }
        let activities = (0..<count).map { index in
            let start = base.addingTimeInterval(
                30 * 24 * hour + TimeInterval(index * 60)
            )
            return MotionActivityRecord(
                span: TimeSpan(
                    start: start,
                    end: start.addingTimeInterval(30)
                ),
                motion: .walking,
                confidence: .high
            )
        }
        var inspectionCount = 0

        let result = AppleDeviceGroundTruthEngine.applyingMotionHistory(
            to: readings,
            activities: activities,
            candidateInspectionCount: &inspectionCount
        )

        XCTAssertEqual(result, readings)
        XCTAssertLessThan(inspectionCount, count * count / 10)
    }

    func testAppleDeviceMotionFillsMovementMissingFromGPS() {
        let base = makeDate(2026, 7, 30, 9, 0)
        let walking = MotionActivityRecord(
            span: TimeSpan(
                start: base,
                end: base.addingTimeInterval(20 * 60)
            ),
            motion: .walking,
            confidence: .high
        )
        let running = MotionActivityRecord(
            span: TimeSpan(
                start: base.addingTimeInterval(30 * 60),
                end: base.addingTimeInterval(40 * 60)
            ),
            motion: .running,
            confidence: .medium
        )
        let pedometer = PedometerSummary(
            span: TimeSpan(
                start: base,
                end: base.addingTimeInterval(hour)
            ),
            stepCount: 3_000,
            distanceMeters: 3_000,
            floorsAscended: 1,
            floorsDescended: 0,
            averageActivePaceSecondsPerMeter: nil
        )

        let result = AppleDeviceGroundTruthEngine.mergingTravel(
            gpsSegments: [],
            motionActivities: [walking, running],
            pedometer: pedometer
        )

        XCTAssertEqual(result.map(\.mode), [.walking, .running])
        XCTAssertEqual(
            result.reduce(0) { $0 + $1.distanceMeters },
            3_000,
            accuracy: 0.001
        )
        XCTAssertTrue(
            result.allSatisfy {
                $0.evidence.contains("iPhone Core Motion 기록")
            }
        )
    }

    func testAppleDeviceGPSMovementWinsOverMotionFallback() {
        let base = makeDate(2026, 7, 30, 9, 0)
        let gps = TravelSegment(
            mode: .subway,
            span: TimeSpan(
                start: base,
                end: base.addingTimeInterval(30 * 60)
            ),
            distanceMeters: 8_000,
            confidence: .high,
            evidence: ["GPS"]
        )
        let automotive = MotionActivityRecord(
            span: TimeSpan(
                start: base.addingTimeInterval(10 * 60),
                end: base.addingTimeInterval(25 * 60)
            ),
            motion: .automotive,
            confidence: .high
        )

        let result = AppleDeviceGroundTruthEngine.mergingTravel(
            gpsSegments: [gps],
            motionActivities: [automotive],
            pedometer: nil
        )

        XCTAssertEqual(result, [gps])
    }

    func testMergingTravelKeepsTouchingSourcesSeparateAtStrictBoundary() {
        let base = makeDate(2026, 8, 1, 9, 0)
        let gps = TravelSegment(
            mode: .car,
            span: TimeSpan(
                start: base,
                end: base.addingTimeInterval(10 * 60)
            ),
            distanceMeters: 5_000,
            confidence: .high,
            evidence: ["GPS"]
        )
        let watchWorkout = AppleMovementEvidence(
            span: TimeSpan(
                start: base.addingTimeInterval(10 * 60),
                end: base.addingTimeInterval(20 * 60)
            ),
            source: .appleWatch,
            kind: .workout,
            workoutMode: .walking,
            distanceMeters: 800,
            sourceName: "Apple Watch"
        )
        let motion = MotionActivityRecord(
            span: TimeSpan(
                start: base.addingTimeInterval(20 * 60),
                end: base.addingTimeInterval(30 * 60)
            ),
            motion: .walking,
            confidence: .high
        )

        let result = AppleDeviceGroundTruthEngine.mergingTravel(
            gpsSegments: [gps],
            motionActivities: [motion],
            pedometer: nil,
            healthEvidence: [watchWorkout]
        )

        XCTAssertEqual(result.map(\.mode), [.car, .walking, .walking])
        XCTAssertEqual(
            result.map(\.span),
            [gps.span, watchWorkout.span, motion.span]
        )
    }

    func testMergingTravelBoundsDisjointSegmentInspection() {
        let base = makeDate(2026, 8, 1, 0, 0)
        let count = 1_000
        let gpsSegments = (0..<count).map { index in
            let start = base.addingTimeInterval(TimeInterval(index * 5 * 60))
            return TravelSegment(
                mode: .car,
                span: TimeSpan(
                    start: start,
                    end: start.addingTimeInterval(2 * 60)
                ),
                distanceMeters: 1_000,
                confidence: .high,
                evidence: ["GPS"]
            )
        }
        let motionActivities = (0..<count).map { index in
            let start = base.addingTimeInterval(
                30 * 24 * hour + TimeInterval(index * 5 * 60)
            )
            return MotionActivityRecord(
                span: TimeSpan(
                    start: start,
                    end: start.addingTimeInterval(2 * 60)
                ),
                motion: .walking,
                confidence: .high
            )
        }
        var inspectionCount = 0

        let result = AppleDeviceGroundTruthEngine.mergingTravel(
            gpsSegments: gpsSegments,
            motionActivities: motionActivities,
            pedometer: nil,
            candidateInspectionCount: &inspectionCount
        )

        XCTAssertEqual(result.count, count * 2)
        XCTAssertLessThan(inspectionCount, count * count / 10)
    }

    func testWalkingLocationEngineAddsConfirmedGPSLocations() {
        let base = makeDate(2026, 7, 30, 18)
        let sessionID = UUID()
        let readings = [
            SensorReading(
                timestamp: base,
                point: GeoPoint(
                    latitude: 37.5,
                    longitude: 127,
                    altitude: 30,
                    horizontalAccuracy: 8,
                    verticalAccuracy: 5
                ),
                motion: .walking,
                trackingSessionID: sessionID,
                trackingKind: .walking,
                sourceDevice: .iPhone
            ),
            SensorReading(
                timestamp: base.addingTimeInterval(45),
                point: GeoPoint(
                    latitude: 37.5002,
                    longitude: 127.0002,
                    altitude: 30,
                    horizontalAccuracy: 8,
                    verticalAccuracy: 5
                ),
                motion: .walking,
                trackingSessionID: sessionID,
                trackingKind: .walking,
                sourceDevice: .iPhone
            ),
            SensorReading(
                timestamp: base.addingTimeInterval(90),
                point: GeoPoint(
                    latitude: 37.5004,
                    longitude: 127.0004,
                    altitude: 30,
                    horizontalAccuracy: 8,
                    verticalAccuracy: 5
                ),
                motion: .walking,
                trackingSessionID: sessionID,
                trackingKind: .walking,
                sourceDevice: .iPhone
            )
        ]

        let locations = WalkingLocationEngine().build(readings: readings)

        XCTAssertEqual(locations.count, 1)
        XCTAssertEqual(locations.first?.displayName, "확인된 위치")
        XCTAssertTrue(locations.first?.isConfirmed == true)
        XCTAssertTrue(locations.first?.isWalkingLocation == true)
        XCTAssertEqual(locations.first?.span.duration ?? 0, 90, accuracy: 0.001)
    }

    func testWalkingLocationEngineIgnoresInaccurateAndNonWalkingGPS() {
        let base = makeDate(2026, 7, 30, 18)
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 30,
            horizontalAccuracy: 80,
            verticalAccuracy: 5
        )
        let readings = [
            SensorReading(
                timestamp: base,
                point: point,
                motion: .walking,
                trackingKind: .walking
            ),
            SensorReading(
                timestamp: base.addingTimeInterval(60),
                point: point,
                motion: .stationary,
                trackingKind: .automatic
            )
        ]

        XCTAssertTrue(WalkingLocationEngine().build(readings: readings).isEmpty)
    }

    func testWalkingLocationEngineIgnoresApproximateLocationEvenWithGoodAccuracy() {
        let base = makeDate(2026, 7, 30, 18)
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 30,
            horizontalAccuracy: 10,
            verticalAccuracy: 5
        )
        let readings = [
            SensorReading(
                timestamp: base,
                point: point,
                locationFixQuality: .approximate,
                motion: .walking,
                gpsAvailable: false,
                trackingKind: .walking
            ),
            SensorReading(
                timestamp: base.addingTimeInterval(60),
                point: point,
                locationFixQuality: .approximate,
                motion: .walking,
                gpsAvailable: false,
                trackingKind: .walking
            )
        ]

        XCTAssertTrue(WalkingLocationEngine().build(readings: readings).isEmpty)
    }

    func testCatMotionRespectsReduceMotion() {
        XCTAssertEqual(
            CatMotionPolicy.resolve(
                style: .white,
                hasCurrentActivity: true,
                reduceMotion: true
            ).animationDuration,
            0
        )
    }

    func testWidgetAutomotiveActualUsesMovementLaneAndAutomobileTitle() {
        let now = makeDate(2026, 8, 1, 18, 0)
        var snapshot = TaptionDataSnapshot.empty
        snapshot.actuals = [
            ActualRecord(
                planID: nil,
                title: "차량 탑승",
                categoryID: "movement",
                startedAt: now.addingTimeInterval(-10 * 60),
                endedAt: now,
                source: .motion,
                behavior: MotionKind.automotive.rawValue
            ),
        ]

        let payload = TaptionWidgetPayloadFactory.make(from: snapshot, now: now)

        XCTAssertEqual(
            payload.items.filter { $0.resolvedLane == .movement }.map(\.title),
            ["자동차"]
        )
        XCTAssertFalse(payload.items.contains { $0.resolvedLane == .activity })
    }

    func testWidgetCatWalksAcrossAndTurnsAround() {
        let reference = Date(timeIntervalSinceReferenceDate: 0)
        let step = TaptionWidgetCatWalkEngine.defaultStepDuration
        let start = TaptionWidgetCatWalkEngine.pose(at: reference)
        let farEdge = TaptionWidgetCatWalkEngine.pose(
            at: reference.addingTimeInterval((step * 9) + 0.01)
        )
        let turnedAtFarEdge = TaptionWidgetCatWalkEngine.pose(
            at: reference.addingTimeInterval((step * 10) + 0.01)
        )
        let returning = TaptionWidgetCatWalkEngine.pose(
            at: reference.addingTimeInterval((step * 12) + 0.01)
        )
        let nearEdge = TaptionWidgetCatWalkEngine.pose(
            at: reference.addingTimeInterval((step * 19) + 0.01)
        )
        let sittingAtNearEdge = TaptionWidgetCatWalkEngine.pose(
            at: reference.addingTimeInterval((step * 20) + 0.01),
            preferredAction: .sitting
        )
        let movingAfterActionHold = TaptionWidgetCatWalkEngine.pose(
            at: reference.addingTimeInterval((step * 24) + 0.01),
            preferredAction: .sitting
        )
        let farActionHold = TaptionWidgetCatWalkEngine.pose(
            at: reference.addingTimeInterval((step * 30) + 0.01),
            preferredAction: .sleeping
        )
        let looped = TaptionWidgetCatWalkEngine.pose(
            at: reference.addingTimeInterval(
                TaptionWidgetCatWalkEngine.sequenceDuration + 0.01
            )
        )

        XCTAssertEqual(TaptionWidgetCatWalkEngine.roundTripDuration, 10)
        XCTAssertEqual(TaptionWidgetCatWalkEngine.sequenceDuration, 20)
        XCTAssertEqual(start.progress, 0, accuracy: 0.001)
        XCTAssertFalse(start.facesLeft)
        XCTAssertTrue(start.isAtEndpoint)
        XCTAssertEqual(start.action, .walking)
        XCTAssertEqual(farEdge.progress, 1, accuracy: 0.001)
        XCTAssertFalse(farEdge.facesLeft)
        XCTAssertTrue(farEdge.isAtEndpoint)
        XCTAssertEqual(farEdge.action, .walking)
        XCTAssertEqual(turnedAtFarEdge.progress, 1, accuracy: 0.001)
        XCTAssertTrue(turnedAtFarEdge.facesLeft)
        XCTAssertTrue(turnedAtFarEdge.isAtEndpoint)
        XCTAssertEqual(turnedAtFarEdge.action, .startled)
        XCTAssertLessThan(returning.progress, 1)
        XCTAssertTrue(returning.facesLeft)
        XCTAssertFalse(returning.isAtEndpoint)
        XCTAssertEqual(returning.action, .running)
        XCTAssertEqual(nearEdge.progress, 0, accuracy: 0.001)
        XCTAssertTrue(nearEdge.facesLeft)
        XCTAssertTrue(nearEdge.isAtEndpoint)
        XCTAssertEqual(nearEdge.action, .running)
        XCTAssertEqual(sittingAtNearEdge.progress, 0, accuracy: 0.001)
        XCTAssertFalse(sittingAtNearEdge.facesLeft)
        XCTAssertTrue(sittingAtNearEdge.isAtEndpoint)
        XCTAssertEqual(sittingAtNearEdge.action, .sitting)
        XCTAssertGreaterThan(movingAfterActionHold.progress, 0)
        XCTAssertEqual(movingAfterActionHold.action, .walking)
        XCTAssertEqual(farActionHold.progress, 1, accuracy: 0.001)
        XCTAssertTrue(farActionHold.facesLeft)
        XCTAssertEqual(farActionHold.action, .sleeping)
        XCTAssertEqual(looped.progress, 0, accuracy: 0.001)
        XCTAssertFalse(looped.facesLeft)
        XCTAssertTrue(looped.isAtEndpoint)
        XCTAssertEqual(looped.action, .walking)
    }

    func testReduceMotionFreezesEveryCatActionIncludingIdleDetail() {
        let reference = Date(timeIntervalSinceReferenceDate: 0)
        let samples = (0..<80).map {
            reference.addingTimeInterval(
                Double($0) * TaptionCatAnimationEngine.stepDuration
            )
        }

        for action in TaptionCatAnimationAction.allCases {
            for date in samples {
                let pose = TaptionCatAnimationEngine.pose(
                    at: date,
                    preferredAction: action,
                    reducesMotion: true
                )
                XCTAssertEqual(pose.action, .sitting)
                XCTAssertEqual(pose.phase, 0)
                XCTAssertEqual(pose.progress, 0.5, accuracy: 0.001)
                XCTAssertFalse(pose.facesLeft)
                XCTAssertEqual(pose.tailSwing, 0, accuracy: 0.0001)
                XCTAssertEqual(pose.headTiltDegrees, 0, accuracy: 0.0001)
                XCTAssertEqual(pose.legSwing, 0, accuracy: 0.0001)
                XCTAssertEqual(pose.idle, .still)
                XCTAssertEqual(pose.cycleEase, 0, accuracy: 0.0001)
            }
        }

        for action in TaptionWidgetCatAction.allCases {
            for date in samples {
                let pose = TaptionWidgetCatPreviewEngine.pose(
                    at: date,
                    action: action,
                    reducesMotion: true
                )
                XCTAssertEqual(pose.legPhase, 0)
                XCTAssertEqual(pose.progress, 0.5, accuracy: 0.001)
                XCTAssertFalse(pose.facesLeft)
                XCTAssertEqual(pose.tailSwing, 0, accuracy: 0.0001)
                XCTAssertEqual(pose.headTiltDegrees, 0, accuracy: 0.0001)
                XCTAssertEqual(pose.legSwing, 0, accuracy: 0.0001)
                XCTAssertEqual(pose.idle, .still)
            }
        }

        XCTAssertEqual(
            TaptionCatIdleBeat.beat(at: reference, reducesMotion: true),
            .still
        )
        XCTAssertEqual(TaptionCatIdleBeat.still.eyeOpenness, 1, accuracy: 0.0001)
        XCTAssertEqual(TaptionCatIdleBeat.still.earFlick, 0, accuracy: 0.0001)
        XCTAssertEqual(TaptionCatIdleBeat.still.tailTip, 0, accuracy: 0.0001)
    }

    func testJSONCSVAndRepositoryRoundTrip() async throws {
        let base = makeDate(2026, 7, 30)
        let plan = PlanRecord(
            title: "저장",
            span: TimeSpan(start: base, end: base.addingTimeInterval(hour)),
            categoryID: "project"
        )
        var snapshot = TaptionDataSnapshot.empty
        snapshot.updatedAt = base
        snapshot.categories = CategoryCatalog.builtIn
        snapshot.plans = [plan]

        let encoded = try SnapshotExporter.jsonData(snapshot)
        let decoded = try SnapshotExporter.decodeJSON(encoded)
        XCTAssertEqual(decoded.plans.first?.id, plan.id)
        XCTAssertEqual(decoded.plans.first?.title, plan.title)
        XCTAssertEqual(decoded.plans.first?.span, plan.span)
        XCTAssertTrue(
            String(decoding: SnapshotExporter.plansCSV(snapshot), as: UTF8.self)
                .contains("\"저장\"")
        )

        let repository = InMemoryPlanRepository()
        try await repository.save(snapshot)
        let restored = try await repository.load()
        XCTAssertEqual(restored.plans, [plan])
    }

    func testSnapshotCompressionRoundTripAndLegacyJSON() throws {
        let json = Data(repeating: 0x41, count: 32 * 1024)
        let stored = TaptionSnapshotCompression.encode(json)

        XCTAssertLessThan(stored.count, json.count)
        XCTAssertEqual(try TaptionSnapshotCompression.decode(stored), json)

        let legacy = Data("{\"schemaVersion\":1}".utf8)
        XCTAssertEqual(try TaptionSnapshotCompression.decode(legacy), legacy)
    }

    /// "대기"가 이동 종류였을 때는 앞뒤 이동과 겹친다고 보고 화면에서
    /// 지워졌다. 정지 문맥은 모두 활동 줄에 남아야 한다.
    func testWaitingRecordSurvivesMovementDisplayFiltering() {
        let start = makeDate(2026, 8, 4, 10, 0)
        let end = start.addingTimeInterval(10 * 60)
        let travel = [
            TravelSegment(
                mode: .walking,
                span: TimeSpan(
                    start: start.addingTimeInterval(-10 * 60),
                    end: start.addingTimeInterval(3 * 60)
                ),
                distanceMeters: 500,
                confidence: .medium,
                evidence: ["걸음 수"]
            ),
            TravelSegment(
                mode: .subway,
                span: TimeSpan(start: end, end: end.addingTimeInterval(20 * 60)),
                distanceMeters: 6_000,
                confidence: .medium,
                evidence: ["역 근처"]
            ),
        ]
        let records = StationaryContextActualEngine.records(
            stays: [makeContextStay(start: start, end: end)],
            placeKinds: [:],
            travel: travel,
            inside: TimeSpan(start: start, end: end.addingTimeInterval(hour)),
            calendar: utcCalendar,
            now: end.addingTimeInterval(hour)
        )

        XCTAssertEqual(records.map(\.title), ["대기"])
        XCTAssertEqual(records.first?.categoryID, "activity")
        XCTAssertEqual(
            MovementDisplayEngine.visibleActuals(
                records,
                travel: travel,
                asOf: end.addingTimeInterval(hour)
            ).map(\.title),
            ["대기"]
        )
    }

    /// 하단 메모 카드는 보고 있는 기간의 메모를 시각 순서대로 편다. 표식과
    /// 달리 합치지 않아야 하나씩 눌러 열 수 있다.
    func testMemoDetailCardListsEveryMemoInTheVisibleSpanInOrder() {
        let day = TimeSpan(
            start: makeDate(2026, 8, 4),
            end: makeDate(2026, 8, 5)
        )
        let morning = memoFixture(at: makeDate(2026, 8, 4, 9, 0))
        // 표식 하나로 합쳐질 만큼 붙어 있어도 카드에서는 따로 선다.
        let alongside = memoFixture(at: makeDate(2026, 8, 4, 9, 1))
        let evening = memoFixture(at: makeDate(2026, 8, 4, 21, 30))
        let nextDay = memoFixture(at: makeDate(2026, 8, 5, 8, 0))

        let listed = MemoTimelineEngine.detailList(
            in: day,
            from: [evening, nextDay, alongside, morning]
        )
        XCTAssertEqual(
            listed.map(\.id),
            [morning.id, alongside.id, evening.id]
        )
        XCTAssertEqual(
            MemoTimelineEngine.markers(
                from: listed,
                in: day,
                visibleDuration: day.duration
            )
            .count,
            2
        )
    }

    /// 메모가 없는 기간에서는 목록이 빈다. 하단의 메모 알약과 카드는 다른
    /// 줄과 같은 규칙으로 이 값을 보고 함께 나타나고 함께 빠진다.
    func testMemoDetailCardIsEmptyWhenTheVisibleSpanHasNoMemo() {
        let memo = memoFixture(at: makeDate(2026, 8, 4, 9, 0))
        let emptyDay = TimeSpan(
            start: makeDate(2026, 8, 5),
            end: makeDate(2026, 8, 6)
        )
        XCTAssertTrue(
            MemoTimelineEngine.detailList(in: emptyDay, from: [memo]).isEmpty
        )
        XCTAssertTrue(
            MemoTimelineEngine.detailList(in: emptyDay, from: []).isEmpty
        )
        // 같은 메모라도 그 메모가 놓인 기간에서는 카드에 오른다.
        XCTAssertEqual(
            MemoTimelineEngine.detailList(
                in: TimeSpan(
                    start: makeDate(2026, 8, 4),
                    end: makeDate(2026, 8, 5)
                ),
                from: [memo]
            )
            .map(\.id),
            [memo.id]
        )
    }

    func testStandaloneMemoSurvivesRepositoryRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = TaptionStoreRepository(
            store: try TaptionStoreV2(url: directory.appendingPathComponent(TaptionStoreV2.fileName))
        )
        let occurredAt = makeDate(2026, 8, 4, 9, 30)
        let memo = ActionMemo(
            categoryID: "activity",
            occurredAt: occurredAt,
            kind: .idea,
            text: "무릎 상태 확인",
            createdAt: occurredAt,
            updatedAt: occurredAt
        )
        var snapshot = TaptionDataSnapshot.empty
        snapshot.memos = [memo]

        try await repository.save(snapshot)
        let loaded = try await repository.load()

        XCTAssertTrue(loaded.plans.isEmpty)
        XCTAssertEqual(loaded.memos, [memo])
    }

    /// 같은 이동 수단이 이어지면 하나로 붙이고, 너무 짧은 구간은 이웃에
    /// 합치되 이웃이 없으면 최소 길이로 넓혀 남긴다.
    func testTravelRingJoinsSameModeAndCondensesShortSegments() throws {
        let dayStart = makeDate(2026, 8, 4)
        let day = TimeSpan(
            start: dayStart,
            end: dayStart.addingTimeInterval(24 * hour)
        )
        func travel(
            _ mode: TravelMode,
            _ from: Double,
            _ to: Double
        ) -> TravelSegment {
            TravelSegment(
                mode: mode,
                span: TimeSpan(
                    start: dayStart.addingTimeInterval(from * hour),
                    end: dayStart.addingTimeInterval(to * hour)
                ),
                distanceMeters: 500,
                confidence: .high,
                evidence: ["GPS"]
            )
        }
        let ring = try XCTUnwrap(
            RecordClockDetailEngine.travelRing(
                segments: [
                    travel(.walking, 8, 8 + 20.0 / 60),
                    travel(.walking, 8 + 20.0 / 60, 8.5),
                    travel(.car, 9, 9 + 40.0 / 60),
                    travel(.subway, 9 + 40.0 / 60, 9 + 42.0 / 60),
                    travel(.running, 12, 12 + 2.0 / 60),
                ],
                in: day
            )
        )
        XCTAssertEqual(ring.kind, .travel)
        XCTAssertEqual(ring.arcs.map(\.token), ["walking", "car", "running"])
        XCTAssertEqual(
            ring.arcs[0].endFraction,
            8.5 / 24,
            accuracy: 1e-9
        )
        // 2분짜리 지하철은 앞선 자동차 구간에 합쳐진다.
        XCTAssertEqual(
            ring.arcs[1].endFraction,
            (9 * hour + 42 * 60) / (24 * hour),
            accuracy: 1e-9
        )
        assertRingHasNoSlivers(ring)

        XCTAssertNil(
            RecordClockDetailEngine.travelRing(segments: [], in: day)
        )
        XCTAssertNil(
            RecordClockDetailEngine.sleepRing(sessions: [], in: day)
        )
    }

}
