import XCTest
@testable import TaptionPlan
import TaptionPlanStore

/// FLT1119A01: 출발 가까운 비행의 화랑이 말풍선과 지구본 환승 점 판정.
final class FlightBubbleTests: XCTestCase {
    /// 2027-03-07 09:05 KST.
    private let departure = Date(timeIntervalSince1970: 1_804_377_900)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 32_400) ?? .gmt
        return calendar
    }

    private func flight(_ id: String = "i1", start: Date? = nil, origin: String = "ICN", destination: String = "BKK", log: String? = nil, number: String = "AB123") -> TravelTripItem {
        let start = start ?? departure
        var item = TravelTripItem(tripID: "t1", itemID: id, kind: "flight", title: "\(number) \(origin) → \(destination)", start: start, end: start.addingTimeInterval(19_800),
                                  startOffsetSeconds: 32_400, endOffsetSeconds: 25_200, planID: nil)
        item.flightNumber = number; item.originCode = origin; item.destinationCode = destination; item.flightLog = log
        return item
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("flight-bubbles-\(UUID().uuidString).json")
    }

    func testBubbleWindowStartsFourHoursBeforeAndEndsAtDeparture() throws {
        let now = departure.addingTimeInterval(-10 * 3_600)
        let bubble = try XCTUnwrap(FlightBubble.bubbles(items: [flight()], now: now, calendar: calendar, language: .korean).first)
        XCTAssertEqual(bubble.kind, .event)
        XCTAssertEqual(bubble.end, departure)
        // 09:05 − 4시간 = 05:05, 같은 날 0시 이후라 그대로.
        XCTAssertEqual(bubble.start, departure.addingTimeInterval(-4 * 3_600))
        XCTAssertEqual(bubble.text, "곧 출발! 공항에 06:05까지 가요 ✈")
        XCTAssertNotNil(bubble.parsed, "말풍선 문법(80자 안)을 지킨다")
        XCTAssertEqual(bubble.id, FlightBubble.id(tripID: "t1", itemID: "i1"), "같은 일정은 같은 id")
        XCTAssertNotEqual(bubble.id, FlightBubble.id(tripID: "t1", itemID: "i2"))
    }

    func testWindowDoesNotCrossBackIntoThePreviousDay() throws {
        // 새벽 01:00 출발이면 창은 그날 0시부터.
        let early = departure.addingTimeInterval(-8 * 3_600) // 01:05
        let bubble = try XCTUnwrap(FlightBubble.bubbles(items: [flight(start: early)], now: early.addingTimeInterval(-20 * 3_600), calendar: calendar, language: .korean).first)
        XCTAssertEqual(bubble.start, calendar.startOfDay(for: early))
        XCTAssertTrue(calendar.isDate(bubble.start, inSameDayAs: bubble.end))
    }

    func testDelayChangesTheWordingAndPastOrFarFlightsGetNoBubble() throws {
        let log = #"{"changes":[{"after":"2027-03-07T10:10","before":"2027-03-07T09:05","delay":65,"at":1}]}"#
        let delayed = flight(start: departure.addingTimeInterval(65 * 60), log: log)
        let bubble = try XCTUnwrap(FlightBubble.bubbles(items: [delayed], now: departure.addingTimeInterval(-3_600), calendar: calendar, language: .korean).first)
        XCTAssertEqual(bubble.text, "AB123 65분 지연, 새 출발 10:10")
        XCTAssertTrue(FlightBubble.bubbles(items: [flight()], now: departure.addingTimeInterval(60), calendar: calendar, language: .korean).isEmpty, "이미 떠났다")
        XCTAssertTrue(FlightBubble.bubbles(items: [flight()], now: departure.addingTimeInterval(-49 * 3_600), calendar: calendar, language: .korean).isEmpty, "48시간보다 멀다")
        XCTAssertEqual(FlightBubble.bubbles(items: [flight()], now: departure.addingTimeInterval(-10 * 3_600), calendar: calendar, language: .english).first?.text, "Departing soon! Be at the airport by 06:05 ✈")
    }

    @MainActor
    func testSyncWritesOnceReplacesInPlaceAndKeepsHiddenAndOtherBubbles() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let other = AssistantBubble(start: departure.addingTimeInterval(-86_400), end: departure.addingTimeInterval(-80_000), text: "다른 말풍선")
        AssistantBubbleStore.save([other], to: file)
        let now = departure.addingTimeInterval(-10 * 3_600)
        FlightBubble.sync(items: [flight()], now: now, calendar: calendar, language: .korean, file: file)
        var list = AssistantBubbleStore.load(from: file)
        XCTAssertEqual(list.count, 2)
        XCTAssertTrue(list.contains { $0.id == other.id })
        // 같은 입력으로 다시 맞추면 변하지 않는다.
        let before = try Data(contentsOf: file)
        FlightBubble.sync(items: [flight()], now: now, calendar: calendar, language: .korean, file: file)
        XCTAssertEqual(try Data(contentsOf: file), before)
        // 지연이 오면 같은 id의 말풍선 글이 바뀌고 개수는 그대로.
        let log = #"{"changes":[{"delay":65,"at":1}]}"#
        FlightBubble.sync(items: [flight(start: departure.addingTimeInterval(65 * 60), log: log)], now: now, calendar: calendar, language: .korean, file: file)
        list = AssistantBubbleStore.load(from: file)
        XCTAssertEqual(list.count, 2)
        XCTAssertTrue(list.contains { $0.text.contains("지연") })
        // 사용자가 숨긴 말풍선은 다시 켜지 않는다.
        let mine = FlightBubble.id(tripID: "t1", itemID: "i1")
        AssistantBubbleStore.hide(mine, file: file)
        FlightBubble.sync(items: [flight()], now: now, calendar: calendar, language: .korean, file: file)
        XCTAssertEqual(AssistantBubbleStore.load(from: file).first { $0.id == mine }?.hidden, true)
        // 비행이 없으면(지난 뒤) 비행 말풍선은 사라지고 다른 것은 남는다.
        FlightBubble.sync(items: [], now: now, calendar: calendar, language: .korean, file: file)
        XCTAssertEqual(AssistantBubbleStore.load(from: file).count, 2, "일정 목록에서 빠진 비행의 말풍선은 건드리지 않고 하루 지나 지운다")
    }

    // MARK: 환승 점

    func testLayoverAirportsAreMarkedForTheNextFlightFromTheSameAirport() {
        let first = flight("a", start: departure, origin: "ICN", destination: "BKK", number: "AB123")
        let second = flight("b", start: departure.addingTimeInterval(12 * 3_600), origin: "BKK", destination: "DAD", number: "CD456")
        let third = flight("c", start: departure.addingTimeInterval(4 * 86_400), origin: "DAD", destination: "ICN", number: "EF789")
        let marks = FlightLayoverMarks.layoverItemIDs(in: [first, second, third])
        XCTAssertEqual(marks, ["a"], "방콕에서 12시간 뒤 이어 타는 첫 구간의 도착만 환승 점")
        XCTAssertTrue(FlightLayoverMarks.layoverItemIDs(in: [first]).isEmpty)
        XCTAssertTrue(FlightLayoverMarks.layoverItemIDs(in: [first, third]).isEmpty, "공항이 다르면 환승이 아니다")
        let farLater = flight("d", start: departure.addingTimeInterval(3 * 86_400), origin: "BKK", destination: "SIN")
        XCTAssertTrue(FlightLayoverMarks.layoverItemIDs(in: [first, farLater]).isEmpty, "36시간이 넘으면 체류지다")
        var plain = first
        plain.clearFlight()
        XCTAssertTrue(FlightLayoverMarks.layoverItemIDs(in: [plain, second]).isEmpty)
    }
}
