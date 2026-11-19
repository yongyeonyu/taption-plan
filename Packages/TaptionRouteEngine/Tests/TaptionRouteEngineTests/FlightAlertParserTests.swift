import Foundation
import Testing
@testable import TaptionRouteEngine

/// FLT1119A01: 항공 알림 파서. 샘플은 전부 가짜다(HONG/GILDONG·ABC123·0000-0000·example.com).
struct FlightAlertParserTests {
    private let received: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar.date(from: DateComponents(year: 2027, month: 3, day: 1, hour: 3)) ?? .now
    }()

    private func alert(_ text: String) -> FlightAlert? {
        if case .alert(let value) = FlightAlertParser.parse(text, receivedAt: received) { return value }
        return nil
    }

    // MARK: 정규화

    @Test func normalizerFoldsFullWidthSpacingArrowsAndMarker() {
        let raw = "[Web발신]\r\n\u{FF21}\u{FF22}\u{FF11}\u{FF12}\u{FF13}　ICN  ->  BKK \u{FF5E}\n\n\n 다낭 - 인천 “시험”"
        let result = FlightAlertText.normalize(raw)
        #expect(result.marker == "Web발신")
        #expect(result.text.contains("AB123"))
        #expect(result.text.contains("ICN→BKK"))
        #expect(result.text.contains("다낭→인천"))
        #expect(result.text.contains("\"시험\""))
        #expect(!result.text.contains("\n\n\n"))
        #expect(!result.text.contains("  "))
        #expect(FlightAlertText.normalize("[가상항공] 안녕").marker == nil, "항공사 이름 머리표는 떼지 않는다")
        #expect(FlightAlertText.normalize("   ").text.isEmpty)
        #expect(FlightAlertText.normalize("(광고)[Web발신] 본문").marker != nil)
    }

    @Test func arrowVariantsAllBecomeOne() {
        for variant in ["ICN->BKK", "ICN → BKK", "ICN~BKK", "ICN-BKK", "ICN ⇒ BKK", "ICN – BKK"] {
            #expect(FlightAlertText.normalize(variant).text == "ICN→BKK", "\(variant)")
        }
    }

    // MARK: 유형 1 ① 예약번호 안내

    @Test func bookingNoticeGivesPNRCityPairTimeAndDate() throws {
        let value = try #require(alert("[가상항공] HONG/GILDONG 님, 예약번호 ABC123. 03월 07일 09:05 인천 출발, 방콕 도착 예정입니다."))
        #expect(value.kind == .bookingNotice)
        #expect(value.pnr == "ABC123")
        #expect(value.passengerName == "HONG/GILDONG")
        #expect(value.airlineName == "가상항공")
        let segment = try #require(value.segments.first)
        #expect(segment.origin == "ICN" && segment.destination == "BKK")
        #expect(segment.time == FlightAlertTime(hour: 9, minute: 5))
        #expect(segment.date == FlightAlertDate(month: 3, day: 7))
        #expect(segment.flight == nil)
    }

    @Test func bookingNoticeBrokenOrMissingPartsAreNotInvented() {
        #expect(alert("[가상항공] 예약번호 ABC123. 인천 출발, 방콕 도착 예정입니다.") == nil, "시각이 없으면 안내형으로 읽지 않는다")
        #expect(alert("[가상항공] 예약번호 ABC123. 03월 07일 09:05 출발 도착 예정입니다.") == nil)
    }

    // MARK: 유형 1 ② 여정

    @Test func itineraryListsFlightsRoutesAndDatesWithoutTimes() throws {
        let value = try #require(alert("[가상항공] HONG/GILDONG 03/07 AB123 ICN -> BKK, 03/11 AB124 BKK -> ICN"))
        #expect(value.kind == .itinerary)
        #expect(value.segments.count == 2)
        #expect(value.segments[0] == FlightAlertSegment(flight: "AB123", origin: "ICN", destination: "BKK", date: FlightAlertDate(month: 3, day: 7), time: nil))
        #expect(value.segments[1] == FlightAlertSegment(flight: "AB124", origin: "BKK", destination: "ICN", date: FlightAlertDate(month: 3, day: 11), time: nil))
        #expect(value.pnr == nil)
        #expect(value.airlineName == "가상항공")
    }

    @Test func itineraryAcceptsLowercaseAndAirlineCodesWithDigits() throws {
        let value = try #require(alert("[가상항공] 03/07 ab123 icn -> bkk, 03/11 7c456 bkk -> icn"))
        #expect(value.segments.map(\.flight) == ["AB123", "7C456"])
        #expect(value.segments[0].origin == "ICN")
    }

    // MARK: 유형 2 본문 항공사명형

    @Test func airlineNameBodyKeepsFooterNotesAndHasNoFlightOrTime() throws {
        let text = """
        [가상항공]
        HONG/GILDONG 님
        예약번호 ABC123
        ICN - DAD
        출발일 2027-03-07
        ※ 출국장 마감 1시간 전 도착
        보조배터리는 기내 반입만 가능합니다.
        """
        let value = try #require(alert(text))
        #expect(value.kind == .airlineNameBody)
        #expect(value.segments[0].origin == "ICN" && value.segments[0].destination == "DAD")
        #expect(value.segments[0].date == FlightAlertDate(year: 2027, month: 3, day: 7))
        #expect(value.segments[0].flight == nil && value.segments[0].time == nil)
        #expect(value.notes.count == 2)
        #expect(value.notes.contains { $0.contains("보조배터리") })
    }

    // MARK: 유형 3 지연

    @Test func delayNoticeGivesOldNewTimeDelayAndReason() throws {
        let value = try #require(alert("[가상항공] 예약번호 ABC123 편명 AB125 기존 14:20 → 변경 15:25 지연사유 기체 점검 +65분"))
        #expect(value.kind == .delayChange)
        let change = try #require(value.change)
        #expect(change.flight == "AB125")
        #expect(change.from == FlightAlertTime(hour: 14, minute: 20))
        #expect(change.to == FlightAlertTime(hour: 15, minute: 25))
        #expect(change.delayMinutes == 65)
        #expect(change.reason == "기체 점검")
        #expect(value.pnr == "ABC123")
    }

    @Test func delayMinutesAreDerivedWhenNotWrittenAndAcrossMidnight() throws {
        let value = try #require(alert("[가상항공] 편명 AB126 기존 23:50 변경 00:20"))
        #expect(value.change?.delayMinutes == 30)
        let plain = try #require(alert("[가상항공] 편명 AB127 기존 09:00 변경 10:10"))
        #expect(plain.change?.delayMinutes == 70)
        #expect(alert("[가상항공] 일정 변경은 고객센터로 문의해 주세요.") == nil, "시각도 지연 분도 없는 안내는 지연 알림이 아니다")
    }

    // MARK: 유형 4 체크인

    @Test func checkInNoticeGivesStatusAndDeadlineNotNewCard() throws {
        let value = try #require(alert("[가상항공] 온라인 체크인 안내 예약번호 ABC123 DAD - ICN 출발일 03/11 체크인 가능 마감은 출발 90분 전입니다"))
        #expect(value.kind == .checkIn)
        let info = try #require(value.checkIn)
        #expect(info.isOpen)
        #expect(info.deadlineMinutesBeforeDeparture == 90)
        #expect(value.segments[0].origin == "DAD" && value.segments[0].destination == "ICN")
        #expect(value.pnr == "ABC123")
    }

    @Test func hotelCheckInIsNotAFlightCheckIn() {
        let result = alert("[가상숙소] 숙소 체크인 안내 예약번호 XYZ789 체크인 15:00 체크아웃 11:00")
        #expect(result?.kind != .checkIn)
    }

    // MARK: 유형 5 현장·혼잡도

    @Test func onsiteGuidanceGivesLeadCongestionAndCounterClose() throws {
        let value = try #require(alert("다낭-인천 출발 2시간 30분 전 도착 권장 · 21시 이후 혼잡 · 수속 마감 1시간 전"))
        #expect(value.kind == .airportOnsite)
        #expect(value.segments[0].origin == "DAD" && value.segments[0].destination == "ICN")
        #expect(value.onsite == FlightAlertOnsite(arriveMinutesBeforeDeparture: 150, congestedAfterHour: 21, counterCloseMinutesBeforeDeparture: 60))
        #expect(value.pnr == nil)
    }

    // MARK: 유형 6 SMS 사전 안내

    @Test func smsAdvanceDropsPhoneSuffixAsReservationNumber() throws {
        let value = try #require(alert("[Web발신] (예약번호: 0000-0000) 03/07 AB123 노쇼 시 예약부도 위약금이 부과될 수 있습니다."))
        #expect(value.kind == .smsAdvance)
        #expect(value.pnr == nil, "전화번호 뒷자리는 예약번호가 아니다")
        #expect(value.droppedPhoneAsPNR)
        #expect(value.marker == "Web발신")
        #expect(value.segments[0].flight == "AB123")
        #expect(value.segments[0].date == FlightAlertDate(month: 3, day: 7))
        #expect(value.notes.first?.contains("위약금") == true)
    }

    @Test func longDigitStringsAreNeverReservationNumbers() throws {
        let value = try #require(alert("[가상항공] 예약번호 12345678901 편명 AB125 기존 14:20 변경 15:25"))
        #expect(value.pnr == nil)
        #expect(value.change?.flight == "AB125")
    }

    // MARK: 유형 7 부가 예약

    @Test func esimGivesCountryDaysLinkAndValidity() throws {
        let value = try #require(alert("[가상유심] eSIM 구매 완료\n상품명: 베트남 · 4일 데이터 무제한\n개통 링크 https://example.com/voucher\nQR 발급 후 30일 내 사용"))
        #expect(value.kind == .travelExtra)
        let extra = try #require(value.extra)
        #expect(extra.kind == .esim)
        #expect(extra.country == "베트남" && extra.days == 4)
        #expect(extra.link == "https://example.com/voucher")
        #expect(extra.validityNote?.contains("30일") == true)
    }

    @Test func lodgingReceiptIsTentativeBusinessTaggedAndPeriodIsAmbiguous() throws {
        let value = try #require(alert("[가상숙소] 예약 접수 안내 예약번호 XYZ789 이용기간 05/03 ~ 09/15 출장문의"))
        let extra = try #require(value.extra)
        #expect(extra.kind == .lodging)
        #expect(extra.status == .tentative)
        #expect(extra.isBusiness)
        #expect(extra.ambiguousPeriod?.start == FlightAlertDate(month: 5, day: 3))
        #expect(extra.ambiguousPeriod?.end == FlightAlertDate(month: 9, day: 15))
        #expect(value.pnr == "XYZ789")
        let confirmed = try #require(alert("[가상숙소] 예약 확정 예약번호 XYZ789 호텔 객실 1박"))
        #expect(confirmed.extra?.status == .booked)
    }

    @Test func dutyFreeOrderAndReceiptShareTheOrderNumber() throws {
        let order = try #require(alert("[가상면세점] 주문완료 주문번호 1234567890 출국일시 2027-03-07 09:05 인도장 제1터미널 3층 인도장"))
        let extra = try #require(order.extra)
        #expect(extra.kind == .dutyFree)
        #expect(extra.orderNumber == "1234567890")
        #expect(extra.status == .booked)
        #expect(extra.departureDate == FlightAlertDate(year: 2027, month: 3, day: 7))
        #expect(extra.departureTime == FlightAlertTime(hour: 9, minute: 5))
        let receipt = try #require(alert("[가상면세점] 정상 수령 안내 주문번호 1234567890 주문상품정보 화장품 1건"))
        #expect(receipt.extra?.status == .received)
        #expect(receipt.extra?.orderNumber == "1234567890")
    }

    // MARK: 못 읽음·경계

    @Test func unreadableTextsReturnUnreadable() {
        for text in ["", "   \n  ", "안녕하세요 오늘 점심 뭐 드실래요", "택배 송장 번호 AB123456 배송 출발", "인증번호 482913 을 입력해 주세요", String(repeating: "가", count: 7_000)] {
            #expect(FlightAlertParser.parse(text, receivedAt: received) == .unreadable, "\(text.prefix(20))")
        }
    }

    @Test func datesFollowFourFormatsAndInferTheYearFromReceivedDate() throws {
        let forms = ["2027-03-07", "2027.03.07", "3월 7일", "03/07", "03.07"]
        for form in forms {
            let dates = FlightAlertParser.dates(in: "출발 \(form) 입니다")
            #expect(dates.count == 1, "\(form)")
            #expect(dates[0].month == 3 && dates[0].day == 7)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        // 3월 1일에 받은 「03/07」은 올해, 12월에 받은 「01/05」는 내년.
        #expect(FlightAlertDate(month: 3, day: 7).resolved(reference: received, calendar: calendar)?.year == 2027)
        let december = calendar.date(from: DateComponents(year: 2026, month: 12, day: 20)) ?? .now
        #expect(FlightAlertDate(month: 1, day: 5).resolved(reference: december, calendar: calendar)?.year == 2027)
        #expect(FlightAlertDate(month: 2, day: 30).resolved(reference: received, calendar: calendar) == nil, "없는 날짜")
        #expect(FlightAlertParser.dates(in: "예약번호 0000-0000").isEmpty)
    }

    @Test func parserNeverOutputsAnythingAndDoesNotCrashOnHostileInput() {
        let hostile = ["(" + String(repeating: "[", count: 2_000), "ICN→", "→BKK", "예약번호", "예약번호 :", "편명 ::: 기존 변경 +분", String(repeating: "ICN→BKK ", count: 500)]
        for text in hostile { _ = FlightAlertParser.parse(text, receivedAt: received) }
    }

    @Test func longInputsStayFast() {
        let clock = ContinuousClock()
        let samples = [String(repeating: "가", count: 5_900), String(repeating: "A", count: 5_900), String(repeating: "ICN->", count: 1_100),
                       String(repeating: "예약번호 ", count: 1_000), String(repeating: "1", count: 5_900), String(repeating: "가 ", count: 2_900)]
        for sample in samples {
            let elapsed = clock.measure { _ = FlightAlertParser.parse(sample, receivedAt: received) }
            #expect(elapsed < .seconds(2), "\(sample.prefix(6))… \(elapsed)")
        }
        #expect(FlightAlertParser.parse(String(repeating: "가", count: 12_001), receivedAt: received) == .unreadable)
    }
}
