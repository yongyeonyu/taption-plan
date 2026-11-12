import MapKit
@preconcurrency import MapLibre
import SwiftUI
import XCTest
@testable import TaptionPlan

final class TimeScaleTests: XCTestCase {
    func testUnconfirmedQuickCategoriesFitInTwoOrderedRows() {
        let ids = ["work", "study", "sleep", "eating", "movement", "exercise", "hobby", "activity"]
        let byID = Dictionary(uniqueKeysWithValues: MapHomeSidebarMajorCategory.all.map { ($0.id, $0) })
        let categories = ids.compactMap { byID[$0] }
        let rows = MapHomeUnconfirmedQuickCategoryLayout.rows(from: categories)

        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.count == 4 })
        XCTAssertEqual(rows.flatMap { $0 }.map(\.id), ids)
    }

    private func makeDate(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 0
    ) -> Date {
        Calendar(identifier: .gregorian).date(
            from: DateComponents(
                year: year,
                month: month,
                day: day,
                hour: hour
            )
        )!
    }

    func testUnconfirmedReviewIncludesOnlySortedUnconfirmedIntervals() {
        let confirmed = MapHomeTimeRailSegment(
            startMinute: 120,
            endMinute: 180,
            categoryID: "work",
            title: "업무"
        )
        let laterGap = MapHomeTimeRailSegment(
            startMinute: 300,
            endMinute: 360,
            categoryID: "unconfirmed",
            title: "미확인"
        )
        let earlierGap = MapHomeTimeRailSegment(
            startMinute: 60,
            endMinute: 90,
            categoryID: "unconfirmed",
            title: "미확인"
        )

        XCTAssertEqual(
            MapHomeUnconfirmedReviewPolicy.segments(
                from: [laterGap, confirmed, earlierGap],
                for: makeDate(2026, 9, 26),
                asOf: makeDate(2026, 9, 27)
            ),
            [earlierGap, laterGap]
        )
        XCTAssertEqual(MapHomeUnconfirmedReviewPolicy.midpointMinute(for: earlierGap), 75)
    }

    func testUnconfirmedReviewClipsTodayAtCurrentMinute() {
        let day = makeDate(2026, 9, 27)
        let now = day.addingTimeInterval(9 * 3_600 + 30 * 60)
        let gap = MapHomeTimeRailSegment(
            startMinute: 8 * 60,
            endMinute: 12 * 60,
            categoryID: "unconfirmed",
            title: "미확인"
        )
        let future = MapHomeTimeRailSegment(
            startMinute: 10 * 60,
            endMinute: 11 * 60,
            categoryID: "unconfirmed",
            title: "미확인"
        )

        let visible = MapHomeUnconfirmedReviewPolicy.segments(
            from: [future, gap], for: day, asOf: now
        )
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible.first?.startMinute, 480)
        XCTAssertEqual(visible.first?.endMinute, 570)
    }

    func testUnconfirmedReviewAvailabilityIgnoresFutureAndConfirmedIntervals() {
        let day = makeDate(2026, 9, 27)
        let now = day.addingTimeInterval(9 * 3_600 + 30 * 60)
        let confirmed = MapHomeTimeRailSegment(
            startMinute: 480,
            endMinute: 540,
            categoryID: "work",
            title: "업무"
        )
        let futureGap = MapHomeTimeRailSegment(
            startMinute: 600,
            endMinute: 660,
            categoryID: "unconfirmed",
            title: "미확인"
        )
        let pastGap = MapHomeTimeRailSegment(
            startMinute: 480,
            endMinute: 600,
            categoryID: "unconfirmed",
            title: "미확인"
        )

        XCTAssertFalse(
            MapHomeUnconfirmedReviewPolicy.hasSegments(
                from: [confirmed], for: day, asOf: now
            )
        )
        XCTAssertFalse(
            MapHomeUnconfirmedReviewPolicy.hasSegments(
                from: [futureGap], for: day, asOf: now
            )
        )
        XCTAssertTrue(
            MapHomeUnconfirmedReviewPolicy.hasSegments(
                from: [pastGap], for: day, asOf: now
            )
        )
        XCTAssertFalse(
            MapHomeUnconfirmedReviewPolicy.hasSegments(
                from: [pastGap], for: makeDate(2026, 9, 28), asOf: now
            )
        )
    }

    func testQuestionMarkMarkersOnlyExistForActualVisibleUnconfirmedActivity() {
        let day = makeDate(2026, 9, 27)
        let now = day.addingTimeInterval(12 * 3_600)
        let confirmed = MapHomeTimeRailSegment(
            startMinute: 60,
            endMinute: 120,
            categoryID: "work",
            title: "업무"
        )
        let gap = MapHomeTimeRailSegment(
            startMinute: 180,
            endMinute: 240,
            categoryID: "unconfirmed",
            title: "미확인"
        )
        let futureGap = MapHomeTimeRailSegment(
            startMinute: 13 * 60,
            endMinute: 14 * 60,
            categoryID: "unconfirmed",
            title: "미확인"
        )

        XCTAssertTrue(
            MapHomeUnconfirmedReviewPolicy.visibleReviewTargets(
                from: [], in: 0...1_440, for: day, asOf: now
            ).isEmpty
        )
        XCTAssertTrue(
            MapHomeUnconfirmedReviewPolicy.visibleReviewTargets(
                from: [confirmed], in: 0...1_440, for: day, asOf: now
            ).isEmpty
        )
        XCTAssertEqual(
            MapHomeUnconfirmedReviewPolicy.visibleReviewTargets(
                from: [confirmed, futureGap, gap],
                in: 150...250,
                for: day,
                asOf: now
            ),
            [gap]
        )
        XCTAssertTrue(
            MapHomeUnconfirmedReviewPolicy.visibleReviewTargets(
                from: [gap], in: 250...300, for: day, asOf: now
            ).isEmpty
        )
    }

    func testContinuousUnconfirmedReviewAdvancesWrapsAndFinishes() {
        let first = MapHomeTimeRailSegment(startMinute: 60, endMinute: 90,
            categoryID: "unconfirmed", title: "미확인")
        let second = MapHomeTimeRailSegment(startMinute: 120, endMinute: 150,
            categoryID: "unconfirmed", title: "미확인")
        let confirmed = MapHomeTimeRailSegment(startMinute: 100, endMinute: 110,
            categoryID: "work", title: "업무")
        XCTAssertEqual(MapHomeUnconfirmedReviewPolicy.nextSegment(
            after: first, in: [second, confirmed, first]), second)
        XCTAssertEqual(MapHomeUnconfirmedReviewPolicy.nextSegment(
            after: second, in: [second, confirmed, first]), first)
        XCTAssertNil(MapHomeUnconfirmedReviewPolicy.nextSegment(
            after: first, in: [confirmed, first]))
        XCTAssertNil(MapHomeUnconfirmedReviewPolicy.nextSegment(after: first, in: []))
    }

    func testUnconfirmedReviewTargetShowsAndSelectsOnlyItsSegment() {
        let day = makeDate(2026, 9, 27)
        let now = day.addingTimeInterval(10 * 3_600 + 30 * 60)
        let firstGap = MapHomeTimeRailSegment(
            startMinute: 8 * 60,
            endMinute: 9 * 60,
            categoryID: "unconfirmed",
            title: "미확인"
        )
        let selectedGap = MapHomeTimeRailSegment(
            startMinute: 9 * 60 + 30,
            endMinute: 11 * 60,
            categoryID: "unconfirmed",
            title: "미확인",
            sourceIDs: [UUID()]
        )
        let futureGap = MapHomeTimeRailSegment(
            startMinute: 12 * 60,
            endMinute: 13 * 60,
            categoryID: "unconfirmed",
            title: "미확인"
        )
        let confirmed = MapHomeTimeRailSegment(
            startMinute: 9 * 60,
            endMinute: 9 * 60 + 30,
            categoryID: "work",
            title: "업무"
        )
        let allTargets = MapHomeUnconfirmedReviewPolicy.reviewTargets(
            from: [futureGap, confirmed, selectedGap, firstGap],
            focusingOn: nil,
            for: day,
            asOf: now,
            calendar: Calendar(identifier: .gregorian)
        )
        let selectedTargets = MapHomeUnconfirmedReviewPolicy.reviewTargets(
            from: [futureGap, confirmed, selectedGap, firstGap],
            focusingOn: selectedGap,
            for: day,
            asOf: now,
            calendar: Calendar(identifier: .gregorian)
        )

        XCTAssertEqual(allTargets.map(\.startMinute), [480, 570])
        XCTAssertEqual(allTargets.map(\.endMinute), [540, 630])
        XCTAssertEqual(selectedTargets, [allTargets[1]])
        XCTAssertEqual(selectedTargets.first?.sourceIDs, selectedGap.sourceIDs)
    }

    func testUnconfirmedReviewMarkersKeepExactMidpointsWhenNearby() throws {
        let segments = [
            MapHomeTimeRailSegment(
                startMinute: 60,
                endMinute: 75,
                categoryID: "unconfirmed",
                title: "미확인"
            ),
            MapHomeTimeRailSegment(
                startMinute: 76,
                endMinute: 90,
                categoryID: "unconfirmed",
                title: "미확인"
            ),
            MapHomeTimeRailSegment(
                startMinute: 91,
                endMinute: 105,
                categoryID: "unconfirmed",
                title: "미확인"
            )
        ]
        let trackHeight: CGFloat = 720
        let centers = MapHomeTimeSidebarMath.unconfirmedReviewMarkerCenters(
            segments: segments,
            window: 0...1_440,
            trackHeight: trackHeight
        )
        let orderedCenters = segments.compactMap { centers[$0.id] }

        XCTAssertEqual(orderedCenters.count, segments.count)
        let expectedOffsets: [CGFloat] = [33.75, 41.5, 49]
        for (segment, offset) in zip(segments, expectedOffsets) {
            XCTAssertEqual(
                try XCTUnwrap(centers[segment.id]),
                MapHomeTimeSidebarMath.verticalInset + offset,
                accuracy: 0.0001
            )
        }
        XCTAssertLessThan(orderedCenters[1] - orderedCenters[0],
                          MapHomeTimeSidebarMath.reviewMarkerHitHeight)
    }

    func testUnconfirmedReviewMarkersKeepDayBoundaryPositions() throws {
        let first = MapHomeTimeRailSegment(startMinute: 0, endMinute: 1,
                                          categoryID: "unconfirmed", title: "미확인")
        let last = MapHomeTimeRailSegment(startMinute: 1_439, endMinute: 1_440,
                                         categoryID: "unconfirmed", title: "미확인")
        let centers = MapHomeTimeSidebarMath.unconfirmedReviewMarkerCenters(
            segments: [first, last], window: 0...1_440,
            trackHeight: 720, verticalInset: 10
        )
        XCTAssertEqual(try XCTUnwrap(centers[first.id]), 10.25, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(centers[last.id]), 729.75, accuracy: 0.0001)
    }

    func testUnconfirmedReviewMarkersUseClippedFractionalMidpointsWhenZoomed() throws {
        let segments = [
            MapHomeTimeRailSegment(startMinute: 590, endMinute: 605,
                                   categoryID: "unconfirmed", title: "미확인"),
            MapHomeTimeRailSegment(startMinute: 601, endMinute: 602,
                                   categoryID: "unconfirmed", title: "미확인"),
            MapHomeTimeRailSegment(startMinute: 658, endMinute: 700,
                                   categoryID: "unconfirmed", title: "미확인"),
            MapHomeTimeRailSegment(startMinute: 590, endMinute: 600,
                                   categoryID: "unconfirmed", title: "미확인")
        ]
        let centers = MapHomeTimeSidebarMath.unconfirmedReviewMarkerCenters(
            segments: segments, window: 600...660, trackHeight: 600, verticalInset: 12
        )
        XCTAssertEqual(centers.count, 3)
        XCTAssertEqual(try XCTUnwrap(centers[segments[0].id]), 37, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(centers[segments[1].id]), 27, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(centers[segments[2].id]), 602, accuracy: 0.0001)
        XCTAssertNil(centers[segments[3].id])
    }

    func testUnconfirmedReviewMarkersAllowIdenticalCentersInAnyInputOrder() throws {
        let first = MapHomeTimeRailSegment(startMinute: 603, endMinute: 607,
                                          categoryID: "unconfirmed", title: "미확인")
        let second = MapHomeTimeRailSegment(startMinute: 604, endMinute: 606,
                                           categoryID: "unconfirmed", title: "미확인")
        let centers = MapHomeTimeSidebarMath.unconfirmedReviewMarkerCenters(
            segments: [first, second], window: 600...660,
            trackHeight: 600, verticalInset: 12
        )
        let reversedCenters = MapHomeTimeSidebarMath.unconfirmedReviewMarkerCenters(
            segments: [second, first], window: 600...660,
            trackHeight: 600, verticalInset: 12
        )
        XCTAssertEqual(try XCTUnwrap(centers[first.id]), 62, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(centers[second.id]), 62, accuracy: 0.0001)
        XCTAssertEqual(centers, reversedCenters)
    }

    func testUnconfirmedReviewOffersTodayAndPreviousSevenDays() {
        let dates = MapHomeUnconfirmedReviewPolicy.recentDates(asOf: makeDate(2026, 9, 27, 15))
        XCTAssertEqual(dates.count, 8)
        XCTAssertEqual(dates.first, makeDate(2026, 9, 20))
        XCTAssertEqual(dates.last, makeDate(2026, 9, 27))
    }

    func testQuickConfirmedIntervalDisappearsFromUnconfirmedReview() {
        let day = makeDate(2026, 9, 26)
        let span = TimeSpan(
            start: day.addingTimeInterval(9 * 3_600),
            end: day.addingTimeInterval(10 * 3_600)
        )
        let work = MapHomeSidebarMajorCategory.presentation(for: "work")
        let option = ActivityCorrectionOption(
            id: "phase.work",
            title: work.title,
            behavior: nil,
            categoryID: work.id,
            systemImage: work.systemImage,
            isAutomatic: false,
            isCustom: false
        )
        let request = ActivitySectionEditRequest(
            sourceIDs: [],
            originalSpan: span,
            originalOption: ActivitySectionOverrideEngine.unconfirmedOption,
            mode: .replace(editedSpan: span, option: option)
        )
        let records = ActivitySectionOverrideEngine.records(for: request)
        let rail = MapHomeTimeRailSegmentEngine.segments(
            from: records,
            on: day,
            asOf: day.addingTimeInterval(86_400)
        )
        let remaining = MapHomeUnconfirmedReviewPolicy.segments(
            from: rail,
            for: day,
            asOf: day.addingTimeInterval(86_400)
        )

        XCTAssertEqual(records.map(\.categoryID), ["work"])
        XCTAssertTrue(remaining.allSatisfy { $0.endMinute <= 540 || $0.startMinute >= 600 })
    }

    func testTimeSidebarHourLabelsKeepAnInnerTrailingMargin() {
        let defaultCenter = MapHomeTimeSidebarMath.rulerLabelCenterX(
            railOriginX: 69,
            railWidth: 44,
            numericColumnWidth: 32,
            trailingInset: 0
        )
        let insetCenter = MapHomeTimeSidebarMath.rulerLabelCenterX(
            railOriginX: 69,
            railWidth: 44,
            numericColumnWidth: 32
        )

        XCTAssertEqual(defaultCenter - insetCenter, 6)
    }

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

    func testTimelineInteractionFrameGateSeparates240HzInputFromDisplayRates() {
        XCTAssertEqual(
            TimelineInteractionFrameGate.inputInterval,
            1.0 / 240.0,
            accuracy: 0.000_000_001
        )
        XCTAssertEqual(
            TimelineInteractionFrameGate.minimumInterval,
            1.0 / 60.0,
            accuracy: 0.000_000_001
        )

        var displayLastUptime = 0.0
        var displayCount = 0
        for sample in 0...240 {
            if TimelineInteractionFrameGate.shouldRender(
                lastUptime: &displayLastUptime,
                nowUptime: Double(sample) / 240.0
            ) {
                displayCount += 1
            }
        }
        XCTAssertLessThanOrEqual(displayCount, 61)

        var cameraLastUptime = 0.0
        var cameraCount = 0
        for sample in 0...240 {
            if TimelineInteractionFrameGate.shouldRender(
                lastUptime: &cameraLastUptime,
                nowUptime: Double(sample) / 240.0,
                minimumInterval: 1.0 / 30.0
            ) {
                cameraCount += 1
            }
        }
        XCTAssertGreaterThan(cameraCount, 25)
        XCTAssertLessThanOrEqual(cameraCount, 32)
    }

    func testTimelineInteractionFrameGateDoesNotDoublePublishAtZeroTimestamp() {
        var lastUptime = 0.0

        XCTAssertTrue(
            TimelineInteractionFrameGate.shouldRender(
                lastUptime: &lastUptime,
                nowUptime: 0
            )
        )
        XCTAssertFalse(
            TimelineInteractionFrameGate.shouldRender(
                lastUptime: &lastUptime,
                nowUptime: TimelineInteractionFrameGate.inputInterval
            )
        )
    }

    func testDuplicateCameraAndSubpixelMarkerSamplesDoNotDelayChangedPan() {
        let center = CLLocationCoordinate2D(latitude: 37, longitude: 127)
        let region = MKCoordinateRegion(center: center,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
        let frame = MapHomeCameraFrame(camera: MapCamera(centerCoordinate: center, distance: 1_000), region: region)
        let next = MapHomeCameraFrame(camera: MapCamera(centerCoordinate: center, distance: 900), region: region)
        let camera = MapHomeCameraFrameProjection()
        XCTAssertEqual(camera.submit(frame, nowUptime: 1), frame)
        XCTAssertNil(camera.submit(frame, nowUptime: 1.02))
        XCTAssertEqual(camera.submit(next, nowUptime: 1.024), next)
        let marker = MapHomeStickmanViewportProjection()
        XCTAssertEqual(marker.submit(.zero, nowUptime: 1), .zero)
        XCTAssertNil(marker.submit(CGPoint(x: 0.1, y: 0.1), nowUptime: 1.02))
        XCTAssertEqual(marker.submit(CGPoint(x: 2, y: 2), nowUptime: 1.024), CGPoint(x: 2, y: 2))
    }

    func testTimelineDuplicateInputDoesNotDelayChangedTouch() {
        let projection = TimelineNLEProjection<Int>()
        XCTAssertEqual(projection.submit(1, nowUptime: 1), 1)
        XCTAssertNil(projection.submit(1, nowUptime: 1.02))
        XCTAssertEqual(projection.submit(2, nowUptime: 1.024), 2)
        XCTAssertEqual(projection.finish(with: 3, nowUptime: 1.025), 3)
    }

    func testMapContentKeyDistinguishesLayerGeometryAndAppearance() {
        let coordinate = CLLocationCoordinate2D(latitude: 37, longitude: 127)
        let route = MapHomeVectorRoute(id: "route#|", coordinates: [coordinate],
            geometrySignature: 1, colorHex: "#ffffff", opacity: 1)
        let base = MapHomeVectorContentKey(historical: [route.contentKey], active: nil,
            expected: [], subway: [])
        XCTAssertEqual(base, MapHomeVectorContentKey(historical: [route.contentKey], active: nil,
            expected: [], subway: []))
        XCTAssertNotEqual(base, MapHomeVectorContentKey(historical: [], active: route.contentKey,
            expected: [], subway: []))
        for changed in [
            MapHomeVectorRouteContentKey(id: route.id, geometrySignature: 2, colorHex: "#ffffff", opacity: 1),
            MapHomeVectorRouteContentKey(id: route.id, geometrySignature: 1, colorHex: "#000000", opacity: 1),
            MapHomeVectorRouteContentKey(id: route.id, geometrySignature: 1, colorHex: "#ffffff", opacity: 0.5)
        ] {
            XCTAssertNotEqual(base, MapHomeVectorContentKey(historical: [changed], active: nil,
                expected: [], subway: []))
        }
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
        XCTAssertNil(projection.finish(with: final, nowUptime: 1.002))
    }

    func testMapHomeSidebarRailSnapshotIndexesOnlyVisibleIntervals() {
        let snapshot = MapHomeTimeSidebarRailSnapshot([
            MapHomeTimeRailSegment(
                startMinute: 0,
                endMinute: 120,
                categoryID: "work",
                title: "이전"
            ),
            MapHomeTimeRailSegment(
                startMinute: 30,
                endMinute: 90,
                categoryID: "study",
                title: "표시"
            ),
            MapHomeTimeRailSegment(
                startMinute: 90,
                endMinute: 120,
                categoryID: "sleep",
                title: "다음"
            ),
        ])

        XCTAssertEqual(
            snapshot.visibleSegments(in: 45...90).map(\.title),
            ["이전", "표시"]
        )
        XCTAssertEqual(
            snapshot.visibleSegments(in: 90...120).map(\.title),
            ["이전", "다음"]
        )
        XCTAssertEqual(
            MapHomeTimeSidebarRailSnapshot([])
                .visibleSegments(in: 0...1_440),
            []
        )
    }

    func testMapHomeSidebarDateChangeProjectsTheSelectedDaysMajorCategories() {
        let calendar = Calendar(identifier: .gregorian)
        let firstDay = calendar.date(
            from: DateComponents(year: 2026, month: 9, day: 1)
        )!
        let secondDay = calendar.date(byAdding: .day, value: 1, to: firstDay)!
        let records = [
            ActualRecord(
                planID: nil,
                title: "업무",
                categoryID: "work",
                startedAt: firstDay.addingTimeInterval(9 * 3_600),
                endedAt: firstDay.addingTimeInterval(10 * 3_600),
                source: .manual,
                manuallyCorrected: true
            ),
            ActualRecord(
                planID: nil,
                title: "수업",
                categoryID: "study",
                startedAt: secondDay.addingTimeInterval(13 * 3_600),
                endedAt: secondDay.addingTimeInterval(14 * 3_600),
                source: .manual,
                manuallyCorrected: true
            ),
        ]

        let first = MapHomeTimeRailSegmentEngine.segments(
            from: records,
            on: firstDay,
            asOf: secondDay.addingTimeInterval(2 * 86_400),
            calendar: calendar
        )
        let second = MapHomeTimeRailSegmentEngine.segments(
            from: records,
            on: secondDay,
            asOf: secondDay.addingTimeInterval(2 * 86_400),
            calendar: calendar
        )

        XCTAssertTrue(first.contains { $0.categoryID == "work" })
        XCTAssertFalse(first.contains { $0.categoryID == "study" })
        XCTAssertTrue(second.contains { $0.categoryID == "study" })
        XCTAssertFalse(second.contains { $0.categoryID == "work" })
    }

    func testMapHomeTimeRailMergesAdjacentSourcesAndKeepsTheirIDs() throws {
        let calendar = Calendar(identifier: .gregorian)
        let day = makeDate(2026, 9, 1)
        let first = ActualRecord(
            planID: nil,
            title: "업무",
            categoryID: "work",
            startedAt: day.addingTimeInterval(9 * 60 * 60),
            endedAt: day.addingTimeInterval(10 * 60 * 60),
            source: .manual,
            manuallyCorrected: true
        )
        let second = ActualRecord(
            planID: nil,
            title: "업무",
            categoryID: "work",
            startedAt: day.addingTimeInterval(10 * 60 * 60),
            endedAt: day.addingTimeInterval(11 * 60 * 60),
            source: .manual,
            manuallyCorrected: true
        )
        let segments = MapHomeTimeRailSegmentEngine.segments(
            from: [first, second],
            on: day,
            asOf: day.addingTimeInterval(24 * 60 * 60),
            calendar: calendar
        )

        let work = try XCTUnwrap(segments.first { $0.categoryID == "work" })
        XCTAssertEqual(work.startMinute, 540)
        XCTAssertEqual(work.endMinute, 660)
        XCTAssertEqual(
            work.sourceIDs,
            [first.id, second.id].sorted { $0.uuidString < $1.uuidString }
        )
    }

    func testMapHomeTimeRailDenseCandidateScale() {
        let day = makeDate(2026, 9, 1)
        let dayEnd = day.addingTimeInterval(24 * 60 * 60)
        let actuals = (0..<10_000).map { index in
            let minute = index % 1_200
            let second = Double(index / 1_200)
            let start = day.addingTimeInterval(Double(minute * 60) + second)
            return ActualRecord(
                planID: nil,
                title: "업무",
                categoryID: "work",
                startedAt: start,
                endedAt: min(dayEnd, start.addingTimeInterval(4 * 60 * 60)),
                source: .manual,
                confidence: .high,
                manuallyCorrected: true
            )
        }
        let clock = ContinuousClock()
        let startedAt = clock.now
        let segments = MapHomeTimeRailSegmentEngine.segments(
            from: actuals,
            on: day,
            asOf: dayEnd.addingTimeInterval(60),
            calendar: Calendar(identifier: .gregorian)
        )
        print(
            "MPC0921A01 rail 10000 candidates: "
                + String(describing: startedAt.duration(to: clock.now))
        )

        XCTAssertEqual(segments.first?.startMinute, 0)
        XCTAssertEqual(segments.last?.endMinute, 1_440)
        XCTAssertTrue(
            zip(segments, segments.dropFirst()).allSatisfy {
                $0.endMinute == $1.startMinute
            }
        )
    }

    func testMapRouteDocumentGateCollapses240HzSourceCallbacksIntoOneCommit() {
        let gate = MapHomeRouteDocumentProjectionGate()

        for sample in 1...240 {
            gate.deferRefresh(preparingReadings: sample == 120)
        }

        XCTAssertEqual(
            gate.consumeDeferredRefresh(),
            MapHomeRouteDocumentRefresh(preparesReadings: true)
        )
        XCTAssertNil(gate.consumeDeferredRefresh())
    }

    func testMapHomeCameraProjectionCoalescesContinuousInputAndFlushesLatestFrame() {
        let baseCenter = CLLocationCoordinate2D(latitude: 37.5, longitude: 127.0)
        let baseCamera = MapCamera(
            centerCoordinate: baseCenter,
            distance: 1_000,
            heading: 0,
            pitch: 0
        )
        let baseRegion = MKCoordinateRegion(
            center: baseCenter,
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
        )
        let projection = MapHomeCameraFrameProjection()
        let initial = MapHomeCameraFrame(camera: baseCamera, region: baseRegion)
        XCTAssertEqual(projection.submit(initial, nowUptime: 1), initial)

        let latestCenter = CLLocationCoordinate2D(
            latitude: baseCenter.latitude + 0.001,
            longitude: baseCenter.longitude + 0.001
        )
        let latest = MapHomeCameraFrame(
            camera: MapCamera(
                centerCoordinate: latestCenter,
                distance: 1_000,
                heading: 0,
                pitch: 0
            ),
            region: MKCoordinateRegion(
                center: latestCenter,
                span: baseRegion.span
            )
        )
        XCTAssertNil(projection.submit(latest, nowUptime: 1.001))
        XCTAssertEqual(projection.finish(nowUptime: 1.001), latest)

        var renderedCount = 0
        for sample in 1...240 {
            let center = CLLocationCoordinate2D(
                latitude: baseCenter.latitude + Double(sample) * 0.000_001,
                longitude: baseCenter.longitude
            )
            let frame = MapHomeCameraFrame(
                camera: MapCamera(
                    centerCoordinate: center,
                    distance: 1_000,
                    heading: 0,
                    pitch: 0
                ),
                region: MKCoordinateRegion(center: center, span: baseRegion.span)
            )
            if projection.submit(frame, nowUptime: 1 + Double(sample) / 240) != nil {
                renderedCount += 1
            }
        }
        XCTAssertLessThanOrEqual(renderedCount, 61)
        XCTAssertEqual(
            projection.latestFrame?.centerLatitude,
            baseCenter.latitude + 240 * 0.000_001
        )
    }

    func testMapHomeCameraProjectionLimitsParentReadbackAndFlushesFinalFrame() {
        let projection = MapHomeCameraFrameProjection()

        XCTAssertTrue(
            projection.shouldPublishParentReadback(
                nowUptime: 1,
                isFinal: false
            )
        )
        XCTAssertFalse(
            projection.shouldPublishParentReadback(
                nowUptime: 1.02,
                isFinal: false
            )
        )
        XCTAssertFalse(
            projection.shouldPublishParentReadback(
                nowUptime: 1.2,
                isFinal: false
            )
        )
        XCTAssertTrue(
            projection.shouldPublishParentReadback(
                nowUptime: 1.26,
                isFinal: false
            )
        )
        XCTAssertTrue(
            projection.shouldPublishParentReadback(
                nowUptime: 1.261,
                isFinal: true
            )
        )

        projection.reset()
        XCTAssertTrue(
            projection.shouldPublishParentReadback(
                nowUptime: 2,
                isFinal: false
            )
        )
    }

    func testStickmanViewportProjectionCoalesces240HzAndFlushesLatestPoint() {
        let projection = MapHomeStickmanViewportProjection()
        let initial = CGPoint(x: 100, y: 200)
        let latest = CGPoint(x: 120, y: 240)

        XCTAssertEqual(projection.submit(initial, nowUptime: 1), initial)
        XCTAssertNil(projection.submit(latest, nowUptime: 1.001))
        XCTAssertEqual(projection.finish(nowUptime: 1.001), latest)

        let highRateProjection = MapHomeStickmanViewportProjection()
        var renderedCount = 0
        for sample in 1...240 {
            let point = CGPoint(x: sample, y: sample)
            if highRateProjection.submit(
                point,
                nowUptime: 2 + Double(sample) / 240
            ) != nil {
                renderedCount += 1
            }
        }
        XCTAssertLessThanOrEqual(renderedCount, 61)
    }

    @MainActor
    func testVectorViewportStoreDefersParentReadbackUntilFinalPoint() {
        let store = MapHomeVectorViewportStore()
        for sample in 0..<480 {
            XCTAssertFalse(store.shouldPublishParentReadback(
                nowUptime: Double(sample) / 240, isFinal: false))
        }
        XCTAssertTrue(store.shouldPublishParentReadback(nowUptime: 2, isFinal: true))

        let initial = CGPoint(x: 100, y: 200)
        let latest = CGPoint(x: 120, y: 240)
        store.updateStickmanPoint(initial, nowUptime: 2)
        store.updateStickmanPoint(latest, nowUptime: 2.001)
        XCTAssertEqual(store.stickmanPoint, initial)

        store.finishStickmanPoint(nowUptime: 2.001)
        XCTAssertEqual(store.stickmanPoint, latest)
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
                verticalInset: MapHomeTimeSidebarMath.verticalInset,
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
        XCTAssertEqual(MapHomeOverlayLayoutMath.sharedBottomMargin, 48)
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

    func testTimeSidebarUsesItsOwnExpandedTopAndBottomMargins() {
        let sidebar = MapHomeOverlayLayoutMath.timeSidebarFrame(
            viewportHeight: 844,
            topOverlayHeight: 100
        )
        let mapControls = MapHomeOverlayLayoutMath.alignedRailFrame(
            viewportHeight: 844,
            topInset: 146,
            bottomInset: MapHomeOverlayLayoutMath.sharedBottomMargin
        )
        let largeScreenSidebar = MapHomeOverlayLayoutMath.timeSidebarFrame(
            viewportHeight: 1_400,
            topOverlayHeight: 100
        )

        XCTAssertEqual(sidebar.minY, 120)
        XCTAssertEqual(sidebar.maxY, 812)
        XCTAssertLessThan(sidebar.minY, mapControls.minY)
        XCTAssertGreaterThan(sidebar.maxY, mapControls.maxY)
        XCTAssertEqual(largeScreenSidebar.height, 1_248)
        XCTAssertEqual(largeScreenSidebar.maxY, 1_368)
        XCTAssertEqual(
            MapHomeOverlayLayoutMath.timeSidebarHeight(availableHeight: 1_400),
            1_400
        )
        XCTAssertEqual(MapHomeTimeSidebarMath.verticalInset, 40)
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
        XCTAssertGreaterThan(MapHomeLayerPriority.stickman, MapHomeLayerPriority.map)
        XCTAssertGreaterThan(MapHomeLayerPriority.sidebar, MapHomeLayerPriority.stickman)
        XCTAssertGreaterThan(MapHomeLayerPriority.search, MapHomeLayerPriority.sidebar)
        XCTAssertGreaterThan(MapHomeLayerPriority.search, MapHomeLayerPriority.map)
        XCTAssertGreaterThan(MapHomeLayerPriority.menu, MapHomeLayerPriority.search)
        XCTAssertGreaterThan(MapHomeLayerPriority.header, MapHomeLayerPriority.menu)
    }

    func testAppleMapStickmanLayerStaysAbovePlaceAnnotations() {
        XCTAssertGreaterThan(
            MapHomeAppleAnnotationLayerPriority.stickman,
            MapHomeAppleAnnotationLayerPriority.place
        )
        XCTAssertGreaterThan(
            MapHomeAppleAnnotationLayerPriority.stickman,
            MapHomeAppleAnnotationLayerPriority.userLocation
        )
    }

    @MainActor
    func testWalkerOverlayStaysOutsideAnnotationOrderingAndKeepsFootCoordinate() {
        let mapView = MKMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let coordinate = CLLocationCoordinate2D(latitude: 37.55, longitude: 126.75)
        let house = MKPointAnnotation()
        house.coordinate = coordinate
        mapView.addAnnotation(house)
        let walker = UIView(frame: CGRect(origin: .zero, size: MapHomeStickmanMarker.size))
        for distance in [300.0, 3_000.0, 30_000.0] {
            mapView.setCamera(MKMapCamera(
                lookingAtCenter: coordinate, fromDistance: distance, pitch: 0, heading: 45
            ), animated: false)
            mapView.selectAnnotation(house, animated: false)
            MapHomeAppleWalkerOverlayLayout.update(walker, coordinate: coordinate, on: mapView)
            XCTAssertTrue(walker.superview === mapView)
            XCTAssertTrue(mapView.subviews.last === walker)
            XCTAssertEqual(mapView.annotations.filter { !($0 is MKUserLocation) }.count, 1)
            let projected = mapView.convert(coordinate, toPointTo: mapView)
            XCTAssertEqual(walker.center.x, projected.x, accuracy: 0.001)
            XCTAssertEqual(walker.frame.maxY, projected.y, accuracy: 0.001)
            mapView.deselectAnnotation(house, animated: false)
        }
    }

    @MainActor
    func testWalkerViewportUpdatesDoNotRestackMapSubviews() {
        let mapView = MKMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let coordinate = CLLocationCoordinate2D(latitude: 37.55, longitude: 126.75)
        let walker = UIView(frame: CGRect(origin: .zero, size: MapHomeStickmanMarker.size))

        MapHomeAppleWalkerOverlayLayout.update(walker, coordinate: coordinate, on: mapView)
        let mapKitSubview = UIView(frame: .zero)
        mapView.addSubview(mapKitSubview)
        let newTopSubview = mapView.subviews.last
        mapView.setRegion(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 37.56, longitude: 126.76),
                latitudinalMeters: 800,
                longitudinalMeters: 800
            ),
            animated: false
        )

        MapHomeAppleWalkerOverlayLayout.update(walker, coordinate: coordinate, on: mapView)

        XCTAssertTrue(mapView.subviews.last === newTopSubview)
        XCTAssertEqual(walker.layer.zPosition, MapHomeAppleAnnotationLayerPriority.stickman)
        let projected = mapView.convert(coordinate, toPointTo: mapView)
        // 흔들림을 막으려 원점을 기기 픽셀에 맞춘다(CTR1103A02). 창 밖 시험 뷰는 배율 1이라 반 픽셀은 0.5pt다.
        XCTAssertEqual(walker.center.x, projected.x, accuracy: 0.5)
        XCTAssertEqual(
            walker.frame.maxY,
            projected.y,
            accuracy: 0.5
        )
    }

    func testWeatherTimelineCapsulesAttachFlushToSidebarPanel() {
        let weatherRailWidth: CGFloat = 62
        let timeRailWidth: CGFloat = 44
        let originX = MapHomeWeatherRailAlignmentMath.weatherOriginX(
            weatherRailWidth: weatherRailWidth,
            timeRailWidth: timeRailWidth
        )
        let itemWidth = MapHomeWeatherRailLayout.itemWidth(railWidth: weatherRailWidth)
        let weatherItemRightX = originX
            + MapHomeWeatherRailLayout.itemCenterX(
                railWidth: weatherRailWidth,
                itemWidth: itemWidth
            )
            + itemWidth / 2

        XCTAssertEqual(
            weatherItemRightX,
            MapHomeTimeSidebarMath.handleLaneWidth
                - MapHomeTimeSidebarMath.weatherDockGap
        )
        XCTAssertEqual(MapHomeTimeSidebarMath.weatherDockGap, 4)
    }

    func testSidebarSelectionHandleUsesApprovedWhiteAndDeepPinkStyle() {
        XCTAssertEqual(MapHomeTimeSidebarStyle.deepPinkHex, "#D94772")
        XCTAssertEqual(MapHomeTimeSidebarStyle.handleFontSize, 12)
        XCTAssertEqual(MapHomeTimeSidebarStyle.handleCornerRadius, 18)
    }

    func testWeatherTimelineKeepsItsCenterWhenPlayheadOverlaps() {
        let weatherOriginX = MapHomeWeatherRailAlignmentMath.weatherOriginX(
            weatherRailWidth: 62,
            timeRailWidth: 44
        )
        XCTAssertEqual(
            weatherOriginX + 62 / 2,
            weatherOriginX + 31
        )
    }

    func testSidebarRulerFontStaysFixedAcrossAllZoomSteps() {
        XCTAssertEqual(
            MapHomeTimeSidebarMath.zoomDurations.map {
                MapHomeTimeSidebarMath.rulerFontSize(durationMinutes: $0)
            },
            [10, 10, 10, 10, 10]
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
            searchBottom: 98
        )
        XCTAssertEqual(target.x, viewport.width / 2)
        XCTAssertEqual(target.y, 471)

        let source = MapHomeCameraLayoutMath.cameraCenterSourcePoint(
            currentLocationPoint: CGPoint(x: 180, y: 500),
            targetPoint: target,
            viewportSize: viewport
        )
        XCTAssertEqual(source.x, 180)
        XCTAssertEqual(source.y, 451)
        XCTAssertTrue(
            MapHomeCameraLayoutMath.isCentered(
                locationPoint: CGPoint(x: 203, y: 476),
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

    @MainActor
    func testMapLongPressIgnoresAnnotationTouches() {
        let annotation = MKAnnotationView(
            annotation: nil,
            reuseIdentifier: "test"
        )
        let child = UIView()
        annotation.addSubview(child)

        XCTAssertTrue(MapHomeLongPressRoutingMath.isAnnotationTouch(child))
        XCTAssertTrue(MapHomeLongPressRoutingMath.isAnnotationTouch(annotation))
        XCTAssertFalse(MapHomeLongPressRoutingMath.isAnnotationTouch(UIView()))
        XCTAssertFalse(MapHomeLongPressRoutingMath.isAnnotationTouch(nil))
    }

    func testMapLongPressOffersLocationAndMapMemoActions() {
        XCTAssertEqual(
            MapHomeLongPressAction.allCases.map(\.rawValue),
            ["location", "memo"]
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
            MapHomeTimeSidebarPinchMath.stepOffset(magnification: 1.11),
            1
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

    func testMapRouteGeometrySignatureIncludesMiddleCoordinates() {
        let first = CLLocationCoordinate2D(latitude: 37, longitude: 127)
        let last = CLLocationCoordinate2D(latitude: 38, longitude: 128)

        XCTAssertNotEqual(
            MapHomeRouteGeometrySignature.value(for: [
                first,
                CLLocationCoordinate2D(latitude: 37.25, longitude: 127.25),
                last,
            ]),
            MapHomeRouteGeometrySignature.value(for: [
                first,
                CLLocationCoordinate2D(latitude: 37.75, longitude: 127.75),
                last,
            ])
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
        let labels = MapHomeTimeSidebarMath.visibleRulerLabels(
            window: 780...900,
            durationMinutes: 120,
            trackHeight: 192
        )

        XCTAssertEqual(labels.hours, [13, 14, 15])
        XCTAssertEqual(
            labels.minutes,
            [795, 810, 825, 855, 870, 885]
        )
    }

    func testSidebarRulerDetailFollowsThirdAndFourthZoomSteps() {
        XCTAssertTrue(MapHomeTimeSidebarMath.showsTenMinuteRuler(durationMinutes: 720))
        XCTAssertTrue(MapHomeTimeSidebarMath.showsTenMinuteRuler(durationMinutes: 360))
        XCTAssertTrue(MapHomeTimeSidebarMath.showsTenMinuteRuler(durationMinutes: 180))
        XCTAssertFalse(MapHomeTimeSidebarMath.showsTenMinuteRuler(durationMinutes: 1440))
        XCTAssertFalse(MapHomeTimeSidebarMath.showsMinuteTicks(durationMinutes: 180))
        XCTAssertTrue(MapHomeTimeSidebarMath.showsMinuteTicks(durationMinutes: 60))
    }

    func testZoomedOutExpandedRulerKeepsMinuteComponents() {
        let rows = MapHomeTimeSidebarMath.visibleRulerRows(
            window: 360...1080,
            durationMinutes: 720,
            trackHeight: 680
        )

        XCTAssertFalse(rows.contains { $0.minuteComponent == 15 })
        XCTAssertTrue(rows.contains { $0.minuteComponent == 30 })
        XCTAssertFalse(rows.contains { $0.minuteComponent == 45 })

        let compactRows = MapHomeTimeSidebarMath.visibleRulerRows(
            window: 360...1080,
            durationMinutes: 720,
            trackHeight: 220
        )
        XCTAssertFalse(compactRows.contains { $0.minuteComponent == 30 })
    }

    func testExpandedSidebarRulerChoosesReadableMinuteSteps() {
        XCTAssertEqual(
            MapHomeTimeSidebarMath.minuteRulerStep(
                durationMinutes: 15,
                trackHeight: 600
            ),
            1
        )
        XCTAssertEqual(
            MapHomeTimeSidebarMath.minuteRulerStep(
                durationMinutes: 60,
                trackHeight: 600
            ),
            5
        )
        XCTAssertEqual(
            MapHomeTimeSidebarMath.minuteRulerStep(
                durationMinutes: 180,
                trackHeight: 400
            ),
            15
        )
        XCTAssertEqual(
            MapHomeTimeSidebarMath.minuteRulerStep(
                durationMinutes: 180,
                trackHeight: 192
            ),
            30
        )
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

    func testFullDayTimelineSpacesHourLabelsOnCompactRail() {
        let compactLabels = MapHomeTimeSidebarMath.visibleHourLabels(
            window: 0...MapHomeTimeSidebarMath.fullDayMinutes,
            durationMinutes: MapHomeTimeSidebarMath.fullDayMinutes,
            trackHeight: 192
        )
        let tallLabels = MapHomeTimeSidebarMath.visibleHourLabels(
            window: 0...MapHomeTimeSidebarMath.fullDayMinutes,
            durationMinutes: MapHomeTimeSidebarMath.fullDayMinutes,
            trackHeight: 720
        )

        XCTAssertEqual(compactLabels, Array(stride(from: 0, through: 24, by: 3)))
        XCTAssertEqual(tallLabels, Array(0...24))
        let compactPositions = compactLabels.map {
            MapHomeTimeSidebarMath.position(
                minute: $0 * 60,
                window: 0...MapHomeTimeSidebarMath.fullDayMinutes
            ) * 192
        }
        XCTAssertTrue(
            zip(compactPositions, compactPositions.dropFirst())
                .allSatisfy {
                    $1 - $0 >= MapHomeTimeSidebarMath.minimumRulerLabelSpacing
                }
        )
    }

    func testSidebarSelectionTimeBlockFitsTheExistingRailWidth() {
        let railWidth: CGFloat = 44
        let activeRailWidth = MapHomeTimeSidebarMath.activeRailWidth
        let trackX = railWidth
            - MapHomeTimeSidebarMath.rulerNumericColumnWidth
            - activeRailWidth / 2
            - 1
        let center = MapHomeTimeSidebarMath.selectionTimeBlockCenterX(
            railWidth: railWidth,
            trackX: trackX,
            activeRailWidth: activeRailWidth
        )
        let halfWidth = MapHomeTimeSidebarMath.selectionTimeBlockWidth / 2

        XCTAssertGreaterThanOrEqual(center - halfWidth, 0)
        XCTAssertLessThanOrEqual(center + halfWidth, railWidth)
        XCTAssertEqual(center, 22)
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

    func testSidebarHandleHitAreaStaysInsideRailAtEdges() {
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
        XCTAssertGreaterThan(MapHomeTimeSidebarMath.handleDragHitHeight, hitHeight)
        XCTAssertEqual(
            MapHomeTimeSidebarMath.handleHitCenterY(
                handleCenterY: 14,
                railHeight: railHeight,
                hitHeight: MapHomeTimeSidebarMath.trailingHandleDragHitHeight
            ),
            66
        )
        XCTAssertEqual(
            MapHomeTimeSidebarMath.handleHitCenterY(
                handleCenterY: 590,
                railHeight: railHeight,
                hitHeight: MapHomeTimeSidebarMath.trailingHandleDragHitHeight
            ),
            534
        )
    }

    func testSidebarHandleInteractionReachesTrailingScreenEdge() {
        XCTAssertEqual(
            MapHomeTimeSidebarMath.interactionWidth(
                railWidth: 58,
                trailingInteractionWidth: 10
            ),
            137
        )
        XCTAssertEqual(
            MapHomeTimeSidebarMath.interactionWidth(
                railWidth: 58,
                trailingInteractionWidth: -10
            ),
            127
        )
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

    /// 여러 기록이 하나의 대분류 구간으로 합쳐져도 그 기록들이 상세활동으로 남아야 한다.
    /// 예전에는 구간의 sourceIDs를 **전부** 상세에서 빼서, 업무 세 건이 합쳐진 5시간짜리
    /// 구간의 상세 목록이 비어 있었다(클립 편집기 하단 줄이 빈 채로 보임).
    func testSectionDetailsKeepEverySourceOfAMergedSegment() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dayStart = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 8,
            day: 24
        ))!
        func at(_ minute: Int) -> Date {
            dayStart.addingTimeInterval(TimeInterval(minute * 60))
        }
        let mailID = UUID()
        let meetingID = UUID()
        let codingID = UUID()
        let records = [
            ActualRecord(
                id: mailID,
                planID: nil,
                title: "메일",
                categoryID: "work",
                startedAt: at(7 * 60),
                endedAt: at(8 * 60 + 10),
                source: .location,
                behavior: WatchBehaviorKind.sitting.rawValue
            ),
            ActualRecord(
                id: meetingID,
                planID: nil,
                title: "회의",
                categoryID: "work",
                startedAt: at(8 * 60 + 10),
                endedAt: at(10 * 60 + 30),
                source: .location,
                behavior: WatchBehaviorKind.sitting.rawValue
            ),
            ActualRecord(
                id: codingID,
                planID: nil,
                title: "코딩",
                categoryID: "work",
                startedAt: at(10 * 60 + 30),
                endedAt: at(12 * 60),
                source: .location,
                behavior: WatchBehaviorKind.sitting.rawValue
            ),
        ]
        // 세 기록이 하나로 합쳐진 구간 — sourceIDs에 셋이 모두 들어 있다.
        let segment = MapHomeTimeRailSegment(
            startMinute: 7 * 60,
            endMinute: 12 * 60,
            categoryID: "work",
            title: "업무",
            sourceIDs: [mailID, meetingID, codingID]
        )

        let details = MapHomeSectionDetailEngine.details(
            actuals: records,
            travel: [],
            segment: segment,
            dayStart: dayStart,
            dayEnd: dayStart.addingTimeInterval(86_400),
            asOf: at(13 * 60)
        )

        XCTAssertEqual(details.map(\.id), [mailID, meetingID, codingID])
        XCTAssertEqual(details.map(\.startMinute), [420, 490, 630])
        XCTAssertEqual(details.map(\.endMinute), [490, 630, 720])
        XCTAssertEqual(details.map(\.title), ["메일", "회의", "코딩"])

        // 한 기록짜리 구간은 그 기록이 곧 구간이므로 여전히 상세에서 빠진다.
        let single = MapHomeTimeRailSegment(
            startMinute: 7 * 60,
            endMinute: 8 * 60 + 10,
            categoryID: "work",
            title: "메일",
            sourceIDs: [mailID]
        )
        XCTAssertTrue(
            MapHomeSectionDetailEngine.details(
                actuals: [records[0]],
                travel: [],
                segment: single,
                dayStart: dayStart,
                dayEnd: dayStart.addingTimeInterval(86_400),
                asOf: at(13 * 60)
            ).isEmpty
        )
    }

    /// 구간 경계에 걸친 기록이 잘리지 않는다. 구간별 목록은 경계에서 자르지만,
    /// 하루 목록(`dayDetails`)은 자르지 않아야 한다 — 예전에는 잘린 앞토막만 남았다.
    func testDayDetailsKeepARecordThatCrossesASectionBoundary() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dayStart = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 8,
            day: 24
        ))!
        func at(_ minute: Int) -> Date {
            dayStart.addingTimeInterval(TimeInterval(minute * 60))
        }
        let dayEnd = at(1_440)
        let crossing = ActualRecord(
            id: UUID(),
            planID: nil,
            title: "보고서",
            categoryID: "work",
            startedAt: at(9 * 60 + 50),
            endedAt: at(10 * 60 + 20),
            source: .location,
            behavior: WatchBehaviorKind.sitting.rawValue
        )
        func segment(_ start: Int, _ end: Int) -> MapHomeTimeRailSegment {
            MapHomeTimeRailSegment(
                startMinute: start,
                endMinute: end,
                categoryID: "work",
                title: "업무",
                sourceIDs: []
            )
        }

        let before = MapHomeSectionDetailEngine.details(
            actuals: [crossing],
            travel: [],
            segment: segment(9 * 60, 10 * 60),
            dayStart: dayStart,
            dayEnd: dayEnd,
            asOf: at(13 * 60)
        )
        let after = MapHomeSectionDetailEngine.details(
            actuals: [crossing],
            travel: [],
            segment: segment(10 * 60, 11 * 60),
            dayStart: dayStart,
            dayEnd: dayEnd,
            asOf: at(13 * 60)
        )
        XCTAssertEqual(before.map(\.endMinute), [600], "구간 목록은 경계에서 잘린다")
        XCTAssertEqual(after.map(\.startMinute), [600])

        let day = MapHomeSectionDetailEngine.dayDetails(
            actuals: [crossing],
            travel: [],
            dayStart: dayStart,
            dayEnd: dayEnd,
            asOf: at(13 * 60)
        )
        XCTAssertEqual(day.map(\.startMinute), [590])
        XCTAssertEqual(day.map(\.endMinute), [620], "경계에서 잘리면 뒤 20분이 사라진다")
        XCTAssertEqual(day.count, 1)
    }

    /// 맞닿은 두 기록이 1분씩 겹쳐 보이지 않는다.
    /// 예전에는 시작을 내림·끝을 올림해서, 09:45:20에 끝나고 시작하는 두 기록이
    /// 09:45–09:46에서 겹쳤다.
    func testSectionDetailsDoNotInflateAdjacentRecords() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dayStart = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 8,
            day: 24
        ))!
        let shared = dayStart.addingTimeInterval(9 * 3_600 + 45 * 60 + 20)
        let first = ActualRecord(
            id: UUID(),
            planID: nil,
            title: "회의",
            categoryID: "work",
            startedAt: dayStart.addingTimeInterval(9 * 3_600),
            endedAt: shared,
            source: .location,
            behavior: WatchBehaviorKind.sitting.rawValue
        )
        let second = ActualRecord(
            id: UUID(),
            planID: nil,
            title: "코딩",
            categoryID: "work",
            startedAt: shared,
            endedAt: dayStart.addingTimeInterval(10 * 3_600),
            source: .location,
            behavior: WatchBehaviorKind.sitting.rawValue
        )

        let details = MapHomeSectionDetailEngine.dayDetails(
            actuals: [first, second],
            travel: [],
            dayStart: dayStart,
            dayEnd: dayStart.addingTimeInterval(86_400),
            asOf: dayStart.addingTimeInterval(13 * 3_600)
        )

        XCTAssertEqual(details.map(\.startMinute), [540, 585])
        XCTAssertEqual(details.map(\.endMinute), [585, 600])
        XCTAssertEqual(details[0].endMinute, details[1].startMinute, "맞닿은 경계는 겹치지도 벌어지지도 않는다")
    }

    func testSectionDetailsDeduplicateExactSourcesByPriorityWithoutMutatingInputs() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dayStart = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 8,
            day: 24
        ))!
        let start = dayStart.addingTimeInterval(9 * 3_600 + 22 * 60)
        let end = start.addingTimeInterval(14 * 60)
        let correctedID = UUID()
        let healthID = UUID()
        let motionID = UUID()
        let locationID = UUID()
        let travelID = UUID()
        func actual(
            id: UUID,
            source: ActualSource,
            manuallyCorrected: Bool = false
        ) -> ActualRecord {
            ActualRecord(
                id: id,
                planID: nil,
                title: "걷기 탑승",
                categoryID: manuallyCorrected ? "movement" : "activity",
                startedAt: start,
                endedAt: end,
                source: source,
                behavior: "walking",
                manuallyCorrected: manuallyCorrected
            )
        }
        let actuals = [
            actual(id: locationID, source: .location),
            actual(id: motionID, source: .motion),
            actual(id: healthID, source: .healthKit),
            actual(id: correctedID, source: .location, manuallyCorrected: true),
        ]
        let travel = [
            TravelSegment(
                id: travelID,
                mode: .walking,
                span: TimeSpan(start: start, end: end),
                distanceMeters: 500,
                confidence: .high,
                evidence: ["GPS"]
            ),
        ]
        let originalActuals = actuals
        let originalTravel = travel
        let segment = MapHomeTimeRailSegment(
            startMinute: 9 * 60,
            endMinute: 10 * 60,
            categoryID: "movement",
            title: "이동",
            sourceIDs: []
        )

        let details = MapHomeSectionDetailEngine.details(
            actuals: actuals,
            travel: travel,
            segment: segment,
            dayStart: dayStart,
            dayEnd: dayStart.addingTimeInterval(86_400),
            asOf: end.addingTimeInterval(60)
        )

        XCTAssertEqual(details.count, 1)
        XCTAssertEqual(details.first?.id, correctedID)
        XCTAssertEqual(details.first?.categoryID, "movement")
        XCTAssertEqual(details.first?.behavior, "walking")
        XCTAssertEqual(details, MapHomeSectionDetailEngine.details(
            actuals: actuals,
            travel: travel,
            segment: segment,
            dayStart: dayStart,
            dayEnd: dayStart.addingTimeInterval(86_400),
            asOf: end.addingTimeInterval(60)
        ))
        XCTAssertEqual(actuals, originalActuals)
        XCTAssertEqual(travel, originalTravel)
    }

    func testSectionDetailsKeepsOverlappingDetailsWithDifferentKeys() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dayStart = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 8,
            day: 24
        ))!
        let firstStart = dayStart.addingTimeInterval(9 * 3_600 + 22 * 60)
        let secondStart = dayStart.addingTimeInterval(9 * 3_600 + 25 * 60)
        let first = ActualRecord(
            planID: nil,
            title: "걷기",
            categoryID: "activity",
            startedAt: firstStart,
            endedAt: dayStart.addingTimeInterval(9 * 3_600 + 36 * 60),
            source: .location,
            behavior: "walking"
        )
        let second = ActualRecord(
            planID: nil,
            title: "걷기",
            categoryID: "activity",
            startedAt: secondStart,
            endedAt: dayStart.addingTimeInterval(9 * 3_600 + 36 * 60),
            source: .motion,
            behavior: "walking"
        )
        let segment = MapHomeTimeRailSegment(
            startMinute: 9 * 60,
            endMinute: 10 * 60,
            categoryID: "movement",
            title: "이동",
            sourceIDs: []
        )

        let details = MapHomeSectionDetailEngine.details(
            actuals: [first, second],
            travel: [],
            segment: segment,
            dayStart: dayStart,
            dayEnd: dayStart.addingTimeInterval(86_400),
            asOf: dayStart.addingTimeInterval(10 * 3_600)
        )

        XCTAssertEqual(details.count, 2)
        XCTAssertEqual(details.map(\.startMinute), [562, 565])
    }

    func testMapHomeCompassControlReturnsToArrowWithFixedDirection() {
        let compass = MapHomeCompassControlState.directionArrow.toggled
        XCTAssertEqual(compass, .compass)
        XCTAssertTrue(compass.followsHeading)

        let fixedDirection = compass.toggled
        XCTAssertEqual(fixedDirection, .directionArrow)
        XCTAssertFalse(fixedDirection.followsHeading)
        XCTAssertEqual(fixedDirection.mapCameraHeading, 0)
        XCTAssertNil(compass.mapCameraHeading)
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

    func testMapHomeRouteFitIncludesAllDisplayedCoordinates() throws {
        let region = try XCTUnwrap(
            MapHomeRouteFitMath.region(for: [
                CLLocationCoordinate2D(latitude: 37.0, longitude: 126.0),
                CLLocationCoordinate2D(latitude: 37.4, longitude: 126.8),
            ])
        )

        XCTAssertEqual(region.center.latitude, 37.2, accuracy: 0.000_001)
        XCTAssertEqual(region.center.longitude, 126.4, accuracy: 0.000_001)
        XCTAssertEqual(region.span.latitudeDelta, 0.72, accuracy: 0.000_001)
        XCTAssertEqual(region.span.longitudeDelta, 1.44, accuracy: 0.000_001)
    }

    func testMapHomeRouteFitKeepsDateLineCrossingRouteNarrow() throws {
        let region = try XCTUnwrap(
            MapHomeRouteFitMath.region(for: [
                CLLocationCoordinate2D(latitude: 10, longitude: 179.9),
                CLLocationCoordinate2D(latitude: 10, longitude: -179.9),
            ])
        )

        XCTAssertLessThan(abs(abs(region.center.longitude) - 180), 0.001)
        XCTAssertLessThan(region.span.longitudeDelta, 1)
    }

    func testMapHomeCurrentGPSDotRequiresAnIPhoneGPSReading() {
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127.0,
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5
        )
        let iPhoneGPS = SensorReading(
            timestamp: .now,
            point: point,
            gpsAvailable: true,
            sourceDevice: .iPhone
        )
        var watchGPS = iPhoneGPS
        watchGPS.sourceDevice = .appleWatch
        var unavailableGPS = iPhoneGPS
        unavailableGPS.gpsAvailable = false

        XCTAssertTrue(MapHomeCurrentGPSPolicy.isConfirmed(in: [iPhoneGPS]))
        XCTAssertFalse(MapHomeCurrentGPSPolicy.isConfirmed(in: [watchGPS]))
        XCTAssertFalse(
            MapHomeCurrentGPSPolicy.isConfirmed(in: [unavailableGPS])
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

    func testMapHomeWeatherDisplayRequiresACompleteFetchedContext() {
        let observedAt = makeDate(2026, 8, 23, 11)
        let complete = WeatherContext(
            observedAt: observedAt,
            fetchedAt: observedAt,
            isStale: false,
            condition: "맑음",
            symbolName: "sun.max.fill",
            temperatureCelsius: 26
        )
        XCTAssertTrue(MapHomeWeatherDisplayPolicy.isComplete(complete))

        var notFetched = complete
        notFetched.fetchedAt = nil
        XCTAssertFalse(MapHomeWeatherDisplayPolicy.isComplete(notFetched))

        var partial = complete
        partial.symbolName = ""
        XCTAssertFalse(MapHomeWeatherDisplayPolicy.isComplete(partial))

        var stale = complete
        stale.isStale = true
        XCTAssertFalse(MapHomeWeatherDisplayPolicy.isComplete(stale))

        var invalidAirQuality = complete
        invalidAirQuality.airQuality = AirQualityContext(
            pm10MicrogramsPerCubicMeter: .nan,
            pm25MicrogramsPerCubicMeter: 12,
            observedAt: observedAt,
            providerName: "",
            isFallback: false
        )
        XCTAssertFalse(MapHomeWeatherDisplayPolicy.isComplete(invalidAirQuality))
    }

    func testWeatherTimelineDimsForecastsAndScalesWidgetsToEightyPercent() {
        let observedAt = makeDate(2026, 8, 23, 11)
        let current = WeatherContext(
            observedAt: observedAt,
            isForecast: false,
            condition: "맑음",
            symbolName: "sun.max.fill",
            temperatureCelsius: 26
        )
        let future = WeatherContext(
            observedAt: observedAt.addingTimeInterval(3_600),
            isForecast: true,
            condition: "구름",
            symbolName: "cloud.fill",
            temperatureCelsius: 24
        )

        XCTAssertEqual(MapHomeWeatherDisplayPolicy.pillOpacity(for: current, now: observedAt.addingTimeInterval(1_800)), 1)
        XCTAssertEqual(
            MapHomeWeatherDisplayPolicy.opacity(for: future),
            MapHomeWeatherDisplayPolicy.forecastOpacity
        )
        XCTAssertEqual(
            MapHomeWeatherDisplayPolicy.pillBackgroundStyle(for: current),
            .currentWhite
        )
        XCTAssertEqual(
            MapHomeWeatherDisplayPolicy.pillBackgroundStyle(for: future),
            .forecastOpaque
        )
        XCTAssertEqual(MapHomeWeatherDisplayPolicy.pillBackgroundOpacity, 0.10)
        XCTAssertEqual(MapHomeWeatherDisplayPolicy.forecastOpacity, 0.58)
        XCTAssertEqual(MapHomeWeatherRailLayout.widgetScale, 0.8)
        XCTAssertEqual(
            MapHomeWeatherRailLayout.itemWidth(railWidth: 62),
            48,
            accuracy: 0.001
        )
        XCTAssertEqual(MapHomeWeatherRailLayout.itemHeight, 22.4, accuracy: 0.001)
        XCTAssertEqual(MapHomeWeatherRailLayout.scaled(13), 10.4, accuracy: 0.001)
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

    func testMapHomeWeatherCollapsesConcurrentLocationStreamsForDisplay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 23))
        )
        let firstDate = try XCTUnwrap(
            calendar.date(byAdding: .second, value: 10, to: day.addingTimeInterval(10 * 60 * 60))
        )
        let observedDate = try XCTUnwrap(
            calendar.date(byAdding: .second, value: 45, to: day.addingTimeInterval(10 * 60 * 60))
        )
        let nextDate = try XCTUnwrap(
            calendar.date(byAdding: .hour, value: 11, to: day)
        )
        let forecast = WeatherContext(
            observedAt: firstDate,
            fetchedAt: firstDate,
            isForecast: true,
            condition: "맑음",
            symbolName: "sun.max.fill",
            temperatureCelsius: 25,
            point: GeoPoint(
                latitude: 37.5,
                longitude: 127,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5
            )
        )
        let observed = WeatherContext(
            observedAt: observedDate,
            fetchedAt: observedDate,
            isForecast: false,
            condition: "흐림",
            symbolName: "cloud.fill",
            temperatureCelsius: 24,
            point: GeoPoint(
                latitude: 37.6,
                longitude: 127.1,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5
            )
        )
        let next = WeatherContext(
            observedAt: nextDate,
            fetchedAt: nextDate,
            condition: "비",
            symbolName: "cloud.rain.fill",
            temperatureCelsius: 24
        )

        let spans = MapHomeWeatherTimelineMath.persistentSpans(
            for: day,
            contexts: [forecast, observed, next],
            calendar: calendar
        )

        XCTAssertEqual(spans.map { $0.context.id }, [observed.id, next.id])
        XCTAssertEqual(spans[0].span.start, observedDate)
        XCTAssertEqual(spans[0].span.end, nextDate)
    }

    func testMapHomeWeatherPrefersObservedOverSameSignatureForecast() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 23))
        )
        let firstDate = day.addingTimeInterval(10 * 60 * 60 + 10)
        let observedDate = day.addingTimeInterval(10 * 60 * 60 + 45)
        let nextDate = day.addingTimeInterval(11 * 60 * 60)
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5
        )
        let forecast = WeatherContext(
            observedAt: firstDate,
            fetchedAt: firstDate,
            isForecast: true,
            condition: "맑음",
            symbolName: "sun.max.fill",
            temperatureCelsius: 25,
            point: point
        )
        let observed = WeatherContext(
            observedAt: observedDate,
            fetchedAt: observedDate,
            isForecast: false,
            condition: "맑음",
            symbolName: "sun.max.fill",
            temperatureCelsius: 25,
            point: point
        )
        let next = WeatherContext(
            observedAt: nextDate,
            fetchedAt: nextDate,
            condition: "흐림",
            symbolName: "cloud.fill",
            temperatureCelsius: 24
        )

        let spans = MapHomeWeatherTimelineMath.persistentSpans(
            for: day,
            contexts: [forecast, observed, next],
            calendar: calendar
        )

        XCTAssertEqual(spans.map { $0.context.id }, [observed.id, next.id])
        XCTAssertEqual(spans[0].span.start, observedDate)
        XCTAssertEqual(spans[0].span.end, nextDate)
    }

    func testMapHomeWeatherOnlyShowsDisplayedWeatherChanges() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 23))
        )
        let firstDate = try XCTUnwrap(calendar.date(byAdding: .hour, value: 10, to: day))
        let secondDate = try XCTUnwrap(calendar.date(byAdding: .hour, value: 11, to: day))
        let thirdDate = try XCTUnwrap(calendar.date(byAdding: .hour, value: 12, to: day))
        let first = WeatherContext(
            observedAt: firstDate,
            condition: "맑음",
            symbolName: "sun.max.fill",
            temperatureCelsius: 20
        )
        let second = WeatherContext(
            observedAt: secondDate,
            condition: "Clear",
            symbolName: "sun.max.fill",
            temperatureCelsius: 20
        )
        let third = WeatherContext(
            observedAt: thirdDate,
            condition: "흐림",
            symbolName: "cloud.fill",
            temperatureCelsius: 20
        )

        let spans = MapHomeWeatherTimelineMath.persistentSpans(
            for: day,
            contexts: [first, second, third],
            calendar: calendar
        )

        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].context.id, second.id)
        XCTAssertEqual(spans[0].span.start, firstDate)
        XCTAssertEqual(spans[0].span.end, thirdDate)
        XCTAssertEqual(spans[1].context.id, third.id)
    }

    func testWeatherRailKeepsTheSelectedValueWithoutStackingLabels() {
        let visible = MapHomeWeatherRailLayout.visibleIndices(
            yPositions: [10, 22, 34, 70],
            candidateIndices: [0, 1, 2, 3],
            priorityIndices: [1],
            minimumSpacing: 30
        )

        XCTAssertEqual(visible, Set([1, 3]))
        XCTAssertEqual(
            MapHomeWeatherRailLayout.visibleIndices(
                yPositions: [22, 22, 52],
                candidateIndices: [1, 2],
                priorityIndices: [0, 1],
                minimumSpacing: 30
            ),
            Set([1, 2])
        )
    }

    func testFullDayWeatherOnlyShowsLargeTemperatureChanges() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 23))
        )
        let firstDate = try XCTUnwrap(calendar.date(byAdding: .hour, value: 10, to: day))
        let oneDegreeDate = try XCTUnwrap(calendar.date(byAdding: .hour, value: 11, to: day))
        let twoDegreeDate = try XCTUnwrap(calendar.date(byAdding: .hour, value: 12, to: day))
        let weatherChangeDate = try XCTUnwrap(calendar.date(byAdding: .hour, value: 13, to: day))
        let first = WeatherContext(
            observedAt: firstDate,
            condition: "맑음",
            symbolName: "sun.max.fill",
            temperatureCelsius: 20
        )
        let oneDegreeChange = WeatherContext(
            observedAt: oneDegreeDate,
            condition: "맑음",
            symbolName: "sun.max.fill",
            temperatureCelsius: 21
        )
        let twoDegreeChange = WeatherContext(
            observedAt: twoDegreeDate,
            condition: "맑음",
            symbolName: "sun.max.fill",
            temperatureCelsius: 22
        )
        let weatherChange = WeatherContext(
            observedAt: weatherChangeDate,
            condition: "비",
            symbolName: "cloud.rain.fill",
            temperatureCelsius: 22
        )

        let spans = MapHomeWeatherTimelineMath.persistentSpans(
            for: day,
            contexts: [first, oneDegreeChange, twoDegreeChange, weatherChange],
            calendar: calendar,
            minimumTemperatureChangeCelsius: MapHomeWeatherTimelineMath.fullDayTemperatureChangeCelsius
        )

        XCTAssertEqual(spans.map { $0.context.id }, [first.id, twoDegreeChange.id, weatherChange.id])
        XCTAssertEqual(spans[0].span.start, firstDate)
        XCTAssertEqual(spans[0].span.end, twoDegreeDate)
        XCTAssertEqual(spans[1].span.start, twoDegreeDate)
        XCTAssertEqual(spans[1].span.end, weatherChangeDate)
    }

    func testWeatherRawTimelineStoresOnlyDisplayedChanges() {
        let start = makeDate(2026, 8, 23, 10)
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5
        )
        let first = WeatherContext(
            observedAt: start,
            isForecast: true,
            condition: "맑음",
            symbolName: "sun.max.fill",
            temperatureCelsius: 20.1,
            point: point
        )
        let same = WeatherContext(
            observedAt: start.addingTimeInterval(60 * 60),
            isForecast: true,
            condition: "Clear",
            symbolName: "sun.max.fill",
            temperatureCelsius: 20.4,
            point: point
        )
        let changed = WeatherContext(
            observedAt: start.addingTimeInterval(2 * 60 * 60),
            isForecast: true,
            condition: "흐림",
            symbolName: "cloud.fill",
            temperatureCelsius: 20.4,
            point: point
        )
        let current = WeatherContext(
            observedAt: start.addingTimeInterval(3 * 60 * 60),
            isForecast: false,
            condition: "흐림",
            symbolName: "cloud.fill",
            temperatureCelsius: 20.4,
            point: point
        )

        let changes = WeatherTimelineEngine.changedRawContexts(
            [first, same, changed, current],
            relativeTo: []
        )

        XCTAssertEqual(changes.map(\.id), [first.id, changed.id, current.id])
        XCTAssertTrue(
            WeatherTimelineEngine.changedRawContexts(
                [same],
                relativeTo: [first, changed]
            ).isEmpty
        )
    }

    func testDeviceForecastDoesNotMultiplyWhenLocationChanges() {
        let start = makeDate(2026, 8, 23, 10)
        let first = WeatherContext(
            observedAt: start,
            fetchedAt: start,
            isForecast: true,
            condition: "맑음",
            symbolName: "sun.max.fill",
            temperatureCelsius: 20,
            point: GeoPoint(
                latitude: 37.5,
                longitude: 127,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5
            )
        )
        let moved = WeatherContext(
            observedAt: start.addingTimeInterval(5 * 60),
            fetchedAt: start.addingTimeInterval(60),
            isForecast: true,
            condition: "Clear",
            symbolName: "sun.max.fill",
            temperatureCelsius: 20.4,
            point: GeoPoint(
                latitude: 37.6,
                longitude: 127.1,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5
            )
        )

        XCTAssertEqual(
            WeatherTimelineEngine.coalesced([first, moved]).map(\.id),
            [moved.id]
        )
        XCTAssertTrue(
            WeatherTimelineEngine.changedRawContexts(
                [moved],
                relativeTo: [first]
            ).isEmpty
        )
        let replaced = WeatherTimelineEngine.replacing(
            [first],
            forecast: [moved],
            forecastRange: TimeSpan(
                start: moved.observedAt,
                end: moved.observedAt.addingTimeInterval(2 * 60 * 60)
            )
        )
        XCTAssertEqual(replaced.map(\.id), [moved.id])
    }

    func testMapHomeWeatherDisplayCacheSurvivesViewportRefreshWithoutNetworkData() {
        let observedAt = makeDate(2026, 8, 23, 10)
        let cached = WeatherContext(
            observedAt: observedAt,
            fetchedAt: observedAt,
            condition: "맑음",
            symbolName: "sun.max.fill",
            temperatureCelsius: 25
        )

        let afterViewportChange = MapHomeWeatherDisplayCache.contexts(
            incoming: [],
            cached: [cached]
        )

        XCTAssertEqual(afterViewportChange.map(\.id), [cached.id])
        XCTAssertEqual(afterViewportChange.first?.temperatureCelsius, 25)
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
        XCTAssertEqual(fields["subway_route_mode_mismatch_count"], "0")
        XCTAssertEqual(fields["classification_locked_count"], "0")
        XCTAssertEqual(fields["subway_route_lines"], "인천1호선+5호선")
        XCTAssertEqual(
            fields["subway_route_stations"],
            "가정역→검암역→마곡나루역"
        )
        XCTAssertEqual(fields["subway_transfer_stations"], "검암역")
        XCTAssertTrue(fields["travel_mode_counts"]?.contains("subway=1") == true)
        XCTAssertTrue(fields["travel_mode_counts"]?.contains("car=1") == true)
        XCTAssertEqual(
            TaptionPlanDiagnosticsTravelSummary.fields(
                for: [
                    TravelSegment(
                        mode: .walking,
                        span: subway.span,
                        distanceMeters: subway.distanceMeters,
                        confidence: .high,
                        evidence: [],
                        subwayRoute: route
                    ),
                ]
            )["subway_route_mode_mismatch_count"],
            "1"
        )
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
                y: MapHomeTimeSidebarMath.verticalInset,
                trackHeight: 300,
                verticalInset: MapHomeTimeSidebarMath.verticalInset,
                maxMinute: 1_439
            ),
            0
        )
        XCTAssertEqual(
            MapHomeTimeSidebarMath.minuteByLocation(
                y: MapHomeTimeSidebarMath.verticalInset + 150,
                trackHeight: 300,
                verticalInset: MapHomeTimeSidebarMath.verticalInset,
                maxMinute: 1_439
            ),
            720
        )
        XCTAssertEqual(
            MapHomeTimeSidebarMath.minuteByLocation(
                y: 400,
                trackHeight: 300,
                verticalInset: MapHomeTimeSidebarMath.verticalInset,
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

    func testMapHomeTimeSidebarHandleAcceptsFutureTouchButClampsSelectionToNow() throws {
        let drag = MapHomeTimeSidebarHandleDrag()
        drag.begin(
            with: MapHomeTimeSidebarNLEState(
                selectedMinute: 570,
                visibleStartMinute: 540,
                visibleDurationMinutes: 60
            ),
            nowUptime: 10
        )

        let future = try XCTUnwrap(
            drag.projectedState(
                locationY: 301,
                trackHeight: 300,
                verticalInset: 0,
                maxMinute: 600,
                interactionMaxMinute: MapHomeTimeSidebarMath.fullDayMinutes,
                nowUptime: 10
            )
        )
        XCTAssertEqual(future.selectedMinute, 600)
        XCTAssertEqual(future.visibleStartMinute, 540)

        let valid = try XCTUnwrap(
            drag.projectedState(
                locationY: 100,
                trackHeight: 300,
                verticalInset: 0,
                maxMinute: 600,
                interactionMaxMinute: MapHomeTimeSidebarMath.fullDayMinutes,
                nowUptime: 10
            )
        )
        XCTAssertEqual(valid.selectedMinute, 560)
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

    func testRightSidebarHandleTouchAreaIsExactlyFiftyPercentLarger() {
        let trailingFrame = MapHomeTimeSidebarMath.selectionHandleTouchFrame(
            side: .trailing,
            leadingCenterX: 44,
            trailingCenterX: 99,
            leadingHitWidth: 87,
            trailingHitWidth: MapHomeTimeSidebarMath.selectionTimeBlockHitWidth,
            totalWidth: 127
        )
        let originalArea = trailingFrame.width
            * MapHomeTimeSidebarMath.handleDragHitHeight
        let expandedArea = trailingFrame.width
            * MapHomeTimeSidebarMath.trailingHandleDragHitHeight

        XCTAssertEqual(MapHomeTimeSidebarMath.trailingHandleDragHitHeight, 132)
        XCTAssertEqual(expandedArea, originalArea * 1.5, accuracy: 0.001)
        XCTAssertEqual(MapHomeTimeSidebarMath.handleVisualSize, CGSize(width: 44, height: 44))
    }

    func testSidebarHandleSidesBothDragAndKeepNonOverlappingHitZones() {
        let leadingFrame = MapHomeTimeSidebarMath.selectionHandleTouchFrame(
            side: .leading,
            leadingCenterX: 44,
            trailingCenterX: 99,
            leadingHitWidth: 87,
            trailingHitWidth: MapHomeTimeSidebarMath.selectionTimeBlockHitWidth,
            totalWidth: 127
        )
        let trailingFrame = MapHomeTimeSidebarMath.selectionHandleTouchFrame(
            side: .trailing,
            leadingCenterX: 44,
            trailingCenterX: 99,
            leadingHitWidth: 87,
            trailingHitWidth: MapHomeTimeSidebarMath.selectionTimeBlockHitWidth,
            totalWidth: 127
        )

        XCTAssertTrue(MapHomeTimeSidebarHandleSide.leading.allowsDrag)
        XCTAssertTrue(MapHomeTimeSidebarHandleSide.trailing.allowsDrag)
        XCTAssertLessThanOrEqual(leadingFrame.maxX, trailingFrame.minX)
        XCTAssertGreaterThanOrEqual(leadingFrame.minX, 0)
        XCTAssertLessThanOrEqual(trailingFrame.maxX, 127)
        XCTAssertEqual(MapHomeTimeSidebarMath.selectionTimeBlockWidth, 44)
        XCTAssertGreaterThan(
            MapHomeTimeSidebarMath.selectionTimeBlockHitWidth,
            MapHomeTimeSidebarMath.selectionTimeBlockWidth
        )
    }

    func testExpandedRulerRowsKeepHourAndMinuteInOneVerticalColumn() {
        let rows = MapHomeTimeSidebarMath.visibleRulerRows(
            window: 480...600,
            durationMinutes: 120,
            trackHeight: 192
        )

        XCTAssertEqual(
            rows.map(\.minute),
            [480, 495, 510, 525, 540, 555, 570, 585, 600]
        )
        XCTAssertEqual(rows.first?.hour, 8)
        XCTAssertNil(rows.first?.minuteComponent)
        XCTAssertEqual(rows[1].minuteComponent, 15)
        XCTAssertNil(rows[1].hour)
        XCTAssertEqual(rows[4].hour, 9)
        XCTAssertNil(rows[4].minuteComponent)
    }

    /// 손잡이 드래그는 4pt부터. 탭은 드래그 종료로 한 번 더 알려지지 않는다(PRF1101A01).
    func testMapHomeTimeSidebarHandleDragStartsAfterFourPoints() {
        XCTAssertEqual(
            MapHomeTimeSidebarMath.handleDragMinimumDistance,
            4,
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

    func testMapLocationAnchorPrefersFreshPreciseReading() {
        let now = Date(timeIntervalSince1970: 20_000)
        let precise = SensorReading(
            timestamp: now.addingTimeInterval(-4 * 60),
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

    func testMapLocationAnchorAcceptsFiveMinuteBoundaryAndRejectsOlderFix() {
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
        let boundary = approximate(age: 5 * 60)
        let stale = approximate(age: 5 * 60 + 1)

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

    func testPlaybackCenterDoesNotOverridePinchWithoutLocationChange() {
        let coordinate = CLLocationCoordinate2D(
            latitude: 37.55,
            longitude: 126.99
        )
        let target = CGPoint(x: 150, y: 390)

        XCTAssertFalse(MapHomePlaybackCenterPolicy.shouldCenter(
            previousCoordinate: coordinate,
            previousTargetPoint: target,
            coordinate: coordinate,
            targetPoint: target
        ))
        XCTAssertFalse(MapHomePlaybackCenterPolicy.shouldCenter(
            previousCoordinate: nil,
            previousTargetPoint: nil,
            coordinate: coordinate,
            targetPoint: target,
            hasPendingViewportCommand: true
        ))
        XCTAssertTrue(MapHomePlaybackCenterPolicy.shouldCenter(
            previousCoordinate: coordinate,
            previousTargetPoint: target,
            coordinate: CLLocationCoordinate2D(
                latitude: 37.550_01,
                longitude: 126.99
            ),
            targetPoint: target
        ))
        XCTAssertTrue(MapHomePlaybackCenterPolicy.shouldCenter(
            previousCoordinate: coordinate,
            previousTargetPoint: target,
            coordinate: coordinate,
            targetPoint: CGPoint(x: 150, y: 400)
        ))
    }

    func testPlaybackBlocksAutomaticMapFitAndInitialZoomReset() {
        XCTAssertFalse(
            MapHomePlaybackCameraPolicy.allowsAutomaticFit(
                isPlaybackRunning: true,
                hasUserAdjustedMap: false
            )
        )
        XCTAssertFalse(
            MapHomePlaybackCameraPolicy.allowsAutomaticFit(
                isPlaybackRunning: true,
                hasUserAdjustedMap: true
            )
        )
        XCTAssertTrue(
            MapHomePlaybackCameraPolicy.allowsAutomaticFit(
                isPlaybackRunning: false,
                hasUserAdjustedMap: false
            )
        )
        XCTAssertFalse(
            MapHomePlaybackCameraPolicy.allowsAutomaticFit(
                isPlaybackRunning: false,
                hasUserAdjustedMap: true
            )
        )
        XCTAssertFalse(
            MapHomePlaybackCameraPolicy.allowsInitialFocus(
                isPlaybackRunning: true
            )
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

    @MainActor
    func testAppleCurrentLocationCenterCommandPreservesCameraScaleAndAngles() {
        let mapView = MKMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        mapView.setCamera(
            MKMapCamera(
                lookingAtCenter: CLLocationCoordinate2D(
                    latitude: 37.55,
                    longitude: 126.99
                ),
                fromDistance: 2_500,
                pitch: 35,
                heading: 73
            ),
            animated: false
        )
        mapView.layoutIfNeeded()
        let altitude = mapView.camera.altitude
        let heading = mapView.camera.heading
        let pitch = mapView.camera.pitch
        let span = mapView.region.span
        let target = CLLocationCoordinate2D(
            latitude: 37.55,
            longitude: 127.01
        )

        MapHomeAppleCameraCommand.center(target, at: nil, on: mapView)

        XCTAssertEqual(mapView.centerCoordinate.latitude, target.latitude, accuracy: 0.000_001)
        XCTAssertEqual(mapView.centerCoordinate.longitude, target.longitude, accuracy: 0.000_001)
        XCTAssertEqual(mapView.camera.altitude, altitude, accuracy: 0.01)
        XCTAssertEqual(mapView.camera.heading, heading, accuracy: 0.000_001)
        XCTAssertEqual(mapView.camera.pitch, pitch, accuracy: 0.000_001)
        XCTAssertEqual(mapView.region.span.latitudeDelta, span.latitudeDelta, accuracy: 0.000_001)
        XCTAssertEqual(mapView.region.span.longitudeDelta, span.longitudeDelta, accuracy: 0.000_001)
    }

    @MainActor
    func testAppleCurrentLocationCenterCommandUsesUsableViewportTarget() {
        let mapView = MKMapView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844)
        )
        let coordinate = CLLocationCoordinate2D(
            latitude: 37.55,
            longitude: 126.99
        )
        mapView.setRegion(
            MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(
                    latitudeDelta: 0.02,
                    longitudeDelta: 0.02
                )
            ),
            animated: false
        )
        mapView.layoutIfNeeded()
        let targetPoint = CGPoint(x: 150, y: 390)

        MapHomeAppleCameraCommand.center(
            coordinate,
            at: targetPoint,
            on: mapView
        )

        let rendered = mapView.convert(coordinate, toPointTo: mapView)
        XCTAssertEqual(rendered.x, targetPoint.x, accuracy: 2)
        XCTAssertEqual(rendered.y, targetPoint.y, accuracy: 2)
    }

    @MainActor
    func testAppleCompassHeadingCommandPreservesCameraScaleAndPitch() {
        let mapView = MKMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        mapView.setCamera(
            MKMapCamera(
                lookingAtCenter: CLLocationCoordinate2D(
                    latitude: 37.55,
                    longitude: 126.99
                ),
                fromDistance: 2_500,
                pitch: 35,
                heading: 73
            ),
            animated: false
        )
        mapView.layoutIfNeeded()
        let distance = mapView.camera.centerCoordinateDistance
        let pitch = mapView.camera.pitch
        let target = CLLocationCoordinate2D(
            latitude: 37.55,
            longitude: 127.01
        )

        MapHomeAppleCameraCommand.heading(
            0,
            centeredAt: target,
            targetPoint: nil,
            on: mapView
        )

        XCTAssertEqual(mapView.centerCoordinate.latitude, target.latitude, accuracy: 0.000_001)
        XCTAssertEqual(mapView.centerCoordinate.longitude, target.longitude, accuracy: 0.000_001)
        XCTAssertEqual(mapView.camera.heading, 0, accuracy: 0.000_001)
        XCTAssertEqual(mapView.camera.centerCoordinateDistance, distance, accuracy: 0.01)
        XCTAssertEqual(mapView.camera.pitch, pitch, accuracy: 0.000_001)

        MapHomeAppleCameraCommand.heading(
            135,
            centeredAt: nil,
            targetPoint: nil,
            on: mapView
        )

        XCTAssertEqual(mapView.centerCoordinate.latitude, target.latitude, accuracy: 0.000_001)
        XCTAssertEqual(mapView.centerCoordinate.longitude, target.longitude, accuracy: 0.000_001)
        XCTAssertEqual(mapView.camera.heading, 135, accuracy: 0.000_001)
        XCTAssertEqual(mapView.camera.centerCoordinateDistance, distance, accuracy: 0.01)
        XCTAssertEqual(mapView.camera.pitch, pitch, accuracy: 0.000_001)
    }

    func testMapDisplayStylePreservesPersistedSelectionAndDefaultsToRPGMap() throws {
        var settings = AppFeatureSettings.defaults
        settings.mapDisplayStyle = .hybrid
        XCTAssertEqual(settings.mapDisplayStyle, .hybrid)
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
            .mapLibreRPG
        )

        settings.mapDisplayStyle = .mapLibreCasual
        XCTAssertEqual(settings.mapDisplayStyle, .mapLibreCasual)
        XCTAssertEqual(
            try JSONDecoder().decode(
                AppFeatureSettings.self,
                from: JSONEncoder().encode(settings)
            ).mapDisplayStyle,
            .mapLibreCasual
        )
    }

    func testMapDisplayStyleIncludesSimplifiedAndUnknownValuesFallback() throws {
        XCTAssertEqual(
            MapDisplayStyle.allCases,
            [
                .standard,
                .hybrid,
                .mapLibreNight,
                .mapLibreContrast,
                .mapLibreCasual,
                .mapLibreRPG,
                .mapLibreInk,
                .mapLibrePorcelain,
            ]
        )
        // 없앤 밝게·파스텔로 저장된 값은 산책 지도로 읽는다(UIX1101A03).
        for retired in ["mapLibreLight", "mapLibrePastel"] {
            XCTAssertEqual(
                try JSONDecoder().decode(MapDisplayStyle.self, from: JSONEncoder().encode(retired)),
                .mapLibreCasual
            )
        }
        for style in MapDisplayStyle.allCases {
            XCTAssertEqual(
                try JSONDecoder().decode(
                    MapDisplayStyle.self,
                    from: JSONEncoder().encode(style)
                ),
                style
            )
        }
        XCTAssertEqual(
            try JSONDecoder().decode(
                MapDisplayStyle.self,
                from: Data("\"legacy-map-style\"".utf8)
            ),
            .standard
        )
    }

    func testSubwayOverlayEngineKeepsOnlyConfirmedCatalogPath() {
        let stations = SubwayStationCatalog.stations
            .filter { $0.coordinate != nil }
        guard let first = stations.first else {
            XCTFail("subway catalog is empty")
            return
        }
        let stops = stations.filter { $0.lineName == first.lineName }.prefix(4)
        guard stops.count == 4,
              let route = SubwayStationCatalog.route(
                  for: stops.map(\.stationName)
              ) else {
            XCTFail("subway catalog route is incomplete")
            return
        }
        let start = makeDate(2026, 8, 24, 9)
        let segment = TravelSegment(
            mode: .subway,
            span: TimeSpan(start: start, end: start.addingTimeInterval(20 * 60)),
            distanceMeters: 2_000,
            confidence: .medium,
            evidence: ["철도 지도 신호"],
            subwayRoute: nil
        )
        let readings: [SensorReading] = stops.enumerated().compactMap {
            index, station in
            guard let point = station.coordinate else { return nil }
            return SensorReading(
                timestamp: start.addingTimeInterval(Double(index) * 10 * 60),
                point: point,
                locationFixQuality: .precise,
                nearbyStationName: station.stationName,
                matchesRailRoute: true
            )
        }

        let overlays = MapHomeSubwayRouteOverlayEngine.overlays(
            travel: [segment],
            readings: readings,
            day: TimeSpan(
                start: makeDate(2026, 8, 24),
                end: makeDate(2026, 8, 25)
            ),
            through: start.addingTimeInterval(20 * 60)
        )

        XCTAssertTrue(overlays.isEmpty)

        let confirmed = TravelSegment(
            id: segment.id,
            mode: .subway,
            span: segment.span,
            distanceMeters: segment.distanceMeters,
            confidence: .high,
            evidence: segment.evidence,
            isConfirmed: true,
            subwayRoute: route
        )
        let confirmedOverlays = MapHomeSubwayRouteOverlayEngine.overlays(
            travel: [confirmed],
            readings: readings,
            day: TimeSpan(
                start: makeDate(2026, 8, 24),
                end: makeDate(2026, 8, 25)
            ),
            through: segment.span.end
        )
        XCTAssertEqual(confirmedOverlays.count, 1)
        XCTAssertEqual(confirmedOverlays.first?.estimated, false)
    }

    func testSubwayOverlayEngineRejectsUnconfirmedStoredRouteWithoutGPS() {
        let stations = SubwayStationCatalog.stations
            .filter { $0.coordinate != nil }
        guard let first = stations.first else {
            XCTFail("subway catalog is empty")
            return
        }
        let stops = stations.filter { $0.lineName == first.lineName }.prefix(4)
        guard stops.count == 4,
              let route = SubwayStationCatalog.route(
                  for: stops.map(\.stationName)
              ) else {
            XCTFail("subway catalog route is incomplete")
            return
        }

        let start = makeDate(2026, 8, 24, 9)
        let segment = TravelSegment(
            mode: .subway,
            span: TimeSpan(start: start, end: start.addingTimeInterval(20 * 60)),
            distanceMeters: 2_000,
            confidence: .medium,
            evidence: ["저장된 역 경로"],
            subwayRoute: route
        )
        let overlays = MapHomeSubwayRouteOverlayEngine.overlays(
            travel: [segment],
            readings: [],
            day: TimeSpan(
                start: makeDate(2026, 8, 24),
                end: makeDate(2026, 8, 25)
            ),
            through: segment.span.end
        )

        XCTAssertTrue(overlays.isEmpty)
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
            8_333_333
        )
        XCTAssertEqual(
            MapHomeDayPlaybackMath.routeProjectionInterval,
            0.5,
            accuracy: 0.000_000_001
        )
        XCTAssertEqual(
            MapHomeDayPlaybackMath.mapFocusInterval,
            0.008,
            accuracy: 0.000_000_001
        )
        XCTAssertEqual(MapHomeDayPlaybackMath.minute(elapsedSeconds: 0), 0)
        XCTAssertEqual(MapHomeDayPlaybackMath.minute(elapsedSeconds: 1), 60)
        XCTAssertEqual(MapHomeDayPlaybackMath.minute(elapsedSeconds: 12), 720)
        XCTAssertEqual(MapHomeDayPlaybackMath.minute(elapsedSeconds: 23.999), 1_439)
        XCTAssertEqual(MapHomeDayPlaybackMath.minute(elapsedSeconds: 24), 1_440)
        XCTAssertEqual(MapHomeDayPlaybackMath.minute(elapsedSeconds: 30), 1_440)
        // 시험용 `-slowDayPlayback` 인자가 없으면 실사용 배속은 그대로여야 한다.
        // 화면 시험이 재생을 관찰하려고 늦추는 것과 실사용 배속을 섞으면 안 된다.
        XCTAssertEqual(MapHomeDayPlaybackTestHooks.rateScale, 1, accuracy: 0.000_001)
        XCTAssertEqual(
            MapHomeDayPlaybackMath.stationaryMinutesPerSecond,
            120,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            MapHomeDayPlaybackMath.movingMinutesPerSecond,
            2.5,
            accuracy: 0.000_001
        )
    }

    func testMapHomeDayPlaybackStopsAtNowOnlyForToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: .now)
        let now = calendar.date(byAdding: .second, value: 6 * 60 * 60 + 24 * 60 + 30, to: today)!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        XCTAssertEqual(
            MapHomeDayPlaybackMath.playbackEndMinute(
                for: today,
                now: now,
                calendar: calendar
            ),
            384.5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            MapHomeDayPlaybackMath.playbackEndMinute(
                for: yesterday,
                now: now,
                calendar: calendar
            ),
            1_440
        )
    }

    func testMapHomeDayPlaybackRestartsTodayFromMidnightAtCurrentTime() {
        XCTAssertEqual(
            MapHomeDayPlaybackMath.playbackStartMinute(
                selectedMinute: 384,
                endMinute: 384.5,
                isToday: true
            ),
            0
        )
        XCTAssertEqual(
            MapHomeDayPlaybackMath.playbackStartMinute(
                selectedMinute: 385,
                endMinute: 384.5,
                isToday: true
            ),
            0
        )
        XCTAssertEqual(
            MapHomeDayPlaybackMath.playbackStartMinute(
                selectedMinute: 120,
                endMinute: 384.5,
                isToday: true
            ),
            120
        )
    }

    func testMapHomeDayPlaybackDoesNotWrapPastDayEndpoint() {
        XCTAssertEqual(
            MapHomeDayPlaybackMath.playbackStartMinute(
                selectedMinute: 1_440,
                endMinute: 1_440,
                isToday: false
            ),
            1_440
        )
    }

    func testMapHomePlaybackRouteFollowsPlayheadWhilePlaying() {
        let dayEnd = makeDate(2026, 8, 26).addingTimeInterval(24 * 60 * 60)
        let playhead = makeDate(2026, 8, 26, 9)

        XCTAssertEqual(
            MapHomeRouteOverlayCutoffPolicy.cutoff(
                selectedDayEnd: dayEnd,
                timelineDate: playhead,
                isPlaybackRunning: true
            ),
            playhead
        )
        XCTAssertEqual(
            MapHomeRouteOverlayCutoffPolicy.cutoff(
                selectedDayEnd: dayEnd,
                timelineDate: playhead,
                isPlaybackRunning: false
            ),
            playhead
        )
    }

    func testMapHomePlaybackCutoffIgnoresStaleProjectionCutoff() {
        let dayEnd = makeDate(2026, 8, 26).addingTimeInterval(24 * 60 * 60)
        let playhead = makeDate(2026, 8, 26, 9).addingTimeInterval(2 * 60)
        let staleProjectionCutoff = makeDate(2026, 8, 26, 9)

        XCTAssertEqual(
            MapHomeRouteOverlayCutoffPolicy.cutoff(
                selectedDayEnd: dayEnd,
                timelineDate: playhead,
                isPlaybackRunning: true,
                interactiveProjectionCutoff: staleProjectionCutoff
            ),
            playhead
        )
        XCTAssertEqual(
            MapHomeRouteOverlayCutoffPolicy.cutoff(
                selectedDayEnd: dayEnd,
                timelineDate: playhead,
                isPlaybackRunning: false,
                interactiveProjectionCutoff: staleProjectionCutoff
            ),
            staleProjectionCutoff
        )
    }

    func testMapHomeDayPlaybackUsesOneFortyEighthSpeedInsideMovement() {
        let ranges = [
            MapHomePlaybackMovementRange(startMinute: 60, endMinute: 120)
        ]

        XCTAssertEqual(
            MapHomeDayPlaybackMath.advancedMinute(
                from: 0,
                elapsedSeconds: 1,
                normalizedMovingRanges: ranges
            ),
            61.25,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            MapHomeDayPlaybackMath.advancedMinute(
                from: 60,
                elapsedSeconds: 1,
                normalizedMovingRanges: ranges
            ),
            62.5,
            accuracy: 0.000_001
        )
    }

    /// 걷기는 초당 7.5분(PLY1029A01). 이동 기본 배속이 초당 2.5분이 되면서(ARC1030A02, 지금의 절반) 배수는 3배다.
    /// 차량·달리기는 기본 배속 그대로다. 이름의 1/24는 정지 배속이 60분/초이던 시절 기준이라
    /// 지금 값(정지 120분/초의 1/48)과 맞지 않아 이름과 기대값을 함께 고쳤다.
    func testMapHomeDayPlaybackRunsWalkingSixTimesFasterThanVehicles() {
        XCTAssertEqual(
            MapHomeDayPlaybackMath.advancedMinute(
                from: 60,
                elapsedSeconds: 1,
                normalizedMovingRanges: [
                    .init(startMinute: 60, endMinute: 120, mode: .walking),
                ]
            ),
            67.5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            MapHomeDayPlaybackMath.advancedMinute(
                from: 60,
                elapsedSeconds: 1,
                normalizedMovingRanges: [
                    .init(startMinute: 60, endMinute: 120, mode: .car),
                ]
            ),
            62.5,
            accuracy: 0.000_001
        )
    }

    func testMapHomeDayPlaybackSplitsElapsedTimeAtMovementBoundary() {
        let ranges = [
            MapHomePlaybackMovementRange(startMinute: 60, endMinute: 120)
        ]

        XCTAssertEqual(
            MapHomeDayPlaybackMath.advancedMinute(
                from: 30,
                elapsedSeconds: 1,
                normalizedMovingRanges: ranges
            ),
            61.875,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            MapHomeDayPlaybackMath.advancedMinute(
                from: 110,
                elapsedSeconds: 1,
                normalizedMovingRanges: ranges
            ),
            112.5,
            accuracy: 0.000_001
        )
    }

    func testMapHomeExpectedRoutePlaybackInterpolatesByDistanceAndTime() throws {
        let start = makeDate(2026, 8, 26, 9)
        let end = makeDate(2026, 8, 26, 10)
        let coordinates = [
            CLLocationCoordinate2D(latitude: 37.5, longitude: 127.0),
            CLLocationCoordinate2D(latitude: 37.5, longitude: 127.01),
        ]

        let beginning = try XCTUnwrap(MapHomeExpectedRoutePlaybackMath.coordinate(
            at: start,
            departureDate: start,
            arrivalDate: end,
            coordinates: coordinates
        ))
        XCTAssertEqual(beginning.latitude, 37.5, accuracy: 0.000_001)
        XCTAssertEqual(beginning.longitude, 127.0, accuracy: 0.000_001)

        let midpoint = try XCTUnwrap(MapHomeExpectedRoutePlaybackMath.coordinate(
            at: start.addingTimeInterval(30 * 60),
            departureDate: start,
            arrivalDate: end,
            coordinates: coordinates
        ))
        XCTAssertEqual(midpoint.latitude, 37.5, accuracy: 0.000_001)
        XCTAssertEqual(midpoint.longitude, 127.005, accuracy: 0.000_001)

        let arrival = try XCTUnwrap(MapHomeExpectedRoutePlaybackMath.coordinate(
            at: end,
            departureDate: start,
            arrivalDate: end,
            coordinates: coordinates
        ))
        XCTAssertEqual(arrival.longitude, 127.01, accuracy: 0.000_001)
        XCTAssertNil(
            MapHomeExpectedRoutePlaybackMath.coordinate(
                at: start.addingTimeInterval(-1),
                departureDate: start,
                arrivalDate: end,
                coordinates: coordinates
            )
        )
        XCTAssertNil(
            MapHomeExpectedRoutePlaybackMath.coordinate(
                at: end.addingTimeInterval(1),
                departureDate: start,
                arrivalDate: end,
                coordinates: coordinates
            )
        )
    }

    func testMapHomePlaybackMovementRangesMergeOverlaps() {
        XCTAssertEqual(
            MapHomePlaybackMovementRange.normalized([
                .init(startMinute: 100, endMinute: 200),
                .init(startMinute: 50, endMinute: 120),
                .init(startMinute: 300, endMinute: 320),
            ]),
            [
                .init(startMinute: 50, endMinute: 200),
                .init(startMinute: 300, endMinute: 320),
            ]
        )
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

    func testMapHomeSectionEditHandlesSitOnTheLowerBoundaryEdge() {
        XCTAssertEqual(
            MapHomeSectionEditLayout.handleCenterY(
                boundaryY: 120,
                frameHeight: 600
            ),
            124
        )
        XCTAssertEqual(
            MapHomeSectionEditLayout.handleCenterY(
                boundaryY: 600,
                frameHeight: 600
            ),
            596
        )
        XCTAssertEqual(
            MapHomeSectionEditLayout.handleCenterY(
                boundaryY: 0,
                frameHeight: 600
            ),
            4
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
                    .calendar: .authorized,
                    .notifications: .authorized,
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
                .calendar,
                .notifications,
                .liveActivities,
            ]
        )
    }

    func testRequiredPermissionGateLetsManualFeaturesWorkWithoutIntegrations() {
        let gate = RequiredPermissionGate.evaluate(
            RequiredPermissionSnapshot(
                permissions: [
                    .location: .authorized,
                    .motion: .authorized,
                ],
                locationAlwaysAuthorized: true,
                locationPrecise: true
            )
        )

        XCTAssertTrue(gate.sensorCollectionReady)
        XCTAssertFalse(gate.allSatisfied)
        XCTAssertEqual(
            gate.missing,
            [.healthKitRequestCompleted, .calendar, .notifications, .liveActivities]
        )
    }

    func testRequiredPermissionGateSeparatesSensorRequirements() {
        let gate = RequiredPermissionGate.evaluate(
            RequiredPermissionSnapshot(
                permissions: [.location: .authorized]
            )
        )

        XCTAssertFalse(gate.sensorCollectionReady)
        XCTAssertEqual(
            gate.sensorCollectionMissing,
            [.locationAlways, .locationPrecise, .motion]
        )
    }

    func testRequiredPermissionGateDoesNotRequirePhotosOrAppUsage() {
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

        XCTAssertTrue(gate.allSatisfied)
    }

    func testMapHomeVectorStylesKeepOnlyStyledRoadMapLayers() throws {
        XCTAssertEqual(
            MapHomeVectorStyle.allCases,
            [.night, .contrast, .casual, .rpg, .ink, .porcelain]
        )

        let baseLayerIDs = [
            "background",
            "water",
            "landuse",
            "building",
            "road-casing",
            "road",
        ]

        for style in MapHomeVectorStyle.allCases {
            let data = try XCTUnwrap(style.json.data(using: .utf8))
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            let sources = try XCTUnwrap(object["sources"] as? [String: Any])
            let source = try XCTUnwrap(sources["openmaptiles"] as? [String: Any])
            let layers = try XCTUnwrap(object["layers"] as? [[String: Any]])
            let layerIDs = layers.compactMap { $0["id"] as? String }
            let labelIDs = MapHomeVectorLabels.layers.map(\.id)
            let expectedLayerIDs: [String]
            switch style {
            case .casual:
                expectedLayerIDs = [
                    "background",
                    "water",
                    "landuse",
                    "casual-landcover",
                    "casual-park",
                    "building",
                    "casual-building-outline",
                    "road-casing",
                    "road",
                    "casual-waterway",
                    "casual-place-marker",
                    "casual-poi-marker",
                ] + labelIDs
            case .rpg:
                expectedLayerIDs = [
                    "background",
                    "water",
                    "landuse",
                    "rpg-landcover",
                    "rpg-park",
                    "rpg-landuse-accent",
                    "rpg-landcover-extra",
                    "rpg-coastline",
                    "building",
                    "rpg-building-tall",
                    "rpg-building-outline",
                    "road-casing",
                    "road",
                    "rpg-road-main",
                    "rpg-road-highway",
                    "rpg-rail",
                    "rpg-waterway",
                    "rpg-place-marker",
                    "rpg-poi-marker",
                ] + labelIDs
            case .ink:
                expectedLayerIDs = [
                    "background",
                    "water",
                    "landuse",
                    "ink-landcover",
                    "ink-coastline",
                    "building",
                    "road-casing",
                    "road",
                    "ink-road-major",
                    "ink-waterway",
                ] + labelIDs
            case .porcelain:
                expectedLayerIDs = [
                    "background",
                    "water",
                    "landuse",
                    "porcelain-landcover",
                    "porcelain-park",
                    "porcelain-coastline",
                    "building",
                    "road-casing",
                    "road",
                    "porcelain-building-outline",
                    "porcelain-road-major",
                    "porcelain-road-highway",
                    "porcelain-rail",
                    "porcelain-waterway",
                ] + labelIDs
            default:
                expectedLayerIDs = baseLayerIDs + labelIDs
            }

            XCTAssertEqual(object["version"] as? Int, 8, style.rawValue)
            XCTAssertEqual(
                source["url"] as? String,
                MapHomeVectorStyle.sourceURL,
                style.rawValue
            )
            XCTAssertFalse(
                (source["attribution"] as? String)?.isEmpty ?? true,
                style.rawValue
            )
            XCTAssertEqual(
                object["glyphs"] as? String,
                MapHomeVectorStyle.glyphsURL,
                style.rawValue
            )
            XCTAssertEqual(layerIDs, expectedLayerIDs, style.rawValue)
            XCTAssertEqual(object["sprite"] as? String, MapHomeVectorLabels.spriteURL, style.rawValue)
            XCTAssertEqual(layers.filter { $0["type"] as? String == "symbol" }.count, labelIDs.count, style.rawValue)

            let background = try XCTUnwrap(
                layers.first { $0["id"] as? String == "background" }?["paint"]
                    as? [String: Any]
            )
            let building = try XCTUnwrap(
                layers.first { $0["id"] as? String == "building" }?["paint"]
                    as? [String: Any]
            )
            let road = try XCTUnwrap(
                layers.first { $0["id"] as? String == "road" }?["paint"]
                    as? [String: Any]
            )

            XCTAssertEqual(
                background["background-color"] as? String,
                style.backgroundHex,
                style.rawValue
            )
            XCTAssertEqual(
                building["fill-color"] as? String,
                style.buildingHex,
                style.rawValue
            )
            XCTAssertEqual(
                road["line-color"] as? String,
                style.roadHex,
                style.rawValue
            )
        }

        XCTAssertEqual(MapHomeVectorStyle.routeHex, MapHomeWBSTripStyle.actualRouteHex)
        XCTAssertEqual(
            MapHomeVectorStyle.transitRouteHex,
            MapHomeWBSTripStyle.transitRouteHex
        )
    }

    func testMapDisplayStylesMapToTheirVectorStyleOrNilForMapKit() {
        XCTAssertEqual(
            MapDisplayStyle.mapLibreNight.mapHomeVectorStyle,
            .night
        )
        XCTAssertEqual(
            MapDisplayStyle.mapLibreContrast.mapHomeVectorStyle,
            .contrast
        )
        XCTAssertEqual(
            MapDisplayStyle.mapLibreCasual.mapHomeVectorStyle,
            .casual
        )
        XCTAssertEqual(MapDisplayStyle.mapLibreRPG.mapHomeVectorStyle, .rpg)
        XCTAssertEqual(MapDisplayStyle.mapLibreInk.mapHomeVectorStyle, .ink)

        for style in [
            MapDisplayStyle.standard,
            .hybrid,
        ] {
            XCTAssertNil(style.mapHomeVectorStyle)
        }
    }

    func testMapStylesRemainDecodableAndRuntimePreservesSelection() {
        XCTAssertEqual(
            MapDisplayStyle.appleStyles,
            [.standard, .hybrid]
        )
        XCTAssertEqual(
            MapDisplayStyle.openFreeMapStyles,
            [
                .mapLibreRPG,
                .mapLibreCasual,
                .mapLibreNight,
                .mapLibreContrast,
                .mapLibreInk,
                .mapLibrePorcelain,
            ]
        )
        XCTAssertEqual(MapDisplayStyle.standard.provider, .apple)
        XCTAssertEqual(MapDisplayStyle.mapLibrePorcelain.mapHomeVectorStyle, .porcelain)
        // RTC1111A01: 경로 색은 백자에서만 테라코타, 나머지 모양은 모두 예전 청록.
        for style in MapDisplayStyle.allCases {
            XCTAssertEqual(MapHomeWBSTripStyle.actualRouteHex(for: style), style == .mapLibrePorcelain ? "#A8442F" : "#458B88", style.rawValue)
        }
        XCTAssertEqual(MapDisplayStyle.defaultStyle(for: .openFreeMap), .mapLibreRPG, "새 모양을 더해도 기본 지도는 그대로다")
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(MapHomeVectorStyle.porcelain.json.utf8)), "백자 지도 스타일 JSON이 깨지지 않는다")
        XCTAssertEqual(MapDisplayStyle.mapLibreCasual.provider, .openFreeMap)
        XCTAssertEqual(
            MapDisplayStyle.defaultStyle(for: .openFreeMap),
            .mapLibreRPG
        )
        XCTAssertEqual(
            MapDisplayStyle.defaultStyle(for: .apple),
            .standard
        )
        XCTAssertEqual(MapDisplayStyle.standard.runtimeStyle, .standard)
        for style in MapDisplayStyle.allCases {
            XCTAssertEqual(style.runtimeStyle, style)
        }
    }

    func testMapHomeVectorLabelsPreferKoreanAndCoverEveryNamedLayer() throws {
        let saved = AppLanguagePreference.current
        defer { AppLanguagePreference.save(saved) }
        AppLanguagePreference.save(.korean)
        let json = MapHomeVectorStyle.night.json
        XCTAssertFalse(json.contains("name:en"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let layers = try XCTUnwrap(object["layers"] as? [[String: Any]])
        let symbols = layers.filter { $0["type"] as? String == "symbol" }
        XCTAssertEqual(
            Set(symbols.compactMap { $0["source-layer"] as? String }),
            ["housenumber", "transportation_name", "waterway", "poi", "park", "water_name", "mountain_peak", "place", "aerodrome_label"]
        )
        for layer in symbols where layer["source-layer"] as? String != "housenumber" {
            let id = String(describing: layer["id"])
            let field = try XCTUnwrap((layer["layout"] as? [String: Any])?["text-field"] as? [Any], id)
            XCTAssertEqual(field[1] as? [String], ["get", "name:ko"], id)
        }
        // 역이 가장 먼저 자리를 차지하도록 맨 위에 둔다.
        XCTAssertEqual(MapHomeVectorLabels.layers.last?.id, "label-station")
        XCTAssertEqual(Set(MapHomeVectorLabels.layers.map(\.id)).count, MapHomeVectorLabels.layers.count)
    }

    func testMapHomeVectorLabelColorsStayReadableInEveryStyleAndSeason() throws {
        func luminance(_ hex: String) throws -> Double {
            let value = try XCTUnwrap(UInt32(hex.dropFirst().prefix(6), radix: 16), hex)
            let channels = [value >> 16 & 0xFF, value >> 8 & 0xFF, value & 0xFF].map { channel -> Double in
                let c = Double(channel) / 255
                return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
        }
        func contrast(_ a: String, _ b: String) throws -> Double {
            let (x, y) = try (luminance(a), luminance(b))
            return (max(x, y) + 0.05) / (min(x, y) + 0.05)
        }
        var palettes: [(String, MapHomeVectorLabels.Palette)] = [
            ("night", .night), ("contrast", .contrast), ("rpg", .rpg),
        ]
        // 달마다 하나씩 보면 계절이 섞이는 끝 달(5·8·11·2월)도 들어간다.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        for month in 1...12 {
            let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: month, day: 20)))
            palettes.append(("season-\(month)", .season(TaptionSeason.colors(on: date, calendar: calendar).map)))
        }
        for (name, palette) in palettes {
            for tone in MapHomeVectorLabels.Tone.allCases {
                // 물·공원은 큰 글자 기준(3:1), 나머지는 본문 기준(4.5:1).
                let minimum = tone == .water || tone == .park ? 3.0 : 4.5
                XCTAssertGreaterThanOrEqual(
                    try contrast(palette.text(tone), palette.halo(tone)), minimum, "\(name) \(tone)"
                )
            }
        }
    }

    func testMapHomeVectorBearingUsesCardinalDirections() {
        let origin = CLLocationCoordinate2D(latitude: 0, longitude: 0)

        XCTAssertEqual(
            MapHomeVectorNavigationMath.bearing(
                from: origin,
                to: CLLocationCoordinate2D(latitude: 1, longitude: 0)
            ),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            MapHomeVectorNavigationMath.bearing(
                from: origin,
                to: CLLocationCoordinate2D(latitude: 0, longitude: 1)
            ),
            90,
            accuracy: 0.001
        )
        XCTAssertEqual(
            MapHomeVectorNavigationMath.bearing(
                from: origin,
                to: CLLocationCoordinate2D(latitude: -1, longitude: 0)
            ),
            180,
            accuracy: 0.001
        )
        XCTAssertEqual(
            MapHomeVectorNavigationMath.bearing(
                from: origin,
                to: CLLocationCoordinate2D(latitude: 0, longitude: -1)
            ),
            270,
            accuracy: 0.001
        )
    }
}

