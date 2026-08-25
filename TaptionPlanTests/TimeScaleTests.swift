import MapKit
import SwiftUI
import XCTest
@testable import TaptionPlan

final class TimeScaleTests: XCTestCase {
    func testEveryScaleHasAxisLabels() {
        for scale in TimeScale.allCases {
            XCTAssertFalse(scale.axisLabels.isEmpty)
        }
    }

    func testScheduleUsesDayWeekMonthAndNormalizesYearToMonth() {
        XCTAssertEqual(TimeScale.scheduleCases, [.day, .week, .month])
        XCTAssertEqual(TimeScale.year.scheduleEquivalent, .month)
        XCTAssertNil(TimeScale.month.scheduleBroader)
        XCTAssertEqual(TimeScale.week.scheduleBroader, .month)
        XCTAssertFalse(TimelineZoomPreset.scheduleCases.contains(.oneYear))
    }

    func testCircularActivityLabelsUseTheirClockQuadrant() {
        XCTAssertEqual(
            CircularActivityLabelQuadrant(clockFraction: 0),
            .topRight
        )
        XCTAssertEqual(
            CircularActivityLabelQuadrant(clockFraction: 0.249_999),
            .topRight
        )
        XCTAssertEqual(
            CircularActivityLabelQuadrant(clockFraction: 0.25),
            .bottomRight
        )
        XCTAssertEqual(
            CircularActivityLabelQuadrant(clockFraction: 0.5),
            .bottomLeft
        )
        XCTAssertEqual(
            CircularActivityLabelQuadrant(clockFraction: 0.75),
            .topLeft
        )
        XCTAssertEqual(
            CircularActivityLabelQuadrant(clockFraction: 0.999_999),
            .topLeft
        )
        XCTAssertEqual(
            CircularActivityLabelQuadrant(clockFraction: 1),
            .topRight
        )
    }

    func testCircularActivityLabelPagingMovesInOrderAndStopsAtEnds() {
        XCTAssertEqual(
            CircularActivityLabelPaging.index(
                movingBy: -1,
                from: 0,
                count: 3
            ),
            0
        )
        XCTAssertEqual(
            CircularActivityLabelPaging.index(
                movingBy: 1,
                from: 0,
                count: 3
            ),
            1
        )
        XCTAssertEqual(
            CircularActivityLabelPaging.index(
                movingBy: 1,
                from: 1,
                count: 3
            ),
            2
        )
        XCTAssertEqual(
            CircularActivityLabelPaging.index(
                movingBy: 1,
                from: 2,
                count: 3
            ),
            2
        )
    }

    func testQuickActivitySelectionOpensForUnclassifiedActivityOnly() {
        let stay = ActualRecord(
            planID: nil,
            title: "머무름",
            categoryID: "activity",
            startedAt: .now,
            endedAt: .now.addingTimeInterval(60),
            source: .location,
            behavior: StationaryContextKind.unknownStay.rawValue
        )
        let walking = ActualRecord(
            planID: nil,
            title: "걷기",
            categoryID: "activity",
            startedAt: .now,
            endedAt: .now.addingTimeInterval(60),
            source: .motion,
            behavior: WatchBehaviorKind.walking.rawValue
        )
        let namedActivity = ActualRecord(
            planID: nil,
            title: "출근준비",
            categoryID: "activity",
            startedAt: .now,
            endedAt: .now.addingTimeInterval(60),
            source: .manual
        )

        XCTAssertTrue(ActivityQuickSelectionPolicy.needsSelection(stay))
        XCTAssertFalse(ActivityQuickSelectionPolicy.needsSelection(walking))
        XCTAssertFalse(
            ActivityQuickSelectionPolicy.needsSelection(namedActivity)
        )
    }

    func testQuickActivitySelectionExcludesPlaceholderOptions() {
        let placeholder = ActivityCorrectionOption(
            id: "placeholder",
            title: "활동",
            behavior: WatchBehaviorKind.unknown.rawValue,
            categoryID: "activity",
            systemImage: "sparkles",
            isAutomatic: true,
            isCustom: false
        )
        let detailed = ActivityCorrectionOption.custom("독서")

        XCTAssertFalse(
            ActivityQuickSelectionPolicy.isDetailedOption(placeholder)
        )
        XCTAssertTrue(
            ActivityQuickSelectionPolicy.isDetailedOption(detailed)
        )
    }

    func testCircularClockTapChoosesNearestVisibleBand() {
        let outer = 138.0
        let phaseWidth = 12.0
        let gap = 3.5
        let activityWidth = 20.0
        let phaseCenter = outer - phaseWidth / 2
        let activityCenter = outer - phaseWidth - gap - activityWidth / 2

        XCTAssertEqual(
            CircularClockTapBand.resolve(
                distance: phaseCenter,
                outerRadius: outer,
                phaseBandWidth: phaseWidth,
                bandGap: gap,
                activityBandWidth: activityWidth
            ),
            .phase
        )
        XCTAssertEqual(
            CircularClockTapBand.resolve(
                distance: activityCenter,
                outerRadius: outer,
                phaseBandWidth: phaseWidth,
                bandGap: gap,
                activityBandWidth: activityWidth
            ),
            .activity
        )
        XCTAssertNil(
            CircularClockTapBand.resolve(
                distance: 20,
                outerRadius: outer,
                phaseBandWidth: phaseWidth,
                bandGap: gap,
                activityBandWidth: activityWidth
            )
        )
    }

    func testContinuousDayZoomPresetsCoverOneMinuteToOneWeek() {
        XCTAssertEqual(TimelineZoomPreset.oneMinute.duration, 60)
        XCTAssertEqual(TimelineZoomPreset.oneWeek.duration, 7 * 24 * 60 * 60)
        XCTAssertEqual(
            TimelineZoomPreset.nearest(to: 60),
            .oneMinute
        )
        XCTAssertEqual(
            TimelineZoomPreset.nearest(to: 24 * 60 * 60),
            .oneDay
        )
    }

    func testTimelineInteractionFrameGateReduces240HzInputToDisplayCadence() {
        var lastUptime: TimeInterval = 0
        var renderedSamples = 0

        for sample in 0...240 {
            let uptime = Double(sample) / 240
            if TimelineInteractionFrameGate.shouldRender(
                lastUptime: &lastUptime,
                nowUptime: uptime
            ) {
                renderedSamples += 1
            }
        }

        XCTAssertGreaterThan(renderedSamples, 50)
        XCTAssertLessThanOrEqual(renderedSamples, 62)
    }

    func testTimelineInteractionFrameGateAlwaysAcceptsFinalSample() {
        var lastUptime = 10.0

        XCTAssertFalse(
            TimelineInteractionFrameGate.shouldRender(
                lastUptime: &lastUptime,
                nowUptime: 10.001
            )
        )
        XCTAssertTrue(
            TimelineInteractionFrameGate.shouldRender(
                lastUptime: &lastUptime,
                nowUptime: 10.001,
                force: true
            )
        )
        XCTAssertEqual(lastUptime, 10.001)
    }

    func testTimelineNLEProjectionCoalesces240HzInputAndFlushesLatestState() {
        let projection = TimelineNLEProjection<Int>()
        projection.begin(with: 0)
        var rendered: [Int] = []

        for sample in 1...240 {
            if let state = projection.submit(
                sample,
                nowUptime: Double(sample) / 240
            ) {
                rendered.append(state)
            }
        }

        XCTAssertGreaterThan(rendered.count, 50)
        XCTAssertLessThanOrEqual(rendered.count, 61)
        XCTAssertEqual(projection.latestState, 240)
        XCTAssertEqual(
            projection.finish(with: 241, nowUptime: 1.001),
            241
        )
        XCTAssertEqual(projection.renderedState, 241)
    }

    func testTimelineNLEProjectionSynchronizesExternalTimelineState() {
        let projection = TimelineNLEProjection<Int>()
        projection.begin(with: 600)
        projection.synchronize(with: 720)

        XCTAssertEqual(
            projection.finish(with: 600, nowUptime: 10),
            600
        )
    }

    func testMapHomeSidebarNLEProjectionCoalesces240HzDragAndFlushesFinalState() {
        let projection = TimelineNLEProjection<MapHomeTimeSidebarNLEState>()
        let initial = MapHomeTimeSidebarNLEState(
            selectedMinute: 720,
            visibleStartMinute: 690,
            visibleDurationMinutes: 60
        )
        projection.begin(with: initial)
        var renderedCount = 0

        for sample in 1...240 {
            let state = MapHomeTimeSidebarNLEState(
                selectedMinute: min(1_439, 720 + sample),
                visibleStartMinute: min(1_380, 690 + sample),
                visibleDurationMinutes: 60
            )
            if projection.submit(
                state,
                nowUptime: Double(sample) / 240
            ) != nil {
                renderedCount += 1
            }
        }

        let final = MapHomeTimeSidebarNLEState(
            selectedMinute: 961,
            visibleStartMinute: 931,
            visibleDurationMinutes: 60
        )
        XCTAssertGreaterThan(renderedCount, 50)
        XCTAssertLessThanOrEqual(renderedCount, 61)
        XCTAssertEqual(
            projection.finish(with: final, nowUptime: 1.001),
            final
        )
    }

