import XCTest
import UIKit
import CoreLocation
import StoreKit
import StoreKitTest
import TaptionPlanCore
@testable import TaptionPlan

extension FeatureEngineTests {
    func testHomeSummaryTapCoversIconAndLevelLabelButNotTheMapAround() {
        let pin = CGPoint(x: 100, y: 200)
        let icon = CGPoint(x: pin.x + MapHomeCatTapRouting.homeImageCenterOffset.x,
                           y: pin.y + MapHomeCatTapRouting.homeImageCenterOffset.y)
        // 집 아이콘 가운데와 둘레 안쪽은 열린다.
        XCTAssertTrue(MapHomeCatTapRouting.hitsHomeSummary(tapPoint: icon, pinPoint: pin, showsCatAtHome: false))
        XCTAssertTrue(MapHomeCatTapRouting.hitsHomeSummary(
            tapPoint: CGPoint(x: icon.x + 25, y: icon.y), pinPoint: pin, showsCatAtHome: true))
        // 레벨 라벨(아바타 아래)도 열린다. 아바타 크기가 화랑이 유무와 같아 라벨 자리도 같다.
        for showsCat in [false, true] {
            let label = MapHomeCatTapRouting.homeLevelLabelCenter(pinPoint: pin, showsCatAtHome: showsCat)
            XCTAssertGreaterThan(label.y, icon.y)
            XCTAssertTrue(MapHomeCatTapRouting.hitsHomeSummary(tapPoint: label, pinPoint: pin, showsCatAtHome: showsCat))
        }
        XCTAssertEqual(
            MapHomeCatTapRouting.homeLevelLabelCenter(pinPoint: pin, showsCatAtHome: true).y,
            MapHomeCatTapRouting.homeLevelLabelCenter(pinPoint: pin, showsCatAtHome: false).y,
            accuracy: 0.5
        )
        // 멀리 떨어진 지도 점은 열리지 않는다.
        XCTAssertFalse(MapHomeCatTapRouting.hitsHomeSummary(
            tapPoint: CGPoint(x: pin.x + 120, y: pin.y), pinPoint: pin, showsCatAtHome: false))
        XCTAssertFalse(MapHomeCatTapRouting.hitsHomeSummary(
            tapPoint: CGPoint(x: pin.x, y: pin.y - 80), pinPoint: pin, showsCatAtHome: false))
    }

    /// 집 핀 세로 배치: 아바타 중심이 좌표에 오고, 날씨는 아바타 위쪽에 걸치고,
    /// 레벨 라벨은 아바타 아래에 붙고, 연봉 카운터는 그 위에 온다.
    func testHomePinCentersAvatarOnCoordinateAndStacksBadgesAround() {
        let avatarRadius = MapHomePlacePinLayout.avatarSize / 2

        // 1) 아바타 중심은 좌표다. 마커 안에 보이지 않는 빈 자리가 없다.
        XCTAssertEqual(MapHomeCatTapRouting.homeImageCenterOffset, .zero)

        // 3) 레벨 라벨은 아바타 바로 아래 간격만큼 떨어진다.
        let labelCenterY = MapHomeCatTapRouting.homeLevelLabelCenter(
            pinPoint: .zero, showsCatAtHome: false
        ).y
        XCTAssertEqual(
            labelCenterY - MapHomePlacePinLayout.levelLabelHeight / 2,
            avatarRadius + MapHomePlacePinLayout.levelLabelGap,
            accuracy: 0.5
        )

        // 4) 연봉 카운터는 아바타 위에 온다(아바타를 덮지 않는다).
        XCTAssertLessThanOrEqual(
            MapHomePlacePinLayout.salaryOffsetFromPinCenter + 13,
            -avatarRadius
        )
    }

    /// 하루요약 시트가 지도를 덮으면 집은 가려지지 않은 영역의 가운데로 올라가고,
    /// 시트를 내리면 다시 지도 전체 가운데로 돌아온다.
    func testDaySummarySheetCentersHomeInTheRemainingMapArea() {
        let height: CGFloat = 844

        // 시트를 내린 상태: 보정 없음, 집은 지도 전체 가운데(422)에 있다.
        XCTAssertEqual(MapHomeDaySummaryLayout.visibleCenterY(viewportHeight: height, coverage: 0), 422)
        XCTAssertEqual(MapHomeDaySummaryLayout.centerShift(viewportHeight: height, coverage: 0), 0)

        // 접힌 시트(절반)가 올라오면 남은 영역(0~422)의 가운데인 211로 올라간다.
        XCTAssertEqual(MapHomeDaySummaryLayout.collapsedCoverage, 0.5)
        XCTAssertEqual(
            MapHomeDaySummaryLayout.visibleCenterY(viewportHeight: height, coverage: 0.5),
            211
        )
        XCTAssertEqual(MapHomeDaySummaryLayout.centerShift(viewportHeight: height, coverage: 0.5), 211)
        // 따라가기·재생이 가운데로 삼는 점도 같은 자리로 올라간다.
        XCTAssertEqual(
            MapHomeDaySummaryLayout.targetPoint(
                viewportSize: CGSize(width: 390, height: height),
                coverage: 0.5
            ),
            CGPoint(x: 195, y: 211)
        )
        XCTAssertEqual(
            MapHomeDaySummaryLayout.targetPoint(
                viewportSize: CGSize(width: 390, height: height),
                coverage: 0
            ),
            CGPoint(x: 195, y: 422)
        )

        // 위도 보정: 한 화면이 0.025도면 211pt는 그 1/4인 0.00625도다.
        let latitudeShift = MapHomeDaySummaryLayout.latitudeShift(
            shift: 211,
            viewportHeight: height,
            latitudeDelta: 0.025
        )
        XCTAssertEqual(latitudeShift, 0.00625, accuracy: 1e-9)

        // 보정한 중심으로 옮기면 집이 남은 영역 가운데(211)에 온다.
        let homeLatitude = 37.5
        let centerLatitude = homeLatitude - latitudeShift
        let homePointY = height / 2
            - CGFloat((homeLatitude - centerLatitude) / 0.025) * height
        XCTAssertEqual(homePointY, 211, accuracy: 0.001)

        // 화면 높이가 0이거나 비율이 범위를 벗어나도 값이 깨지지 않는다.
        XCTAssertEqual(MapHomeDaySummaryLayout.centerShift(viewportHeight: 0, coverage: 0.5), 0)
        XCTAssertEqual(MapHomeDaySummaryLayout.visibleCenterY(viewportHeight: height, coverage: -1), 422)
        XCTAssertEqual(
            MapHomeDaySummaryLayout.latitudeShift(shift: 0, viewportHeight: height, latitudeDelta: 0.025),
            0
        )
    }

    func testHomeIconTapRoutingSeparatesHouseFromHomeCat() {
        let homeLocation = CGPoint(x: 100, y: 200)
        let houseCenter = CGPoint(
            x: homeLocation.x + MapHomeCatTapRouting.homeImageCenterOffset.x,
            y: homeLocation.y + MapHomeCatTapRouting.homeImageCenterOffset.y
        )
        let catCenter = MapHomeCatTapRouting.markerPoint(
            locationPoint: homeLocation,
            isAtHome: true
        )

        XCTAssertTrue(
            MapHomeCatTapRouting.isHomeIconTap(
                tapPoint: houseCenter,
                locationPoint: homeLocation
            )
        )
        XCTAssertFalse(
            MapHomeCatTapRouting.isHomeIconTap(
                tapPoint: catCenter,
                locationPoint: homeLocation
            )
        )
        XCTAssertFalse(
            MapHomeCatTapRouting.shouldPresentCatDetails(
                tapPoint: houseCenter,
                locationPoint: homeLocation,
                isAtHome: true
            )
        )
        XCTAssertTrue(
            MapHomeCatTapRouting.shouldPresentCatDetails(
                tapPoint: catCenter,
                locationPoint: homeLocation,
                isAtHome: true
            )
        )
    }

    func testRegisteredPlaceIconCenterMatchesStoredCoordinate() {
        XCTAssertEqual(MapHomePlaceAnnotationLayout.vectorAnchor, .center)
        XCTAssertEqual(MapHomePlaceAnnotationLayout.appleCenterOffset, .zero)
    }

    func testMapHomeSidebarUsesDistinctMajorCategoryVisuals() {
        let categories = MapHomeSidebarMajorCategory.all

        XCTAssertEqual(categories.map(\.id), CanonicalCategoryPalette.orderedIDs)
        XCTAssertEqual(Set(categories.map(\.hex)).count, 12)
        XCTAssertEqual(Set(categories.map(\.systemImage)).count, 12)
        XCTAssertEqual(
            categories.map(\.title),
            ["활동", "업무", "수업", "취미", "수면", "이동", "식사", "운동", "건강관리", "샤워", "집안일", "미확인"]
        )
    }

    func testMapHomePastelPaletteKeepsCategoriesVisuallySeparated() {
        let hexes = CanonicalCategoryPalette.orderedIDs.map {
            MapHomePastelPalette.hex($0)
        }
        XCTAssertEqual(Set(hexes).count, hexes.count)

        let rgb = hexes.compactMap { hex -> (Double, Double, Double)? in
            guard hex.count == 7,
                  let value = UInt64(hex.dropFirst(), radix: 16) else {
                return nil
            }
            return (
                Double((value >> 16) & 0xFF) / 255,
                Double((value >> 8) & 0xFF) / 255,
                Double(value & 0xFF) / 255
            )
        }
        XCTAssertEqual(rgb.count, hexes.count)

        let minimumDistance = rgb.enumerated().flatMap { index, color in
            rgb.dropFirst(index + 1).map { other in
                sqrt(
                    pow(color.0 - other.0, 2)
                        + pow(color.1 - other.1, 2)
                        + pow(color.2 - other.2, 2)
                )
            }
        }.min() ?? 0
        XCTAssertGreaterThan(minimumDistance, 0.12)
    }

    func testMapHomeSidebarHandleUsesCanonicalMajorCategoryPresentation() {
        let categories = CanonicalCategoryPalette.orderedIDs.map {
            MapHomeSidebarMajorCategory.presentation(for: $0)
        }

        XCTAssertEqual(categories, MapHomeSidebarMajorCategory.all)
        XCTAssertEqual(
            MapHomeTimeSidebarActivity.majorCategory("unconfirmed").systemImage,
            "questionmark.circle.fill"
        )
        XCTAssertEqual(
            MapHomeTimeSidebarActivity.majorCategory("unconfirmed").accessibilityLabel,
            "미확인"
        )
    }

    func testUnconfirmedStaysSeparateFromActivityAndMovement() {
        let record = ActualRecord(
            planID: nil,
            title: "미확인",
            categoryID: "activity",
            startedAt: makeDate(2026, 8, 13, 9, 0),
            endedAt: makeDate(2026, 8, 13, 10, 0),
            source: .motion,
            behavior: "unconfirmed-movement"
        )

        XCTAssertEqual(
            RecordAnalysisCategoryNormalizer.categoryID(
                for: record.categoryID,
                title: record.title,
                behavior: record.behavior
            ),
            "unconfirmed"
        )
        XCTAssertEqual(RecordAnalysisCategoryPolicy.categoryID(for: record), "unconfirmed")
        XCTAssertEqual(RecordAnalysisCategoryPolicy.phase(for: "unconfirmed"), .unconfirmed)
        XCTAssertEqual(RecordAnalysisCategoryPolicy.detailTitle(for: record), "미확인")
    }

    func testMapHomeLocationHierarchyKeepsConfiguredAndUserDestinationsDistinct() {
        XCTAssertEqual(
            MapHomeLocationDestination.allCases.map(\.rawValue),
            ["home", "company", "school", "academy", "exercise", "hobby", "restaurant", "user"]
        )
        XCTAssertEqual(MapHomeLocationDestination.home.placeKind, .home)
        XCTAssertEqual(MapHomeLocationDestination.company.placeKind, .company)
        XCTAssertEqual(MapHomeLocationDestination.school.placeKind, .school)
        XCTAssertEqual(MapHomeLocationDestination.academy.placeKind, .academy)
        XCTAssertEqual(MapHomeLocationDestination.exercise.placeKind, .exercise)
        XCTAssertEqual(MapHomeLocationDestination.hobby.placeKind, .hobby)
        XCTAssertNil(MapHomeLocationDestination.user.placeKind)
    }

    func testRouteDecimationDropsPointsKeepsEndsAndStaysWithinTolerance() {
        let dense = makeWalkPolyline(pointCount: 900)
        let simplified = RoutePolylineDecimator.decimate(
            dense,
            toleranceMeters: 5,
            limit: 400
        )

        XCTAssertLessThan(simplified.count, dense.count)
        XCTAssertGreaterThanOrEqual(simplified.count, 2)
        XCTAssertEqual(simplified.first?.latitude, dense.first?.latitude)
        XCTAssertEqual(simplified.first?.longitude, dense.first?.longitude)
        XCTAssertEqual(simplified.last?.latitude, dense.last?.latitude)
        XCTAssertEqual(simplified.last?.longitude, dense.last?.longitude)

        let worst = dense.compactMap {
            RoutePolylineDecimator.distanceMeters(from: $0, to: simplified)
        }.max() ?? 0
        XCTAssertLessThanOrEqual(
            worst,
            5.001,
            "줄인 경로는 원래 모양에서 허용 오차보다 멀어지지 않는다"
        )
    }

    func testGoalChildMustStayInsideParent() {
        let base = makeDate(2026, 1, 1)
        let parent = PlanRecord(
            title: "부모",
            span: TimeSpan(start: base, end: base.addingTimeInterval(10 * hour)),
            categoryID: "project"
        )
        XCTAssertThrowsError(
            try GoalDecompositionEngine.makeChild(
                parent: parent,
                title: "범위 밖",
                span: TimeSpan(
                    start: base.addingTimeInterval(9 * hour),
                    end: base.addingTimeInterval(11 * hour)
                )
            )
        )
    }

    func testGanttViewportPinchZoomAndPanStayInsideTimeline() {
        let zoomed = GanttViewport.full.magnifying(
            by: 2,
            anchor: 0.25
        )
        XCTAssertEqual(zoomed.start, 0.125, accuracy: 0.0001)
        XCTAssertEqual(zoomed.length, 0.5, accuracy: 0.0001)
        XCTAssertEqual(zoomed.zoomScale, 2, accuracy: 0.0001)

        let panned = zoomed.panning(
            translation: -100,
            viewportWidth: 400
        )
        XCTAssertEqual(panned.start, 0.25, accuracy: 0.0001)
        XCTAssertEqual(panned.end, 0.75, accuracy: 0.0001)

        let clampedRight = panned.panning(
            translation: -2_000,
            viewportWidth: 400
        )
        XCTAssertEqual(clampedRight.end, 1, accuracy: 0.0001)

        let restored = clampedRight.magnifying(
            by: 0.01,
            anchor: 0.5
        )
        XCTAssertEqual(restored, .full)
    }