@MainActor
final class MapHomeVectorRouteRenderingTests: XCTestCase {
    func testRoutesRemainVisibleAcrossZoomAndOffscreenRoundTrip() async throws {
        let center = CLLocationCoordinate2D(latitude: 37.55, longitude: 126.95)
        let coordinates = [
            CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude - 0.1),
            center,
            CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude + 0.1),
        ]
        func route(_ id: String) -> MapHomeVectorRoute {
            MapHomeVectorRoute(id: id, coordinates: coordinates,
                geometrySignature: MapHomeRouteGeometrySignature.value(for: coordinates),
                colorHex: "#ED5599", opacity: 1)
        }
        let parent = MapHomeVectorMap(style: .rpg, cameraPosition: .automatic, cameraRevision: 0,
            historicalRoutes: [route("history")], activeRoute: route("active"),
            expectedRoutes: [route("expected")], subwayRoutes: [route("subway")], markers: [],
            contentInsets: .zero, longPressExclusionFrame: .zero, followsHeading: false,
            headingDegrees: 0, displayedCoordinate: center, onViewportChange: { _, _ in },
            onSingleFingerPanBegan: {}, onSingleFingerPanEnded: {}, onUserCameraGesture: {},
            onLongPress: { _ in }, onSingleTap: { _, _ in })
        let coordinator = parent.makeCoordinator()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        window.rootViewController = UIViewController()
        let map = MLNMapView(frame: window.bounds,
            styleJSON: ##"{"version":8,"sources":{},"layers":[{"id":"background","type":"background","paint":{"background-color":"#ffffff"}}]}"##)
        map.delegate = coordinator
        coordinator.attach(to: map)
        window.rootViewController?.view.addSubview(map)
        window.makeKeyAndVisible()
        defer {
            coordinator.detach(from: map)
            map.delegate = nil
            map.removeFromSuperview()
            window.isHidden = true
        }
        let layers: Set<String> = ["tap-historical-route", "tap-active-route", "tap-expected-route", "tap-subway-route"]
        for _ in 0..<80 where map.style?.layer(withIdentifier: "tap-active-route") == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        let loadedStyle = try XCTUnwrap(map.style)
        XCTAssertNotNil(loadedStyle.layer(withIdentifier: "tap-active-route"))
        XCTAssertNotNil(loadedStyle.source(withIdentifier: "tap-active-route-source") as? MLNShapeSource)
        for zoom in [14.0, 20, 8, 16, 12, 18, 14] {
            map.setCenter(CLLocationCoordinate2D(latitude: 35, longitude: 129), zoomLevel: zoom, animated: false)
            map.setCenter(center, zoomLevel: zoom, animated: false)
            var visible = Set<String>()
            for _ in 0..<160 {
                try await Task.sleep(for: .milliseconds(50))
                coordinator.updateContent(in: map)
                visible = Set(layers.filter {
                    !map.visibleFeatures(in: map.bounds, styleLayerIdentifiers: [$0]).isEmpty
                })
                if visible == layers { break }
            }
            XCTAssertEqual(visible, layers,
                "route layers at zoom \(zoom), app state \(UIApplication.shared.applicationState.rawValue), "
                + "protected data \(UIApplication.shared.isProtectedDataAvailable)")
        }
        map.styleJSON = #"{"version":8,"sources":{},"layers":[]}"#
        for _ in 0..<160 {
            try await Task.sleep(for: .milliseconds(50))
            coordinator.updateContent(in: map)
            if layers.allSatisfy({ !map.visibleFeatures(in: map.bounds, styleLayerIdentifiers: [$0]).isEmpty }) { break }
        }
        for layer in layers {
            XCTAssertFalse(map.visibleFeatures(in: map.bounds, styleLayerIdentifiers: [layer]).isEmpty,
                "style reload must restore \(layer) even when route content is unchanged")
        }
    }
}

