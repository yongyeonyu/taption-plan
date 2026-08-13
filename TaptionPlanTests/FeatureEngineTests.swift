import XCTest
import UIKit
import CoreLocation
import SwiftUI // TEMP-CAT-SHEET
@testable import TaptionPlan

final class FeatureEngineTests: XCTestCase {
    private let hour: TimeInterval = 3_600

    func testRecordAnalysisPolicyUsesOnlyCanonicalAutomaticCategories() {
        let phaseTitles = RecordAnalysisCategoryPolicy.options
            .filter(RecordAnalysisCategoryPolicy.isPhaseOption)
            .map(\.title)
        XCTAssertEqual(
            phaseTitles,
            ["활동", "업무", "수업", "취미", "수면", "이동", "운동"]
        )

        let detailTitles = Set(
            RecordAnalysisCategoryPolicy.options
                .filter { !RecordAnalysisCategoryPolicy.isPhaseOption($0) }
                .map(\.title)
        )
        XCTAssertTrue(detailTitles.isSuperset(of: [
            "휴식", "미확인", "업무(집 - 회사)", "수업(집 - 학교·학원)",
            "취미(집 - 취미)", "코어 수면", "깊은 수면", "REM 수면",
            "걷기", "자동차", "지하철", "자가용", "버스", "배", "비행기",
            "자전거", "운동",
        ]))
    }

    func testCanonicalAnalysisDoesNotMutateStoredRecord() {
        let record = ActualRecord(
            planID: nil,
            title: "집에서 휴식",
            categoryID: "rest",
            startedAt: makeDate(2026, 8, 13, 9, 0),
            endedAt: makeDate(2026, 8, 13, 10, 0),
            source: .location,
            behavior: StationaryContextKind.homeRest.rawValue
        )

        XCTAssertEqual(
            RecordAnalysisCategoryPolicy.categoryID(for: record),
            "activity"
        )
        XCTAssertEqual(
            RecordAnalysisCategoryNormalizer.categoryID(
                for: record.categoryID,
                title: record.title,
                behavior: record.behavior
            ),
            "activity"
        )
        XCTAssertEqual(record.categoryID, "rest")
        XCTAssertEqual(record.title, "집에서 휴식")
    }

    func testHouseworkAlwaysBelongsToActivity() {
        let record = ActualRecord(
            planID: nil,
            title: "집안일",
            categoryID: "work",
            startedAt: makeDate(2026, 8, 13, 9, 0),
            endedAt: makeDate(2026, 8, 13, 10, 0),
            source: .location,
            behavior: WatchBehaviorKind.housework.rawValue
        )

        XCTAssertEqual(
            RecordAnalysisCategoryPolicy.categoryID(for: record),
            "activity"
        )
        XCTAssertEqual(
            RecordAnalysisCategoryPolicy.detailTitle(for: record),
            "집안일"
        )
        XCTAssertFalse(
            RecordAnalysisCategoryPolicy.options
                .filter { $0.categoryID == "work" }
                .contains { $0.title == "집안일" }
        )
    }

    func testTimelineHierarchyIsSeparateFromRecordSource() {
        let span = TimeSpan(
            start: makeDate(2026, 8, 8, 9, 0),
            end: makeDate(2026, 8, 8, 10, 0)
        )
        let routine = PlanRecord(
            title: "루틴: 운동",
            span: span,
            categoryID: "activity",
            middleCategoryName: "운동"
        )
        let detailedActivity = ActualRecord(
            planID: nil,
            title: "깊은 수면",
            categoryID: "sleep",
            startedAt: span.start,
            endedAt: span.end,
            source: .healthKit,
            behavior: "deepSleep"
        )

        XCTAssertEqual(routine.semanticLevel, .activity)
        XCTAssertEqual(routine.sourceKind, .routine)
        XCTAssertEqual(detailedActivity.semanticLevel, .activity)
        XCTAssertEqual(detailedActivity.sourceKind, .automatic)
    }

    func testActivityCorrectionChangesDisplayFieldsWithoutTouchingEvidence() {
        let source = ActualRecord(
            planID: nil,
            title: "머무름",
            categoryID: "activity",
            startedAt: makeDate(2026, 8, 10, 0, 0),
            endedAt: makeDate(2026, 8, 10, 1, 0),
            source: .location,
            behavior: StationaryContextKind.unknownStay.rawValue,
            evidence: ["GPS"]
        )
        let corrected = ActivityCorrectionEngine.applying(
            [source.id: ActivityCorrection(
                title: "샤워",
                behavior: WatchBehaviorKind.showering.rawValue,
                categoryID: "activity"
            )],
            to: [source]
        )[0]

        XCTAssertEqual(corrected.id, source.id)
        XCTAssertEqual(corrected.title, "샤워")
        XCTAssertEqual(corrected.behavior, WatchBehaviorKind.showering.rawValue)
        XCTAssertEqual(corrected.evidence, ["GPS"])
        XCTAssertEqual(corrected.source, .location)
        XCTAssertTrue(corrected.manuallyCorrected)
    }

    func testActivityCorrectionCanAdjustDisplaySpanWithoutChangingSource() {
        let source = ActualRecord(
            planID: nil,
            title: "머무름",
            categoryID: "activity",
            startedAt: makeDate(2026, 8, 10, 0, 0),
            endedAt: makeDate(2026, 8, 10, 1, 0),
            source: .location,
            behavior: StationaryContextKind.unknownStay.rawValue,
            evidence: ["GPS"]
        )
        let start = makeDate(2026, 8, 10, 0, 10)
        let end = makeDate(2026, 8, 10, 0, 40)
        let corrected = ActivityCorrectionEngine.applying(
            [source.id: ActivityCorrection(
                title: source.title,
                behavior: source.behavior,
                categoryID: source.categoryID,
                startedAt: start,
                endedAt: end
            )],
            to: [source]
        )[0]

        XCTAssertEqual(corrected.startedAt, start)
        XCTAssertEqual(corrected.endedAt, end)
        XCTAssertEqual(corrected.evidence, source.evidence)
        XCTAssertEqual(corrected.source, source.source)
        XCTAssertTrue(corrected.manuallyCorrected)
    }

    func testActivityCorrectionChoiceKeepsExistingDisplaySpan() {
        let start = makeDate(2026, 8, 10, 0, 10)
        let end = makeDate(2026, 8, 10, 0, 40)
        let updated = ActivityCorrectionEngine.replacingActivity(
            in: ActivityCorrection(
                title: "머무름",
                behavior: StationaryContextKind.unknownStay.rawValue,
                categoryID: "activity",
                startedAt: start,
                endedAt: end
            ),
            with: ActivityCorrectionOption.custom("독서")
        )

        XCTAssertEqual(updated.title, "독서")
        XCTAssertNil(updated.behavior)
        XCTAssertEqual(updated.startedAt, start)
        XCTAssertEqual(updated.endedAt, end)
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

    func testBrushingTeethActivityUsesToothbrushIcon() {
        XCTAssertEqual(
            WatchBehaviorKind.brushingTeeth.systemImage,
            "toothbrush.fill"
        )
        XCTAssertEqual(
            ActivityCorrectionOption.custom("양치").systemImage,
            "toothbrush.fill"
        )
    }

    func testFragmentCorrectionChangesOnlyTheSelectedSplitPiece() throws {
        let start = makeDate(2026, 8, 12, 0, 0)
        let source = ActualRecord(
            planID: nil,
            title: "활동",
            categoryID: "activity",
            startedAt: start,
            endedAt: start.addingTimeInterval(8 * hour),
            source: .location
        )
        let sleep = ActualRecord(
            planID: nil,
            title: "수면",
            categoryID: "sleep",
            startedAt: start.addingTimeInterval(2 * hour),
            endedAt: start.addingTimeInterval(7 * hour),
            source: .healthKit
        )
        let period = TimeSpan(
            start: start,
            end: start.addingTimeInterval(8 * hour)
        )
        let pieces = ReviewCoverageEngine.records(
            actuals: [source, sleep],
            in: [period],
            asOf: period.end
        ).filter { $0.title == source.title }
        let selected = try XCTUnwrap(
            pieces.max { $0.startedAt < $1.startedAt }
        ).span(asOf: period.end)

        XCTAssertTrue(
            ActivityFragmentCorrectionEngine.needsSeparateRecord(
                source: source,
                displayedSpan: selected
            )
        )
        let corrected = ActivityFragmentCorrectionEngine.record(
            source: source,
            displayedSpan: selected,
            correctedSpan: selected,
            option: .custom("출근준비")
        )
        let result = ReviewCoverageEngine.records(
            actuals: [source, sleep, corrected],
            in: [period],
            asOf: period.end
        )

        XCTAssertEqual(source.title, "활동")
        XCTAssertEqual(corrected.source, .manual)
        XCTAssertNotEqual(corrected.id, source.id)
        XCTAssertEqual(
            result.first(where: { $0.startedAt == start })?.title,
            "활동"
        )
        XCTAssertEqual(
            result.first(where: {
                $0.startedAt == start.addingTimeInterval(7 * hour)
            })?.title,
            "출근준비"
        )
    }

    func testFragmentCorrectionReusesWholeFinishedRecord() {
        let source = ActualRecord(
            planID: nil,
            title: "활동",
            categoryID: "activity",
            startedAt: makeDate(2026, 8, 12, 7, 0),
            endedAt: makeDate(2026, 8, 12, 8, 0),
            source: .location
        )

        XCTAssertFalse(
            ActivityFragmentCorrectionEngine.needsSeparateRecord(
                source: source,
                displayedSpan: TimeSpan(
                    start: source.startedAt,
                    end: source.endedAt ?? source.startedAt
                )
            )
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

    /// 굽은 길을 1m 간격으로 찍은 뒤 GPS 흔들림을 얹은 경로.
    private func makeWalkPolyline(pointCount: Int) -> [CLLocationCoordinate2D] {
        (0..<pointCount).map { index in
            let progress = Double(index) / Double(max(1, pointCount - 1))
            let jitter = sin(Double(index) * 1.7) * 0.000004
            return CLLocationCoordinate2D(
                latitude: 37.5 + progress * 0.004 + jitter,
                longitude: 127.0
                    + sin(progress * .pi * 2) * 0.002
                    + cos(Double(index) * 2.3) * 0.000004
            )
        }
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

    func testReviewCoverageMakesPastDayExactlyTwentyFourHours() {
        let day = TimeSpan(
            start: makeDate(2026, 8, 4),
            end: makeDate(2026, 8, 5)
        )
        let activity = ActualRecord(
            planID: nil,
            title: "생활",
            categoryID: "routine",
            startedAt: day.start,
            endedAt: day.start.addingTimeInterval(12 * hour),
            source: .location
        )
        let sleep = ActualRecord(
            planID: nil,
            title: "수면",
            categoryID: "sleep",
            startedAt: day.start.addingTimeInterval(2 * hour),
            endedAt: day.start.addingTimeInterval(8 * hour),
            source: .healthKit
        )
        let movement = ActualRecord(
            planID: nil,
            title: "자동차",
            categoryID: "movement",
            startedAt: day.start.addingTimeInterval(10 * hour),
            endedAt: day.start.addingTimeInterval(14 * hour),
            source: .motion
        )

        let records = ReviewCoverageEngine.records(
            actuals: [activity, sleep, movement],
            in: [day],
            asOf: day.end
        )
        XCTAssertEqual(
            records.reduce(0) { $0 + $1.span(asOf: day.end).duration },
            24 * hour
        )
        XCTAssertEqual(
            records.filter { $0.categoryID == "sleep" }
                .reduce(0) { $0 + $1.span(asOf: day.end).duration },
            6 * hour
        )
        XCTAssertEqual(
            records.filter {
                $0.categoryID == ReviewCoverageEngine.unconfirmedCategoryID
            }.reduce(0) { $0 + $1.span(asOf: day.end).duration },
            10 * hour
        )
        let ordered = records.map { $0.span(asOf: day.end) }
            .sorted { $0.start < $1.start }
        for pair in zip(ordered, ordered.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0.end, pair.1.start)
        }
    }

    func testReviewCoverageFillsCurrentDayOnlyThroughNow() {
        let day = TimeSpan(
            start: makeDate(2026, 8, 6),
            end: makeDate(2026, 8, 7)
        )
        let now = day.start.addingTimeInterval(11 * hour + 15 * 60)
        let records = ReviewCoverageEngine.records(
            actuals: [],
            in: [day],
            asOf: now
        )
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].title, "미확인")
        XCTAssertEqual(records[0].span(asOf: now).duration, 11 * hour + 15 * 60)
        XCTAssertEqual(records[0].endedAt, now)
    }

    func testManualClassificationWinsOverLaterAutomaticEvidence() {
        let day = TimeSpan(
            start: makeDate(2026, 8, 10),
            end: makeDate(2026, 8, 11)
        )
        let automatic = ActualRecord(
            planID: nil,
            title: "걷기",
            categoryID: "movement",
            startedAt: day.start,
            endedAt: day.start.addingTimeInterval(3 * hour),
            source: .motion
        )
        let manual = ActualRecord(
            planID: nil,
            title: "샤워",
            categoryID: "activity",
            startedAt: day.start.addingTimeInterval(hour),
            endedAt: day.start.addingTimeInterval(2 * hour),
            source: .manual,
            manuallyCorrected: true
        )

        let records = ReviewCoverageEngine.records(
            actuals: [automatic, manual],
            in: [day],
            asOf: day.start.addingTimeInterval(3 * hour)
        )

        XCTAssertEqual(
            records.filter { $0.title == "샤워" }
                .reduce(0) { $0 + $1.span(asOf: day.end).duration },
            hour
        )
        XCTAssertEqual(
            records.filter { $0.title == "걷기" }
                .reduce(0) { $0 + $1.span(asOf: day.end).duration },
            2 * hour
        )
    }

    func testManualClassificationDoesNotHideConfirmedWorkoutOrSleep() {
        let day = TimeSpan(
            start: makeDate(2026, 8, 10),
            end: makeDate(2026, 8, 11)
        )
        let manual = ActualRecord(
            planID: nil,
            title: "샤워",
            categoryID: "activity",
            startedAt: day.start,
            endedAt: day.start.addingTimeInterval(3 * hour),
            source: .manual,
            manuallyCorrected: true
        )
        let workout = ActualRecord(
            planID: nil,
            title: "걷기 운동",
            categoryID: "exercise",
            startedAt: day.start.addingTimeInterval(hour),
            endedAt: day.start.addingTimeInterval(2 * hour),
            source: .appleWatch
        )
        let sleep = ActualRecord(
            planID: nil,
            title: "수면",
            categoryID: "sleep",
            startedAt: day.start.addingTimeInterval(2 * hour),
            endedAt: day.start.addingTimeInterval(3 * hour),
            source: .healthKit
        )

        let records = ReviewCoverageEngine.records(
            actuals: [manual, workout, sleep],
            in: [day],
            asOf: day.start.addingTimeInterval(3 * hour)
        )

        XCTAssertEqual(
            records.first(where: { $0.title == "걷기 운동" })?.span(
                asOf: day.end
            ).duration ?? 0,
            hour,
            accuracy: 0.001
        )
        XCTAssertEqual(
            records.first(where: { $0.title == "수면" })?.span(
                asOf: day.end
            ).duration ?? 0,
            hour,
            accuracy: 0.001
        )
        XCTAssertEqual(
            records.filter { $0.title == "샤워" }
                .reduce(0) { $0 + $1.span(asOf: day.end).duration },
            hour,
            accuracy: 0.001
        )
    }

    // MARK: - 수면과 겹친 휴식·생활

    private func restSpans(
        _ actuals: [ActualRecord],
        asOf: Date
    ) -> [TimeSpan] {
        RestSleepDisplayEngine.visibleActuals(actuals, asOf: asOf)
            .filter(RestSleepDisplayEngine.isRest)
            .map { $0.span(asOf: asOf) }
            .sorted { $0.start < $1.start }
    }

    private func routineSpans(
        _ actuals: [ActualRecord],
        asOf: Date
    ) -> [TimeSpan] {
        RestSleepDisplayEngine.visibleActuals(actuals, asOf: asOf)
            .filter {
                ActualRecordCategoryResolver.categoryID(for: $0) == "routine"
            }
            .map { $0.span(asOf: asOf) }
            .sorted { $0.start < $1.start }
    }

    /// 사용자 화면의 실제 값: 휴식 00:57 + 8시간 13분, 수면 02:43 + 4시간 50분.
    /// 수면이 휴식 한가운데 들어 있으므로 휴식은 앞뒤 두 조각만 남는다.
    func testSleepInsideRestLeavesTwoRestRemainders() {
        let day = makeDate(2026, 8, 5)
        let rest = makeActual(
            "집에서 휴식",
            "rest",
            start: makeDate(2026, 8, 5, 0, 57),
            minutes: 8 * 60 + 13,
            source: .location
        )
        let sleep = makeActual(
            "수면",
            "sleep",
            start: makeDate(2026, 8, 5, 2, 43),
            minutes: 4 * 60 + 50,
            source: .healthKit
        )
        let asOf = day.addingTimeInterval(24 * hour)

        let trimmed = RestSleepDisplayEngine.visibleActuals(
            [rest, sleep],
            asOf: asOf
        )
        let rests = trimmed.filter(RestSleepDisplayEngine.isRest)

        XCTAssertEqual(rests.count, 2)
        XCTAssertEqual(rests.map(\.startedAt), [
            makeDate(2026, 8, 5, 0, 57),
            makeDate(2026, 8, 5, 7, 33),
        ])
        XCTAssertEqual(rests.map(\.endedAt), [
            makeDate(2026, 8, 5, 2, 43),
            makeDate(2026, 8, 5, 9, 10),
        ])
        // 첫 조각이 원본 식별자를 지켜야 기록 상세가 열린다.
        XCTAssertEqual(rests.first?.id, rest.id)
        XCTAssertEqual(Set(rests.map(\.id)).count, 2)
        // 수면 기록 자체는 손대지 않는다.
        XCTAssertEqual(
            trimmed.filter { $0.categoryID == "sleep" }.map(\.id),
            [sleep.id]
        )
        // 다시 잘라도 같은 값이라야 화면 갱신마다 선택이 풀리지 않는다.
        XCTAssertEqual(
            RestSleepDisplayEngine.visibleActuals([rest, sleep], asOf: asOf),
            trimmed
        )
    }

    func testRestFullyInsideSleepDisappears() {
        let sleep = makeActual(
            "수면",
            "sleep",
            start: makeDate(2026, 8, 5, 1),
            minutes: 6 * 60,
            source: .healthKit
        )
        let rest = makeActual(
            "집에서 휴식",
            "rest",
            start: makeDate(2026, 8, 5, 2),
            minutes: 90,
            source: .location
        )
        let asOf = makeDate(2026, 8, 5, 12)

        XCTAssertTrue(restSpans([rest, sleep], asOf: asOf).isEmpty)
        XCTAssertEqual(
            RestSleepDisplayEngine.visibleActuals([rest, sleep], asOf: asOf)
                .map(\.id),
            [sleep.id]
        )
    }

    func testSleepCutsOverlappingLifeIntoVisibleRemainders() {
        let asOf = makeDate(2026, 8, 6, 12)
        let life = makeActual(
            "집안일",
            "activity",
            start: makeDate(2026, 8, 6, 0),
            minutes: 8 * 60,
            source: .location,
            behavior: StationaryContextKind.housework.rawValue
        )
        let sleep = makeActual(
            "수면",
            "sleep",
            start: makeDate(2026, 8, 6, 1),
            minutes: 5 * 60,
            source: .healthKit
        )

        XCTAssertEqual(
            routineSpans([life, sleep], asOf: asOf),
            [
                TimeSpan(
                    start: makeDate(2026, 8, 6, 0),
                    end: makeDate(2026, 8, 6, 1)
                ),
                TimeSpan(
                    start: makeDate(2026, 8, 6, 6),
                    end: makeDate(2026, 8, 6, 8)
                ),
            ]
        )

        let visible = RestSleepDisplayEngine.visibleActuals(
            [life, sleep],
            asOf: asOf
        )
        let groups = ActualRecordGroupingEngine.groups(
            actuals: visible,
            in: TimeSpan(
                start: makeDate(2026, 8, 6),
                end: makeDate(2026, 8, 7)
            ),
            categories: CategoryCatalog.builtIn,
            asOf: asOf
        )
        XCTAssertEqual(
            groups.first { $0.id == "routine" }?.duration,
            3 * hour
        )
        XCTAssertEqual(
            groups.first { $0.id == "sleep" }?.duration,
            5 * hour
        )
    }

    func testPartialSleepOverlapTrimsEachEdge() {
        let asOf = makeDate(2026, 8, 5, 23)
        let sleep = makeActual(
            "수면",
            "sleep",
            start: makeDate(2026, 8, 5, 1),
            minutes: 6 * 60,
            source: .healthKit
        )
        // 휴식이 수면보다 늦게 시작하고 늦게 끝난다: 뒤쪽만 남는다.
        let tail = makeActual(
            "집에서 휴식",
            "rest",
            start: makeDate(2026, 8, 5, 5),
            minutes: 4 * 60,
            source: .location
        )
        XCTAssertEqual(
            restSpans([tail, sleep], asOf: asOf),
            [TimeSpan(
                start: makeDate(2026, 8, 5, 7),
                end: makeDate(2026, 8, 5, 9)
            )]
        )

        // 휴식이 수면보다 먼저 시작하고 먼저 끝난다: 앞쪽만 남는다.
        let head = makeActual(
            "집에서 휴식",
            "rest",
            start: makeDate(2026, 8, 5, 0),
            minutes: 3 * 60,
            source: .location
        )
        let headRemainders = restSpans([head, sleep], asOf: asOf)
        XCTAssertEqual(
            headRemainders,
            [TimeSpan(
                start: makeDate(2026, 8, 5, 0),
                end: makeDate(2026, 8, 5, 1)
            )]
        )
        // 조각이 하나뿐이면 원본 식별자를 그대로 쓴다.
        XCTAssertEqual(
            RestSleepDisplayEngine.visibleActuals([head, sleep], asOf: asOf)
                .first?.id,
            head.id
        )
    }

    func testRestNotOverlappingSleepIsUntouched() {
        let asOf = makeDate(2026, 8, 5, 23)
        let sleep = makeActual(
            "수면",
            "sleep",
            start: makeDate(2026, 8, 5, 1),
            minutes: 6 * 60,
            source: .healthKit
        )
        let rest = makeActual(
            "카페",
            "rest",
            start: makeDate(2026, 8, 5, 14),
            minutes: 70,
            source: .location
        )
        let input = [rest, sleep]

        XCTAssertEqual(
            RestSleepDisplayEngine.visibleActuals(input, asOf: asOf),
            input
        )
        // 수면 기록이 없으면 휴식은 언제나 그대로다.
        XCTAssertEqual(
            RestSleepDisplayEngine.visibleActuals([rest], asOf: asOf),
            [rest]
        )
    }

    /// 근무·수업·통화·회의가 수면과 겹치면 감출 일이 아니라 따로 봐야 할
    /// 잘못이다. 수면 우선 규칙은 휴식·생활 분류에만 닿는다.
    func testSleepDoesNotSwallowWorkOrMeetingRecords() {
        let asOf = makeDate(2026, 8, 5, 23)
        let sleep = makeActual(
            "수면",
            "sleep",
            start: makeDate(2026, 8, 5, 1),
            minutes: 6 * 60,
            source: .healthKit
        )
        let others = [
            makeActual(
                "근무",
                "work",
                start: makeDate(2026, 8, 5, 2),
                minutes: 60,
                source: .location
            ),
            makeActual(
                "수업·학습",
                "study",
                start: makeDate(2026, 8, 5, 3),
                minutes: 60,
                source: .location
            ),
            makeActual(
                "통화",
                "relationship",
                start: makeDate(2026, 8, 5, 4),
                minutes: 20,
                source: .call
            ),
            makeActual(
                "머무름",
                "activity",
                start: makeDate(2026, 8, 5, 5),
                minutes: 30,
                source: .location
            ),
        ]

        XCTAssertEqual(
            RestSleepDisplayEngine.visibleActuals(others + [sleep], asOf: asOf),
            others + [sleep]
        )
    }

    /// 화면에 보이는 목록·눈금판·합계가 모두 같은 값을 읽는지 본다. 세 값이
    /// 흐른 시간(00:57–09:10)을 넘으면 안 된다.
    func testRecordTotalsForOverlappingRestAndSleepMatchElapsedTime() {
        let day = makeDate(2026, 8, 5)
        let span = TimeSpan(start: day, end: day.addingTimeInterval(24 * hour))
        let asOf = day.addingTimeInterval(24 * hour)
        let raw = [
            makeActual(
                "집에서 휴식",
                "rest",
                start: makeDate(2026, 8, 5, 0, 57),
                minutes: 8 * 60 + 13,
                source: .location
            ),
            makeActual(
                "수면",
                "sleep",
                start: makeDate(2026, 8, 5, 2, 43),
                minutes: 4 * 60 + 50,
                source: .healthKit
            ),
        ]
        let elapsed = makeDate(2026, 8, 5, 9, 10)
            .timeIntervalSince(makeDate(2026, 8, 5, 0, 57))
        let expectedRest: TimeInterval = (1 * 60 + 46) * 60
            + (1 * 60 + 37) * 60
        let expectedSleep: TimeInterval = (4 * 60 + 50) * 60

        // 다듬기 전에는 두 값의 합이 흐른 시간을 넘는다.
        XCTAssertGreaterThan(
            ActualRecordGroupingEngine.groups(
                actuals: raw,
                in: span,
                categories: CategoryCatalog.builtIn,
                asOf: asOf
            ).reduce(0) { $0 + $1.duration },
            elapsed
        )

        let actuals = RestSleepDisplayEngine.visibleActuals(raw, asOf: asOf)
        let groups = ActualRecordGroupingEngine.groups(
            actuals: actuals,
            in: span,
            categories: CategoryCatalog.builtIn,
            asOf: asOf
        )
        let byCategory = Dictionary(
            groups.map { ($0.id, $0.duration) },
            uniquingKeysWith: { first, _ in first }
        )

        XCTAssertEqual(byCategory["sleep"], expectedSleep)
        XCTAssertEqual(byCategory["rest"], expectedRest)
        XCTAssertEqual(groups.reduce(0) { $0 + $1.duration }, elapsed)

        // 잘린 두 조각은 제목이 같으므로 목록에서는 한 줄로 합쳐 보인다.
        let restGroup = groups.first { $0.id == "rest" }
        XCTAssertEqual(restGroup?.children.map(\.title), ["집에서 휴식"])
        XCTAssertEqual(restGroup?.children.first?.occurrenceCount, 2)
        XCTAssertEqual(
            restGroup?.children.first?.start,
            makeDate(2026, 8, 5, 0, 57)
        )

        // 눈금판(원형 시간표)도 같은 값을 읽는다.
        let rings = RecordChartEngine.clockRings(
            actuals: actuals,
            in: span,
            asOf: asOf
        )
        XCTAssertEqual(
            rings.first { $0.categoryID == "rest" }?.duration,
            expectedRest
        )
        XCTAssertEqual(
            rings.first { $0.categoryID == "rest" }?.arcs.count,
            2
        )
        XCTAssertEqual(
            rings.reduce(0) { $0 + $1.duration },
            groups.reduce(0) { $0 + $1.duration }
        )
    }

    func testIntervalSubtractionKeepsOnlyUncoveredParts() {
        let base = makeDate(2026, 8, 5)
        func span(_ from: Double, _ to: Double) -> TimeSpan {
            TimeSpan(
                start: base.addingTimeInterval(from * hour),
                end: base.addingTimeInterval(to * hour)
            )
        }

        XCTAssertEqual(
            ActualIntervalMergeEngine.subtracting(
                [span(2, 3), span(5, 6)],
                from: span(1, 8)
            ),
            [span(1, 2), span(3, 5), span(6, 8)]
        )
        XCTAssertEqual(
            ActualIntervalMergeEngine.subtracting(
                [span(0, 9)],
                from: span(1, 8)
            ),
            []
        )
        XCTAssertEqual(
            ActualIntervalMergeEngine.subtracting(
                [span(9, 10)],
                from: span(1, 8)
            ),
            [span(1, 8)]
        )
        // 맞닿기만 한 구간은 아무것도 덜어 내지 않는다.
        XCTAssertEqual(
            ActualIntervalMergeEngine.subtracting(
                [span(0, 1), span(8, 9)],
                from: span(1, 8)
            ),
            [span(1, 8)]
        )
    }

    func testHierarchySupportsUnlimitedDescendantsAndRollup() throws {
        let base = makeDate(2026, 1, 1)
        let year = PlanRecord(
            title: "출시",
            span: TimeSpan(start: base, end: base.addingTimeInterval(365 * 24 * hour)),
            categoryID: "project"
        )
        let month = PlanRecord(
            title: "기획",
            span: TimeSpan(start: base, end: base.addingTimeInterval(30 * 24 * hour)),
            categoryID: "project",
            parentID: year.id
        )
        let week = PlanRecord(
            title: "초안",
            span: TimeSpan(start: base, end: base.addingTimeInterval(7 * 24 * hour)),
            categoryID: "study",
            parentID: month.id
        )
        let day = PlanRecord(
            title: "작성",
            span: TimeSpan(start: base, end: base.addingTimeInterval(2 * hour)),
            categoryID: "study",
            parentID: week.id
        )
        let actual = ActualRecord(
            planID: day.id,
            title: day.title,
            categoryID: day.categoryID,
            startedAt: base,
            endedAt: base.addingTimeInterval(hour),
            source: .manual
        )
        let plans = [year, month, week, day]

        XCTAssertEqual(try PlanHierarchy.descendants(of: year.id, in: plans).count, 3)
        let rollup = try TimelineAggregationEngine(
            calendar: utcCalendar
        ).rollup(
            goalID: year.id,
            plans: plans,
            actuals: [actual],
            asOf: base.addingTimeInterval(hour)
        )
        XCTAssertEqual(rollup.descendantCount, 3)
        XCTAssertEqual(rollup.actualDuration, hour)
        XCTAssertEqual(rollup.plannedDuration, month.span.duration)
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

    func testSummaryHierarchyProvidesExpectedLowerLevels() {
        let date = makeDate(2026, 7, 15)
        let engine = TimelineAggregationEngine(calendar: utcCalendar)

        let week = engine.hierarchySummaries(
            for: .week,
            containing: date,
            plans: [],
            actuals: [],
            photos: []
        )
        XCTAssertEqual(week[.day]?.count, 7)

        let year = engine.hierarchySummaries(
            for: .year,
            containing: date,
            plans: [],
            actuals: [],
            photos: []
        )
        XCTAssertEqual(year[.month]?.count, 12)
        XCTAssertNotNil(year[.week])
        XCTAssertNotNil(year[.day])
    }

    func testAutomaticActivityIncludesSleepWorkoutAndWatchWithOverlapLanes() {
        let day = makeDate(2026, 8, 1)
        let sleep = ActualRecord(
            planID: nil,
            title: "수면",
            categoryID: "sleep",
            startedAt: day,
            endedAt: day.addingTimeInterval(8 * hour),
            source: .healthKit
        )
        let workout = ActualRecord(
            planID: nil,
            title: "러닝",
            categoryID: "exercise",
            startedAt: day.addingTimeInterval(7 * hour),
            endedAt: day.addingTimeInterval(9 * hour),
            source: .healthKit
        )
        let watch = ActualRecord(
            planID: nil,
            title: "Apple Watch 활동",
            categoryID: "health",
            startedAt: day.addingTimeInterval(10 * hour),
            endedAt: day.addingTimeInterval(11 * hour),
            source: .appleWatch
        )
        let manual = ActualRecord(
            planID: nil,
            title: "직접 기록",
            categoryID: "routine",
            startedAt: day.addingTimeInterval(12 * hour),
            endedAt: day.addingTimeInterval(13 * hour),
            source: .manual
        )
        let span = TimeSpan(
            start: day,
            end: day.addingTimeInterval(24 * hour)
        )

        let activities = AutomaticRecordTimelineEngine.activities(
            from: [manual, watch, workout, sleep],
            inside: span,
            asOf: span.end
        )
        XCTAssertEqual(activities.map(\.id), [sleep.id, workout.id, watch.id])

        let allocation = TimelineLaneAllocator.allocate(
            activities,
            span: { $0.span(asOf: span.end) }
        )
        XCTAssertEqual(allocation.count, 2)
        XCTAssertNotEqual(
            allocation.lanes[sleep.id],
            allocation.lanes[workout.id]
        )
        XCTAssertEqual(allocation.lanes[sleep.id], allocation.lanes[watch.id])
    }

    func testAutomaticHealthAndSensorRecordsAreImmutable() {
        let start = makeDate(2026, 8, 1, 9)
        func record(_ source: ActualSource) -> ActualRecord {
            ActualRecord(
                planID: nil,
                title: "활동",
                categoryID: "activity",
                startedAt: start,
                endedAt: start.addingTimeInterval(hour),
                source: source
            )
        }

        XCTAssertTrue(
            AutomaticRecordTimelineEngine.isImmutable(record(.healthKit))
        )
        XCTAssertTrue(
            AutomaticRecordTimelineEngine.isImmutable(record(.appleWatch))
        )
        XCTAssertTrue(
            AutomaticRecordTimelineEngine.isImmutable(record(.location))
        )
        XCTAssertTrue(
            AutomaticRecordTimelineEngine.isImmutable(record(.motion))
        )
        XCTAssertTrue(
            AutomaticRecordTimelineEngine.isImmutable(record(.media))
        )
        XCTAssertTrue(
            AutomaticRecordTimelineEngine.isImmutable(record(.call))
        )
        XCTAssertFalse(
            AutomaticRecordTimelineEngine.isImmutable(record(.manual))
        )
        XCTAssertFalse(
            AutomaticRecordTimelineEngine.isImmutable(record(.timer))
        )
    }

    func testAutomaticTimelineDoesNotForecastPastNow() {
        let now = makeDate(2026, 8, 3, 12)
        let ongoing = ActualRecord(
            planID: nil,
            title: "정지·휴식",
            categoryID: "activity",
            startedAt: now.addingTimeInterval(-hour),
            endedAt: now.addingTimeInterval(hour),
            source: .motion
        )
        let future = ActualRecord(
            planID: nil,
            title: "걷기",
            categoryID: "activity",
            startedAt: now.addingTimeInterval(10 * 60),
            endedAt: now.addingTimeInterval(20 * 60),
            source: .appleWatch
        )

        let visible = AutomaticRecordTimelineEngine.activities(
            from: [ongoing, future],
            inside: TimeSpan(
                start: now.addingTimeInterval(-2 * hour),
                end: now.addingTimeInterval(2 * hour)
            ),
            asOf: now
        )

        XCTAssertEqual(visible.map(\.id), [ongoing.id])
        XCTAssertEqual(visible[0].endedAt, now)
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

    func testTimeSliderUsesOneMinuteAndTenMinutePrecision() {
        let base = makeDate(2026, 7, 30, 9, 0)
        let span = TimeSpan(start: base, end: base.addingTimeInterval(hour))
        let slow = TimeSliderEngine.adjust(
            span,
            handle: .body,
            delta: 7 * 60,
            velocityPointsPerSecond: 100,
            isLongPressPrecision: false
        )
        let fast = TimeSliderEngine.adjust(
            span,
            handle: .body,
            delta: 7 * 60,
            velocityPointsPerSecond: 900,
            isLongPressPrecision: false
        )
        XCTAssertEqual(slow.start.timeIntervalSince(base), 7 * 60)
        XCTAssertEqual(fast.start.timeIntervalSince(base), 10 * 60)
        XCTAssertEqual(
            TimeSliderEngine.snapInterval(
                velocityPointsPerSecond: 900,
                isLongPressPrecision: true
            ),
            60
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

    func testGanttViewportStopsAtOneMinuteForEveryTimelineDuration() {
        let durations: [TimeInterval] = [
            24 * 60 * 60,
            7 * 24 * 60 * 60,
            31 * 24 * 60 * 60,
            366 * 24 * 60 * 60,
        ]

        for duration in durations {
            let minimumLength = GanttViewport.oneMinuteMinimumLength(
                for: duration
            )
            let zoomed = GanttViewport.full.magnifying(
                by: 1_000_000,
                anchor: 0.5,
                minimumLength: minimumLength
            )

            XCTAssertEqual(
                duration * zoomed.length,
                60,
                accuracy: 0.001
            )
        }
    }

    func testGanttSemanticZoomStagesFollowProductHierarchy() {
        XCTAssertEqual(
            GanttZoomStage.allCases,
            [
                .year,
                .month,
                .week,
                .day,
                .hour,
                .fifteenMinutes,
                .fiveMinutes,
                .oneMinute,
            ]
        )
        XCTAssertEqual(GanttZoomStage.day.narrower, .hour)
        XCTAssertEqual(GanttZoomStage.oneMinute.narrower, nil)
        XCTAssertEqual(GanttZoomStage.oneMinute.broader, .fiveMinutes)
        XCTAssertEqual(GanttZoomStage.nearest(to: 15 * 60), .fifteenMinutes)
        XCTAssertEqual(GanttZoomStage.nearest(to: 60), .oneMinute)

        XCTAssertEqual(TimeScale.year.narrower, .month)
        XCTAssertEqual(TimeScale.month.narrower, .week)
        XCTAssertEqual(TimeScale.week.narrower, .day)
        XCTAssertEqual(TimeScale.day.broader, .week)
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

    @MainActor
    func testTwoFingerDoubleTapRecognizerIsInstalledAndInvokesReset() {
        var recognitionCount = 0
        let coordinator = TwoFingerDoubleTapAttachment.Coordinator {
            recognitionCount += 1
        }
        let hostView = UIView()
        let attachmentView = TwoFingerDoubleTapAttachment.AttachmentView()
        attachmentView.coordinator = coordinator

        hostView.addSubview(attachmentView)
        attachmentView.installRecognizerIfNeeded()

        let recognizer = hostView.gestureRecognizers?
            .compactMap { $0 as? UITapGestureRecognizer }
            .first
        XCTAssertEqual(recognizer?.numberOfTapsRequired, 2)
        XCTAssertEqual(recognizer?.numberOfTouchesRequired, 2)
        XCTAssertEqual(recognizer?.cancelsTouchesInView, false)

        coordinator.didRecognize()
        XCTAssertEqual(recognitionCount, 1)
    }

    @MainActor
    func testTwoFingerPinchRecognizerIsInstalledAndDeliversScale() {
        var changed: (CGFloat, CGFloat)?
        var ended: (CGFloat, CGFloat)?
        let coordinator = TwoFingerPinchAttachment.Coordinator(
            onChanged: { scale, anchor in
                changed = (scale, anchor)
            },
            onEnded: { scale, anchor in
                ended = (scale, anchor)
            }
        )
        let window = UIWindow(
            frame: CGRect(x: 0, y: 0, width: 400, height: 300)
        )
        let controller = UIViewController()
        window.rootViewController = controller
        let scrollView = UIScrollView(frame: window.bounds)
        let hostView = UIView(frame: scrollView.bounds)
        let attachmentView = TwoFingerPinchAttachment.AttachmentView()
        attachmentView.frame = hostView.bounds
        attachmentView.coordinator = coordinator
        coordinator.targetView = attachmentView

        // SwiftUI creates background representables before their final window
        // hierarchy exists. The recognizer must not stay on that temporary host.
        hostView.addSubview(attachmentView)
        attachmentView.installRecognizerIfNeeded()
        XCTAssertFalse(
            hostView.gestureRecognizers?.contains {
                $0 is UIPinchGestureRecognizer
            } ?? false
        )

        controller.view.addSubview(scrollView)
        scrollView.addSubview(hostView)
        window.isHidden = false
        attachmentView.installRecognizerIfNeeded()

        let recognizer = window.gestureRecognizers?
            .compactMap { $0 as? UIPinchGestureRecognizer }
            .first
        XCTAssertNotNil(recognizer)
        XCTAssertEqual(recognizer?.cancelsTouchesInView, false)
        XCTAssertEqual(
            scrollView.panGestureRecognizer.maximumNumberOfTouches,
            1
        )
        XCTAssertFalse(
            hostView.gestureRecognizers?.contains {
                $0 is UIPinchGestureRecognizer
            } ?? false
        )

        coordinator.onChanged(1.5, 0.25)
        coordinator.onEnded(0.75, 0.75)
        XCTAssertEqual(changed?.0 ?? 0, 1.5, accuracy: 0.0001)
        XCTAssertEqual(changed?.1 ?? 0, 0.25, accuracy: 0.0001)
        XCTAssertEqual(ended?.0 ?? 0, 0.75, accuracy: 0.0001)
        XCTAssertEqual(ended?.1 ?? 0, 0.75, accuracy: 0.0001)
        coordinator.restoreScrollTouchLimits()
    }

    @MainActor
    func testTwoFingerPinchKeepsSharedScrollLimitUntilLastAttachmentLeaves() {
        let scrollView = UIScrollView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 300)
        )
        let firstView = UIView(frame: scrollView.bounds)
        let secondView = UIView(frame: scrollView.bounds)
        scrollView.addSubview(firstView)
        scrollView.addSubview(secondView)
        let first = TwoFingerPinchAttachment.Coordinator(
            onChanged: { _, _ in },
            onEnded: { _, _ in }
        )
        let second = TwoFingerPinchAttachment.Coordinator(
            onChanged: { _, _ in },
            onEnded: { _, _ in }
        )

        let original = scrollView.panGestureRecognizer.maximumNumberOfTouches
        first.limitAncestorScrollPans(from: firstView)
        second.limitAncestorScrollPans(from: secondView)
        XCTAssertEqual(
            scrollView.panGestureRecognizer.maximumNumberOfTouches,
            1
        )

        first.restoreScrollTouchLimits()
        XCTAssertEqual(
            scrollView.panGestureRecognizer.maximumNumberOfTouches,
            1
        )
        second.restoreScrollTouchLimits()
        XCTAssertEqual(
            scrollView.panGestureRecognizer.maximumNumberOfTouches,
            original
        )
    }

    func testScheduleDragSnapsToFifteenMinutes() throws {
        let base = makeDate(2026, 7, 30, 9, 0)
        let plan = PlanRecord(
            title: "초안",
            span: TimeSpan(start: base, end: base.addingTimeInterval(hour)),
            categoryID: "project"
        )
        let moved = try ScheduleEditEngine.move(plan, by: 22 * 60)
        XCTAssertEqual(moved.span.start.timeIntervalSince(base), 15 * 60)
    }

    func testQuickActionsPreservePlanAndCreateSeparateActual() {
        let base = makeDate(2026, 7, 30, 9, 0)
        let plan = PlanRecord(
            title: "러닝",
            span: TimeSpan(start: base, end: base.addingTimeInterval(hour)),
            categoryID: "exercise"
        )
        let started = QuickActionEngine.start(plan: plan, actuals: [], at: base)
        XCTAssertEqual(started.plan.span, plan.span)
        XCTAssertEqual(started.plan.status, .running)
        XCTAssertEqual(started.actuals.count, 1)

        let completed = QuickActionEngine.complete(
            plan: started.plan,
            actuals: started.actuals,
            at: base.addingTimeInterval(40 * 60)
        )
        XCTAssertEqual(completed.plan.status, .completed)
        XCTAssertEqual(completed.actuals[0].span().duration, 40 * 60)
        XCTAssertEqual(completed.plan.span.duration, hour)
    }

    func testMoveToNextFreeTimeFindsGap() throws {
        let base = makeDate(2026, 7, 30, 9, 0)
        let plan = PlanRecord(
            title: "집중",
            span: TimeSpan(start: base, end: base.addingTimeInterval(hour)),
            categoryID: "project"
        )
        let occupied = [
            TimeSpan(start: base, end: base.addingTimeInterval(2 * hour)),
            TimeSpan(
                start: base.addingTimeInterval(3 * hour),
                end: base.addingTimeInterval(4 * hour)
            )
        ]
        let moved = try QuickActionEngine.moveToNextFreeTime(
            plan: plan,
            occupied: occupied,
            after: base
        )
        XCTAssertEqual(moved.span.start, base.addingTimeInterval(2 * hour))
    }

    func testPhotoMomentsClusterAndRespectHiddenFlag() {
        let base = makeDate(2026, 7, 30, 11, 42)
        let photos = [
            PhotoMoment(id: "1", capturedAt: base, pixelWidth: 100, pixelHeight: 100, isFavorite: false, isHiddenFromTimeline: false),
            PhotoMoment(id: "2", capturedAt: base.addingTimeInterval(5 * 60), pixelWidth: 100, pixelHeight: 100, isFavorite: true, isHiddenFromTimeline: false),
            PhotoMoment(id: "3", capturedAt: base.addingTimeInterval(40 * 60), pixelWidth: 100, pixelHeight: 100, isFavorite: false, isHiddenFromTimeline: true)
        ]
        let clusters = PhotoClusterer.cluster(photos)
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].representative.id, "2")
        XCTAssertEqual(clusters[0].additionalCount, 1)
        XCTAssertEqual(
            PhotoClusterer.nearestCluster(
                to: base.addingTimeInterval(8 * 60),
                in: photos,
                tolerance: 10 * 60
            )?.representative.id,
            "2"
        )
        XCTAssertNil(
            PhotoClusterer.nearestCluster(
                to: base.addingTimeInterval(2 * 60 * 60),
                in: photos,
                tolerance: 10 * 60
            )
        )
    }

    func testReviewDescribesDifferenceInsteadOfScoring() {
        let base = makeDate(2026, 7, 27)
        let plan = PlanRecord(
            title: "학습",
            span: TimeSpan(start: base, end: base.addingTimeInterval(2 * hour)),
            categoryID: "study"
        )
        let actual = ActualRecord(
            planID: plan.id,
            title: plan.title,
            categoryID: "study",
            startedAt: base,
            endedAt: base.addingTimeInterval(hour),
            source: .manual
        )
        let report = ReviewEngine(calendar: utcCalendar).report(
            for: .week,
            containing: base,
            plans: [plan],
            actuals: [actual],
            weather: [],
            photos: [],
            memos: [],
            asOf: base.addingTimeInterval(hour)
        )
        XCTAssertEqual(report.plannedDuration, 2 * hour)
        XCTAssertEqual(report.actualDuration, hour)
    }

    func testReviewArchiveStoresDailyWeeklyAndMonthlyDataInsideYear() {
        let first = makeDate(2026, 1, 2, 9)
        let second = makeDate(2026, 1, 8, 10)
        let asOf = makeDate(2026, 1, 11, 12)
        var snapshot = TaptionDataSnapshot.empty
        snapshot.actuals = [
            ActualRecord(
                planID: nil,
                title: "업무",
                categoryID: "work",
                startedAt: first,
                endedAt: first.addingTimeInterval(hour),
                source: .manual
            ),
            ActualRecord(
                planID: nil,
                title: "운동",
                categoryID: "exercise",
                startedAt: second,
                endedAt: second.addingTimeInterval(2 * hour),
                source: .manual
            ),
        ]

        let archives = ReviewReportArchiveEngine.refreshed(
            snapshot: snapshot,
            asOf: asOf,
            calendar: utcCalendar
        )

        XCTAssertEqual(archives.count, 1)
        XCTAssertEqual(archives[0].months.count, 1)
        XCTAssertGreaterThanOrEqual(archives[0].months[0].weeks.count, 2)
        XCTAssertEqual(
            Set(archives[0].months[0].dayIDs),
            Set(archives[0].days.map(\.id))
        )
    }

    func testChangingDailyDataRebuildsMonthAndYear() {
        let start = makeDate(2026, 2, 3, 9)
        let asOf = makeDate(2026, 2, 4)
        let id = UUID()
        var snapshot = TaptionDataSnapshot.empty
        snapshot.actuals = [
            ActualRecord(
                id: id,
                planID: nil,
                title: "업무",
                categoryID: "work",
                startedAt: start,
                endedAt: start.addingTimeInterval(hour),
                source: .manual
            )
        ]
        let original = ReviewReportArchiveEngine.refreshed(
            snapshot: snapshot,
            asOf: asOf,
            calendar: utcCalendar
        )
        snapshot.yearlyReports = original
        snapshot.actuals[0].endedAt = start.addingTimeInterval(3 * hour)

        let updated = ReviewReportArchiveEngine.refreshed(
            snapshot: snapshot,
            asOf: asOf,
            calendar: utcCalendar
        )
        let day = updated[0].days.first { $0.span.contains(start) }
        let month = updated[0].months[0].report.categories.first {
            $0.categoryID == "work"
        }
        let year = updated[0].report.categories.first {
            $0.categoryID == "work"
        }

        XCTAssertNotEqual(
            day?.sourceFingerprint,
            original[0].days.first { $0.span.contains(start) }?.sourceFingerprint
        )
        XCTAssertEqual(day?.groups.first { $0.id == "work" }?.duration, 3 * hour)
        XCTAssertEqual(month?.actual, 3 * hour)
        XCTAssertEqual(year?.actual, 3 * hour)
        XCTAssertEqual(day?.dayPhases?.reduce(0) { $0 + $1.actual }, 24 * hour)
        XCTAssertEqual(
            updated[0].months[0].dayPhases?.reduce(0) { $0 + $1.actual },
            24 * hour
        )
        XCTAssertEqual(
            updated[0].dayPhases?.reduce(0) { $0 + $1.actual },
            24 * hour
        )
    }

    func testHistoricalDailyBackupSurvivesMissingLocalSource() {
        let start = makeDate(2026, 2, 10, 9)
        let firstAsOf = makeDate(2026, 2, 11)
        var snapshot = TaptionDataSnapshot.empty
        snapshot.actuals = [
            ActualRecord(
                planID: nil,
                title: "업무",
                categoryID: "work",
                startedAt: start,
                endedAt: start.addingTimeInterval(2 * hour),
                source: .manual
            )
        ]
        snapshot.yearlyReports = ReviewReportArchiveEngine.refreshed(
            snapshot: snapshot,
            asOf: firstAsOf,
            calendar: utcCalendar
        )
        snapshot.actuals = []

        let recovered = ReviewReportArchiveEngine.refreshed(
            snapshot: snapshot,
            asOf: makeDate(2026, 2, 12),
            calendar: utcCalendar
        )
        let archivedDay = recovered[0].days.first { $0.span.contains(start) }

        XCTAssertEqual(
            archivedDay?.groups.first { $0.id == "work" }?.duration,
            2 * hour
        )
    }

    func testCloudRecoveryMergesDifferentDailyReportsInSameYear() {
        let first = makeDate(2026, 3, 2, 9)
        let second = makeDate(2026, 3, 8, 10)
        let asOf = makeDate(2026, 3, 10)
        var local = TaptionDataSnapshot.empty
        local.updatedAt = asOf
        local.actuals = [
            ActualRecord(
                planID: nil,
                title: "업무",
                categoryID: "work",
                startedAt: first,
                endedAt: first.addingTimeInterval(hour),
                source: .manual
            )
        ]
        local.yearlyReports = ReviewReportArchiveEngine.refreshed(
            snapshot: local,
            asOf: asOf,
            calendar: utcCalendar
        )
        var remote = TaptionDataSnapshot.empty
        remote.updatedAt = asOf.addingTimeInterval(-hour)
        remote.actuals = [
            ActualRecord(
                planID: nil,
                title: "업무",
                categoryID: "work",
                startedAt: second,
                endedAt: second.addingTimeInterval(2 * hour),
                source: .manual
            )
        ]
        remote.yearlyReports = ReviewReportArchiveEngine.refreshed(
            snapshot: remote,
            asOf: asOf,
            calendar: utcCalendar
        )

        let recovered = CloudSnapshotRecoveryEngine.merge(
            local: local,
            remote: remote
        )
        let work = recovered.yearlyReports[0].report.categories.first {
            $0.categoryID == "work"
        }

        XCTAssertTrue(recovered.yearlyReports[0].days.contains {
            $0.span.contains(first)
        })
        XCTAssertTrue(recovered.yearlyReports[0].days.contains {
            $0.span.contains(second)
        })
        XCTAssertEqual(work?.actual, 3 * hour)
    }

    func testSnapshotWithoutYearlyReportsDecodesAsEmptyArchive() throws {
        let data = try JSONEncoder().encode(TaptionDataSnapshot.empty)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "yearlyReports")

        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(
            TaptionDataSnapshot.self,
            from: legacy
        )

        XCTAssertTrue(decoded.yearlyReports.isEmpty)
    }

    func testAllCustomCategoryRequirementsExist() throws {
        XCTAssertEqual(CategoryCatalog.builtIn.count, 32)
        XCTAssertGreaterThanOrEqual(CategoryIcon.allCases.count, 32)
        XCTAssertEqual(
            Set(CategoryCatalog.builtIn.map(\.icon)).count,
            CategoryCatalog.builtIn.count,
            "기본 대분류 아이콘은 서로 겹치지 않아야 합니다."
        )
        let custom = try CategoryCatalog.makeCustom(
            name: "봉사",
            icon: .family,
            lightHex: "AABBCC",
            existing: CategoryCatalog.builtIn
        )
        XCTAssertFalse(custom.isBuiltIn)
        XCTAssertEqual(custom.lightHex, "#AABBCC")
    }

    func testEveryBuiltInCategoryProvidesMiddleCategorySuggestions() {
        XCTAssertEqual(
            Set(CategoryHierarchyCatalog.middleSuggestionsByCategoryID.keys),
            Set(CategoryCatalog.builtIn.map(\.id))
        )

        for category in CategoryCatalog.builtIn {
            let suggestions = CategoryHierarchyCatalog.middleSuggestions(
                for: category.id
            )
            XCTAssertGreaterThanOrEqual(
                suggestions.count,
                4,
                "\(category.name) 중분류 추천이 부족합니다."
            )
            XCTAssertEqual(Set(suggestions).count, suggestions.count)
            XCTAssertTrue(suggestions.allSatisfy {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })
        }

        XCTAssertEqual(
            CategoryHierarchyCatalog.middleSuggestions(
                for: "custom.volunteer"
            ),
            CategoryHierarchyCatalog.defaultMiddleSuggestions
        )
    }

    func testQuickPlanDraftUsesHalfHourDefaultsAndTitleFallback() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let input = calendar.date(
            from: DateComponents(
                year: 2026,
                month: 8,
                day: 1,
                hour: 12,
                minute: 57
            )
        )!
        let rounded = QuickPlanDraftEngine.roundedUpToHalfHour(input)

        XCTAssertEqual(calendar.component(.hour, from: rounded), 13)
        XCTAssertEqual(calendar.component(.minute, from: rounded), 0)
        XCTAssertEqual(QuickPlanDraftEngine.defaultDuration, 30 * 60)
        XCTAssertEqual(QuickPlanDraftEngine.adjustmentStep, 5 * 60)
        XCTAssertEqual(
            QuickPlanDraftEngine.resolvedTitle(
                subcategory: "청계천 산책",
                middleCategory: "산책"
            ),
            "청계천 산책"
        )
        XCTAssertEqual(
            QuickPlanDraftEngine.resolvedTitle(
                subcategory: "   ",
                middleCategory: "산책"
            ),
            "산책"
        )
        XCTAssertNil(
            QuickPlanDraftEngine.resolvedTitle(
                subcategory: "",
                middleCategory: ""
            )
        )
    }

