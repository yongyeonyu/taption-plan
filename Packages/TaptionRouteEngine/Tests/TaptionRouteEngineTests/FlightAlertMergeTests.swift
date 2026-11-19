import Foundation
import Testing
@testable import TaptionRouteEngine

/// FLT1119A01: 알림 병합 엔진. 같은 편명·같은 날짜는 카드 하나, 안내형은 카드를 만들지 않고, 후보가 둘 이상이면 묻는다.
struct FlightAlertMergeTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    private func day(_ month: Int, _ day: Int, hour: Int = 3, year: Int = 2027) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)) ?? .now
    }

    private final class IDs { var n = 0; func next() -> String { n += 1; return "c\(n)" } }

    private func apply(_ text: String, to cards: [FlightCard], at date: Date, ids: IDs = IDs()) -> FlightMergeResult {
        guard case .alert(let alert) = FlightAlertParser.parse(text, receivedAt: date) else { return FlightMergeResult(cards: cards, outcomes: []) }
        return FlightAlertMerge.apply(alert, to: cards, receivedAt: date, calendar: calendar, makeID: { ids.next() })
    }

    private let booking = "[가상항공] HONG/GILDONG 님, 예약번호 ABC123. 03월 07일 09:05 인천 출발, 방콕 도착 예정입니다."
    private let itinerary = "[가상항공] HONG/GILDONG 03/07 AB123 ICN -> BKK, 03/11 AB124 BKK -> ICN"

    // MARK: 분할 발송 ① + ②

    @Test func bookingThenItineraryMergesIntoOneOutboundCardAndAddsReturn() throws {
        let ids = IDs()
        var cards = apply(booking, to: [], at: day(3, 1), ids: ids).cards
        #expect(cards.count == 1)
        #expect(cards[0].flight == nil && cards[0].time == FlightAlertTime(hour: 9, minute: 5))
        let second = apply(itinerary, to: cards, at: day(3, 1, hour: 4), ids: ids)
        cards = second.cards
        #expect(cards.count == 2, "출국편은 합치고 귀국편만 새로 생긴다")
        #expect(second.outcomes == [.merged(cardID: "c1", filled: ["flight", "airline"]), .created(cardID: "c2")])
        let outbound = try #require(cards.first { $0.id == "c1" })
        #expect(outbound.flight == "AB123" && outbound.time == FlightAlertTime(hour: 9, minute: 5) && outbound.pnr == "ABC123")
        #expect(outbound.sources["time"] == .message && outbound.sources["flight"] == .message)
        let trips = FlightAlertMerge.groups(cards)
        #expect(trips == [FlightTripGroup(cardIDs: ["c1", "c2"], startDate: "2027-03-07", endDate: "2027-03-11")])
    }

    @Test func itineraryThenBookingMergesTheEmptyTimeFromTheNotice() throws {
        let ids = IDs()
        var cards = apply(itinerary, to: [], at: day(3, 1), ids: ids).cards
        #expect(cards.count == 2 && cards[0].time == nil)
        let second = apply(booking, to: cards, at: day(3, 1, hour: 5), ids: ids)
        cards = second.cards
        #expect(cards.count == 2, "같은 날짜·노선·항공사라 카드가 늘지 않는다")
        let outbound = try #require(cards.first { $0.flight == "AB123" })
        #expect(outbound.time == FlightAlertTime(hour: 9, minute: 5) && outbound.pnr == "ABC123")
    }

    @Test func sameFlightSameDateIsAlwaysOneCard() {
        let ids = IDs()
        var cards: [FlightCard] = []
        for hour in 1...4 { cards = apply(itinerary, to: cards, at: day(3, 1, hour: hour), ids: ids).cards }
        #expect(cards.count == 2)
        #expect(Set(cards.compactMap(\.flight)).count == 2)
    }

    // MARK: 병합 키 우선순위

    @Test func keyOrderIsDateFlightThenPNRThenDateRouteAirline() {
        let a = FlightCard(id: "a", flight: "AB123", airline: "AB", pnr: "ABC123", origin: "ICN", destination: "BKK", date: "2027-03-07")
        let b = FlightCard(id: "b", flight: "AB124", airline: "AB", pnr: "ABC123", origin: "BKK", destination: "ICN", date: "2027-03-11")
        let cards = [a, b]
        #expect(FlightAlertMerge.candidates(flight: "AB124", date: "2027-03-11", origin: nil, destination: nil, pnr: "ABC123", airline: nil, in: cards, allowRouteOnly: false) == [1], "날짜+편명이 먼저")
        #expect(FlightAlertMerge.candidates(flight: nil, date: "2027-03-11", origin: "BKK", destination: "ICN", pnr: "ABC123", airline: nil, in: cards, allowRouteOnly: false) == [1], "예약번호가 둘이어도 날짜·노선으로 좁힌다")
        #expect(FlightAlertMerge.candidates(flight: nil, date: nil, origin: nil, destination: nil, pnr: "ABC123", airline: nil, in: cards, allowRouteOnly: false) == [0, 1], "좁힐 열쇠가 없으면 둘 다")
        #expect(FlightAlertMerge.candidates(flight: nil, date: "2027-03-07", origin: "ICN", destination: "BKK", pnr: nil, airline: "AB", in: cards, allowRouteOnly: false) == [0])
        #expect(FlightAlertMerge.candidates(flight: nil, date: "2027-03-07", origin: "ICN", destination: "BKK", pnr: nil, airline: nil, in: cards, allowRouteOnly: false).isEmpty, "날짜+노선만으로는 안내형이 아니면 합치지 않는다")
        #expect(FlightAlertMerge.candidates(flight: nil, date: "2027-03-07", origin: "ICN", destination: "BKK", pnr: nil, airline: nil, in: cards, allowRouteOnly: true) == [0])
        #expect(FlightAlertMerge.candidates(flight: "ZZ999", date: "2027-03-07", origin: nil, destination: nil, pnr: nil, airline: nil, in: cards, allowRouteOnly: true).isEmpty)
    }

    @Test func twoCandidatesAskTheUserInsteadOfMerging() {
        let a = FlightCard(id: "a", flight: "AB123", pnr: "ABC123", origin: "ICN", destination: "BKK", date: "2027-03-07")
        let b = FlightCard(id: "b", flight: "AB124", pnr: "ABC123", origin: "BKK", destination: "ICN", date: "2027-03-11")
        // 날짜·노선이 없는 지연 글: 예약번호만으로는 둘 다 후보.
        let result = apply("[가상항공] 예약번호 ABC123 기존 14:20 변경 15:25 +65분", to: [a, b], at: day(3, 5))
        #expect(result.outcomes == [.needsConfirmation(candidateIDs: ["a", "b"])])
        #expect(result.cards == [a, b], "묻기 전에는 아무것도 바꾸지 않는다")
    }

    // MARK: 3번 지연

    @Test func delayUpdatesTheCardKeepsHistoryAndNeverMovesLaterPlans() throws {
        let card = FlightCard(id: "a", flight: "AB125", airline: "AB", pnr: "ABC123", origin: "ICN", destination: "BKK", date: "2027-03-07", time: FlightAlertTime(hour: 14, minute: 20))
        let result = apply("[가상항공] 예약번호 ABC123 편명 AB125 기존 14:20 → 변경 15:25 지연사유 기체 점검 +65분", to: [card], at: day(3, 7, hour: 2))
        #expect(result.outcomes == [.merged(cardID: "a", filled: ["time", "change"])])
        let updated = try #require(result.cards.first)
        #expect(updated.time == FlightAlertTime(hour: 15, minute: 25))
        #expect(updated.currentDelayMinutes == 65)
        let change = try #require(updated.changes.first)
        #expect(change.delayMinutes == 65 && change.reason == "기체 점검")
        #expect(change.before == FlightLocalTime(year: 2027, month: 3, day: 7, hour: 14, minute: 20))
        #expect(change.after == FlightLocalTime(year: 2027, month: 3, day: 7, hour: 15, minute: 25))
        // 같은 지연 글이 한 번 더 와도 이력은 쌓이되 카드는 하나.
        let again = apply("[가상항공] 예약번호 ABC123 편명 AB125 기존 15:25 변경 16:00 +35분", to: updated.self.changes.isEmpty ? [card] : result.cards, at: day(3, 7, hour: 3))
        #expect(again.cards.count == 1 && again.cards[0].changes.count == 2)
        #expect(again.cards[0].time == FlightAlertTime(hour: 16, minute: 0))
    }

    @Test func delayWithoutAMatchingCardIsDeferredNotCreated() {
        let result = apply("[가상항공] 예약번호 ZZZ999 편명 ZZ999 기존 14:20 변경 15:25 +65분", to: [], at: day(3, 7))
        #expect(result.outcomes == [.deferred(.noMatchingCard)])
        #expect(result.cards.isEmpty)
    }

    @Test func manualTimeIsNotOverwrittenByAMessage() throws {
        let card = FlightCard(id: "a", flight: "AB123", airline: "AB", origin: "ICN", destination: "BKK", date: "2027-03-07", time: FlightAlertTime(hour: 8, minute: 0),
                              sources: ["time": .manual], receivedAt: day(2, 1))
        let result = apply(booking, to: [card], at: day(3, 1))
        // 날짜·노선·항공사 이름이 달라(카드에 이름이 없음) 합쳐지지 않고 새 카드가 생긴다 → 직접 값이 보호되는지는 같은 편명 글로 따로 확인한다.
        #expect(result.cards.count == 2)
        let sameFlight = apply("[가상항공] 03/07 AB123 ICN -> BKK", to: [card], at: day(3, 1))
        #expect(sameFlight.cards.count == 1)
        #expect(sameFlight.cards[0].time == FlightAlertTime(hour: 8, minute: 0))
        #expect(sameFlight.cards[0].sources["time"] == .manual)
    }

    // MARK: 4번 체크인 · 5번 현장 안내 — 새 카드를 만들지 않는다

    @Test func checkInOnlyUpdatesAnExistingCardAndNeverCreatesOne() throws {
        let returning = FlightCard(id: "r", flight: "AB124", airline: "AB", pnr: "ABC123", origin: "DAD", destination: "ICN", date: "2027-03-11")
        let text = "[가상항공] 온라인 체크인 안내 예약번호 ABC123 DAD - ICN 출발일 03/11 체크인 가능 마감은 출발 90분 전입니다"
        let result = apply(text, to: [returning], at: day(3, 10))
        #expect(result.cards.count == 1)
        #expect(result.outcomes == [.merged(cardID: "r", filled: ["checkIn"])])
        #expect(result.cards[0].checkIn == FlightAlertCheckIn(isOpen: true, deadlineMinutesBeforeDeparture: 90))
        let none = apply(text, to: [], at: day(3, 10))
        #expect(none.cards.isEmpty)
        #expect(none.outcomes == [.deferred(.noMatchingCard)])
    }

    @Test func onsiteGuidanceCorrectsTheArrivalAndNeverCreatesACard() throws {
        let card = FlightCard(id: "r", flight: "AB124", origin: "DAD", destination: "ICN", date: "2027-03-11", time: FlightAlertTime(hour: 1, minute: 0))
        let text = "다낭-인천 출발 2시간 30분 전 도착 권장 · 21시 이후 혼잡 · 수속 마감 1시간 전"
        let result = apply(text, to: [card], at: day(3, 10))
        #expect(result.outcomes == [.merged(cardID: "r", filled: ["onsiteArrive", "notes"])])
        #expect(result.cards[0].onsiteArriveMinutesBefore == 150)
        #expect(result.cards[0].notes.contains("21시 이후 혼잡") && result.cards[0].notes.contains("수속 마감 출발 60분 전"))
        // 붙일 카드가 없으면 새 카드를 만들지 않고 보류.
        let none = apply(text, to: [], at: day(3, 10))
        #expect(none.cards.isEmpty && none.outcomes == [.deferred(.noMatchingTrip)])
        // 진행 중인 범위 밖(5일 뒤 카드)은 붙이지 않는다.
        let far = FlightCard(id: "f", flight: "AB124", origin: "DAD", destination: "ICN", date: "2027-03-20")
        #expect(apply(text, to: [far], at: day(3, 10)).outcomes == [.deferred(.noMatchingTrip)])
        // 같은 노선 카드가 둘이면 묻는다.
        let twin = FlightCard(id: "t", flight: "AB126", origin: "DAD", destination: "ICN", date: "2027-03-11")
        #expect(apply(text, to: [card, twin], at: day(3, 10)).outcomes == [.needsConfirmation(candidateIDs: ["r", "t"])])
    }

    // MARK: 6번 SMS 사전 안내

    @Test func smsAdvanceUsesDatePlusFlightAndNeverDuplicatesTheCard() throws {
        let sms = "[Web발신] (예약번호: 0000-0000) 03/07 AB123 노쇼 시 예약부도 위약금이 부과될 수 있습니다."
        let existing = FlightCard(id: "a", flight: "AB123", airline: "AB", origin: "ICN", destination: "BKK", date: "2027-03-07")
        let merged = apply(sms, to: [existing], at: day(3, 1))
        #expect(merged.cards.count == 1)
        #expect(merged.outcomes == [.merged(cardID: "a", filled: ["notes"])])
        #expect(merged.cards[0].notes.first?.contains("위약금") == true)
        #expect(merged.cards[0].pnr == nil, "전화번호 뒷자리는 예약번호로 저장하지 않는다")
        // 같은 문자가 또 와도 메모는 한 번.
        let again = apply(sms, to: merged.cards, at: day(3, 1, hour: 4))
        #expect(again.cards[0].notes.count == 1)
        // 카드가 없으면 편명으로 공공데이터를 조회해 등록한다(엔진은 요청만).
        let missing = apply(sms, to: [], at: day(3, 1))
        #expect(missing.cards.isEmpty)
        #expect(missing.outcomes == [.lookupNeeded(flight: "AB123", date: "2027-03-07")])
    }

    // MARK: 공공데이터 보충 · 부가 예약 · 경계

    @Test func publicDataFillsOnlyEmptyFieldsAndMarksTheSource() {
        let card = FlightCard(id: "a", flight: "AB123", terminal: "1", sources: ["terminal": .manual])
        let (filled, names) = FlightAlertMerge.fill(card, publicData: FlightPublicEntry(flight: "AB123", time: FlightAlertTime(hour: 9, minute: 5), terminal: "2", gate: "252"))
        #expect(filled.time == FlightAlertTime(hour: 9, minute: 5) && filled.gate == "252")
        #expect(filled.terminal == "1", "직접 적은 터미널은 그대로")
        #expect(filled.sources["time"] == .publicData && filled.sources["gate"] == .publicData)
        #expect(names == ["time", "gate"])
    }

    @Test func travelExtrasAreNotHandledByTheCardMerger() {
        let result = apply("[가상유심] eSIM 구매 완료\n상품명: 베트남 · 4일\nhttps://example.com/voucher", to: [], at: day(3, 1))
        #expect(result.outcomes == [.ignored] && result.cards.isEmpty)
    }

    @Test func groupsPairOutboundAndReturnWithinFortyFiveDaysAndLeaveOthersAlone() {
        let out = FlightCard(id: "o", flight: "AB123", origin: "ICN", destination: "BKK", date: "2027-03-07")
        let back = FlightCard(id: "b", flight: "AB124", origin: "BKK", destination: "ICN", date: "2027-03-11")
        let later = FlightCard(id: "l", flight: "CD1", origin: "ICN", destination: "NRT", date: "2027-06-01")
        let farBack = FlightCard(id: "fb", flight: "AB200", origin: "BKK", destination: "ICN", date: "2027-05-30")
        let groups = FlightAlertMerge.groups([later, back, out, farBack])
        #expect(groups.first == FlightTripGroup(cardIDs: ["o", "b"], startDate: "2027-03-07", endDate: "2027-03-11"))
        #expect(groups.count == 3, "46일 넘게 떨어진 귀국편은 묶지 않는다")
        let samePNR = [FlightCard(id: "x", pnr: "ABC123", date: "2027-03-07"), FlightCard(id: "y", pnr: "ABC123", date: "2027-04-30")]
        #expect(FlightAlertMerge.groups(samePNR).count == 1, "같은 예약번호는 간격과 무관하게 한 여행")
    }

    @Test func cardWithoutEnoughInformationIsNotCreated() {
        // 날짜 없는 알림(연도·월일 없음)은 카드를 만들 수 없다.
        let alert = FlightAlert(kind: .itinerary, marker: nil, segments: [FlightAlertSegment(flight: "AB123")], pnr: nil, passengerName: nil, airlineName: nil,
                                change: nil, checkIn: nil, onsite: nil, extra: nil, notes: [], droppedPhoneAsPNR: false)
        let result = FlightAlertMerge.apply(alert, to: [], receivedAt: day(3, 1), calendar: calendar)
        #expect(result.cards.isEmpty && result.outcomes == [.deferred(.noMatchingCard)])
    }

    @Test func sameReservationNumberDoesNotMergeADifferentFlightOrDate() {
        let ids = IDs()
        // 한 예약번호로 출국편(03/07 AB123)과 귀국편(03/11 AB124)이 한 글에 온다: 두 카드가 생겨야 한다.
        let result = apply("[가상항공] HONG/GILDONG 예약번호 ABC123 03/07 AB123 ICN -> BKK, 03/11 AB124 BKK -> ICN", to: [], at: day(3, 1), ids: ids)
        #expect(result.cards.count == 2)
        #expect(result.cards.map(\.pnr) == ["ABC123", "ABC123"])
        #expect(result.outcomes == [.created(cardID: "c1"), .created(cardID: "c2")])
        // 편명이 다른 지연 글은 같은 예약번호의 다른 카드에 붙지 않는다.
        let other = apply("[가상항공] 예약번호 ABC123 편명 AB999 기존 14:20 변경 15:25 +65분", to: result.cards, at: day(3, 5))
        #expect(other.outcomes == [.deferred(.noMatchingCard)])
    }
}