final class MapHomeSubwayRouteCacheTests: XCTestCase {
    func testCameraRedrawKeepsRestoredRouteUntilDayInputIsReady() {
        let cache = MapHomeSubwayRouteCache()
        let day = Date(timeIntervalSince1970: 1_790_208_000)
        let overlay = MapHomeSubwayRouteOverlay(id: UUID(), coordinates: [
            CLLocationCoordinate2D(latitude: 37.5, longitude: 126.7),
            CLLocationCoordinate2D(latitude: 37.6, longitude: 126.8),
        ], estimated: false)
        cache.restore(day: day, overlays: [overlay])
        for minute in [600, 600, 601, 601] {
            XCTAssertEqual(cache.routes(day: day, minute: minute, sourceRevision: nil) {
                XCTFail("unavailable input must not erase a restored route")
                return []
            }.map(\.id), [overlay.id])
        }
        var computations = 0
        XCTAssertEqual(cache.routes(day: day, minute: 601, sourceRevision: 1) {
            computations += 1
            return [overlay]
        }.map(\.id), [overlay.id])
        _ = cache.routes(day: day, minute: 601, sourceRevision: 1) {
            computations += 1
            return []
        }
        XCTAssertEqual(computations, 1)
        cache.invalidate()
        XCTAssertEqual(cache.routes(day: day, minute: 601, sourceRevision: nil) { [] }.count, 1)
        XCTAssertTrue(cache.routes(day: day, minute: 601, sourceRevision: 2) { [] }.isEmpty,
            "a ready, empty source must remove deleted routes")
    }