    func testMiniGanttAdjustmentSnapsToFiveMinutes() {
        let base = makeDate(2026, 8, 1).addingTimeInterval(13 * hour)
        let span = TimeSpan(
            start: base,
            end: base.addingTimeInterval(30 * 60)
        )
        let resized = TimeSliderEngine.adjust(
            span,
            handle: .end,
            delta: 8 * 60,
            snapInterval: QuickPlanDraftEngine.adjustmentStep,
            minimumDuration: QuickPlanDraftEngine.adjustmentStep
        )
        let moved = TimeSliderEngine.adjust(
            span,
            handle: .body,
            delta: 12 * 60,
            snapInterval: QuickPlanDraftEngine.adjustmentStep,
            minimumDuration: QuickPlanDraftEngine.adjustmentStep
        )

        XCTAssertEqual(resized.duration, 40 * 60)
        XCTAssertEqual(moved.start, base.addingTimeInterval(10 * 60))
        XCTAssertEqual(moved.duration, span.duration)
    }

    func testDeletingCustomCategoryReassignsRecords() throws {
        let custom = try CategoryCatalog.makeCustom(
            name: "봉사",
            icon: .family,
            lightHex: "#AABBCC",
            existing: CategoryCatalog.builtIn
        )
        let base = makeDate(2026, 7, 30)
        let plan = PlanRecord(
            title: "봉사",
            span: TimeSpan(start: base, end: base.addingTimeInterval(hour)),
            categoryID: custom.id
        )
        let result = try CategoryCatalog.deleting(
            categoryID: custom.id,
            reassigningTo: "relationship",
            categories: CategoryCatalog.builtIn + [custom],
            plans: [plan],
            actuals: []
        )
        XCTAssertEqual(result.plans[0].categoryID, "relationship")
        XCTAssertFalse(result.categories.contains(where: { $0.id == custom.id }))
    }

    func testCategoryDragReorderingMovesInsteadOfSwapping() {
        let categories = Array(CategoryCatalog.builtIn.prefix(4))
        let reordered = CategoryCatalog.moving(
            categories,
            fromOffsets: IndexSet(integer: 0),
            toOffset: 3
        )

        XCTAssertEqual(
            reordered.map(\.id),
            [
                categories[1].id,
                categories[2].id,
                categories[0].id,
                categories[3].id,
            ]
        )
        XCTAssertEqual(
            reordered.map(\.sortOrder),
            Array(0..<categories.count)
        )
    }