    func testSidebarDragMovementDoesNotDependOn240HzSampleCount() {
        let handleBase = MapHomeTimeSidebarNLEState(
            selectedMinute: 720,
            visibleStartMinute: 0,
            visibleDurationMinutes: 1_440
        )
        let viewportBase = MapHomeTimeSidebarNLEState(
            selectedMinute: 720,
            visibleStartMinute: 690,
            visibleDurationMinutes: 60
        )
        let viewportProjection: (CGFloat) -> MapHomeTimeSidebarNLEState = { translation in
            MapHomeTimeSidebarViewportProjection.state(
                from: viewportBase,
                translation: translation,
                trackHeight: 600,
                verticalInset: 14,
                maxMinute: 1_439,
                sensitivity: MapHomeTimeSidebarMath.standardDragSensitivity
            )
        }

        let finalTranslation: CGFloat = 60
        let viewportAt240Hz = stride(from: 1, through: 240, by: 1)
            .map { viewportProjection(CGFloat($0) / 4) }
            .last
        let viewportAt60Hz = stride(from: 4, through: 240, by: 4)
            .map { viewportProjection(CGFloat($0) / 4) }
            .last

        XCTAssertEqual(viewportAt240Hz, viewportAt60Hz)
        XCTAssertEqual(viewportAt240Hz, viewportProjection(finalTranslation))
        XCTAssertEqual(viewportAt240Hz?.visibleStartMinute, 700)

        XCTAssertEqual(MapHomeTimeSidebarMath.standardDragSensitivity, 1.6)
        XCTAssertEqual(MapHomeTimeSidebarMath.precisionDragSensitivity, 0.25)
        for sensitivity in [
            MapHomeTimeSidebarMath.standardDragSensitivity,
            MapHomeTimeSidebarMath.precisionDragSensitivity,
        ] {
            let handleProjection: (CGFloat) -> MapHomeTimeSidebarNLEState = { translation in
                MapHomeTimeSidebarDragProjection.state(
                    from: handleBase,
                    translation: translation,
                    trackHeight: 600,
                    maxMinute: 1_439,
                    sensitivity: sensitivity
                )
            }
            let handleAt240Hz = stride(from: 1, through: 240, by: 1)
                .map { handleProjection(CGFloat($0) / 4) }
                .last
            let handleAt60Hz = stride(from: 4, through: 240, by: 4)
                .map { handleProjection(CGFloat($0) / 4) }
                .last

            XCTAssertEqual(handleAt240Hz, handleAt60Hz)
            XCTAssertEqual(handleAt240Hz, handleProjection(finalTranslation))

            guard sensitivity == MapHomeTimeSidebarMath.standardDragSensitivity else {
                continue
            }
            var incorrectlyRebased = handleBase
            for sample in 1...240 {
                incorrectlyRebased = MapHomeTimeSidebarDragProjection.state(
                    from: incorrectlyRebased,
                    translation: CGFloat(sample) / 4,
                    trackHeight: 600,
                    maxMinute: 1_439,
                    sensitivity: sensitivity
                )
            }
            XCTAssertNotEqual(incorrectlyRebased, handleProjection(finalTranslation))
        }
    }

    func testMapHomeOverlayUsesSharedBottomMarginAndUniformControlSpacing() {
        XCTAssertEqual(MapHomeOverlayLayoutMath.sharedBottomMargin, 76)
        XCTAssertEqual(MapHomeOverlayLayoutMath.controlSize, 44)
        XCTAssertEqual(MapHomeOverlayLayoutMath.controlSpacing, 9)
        XCTAssertEqual(
            MapHomeOverlayLayoutMath.controlStackHeight(buttonCount: 4),
            203
        )
        XCTAssertEqual(
            MapHomeOverlayLayoutMath.railHeight(availableHeight: 720),
            680
        )
        XCTAssertEqual(
            MapHomeOverlayLayoutMath.railHeight(availableHeight: 620),
            620
        )
        XCTAssertEqual(
            MapHomeOverlayLayoutMath.railHeight(availableHeight: 460),
            460
        )
    }

    func testMapSearchUsesMenuEdgeAndClampsForCompactScreens() {
        XCTAssertEqual(
            MapHomeSearchLayoutMath.searchWidth(
                viewportWidth: 390,
                horizontalInset: 10
            ),
            306
        )
        XCTAssertEqual(
            MapHomeSearchLayoutMath.searchWidth(
                viewportWidth: 320,
                horizontalInset: 10
            ),
            248
        )
        XCTAssertEqual(MapHomeSearchLayoutMath.playbackVisualSize, 40.74)
        XCTAssertEqual(MapHomeSearchLayoutMath.playbackTouchSize, 44)
        XCTAssertEqual(
            MapHomeSearchLayoutMath.searchWidth(
                viewportWidth: 320,
                horizontalInset: 10,
                trailingControlCount: 2
            ),
            196
        )
    }

    func testMapSearchResultsDoNotOccupyTheMapViewport() {
        XCTAssertEqual(
            MapHomeSearchLayoutMath.searchResultsHeight(resultCount: 0),
            0
        )
        XCTAssertEqual(
            MapHomeSearchLayoutMath.searchResultsHeight(resultCount: 1),
            MapHomeSearchLayoutMath.searchRowHeight
        )
        XCTAssertEqual(
            MapHomeSearchLayoutMath.searchResultsHeight(resultCount: 20),
            MapHomeSearchLayoutMath.searchResultsMaximumHeight
        )
    }

    func testMapSearchLayerCoversMapChromeButStaysBelowMenu() {
        XCTAssertGreaterThan(MapHomeLayerPriority.search, MapHomeLayerPriority.sidebar)
        XCTAssertGreaterThan(MapHomeLayerPriority.search, MapHomeLayerPriority.map)
        XCTAssertGreaterThan(MapHomeLayerPriority.menu, MapHomeLayerPriority.search)
        XCTAssertGreaterThan(MapHomeLayerPriority.header, MapHomeLayerPriority.menu)
    }

    func testWeatherMovesOnlyForAnIntersectingPlayhead() {
        let weather = CGRect(x: 1, y: 100, width: 56, height: 30)
        let intersectingPlayhead = CGRect(x: 24, y: 90, width: 44, height: 44)
        XCTAssertEqual(
            MapHomeWeatherCollisionMath.horizontalOffset(
                weatherFrame: weather,
                playheadFrame: intersectingPlayhead
            ),
            -37
        )
        XCTAssertEqual(
            MapHomeWeatherCollisionMath.horizontalOffset(
                weatherFrame: weather,
                playheadFrame: CGRect(x: 24, y: 140, width: 44, height: 44)
            ),
            0
        )
    }

    func testWeatherAlignsWithPlayheadAndKeepsClearanceWhenSidebarIsHidden() {
        let playhead = CGRect(x: 24, y: 90, width: 44, height: 44)
        let weather = MapHomeWeatherCollisionMath.alignedWeatherFrame(
            centerX: playhead.midX,
            playheadFrame: playhead
        )
        let offset = MapHomeWeatherCollisionMath.horizontalOffset(
            weatherFrame: weather,
            playheadFrame: playhead
        )
        let shiftedWeather = weather.offsetBy(dx: offset, dy: 0)

        XCTAssertEqual(weather.midY, playhead.midY)
        XCTAssertEqual(
            shiftedWeather.maxX,
            playhead.minX - MapHomeWeatherCollisionMath.clearance
        )
    }

    func testWeatherTimelineRightEdgeAttachesToActivityRail() {
        let weatherRailWidth: CGFloat = 58
        let timeRailWidth: CGFloat = 58
        let originX = MapHomeWeatherRailAlignmentMath.weatherOriginX(
            weatherRailWidth: weatherRailWidth,
            timeRailWidth: timeRailWidth
        )
        let trackX = MapHomeTimeSidebarMath.trackCenterX(
            railOriginX: MapHomeTimeSidebarMath.handleLaneWidth,
            railWidth: timeRailWidth,
            numericColumnWidth: MapHomeTimeSidebarMath.rulerNumericColumnWidth,
            activeRailWidth: MapHomeTimeSidebarMath.activeRailWidth
        )
        let weatherItemRightX = originX + weatherRailWidth - 1

        XCTAssertEqual(
            weatherItemRightX,
            trackX
                - MapHomeTimeSidebarMath.activeRailWidth / 2
                - MapHomeWeatherCollisionMath.clearance
        )
    }

    func testWeatherTimelineUsesTheActualHandleForCollision() {
        let weatherOriginX = MapHomeWeatherRailAlignmentMath.weatherOriginX(
            weatherRailWidth: 58,
            timeRailWidth: 58
        )
        let localHandleCenterX = MapHomeWeatherRailAlignmentMath.playheadCenterX(
            weatherOriginX: weatherOriginX,
            timeRailWidth: 58
        )
        let weather = CGRect(x: 1, y: 100, width: 56, height: 30)
        let playhead = CGRect(
            x: localHandleCenterX
                - MapHomeTimeSidebarMath.handleVisualSize.width / 2,
            y: 93,
            width: MapHomeTimeSidebarMath.handleVisualSize.width,
            height: MapHomeTimeSidebarMath.handleVisualSize.height
        )
        let shifted = weather.offsetBy(
            dx: MapHomeWeatherCollisionMath.horizontalOffset(
                weatherFrame: weather,
                playheadFrame: playhead
            ),
            dy: 0
        )

        XCTAssertEqual(
            shifted.maxX,
            playhead.minX - MapHomeWeatherCollisionMath.clearance
        )
    }

    func testSidebarRulerFontGrowsAcrossAllZoomSteps() {
        XCTAssertEqual(
            MapHomeTimeSidebarMath.zoomDurations.map {
                MapHomeTimeSidebarMath.rulerFontSize(durationMinutes: $0)
            },
            [10, 11, 12, 13, 14]
        )
        XCTAssertLessThanOrEqual(
            MapHomeTimeSidebarMath.rulerTickWidth
                + MapHomeTimeSidebarMath.rulerColumnWidth(durationMinutes: 60) * 2
                + MapHomeTimeSidebarMath.rulerColumnSpacing,
            MapHomeTimeSidebarMath.rulerNumericColumnWidth
        )
    }