    func testPendingDifferentDayDoesNotShowPreviousDaysRoute() {
        let cache = MapHomeSubwayRouteCache()
        let day = Date(timeIntervalSince1970: 1_790_208_000)
        cache.restore(day: day, overlays: [MapHomeSubwayRouteOverlay(id: UUID(), coordinates: [], estimated: false)])
        XCTAssertTrue(cache.routes(day: day.addingTimeInterval(86_400), minute: 600,
            sourceRevision: nil) { [] }.isEmpty)
    }
}

@MainActor
final class MapHomeStartupCameraTests: XCTestCase {
    private let center = CLLocationCoordinate2D(latitude: 37.55, longitude: 126.95)

    private func map(revision: Int = 1, position: MapCameraPosition? = nil,
                     onViewport: @escaping (MapHomeVectorViewport, Bool) -> Void = { _, _ in }) -> MapHomeVectorMap {
        MapHomeVectorMap(style: .rpg,
            cameraPosition: position ?? .camera(MapCamera(centerCoordinate: center,
                distance: MapHomeStartupCameraPolicy.distance)), cameraRevision: revision,
            historicalRoutes: [], activeRoute: nil, expectedRoutes: [], subwayRoutes: [], markers: [],
            contentInsets: .zero, longPressExclusionFrame: .zero, followsHeading: false,
            headingDegrees: 0, displayedCoordinate: center, onViewportChange: onViewport,
            onSingleFingerPanBegan: {}, onSingleFingerPanEnded: {}, onUserCameraGesture: {},
            onLongPress: { _ in }, onSingleTap: { _, _ in })
    }