    func testSubwayNeedsCombinedSignals() {
        let base = makeDate(2026, 7, 30, 8, 0)
        let readings = (0..<6).map { index in
            SensorReading(
                timestamp: base.addingTimeInterval(Double(index) * 60),
                speedMetersPerSecond: 12,
                motion: .automotive,
                motionConfidence: .high,
                relativeAltitudeMeters: Double(index) * -0.8,
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

    func testAppleWatchAccelerationAndUndergroundWindowIdentifySubway() {
        let base = makeDate(2026, 7, 30, 8, 0)
        let readings = (0..<6).map { index in
            SensorReading(
                timestamp: base.addingTimeInterval(Double(index) * 60),
                speedMetersPerSecond: index < 2 ? 14 : nil,
                motion: .automotive,
                motionConfidence: .high,
                relativeAltitudeMeters: Double(index) * -0.8,
                stepCount: 100,
                watchAccelerationStandardDeviationG: 0.04,
                watchAccelerationMeanJerkGPerSecond: 0.16,
                gpsAvailable: index < 2,
                nearbyStation: true,
                frequentStops: true
            )
        }

        let result = TravelModeClassifier().classify(readings: readings)
        XCTAssertEqual(result.mode, .subway)
        XCTAssertTrue(
            result.evidence.contains("Apple Watch 3축 가속도 철도 진동")
        )
        XCTAssertTrue(result.evidence.contains("걸음 거의 없음 · 지하 구간"))
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

        XCTAssertNotEqual(
            TravelModeClassifier().classify(readings: readings).mode,
            .subway
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

    func testWatchVibrationWithoutUndergroundContextDoesNotBecomeSubway() {
        let base = makeDate(2026, 7, 30, 8, 0)
        let readings = (0..<4).map { index in
            SensorReading(
                timestamp: base.addingTimeInterval(Double(index) * 60),
                speedMetersPerSecond: 13,
                motion: .automotive,
                motionConfidence: .high,
                stepCount: 20,
                watchAccelerationStandardDeviationG: 0.04,
                watchAccelerationMeanJerkGPerSecond: 0.16,
                gpsAvailable: true
            )
        }

        XCTAssertNotEqual(
            TravelModeClassifier().classify(readings: readings).mode,
            .subway
        )
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

    func testChargingInactivityBecomesSleepOnlyAfterOneHourWithoutWatch() {
        let start = makeDate(2026, 8, 9, 14, 0)
        let readings = (0...4).map { index in
            SensorReading(
                timestamp: start.addingTimeInterval(Double(index) * 15 * 60),
                motion: .stationary,
                motionConfidence: .high,
                stepCount: 0,
                powerState: .charging
            )
        }
        let span = TimeSpan(
            start: start,
            end: start.addingTimeInterval(2 * hour)
        )

        let records = ChargingInactivitySleepEngine.records(
            readings: readings,
            actuals: [],
            inside: span,
            watchAvailable: false,
            maximumSampleGap: 15 * 60,
            asOf: span.end
        )
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.categoryID, "sleep")
        XCTAssertEqual(records.first?.span(asOf: span.end).duration, hour)

        XCTAssertTrue(
            ChargingInactivitySleepEngine.records(
                readings: Array(readings.prefix(4)),
                actuals: [],
                inside: span,
                watchAvailable: false,
                maximumSampleGap: 15 * 60,
                asOf: span.end
            ).isEmpty
        )
        XCTAssertTrue(
            ChargingInactivitySleepEngine.records(
                readings: readings,
                actuals: [],
                inside: span,
                watchAvailable: true,
                maximumSampleGap: 15 * 60,
                asOf: span.end
            ).isEmpty
        )
    }

    func testChargingInactivitySleepIsBlockedByAppUsage() {
        let start = makeDate(2026, 8, 9, 14, 0)
        let readings = (0...4).map { index in
            SensorReading(
                timestamp: start.addingTimeInterval(Double(index) * 15 * 60),
                motion: .stationary,
                stepCount: 0,
                powerState: .full
            )
        }
        let span = TimeSpan(
            start: start,
            end: start.addingTimeInterval(2 * hour)
        )
        let appUsage = ActualRecord(
            planID: nil,
            title: "앱 사용",
            categoryID: "appUsage",
            startedAt: start.addingTimeInterval(10 * 60),
            endedAt: start.addingTimeInterval(50 * 60),
            source: .appUsage
        )

        XCTAssertTrue(
            ChargingInactivitySleepEngine.records(
                readings: readings,
                actuals: [appUsage],
                inside: span,
                watchAvailable: false,
                maximumSampleGap: 15 * 60,
                asOf: span.end
            ).isEmpty
        )
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

    func testAppleWatchWorkoutOverridesConflictingIPhoneMotion() {
        let base = makeDate(2026, 7, 30, 9, 0)
        let span = TimeSpan(
            start: base,
            end: base.addingTimeInterval(10 * 60)
        )
        let readings = (0..<6).map { index in
            SensorReading(
                timestamp: base.addingTimeInterval(Double(index) * 2 * 60),
                speedMetersPerSecond: 8,
                motion: .automotive,
                motionConfidence: .high,
                stepCount: index * 100
            )
        }
        let watchWorkout = AppleMovementEvidence(
            span: span,
            source: .appleWatch,
            kind: .workout,
            workoutMode: .walking,
            stepCount: 1_000,
            distanceMeters: 800,
            sourceName: "Apple Watch",
            deviceName: "Apple Watch"
        )

        let result = TravelModeClassifier().classify(
            readings: readings,
            inside: span,
            healthEvidence: [watchWorkout]
        )

        XCTAssertEqual(result.mode, .walking)
        XCTAssertEqual(result.confidence, .high)
        XCTAssertTrue(
            result.evidence.contains("Apple Watch 걷기 운동")
        )
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
        let refreshed = TravelSegment(
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

    func testTravelPresentationSeparatesWorkoutWalkingColorClass() {
        let base = makeDate(2026, 8, 9, 18, 0)
        let walking = TravelSegment(
            mode: .walking,
            span: TimeSpan(
                start: base,
                end: base.addingTimeInterval(hour)
            ),
            distanceMeters: 4_800,
            confidence: .high,
            evidence: []
        )
        let workout = ActualRecord(
            planID: nil,
            title: "걷기 운동",
            categoryID: "exercise",
            startedAt: base.addingTimeInterval(10 * 60),
            endedAt: base.addingTimeInterval(55 * 60),
            source: .appleWatch,
            behavior: WatchBehaviorKind.walking.rawValue,
            evidence: [AutomaticRecordTimelineEngine.watchWorkoutEvidence],
            sensorChunkID: UUID()
        )
        let passive = ActualRecord(
            planID: nil,
            title: "걷기",
            categoryID: "movement",
            startedAt: walking.span.start,
            endedAt: walking.span.end,
            source: .motion,
            behavior: WatchBehaviorKind.walking.rawValue
        )

        XCTAssertTrue(
            TravelSegmentPresentationEngine.isWorkoutWalking(
                walking,
                actuals: [workout],
                asOf: base.addingTimeInterval(2 * hour)
            )
        )
        XCTAssertFalse(
            TravelSegmentPresentationEngine.isWorkoutWalking(
                walking,
                actuals: [passive],
                asOf: base.addingTimeInterval(2 * hour)
            )
        )
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

    func testMemoEditingPreservesIdentityAndAttachments() throws {
        let createdAt = makeDate(2026, 7, 30, 9, 0)
        let updatedAt = createdAt.addingTimeInterval(60)
        let attachment = MemoAttachment(
            kind: .photo,
            localIdentifier: "photo-id",
            createdAt: createdAt
        )
        let original = ActionMemo(
            planID: UUID(),
            targetID: "automatic.actual.item",
            kind: .idea,
            text: "초안",
            attachments: [attachment],
            createdAt: createdAt,
            updatedAt: createdAt
        )

        let updated = try XCTUnwrap(
            ActionMemoEditingEngine.updating(
                original,
                text: "  다음 행동  ",
                kind: .nextAction,
                at: updatedAt
            )
        )

        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(updated.planID, original.planID)
        XCTAssertEqual(updated.targetID, original.targetID)
        XCTAssertEqual(updated.text, "다음 행동")
        XCTAssertEqual(updated.kind, .nextAction)
        XCTAssertEqual(updated.attachments, [attachment])
        XCTAssertEqual(updated.createdAt, createdAt)
        XCTAssertEqual(updated.updatedAt, updatedAt)
        XCTAssertNil(
            ActionMemoEditingEngine.updating(
                original,
                text: "  ",
                kind: .decision
            )
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
            (120, 37.57127, 126.7359, "마곡나루역"),
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
                relativeAltitudeMeters: 0,
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
                timestamp: base.addingTimeInterval(20 * 60),
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

    func testResolvingOverlapsKeepsOneSegmentPerMoment() {
        let base = makeDate(2026, 8, 4, 9, 24)
        let long = TravelSegment(
            mode: .car,
            span: TimeSpan(start: base, end: base.addingTimeInterval(40 * 60)),
            distanceMeters: 8_000,
            confidence: .high,
            evidence: ["GPS"]
        )
        let overlapping = TravelSegment(
            mode: .cycling,
            span: TimeSpan(
                start: base.addingTimeInterval(10 * 60),
                end: base.addingTimeInterval(20 * 60)
            ),
            distanceMeters: 900,
            confidence: .low,
            evidence: ["iPhone Core Motion 기록"]
        )

        let resolved = AppleDeviceGroundTruthEngine.resolvingOverlaps(
            [long, overlapping]
        )

        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.mode, .car)
        for pair in zip(resolved, resolved.dropFirst()) {
            XCTAssertNil(pair.0.span.intersection(with: pair.1.span))
        }
    }

    func testResolvingOverlapsTrimsTrailingRemainder() {
        let base = makeDate(2026, 8, 4, 9, 24)
        let first = TravelSegment(
            mode: .car,
            span: TimeSpan(start: base, end: base.addingTimeInterval(20 * 60)),
            distanceMeters: 6_000,
            confidence: .high,
            evidence: ["GPS"]
        )
        let second = TravelSegment(
            mode: .walking,
            span: TimeSpan(
                start: base.addingTimeInterval(18 * 60),
                end: base.addingTimeInterval(30 * 60)
            ),
            distanceMeters: 600,
            confidence: .medium,
            evidence: ["iPhone Core Motion 기록"]
        )

        let resolved = AppleDeviceGroundTruthEngine.resolvingOverlaps(
            [first, second]
        )

        XCTAssertEqual(resolved.count, 2)
        XCTAssertEqual(resolved[1].mode, .walking)
        XCTAssertEqual(resolved[1].span.start, first.span.end)
        XCTAssertNil(
            resolved[0].span.intersection(with: resolved[1].span)
        )
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

    func testSleepAnalysisBuildsOneSessionWithoutDoubleCountingOverlaps() {
        let base = makeDate(2026, 7, 30, 22, 0)
        let segments = [
            SleepSegment(
                stage: .inBed,
                span: TimeSpan(start: base, end: base.addingTimeInterval(8.5 * hour)),
                sourceName: "iPhone"
            ),
            SleepSegment(
                stage: .core,
                span: TimeSpan(
                    start: base.addingTimeInterval(0.5 * hour),
                    end: base.addingTimeInterval(3 * hour)
                ),
                sourceName: "Apple Watch"
            ),
            SleepSegment(
                stage: .deep,
                span: TimeSpan(
                    start: base.addingTimeInterval(3 * hour),
                    end: base.addingTimeInterval(4 * hour)
                ),
                sourceName: "Apple Watch"
            ),
            SleepSegment(
                stage: .core,
                span: TimeSpan(
                    start: base.addingTimeInterval(4 * hour),
                    end: base.addingTimeInterval(6 * hour)
                ),
                sourceName: "Apple Watch"
            ),
            SleepSegment(
                stage: .rem,
                span: TimeSpan(
                    start: base.addingTimeInterval(6 * hour),
                    end: base.addingTimeInterval(7 * hour)
                ),
                sourceName: "Apple Watch"
            ),
            SleepSegment(
                stage: .awake,
                span: TimeSpan(
                    start: base.addingTimeInterval(7 * hour),
                    end: base.addingTimeInterval(7.25 * hour)
                ),
                sourceName: "Apple Watch"
            ),
            SleepSegment(
                stage: .rem,
                span: TimeSpan(
                    start: base.addingTimeInterval(7.25 * hour),
                    end: base.addingTimeInterval(8 * hour)
                ),
                sourceName: "Apple Watch"
            ),
            SleepSegment(
                stage: .asleepUnspecified,
                span: TimeSpan(
                    start: base.addingTimeInterval(0.5 * hour),
                    end: base.addingTimeInterval(8 * hour)
                ),
                sourceName: "iPhone"
            )
        ]

        let sessions = SleepAnalysisEngine().sessions(from: segments)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].asleepDuration, 7.25 * hour)
        XCTAssertEqual(sessions[0].awakeDuration, 0.25 * hour)
        XCTAssertEqual(sessions[0].inBedDuration, 8.5 * hour)
        XCTAssertEqual(sessions[0].stageDurations[.deep], hour)
        XCTAssertEqual(sessions[0].sourceNames, ["iPhone", "Apple Watch"])
        XCTAssertEqual(
            sessions[0].sleepEfficiency ?? 0,
            7.25 / 8.5,
            accuracy: 0.0001
        )
    }

    func testSleepAnalysisSeparatesNapFromNightSleep() {
        let base = makeDate(2026, 7, 30, 1, 0)
        let segments = [
            SleepSegment(
                stage: .core,
                span: TimeSpan(start: base, end: base.addingTimeInterval(6 * hour)),
                sourceName: "Apple Watch"
            ),
            SleepSegment(
                stage: .asleepUnspecified,
                span: TimeSpan(
                    start: base.addingTimeInterval(12 * hour),
                    end: base.addingTimeInterval(13 * hour)
                ),
                sourceName: "iPhone"
            )
        ]
        XCTAssertEqual(
            SleepAnalysisEngine().sessions(from: segments).count,
            2
        )
    }

    func testSensorArchivePersistsMotionAndPrunesOldReadings() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("taption-sensors-\(UUID().uuidString)")
        let fileURL = directory.appendingPathComponent("readings.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }

        let archive = SensorReadingArchive(
            fileURL: fileURL,
            retentionInterval: 86_400
        )
        let now = makeDate(2026, 7, 30, 12, 0)
        let motion = DeviceMotionSnapshot(
            gravity: SensorVector3(x: 0, y: 0, z: -1),
            userAcceleration: SensorVector3(x: 0.1, y: 0, z: 0),
            rotationRate: SensorVector3(x: 0, y: 0.2, z: 0),
            attitudeRadians: SensorVector3(x: 0, y: 0, z: 1)
        )
        try await archive.append(
            SensorReading(
                timestamp: now.addingTimeInterval(-2 * 86_400),
                motion: .walking,
                stepCount: 100
            ),
            now: now
        )
        try await archive.append(
            SensorReading(
                timestamp: now,
                motion: .running,
                stepCount: 220,
                deviceMotion: motion
            ),
            now: now
        )
        try await archive.compact(now: now)

        let restored = try await archive.readings(
            in: TimeSpan(
                start: now.addingTimeInterval(-3 * 86_400),
                end: now.addingTimeInterval(hour)
            )
        )
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].motion, .running)
        XCTAssertEqual(restored[0].stepCount, 220)
        XCTAssertEqual(restored[0].deviceMotion, motion)
    }

    func testRawDeviceDataArchiveStoresMonthlyCompressedPayloads() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("taption-raw-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let archive = RawDeviceDataMonthlyArchive(rootDirectory: directory)
        let july = makeDate(2026, 7, 31, 5, 42)
        let august = makeDate(2026, 8, 1, 0, 5)
        let reading = SensorReading(
            timestamp: july,
            point: GeoPoint(
                latitude: 37.524,
                longitude: 126.673,
                altitude: 42,
                horizontalAccuracy: 9,
                verticalAccuracy: 12
            ),
            motion: .automotive,
            stepCount: 33
        )
        try archive.append(
            source: .gps,
            kind: "sensor-reading",
            payload: reading,
            capturedAt: july
        )
        let watchPayload = RawArchiveWatchFixture(sampleCount: 12, mode: "car")
        try archive.append(
            source: .appleWatch,
            kind: "watch-sensor-summary",
            payload: watchPayload,
            capturedAt: august
        )

        let julyValues = try archive.envelopes(inMonthContaining: july)
        let augustValues = try archive.envelopes(inMonthContaining: august)
        XCTAssertEqual(julyValues.count, 1)
        XCTAssertEqual(julyValues[0].source, .gps)
        XCTAssertEqual(julyValues[0].kind, "sensor-reading")
        XCTAssertTrue(julyValues[0].payloadJSON.contains("\"automotive\""))
        XCTAssertEqual(augustValues.count, 1)
        XCTAssertEqual(augustValues[0].source, .appleWatch)
        try archive.flushPendingWrites()
        let chunks = directory
            .appendingPathComponent("2026-08")
            .appendingPathComponent("chunks")
        let chunkFiles = try FileManager.default.contentsOfDirectory(
            at: chunks,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(chunkFiles.contains { $0.pathExtension == "zlib" })
    }

    func testRawDeviceDataArchiveDoesNotRewriteLegacyMonthlyFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("taption-raw-legacy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let monthDirectory = directory.appendingPathComponent("2026-08")
        try FileManager.default.createDirectory(
            at: monthDirectory,
            withIntermediateDirectories: true
        )
        let date = makeDate(2026, 8, 1, 12)
        let legacyEnvelope = try RawDeviceDataEnvelope(
            capturedAt: date,
            source: .gps,
            kind: "legacy",
            payload: RawArchiveWatchFixture(sampleCount: 1, mode: "walk")
        )
        var legacyPayload = try RawDeviceDataMonthlyArchive
            .payloadEncoder()
            .encode(legacyEnvelope)
        legacyPayload.append(0x0A)
        let legacyData = try (legacyPayload as NSData).compressed(
            using: .zlib
        ) as Data
        let legacyURL = monthDirectory.appendingPathComponent(
            "taption-raw-2026-08.jsonl.zlib"
        )
        try legacyData.write(to: legacyURL)

        let archive = RawDeviceDataMonthlyArchive(
            rootDirectory: directory,
            flushDelay: 3_600
        )
        try archive.append(
            source: .healthKit,
            kind: "new",
            payload: RawArchiveWatchFixture(sampleCount: 2, mode: "run"),
            capturedAt: date.addingTimeInterval(60)
        )
        try archive.flushPendingWrites()

        XCTAssertEqual(try Data(contentsOf: legacyURL), legacyData)
        XCTAssertEqual(
            try archive.envelopes(inMonthContaining: date).map(\.kind),
            ["legacy", "new"]
        )
    }

    func testTrackingSessionArchiveWritesIndependentCompressedChunks() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("taption-session-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = TrackingSessionChunkArchive(rootDirectory: directory)
        let sessionID = UUID()
        let start = makeDate(2026, 8, 1, 9, 0)
        try archive.append(
            SensorReading(
                timestamp: start,
                motion: .walking,
                trackingSessionID: sessionID,
                trackingKind: .walking,
                sourceDevice: .iPhone,
                sequence: 1
            )
        )
        try archive.append(
            SensorReading(
                timestamp: start.addingTimeInterval(12),
                motion: .walking,
                trackingSessionID: sessionID,
                trackingKind: .walking,
                sourceDevice: .iPhone,
                sequence: 2,
                trackingSessionEnded: true
            )
        )
        let file = directory
            .appendingPathComponent("2026-08")
            .appendingPathComponent(sessionID.uuidString)
            .appendingPathComponent("000001.jsonl.zlib")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let compressed = try Data(contentsOf: file)
        let payload = try (compressed as NSData).decompressed(using: .zlib) as Data
        XCTAssertEqual(payload.split(separator: 0x0A).count, 2)
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

    func testWatchCollectionAndDataSyncProfilesAreIndependent() throws {
        XCTAssertEqual(
            TaptionWatchAccelerationProfile.batterySaver.interval,
            15 * 60
        )
        XCTAssertEqual(
            TaptionWatchAccelerationProfile.accuracy.interval,
            60
        )
        XCTAssertEqual(
            TaptionWatchDataSyncProfile.balanced.interval,
            5 * 60
        )
        XCTAssertNil(TaptionWatchDataSyncProfile.off.intervalMinutes)

        let settings = TaptionWatchAccelerationSettings(
            profile: .accuracy,
            samplingWindowSeconds: 90
        )
        XCTAssertEqual(settings.samplingWindowSeconds, 60)
        XCTAssertTrue(settings.isEnabled)

        let data = try JSONEncoder().encode(
            TaptionWatchPayload(
                generatedAt: .now,
                viewportStart: .now,
                viewportEnd: .now,
                items: [],
                catStyle: "calico",
                reducesMotion: false,
                accelerationSettings: settings,
                dataSyncProfile: .batterySaver,
                locationTrackingEnabled: true,
                locationPermissionState: PermissionState.authorized.rawValue
            )
        )
        let decoded = try JSONDecoder().decode(
            TaptionWatchPayload.self,
            from: data
        )
        XCTAssertEqual(decoded.accelerationSettings, settings)
        XCTAssertEqual(decoded.dataSyncProfile, .batterySaver)
        XCTAssertEqual(decoded.locationTrackingEnabled, true)
        XCTAssertEqual(
            decoded.locationPermissionState,
            PermissionState.authorized.rawValue
        )
    }

    func testAutomaticTrackingPromotionAndStopPolicy() {
        XCTAssertFalse(
            TrackingSessionPolicy.shouldAutomaticallyStart(
                motion: .walking,
                confidence: .medium,
                sustainedFor: 9.9
            )
        )
        XCTAssertTrue(
            TrackingSessionPolicy.shouldAutomaticallyStart(
                motion: .walking,
                confidence: .medium,
                sustainedFor: 10
            )
        )
        XCTAssertTrue(
            TrackingSessionPolicy.shouldAutomaticallyStart(
                motion: .running,
                confidence: .high,
                sustainedFor: 15
            )
        )
        XCTAssertFalse(
            TrackingSessionPolicy.shouldAutomaticallyStart(
                motion: .automotive,
                confidence: .high,
                sustainedFor: 30
            )
        )
        XCTAssertFalse(
            TrackingSessionPolicy.shouldAutomaticallyStop(
                motion: .stationary,
                stationaryFor: 119
            )
        )
        XCTAssertTrue(
            TrackingSessionPolicy.shouldAutomaticallyStop(
                motion: .stationary,
                stationaryFor: 120
            )
        )
        XCTAssertEqual(TrackingSessionPolicy.activeDistanceFilterMeters, 5)
        XCTAssertEqual(TrackingSessionPolicy.activeHorizontalAccuracyLimit, 50)
    }

    func testHealthRefreshUsesFiveMinuteForegroundAndImmediateBackgroundPolicy() {
        XCTAssertEqual(
            HealthRefreshPolicy.foregroundInterval,
            5 * 60
        )
        XCTAssertEqual(
            HealthRefreshPolicy.periodicLookback,
            2 * 86_400
        )
        XCTAssertEqual(
            HealthRefreshPolicy.backgroundFrequency,
            .immediate
        )
    }

    func testAppleDeviceMotionHistoryOverridesAppSensorEstimate() {
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

        let result = AppleDeviceGroundTruthEngine.applyingMotionHistory(
            to: readings,
            activities: activities
        )

        XCTAssertEqual(result[0].motion, .running)
        XCTAssertEqual(result[0].motionConfidence, .high)
        XCTAssertEqual(result[1].motion, .walking)
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

    func testHealthKitRefreshReplacesOnlyHealthKitGroundTruthWindow() {
        let base = makeDate(2026, 7, 30, 9, 0)
        let span = TimeSpan(
            start: base,
            end: base.addingTimeInterval(24 * hour)
        )
        let manual = ActualRecord(
            planID: nil,
            title: "직접 기록",
            categoryID: "exercise",
            startedAt: base,
            endedAt: base.addingTimeInterval(hour),
            source: .manual
        )
        let staleHealth = ActualRecord(
            planID: nil,
            title: "이전 Watch 기록",
            categoryID: "exercise",
            startedAt: base.addingTimeInterval(2 * hour),
            endedAt: base.addingTimeInterval(3 * hour),
            source: .healthKit
        )
        let freshHealth = ActualRecord(
            planID: nil,
            title: "새 Watch 기록",
            categoryID: "exercise",
            startedAt: base.addingTimeInterval(4 * hour),
            endedAt: base.addingTimeInterval(5 * hour),
            source: .healthKit
        )

        let result = AppleDeviceGroundTruthEngine
            .replacingHealthKitActuals(
                existing: [manual, staleHealth],
                with: [freshHealth, freshHealth],
                inside: span
            )

        XCTAssertTrue(result.contains(manual))
        XCTAssertFalse(result.contains(staleHealth))
        XCTAssertEqual(
            result.filter { $0.source == .healthKit },
            [freshHealth]
        )
    }

    func testLinkedWatchWorkoutSupersedesItsTimerActual() {
        let base = makeDate(2026, 7, 30, 9, 0)
        let planID = UUID()
        let timer = ActualRecord(
            planID: planID,
            title: "아침 달리기",
            categoryID: "exercise",
            startedAt: base,
            endedAt: base.addingTimeInterval(30 * 60),
            source: .timer
        )
        let otherTimer = ActualRecord(
            planID: UUID(),
            title: "다른 계획",
            categoryID: "project",
            startedAt: base,
            endedAt: base.addingTimeInterval(30 * 60),
            source: .timer
        )
        let watchWorkout = ActualRecord(
            planID: planID,
            title: "아침 달리기",
            categoryID: "exercise",
            startedAt: base.addingTimeInterval(20),
            endedAt: base.addingTimeInterval(31 * 60),
            source: .healthKit
        )

        let result = AppleDeviceGroundTruthEngine.replacingHealthKitActuals(
            existing: [timer, otherTimer],
            with: [watchWorkout],
            inside: TimeSpan(
                start: base.addingTimeInterval(-60),
                end: base.addingTimeInterval(60 * 60)
            )
        )

        XCTAssertFalse(result.contains(timer))
        XCTAssertTrue(result.contains(otherTimer))
        XCTAssertTrue(result.contains(watchWorkout))
    }

    func testWatchPayloadAndCommandRoundTrip() throws {
        let planID = UUID()
        let command = TaptionWatchCommand(
            planID: planID,
            kind: .postponeThirtyMinutes
        )
        let commandData = try JSONEncoder().encode(command)
        XCTAssertEqual(
            try JSONDecoder().decode(
                TaptionWatchCommand.self,
                from: commandData
            ),
            command
        )

        let base = makeDate(2026, 7, 30, 9, 0)
        let payload = TaptionWatchPayload(
            generatedAt: base,
            viewportStart: base,
            viewportEnd: base.addingTimeInterval(24 * hour),
            items: [
                TaptionWatchPlanItem(
                    id: planID,
                    title: "워치 연동",
                    categoryID: "project",
                    startsAt: base,
                    endsAt: base.addingTimeInterval(hour),
                    status: PlanStatus.planned.rawValue,
                    actualStartedAt: nil,
                    categoryName: "프로젝트",
                    categoryHex: "#5C81B1"
                )
            ],
            catStyle: CatStyle.calico.rawValue,
            reducesMotion: false,
            todaySummary: TaptionWatchDaySummary(
                date: base,
                scheduledCount: 3,
                completedCount: 1,
                recordedMinutes: 95,
                activeMinutes: 40
            )
        )
        let payloadData = try JSONEncoder().encode(payload)
        XCTAssertEqual(
            try JSONDecoder().decode(
                TaptionWatchPayload.self,
                from: payloadData
            ),
            payload
        )
    }

    func testWatchLiveItemPolicyDropsPastItemsAndKeepsParallelCurrentItems() {
        let now = makeDate(2026, 8, 1, 10, 0)
        let past = TaptionWatchPlanItem(
            id: UUID(),
            title: "지난 계획",
            categoryID: "project",
            startsAt: now.addingTimeInterval(-2 * hour),
            endsAt: now.addingTimeInterval(-hour),
            status: PlanStatus.planned.rawValue,
            actualStartedAt: nil,
            categoryName: "프로젝트",
            categoryHex: "#5C81B1"
        )
        let goal = TaptionWatchPlanItem(
            id: UUID(),
            title: "목표: 운동",
            categoryID: "exercise",
            startsAt: now.addingTimeInterval(-30 * 60),
            endsAt: now.addingTimeInterval(90 * 60),
            status: PlanStatus.planned.rawValue,
            actualStartedAt: nil,
            categoryName: "운동",
            categoryHex: "#4E8E63",
            isGoal: true
        )
        let plan = TaptionWatchPlanItem(
            id: UUID(),
            title: "달리기",
            categoryID: "exercise",
            startsAt: now,
            endsAt: now.addingTimeInterval(30 * 60),
            status: PlanStatus.running.rawValue,
            actualStartedAt: now,
            categoryName: "운동",
            categoryHex: "#4E8E63",
            parentID: goal.id
        )
        let completed = TaptionWatchPlanItem(
            id: UUID(),
            title: "완료된 계획",
            categoryID: "project",
            startsAt: now.addingTimeInterval(-15 * 60),
            endsAt: now.addingTimeInterval(15 * 60),
            status: PlanStatus.completed.rawValue,
            actualStartedAt: nil,
            categoryName: "프로젝트",
            categoryHex: "#5C81B1"
        )
        let upcoming = TaptionWatchPlanItem(
            id: UUID(),
            title: "다음 계획",
            categoryID: "project",
            startsAt: now.addingTimeInterval(2 * hour),
            endsAt: now.addingTimeInterval(3 * hour),
            status: PlanStatus.planned.rawValue,
            actualStartedAt: nil,
            categoryName: "프로젝트",
            categoryHex: "#5C81B1"
        )

        let items = [past, goal, plan, completed, upcoming]
        XCTAssertEqual(
            TaptionWatchLiveItemPolicy.current(items, at: now).map(\.id),
            [goal.id, plan.id]
        )
        XCTAssertEqual(
            TaptionWatchLiveItemPolicy.upcoming(items, at: now).map(\.id),
            [upcoming.id]
        )
        XCTAssertFalse(TaptionWatchLiveItemPolicy.isLive(past, at: now))
        XCTAssertFalse(
            TaptionWatchLiveItemPolicy.isLive(completed, at: now)
        )
    }

    func testWatchPlanItemDecodesPayloadWithoutNewGoalFields() throws {
        let id = UUID()
        let base = makeDate(2026, 8, 1, 10)
        let legacy: [String: Any] = [
            "id": id.uuidString,
            "title": "기존 워치 계획",
            "categoryID": "project",
            "startsAt": base.timeIntervalSince1970,
            "endsAt": base.addingTimeInterval(hour).timeIntervalSince1970,
            "status": PlanStatus.planned.rawValue,
            "categoryName": "프로젝트",
            "categoryHex": "#5C81B1"
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let item = try decoder.decode(TaptionWatchPlanItem.self, from: data)
        XCTAssertFalse(item.isGoal)
        XCTAssertNil(item.parentID)
        XCTAssertEqual(item.id, id)
    }

    func testWatchDaySummaryMergesOverlappingActuals() {
        let base = makeDate(2026, 7, 30, 9)
        let plans = [
            PlanRecord(
                title: "완료한 계획",
                span: TimeSpan(
                    start: base,
                    end: base.addingTimeInterval(hour)
                ),
                categoryID: "project",
                status: .completed
            ),
            PlanRecord(
                title: "다음 계획",
                span: TimeSpan(
                    start: base.addingTimeInterval(2 * hour),
                    end: base.addingTimeInterval(3 * hour)
                ),
                categoryID: "study"
            ),
            PlanRecord(
                title: "건너뛴 계획",
                span: TimeSpan(
                    start: base,
                    end: base.addingTimeInterval(hour)
                ),
                categoryID: "hobby",
                status: .skipped
            ),
        ]
        let actuals = [
            ActualRecord(
                planID: nil,
                title: "걷기",
                categoryID: "movement",
                startedAt: base,
                endedAt: base.addingTimeInterval(hour),
                source: .appleWatch
            ),
            ActualRecord(
                planID: nil,
                title: "운동",
                categoryID: "exercise",
                startedAt: base.addingTimeInterval(30 * 60),
                endedAt: base.addingTimeInterval(90 * 60),
                source: .healthKit
            ),
            ActualRecord(
                planID: nil,
                title: "업무",
                categoryID: "project",
                startedAt: base.addingTimeInterval(3 * hour),
                endedAt: base.addingTimeInterval(4 * hour),
                source: .timer
            ),
        ]

        let summary = TaptionWatchDaySummaryFactory.make(
            plans: plans,
            actuals: actuals,
            at: base.addingTimeInterval(6 * hour),
            calendar: utcCalendar
        )

        XCTAssertEqual(summary.scheduledCount, 2)
        XCTAssertEqual(summary.completedCount, 1)
        XCTAssertEqual(summary.recordedMinutes, 150)
        XCTAssertEqual(summary.activeMinutes, 90)
    }

    func testWatchSensorSummaryRoundTripCreatesOneActivityAndHealthReplacesIt()
        throws {
        let base = makeDate(2026, 7, 30, 9, 0)
        let plan = PlanRecord(
            title: "출근 달리기",
            span: TimeSpan(
                start: base,
                end: base.addingTimeInterval(30 * 60)
            ),
            categoryID: "exercise"
        )
        let summary = TaptionWatchSensorSummary(
            sessionID: UUID(),
            sequence: 2,
            workoutKind: .running,
            linkedPlanID: plan.id,
            linkedPlanTitle: plan.title,
            linkedCategoryID: plan.categoryID,
            startedAt: base,
            endedAt: base.addingTimeInterval(30 * 60),
            isFinal: true,
            accelerometerSampleCount: 18_000,
            accelerometerAverageG: TaptionWatchSensorVector3(
                x: 0.1,
                y: -0.2,
                z: 0.9
            ),
            peakAccelerationG: 2.4,
            gyroscopeSampleCount: 18_000,
            gyroscopeAverageRadiansPerSecond: TaptionWatchSensorVector3(
                x: 0.2,
                y: 0.1,
                z: -0.1
            ),
            peakRotationRateRadiansPerSecond: 3.1,
            gravity: TaptionWatchSensorVector3(x: 0, y: 0, z: -1),
            userAccelerationG: TaptionWatchSensorVector3(
                x: 0.1,
                y: 0.2,
                z: 0.3
            ),
            rotationRateRadiansPerSecond: TaptionWatchSensorVector3(
                x: 0.2,
                y: 0.3,
                z: 0.4
            ),
            attitudeRadians: TaptionWatchSensorVector3(
                x: 0.3,
                y: 0.4,
                z: 0.5
            ),
            relativeAltitudeMeters: 8.4,
            pressureKilopascals: 100.8,
            stepCount: 3_210,
            distanceMeters: 4_800,
            floorsAscended: 2,
            floorsDescended: 1,
            latestHeartRate: 154,
            averageHeartRate: 146,
            maximumHeartRate: 171,
            activeEnergyKilocalories: 280
        )

        let encoded = try JSONEncoder().encode(summary)
        XCTAssertEqual(
            try JSONDecoder().decode(
                TaptionWatchSensorSummary.self,
                from: encoded
            ),
            summary
        )

        let watchActuals = AppleWatchSensorActivityEngine.upserting(
            summary,
            into: [],
            linkedPlan: plan
        )
        let repeated = AppleWatchSensorActivityEngine.upserting(
            summary,
            into: watchActuals,
            linkedPlan: plan
        )
        XCTAssertEqual(repeated.count, 1)
        XCTAssertEqual(repeated[0].id, summary.sessionID)
        XCTAssertEqual(repeated[0].source, .appleWatch)
        XCTAssertEqual(repeated[0].planID, plan.id)

        let healthActual = ActualRecord(
            id: summary.sessionID,
            planID: plan.id,
            title: plan.title,
            categoryID: plan.categoryID,
            startedAt: summary.startedAt,
            endedAt: summary.endedAt,
            source: .healthKit
        )
        let reconciled = AppleDeviceGroundTruthEngine
            .replacingHealthKitActuals(
                existing: repeated,
                with: [healthActual],
                inside: TimeSpan(
                    start: base.addingTimeInterval(-60),
                    end: base.addingTimeInterval(hour)
                )
            )
        XCTAssertEqual(reconciled, [healthActual])
    }

    func testWatchBehaviorRulesPrioritizeWorkoutAndDetectStairs() {
        let workout = WatchBehaviorClassifier.classify(
            WatchBehaviorInput(
                workoutKind: .running,
                duration: 30,
                steps: 20
            )
        )
        XCTAssertEqual(workout.kind, .running)
        XCTAssertGreaterThan(workout.confidenceScore, 0.9)
        XCTAssertTrue(workout.evidence.contains("Apple Watch 운동 종류"))

        let stairs = WatchBehaviorClassifier.classify(
            WatchBehaviorInput(
                duration: 120,
                accelerometerSampleCount: 3_000,
                accelerometerStandardDeviationG: 0.12,
                accelerometerMeanJerkGPerSecond: 0.3,
                steps: 140,
                floorsAscended: 3,
                altitudeDeltaMeters: 9
            )
        )
        XCTAssertEqual(stairs.kind, .stairsUp)
        XCTAssertTrue(stairs.evidence.contains("걸음·층수 증가"))
    }

    func testWatchHARWindowExtractsPeriodicWalkingFeatures() throws {
        let start = makeDate(2026, 8, 2, 9)
        let samples = (0..<65).map { index in
            let elapsed = Double(index) / 25
            let wave = sin(2 * .pi * 1.8 * elapsed) * 0.14
            return WatchMotionSample(
                capturedAt: start.addingTimeInterval(elapsed),
                acceleration: TaptionWatchSensorVector3(
                    x: 0,
                    y: 0,
                    z: 1 + wave
                ),
                rotationRate: TaptionWatchSensorVector3(x: 0.2, y: 0, z: 0),
                gravity: TaptionWatchSensorVector3(x: 0, y: 0, z: 1)
            )
        }
        let features = try XCTUnwrap(
            WatchBehaviorWindowAnalyzer.features(from: samples)
        )
        XCTAssertGreaterThan(features.bodyAccelerationRMSG, 0.05)
        XCTAssertGreaterThan(features.dominantFrequencyHz ?? 0, 1.2)
        XCTAssertLessThan(features.dominantFrequencyHz ?? 0, 4.2)

        let inference = WatchBehaviorClassifier.classifyWindow(
            features,
            context: WatchBehaviorInput(
                duration: features.duration,
                accelerometerSampleCount: features.sampleCount,
                steps: 3,
                gpsAvailable: false
            )
        )
        XCTAssertEqual(inference.kind, .walking)
        XCTAssertTrue(inference.evidence.contains("IMU 보행 주기"))
        XCTAssertEqual(inference.modelVersion, WatchBehaviorClassifier.rulesVersion)
    }

    func testWatchHARWindowDistinguishesFineHandBehaviors() {
        let typing = WatchBehaviorClassifier.classify(
            WatchBehaviorInput(
                duration: 2.56,
                accelerometerSampleCount: 64,
                steps: 0,
                accelerationBodyRMSG: 0.06,
                accelerationZeroCrossingRateHz: 0.8,
                gyroscopeRMSG: 0.3
            )
        )
        XCTAssertEqual(typing.kind, .typing)

        let brushing = WatchBehaviorClassifier.classify(
            WatchBehaviorInput(
                duration: 2.56,
                accelerometerSampleCount: 64,
                steps: 0,
                accelerationBodyRMSG: 0.08,
                gyroscopeRMSG: 1.8
            )
        )
        XCTAssertEqual(brushing.kind, .brushingTeeth)
    }

    func testWatchHARWindowRefinesBroadWorkoutWithoutLosingFallback() throws {
        let start = makeDate(2026, 8, 2, 9)
        let samples = (0..<65).map { index in
            let elapsed = Double(index) / 25
            let wave = sin(2 * .pi * 1.8 * elapsed) * 0.14
            return WatchMotionSample(
                capturedAt: start.addingTimeInterval(elapsed),
                acceleration: TaptionWatchSensorVector3(
                    x: 0,
                    y: 0,
                    z: 1 + wave
                ),
                rotationRate: nil,
                gravity: TaptionWatchSensorVector3(x: 0, y: 0, z: 1)
            )
        }
        let features = try XCTUnwrap(
            WatchBehaviorWindowAnalyzer.features(from: samples)
        )
        let refined = WatchBehaviorClassifier.classifyWindow(
            features,
            context: WatchBehaviorInput(
                workoutKind: .walking,
                duration: features.duration,
                steps: 3
            )
        )
        XCTAssertEqual(refined.kind, .walking)

        let fallback = WatchBehaviorClassifier.classifyWindow(
            WatchBehaviorWindowFeatures(
                startedAt: start,
                endedAt: start.addingTimeInterval(2.56),
                sampleCount: 64,
                sampleRateHz: 25,
                accelerationMeanG: 1,
                accelerationStandardDeviationG: 0,
                bodyAccelerationRMSG: 0,
                jerkRMSGPerSecond: 0,
                zeroCrossingRateHz: 0,
                dominantFrequencyHz: nil,
                gyroscopeRMSGPerSecond: 0,
                posturePitchRadians: 0,
                postureRollRadians: 0
            ),
            context: WatchBehaviorInput(
                workoutKind: .cycling,
                duration: 2.56
            )
        )
        XCTAssertEqual(fallback.kind, .cycling)
    }

    func testWatchHARFeatureVectorAndTemporalAggregation() throws {
        let start = makeDate(2026, 8, 2, 9)
        let samples = (0..<65).map { index in
            let elapsed = Double(index) / 25
            let wave = sin(2 * .pi * 1.8 * elapsed) * 0.14
            return WatchMotionSample(
                capturedAt: start.addingTimeInterval(elapsed),
                acceleration: TaptionWatchSensorVector3(
                    x: 0,
                    y: 0,
                    z: 1 + wave
                ),
                rotationRate: nil,
                gravity: TaptionWatchSensorVector3(x: 0, y: 0, z: 1)
            )
        }
        let features = try XCTUnwrap(
            WatchBehaviorWindowAnalyzer.features(from: samples)
        )
        XCTAssertEqual(
            features.featureVector.count,
            12
        )
        XCTAssertEqual(
            WatchBehaviorWindowFeatures.featureSchemaVersion,
            "watch-har-window-v1"
        )
        XCTAssertEqual(
            WatchBehaviorKind.fromModelLabel("달리기"),
            .running
        )
        XCTAssertEqual(
            WatchBehaviorKind.fromModelLabel("stairsUp"),
            .stairsUp
        )

        let walking = WatchBehaviorSegment(
            startedAt: start,
            endedAt: start.addingTimeInterval(10),
            behavior: .walking,
            confidenceScore: 0.8,
            evidence: ["보행"],
            modelVersion: WatchBehaviorClassifier.rulesVersion
        )
        let stationary = WatchBehaviorSegment(
            startedAt: start.addingTimeInterval(10),
            endedAt: start.addingTimeInterval(18),
            behavior: .stationary,
            confidenceScore: 0.95,
            evidence: ["저진동"],
            modelVersion: WatchBehaviorClassifier.rulesVersion
        )
        let aggregate = WatchBehaviorClassifier.aggregate(
            [walking, stationary],
            fallback: WatchBehaviorInference(
                kind: .unknown,
                confidenceScore: 0.2,
                evidence: [],
                modelVersion: WatchBehaviorClassifier.rulesVersion
            )
        )
        XCTAssertEqual(aggregate.kind, .walking)
        XCTAssertTrue(aggregate.evidence.contains("시간 가중 집계"))
    }

    func testWatchSensorChunksUpdateTheSameImmutableActivity() {
        let base = makeDate(2026, 8, 2, 9)
        let sessionID = UUID()
        let first = TaptionWatchSensorSummary(
            sessionID: sessionID,
            sequence: 1,
            workoutKind: .walking,
            linkedPlanID: nil,
            linkedPlanTitle: nil,
            linkedCategoryID: nil,
            startedAt: base,
            endedAt: base.addingTimeInterval(30),
            isFinal: false,
            accelerometerSampleCount: 750,
            accelerometerAverageG: nil,
            peakAccelerationG: 0.9,
            gyroscopeSampleCount: 0,
            gyroscopeAverageRadiansPerSecond: nil,
            peakRotationRateRadiansPerSecond: nil,
            gravity: nil,
            userAccelerationG: nil,
            rotationRateRadiansPerSecond: nil,
            attitudeRadians: nil,
            relativeAltitudeMeters: nil,
            pressureKilopascals: nil,
            stepCount: 40,
            distanceMeters: 30,
            floorsAscended: nil,
            floorsDescended: nil,
            latestHeartRate: 90,
            averageHeartRate: 88,
            maximumHeartRate: 95,
            activeEnergyKilocalories: 4,
            behavior: .walking,
            behaviorConfidenceScore: 0.8,
            behaviorEvidence: ["걸음"],
            behaviorModelVersion: WatchBehaviorClassifier.rulesVersion
        )
        let second = TaptionWatchSensorSummary(
            sessionID: sessionID,
            sequence: 2,
            workoutKind: .walking,
            linkedPlanID: nil,
            linkedPlanTitle: nil,
            linkedCategoryID: nil,
            startedAt: base,
            endedAt: base.addingTimeInterval(90),
            isFinal: true,
            accelerometerSampleCount: 2_250,
            accelerometerAverageG: nil,
            peakAccelerationG: 1.1,
            gyroscopeSampleCount: 0,
            gyroscopeAverageRadiansPerSecond: nil,
            peakRotationRateRadiansPerSecond: nil,
            gravity: nil,
            userAccelerationG: nil,
            rotationRateRadiansPerSecond: nil,
            attitudeRadians: nil,
            relativeAltitudeMeters: nil,
            pressureKilopascals: nil,
            stepCount: 130,
            distanceMeters: 100,
            floorsAscended: nil,
            floorsDescended: nil,
            latestHeartRate: 98,
            averageHeartRate: 92,
            maximumHeartRate: 105,
            activeEnergyKilocalories: 14,
            behavior: .walking,
            behaviorConfidenceScore: 0.9,
            behaviorEvidence: ["걸음"],
            behaviorModelVersion: WatchBehaviorClassifier.rulesVersion
        )
        let firstActual = AppleWatchSensorActivityEngine.upserting(
            first,
            into: [],
            linkedPlan: nil
        )
        let finalActual = AppleWatchSensorActivityEngine.upserting(
            second,
            into: firstActual,
            linkedPlan: nil
        )
        XCTAssertEqual(finalActual.count, 1)
        XCTAssertEqual(finalActual[0].endedAt, second.endedAt)
        XCTAssertEqual(finalActual[0].behavior, WatchBehaviorKind.walking.rawValue)
        XCTAssertEqual(finalActual[0].modelVersion, WatchBehaviorClassifier.rulesVersion)
    }

    func testAmbientWatchMotionAtHomeCreatesHouseworkRecord() {
        let base = makeDate(2026, 8, 2, 14)
        let sessionID = UUID()
        let first = TaptionWatchSensorSummary(
            sessionID: sessionID,
            sequence: 1,
            workoutKind: .walking,
            linkedPlanID: nil,
            linkedPlanTitle: nil,
            linkedCategoryID: nil,
            startedAt: base,
            endedAt: base.addingTimeInterval(30),
            isFinal: false,
            accelerometerSampleCount: 150,
            accelerometerAverageG: nil,
            peakAccelerationG: 1.2,
            accelerometerStandardDeviationG: 0.08,
            accelerometerMeanJerkGPerSecond: 0.2,
            gyroscopeSampleCount: 0,
            gyroscopeAverageRadiansPerSecond: nil,
            peakRotationRateRadiansPerSecond: nil,
            gravity: nil,
            userAccelerationG: nil,
            rotationRateRadiansPerSecond: nil,
            attitudeRadians: nil,
            relativeAltitudeMeters: nil,
            pressureKilopascals: nil,
            stepCount: nil,
            distanceMeters: nil,
            floorsAscended: nil,
            floorsDescended: nil,
            latestHeartRate: nil,
            averageHeartRate: nil,
            maximumHeartRate: nil,
            activeEnergyKilocalories: nil,
            behavior: .stationary,
            behaviorConfidenceScore: 0.7,
            behaviorEvidence: ["지속 움직임"],
            behaviorModelVersion: WatchBehaviorClassifier.rulesVersion,
            isAmbient: true
        )
        var second = first
        second.sequence = 2
        second.endedAt = base.addingTimeInterval(60)

        let firstActuals = AppleWatchSensorActivityEngine.upserting(
            first,
            into: [],
            linkedPlan: nil,
            atHome: true
        )
        let finalActuals = AppleWatchSensorActivityEngine.upserting(
            second,
            into: firstActuals,
            linkedPlan: nil,
            atHome: true
        )

        XCTAssertEqual(finalActuals.count, 1)
        XCTAssertEqual(finalActuals[0].title, "집안일")
        XCTAssertEqual(finalActuals[0].behavior, WatchBehaviorKind.housework.rawValue)
        XCTAssertEqual(finalActuals[0].endedAt, second.endedAt)

        let outsideHome = AppleWatchSensorActivityEngine.upserting(
            second,
            into: [],
            linkedPlan: nil,
            atHome: false
        )
        XCTAssertTrue(outsideHome.isEmpty)
    }

    func testWatchAsksAboutShowerFromHomeWaterLockAndMotion() throws {
        let base = makeDate(2026, 8, 9, 7)
        let summary = TaptionWatchSensorSummary(
            sessionID: UUID(),
            sequence: 1,
            workoutKind: .walking,
            linkedPlanID: nil,
            linkedPlanTitle: nil,
            linkedCategoryID: nil,
            startedAt: base,
            endedAt: base.addingTimeInterval(2 * 60),
            isFinal: true,
            accelerometerSampleCount: 1_500,
            accelerometerAverageG: nil,
            peakAccelerationG: 1.3,
            accelerometerStandardDeviationG: 0.08,
            accelerometerMeanJerkGPerSecond: 0.2,
            gyroscopeSampleCount: 0,
            gyroscopeAverageRadiansPerSecond: nil,
            peakRotationRateRadiansPerSecond: 1.2,
            gravity: nil,
            userAccelerationG: nil,
            rotationRateRadiansPerSecond: nil,
            attitudeRadians: nil,
            relativeAltitudeMeters: nil,
            pressureKilopascals: nil,
            stepCount: 0,
            distanceMeters: nil,
            floorsAscended: nil,
            floorsDescended: nil,
            latestHeartRate: nil,
            averageHeartRate: 82,
            maximumHeartRate: nil,
            activeEnergyKilocalories: nil,
            behavior: .housework,
            behaviorConfidenceScore: 0.62,
            behaviorEvidence: ["손목 움직임"],
            behaviorModelVersion: WatchBehaviorClassifier.rulesVersion,
            isAmbient: true,
            waterLockEnabled: true
        )

        let resolution = WatchActivityPersonalizationEngine.resolve(
            summary,
            atHome: true,
            learnedSamples: [],
            now: base.addingTimeInterval(2 * 60)
        )
        let suggestion = try XCTUnwrap(resolution.suggestion)
        XCTAssertNil(resolution.learnedBehavior)
        XCTAssertEqual(suggestion.proposedBehavior, .showering)
        XCTAssertTrue(suggestion.alternativeBehaviors.contains(.housework))
        XCTAssertTrue(suggestion.evidence.contains("Water Lock 켜짐"))
    }

    func testThreeMatchingWatchConfirmationsEnableAutomaticClassification()
        throws {
        let pattern = WatchActivityPattern(
            duration: 120,
            accelerationVariationG: 0.08,
            jerkGPerSecond: 0.2,
            peakRotationRate: 1.2,
            stepsPerMinute: 0,
            averageHeartRate: 82,
            atHome: true,
            waterLockEnabled: true,
            observedBehavior: .housework
        )
        let samples = (0..<3).map { index in
            WatchActivityPatternSample(
                capturedAt: makeDate(2026, 8, 6 + index, 7),
                pattern: pattern,
                label: .showering
            )
        }

        let learned = try XCTUnwrap(
            WatchActivityPersonalizationEngine.learnedBehavior(
                for: pattern,
                samples: samples
            )
        )
        XCTAssertEqual(learned.kind, .showering)
        XCTAssertGreaterThanOrEqual(learned.confidenceScore, 0.8)
        XCTAssertTrue(learned.evidence.first?.contains("3회") == true)
    }

    func testWatchConfirmationUsesOnlyPredefinedActivities() {
        let choices = WatchBehaviorKind.confirmationChoices

        XCTAssertFalse(choices.isEmpty)
        XCTAssertFalse(choices.contains(.unknown))
        XCTAssertEqual(Set(choices).count, choices.count)
        XCTAssertTrue(choices.contains(.showering))
        XCTAssertTrue(choices.contains(.housework))
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

    func testTimelineRouteUsesSameClockCoordinates() {
        let base = makeDate(2026, 7, 30)
        let viewport = TimelineViewport(
            dayStart: base,
            visibleSpan: 10 * hour,
            horizontalOffset: 6 * hour,
            currentTime: base.addingTimeInterval(8 * hour)
        )
        XCTAssertEqual(
            TimelineCoordinateMapper.fraction(
                for: base.addingTimeInterval(8 * hour),
                in: viewport
            ),
            0.2,
            accuracy: 0.0001
        )
    }

    func testWidgetSnapshotAndCatMotion() {
        let base = makeDate(2026, 7, 30, 12, 0)
        let plan = PlanRecord(
            title: "현재 계획",
            span: TimeSpan(
                start: base.addingTimeInterval(-hour),
                end: base.addingTimeInterval(hour)
            ),
            categoryID: "project"
        )
        let snapshot = WidgetSnapshotFactory.make(
            plans: [plan],
            now: base,
            catStyle: .calico,
            hideSensitiveContent: true
        )
        XCTAssertTrue(snapshot.catIsRunning)
        XCTAssertTrue(snapshot.availableActions.isEmpty)
        XCTAssertEqual(
            CatMotionPolicy.resolve(
                style: .white,
                hasCurrentActivity: true,
                reduceMotion: true
            ).animationDuration,
            0
        )
    }

    func testWidgetPlaybackAlwaysKeepsAutomaticLanes() {
        let base = makeDate(2026, 8, 1, 12, 0)

        XCTAssertEqual(
            TaptionWidgetPlaybackEngine.lanes(
                for: [],
                at: base
            ),
            [.schedule, .location, .movement, .sleep, .activity, .appUsage]
        )

        let action = TaptionWidgetItem(
            id: UUID(),
            title: "여행 준비",
            categoryID: "travel",
            startsAt: base.addingTimeInterval(-30 * 60),
            endsAt: base.addingTimeInterval(30 * 60),
            status: "planned",
            isFixed: false,
            lane: .action
        )
        XCTAssertEqual(
            TaptionWidgetPlaybackEngine.lanes(
                for: [action],
                at: base
            ),
            [.schedule, .location, .movement, .sleep, .activity, .appUsage, .action]
        )
        XCTAssertEqual(
            TaptionWidgetPlaybackEngine.activeItems(
                in: .action,
                from: [action],
                at: base
            ),
            [action]
        )
    }

    func testWidgetPayloadIsAlwaysCurrentCenteredAtSixHours() {
        let now = makeDate(2026, 8, 1, 18, 0)
        var snapshot = TaptionDataSnapshot.empty
        snapshot.settings.locationEnabled = true
        snapshot.settings.permissions[.location] = .authorized
        let payload = TaptionWidgetPayloadFactory.make(
            from: snapshot,
            now: now
        )

        XCTAssertEqual(payload.displayCenterDate, now)
        XCTAssertEqual(
            payload.displayDuration,
            TaptionWidgetPlaybackEngine.defaultWindowDuration
        )
        XCTAssertEqual(
            payload.displayResolutionLabel,
            TaptionWidgetPlaybackEngine.defaultResolutionLabel
        )
        XCTAssertEqual(payload.displayDuration, 6 * hour)
        XCTAssertEqual(payload.locationTrackingEnabled, true)
        XCTAssertEqual(
            payload.locationPermissionState,
            PermissionState.authorized.rawValue
        )
        XCTAssertEqual(
            payload.sourceFingerprint,
            TaptionWidgetSyncFingerprint.make(items: payload.items)
        )

        let oldOffice = TaptionWidgetItem(
            id: UUID(),
            title: "회사",
            categoryID: "location",
            startsAt: now.addingTimeInterval(-6 * hour),
            endsAt: now.addingTimeInterval(-4 * hour),
            status: "recorded",
            isFixed: true,
            lane: .location
        )
        let currentHome = TaptionWidgetItem(
            id: UUID(),
            title: "집",
            categoryID: "location",
            startsAt: now.addingTimeInterval(-hour),
            endsAt: now.addingTimeInterval(hour),
            status: "recorded",
            isFixed: true,
            lane: .location
        )
        let oldMovement = TaptionWidgetItem(
            id: UUID(),
            title: "자가용",
            categoryID: "movement",
            startsAt: now.addingTimeInterval(-5 * hour),
            endsAt: now.addingTimeInterval(-4 * hour),
            status: "recorded",
            isFixed: true,
            lane: .movement
        )

        XCTAssertEqual(
            TaptionWidgetPlaybackEngine.visibleItems(
                in: .location,
                from: [oldOffice, currentHome, oldMovement],
                at: now
            ).map(\.title),
            ["집"]
        )
        XCTAssertTrue(
            TaptionWidgetPlaybackEngine.visibleItems(
                in: .movement,
                from: [oldOffice, currentHome, oldMovement],
                at: now
            ).isEmpty
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

    func testWidgetFingerprintStaysStableWhileHealthActivityIsOpen() {
        let startedAt = makeDate(2026, 8, 1, 18, 0)
        var snapshot = TaptionDataSnapshot.empty
        snapshot.updatedAt = startedAt
        snapshot.actuals = [
            ActualRecord(
                planID: nil,
                title: "걷기",
                categoryID: "walking",
                startedAt: startedAt.addingTimeInterval(-10 * 60),
                source: .healthKit
            ),
        ]

        let first = TaptionWidgetPayloadFactory.make(
            from: snapshot,
            now: startedAt
        )
        let later = TaptionWidgetPayloadFactory.make(
            from: snapshot,
            now: startedAt.addingTimeInterval(5 * 60)
        )

        XCTAssertEqual(first.sourceFingerprint, later.sourceFingerprint)
        XCTAssertEqual(
            TaptionWidgetSyncStatus.compare(
                groundTruth: later,
                cached: first
            ),
            .synchronized(first.generatedAt)
        )

        var savedLater = later
        savedLater.sourceSnapshotUpdatedAt = startedAt.addingTimeInterval(1)
        XCTAssertEqual(
            TaptionWidgetSyncStatus.compare(
                groundTruth: savedLater,
                cached: first
            ),
            .pending
        )
    }

    func testWidgetRejectsNewerLegacyCacheWithoutGroundTruthFingerprint() {
        let now = makeDate(2026, 8, 1, 18, 0)
        var groundTruth = TaptionWidgetPayloadFactory.make(
            from: .empty,
            now: now
        )
        groundTruth.sourceFingerprint = "ground-truth"
        var legacyCache = groundTruth
        legacyCache.generatedAt = now.addingTimeInterval(60)
        legacyCache.sourceFingerprint = nil
        legacyCache.items = [
            TaptionWidgetItem(
                id: UUID(),
                title: "회사",
                categoryID: "location",
                startsAt: now.addingTimeInterval(-hour),
                endsAt: now.addingTimeInterval(hour),
                status: "recorded",
                isFixed: true,
                lane: .location
            )
        ]

        XCTAssertEqual(
            TaptionWidgetPayloadSyncPolicy.freshest(
                groundTruth: groundTruth,
                cached: legacyCache
            ),
            groundTruth
        )

        var staleCache = groundTruth
        staleCache.generatedAt = now.addingTimeInterval(120)
        staleCache.sourceSnapshotUpdatedAt = now.addingTimeInterval(-hour)
        groundTruth.sourceSnapshotUpdatedAt = now
        XCTAssertEqual(
            TaptionWidgetPayloadSyncPolicy.freshest(
                groundTruth: groundTruth,
                cached: staleCache
            ),
            groundTruth
        )
    }

    func testWidgetGroundTruthWinsWhenFingerprintsDifferAtSameSourceRevision() {
        let now = makeDate(2026, 8, 1, 18, 0)
        var groundTruth = TaptionWidgetPayload.empty
        groundTruth.generatedAt = now
        groundTruth.sourceSnapshotUpdatedAt = now
        groundTruth.sourceFingerprint = "app-ground-truth"
        groundTruth.items = [
            TaptionWidgetItem(
                id: UUID(),
                title: "집",
                categoryID: "location",
                startsAt: now.addingTimeInterval(-hour),
                endsAt: now.addingTimeInterval(hour),
                status: "recorded",
                isFixed: true,
                lane: .location
            ),
        ]
        var cached = groundTruth
        cached.generatedAt = now.addingTimeInterval(60)
        cached.sourceFingerprint = "stale-cache"
        cached.items = []

        XCTAssertEqual(
            TaptionWidgetPayloadSyncPolicy.selectionReason(
                groundTruth: groundTruth,
                cached: cached
            ),
            .groundTruth
        )
        XCTAssertEqual(
            TaptionWidgetPayloadSyncPolicy.freshest(
                groundTruth: groundTruth,
                cached: cached
            ).items.map(\.title),
            ["집"]
        )
    }

    func testWidgetPayloadDecodesLegacyCacheWithoutSyncMetadata() throws {
        let payload = TaptionWidgetPayloadFactory.make(
            from: .empty,
            now: makeDate(2026, 8, 1, 18, 0)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let encoded = try encoder.encode(payload)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "sourceSnapshotUpdatedAt")
        object.removeValue(forKey: "sourceFingerprint")
        object.removeValue(forKey: "locationTrackingEnabled")
        object.removeValue(forKey: "locationPermissionState")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(
            TaptionWidgetPayload.self,
            from: legacyData
        )

        XCTAssertNil(decoded.sourceSnapshotUpdatedAt)
        XCTAssertNil(decoded.sourceFingerprint)
        XCTAssertNil(decoded.locationTrackingEnabled)
        XCTAssertNil(decoded.locationPermissionState)
    }

    func testWidgetAutomaticallyScrollsOverflowingRowsAndReturns() {
        let reference = Date(timeIntervalSinceReferenceDate: 0)

        XCTAssertEqual(
            TaptionWidgetAutoScrollEngine.progress(
                at: reference,
                rowCount: 4
            ),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            TaptionWidgetAutoScrollEngine.progress(
                at: reference.addingTimeInterval(2.5),
                rowCount: 5
            ),
            0.5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            TaptionWidgetAutoScrollEngine.offset(
                at: reference.addingTimeInterval(3.5),
                contentHeight: 100,
                viewportHeight: 80,
                rowCount: 5
            ),
            20,
            accuracy: 0.001
        )
        XCTAssertEqual(
            TaptionWidgetAutoScrollEngine.offset(
                at: reference.addingTimeInterval(3.5),
                contentHeight: 80,
                viewportHeight: 100,
                rowCount: 5
            ),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            TaptionWidgetAutoScrollEngine.progress(
                at: reference.addingTimeInterval(5.5),
                rowCount: 5
            ),
            0.5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            TaptionWidgetAutoScrollEngine.progress(
                at: reference.addingTimeInterval(60),
                rowCount: 5,
                reducesMotion: true
            ),
            1,
            accuracy: 0.001
        )
    }

    func testWidgetPlaybackUsesMinuteTicksAndExactItemBoundaries() {
        let base = makeDate(2026, 8, 1, 12, 0)
        let startsAt = base.addingTimeInterval(95)
        let endsAt = base.addingTimeInterval(185)
        let movement = TaptionWidgetItem(
            id: UUID(),
            title: "자가용",
            categoryID: "movement",
            startsAt: startsAt,
            endsAt: endsAt,
            status: "recorded",
            isFixed: true,
            lane: .movement
        )
        let dates = TaptionWidgetPlaybackEngine.timelineDates(
            for: [movement],
            from: base,
            horizon: base.addingTimeInterval(5 * 60)
        )

        XCTAssertTrue(dates.contains(base.addingTimeInterval(60)))
        XCTAssertTrue(dates.contains(startsAt))
        XCTAssertTrue(dates.contains(endsAt))
        XCTAssertEqual(dates, dates.sorted())
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

    func testCatPickerPreviewIncludesAndAnimatesEveryWidgetAction() {
        let reference = Date(timeIntervalSinceReferenceDate: 0)
        let actions = TaptionWidgetCatAction.allCases

        XCTAssertEqual(actions.count, 12)
        XCTAssertEqual(TaptionCatAnimationEngine.phaseCount, 6)
        XCTAssertEqual(Set(actions.map(\.previewTitle)).count, actions.count)
        XCTAssertTrue(actions.allSatisfy { !$0.previewSystemImage.isEmpty })

        let runningStart = TaptionWidgetCatPreviewEngine.pose(
            at: reference,
            action: .running
        )
        let runningEnd = TaptionWidgetCatPreviewEngine.pose(
            at: reference.addingTimeInterval(2),
            action: .running
        )
        let grooming = TaptionWidgetCatPreviewEngine.pose(
            at: reference.addingTimeInterval(0.2),
            action: .grooming
        )
        let reduced = TaptionWidgetCatPreviewEngine.pose(
            at: reference.addingTimeInterval(1.8),
            action: .fishingPlay,
            reducesMotion: true
        )

        XCTAssertEqual(runningStart.progress, 0, accuracy: 0.001)
        XCTAssertEqual(runningEnd.progress, 1, accuracy: 0.001)
        XCTAssertEqual(grooming.progress, 0.5, accuracy: 0.001)
        XCTAssertEqual(grooming.action, .grooming)
        XCTAssertNotEqual(grooming.headTiltDegrees, 0)
        XCTAssertEqual(reduced.progress, 0.5, accuracy: 0.001)
        XCTAssertEqual(reduced.action, .fishingPlay)
        XCTAssertEqual(reduced.tailSwing, 0, accuracy: 0.001)
        XCTAssertEqual(reduced.headTiltDegrees, 0, accuracy: 0.001)
    }

    func testCatFrameClocksSupportWatchSizedIntOverflowDates() {
        let currentEra = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let phases = 0...(TaptionCatAnimationEngine.phaseCount - 1)

        XCTAssertTrue(
            phases.contains(
                TaptionCatAnimationEngine.pose(at: currentEra).phase
            )
        )
        XCTAssertTrue(
            phases.contains(
                TaptionWidgetCatWalkEngine.pose(at: currentEra).legPhase
            )
        )
        XCTAssertTrue(
            phases.contains(
                TaptionWidgetCatPreviewEngine.pose(
                    at: currentEra,
                    action: .walking
                ).legPhase
            )
        )
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

    func testEveryCatActionHasFinitePoseAtEveryPhase() {
        let phases = Array(-3...(TaptionCatAnimationEngine.phaseCount + 3))

        for action in TaptionCatAnimationAction.allCases {
            for phase in phases {
                let motion = TaptionCatAnimationEngine.motionDetails(
                    for: action,
                    phase: phase
                )
                XCTAssertTrue(motion.tailSwing.isFinite, "\(action) \(phase)")
                XCTAssertTrue(
                    motion.headTiltDegrees.isFinite,
                    "\(action) \(phase)"
                )
                XCTAssertTrue(motion.legSwing.isFinite, "\(action) \(phase)")
                XCTAssertLessThanOrEqual(abs(motion.tailSwing), 1.01)
                XCTAssertLessThanOrEqual(abs(motion.legSwing), 1.01)
                XCTAssertLessThanOrEqual(abs(motion.headTiltDegrees), 24)

                let pose = TaptionCatAnimationEngine.pose(
                    from: action.rawValue,
                    progress: 0.5,
                    phase: phase,
                    facesLeft: false,
                    tailSwing: motion.tailSwing,
                    headTiltDegrees: motion.headTiltDegrees,
                    legSwing: motion.legSwing
                )
                XCTAssertEqual(pose.action, action)
                XCTAssertTrue((0...1).contains(pose.cycleEase))
            }
        }

        // 위젯이 도는 40스텝 시퀀스가 6프레임 주기를 빠짐없이 채운다.
        let walkPhases = (0..<40).map {
            TaptionWidgetCatWalkEngine.pose(
                at: Date(
                    timeIntervalSinceReferenceDate:
                        Double($0)
                            * TaptionWidgetCatWalkEngine.defaultStepDuration
                            + 0.01
                )
            ).legPhase
        }
        XCTAssertEqual(
            Set(walkPhases),
            Set(0..<TaptionCatAnimationEngine.phaseCount)
        )
    }

    func testCatActionVocabulariesShareRawValuesAndTolerateUnknownStored() {
        XCTAssertEqual(
            Set(TaptionWidgetCatAction.allCases.map(\.rawValue)),
            Set(TaptionCatAnimationAction.allCases.map(\.rawValue))
        )
        for action in TaptionWidgetCatAction.allCases {
            XCTAssertEqual(action.animationAction.rawValue, action.rawValue)
        }

        // 옛 저장본이나 알 수 없는 동작 이름은 기본 동작으로 떨어진다.
        XCTAssertNil(TaptionWidgetCatAction(rawValue: "zoomies"))
        XCTAssertEqual(
            TaptionCatAnimationEngine.pose(
                from: "zoomies",
                progress: 0.5,
                phase: 0,
                facesLeft: false,
                tailSwing: 0,
                headTiltDegrees: 0
            ).action,
            .walking
        )
        XCTAssertEqual(
            TaptionCatAnimationEngine.pose(
                from: "",
                progress: 2,
                phase: 0,
                facesLeft: false,
                tailSwing: 0,
                headTiltDegrees: 0
            ).progress,
            1,
            accuracy: 0.0001
        )
    }

    func testStoredSettingsKeepCatChoiceWhenActionNamesAreUnknown() throws {
        let legacy = """
        {
            "startScale": "day",
            "rememberLastScale": true,
            "catStyle": "cheese",
            "reduceMotion": true,
            "catAction": "zoomies",
            "showsPhotos": false,
            "showsPhotosInWidgets": false,
            "selectedCalendarIDs": [],
            "healthEnabled": false,
            "locationEnabled": false,
            "backgroundPreciseLocationEnabled": false,
            "weatherEnabled": false,
            "notificationsEnabled": false,
            "permissions": []
        }
        """
        let decoded = try JSONDecoder().decode(
            AppFeatureSettings.self,
            from: Data(legacy.utf8)
        )

        XCTAssertEqual(decoded.catStyle, .cheese)
        XCTAssertTrue(decoded.reduceMotion)
        XCTAssertTrue(decoded.rememberLastScale)
        XCTAssertEqual(
            decoded.sensorCollectionProfile,
            AppFeatureSettings.defaults.sensorCollectionProfile
        )
    }

    func testCatIdleBeatBlinksAndStirsAcrossOneMinute() {
        let step = TaptionCatAnimationEngine.stepDuration
        let beats = (0..<750).map {
            TaptionCatIdleBeat.beat(
                at: Date(timeIntervalSinceReferenceDate: Double($0) * step)
            )
        }

        XCTAssertTrue(beats.allSatisfy {
            $0.eyeOpenness.isFinite
                && $0.earFlick.isFinite
                && $0.tailTip.isFinite
        })
        XCTAssertTrue(beats.allSatisfy { (0...1).contains($0.eyeOpenness) })
        XCTAssertTrue(beats.allSatisfy { abs($0.earFlick) <= 1 })
        XCTAssertTrue(beats.allSatisfy { abs($0.tailTip) <= 1 })

        let closedFrames = beats.filter { $0.eyeOpenness < 0.5 }.count
        XCTAssertGreaterThan(closedFrames, 8)
        // 눈을 감고 있는 시간이 뜨고 있는 시간을 넘으면 졸려 보인다.
        XCTAssertLessThan(Double(closedFrames) / Double(beats.count), 0.15)
        XCTAssertTrue(beats.contains { abs($0.earFlick) > 0.6 })
        XCTAssertTrue(beats.contains { $0.tailTip > 0.7 })
        XCTAssertTrue(beats.contains { $0.tailTip < -0.7 })

        // 기준일 이전 날짜에서도 나머지 연산이 음수로 새지 않는다.
        let past = (1...400).map {
            TaptionCatIdleBeat.beat(
                at: Date(timeIntervalSinceReferenceDate: Double(-$0) * step)
            )
        }
        XCTAssertTrue(past.allSatisfy { (0...1).contains($0.eyeOpenness) })
        XCTAssertTrue(past.allSatisfy { abs($0.earFlick) <= 1 })
        XCTAssertTrue(past.allSatisfy { abs($0.tailTip) <= 1 })
        XCTAssertTrue(past.contains { $0.eyeOpenness < 0.5 })

        XCTAssertEqual(
            TaptionCatIdleBeat.beat(at: Date(timeIntervalSinceReferenceDate: .nan)),
            .still
        )
    }

    // TEMP-CAT-SHEET-START
    @MainActor
    func testTempRenderCatContactSheet() throws {
        let outputRoot = "/Users/u_mo_c/Documents/taption plan/.cat-visual-check"
        try? FileManager.default.createDirectory(
            atPath: outputRoot,
            withIntermediateDirectories: true
        )
        let step = TaptionCatAnimationEngine.stepDuration
        let phases = TaptionCatAnimationEngine.phaseCount

        func poses(
            for action: TaptionCatAnimationAction,
            base: Double,
            count: Int
        ) -> [TaptionCatAnimationPose] {
            (0..<count).map { index in
                TaptionCatAnimationEngine.pose(
                    at: Date(
                        timeIntervalSinceReferenceDate: base + Double(index) * step
                    ),
                    preferredAction: action
                )
            }
        }

        func strip(
            _ label: String,
            _ list: [TaptionCatAnimationPose],
            reduces: Bool = false
        ) -> AnyView {
            AnyView(
                HStack(spacing: 2) {
                    Text(label)
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 78, alignment: .leading)
                    ForEach(Array(list.enumerated()), id: \.offset) { _, pose in
                        TaptionCatAnimationView(
                            style: "calico",
                            pose: pose,
                            reducesMotion: reduces
                        )
                        .frame(width: 52, height: 32)
                        .background(Color(white: 0.97))
                        .border(Color(white: 0.85), width: 0.5)
                    }
                }
            )
        }

        var rows: [AnyView] = []
        for action in TaptionCatAnimationAction.allCases {
            rows.append(
                strip(
                    action.rawValue,
                    poses(for: action, base: 1.0, count: phases)
                )
            )
        }
        rows.append(
            strip(
                "idle 0.00~0.56s",
                poses(for: .sitting, base: 0, count: phases)
            )
        )
        rows.append(
            strip(
                "reduceMotion",
                (0..<phases).map { index in
                    TaptionCatAnimationEngine.pose(
                        at: Date(
                            timeIntervalSinceReferenceDate: Double(index) * step
                        ),
                        preferredAction: .running,
                        reducesMotion: true
                    )
                },
                reduces: true
            )
        )

        let sheet = VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                row
            }
        }
        .padding(6)
        .background(Color.white)

        for scale in [4.0, 3.0] {
            let renderer = ImageRenderer(content: sheet)
            renderer.scale = scale
            guard let image = renderer.uiImage,
                  let data = image.pngData() else {
                XCTFail("렌더 실패")
                return
            }
            try data.write(
                to: URL(
                    fileURLWithPath:
                        "\(outputRoot)/cat_sheet_x\(Int(scale)).png"
                )
            )
        }

        // 위젯 실제 크기(@3x) 한 줄 스트립.
        for action in TaptionCatAnimationAction.allCases {
            let renderer = ImageRenderer(
                content: HStack(spacing: 1) {
                    ForEach(0..<phases, id: \.self) { index in
                        TaptionCatAnimationView(
                            style: "calico",
                            pose: TaptionCatAnimationEngine.pose(
                                at: Date(
                                    timeIntervalSinceReferenceDate:
                                        1.0 + Double(index) * step
                                ),
                                preferredAction: action
                            ),
                            reducesMotion: false
                        )
                        .frame(width: 52, height: 32)
                    }
                }
                .background(Color(red: 1.0, green: 0.97, blue: 0.91))
            )
            renderer.scale = 3
            if let data = renderer.uiImage?.pngData() {
                try data.write(
                    to: URL(
                        fileURLWithPath:
                            "\(outputRoot)/actual_\(action.rawValue).png"
                    )
                )
            }
        }
    }
    // TEMP-CAT-SHEET-END

    func testWidgetCatActionMatchesCurrentActionItemCategoryAndTitle() {
        XCTAssertEqual(
            TaptionWidgetCatActionSelector.preferredAction(
                categoryID: "exercise",
                title: "근력 운동"
            ),
            .ballPlay
        )
        XCTAssertEqual(
            TaptionWidgetCatActionSelector.preferredAction(
                categoryID: "hobby",
                title: "기타 연습"
            ),
            .fishingPlay
        )
        XCTAssertEqual(
            TaptionWidgetCatActionSelector.preferredAction(
                categoryID: "routine",
                title: "저녁 식사"
            ),
            .eating
        )
        XCTAssertEqual(
            TaptionWidgetCatActionSelector.preferredAction(
                categoryID: "sleep",
                title: "낮잠"
            ),
            .sleeping
        )
        XCTAssertEqual(
            TaptionWidgetCatActionSelector.preferredAction(
                categoryID: "movement",
                title: "아침 산책"
            ),
            .walking
        )
        XCTAssertEqual(
            TaptionWidgetCatActionSelector.preferredAction(
                categoryID: "exercise",
                title: "러닝"
            ),
            .running
        )
        XCTAssertNil(
            TaptionWidgetCatActionSelector.preferredAction(
                categoryID: "custom-unknown",
                title: "사용자 항목"
            )
        )
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

    func testEncryptedFileRepositoryRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("taption-test-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("snapshot.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        var snapshot = TaptionDataSnapshot.empty
        snapshot.categories = CategoryCatalog.builtIn
        let repository = FilePlanRepository(fileURL: fileURL)
        try await repository.save(snapshot)
        let restored = try await repository.load()

        XCTAssertEqual(restored.categories.count, CategoryCatalog.builtIn.count)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testFileRepositoryRecoversLastValidGenerationAfterCorruption() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("taption-recovery-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("snapshot.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        var first = TaptionDataSnapshot.empty
        first.categories = CategoryCatalog.builtIn
        first.plans = [
            PlanRecord(
                title: "보존된 기록",
                span: TimeSpan(start: .now, end: .now.addingTimeInterval(60)),
                categoryID: "activity"
            )
        ]
        let repository = FilePlanRepository(fileURL: fileURL)
        try await repository.save(first)

        var second = first
        second.plans[0].title = "새 기록"
        try await repository.save(second)
        try Data("broken".utf8).write(to: fileURL, options: [.atomic])

        let recovered = try await repository.load()
        XCTAssertEqual(recovered.plans.first?.title, "보존된 기록")
    }

    func testSnapshotCompressionRoundTripAndLegacyJSON() {
        let json = Data(repeating: 0x41, count: 32 * 1024)
        let stored = TaptionSnapshotCompression.encode(json)

        XCTAssertLessThan(stored.count, json.count)
        XCTAssertEqual(TaptionSnapshotCompression.decode(stored), json)

        let legacy = Data("{\"schemaVersion\":1}".utf8)
        XCTAssertEqual(TaptionSnapshotCompression.decode(legacy), legacy)
    }

    func testAppGroupRepositoryMigratesExistingDeviceSnapshotOnce() async throws {
        var existing = TaptionDataSnapshot.empty
        existing.updatedAt = makeDate(2026, 7, 31, 18)
        existing.categories = CategoryCatalog.builtIn
        existing.plans = [
            PlanRecord(
                title: "기존 계획",
                span: TimeSpan(
                    start: existing.updatedAt,
                    end: existing.updatedAt.addingTimeInterval(hour)
                ),
                categoryID: "project"
            )
        ]
        let primary = InMemoryPlanRepository()
        let legacy = InMemoryPlanRepository(snapshot: existing)
        let repository = MigratingPlanRepository(
            primary: primary,
            legacy: legacy
        )

        let loaded = try await repository.load()
        let shared = try await primary.load()

        XCTAssertEqual(loaded.plans.first?.title, "기존 계획")
        XCTAssertEqual(shared.plans, loaded.plans)
    }

    func testWidgetCommandMutatesSharedSnapshotWithoutOpeningApp() throws {
        let base = makeDate(2026, 7, 30, 9)
        let plan = PlanRecord(
            title: "집중 작업",
            span: TimeSpan(
                start: base,
                end: base.addingTimeInterval(hour)
            ),
            categoryID: "project"
        )
        var source = TaptionDataSnapshot.empty
        source.plans = [plan]

        let postponed = try TaptionWidgetCommandEngine.apply(
            TaptionWidgetCommand(
                planID: plan.id,
                kind: .postponeThirtyMinutes,
                requestedAt: base
            ),
            to: source
        )
        XCTAssertEqual(
            postponed.plans[0].span.start,
            base.addingTimeInterval(30 * 60)
        )
        XCTAssertEqual(
            postponed.plans[0].span.end,
            base.addingTimeInterval(90 * 60)
        )

        let completed = try TaptionWidgetCommandEngine.apply(
            TaptionWidgetCommand(
                planID: plan.id,
                kind: .complete,
                requestedAt: base.addingTimeInterval(45 * 60)
            ),
            to: source
        )
        XCTAssertEqual(completed.plans[0].status, .completed)
        XCTAssertEqual(completed.actuals.count, 1)
        XCTAssertEqual(
            completed.actuals[0].endedAt,
            base.addingTimeInterval(hour)
        )
    }

    func testWidgetDeepLinkParsesExactPlan() throws {
        let planID = UUID()
        let link = TaptionDeepLink(
            url: URL(
                string: "taptionplan://plan/\(planID.uuidString)"
            )!
        )

        XCTAssertEqual(link, .plan(planID))
        XCTAssertEqual(
            TaptionDeepLink(url: URL(string: "taptionplan://today")!),
            .today
        )
        XCTAssertEqual(
            TaptionDeepLink(url: URL(string: "taptionplan://cats")!),
            .catPicker
        )
    }

    func testPlanNotificationPolicyKeepsOnlyUpcomingPlansInOrder() {
        let now = makeDate(2026, 7, 30, 9)
        let past = PlanRecord(
            title: "지난 계획",
            span: TimeSpan(
                start: now.addingTimeInterval(-hour),
                end: now
            ),
            categoryID: "project"
        )
        let later = PlanRecord(
            title: "두 번째",
            span: TimeSpan(
                start: now.addingTimeInterval(2 * hour),
                end: now.addingTimeInterval(3 * hour)
            ),
            categoryID: "project"
        )
        let first = PlanRecord(
            title: "첫 번째",
            span: TimeSpan(
                start: now.addingTimeInterval(hour),
                end: now.addingTimeInterval(2 * hour)
            ),
            categoryID: "study"
        )
        var completed = later
        completed.id = UUID()
        completed.status = .completed

        let reminders = PlanNotificationPolicy.reminderPlans(
            from: [past, later, completed, first],
            now: now
        )

        XCTAssertEqual(reminders.map(\.id), [first.id, later.id])
        XCTAssertEqual(
            PlanNotificationScheduler.identifier(for: first.id),
            "plan-start-\(first.id.uuidString)"
        )
    }

    func testCommercePolicyUsesLifetimeNonConsumableEntitlement() {
        XCTAssertTrue(TaptionCommercePolicy.isLifetimeNonConsumable)
        XCTAssertTrue(
            TaptionCommercePolicy.grantsProAccess(
                productID: TaptionCommercePolicy.proProductID,
                revocationDate: nil
            )
        )
        XCTAssertFalse(
            TaptionCommercePolicy.grantsProAccess(
                productID: TaptionCommercePolicy.proProductID,
                revocationDate: .now
            )
        )
        XCTAssertFalse(
            TaptionCommercePolicy.grantsProAccess(
                productID: "com.example.other",
                revocationDate: nil
            )
        )
    }

    func testSettingsMigrationDefaultsNotificationToggleToOff() throws {
        let encoded = try JSONEncoder().encode(AppFeatureSettings.defaults)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded)
                as? [String: Any]
        )
        object.removeValue(forKey: "notificationsEnabled")
        object.removeValue(forKey: "movementCorrections")
        object.removeValue(forKey: "suppressedActualIDs")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let migrated = try JSONDecoder().decode(
            AppFeatureSettings.self,
            from: legacyData
        )

        XCTAssertFalse(migrated.notificationsEnabled)
        XCTAssertTrue(migrated.movementCorrections.isEmpty)
        XCTAssertTrue(migrated.suppressedActualIDs.isEmpty)
        XCTAssertEqual(migrated.startScale, .day)
        XCTAssertEqual(
            migrated.permissions.count,
            PermissionFeature.allCases.count
        )
        XCTAssertEqual(migrated.timelineRowOrder, TimelineRowOrder.defaults)
    }

    func testTimelineRowOrderMovesRowsAndKeepsUnknownRowsStable() {
        let rows = ["calendar", "location", "movement", "sleep", "photo"]
        let saved = TimelineRowOrder.defaults

        XCTAssertEqual(
            TimelineRowOrder.ordered(
                rows,
                id: { $0 },
                savedIDs: saved
            ),
            rows
        )
        XCTAssertEqual(
            TimelineRowOrder.moved(
                rows,
                sourceID: "photo",
                targetID: "location",
                savedIDs: saved
            ),
            ["calendar", "photo", "location", "movement", "sleep"]
        )
        XCTAssertEqual(
            TimelineRowOrder.moved(
                rows,
                sourceID: "calendar",
                targetID: "movement",
                savedIDs: saved
            ),
            ["location", "calendar", "movement", "sleep", "photo"]
        )
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

    func testCloudKitRequiresExactContainerEntitlement() {
        XCTAssertFalse(
            CloudKitEntitlementPolicy.canInitialize(
                containerIdentifier: "iCloud.com.taption.plan",
                embeddedProfileData: nil
            )
        )
        XCTAssertFalse(
            CloudKitEntitlementPolicy.canInitialize(
                containerIdentifier: "iCloud.com.taption.plan",
                embeddedProfileData: Data(
                    "iCloud.com.example.other".utf8
                )
            )
        )
        XCTAssertTrue(
            CloudKitEntitlementPolicy.canInitialize(
                containerIdentifier: "iCloud.com.taption.plan",
                embeddedProfileData: Data(
                    """
                    <key>com.apple.developer.icloud-container-identifiers</key>
                    <array><string>iCloud.com.taption.plan</string></array>
                    """.utf8
                )
            )
        )
    }

    func testActualIntervalMergeDoesNotDoubleCountOverlaps() {
        let start = makeDate(2026, 8, 3, 9)
        let spans = [
            TimeSpan(start: start, end: start.addingTimeInterval(60 * 60)),
            TimeSpan(
                start: start.addingTimeInterval(30 * 60),
                end: start.addingTimeInterval(90 * 60)
            ),
            TimeSpan(
                start: start.addingTimeInterval(3 * 60 * 60),
                end: start.addingTimeInterval(4 * 60 * 60)
            ),
        ]

        XCTAssertEqual(
            ActualIntervalMergeEngine.duration(of: spans),
            2.5 * hour,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ActualIntervalMergeEngine.union(spans).count,
            2
        )
    }

    func testAutomaticActualSpanStopsAtObservationTime() {
        let observedAt = makeDate(2026, 8, 3, 18)
        let actual = ActualRecord(
            planID: nil,
            title: "걷기",
            categoryID: "movement",
            startedAt: observedAt.addingTimeInterval(-hour),
            endedAt: observedAt.addingTimeInterval(hour),
            source: .motion
        )

        XCTAssertEqual(
            actual.span(asOf: observedAt).end,
            observedAt
        )
        XCTAssertEqual(
            actual.span(asOf: observedAt).duration,
            hour,
            accuracy: 0.001
        )
    }

    func testCloudKitProductionSchemaErrorIsHandledAsUnavailable() {
        let error = NSError(
            domain: "CKErrorDomain",
            code: 15,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Cannot create new type TaptionSnapshot in production schema"
            ]
        )
        XCTAssertTrue(
            CloudKitErrorPolicy.isProductionSchemaUnavailable(error)
        )
        XCTAssertFalse(
            CloudKitErrorPolicy.isProductionSchemaUnavailable(
                NSError(domain: "CKErrorDomain", code: 3)
            )
        )
        XCTAssertEqual(CloudUnavailableReason.schemaMissing.statusLabel, "서버 설정 필요")
        XCTAssertTrue(
            CloudUnavailableReason.schemaMissing.guidance.contains("Production")
        )
    }

    func testCloudKitRecordConflictRecognizesCodeAndOplockMessage() {
        XCTAssertTrue(
            CloudKitErrorPolicy.isRecordConflict(
                NSError(domain: "CKErrorDomain", code: 14)
            )
        )
        XCTAssertTrue(
            CloudKitErrorPolicy.isRecordConflict(
                NSError(
                    domain: "CKInternalErrorDomain",
                    code: 2_000,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "client oplock error updating record"
                    ]
                )
            )
        )
        XCTAssertFalse(
            CloudKitErrorPolicy.isRecordConflict(
                NSError(domain: "CKErrorDomain", code: 3)
            )
        )
    }

    func testCloudRecoveryRestoresRecordsMissingFromNewerLocalSnapshot() {
        let base = makeDate(2026, 8, 9, 9)
        let localPlan = PlanRecord(
            title: "로컬 계획",
            span: TimeSpan(start: base, end: base.addingTimeInterval(hour)),
            categoryID: "activity",
            updatedAt: base.addingTimeInterval(2 * hour)
        )
        let cloudPlan = PlanRecord(
            title: "백업 계획",
            span: TimeSpan(
                start: base.addingTimeInterval(2 * hour),
                end: base.addingTimeInterval(3 * hour)
            ),
            categoryID: "activity",
            updatedAt: base
        )
        let cloudMemo = ActionMemo(
            planID: cloudPlan.id,
            kind: .decision,
            text: "백업 메모",
            createdAt: base,
            updatedAt: base
        )
        var local = TaptionDataSnapshot.empty
        local.updatedAt = base.addingTimeInterval(3 * hour)
        local.plans = [localPlan]
        var remote = TaptionDataSnapshot.empty
        remote.updatedAt = base.addingTimeInterval(hour)
        remote.plans = [cloudPlan]
        remote.memos = [cloudMemo]

        let recovered = CloudSnapshotRecoveryEngine.merge(
            local: local,
            remote: remote
        )

        XCTAssertEqual(Set(recovered.plans.map(\.id)), [localPlan.id, cloudPlan.id])
        XCTAssertEqual(recovered.memos, [cloudMemo])
        XCTAssertEqual(recovered.updatedAt, local.updatedAt)
    }

    func testCloudRecoveryUsesNewestVersionOfSameRecord() {
        let base = makeDate(2026, 8, 9, 10)
        let id = UUID()
        let localPlan = PlanRecord(
            id: id,
            title: "이전 제목",
            span: TimeSpan(start: base, end: base.addingTimeInterval(hour)),
            categoryID: "activity",
            updatedAt: base
        )
        let cloudPlan = PlanRecord(
            id: id,
            title: "최신 제목",
            span: TimeSpan(start: base, end: base.addingTimeInterval(hour)),
            categoryID: "activity",
            updatedAt: base.addingTimeInterval(hour)
        )
        var local = TaptionDataSnapshot.empty
        local.updatedAt = base.addingTimeInterval(2 * hour)
        local.plans = [localPlan]
        var remote = TaptionDataSnapshot.empty
        remote.updatedAt = base.addingTimeInterval(hour)
        remote.plans = [cloudPlan]

        let recovered = CloudSnapshotRecoveryEngine.merge(
            local: local,
            remote: remote
        )

        XCTAssertEqual(recovered.plans, [cloudPlan])
    }

    func testCloudRecoveryDoesNotResurrectDeletedRecords() {
        let base = makeDate(2026, 8, 9, 11)
        let plan = PlanRecord(
            title: "삭제한 계획",
            span: TimeSpan(start: base, end: base.addingTimeInterval(hour)),
            categoryID: "activity"
        )
        let memo = ActionMemo(
            planID: plan.id,
            kind: .idea,
            text: "삭제한 메모"
        )
        let actual = ActualRecord(
            planID: nil,
            title: "삭제한 기록",
            categoryID: "activity",
            startedAt: base,
            endedAt: base.addingTimeInterval(hour),
            source: .manual
        )
        var local = TaptionDataSnapshot.empty
        local.updatedAt = base.addingTimeInterval(2 * hour)
        local.settings.cloudDeletedRecordKeys = [
            CloudBackupRecordKey.plan(plan.id),
            CloudBackupRecordKey.memo(memo.id),
        ]
        local.settings.suppressedActualIDs = [actual.id]
        var remote = TaptionDataSnapshot.empty
        remote.updatedAt = base
        remote.plans = [plan]
        remote.memos = [memo]
        remote.actuals = [actual]

        let recovered = CloudSnapshotRecoveryEngine.merge(
            local: local,
            remote: remote
        )

        XCTAssertTrue(recovered.plans.isEmpty)
        XCTAssertTrue(recovered.memos.isEmpty)
        XCTAssertTrue(recovered.actuals.isEmpty)
    }

    func testCloudRecoveryKeepsExplicitFullReset() {
        let base = makeDate(2026, 8, 9, 12)
        var reset = TaptionDataSnapshot.empty
        reset.updatedAt = base
        reset.settings.cloudResetAt = base
        var staleDevice = TaptionDataSnapshot.empty
        staleDevice.updatedAt = base.addingTimeInterval(hour)
        staleDevice.plans = [
            PlanRecord(
                title: "초기화 전 계획",
                span: TimeSpan(
                    start: base,
                    end: base.addingTimeInterval(hour)
                ),
                categoryID: "activity"
            )
        ]

        let recovered = CloudSnapshotRecoveryEngine.merge(
            local: reset,
            remote: staleDevice
        )

        XCTAssertEqual(recovered, reset)
    }

    func testOpenMeteoWeatherCodesUseKoreanConditionsAndDayNightSymbols() {
        let clearDay = OpenMeteoWeatherCodePresentation(
            code: 0,
            isDay: true
        )
        XCTAssertEqual(clearDay.condition, "맑음")
        XCTAssertEqual(clearDay.symbolName, "sun.max.fill")

        let clearNight = OpenMeteoWeatherCodePresentation(
            code: 0,
            isDay: false
        )
        XCTAssertEqual(clearNight.condition, "맑음")
        XCTAssertEqual(clearNight.symbolName, "moon.stars.fill")

        let heavyRain = OpenMeteoWeatherCodePresentation(
            code: 65,
            isDay: true
        )
        XCTAssertEqual(heavyRain.condition, "강한 비")
        XCTAssertEqual(heavyRain.symbolName, "cloud.heavyrain.fill")
    }

    func testWeatherFreshnessMetadataSurvivesRoundTrip() throws {
        let fetchedAt = makeDate(2026, 8, 1, 18)
        let context = WeatherContext(
            observedAt: fetchedAt,
            fetchedAt: fetchedAt,
            isStale: true,
            condition: "맑음",
            symbolName: "sun.max.fill",
            temperatureCelsius: 28
        )
        let decoded = try JSONDecoder().decode(
            WeatherContext.self,
            from: JSONEncoder().encode(context)
        )
        XCTAssertEqual(decoded.fetchedAt, fetchedAt)
        XCTAssertEqual(decoded.isStale, true)
    }

    func testWeatherTimelineMergesEqualValuesAndSplitsOnChange() {
        let start = makeDate(2026, 8, 1, 10)
        let first = WeatherContext(
            observedAt: start,
            condition: "맑음",
            symbolName: "sun.max.fill",
            temperatureCelsius: 26.1
        )
        let repeated = WeatherContext(
            observedAt: start.addingTimeInterval(60 * 60),
            condition: "맑음",
            symbolName: "cloud.sun.fill",
            temperatureCelsius: 26.4
        )
        let changed = WeatherContext(
            observedAt: start.addingTimeInterval(2 * 60 * 60),
            condition: "흐림",
            symbolName: "cloud.fill",
            temperatureCelsius: 26.4
        )

        let merged = WeatherTimelineEngine.coalesced([
            first,
            repeated,
            changed,
        ])

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].observedAt, start)
        XCTAssertEqual(
            merged[0].validUntil,
            changed.observedAt
        )
        XCTAssertEqual(
            merged[1].validUntil,
            changed.observedAt.addingTimeInterval(15 * 60)
        )
    }

    func testWeatherTimelineKeepsSameDisplayedWeatherContinuous() {
        let start = makeDate(2026, 8, 1, 10)
        let first = WeatherContext(
            observedAt: start,
            condition: "맑음",
            symbolName: "sun.max.fill",
            temperatureCelsius: 28,
            airQuality: AirQualityContext(
                pm10MicrogramsPerCubicMeter: 41,
                pm25MicrogramsPerCubicMeter: 21,
                observedAt: start,
                providerName: "에어코리아",
                isFallback: false
            )
        )
        let repeated = WeatherContext(
            observedAt: start.addingTimeInterval(60 * 60),
            condition: "맑음",
            symbolName: "sun.max.fill",
            temperatureCelsius: 28.4,
            airQuality: AirQualityContext(
                pm10MicrogramsPerCubicMeter: 63,
                pm25MicrogramsPerCubicMeter: 30,
                observedAt: start.addingTimeInterval(60 * 60),
                providerName: "Open-Meteo",
                isFallback: true
            )
        )

        let merged = WeatherTimelineEngine.coalesced([first, repeated])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].validUntil, repeated.observedAt.addingTimeInterval(15 * 60))
        XCTAssertEqual(merged[0].airQuality?.pm10MicrogramsPerCubicMeter, 63)
    }

    func testWidgetSyncStatusUsesGroundTruthFingerprint() {
        var groundTruth = TaptionWidgetPayload.empty
        groundTruth.sourceFingerprint = "ground-truth"
        var cached = groundTruth
        cached.generatedAt = .now
        XCTAssertEqual(
            TaptionWidgetSyncStatus.compare(
                groundTruth: groundTruth,
                cached: cached
            ),
            .synchronized(cached.generatedAt)
        )

        cached.sourceFingerprint = "old"
        XCTAssertEqual(
            TaptionWidgetSyncStatus.compare(
                groundTruth: groundTruth,
                cached: cached
            ),
            .pending
        )
        groundTruth.sourceFingerprint = nil
        XCTAssertEqual(
            TaptionWidgetSyncStatus.compare(
                groundTruth: groundTruth,
                cached: cached
            ),
            .unavailable
        )
    }

    func testDomesticAirQualityGradeBoundaries() {
        XCTAssertEqual(AirQualityGrade.pm10(30), .good)
        XCTAssertEqual(AirQualityGrade.pm10(31), .moderate)
        XCTAssertEqual(AirQualityGrade.pm10(80), .moderate)
        XCTAssertEqual(AirQualityGrade.pm10(81), .bad)
        XCTAssertEqual(AirQualityGrade.pm10(151), .veryBad)
        XCTAssertEqual(AirQualityGrade.pm25(15), .good)
        XCTAssertEqual(AirQualityGrade.pm25(16), .moderate)
        XCTAssertEqual(AirQualityGrade.pm25(36), .bad)
        XCTAssertEqual(AirQualityGrade.pm25(76), .veryBad)

        let context = AirQualityContext(
            pm10MicrogramsPerCubicMeter: 45,
            pm25MicrogramsPerCubicMeter: 80,
            observedAt: .now,
            providerName: "test",
            isFallback: false
        )
        XCTAssertEqual(context.overallGrade, .veryBad)
    }

    func testAirKoreaUsesNearestStationAndCachesContext() async throws {
        AirQualityURLProtocolStub.requestCount = 0
        AirQualityURLProtocolStub.handler = { request in
            let path = try XCTUnwrap(request.url?.path)
            let json: String
            if path.contains("getMsrstnList") {
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
            serviceKey: "local-test-key"
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

    func testAirQualityFallsBackToOpenMeteoWithoutKey() async throws {
        AirQualityURLProtocolStub.requestCount = 0
        AirQualityURLProtocolStub.handler = { request in
            XCTAssertTrue(
                request.url?.host?.contains("open-meteo.com") == true
            )
            return (
                200,
                Data("{\"current\":{\"pm10\":21.5,\"pm2_5\":8.25}}".utf8)
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AirQualityURLProtocolStub.self]
        let service = AirQualityContextService(
            session: URLSession(configuration: configuration),
            serviceKey: nil
        )
        let context = try await service.context(
            latitude: 37.5,
            longitude: 127
        )
        XCTAssertTrue(context.isFallback)
        XCTAssertEqual(context.providerName, "Open-Meteo")
        XCTAssertEqual(context.pm10MicrogramsPerCubicMeter, 21.5)
        XCTAssertEqual(context.pm25MicrogramsPerCubicMeter, 8.25)
        XCTAssertEqual(AirQualityURLProtocolStub.requestCount, 1)
    }

    func testGoalDetailBranchesAndDeduplicatesOverlappingTime() {
        let start = makeDate(2026, 8, 1, 9)
        let repeatGoal = PlanRecord(
            title: "수면",
            span: TimeSpan(start: start, end: start.addingTimeInterval(30 * 86_400)),
            categoryID: "sleep",
            repeatRules: [
                GoalRepeatRule(
                    weekdays: [2, 3, 4, 5, 6],
                    startMinuteOfDay: 23 * 60,
                    endMinuteOfDay: 6 * 60 + 30
                ),
            ]
        )
        XCTAssertEqual(
            GoalDetailEngine.make(
                goal: repeatGoal,
                plans: [repeatGoal],
                actuals: [],
                referenceDate: start,
                calendar: utcCalendar
            ).mode,
            .habit
        )

        let projectGoal = PlanRecord(
            title: "자격증",
            span: TimeSpan(start: start, end: start.addingTimeInterval(10 * 86_400)),
            categoryID: "study"
        )
        let child = PlanRecord(
            title: "강의 듣기",
            span: TimeSpan(start: start, end: start.addingTimeInterval(hour)),
            categoryID: "study",
            parentID: projectGoal.id
        )
        XCTAssertEqual(
            GoalDetailEngine.make(
                goal: projectGoal,
                plans: [projectGoal, child],
                actuals: [],
                referenceDate: start,
                calendar: utcCalendar
            ).mode,
            .project
        )
        XCTAssertEqual(
            GoalDetailEngine.make(
                goal: projectGoal,
                plans: [projectGoal],
                actuals: [],
                referenceDate: start,
                calendar: utcCalendar
            ).mode,
            .empty
        )
        XCTAssertEqual(
            GoalDetailEngine.unionDuration([
                TimeSpan(start: start, end: start.addingTimeInterval(hour)),
                TimeSpan(
                    start: start.addingTimeInterval(30 * 60),
                    end: start.addingTimeInterval(2 * hour)
                ),
            ]),
            2 * hour
        )
    }

    func testSleepActualLinksToRoutineOnlyInRelationshipGraph() {
        let start = makeDate(2026, 8, 1, 22)
        let routine = PlanRecord(
            title: "루틴:수면",
            span: TimeSpan(start: start, end: start.addingTimeInterval(10 * hour)),
            categoryID: "sleep"
        )
        let action = PlanRecord(
            title: "취침 준비",
            span: TimeSpan(start: start, end: start.addingTimeInterval(hour)),
            categoryID: "sleep",
            parentID: routine.id
        )
        let sleep = ActualRecord(
            planID: action.id,
            routineID: routine.id,
            title: "수면",
            categoryID: "sleep",
            startedAt: start.addingTimeInterval(15 * 60),
            endedAt: start.addingTimeInterval(8 * hour),
            source: .appleWatch
        )

        let graph = RecordRelationshipEngine.make(
            inside: routine.span,
            plans: [routine, action],
            actuals: [sleep],
            calendarEvents: [],
            places: [],
            travel: []
        )

        XCTAssertTrue(
            graph.edges.contains {
                $0.from == "automatic.actual.\(sleep.id.uuidString)"
                    && $0.to == "routine.\(routine.id.uuidString)"
            }
        )
        XCTAssertFalse(
            graph.edges.contains {
                $0.from == "automatic.actual.\(sleep.id.uuidString)"
                    && $0.to == "action.\(action.id.uuidString)"
            }
        )
        XCTAssertTrue(
            graph.edges.contains {
                $0.from == "routine.\(routine.id.uuidString)"
                    && $0.to == "action.\(action.id.uuidString)"
            }
        )
    }

    func testRelationshipGraphResolvesNestedActionAndAutomaticEvidence() {
        let start = makeDate(2026, 8, 2, 9)
        let routine = PlanRecord(
            title: "루틴:운동",
            span: TimeSpan(start: start, end: start.addingTimeInterval(4 * hour)),
            categoryID: "activity"
        )
        let parentAction = PlanRecord(
            title: "준비 운동",
            span: TimeSpan(start: start, end: start.addingTimeInterval(hour)),
            categoryID: "exercise",
            parentID: routine.id
        )
        let nestedAction = PlanRecord(
            title: "달리기",
            span: TimeSpan(
                start: start.addingTimeInterval(hour),
                end: start.addingTimeInterval(3 * hour)
            ),
            categoryID: "exercise",
            parentID: parentAction.id
        )
        let running = ActualRecord(
            planID: nestedAction.id,
            routineID: nil,
            title: "달리기",
            categoryID: "exercise",
            startedAt: start.addingTimeInterval(75 * 60),
            endedAt: start.addingTimeInterval(2 * hour),
            source: .appleWatch
        )

        let graph = RecordRelationshipEngine.make(
            inside: running.span(),
            plans: [routine, parentAction, nestedAction],
            actuals: [running],
            calendarEvents: [],
            places: [],
            travel: [],
            focusNodeID: "automatic.actual.\(running.id.uuidString)"
        )

        XCTAssertTrue(graph.edges.contains {
            $0.from == "routine.\(routine.id.uuidString)"
                && $0.to == "action.\(nestedAction.id.uuidString)"
        })
        XCTAssertTrue(graph.edges.contains {
            $0.from == "automatic.actual.\(running.id.uuidString)"
                && $0.to == "action.\(nestedAction.id.uuidString)"
        })
        XCTAssertTrue(graph.nodes.contains { $0.id == "routine.\(routine.id.uuidString)" })
        XCTAssertTrue(graph.nodes.contains { $0.id == "action.\(nestedAction.id.uuidString)" })
    }

    func testRelationshipGraphOmitsRepeatSegmentsAndKeepsFocusedRoutineChain() {
        let start = makeDate(2026, 8, 2, 22)
        let routine = PlanRecord(
            title: "루틴:수면",
            span: TimeSpan(start: start, end: start.addingTimeInterval(10 * hour)),
            categoryID: "sleep"
        )
        let repeatSegment = PlanRecord(
            title: "수면 · 주중",
            span: TimeSpan(
                start: start.addingTimeInterval(hour),
                end: start.addingTimeInterval(8 * hour)
            ),
            categoryID: "sleep",
            parentID: routine.id,
            origin: .repeatRule
        )
        let action = PlanRecord(
            title: "취침 준비",
            span: TimeSpan(start: start, end: start.addingTimeInterval(hour)),
            categoryID: "sleep",
            parentID: routine.id
        )
        let sleep = ActualRecord(
            planID: action.id,
            routineID: routine.id,
            title: "수면",
            categoryID: "sleep",
            startedAt: start.addingTimeInterval(2 * hour),
            endedAt: start.addingTimeInterval(7 * hour),
            source: .healthKit
        )

        let graph = RecordRelationshipEngine.make(
            inside: sleep.span(),
            plans: [routine, repeatSegment, action],
            actuals: [sleep],
            calendarEvents: [],
            places: [],
            travel: [],
            focusNodeID: "automatic.actual.\(sleep.id.uuidString)"
        )

        XCTAssertFalse(graph.nodes.contains { $0.id == "routine.\(repeatSegment.id.uuidString)" })
        XCTAssertTrue(graph.edges.contains {
            $0.from == "automatic.actual.\(sleep.id.uuidString)"
                && $0.to == "routine.\(routine.id.uuidString)"
        })
        XCTAssertFalse(graph.edges.contains {
            $0.from == "automatic.actual.\(sleep.id.uuidString)"
                && $0.to == "action.\(action.id.uuidString)"
        })
        XCTAssertTrue(graph.edges.contains {
            $0.from == "routine.\(routine.id.uuidString)"
                && $0.to == "action.\(action.id.uuidString)"
        })
    }

    func testRelationshipGraphCanonicalizesLegacyRepeatLink() {
        let start = makeDate(2026, 8, 3, 8)
        let routine = PlanRecord(
            title: "루틴:출근",
            span: TimeSpan(start: start, end: start.addingTimeInterval(2 * hour)),
            categoryID: "work"
        )
        let repeatSegment = PlanRecord(
            title: "출근 · 월요일",
            span: TimeSpan(start: start, end: start.addingTimeInterval(hour)),
            categoryID: "work",
            parentID: routine.id,
            origin: .repeatRule
        )
        let place = PlaceStay(
            id: UUID(),
            placeKey: "company",
            displayName: "회사",
            floor: nil,
            span: TimeSpan(start: start, end: start.addingTimeInterval(30 * 60)),
            confidence: .high,
            point: nil
        )
        let graph = RecordRelationshipEngine.make(
            inside: place.span,
            plans: [routine, repeatSegment],
            actuals: [],
            calendarEvents: [],
            places: [place],
            travel: [],
            recordLinks: [
                RecordLink(
                    fromNodeID: "automatic.place.\(place.id.uuidString)",
                    toNodeID: "action.\(repeatSegment.id.uuidString)"
                )
            ]
        )

        XCTAssertTrue(graph.edges.contains {
            $0.from == "automatic.place.\(place.id.uuidString)"
                && $0.to == "routine.\(routine.id.uuidString)"
        })
        XCTAssertFalse(graph.edges.contains {
            $0.to == "action.\(repeatSegment.id.uuidString)"
        })
    }

    func testGoalActivityMatchingCountsExplicitlyLinkedSleepOnly() {
        let start = makeDate(2026, 8, 1, 22)
        let routine = PlanRecord(
            title: "루틴:수면",
            span: TimeSpan(start: start, end: start.addingTimeInterval(10 * hour)),
            categoryID: "sleep"
        )
        let linked = ActualRecord(
            planID: nil,
            routineID: routine.id,
            title: "수면",
            categoryID: "sleep",
            startedAt: start,
            endedAt: start.addingTimeInterval(7 * hour),
            source: .healthKit
        )
        let unlinked = ActualRecord(
            planID: nil,
            routineID: nil,
            title: "수면",
            categoryID: "sleep",
            startedAt: start,
            endedAt: start.addingTimeInterval(7 * hour),
            source: .healthKit
        )

        XCTAssertEqual(
            GoalActivityMatchingEngine.matches(
                goal: routine,
                plans: [routine],
                actuals: [linked, unlinked]
            ).map(\.actual.id),
            [linked.id]
        )
    }

    func testAutomaticSleepEvidenceUsesBestOverlappingRepeatSegment() {
        let routineStart = makeDate(2026, 8, 1, 22)
        let routine = PlanRecord(
            title: "루틴:수면",
            span: TimeSpan(
                start: routineStart,
                end: routineStart.addingTimeInterval(10 * hour)
            ),
            categoryID: "sleep"
        )
        let repeatSegment = PlanRecord(
            title: "수면 · 주중",
            span: TimeSpan(
                start: makeDate(2026, 8, 1, 23),
                end: makeDate(2026, 8, 2, 6, 30)
            ),
            categoryID: "sleep",
            parentID: routine.id,
            origin: .repeatRule
        )
        let sleep = ActualRecord(
            planID: nil,
            routineID: nil,
            title: "수면",
            categoryID: "sleep",
            startedAt: makeDate(2026, 8, 2, 2),
            endedAt: makeDate(2026, 8, 2, 6),
            source: .healthKit
        )

        let matches = GoalActivityMatchingEngine.matches(
            goal: routine,
            plans: [routine, repeatSegment],
            actuals: [sleep],
            asOf: makeDate(2026, 8, 2, 12)
        )

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.kind, .automatic)
        XCTAssertEqual(matches.first?.matchedPlanID, repeatSegment.id)
        XCTAssertEqual(
            GoalActivityMatchingEngine.progress(
                for: repeatSegment,
                matches: matches,
                asOf: makeDate(2026, 8, 2, 12)
            ),
            4 * hour / (7.5 * hour),
            accuracy: 0.001
        )
    }

    func testGoalRecordPolicyKeepsOrdinaryPlansOutOfGoalTab() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let goal = PlanRecord(
            title: "목표:달리기",
            span: TimeSpan(
                start: start,
                end: start.addingTimeInterval(86_400)
            ),
            categoryID: "exercise"
        )
        let ordinaryPlan = PlanRecord(
            title: "청계천 달리기",
            span: TimeSpan(
                start: start.addingTimeInterval(3_600),
                end: start.addingTimeInterval(5_400)
            ),
            categoryID: "exercise"
        )
        let childPlan = PlanRecord(
            title: "인터벌 훈련",
            span: TimeSpan(
                start: start.addingTimeInterval(7_200),
                end: start.addingTimeInterval(9_000)
            ),
            categoryID: "exercise",
            parentID: goal.id
        )
        let skippedGoal = PlanRecord(
            title: "목표:지난 목표",
            span: TimeSpan(
                start: start,
                end: start.addingTimeInterval(3_600)
            ),
            categoryID: "exercise",
            status: .skipped
        )

        let visible = GoalRecordPolicy.visibleGoals(
            in: [ordinaryPlan, childPlan, skippedGoal, goal]
        )

        XCTAssertEqual(visible.map(\.id), [goal.id])
        XCTAssertFalse(GoalRecordPolicy.isGoal(ordinaryPlan))
        XCTAssertFalse(GoalRecordPolicy.isGoal(childPlan))
    }

    func testScheduleHeaderUsesKoreanCalendarTitles() {
        let date = makeDate(2026, 7, 31)
        let formatter = ScheduleHeaderFormatter(calendar: utcCalendar)

        XCTAssertEqual(
            formatter.title(for: date, scale: .day),
            "7월 31일 (금)"
        )
        XCTAssertEqual(
            formatter.title(for: date, scale: .week),
            "7월 27일 – 8월 2일"
        )
        XCTAssertEqual(
            formatter.title(for: date, scale: .month),
            "2026년 7월"
        )
        XCTAssertEqual(
            formatter.title(for: date, scale: .year),
            "2026년"
        )
        XCTAssertEqual(
            formatter.playheadTitle(for: date, scale: .week),
            "7월 31일 (금)"
        )
        XCTAssertEqual(
            formatter.playheadTitle(for: date, scale: .month),
            "7월 31일 (금)"
        )
        XCTAssertEqual(
            formatter.playheadTitle(for: date, scale: .year),
            "7월 31일 (금)"
        )
    }

    func testPeriodNavigationAllowsEmptyAdjacentPeriodForEveryScale() throws {
        let date = makeDate(2026, 7, 31, 12)
        let engine = TimelinePeriodNavigationEngine(calendar: utcCalendar)

        // 기록이 없는 날짜도 고를 수 있어야 한다. 빈 구간이라는 사실
        // 자체를 확인하려면 일단 넘어갈 수 있어야 하기 때문이다.
        for level in TimelineLevel.allCases {
            for direction in [-1, 1] {
                XCTAssertTrue(
                    engine.canNavigate(
                        from: date,
                        level: level,
                        direction: direction,
                        snapshot: .empty
                    ),
                    "\(level.rawValue) should stay enabled without data"
                )
            }
        }
    }

    /// 기록이 있는 곳으로 끌려가지 않는다. 빈 구간으로 넘어가면 그 빈 구간이
    /// 그대로 나온다. 예전에는 손을 뗀 자리에 아무것도 없으면 가장 가까운
    /// 기록으로 화면이 되돌아가, 아직 비어 있는 앞날을 펼쳐 둘 수 없었다.
    func testPeriodNavigationLandsOnTheNeighborNotOnTheNearestRecord() throws {
        let date = makeDate(2026, 7, 31, 12)
        let engine = TimelinePeriodNavigationEngine(calendar: utcCalendar)
        // 기록은 한참 뒤에만 있다. 어느 배율에서 한 칸을 움직여도 여기에
        // 닿지 않는다.
        let distant = makeDate(2027, 3, 2, 9)
        let snapshot = makeSnapshot(
            plans: [
                PlanRecord(
                    title: "먼 계획",
                    span: TimeSpan(
                        start: distant,
                        end: distant.addingTimeInterval(hour)
                    ),
                    categoryID: "project"
                ),
            ]
        )

        for level in TimelineLevel.allCases {
            let component: Calendar.Component = switch level {
            case .day: .day
            case .week: .weekOfYear
            case .month: .month
            case .year: .year
            }
            for direction in [-1, 1] {
                XCTAssertTrue(
                    engine.canNavigate(
                        from: date,
                        level: level,
                        direction: direction,
                        snapshot: snapshot
                    )
                )
                XCTAssertEqual(
                    engine.adjacentDate(
                        from: date,
                        level: level,
                        direction: direction
                    ),
                    utcCalendar.date(
                        byAdding: component,
                        value: direction,
                        to: date
                    ),
                    "\(level.rawValue) \(direction) should not seek data"
                )
            }
        }
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

    func testPeriodNavigationStillRejectsZeroDirection() {
        let date = makeDate(2026, 7, 31, 12)
        let engine = TimelinePeriodNavigationEngine(calendar: utcCalendar)

        for level in TimelineLevel.allCases {
            XCTAssertFalse(
                engine.canNavigate(
                    from: date,
                    level: level,
                    direction: 0,
                    snapshot: .empty
                )
            )
        }
    }

    func testScreenTimeUsageReplacesOnlyTheFetchedHours() {
        let start = makeDate(2026, 8, 3, 9)
        let span = TimeSpan(start: start, end: start.addingTimeInterval(hour))
        let fresh = ScreenTimeUsageRecordEngine.records(
            from: [
                ScreenTimeUsageSample(
                    key: "bundle:com.example.maps",
                    title: "어플 · 지도",
                    span: span,
                    duration: 20 * 60,
                    pickups: 1,
                    notifications: 2
                )
            ],
            suppressedIDs: []
        )
        let stale = ActualRecord(
            planID: nil,
            title: "어플 · 이전",
            categoryID: "appUsage",
            startedAt: start,
            endedAt: start.addingTimeInterval(5 * 60),
            source: .appUsage
        )
        let outside = ActualRecord(
            planID: nil,
            title: "어플 · 유지",
            categoryID: "appUsage",
            startedAt: start.addingTimeInterval(2 * hour),
            endedAt: start.addingTimeInterval(2 * hour + 5 * 60),
            source: .appUsage
        )

        let result = ScreenTimeUsageRecordEngine.replacing(
            existing: [stale, outside],
            with: fresh,
            inside: span
        )

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.map(\.title), ["어플 · 지도", "어플 · 유지"])
        XCTAssertEqual(result[0].source, .appUsage)
        XCTAssertEqual(result[0].span().duration, 20 * 60)
        XCTAssertEqual(result[0].evidence, [
            "Screen Time 시간대 합계",
            "사용 20분",
            "앱 열기 1회",
            "알림 2회",
        ])
    }

    func testScreenTimeUsageKeepsOneRecordPerApplication() {
        let start = makeDate(2026, 8, 3, 9)
        let span = TimeSpan(start: start, end: start.addingTimeInterval(hour))
        let records = ScreenTimeUsageRecordEngine.records(
            from: [
                ScreenTimeUsageSample(
                    key: "bundle:com.example.maps",
                    title: "어플 · 지도",
                    span: span,
                    duration: 12 * 60,
                    pickups: 3,
                    notifications: 0
                ),
                ScreenTimeUsageSample(
                    key: "bundle:com.example.chat",
                    title: "어플 · 메시지",
                    span: span,
                    duration: 25 * 60,
                    pickups: 8,
                    notifications: 4
                ),
                // 같은 시간대에 다시 나온 같은 앱은 한 줄로 합친다.
                ScreenTimeUsageSample(
                    key: "bundle:com.example.maps",
                    title: "어플 · 지도",
                    span: span,
                    duration: 12 * 60,
                    pickups: 3,
                    notifications: 0
                ),
            ],
            suppressedIDs: []
        )

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(
            Set(records.map(\.title)),
            ["어플 · 지도", "어플 · 메시지"]
        )
        XCTAssertEqual(Set(records.map(\.id)).count, 2)
        XCTAssertTrue(records.allSatisfy { $0.categoryID == "appUsage" })
        XCTAssertTrue(records.allSatisfy { $0.startedAt == start })
        XCTAssertEqual(
            records.first { $0.title == "어플 · 메시지" }?.span().duration,
            25 * 60
        )
        XCTAssertTrue(
            records.allSatisfy { !$0.evidence.contains(where: {
                $0.contains("카테고리")
            }) }
        )
    }

    func testScreenTimeUsageExplainsCategoryAndUnknownFallbacks() {
        let start = makeDate(2026, 8, 3, 14)
        let span = TimeSpan(start: start, end: start.addingTimeInterval(hour))
        let records = ScreenTimeUsageRecordEngine.records(
            from: [
                ScreenTimeUsageSample(
                    key: "category:소셜",
                    title: "어플 · 소셜",
                    span: span,
                    duration: 18 * 60,
                    pickups: 0,
                    notifications: 0,
                    nameSource: .category
                ),
                ScreenTimeUsageSample(
                    key: "total",
                    title: "어플",
                    span: span,
                    duration: 40 * 60,
                    pickups: 2,
                    notifications: 0,
                    nameSource: .unknown
                ),
            ],
            suppressedIDs: []
        )

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(
            records.first { $0.title == "어플 · 소셜" }?.evidence,
            [
                "Screen Time 시간대 합계",
                "사용 18분",
                "앱 이름을 읽을 수 없어 카테고리 단위로 묶었습니다",
            ]
        )
        XCTAssertEqual(
            records.first { $0.title == "어플" }?.evidence,
            [
                "Screen Time 시간대 합계",
                "사용 40분",
                "앱 열기 2회",
                "앱 이름과 카테고리를 모두 읽을 수 없어 시간대 합계만 남겼습니다",
            ]
        )
    }

    func testScreenTimeUsageDurationTextMatchesSettingsRow() {
        XCTAssertNil(ScreenTimeUsageRecordEngine.durationText(30))
        XCTAssertEqual(ScreenTimeUsageRecordEngine.durationText(14 * 60), "14분")
        XCTAssertEqual(
            ScreenTimeUsageRecordEngine.durationText(2 * hour),
            "2시간"
        )
        XCTAssertEqual(
            ScreenTimeUsageRecordEngine.durationText(2 * hour + 14 * 60),
            "2시간 14분"
        )
    }

    func testScreenTimeRetriesTransientDeviceActivityStoreErrorOnly() {
        let transient = NSError(
            domain: "DeviceActivity.DeviceActivityDataStore.DataStoreError",
            code: 0
        )
        let denied = NSError(
            domain: "DeviceActivity.DeviceActivityDataStore.DataStoreError",
            code: 2
        )

        XCTAssertTrue(ScreenTimeUsageRetryPolicy.shouldRetry(transient))
        XCTAssertFalse(ScreenTimeUsageRetryPolicy.shouldRetry(denied))
        XCTAssertEqual(ScreenTimeUsageRetryPolicy.maximumAttempts, 3)
    }

    func testDiagnosticErrorFieldsRetainDomainCodeAndDescription() {
        let error = NSError(
            domain: "TaptionPlanTests",
            code: 47,
            userInfo: [NSLocalizedDescriptionKey: "diagnostic detail"]
        )
        let fields = TaptionDiagnosticError.fields(for: error)

        XCTAssertEqual(fields["error_domain"], "TaptionPlanTests")
        XCTAssertEqual(fields["error_code"], "47")
        XCTAssertEqual(fields["error_description"], "diagnostic detail")
    }

    func testRecentWatchContactOverridesTransientInstallationFlag() {
        let now = makeDate(2026, 8, 9, 22, 0)
        XCTAssertEqual(
            AppleWatchConnectionPolicy.state(
                isSupported: true,
                isPaired: true,
                isWatchAppInstalled: false,
                isReachable: false,
                lastContactAt: now.addingTimeInterval(-60),
                now: now
            ),
            .background
        )
        XCTAssertEqual(
            AppleWatchConnectionPolicy.state(
                isSupported: true,
                isPaired: true,
                isWatchAppInstalled: false,
                isReachable: false,
                lastContactAt: now.addingTimeInterval(-31 * 60),
                now: now
            ),
            .appNotInstalled
        )
    }

    func testBundleIdentifierDisplayNameDropsReverseDNSPrefix() {
        let name = AppBundleDisplayName.displayName(forBundleIdentifier:)
        XCTAssertEqual(name("com.burbn.instagram"), "Instagram")
        XCTAssertEqual(name("com.google.ios.youtube"), "Youtube")
        XCTAssertEqual(name("net.whatsapp.WhatsApp"), "WhatsApp")
        // "com."만 떼면 "burbn.instagram"이 남는다. 마지막 조각만 써야 한다.
        XCTAssertNotEqual(name("com.burbn.instagram"), "burbn.instagram")
    }

    func testBundleIdentifierDisplayNameStripsPlatformNoise() {
        let name = AppBundleDisplayName.displayName(forBundleIdentifier:)
        XCTAssertEqual(name("com.apple.mobilesafari"), "Safari")
        XCTAssertEqual(name("com.apple.mobilemail"), "Mail")
        XCTAssertEqual(name("com.apple.MobileSMS"), "SMS")
        XCTAssertEqual(name("com.atebits.Tweetie2"), "Tweetie")
        XCTAssertEqual(name("com.example.player.ios"), "Player")
    }

    func testBundleIdentifierDisplayNameUsesCuratedKoreanNames() {
        let name = AppBundleDisplayName.displayName(forBundleIdentifier:)
        XCTAssertEqual(name("com.kakao.talk"), "카카오톡")
        XCTAssertEqual(name("viva.republica.toss"), "토스")
        XCTAssertEqual(name("COM.KAKAO.TALK"), "카카오톡")
    }

    func testBundleIdentifierDisplayNameRejectsEmptyInput() {
        let name = AppBundleDisplayName.displayName(forBundleIdentifier:)
        XCTAssertNil(name(""))
        XCTAssertNil(name("   "))
        XCTAssertNil(name("123"))
    }

    func testScreenTimeUsageNamesBundleFallbackAsEstimate() {
        let start = makeDate(2026, 8, 3, 14)
        let span = TimeSpan(start: start, end: start.addingTimeInterval(hour))
        let records = ScreenTimeUsageRecordEngine.records(
            from: [
                ScreenTimeUsageSample(
                    key: "bundle:com.burbn.instagram",
                    title: "Instagram",
                    span: span,
                    duration: 12 * 60,
                    pickups: 0,
                    notifications: 0,
                    nameSource: .bundleIdentifier
                ),
            ],
            suppressedIDs: []
        )

        XCTAssertEqual(records.first?.title, "Instagram")
        XCTAssertEqual(
            records.first?.evidence,
            [
                "Screen Time 시간대 합계",
                "사용 12분",
                "앱 이름 대신 번들 ID에서 유추한 이름입니다",
            ]
        )
    }

    // MARK: - 기록 계층·차트

    private func makeActual(
        _ title: String,
        _ categoryID: String,
        start: Date,
        minutes: Double,
        source: ActualSource = .motion,
        behavior: String? = nil
    ) -> ActualRecord {
        ActualRecord(
            planID: nil,
            title: title,
            categoryID: categoryID,
            startedAt: start,
            endedAt: start.addingTimeInterval(minutes * 60),
            source: source,
            behavior: behavior
        )
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

    func testRecordGroupingSortsCategoriesByTotalAndChildrenByStart() {
        let day = makeDate(2026, 8, 4)
        let span = TimeSpan(start: day, end: day.addingTimeInterval(24 * hour))
        let actuals = [
            makeActual(
                "Safari",
                "appUsage",
                start: day.addingTimeInterval(10 * hour),
                minutes: 22,
                source: .appUsage
            ),
            makeActual(
                "카카오톡",
                "appUsage",
                start: day.addingTimeInterval(9 * hour),
                minutes: 38,
                source: .appUsage
            ),
            makeActual(
                "수면",
                "sleep",
                start: day,
                minutes: 7 * 60
            ),
        ]

        let groups = ActualRecordGroupingEngine.groups(
            actuals: actuals,
            in: span,
            categories: CategoryCatalog.builtIn,
            asOf: day.addingTimeInterval(24 * hour)
        )

        XCTAssertEqual(groups.map(\.id), ["sleep", "appUsage"])
        XCTAssertEqual(groups[0].name, "수면")
        // 사용자 카테고리에 없는 자동 줄도 한글 이름을 갖는다.
        XCTAssertEqual(groups[1].name, "어플")
        XCTAssertEqual(groups[0].duration, 7 * hour)
        XCTAssertEqual(groups[1].duration, 60 * 60)
        XCTAssertEqual(groups[1].children.map(\.title), ["카카오톡", "Safari"])
        XCTAssertEqual(groups[1].children.map(\.duration), [38 * 60, 22 * 60])
    }

    func testChartSelectionReturnsOnlyTheTappedBucketSpan() {
        let day = makeDate(2026, 8, 3)
        let buckets = RecordChartEngine.buckets(
            actuals: [
                makeActual(
                    "걷기",
                    "movement",
                    start: day.addingTimeInterval(hour),
                    minutes: 30
                ),
                makeActual(
                    "수면",
                    "sleep",
                    start: day.addingTimeInterval(24 * hour),
                    minutes: 6 * 60
                ),
            ],
            in: TimeSpan(
                start: day,
                end: day.addingTimeInterval(7 * 24 * hour)
            ),
            unit: .day,
            calendar: Calendar(identifier: .gregorian),
            asOf: day.addingTimeInterval(7 * 24 * hour)
        )
        let selected = buckets[1]

        XCTAssertEqual(
            ReviewSelectionEngine.chartSpan(selected.id, buckets: buckets),
            selected.span
        )
        XCTAssertNil(
            ReviewSelectionEngine.chartSpan("missing", buckets: buckets)
        )
    }

    func testRecordGroupingMergesRepeatedTitlesAndClipsToSpan() {
        let day = makeDate(2026, 8, 4)
        let span = TimeSpan(
            start: day.addingTimeInterval(9 * hour),
            end: day.addingTimeInterval(12 * hour)
        )
        let actuals = [
            // 기간 앞으로 삐져나온 기록은 겹치는 만큼만 센다.
            makeActual(
                "회의",
                "work",
                start: day.addingTimeInterval(8.5 * hour),
                minutes: 60
            ),
            makeActual(
                "회의",
                "work",
                start: day.addingTimeInterval(10 * hour),
                minutes: 30
            ),
            // 같은 제목이 겹치면 한 번만 센다.
            makeActual(
                "회의",
                "work",
                start: day.addingTimeInterval(10 * hour + 15 * 60),
                minutes: 30
            ),
        ]

        let groups = ActualRecordGroupingEngine.groups(
            actuals: actuals,
            in: span,
            categories: CategoryCatalog.builtIn,
            asOf: day.addingTimeInterval(24 * hour)
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].name, "업무")
        XCTAssertEqual(groups[0].children.count, 1)
        XCTAssertEqual(groups[0].children[0].occurrenceCount, 3)
        XCTAssertEqual(groups[0].children[0].duration, 75 * 60)
        XCTAssertEqual(groups[0].duration, 75 * 60)
    }

    func testRecordGroupingRoutesActivityRecordsToSleepAndMovement() {
        let day = makeDate(2026, 8, 4)
        let span = TimeSpan(start: day, end: day.addingTimeInterval(24 * hour))
        let actuals = [
            makeActual("수면 추정", "activity", start: day, minutes: 60),
            makeActual(
                "걷기",
                "activity",
                start: day.addingTimeInterval(9 * hour),
                minutes: 30
            ),
            makeActual(
                "서 있기",
                "activity",
                start: day.addingTimeInterval(11 * hour),
                minutes: 10
            ),
        ]

        let groups = ActualRecordGroupingEngine.groups(
            actuals: actuals,
            in: span,
            categories: CategoryCatalog.builtIn,
            asOf: day.addingTimeInterval(24 * hour)
        )

        XCTAssertEqual(
            Set(groups.map(\.id)),
            ["sleep", "movement", "activity"]
        )
        XCTAssertEqual(groups.first { $0.id == "sleep" }?.duration, 60 * 60)
        XCTAssertEqual(groups.first { $0.id == "movement" }?.duration, 30 * 60)
        XCTAssertEqual(groups.first { $0.id == "activity" }?.duration, 10 * 60)
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

    func testChartBucketsSplitDurationAcrossDayBoundaries() {
        let start = makeDate(2026, 8, 3)
        let span = TimeSpan(
            start: start,
            end: start.addingTimeInterval(7 * 24 * hour)
        )
        let actuals = [
            // 자정을 넘긴 수면은 두 칸으로 갈린다.
            makeActual(
                "수면",
                "sleep",
                start: start.addingTimeInterval(23 * hour),
                minutes: 4 * 60
            ),
            makeActual(
                "걷기",
                "movement",
                start: start.addingTimeInterval(10 * hour),
                minutes: 30
            ),
        ]

        let buckets = RecordChartEngine.buckets(
            actuals: actuals,
            in: span,
            unit: .day,
            calendar: utcCalendar,
            asOf: start.addingTimeInterval(7 * 24 * hour)
        )

        XCTAssertEqual(buckets.count, 7)
        XCTAssertEqual(buckets[0].total, 90 * 60)
        XCTAssertEqual(
            buckets[0].slices.map(\.categoryID),
            ["sleep", "movement"]
        )
        XCTAssertEqual(buckets[0].slices[0].duration, 60 * 60)
        XCTAssertEqual(buckets[1].total, 3 * hour)
        XCTAssertEqual(buckets[2].total, 0)
    }

    func testDayPhaseBucketsCompleteEachPastDayTo24Hours() {
        let day = dayPhaseDay()
        let period = TimeSpan(
            start: day.start,
            end: day.end.addingTimeInterval(24 * hour)
        )
        let buckets = RecordChartEngine.phaseBuckets(
            actuals: [
                sleepActual(0, 7, on: day),
                stationaryContext(.work, 9, 17, on: day),
            ],
            travel: [],
            stays: [],
            placeKinds: [:],
            in: period,
            unit: .day,
            calendar: utcCalendar,
            asOf: period.end
        )

        XCTAssertEqual(buckets.count, 2)
        XCTAssertEqual(buckets[0].total, 24 * hour)
        XCTAssertEqual(
            buckets[0].slices.first {
                $0.categoryID == DayPhase.unconfirmed.rawValue
            }?.duration,
            9 * hour
        )
        XCTAssertEqual(buckets[1].total, 24 * hour)
        XCTAssertEqual(
            buckets[1].slices.map(\.categoryID),
            [DayPhase.unconfirmed.rawValue]
        )
    }

    func testChartBucketsUseOneColumnPerMonthForTheYearScale() {
        let start = makeDate(2026, 1, 1)
        let span = TimeSpan(start: start, end: makeDate(2027, 1, 1))
        let actuals = [
            makeActual(
                "수면",
                "sleep",
                start: makeDate(2026, 3, 2, 22),
                minutes: 6 * 60
            )
        ]

        let buckets = RecordChartEngine.buckets(
            actuals: actuals,
            in: span,
            unit: .month,
            calendar: utcCalendar,
            asOf: makeDate(2027, 1, 1)
        )

        XCTAssertEqual(buckets.count, 12)
        XCTAssertEqual(buckets[2].total, 6 * hour)
        XCTAssertEqual(buckets.map(\.total).reduce(0, +), 6 * hour)
    }

    func testClockNowHandOnlyAppearsInsideTheShownDay() {
        let day = makeDate(2026, 8, 4)
        let span = TimeSpan(start: day, end: day.addingTimeInterval(24 * hour))

        XCTAssertEqual(
            RecordClockEngine.nowFraction(
                in: span,
                asOf: day.addingTimeInterval(6 * hour)
            ) ?? -1,
            0.25,
            accuracy: 0.0001
        )
        XCTAssertNil(
            RecordClockEngine.nowFraction(
                in: span,
                asOf: day.addingTimeInterval(-1)
            )
        )
        XCTAssertNil(
            RecordClockEngine.nowFraction(
                in: span,
                asOf: day.addingTimeInterval(24 * hour)
            )
        )
    }

    func testClockPlaybackProgressSpansTheWholeDayOnce() {
        let start = makeDate(2026, 8, 4, 9)

        XCTAssertNil(RecordClockEngine.progress(start: nil, now: start))
        XCTAssertEqual(
            RecordClockEngine.progress(start: start, now: start) ?? -1,
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            RecordClockEngine.progress(
                start: start,
                now: start.addingTimeInterval(
                    RecordClockEngine.sweepDuration / 2
                )
            ) ?? -1,
            0.5,
            accuracy: 0.0001
        )
        // 한 바퀴를 넘겨도 1을 넘지 않는다.
        XCTAssertEqual(
            RecordClockEngine.progress(
                start: start,
                now: start.addingTimeInterval(
                    RecordClockEngine.sweepDuration * 3
                )
            ) ?? -1,
            1,
            accuracy: 0.0001
        )
    }

    func testClockPlaybackStopsAtNowForToday() {
        let day = makeDate(2026, 8, 4)
        let span = TimeSpan(
            start: day,
            end: day.addingTimeInterval(24 * hour)
        )
        let now = day.addingTimeInterval(6 * hour)
        let playbackStartedAt = makeDate(2026, 8, 5)
        let end = RecordClockEngine.playbackEndFraction(in: span, asOf: now)

        XCTAssertEqual(end, 0.25, accuracy: 0.0001)
        XCTAssertEqual(
            RecordClockEngine.progress(
                start: playbackStartedAt,
                now: playbackStartedAt.addingTimeInterval(24),
                endFraction: end
            ) ?? -1,
            0.25,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            RecordClockEngine.playbackEndFraction(
                in: span,
                asOf: span.end.addingTimeInterval(1)
            ),
            1
        )
        XCTAssertEqual(
            RecordClockEngine.playbackEndFraction(
                in: span,
                asOf: span.start.addingTimeInterval(-1)
            ),
            0
        )
    }

    func testClockDragMapsEveryQuarterTurnLikeAClock() {
        XCTAssertEqual(RecordClockEngine.labeledHours, Array(0..<24))
        XCTAssertEqual(
            RecordClockEngine.clockFraction(
                x: 100,
                y: 0,
                centerX: 100,
                centerY: 100
            ),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            RecordClockEngine.clockFraction(
                x: 200,
                y: 100,
                centerX: 100,
                centerY: 100
            ),
            0.25,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            RecordClockEngine.clockFraction(
                x: 100,
                y: 200,
                centerX: 100,
                centerY: 100
            ),
            0.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            RecordClockEngine.clockFraction(
                x: 0,
                y: 100,
                centerX: 100,
                centerY: 100
            ),
            0.75,
            accuracy: 0.0001
        )
    }

    func testLinearClockKeepsCenteredPlayheadMappedToScrollOffset() {
        XCTAssertEqual(
            RecordClockEngine.playheadFraction(
                contentOffset: 600,
                timelineWidth: 2_400
            ),
            0.25,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            RecordClockEngine.contentOffset(
                for: 0.75,
                timelineWidth: 2_400
            ),
            1_800,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            RecordClockEngine.playheadFraction(
                contentOffset: 3_000,
                timelineWidth: 2_400
            ),
            1
        )
        XCTAssertEqual(
            RecordClockEngine.contentOffset(
                for: -0.5,
                timelineWidth: 2_400
            ),
            0
        )
    }

    func testClockPlaybackRevealsArcsAsThePlayheadPassesThem() {
        let day = makeDate(2026, 8, 4)
        let span = TimeSpan(start: day, end: day.addingTimeInterval(24 * hour))
        let rings = RecordChartEngine.clockRings(
            actuals: [
                makeActual("수면", "sleep", start: day, minutes: 6 * 60),
                makeActual(
                    "걷기",
                    "movement",
                    start: day.addingTimeInterval(12 * hour),
                    minutes: 60
                ),
            ],
            in: span,
            asOf: day.addingTimeInterval(24 * hour)
        )

        // 재생 전에는 자르지 않는다.
        XCTAssertEqual(
            RecordClockEngine.rings(rings, revealedThrough: nil).count,
            2
        )

        // 재생머리가 수면 한가운데면 수면만, 그것도 절반만 보인다.
        let half = RecordClockEngine.rings(rings, revealedThrough: 0.125)
        XCTAssertEqual(half.map(\.categoryID), ["sleep"])
        XCTAssertEqual(half[0].arcs[0].endFraction, 0.125, accuracy: 0.0001)
        XCTAssertEqual(
            RecordClockEngine.categoryIDs(in: rings, at: 0.125),
            ["sleep"]
        )

        // 다 지나가면 원래 원호가 그대로 남는다.
        let whole = RecordClockEngine.rings(rings, revealedThrough: 1)
        XCTAssertEqual(whole.map(\.categoryID), ["sleep", "movement"])
        XCTAssertEqual(whole[0].arcs[0].endFraction, 0.25, accuracy: 0.0001)
        XCTAssertTrue(
            RecordClockEngine.categoryIDs(in: rings, at: 0.4).isEmpty
        )
    }

    func testClockLegendKeepsOnlyTheChosenCategory() {
        let day = makeDate(2026, 8, 4)
        let span = TimeSpan(start: day, end: day.addingTimeInterval(24 * hour))
        let rings = RecordChartEngine.clockRings(
            actuals: [
                makeActual("수면", "sleep", start: day, minutes: 6 * 60),
                makeActual(
                    "걷기",
                    "movement",
                    start: day.addingTimeInterval(12 * hour),
                    minutes: 60
                ),
            ],
            in: span,
            asOf: day.addingTimeInterval(24 * hour)
        )

        XCTAssertEqual(
            RecordClockEngine.rings(rings, isolating: nil).count,
            2
        )
        XCTAssertEqual(
            RecordClockEngine.rings(rings, isolating: "movement")
                .map(\.categoryID),
            ["movement"]
        )
        XCTAssertTrue(
            RecordClockEngine.rings(rings, isolating: "sleepless").isEmpty
        )
    }

    func testClockSwipeMovesADayOnlyOnADeliberateHorizontalDrag() {
        XCTAssertEqual(
            RecordClockEngine.swipeStep(width: -80, height: 10),
            1
        )
        XCTAssertEqual(
            RecordClockEngine.swipeStep(width: 80, height: -10),
            -1
        )
        // 짧게 흔든 손가락은 날짜를 넘기지 않는다.
        XCTAssertNil(RecordClockEngine.swipeStep(width: -20, height: 4))
        // 세로가 더 길면 목록을 굴리는 중이다.
        XCTAssertNil(RecordClockEngine.swipeStep(width: -60, height: 120))
    }

    func testAutomaticRowVocabularyIsSharedByEverySurface() {
        XCTAssertEqual(TimelineRowKind.appUsage.title, "어플")
        XCTAssertEqual(ScreenTimeUsageRecordEngine.laneTitle, "어플")
        XCTAssertEqual(TaptionWidgetLane.appUsage.title, "어플")
        XCTAssertEqual(
            TaptionWidgetLane.movement.systemImage,
            TimelineRowKind.movement.systemImage
        )
        XCTAssertEqual(TaptionWidgetLane.schedule.title, "일정")
        XCTAssertEqual(TaptionWidgetLane.action.title, "액션")
        XCTAssertEqual(
            TimelineRowOrder.defaults,
            [
                "calendar",
                "location",
                "movement",
                "sleep",
                "activity",
                "appUsage",
                "weather",
                "photo",
                "memo",
            ]
        )
        XCTAssertNil(TimelineRowKind(categoryID: "work"))
        XCTAssertEqual(TimelineRowKind(categoryID: "schedule"), .calendar)
        // 메모도 일정·위치·수면과 같은 자격의 줄이다.
        XCTAssertEqual(TimelineRowKind.memo.title, "메모")
        XCTAssertEqual(TimelineRowKind.memo.systemImage, "note.text")
        XCTAssertEqual(TimelineRowKind(categoryID: "memo"), .memo)
        XCTAssertEqual(
            MemoTimelineEngine.categoryID,
            TimelineRowKind.memo.rawValue
        )
    }

    func testDurationTextMatchesTheScreenTimeWording() {
        XCTAssertEqual(DurationText.korean(0), "0분")
        XCTAssertEqual(DurationText.korean(38 * 60), "38분")
        XCTAssertEqual(DurationText.korean(2 * hour), "2시간")
        XCTAssertEqual(DurationText.korean(2 * hour + 14 * 60), "2시간 14분")
        XCTAssertEqual(DurationText.signedKorean(-90 * 60), "－1시간 30분")
    }

    /// 같은 앱 사용 기록이 시간표 상세에서는 "1분 미만", 기록 목록에서는
    /// "0분"으로 읽히던 자리. 두 화면이 같은 문구를 쓴다.
    func testSubMinuteAppUsageReadsTheSameOnBothSurfaces() {
        // 시간표 상세는 durationText 가 nil 이면 "1분 미만"을 적는다.
        XCTAssertNil(ScreenTimeUsageRecordEngine.durationText(45))
        XCTAssertEqual(DurationText.koreanAtLeastAMinute(45), "1분 미만")
        XCTAssertEqual(DurationText.koreanAtLeastAMinute(59), "1분 미만")
        // 아무 일도 없던 0초까지 부풀리지는 않는다.
        XCTAssertEqual(DurationText.koreanAtLeastAMinute(0), "0분")
        XCTAssertEqual(DurationText.koreanAtLeastAMinute(60), "1분")
        XCTAssertEqual(DurationText.koreanAtLeastAMinute(2 * hour), "2시간")
        XCTAssertEqual(
            DurationText.koreanAtLeastAMinute(2 * hour + 14 * 60),
            "2시간 14분"
        )
    }

    // MARK: - Stationary context

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
        XCTAssertEqual(records.first?.modelVersion, "stationary-context-v1")
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

    /// 일과 고리는 60초 안에서 맞닿은 근무만 붙인다. 기록이 이미 한 줄이면
    /// 고리도 한 조각이라, 둘이 서로 다른 그림을 그리지 않는다.
    func testJoinedWorkRecordGivesTheDayPhaseRingOneWorkArc() {
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
                floor: 2
            ),
        ]
        let readings = officeReadings(
            from: morning,
            count: 55,
            metersFromAnchor: { _ in 0 }
        )
        let records = officeRecords(
            stays: stays,
            readings: readings,
            inside: day
        )
        let phases = DayPhaseEngine.phases(
            actuals: records,
            travel: [],
            stays: stays,
            placeKinds: [officeKey: .company],
            in: day,
            asOf: day.end
        )

        XCTAssertEqual(phases.filter { $0.phase == .work }.count, 1)
        XCTAssertEqual(
            phases.first { $0.phase == .work }?.span,
            TimeSpan(
                start: morning,
                end: morning.addingTimeInterval(9 * hour)
            )
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

    private var officeKey: String { "frequent-office" }

    private func officePoint(_ metersNorth: Double) -> GeoPoint {
        GeoPoint(
            latitude: 37.5 + metersNorth / 111_320,
            longitude: 127,
            altitude: 40,
            horizontalAccuracy: 12,
            verticalAccuracy: 8
        )
    }

    private func officeStay(
        start: Date,
        end: Date,
        floor: Int
    ) -> PlaceStay {
        PlaceStay(
            placeKey: officeKey,
            displayName: "회사",
            floor: floor,
            span: TimeSpan(start: start, end: end),
            confidence: .high,
            point: officePoint(0),
            isConfirmed: true,
            floorEvidence: FloorEvidence(
                measuredAt: start,
                relativeAltitudeMeters: Double(floor) * 3
            )
        )
    }

    private func officeReadings(
        from start: Date,
        count: Int,
        metersFromAnchor: (Int) -> Double
    ) -> [SensorReading] {
        (0..<count).map { step in
            SensorReading(
                timestamp: start.addingTimeInterval(Double(step) * 600),
                point: officePoint(metersFromAnchor(step)),
                motion: .stationary,
                motionConfidence: .high,
                relativeAltitudeMeters: 0
            )
        }
    }

    private func floorChanging(
        _ readings: [SensorReading],
        after index: Int
    ) -> [SensorReading] {
        readings.enumerated().map { offset, reading in
            var value = reading
            value.systemFloor = offset < index ? 20 : 2
            return value
        }
    }

    /// 사용자가 설정에서 맞춘 반경 120m·최소 체류 10분을 그대로 쓴다.
    private func officeRecords(
        stays: [PlaceStay],
        readings: [SensorReading],
        inside: TimeSpan? = nil,
        stationarySpans: [TimeSpan] = []
    ) -> [ActualRecord] {
        let span = inside ?? TimeSpan(
            start: makeDate(2026, 8, 4, 0, 0),
            end: makeDate(2026, 8, 5, 0, 0)
        )
        return StationaryContextActualEngine.records(
            stays: stays,
            placeKinds: [officeKey: .company],
            placeAnchors: [
                officeKey: FrequentPlaceAnchor(
                    point: officePoint(0),
                    radiusMeters: 120
                )
            ],
            stationarySpans: stationarySpans,
            readings: readings,
            inside: span,
            calendar: utcCalendar,
            now: span.end
        )
    }

    private func makeContextStay(
        start: Date,
        end: Date,
        placeKey: String = "frequent-context"
    ) -> PlaceStay {
        PlaceStay(
            placeKey: placeKey,
            displayName: "장소",
            span: TimeSpan(start: start, end: end),
            confidence: .medium
        )
    }

    private func makeContextEvent(
        title: String,
        start: Date,
        end: Date,
        attendeeCount: Int? = nil
    ) -> CalendarRecord {
        CalendarRecord(
            id: title,
            calendarID: "calendar",
            title: title,
            span: TimeSpan(start: start, end: end),
            isAllDay: false,
            calendarTitle: "업무",
            attendeeCount: attendeeCount,
            isCancelled: false
        )
    }

    private func makeContextActual(
        source: ActualSource,
        start: Date,
        end: Date
    ) -> ActualRecord {
        ActualRecord(
            planID: nil,
            title: "자동 기록",
            categoryID: "activity",
            startedAt: start,
            endedAt: end,
            source: source,
            confidence: .medium,
            createdAt: start
        )
    }

    private func makeContextReading(
        at timestamp: Date,
        flat: Bool
    ) -> SensorReading {
        SensorReading(
            timestamp: timestamp,
            motion: .stationary,
            motionConfidence: .high,
            deviceMotion: DeviceMotionSnapshot(
                gravity: SensorVector3(
                    x: 0,
                    y: flat ? 0 : -0.99,
                    z: flat ? -0.99 : 0.02
                ),
                userAcceleration: SensorVector3(x: 0, y: 0, z: 0),
                rotationRate: SensorVector3(x: 0, y: 0, z: 0),
                attitudeRadians: SensorVector3(x: 0, y: 0, z: 0)
            ),
            deviceMotionSummary: DeviceMotionSummary(
                sampleCount: 100,
                meanUserAccelerationG: 0.001,
                userAccelerationStandardDeviationG: 0.001,
                peakUserAccelerationG: 0.004,
                meanRotationRateRadiansPerSecond: 0.001,
                rotationRateStandardDeviationRadiansPerSecond: 0.001,
                peakRotationRateRadiansPerSecond: 0.003
            )
        )
    }

    func testSummaryBucketsSplitRecordsAcrossDayBoundaries() {
        let engine = TimelineAggregationEngine(calendar: utcCalendar)
        let outer = TimeSpan(
            start: makeDate(2026, 7, 1),
            end: makeDate(2026, 7, 8)
        )
        let crossing = PlanRecord(
            title: "밤샘",
            span: TimeSpan(
                start: makeDate(2026, 7, 2, 22, 0),
                end: makeDate(2026, 7, 3, 4, 0)
            ),
            categoryID: "project"
        )
        let morning = PlanRecord(
            title: "오전",
            span: TimeSpan(
                start: makeDate(2026, 7, 3, 9, 0),
                end: makeDate(2026, 7, 3, 11, 0)
            ),
            categoryID: "project"
        )
        let overlapping = PlanRecord(
            title: "겹침",
            span: TimeSpan(
                start: makeDate(2026, 7, 3, 10, 0),
                end: makeDate(2026, 7, 3, 12, 0)
            ),
            categoryID: "project"
        )
        let sleep = ActualRecord(
            planID: nil,
            title: "수면",
            categoryID: "sleep",
            startedAt: makeDate(2026, 7, 2, 23, 0),
            endedAt: makeDate(2026, 7, 3, 5, 0),
            source: .healthKit
        )
        let early = PhotoMoment(
            id: "early",
            capturedAt: makeDate(2026, 7, 3, 8, 0),
            pixelWidth: 100,
            pixelHeight: 100,
            isFavorite: false,
            isHiddenFromTimeline: false
        )
        let late = PhotoMoment(
            id: "late",
            capturedAt: makeDate(2026, 7, 3, 20, 0),
            pixelWidth: 100,
            pixelHeight: 100,
            isFavorite: false,
            isHiddenFromTimeline: false
        )
        let hidden = PhotoMoment(
            id: "hidden",
            capturedAt: makeDate(2026, 7, 3, 21, 0),
            pixelWidth: 100,
            pixelHeight: 100,
            isFavorite: false,
            isHiddenFromTimeline: true
        )

        let buckets = engine.buckets(
            of: .day,
            inside: outer,
            plans: [crossing, morning, overlapping],
            actuals: [sleep],
            photos: [late, early, hidden]
        )

        XCTAssertEqual(buckets.count, 7)

        func duration(
            _ bucket: SummaryBucket,
            _ categoryID: String
        ) -> (planned: TimeInterval, actual: TimeInterval) {
            guard let value = bucket.categories.first(where: {
                $0.categoryID == categoryID
            }) else {
                return (0, 0)
            }
            return (value.planned, value.actual)
        }

        XCTAssertEqual(duration(buckets[1], "project").planned, 2 * hour)
        XCTAssertEqual(duration(buckets[1], "sleep").actual, hour)
        // 겹치는 계획은 합쳐서 센다. 22시–4시 중 4시간에 9시–12시 3시간.
        XCTAssertEqual(duration(buckets[2], "project").planned, 7 * hour)
        XCTAssertEqual(duration(buckets[2], "sleep").actual, 5 * hour)
        XCTAssertEqual(buckets[2].photoCount, 2)
        XCTAssertEqual(buckets[2].representativePhotoID, "early")

        // 기록이 하나도 걸치지 않는 칸도 같은 분류 열쇠를 0으로 남긴다.
        XCTAssertEqual(duration(buckets[0], "project").planned, 0)
        XCTAssertEqual(duration(buckets[0], "sleep").actual, 0)
        XCTAssertEqual(buckets[0].photoCount, 0)
        XCTAssertNil(buckets[0].representativePhotoID)
    }

    // MARK: - 메모는 메모

    /// The placeholder factory always produced exactly this plan.
    private func makeMemoShellPlan(
        categoryID: String = "activity",
        categoryName: String = "활동",
        start: Date
    ) -> PlanRecord {
        PlanRecord(
            title: "메모 - \(categoryName)",
            span: TimeSpan(start: start, end: start.addingTimeInterval(60)),
            categoryID: categoryID,
            isImportant: false
        )
    }

    private func makeSnapshot(
        plans: [PlanRecord] = [],
        actuals: [ActualRecord] = [],
        recordLinks: [RecordLink] = [],
        memos: [ActionMemo] = []
    ) -> TaptionDataSnapshot {
        var snapshot = TaptionDataSnapshot.empty
        snapshot.plans = plans
        snapshot.actuals = actuals
        snapshot.recordLinks = recordLinks
        snapshot.memos = memos
        return snapshot
    }

    func testMemoShellMigrationLiftsMemoAndRemovesShellPlan() {
        let start = makeDate(2026, 8, 4, 9, 30)
        let shell = makeMemoShellPlan(start: start)
        var snapshot = makeSnapshot(
            plans: [shell],
            memos: [
                ActionMemo(planID: shell.id, kind: .idea, text: "회의 정리"),
            ]
        )

        MemoShellPlanMigration.apply(to: &snapshot)

        XCTAssertTrue(snapshot.plans.isEmpty)
        XCTAssertEqual(snapshot.memos.count, 1)
        let lifted = snapshot.memos[0]
        XCTAssertNil(lifted.planID)
        XCTAssertEqual(lifted.categoryID, "activity")
        XCTAssertEqual(lifted.occurredAt, start)
        XCTAssertEqual(lifted.text, "회의 정리")
    }

    func testMemoShellMigrationKeepsRealOneMinuteUserPlans() {
        let start = makeDate(2026, 8, 4, 9, 30)
        let sameShapeDifferentTitle = PlanRecord(
            title: "약 먹기",
            span: TimeSpan(start: start, end: start.addingTimeInterval(60)),
            categoryID: "health"
        )
        let importantShellLookalike = PlanRecord(
            title: "메모 - 활동",
            span: TimeSpan(start: start, end: start.addingTimeInterval(60)),
            categoryID: "activity",
            isImportant: true
        )
        let longerShellLookalike = PlanRecord(
            title: "메모 - 활동",
            span: TimeSpan(start: start, end: start.addingTimeInterval(120)),
            categoryID: "activity"
        )
        let trackedShellLookalike = PlanRecord(
            title: "메모 - 활동",
            span: TimeSpan(start: start, end: start.addingTimeInterval(60)),
            categoryID: "activity"
        )
        let linkedShellLookalike = PlanRecord(
            title: "메모 - 활동",
            span: TimeSpan(start: start, end: start.addingTimeInterval(60)),
            categoryID: "activity"
        )
        var snapshot = makeSnapshot(
            plans: [
                sameShapeDifferentTitle,
                importantShellLookalike,
                longerShellLookalike,
                trackedShellLookalike,
                linkedShellLookalike,
            ],
            actuals: [
                ActualRecord(
                    planID: trackedShellLookalike.id,
                    title: "메모 - 활동",
                    categoryID: "activity",
                    startedAt: start,
                    endedAt: start.addingTimeInterval(60),
                    source: .timer
                ),
            ],
            recordLinks: [
                RecordLink(
                    fromNodeID: "action.\(linkedShellLookalike.id.uuidString)",
                    toNodeID: "action.\(sameShapeDifferentTitle.id.uuidString)"
                ),
            ]
        )
        let before = snapshot.plans

        MemoShellPlanMigration.apply(to: &snapshot)

        XCTAssertEqual(snapshot.plans, before)
    }

    func testMemoShellMigrationIsIdempotent() {
        let start = makeDate(2026, 8, 4, 9, 30)
        let shell = makeMemoShellPlan(start: start)
        let keeper = PlanRecord(
            title: "논문 읽기",
            span: TimeSpan(start: start, end: start.addingTimeInterval(3_600)),
            categoryID: "study"
        )
        var snapshot = makeSnapshot(
            plans: [shell, keeper],
            memos: [
                ActionMemo(planID: shell.id, kind: .idea, text: "회의 정리"),
                ActionMemo(planID: keeper.id, kind: .idea, text: "3장까지"),
            ]
        )

        MemoShellPlanMigration.apply(to: &snapshot)
        let once = snapshot
        MemoShellPlanMigration.apply(to: &snapshot)

        XCTAssertEqual(snapshot, once)
        XCTAssertEqual(snapshot.plans.map(\.id), [keeper.id])
        XCTAssertEqual(
            snapshot.memos.first { $0.text == "3장까지" }?.planID,
            keeper.id
        )
    }

    @MainActor
    func testSavingCategoryMemoCreatesNoPlan() async {
        let repository = InMemoryPlanRepository()
        let model = AppModel(repository: repository, cloudSyncService: nil)
        let day = makeDate(2026, 8, 4, 9, 30)

        model.addMemo(
            text: "무릎 상태 확인",
            kind: .idea,
            categoryID: "activity",
            on: day
        )

        XCTAssertTrue(model.snapshot.plans.isEmpty)
        XCTAssertEqual(model.snapshot.memos.count, 1)
        let saved = model.memos(forCategoryID: "activity", on: day)
        XCTAssertEqual(saved.map(\.text), ["무릎 상태 확인"])
        XCTAssertNil(saved.first?.planID)
    }

    // MARK: - 메모 줄

    /// 메모 입력의 입구는 하나뿐이다. 계획도 기록도 카테고리도 고르지 않고
    /// 순간 하나만 받아 저장하며, 그 순간이 곧 메모 줄에서의 자리다.
    @MainActor
    func testGlobalMemoEntryHasNoHostAndLandsOnTheMemoRowAtOccurredAt() async throws {
        let model = AppModel(
            repository: InMemoryPlanRepository(),
            cloudSyncService: nil
        )
        let instant = makeDate(2026, 8, 4, 14, 12)
        let day = TimeSpan(
            start: makeDate(2026, 8, 4),
            end: makeDate(2026, 8, 5)
        )

        model.openMemoEntry(at: instant)
        XCTAssertEqual(model.detail, .memo)
        XCTAssertEqual(model.memoEntry?.occurredAt, instant)
        model.addMemoAtEntryInstant(text: "여기서 막혔다", kind: .blocker)

        XCTAssertTrue(model.snapshot.plans.isEmpty)
        let saved = try XCTUnwrap(model.snapshot.memos.first)
        XCTAssertEqual(model.snapshot.memos.count, 1)
        XCTAssertNil(saved.planID)
        XCTAssertNil(saved.targetID)
        XCTAssertEqual(saved.categoryID, MemoTimelineEngine.categoryID)
        XCTAssertEqual(saved.occurredAt, instant)

        let markers = MemoTimelineEngine.markers(
            from: model.timelineMemos(in: day),
            in: day,
            visibleDuration: day.duration
        )
        XCTAssertEqual(markers.map(\.span.start), [instant])
        XCTAssertEqual(markers.map(\.title), ["여기서 막혔다"])
        XCTAssertEqual(markers.map(\.memoIDs), [[saved.id]])

        // 표식을 다시 누르면 그 자리의 메모가 열린다.
        let marker = try XCTUnwrap(markers.first)
        model.openMemoEntry(
            at: marker.span.start,
            memoIDs: MemoTimelineEngine.memoIDs(
                in: marker.span,
                from: model.snapshot.memos
            )
        )
        XCTAssertEqual(model.memoEntryMemos.map(\.id), [saved.id])
        model.deleteMemo(saved.id)
        XCTAssertTrue(model.memoEntryMemos.isEmpty)
        XCTAssertEqual(model.memoEntry?.memoIDs, [])
    }

    /// 메모를 더해도 시간표가 다시 그려지지 않으면 새 메모가 줄에 나타나지
    /// 않는다. 배치 캐시를 깨우는 개정 번호가 메모까지 본다.
    @MainActor
    func testSavingAMemoInvalidatesTheTimelineLayout() async {
        let model = AppModel(
            repository: InMemoryPlanRepository(),
            cloudSyncService: nil
        )
        let before = model.timelineRevision
        model.openMemoEntry(at: makeDate(2026, 8, 4, 14, 12))
        model.addMemoAtEntryInstant(text: "여기서 막혔다", kind: .blocker)
        XCTAssertNotEqual(model.timelineRevision, before)
    }

    /// 순간을 그리는 표식이 화소보다 얇아지면 안 된다. 붙어 있는 메모는 낱개로
    /// 그리지 않고 하나로 합친다 — 눈금판 띠와 같은 기준을 쓴다.
    func testClusteredMemosMergeIntoOneMarkerInsteadOfSlivers() throws {
        let base = makeDate(2026, 8, 4, 9, 0)
        let day = TimeSpan(
            start: makeDate(2026, 8, 4),
            end: makeDate(2026, 8, 5)
        )
        let clustered = (0..<5).map { offset in
            memoFixture(at: base.addingTimeInterval(Double(offset) * 60))
        }

        let merged = MemoTimelineEngine.markers(
            from: clustered,
            in: day,
            visibleDuration: day.duration
        )
        let marker = try XCTUnwrap(merged.first)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(marker.count, 5)
        XCTAssertEqual(marker.title, "메모 5개")
        XCTAssertEqual(marker.span.start, base)
        // 합쳐도 표식 하나 길이 아래로는 내려가지 않는다.
        XCTAssertGreaterThanOrEqual(
            marker.span.duration,
            MemoTimelineEngine.markerDuration
        )
        XCTAssertEqual(
            MemoTimelineEngine.memoIDs(in: marker.span, from: clustered),
            clustered.map(\.id)
        )

        // 표식 하나 길이보다 멀리 떨어진 메모는 합쳐지지 않는다.
        let apart = clustered + [
            memoFixture(at: base.addingTimeInterval(3_600)),
        ]
        let separate = MemoTimelineEngine.markers(
            from: apart,
            in: day,
            visibleDuration: day.duration
        )
        XCTAssertEqual(separate.map(\.count), [5, 1])
        // 이웃 표식의 메모를 끌어오지 않는다.
        XCTAssertEqual(
            MemoTimelineEngine.memoIDs(
                in: try XCTUnwrap(separate.first).span,
                from: apart
            )
            .count,
            5
        )
    }

    /// 주·월·년으로 넓힐수록 표식은 더 크게 뭉친다. 하루에서 30분씩 떨어져
    /// 보이던 메모 셋은 주 배율에서 이미 한 표식이다.
    func testMemoRowCollapsesFurtherAsTheScaleWidens() throws {
        let base = makeDate(2026, 8, 4, 9, 0)
        let memos = (0..<3).map { offset in
            memoFixture(at: base.addingTimeInterval(Double(offset) * 30 * 60))
        }
        let day = TimeSpan(
            start: makeDate(2026, 8, 4),
            end: makeDate(2026, 8, 5)
        )
        let week = TimeSpan(
            start: makeDate(2026, 8, 3),
            end: makeDate(2026, 8, 10)
        )
        let month = TimeSpan(
            start: makeDate(2026, 8, 1),
            end: makeDate(2026, 9, 1)
        )
        let year = TimeSpan(
            start: makeDate(2026, 1, 1),
            end: makeDate(2027, 1, 1)
        )

        func markers(_ span: TimeSpan) -> [MemoTimelineEngine.Marker] {
            MemoTimelineEngine.markers(
                from: memos,
                in: span,
                visibleDuration: span.duration
            )
        }

        XCTAssertEqual(markers(day).map(\.count), [1, 1, 1])
        XCTAssertEqual(markers(week).map(\.count), [3])
        XCTAssertEqual(markers(month).map(\.count), [3])
        XCTAssertEqual(markers(year).map(\.count), [3])
        XCTAssertEqual(markers(year).map(\.title), ["메모 3개"])
        // 넓은 배율일수록 더 많이 합친다.
        let intervals = [day, week, month, year].map {
            MemoTimelineEngine.clusterInterval(visibleDuration: $0.duration)
        }
        XCTAssertEqual(intervals, intervals.sorted())
        XCTAssertEqual(intervals.first, MemoTimelineEngine.markerDuration)
        // 기간 밖의 메모는 그 줄에 오르지 않는다.
        XCTAssertTrue(
            MemoTimelineEngine.markers(
                from: memos,
                in: TimeSpan(
                    start: makeDate(2026, 8, 5),
                    end: makeDate(2026, 8, 6)
                ),
                visibleDuration: 86_400
            )
            .isEmpty
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

    /// 메모는 "지금" 남기는 것이 기본이지만, 지난 기간을 펼쳐 두었다면 그
    /// 기간에 남는다. 어제에 남긴 메모는 어제에 남는다.
    func testMemoEntryInstantFollowsTheTimelineNotTheWallClock() {
        let now = makeDate(2026, 8, 4, 14, 0)
        XCTAssertEqual(
            MemoTimelineEngine.entryDate(
                now: now,
                visibleSpan: TimeSpan(
                    start: makeDate(2026, 8, 4),
                    end: makeDate(2026, 8, 5)
                )
            ),
            now
        )
        XCTAssertEqual(
            MemoTimelineEngine.entryDate(
                now: now,
                visibleSpan: TimeSpan(
                    start: makeDate(2026, 8, 3),
                    end: makeDate(2026, 8, 4)
                )
            ),
            makeDate(2026, 8, 3, 12, 0)
        )
    }

    private func memoFixture(at instant: Date) -> ActionMemo {
        ActionMemo(
            categoryID: MemoTimelineEngine.categoryID,
            occurredAt: instant,
            kind: .idea,
            text: "메모 \(instant.timeIntervalSinceReferenceDate)",
            createdAt: instant,
            updatedAt: instant
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

        let repository = FilePlanRepository(
            fileURL: directory.appendingPathComponent("taption-data-v1.json")
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

    /// Archives written before memos had their own identity carry a required
    /// `planID` and neither `categoryID` nor `occurredAt`.
    func testLegacyMemoDecodesWithPlanDerivedDefaults() throws {
        let planID = UUID()
        let createdAt = makeDate(2026, 8, 4, 9, 30)
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "planID": "\(planID.uuidString)",
          "kind": "idea",
          "text": "예전 메모",
          "attachments": [],
          "isHighlightedInReview": true,
          "createdAt": \(createdAt.timeIntervalSince1970),
          "updatedAt": \(createdAt.timeIntervalSince1970)
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let memo = try decoder.decode(
            ActionMemo.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(memo.planID, planID)
        XCTAssertNil(memo.categoryID)
        XCTAssertEqual(memo.occurredAt, createdAt)
    }

    // MARK: - 기록 화면에서 여러 칸 고르기

    /// 떨어져 있는 두 주를 고르면 그 사이의 주는 어디에도 들어가지 않는다.
    /// 합계와 목록이 같은 구간 묶음을 읽으므로 두 값이 어긋나지 않는다.
    func testNonContiguousBucketSelectionAddsOnlyChosenBuckets() {
        let engine = TimelineAggregationEngine(calendar: utcCalendar)
        let asOf = makeDate(2026, 9, 1)
        let period = engine.interval(
            for: .month,
            containing: makeDate(2026, 8, 15)
        )
        let buckets = ReviewSelectionEngine.buckets(
            for: .month,
            in: period,
            calendar: engine.calendar
        )
        XCTAssertEqual(buckets.map(\.label), ["1주", "2주", "3주", "4주", "5주", "6주"])
        XCTAssertEqual(buckets[1].span.start, makeDate(2026, 8, 3))
        XCTAssertEqual(buckets[3].span.start, makeDate(2026, 8, 17))

        let chosen = ActualRecord(
            planID: nil,
            title: "학습",
            categoryID: "study",
            startedAt: makeDate(2026, 8, 4, 9, 0),
            endedAt: makeDate(2026, 8, 4, 11, 0),
            source: .manual
        )
        let skipped = ActualRecord(
            planID: nil,
            title: "학습",
            categoryID: "study",
            startedAt: makeDate(2026, 8, 12, 9, 0),
            endedAt: makeDate(2026, 8, 12, 10, 0),
            source: .manual
        )
        let alsoChosen = ActualRecord(
            planID: nil,
            title: "달리기",
            categoryID: "exercise",
            startedAt: makeDate(2026, 8, 18, 9, 0),
            endedAt: makeDate(2026, 8, 18, 12, 0),
            source: .manual
        )
        let actuals = [chosen, skipped, alsoChosen]

        let spans = ReviewSelectionEngine.spans(
            period: period,
            buckets: buckets,
            selectedIDs: [buckets[1].id, buckets[3].id]
        )
        XCTAssertEqual(spans, [buckets[1].span, buckets[3].span])

        let report = ReviewEngine(calendar: utcCalendar).report(
            over: spans,
            plans: [],
            actuals: actuals,
            weather: [],
            photos: [],
            memos: [],
            asOf: asOf
        )
        XCTAssertEqual(report.actualDuration, 5 * hour)

        let groups = ActualRecordGroupingEngine.groups(
            actuals: actuals,
            in: spans,
            categories: [],
            asOf: asOf
        )
        XCTAssertEqual(
            groups.reduce(0) { $0 + $1.duration },
            report.actualDuration
        )
        XCTAssertEqual(Set(groups.map(\.id)), ["study", "exercise"])
        XCTAssertEqual(groups.first { $0.id == "study" }?.duration, 2 * hour)
        XCTAssertFalse(
            groups.contains { $0.children.contains { $0.recordID == skipped.id } }
        )

        // 붙어 있는 칸을 고르면 하나의 구간으로 이어진다.
        let adjacent = ReviewSelectionEngine.spans(
            period: period,
            buckets: buckets,
            selectedIDs: [buckets[1].id, buckets[2].id]
        )
        XCTAssertEqual(
            adjacent,
            [TimeSpan(start: buckets[1].span.start, end: buckets[2].span.end)]
        )
    }

    /// 고른 칸을 모두 끄면 지금까지의 화면(기간 하나)으로 돌아간다. 지난
    /// 기간의 칸만 남아 있을 때도 마찬가지라 빈 화면에 갇히지 않는다.
    func testClearingBucketSelectionRestoresWholePeriod() {
        let engine = TimelineAggregationEngine(calendar: utcCalendar)
        let asOf = makeDate(2026, 9, 1)
        let date = makeDate(2026, 8, 15)
        let period = engine.interval(for: .month, containing: date)
        let buckets = ReviewSelectionEngine.buckets(
            for: .month,
            in: period,
            calendar: engine.calendar
        )
        let actual = ActualRecord(
            planID: nil,
            title: "학습",
            categoryID: "study",
            startedAt: makeDate(2026, 8, 12, 9, 0),
            endedAt: makeDate(2026, 8, 12, 10, 0),
            source: .manual
        )

        XCTAssertEqual(
            ReviewSelectionEngine.spans(
                period: period,
                buckets: buckets,
                selectedIDs: []
            ),
            [period]
        )
        XCTAssertEqual(
            ReviewSelectionEngine.spans(
                period: period,
                buckets: buckets,
                selectedIDs: ["지난 달에 고른 칸"]
            ),
            [period]
        )

        let review = ReviewEngine(calendar: utcCalendar)
        let cleared = review.report(
            over: [period],
            plans: [],
            actuals: [actual],
            weather: [],
            photos: [],
            memos: [],
            asOf: asOf
        )
        let single = review.report(
            for: .month,
            containing: date,
            plans: [],
            actuals: [actual],
            weather: [],
            photos: [],
            memos: [],
            asOf: asOf
        )
        XCTAssertEqual(cleared.span, single.span)
        XCTAssertEqual(cleared.categories, single.categories)
        XCTAssertEqual(cleared.actualDuration, single.actualDuration)
        XCTAssertEqual(cleared.actualDuration, hour)
    }

    /// 하루는 나눠 고르지 않는다. 어떤 칸을 고른 척해도 하루 전체를 읽는다.
    func testDayScaleKeepsSinglePeriodBehaviour() {
        let engine = TimelineAggregationEngine(calendar: utcCalendar)
        let asOf = makeDate(2026, 8, 5)
        let day = engine.interval(
            for: .day,
            containing: makeDate(2026, 8, 4, 10, 0)
        )
        XCTAssertNil(ReviewSelectionEngine.bucketLevel(for: .day))
        XCTAssertTrue(
            ReviewSelectionEngine.buckets(
                for: .day,
                in: day,
                calendar: engine.calendar
            ).isEmpty
        )
        XCTAssertEqual(
            ReviewSelectionEngine.spans(
                period: day,
                buckets: [],
                selectedIDs: ["주에서 고른 칸"]
            ),
            [day]
        )

        let actual = ActualRecord(
            planID: nil,
            title: "학습",
            categoryID: "study",
            startedAt: makeDate(2026, 8, 4, 9, 0),
            endedAt: makeDate(2026, 8, 4, 11, 0),
            source: .manual
        )
        XCTAssertEqual(
            ActualRecordGroupingEngine.groups(
                actuals: [actual],
                in: [day],
                categories: [],
                asOf: asOf
            ),
            ActualRecordGroupingEngine.groups(
                actuals: [actual],
                in: day,
                categories: [],
                asOf: asOf
            )
        )
    }

    // MARK: - 하루 눈금판 안쪽 띠

    /// 겹쳐 들어온 수면 단계는 한 줄로 펴고, 화소보다 얇게 그려질 3분짜리
    /// 각성은 이웃에 합친다. 조각을 그대로 그리면 눈에 보이지도 않으면서
    /// 그리는 값만 늘어난다.
    func testSleepStageRingFlattensOverlapAndMergesTooShortStage() throws {
        let dayStart = makeDate(2026, 8, 4)
        let day = TimeSpan(
            start: dayStart,
            end: dayStart.addingTimeInterval(24 * hour)
        )
        func segment(
            _ stage: SleepStage,
            _ from: Double,
            _ to: Double
        ) -> SleepSegment {
            SleepSegment(
                stage: stage,
                span: TimeSpan(
                    start: dayStart.addingTimeInterval(from * hour),
                    end: dayStart.addingTimeInterval(to * hour)
                ),
                sourceName: "Apple Watch"
            )
        }
        let sessions = SleepAnalysisEngine().sessions(
            from: [
                segment(.inBed, 0, 7),
                segment(.core, 0, 1),
                segment(.deep, 1, 2),
                segment(.awake, 2, 2 + 3.0 / 60),
                segment(.core, 2 + 3.0 / 60, 4),
                segment(.rem, 4, 5),
            ]
        )
        XCTAssertEqual(sessions.count, 1)

        let ring = try XCTUnwrap(
            RecordClockDetailEngine.sleepRing(sessions: sessions, in: day)
        )
        XCTAssertEqual(ring.kind, .sleepStage)
        XCTAssertEqual(
            ring.arcs.map(\.token),
            ["core", "deep", "core", "rem", "inBed"]
        )
        // 3분짜리 각성은 앞 조각에 흡수돼 사라진다.
        XCTAssertEqual(
            ring.arcs[1].endFraction,
            (2 * hour + 180) / (24 * hour),
            accuracy: 1e-9
        )
        assertRingHasNoSlivers(ring)
    }

    func testActivitySleepRingKeepsOnlyAsleepStages() throws {
        let dayStart = makeDate(2026, 8, 4)
        let day = TimeSpan(
            start: dayStart,
            end: dayStart.addingTimeInterval(24 * hour)
        )
        let segments = [
            SleepSegment(
                stage: .inBed,
                span: TimeSpan(
                    start: dayStart,
                    end: dayStart.addingTimeInterval(5 * hour)
                ),
                sourceName: "Apple Watch"
            ),
            SleepSegment(
                stage: .core,
                span: TimeSpan(
                    start: dayStart.addingTimeInterval(hour),
                    end: dayStart.addingTimeInterval(3 * hour)
                ),
                sourceName: "Apple Watch"
            ),
            SleepSegment(
                stage: .awake,
                span: TimeSpan(
                    start: dayStart.addingTimeInterval(3 * hour),
                    end: dayStart.addingTimeInterval(4 * hour)
                ),
                sourceName: "Apple Watch"
            ),
            SleepSegment(
                stage: .rem,
                span: TimeSpan(
                    start: dayStart.addingTimeInterval(4 * hour),
                    end: dayStart.addingTimeInterval(5 * hour)
                ),
                sourceName: "Apple Watch"
            ),
        ]
        let sessions = SleepAnalysisEngine().sessions(from: segments)
        let ring = try XCTUnwrap(
            RecordClockDetailEngine.activitySleepRing(
                sessions: sessions,
                in: day
            )
        )

        XCTAssertEqual(ring.arcs.map(\.token), ["core", "rem"])
    }

    func testActivitySleepRingHidesStagesWithoutWatchEvidence() throws {
        let dayStart = makeDate(2026, 8, 4)
        let day = TimeSpan(
            start: dayStart,
            end: dayStart.addingTimeInterval(24 * hour)
        )
        let sessions = SleepAnalysisEngine().sessions(
            from: [
                SleepSegment(
                    stage: .core,
                    span: TimeSpan(
                        start: dayStart,
                        end: dayStart.addingTimeInterval(2 * hour)
                    ),
                    sourceName: "iPhone"
                ),
                SleepSegment(
                    stage: .deep,
                    span: TimeSpan(
                        start: dayStart.addingTimeInterval(2 * hour),
                        end: dayStart.addingTimeInterval(3 * hour)
                    ),
                    sourceName: "iPhone"
                ),
            ]
        )
        let ring = try XCTUnwrap(
            RecordClockDetailEngine.activitySleepRing(
                sessions: sessions,
                in: day
            )
        )

        XCTAssertEqual(
            Set(ring.arcs.map(\.token)),
            Set([SleepStage.asleepUnspecified.rawValue])
        )
    }

    func testActivityBandIncludesSleepStagesAndTravelModes() {
        let dayStart = makeDate(2026, 8, 4)
        let day = TimeSpan(
            start: dayStart,
            end: dayStart.addingTimeInterval(24 * hour)
        )
        let sessions = SleepAnalysisEngine().sessions(
            from: [
                SleepSegment(
                    stage: .core,
                    span: TimeSpan(
                        start: dayStart,
                        end: dayStart.addingTimeInterval(2 * hour)
                    ),
                    sourceName: "Apple Watch"
                )
            ]
        )
        let travel = TravelSegment(
            mode: .car,
            span: TimeSpan(
                start: dayStart.addingTimeInterval(8 * hour),
                end: dayStart.addingTimeInterval(9 * hour)
            ),
            distanceMeters: 10_000,
            confidence: .high,
            evidence: ["GPS"]
        )

        let rings = RecordClockDetailEngine.activityRings(
            sleepSessions: sessions,
            travel: [travel],
            in: day
        )

        XCTAssertEqual(rings.map(\.kind), [.sleepStage, .travel])
        XCTAssertEqual(rings[0].arcs.map(\.token), ["core"])
        XCTAssertEqual(rings[1].arcs.map(\.token), ["car"])
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

    func testWeatherRingShowsChangedMeasurementsWithAirQuality() throws {
        let dayStart = makeDate(2026, 8, 4)
        let day = TimeSpan(
            start: dayStart,
            end: dayStart.addingTimeInterval(24 * hour)
        )
        func weather(
            _ minute: Double,
            _ condition: String,
            _ temperature: Double,
            _ pm10: Double
        ) -> WeatherContext {
            WeatherContext(
                observedAt: dayStart.addingTimeInterval(minute * 60),
                condition: condition,
                symbolName: condition == "비" ? "cloud.rain.fill" : "sun.max.fill",
                temperatureCelsius: temperature,
                airQuality: AirQualityContext(
                    pm10MicrogramsPerCubicMeter: pm10,
                    pm25MicrogramsPerCubicMeter: 8,
                    observedAt: dayStart.addingTimeInterval(minute * 60),
                    providerName: "테스트",
                    isFallback: false
                )
            )
        }
        let ring = try XCTUnwrap(
            RecordClockDetailEngine.weatherRing(
                contexts: [
                    weather(8 * 60, "맑음", 25, 12),
                    weather(8 * 60 + 15, "맑음", 25, 12),
                    weather(9 * 60, "비", 21, 92),
                ],
                in: day,
                asOf: day.end
            )
        )
        XCTAssertEqual(ring.kind, .weather)
        XCTAssertEqual(ring.arcs.count, 2)
        XCTAssertEqual(WeatherClockToken.displayName(ring.arcs[0].token), "☀️ 25° · 🟢")
        XCTAssertEqual(WeatherClockToken.displayName(ring.arcs[1].token), "🌧️ 21° · 🟠")
        assertRingHasNoSlivers(ring)
    }

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

    private func assertRingHasNoSlivers(
        _ ring: RecordClockDetailRing?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let ring else {
            XCTFail("띠가 없습니다.", file: file, line: line)
            return
        }
        var previousEnd = 0.0
        for arc in ring.arcs {
            XCTAssertGreaterThanOrEqual(
                arc.startFraction,
                previousEnd - 1e-9,
                "조각이 겹칩니다.",
                file: file,
                line: line
            )
            XCTAssertGreaterThanOrEqual(
                arc.endFraction - arc.startFraction,
                RecordClockDetailEngine.minimumArcFraction - 1e-9,
                "화소보다 얇은 조각이 남았습니다.",
                file: file,
                line: line
            )
            previousEnd = arc.endFraction
        }
        XCTAssertLessThanOrEqual(
            ring.arcs.count,
            RecordClockDetailEngine.maximumArcCount,
            file: file,
            line: line
        )
    }

    // MARK: - 하루 눈금판 바깥의 일과 고리

    func testActivityIsSplitAcrossItsDayPhaseRows() {
        let day = dayPhaseDay()
        let boundary = day.start.addingTimeInterval(7 * hour)
        let activity = TimeSpan(
            start: boundary.addingTimeInterval(-30 * 60),
            end: boundary.addingTimeInterval(30 * 60)
        )
        let assignments = DayPhaseEngine.assignments(
            of: activity,
            to: [
                DayPhaseSpan(
                    phase: .sleep,
                    span: TimeSpan(start: day.start, end: boundary)
                ),
                DayPhaseSpan(
                    phase: .commuteToWork,
                    span: TimeSpan(start: boundary, end: day.end)
                ),
            ]
        )

        XCTAssertEqual(assignments.map(\.phase), [.sleep, .commuteToWork])
        XCTAssertEqual(assignments.map(\.span.duration), [30 * 60, 30 * 60])
    }

    func testActivityDoesNotBorrowSleepPhase() {
        let day = dayPhaseDay()
        let sleepEnd = day.start.addingTimeInterval(8 * hour)
        let phases = [
            DayPhaseSpan(
                phase: .sleep,
                span: TimeSpan(start: day.start, end: sleepEnd)
            ),
            DayPhaseSpan(
                phase: .activity,
                span: TimeSpan(start: sleepEnd, end: day.end)
            ),
        ]
        let stay = TimeSpan(
            start: day.start.addingTimeInterval(7 * hour),
            end: day.start.addingTimeInterval(9 * hour)
        )

        XCTAssertEqual(
            DayPhaseEngine.assignments(of: stay, to: phases)
                .filter {
                    $0.phase == DayPhase.phase(
                        forActivityCategory: "activity"
                    )
                }
                .map(\.phase),
            [.activity]
        )
    }

    func testAutomaticTimelineKeepsEveryDayPhaseRowWithoutData() {
        XCTAssertEqual(
            DayPhase.timelineRows,
            [
                .sleep, .movement, .exercise, .work, .study, .hobby, .activity,
                .appointment, .unconfirmed,
            ]
        )
    }

    func testDayRecordGroupsShowPhasesWithNestedActivitiesAnd24Hours() {
        let day = dayPhaseDay()
        let sleepEnd = day.start.addingTimeInterval(8 * hour)
        let phases = [
            DayPhaseSpan(
                phase: .sleep,
                span: TimeSpan(start: day.start, end: sleepEnd)
            ),
            DayPhaseSpan(
                phase: .activity,
                span: TimeSpan(start: sleepEnd, end: day.end)
            ),
        ]
        let sleep = ActualRecord(
            planID: nil,
            title: "코어 수면",
            categoryID: "sleep",
            startedAt: day.start.addingTimeInterval(2 * hour),
            endedAt: day.start.addingTimeInterval(3 * hour),
            source: .healthKit
        )
        let walk = ActualRecord(
            planID: nil,
            title: "걷기",
            categoryID: "movement",
            startedAt: sleepEnd.addingTimeInterval(2 * hour),
            endedAt: sleepEnd.addingTimeInterval(3 * hour),
            source: .motion
        )

        let groups = ActualRecordGroupingEngine.phaseGroups(
            phases: phases,
            actuals: [sleep, walk],
            categories: CategoryCatalog.builtIn,
            asOf: day.end
        )

        XCTAssertEqual(groups.map(\.id), ["sleep", "activity"])
        XCTAssertEqual(groups.map(\.children.count), [1, 1])
        XCTAssertEqual(groups[0].children[0].title, "코어 수면")
        XCTAssertEqual(groups[1].children[0].title, "걷기")
        XCTAssertEqual(
            groups.reduce(0) { $0 + $1.duration },
            day.duration,
            accuracy: 0.001
        )
    }

    /// iPhone·Watch가 운동으로 확정한 시간은 업무·이동·수면보다 먼저
    /// 일과에 놓인다. 수동 계획이나 수동적 동작 추정은 운동으로 올리지 않는다.
    func testDayPhaseRingPrioritizesConfirmedWorkout() {
        let day = dayPhaseDay()
        let watchWorkout = ActualRecord(
            planID: nil,
            title: "달리기",
            categoryID: "activity",
            startedAt: day.start.addingTimeInterval(6.5 * hour),
            endedAt: day.start.addingTimeInterval(7.5 * hour),
            source: .appleWatch,
            behavior: WatchBehaviorKind.running.rawValue,
            evidence: [AutomaticRecordTimelineEngine.watchWorkoutEvidence],
            sensorChunkID: UUID()
        )
        let passiveMotion = ActualRecord(
            planID: nil,
            title: "운동",
            categoryID: "exercise",
            startedAt: day.start.addingTimeInterval(18 * hour),
            endedAt: day.start.addingTimeInterval(19 * hour),
            source: .motion
        )
        let iPhoneWorkout = ActualRecord(
            planID: nil,
            title: "근력 운동",
            categoryID: "exercise",
            startedAt: day.start.addingTimeInterval(12 * hour),
            endedAt: day.start.addingTimeInterval(13 * hour),
            source: .healthKit,
            behavior: WatchBehaviorKind.exercise.rawValue,
            evidence: [AutomaticRecordTimelineEngine.healthWorkoutEvidence]
        )
        let phases = DayPhaseEngine.phases(
            actuals: [
                sleepActual(0, 7, on: day),
                stationaryContext(.homeRest, 0, 6, on: day),
                stationaryContext(.work, 8, 18, on: day),
                watchWorkout,
                iPhoneWorkout,
                passiveMotion,
            ],
            travel: [travelLeg(.walking, 6, 8, on: day)],
            stays: [],
            placeKinds: [:],
            in: day,
            asOf: day.end
        )

        XCTAssertEqual(
            phases.map(\.phase),
            [.sleep, .exercise, .movement, .work, .exercise, .work]
        )
        XCTAssertEqual(
            phases.filter { $0.phase == .exercise }.map(\.span),
            [watchWorkout.span(asOf: day.end), iPhoneWorkout.span(asOf: day.end)]
        )
        XCTAssertFalse(
            phases.contains {
                $0.span.start == passiveMotion.startedAt
                    && $0.phase == .exercise
            }
        )
        assertPhasesPartitionTheDay(phases, in: day)
    }

    func testWatchWalkingWorkoutIsExerciseWithWalkingActivity() throws {
        let day = dayPhaseDay()
        let span = TimeSpan(
            start: day.start.addingTimeInterval(18 * hour),
            end: day.start.addingTimeInterval(19 * hour)
        )
        let workout = ActualRecord(
            planID: nil,
            title: "걷기",
            categoryID: "exercise",
            startedAt: span.start,
            endedAt: span.end,
            source: .appleWatch,
            behavior: WatchBehaviorKind.exercise.rawValue,
            evidence: [AutomaticRecordTimelineEngine.healthWorkoutEvidence]
        )
        let travel = TravelSegment(
            mode: .walking,
            span: span,
            distanceMeters: 5_600,
            confidence: .high,
            evidence: ["Apple Watch 운동 경로"]
        )

        let displayed = MovementDisplayEngine.reviewActuals(
            [workout],
            travel: [travel],
            asOf: day.end
        )
        let walking = try XCTUnwrap(
            displayed.first {
                ActualRecordCategoryResolver.categoryID(for: $0) == "movement"
            }
        )
        XCTAssertEqual(MovementPresentation.title(for: walking), "걷기")
        XCTAssertFalse(displayed.contains { $0.id == workout.id })

        let evidence = DayPhaseEvidenceEngine.records(
            from: [workout],
            intersecting: day,
            asOf: day.end
        )
        let phases = DayPhaseEngine.phases(
            actuals: evidence,
            travel: [travel],
            stays: [],
            placeKinds: [:],
            in: day,
            asOf: day.end
        )
        XCTAssertEqual(
            phases.filter { $0.phase == .exercise }.map(\.span),
            [span]
        )
    }

    func testWalkingBelongsToMovementUnlessAWorkoutCoversIt() {
        let day = dayPhaseDay()
        let workoutSpan = TimeSpan(
            start: day.start.addingTimeInterval(10 * hour),
            end: day.start.addingTimeInterval(11 * hour)
        )
        let ordinarySpan = TimeSpan(
            start: day.start.addingTimeInterval(12 * hour),
            end: day.start.addingTimeInterval(13 * hour)
        )
        let workout = ActualRecord(
            planID: nil,
            title: "걷기 운동",
            categoryID: "exercise",
            startedAt: workoutSpan.start,
            endedAt: workoutSpan.end,
            source: .appleWatch,
            behavior: WatchBehaviorKind.walking.rawValue,
            evidence: [AutomaticRecordTimelineEngine.watchWorkoutEvidence]
        )
        let phases = DayPhaseEngine.phases(
            actuals: [workout],
            travel: [
                TravelSegment(
                    mode: .walking,
                    span: workoutSpan,
                    distanceMeters: 4_000,
                    confidence: .high,
                    evidence: ["Apple Watch 운동 경로"]
                ),
                TravelSegment(
                    mode: .walking,
                    span: ordinarySpan,
                    distanceMeters: 2_000,
                    confidence: .high,
                    evidence: ["iPhone Core Motion"]
                ),
            ],
            stays: [],
            placeKinds: [:],
            in: day,
            asOf: day.end
        )

        XCTAssertEqual(
            phases.first { $0.span.contains(workoutSpan.start) }?.phase,
            .exercise
        )
        XCTAssertEqual(
            phases.first { $0.span.contains(ordinarySpan.start) }?.phase,
            .movement
        )
    }

    /// 일과는 수면·활동·이동·업무처럼 배타적인 대분류 한 줄로 읽힌다.
    func testDayPhaseRingTellsACommuteDayInOrder() throws {
        let day = dayPhaseDay()
        let phases = DayPhaseEngine.phases(
            actuals: [
                sleepActual(0, 7, on: day),
                stationaryContext(.homeRest, 7, 8, on: day),
                stationaryContext(.work, 8.75, 18, on: day),
                stationaryContext(.homeRest, 18.75, 24, on: day),
            ],
            travel: [
                travelLeg(.walking, 8, 8.25, on: day),
                travelLeg(.subway, 8.25, 8.75, on: day),
                travelLeg(.subway, 18, 18.5, on: day),
                travelLeg(.walking, 18.5, 18.75, on: day),
            ],
            stays: [],
            placeKinds: [:],
            in: day,
            asOf: day.end
        )

        XCTAssertEqual(
            phases.map(\.phase.title),
            ["수면", "활동", "이동", "업무", "이동", "활동"]
        )
        // 걷고 타는 두 다리는 한 번의 이동이다.
        XCTAssertEqual(phases[2].span.start, day.start.addingTimeInterval(8 * hour))
        XCTAssertEqual(
            phases[2].span.end,
            day.start.addingTimeInterval(8.75 * hour)
        )
        assertPhasesPartitionTheDay(phases, in: day)
    }

    /// 출발지에서 이동해 도착한 목적지 안에 머무는 동안은 같은 목적지라면
    /// 업무/수업 문맥이 끊기지 않는다. 분류가 잠깐 비어도 등록된 장소가
    /// 근거가 되면 이어붙인다.
    func testDayPhaseRingKeepsWorkOrStudyContinuousWhenDestinationIsNotLeft() throws {
        let day = dayPhaseDay()
        let homeKey = "frequent-home"
        let workKey = "frequent-company"
        let schoolKey = "frequent-school"

        let workPhases = DayPhaseEngine.phases(
            actuals: [
                sleepActual(0, 7, on: day),
                stationaryContext(.work, 9, 10, on: day),
                stationaryContext(.unknownStay, 10, 11, on: day),
                stationaryContext(.work, 11, 18, on: day),
            ],
            travel: [
                travelLeg(.subway, 8, 8.75, on: day),
                travelLeg(.subway, 18, 18.5, on: day),
                travelLeg(.walking, 18.5, 18.75, on: day),
            ],
            stays: [
                homeStay(0, 8, key: homeKey, on: day),
                PlaceStay(
                    placeKey: workKey,
                    displayName: "회사",
                    span: TimeSpan(
                        start: day.start.addingTimeInterval(8.75 * hour),
                        end: day.start.addingTimeInterval(18 * hour)
                    ),
                    confidence: .high,
                    isConfirmed: true
                ),
                homeStay(18.75, 24, key: homeKey, on: day),
            ],
            placeKinds: [homeKey: .home, workKey: .company],
            in: day,
            asOf: day.end
        )

        XCTAssertEqual(
            workPhases.map(\.phase.title),
            ["수면", "이동", "업무", "이동"]
        )
        XCTAssertEqual(
            workPhases.first(where: { $0.phase == .work })?.span.start,
            day.start.addingTimeInterval(8.75 * hour)
        )
        XCTAssertEqual(
            workPhases.first(where: { $0.phase == .work })?.span.end,
            day.start.addingTimeInterval(18 * hour)
        )

        let studyPhases = DayPhaseEngine.phases(
            actuals: [
                sleepActual(0, 7, on: day),
                stationaryContext(.study, 9, 10, on: day),
                stationaryContext(.unknownStay, 10, 11, on: day),
                stationaryContext(.study, 11, 18, on: day),
            ],
            travel: [
                travelLeg(.bus, 8, 8.75, on: day),
                travelLeg(.bus, 18, 18.5, on: day),
                travelLeg(.walking, 18.5, 18.75, on: day),
            ],
            stays: [
                homeStay(0, 8, key: homeKey, on: day),
                PlaceStay(
                    placeKey: schoolKey,
                    displayName: "학교",
                    span: TimeSpan(
                        start: day.start.addingTimeInterval(8.75 * hour),
                        end: day.start.addingTimeInterval(18 * hour)
                    ),
                    confidence: .high,
                    isConfirmed: true
                ),
                homeStay(18.75, 24, key: homeKey, on: day),
            ],
            placeKinds: [homeKey: .home, schoolKey: .school],
            in: day,
            asOf: day.end
        )

        XCTAssertEqual(
            studyPhases.map(\.phase.title),
            ["수면", "이동", "수업", "이동"]
        )
        XCTAssertEqual(
            studyPhases.first(where: { $0.phase == .study })?.span.start,
            day.start.addingTimeInterval(8.75 * hour)
        )
        XCTAssertEqual(
            studyPhases.first(where: { $0.phase == .study })?.span.end,
            day.start.addingTimeInterval(18 * hour)
        )
        assertPhasesPartitionTheDay(workPhases, in: day)
        assertPhasesPartitionTheDay(studyPhases, in: day)
    }

    func testReturningToCompanyKeepsLunchActivityUnderWork() throws {
        let day = dayPhaseDay()
        let companyKey = "frequent-company"
        let lunch = TimeSpan(
            start: day.start.addingTimeInterval(12.1 * hour),
            end: day.start.addingTimeInterval(12.9 * hour)
        )
        let phases = DayPhaseEngine.phases(
            actuals: [
                stationaryContext(.mealPlace, 12.1, 12.9, on: day),
            ],
            travel: [],
            stays: [
                PlaceStay(
                    placeKey: companyKey,
                    displayName: "회사",
                    span: TimeSpan(
                        start: day.start.addingTimeInterval(9 * hour),
                        end: day.start.addingTimeInterval(12 * hour)
                    ),
                    confidence: .high,
                    isConfirmed: true
                ),
                PlaceStay(
                    placeKey: companyKey,
                    displayName: "회사",
                    span: TimeSpan(
                        start: day.start.addingTimeInterval(13 * hour),
                        end: day.start.addingTimeInterval(18 * hour)
                    ),
                    confidence: .high,
                    isConfirmed: true
                ),
            ],
            placeKinds: [companyKey: .company],
            in: day,
            asOf: day.end
        )

        let parent = try XCTUnwrap(
            phases.first { $0.span.contains(lunch.start) }
        )
        XCTAssertEqual(parent.phase, .work)
        XCTAssertEqual(
            DayPhaseEngine.assignments(of: lunch, to: phases).map(\.phase),
            [.work]
        )
    }

    /// 학교에 닿으면 이동의 목적은 활동 상세에 남고 일과는 수업으로 읽힌다.
    func testDayPhaseRingSaysSchoolWordsWhenArrivingAtStudy() throws {
        let day = dayPhaseDay()
        let homeKey = "frequent-home"
        let phases = DayPhaseEngine.phases(
            actuals: [
                sleepActual(0, 6.5, on: day),
                stationaryContext(.study, 8.2, 16, on: day),
            ],
            travel: [
                travelLeg(.walking, 7, 7.5, on: day),
                travelLeg(.bus, 7.5, 8, on: day),
                travelLeg(.bus, 16, 16.5, on: day),
            ],
            // 집이라는 사실은 자주가는 곳으로 확정된 체류에서도 온다.
            stays: [
                homeStay(0, 7, key: homeKey, on: day),
                homeStay(16.5, 24, key: homeKey, on: day),
            ],
            placeKinds: [homeKey: .home],
            in: day,
            asOf: day.end
        )

        XCTAssertEqual(
            phases.map(\.phase.title),
            ["수면", "이동", "수업", "이동"]
        )
        assertPhasesPartitionTheDay(phases, in: day)
    }

    /// 오감이 없는 날은 빈칸으로 남는다. 주말도 재택도 지어낸 이름을 갖지
    /// 않고, 그래도 화면이 망가진 것처럼 보이지 않는다.
    func testDayPhaseRingLeavesGapsWhenThereIsNoCommute() throws {
        let day = dayPhaseDay()
        let weekend = DayPhaseEngine.phases(
            actuals: [
                sleepActual(0, 8, on: day),
                stationaryContext(.homeRest, 8, 12, on: day),
                stationaryContext(.housework, 12, 13, on: day),
                stationaryContext(.homeRest, 13, 24, on: day),
            ],
            travel: [],
            stays: [],
            placeKinds: [:],
            in: day,
            asOf: day.end
        )
        XCTAssertEqual(weekend.map(\.phase), [.sleep, .activity])
        assertPhasesPartitionTheDay(weekend, in: day)

        let workedFromHome = DayPhaseEngine.phases(
            actuals: [
                sleepActual(0, 7, on: day),
                stationaryContext(.homeRest, 7, 9, on: day),
                stationaryContext(.work, 9, 18, on: day),
                stationaryContext(.homeRest, 18, 24, on: day),
            ],
            travel: [],
            stays: [],
            placeKinds: [:],
            in: day,
            asOf: day.end
        )
        XCTAssertEqual(
            workedFromHome.map(\.phase),
            [.sleep, .activity, .work, .activity]
        )
        assertPhasesPartitionTheDay(workedFromHome, in: day)
    }

    /// 수면 근거는 회사 체류와 겹쳐도 수면 일과가 우선한다.
    func testDayPhaseRingKeepsSleepOverWorkAtTheOffice() throws {
        let day = dayPhaseDay()
        let nap = sleepActual(13, 13.75, on: day)
        let actuals = [
            sleepActual(0, 7, on: day),
            stationaryContext(.homeRest, 7, 8, on: day),
            stationaryContext(.work, 8.75, 18, on: day),
            nap,
            stationaryContext(.homeRest, 18.75, 24, on: day),
        ]
        let travel = [
            travelLeg(.subway, 8, 8.75, on: day),
            travelLeg(.subway, 18, 18.75, on: day),
        ]
        let phases = DayPhaseEngine.phases(
            actuals: actuals,
            travel: travel,
            stays: [],
            placeKinds: [:],
            in: day,
            asOf: day.end
        )

        XCTAssertEqual(
            phases.map(\.phase.title),
            ["수면", "활동", "이동", "업무", "수면", "업무", "이동", "활동"]
        )
        let napMiddle = day.start.addingTimeInterval(13.5 * hour)
        XCTAssertEqual(
            phases.first { $0.span.contains(napMiddle) }?.phase,
            .sleep
        )
        assertPhasesPartitionTheDay(phases, in: day)

        // 카테고리 고리는 낮잠을 감추지 않는다.
        let sleepRing = RecordChartEngine.clockRings(
            actuals: actuals,
            in: day,
            asOf: day.end
        )
        .first { $0.categoryID == "sleep" }
        XCTAssertEqual(
            try XCTUnwrap(sleepRing).arcs.map(\.startFraction),
            [0, 13.0 / 24]
        )
    }

    /// 조각이 화소보다 얇으면 그리지 않고 이웃에 합친다. 안쪽 띠와 같은
    /// 기준을 쓰므로 눈금판에 규칙이 두 벌 생기지 않는다.
    func testDayPhaseRingMergesShortPhasesInsteadOfDrawingSlivers() throws {
        let day = dayPhaseDay()
        let actuals = [
            sleepActual(0, 7, on: day),
            stationaryContext(.homeRest, 7, 8, on: day),
            stationaryContext(.work, 8.75, 12, on: day),
            // 근무 사이에 낀 3.6분짜리 수업. 그리면 보이지도 않는다.
            stationaryContext(.study, 12, 12.06, on: day),
            stationaryContext(.work, 12.06, 18, on: day),
            stationaryContext(.homeRest, 18.75, 24, on: day),
        ]
        let travel = [
            travelLeg(.subway, 8, 8.75, on: day),
            travelLeg(.subway, 18, 18.75, on: day),
        ]
        let phases = DayPhaseEngine.phases(
            actuals: actuals,
            travel: travel,
            stays: [],
            placeKinds: [:],
            in: day,
            asOf: day.end
        )
        // 나누기 단계에서는 짧은 수업도 제 자리를 지킨다.
        XCTAssertEqual(
            phases.map(\.phase),
            [.sleep, .activity, .movement, .work, .study, .work,
             .movement, .activity]
        )
        assertPhasesPartitionTheDay(phases, in: day)

        let ring = try XCTUnwrap(
            RecordClockDetailEngine.phaseRing(
                actuals: actuals,
                travel: travel,
                stays: [],
                placeKinds: [:],
                in: day,
                asOf: day.end
            )
        )
        XCTAssertEqual(ring.kind, .dayPhase)
        // 그릴 때는 앞선 업무가 그 자리를 이어받는다.
        XCTAssertEqual(
            ring.arcs.map(\.token),
            ["sleep", "activity", "movement", "work", "movement", "activity"]
        )
        XCTAssertEqual(ring.arcs[3].endFraction, 18.0 / 24, accuracy: 1e-9)
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

    /// 등록해 두지 않은 곳에 다녀온 길은 이름을 지어내지 않는다. 도착해서
    /// 근무나 수업이 시작되면 예전처럼 출근·퇴근이라 부르고, 그마저 없으면
    /// 빈칸으로 남긴다.
    func testDayPhaseRingFallsBackWhenTheFarEndIsNotRegistered() {
        let known = roundTripPhases(
            to: .company,
            staying: .work,
            registeringDestination: false
        )
        XCTAssertEqual(
            known.map(\.phase.title),
            ["수면", "이동", "업무", "이동"]
        )

        let unknown = roundTripPhases(
            to: .hobby,
            staying: .cafe,
            registeringDestination: false
        )
        XCTAssertEqual(unknown.map(\.phase.title), ["수면", "이동", "활동", "이동"])

        // 등록은 했지만 종류에 이름이 없는 곳도 같은 자리로 떨어진다.
        let custom = roundTripPhases(to: .custom, staying: .cafe)
        XCTAssertEqual(custom.map(\.phase.title), ["수면", "이동", "활동", "이동"])
    }

    /// 읽음창은 짚은 조각의 진짜 시작·끝 시각을 적는다. 각도로 접었다 펴도
    /// 8시 12분이 8시 11분으로 새지 않아야 한다.
    func testPhaseReadoutReportsTheTrueStartAndEnd() throws {
        let day = dayPhaseDay()
        func at(_ hours: Int, _ minutes: Int) -> Date {
            day.start.addingTimeInterval(
                TimeInterval(hours * 3_600 + minutes * 60)
            )
        }
        let leaving = TimeSpan(start: at(8, 12), end: at(8, 47))
        let ring = try XCTUnwrap(
            RecordClockDetailEngine.phaseRing(
                actuals: [
                    sleepActual(0, 7, on: day),
                    ActualRecord(
                        planID: nil,
                        title: StationaryContextKind.work.title,
                        categoryID: StationaryContextKind.work.categoryID,
                        startedAt: leaving.end,
                        endedAt: at(18, 0),
                        source: .location,
                        confidence: .medium,
                        behavior: StationaryContextKind.work.rawValue,
                        modelVersion: StationaryContextClassifier.modelVersion
                    ),
                ],
                travel: [
                    TravelSegment(
                        mode: .subway,
                        span: leaving,
                        distanceMeters: 4_000,
                        confidence: .medium,
                        evidence: ["GPS"]
                    ),
                ],
                stays: [
                    PlaceStay(
                        placeKey: "frequent-home",
                        displayName: "집",
                        span: TimeSpan(start: day.start, end: leaving.start),
                        confidence: .high,
                        isConfirmed: true
                    ),
                ],
                placeKinds: ["frequent-home": .home],
                in: day,
                asOf: day.end
            )
        )

        let arc = try XCTUnwrap(
            ring.arcs.first { $0.token == DayPhase.movement.rawValue }
        )
        // 재생머리가 그 조각 위를 지날 때 읽는 조각도 같은 조각이다.
        XCTAssertEqual(
            RecordClockEngine.arc(
                in: ring,
                at: (arc.startFraction + arc.endFraction) / 2
            ),
            arc
        )
        let span = RecordClockEngine.span(of: arc, in: day)
        XCTAssertEqual(span.start, leaving.start)
        XCTAssertEqual(span.end, leaving.end)
        XCTAssertEqual(
            RecordClockEngine.timeRangeText(span),
            "\(leaving.start.formatted(date: .omitted, time: .shortened))"
                + "–"
                + "\(leaving.end.formatted(date: .omitted, time: .shortened))"
        )
    }

    /// 집을 나서 한 곳에 머물다 집으로 돌아오는 하루. 걷고 타는 두 다리가
    /// 한 번의 오감이 되는 것은 여느 날과 같다.
    private func roundTripPhases(
        to kind: FrequentPlaceKind,
        staying context: StationaryContextKind?,
        registeringDestination: Bool = true
    ) -> [DayPhaseSpan] {
        let day = dayPhaseDay()
        let homeKey = "frequent-home"
        let awayKey = "frequent-away"
        return DayPhaseEngine.phases(
            actuals: [sleepActual(0, 7, on: day)]
                + (context.map { [stationaryContext($0, 8.75, 18, on: day)] }
                    ?? []),
            travel: [
                travelLeg(.walking, 8, 8.25, on: day),
                travelLeg(.subway, 8.25, 8.75, on: day),
                travelLeg(.subway, 18, 18.5, on: day),
                travelLeg(.walking, 18.5, 18.75, on: day),
            ],
            stays: [
                homeStay(0, 8, key: homeKey, on: day),
                PlaceStay(
                    placeKey: awayKey,
                    displayName: kind.defaultName,
                    span: TimeSpan(
                        start: day.start.addingTimeInterval(8.75 * hour),
                        end: day.start.addingTimeInterval(18 * hour)
                    ),
                    confidence: .high,
                    isConfirmed: true
                ),
                homeStay(18.75, 24, key: homeKey, on: day),
            ],
            placeKinds: registeringDestination
                ? [homeKey: .home, awayKey: kind]
                : [homeKey: .home],
            in: day,
            asOf: day.end
        )
    }

    private func dayPhaseDay() -> TimeSpan {
        let start = makeDate(2026, 8, 4)
        return TimeSpan(start: start, end: start.addingTimeInterval(24 * hour))
    }

    private func stationaryContext(
        _ kind: StationaryContextKind,
        _ from: Double,
        _ to: Double,
        on day: TimeSpan
    ) -> ActualRecord {
        ActualRecord(
            planID: nil,
            title: kind.title,
            categoryID: kind.categoryID,
            startedAt: day.start.addingTimeInterval(from * hour),
            endedAt: day.start.addingTimeInterval(to * hour),
            source: .location,
            confidence: .medium,
            behavior: kind.rawValue,
            modelVersion: StationaryContextClassifier.modelVersion
        )
    }

    private func sleepActual(
        _ from: Double,
        _ to: Double,
        on day: TimeSpan
    ) -> ActualRecord {
        ActualRecord(
            planID: nil,
            title: "수면",
            categoryID: "sleep",
            startedAt: day.start.addingTimeInterval(from * hour),
            endedAt: day.start.addingTimeInterval(to * hour),
            source: .healthKit
        )
    }

    private func travelLeg(
        _ mode: TravelMode,
        _ from: Double,
        _ to: Double,
        on day: TimeSpan
    ) -> TravelSegment {
        TravelSegment(
            mode: mode,
            span: TimeSpan(
                start: day.start.addingTimeInterval(from * hour),
                end: day.start.addingTimeInterval(to * hour)
            ),
            distanceMeters: 4_000,
            confidence: .medium,
            evidence: ["GPS"]
        )
    }

    private func homeStay(
        _ from: Double,
        _ to: Double,
        key: String,
        on day: TimeSpan
    ) -> PlaceStay {
        PlaceStay(
            placeKey: key,
            displayName: "집",
            span: TimeSpan(
                start: day.start.addingTimeInterval(from * hour),
                end: day.start.addingTimeInterval(to * hour)
            ),
            confidence: .high,
            isConfirmed: true
        )
    }

    /// 이 고리는 겹칠 수 없는 한 줄이다. 조각은 시간 순서대로 놓이고, 서로
    /// 겹치지 않으며, 하루 밖으로 나가지 않는다.
    private func assertPhasesPartitionTheDay(
        _ phases: [DayPhaseSpan],
        in day: TimeSpan,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var previousEnd = day.start
        for piece in phases {
            XCTAssertGreaterThanOrEqual(
                piece.span.start,
                previousEnd,
                "줄거리가 겹칩니다.",
                file: file,
                line: line
            )
            XCTAssertGreaterThan(piece.span.duration, 0, file: file, line: line)
            previousEnd = piece.span.end
        }
        XCTAssertGreaterThanOrEqual(
            phases.first?.span.start ?? day.start,
            day.start,
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            previousEnd,
            day.end,
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            phases.reduce(0) { $0 + $1.span.duration },
            day.duration,
            file: file,
            line: line
        )
    }

    /// 오늘 적은 지난주 이야기는 지난주에 남는다. 메모가 놓이는 자리는
    /// 적은 시각이 아니라 그 메모가 말하는 시각이다.
    func testHighlightedMemoLandsOnTheWeekItIsAbout() {
        let occurredAt = makeDate(2026, 8, 4, 15, 0)
        let createdAt = makeDate(2026, 8, 20, 9, 0)
        let memo = ActionMemo(
            categoryID: "activity",
            occurredAt: occurredAt,
            kind: .decision,
            text: "무릎이 아팠던 날",
            createdAt: createdAt,
            updatedAt: createdAt
        )
        let engine = ReviewEngine(calendar: utcCalendar)

        let aboutWeek = engine.report(
            for: .week,
            containing: occurredAt,
            plans: [],
            actuals: [],
            weather: [],
            photos: [],
            memos: [memo],
            asOf: createdAt
        )
        XCTAssertEqual(aboutWeek.contexts.map(\.text), ["무릎이 아팠던 날"])
        XCTAssertEqual(aboutWeek.contexts.first?.date, occurredAt)

        let writtenWeek = engine.report(
            for: .week,
            containing: createdAt,
            plans: [],
            actuals: [],
            weather: [],
            photos: [],
            memos: [memo],
            asOf: createdAt
        )
        XCTAssertTrue(writtenWeek.contexts.isEmpty)
    }

    // MARK: - 현재 층수로 보정하기

    /// 주어진 고도 차이를 만드는 기압. 층 높이 계산이 쓰는 기압 공식의 역함수다.
    private func pressure(
        _ baseline: Double,
        risingBy meters: Double
    ) -> Double {
        baseline * pow(1 - meters / 44_330, 1 / 0.1903)
    }

    private func makeAltitudeReading(
        at date: Date,
        latitude: Double = 37.5,
        longitude: Double = 127,
        altitude: Double = 82,
        pressureKilopascals: Double
    ) -> SensorReading {
        SensorReading(
            timestamp: date,
            point: GeoPoint(
                latitude: latitude,
                longitude: longitude,
                altitude: altitude,
                horizontalAccuracy: 8,
                verticalAccuracy: 6
            ),
            pressureKilopascals: pressureKilopascals,
            // 앱을 다시 켠 뒤라 상대고도 세션이 끊겼다. 실제 기기에서 가장
            // 흔한 경우이므로 기압차 경로를 그대로 태운다.
            altimeterSessionID: UUID()
        )
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

    /// 새 기준점은 그 자리에서 바로 기준이 된다. 다음 센서 주기를 기다리면
    /// 사용자는 방금 고친 값이 반영되지 않았다고 본다.
    func testNewReferenceTakesEffectImmediately() throws {
        let base = makeDate(2026, 8, 5, 9, 0)
        let groundPressure = 101.0
        var place = FrequentPlace(kind: .company)
        place.calibrateCurrentFloor(
            to: 19,
            from: makeAltitudeReading(
                at: base,
                pressureKilopascals: groundPressure
            )
        )
        let here = makeAltitudeReading(
            at: base.addingTimeInterval(60),
            pressureKilopascals: pressure(groundPressure, risingBy: 0.2)
        )
        XCTAssertEqual(
            FloorCalibrationEngine().estimate(
                reading: here,
                calibration: try XCTUnwrap(place.floorCalibration)
            )?.floor,
            19
        )

        place.calibrateCurrentFloor(to: 2, from: here)

        XCTAssertEqual(
            FloorCalibrationEngine().estimate(
                reading: here,
                calibration: try XCTUnwrap(place.floorCalibration)
            )?.floor,
            2
        )
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

    private func legacyData(
        from value: some Encodable,
        without key: String
    ) throws -> Data {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
                as? [String: Any]
        )
        XCTAssertNotNil(object.removeValue(forKey: key))
        return try JSONSerialization.data(withJSONObject: object)
    }

    // MARK: - 고도 표본 묶음

    private func burstSamples(
        _ values: [Double],
        session: UUID,
        from start: Date
    ) -> [AltitudeBurstSample] {
        values.enumerated().map { index, meters in
            AltitudeBurstSample(
                relativeAltitudeMeters: meters,
                pressureKilopascals: pressure(101.0, risingBy: meters),
                altimeterSessionID: session,
                timestamp: start.addingTimeInterval(Double(index))
            )
        }
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

    private func makeUsageSample(
        key: String,
        title: String,
        nameSource: ScreenTimeUsageNameSource,
        start: Date,
        minutes: Double = 12
    ) -> ScreenTimeUsageSample {
        let span = TimeSpan(start: start, end: start.addingTimeInterval(3_600))
        return ScreenTimeUsageSample(
            key: key,
            title: title,
            span: span,
            duration: minutes * 60,
            pickups: 2,
            notifications: 1,
            nameSource: nameSource
        )
    }

    /// 스크린 타임은 화면에 뜨지 않는 iOS 서비스 프로세스까지 앱으로 올려
    /// 준다. 애플 번들 ID인데 시스템이 이름을 내주지 않은 줄만 감춘다.
    func testAppUsageRecordsHideAppleInternalServices() {
        let start = makeDate(2026, 8, 5, 9, 0)
        let samples = [
            makeUsageSample(
                key: "bundle:com.apple.ScreenshotServicesService",
                title: "ScreenshotServicesService",
                nameSource: .bundleIdentifier,
                start: start
            ),
            makeUsageSample(
                key: "bundle:com.apple.LocalAuthenticationUIService",
                title: "LocalAuthenticationUIService",
                nameSource: .bundleIdentifier,
                start: start
            ),
            makeUsageSample(
                key: "bundle:com.apple.mobilesafari",
                title: "Safari",
                nameSource: .application,
                start: start
            ),
            makeUsageSample(
                key: "bundle:com.apple.Maps",
                title: "지도",
                nameSource: .application,
                start: start
            ),
            makeUsageSample(
                key: "bundle:com.jumpdesktop.ios",
                title: "Jumpdesktop",
                nameSource: .bundleIdentifier,
                start: start
            ),
            makeUsageSample(
                key: "category:생산성",
                title: "생산성",
                nameSource: .category,
                start: start
            ),
            makeUsageSample(
                key: "total",
                title: "어플",
                nameSource: .unknown,
                start: start
            ),
        ]

        let records = ScreenTimeUsageRecordEngine.records(
            from: samples,
            suppressedIDs: []
        )

        // 이름이 온 애플 앱, 다른 회사 앱, 카테고리·합계 줄은 그대로 남는다.
        XCTAssertEqual(
            Set(records.map(\.title)),
            ["Safari", "지도", "Jumpdesktop", "생산성", "어플"]
        )
        XCTAssertTrue(
            samples
                .filter(ScreenTimeUsageRecordEngine.isHiddenSystemService)
                .map(\.title)
                .sorted()
                == ["LocalAuthenticationUIService", "ScreenshotServicesService"]
        )
    }

    /// 번들 ID가 없는 줄에는 이 규칙을 적용할 근거가 없다.
    func testHiddenSystemServiceRuleNeedsBothAppleBundleAndDerivedName() {
        let start = makeDate(2026, 8, 5, 9, 0)
        // 이름을 받은 애플 앱은 번들 ID가 애플이어도 남는다.
        XCTAssertFalse(
            ScreenTimeUsageRecordEngine.isHiddenSystemService(
                makeUsageSample(
                    key: "bundle:com.apple.MobileSMS",
                    title: "메시지",
                    nameSource: .application,
                    start: start
                )
            )
        )
        // 다른 회사 앱은 이름을 못 받아도 사용자가 직접 설치한 앱이다.
        XCTAssertFalse(
            ScreenTimeUsageRecordEngine.isHiddenSystemService(
                makeUsageSample(
                    key: "bundle:com.openai.chat",
                    title: "Chat",
                    nameSource: .bundleIdentifier,
                    start: start
                )
            )
        )
        // 토큰만 있는 줄은 번들 ID를 모르므로 판단하지 않는다.
        XCTAssertNil(
            ScreenTimeUsageRecordEngine.bundleIdentifier(
                of: makeUsageSample(
                    key: "token:abcd",
                    title: "Slideshow",
                    nameSource: .bundleIdentifier,
                    start: start
                )
            )
        )
    }

    // MARK: - 메모 이관이 메모를 잃지 않는지

    /// 실기기 모양 그대로: 카테고리 줄에 남긴 메모는 껍데기 계획에만 붙어
    /// 있었고 분류도 시각도 저장돼 있지 않았다. 이관 뒤에도 같은 분류·같은
    /// 날에서 찾을 수 있어야 하고, 기록 탭의 "이 기간을 설명한 기록"에도
    /// 그대로 떠야 한다.
    func testMemoShellMigrationKeepsLegacyMemoReachableAndRendered() throws {
        let start = makeDate(2026, 8, 4, 9, 30)
        let shell = makeMemoShellPlan(start: start)
        let legacyMemo = ActionMemo(
            planID: shell.id,
            categoryID: nil,
            occurredAt: nil,
            kind: .idea,
            text: "운동",
            createdAt: start,
            updatedAt: start
        )
        var snapshot = makeSnapshot(plans: [shell], memos: [legacyMemo])

        MemoShellPlanMigration.apply(to: &snapshot)

        XCTAssertTrue(snapshot.plans.isEmpty)
        let lifted = try XCTUnwrap(snapshot.memos.first)
        XCTAssertEqual(snapshot.memos.count, 1)
        XCTAssertEqual(lifted.id, legacyMemo.id)
        XCTAssertEqual(lifted.text, "운동")
        XCTAssertNil(lifted.planID)
        XCTAssertNil(lifted.targetID)
        XCTAssertEqual(lifted.categoryID, "activity")
        XCTAssertEqual(lifted.occurredAt, start)

        // 기록 탭의 맥락 줄을 만드는 바로 그 엔진.
        let report = ReviewEngine(calendar: utcCalendar).report(
            for: .day,
            containing: start,
            plans: snapshot.plans,
            actuals: [],
            weather: [],
            photos: [],
            memos: snapshot.memos,
            asOf: start.addingTimeInterval(hour)
        )
        XCTAssertEqual(report.contexts.map(\.text), ["운동"])
        XCTAssertEqual(report.contexts.map(\.symbolName), ["note.text"])
    }

    /// 자동 기록 줄에 남긴 메모는 껍데기 계획과 기록 키를 함께 들고 있었다.
    /// 이관은 계획 고리만 끊고 기록 키는 그대로 둬야 한다.
    func testMemoShellMigrationKeepsAutomaticRecordTargetKey() throws {
        let start = makeDate(2026, 8, 4, 9, 30)
        let shell = makeMemoShellPlan(start: start)
        let targetID = "automatic.actual.\(UUID().uuidString)"
        var snapshot = makeSnapshot(
            plans: [shell],
            memos: [
                ActionMemo(
                    planID: shell.id,
                    targetID: targetID,
                    kind: .idea,
                    text: "무릎 상태 확인",
                    createdAt: start,
                    updatedAt: start
                ),
            ]
        )

        MemoShellPlanMigration.apply(to: &snapshot)

        let lifted = try XCTUnwrap(snapshot.memos.first)
        XCTAssertNil(lifted.planID)
        XCTAssertEqual(lifted.targetID, targetID)
        XCTAssertEqual(lifted.categoryID, "activity")
        XCTAssertEqual(lifted.occurredAt, start)

        let report = ReviewEngine(calendar: utcCalendar).report(
            for: .day,
            containing: start,
            plans: snapshot.plans,
            actuals: [],
            weather: [],
            photos: [],
            memos: snapshot.memos,
            asOf: start.addingTimeInterval(hour)
        )
        XCTAssertEqual(report.contexts.map(\.text), ["무릎 상태 확인"])
    }

    /// 저장소에서 불러오는 실제 경로를 그대로 태운다. 껍데기 계획은 사라지고
    /// 메모는 분류 줄에서 다시 찾을 수 있어야 한다.
    @MainActor
    func testMemoShellMigrationSurvivesAppLoad() async {
        let start = makeDate(2026, 8, 4, 9, 30)
        let shell = makeMemoShellPlan(start: start)
        var stored = makeSnapshot(
            plans: [shell],
            memos: [
                ActionMemo(
                    planID: shell.id,
                    kind: .idea,
                    text: "운동",
                    createdAt: start,
                    updatedAt: start
                ),
            ]
        )
        stored.updatedAt = start
        stored.categories = CategoryCatalog.builtIn
        let model = AppModel(
            repository: InMemoryPlanRepository(snapshot: stored),
            cloudSyncService: nil
        )

        await model.bootstrap()
        // 이관은 첫 화면을 붙잡지 않도록 별도 작업에서 돈다.
        let deadline = Date.now.addingTimeInterval(10)
        while !model.snapshot.plans.isEmpty, Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertTrue(model.snapshot.plans.isEmpty)
        XCTAssertEqual(model.snapshot.memos.count, 1)
        XCTAssertEqual(
            model.memos(forCategoryID: "activity", on: start).map(\.text),
            ["운동"]
        )
    }

    /// 판독은 7일만 보관한다. 보관 기간이 지난 날을 열면 문맥을 다시 만들
    /// 근거가 없는데, 그렇다고 저장된 근무·수업 기록까지 지우면 되살릴 원본이
    /// 없다. 근거가 없는 갱신은 아무것도 지우지 않는다.
    @MainActor
    func testRefreshingADayWithoutArchivedReadingsKeepsStoredContextRecords()
        async throws {
        let day = makeDate(2026, 6, 1)
        let stored = ActualRecord(
            planID: nil,
            title: "근무",
            categoryID: "work",
            startedAt: makeDate(2026, 6, 1, 10),
            endedAt: makeDate(2026, 6, 1, 18),
            source: .location,
            confidence: .medium,
            createdAt: makeDate(2026, 6, 1, 10),
            behavior: "work",
            modelVersion: StationaryContextClassifier.modelVersion
        )
        var snapshot = makeSnapshot(actuals: [stored])
        snapshot.updatedAt = day
        snapshot.settings.locationEnabled = false
        snapshot.settings.weatherEnabled = false
        snapshot.settings.healthEnabled = false
        // 사진에 남은 위치 한 점만으로도 갱신은 판독 없이 끝까지 진행한다.
        snapshot.photos = [
            PhotoMoment(
                id: "photo-1",
                capturedAt: makeDate(2026, 6, 1, 12),
                pixelWidth: 100,
                pixelHeight: 100,
                isFavorite: false,
                isHiddenFromTimeline: false,
                location: GeoPoint(
                    latitude: 37.5,
                    longitude: 127.0,
                    altitude: 30,
                    horizontalAccuracy: 10,
                    verticalAccuracy: 10
                )
            ),
        ]

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            repository: InMemoryPlanRepository(snapshot: snapshot),
            sensorService: AppleSensorDataService(
                archive: SensorReadingArchive(
                    fileURL: directory
                        .appendingPathComponent("sensor-readings.jsonl")
                )
            ),
            cloudSyncService: nil
        )
        await model.bootstrap()
        // 불러오기 뒷정리가 끝난 뒤에 갱신해야 결과가 되돌려지지 않는다.
        let deadline = Date.now.addingTimeInterval(10)
        while model.snapshot.categories.isEmpty, Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(model.snapshot.categories.isEmpty)

        await model.refreshSensorTimeline(containing: day)

        XCTAssertEqual(
            model.snapshot.actuals
                .filter { $0.source == .location }
                .map(\.id),
            [stored.id]
        )
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        return calendar
    }

    // MARK: - 등록하지 않은 자주 가는 곳

    private func makeVisitStay(
        latitude: Double,
        longitude: Double,
        start: Date,
        minutes: Double = 60,
        displayName: String = "자동 감지 장소"
    ) -> PlaceStay {
        PlaceStay(
            // `PlaceDetectionEngine` 과 같은 방식의 좌표 키. 방문마다 GPS
            // 평균이 달라지므로 같은 자리라도 키가 갈린다.
            placeKey: String(format: "%.4f,%.4f", latitude, longitude),
            displayName: displayName,
            span: TimeSpan(
                start: start,
                end: start.addingTimeInterval(minutes * 60)
            ),
            confidence: .medium,
            point: GeoPoint(
                latitude: latitude,
                longitude: longitude,
                altitude: 30,
                horizontalAccuracy: 10,
                verticalAccuracy: 8
            )
        )
    }

    private func makeCafeVisits(
        from base: Date,
        dayOffsets: [Double]
    ) -> [PlaceStay] {
        // 좌표를 조금씩 흔들어 방문마다 `placeKey` 가 달라지게 한다. 같은
        // 장소를 알아보는 것은 키가 아니라 거리여야 한다.
        dayOffsets.enumerated().map { index, offset in
            makeVisitStay(
                latitude: 37.5000 + Double(index % 3) * 0.0002,
                longitude: 127.0000 + Double(index % 2) * 0.0002,
                start: base.addingTimeInterval(offset * 86_400)
            )
        }
    }

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

    func testDiagnosticsPackageIncludesIPhoneAndWatchLogs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let package = try TaptionPlanDiagnosticsLogPackageBuilder(
            packageDirectoryURL: root
        ).makePackage(
            summary: ["build": "47", "actuals": "12"],
            iphoneLog: "iphone-event",
            watchLog: "watch-event"
        )
        let text = try String(contentsOf: package, encoding: .utf8)

        XCTAssertTrue(text.contains("## iphone_log"))
        XCTAssertTrue(text.contains("iphone-event"))
        XCTAssertTrue(text.contains("## apple_watch_log"))
        XCTAssertTrue(text.contains("watch-event"))
        XCTAssertTrue(text.contains("raw health values are excluded"))
    }

    func testDiagnosticsICloudExporterKeepsSourceAndAvoidsCollision() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let package = root.appendingPathComponent("TaptionLogs-test.txt")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try "diagnostics".write(to: package, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let exporter = TaptionPlanDiagnosticsICloudExporter(
            ubiquityContainerURL: { root.appendingPathComponent("iCloud") },
            transferItem: { source, destination in
                try FileManager.default.copyItem(at: source, to: destination)
            }
        )

        let first = try exporter.export(package)
        let second = try exporter.export(package)

        XCTAssertTrue(FileManager.default.fileExists(atPath: package.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertEqual(second.lastPathComponent, "TaptionLogs-test-2.txt")
    }

    private func makeDate(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 0,
        _ minute: Int = 0
    ) -> Date {
        utcCalendar.date(
            from: DateComponents(
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute
            )
        )!
    }
}

private struct RawArchiveWatchFixture: Codable, Hashable {
    var sampleCount: Int
    var mode: String
}

private final class AirQualityURLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler:
        ((URLRequest) throws -> (Int, Data))?
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requestCount += 1
        guard let handler = Self.handler else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
