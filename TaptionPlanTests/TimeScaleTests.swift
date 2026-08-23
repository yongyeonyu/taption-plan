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

    func testMapOverlayPinchRoutesOnlyCoveredControlsOutsideSidebar() {
        let viewport = CGSize(width: 390, height: 844)
        let route: (CGPoint) -> Bool = { point in
            MapHomeOverlayPinchMath.shouldForwardToMap(
                startLocation: point,
                viewportSize: viewport,
                sidebarWidth: 126,
                topOverlayHeight: 190,
                controlsWidth: 82,
                controlsHeight: 250
            )
        }

        XCTAssertTrue(route(CGPoint(x: 180, y: 80)))
        XCTAssertTrue(route(CGPoint(x: 45, y: 700)))
        XCTAssertFalse(route(CGPoint(x: 180, y: 400)))
        XCTAssertFalse(route(CGPoint(x: 330, y: 80)))
    }

    func testMapOverlayPinchPreservesCameraAndPublishesFinalValue() {
        let camera = MapCamera(
            centerCoordinate: CLLocationCoordinate2D(latitude: 37.5, longitude: 127),
            distance: 2_000,
            heading: 24,
            pitch: 35
        )
        let zoomed = MapHomeOverlayPinchMath.zoomedCamera(
            from: camera,
            magnification: 2
        )

        XCTAssertEqual(zoomed.centerCoordinate.latitude, 37.5, accuracy: 0.000_001)
        XCTAssertEqual(zoomed.centerCoordinate.longitude, 127, accuracy: 0.000_001)
        XCTAssertEqual(zoomed.distance, 1_000, accuracy: 0.01)
        XCTAssertEqual(zoomed.heading, 24, accuracy: 0.01)
        XCTAssertEqual(zoomed.pitch, 35, accuracy: 0.01)
        XCTAssertEqual(
            MapHomeOverlayPinchMath.zoomedCamera(
                from: MapCamera(centerCoordinate: camera.centerCoordinate, distance: 1_000),
                magnification: 1_000
            ).distance,
            80,
            accuracy: 0.01
        )
        XCTAssertEqual(
            MapHomeOverlayPinchMath.zoomedCamera(
                from: MapCamera(
                    centerCoordinate: camera.centerCoordinate,
                    distance: 30_000_000
                ),
                magnification: 0.001
            ).distance,
            30_000_000,
            accuracy: 0.01
        )
        XCTAssertFalse(
            MapHomeOverlayPinchMath.shouldPublish(
                lastUptime: 10,
                currentUptime: 10.005,
                isFinal: false
            )
        )
        XCTAssertTrue(
            MapHomeOverlayPinchMath.shouldPublish(
                lastUptime: 10,
                currentUptime: 10.005,
                isFinal: true
            )
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
        drag.begin(with: base, handleY: 150, nowUptime: 10)

        var state = try XCTUnwrap(
            drag.projectedState(
                translation: 151,
                trackHeight: 300,
                maxMinute: 1_439,
                sensitivity: 1,
                nowUptime: 10
            )
        )
        for frame in 1...60 {
            state = try XCTUnwrap(
                drag.projectedState(
                    translation: 151,
                    trackHeight: 300,
                    maxMinute: 1_439,
                    sensitivity: 1,
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
            handleY: 150,
            nowUptime: 10
        )

        var state = try XCTUnwrap(
            drag.projectedState(
                translation: -151,
                trackHeight: 300,
                maxMinute: 1_439,
                sensitivity: 1,
                nowUptime: 10
            )
        )
        for frame in 1...60 {
            state = try XCTUnwrap(
                drag.projectedState(
                    translation: -151,
                    trackHeight: 300,
                    maxMinute: 1_439,
                    sensitivity: 1,
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
            handleY: 150,
            nowUptime: 10
        )

        var state = try XCTUnwrap(
            drag.projectedState(
                translation: 151,
                trackHeight: 300,
                maxMinute: 600,
                sensitivity: 1,
                nowUptime: 10
            )
        )
        for frame in 1...180 {
            state = try XCTUnwrap(
                drag.projectedState(
                    translation: 151,
                    trackHeight: 300,
                    maxMinute: 600,
                    sensitivity: 1,
                    nowUptime: 10 + Double(frame) / 60
                )
            )
        }

        XCTAssertEqual(state.selectedMinute, 600)
        XCTAssertEqual(state.visibleStartMinute, 540)
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
            StartupMapLocationPolicy.latestValidReading(
                in: [validEarlier, invalidNewer, newestValid]
            )?.id,
            newestValid.id
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
}