    func testGanttViewportFocusAndSemanticFitStayInsideTimeline() {
        let focused = GanttViewport.full.focusing(
            start: 0.45,
            length: 0.10,
            minimumLength: 1 / 1_440
        )
        XCTAssertLessThan(focused.start, 0.45)
        XCTAssertGreaterThan(focused.end, 0.55)

        let oneHour = GanttViewport.full.fitting(
            visibleDuration: 60 * 60,
            within: 24 * 60 * 60,
            anchor: 0.75
        )
        XCTAssertEqual(
            oneHour.length * 24 * 60 * 60,
            60 * 60,
            accuracy: 0.001
        )
        XCTAssertEqual(
            oneHour.start + oneHour.length * 0.75,
            0.75,
            accuracy: 0.001
        )
    }

    func testRecordTimelineColorsStayDistinctWithinEachRing() {
        let palettes = [
            RecordTimelinePalette.categoryHexes,
            RecordTimelinePalette.sleepStageHexes,
            RecordTimelinePalette.travelHexes,
            RecordTimelinePalette.dayPhaseHexes,
        ]
        for palette in palettes {
            XCTAssertEqual(Set(palette.values).count, palette.count)
        }
        XCTAssertNotEqual(
            RecordTimelinePalette.sleepStageHexes[SleepStage.core.rawValue],
            RecordTimelinePalette.sleepStageHexes[SleepStage.deep.rawValue]
        )
    }

    func testPlacePresentationShowsOneCopyOfDuplicateStay() throws {
        let base = makeDate(2026, 8, 9, 2, 38)
        let span = TimeSpan(
            start: base,
            end: base.addingTimeInterval(15 * hour + 28 * 60)
        )
        let inferred = PlaceStay(
            placeKey: "home",
            displayName: "집",
            floor: 19,
            span: span,
            confidence: .medium
        )
        let confirmed = PlaceStay(
            placeKey: "home",
            displayName: "집",
            floor: 19,
            span: span,
            confidence: .high,
            isConfirmed: true
        )

        let values = PlaceStayPresentationEngine.consolidated(
            [inferred, confirmed, inferred, confirmed]
        )
        let result = try XCTUnwrap(values.first)
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(result.id, confirmed.id)
        XCTAssertEqual(result.span, span)
        XCTAssertEqual(result.floor, 19)
        XCTAssertEqual(result.confidence, .high)
        XCTAssertTrue(result.isConfirmed)
    }

    func testPlacePresentationKeepsOnlyMostAccurateOverlappingLocation()
        throws
    {
        let base = makeDate(2026, 8, 12, 9)
        let span = TimeSpan(
            start: base,
            end: base.addingTimeInterval(hour)
        )
        let noisy = PlaceStay(
            placeKey: "gps-candidate",
            displayName: "근처 위치",
            span: span,
            confidence: .high,
            point: GeoPoint(
                latitude: 37.0,
                longitude: 126.0,
                altitude: 15,
                horizontalAccuracy: 65,
                verticalAccuracy: 22
            )
        )
        let accurate = PlaceStay(
            placeKey: "office",
            displayName: "회사",
            span: span,
            confidence: .high,
            point: GeoPoint(
                latitude: 37.1,
                longitude: 126.1,
                altitude: 14,
                horizontalAccuracy: 4,
                verticalAccuracy: 3
            )
        )

        let values = PlaceStayPresentationEngine.consolidated([
            noisy, accurate,
        ])

        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(try XCTUnwrap(values.first).id, accurate.id)
    }

    func testPlacePresentationReturnsNoOverlappingLocationSegments() {
        let base = makeDate(2026, 8, 12, 9)
        let values = PlaceStayPresentationEngine.consolidated([
            PlaceStay(
                placeKey: "candidate-a",
                displayName: "후보 A",
                span: TimeSpan(
                    start: base,
                    end: base.addingTimeInterval(50 * 60)
                ),
                confidence: .low
            ),
            PlaceStay(
                placeKey: "office",
                displayName: "회사",
                span: TimeSpan(
                    start: base.addingTimeInterval(10 * 60),
                    end: base.addingTimeInterval(70 * 60)
                ),
                confidence: .high,
                isConfirmed: true
            ),
            PlaceStay(
                placeKey: "candidate-b",
                displayName: "후보 B",
                span: TimeSpan(
                    start: base.addingTimeInterval(40 * 60),
                    end: base.addingTimeInterval(90 * 60)
                ),
                confidence: .medium
            ),
        ])

        for (index, value) in values.enumerated() {
            for other in values.dropFirst(index + 1) {
                XCTAssertNil(value.span.intersection(with: other.span))
            }
        }
        XCTAssertEqual(values.map(\.displayName), ["회사"])
    }

    func testPlacePresentationKeepsRealFloorChangesSeparate() {
        let base = makeDate(2026, 8, 9, 9)
        let first = PlaceStay(
            placeKey: "office",
            displayName: "회사",
            floor: 1,
            span: TimeSpan(
                start: base,
                end: base.addingTimeInterval(30 * 60)
            ),
            confidence: .high
        )
        let second = PlaceStay(
            placeKey: "office",
            displayName: "회사",
            floor: 2,
            span: TimeSpan(
                start: first.span.end,
                end: first.span.end.addingTimeInterval(30 * 60)
            ),
            confidence: .high
        )

        XCTAssertEqual(
            PlaceStayPresentationEngine.consolidated([first, second]).count,
            2
        )
    }

    func testFloorEstimatorUsesRelativeAltitudeAndBaseline() {
        let base = makeDate(2026, 7, 30)
        let readings = [
            SensorReading(timestamp: base, relativeAltitudeMeters: 0),
            SensorReading(
                timestamp: base.addingTimeInterval(60),
                relativeAltitudeMeters: 3.1,
                floorsAscended: 1
            )
        ]
        let result = FloorEstimator().estimate(
            readings: readings,
            placeKey: "office",
            baselineFloor: 9
        )
        XCTAssertEqual(result?.fromFloor, 9)
        XCTAssertEqual(result?.toFloor, 10)
    }

    func testTimelineFloorEstimatorNeedsPersistentSamples() {
        let base = makeDate(2026, 7, 30)
        let readings = [
            SensorReading(timestamp: base, relativeAltitudeMeters: 0),
            SensorReading(
                timestamp: base.addingTimeInterval(60),
                relativeAltitudeMeters: 3.1
            ),
        ]

        XCTAssertNil(
            FloorEstimator(minimumStableSampleCount: 3).estimate(
                readings: readings,
                placeKey: "home",
                baselineFloor: 20
            )
        )
    }

    func testHomeFloorCalibrationUsesRelativeAltitudeAndShowsSeaLevelAltitude() {
        let base = makeDate(2026, 7, 31, 18)
        let sessionID = UUID()
        let homePoint = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 82,
            horizontalAccuracy: 8,
            verticalAccuracy: 6
        )
        let initial = SensorReading(
            timestamp: base,
            point: homePoint,
            relativeAltitudeMeters: 0,
            pressureKilopascals: 100.2,
            altimeterSessionID: sessionID
        )
        let engine = FloorCalibrationEngine()
        let calibration = engine.capturing(
            .homeTwentiethFloor,
            from: initial
        )
        let estimate = engine.estimate(
            reading: SensorReading(
                timestamp: base.addingTimeInterval(60),
                point: homePoint,
                relativeAltitudeMeters: 3.1,
                pressureKilopascals: 100.16,
                altimeterSessionID: sessionID
            ),
            calibration: calibration
        )