    func testCurrentLocationTargetUsesVisibleMapCenter() {
        let viewport = CGSize(width: 390, height: 844)
        let target = MapHomeCameraLayoutMath.targetPoint(
            viewportSize: viewport,
            searchBottom: 98,
            sidebarLeft: 264
        )
        XCTAssertEqual(target.x, 132)
        XCTAssertEqual(target.y, 471)

        let source = MapHomeCameraLayoutMath.cameraCenterSourcePoint(
            currentLocationPoint: CGPoint(x: 180, y: 500),
            targetPoint: target,
            viewportSize: viewport
        )
        XCTAssertEqual(source.x, 243)
        XCTAssertEqual(source.y, 451)
        XCTAssertTrue(
            MapHomeCameraLayoutMath.isCentered(
                locationPoint: CGPoint(x: 140, y: 476),
                targetPoint: target
            )
        )
        XCTAssertFalse(
            MapHomeCameraLayoutMath.isCentered(
                locationPoint: CGPoint(x: 170, y: 500),
                targetPoint: target
            )
        )
    }

    func testMapLongPressExcludesControlsAndTheirTouchPadding() {
        let controls = CGRect(x: 10, y: 560, width: 44, height: 203)

        XCTAssertFalse(
            MapHomeLongPressRoutingMath.shouldPresentLocation(
                at: CGPoint(x: 32, y: 650),
                excluding: controls
            )
        )
        XCTAssertFalse(
            MapHomeLongPressRoutingMath.shouldPresentLocation(
                at: CGPoint(x: 58, y: 650),
                excluding: controls
            )
        )
        XCTAssertTrue(
            MapHomeLongPressRoutingMath.shouldPresentLocation(
                at: CGPoint(x: 90, y: 650),
                excluding: controls
            )
        )
    }

    func testMapZoomReachesBothDistanceLimitsAndPreservesAnchor() {
        var distance: CLLocationDistance = 12_000
        for _ in 0..<100 {
            distance = MapHomeCameraZoomMath.distance(from: distance, direction: 1)
        }
        XCTAssertEqual(distance, MapHomeCameraZoomMath.minimumDistance)
        XCTAssertTrue(MapHomeCameraZoomMath.isAtLimit(distance: distance, direction: 1))

        for _ in 0..<100 {
            distance = MapHomeCameraZoomMath.distance(from: distance, direction: -1)
        }
        XCTAssertEqual(distance, MapHomeCameraZoomMath.maximumDistance)
        XCTAssertTrue(MapHomeCameraZoomMath.isAtLimit(distance: distance, direction: -1))

        let center = CLLocationCoordinate2D(latitude: 37.5, longitude: 127)
        let anchor = CLLocationCoordinate2D(latitude: 37.6, longitude: 127.2)
        let zoomedCenter = MapHomeCameraZoomMath.centerPreservingAnchor(
            cameraCenter: center,
            anchor: anchor,
            oldDistance: 1_000,
            newDistance: 500
        )
        let centerPoint = MKMapPoint(center)
        let anchorPoint = MKMapPoint(anchor)
        let zoomedPoint = MKMapPoint(zoomedCenter)
        XCTAssertEqual(
            zoomedPoint.x,
            (centerPoint.x + anchorPoint.x) / 2,
            accuracy: 0.01
        )
        XCTAssertEqual(
            zoomedPoint.y,
            (centerPoint.y + anchorPoint.y) / 2,
            accuracy: 0.01
        )
    }

    func testMapHomeSidebarPinchTraversesSeveralZoomStepsPerGesture() {
        XCTAssertEqual(
            MapHomeTimeSidebarPinchMath.stepOffset(magnification: 1),
            0
        )
        XCTAssertEqual(
            MapHomeTimeSidebarPinchMath.stepOffset(magnification: 1.2),
            1
        )
        XCTAssertEqual(
            MapHomeTimeSidebarPinchMath.stepOffset(magnification: 2),
            4
        )
        XCTAssertEqual(
            MapHomeTimeSidebarPinchMath.stepOffset(magnification: 0.5),
            -4
        )
        XCTAssertEqual(
            MapHomeTimeSidebarPinchMath.stepOffset(magnification: .nan),
            0
        )
    }

    func testExpandedSidebarRulerUsesEveryVisibleMinute() {
        let marks = MapHomeTimeSidebarMath.visibleMinuteMarks(window: 120...180)

        XCTAssertEqual(marks.count, 61)
        XCTAssertEqual(marks.first, 120)
        XCTAssertEqual(marks.last, 180)
        XCTAssertTrue(marks.filter { $0.isMultiple(of: 10) }.contains(150))
    }

    func testExpandedSidebarRulerSeparatesHourAndMinuteLabels() {
        let labels = MapHomeTimeSidebarMath.visibleRulerLabels(window: 780...900)

        XCTAssertEqual(labels.hours, [13, 14, 15])
        XCTAssertEqual(
            labels.minutes,
            [790, 800, 810, 820, 830, 850, 860, 870, 880, 890]
        )
    }

    func testSidebarRulerDetailFollowsThirdAndFourthZoomSteps() {
        XCTAssertFalse(MapHomeTimeSidebarMath.showsTenMinuteRuler(durationMinutes: 360))
        XCTAssertTrue(MapHomeTimeSidebarMath.showsTenMinuteRuler(durationMinutes: 180))
        XCTAssertFalse(MapHomeTimeSidebarMath.showsMinuteTicks(durationMinutes: 180))
        XCTAssertTrue(MapHomeTimeSidebarMath.showsMinuteTicks(durationMinutes: 60))
    }

    func testExpandedSidebarRulerLabelsStartAfterTickColumn() {
        let railWidth: CGFloat = 58
        let labelsStart = MapHomeTimeSidebarMath.rulerLabelsStartX(railWidth: railWidth)
        let tickEnd = railWidth - MapHomeTimeSidebarMath.rulerNumericColumnWidth
            + MapHomeTimeSidebarMath.rulerTickWidth

        XCTAssertGreaterThanOrEqual(labelsStart, tickEnd)
        XCTAssertLessThanOrEqual(
            labelsStart
                + MapHomeTimeSidebarMath.rulerHourColumnWidth
                + MapHomeTimeSidebarMath.rulerColumnSpacing
                + MapHomeTimeSidebarMath.rulerMinuteColumnWidth,
            railWidth
        )
    }

    func testSidebarLabelsKeepSafeVerticalSpacingAcrossZoomSteps() {
        let trackHeight: CGFloat = 192
        let centerMinute = 720

        for duration in MapHomeTimeSidebarMath.zoomDurations {
            let window = MapHomeTimeSidebarMath.visibleWindow(
                centerMinute: centerMinute,
                durationMinutes: duration
            )
            if MapHomeTimeSidebarMath.showsTenMinuteRuler(
                durationMinutes: duration
            ) {
                let labels = MapHomeTimeSidebarMath.visibleRulerLabels(
                    window: window,
                    durationMinutes: duration,
                    trackHeight: trackHeight
                )
                let minutePositions = labels.minutes.map {
                    MapHomeTimeSidebarMath.position(
                        minute: $0,
                        window: window
                    ) * trackHeight
                }
                XCTAssertTrue(
                    zip(minutePositions, minutePositions.dropFirst())
                        .allSatisfy {
                            $1 - $0 >= MapHomeTimeSidebarMath.minimumRulerLabelSpacing
                        },
                    "minute labels overlap at \(duration) minutes"
                )
            } else {
                let labels = MapHomeTimeSidebarMath.visibleHourLabels(
                    window: window,
                    durationMinutes: duration,
                    trackHeight: trackHeight
                )
                let hourPositions = labels.map {
                    MapHomeTimeSidebarMath.position(
                        minute: $0 * 60,
                        window: window
                    ) * trackHeight
                }
                XCTAssertTrue(
                    zip(hourPositions, hourPositions.dropFirst())
                        .allSatisfy {
                            $1 - $0 >= MapHomeTimeSidebarMath.minimumRulerLabelSpacing
                        },
                    "hour labels overlap at \(duration) minutes"
                )
            }
        }
    }

    func testSidebarSelectionTimeBlockFitsTheExistingRailWidth() {
        let railWidth: CGFloat = 58
        let trackX = railWidth
            - MapHomeTimeSidebarMath.rulerNumericColumnWidth
            - 12 / 2
            - 1
        let center = MapHomeTimeSidebarMath.selectionTimeBlockCenterX(
            railWidth: railWidth,
            trackX: trackX,
            activeRailWidth: 12
        )
        let halfWidth = MapHomeTimeSidebarMath.selectionTimeBlockWidth / 2

        XCTAssertGreaterThanOrEqual(center - halfWidth, 0)
        XCTAssertLessThanOrEqual(center + halfWidth, railWidth)
        XCTAssertEqual(center, 30)
    }

    func testSidebarHandleLaneContainsExpandedHitAreaWithoutRailOverlap() {
        let railWidth: CGFloat = 58
        let activeRailWidth: CGFloat = 12
        let totalWidth = MapHomeTimeSidebarMath.totalWidth(railWidth: railWidth)
        let trackX = MapHomeTimeSidebarMath.trackCenterX(
            railOriginX: MapHomeTimeSidebarMath.handleLaneWidth,
            railWidth: railWidth,
            numericColumnWidth: MapHomeTimeSidebarMath.rulerNumericColumnWidth,
            activeRailWidth: activeRailWidth
        )
        let handleX = MapHomeTimeSidebarMath.handleCenterX(
            trackX: trackX,
            activeRailWidth: activeRailWidth
        )
        let hitSize = MapHomeTimeSidebarMath.handleDoubleTapHitSize(
            railWidth: railWidth,
            handleHeight: MapHomeTimeSidebarMath.handleVisualSize.height
        )
        let activeRailMinX = trackX - activeRailWidth / 2
        let handleMaxX = handleX + MapHomeTimeSidebarMath.handleVisualSize.width / 2

        XCTAssertEqual(totalWidth, 127)
        XCTAssertEqual(activeRailMinX - handleMaxX, MapHomeTimeSidebarMath.handleRailGap)
        XCTAssertGreaterThanOrEqual(handleX - hitSize.width / 2, 0)
        XCTAssertLessThanOrEqual(handleX + hitSize.width / 2, totalWidth)
    }