    func testPlaceRangeMapFitsSpanAndDrawsClosedCircle() {
        let zoom = MapHomePlaceRangeMap.zoomLevel(latitude: 0, spanMeters: 512, points: 512)
        XCTAssertEqual(pow(2, zoom), 40_075_016.686 / 512, accuracy: 1)
        XCTAssertGreaterThan(
            MapHomePlaceRangeMap.zoomLevel(latitude: 37.5, spanMeters: 200, points: 170),
            MapHomePlaceRangeMap.zoomLevel(latitude: 37.5, spanMeters: 1_500, points: 170)
        )
        let circle = MapHomePlaceRangeMap.circle(center: center, radiusMeters: 100)
        XCTAssertEqual(circle.first?.latitude ?? 0, circle.last?.latitude ?? 1, accuracy: 1e-9)
        let origin = CLLocation(latitude: center.latitude, longitude: center.longitude)
        for point in circle {
            let distance = origin.distance(from: CLLocation(latitude: point.latitude, longitude: point.longitude))
            XCTAssertEqual(distance, 100, accuracy: 2)
        }
    }

    func testRestaurantWithDefaultNameShowsRestaurant() {
        XCTAssertEqual(FrequentPlace(kind: .restaurant, name: "사용자 지점").displayName, "식당")
        XCTAssertEqual(FrequentPlace(kind: .restaurant, name: "User location").displayName, "식당")
        XCTAssertEqual(FrequentPlace(kind: .restaurant, name: "구내식당").displayName, "구내식당")
    }