        XCTAssertTrue(calibration.isCaptured)
        XCTAssertEqual(estimate?.floor, 21)
        XCTAssertEqual(
            estimate?.seaLevelAltitudeMeters ?? 0,
            85.1,
            accuracy: 0.01
        )
        XCTAssertEqual(estimate?.verticalAccuracyMeters, 6)
        XCTAssertEqual(estimate?.confidence, .high)
    }

    func testFloorCalibrationUsesStableMedianInsteadOfPressureOutlier() {
        let base = makeDate(2026, 7, 31, 18)
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 82,
            horizontalAccuracy: 8,
            verticalAccuracy: 6
        )
        let engine = FloorCalibrationEngine()
        let calibration = engine.capturing(
            .homeTwentiethFloor,
            from: SensorReading(
                timestamp: base,
                point: point,
                pressureKilopascals: 100.2
            )
        )
        let readings = [99.5, 100.19, 100.2, 100.21, 100.18].enumerated().map {
            SensorReading(
                timestamp: base.addingTimeInterval(Double($0.offset) * 60),
                point: point,
                pressureKilopascals: $0.element
            )
        }

        let estimate = engine.estimate(readings: readings, calibration: calibration)

        XCTAssertEqual(estimate?.floor, 20)
        XCTAssertEqual(estimate?.confidence, .medium)
    }

    // CAT1029A03: 밤새 GPS가 끊겨 집 머무름이 01:25에 끝나도, 이동은 실제 출발(09:00 이후)에서 시작한다.
    func testOvernightStayGapStartsTravelAtDepartureNotAtLastHomeFix() {
        let day = makeDate(2026, 8, 1, 0, 0)
        func at(_ minute: Int) -> Date { day.addingTimeInterval(Double(minute) * 60) }
        func geo(_ latitude: Double) -> GeoPoint {
            // 역이 없는 좌표(동해). 서울 도심을 지나면 도로 주행도 역 좌표 궤적으로 지하철이 된다(따로 본다).
            GeoPoint(latitude: latitude, longitude: 129.8, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10)
        }
        let stays = [
            PlaceStay(placeKey: "home", displayName: "집", span: TimeSpan(start: at(0), end: at(85)),
                      confidence: .high, point: geo(37.50)),
            PlaceStay(placeKey: "office", displayName: "회사", span: TimeSpan(start: at(608), end: at(720)),
                      confidence: .high, point: geo(37.60)),
        ]
        let night = stride(from: 90, through: 540, by: 10).map {
            SensorReading(timestamp: at($0), motion: .stationary, motionConfidence: .high, gpsAvailable: false)
        }
        let drive = stride(from: 550, through: 606, by: 2).map {
            SensorReading(timestamp: at($0), point: geo(37.50 + Double($0 - 548) / 600), speedMetersPerSecond: 15,
                          motion: .automotive, motionConfidence: .high)
        }

        let result = MovementRouteBuilder().build(stays: stays, readings: night + drive)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.span.start, at(540))
        XCTAssertEqual(result.first?.span.end, at(608))
        XCTAssertNotEqual(result.first?.mode, .subway, "\(result.first?.evidence ?? [])")
    }

    func testShortSlowSegmentStaysWalking() {
        let base = makeDate(2026, 8, 4, 9, 24)
        let span = TimeSpan(start: base, end: base.addingTimeInterval(10 * 60))
        let readings = [
            SensorReading(
                timestamp: base,
                point: GeoPoint(
                    latitude: 37.4870,
                    longitude: 126.7830,
                    altitude: 30,
                    horizontalAccuracy: 10,
                    verticalAccuracy: 8
                ),
                motion: .walking,
                motionConfidence: .high
            ),
            SensorReading(
                timestamp: span.end,
                point: GeoPoint(
                    latitude: 37.4900,
                    longitude: 126.7845,
                    altitude: 30,
                    horizontalAccuracy: 10,
                    verticalAccuracy: 8
                ),
                motion: .walking,
                motionConfidence: .high
            ),
        ]

        let inference = TravelModeClassifier().classify(
            readings: readings,
            inside: span
        )

        XCTAssertEqual(inference.mode, .walking)
    }

    func testRecalibrationKeepsOtherFloorsInSameBuilding() {
        let base = makeDate(2026, 8, 4, 9)
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 40,
            horizontalAccuracy: 8,
            verticalAccuracy: 6
        )
        var place = FrequentPlace(kind: .home, name: "집")
        place.setLocation(
            from: SensorReading(timestamp: base, point: point),
            floor: 1
        )
        place.addFloorCalibration(
            from: SensorReading(
                timestamp: base.addingTimeInterval(60),
                point: point
            ),
            floor: 20
        )

        place.setLocation(
            from: SensorReading(
                timestamp: base.addingTimeInterval(120),
                point: point
            ),
            floor: 1
        )

        XCTAssertEqual(place.floorCalibration?.knownFloors, [1, 20])
    }

    func testRecalibrationInAnotherBuildingDropsStaleFloors() {
        let base = makeDate(2026, 8, 4, 9)
        let home = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 40,
            horizontalAccuracy: 8,
            verticalAccuracy: 6
        )
        let elsewhere = GeoPoint(
            latitude: 37.55,
            longitude: 127.05,
            altitude: 30,
            horizontalAccuracy: 8,
            verticalAccuracy: 6
        )
        var place = FrequentPlace(kind: .home, name: "집")
        place.setLocation(
            from: SensorReading(timestamp: base, point: home),
            floor: 1
        )
        place.addFloorCalibration(
            from: SensorReading(
                timestamp: base.addingTimeInterval(60),
                point: home
            ),
            floor: 20
        )

        place.setLocation(
            from: SensorReading(
                timestamp: base.addingTimeInterval(120),
                point: elsewhere
            ),
            floor: 3
        )

        XCTAssertEqual(place.floorCalibration?.knownFloors, [3])
    }

    func testAltitudeSpikeGateSkipsSingleSpikeAndAcceptsConfirmedChange() {
        var gate = AltitudeSpikeGate()
        XCTAssertTrue(gate.accept(80))
        XCTAssertTrue(gate.accept(83))
        XCTAssertFalse(gate.accept(140))
        XCTAssertTrue(gate.accept(84))
        XCTAssertFalse(gate.accept(120))
        XCTAssertTrue(gate.accept(121))
        XCTAssertTrue(gate.accept(122))
    }

    func testCoalescingTravelKeepsFragmentsSeparatedByStay() {
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
        let stay = PlaceStay(
            placeKey: "cafe",
            displayName: "카페",
            span: TimeSpan(
                start: base.addingTimeInterval(130),
                end: base.addingTimeInterval(350)
            ),
            confidence: .high
        )

        let merged = AppleDeviceGroundTruthEngine.coalescingTravel(
            [first, second],
            stays: [stay],
            maximumGap: 6 * 60
        )

        XCTAssertEqual(merged.count, 2)
    }

    func testCoalescingTravelBoundsDisjointStayInspection() {
        let base = makeDate(2026, 8, 1, 0, 0)
        let count = 1_000
        let segments = (0..<count).map { index in
            let start = base.addingTimeInterval(TimeInterval(index * 6 * 60))
            return TravelSegment(
                mode: .walking,
                span: TimeSpan(
                    start: start,
                    end: start.addingTimeInterval(2 * 60)
                ),
                distanceMeters: 100,
                confidence: .medium,
                evidence: ["GPS"]
            )
        }
        let stays = (0..<count).map { index in
            let start = base.addingTimeInterval(
                30 * 24 * hour + TimeInterval(index * 5 * 60)
            )
            return PlaceStay(
                placeKey: "future-\(index)",
                displayName: "미래 체류",
                span: TimeSpan(
                    start: start,
                    end: start.addingTimeInterval(3 * 60)
                ),
                confidence: .high
            )
        }
        var inspectionCount = 0

        let merged = AppleDeviceGroundTruthEngine.coalescingTravel(
            segments,
            stays: stays,
            maximumGap: 5 * 60,
            candidateInspectionCount: &inspectionCount
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertLessThan(inspectionCount, count * count / 10)
    }

    func testHomeFloorCalibrationRejectsFarAwayLocation() {
        let base = makeDate(2026, 7, 31, 18)
        let sessionID = UUID()
        let homePoint = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 82,
            horizontalAccuracy: 8,
            verticalAccuracy: 6
        )
        let engine = FloorCalibrationEngine()
        let calibration = engine.capturing(
            .homeTwentiethFloor,
            from: SensorReading(
                timestamp: base,
                point: homePoint,
                relativeAltitudeMeters: 0,
                altimeterSessionID: sessionID
            )
        )
        let estimate = engine.estimate(
            reading: SensorReading(
                timestamp: base.addingTimeInterval(60),
                point: GeoPoint(
                    latitude: 37.52,
                    longitude: 127.02,
                    altitude: 85,
                    horizontalAccuracy: 8,
                    verticalAccuracy: 6
                ),
                relativeAltitudeMeters: 3,
                altimeterSessionID: sessionID
            ),
            calibration: calibration
        )

        XCTAssertNil(estimate)
    }

    func testFloorEstimatorUsesPedometerCountersAsCumulativeValues() {
        let base = makeDate(2026, 7, 30)
        let readings = [
            SensorReading(
                timestamp: base,
                relativeAltitudeMeters: 0,
                floorsAscended: 4,
                floorsDescended: 1
            ),
            SensorReading(
                timestamp: base.addingTimeInterval(30),
                relativeAltitudeMeters: 3,
                floorsAscended: 5,
                floorsDescended: 1
            ),
            SensorReading(
                timestamp: base.addingTimeInterval(60),
                relativeAltitudeMeters: 3.1,
                floorsAscended: 5,
                floorsDescended: 1
            )
        ]
        let result = FloorEstimator().estimate(
            readings: readings,
            placeKey: "office",
            baselineFloor: 9
        )
        XCTAssertEqual(result?.toFloor, 10)
        XCTAssertTrue(result?.evidence.contains("층계 +1") == true)
    }

    func testFloorEstimatorDoesNotMixDifferentAltimeterSessions() {
        let base = makeDate(2026, 7, 30, 9)
        let firstSession = UUID()
        let secondSession = UUID()
        let readings = [
            SensorReading(
                timestamp: base,
                relativeAltitudeMeters: 0,
                altimeterSessionID: firstSession
            ),
            SensorReading(
                timestamp: base.addingTimeInterval(60),
                relativeAltitudeMeters: 0.1,
                altimeterSessionID: firstSession
            ),
            SensorReading(
                timestamp: base.addingTimeInterval(120),
                relativeAltitudeMeters: 3.1,
                altimeterSessionID: secondSession
            ),
            SensorReading(
                timestamp: base.addingTimeInterval(180),
                relativeAltitudeMeters: 3.2,
                altimeterSessionID: secondSession
            ),
        ]

        XCTAssertNil(
            FloorEstimator().estimate(
                readings: readings,
                placeKey: "office",
                baselineFloor: 9
            )
        )
    }

    func testFloorTimelineAppliesConfirmedBaselineAndSplitsPlace() {
        let base = makeDate(2026, 7, 30, 9)
        let sessionID = UUID()
        let placeSpan = TimeSpan(
            start: base,
            end: base.addingTimeInterval(30 * 60)
        )
        let detected = PlaceStay(
            placeKey: "office",
            displayName: "회사",
            span: placeSpan,
            confidence: .high
        )
        let known = PlaceStay(
            placeKey: "office",
            displayName: "회사",
            floor: 9,
            span: TimeSpan(
                start: base.addingTimeInterval(-8 * hour),
                end: base.addingTimeInterval(-7 * hour)
            ),
            confidence: .high,
            isConfirmed: true
        )
        let altitudes: [Double] = [0, 0.1, 3.0, 3.1, 3.1]
        let readings = altitudes.enumerated().map { index, altitude in
            SensorReading(
                timestamp: base.addingTimeInterval(
                    Double(index) * 5 * 60
                ),
                relativeAltitudeMeters: altitude,
                pressureKilopascals: 101.3 - altitude * 0.012,
                altimeterSessionID: sessionID
            )
        }

        let result = FloorTimelineEngine().apply(
            readings: readings,
            to: [detected],
            knownPlaces: [known]
        )

        XCTAssertEqual(result.places.map(\.floor), [9, 10])
        XCTAssertEqual(result.transitions.count, 1)
        XCTAssertEqual(result.transitions.first?.fromFloor, 9)
        XCTAssertEqual(result.transitions.first?.toFloor, 10)
        XCTAssertTrue(
            result.transitions.first?.evidence.contains(
                "기압 고도 센서"
            ) == true
        )
        XCTAssertTrue(
            MovementRouteBuilder().build(
                stays: result.places,
                readings: readings
            ).isEmpty
        )
    }

    func testFrequentPlaceFloorAnchorsSameBuildingAndDetectsFloorMove() {
        let base = makeDate(2026, 8, 1, 9)
        let sessionID = UUID()
        let anchor = GeoPoint(
            latitude: 37.5000,
            longitude: 127.0000,
            altitude: 60,
            horizontalAccuracy: 6,
            verticalAccuracy: 5
        )
        let frequent = FrequentPlace(
            kind: .company,
            name: "회사",
            point: anchor,
            floor: 9,
            referenceRelativeAltitudeMeters: 0,
            referencePressureKilopascals: 100.5,
            referenceAltimeterSessionID: sessionID,
            floorCapturedAt: base
        )
        let span = TimeSpan(
            start: base,
            end: base.addingTimeInterval(30 * 60)
        )
        let detected = PlaceStay(
            placeKey: "gps-cluster-1",
            displayName: "자동 감지 장소",
            span: span,
            confidence: .medium,
            point: GeoPoint(
                latitude: 37.5002,
                longitude: 127.0001,
                altitude: 60,
                horizontalAccuracy: 12,
                verticalAccuracy: 8
            )
        )
        let altitudes: [Double] = [0, 0.1, 3.0, 3.1, 3.1]
        let readings = altitudes.enumerated().map { index, altitude in
            SensorReading(
                timestamp: base.addingTimeInterval(
                    Double(index) * 5 * 60
                ),
                point: anchor,
                relativeAltitudeMeters: altitude,
                pressureKilopascals: 100.5 - altitude * 0.012,
                altimeterSessionID: sessionID
            )
        }

        let resolved = FrequentPlaceResolutionEngine().applying(
            [frequent],
            to: [detected],
            readings: readings
        )
        let result = FloorTimelineEngine().apply(
            readings: readings,
            to: resolved,
            knownPlaces: []
        )

        XCTAssertEqual(resolved.first?.placeKey, frequent.stablePlaceKey)
        XCTAssertEqual(resolved.first?.displayName, "회사")
        XCTAssertEqual(resolved.first?.floor, 9)
        XCTAssertEqual(result.places.map(\.floor), [9, 10])
        XCTAssertEqual(result.transitions.first?.fromFloor, 9)
        XCTAssertEqual(result.transitions.first?.toFloor, 10)
        XCTAssertTrue(
            MovementRouteBuilder().build(
                stays: result.places,
                readings: readings
            ).isEmpty
        )
    }

    func testFrequentPlaceLocationCanBeClearedWithoutDeletingPlace() {
        let base = makeDate(2026, 8, 1, 9)
        var place = FrequentPlace(kind: .home)
        place.setLocation(
            from: SensorReading(
                timestamp: base,
                point: GeoPoint(
                    latitude: 37.5,
                    longitude: 127,
                    altitude: 60,
                    horizontalAccuracy: 6,
                    verticalAccuracy: 5
                ),
                relativeAltitudeMeters: 1.2,
                pressureKilopascals: 100.4,
                altimeterSessionID: UUID()
            ),
            floor: 20
        )

        XCTAssertNotNil(place.floorCalibration)
        place.clearLocation()

        XCTAssertEqual(place.kind, .home)
        XCTAssertNil(place.point)
        XCTAssertNil(place.floor)
        XCTAssertNil(place.floorCalibration)
    }

    func testFrequentPlaceFloorHeightPersistsAndFeedsCalibration() throws {
        let base = makeDate(2026, 8, 1, 9)
        let place = FrequentPlace(
            kind: .company,
            name: "사무실",
            point: GeoPoint(
                latitude: 37.5,
                longitude: 127,
                altitude: 60,
                horizontalAccuracy: 5,
                verticalAccuracy: 5
            ),
            floor: 10,
            referenceRelativeAltitudeMeters: 0,
            floorCapturedAt: base,
            floorHeightMeters: 4.2
        )

        let data = try JSONEncoder().encode(place)
        let decoded = try JSONDecoder().decode(FrequentPlace.self, from: data)

        XCTAssertEqual(decoded.floorHeightMeters, 4.2, accuracy: 0.001)
        XCTAssertEqual(
            decoded.floorCalibration?.floorHeightMeters ?? 0,
            4.2,
            accuracy: 0.001
        )
    }

    func testFrequentPlaceLocationSaveKeepsUserSelectedFloor() throws {
        let date = makeDate(2026, 8, 27, 7)
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 42,
            horizontalAccuracy: 5,
            verticalAccuracy: 6
        )
        var place = FrequentPlace(kind: .home, name: "집")
        place.setLocation(
            from: SensorReading(timestamp: date, point: point),
            floor: 12
        )

        let decoded = try JSONDecoder().decode(
            FrequentPlace.self,
            from: JSONEncoder().encode(place)
        )
        XCTAssertEqual(decoded.point, point)
        XCTAssertEqual(decoded.floor, 12)
        XCTAssertEqual(decoded.floorReferencePoints.last?.floor, 12)
    }

    func testFrequentPlaceAutomaticRecordingHonorsDwellAndToggle() {
        let base = makeDate(2026, 8, 1, 9)
        let anchor = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 60,
            horizontalAccuracy: 5,
            verticalAccuracy: 5
        )
        let shortStay = PlaceStay(
            placeKey: "gps-short",
            displayName: "자동 감지 장소",
            span: TimeSpan(
                start: base,
                end: base.addingTimeInterval(5 * 60)
            ),
            confidence: .medium,
            point: anchor
        )
        let longStay = PlaceStay(
            placeKey: "gps-long",
            displayName: "자동 감지 장소",
            span: TimeSpan(
                start: base,
                end: base.addingTimeInterval(15 * 60)
            ),
            confidence: .medium,
            point: anchor
        )
        let place = FrequentPlace(
            kind: .company,
            name: "회사",
            point: anchor,
            floor: 10,
            minimumDwellMinutes: 10
        )

        let shortResolved = FrequentPlaceResolutionEngine().applying(
            [place],
            to: [shortStay],
            readings: []
        )
        let longResolved = FrequentPlaceResolutionEngine().applying(
            [place],
            to: [longStay],
            readings: []
        )
        var disabled = place
        disabled.isAutomaticRecordingEnabled = false
        let disabledResolved = FrequentPlaceResolutionEngine().applying(
            [disabled],
            to: [longStay],
            readings: []
        )

        XCTAssertEqual(shortResolved.first?.displayName, "자동 감지 장소")
        XCTAssertEqual(longResolved.first?.displayName, "회사")
        XCTAssertEqual(disabledResolved.first?.displayName, "자동 감지 장소")
    }

    @MainActor
    func testMapRouteReadingsDoNotInjectSavedPlaceTravelFallback()
        async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("taption-route-source-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try SensorReadingArchive(
            fileURL: directory.appendingPathComponent("readings.jsonl")
        )
        let start = makeDate(2026, 8, 24, 9)
        let realReadings = [
            SensorReading(
                timestamp: start.addingTimeInterval(10 * 60),
                point: GeoPoint(
                    latitude: 37.56,
                    longitude: 126.82,
                    altitude: 20,
                    horizontalAccuracy: 8,
                    verticalAccuracy: 10
                ),
                locationFixQuality: .precise,
                gpsAvailable: true
            ),
            SensorReading(
                timestamp: start.addingTimeInterval(20 * 60),
                point: GeoPoint(
                    latitude: 37.55,
                    longitude: 126.80,
                    altitude: 20,
                    horizontalAccuracy: 7,
                    verticalAccuracy: 10
                ),
                locationFixQuality: .precise,
                gpsAvailable: true
            ),
        ]
        for reading in realReadings {
            try await archive.append(
                reading,
                now: start.addingTimeInterval(2 * hour)
            )
        }

        let home = PlaceStay(
            placeKey: "home",
            displayName: "집",
            span: TimeSpan(
                start: start.addingTimeInterval(-hour),
                end: start
            ),
            confidence: .high,
            point: GeoPoint(
                latitude: 37.56,
                longitude: 126.83,
                altitude: 20,
                horizontalAccuracy: 10,
                verticalAccuracy: 10
            )
        )
        let office = PlaceStay(
            placeKey: "office",
            displayName: "회사",
            span: TimeSpan(
                start: start.addingTimeInterval(hour),
                end: start.addingTimeInterval(2 * hour)
            ),
            confidence: .high,
            point: GeoPoint(
                latitude: 37.52,
                longitude: 126.67,
                altitude: 20,
                horizontalAccuracy: 10,
                verticalAccuracy: 10
            )
        )
        let travel = TravelSegment(
            fromPlaceID: home.id,
            toPlaceID: office.id,
            mode: .bus,
            span: TimeSpan(
                start: start,
                end: start.addingTimeInterval(hour)
            ),
            distanceMeters: 18_000,
            confidence: .high,
            evidence: []
        )
        var stored = TaptionDataSnapshot.empty
        stored.updatedAt = start
        stored.places = [home, office]
        stored.travel = [travel]
        stored.settings.locationEnabled = false
        stored.settings.weatherEnabled = false
        stored.settings.healthEnabled = false
        let model = AppModel(
            repository: InMemoryPlanRepository(snapshot: stored),
            sensorService: AppleSensorDataService(archive: archive),
            cloudSyncService: nil,
            registersHealthBackgroundHandler: false
        )
        await model.bootstrap()

        let readings = await model.sensorReadings(
            in: TimeSpan(
                start: start,
                end: start.addingTimeInterval(hour)
            )
        )

        XCTAssertEqual(Set(readings.map(\.id)), Set(realReadings.map(\.id)))
        XCTAssertFalse(readings.contains { $0.behavior == TravelMode.bus.rawValue })
    }

    func testPlaceDetectionRequiresLongStay() {
        let base = makeDate(2026, 7, 30)
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127.0,
            altitude: 30,
            horizontalAccuracy: 10,
            verticalAccuracy: 5
        )
        let readings = [
            SensorReading(timestamp: base, point: point, motion: .stationary),
            SensorReading(
                timestamp: base.addingTimeInterval(20 * 60),
                point: point,
                motion: .stationary
            )
        ]
        XCTAssertEqual(
            PlaceDetectionEngine().detectStays(readings: readings).count,
            1
        )
    }

    func testPlaceAndWalkingLocationsChooseLowerFloorOnVoteTies() {
        let base = makeDate(2026, 7, 30, 18)
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 30,
            horizontalAccuracy: 8,
            verticalAccuracy: 5
        )
        let readings = [2, 1, 2, 1].enumerated().map { index, floor in
            SensorReading(
                timestamp: base.addingTimeInterval(TimeInterval(index * 20)),
                point: point,
                motion: .walking,
                systemFloor: floor,
                trackingSessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001"),
                trackingKind: .walking,
                sourceDevice: .iPhone
            )
        }

        let placeDetector = PlaceDetectionEngine(minimumDwell: 30)
        XCTAssertEqual(
            placeDetector.detectStays(readings: readings).first?.floor,
            1
        )
        XCTAssertEqual(
            placeDetector.detectStays(readings: Array(readings.reversed()))
                .first?.floor,
            1
        )

        XCTAssertEqual(WalkingLocationEngine().build(readings: readings).first?.floor, 1)
        XCTAssertEqual(
            WalkingLocationEngine().build(readings: Array(readings.reversed()))
                .first?.floor,
            1
        )
    }

    func testPlaceDetectionDoesNotBridgeAnUnobservedDay() {
        let base = makeDate(2026, 7, 30)
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 30,
            horizontalAccuracy: 10,
            verticalAccuracy: 5
        )
        let readings = [
            SensorReading(timestamp: base, point: point, motion: .stationary),
            SensorReading(
                timestamp: base.addingTimeInterval(12 * 60 * 60),
                point: point,
                motion: .stationary
            ),
        ]

        XCTAssertTrue(
            PlaceDetectionEngine().detectStays(readings: readings).isEmpty
        )
    }

    func testRegisteredRestaurantNeeds15MinutesAndMapsToEating() {
        let base = makeDate(2026, 7, 30, 12)
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 30,
            horizontalAccuracy: 10,
            verticalAccuracy: 5
        )
        let restaurant = FrequentPlace(
            kind: .restaurant,
            name: "테스트 식당",
            point: point,
            radiusMeters: 100,
            minimumDwellMinutes: 1
        )
        XCTAssertEqual(restaurant.minimumDwellMinutes, 15)
        let shortReadings = [
            SensorReading(timestamp: base, point: point),
            SensorReading(
                timestamp: base.addingTimeInterval(14 * 60),
                point: point
            ),
        ]
        XCTAssertTrue(
            PlaceDetectionEngine().detectStays(readings: shortReadings).isEmpty
        )
        let shortStay = PlaceStay(
            placeKey: "unregistered",
            displayName: "짧은 체류",
            span: TimeSpan(
                start: base,
                end: base.addingTimeInterval(14 * 60)
            ),
            confidence: .high,
            point: point
        )
        XCTAssertNotEqual(
            FrequentPlaceResolutionEngine().applying(
                [restaurant],
                to: [shortStay],
                readings: shortReadings
            ).first?.placeKey,
            restaurant.stablePlaceKey
        )

        let longReadings = [
            SensorReading(timestamp: base, point: point),
            SensorReading(
                timestamp: base.addingTimeInterval(15 * 60),
                point: point
            ),
        ]
        let detected = PlaceDetectionEngine().detectStays(readings: longReadings)
        let resolved = FrequentPlaceResolutionEngine().applying(
            [restaurant],
            to: detected,
            readings: longReadings
        )
        let span = TimeSpan(start: base, end: base.addingTimeInterval(15 * 60))
        let actuals = StationaryContextActualEngine.records(
            stays: resolved,
            placeKinds: [restaurant.stablePlaceKey: .restaurant],
            placeAnchors: [
                restaurant.stablePlaceKey: FrequentPlaceAnchor(
                    point: point,
                    radiusMeters: restaurant.radiusMeters
                ),
            ],
            readings: longReadings,
            inside: span
        )
        XCTAssertEqual(actuals.count, 1)
        XCTAssertEqual(actuals.first?.categoryID, "food")
        XCTAssertEqual(actuals.first?.behavior, "mealPlace")
        XCTAssertEqual(
            RecordAnalysisCategoryPolicy.categoryID(for: try XCTUnwrap(actuals.first)),
            "eating"
        )
    }

    func testMultipleRestaurantsPersistAndManualMealWinsDuplicateDisplay() throws {
        let base = makeDate(2026, 7, 30, 12)
        let first = FrequentPlace(
            kind: .restaurant,
            name: "첫 식당",
            point: GeoPoint(
                latitude: 37.5,
                longitude: 127,
                altitude: 30,
                horizontalAccuracy: 10,
                verticalAccuracy: 5
            )
        )
        let second = FrequentPlace(
            kind: .restaurant,
            name: "둘째 식당",
            point: GeoPoint(
                latitude: 37.51,
                longitude: 127.01,
                altitude: 30,
                horizontalAccuracy: 10,
                verticalAccuracy: 5
            )
        )
        var settings = AppFeatureSettings.defaults
        settings.frequentPlaces += [first, second]
        let restored = try JSONDecoder().decode(
            AppFeatureSettings.self,
            from: JSONEncoder().encode(settings)
        )
        XCTAssertEqual(
            restored.frequentPlaces.filter { $0.kind == .restaurant }.map(\.name),
            ["첫 식당", "둘째 식당"]
        )

        let span = TimeSpan(start: base, end: base.addingTimeInterval(30 * 60))
        let automatic = ActualRecord(
            planID: nil,
            title: "식사 장소",
            categoryID: "eating",
            startedAt: span.start,
            endedAt: span.end,
            source: .location,
            behavior: "mealPlace"
        )
        let manual = ActualRecord(
            planID: nil,
            title: "점심 식사",
            categoryID: "eating",
            startedAt: span.start,
            endedAt: span.end,
            source: .manual,
            behavior: "meal"
        )
        let visible = ReviewCoverageEngine.records(
            actuals: [automatic, manual],
            in: [span],
            asOf: span.end
        )
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible.first?.title, "점심 식사")
    }

    func testRestaurantMealEngineCreatesOneEatingRecordPerRestaurantStay() {
        let base = makeDate(2026, 7, 30, 12)
        let firstPoint = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 30,
            horizontalAccuracy: 10,
            verticalAccuracy: 5
        )
        let secondPoint = GeoPoint(
            latitude: 37.51,
            longitude: 127.01,
            altitude: 30,
            horizontalAccuracy: 10,
            verticalAccuracy: 5
        )
        let restaurants = [
            FrequentPlace(
                kind: .restaurant,
                name: "첫 식당",
                point: firstPoint,
                radiusMeters: 120
            ),
            FrequentPlace(
                kind: .restaurant,
                name: "둘째 식당",
                point: secondPoint,
                radiusMeters: 120
            ),
        ]
        let readings = [
            SensorReading(timestamp: base, point: firstPoint),
            SensorReading(
                timestamp: base.addingTimeInterval(15 * 60),
                point: firstPoint
            ),
            SensorReading(
                timestamp: base.addingTimeInterval(30 * 60),
                point: secondPoint
            ),
            SensorReading(
                timestamp: base.addingTimeInterval(45 * 60),
                point: secondPoint
            ),
        ]
        let records = RestaurantMealActualEngine.records(
            restaurants: restaurants,
            readings: readings,
            inside: TimeSpan(
                start: base,
                end: base.addingTimeInterval(45 * 60)
            ),
            asOf: base.addingTimeInterval(45 * 60)
        )
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.map { $0.categoryID }, ["eating", "eating"])
        XCTAssertEqual(
            Set(records.map { $0.title }),
            ["식사 · 첫 식당", "식사 · 둘째 식당"]
        )
        let shortRecords = RestaurantMealActualEngine.records(
            restaurants: restaurants,
            readings: readings,
            inside: TimeSpan(
                start: base,
                end: base.addingTimeInterval(14 * 60)
            ),
            asOf: base.addingTimeInterval(14 * 60)
        )
        XCTAssertTrue(shortRecords.isEmpty)
    }

    func testWidgetLocationUsesResolvedIPhonePlaceName() {
        XCTAssertEqual(
            TaptionWidgetContentPolicy.locationTitle(
                displayName: "집",
                floor: nil
            ),
            "집"
        )
        XCTAssertEqual(
            TaptionWidgetContentPolicy.locationTitle(
                displayName: "회사",
                floor: 10
            ),
            "회사 · 10층"
        )
        XCTAssertEqual(
            TaptionWidgetContentPolicy.locationTitle(
                displayName: "   ",
                floor: nil
            ),
            "위치 기록"
        )
    }

    /// 위젯·알림이 보내는 링크가 지도 홈의 어느 상태로 번역되는지 고정한다.
    /// 탭 IA가 없어진 뒤로는 이 번역이 유일한 라우팅 규칙이다.
    func testDeepLinkMapsToMapHomeDestination() {
        let now = makeDate(2026, 7, 30, 9)
        let planStart = makeDate(2026, 7, 28, 14)

        let today = TaptionDeepLink.today.mapHomeDestination(
            planStart: nil,
            now: now
        )
        XCTAssertEqual(today.date, now)
        XCTAssertEqual(today.route, .today)

        // 센서 수집 위젯과 고양이 링크는 캐릭터가 있는 현재 위치로 데려간다.
        for link in [TaptionDeepLink.sensor, .catPicker] {
            let destination = link.mapHomeDestination(planStart: nil, now: now)
            XCTAssertEqual(destination.date, now)
            XCTAssertEqual(destination.route, .liveLocation)
        }

        // 계획 링크는 그 계획이 시작하는 날로 옮기고 하루 요약을 연다.
        let plan = TaptionDeepLink.plan(UUID()).mapHomeDestination(
            planStart: planStart,
            now: now
        )
        XCTAssertEqual(plan.date, planStart)
        XCTAssertEqual(plan.route, .daySummary)

        // 계획을 찾지 못하면 오늘로 떨어지고 시트는 열지 않는다.
        let missing = TaptionDeepLink.plan(UUID()).mapHomeDestination(
            planStart: nil,
            now: now
        )
        XCTAssertEqual(missing.date, now)
        XCTAssertEqual(missing.route, .today)
    }

    /// 라우트가 어떤 동작을 부르는지 고정한다. 지도 홈 뷰 없이 확인하는 지점이다.
    func testMapHomeRouteAppliesExpectedAction() {
        func run(_ route: MapHomeRoute) -> [String] {
            var calls: [String] = []
            route.apply(
                openDaySummary: { calls.append("daySummary") },
                followLiveLocation: { calls.append("liveLocation") }
            )
            return calls
        }

        XCTAssertEqual(run(.today), [])
        XCTAssertEqual(run(.daySummary), ["daySummary"])
        XCTAssertEqual(run(.liveLocation), ["liveLocation"])
    }

    func testDeletedActualRecordStaysSuppressedOnAutomaticRefresh() throws {
        let base = makeDate(2026, 8, 1, 9, 0)
        let deleted = ActualRecord(
            planID: UUID(),
            title: "여행 준비",
            categoryID: "travel",
            startedAt: base,
            endedAt: base.addingTimeInterval(hour),
            source: .timer
        )
        let remaining = ActualRecord(
            planID: nil,
            title: "걷기",
            categoryID: "exercise",
            startedAt: base.addingTimeInterval(2 * hour),
            endedAt: base.addingTimeInterval(3 * hour),
            source: .healthKit
        )

        let visible = ActualRecordSuppressionEngine.visibleRecords(
            from: [deleted, remaining, deleted],
            suppressedIDs: [deleted.id]
        )

        XCTAssertEqual(visible, [remaining])

        var settings = AppFeatureSettings.defaults
        settings.suppressedActualIDs = [deleted.id]
        let decoded = try JSONDecoder().decode(
            AppFeatureSettings.self,
            from: JSONEncoder().encode(settings)
        )
        XCTAssertEqual(decoded.suppressedActualIDs, [deleted.id])
    }

    /// 배율마다 한 칸씩 넘긴 자리에 그대로 머문다. 되돌아오면 처음 자리다.
    @MainActor
    func testShiftingIntoAnEmptyPeriodStaysThereForEveryScale() {
        let calendar = Calendar.autoupdatingCurrent
        let anchor = makeDate(2026, 7, 31, 12)
        let model = AppModel(
            repository: InMemoryPlanRepository(),
            cloudSyncService: nil
        )

        for scale in TimeScale.allCases {
            let component: Calendar.Component = switch scale {
            case .day: .day
            case .week: .weekOfYear
            case .month: .month
            case .year: .year
            }
            model.selectedScale = scale
            model.selectedDate = anchor

            model.shiftSelectedDate(by: 1)
            XCTAssertEqual(
                model.selectedDate,
                calendar.date(byAdding: component, value: 1, to: anchor),
                "\(scale.rawValue) should stay on the empty next period"
            )

            model.shiftSelectedDate(by: -1)
            XCTAssertEqual(
                model.selectedDate,
                anchor,
                "\(scale.rawValue) should come back to where it started"
            )
        }
    }

    @MainActor
    func testPermissionOnboardingStaysHiddenWhenAllStepsAreGranted() async {
        var snapshot = TaptionDataSnapshot.empty
        for feature in [
            PermissionFeature.location,
            .health,
            .photos,
            .calendar,
            .notifications,
        ] {
            snapshot.settings.permissions[feature] = .authorized
        }
        snapshot.settings.healthEnabled = true
        let model = AppModel(
            repository: InMemoryPlanRepository(snapshot: snapshot),
            cloudSyncService: nil
        )
        await model.bootstrap()

        model.presentPermissionOnboardingIfNeeded()

        XCTAssertFalse(model.isPermissionOnboardingPresented)
    }

    func testClockRingsPlaceArcsAtTheirTimeOfDay() {
        let day = makeDate(2026, 8, 4)
        let span = TimeSpan(start: day, end: day.addingTimeInterval(24 * hour))
        let actuals = [
            makeActual("수면", "sleep", start: day, minutes: 6 * 60),
            makeActual(
                "걷기",
                "movement",
                start: day.addingTimeInterval(12 * hour),
                minutes: 60
            ),
        ]

        let rings = RecordChartEngine.clockRings(
            actuals: actuals,
            in: span,
            asOf: day.addingTimeInterval(24 * hour)
        )

        XCTAssertEqual(rings.map(\.categoryID), ["sleep", "movement"])
        XCTAssertEqual(rings[0].arcs.count, 1)
        XCTAssertEqual(rings[0].arcs[0].startFraction, 0, accuracy: 0.0001)
        XCTAssertEqual(rings[0].arcs[0].endFraction, 0.25, accuracy: 0.0001)
        XCTAssertEqual(rings[1].arcs[0].startFraction, 0.5, accuracy: 0.0001)
        XCTAssertEqual(
            rings[1].arcs[0].endFraction,
            0.5 + 1.0 / 24,
            accuracy: 0.0001
        )
    }

    /// 사용자가 본 것: 회사에서 한 번도 나가지 않았는데 "근무 2회 · 4시간
    /// 23분". 층이 바뀌면 체류가 둘로 갈리고(FloorTimelineEngine.split),
    /// 자리를 옮겨 잠깐 걸으면 체류 묶음이 끊긴다(PlaceDetectionEngine).
    /// 등록한 곳 반경 안이라면 어느 쪽도 "나갔다"가 아니다.
    func testWorkStaysJoinAcrossAFloorChangeAtTheSamePlace() {
        let officeStart = makeDate(2026, 8, 4, 9, 0)
        let readings = officeReadings(
            from: officeStart,
            count: 25,
            metersFromAnchor: { _ in 0 }
        )
        let stay = PlaceStay(
            placeKey: officeKey,
            displayName: "회사",
            floor: 20,
            span: TimeSpan(
                start: officeStart,
                end: officeStart.addingTimeInterval(4 * hour)
            ),
            confidence: .high,
            point: officePoint(0),
            isConfirmed: true,
            floorEvidence: FloorEvidence(
                measuredAt: officeStart,
                relativeAltitudeMeters: 57
            )
        )
        // 20층 → 2층. 같은 회사이므로 떠난 것이 아니다.
        let timeline = FloorTimelineEngine().apply(
            readings: floorChanging(readings, after: 12),
            to: [stay],
            knownPlaces: []
        )
        XCTAssertEqual(
            timeline.places.count,
            2,
            "층 이동이 체류를 둘로 가르는 것이 쪼개짐의 원인이다"
        )
        XCTAssertEqual(Set(timeline.places.map(\.placeKey)).count, 1)

        let records = officeRecords(stays: timeline.places, readings: readings)
        XCTAssertEqual(records.map(\.title), ["근무"])
        XCTAssertEqual(records.first?.startedAt, stay.span.start)
        XCTAssertEqual(records.first?.endedAt, stay.span.end)
        // 층 근거는 원본 체류에 그대로 남는다. 표시를 이었다고 근거를 지우지
        // 않는다.
        XCTAssertEqual(
            timeline.places.compactMap(\.floorEvidence).count,
            2
        )
        XCTAssertEqual(timeline.places.map(\.floor), [20, 2])
    }

    /// 실기기에서 "근무 2회"가 나온 길. 사무실 안에서 70m 넘게 자리를 옮기면
    /// PlaceDetectionEngine 이 묶음을 끊고(SensorFusion 의 detectStays 는
    /// 묶음 첫 점에서 잰 거리로만 자른다), 그 조각이 최소 체류 15분에 못
    /// 미치면 통째로 버려져 앞뒤 근무 사이에 구멍이 남는다. 사용자가 맞춘
    /// 반경 120m 안이므로 나간 것이 아니다.
    func testOfficeStaysDetectedFromReadingsJoinIntoOneWorkRecord() {
        let dayStart = makeDate(2026, 8, 4, 0, 0)
        let day = TimeSpan(
            start: dayStart,
            end: dayStart.addingTimeInterval(24 * hour)
        )
        let morning = makeDate(2026, 8, 4, 9, 0)
        // 09:00–18:00 사이 5분마다 한 점. 12:00–12:10 만 90m 떨어진 회의실.
        let readings = (0..<109).map { step -> SensorReading in
            let minutes = Double(step) * 5
            return SensorReading(
                timestamp: morning.addingTimeInterval(minutes * 60),
                point: officePoint(
                    minutes >= 180 && minutes < 195 ? 90 : 0
                ),
                motion: .stationary,
                motionConfidence: .high
            )
        }
        let office = FrequentPlace(
            kind: .company,
            name: "회사",
            point: officePoint(0),
            floor: 20,
            radiusMeters: 120,
            minimumDwellMinutes: 10
        )
        let detected = PlaceDetectionEngine().detectStays(readings: readings)
        XCTAssertEqual(
            detected.count,
            2,
            "70m 밖으로 옮긴 자리가 체류를 끊는 것이 쪼개짐의 원인이다"
        )

        let engine = FrequentPlaceResolutionEngine()
        let resolved = engine.applying(
            [office],
            to: detected,
            readings: readings
        )
        XCTAssertEqual(
            Set(resolved.map(\.placeKey)),
            [office.stablePlaceKey]
        )

        let records = StationaryContextActualEngine.records(
            stays: resolved,
            placeKinds: engine.kindsByPlaceKey([office]),
            placeAnchors: engine.anchorsByPlaceKey([office]),
            readings: readings,
            inside: day,
            calendar: utcCalendar,
            now: day.end
        )
        XCTAssertEqual(records.map(\.title), ["근무"])
        XCTAssertEqual(records.first?.startedAt, morning)
        XCTAssertEqual(
            records.first?.endedAt,
            morning.addingTimeInterval(9 * hour)
        )
    }

    /// 사용자가 말한 규칙 그대로: 등록한 장소 안에 계속 있으면 한 줄이다.
    /// 층이 바뀌고, 점심때 자리를 떠나 건물 안을 돌아다녀도 이어진다.
    func testWorkStaysJoinAcrossFloorChangeAndDeskBreakInsideThePlace() {
        let dayStart = makeDate(2026, 8, 4, 0, 0)
        let day = TimeSpan(
            start: dayStart,
            end: dayStart.addingTimeInterval(24 * hour)
        )
        let morning = makeDate(2026, 8, 4, 9, 0)
        // 09:00–12:00 20층, 12:00–13:00 같은 건물 90m 지점(구내식당),
        // 13:00–18:00 2층. 어느 것도 반경 120m를 벗어나지 않는다.
        let stays = [
            officeStay(
                start: morning,
                end: morning.addingTimeInterval(3 * hour),
                floor: 20
            ),
            officeStay(
                start: morning.addingTimeInterval(4 * hour),
                end: morning.addingTimeInterval(9 * hour),
                floor: 2
            ),
        ]
        let readings = officeReadings(
            from: morning,
            count: 55,
            metersFromAnchor: { step in
                (step >= 18 && step < 24) ? 90 : 0
            }
        )
        let records = officeRecords(
            stays: stays,
            readings: readings,
            inside: day,
            // 점심 사이 시간은 정지로 남아 예전에는 "머무름"이 되었다.
            stationarySpans: [
                TimeSpan(
                    start: morning,
                    end: morning.addingTimeInterval(9 * hour)
                )
            ]
        )

        XCTAssertEqual(records.map(\.title), ["근무"])
        XCTAssertEqual(records.first?.startedAt, morning)
        XCTAssertEqual(
            records.first?.endedAt,
            morning.addingTimeInterval(9 * hour)
        )

        // 기록 목록의 "N회"와 시간표 막대가 같은 값을 읽는다.
        let groups = ActualRecordGroupingEngine.groups(
            actuals: records,
            in: day,
            categories: CategoryCatalog.builtIn,
            asOf: day.end
        )
        let work = groups.first { $0.id == "work" }
        XCTAssertEqual(work?.children.map(\.title), ["근무"])
        XCTAssertEqual(work?.children.first?.occurrenceCount, 1)
        XCTAssertEqual(work?.duration, 9 * hour)
    }

    /// 건물을 나갔다 돌아오면 두 기록이어야 한다. 그러지 않으면 출근·퇴근과
    /// 일과 고리가 뜻을 잃는다.
    func testWorkStaysDoNotJoinWhenTheUserLeavesTheRegisteredRadius() {
        let dayStart = makeDate(2026, 8, 4, 0, 0)
        let day = TimeSpan(
            start: dayStart,
            end: dayStart.addingTimeInterval(24 * hour)
        )
        let morning = makeDate(2026, 8, 4, 9, 0)
        let stays = [
            officeStay(
                start: morning,
                end: morning.addingTimeInterval(3 * hour),
                floor: 20
            ),
            officeStay(
                start: morning.addingTimeInterval(4 * hour),
                end: morning.addingTimeInterval(9 * hour),
                floor: 20
            ),
        ]
        // 12:00–13:00 사이에 600m 떨어진 곳에서 위치가 찍힌다.
        let readings = officeReadings(
            from: morning,
            count: 55,
            metersFromAnchor: { step in
                (step >= 18 && step < 24) ? 600 : 0
            }
        )
        let records = officeRecords(
            stays: stays,
            readings: readings,
            inside: day
        )

        XCTAssertEqual(records.map(\.title), ["근무", "근무"])
        XCTAssertEqual(records.first?.endedAt, stays[0].span.end)
        XCTAssertEqual(records.last?.startedAt, stays[1].span.start)
    }

    /// 이어 붙여도 하루 합계는 그대로다. 예전에는 사이 시간이 "머무름"으로
    /// 남았고, 이제는 그 시간을 근무가 한 번만 덮는다.
    func testJoiningStaysKeepsTheMeasuredTotalUnchanged() {
        let dayStart = makeDate(2026, 8, 4, 0, 0)
        let day = TimeSpan(
            start: dayStart,
            end: dayStart.addingTimeInterval(24 * hour)
        )
        let morning = makeDate(2026, 8, 4, 9, 0)
        let whole = TimeSpan(
            start: morning,
            end: morning.addingTimeInterval(9 * hour)
        )
        let stays = [
            officeStay(
                start: morning,
                end: morning.addingTimeInterval(3 * hour),
                floor: 20
            ),
            officeStay(
                start: morning.addingTimeInterval(4 * hour),
                end: whole.end,
                floor: 2
            ),
        ]
        let readings = officeReadings(
            from: morning,
            count: 55,
            metersFromAnchor: { _ in 0 }
        )
        let split = StationaryContextActualEngine.records(
            stays: stays,
            placeKinds: [officeKey: .company],
            stationarySpans: [whole],
            readings: readings,
            inside: day,
            calendar: utcCalendar,
            now: day.end
        )
        let joined = officeRecords(
            stays: stays,
            readings: readings,
            inside: day,
            stationarySpans: [whole]
        )

        // 반경을 모르면 사이 시간이 "머무름"으로 남는다.
        XCTAssertEqual(split.map(\.title), ["근무", "머무름", "근무"])
        XCTAssertEqual(joined.map(\.title), ["근무"])
        XCTAssertEqual(
            ActualIntervalMergeEngine.duration(
                of: joined.map { $0.span(asOf: day.end) }
            ),
            ActualIntervalMergeEngine.duration(
                of: split.map { $0.span(asOf: day.end) }
            ),
            "이어 붙이면서 시간을 잃거나 겹쳐 세면 안 된다"
        )
        XCTAssertEqual(
            joined.reduce(0) { $0 + $1.span(asOf: day.end).duration },
            whole.duration,
            "이어진 기록끼리 겹치면 합계가 흐른 시간을 넘는다"
        )
    }

    /// 등록하지 않은 곳에는 사용자가 맞춘 반경이 없다. 층이 갈린 자국만
    /// 메우고, 크게 벌어진 시간까지 지어내지 않는다.
    func testUnregisteredPlaceJoinsOnlyTheShortSplit() {
        let dayStart = makeDate(2026, 8, 4, 0, 0)
        let day = TimeSpan(
            start: dayStart,
            end: dayStart.addingTimeInterval(24 * hour)
        )
        let start = makeDate(2026, 8, 4, 9, 0)
        func records(gap: TimeInterval) -> [ActualRecord] {
            StationaryContextActualEngine.records(
                stays: [
                    makeContextStay(
                        start: start,
                        end: start.addingTimeInterval(hour),
                        placeKey: "somewhere"
                    ),
                    makeContextStay(
                        start: start.addingTimeInterval(hour + gap),
                        end: start.addingTimeInterval(3 * hour + gap),
                        placeKey: "somewhere"
                    ),
                ],
                placeKinds: [:],
                inside: day,
                calendar: utcCalendar,
                now: day.end
            )
        }

        XCTAssertEqual(records(gap: 90).map(\.title), ["머무름"])
        XCTAssertEqual(
            records(gap: 30 * 60).map(\.title),
            ["머무름", "머무름"]
        )
    }

    // MARK: - 한 곳에 머문 시간 잇기 · 재료

    func testLocationRingShowsPlaceAndFloorBelowDetailContext() throws {
        let dayStart = makeDate(2026, 8, 4)
        let day = TimeSpan(
            start: dayStart,
            end: dayStart.addingTimeInterval(24 * hour)
        )
        let ring = try XCTUnwrap(
            RecordClockDetailEngine.locationRing(
                stays: [
                    PlaceStay(
                        placeKey: "home",
                        displayName: "집",
                        floor: 20,
                        span: TimeSpan(
                            start: dayStart.addingTimeInterval(8 * hour),
                            end: dayStart.addingTimeInterval(10 * hour)
                        ),
                        confidence: .high
                    ),
                ],
                in: day,
                asOf: day.end
            )
        )
        XCTAssertEqual(ring.kind, .location)
        XCTAssertEqual(ring.arcs.map(\.token), ["집 · 20층"])
        assertRingHasNoSlivers(ring)
    }

    /// 하루보다 넓은 기간에서는 여러 날의 줄거리가 같은 각도에 겹쳐 뭉개진다.
    /// 그때는 아무것도 그리지 않는다.
    func testDayPhaseRingStaysAtTheDayScale() {
        let day = dayPhaseDay()
        let week = TimeSpan(
            start: day.start,
            end: day.start.addingTimeInterval(7 * 24 * hour)
        )
        let actuals = [
            sleepActual(0, 7, on: day),
            stationaryContext(.homeRest, 7, 8, on: day),
            stationaryContext(.work, 8.75, 18, on: day),
        ]
        let travel = [travelLeg(.subway, 8, 8.75, on: day)]

        XCTAssertTrue(
            DayPhaseEngine.phases(
                actuals: actuals,
                travel: travel,
                stays: [],
                placeKinds: [:],
                in: week,
                asOf: week.end
            )
            .isEmpty
        )
        XCTAssertNil(
            RecordClockDetailEngine.phaseRing(
                actuals: actuals,
                travel: travel,
                stays: [],
                placeKinds: [:],
                in: week,
                asOf: week.end
            )
        )
        XCTAssertEqual(
            RecordClockDetailEngine.phaseRing(
                actuals: [],
                travel: [],
                stays: [],
                placeKinds: [:],
                in: day,
                asOf: day.end
            )?.arcs.map(\.token),
            [DayPhase.unconfirmed.rawValue]
        )
    }

    /// 목적지 종류는 머무름의 일과를 정하고, 오가는 구간은 모두 이동이다.
    func testDayPhaseRingNamesTheRoundTripFromTheRegisteredPlace() {
        let cases: [(FrequentPlaceKind, StationaryContextKind?, [String])] = [
            (.company, .work, ["수면", "이동", "업무", "이동"]),
            (.school, .study, ["수면", "이동", "수업", "이동"]),
            (.academy, .study, ["수면", "이동", "수업", "이동"]),
            (.hobby, nil, ["수면", "이동", "취미", "이동"]),
            (.exercise, .gymFacility, ["수면", "이동", "운동", "이동"]),
        ]
        for (kind, context, titles) in cases {
            let phases = roundTripPhases(to: kind, staying: context)
            XCTAssertEqual(
                phases.map(\.phase.title),
                titles,
                "\(kind.defaultName)에 다녀온 하루"
            )
        }
    }

    /// 사용자는 "지금 몇 층인지"만 알려 준다. 층 높이는 서로 다른 두 층의
    /// 고도 차이에서 앱이 스스로 구한다.
    func testMapLocationKeepsNearbyFloorAndClearsDistantCalibration() {
        let original = GeoPoint(
            latitude: 37.5,
            longitude: 127.0,
            altitude: 35,
            horizontalAccuracy: 8,
            verticalAccuracy: 6
        )
        var place = FrequentPlace(
            kind: .company,
            point: original,
            floor: 2
        )
        place.setMapLocation(
            GeoPoint(
                latitude: 37.5001,
                longitude: 127.0001,
                altitude: 35,
                horizontalAccuracy: 25,
                verticalAccuracy: -1
            )
        )
        XCTAssertEqual(place.floor, 2)

        place.setMapLocation(
            GeoPoint(
                latitude: 37.51,
                longitude: 127.01,
                altitude: 0,
                horizontalAccuracy: 25,
                verticalAccuracy: -1
            )
        )
        XCTAssertNil(place.floor)
        XCTAssertTrue(place.floorReferencePoints.isEmpty)
    }

    func testCurrentFloorCalibrationDerivesFloorHeightFromTwoFloors() throws {
        let base = makeDate(2026, 8, 5, 9, 0)
        let groundPressure = 101.0
        var place = FrequentPlace(kind: .company)
        XCTAssertEqual(place.floorHeightMeters, 3, accuracy: 0.001)

        place.calibrateCurrentFloor(
            to: 1,
            from: makeAltitudeReading(
                at: base,
                pressureKilopascals: groundPressure
            )
        )
        // 기준이 한 층뿐이면 잴 것이 없으므로 쓰던 값을 그대로 둔다.
        XCTAssertEqual(place.floorHeightMeters, 3, accuracy: 0.001)
        XCTAssertEqual(place.floor, 1)

        let upstairs = makeAltitudeReading(
            at: base.addingTimeInterval(600),
            latitude: 37.5002,
            pressureKilopascals: pressure(groundPressure, risingBy: 13.6)
        )
        place.calibrateCurrentFloor(to: 5, from: upstairs)

        XCTAssertEqual(place.floorHeightMeters, 3.4, accuracy: 0.05)
        XCTAssertEqual(place.floorReferencePoints.map(\.floor).sorted(), [1, 5])
        // 자리는 처음 잡은 기준점 그대로다. 층만 더한다.
        XCTAssertEqual(place.point?.latitude, 37.5)

        let estimate = FloorCalibrationEngine().estimate(
            reading: upstairs,
            calibration: try XCTUnwrap(place.floorCalibration)
        )
        XCTAssertEqual(estimate?.floor, 5)
    }

    /// 같은 층을 다시 알려 주면 그 층 기준만 갱신하고 다른 층은 남긴다.
    func testCurrentFloorCalibrationKeepsOtherFloors() {
        let base = makeDate(2026, 8, 5, 9, 0)
        let groundPressure = 101.0
        var place = FrequentPlace(kind: .home)
        place.calibrateCurrentFloor(
            to: 1,
            from: makeAltitudeReading(
                at: base,
                pressureKilopascals: groundPressure
            )
        )
        place.calibrateCurrentFloor(
            to: 5,
            from: makeAltitudeReading(
                at: base.addingTimeInterval(600),
                pressureKilopascals: pressure(groundPressure, risingBy: 13.6)
            )
        )
        place.calibrateCurrentFloor(
            to: 5,
            from: makeAltitudeReading(
                at: base.addingTimeInterval(1_200),
                pressureKilopascals: pressure(groundPressure, risingBy: 12.8)
            )
        )

        XCTAssertEqual(place.floorReferencePoints.map(\.floor).sorted(), [1, 5])
        XCTAssertEqual(place.floorHeightMeters, 3.2, accuracy: 0.05)
    }

    /// 잘못 잰 짝은 층 높이 계산에서 버린다. 억지로 끌어다 맞추면 멀쩡한
    /// 다른 기준까지 망가진다.
    func testFloorHeightEstimatorDropsImpossiblePairs() {
        let base = makeDate(2026, 8, 5, 9, 0)
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 82,
            horizontalAccuracy: 8,
            verticalAccuracy: 6
        )
        let references = [
            FloorCalibrationPoint(
                floor: 1,
                point: point,
                relativeAltitudeMeters: nil,
                pressureKilopascals: 101.0,
                altimeterSessionID: UUID(),
                capturedAt: base
            ),
            FloorCalibrationPoint(
                floor: 5,
                point: point,
                relativeAltitudeMeters: nil,
                pressureKilopascals: pressure(101.0, risingBy: 60),
                altimeterSessionID: UUID(),
                capturedAt: base.addingTimeInterval(600)
            ),
        ]

        XCTAssertNil(FloorHeightEstimator.metersPerFloor(from: references))
        XCTAssertNil(
            FloorHeightEstimator.metersPerFloor(from: [references[0]])
        )
    }

    /// 위층이 아래층보다 낮게 잰 짝은 둘 중 하나가 오염된 것이다. 부호를
    /// 감추면 그 오염이 3m짜리 멀쩡한 값으로 둔갑한다.
    func testFloorHeightEstimatorRejectsInvertedPair() {
        let base = makeDate(2026, 8, 5, 9, 0)
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 82,
            horizontalAccuracy: 8,
            verticalAccuracy: 6
        )
        let references = [
            FloorCalibrationPoint(
                floor: 1,
                point: point,
                relativeAltitudeMeters: nil,
                pressureKilopascals: 101.0,
                altimeterSessionID: UUID(),
                capturedAt: base
            ),
            FloorCalibrationPoint(
                floor: 5,
                point: point,
                relativeAltitudeMeters: nil,
                pressureKilopascals: pressure(101.0, risingBy: -12),
                altimeterSessionID: UUID(),
                capturedAt: base.addingTimeInterval(600)
            ),
        ]

        XCTAssertNil(FloorHeightEstimator.metersPerFloor(from: references))
    }

    /// 같은 높이에 두 층이 있다고 적힌 짝. 층 높이 계산은 여기서 아무 값도
    /// 내놓지 않아야 하고, 장소의 층 높이는 기본값 그대로여야 한다.
    func testPoisonedFloorPairKeepsFloorHeightSane() {
        let base = makeDate(2026, 8, 5, 9, 0)
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 82,
            horizontalAccuracy: 8,
            verticalAccuracy: 6
        )
        let references = [
            FloorCalibrationPoint(
                floor: 2,
                point: point,
                relativeAltitudeMeters: nil,
                pressureKilopascals: 101.0,
                altimeterSessionID: UUID(),
                capturedAt: base
            ),
            FloorCalibrationPoint(
                floor: 19,
                point: point,
                relativeAltitudeMeters: nil,
                pressureKilopascals: pressure(101.0, risingBy: 0.3),
                altimeterSessionID: UUID(),
                capturedAt: base.addingTimeInterval(600)
            ),
        ]

        XCTAssertNil(FloorHeightEstimator.metersPerFloor(from: references))

        var place = FrequentPlace(kind: .company)
        place.calibrateCurrentFloor(
            to: 19,
            from: makeAltitudeReading(at: base, pressureKilopascals: 101.0)
        )
        XCTAssertEqual(place.floorHeightMeters, 3, accuracy: 0.001)
    }

    /// 상대고도의 0점은 기압 세션마다 새로 잡힌다. 세션을 모르는 표본끼리
    /// 비교하면 없던 수십 미터가 생긴다. 그때는 절대 기압으로 내려간다.
    func testRelativeAltitudeIsIgnoredWithoutAKnownSession() throws {
        let base = makeDate(2026, 8, 5, 9, 0)
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 82,
            horizontalAccuracy: 8,
            verticalAccuracy: 6
        )
        let older = FloorCalibrationPoint(
            floor: 2,
            point: point,
            relativeAltitudeMeters: 0,
            pressureKilopascals: 101.0,
            altimeterSessionID: nil,
            capturedAt: base
        )
        let newer = FloorCalibrationPoint(
            floor: 2,
            point: point,
            relativeAltitudeMeters: 51,
            pressureKilopascals: 101.0,
            altimeterSessionID: nil,
            capturedAt: base.addingTimeInterval(86_400)
        )

        let delta = try XCTUnwrap(
            AltitudeDelta.between(
                AltitudeDelta.Sample(older),
                and: AltitudeDelta.Sample(newer)
            )
        )
        XCTAssertEqual(delta.meters, 0, accuracy: 0.01)
    }

    /// 같은 높이에서 잰 두 층 기준은 함께 참일 수 없다. 새로 보정하면
    /// 모순되는 옛 기준은 남지 않는다. 남으면 사용자는 자기 데이터를 고칠
    /// 방법이 없다.
    func testCalibratingSameAltitudeReplacesContradictingReference() {
        let base = makeDate(2026, 8, 5, 9, 0)
        let groundPressure = 101.0
        var place = FrequentPlace(kind: .company)
        // 앱이 스스로 19층이라고 적어 둔 기준점. 실제로는 2층에서 잰 값이다.
        place.calibrateCurrentFloor(
            to: 19,
            from: makeAltitudeReading(
                at: base,
                pressureKilopascals: groundPressure
            )
        )
        XCTAssertEqual(place.floorReferencePoints.map(\.floor), [19])

        place.calibrateCurrentFloor(
            to: 2,
            from: makeAltitudeReading(
                at: base.addingTimeInterval(60),
                pressureKilopascals: pressure(groundPressure, risingBy: 0.2)
            )
        )

        XCTAssertEqual(place.floorReferencePoints.map(\.floor), [2])
        XCTAssertEqual(place.floor, 2)
        XCTAssertEqual(place.floorHeightMeters, 3, accuracy: 0.001)
    }

    /// 자동 추정은 사용자가 확인한 기준을 밀어내지 못한다. 밀어낼 수 있으면
    /// 틀린 추정이 사용자의 정정을 즉시 되돌린다.
    func testAutomaticCalibrationCannotOverrideConfirmedFloor() {
        let base = makeDate(2026, 8, 5, 9, 0)
        let groundPressure = 101.0
        var place = FrequentPlace(kind: .company)
        place.calibrateCurrentFloor(
            to: 2,
            from: makeAltitudeReading(
                at: base,
                pressureKilopascals: groundPressure
            )
        )

        let accepted = place.addFloorCalibration(
            from: makeAltitudeReading(
                at: base.addingTimeInterval(300),
                pressureKilopascals: pressure(groundPressure, risingBy: 0.4)
            ),
            floor: 19
        )

        XCTAssertFalse(accepted)
        XCTAssertEqual(place.floorReferencePoints.map(\.floor), [2])
    }

    /// 미리 채워 둔 층수는 사용자가 고른 값이 아니다. 눈으로 보고 한 번 더
    /// 누르기 전에는 보정이 잠겨 있어야 한다.
    func testFloorCalibrationPromptNeedsDeliberateConfirmation() {
        var prompt = FloorCalibrationPrompt(lastConfirmedFloor: 19)
        XCTAssertEqual(prompt.floor, 19)
        XCTAssertFalse(prompt.canCommit)

        prompt.select(2)
        XCTAssertEqual(prompt.floor, 2)
        XCTAssertFalse(prompt.canCommit)

        prompt.arm()
        XCTAssertTrue(prompt.canCommit)

        // 값이 바뀌면 확인은 무효다. 확인한 값과 보정할 값은 늘 같아야 한다.
        prompt.select(3)
        XCTAssertFalse(prompt.canCommit)

        // 확인한 적 없는 기본 프롬프트도 잠겨 있다.
        XCTAssertFalse(FloorCalibrationPrompt().canCommit)
        XCTAssertEqual(FloorCalibrationPrompt().floor, 1)
    }

    /// 틀린 기준점 하나만 지운다. 나머지 기준과 위치는 그대로 남고, 층
    /// 높이는 남은 기준으로 다시 구한다.
    func testRemovingFloorReferenceKeepsTheOthers() {
        let base = makeDate(2026, 8, 5, 9, 0)
        let groundPressure = 101.0
        var place = FrequentPlace(kind: .company)
        place.calibrateCurrentFloor(
            to: 1,
            from: makeAltitudeReading(
                at: base,
                pressureKilopascals: groundPressure
            )
        )
        place.calibrateCurrentFloor(
            to: 5,
            from: makeAltitudeReading(
                at: base.addingTimeInterval(600),
                pressureKilopascals: pressure(groundPressure, risingBy: 13.6)
            )
        )
        XCTAssertEqual(place.floorHeightMeters, 3.4, accuracy: 0.05)

        // 자동 추정이 엉뚱한 층 기준을 끼워 넣었다.
        place.addFloorCalibration(
            from: makeAltitudeReading(
                at: base.addingTimeInterval(1_200),
                pressureKilopascals: pressure(groundPressure, risingBy: 51)
            ),
            floor: 19
        )
        XCTAssertEqual(place.floorReferencePoints.map(\.floor), [1, 5, 19])

        XCTAssertTrue(place.removeFloorReference(floor: 19))

        XCTAssertEqual(place.floorReferencePoints.map(\.floor), [1, 5])
        XCTAssertEqual(place.floorHeightMeters, 3.4, accuracy: 0.05)
        // 마지막으로 확인한 층이 여전히 이 장소의 기준 층이다.
        XCTAssertEqual(place.floor, 5)
        XCTAssertNotNil(place.point)
        // 없는 기준을 다시 지우려 해도 아무 일도 일어나지 않는다.
        XCTAssertFalse(place.removeFloorReference(floor: 19))
    }

    /// 기준 층을 지우면 남은 기준 중 하나가 그 자리를 잇는다. 기준이 하나도
    /// 남지 않으면 이 장소는 층을 말하지 않는다. 위치는 그대로 둔다.
    func testRemovingAnchorFloorReferenceRebasesOrClearsFloor() {
        let base = makeDate(2026, 8, 5, 9, 0)
        let groundPressure = 101.0
        var place = FrequentPlace(kind: .company)
        place.calibrateCurrentFloor(
            to: 1,
            from: makeAltitudeReading(
                at: base,
                pressureKilopascals: groundPressure
            )
        )
        place.calibrateCurrentFloor(
            to: 5,
            from: makeAltitudeReading(
                at: base.addingTimeInterval(600),
                pressureKilopascals: pressure(groundPressure, risingBy: 13.6)
            )
        )
        XCTAssertEqual(place.floor, 5)

        XCTAssertTrue(place.removeFloorReference(floor: 5))
        XCTAssertEqual(place.floor, 1)
        // 층 높이는 지운 기준점에서 나온 값이었다. 잴 짝이 없으면 기본값으로
        // 되돌린다.
        XCTAssertEqual(place.floorHeightMeters, 3, accuracy: 0.001)

        XCTAssertTrue(place.removeFloorReference(floor: 1))
        XCTAssertNil(place.floor)
        XCTAssertNil(place.floorCalibration)
        XCTAssertNotNil(place.point)
    }

    /// 기준을 고치면 그 기준으로 매긴 지난 기록도 다시 매긴다. 원본 표본이
    /// 남아 있는 기록만 손댄다.
    func testReapplyingFloorsRecomputesStoredStayFromNewReference() {
        let base = makeDate(2026, 8, 5, 9, 0)
        let groundPressure = 101.0
        var place = FrequentPlace(kind: .company)
        let here = makeAltitudeReading(
            at: base,
            pressureKilopascals: groundPressure
        )
        place.calibrateCurrentFloor(to: 2, from: here)

        let span = TimeSpan(start: base, end: base.addingTimeInterval(3_600))
        let stay = PlaceStay(
            placeKey: place.stablePlaceKey,
            displayName: "회사",
            floor: 19,
            span: span,
            confidence: .high,
            point: here.point,
            isConfirmed: true
        )
        let elsewhere = PlaceStay(
            placeKey: "other",
            displayName: "다른 곳",
            floor: 19,
            span: span,
            confidence: .high,
            point: here.point,
            isConfirmed: true
        )

        let recomputed = FrequentPlaceResolutionEngine().reapplyingFloors(
            of: place,
            to: [stay, elsewhere],
            readings: [here]
        )

        XCTAssertEqual(recomputed[0].floor, 2)
        // 다른 장소의 기록은 이 보정과 무관하다.
        XCTAssertEqual(recomputed[1].floor, 19)
    }

    /// 원본 표본이 이미 지워진 기록은 다시 구할 방법이 없다. 지어내느니
    /// 그대로 둔다.
    func testReapplyingFloorsLeavesRecordsWithoutRawSamplesAlone() {
        let base = makeDate(2026, 8, 5, 9, 0)
        var place = FrequentPlace(kind: .company)
        place.calibrateCurrentFloor(
            to: 2,
            from: makeAltitudeReading(at: base, pressureKilopascals: 101.0)
        )
        let old = PlaceStay(
            placeKey: place.stablePlaceKey,
            displayName: "회사",
            floor: 19,
            span: TimeSpan(
                start: base.addingTimeInterval(-30 * 86_400),
                end: base.addingTimeInterval(-30 * 86_400 + 3_600)
            ),
            confidence: .high,
            isConfirmed: true
        )

        let recomputed = FrequentPlaceResolutionEngine().reapplyingFloors(
            of: place,
            to: [old],
            readings: []
        )

        XCTAssertEqual(recomputed, [old])
    }

    /// 기압 원본이 만료된 과거 기록도 대표 GPS 고도를 가지고 있으면 새 층
    /// 기준으로 다시 표시한다. 좌표와 고도 원본은 그대로 보존한다.
    func testReapplyingFloorsUsesStoredPointForPastStay() {
        let base = makeDate(2026, 8, 5, 9, 0)
        let reference = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 60,
            horizontalAccuracy: 8,
            verticalAccuracy: 8
        )
        var place = FrequentPlace(kind: .company)
        place.calibrateCurrentFloor(
            to: 2,
            from: SensorReading(timestamp: base, point: reference)
        )
        let pastPoint = GeoPoint(
            latitude: reference.latitude,
            longitude: reference.longitude,
            altitude: 66,
            horizontalAccuracy: 8,
            verticalAccuracy: 8
        )
        let past = PlaceStay(
            placeKey: place.stablePlaceKey,
            displayName: "회사",
            floor: 19,
            span: TimeSpan(
                start: base.addingTimeInterval(-90 * 86_400),
                end: base.addingTimeInterval(-90 * 86_400 + 3_600)
            ),
            confidence: .high,
            point: pastPoint,
            isConfirmed: true
        )

        let recomputed = FrequentPlaceResolutionEngine().reapplyingFloors(
            of: place,
            to: [past],
            readings: []
        )[0]

        XCTAssertEqual(recomputed.floor, 4)
        XCTAssertEqual(recomputed.point, pastPoint)
    }

    /// 기록이 스스로 근거를 지니고 있으면 원본 표본 보관 기간과 상관없이
    /// 다시 매긴다. 근거가 없는 옆 기록은 그대로 둔다.
    func testReapplyingFloorsPrefersStoredEvidenceOverArchive() {
        let base = makeDate(2026, 8, 5, 9, 0)
        let groundPressure = 101.0
        var place = FrequentPlace(kind: .company)
        place.calibrateCurrentFloor(
            to: 2,
            from: makeAltitudeReading(
                at: base,
                pressureKilopascals: groundPressure
            )
        )

        // 보관 기간(7일)을 훌쩍 넘긴 기록. 예전 기준으로 36층이 찍혀 있다.
        let long = base.addingTimeInterval(-90 * 86_400)
        let span = TimeSpan(start: long, end: long.addingTimeInterval(3_600))
        let stay = PlaceStay(
            placeKey: place.stablePlaceKey,
            displayName: "회사",
            floor: 36,
            span: span,
            confidence: .high,
            point: place.point,
            isConfirmed: true,
            floorEvidence: FloorEvidence(
                measuredAt: long,
                pressureKilopascals: pressure(groundPressure, risingBy: 51)
            )
        )
        // 기압 근거와 보관 표본은 없지만 대표 GPS 고도는 남은 더 오래된 기록.
        let older = long.addingTimeInterval(-110 * 86_400)
        let legacy = PlaceStay(
            placeKey: place.stablePlaceKey,
            displayName: "회사",
            floor: 36,
            span: TimeSpan(start: older, end: older.addingTimeInterval(3_600)),
            confidence: .high,
            point: place.point,
            isConfirmed: true
        )
        // 보관분에는 이 기록과 어긋나는 표본만 남아 있다.
        let stale = makeAltitudeReading(
            at: long.addingTimeInterval(60),
            pressureKilopascals: groundPressure
        )

        let engine = FrequentPlaceResolutionEngine()
        for readings: [SensorReading] in [[], [stale]] {
            let recomputed = engine.reapplyingFloors(
                of: place,
                to: [stay, legacy],
                readings: readings
            )
            // 2층 기준에서 51m 위, 층 높이 3m이면 19층이다. 보관분이 비어
            // 있든 엉뚱한 표본이 남아 있든 답은 기록이 지닌 근거에서 나온다.
            XCTAssertEqual(recomputed[0].floor, 19)
            // 대표 GPS 고도는 낮은 신뢰도의 원본 근거다. 기준점과 같은
            // 고도이므로 새 2층 기준으로 다시 표시한다.
            XCTAssertEqual(recomputed[1].floor, 2)
            XCTAssertEqual(recomputed[1].point, legacy.point)
        }
    }

    /// 상대고도의 0점은 기압 세션마다 새로 잡힌다. 저장된 근거의 세션이
    /// 기준점과 다르면 두 값을 빼서는 안 된다.
    func testStoredFloorEvidenceIsNotDifferencedAcrossAltimeterSessions() {
        let base = makeDate(2026, 8, 5, 9, 0)
        let session = UUID()
        let anchor = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 82,
            horizontalAccuracy: 8,
            verticalAccuracy: 6
        )
        var place = FrequentPlace(kind: .home)
        place.calibrateCurrentFloor(
            to: 3,
            from: SensorReading(
                timestamp: base,
                point: anchor,
                relativeAltitudeMeters: 0,
                altimeterSessionID: session
            )
        )
        var stay = PlaceStay(
            placeKey: place.stablePlaceKey,
            displayName: "집",
            floor: 3,
            span: TimeSpan(
                start: base.addingTimeInterval(-40 * 86_400),
                end: base.addingTimeInterval(-40 * 86_400 + 3_600)
            ),
            confidence: .high,
            point: anchor,
            isConfirmed: true
        )
        let engine = FrequentPlaceResolutionEngine()

        // 같은 세션이면 51m 차이가 그대로 17층으로 읽힌다.
        stay.floorEvidence = FloorEvidence(
            measuredAt: stay.span.start,
            relativeAltitudeMeters: 51,
            altimeterSessionID: session
        )
        XCTAssertEqual(
            engine.reapplyingFloors(of: place, to: [stay], readings: [])[0]
                .floor,
            20
        )

        // 세션이 다르면 그 51m는 견줄 수 없는 값이다. 남은 것은 GPS 고도뿐이고
        // 두 지점의 고도가 같으므로 층수는 움직이지 않는다.
        stay.floorEvidence = FloorEvidence(
            measuredAt: stay.span.start,
            relativeAltitudeMeters: 51,
            altimeterSessionID: UUID()
        )
        XCTAssertEqual(
            engine.reapplyingFloors(of: place, to: [stay], readings: [])[0]
                .floor,
            3
        )
    }

    /// 예전 빌드가 쓴 보관 파일에는 근거 필드가 없다. 그대로 읽히고, 근거는
    /// 없는 채로 남아야 한다.
    func testPlaceRecordsDecodeArchivesWrittenBeforeFloorEvidence() throws {
        let base = makeDate(2026, 8, 5, 9, 0)
        let span = TimeSpan(start: base, end: base.addingTimeInterval(3_600))
        let evidence = FloorEvidence(
            measuredAt: base,
            pressureKilopascals: 101.0,
            altimeterSessionID: UUID()
        )
        let stay = PlaceStay(
            placeKey: "frequent-1",
            displayName: "회사",
            floor: 19,
            span: span,
            confidence: .high,
            isConfirmed: true,
            floorEvidence: evidence
        )
        let transition = FloorTransition(
            id: UUID(),
            placeKey: "frequent-1",
            fromFloor: 1,
            toFloor: 19,
            relativeAltitudeMeters: 54,
            span: span,
            confidence: .medium,
            evidence: ["기압 고도 센서"],
            floorEvidence: evidence
        )

        let decodedStay = try JSONDecoder().decode(
            PlaceStay.self,
            from: try legacyData(from: stay, without: "floorEvidence")
        )
        let decodedTransition = try JSONDecoder().decode(
            FloorTransition.self,
            from: try legacyData(from: transition, without: "floorEvidence")
        )

        XCTAssertNil(decodedStay.floorEvidence)
        XCTAssertEqual(decodedStay.floor, 19)
        XCTAssertEqual(decodedStay.displayName, "회사")
        XCTAssertNil(decodedTransition.floorEvidence)
        XCTAssertEqual(decodedTransition.fromFloor, 1)
        XCTAssertEqual(decodedTransition.toFloor, 19)
    }

    /// 표본 하나가 튀어도 가운데값은 흔들리지 않는다. 튄 값은 양끝을 덜어 낸
    /// 품질 판정에서도 빠진다.
    func testAltitudeBurstReducerTakesMedianAndSurvivesOneOutlier() {
        let base = makeDate(2026, 8, 5, 9, 0)
        let samples = burstSamples(
            [0.02, -0.03, 0, 0.05, -0.01, 0.03, 0.01, 12, -0.02, 0, 0.04, -0.04],
            session: UUID(),
            from: base
        )

        guard case let .reduced(reduced, spread) =
            AltitudeBurstReducer.reduce(samples) else {
            return XCTFail("한 표본이 튀었다고 묶음 전체를 버리면 안 된다")
        }
        XCTAssertEqual(reduced.relativeAltitudeMeters ?? 99, 0.005, accuracy: 0.001)
        XCTAssertLessThan(spread, 0.2)
    }

    /// 계단을 오르며 잰 묶음처럼 표본이 서로 어긋나면 기준으로 남기지
    /// 않는다. 잘못 박힌 기준점은 이 건물의 모든 층 추정을 망친다.
    func testAltitudeBurstReducerRejectsMovingBurst() {
        let base = makeDate(2026, 8, 5, 9, 0)
        let samples = burstSamples(
            [0, 0.4, 0.9, 1.4, 1.9, 2.4, 2.9, 3.4, 3.9, 4.4, 4.9, 5.4],
            session: UUID(),
            from: base
        )

        guard case let .tooNoisy(spread) =
            AltitudeBurstReducer.reduce(samples) else {
            return XCTFail("흔들리는 묶음을 기준으로 남기면 안 된다")
        }
        XCTAssertGreaterThan(spread, AltitudeBurstReducer.maximumSpreadMeters)
    }

    /// 표본이 모자라면 아무것도 기록하지 않는다. 한두 표본으로 남긴 기준은
    /// 고치기 전 동작과 다르지 않다.
    func testAltitudeBurstReducerNeedsEnoughSamples() {
        let base = makeDate(2026, 8, 5, 9, 0)
        let samples = burstSamples([0, 0.01, -0.01, 0], session: UUID(), from: base)

        XCTAssertEqual(
            AltitudeBurstReducer.reduce(samples),
            .tooFewSamples(collected: 4)
        )
        XCTAssertEqual(
            AltitudeBurstReducer.reduce([]),
            .tooFewSamples(collected: 0)
        )
    }

    /// 기압 세션이 끊기면 상대고도의 0점이 새로 잡힌다. 앞뒤를 섞어 평균
    /// 내면 없던 층이 생기므로 마지막 세션만 쓴다.
    func testAltitudeBurstReducerDropsSamplesFromAnEarlierSession() {
        let base = makeDate(2026, 8, 5, 9, 0)
        let stale = burstSamples(
            [50, 50.1, 49.9, 50, 50.2, 49.8, 50],
            session: UUID(),
            from: base
        )
        let fresh = burstSamples(
            [0, 0.1, -0.1, 0, 0.2, -0.2, 0, 0.1],
            session: UUID(),
            from: base.addingTimeInterval(60)
        )

        guard case let .reduced(reduced, _) =
            AltitudeBurstReducer.reduce(stale + fresh) else {
            return XCTFail("마지막 세션만으로도 충분한 표본이 있다")
        }
        XCTAssertEqual(reduced.relativeAltitudeMeters ?? 99, 0, accuracy: 0.001)
    }

    // MARK: - 어플 목록에서 iOS 내부 서비스 감추기

    /// 한 주에 세 번이면 조건 하나만으로 충분하다.
    func testUnregisteredPlaceSuggestionTriggersOnThreeVisitsInOneWeek() {
        let base = makeDate(2026, 8, 1, 10)
        let stays = makeCafeVisits(from: base, dayOffsets: [0, 2, 4])

        let suggestion = UnregisteredPlaceSuggestionEngine().suggestion(
            places: stays,
            frequentPlaces: FrequentPlace.defaults,
            dismissed: [],
            now: base.addingTimeInterval(4 * 86_400 + 2 * 3_600)
        )

        XCTAssertEqual(Set(stays.map(\.placeKey)).count, 3)
        XCTAssertEqual(suggestion?.visitCount, 3)
        XCTAssertEqual(suggestion?.reason, .weekly)
        // 역지오코딩 이름이 없으면 이름을 지어내지 않는다.
        XCTAssertNil(suggestion?.suggestedName)
    }

    func testUnregisteredPlaceSuggestionTieUsesStableIDRegardlessOfInputOrder() {
        let base = makeDate(2026, 8, 1, 10)
        let stays = [0.0, 2.0, 4.0].flatMap { offset in
            [
                makeVisitStay(
                    latitude: 37.5000,
                    longitude: 127,
                    start: base.addingTimeInterval(offset * 86_400)
                ),
                makeVisitStay(
                    latitude: 37.5100,
                    longitude: 127,
                    start: base.addingTimeInterval(offset * 86_400)
                ),
            ]
        }
        let engine = UnregisteredPlaceSuggestionEngine()
        let now = base.addingTimeInterval(4 * 86_400 + 2 * 3_600)
        let forward = engine.suggestion(
            places: stays,
            frequentPlaces: [],
            dismissed: [],
            now: now
        )
        let reversed = engine.suggestion(
            places: Array(stays.reversed()),
            frequentPlaces: [],
            dismissed: [],
            now: now
        )

        XCTAssertEqual(forward?.id, "suggested-37.5000,127.0000")
        XCTAssertEqual(reversed?.id, forward?.id)
        XCTAssertEqual(forward?.visitCount, 3)
    }

    func testUnregisteredPlaceClustersEquidistantStayByStableOrder() {
        let base = makeDate(2026, 8, 1, 10)
        let stays = [
            makeVisitStay(latitude: 37.5000, longitude: 127, start: base),
            makeVisitStay(
                latitude: 37.5012,
                longitude: 127,
                start: base
            ),
            makeVisitStay(
                latitude: 37.5000,
                longitude: 127,
                start: base.addingTimeInterval(2 * 86_400)
            ),
            makeVisitStay(
                latitude: 37.5012,
                longitude: 127,
                start: base.addingTimeInterval(2 * 86_400)
            ),
            makeVisitStay(
                latitude: 37.5006,
                longitude: 127,
                start: base.addingTimeInterval(4 * 86_400)
            ),
        ]
        let now = base.addingTimeInterval(4 * 86_400 + 2 * 3_600)
        let engine = UnregisteredPlaceSuggestionEngine()
        let forward = engine.suggestion(
            places: stays,
            frequentPlaces: [],
            dismissed: [],
            now: now
        )
        let reversed = engine.suggestion(
            places: Array(stays.reversed()),
            frequentPlaces: [],
            dismissed: [],
            now: now
        )

        XCTAssertEqual(forward?.id, "suggested-37.5002,127.0000")
        XCTAssertEqual(reversed?.id, forward?.id)
        XCTAssertEqual(forward?.visitCount, 3)
    }

    /// 한 달에 열 번이면, 어느 한 주도 세 번에 못 미쳐도 조건을 넘긴다.
    func testUnregisteredPlaceSuggestionTriggersOnTenMonthlyVisitsWithNoWeeklyRun() {
        let base = makeDate(2026, 7, 1, 10)
        let offsets = [
            0.0, 0.25, 7.25, 7.5, 14.5, 14.75, 21.75, 22.0, 29.0, 29.25,
        ]
        let stays = makeCafeVisits(from: base, dayOffsets: offsets)

        let engine = UnregisteredPlaceSuggestionEngine()
        let now = base.addingTimeInterval(29.25 * 86_400 + 2 * 3_600)
        let suggestion = engine.suggestion(
            places: stays,
            frequentPlaces: FrequentPlace.defaults,
            dismissed: [],
            now: now
        )

        // 어떤 7일 창에도 세 번이 들어가지 않는다는 것을 먼저 확인한다.
        let starts = stays.map(\.span.start).sorted()
        for index in 0...(starts.count - 3) {
            XCTAssertGreaterThan(
                starts[index + 2].timeIntervalSince(starts[index]),
                engine.weeklyWindow
            )
        }
        XCTAssertEqual(suggestion?.visitCount, 10)
        XCTAssertEqual(suggestion?.reason, .monthly)
    }

    /// 한 주 두 번, 한 달 아홉 번은 어느 조건도 넘지 못한다.
    func testUnregisteredPlaceSuggestionStaysSilentBelowBothThresholds() {
        let base = makeDate(2026, 7, 1, 10)
        let offsets = [0.0, 0.25, 7.25, 7.5, 14.5, 14.75, 21.75, 22.0, 29.0]
        let stays = makeCafeVisits(from: base, dayOffsets: offsets)

        let suggestion = UnregisteredPlaceSuggestionEngine().suggestion(
            places: stays,
            frequentPlaces: FrequentPlace.defaults,
            dismissed: [],
            now: base.addingTimeInterval(29.0 * 86_400 + 2 * 3_600)
        )

        XCTAssertEqual(stays.count, 9)
        XCTAssertNil(suggestion)
    }

    /// 이미 등록한 곳은 묻지 않는다. 자동 기록을 꺼 두어 체류가 자주가는 곳
    /// 키로 바뀌지 않는 경우에도 그렇다.
    func testUnregisteredPlaceSuggestionSkipsAlreadyRegisteredPlace() {
        let base = makeDate(2026, 8, 1, 10)
        let stays = makeCafeVisits(from: base, dayOffsets: [0, 1, 2, 3, 4])
        let now = base.addingTimeInterval(4 * 86_400 + 2 * 3_600)
        let engine = UnregisteredPlaceSuggestionEngine()
        let registered = FrequentPlace(
            kind: .hobby,
            point: GeoPoint(
                latitude: 37.5001,
                longitude: 127.0001,
                altitude: 30,
                horizontalAccuracy: 10,
                verticalAccuracy: 8
            ),
            floor: 1,
            isAutomaticRecordingEnabled: false
        )

        XCTAssertNotNil(
            engine.suggestion(
                places: stays,
                frequentPlaces: [],
                dismissed: [],
                now: now
            )
        )
        XCTAssertNil(
            engine.suggestion(
                places: stays,
                frequentPlaces: [registered],
                dismissed: [],
                now: now
            )
        )
    }

    /// 한 번 거절한 곳은 다시 묻지 않는다.
    func testUnregisteredPlaceSuggestionNeverReturnsDismissedPlace() {
        let base = makeDate(2026, 8, 1, 10)
        let stays = makeCafeVisits(from: base, dayOffsets: [0, 1, 2, 3, 4])
        let now = base.addingTimeInterval(4 * 86_400 + 2 * 3_600)
        let engine = UnregisteredPlaceSuggestionEngine()
        // 다음 주에 중심점이 몇십 미터 흔들려도 같은 거절이어야 한다.
        let dismissed = DismissedPlaceSuggestion(
            point: GeoPoint(
                latitude: 37.5005,
                longitude: 127.0000,
                altitude: 30,
                horizontalAccuracy: 10,
                verticalAccuracy: 8
            ),
            dismissedAt: base
        )

        XCTAssertNotNil(
            engine.suggestion(
                places: stays,
                frequentPlaces: [],
                dismissed: [],
                now: now
            )
        )
        XCTAssertNil(
            engine.suggestion(
                places: stays,
                frequentPlaces: [],
                dismissed: [dismissed],
                now: now
            )
        )
    }

    /// 방문은 도착마다 하나다. GPS 표본이 몇 개든, 한 번 머문 것은 한 번이다.
    func testUnregisteredPlaceSuggestionCountsArrivalsNotLocationSamples() {
        let base = makeDate(2026, 8, 1, 9)
        let cafe = GeoPoint(
            latitude: 37.5000,
            longitude: 127.0000,
            altitude: 30,
            horizontalAccuracy: 10,
            verticalAccuracy: 8
        )
        let home = GeoPoint(
            latitude: 37.5200,
            longitude: 127.0000,
            altitude: 30,
            horizontalAccuracy: 10,
            verticalAccuracy: 8
        )
        func readings(days: Int) -> [SensorReading] {
            var values: [SensorReading] = []
            for day in 0..<days {
                let dayStart = base.addingTimeInterval(Double(day) * 86_400)
                for step in 0..<24 {
                    values.append(
                        SensorReading(
                            timestamp: dayStart
                                .addingTimeInterval(Double(step) * 300),
                            point: cafe,
                            motion: .stationary,
                            motionConfidence: .high
                        )
                    )
                }
                for step in 0..<24 {
                    values.append(
                        SensorReading(
                            timestamp: dayStart.addingTimeInterval(
                                8 * 3_600 + Double(step) * 300
                            ),
                            point: home,
                            motion: .stationary,
                            motionConfidence: .high
                        )
                    )
                }
            }
            return values
        }
        // 집은 이미 등록했으므로 제안 후보가 아니다.
        let registered = FrequentPlace(kind: .home, point: home)
        let engine = UnregisteredPlaceSuggestionEngine()
        let detector = PlaceDetectionEngine()

        let oneArrival = detector.detectStays(readings: readings(days: 1))
        let cafeStays = oneArrival.filter { stay in
            guard let point = stay.point else { return false }
            return distanceMeters(point, cafe) <= 70
        }
        XCTAssertEqual(
            cafeStays.count,
            1,
            "표본 24개짜리 한 번의 체류는 체류 하나여야 한다"
        )
        XCTAssertNil(
            engine.suggestion(
                places: oneArrival,
                frequentPlaces: [registered],
                dismissed: [],
                now: base.addingTimeInterval(12 * 3_600)
            )
        )

        let threeArrivals = detector.detectStays(readings: readings(days: 3))
        let suggestion = engine.suggestion(
            places: threeArrivals,
            frequentPlaces: [registered],
            dismissed: [],
            now: base.addingTimeInterval(3 * 86_400)
        )
        XCTAssertEqual(suggestion?.visitCount, 3)
        XCTAssertEqual(
            suggestion?.point.latitude ?? 0,
            cafe.latitude,
            accuracy: 0.0001
        )
    }

    /// 층 이동으로 한 번의 체류가 여러 조각으로 갈라져도 방문은 한 번이다.
    func testUnregisteredPlaceSuggestionMergesContiguousStaySegments() {
        let base = makeDate(2026, 8, 1, 9)
        let split = (0..<3).map { index in
            makeVisitStay(
                latitude: 37.5000,
                longitude: 127.0000,
                start: base.addingTimeInterval(Double(index) * 40 * 60),
                minutes: 40
            )
        }
        let other = makeVisitStay(
            latitude: 37.5001,
            longitude: 127.0001,
            start: base.addingTimeInterval(2 * 86_400)
        )

        let suggestion = UnregisteredPlaceSuggestionEngine().suggestion(
            places: split + [other],
            frequentPlaces: [],
            dismissed: [],
            now: base.addingTimeInterval(2 * 86_400 + 2 * 3_600)
        )

        XCTAssertEqual(split.count + 1, 4)
        XCTAssertNil(suggestion, "조각 세 개는 방문 한 번이므로 두 번뿐이다")
    }

    /// 역지오코딩으로 이미 받아 둔 이름만 제안한다.
    func testUnregisteredPlaceSuggestionOffersOnlyReverseGeocodedNames() {
        let base = makeDate(2026, 8, 1, 10)
        var stays = makeCafeVisits(from: base, dayOffsets: [0, 2, 4])
        stays[0].displayName = "장소 · 3층 추정"
        stays[1].displayName = "동네 도서관"
        stays[2].displayName = "동네 도서관"

        let suggestion = UnregisteredPlaceSuggestionEngine().suggestion(
            places: stays,
            frequentPlaces: [],
            dismissed: [],
            now: base.addingTimeInterval(4 * 86_400 + 2 * 3_600)
        )

        XCTAssertEqual(suggestion?.suggestedName, "동네 도서관")
    }

    /// 자주가는 곳에서 지운 자리는 다시 제안하지 않는다.
    @MainActor
    func testDeletingFrequentPlaceRemembersItAsDismissedSuggestion() async {
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 30,
            horizontalAccuracy: 10,
            verticalAccuracy: 8
        )
        var stored = TaptionDataSnapshot.empty
        let place = FrequentPlace(kind: .hobby, name: "동네 도서관", point: point)
        stored.settings.frequentPlaces = [place]
        let model = AppModel(
            repository: InMemoryPlanRepository(snapshot: stored),
            cloudSyncService: nil
        )
        await model.bootstrap()

        model.deleteFrequentPlace(place.id)

        XCTAssertEqual(
            model.snapshot.settings.dismissedPlaceSuggestions.count,
            1
        )
        XCTAssertNil(
            UnregisteredPlaceSuggestionEngine().suggestion(
                places: makeCafeVisits(
                    from: makeDate(2026, 8, 1, 10),
                    dayOffsets: [0, 1, 2, 3]
                ),
                frequentPlaces: [],
                dismissed: model.snapshot.settings.dismissedPlaceSuggestions,
                now: makeDate(2026, 8, 5, 10)
            )
        )
    }

    /// 거절 기록은 기기 위치 기록에서만 나온다. iCloud로 나가지 않고, 기기
    /// 저장본에는 그대로 남는다.
    func testDismissedPlaceSuggestionsSurviveSettingsEncoding() throws {
        var settings = AppFeatureSettings.defaults
        settings.dismissedPlaceSuggestions = [
            DismissedPlaceSuggestion(
                point: GeoPoint(
                    latitude: 37.5,
                    longitude: 127,
                    altitude: 30,
                    horizontalAccuracy: 10,
                    verticalAccuracy: 8
                ),
                dismissedAt: makeDate(2026, 8, 1, 10)
            )
        ]

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(
            AppFeatureSettings.self,
            from: data
        )

        XCTAssertEqual(
            decoded.dismissedPlaceSuggestions,
            settings.dismissedPlaceSuggestions
        )
    }

}
