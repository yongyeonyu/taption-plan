import XCTest
import UIKit
import CoreLocation
import StoreKit
import StoreKitTest
import TaptionPlanCore
@testable import TaptionPlan

/// 회사 하루가 실내 GPS 흔들림으로 조각나도 근무 한 줄이어야 한다(WRK1029A01).
final class OfficeStayAbsorptionTests: XCTestCase, UTCDateFixture {
    // WRK1029A02: 잠긴 예전 자동 '휴식' 조각이 새로 판정한 회사 업무를 덮지 않는다.
    func testRegisteredCompanyWorkReplacesLockedGenericRest() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let span = TimeSpan(start: start, end: start.addingTimeInterval(9 * 3_600))
        let locked = ActualRecord(
            planID: nil, title: "집에서 휴식", categoryID: "rest",
            startedAt: start.addingTimeInterval(600), endedAt: start.addingTimeInterval(3 * 3_600),
            source: .location, behavior: "homeRest", modelVersion: StationaryContextClassifier.modelVersion,
            isClassificationLocked: true
        )
        let fresh = ActualRecord(
            planID: nil, title: "근무", categoryID: "work",
            startedAt: start, endedAt: span.end,
            source: .location, behavior: StationaryContextKind.work.rawValue,
            evidence: ["자주가는 곳: 회사"], modelVersion: StationaryContextClassifier.modelVersion
        )

        let merged = ActivityClassificationLockEngine.mergingLockedClassifications(
            existing: [locked], fresh: [fresh], inside: span
        )