    func testMeetingEventOverridesSeatedActionOnly() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func event(_ title: String, attendees: Int? = nil, allDay: Bool = false) -> CalendarRecord {
            var record = CalendarRecord(
                id: title, calendarID: "c", title: title,
                span: TimeSpan(start: start, end: start.addingTimeInterval(7_200)),
                isAllDay: allDay, calendarTitle: "c"
            )
            record.attendeeCount = attendees
            return record
        }
        XCTAssertTrue(MapHomeMeetingPolicy.isMeeting(event("아모텍 회의")))
        XCTAssertTrue(MapHomeMeetingPolicy.isMeeting(event("고객사", attendees: 3)))
        XCTAssertFalse(MapHomeMeetingPolicy.isMeeting(event("치과")))
        XCTAssertFalse(MapHomeMeetingPolicy.isMeeting(event("점심 미팅")))
        XCTAssertFalse(MapHomeMeetingPolicy.isMeeting(event("전사 회의", allDay: true)))
        let inside = start.addingTimeInterval(600)
        let events = [event("아모텍 회의")]
        XCTAssertEqual(MapHomeMeetingPolicy.action(.walking, at: inside, events: events, travel: []), .meeting)
        XCTAssertEqual(MapHomeMeetingPolicy.action(.eating, at: inside, events: events, travel: []), .eating)
        XCTAssertEqual(MapHomeMeetingPolicy.action(.walking, at: start.addingTimeInterval(8_000), events: events, travel: []), .walking)
        // 회의 조각은 머문 구간(업무)에만, 이동 구간은 제 상세 무늬(지하철 세로줄)를 쓴다(DTP1111A01).
        XCTAssertEqual(
            MapHomeTimeSidebarMath.detailPatternSpans(
                [MapHomeRailDetailSpan(range: 60..<120, pattern: .diagonal)],
                segments: [
                    MapHomeTimeRailSegment(startMinute: 0, endMinute: 90, categoryID: "work", title: ""),
                    MapHomeTimeRailSegment(startMinute: 90, endMinute: 200, categoryID: "movement", title: "", behavior: "subway"),
                    MapHomeTimeRailSegment(startMinute: 200, endMinute: 300, categoryID: "sleep", title: "", behavior: "core"),
                    MapHomeTimeRailSegment(startMinute: 300, endMinute: 400, categoryID: "sleep", title: "", behavior: "deep"),
                ],
                window: 0...1_440
            ),
            [
                MapHomeRailDetailSpan(range: 60..<90, pattern: .diagonal),
                MapHomeRailDetailSpan(range: 90..<200, pattern: .vertical),
                MapHomeRailDetailSpan(range: 300..<400, pattern: .crosshatch),
            ]
        )
    }

    /// LPR1111A01: 「나중에 확인」을 누른 날에만 질문을 쉬고, 날이 바뀌면 다시 묻는다.
    func testLaunchPromptDeferralLastsOnlyForThatDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let evening = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 22))!
        let key = MapHomeLaunchPromptDeferral.dayKey(evening, calendar: calendar)
        XCTAssertEqual(key, "2026-11-11")
        XCTAssertTrue(MapHomeLaunchPromptDeferral.isDeferred(key, now: evening.addingTimeInterval(3_600), calendar: calendar))
        XCTAssertFalse(MapHomeLaunchPromptDeferral.isDeferred(key, now: evening.addingTimeInterval(3 * 3_600), calendar: calendar), "자정이 지나면 다시 묻는다")
        XCTAssertFalse(MapHomeLaunchPromptDeferral.isDeferred(nil, now: evening, calendar: calendar))
        XCTAssertFalse(MapHomeLaunchPromptDeferral.isDeferred("", now: evening, calendar: calendar))
    }

    /// 앱을 열 때 묻는 순서: 내 차 → 탑승 → 일정 → 자주 가는 곳 → 미확인. 한 번 연 동안 같은 것은 다시 묻지 않는다(ASK1111A01).
    func testLaunchPromptsComeOneAtATimeInOrder() {
        func next(_ asked: Set<String>, unconfirmed: Int = 30) -> MapHomeLaunchPrompt? {
            MapHomeLaunchPromptPolicy.next(
                carAudio: "Audi", boardingIDs: ["b1"], calendarTitles: ["주간 회의"],
                placeSuggestionID: "p1", unconfirmedMinutes: unconfirmed, asked: asked
            )
        }
        var asked = Set<String>()
        var order: [MapHomeLaunchPrompt] = []
        while let prompt = next(asked) { order.append(prompt); asked.insert(prompt.id) }
        XCTAssertEqual(order, [.carAudio("Audi"), .boarding("b1"), .calendarTitle("주간 회의"), .frequentPlace("p1"), .unconfirmed(minutes: 30)])
        XCTAssertNil(next(["car:Audi", "boarding:b1", "calendar:\(CalendarTitleClassification.key("주간 회의"))", "place:p1"], unconfirmed: 5))
    }

    /// TDL1112A01: 「확인할 것」 목록은 전부를 보이고, AI에게는 AI가 명령으로 끝낼 수 있는 것만 넘기며, 넘긴 것은 그날만 건너뛴다.
    func testTodoListShowsEverythingAndHandsOnlyWhatTheAICanFinish() {
        let all = MapHomeLaunchPromptPolicy.all(carAudio: "Audi", boardingIDs: ["b1"], calendarTitles: ["주간 회의"],
                                                placeSuggestionID: "p1", unconfirmedMinutes: 30)
        XCTAssertEqual(all.count, 5)
        // HND1112A01: 내 차·일정 제목·자주 머무는 곳도 AI 명령이 생겨 다섯 가지 모두 넘길 수 있다.
        XCTAssertEqual(all.filter { MapHomeLaunchPromptHandoff.task(for: $0) != nil }.count, 5)
        XCTAssertTrue(MapHomeLaunchPromptHandoff.task(for: .carAudio("Audi"))?.text.contains("set_car_audio") == true)
        XCTAssertTrue(MapHomeLaunchPromptHandoff.task(for: .carAudio("Audi"))?.text.contains("「Audi」") == true)
        let titleTask = MapHomeLaunchPromptHandoff.task(for: .calendarTitle("주간 회의"))
        XCTAssertTrue(titleTask?.text.contains("set_calendar_title_detail") == true && titleTask?.text.contains("work.") == true, "고를 수 있는 상세활동 id를 함께 준다")
        XCTAssertLessThan(titleTask?.text.count ?? 0, 2_000, "AI 확인 목록 글 한도 안")
        XCTAssertEqual(MapHomeLaunchPromptHandoff.task(for: .frequentPlace("p1"))?.kind, .stayPlace)
        XCTAssertEqual(MapHomeLaunchPromptHandoff.task(for: .unconfirmed(minutes: 30))?.kind, .other)
        XCTAssertTrue(MapHomeLaunchPromptHandoff.task(for: .unconfirmed(minutes: 30))?.text.contains("classify_unconfirmed") == true)
        XCTAssertEqual(MapHomeLaunchPromptHandoff.task(for: .boarding("b1"))?.kind, .routeCheck)

        let defaults = UserDefaults(suiteName: "todo-handoff-\(UUID().uuidString)")!
        let day = Date(timeIntervalSinceReferenceDate: 816_066_000)
        XCTAssertTrue(MapHomeLaunchPromptHandoff.handed(now: day, defaults: defaults).isEmpty)
        MapHomeLaunchPromptHandoff.markHanded("unconfirmed", now: day, defaults: defaults)
        MapHomeLaunchPromptHandoff.markHanded("boarding:b1", now: day, defaults: defaults)
        XCTAssertEqual(MapHomeLaunchPromptHandoff.handed(now: day, defaults: defaults), ["unconfirmed", "boarding:b1"])
        XCTAssertTrue(MapHomeLaunchPromptHandoff.handed(now: day.addingTimeInterval(86_400), defaults: defaults).isEmpty, "다음 날에는 다시 묻는다")
    }

    /// 분류를 정하지 않은 오늘·어제 일정 제목만, 같은 제목은 한 번, 종일·취소·아직 안 시작한 일정은 빼고.
    func testUnansweredCalendarTitlesSkipAnsweredAllDayAndFuture() {
        let now = Date(timeIntervalSinceReferenceDate: 816_066_000)
        func event(_ title: String, hoursAgo: Double, allDay: Bool = false) -> CalendarRecord {
            CalendarRecord(id: title + "\(hoursAgo)", calendarID: "c", title: title,
                           span: TimeSpan(start: now.addingTimeInterval(-hoursAgo * 3600), end: now.addingTimeInterval(-hoursAgo * 3600 + 3600)),
                           isAllDay: allDay, calendarTitle: "c")
        }
        let events = [event("주간 회의", hoursAgo: 2), event("주간 회의", hoursAgo: 26), event("치과", hoursAgo: 3),
                      event("휴가", hoursAgo: 4, allDay: true), event("저녁 약속", hoursAgo: -2), event("오래전", hoursAgo: 80)]
        let stored = [CalendarTitleClassification.key("치과"): CalendarTitleDetail(detailID: "health.hospital")]
        XCTAssertEqual(MapHomeLaunchPromptPolicy.unansweredCalendarTitles(events, stored: stored, now: now), ["주간 회의"])
    }

    /// 센서로 정할 수 없는 상세 17개는 기본 목록에서 빠져 「직접 추가」로 가고, 일정 제목으로는 그대로 붙는다(DTL1111A01).
    func testUserAddedDetailsLeaveTheDefaultListButCalendarStillSetsThem() {
        let userAdded = RecordClassificationCatalog.categories.flatMap(\.details).filter { $0.userAdded == true }.map(\.id)
        XCTAssertEqual(userAdded.count, 17)
        XCTAssertFalse(MapHomeCategoryDetailRows.details(for: "hobby").contains { $0.id == "hobby.reading" })
        XCTAssertTrue(MapHomeCategoryDetailRows.userAddedDetails(for: "hobby").contains { $0.id == "hobby.reading" })
        XCTAssertTrue(MapHomeCategoryDetailRows.details(for: "work").contains { $0.id == "work.meeting" })
        XCTAssertTrue(MapHomeCategoryDetailRows.userAddedDetails(for: "movement").isEmpty)
        XCTAssertEqual(CalendarTitleClassification.ruleDetailID(for: "독서 모임"), "hobby.reading")
        XCTAssertTrue(CalendarTitleClassification.selectableDetailIDs.contains("hobby.reading"))
        // 예전 기록의 상세 이름은 계속 읽힌다.
        XCTAssertEqual(RecordClassificationCatalog.detailTitle(categoryID: "hobby", behavior: "reading"), "독서")
    }

    /// 한 대분류 안의 상세끼리는 무늬가 겹치지 않고, 기본 상세는 무늬가 없다(DTP1111A01).
    func testDetailPatternsAreDistinctWithinEachCategory() {
        for category in RecordClassificationCatalog.categories {
            let patterns = category.details.compactMap { MapHomeDetailPattern.pattern(for: $0.behavior) }
            XCTAssertEqual(Set(patterns).count, patterns.count, category.id)
        }
        XCTAssertNil(MapHomeDetailPattern.pattern(for: "stationary"))
        XCTAssertNil(MapHomeDetailPattern.pattern(for: "core"))
        XCTAssertNil(MapHomeDetailPattern.pattern(for: "meal"))
        XCTAssertNotNil(MapHomeDetailPattern.pattern(for: "automotive"))
    }

    func testDailyCardLevelFollowsTheDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        func day(_ d: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: d))! }
        var season = MapHomeGrowthSeason(year: 2026)
        season.level = 5
        let history = MapHomeGrowthHistory(season: season)
        // 그날 카드의 집은 그해 몇째 날인지로 정한다(HOM1111A01): 11월 1일은 305.
        XCTAssertEqual(MapHomeGrowthPolicy.level(on: day(4), in: history, calendar: calendar), 308)
        XCTAssertEqual(MapHomeGrowthPolicy.level(on: day(3), in: history, calendar: calendar), 307)
        XCTAssertEqual(MapHomeGrowthPolicy.level(on: day(1), in: history, calendar: calendar), 305)
        let old = try JSONDecoder().decode(MapHomeGrowthSeason.self, from: Data(#"{"year":2026,"level":3}"#.utf8))
        XCTAssertEqual(old.level, 3, "예전 저장본도 읽는다(날짜별 레벨 칸은 HOM1111A01에서 없앰)")
    }

    func testLabelNamesFollowLanguageOrder() {
        XCTAssertEqual(MapHomeVectorLabels.nameFields(languageCode: nil), #"["get", "name:ko"], ["get", "name"]"#)
        XCTAssertEqual(MapHomeVectorLabels.nameFields(languageCode: "en"), #"["get", "name:en"], ["get", "name"]"#)
        XCTAssertEqual(
            MapHomeVectorLabels.nameFields(languageCode: "ja"),
            #"["get", "name:ja"], ["get", "name:en"], ["get", "name"]"#
        )
        XCTAssertEqual(
            MapHomeVectorLabels.nameFields(languageCode: "zh-Hant"),
            #"["get", "name:zh-Hant"], ["get", "name:zh"], ["get", "name:en"], ["get", "name"]"#
        )
    }

    func testEnglishMapLabelsPreferEnglishNames() throws {
        let saved = AppLanguagePreference.current
        defer { AppLanguagePreference.save(saved) }
        AppLanguagePreference.save(.english)
        let layer = try XCTUnwrap(MapHomeVectorLabels.layers.first { $0.id == "label-road-major" })
        let field = try XCTUnwrap(MapHomeVectorLabels.textField(of: layer) as? [Any])
        XCTAssertEqual(field[1] as? [String], ["get", "name:en"])
        XCTAssertFalse(MapHomeVectorStyle.night.json.contains("name:ko"))
    }

    /// MLG1105A02: 영어 사용자에게 실제 스타일 JSON의 모든 이름 칸이 `name:en`을 먼저 읽는다.
    func testEnglishStyleJSONReadsEnglishNameFirstInEveryLabelLayer() throws {
        let saved = AppLanguagePreference.current
        defer { AppLanguagePreference.save(saved) }
        AppLanguagePreference.save(.english)
        for style in MapHomeVectorStyle.allCases {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(style.json.utf8)) as? [String: Any])
            let layers = try XCTUnwrap(object["layers"] as? [[String: Any]])
            let named = layers.filter { $0["type"] as? String == "symbol" && $0["source-layer"] as? String != "housenumber" }
            XCTAssertFalse(named.isEmpty, style.rawValue)
            for layer in named {
                let id = "\(style.rawValue)/\(layer["id"] ?? "")"
                let field = try XCTUnwrap((layer["layout"] as? [String: Any])?["text-field"] as? [Any], id)
                XCTAssertEqual(field[1] as? [String], ["get", "name:en"], id)
            }
        }
    }

    func testChangingLanguageRewritesMapLabelsWithoutNewStyle() async throws {
        let saved = AppLanguagePreference.current
        defer { AppLanguagePreference.save(saved) }
        AppLanguagePreference.save(.korean)
        var parent = map()
        parent.languageKey = AppLanguagePreference.korean.rawValue
        let coordinator = parent.makeCoordinator()
        let view = MLNMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 600), styleJSON: MapHomeVectorStyle.rpg.json)
        for _ in 0..<100 where view.style?.layer(withIdentifier: "label-road-major") == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        let style = try XCTUnwrap(view.style)
        let layer = try XCTUnwrap(style.layer(withIdentifier: "label-road-major") as? MLNSymbolStyleLayer)
        XCTAssertTrue(layer.text.description.contains("name:ko"), layer.text.description)

        AppLanguagePreference.save(.japanese)
        parent.languageKey = AppLanguagePreference.japanese.rawValue
        coordinator.parent = parent
        coordinator.applyLabelLanguageIfNeeded(to: view)

        XCTAssertTrue(view.style === style)
        XCTAssertTrue(layer.text.description.contains("name:ja"), layer.text.description)
        // 줄 번호 대체(`ref`)는 언어와 무관하게 남는다.
        XCTAssertTrue(layer.text.description.contains("ref"), layer.text.description)
        for label in MapHomeVectorLabels.layers {
            XCTAssertNotNil(MapHomeVectorLabels.textField(of: label), label.id)
        }
    }

    func testCameraCommandWaitsForNonzeroViewport() {
        let coordinator = map().makeCoordinator()
        let view = MLNMapView(frame: .zero, styleJSON: #"{"version":8,"sources":{},"layers":[]}"#)
        coordinator.attach(to: view)
        defer { coordinator.detach(from: view) }
        coordinator.applyCameraCommandIfNeeded(to: view)
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        coordinator.applyCameraCommandIfNeeded(to: view)
        XCTAssertEqual(view.camera.altitude, MapHomeStartupCameraPolicy.distance, accuracy: 1)
        XCTAssertEqual(view.centerCoordinate.latitude, center.latitude, accuracy: 0.00001)
        XCTAssertEqual(view.centerCoordinate.longitude, center.longitude, accuracy: 0.00001)
    }

    func testFirstRenderedFrameAppliesPendingCameraWithoutResettingManualZoom() {
        let coordinator = map().makeCoordinator()
        let view = MLNMapView(frame: .zero, styleJSON: #"{"version":8,"sources":{},"layers":[]}"#)
        coordinator.attach(to: view)
        defer { coordinator.detach(from: view) }
        coordinator.applyCameraCommandIfNeeded(to: view)
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        coordinator.mapViewDidFinishRenderingFrame(view, fullyRendered: true)
        XCTAssertEqual(view.camera.altitude, MapHomeStartupCameraPolicy.distance, accuracy: 1)

        view.setCenter(center, zoomLevel: 9, animated: false)
        let manualDistance = view.camera.altitude
        coordinator.updateContent(in: view)
        coordinator.applyCameraCommandIfNeeded(to: view)
        coordinator.mapViewDidFinishRenderingFrame(view, fullyRendered: true)
        XCTAssertEqual(view.camera.altitude, manualDistance, accuracy: 1)
    }

    func testOnlyBackgroundReturnRequestsZoomRestorationOnce() {
        var policy = MapHomeStartupCameraPolicy()
        XCTAssertFalse(policy.shouldRestoreZoom(on: .active))
        XCTAssertFalse(policy.shouldRestoreZoom(on: .inactive))
        XCTAssertFalse(policy.shouldRestoreZoom(on: .active))
        XCTAssertFalse(policy.shouldRestoreZoom(on: .background))
        XCTAssertFalse(policy.shouldRestoreZoom(on: .inactive))
        XCTAssertTrue(policy.shouldRestoreZoom(on: .active))
        XCTAssertFalse(policy.shouldRestoreZoom(on: .active))
        XCTAssertFalse(policy.shouldRestoreZoom(on: .background))
        XCTAssertTrue(policy.shouldRestoreZoom(on: .active))
    }

    func testRestoredCameraKeepsCenterAndAnglesAtInitialDistance() {
        let camera = MapCamera(centerCoordinate: center, distance: 50_000_000, heading: 70, pitch: 30)
        let restored = MapHomeStartupCameraPolicy.camera(
            restoring: camera, fallbackCenter: MapHomeStartupCameraPolicy.fallbackCenter)
        XCTAssertEqual(restored.distance, MapHomeStartupCameraPolicy.distance)
        XCTAssertEqual(restored.centerCoordinate.latitude, center.latitude)
        XCTAssertEqual(restored.centerCoordinate.longitude, center.longitude)
        XCTAssertEqual(restored.heading, 70)
        XCTAssertEqual(restored.pitch, 30)
        let initial = MapHomeStartupCameraPolicy.camera(restoring: nil, fallbackCenter: center)
        XCTAssertEqual(initial.distance, MapHomeStartupCameraPolicy.distance)
        XCTAssertEqual(initial.centerCoordinate.latitude, center.latitude)
        XCTAssertEqual(initial.centerCoordinate.longitude, center.longitude)
    }

    func testForegroundCameraCommandRestoresZoomAfterManualZoomOut() {
        let coordinator = map().makeCoordinator()
        let view = MLNMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 600),
            styleJSON: #"{"version":8,"sources":{},"layers":[]}"#)
        coordinator.attach(to: view)
        defer { coordinator.detach(from: view) }
        coordinator.applyCameraCommandIfNeeded(to: view)
        let movedCenter = CLLocationCoordinate2D(latitude: 37.61, longitude: 127.01)
        view.setCenter(movedCenter, zoomLevel: 3, animated: false)
        let camera = MapCamera(centerCoordinate: view.centerCoordinate, distance: view.camera.altitude)
        coordinator.parent = map(revision: 2, position: .camera(
            MapHomeStartupCameraPolicy.camera(restoring: camera, fallbackCenter: center)))
        coordinator.applyCameraCommandIfNeeded(to: view)
        XCTAssertEqual(view.camera.altitude, MapHomeStartupCameraPolicy.distance, accuracy: 1)
        XCTAssertEqual(view.centerCoordinate.latitude, movedCenter.latitude, accuracy: 0.00001)
        XCTAssertEqual(view.centerCoordinate.longitude, movedCenter.longitude, accuracy: 0.00001)
        coordinator.updateContent(in: view)
        coordinator.mapViewDidFinishRenderingFrame(view, fullyRendered: true)
        XCTAssertEqual(view.camera.altitude, MapHomeStartupCameraPolicy.distance, accuracy: 1)
    }

    func testAutomaticCameraUsesInitialDistanceWhileLocationLoads() {
        let coordinator = map(position: .automatic).makeCoordinator()
        let view = MLNMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 600),
            styleJSON: #"{"version":8,"sources":{},"layers":[]}"#)
        coordinator.attach(to: view)
        defer { coordinator.detach(from: view) }
        coordinator.applyCameraCommandIfNeeded(to: view)
        XCTAssertEqual(view.camera.altitude, MapHomeStartupCameraPolicy.distance, accuracy: 1)
    }

    func testQueuedViewportFromBeforeCameraResetIsDiscarded() async {
        var received: [MapHomeVectorViewport] = []
        let coordinator = map(onViewport: { viewport, _ in received.append(viewport) }).makeCoordinator()
        let view = MLNMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 600),
            styleJSON: #"{"version":8,"sources":{},"layers":[]}"#)
        coordinator.attach(to: view)
        defer { coordinator.detach(from: view) }
        coordinator.applyCameraCommandIfNeeded(to: view)
        view.setCenter(center, zoomLevel: 3, animated: false)
        coordinator.mapView(view, regionDidChangeAnimated: false)
        coordinator.parent = map(revision: 2, onViewport: { viewport, _ in received.append(viewport) })
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertTrue(received.isEmpty)
        coordinator.applyCameraCommandIfNeeded(to: view)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.last?.cameraDistance ?? 0, MapHomeStartupCameraPolicy.distance, accuracy: 1)
    }
}

@MainActor
final class MapHomePerformanceHelperTests: XCTestCase {
    func testGrowthHistoryCacheReturnsDecodedValueAndFollowsStoredData() throws {
        let cache = MapHomeGrowthHistoryCache()
        let first = MapHomeGrowthHistory.initial(for: Date(timeIntervalSince1970: 1_790_000_000))
        var second = first
        second.season.level += 1
        let firstData = try JSONEncoder().encode(first)
        let secondData = try JSONEncoder().encode(second)

        XCTAssertNil(cache.history(for: Data()))
        XCTAssertEqual(cache.history(for: firstData), first)
        XCTAssertEqual(cache.history(for: firstData), first)
        XCTAssertEqual(cache.history(for: secondData), second, "A changed stored value must not return the cached history")
        XCTAssertEqual(cache.history(for: secondData)?.season.level, second.season.level)
        XCTAssertNil(cache.history(for: Data("not json".utf8)))
    }

    func testDateTextReusesFormatterAndKeepsFormatLocaleAndTimeZone() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let english = Locale(identifier: "en_US_POSIX")
        let korean = Locale(identifier: "ko_KR")
        let a = MapHomeDateText.string(from: date, format: "yyyy-MM-dd", locale: english)
        XCTAssertEqual(a, MapHomeDateText.string(from: date, format: "yyyy-MM-dd", locale: english))
        let formatter = DateFormatter()
        formatter.locale = english
        formatter.dateFormat = "yyyy-MM-dd"
        XCTAssertEqual(a, formatter.string(from: date))
        let weekdayEnglish = MapHomeDateText.string(from: date, format: "EEEE", locale: english)
        let weekdayKorean = MapHomeDateText.string(from: date, format: "EEEE", locale: korean)
        XCTAssertNotEqual(weekdayEnglish, weekdayKorean)
    }
}

final class WeatherRetiredProviderTests: XCTestCase {
    private func context(_ offset: TimeInterval, provider: String?, airProvider: String? = nil) -> WeatherContext {
        let observedAt = Date(timeIntervalSince1970: 1_790_000_000 + offset)
        return WeatherContext(
            observedAt: observedAt, providerName: provider, condition: "맑음", symbolName: "sun.max.fill",
            temperatureCelsius: 20 + offset / 3_600,
            airQuality: airProvider.map {
                AirQualityContext(pm10MicrogramsPerCubicMeter: 20, pm25MicrogramsPerCubicMeter: 10,
                    observedAt: observedAt, providerName: $0, isFallback: true)
            })
    }

