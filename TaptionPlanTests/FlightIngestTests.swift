import XCTest
@testable import TaptionPlan
import TaptionPlanEngine
import TaptionPlanStore

/// FLT1119A01: 항공 알림 → 여행 일정 칸. 샘플은 전부 가짜(HONG/GILDONG·ABC123·0000-0000·example.com)다.
final class FlightIngestTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    private func date(_ month: Int, _ day: Int, hour: Int = 3) -> Date {
        calendar.date(from: DateComponents(year: 2027, month: month, day: day, hour: hour)) ?? .now
    }

    private let booking = "[가상항공] HONG/GILDONG 님, 예약번호 ABC123. 03월 07일 09:05 인천 출발, 방콕 도착 예정입니다."
    private let itinerary = "[가상항공] HONG/GILDONG 03/07 AB123 ICN -> BKK, 03/11 AB124 BKK -> ICN"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: FlightInbox.key)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: FlightInbox.key)
        super.tearDown()
    }

    @MainActor
    private func tripModel(start: String = "2027-03-07", end: String = "2027-03-11") async throws -> AppModel {
        let model = AppModel(repository: InMemoryPlanRepository(), cloudSyncService: nil)
        await model.bootstrapLocalSnapshot()
        let saved = await model.saveTravelTrip(TravelTrip(id: "t1", title: "방콕", startDay: start, endDay: end))
        XCTAssertTrue(saved)
        return model
    }

    @MainActor
    private func flightItems(_ model: AppModel) -> [TravelTripItem] {
        (model.settings.travelTripItems ?? []).filter(\.isFlight).sorted { $0.start < $1.start }
    }

    // MARK: 변환

    func testCardRoundTripsThroughAnItemWithoutLeakingPersonalDataIntoTheLog() throws {
        var card = FlightCard(id: "t1|i1", flight: "AB123", airline: "AB", airlineName: "가상항공", pnr: "ABC123", origin: "ICN", destination: "BKK", date: "2027-03-07",
                              time: FlightAlertTime(hour: 9, minute: 5), terminal: "2", gate: "252",
                              checkIn: FlightAlertCheckIn(isOpen: true, deadlineMinutesBeforeDeparture: 90), onsiteArriveMinutesBefore: 150,
                              changes: [FlightChange(flight: "AB123", before: FlightLocalTime(year: 2027, month: 3, day: 7, hour: 9, minute: 5),
                                                     after: FlightLocalTime(year: 2027, month: 3, day: 7, hour: 10, minute: 10), delayMinutes: 65, reason: "기체 점검", receivedAt: date(3, 7))],
                              notes: ["21시 이후 혼잡"], sources: ["time": .message, "flight": .publicData], confidence: 0.8, receivedAt: date(3, 1))
        let schedule = try XCTUnwrap(FlightCardMapping.schedule(for: card))
        var item = TravelTripItem(tripID: "t1", itemID: "i1", kind: "flight", title: "AB123 ICN → BKK", start: schedule.start, end: schedule.end,
                                  startOffsetSeconds: schedule.startOffsetSeconds, endOffsetSeconds: schedule.endOffsetSeconds, planID: nil)
        FlightCardMapping.apply(card, to: &item)
        let log = try XCTUnwrap(item.flightLog)
        XCTAssertFalse(log.contains("ABC123"), "예약번호는 flightLog에 없다(pnrLocal에만)")
        XCTAssertFalse(log.contains("HONG"))
        XCTAssertEqual(item.pnrLocal, "ABC123")
        let back = try XCTUnwrap(FlightCardMapping.card(from: item))
        card.receivedAt = Date(timeIntervalSince1970: card.receivedAt.timeIntervalSince1970.rounded())
        XCTAssertEqual(back.flight, "AB123")
        XCTAssertEqual(back.pnr, "ABC123")
        XCTAssertEqual(back.origin, "ICN")
        XCTAssertEqual(back.destination, "BKK")
        XCTAssertEqual(back.date, "2027-03-07")
        XCTAssertEqual(back.time, FlightAlertTime(hour: 9, minute: 5))
        XCTAssertEqual(back.terminal, "2")
        XCTAssertEqual(back.checkIn, card.checkIn)
        XCTAssertEqual(back.onsiteArriveMinutesBefore, 150)
        XCTAssertEqual(back.notes, ["21시 이후 혼잡"])
        XCTAssertEqual(back.sources["time"], .message)
        XCTAssertEqual(back.sources["flight"], .publicData)
        XCTAssertEqual(back.currentDelayMinutes, 65)
        XCTAssertEqual(back.changes.first?.reason, "기체 점검")
        XCTAssertEqual(back.airlineName, "가상항공")
        XCTAssertEqual(back.confidence, 0.8)
    }

    func testScheduleUsesBothTimeZonesAndPlaceholderWhenTimeIsUnknown() throws {
        let known = FlightCard(id: "x", origin: "ICN", destination: "BKK", date: "2027-03-07", time: FlightAlertTime(hour: 9, minute: 5))
        let schedule = try XCTUnwrap(FlightCardMapping.schedule(for: known))
        XCTAssertEqual(schedule.start.timeIntervalSince1970, 1_804_377_900)
        XCTAssertEqual(schedule.startOffsetSeconds, 9 * 3_600)
        XCTAssertEqual(schedule.endOffsetSeconds, 7 * 3_600)
        XCTAssertGreaterThan(schedule.end, schedule.start)
        let unknown = FlightCard(id: "y", origin: "ICN", destination: "BKK", date: "2027-03-07")
        let placeholder = try XCTUnwrap(FlightCardMapping.schedule(for: unknown))
        let local = Int(placeholder.start.timeIntervalSince1970) + placeholder.startOffsetSeconds
        XCTAssertEqual((local % 86_400) / 60, FlightCardMapping.placeholderMinute, "시각을 모르면 현지 낮 12시")
        XCTAssertNil(FlightCardMapping.schedule(for: FlightCard(id: "z", origin: "ZZZ", destination: "BKK", date: "2027-03-07")))
        XCTAssertNil(FlightCardMapping.schedule(for: FlightCard(id: "w", origin: "ICN", destination: "BKK")))
    }

    func testUnknownTimeSurvivesAsNilTimeOnTheCard() throws {
        let card = FlightCard(id: "t1|i1", flight: "AB123", origin: "ICN", destination: "BKK", date: "2027-03-07")
        let schedule = try XCTUnwrap(FlightCardMapping.schedule(for: card))
        var item = TravelTripItem(tripID: "t1", itemID: "i1", kind: "flight", title: "x", start: schedule.start, end: schedule.end,
                                  startOffsetSeconds: schedule.startOffsetSeconds, endOffsetSeconds: schedule.endOffsetSeconds, planID: nil)
        FlightCardMapping.apply(card, to: &item)
        XCTAssertNil(FlightCardMapping.card(from: item)?.time)
        XCTAssertEqual(FlightCardMapping.split(cardID: "t1|i1")?.itemID, "i1")
        XCTAssertNil(FlightCardMapping.split(cardID: "broken"))
        XCTAssertNil(FlightCardMapping.card(from: TravelTripItem(tripID: "t", itemID: "i", kind: "sight", title: "s", start: .now, end: .now, startOffsetSeconds: 0, endOffsetSeconds: 0, planID: nil)))
    }

    func testTripSelectionToleratesOneDayAndPicksTheEarliestTrip() {
        let a = TravelTrip(id: "a", title: "A", startDay: "2027-03-07", endDay: "2027-03-11")
        let b = TravelTrip(id: "b", title: "B", startDay: "2027-03-01", endDay: "2027-03-08")
        XCTAssertEqual(FlightIngest.trip(on: "2027-03-07", in: [a])?.id, "a")
        XCTAssertEqual(FlightIngest.trip(on: "2027-03-06", in: [a])?.id, "a", "밤 비행으로 하루 앞도 본다")
        XCTAssertNil(FlightIngest.trip(on: "2027-03-05", in: [a]))
        XCTAssertEqual(FlightIngest.trip(on: "2027-03-07", in: [a, b])?.id, "b", "여럿이면 먼저 시작하는 여행")
        XCTAssertNil(FlightIngest.trip(on: nil, in: [a]))
        XCTAssertNil(FlightIngest.trip(on: "bad", in: [a]))
        XCTAssertNil(FlightIngest.trip(on: "2027-03-07", in: [TravelTrip(id: "w", title: "언젠가", startDay: "", endDay: "", wishDays: 3)]))
    }

    // MARK: 끝에서 끝까지

    @MainActor
    func testBookingNoticeCreatesOneFlightItemWithLocalOnlyBookingNumber() async throws {
        let model = try await tripModel()
        let reply = await model.ingestFlightAlert(booking, source: .paste, now: date(3, 1), calendar: calendar)
        XCTAssertEqual(reply, .attached(created: 1, merged: 0))
        let item = try XCTUnwrap(flightItems(model).first)
        XCTAssertEqual(flightItems(model).count, 1)
        XCTAssertEqual(item.kind, "flight")
        XCTAssertEqual(item.originCode, "ICN")
        XCTAssertEqual(item.destinationCode, "BKK")
        XCTAssertEqual(item.pnrLocal, "ABC123")
        XCTAssertEqual(item.tripID, "t1")
        XCTAssertEqual(item.start.timeIntervalSince1970, 1_804_377_900)
        XCTAssertEqual(item.startOffsetSeconds, 9 * 3_600)
        XCTAssertFalse((item.title + (item.note ?? "")).contains("HONG"), "이름은 일정 글에 없다")
        XCTAssertFalse((item.flightLog ?? "").contains("ABC123"))
    }

    @MainActor
    func testItineraryMergesIntoTheBookingCardAndAddsTheReturnWithoutDuplicates() async throws {
        let model = try await tripModel()
        _ = await model.ingestFlightAlert(booking, source: .paste, now: date(3, 1), calendar: calendar)
        let second = await model.ingestFlightAlert(itinerary, source: .paste, now: date(3, 1, hour: 4), calendar: calendar)
        XCTAssertEqual(second, .attached(created: 1, merged: 1))
        var items = flightItems(model)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.map(\.flightNumber), ["AB123", "AB124"])
        XCTAssertEqual(items[0].pnrLocal, "ABC123")
        // 같은 여정 글이 또 와도 카드는 둘뿐.
        let again = await model.ingestFlightAlert(itinerary, source: .paste, now: date(3, 1, hour: 5), calendar: calendar)
        items = flightItems(model)
        XCTAssertEqual(items.count, 2)
        XCTAssertNotEqual(again, .unreadable)
    }

    @MainActor
    func testDelayMovesTheDepartureKeepsLengthAndRecordsHistory() async throws {
        let model = try await tripModel()
        _ = await model.ingestFlightAlert(booking, source: .paste, now: date(3, 1), calendar: calendar)
        _ = await model.ingestFlightAlert(itinerary, source: .paste, now: date(3, 1, hour: 4), calendar: calendar)
        let before = try XCTUnwrap(flightItems(model).first)
        let length = before.end.timeIntervalSince(before.start)
        let reply = await model.ingestFlightAlert("[가상항공] 예약번호 ABC123 편명 AB123 기존 09:05 → 변경 10:10 지연사유 기체 점검 +65분", source: .message, now: date(3, 7, hour: 1), calendar: calendar)
        XCTAssertEqual(reply, .attached(created: 0, merged: 1))
        let after = try XCTUnwrap(flightItems(model).first)
        XCTAssertEqual(after.start.timeIntervalSince(before.start), 65 * 60, accuracy: 1)
        XCTAssertEqual(after.end.timeIntervalSince(after.start), length, accuracy: 1)
        let card = try XCTUnwrap(FlightCardMapping.card(from: after))
        XCTAssertEqual(card.currentDelayMinutes, 65)
        XCTAssertEqual(card.time, FlightAlertTime(hour: 10, minute: 10))
        XCTAssertEqual(flightItems(model).count, 2, "지연 글은 카드를 늘리지 않는다")
    }

    @MainActor
    func testGuidanceNoticesNeverCreateCardsAndAreDeferred() async throws {
        let model = try await tripModel()
        let checkIn = await model.ingestFlightAlert("[가상항공] 온라인 체크인 안내 예약번호 ABC123 DAD - ICN 출발일 03/11 체크인 가능 마감은 출발 90분 전입니다", source: .message, now: date(3, 10), calendar: calendar)
        XCTAssertEqual(checkIn, .deferred)
        let onsite = await model.ingestFlightAlert("다낭-인천 출발 2시간 30분 전 도착 권장 · 21시 이후 혼잡 · 수속 마감 1시간 전", source: .message, now: date(3, 10), calendar: calendar)
        XCTAssertEqual(onsite, .deferred)
        XCTAssertTrue(flightItems(model).isEmpty)
        XCTAssertEqual(FlightInbox.pending().count, 0, "안내형은 보관함에 두지 않는다")
    }

    @MainActor
    func testNoTripKeepsTheTextOnDeviceAndRetriesWhenATripAppears() async throws {
        let model = AppModel(repository: InMemoryPlanRepository(), cloudSyncService: nil)
        await model.bootstrapLocalSnapshot()
        let reply = await model.ingestFlightAlert(booking, source: .paste, now: date(3, 1), calendar: calendar)
        XCTAssertEqual(reply, .noTrip)
        XCTAssertEqual(FlightInbox.pending().count, 1)
        XCTAssertTrue(flightItems(model).isEmpty)
        let saved = await model.saveTravelTrip(TravelTrip(id: "t1", title: "방콕", startDay: "2027-03-07", endDay: "2027-03-11"))
        XCTAssertTrue(saved)
        await FlightInbox.drain(into: model, now: date(3, 2))
        XCTAssertEqual(flightItems(model).count, 1)
        XCTAssertEqual(FlightInbox.pending().count, 0)
    }

    @MainActor
    func testAmbiguousDelayAsksAndChangesNothingUntilTheUserChooses() async throws {
        let model = try await tripModel()
        _ = await model.ingestFlightAlert("[가상항공] HONG/GILDONG 예약번호 ABC123 03/07 AB123 ICN -> BKK, 03/11 AB124 BKK -> ICN", source: .paste, now: date(3, 1), calendar: calendar)
        let before = flightItems(model)
        XCTAssertEqual(before.count, 2)
        // 날짜·편명 없는 지연 글: 예약번호만으로는 두 카드가 모두 후보.
        let reply = await model.ingestFlightAlert("[가상항공] 예약번호 ABC123 기존 14:20 변경 15:25 +65분", source: .message, now: date(3, 5), calendar: calendar)
        guard case .needsConfirmation(let request) = reply else { return XCTFail("후보가 둘이면 묻는다: \(reply)") }
        XCTAssertEqual(request.candidates.count, 2)
        XCTAssertFalse(request.allowsNew)
        XCTAssertEqual(flightItems(model).map(\.start), before.map(\.start), "묻기 전에는 아무것도 바꾸지 않는다")
        let choice = try XCTUnwrap(request.candidates.first?.cardID)
        let resolved = await model.resolveFlightConfirmation(request, attachTo: choice)
        XCTAssertEqual(resolved, .attached(created: 0, merged: 1))
    }

    @MainActor
    func testUnreadableTextAndTravelExtraAreReportedWithoutTouchingTrips() async throws {
        let model = try await tripModel()
        let unread = await model.ingestFlightAlert("안녕하세요 점심 뭐 드실래요", source: .paste, now: date(3, 1), calendar: calendar)
        XCTAssertEqual(unread, .unreadable)
        let extra = await model.ingestFlightAlert("[가상유심] eSIM 구매 완료\n상품명: 베트남 · 4일\nhttps://example.com/voucher", source: .paste, now: date(3, 1), calendar: calendar)
        XCTAssertEqual(extra, .prepAdded(created: 1, updated: 0))
        XCTAssertTrue(flightItems(model).isEmpty)
    }

    // MARK: 보관함·문구

    func testInboxDedupesCapsAndExpires() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "FlightInboxTests"))
        suite.removePersistentDomain(forName: "FlightInboxTests")
        defer { suite.removePersistentDomain(forName: "FlightInboxTests") }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<30 { FlightInbox.stash("text \(index)", now: now.addingTimeInterval(Double(index)), defaults: suite) }
        XCTAssertEqual(FlightInbox.pending(suite).count, FlightInbox.maximum)
        FlightInbox.stash("text 29", now: now.addingTimeInterval(40), defaults: suite)
        XCTAssertEqual(FlightInbox.pending(suite).filter { $0.text == "text 29" }.count, 1, "같은 글은 한 번만")
        // 30일이 지난 글은 새로 넣을 때 밀려난다.
        FlightInbox.stash("late", now: now.addingTimeInterval(FlightInbox.lifetime + 1_000), defaults: suite)
        XCTAssertEqual(FlightInbox.pending(suite).map(\.text), ["late"])
    }

    func testRepliesHaveKoreanAndEnglishWordingAndNeverEchoThePersonalText() {
        let replies: [FlightIngest.Reply] = [.attached(created: 1, merged: 0), .attached(created: 0, merged: 1), .attached(created: 1, merged: 1), .unreadable, .noTrip, .deferred, .lookupFailed, .prepAdded(created: 1, updated: 0), .planAdded, .sentToAI, .savedAsMemo,
                                            .needsConfirmation(.init(text: "HONG/GILDONG ABC123", candidates: [], allowsNew: true))]
        for reply in replies {
            let ko = FlightIngest.message(for: reply, language: .korean), en = FlightIngest.message(for: reply, language: .english)
            XCTAssertFalse(ko.isEmpty || en.isEmpty)
            XCTAssertNotEqual(ko, en)
            XCTAssertFalse(ko.contains("HONG") || ko.contains("ABC123") || en.contains("HONG") || en.contains("ABC123"))
        }
    }
}