    func testSidebarHandleHitAreaAndWeatherStayInsideRailAtEdges() {
        let railHeight: CGFloat = 600
        let hitHeight: CGFloat = 66
        XCTAssertEqual(
            MapHomeTimeSidebarMath.handleHitCenterY(
                handleCenterY: 14,
                railHeight: railHeight,
                hitHeight: hitHeight
            ),
            33
        )
        XCTAssertEqual(
            MapHomeTimeSidebarMath.handleHitCenterY(
                handleCenterY: 590,
                railHeight: railHeight,
                hitHeight: hitHeight
            ),
            567
        )

        let above = MapHomeTimeSidebarMath.compactWeatherFrame(
            handleCenterX: 44,
            handleCenterY: 200,
            railHeight: railHeight
        )
        let flipped = MapHomeTimeSidebarMath.compactWeatherFrame(
            handleCenterX: 44,
            handleCenterY: 14,
            railHeight: railHeight
        )
        XCTAssertEqual(200 - MapHomeTimeSidebarMath.handleVisualSize.height / 2 - above.maxY, 4)
        XCTAssertEqual(flipped.minY - (14 + MapHomeTimeSidebarMath.handleVisualSize.height / 2), 4)
    }

    func testSectionTimelineDetailFrameKeepsTimeGutterClear() {
        for width: CGFloat in [180, 240, 320] {
            let frame = MapHomeSectionTimelineLayoutMath.detailFrame(leftWidth: width)
            XCTAssertEqual(
                frame.minX - MapHomeSectionTimelineLayoutMath.timeGutterWidth,
                MapHomeSectionTimelineLayoutMath.minimumGap
            )
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertLessThanOrEqual(frame.maxX, width)
        }
    }

    func testSectionTimelineDetailsSplitOverlapsIntoEqualColumns() {
        let twoIDs = [UUID(), UUID()]
        let threeIDs = [UUID(), UUID(), UUID()]
        let adjacentIDs = [UUID(), UUID()]
        let details = [
            MapHomeSectionDetail(
                id: twoIDs[0], title: "A", categoryID: "activity",
                behavior: nil, startMinute: 60, endMinute: 120
            ),
            MapHomeSectionDetail(
                id: twoIDs[1], title: "B", categoryID: "activity",
                behavior: nil, startMinute: 90, endMinute: 110
            ),
            MapHomeSectionDetail(
                id: threeIDs[0], title: "C", categoryID: "activity",
                behavior: nil, startMinute: 180, endMinute: 240
            ),
            MapHomeSectionDetail(
                id: threeIDs[1], title: "D", categoryID: "activity",
                behavior: nil, startMinute: 190, endMinute: 230
            ),
            MapHomeSectionDetail(
                id: threeIDs[2], title: "E", categoryID: "activity",
                behavior: nil, startMinute: 200, endMinute: 220
            ),
            MapHomeSectionDetail(
                id: adjacentIDs[0], title: "F", categoryID: "activity",
                behavior: nil, startMinute: 300, endMinute: 320
            ),
            MapHomeSectionDetail(
                id: adjacentIDs[1], title: "G", categoryID: "activity",
                behavior: nil, startMinute: 320, endMinute: 340
            ),
        ]
        let columns = MapHomeSectionTimelineLayoutMath.detailColumns(
            for: details,
            visibleRange: 0...1_440
        )

        let twoColumns = twoIDs.compactMap { columns[$0] }
            .sorted { $0.index < $1.index }
        XCTAssertEqual(twoColumns.map(\.count), [2, 2])
        XCTAssertEqual(twoColumns.map(\.index), [0, 1])

        let threeColumns = threeIDs.compactMap { columns[$0] }
            .sorted { $0.index < $1.index }
        XCTAssertEqual(threeColumns.map(\.count), [3, 3, 3])
        XCTAssertEqual(threeColumns.map(\.index), [0, 1, 2])
        XCTAssertEqual(columns[adjacentIDs[0]], .single)
        XCTAssertEqual(columns[adjacentIDs[1]], .single)

        let container = MapHomeSectionTimelineLayoutMath.detailFrame(
            leftWidth: 320
        )
        let twoFrames = twoColumns.map {
            MapHomeSectionTimelineLayoutMath.detailFrame(
                leftWidth: 320,
                column: $0
            )
        }
        XCTAssertEqual(
            twoFrames[0].width,
            (container.width - MapHomeSectionTimelineLayoutMath.detailColumnSpacing) / 2,
            accuracy: 0.001
        )
        XCTAssertEqual(
            twoFrames[1].minX - twoFrames[0].maxX,
            MapHomeSectionTimelineLayoutMath.detailColumnSpacing,
            accuracy: 0.001
        )

        let threeFrames = threeColumns.map {
            MapHomeSectionTimelineLayoutMath.detailFrame(
                leftWidth: 320,
                column: $0
            )
        }
        XCTAssertEqual(threeFrames[0].width, threeFrames[1].width, accuracy: 0.001)
        XCTAssertEqual(threeFrames[1].width, threeFrames[2].width, accuracy: 0.001)
        XCTAssertEqual(threeFrames[2].maxX, container.maxX, accuracy: 0.001)
    }

    func testSectionTimelineOverlapColumnsUseOnlyVisibleIntervals() {
        let clippedID = UUID()
        let visibleID = UUID()
        let columns = MapHomeSectionTimelineLayoutMath.detailColumns(
            for: [
                MapHomeSectionDetail(
                    id: clippedID, title: "A", categoryID: "activity",
                    behavior: nil, startMinute: 60, endMinute: 130
                ),
                MapHomeSectionDetail(
                    id: visibleID, title: "B", categoryID: "activity",
                    behavior: nil, startMinute: 120, endMinute: 180
                ),
            ],
            visibleRange: 130...180
        )

        XCTAssertNil(columns[clippedID])
        XCTAssertEqual(columns[visibleID], .single)
    }