    func testCoalescedDropsRowsFromRetiredOpenMeteoProviderOnly() {
        let kept = context(0, provider: "WeatherKit")
        let legacyUnknown = context(3_600, provider: nil)
        let retired = context(7_200, provider: "Open-Meteo")
        let result = WeatherTimelineEngine.coalesced([retired, legacyUnknown, kept])
        XCTAssertEqual(Set(result.map(\.id)), [kept.id, legacyUnknown.id])
    }

    func testCoalescedRemovesRetiredAirQualityFromKeptRows() throws {
        let row = context(0, provider: "WeatherKit", airProvider: "Open-Meteo")
        let korean = context(3_600, provider: "WeatherKit", airProvider: "에어코리아")
        let result = WeatherTimelineEngine.coalesced([row, korean])
        XCTAssertEqual(result.count, 2)
        XCTAssertNil(try XCTUnwrap(result.first { $0.id == row.id }).airQuality)
        XCTAssertEqual(try XCTUnwrap(result.first { $0.id == korean.id }).airQuality?.providerName, "에어코리아")
    }
}

/// App Store Connect rejects an upload whose HealthKit entitlement has no
/// matching purpose strings, so keep both keys even though the iPhone app only reads.
final class HealthPurposeStringContractTests: XCTestCase {
    func testHealthKitPurposeStringsArePresent() {
        for key in ["NSHealthShareUsageDescription", "NSHealthUpdateUsageDescription"] {
            let value = Bundle.main.object(forInfoDictionaryKey: key) as? String
            XCTAssertFalse(value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true, "\(key) is required for HealthKit uploads")
        }
    }
}

/// The design tokens replaced hard-coded literals, so each token must keep the
/// exact value it replaced.
final class DesignTokenValueTests: XCTestCase {
    func testRadiusTokensKeepReplacedValues() {
        XCTAssertEqual(TaptionRadius.tight, 7)
        XCTAssertEqual(TaptionRadius.small, 8)
        XCTAssertEqual(TaptionRadius.control, 9)
        XCTAssertEqual(TaptionRadius.field, 10)
        XCTAssertEqual(TaptionRadius.compact, 11)
        XCTAssertEqual(TaptionRadius.panel, 12)
        XCTAssertEqual(TaptionRadius.tile, 13)
        XCTAssertEqual(TaptionRadius.card, 14)
    }

    func testSpacingTokensKeepReplacedValues() {
        XCTAssertEqual(TaptionSpacing.tight, 4)
        XCTAssertEqual(TaptionSpacing.compact, 5)
        XCTAssertEqual(TaptionSpacing.snug, 6)
        XCTAssertEqual(TaptionSpacing.cozy, 7)
        XCTAssertEqual(TaptionSpacing.regular, 8)
    }

    func testColorTokensKeepReplacedLiterals() {
        // 토큰 값은 양피지 기준이다. 시험 기기에 남은 지도 테마에 흔들리지 않게 고정한다.
        let savedTheme = TaptionUITheme.current
        TaptionUITheme.apply(.classic)
        defer { TaptionUITheme.apply(savedTheme) }
        let expected: [(Color, Color)] = [
            (.tpControlFill, Color(red: 0.94, green: 0.94, blue: 0.95)),
            (.tpControlFillSoft, Color(red: 0.95, green: 0.95, blue: 0.96)),
            (.tpFieldFill, Color(red: 0.965, green: 0.965, blue: 0.975)),
            (.tpControlStroke, Color(red: 0.89, green: 0.89, blue: 0.91)),
            (.tpTrackFill, Color(red: 0.93, green: 0.93, blue: 0.94)),
            (.tpWarningTint, Color(red: 1.00, green: 0.95, blue: 0.85)),
            (.tpSuccessTint, Color(red: 0.93, green: 0.96, blue: 0.91)),
        ]
        for (token, literal) in expected {
            XCTAssertEqual(components(token), components(literal))
        }
    }

    private func components(_ color: Color) -> [CGFloat] {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue, alpha]
    }
}

/// User-facing error and status messages used to be Korean-only. Each pair
/// must keep the original Korean wording and give English users Hangul-free text.
final class LocalizedMessageContractTests: XCTestCase {
    private func containsHangul(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            (0xAC00...0xD7A3).contains($0.value)
                || (0x1100...0x11FF).contains($0.value)
                || (0x3130...0x318F).contains($0.value)
        }
    }

    private func assertPair(
        _ korean: String,
        _ english: String,
        expectedKorean: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(korean, expectedKorean, file: file, line: line)
        XCTAssertFalse(english.isEmpty, file: file, line: line)
        XCTAssertFalse(containsHangul(english), "\(english)", file: file, line: line)
        XCTAssertNotEqual(korean, english, file: file, line: line)
    }

    func testAppModelMessagesKeepKoreanAndHaveEnglish() {
        let cases: [(AppModelMessage, String)] = [
            (.dataLoadFailed("detail"), "저장된 데이터를 불러오지 못했습니다. detail"),
            (.locationReadFailed("detail"), "위치 기록을 읽지 못했습니다. detail"),
            (.sensorSaveFailed("detail"), "센서 기록을 저장하지 못했습니다. detail"),
            (.floorOutOfRange(lower: -3, upper: 60), "층수는 지하 3층부터 60층 사이로 입력해 주세요."),
        ]
        for (message, expected) in cases {
            assertPair(
                message.text(preference: .korean),
                message.text(preference: .english),
                expectedKorean: expected
            )
        }
    }

    func testDataLoadFailureIsRecognisedInEitherLanguage() {
        for preference in [AppLanguagePreference.korean, .english] {
            let message = AppModelMessage.dataLoadFailed("x").text(preference: preference)
            XCTAssertTrue(AppModelMessage.isDataLoadFailure(message))
        }
        XCTAssertFalse(AppModelMessage.isDataLoadFailure(nil))
        XCTAssertFalse(AppModelMessage.isDataLoadFailure("other error"))
        XCTAssertFalse(AppModelMessage.isDataLoadFailure(
            AppModelMessage.sensorSaveFailed("x").text(preference: .english)
        ))
    }

    func testCoreErrorMessagesKeepKoreanAndHaveEnglish() {
        assertPair(
            PlanRepositoryAvailabilityError.unavailable.message(preference: .korean),
            PlanRepositoryAvailabilityError.unavailable.message(preference: .english),
            expectedKorean: "기기 저장소를 열 수 없어 변경 내용을 저장하지 않습니다."
        )
        assertPair(
            BiometricDataProtectionError.authenticationCancelled.message(preference: .korean),
            BiometricDataProtectionError.authenticationCancelled.message(preference: .english),
            expectedKorean: "생체 인증이 취소되었습니다."
        )
        assertPair(
            VoiceMemoRecordingError.inputUnavailable.message(preference: .korean),
            VoiceMemoRecordingError.inputUnavailable.message(preference: .english),
            expectedKorean: "마이크 입력 장치를 사용할 수 없습니다."
        )
        assertPair(
            VoiceMemoPlaybackError.fileMissing.message(preference: .korean),
            VoiceMemoPlaybackError.fileMissing.message(preference: .english),
            expectedKorean: "음성 메모 파일을 찾지 못했습니다."
        )
        assertPair(
            WeatherContextServiceError.temporarilyUnavailable.message(preference: .korean),
            WeatherContextServiceError.temporarilyUnavailable.message(preference: .english),
            expectedKorean: "날씨 서비스에 잠시 연결할 수 없습니다. 잠시 후 다시 시도해 주세요."
        )
        assertPair(
            HealthKitImportCoordinatorError.invalidAnchorCursor.message(preference: .korean),
            HealthKitImportCoordinatorError.invalidAnchorCursor.message(preference: .english),
            expectedKorean: "HealthKit 변경 동기화 지점을 읽지 못했습니다."
        )
        assertPair(
            TaptionPlanDiagnosticsICloudError.unavailable.message(preference: .korean),
            TaptionPlanDiagnosticsICloudError.unavailable.message(preference: .english),
            expectedKorean: "iCloud Drive를 사용할 수 없습니다. iCloud Drive가 켜져 있는지 확인해 주세요."
        )
        assertPair(
            ScreenTimeUsageError.requiresCurrentSystem.message(preference: .korean),
            ScreenTimeUsageError.requiresCurrentSystem.message(preference: .english),
            expectedKorean: "앱 사용시간 기록에는 iOS 26.4 이상이 필요합니다."
        )
    }

    func testStatusLabelsKeepKoreanAndHaveEnglish() {
        let cloud: [(CloudUnavailableReason, String)] = [
            (.unsupportedBuild, "이 빌드 미지원"),
            (.signedOut, "iCloud 로그인 필요"),
            (.restricted, "기기에서 제한됨"),
            (.temporarilyUnavailable, "잠시 후 다시"),
            (.accountCheckFailed, "계정 확인 실패"),
            (.schemaMissing, "서버 설정 필요"),
        ]
        for (reason, expected) in cloud {
            assertPair(
                reason.statusLabel(preference: .korean),
                reason.statusLabel(preference: .english),
                expectedKorean: expected
            )
            XCTAssertFalse(containsHangul(reason.guidance(preference: .english)))
            XCTAssertFalse(reason.guidance(preference: .english).isEmpty)
        }

        assertPair(
            ScreenTimeAuthorizationState.denied.displayName(preference: .korean),
            ScreenTimeAuthorizationState.denied.displayName(preference: .english),
            expectedKorean: "권한 거부됨"
        )
        let screenTimeGuidance = ScreenTimeAuthorizationState.denied
        assertPair(
            screenTimeGuidance.guidance(preference: .korean) ?? "",
            screenTimeGuidance.guidance(preference: .english) ?? "",
            expectedKorean: "설정 > 스크린 타임 > 앱 및 웹사이트 활동에서 BOKKI Plan을 허용해 주세요."
        )
        assertPair(
            AppleWatchConnectionState.noRecentData.settingsLabel(preference: .korean),
            AppleWatchConnectionState.noRecentData.settingsLabel(preference: .english),
            expectedKorean: "연결됨 · 최근 데이터 없음"
        )
        let koreanRow = AppleWatchOnboarding.companionRow(for: .appNotInstalled, preference: .korean)
        let englishRow = AppleWatchOnboarding.companionRow(for: .appNotInstalled, preference: .english)
        assertPair(koreanRow.value, englishRow.value, expectedKorean: "설치 필요")
        XCTAssertFalse(containsHangul(englishRow.subtitle))
        XCTAssertFalse(containsHangul(englishRow.detail ?? ""))
        for limitation in AppleWatchOnboarding.watchlessLimitations(preference: .english) {
            XCTAssertFalse(containsHangul(limitation))
        }
        XCTAssertFalse(containsHangul(AppleWatchOnboarding.iPhoneOnlyCoverage(preference: .english)))
    }

    func testEnglishDurationAndFloorLabelsHaveNoHangul() {
        XCTAssertEqual(ScreenTimeUsageRecordEngine.localizedDurationText(14 * 60, preference: .korean), "14분")
        XCTAssertEqual(ScreenTimeUsageRecordEngine.localizedDurationText(14 * 60, preference: .english), "14 min")
        XCTAssertEqual(ScreenTimeUsageRecordEngine.localizedDurationText(7_200 + 14 * 60, preference: .english), "2 hr 14 min")
        XCTAssertNil(ScreenTimeUsageRecordEngine.localizedDurationText(30, preference: .english))
        XCTAssertEqual(FloorLabel.english(-2), "B2Floor")
        XCTAssertEqual(FloorLabel.english(7), "7Floor")
    }
}

final class PlanTextSuggestionFormatTests: XCTestCase {
    func testCleanedTrimsDedupesAndLimitsTitles() {
        let result = PlanTextSuggestionFormat.cleaned(
            titles: ["  \"아침 러닝\" ", "아침 러닝", "", "• 저녁 독서\n모임", "한강 산책", "네 번째"],
            memo: "준비물:\n운동화"
        )
        XCTAssertEqual(result.titles, ["아침 러닝", "저녁 독서 모임", "한강 산책"])
        XCTAssertEqual(result.memo, "준비물: 운동화")
    }

    func testCleanedClipsLongValues() {
        let long = String(repeating: "가", count: 40)
        let result = PlanTextSuggestionFormat.cleaned(titles: [long], memo: long + long + long)
        XCTAssertEqual(result.titles.first?.count, PlanTextSuggestionFormat.maxTitleLength)
        XCTAssertEqual(result.memo.count, PlanTextSuggestionFormat.maxMemoLength)
    }

    func testEmptyModelOutputBecomesEmptySuggestion() {
        XCTAssertEqual(
            PlanTextSuggestionFormat.cleaned(titles: [" ", "\n"], memo: "  "),
            .empty
        )
    }

    func testPromptIncludesContextAndRecentTitles() {
        let context = PlanTextContext(
            categoryName: "운동",
            middleCategoryName: "러닝",
            startAt: Date(timeIntervalSince1970: 0),
            durationMinutes: 45,
            recentTitles: ["a", "b", "c", "d", "e", "f"]
        )
        let prompt = PlanTextSuggestionFormat.prompt(for: context, preference: .korean)
        XCTAssertTrue(prompt.contains("대분류: 운동"))
        XCTAssertTrue(prompt.contains("중분류: 러닝"))
        XCTAssertTrue(prompt.contains("45분"))
        XCTAssertTrue(prompt.contains("최근 제목: a, b, c, d, e"))
        XCTAssertFalse(prompt.contains("e, f"))
        XCTAssertFalse(prompt.contains("세부:"))
    }
}

final class MapHomeSidebarAndPlaybackPolicyTests: XCTestCase {
    func testDoubleTapIsDetectedForTwoShortStillTouches() {
        var detector = MapHomeSidebarDoubleTapDetector()
        XCTAssertFalse(detector.registerEnd(
            startUptime: 10.00, endUptime: 10.08,
            translation: CGSize(width: 1, height: 2), location: CGPoint(x: 20, y: 300)
        ))
        XCTAssertTrue(detector.registerEnd(
            startUptime: 10.20, endUptime: 10.27,
            translation: .zero, location: CGPoint(x: 22, y: 304)
        ))
    }

    func testDoubleTapIgnoresDragsSlowTouchesAndFarTaps() {
        var detector = MapHomeSidebarDoubleTapDetector()
        _ = detector.registerEnd(startUptime: 0, endUptime: 0.05, translation: .zero, location: .zero)
        XCTAssertFalse(detector.registerEnd(
            startUptime: 0.2, endUptime: 0.3,
            translation: CGSize(width: 0, height: 40), location: .zero
        ), "움직인 터치는 더블탭이 아니다")
        _ = detector.registerEnd(startUptime: 1, endUptime: 1.05, translation: .zero, location: .zero)
        XCTAssertFalse(detector.registerEnd(
            startUptime: 1.2, endUptime: 2.0, translation: .zero, location: .zero
        ), "오래 누른 터치는 더블탭이 아니다")
        _ = detector.registerEnd(startUptime: 3, endUptime: 3.05, translation: .zero, location: .zero)
        XCTAssertFalse(detector.registerEnd(
            startUptime: 3.1, endUptime: 3.15, translation: .zero, location: CGPoint(x: 0, y: 200)
        ), "멀리 떨어진 탭은 더블탭이 아니다")
        _ = detector.registerEnd(startUptime: 5, endUptime: 5.05, translation: .zero, location: .zero)
        XCTAssertFalse(detector.registerEnd(
            startUptime: 6, endUptime: 6.05, translation: .zero, location: .zero
        ), "간격이 길면 더블탭이 아니다")
    }

    func testPlaybackZoomGetsFartherAsSpeedIncreasesForVehiclesOnly() throws {
        let walking = try XCTUnwrap(MapHomePlaybackZoomPolicy.targetDistance(speedMetersPerSecond: 1.4))
        let bus = try XCTUnwrap(MapHomePlaybackZoomPolicy.targetDistance(speedMetersPerSecond: 12))
        let train = try XCTUnwrap(MapHomePlaybackZoomPolicy.targetDistance(speedMetersPerSecond: 80))
        let standing = try XCTUnwrap(MapHomePlaybackZoomPolicy.targetDistance(speedMetersPerSecond: 0))
        XCTAssertEqual(standing, MapHomePlaybackZoomPolicy.baselineDistance, accuracy: 0.001)
        XCTAssertEqual(walking, MapHomePlaybackZoomPolicy.baselineDistance, accuracy: 0.001, "걷기는 85 고정")
        XCTAssertLessThan(walking, bus)
        XCTAssertLessThan(bus, train)
        XCTAssertEqual(
            train, MapHomeCameraZoomMath.distance(forScale: MapHomePlaybackZoomPolicy.fastestScale), accuracy: 0.001
        )
        XCTAssertNil(MapHomePlaybackZoomPolicy.targetDistance(speedMetersPerSecond: nil))
        XCTAssertNil(MapHomePlaybackZoomPolicy.targetDistance(speedMetersPerSecond: .nan))
        let eased = MapHomePlaybackZoomPolicy.eased(current: 1_000, target: 4_000)
        XCTAssertGreaterThan(eased, 1_000)
        XCTAssertLessThan(eased, 4_000)
    }

    func testPawprintSpeedColorRatioStopsAtOneHundredFiftyKilometersPerHour() throws {
        XCTAssertEqual(try XCTUnwrap(MapHomePawprintSpeedColor.ratio(forMetersPerSecond: 0)), 0, accuracy: 0.0001)
        XCTAssertEqual(
            try XCTUnwrap(MapHomePawprintSpeedColor.ratio(forMetersPerSecond: 150 / 3.6)), 1, accuracy: 0.0001
        )
        XCTAssertEqual(try XCTUnwrap(MapHomePawprintSpeedColor.ratio(forMetersPerSecond: 300 / 3.6)), 1)
        XCTAssertEqual(
            try XCTUnwrap(MapHomePawprintSpeedColor.ratio(forMetersPerSecond: 75 / 3.6)), 0.5, accuracy: 0.0001
        )
        XCTAssertNil(MapHomePawprintSpeedColor.ratio(forMetersPerSecond: nil))
        XCTAssertNil(MapHomePawprintSpeedColor.ratio(forMetersPerSecond: -1))
    }

    func testPawprintSpeedFromTwoTimedCoordinates() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let speed = try XCTUnwrap(MapHomePawprintSpeedColor.speed(
            from: CLLocationCoordinate2D(latitude: 37.0, longitude: 127.0), at: start,
            to: CLLocationCoordinate2D(latitude: 37.0, longitude: 127.01), at: start.addingTimeInterval(100)
        ))
        XCTAssertEqual(speed, 8.9, accuracy: 0.5)
        XCTAssertNil(MapHomePawprintSpeedColor.speed(
            from: CLLocationCoordinate2D(latitude: 37, longitude: 127), at: start,
            to: CLLocationCoordinate2D(latitude: 37, longitude: 127), at: nil
        ))
    }

    func testRouteJumpDiagnosticsReportsLargestJumpWithoutCoordinates() {
        func reading(_ seconds: TimeInterval, _ lat: Double, _ lon: Double) -> SensorReading {
            SensorReading(
                timestamp: Date(timeIntervalSince1970: 1_792_300_000 + seconds),
                point: GeoPoint(latitude: lat, longitude: lon, altitude: 0, horizontalAccuracy: 30, verticalAccuracy: 5),
                sourceDevice: .iPhone
            )
        }
        let fields = MapHomeRouteJumpDiagnostics.fields(for: [
            reading(0, 37.5, 127.0),
            reading(60, 37.5005, 127.0),
            reading(120, 35.1, 129.0),
            reading(180, 37.5, 127.0),
        ])
        XCTAssertEqual(fields["largest_jump_gap_s"], "60")
        XCTAssertEqual(fields["largest_jump_device"], "iPhone")
        XCTAssertEqual(fields["largest_jump_accuracy_m"], "30")
        XCTAssertGreaterThan(Int(fields["largest_jump_m"] ?? "0") ?? 0, 300_000)
        XCTAssertFalse(fields.values.contains { $0.contains("37.5") || $0.contains("129.0") })
        XCTAssertTrue(MapHomeRouteJumpDiagnostics.fields(for: []).isEmpty)
    }
}

final class MapHomeExpectedRouteDiagnosticsTests: XCTestCase {
    func testLongestRouteSummaryHasNoCoordinates() {
        func candidate(_ kind: String, _ mode: String, _ lat: Double, _ lon: Double) -> MapHomeExpectedRouteDiagnostics.Candidate {
            .init(
                kind: kind, mode: mode,
                start: Date(timeIntervalSince1970: 1_792_300_000),
                end: Date(timeIntervalSince1970: 1_792_300_000 + 3_600),
                first: CLLocationCoordinate2D(latitude: 37.5, longitude: 127.0),
                last: CLLocationCoordinate2D(latitude: lat, longitude: lon)
            )
        }
        let fields = MapHomeExpectedRouteDiagnostics.fields(for: [
            candidate("expected", "walking", 37.501, 127.0),
            candidate("forecast_gap", "leg", 35.1, 129.0),
            candidate("generated", "subway", 37.6, 127.1),
        ])
        XCTAssertEqual(fields["longest_route_kind"], "forecast_gap")
        XCTAssertEqual(fields["longest_route_mode"], "leg")
        XCTAssertEqual(fields["longest_route_minutes"], "60")
        XCTAssertGreaterThan(Int(fields["longest_route_km"] ?? "0") ?? 0, 300)
        XCTAssertFalse(fields.values.contains { $0.contains("35.1") || $0.contains("129") })
        XCTAssertTrue(MapHomeExpectedRouteDiagnostics.fields(for: []).isEmpty)
    }
}

final class SubwayCatalogCoordinateTests: XCTestCase {
    private func station(_ line: String, _ name: String) throws -> SubwayStationCatalog.Station {
        try XCTUnwrap(SubwayStationCatalog.stations.first {
            $0.lineName == line && $0.stationName == name
        })
    }

    private func kilometers(_ lhs: SubwayStationCatalog.Station, _ rhs: SubwayStationCatalog.Station) throws -> Double {
        let a = CLLocation(latitude: try XCTUnwrap(lhs.latitude), longitude: try XCTUnwrap(lhs.longitude))
        let b = CLLocation(latitude: try XCTUnwrap(rhs.latitude), longitude: try XCTUnwrap(rhs.longitude))
        return a.distance(from: b) / 1_000
    }

    func testSeoulLineFiveSongjeongIsNextToGimpoAirportNotBusan() throws {
        let songjeong = try station("5호선", "송정")
        let airport = try station("5호선", "김포공항")
        let magok = try station("5호선", "마곡")
        XCTAssertLessThan(try kilometers(songjeong, airport), 5)
        XCTAssertLessThan(try kilometers(songjeong, magok), 5)
    }

    func testSeoulStationsAreNotMappedToSameNamedStationsElsewhere() throws {
        XCTAssertLessThan(
            try kilometers(try station("5호선", "양평"), try station("5호선", "영등포시장")),
            5
        )
        XCTAssertLessThan(
            try kilometers(try station("경의중앙", "용산"), try station("경의중앙", "효창공원앞")),
            8
        )
    }
}

final class ExpectedRouteImpossibleJumpTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul") ?? .current
        return calendar
    }()

    private func date(_ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 19))!
            .addingTimeInterval(TimeInterval(minute * 60))
    }

    private func reading(_ minute: Int, _ latitude: Double, _ longitude: Double) -> SensorReading {
        SensorReading(
            timestamp: date(minute),
            point: GeoPoint(
                latitude: latitude, longitude: longitude, altitude: 0,
                horizontalAccuracy: 20, verticalAccuracy: 10
            ),
            locationFixQuality: .precise,
            gpsAvailable: true
        )
    }

    private func requestCount(_ readings: [SensorReading]) -> Int {
        let travel = TravelSegment(
            mode: .subway,
            span: TimeSpan(start: date(0), end: date(60)),
            distanceMeters: 5_000,
            confidence: .high,
            evidence: [],
            isConfirmed: false,
            isClassificationLocked: true
        )
        return ExpectedRouteRequestEngine.requests(
            travel: [travel], places: [], readings: readings,
            in: TimeSpan(start: date(0), end: date(1_440)), through: date(1_440)
        ).count
    }

    func testIsolatedFarFixDoesNotCreateExpectedRoute() {
        // 서울 → (8분 뒤) 부산 한 점 → (16분 뒤) 서울. 부산 점은 튄 위치다.
        let readings = [
            reading(0, 37.5, 126.9),
            reading(8, 35.1875, 129.2024),
            reading(16, 37.50005, 126.9),
        ]
        XCTAssertEqual(requestCount(readings), 0)
    }

    func testFarFixWithoutReturnDoesNotCreateImpossibleExpectedRoute() {
        let readings = [
            reading(0, 37.5, 126.9),
            reading(8, 35.1875, 129.2024),
        ]
        XCTAssertEqual(requestCount(readings), 0)
    }
}