        XCTAssertEqual(merged.map(\.categoryID), ["work"])
    }

    private let officeKey = "frequent-office"
    private let hour: TimeInterval = 3_600

    /// 회사 조각 셋 사이에 걷기 조각과 짧은 빈 시간, 반경 밖으로 튄 한 점이
    /// 있어도 출근부터 퇴근까지 근무 하나다.
    func testOfficeDaySplitByWalkingPiecesBecomesOneWorkRecord() {
        let arrival = makeDate(2026, 10, 29, 10, 7)
        let leave = makeDate(2026, 10, 29, 19, 32)
        let stays = [
            officeStay(start: arrival, end: makeDate(2026, 10, 29, 11, 0)),
            walkingStay(
                start: makeDate(2026, 10, 29, 11, 3),
                end: makeDate(2026, 10, 29, 11, 8),
                metersNorth: 60
            ),
            officeStay(
                start: makeDate(2026, 10, 29, 11, 30),
                end: makeDate(2026, 10, 29, 14, 0)
            ),
            walkingStay(
                start: makeDate(2026, 10, 29, 14, 2),
                end: makeDate(2026, 10, 29, 14, 9),
                metersNorth: 200
            ),
            officeStay(start: makeDate(2026, 10, 29, 14, 20), end: leave),
        ]
        // 10:07부터 5분마다 한 점. 11:17 한 점만 220m로 튄다(사이 6점 중 1점).
        let readings = officeReadings(from: arrival, to: leave) { date in
            date == makeDate(2026, 10, 29, 11, 17) ? 220 : 40
        }
        let records = officeRecords(stays: stays, readings: readings)

        XCTAssertEqual(records.map(\.title), ["근무"])
        XCTAssertEqual(records.first?.startedAt, arrival)
        XCTAssertEqual(records.first?.endedAt, leave)
    }

    /// 이름표를 받지 못한 좌표 키 조각도 중심이 회사 반경 안이면 앞뒤로 붙는다.
    func testRawKeyPieceInsideCompanyRadiusJoinsTheWorkStay() {
        let start = makeDate(2026, 10, 29, 9, 0)
        let end = makeDate(2026, 10, 29, 13, 0)
        let stays = [
            rawStay(
                start: start,
                end: makeDate(2026, 10, 29, 9, 20),
                metersNorth: 130
            ),
            officeStay(
                start: makeDate(2026, 10, 29, 9, 25),
                end: makeDate(2026, 10, 29, 12, 0)
            ),
            rawStay(
                start: makeDate(2026, 10, 29, 12, 10),
                end: end,
                metersNorth: 50
            ),
        ]
        let readings = officeReadings(from: start, to: end) { _ in 30 }
        let records = officeRecords(stays: stays, readings: readings)

        XCTAssertEqual(records.map(\.title), ["근무"])
        XCTAssertEqual(records.first?.startedAt, start)
        XCTAssertEqual(records.first?.endedAt, end)
    }

    /// 20분 넘게 비고 그동안 위치가 150m 밖에 찍혔으면 나갔다 온 것이다.
    func testGenuineDepartureStillSplitsTheWorkDay() {
        let start = makeDate(2026, 10, 29, 9, 0)
        let end = makeDate(2026, 10, 29, 18, 0)
        let stays = [
            officeStay(start: start, end: makeDate(2026, 10, 29, 12, 0)),
            officeStay(start: makeDate(2026, 10, 29, 12, 40), end: end),
        ]
        let away = TimeSpan(
            start: makeDate(2026, 10, 29, 12, 5),
            end: makeDate(2026, 10, 29, 12, 35)
        )
        let readings = officeReadings(from: start, to: end) { date in
            away.contains(date) ? 400 : 30
        }
        let records = officeRecords(stays: stays, readings: readings)

        XCTAssertEqual(records.map(\.title), ["근무", "근무"])
        XCTAssertEqual(records.first?.endedAt, stays[0].span.end)
        XCTAssertEqual(records.last?.startedAt, stays[1].span.start)
    }

    /// 회사 회의 중 실내에서 위치가 1시간 넘게 끊겨도, 앞뒤가 회사이고 그 사이에 일정이 있으면 이어서 회의로 기록한다(CAL1111A02).
    func testCalendarMeetingBridgesALongNoLocationGapAtTheOffice() {
        let before = officeStay(start: makeDate(2026, 10, 29, 12, 18), end: makeDate(2026, 10, 29, 13, 54))
        let after = officeStay(start: makeDate(2026, 10, 29, 15, 37), end: makeDate(2026, 10, 29, 17, 0))
        // 마지막 위치는 체류 끝 6분 전, 다음 위치는 15:37. 공백 안에는 위치가 한 점도 없다.
        let readings = officeReadings(from: before.span.start, to: before.span.end.addingTimeInterval(-360)) { _ in 10 }
            + officeReadings(from: after.span.start, to: after.span.end) { _ in 10 }
        let meeting = CalendarRecord(
            id: "m", calendarID: "c", title: "주간 회의",
            span: TimeSpan(start: makeDate(2026, 10, 29, 14, 0), end: makeDate(2026, 10, 29, 15, 0)),
            isAllDay: false, calendarTitle: "업무"
        )
        let day = TimeSpan(start: makeDate(2026, 10, 29, 0, 0), end: makeDate(2026, 10, 30, 0, 0))
        func records(_ events: [CalendarRecord]) -> [ActualRecord] {
            StationaryContextActualEngine.records(
                stays: [before, after], placeKinds: [officeKey: .company],
                placeAnchors: [officeKey: FrequentPlaceAnchor(point: officePoint(0), radiusMeters: 70)],
                readings: readings, calendarEvents: events, inside: day, calendar: utcCalendar, now: day.end
            )
        }

        let bridged = records([meeting])
        let atMeeting = bridged.first { $0.startedAt <= makeDate(2026, 10, 29, 14, 30) && ($0.endedAt ?? .distantPast) > makeDate(2026, 10, 29, 14, 30) }
        XCTAssertEqual(atMeeting?.categoryID, "work")
        XCTAssertEqual(atMeeting?.startedAt, meeting.span.start)
        XCTAssertEqual(atMeeting?.endedAt, meeting.span.end)
    }

    /// 돌아온 지 얼마 안 돼 다음 체류가 아직 안 생겼어도, 회사 반경 안 최근 위치를 이어서 회의를 채운다(CAL1111A02: 15:37 복귀, 15:46 기록).
    func testCalendarMeetingBridgesToRecentReadingsBeforeTheNextStayForms() {
        let before = officeStay(start: makeDate(2026, 10, 29, 12, 18), end: makeDate(2026, 10, 29, 13, 54))
        let readings = officeReadings(from: before.span.start, to: before.span.end.addingTimeInterval(-360)) { _ in 10 }
            + officeReadings(from: makeDate(2026, 10, 29, 15, 37), to: makeDate(2026, 10, 29, 15, 46)) { _ in 5 }
        let meeting = CalendarRecord(
            id: "m", calendarID: "c", title: "주간 회의",
            span: TimeSpan(start: makeDate(2026, 10, 29, 14, 0), end: makeDate(2026, 10, 29, 15, 0)),
            isAllDay: false, calendarTitle: "업무"
        )
        let day = TimeSpan(start: makeDate(2026, 10, 29, 0, 0), end: makeDate(2026, 10, 30, 0, 0))
        let records = StationaryContextActualEngine.records(
            stays: [before], placeKinds: [officeKey: .company],
            placeAnchors: [officeKey: FrequentPlaceAnchor(point: officePoint(0), radiusMeters: 70)],
            readings: readings, calendarEvents: [meeting], inside: day, calendar: utcCalendar,
            now: makeDate(2026, 10, 29, 15, 46)
        )
        let atMeeting = records.first { $0.startedAt <= makeDate(2026, 10, 29, 14, 30) && ($0.endedAt ?? .distantPast) > makeDate(2026, 10, 29, 14, 30) }
        XCTAssertEqual(atMeeting?.categoryID, "work")
        XCTAssertEqual(atMeeting?.startedAt, meeting.span.start)
    }

    // MARK: - 재료

    private func officePoint(_ metersNorth: Double) -> GeoPoint {
        GeoPoint(
            latitude: 37.5 + metersNorth / 111_320,
            longitude: 127,
            altitude: 40,
            horizontalAccuracy: 12,
            verticalAccuracy: 8
        )
    }

    private func officeStay(start: Date, end: Date) -> PlaceStay {
        PlaceStay(
            placeKey: officeKey,
            displayName: "회사",
            span: TimeSpan(start: start, end: end),
            confidence: .high,
            point: officePoint(0),
            isConfirmed: true
        )
    }

    private func walkingStay(
        start: Date, end: Date, metersNorth: Double
    ) -> PlaceStay {
        PlaceStay(
            placeKey: "walking:\(start.timeIntervalSince1970)",
            displayName: "걷기",
            span: TimeSpan(start: start, end: end),
            confidence: .medium,
            point: officePoint(metersNorth)
        )
    }

    private func rawStay(
        start: Date, end: Date, metersNorth: Double
    ) -> PlaceStay {
        let point = officePoint(metersNorth)
        return PlaceStay(
            placeKey: String(
                format: "%.4f,%.4f", point.latitude, point.longitude
            ),
            displayName: "장소",
            span: TimeSpan(start: start, end: end),
            confidence: .medium,
            point: point
        )
    }

    private func officeReadings(
        from start: Date,
        to end: Date,
        metersFromAnchor: (Date) -> Double
    ) -> [SensorReading] {
        stride(from: 0, through: end.timeIntervalSince(start), by: 300).map {
            let date = start.addingTimeInterval($0)
            return SensorReading(
                timestamp: date,
                point: officePoint(metersFromAnchor(date)),
                motion: .stationary,
                motionConfidence: .high
            )
        }
    }

    /// 설정 반경 70m·하루 범위. 잇기 바닥 반경 150m가 실내 흔들림을 받는다.
    private func officeRecords(
        stays: [PlaceStay],
        readings: [SensorReading]
    ) -> [ActualRecord] {
        let day = TimeSpan(
            start: makeDate(2026, 10, 29, 0, 0),
            end: makeDate(2026, 10, 30, 0, 0)
        )
        return StationaryContextActualEngine.records(
            stays: stays,
            placeKinds: [officeKey: .company],
            placeAnchors: [
                officeKey: FrequentPlaceAnchor(
                    point: officePoint(0),
                    radiusMeters: 70
                ),
            ],
            readings: readings,
            inside: day,
            calendar: utcCalendar,
            now: day.end
        )
    }
}