    func testSectionDetailsExcludeMajorSleepSourceAndKeepActualHomeRest() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dayStart = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 8,
            day: 24
        ))!
        let sleepID = UUID()
        let restID = UUID()
        let start = dayStart.addingTimeInterval(13 * 60)
        let end = dayStart.addingTimeInterval(8 * 3_600 + 60)
        let sleep = ActualRecord(
            id: sleepID,
            planID: nil,
            title: "수면",
            categoryID: "sleep",
            startedAt: start,
            endedAt: end,
            source: .healthKit,
            behavior: "sleep"
        )
        let homeRest = ActualRecord(
            id: restID,
            planID: nil,
            title: "집에서 휴식",
            categoryID: "activity",
            startedAt: start,
            endedAt: end,
            source: .location,
            behavior: StationaryContextKind.homeRest.rawValue
        )
        let segment = MapHomeTimeRailSegment(
            startMinute: 13,
            endMinute: 481,
            categoryID: "sleep",
            title: "수면",
            sourceIDs: [sleepID]
        )

        let details = MapHomeSectionDetailEngine.details(
            actuals: [sleep, homeRest],
            travel: [],
            segment: segment,
            dayStart: dayStart,
            dayEnd: dayStart.addingTimeInterval(86_400),
            asOf: end
        )

        XCTAssertEqual(details.map(\.id), [restID])
        XCTAssertEqual(details.first?.title, "집에서 휴식")
        XCTAssertTrue(
            MapHomeSectionDetailEngine.details(
                actuals: [sleep],
                travel: [],
                segment: segment,
                dayStart: dayStart,
                dayEnd: dayStart.addingTimeInterval(86_400),
                asOf: end
            ).isEmpty
        )
    }

    func testMapHomeCompassControlReturnsToArrowWithFixedDirection() {
        let compass = MapHomeCompassControlState.directionArrow.toggled
        XCTAssertEqual(compass, .compass)
        XCTAssertTrue(compass.followsHeading)

        let fixedDirection = compass.toggled
        XCTAssertEqual(fixedDirection, .directionArrow)
        XCTAssertFalse(fixedDirection.followsHeading)
    }

    func testMapHomeCompassIconCounterRotatesToKeepNorthUp() {
        XCTAssertEqual(
            MapHomeCompassControlState.iconRotationDegrees(for: 90),
            -90
        )
        XCTAssertEqual(
            MapHomeCompassControlState.iconRotationDegrees(for: -90),
            90
        )
        XCTAssertEqual(
            MapHomeCompassControlState.iconRotationDegrees(for: .infinity),
            0
        )
    }

    func testMapHomeCompassUsesShortestRotationAcrossNorthAndHeadingFallback() {
        XCTAssertEqual(
            MapHomeCompassControlState.continuousIconRotationDegrees(
                previousRotationDegrees: -359,
                headingDegrees: 1
            ),
            -361
        )
        XCTAssertEqual(
            MapHomeCompassControlState.preferredHeadingDegrees(
                trueHeading: 42,
                magneticHeading: 120
            ),
            42
        )
        XCTAssertEqual(
            MapHomeCompassControlState.preferredHeadingDegrees(
                trueHeading: -1,
                magneticHeading: 120
            ),
            120
        )
    }

    func testSavedLocationActivationAndManagerMapKeepTheCurrentSpan() {
        XCTAssertEqual(
            MapHomeLocationActivation.resolve(
                isCurrentLocation: false,
                hasSavedPoint: true
            ),
            .savedLocation
        )
        XCTAssertEqual(
            MapHomeLocationActivation.resolve(
                isCurrentLocation: false,
                hasSavedPoint: false
            ),
            .edit
        )
        XCTAssertEqual(
            MapHomeLocationActivation.resolve(
                isCurrentLocation: true,
                hasSavedPoint: false
            ),
            .currentLocation
        )

        let center = CLLocationCoordinate2D(latitude: 37.55, longitude: 126.99)
        let span = MKCoordinateSpan(latitudeDelta: 0.025, longitudeDelta: 0.035)
        let region = MapHomeLocationMapMath.region(center: center, span: span)
        XCTAssertEqual(region.center.latitude, center.latitude, accuracy: 0.000_001)
        XCTAssertEqual(region.center.longitude, center.longitude, accuracy: 0.000_001)
        XCTAssertEqual(region.span.latitudeDelta, span.latitudeDelta, accuracy: 0.000_001)
        XCTAssertEqual(region.span.longitudeDelta, span.longitudeDelta, accuracy: 0.000_001)
    }

    func testWeatherBackgroundSelectionTakesPriorityOverCurrentState() {
        XCTAssertEqual(
            MapHomeWeatherBackgroundKind.resolve(isSelected: true, isCurrent: true),
            .selected
        )
        XCTAssertEqual(
            MapHomeWeatherBackgroundKind.resolve(isSelected: false, isCurrent: true),
            .current
        )
        XCTAssertEqual(
            MapHomeWeatherBackgroundKind.resolve(isSelected: false, isCurrent: false),
            .normal
        )
    }

    func testMapHomeWeatherKeepsThePreviousValueUntilTheNextObservation() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 23))
        )
        let firstDate = try XCTUnwrap(calendar.date(byAdding: .hour, value: 10, to: day))
        let secondDate = try XCTUnwrap(calendar.date(byAdding: .hour, value: 12, to: day))
        let first = WeatherContext(
            observedAt: firstDate,
            condition: "맑음",
            symbolName: "sun.max.fill",
            temperatureCelsius: 20
        )
        let second = WeatherContext(
            observedAt: secondDate,
            condition: "흐림",
            symbolName: "cloud.fill",
            temperatureCelsius: 18
        )
        let atEleven = try XCTUnwrap(
            calendar.date(byAdding: .hour, value: 11, to: day)
        )
        let atTwelve = try XCTUnwrap(
            calendar.date(byAdding: .hour, value: 12, to: day)
        )

        XCTAssertEqual(
            MapHomeWeatherTimelineMath.context(
                at: atEleven,
                contexts: [first, second]
            )?.id,
            first.id
        )
        XCTAssertEqual(
            MapHomeWeatherTimelineMath.context(
                at: atTwelve,
                contexts: [first, second]
            )?.id,
            second.id
        )
        XCTAssertEqual(
            MapHomeWeatherTimelineMath.persistentSpans(
                for: day,
                contexts: [first, second],
                calendar: calendar
            ).first?.span.end,
            secondDate
        )
    }

    func testIntegrationRefreshGateSuppressesSameWindowButAllowsNewWindow() {
        var gate = TimelineIntegrationRefreshGate()

        XCTAssertTrue(
            gate.shouldStart(key: "day|a", nowUptime: 10)
        )
        gate.commit(key: "day|a", nowUptime: 10)
        XCTAssertFalse(
            gate.shouldStart(key: "day|a", nowUptime: 14.9)
        )
        XCTAssertTrue(
            gate.shouldStart(key: "day|a", nowUptime: 15)
        )
        XCTAssertTrue(
            gate.shouldStart(key: "day|b", nowUptime: 10.1)
        )
        XCTAssertTrue(
            gate.shouldStart(key: "day|a", nowUptime: 10.1, force: true)
        )
    }

    func testDiagnosticsTravelSummaryExposesSubwayRouteWithoutCoordinates() {
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        let route = SubwayRoutePath(
            stops: [
                SubwayRouteStop(
                    lineName: "인천1호선",
                    order: 0,
                    stationName: "가정역",
                    latitude: 37.0,
                    longitude: 126.0
                ),
                SubwayRouteStop(
                    lineName: "인천1호선",
                    order: 1,
                    stationName: "검암역",
                    latitude: 37.1,
                    longitude: 126.1
                ),
                SubwayRouteStop(
                    lineName: "5호선",
                    order: 2,
                    stationName: "마곡나루역",
                    latitude: 37.2,
                    longitude: 126.2
                ),
            ],
            lineNames: ["인천1호선", "5호선"],
            transferStationNames: ["검암역"]
        )
        let subway = TravelSegment(
            mode: .subway,
            span: TimeSpan(
                start: start,
                end: start.addingTimeInterval(1_800)
            ),
            distanceMeters: 12_000,
            confidence: .high,
            evidence: ["rail route"],
            isConfirmed: true,
            subwayRoute: route
        )
        let car = TravelSegment(
            mode: .car,
            span: TimeSpan(
                start: start.addingTimeInterval(1_800),
                end: start.addingTimeInterval(2_000)
            ),
            distanceMeters: 100,
            confidence: .medium,
            evidence: ["motion"]
        )

        let fields = TaptionPlanDiagnosticsTravelSummary.fields(
            for: [subway, car]
        )

        XCTAssertEqual(fields["subway_segment_count"], "1")
        XCTAssertEqual(fields["subway_route_count"], "1")
        XCTAssertEqual(fields["subway_route_lines"], "인천1호선+5호선")
        XCTAssertEqual(
            fields["subway_route_stations"],
            "가정역→검암역→마곡나루역"
        )
        XCTAssertEqual(fields["subway_transfer_stations"], "검암역")
        XCTAssertTrue(fields["travel_mode_counts"]?.contains("subway=1") == true)
        XCTAssertTrue(fields["travel_mode_counts"]?.contains("car=1") == true)
    }

    func testNLEViewportPansAndMagnifiesWithoutChangingDocumentData() {
        let base = Date(timeIntervalSinceReferenceDate: 10_000)
        let viewport = NLETimelineViewport(
            centerDate: base,
            visibleDuration: 24 * 60 * 60
        )

        let panned = viewport.panned(by: 100, viewportWidth: 600)
        XCTAssertEqual(
            panned.centerDate.timeIntervalSince(base),
            -4 * 60 * 60,
            accuracy: 0.001
        )
        XCTAssertEqual(panned.visibleDuration, viewport.visibleDuration)

        let magnified = viewport.magnified(by: 2, anchor: 0.25)
        XCTAssertEqual(magnified.visibleDuration, 12 * 60 * 60, accuracy: 0.001)
        XCTAssertEqual(
            magnified.span.start.timeIntervalSince(
                viewport.span.start.addingTimeInterval(3 * 60 * 60)
            ),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            NLETimelineViewport(
                centerDate: base,
                visibleDuration: 90 * 24 * 60 * 60
            ).visibleDuration,
            NLETimelineViewport.maximumScheduleDuration
        )
    }

    func testCachedViewportProjectionMovesOnlyTheViewportDuringDrag() {
        let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let dataSpan = TimeSpan(
            start: base,
            end: base.addingTimeInterval(10 * 60 * 60)
        )
        let displaySpan = TimeSpan(
            start: base.addingTimeInterval(4 * 60 * 60),
            end: base.addingTimeInterval(6 * 60 * 60)
        )

        let projection = TimelineCachedViewportProjection.viewport(
            displaySpan: displaySpan,
            dataSpan: dataSpan,
            viewport: GanttViewport(start: 0.25, length: 0.5)
        )

        XCTAssertEqual(projection?.start ?? -1, 0.45, accuracy: 0.000_001)
        XCTAssertEqual(projection?.length ?? -1, 0.1, accuracy: 0.000_001)
    }

    func testVisibleIntervalIndexSkipsDenseOffscreenBlocks() {
        let starts = (0..<1_000).map { Double($0) / 1_000 }
        let lengths = Array(repeating: 0.001, count: starts.count)
        let prefixEnds = TimelineVisibleIntervalIndex.prefixMaximumEnds(
            starts: starts,
            lengths: lengths
        )

        let range = TimelineVisibleIntervalIndex.candidateRange(
            starts: starts,
            prefixMaximumEnds: prefixEnds,
            visibleStart: 0.5,
            visibleEnd: 0.51
        )

        XCTAssertEqual(range.lowerBound, 500)
        XCTAssertEqual(range.upperBound, 510)
        XCTAssertLessThan(range.count, starts.count / 50)
    }

    func testVisibleIntervalIndexKeepsLongEarlierOverlap() {
        let starts = [0.0, 0.1, 0.2, 0.8]
        let lengths = [0.9, 0.05, 0.05, 0.1]
        let prefixEnds = TimelineVisibleIntervalIndex.prefixMaximumEnds(
            starts: starts,
            lengths: lengths
        )

        let range = TimelineVisibleIntervalIndex.candidateRange(
            starts: starts,
            prefixMaximumEnds: prefixEnds,
            visibleStart: 0.5,
            visibleEnd: 0.6
        )

        XCTAssertTrue(range.contains(0))
        XCTAssertFalse(range.contains(3))
    }

    func testPinchZoomRulerLabelsActualNonPresetSpans() {
        XCTAssertEqual(
            TimelineZoomPreset.displayLabel(for: 90 * 60),
            "1시간 30분"
        )
        XCTAssertEqual(
            TimelineZoomPreset.displayLabel(for: 10 * 24 * 60 * 60),
            "10일"
        )
        XCTAssertEqual(
            TimelineZoomPreset.displayLabel(for: 2 * 366 * 24 * 60 * 60),
            "2년"
        )
    }

    func testDefaultPlanDurationIsNeverNegative() {
        let start = Date(timeIntervalSince1970: 100)
        let plan = PlanItem(
            title: "테스트",
            startAt: start,
            endAt: start.addingTimeInterval(-60),
            category: .project
        )

        XCTAssertEqual(plan.duration, 0)
    }

    func testAxisGridUsesRequestedSlotCounts() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let leapFebruary = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2028, month: 2, day: 15))
        )
        let regularFebruary = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2027, month: 2, day: 15))
        )

        XCTAssertEqual(
            TimelineAxisGrid.buckets(
                for: .day,
                containing: leapFebruary,
                calendar: calendar
            ).count,
            2
        )
        XCTAssertEqual(
            TimelineAxisGrid.buckets(
                for: .week,
                containing: leapFebruary,
                calendar: calendar
            ).count,
            7
        )
        XCTAssertEqual(
            TimelineAxisGrid.buckets(
                for: .month,
                containing: leapFebruary,
                calendar: calendar
            ).count,
            29
        )
        XCTAssertEqual(
            TimelineAxisGrid.buckets(
                for: .month,
                containing: regularFebruary,
                calendar: calendar
            ).count,
            28
        )
        XCTAssertEqual(
            TimelineAxisGrid.buckets(
                for: .year,
                containing: leapFebruary,
                calendar: calendar
            ).count,
            12
        )
    }

    func testAxisGridStartsWeeksOnMondayAndDisplaysKoreanHolidays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2027, month: 2, day: 7))
        )
        let week = TimelineAxisGrid.buckets(
            for: .week,
            containing: date,
            calendar: calendar
        )
        let weekday = calendar.component(.weekday, from: week[0].date)
        XCTAssertEqual(weekday, 2) // Monday in Gregorian Calendar
        XCTAssertEqual(week[6].holidayName, "설날")
        XCTAssertEqual(
            TimelineAxisGrid.koreanHolidayName(
                on: date,
                calendar: calendar
            ),
            "설날"
        )
    }

    func testMapHomeCalendarDayStyleUsesHolidayAndWeekendColors() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        func date(_ day: Int) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: day)))
        }

        XCTAssertEqual(MapHomeCalendarDayStyle(date: try date(15), calendar: calendar), .saturday)
        XCTAssertEqual(MapHomeCalendarDayStyle(date: try date(16), calendar: calendar), .holiday)
        XCTAssertEqual(MapHomeCalendarDayStyle(date: try date(22), calendar: calendar), .saturday)
        XCTAssertEqual(MapHomeCalendarDayStyle(date: try date(18), calendar: calendar), .weekday)
    }

    func testMapHomeLanguageUsesPersistableLocaleAndFormats() {
        XCTAssertEqual(MapHomeLanguage.korean.rawValue, "korean")
        XCTAssertEqual(MapHomeLanguage.english.rawValue, "english")
        XCTAssertEqual(MapHomeLanguage.korean.locale.identifier, "ko_KR")
        XCTAssertEqual(MapHomeLanguage.english.locale.identifier, "en_US")
        XCTAssertEqual(MapHomeLanguage.korean.datePartFormat, "M월 d일")
        XCTAssertEqual(MapHomeLanguage.english.datePartFormat, "MMM d")
        XCTAssertEqual(MapHomeLanguage.english.text("지도 홈", "Map Home"), "Map Home")
    }

    func testMapHomeTimeSidebarLimitsTodayToCurrentMinute() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 16, hour: 10, minute: 18))
        )

        XCTAssertEqual(
            MapHomeTimeSidebarMath.maximumSelectableMinute(for: now, now: now, calendar: calendar),
            618
        )
        XCTAssertEqual(
            MapHomeTimeSidebarMath.maximumSelectableMinute(
                for: try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: now)),
                now: now,
                calendar: calendar
            ),
            1_439
        )
    }

    func testMapHomeTimeSidebarButtonsUseTheApprovedZoomSteps() {
        XCTAssertEqual(
            MapHomeTimeSidebarMath.duration(afterZoomStep: 1, from: 1_440),
            720
        )
        XCTAssertEqual(
            MapHomeTimeSidebarMath.duration(afterZoomStep: 1, from: 720),
            360
        )
        XCTAssertEqual(
            MapHomeTimeSidebarMath.duration(afterZoomStep: 1, from: 180),
            60
        )
        XCTAssertEqual(
            MapHomeTimeSidebarMath.duration(afterZoomStep: 1, from: 60),
            60
        )
        XCTAssertEqual(
            MapHomeTimeSidebarMath.duration(afterZoomStep: -1, from: 60),
            180
        )
        XCTAssertEqual(
            MapHomeTimeSidebarMath.duration(afterZoomStep: -1, from: 1_440),
            1_440
        )
    }

    func testMapHomeMovementIconsCoverTheNineTransportLabels() {
        let labels = [
            "걷기", "자전거", "버스", "지하철", "택시",
            "자동차", "기차", "비행기", "배",
        ]
        let symbols = labels.map(MapHomeMovementIcon.systemImage(for:))
        XCTAssertEqual(
            symbols,
            [
                "figure.walk.motion", "bicycle", "bus.fill", "tram.fill", "car.side.fill",
                "car.fill", "train.side.front.car", "airplane", "ferry.fill",
            ]
        )
    }

    func testMapHomeTimeSidebarCurrentDateResetRestoresFullDayAtCurrentMinute() {
        XCTAssertEqual(
            MapHomeTimeSidebarMath.resetState(selectedMinute: 618),
            MapHomeTimeSidebarNLEState(
                selectedMinute: 618,
                visibleStartMinute: 0,
                visibleDurationMinutes: 1_440
            )
        )
    }

    func testMapHomeTimeSidebarZoomWindowClampsAroundSelectedMinute() {
        XCTAssertEqual(
            MapHomeTimeSidebarMath.visibleWindow(centerMinute: 30, durationMinutes: 60),
            0...60
        )
        XCTAssertEqual(
            MapHomeTimeSidebarMath.visibleWindow(centerMinute: 720, durationMinutes: 60),
            690...750
        )
        XCTAssertEqual(
            MapHomeTimeSidebarMath.visibleWindow(centerMinute: 1_430, durationMinutes: 60),
            1_380...1_440
        )
    }

    func testMapHomeTimeSidebarZoomCentersOnThePlayhead() {
        XCTAssertEqual(
            MapHomeTimeSidebarMath.startMinute(
                centerMinute: 720,
                durationMinutes: 60
            ),
            690
        )
        XCTAssertEqual(
            MapHomeTimeSidebarMath.startMinute(
                centerMinute: 30,
                durationMinutes: 60
            ),
            0
        )
        XCTAssertEqual(
            MapHomeTimeSidebarMath.startMinute(
                centerMinute: 1_430,
                durationMinutes: 60
            ),
            1_380
        )
    }

    func testMapHomeTimeSidebarHandleReleaseRecentersZoomedWindow() {
        let releasedMinute = 840
        let centeredStart = MapHomeTimeSidebarMath.startMinute(
            centerMinute: releasedMinute,
            durationMinutes: 60
        )

        XCTAssertEqual(centeredStart, 810)
        XCTAssertEqual(
            MapHomeTimeSidebarMath.visibleWindow(
                startMinute: centeredStart,
                durationMinutes: 60,
                centerMinute: releasedMinute
            ),
            810...870
        )
    }

    func testMapHomeTimeSidebarTapMapsAndClampsToVisibleRail() {
        XCTAssertEqual(
            MapHomeTimeSidebarMath.minuteByLocation(
                y: 14,
                trackHeight: 300,
                verticalInset: 14,
                maxMinute: 1_439
            ),
            0
        )
        XCTAssertEqual(
            MapHomeTimeSidebarMath.minuteByLocation(
                y: 164,
                trackHeight: 300,
                verticalInset: 14,
                maxMinute: 1_439
            ),
            720
        )
        XCTAssertEqual(
            MapHomeTimeSidebarMath.minuteByLocation(
                y: 400,
                trackHeight: 300,
                verticalInset: 14,
                maxMinute: 618
            ),
            618
        )
    }

    func testMapHomeTimeSidebarHandleUsesConstantEdgeScrollSpeed() throws {
        let drag = MapHomeTimeSidebarHandleDrag()
        let base = MapHomeTimeSidebarNLEState(
            selectedMinute: 720,
            visibleStartMinute: 690,
            visibleDurationMinutes: 60
        )
        drag.begin(with: base, nowUptime: 10)

        var state = try XCTUnwrap(
            drag.projectedState(
                locationY: 301,
                trackHeight: 300,
                verticalInset: 0,
                maxMinute: 1_439,
                nowUptime: 10
            )
        )
        for frame in 1...60 {
            state = try XCTUnwrap(
                drag.projectedState(
                    locationY: 301,
                    trackHeight: 300,
                    verticalInset: 0,
                    maxMinute: 1_439,
                    nowUptime: 10 + Double(frame) / 60
                )
            )
        }

        XCTAssertEqual(state.visibleStartMinute, 728)
        XCTAssertEqual(state.selectedMinute, 788)
    }

    func testMapHomeTimeSidebarHandleScrollsOnlyAtAndStopsAtEdges() throws {
        let drag = MapHomeTimeSidebarHandleDrag()
        drag.begin(
            with: MapHomeTimeSidebarNLEState(
                selectedMinute: 30,
                visibleStartMinute: 0,
                visibleDurationMinutes: 60
            ),
            nowUptime: 10
        )

        var state = try XCTUnwrap(
            drag.projectedState(
                locationY: -1,
                trackHeight: 300,
                verticalInset: 0,
                maxMinute: 1_439,
                nowUptime: 10
            )
        )
        for frame in 1...60 {
            state = try XCTUnwrap(
                drag.projectedState(
                    locationY: -1,
                    trackHeight: 300,
                    verticalInset: 0,
                    maxMinute: 1_439,
                    nowUptime: 10 + Double(frame) / 60
                )
            )
        }

        XCTAssertEqual(state.visibleStartMinute, 0)
        XCTAssertEqual(state.selectedMinute, 0)
        XCTAssertEqual(
            MapHomeTimeSidebarMath.maximumVisibleStart(durationMinutes: 60),
            1_380
        )
    }

    func testMapHomeTimeSidebarHandleDoesNotScrollPastCurrentMinute() throws {
        let drag = MapHomeTimeSidebarHandleDrag()
        drag.begin(
            with: MapHomeTimeSidebarNLEState(
                selectedMinute: 570,
                visibleStartMinute: 540,
                visibleDurationMinutes: 60
            ),
            nowUptime: 10
        )

        var state = try XCTUnwrap(
            drag.projectedState(
                locationY: 301,
                trackHeight: 300,
                verticalInset: 0,
                maxMinute: 600,
                nowUptime: 10
            )
        )
        for frame in 1...180 {
            state = try XCTUnwrap(
                drag.projectedState(
                    locationY: 301,
                    trackHeight: 300,
                    verticalInset: 0,
                    maxMinute: 600,
                    nowUptime: 10 + Double(frame) / 60
                )
            )
        }

        XCTAssertEqual(state.selectedMinute, 600)
        XCTAssertEqual(state.visibleStartMinute, 540)
    }

    func testMapHomeTimeSidebarHandleMapsAbsoluteTouchOneToOne() throws {
        let drag = MapHomeTimeSidebarHandleDrag()
        drag.begin(
            with: MapHomeTimeSidebarNLEState(
                selectedMinute: 660,
                visibleStartMinute: 600,
                visibleDurationMinutes: 120
            ),
            nowUptime: 10
        )

        let state = try XCTUnwrap(drag.projectedState(
            locationY: 74,
            trackHeight: 240,
            verticalInset: 14,
            maxMinute: 1_439,
            nowUptime: 10
        ))

        XCTAssertEqual(state.selectedMinute, 630)
        XCTAssertEqual(state.visibleStartMinute, 600)
    }

    func testMapHomeTimeSidebarHandleDoubleTapAreaIsOnePointFiveTimesLarger() {
        let size = MapHomeTimeSidebarMath.handleDoubleTapHitSize(
            railWidth: 58,
            handleHeight: 44
        )

        XCTAssertEqual(size.width, 87, accuracy: 0.001)
        XCTAssertEqual(size.height, 66, accuracy: 0.001)
    }

    func testSidebarBothHandleHitTargetsShareOneDragAndEditZone() {
        let frame = MapHomeTimeSidebarMath.selectionHandleInteractionFrame(
            leadingCenterX: 44,
            trailingCenterX: 99,
            leadingHitWidth: 87,
            trailingHitWidth: MapHomeTimeSidebarMath.selectionTimeBlockHitWidth,
            totalWidth: 127
        )

        XCTAssertLessThanOrEqual(frame.minX, 44 - 87 / 2)
        XCTAssertGreaterThanOrEqual(frame.maxX, 99 + 48 / 2)
        XCTAssertGreaterThanOrEqual(frame.minX, 0)
        XCTAssertLessThanOrEqual(frame.maxX, 127)
    }

    func testExpandedRulerRowsKeepHourAndMinuteInOneVerticalColumn() {
        let rows = MapHomeTimeSidebarMath.visibleRulerRows(
            window: 480...600,
            durationMinutes: 120,
            trackHeight: 600
        )

        XCTAssertEqual(
            rows.map(\.minute),
            [480, 490, 500, 510, 520, 530, 540, 550, 560, 570, 580, 590, 600]
        )
        XCTAssertEqual(rows.first?.hour, 8)
        XCTAssertNil(rows.first?.minuteComponent)
        XCTAssertEqual(rows[1].minuteComponent, 10)
        XCTAssertNil(rows[1].hour)
        XCTAssertEqual(rows[6].hour, 9)
        XCTAssertNil(rows[6].minuteComponent)
    }

    func testMapHomeTimeSidebarHandleStartsWithinOnePoint() {
        XCTAssertEqual(
            MapHomeTimeSidebarMath.handleDragMinimumDistance,
            1,
            accuracy: 0.001
        )
    }

    func testMapHomeTimelineUsesFullDayForArchivedDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 19, hour: 9, minute: 47)
        )!
        let archivedDate = calendar.date(byAdding: .day, value: -1, to: now)!

        XCTAssertEqual(
            MapHomeTimeSidebarMath.defaultTimelineMinute(
                for: archivedDate,
                now: now,
                calendar: calendar
            ),
            MapHomeTimeSidebarMath.fullDayMinutes
        )
        XCTAssertEqual(
            MapHomeTimeSidebarMath.defaultTimelineMinute(
                for: now,
                now: now,
                calendar: calendar
            ),
            587
        )
    }

    func testStartupMapLocationUsesNewestUsableGPSReading() {
        let base = Date(timeIntervalSinceReferenceDate: 0)
        let validEarlier = SensorReading(
            timestamp: base,
            point: GeoPoint(
                latitude: 37.5665,
                longitude: 126.9780,
                altitude: 25,
                horizontalAccuracy: 12,
                verticalAccuracy: 8
            )
        )
        let invalidNewer = SensorReading(
            timestamp: base.addingTimeInterval(120),
            point: GeoPoint(
                latitude: 37.5670,
                longitude: 126.9785,
                altitude: 25,
                horizontalAccuracy: 80,
                verticalAccuracy: 8
            )
        )
        let newestValid = SensorReading(
            timestamp: base.addingTimeInterval(60),
            point: GeoPoint(
                latitude: 37.5668,
                longitude: 126.9783,
                altitude: 25,
                horizontalAccuracy: 10,
                verticalAccuracy: 8
            )
        )

        XCTAssertEqual(
            MapCurrentLocationAnchorPolicy.latestValidReading(
                in: [validEarlier, invalidNewer, newestValid],
                now: base.addingTimeInterval(180)
            )?.id,
            newestValid.id
        )
    }

    func testMapLocationAnchorFallsBackToRecentApproximateReading() {
        let now = Date(timeIntervalSince1970: 10_000)
        let precise = SensorReading(
            timestamp: now.addingTimeInterval(-7 * 60 * 60),
            point: GeoPoint(
                latitude: 37.5,
                longitude: 126.9,
                altitude: 0,
                horizontalAccuracy: 10,
                verticalAccuracy: 10
            ),
            locationFixQuality: .precise,
            gpsAvailable: true
        )
        let approximate = SensorReading(
            timestamp: now.addingTimeInterval(-5 * 60),
            point: GeoPoint(
                latitude: 37.6,
                longitude: 127.0,
                altitude: 0,
                horizontalAccuracy: 2_000,
                verticalAccuracy: 100
            ),
            locationFixQuality: .approximate,
            gpsAvailable: false
        )

        XCTAssertEqual(
            MapCurrentLocationAnchorPolicy.latestValidReading(
                in: [precise, approximate],
                now: now
            )?.id,
            approximate.id
        )
    }

    func testCurrentLocationRefreshPreservesAlwaysAuthorizedCollection() {
        XCTAssertTrue(
            BackgroundLocationCollectionPolicy.isEnabled(
                hasAlwaysAuthorization: true
            )
        )
        XCTAssertFalse(
            BackgroundLocationCollectionPolicy.isEnabled(
                hasAlwaysAuthorization: false
            )
        )
    }

    func testMapLocationAnchorPrefersRecentPreciseReading() {
        let now = Date(timeIntervalSince1970: 20_000)
        let precise = SensorReading(
            timestamp: now.addingTimeInterval(-30 * 60),
            point: GeoPoint(
                latitude: 37.5,
                longitude: 126.9,
                altitude: 0,
                horizontalAccuracy: 15,
                verticalAccuracy: 10
            ),
            locationFixQuality: .precise,
            gpsAvailable: true
        )
        let approximate = SensorReading(
            timestamp: now,
            point: GeoPoint(
                latitude: 35.1,
                longitude: 129.0,
                altitude: 0,
                horizontalAccuracy: 4_000,
                verticalAccuracy: 100
            ),
            locationFixQuality: .approximate,
            gpsAvailable: false
        )

        XCTAssertEqual(
            MapCurrentLocationAnchorPolicy.latestValidReading(
                in: [precise, approximate],
                now: now
            )?.id,
            precise.id
        )
    }

    func testMapLocationAnchorAcceptsSixHourBoundaryAndRejectsOlderFix() {
        let now = Date(timeIntervalSince1970: 30_000)
        func approximate(age: TimeInterval) -> SensorReading {
            SensorReading(
                timestamp: now.addingTimeInterval(-age),
                point: GeoPoint(
                    latitude: 37.5,
                    longitude: 126.9,
                    altitude: 0,
                    horizontalAccuracy: 3_000,
                    verticalAccuracy: 100
                ),
                locationFixQuality: .approximate,
                gpsAvailable: false
            )
        }
        let boundary = approximate(age: 6 * 60 * 60)
        let stale = approximate(age: 6 * 60 * 60 + 1)

        XCTAssertEqual(
            MapCurrentLocationAnchorPolicy.latestValidReading(
                in: [stale, boundary],
                now: now
            )?.id,
            boundary.id
        )
        XCTAssertNil(
            MapCurrentLocationAnchorPolicy.latestValidReading(
                in: [stale],
                now: now
            )
        )
    }

    func testUserTrackingStopsForPanButKeepsPinchAndRotation() {
        XCTAssertFalse(
            MapHomeUserTrackingPolicy.keepsFollowing(after: .pan)
        )
        XCTAssertTrue(
            MapHomeUserTrackingPolicy.keepsFollowing(after: .pinch)
        )
        XCTAssertTrue(
            MapHomeUserTrackingPolicy.keepsFollowing(after: .rotation)
        )
    }

    func testMapPanObserverAcceptsOneFingerBeganOrChangedOnly() {
        XCTAssertTrue(
            MapHomeUserTrackingPolicy.isSingleFingerPanStart(
                state: .began,
                numberOfTouches: 1
            )
        )
        XCTAssertTrue(
            MapHomeUserTrackingPolicy.isSingleFingerPanStart(
                state: .changed,
                numberOfTouches: 1
            )
        )
        XCTAssertFalse(
            MapHomeUserTrackingPolicy.isSingleFingerPanStart(
                state: .began,
                numberOfTouches: 2
            )
        )
        XCTAssertFalse(
            MapHomeUserTrackingPolicy.isSingleFingerPanStart(
                state: .ended,
                numberOfTouches: 1
            )
        )
    }

    func testTodayTimelineCutoffNeverMovesPastNow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(
            calendar.date(from: DateComponents(
                year: 2026,
                month: 8,
                day: 25,
                hour: 12
            ))
        )
        let future = try XCTUnwrap(
            calendar.date(byAdding: .hour, value: 6, to: now)
        )

        XCTAssertEqual(
            MapHomeRouteReadingsPolicy.clampedTimelineDate(
                selectedDate: now,
                timelineDate: future,
                now: now,
                calendar: calendar
            ),
            now
        )
    }

    func testCompletedRouteLoadOnlyMatchesItsOwnCalendarDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 25))
        )
        let nextDay = try XCTUnwrap(
            calendar.date(byAdding: .day, value: 1, to: day)
        )
        let state = MapHomeRouteReadingsLoadState.loaded(day)

        XCTAssertTrue(state.isLoaded(for: day, calendar: calendar))
        XCTAssertFalse(state.isLoaded(for: nextDay, calendar: calendar))
        XCTAssertFalse(
            MapHomeRouteReadingsLoadState.failed(day).isLoaded(
                for: day,
                calendar: calendar
            )
        )
    }

    func testLocationButtonDotRequiresFollowingAndCenteredCamera() {
        XCTAssertEqual(
            MapHomeLocationButtonState.resolve(
                hasLocation: false,
                trackingMode: .idle,
                isCentered: false
            ),
            .unavailable
        )
        XCTAssertEqual(
            MapHomeLocationButtonState.resolve(
                hasLocation: true,
                trackingMode: .locating,
                isCentered: false
            ),
            .locating
        )
        XCTAssertEqual(
            MapHomeLocationButtonState.resolve(
                hasLocation: true,
                trackingMode: .following,
                isCentered: false
            ),
            .available
        )
        let following = MapHomeLocationButtonState.resolve(
            hasLocation: true,
            trackingMode: .following,
            isCentered: true
        )
        XCTAssertEqual(following, .following)
        XCTAssertTrue(following.showsTrackingDot)
    }

    func testMapDisplayStylePersistsAndMissingValueUsesStandard() throws {
        var settings = AppFeatureSettings.defaults
        settings.mapDisplayStyle = .hybrid
        XCTAssertEqual(
            try JSONDecoder().decode(
                AppFeatureSettings.self,
                from: JSONEncoder().encode(settings)
            ).mapDisplayStyle,
            .hybrid
        )

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(settings)
            ) as? [String: Any]
        )
        object.removeValue(forKey: "mapDisplayStyle")
        XCTAssertEqual(
            try JSONDecoder().decode(
                AppFeatureSettings.self,
                from: JSONSerialization.data(withJSONObject: object)
            ).mapDisplayStyle,
            .standard
        )
    }

    func testMovementEditOptionsUseRequestedOrderAndRestoreStoredMode() {
        XCTAssertEqual(
            MapHomeMovementEditOption.modes,
            [.walking, .cycling, .car, .subway, .bus, .ship, .airplane, .train]
        )
        XCTAssertEqual(
            MapHomeMovementEditOption.mode(
                categoryID: "movement",
                behavior: TravelMode.subway.rawValue,
                title: "이동"
            ),
            .subway
        )
        XCTAssertNil(
            MapHomeMovementEditOption.mode(
                categoryID: "movement",
                behavior: TravelMode.running.rawValue,
                title: "이동"
            )
        )
        XCTAssertEqual(
            MapHomeMovementEditOption.localizedTitle(
                for: .ship,
                language: .english
            ),
            "Ship"
        )
    }

    func testNonDayFractionsKeepCalendarBucketsEqual() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2029, month: 1, day: 1))
        )
        let span = TimelineAxisGrid.span(
            for: .year,
            containing: date,
            calendar: calendar
        )
        let february = try XCTUnwrap(
            calendar.date(byAdding: .month, value: 1, to: span.start)
        )
        let july = try XCTUnwrap(
            calendar.date(byAdding: .month, value: 6, to: span.start)
        )
        XCTAssertEqual(
            TimelineAxisGrid.fraction(
                of: february,
                in: span,
                scale: .year,
                calendar: calendar
            ),
            1.0 / 12.0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            TimelineAxisGrid.fraction(
                of: july,
                in: span,
                scale: .year,
                calendar: calendar
            ),
            0.5,
            accuracy: 0.000_001
        )
    }

    func testMapHomeDayPlaybackMapsTwentyFourSecondsToTwentyFourHours() {
        XCTAssertEqual(
            MapHomeDayPlaybackMath.frameIntervalNanoseconds,
            16_666_667
        )
        XCTAssertEqual(MapHomeDayPlaybackMath.minute(elapsedSeconds: 0), 0)
        XCTAssertEqual(MapHomeDayPlaybackMath.minute(elapsedSeconds: 1), 60)
        XCTAssertEqual(MapHomeDayPlaybackMath.minute(elapsedSeconds: 12), 720)
        XCTAssertEqual(MapHomeDayPlaybackMath.minute(elapsedSeconds: 23.999), 1_439)
        XCTAssertEqual(MapHomeDayPlaybackMath.minute(elapsedSeconds: 24), 1_440)
        XCTAssertEqual(MapHomeDayPlaybackMath.minute(elapsedSeconds: 30), 1_440)
    }

    func testMapHomeSectionBoundaryDragClampsWithoutCrossingOtherEdge() {
        let range = 300...900
        XCTAssertEqual(
            MapHomeSectionBoundaryMath.minute(
                baseMinute: 480,
                translation: -500,
                trackHeight: 500,
                visibleRange: range,
                limit: 600,
                isStart: true
            ),
            300
        )
        XCTAssertEqual(
            MapHomeSectionBoundaryMath.minute(
                baseMinute: 600,
                translation: -500,
                trackHeight: 500,
                visibleRange: range,
                limit: 480,
                isStart: false
            ),
            481
        )
    }

    func testMapHomeSectionBoundaryPublishesAtSixtyHertzAndFlushesFinalValue() {
        XCTAssertFalse(
            MapHomeSectionBoundaryMath.shouldPublish(
                lastUptime: 10,
                currentUptime: 10.01,
                isFinal: false
            )
        )
        XCTAssertTrue(
            MapHomeSectionBoundaryMath.shouldPublish(
                lastUptime: 10,
                currentUptime: 10.02,
                isFinal: false
            )
        )
        XCTAssertTrue(
            MapHomeSectionBoundaryMath.shouldPublish(
                lastUptime: 10,
                currentUptime: 10.001,
                isFinal: true
            )
        )
    }

    func testMapHomeSectionViewportPinchKeepsAnchorMinute() {
        let origin = MapHomeSectionViewportState(
            startMinute: 480,
            durationMinutes: 360
        )

        let zoomed = MapHomeSectionViewportMath.zoomed(
            from: origin,
            magnification: 2,
            anchorY: 300,
            height: 600
        )

        XCTAssertEqual(zoomed.durationMinutes, 180)
        XCTAssertEqual(zoomed.startMinute, 570)
        XCTAssertEqual(
            MapHomeSectionViewportMath.minute(
                atY: 300,
                height: 600,
                viewport: zoomed
            ),
            660
        )
    }

    func testMapHomeSectionViewportPinchClampsZoomLimitsAndDayEdges() {
        let origin = MapHomeSectionViewportState(
            startMinute: 1_200,
            durationMinutes: 240
        )

        XCTAssertEqual(
            MapHomeSectionViewportMath.zoomed(
                from: origin,
                magnification: 100,
                anchorY: 600,
                height: 600
            ).durationMinutes,
            30
        )
        let fullDay = MapHomeSectionViewportMath.zoomed(
            from: origin,
            magnification: 0.01,
            anchorY: 600,
            height: 600
        )
        XCTAssertEqual(fullDay.startMinute, 0)
        XCTAssertEqual(fullDay.durationMinutes, 1_440)
    }

    func testMapHomeSectionDetailSliceRequiresClearRightSwipe() {
        XCTAssertTrue(MapHomeSectionViewportMath.acceptsDetailSlice(
            translation: CGSize(width: 80, height: 12)
        ))
        XCTAssertFalse(MapHomeSectionViewportMath.acceptsDetailSlice(
            translation: CGSize(width: 50, height: 0)
        ))
        XCTAssertFalse(MapHomeSectionViewportMath.acceptsDetailSlice(
            translation: CGSize(width: 80, height: 70)
        ))
        XCTAssertFalse(MapHomeSectionViewportMath.acceptsDetailSlice(
            translation: CGSize(width: -80, height: 0)
        ))
    }

    func testRequiredPermissionGateRequiresEveryVerifiedIntegration() {
        let gate = RequiredPermissionGate.evaluate(
            RequiredPermissionSnapshot(
                permissions: [
                    .location: .authorized,
                    .motion: .authorized,
                    .photos: .authorized,
                    .calendar: .authorized,
                    .notifications: .authorized,
                    .appUsage: .authorized,
                ],
                locationAlwaysAuthorized: true,
                locationPrecise: true,
                healthKitRequestCompleted: true,
                liveActivitiesEnabled: true
            )
        )

        XCTAssertTrue(gate.allSatisfied)
        XCTAssertTrue(gate.missing.isEmpty)
    }

    func testRequiredPermissionGateReportsStableMissingOrder() {
        XCTAssertEqual(
            RequiredPermissionGate.evaluate(
                RequiredPermissionSnapshot()
            ).missing,
            [
                .locationAlways,
                .locationPrecise,
                .motion,
                .healthKitRequestCompleted,
                .photos,
                .calendar,
                .notifications,
                .appUsage,
                .liveActivities,
            ]
        )
    }

    func testRequiredPermissionGateRejectsLimitedPhotosAndUsesHealthRequestCompletion() {
        let gate = RequiredPermissionGate.evaluate(
            RequiredPermissionSnapshot(
                permissions: [
                    .location: .authorized,
                    .motion: .authorized,
                    .health: .denied,
                    .photos: .limited,
                    .calendar: .authorized,
                    .notifications: .authorized,
                    .appUsage: .authorized,
                ],
                locationAlwaysAuthorized: true,
                locationPrecise: true,
                healthKitRequestCompleted: true,
                liveActivitiesEnabled: true
            )
        )

        XCTAssertEqual(gate.missing, [.photos])
    }
}