final class StationaryLocationGateTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_792_300_000)

    private func fillStill(_ tracker: inout DeviceStillnessTracker, seconds: Int, step: Int = 2) {
        for offset in stride(from: 0, through: seconds, by: step) {
            tracker.append(
                userAccelerationMagnitudeG: 0.003, rotationRateMagnitude: 0.002,
                at: start.addingTimeInterval(TimeInterval(offset))
            )
        }
    }

    func testStillOnlyAfterTheFullWindowOfTinyMotion() {
        var tracker = DeviceStillnessTracker()
        fillStill(&tracker, seconds: 30)
        XCTAssertFalse(tracker.isTrulyStill(at: start.addingTimeInterval(31)))
        fillStill(&tracker, seconds: 70)
        XCTAssertTrue(tracker.isTrulyStill(at: start.addingTimeInterval(71)))
    }

    func testAnyMotionOrStaleSamplesBreakStillness() {
        var tracker = DeviceStillnessTracker()
        fillStill(&tracker, seconds: 90)
        XCTAssertTrue(tracker.isTrulyStill(at: start.addingTimeInterval(91)))
        XCTAssertFalse(tracker.isTrulyStill(at: start.addingTimeInterval(120)), "샘플이 오래되면 정지로 보지 않는다")
        tracker.append(userAccelerationMagnitudeG: 0.05, rotationRateMagnitude: 0.002, at: start.addingTimeInterval(92))
        XCTAssertFalse(tracker.isTrulyStill(at: start.addingTimeInterval(93)))
        tracker.append(userAccelerationMagnitudeG: 0.003, rotationRateMagnitude: 0.2, at: start.addingTimeInterval(94))
        XCTAssertFalse(tracker.isTrulyStill(at: start.addingTimeInterval(95)))
    }

    func testLongSampleGapRestartsTheStillWindow() {
        var tracker = DeviceStillnessTracker()
        fillStill(&tracker, seconds: 70)
        tracker.append(userAccelerationMagnitudeG: 0.003, rotationRateMagnitude: 0.002, at: start.addingTimeInterval(200))
        XCTAssertFalse(tracker.isTrulyStill(at: start.addingTimeInterval(201)))
    }

    func testGateIgnoresFixesOnlyWhenEverythingAgreesAndHeartbeatAllowsOne() {
        let now = start.addingTimeInterval(3_600)
        func ignore(still: Bool = true, stationary: Bool = true, previous: Bool = true,
                    manual: Bool = false, last: Date? = nil) -> Bool {
            StationaryLocationGate.shouldIgnoreFixes(
                isTrulyStill: still, motionIsStationary: stationary, hasPreviousLocation: previous,
                hasManualTrackingSession: manual, lastAcceptedAt: last ?? now.addingTimeInterval(-60), now: now
            )
        }
        XCTAssertTrue(ignore())
        XCTAssertFalse(ignore(still: false))
        XCTAssertFalse(ignore(stationary: false))
        XCTAssertFalse(ignore(previous: false))
        XCTAssertFalse(ignore(manual: true))
        XCTAssertFalse(ignore(last: now.addingTimeInterval(-StationaryLocationGate.heartbeatInterval - 1)),
                       "오래 지나면 한 번은 반영한다")
        XCTAssertFalse(StationaryLocationGate.shouldIgnoreFixes(
            isTrulyStill: true, motionIsStationary: true, hasPreviousLocation: true,
            hasManualTrackingSession: false, lastAcceptedAt: nil, now: now
        ))
    }
}

/// 표시 > 사이드바의 시간 표시·시간 간격(UIX1101A02).
final class MapHomeSidebarDisplaySettingsTests: XCTestCase {
    func testTwelveHourLabelsMarkMorningAndAfternoon() {
        let format = MapHomeSidebarTimeFormat.twelveHour
        XCTAssertEqual(format.hourLabel(0, language: .korean), "오전")
        XCTAssertEqual(format.hourLabel(12, language: .korean), "오후")
        XCTAssertEqual(format.hourLabel(15, language: .korean), "3")
        XCTAssertEqual(format.timeLabel(15 * 60 + 5, language: .korean), "오후 3:05")
        XCTAssertEqual(format.timeLabel(5, language: .korean), "오전 12:05")
        XCTAssertEqual(format.timeLabel(15 * 60 + 5, includesPeriod: false), "3:05")
        XCTAssertEqual(MapHomeSidebarTimeFormat.twentyFourHour.timeLabel(15 * 60 + 5), "15:05")
        XCTAssertEqual(MapHomeSidebarTimeFormat.twentyFourHour.hourLabel(7), "07")
    }

    func testRulerIntervalNeverGetsDenserThanTheChosenMinimum() {
        let fitted = MapHomeTimeSidebarMath.minuteRulerStep(durationMinutes: 60, trackHeight: 600)
        XCTAssertEqual(MapHomeTimeSidebarMath.minuteRulerStep(durationMinutes: 60, trackHeight: 600, minimumStep: 0), fitted)
        XCTAssertEqual(MapHomeTimeSidebarMath.minuteRulerStep(durationMinutes: 60, trackHeight: 600, minimumStep: 30), max(fitted, 30))
        // 1시간이면 분 글자는 없고 정시만 남는다.
        let labels = MapHomeTimeSidebarMath.visibleRulerLabels(
            window: 600...720, durationMinutes: 120, trackHeight: 600, minimumStep: 60
        )
        XCTAssertTrue(labels.minutes.isEmpty)
        // 화면이 좁아 자동 간격이 더 넓으면 자동 간격을 쓴다(글자가 겹치지 않게).
        XCTAssertEqual(MapHomeTimeSidebarMath.minuteRulerStep(durationMinutes: 720, trackHeight: 300, minimumStep: 5),
                       MapHomeTimeSidebarMath.minuteRulerStep(durationMinutes: 720, trackHeight: 300))
    }
}

/// 지도 스타일이 테마를 정한다(THM1101A01).
final class TaptionUIThemeMapTests: XCTestCase {
    func testEachMapStyleHasOneTheme() {
        XCTAssertEqual(TaptionUITheme.forMap(.mapLibreRPG), .classic)
        XCTAssertEqual(TaptionUITheme.forMap(.mapLibreNight), .navy)
        XCTAssertEqual(TaptionUITheme.forMap(.mapLibreCasual), .purple)
        XCTAssertEqual(TaptionUITheme.forMap(.mapLibreContrast), .brown)
        XCTAssertEqual(TaptionUITheme.forMap(.mapLibreInk), .ink)
        XCTAssertEqual(TaptionUITheme.forMap(.standard), .classic)
        XCTAssertEqual(TaptionUITheme.forMap(.hybrid), .classic)
    }

    func testWalkThemeIsLightPink() throws {
        XCTAssertEqual(TaptionUITheme.purple.colorScheme, .light)
        XCTAssertFalse(TaptionUITheme.purple.isDark)
        XCTAssertTrue(TaptionUITheme.navy.isDark)
        XCTAssertTrue(TaptionUITheme.brown.isDark)
        XCTAssertFalse(TaptionUITheme.classic.isDark)
    }

    func testPalettesKeepReadableContrast() throws {
        for theme in [TaptionUITheme.navy, .purple, .brown] {
            let palette = try XCTUnwrap(theme.palette)
            XCTAssertGreaterThanOrEqual(contrast(.white, palette.accent), 4.5, "\(theme) 강조 위 흰 글자")
            XCTAssertGreaterThanOrEqual(contrast(palette.accent, palette.surface), 3, "\(theme) 면 위 강조")
            XCTAssertGreaterThanOrEqual(contrast(palette.secondary, palette.surface), 4.5, "\(theme) 면 위 보조 글자")
            XCTAssertGreaterThanOrEqual(contrast(palette.ink, palette.surface), 7, "\(theme) 면 위 글자")
        }
    }

    private func contrast(_ first: Color, _ second: Color) -> Double {
        let values = [luminance(first), luminance(second)].sorted(by: >)
        return (values[0] + 0.05) / (values[1] + 0.05)
    }

    private func luminance(_ color: Color) -> Double {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let channel: (CGFloat) -> Double = { value in
            let value = Double(value)
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }
}

/// 사이드바 옆 일정·메모 말풍선(SBN1102A01).
final class AllowanceConversionTests: XCTestCase {
    func testOnlySelectedPayKindRuns() throws {
        let name = "AllowanceSelection-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(30_000_000.0, forKey: MapHomeSalaryPolicy.annualKey)
        defaults.set(500_000.0, forKey: MapHomeAllowancePolicy.amountKey)
        // 옛 사용자: 급여가 있으면 급여를 쓴다.
        XCTAssertFalse(MapHomeAllowancePolicy.isSelected(defaults))
        XCTAssertFalse(MapHomeAllowancePolicy.load(defaults).isConfigured)
        XCTAssertTrue(MapHomeSalaryPolicy.loadSettings(defaults).isConfigured)
        defaults.set(true, forKey: MapHomeAllowancePolicy.isSelectedKey)
        XCTAssertTrue(MapHomeAllowancePolicy.load(defaults).isConfigured)
        XCTAssertFalse(MapHomeSalaryPolicy.loadSettings(defaults).isConfigured)
        // 옛 사용자: 용돈만 있으면 용돈을 쓴다.
        defaults.removeObject(forKey: MapHomeAllowancePolicy.isSelectedKey)
        defaults.removeObject(forKey: MapHomeSalaryPolicy.annualKey)
        XCTAssertTrue(MapHomeAllowancePolicy.isSelected(defaults))
    }

    func testConversionsRoundTripForEachPeriod() {
        for period in MapHomeAllowancePolicy.Period.allCases {
            let amount = MapHomeAllowancePolicy.amount(fromAnnual: 36_500_000, period: period)
            let settings = MapHomeAllowancePolicy.Settings(amount: amount, period: period)
            XCTAssertEqual(MapHomeAllowancePolicy.annualAmount(settings), 36_500_000, accuracy: 0.01)
        }
        XCTAssertEqual(MapHomeAllowancePolicy.amount(fromAnnual: 12_000_000, period: .month), 1_000_000)
    }
}

final class MapHomeRangeSampleCacheTests: XCTestCase {
    func testRoundTripAndEmptyDayAndCacheableDays() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { MapHomeRangeSampleCache.removeAll(directory: directory) }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let day = try XCTUnwrap(calendar.date(byAdding: .day, value: -5, to: today))
        let samples = [MapHomeRangeTripPlan.Sample(time: 1, latitude: 37.5, longitude: 126.8)]
        MapHomeRangeSampleCache.write(samples, dayStart: day, calendar: calendar, directory: directory)
        XCTAssertEqual(MapHomeRangeSampleCache.read(dayStart: day, calendar: calendar, directory: directory), samples)
        let empty = try XCTUnwrap(calendar.date(byAdding: .day, value: -6, to: today))
        MapHomeRangeSampleCache.write([], dayStart: empty, calendar: calendar, directory: directory)
        XCTAssertNil(MapHomeRangeSampleCache.read(dayStart: empty, calendar: calendar, directory: directory))
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        XCTAssertFalse(MapHomeRangeSampleCache.isCacheable(dayStart: yesterday, now: .now, calendar: calendar))
        XCTAssertTrue(MapHomeRangeSampleCache.isCacheable(dayStart: day, now: .now, calendar: calendar))
    }
}

final class DisplayRouteApproximateFilterTests: XCTestCase {
    private func reading(_ seconds: TimeInterval, quality: LocationFixQuality) -> SensorReading {
        SensorReading(
            timestamp: Date(timeIntervalSinceReferenceDate: 815_549_000 + seconds),
            point: GeoPoint(latitude: 37.56, longitude: 126.83, altitude: 0, horizontalAccuracy: quality == .approximate ? 202 : 8, verticalAccuracy: 8),
            locationFixQuality: quality,
            gpsAvailable: quality == .precise
        )
    }

    /// 대표 원본 14:37:13: 정밀 위치 사이의 오차 202m 한 점이 왕복선을 만들었다.
    func testBracketedApproximateIsDroppedButLoneOneStays() {
        let bracketed = [reading(0, quality: .precise), reading(22, quality: .approximate), reading(23, quality: .precise)]
        XCTAssertEqual(RouteTimelineDataEngine.droppingBracketedApproximates(bracketed).count, 2)
        let lone = [reading(0, quality: .precise), reading(4_000, quality: .approximate), reading(8_000, quality: .precise)]
        XCTAssertEqual(RouteTimelineDataEngine.droppingBracketedApproximates(lone).count, 3)
    }
}

final class CalendarCaloriesTests: XCTestCase {
    func testHealthValueWinsAndStepsAreEstimated() throws {
        let watchDay = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let phoneDay = Date(timeIntervalSinceReferenceDate: 800_086_400)
        let result = MapHomeCalendarTimeTotalsPolicy.dailyCalories(
            health: [watchDay: 320],
            steps: [watchDay: 9_000, phoneDay: 10_000],
            strideMeters: 0.75,
            weightKilograms: 70
        )
        XCTAssertEqual(result[watchDay]?.kilocalories, 320)
        XCTAssertEqual(result[watchDay]?.isEstimated, false)
        // 10,000걸음 × 0.75m = 7.5km, 0.5 × 70kg × 7.5km = 262.5kcal
        XCTAssertEqual(try XCTUnwrap(result[phoneDay]?.kilocalories), 262.5, accuracy: 0.001)
        XCTAssertEqual(result[phoneDay]?.isEstimated, true)
        let noWeight = MapHomeCalendarTimeTotalsPolicy.dailyCalories(
            health: [:], steps: [phoneDay: 10_000], strideMeters: 0.75, weightKilograms: nil
        )
        XCTAssertEqual(try XCTUnwrap(noWeight[phoneDay]?.kilocalories), 243.75, accuracy: 0.001)
    }
}

final class CalendarVisitNameTests: XCTestCase {
    func testRegisteredNameReplacesStoredDisplayName() throws {
        let start = Date(timeIntervalSinceReferenceDate: 815_500_000)
        let stay = PlaceStay(
            placeKey: "frequent-abc", displayName: "사용자 지점",
            span: TimeSpan(start: start, end: start.addingTimeInterval(2_460)), confidence: .high
        )
        let visits = MapHomeCalendarPlaceVisitPolicy.visits(
            stays: [stay], day: start.addingTimeInterval(-60), dayEnd: start.addingTimeInterval(86_000),
            registeredNames: ["frequent-abc": "식당"],
            registeredSymbols: ["frequent-abc": "storefront.fill"]
        )
        XCTAssertEqual(try XCTUnwrap(visits.first).name, "식당")
        XCTAssertEqual(visits.first?.systemImage, "storefront.fill")
    }
}

final class TrackingSessionRecordPolicyTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 815_542_200)

    func testAutomaticSessionLeavesNoRecord() {
        let session = TrackingSession(kind: .walking, startedAt: start, wasAutomaticallyDetected: true)
        XCTAssertNil(TrackingSessionRecordPolicy.actual(
            for: session, endedAt: start.addingTimeInterval(8_703), planID: nil, planTitle: nil, planCategoryID: nil
        ))
    }

    func testUserStartedSessionKeepsRecordAndIsNotArtifact() throws {
        let session = TrackingSession(kind: .running, startedAt: start)
        let actual = try XCTUnwrap(TrackingSessionRecordPolicy.actual(
            for: session, endedAt: start.addingTimeInterval(600), planID: nil, planTitle: nil, planCategoryID: nil
        ))
        XCTAssertEqual(actual.title, "달리기")
        XCTAssertFalse(TrackingSessionRecordPolicy.isAutomaticSessionArtifact(actual))
    }

    func testRestCandidateNeedsFiveMinutesOfStillScreenOn() {
        let dayStart = Calendar.current.startOfDay(for: start)
        func at(_ minute: Int) -> Date { dayStart.addingTimeInterval(Double(minute) * 60) }
        func reading(_ minute: Int, screen: Bool = true, motion: MotionKind = .stationary) -> SensorReading {
            var value = SensorReading(timestamp: at(minute))
            value.screenIsOn = screen
            value.motion = motion
            return value
        }
        let readings = (750...756).map { reading($0) }
            + [reading(800), reading(802)]
            + (850...860).map { reading($0, motion: .walking) }
            + (900...910).map { reading($0, screen: false) }
        XCTAssertEqual(NLESubActivityEngine.restCandidateRuns(readings, dayStart: dayStart), [750..<756])
        let work = MapHomeTimeRailSegment(startMinute: 700, endMinute: 900, categoryID: "work", title: "업무")
        let details = NLESubActivityEngine.details(NLESubActivityInput(segments: [work], readings: readings, dayStart: dayStart, asOf: at(1_000)))
        XCTAssertEqual(details.map(\.title), ["휴식 후보"])
        let home = MapHomeTimeRailSegment(startMinute: 700, endMinute: 900, categoryID: "activity", title: "일상")
        XCTAssertTrue(NLESubActivityEngine.details(NLESubActivityInput(segments: [home], readings: readings, dayStart: dayStart, asOf: at(1_000))).isEmpty)
    }

    /// 대표 원본(11-05 12:30–14:55)과 같은 모양의 옛 기록은 상세 활동에 나오지 않는다.
    func testStoredArtifactIsHiddenFromDetails() {
        let dayStart = Calendar.current.startOfDay(for: start)
        func at(_ minute: Int) -> Date { dayStart.addingTimeInterval(Double(minute) * 60) }
        let artifact = ActualRecord(
            id: UUID(), planID: nil, title: "걷기", categoryID: "activity",
            startedAt: at(750), endedAt: at(895), source: .location, confidence: .high
        )
        XCTAssertTrue(TrackingSessionRecordPolicy.isAutomaticSessionArtifact(artifact))
        let segment = MapHomeTimeRailSegment(startMinute: 750, endMinute: 999, categoryID: "activity", title: "일상")
        XCTAssertTrue(NLESubActivityEngine.details(NLESubActivityInput(
            segments: [segment], actuals: [artifact], dayStart: dayStart, asOf: at(1_000)
        )).isEmpty)
    }
}

@MainActor
final class MapUserActivityCategoryEditingTests: XCTestCase {
    func testEditRejectsDuplicateNameAndDeleteRemoves() async throws {
        let model = AppModel(repository: InMemoryPlanRepository(snapshot: .empty), cloudSyncService: nil)
        await model.bootstrap()
        let icons = MapUserActivityIconCatalog.available(for: [])
        XCTAssertTrue(model.addMapUserActivityCategory(title: "비행기", systemImage: icons[0], hex: "#29A383"))
        XCTAssertTrue(model.addMapUserActivityCategory(title: "독서", systemImage: icons[1], hex: "#29A383"))
        let plane = try XCTUnwrap(model.settings.mapUserActivityCategories.first { $0.title == "비행기" })

        XCTAssertFalse(model.updateMapUserActivityCategory(
            id: plane.id, title: "독서", systemImage: plane.systemImage, hex: plane.hex, animation: nil
        ))
        XCTAssertTrue(model.updateMapUserActivityCategory(
            id: plane.id, title: "여행", systemImage: icons[2], hex: "#112233", animation: .stretching
        ))
        let edited = try XCTUnwrap(model.settings.mapUserActivityCategories.first { $0.id == plane.id })
        XCTAssertEqual(edited.title, "여행")
        XCTAssertEqual(edited.systemImage, icons[2])
        XCTAssertEqual(edited.animation, .stretching)

        model.deleteMapUserActivityCategory(id: plane.id)
        XCTAssertEqual(model.settings.mapUserActivityCategories.map(\.title), ["독서"])
    }
}

final class MapHomeSidebarNoteTests: XCTestCase {
    func testScheduleBadgesStayLeftOfRailWithoutWeatherChips() {
        let base = MapHomeTimeSidebarMath.scheduleBadgeBaseX(hasWeatherChips: false)
        XCTAssertLessThanOrEqual(
            base + MapHomeTimeSidebarMath.scheduleBadgeRadius,
            MapHomeTimeSidebarMath.handleLaneWidth - MapHomeTimeSidebarMath.scheduleBadgeRailGap
        )
        XCTAssertEqual(MapHomeTimeSidebarMath.scheduleBadgeBaseX(hasWeatherChips: true), 28)
    }

    func testOverlappingBadgesSpreadLeftAroundReviewMarker() {
        let columns = MapHomeTimeSidebarMath.scheduleBadgeColumns(
            badges: [(id: "memo", y: 100), (id: "event", y: 105), (id: "far", y: 300)],
            reviewMarkerYs: [110]
        )
        XCTAssertEqual(columns["memo"], 1)
        XCTAssertEqual(columns["event"], 2)
        XCTAssertEqual(columns["far"], 0)
    }

    func testBubbleSitsLeftOfBadgeWithoutOverlap() {
        let badgeX: CGFloat = 300
        let center = MapHomeSidebarNoteLayout.centerX(badgeX: badgeX)
        XCTAssertLessThanOrEqual(center + MapHomeSidebarNoteLayout.width / 2, badgeX - MapHomeSidebarNoteLayout.badgeRadius)
    }

    // 구글 일정 말풍선에 제목·시간·일정 메모가 그대로 실리는지 고정한다(SBN1102A01).
    func testGoogleEventNoteCarriesTitleTimeAndNotes() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let span = TimeSpan(start: start, end: start.addingTimeInterval(3_600))
        let note = MapHomeSidebarNote.event(id: "google-abc", title: "회의", notes: "3층 회의실", span: span, minute: 540, badgeOffset: -26)
        XCTAssertEqual(note.id, "event-google-abc")
        XCTAssertEqual(note.source, .event)
        XCTAssertEqual(note.title, "회의")
        XCTAssertEqual(note.detail, "3층 회의실")
        XCTAssertTrue(note.time.contains("–"))
        XCTAssertEqual(note.minute, 540)
        XCTAssertEqual(note.badgeOffset, -26)
        XCTAssertNil(note.editorTarget)
    }

    func testEventHasNoEditorButMemoAndStickerDo() {
        let id = UUID()
        func note(_ source: MapHomeSidebarNote.Source) -> MapHomeSidebarNote {
            MapHomeSidebarNote(id: "x", source: source, title: "t", time: "9:00", minute: 540, badgeOffset: 0)
        }
        XCTAssertNil(note(.event).editorTarget)
        XCTAssertNotNil(note(.memo(id)).editorTarget)
        XCTAssertNotNil(note(.sticker(id)).editorTarget)
    }

    func testWalkInsideRegisteredPlaceBecomesPlaceCategoryAndJoins() {
        let zones = MapHomePlaceFirstPolicy.zones(
            stays: [("company", 600, 660), ("company", 900, 1_000)],
            categoryForKey: { $0 == "company" ? "work" : nil },
            vehicleSpans: []
        )
        XCTAssertEqual(zones, [MapHomePlaceFirstPolicy.Zone(startMinute: 600, endMinute: 1_000, categoryID: "work")])
        let segments = [
            MapHomeTimeRailSegment(startMinute: 700, endMinute: 760, categoryID: "work", title: "근무"),
            MapHomeTimeRailSegment(startMinute: 760, endMinute: 770, categoryID: "movement", title: "걷기", behavior: "walking"),
            MapHomeTimeRailSegment(startMinute: 770, endMinute: 830, categoryID: "work", title: "회의", behavior: "meeting"),
        ]
        let result = MapHomePlaceFirstPolicy.merged(segments.map { MapHomePlaceFirstPolicy.assign($0, zones: zones) })
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].categoryID, "work")
        XCTAssertEqual(result[0].startMinute, 700)
        XCTAssertEqual(result[0].endMinute, 830)
        XCTAssertEqual(result[0].walkSpans, [760..<770])
    }

    func testWalkOutsideRegisteredPlaceStaysMovement() {
        let zone = MapHomePlaceFirstPolicy.Zone(startMinute: 600, endMinute: 660, categoryID: "work")
        let outside = MapHomeTimeRailSegment(startMinute: 700, endMinute: 720, categoryID: "movement", title: "걷기", behavior: "walking")
        let car = MapHomeTimeRailSegment(startMinute: 610, endMinute: 620, categoryID: "movement", title: "자동차", behavior: "automotive")
        XCTAssertEqual(MapHomePlaceFirstPolicy.assign(outside, zones: [zone]).categoryID, "movement")
        XCTAssertEqual(MapHomePlaceFirstPolicy.assign(car, zones: [zone]).categoryID, "movement")
    }

    func testVehicleBetweenStaysKeepsZonesApart() {
        let zones = MapHomePlaceFirstPolicy.zones(
            stays: [("company", 600, 660), ("company", 900, 1_000)],
            categoryForKey: { _ in "work" },
            vehicleSpans: [700..<750]
        )
        XCTAssertEqual(zones.count, 2)
    }
}
