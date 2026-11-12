import Foundation
import Testing
@testable import TaptionPlanStore

/// 여행 단위(TVA1111A01): 저장 호환, 여행 목록, 일정 시각 고치기.
struct TravelTripsTests {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    /// 2026-11-19 00:00 UTC.
    static let base = Date(timeIntervalSince1970: 1_795_046_400)

    static func item(_ trip: String, _ id: String, hour: Double, hours: Double = 1, offset: Int = 32_400) -> TravelTripItem {
        TravelTripItem(
            tripID: trip, itemID: id, kind: "sight", title: id, start: base.addingTimeInterval(hour * 3_600),
            end: base.addingTimeInterval((hour + hours) * 3_600), startOffsetSeconds: offset, endOffsetSeconds: offset, planID: nil
        )
    }

    // MARK: 저장 호환

    @Test func tripWithOnlyRequiredKeysDecodesAndOptionalKeysAreNotWritten() throws {
        let json = #"{"endDay":"2026-11-22","id":"t1","startDay":"2026-11-19","title":"오사카"}"#
        let trip = try Self.decoder().decode(TravelTrip.self, from: Data(json.utf8))
        #expect(trip.currencyCode == nil)
        #expect(trip.countryCode == nil)
        #expect(String(decoding: try Self.encoder().encode(trip), as: UTF8.self) == json)
    }

    @Test func settingsWithoutTripsKeepTheirBytesAndTripsRoundTrip() throws {
        var settings = AppFeatureSettings.defaults
        let before = try Self.encoder().encode(settings)
        #expect(!String(decoding: before, as: UTF8.self).contains("travelTrips"), "여행이 없으면 키를 쓰지 않아 옛 저장 바이트가 그대로다")
        #expect(try Self.decoder().decode(AppFeatureSettings.self, from: before).travelTrips == nil)

        let trip = TravelTrip(
            id: "t1", title: "오사카", startDay: "2026-11-19", endDay: "2026-11-22", countryCode: "JP", regionName: "오사카",
            latitude: 34.69, longitude: 135.5, currencyCode: "JPY", timeZoneID: "Asia/Tokyo"
        )
        settings.travelTrips = [trip]
        let after = try Self.decoder().decode(AppFeatureSettings.self, from: try Self.encoder().encode(settings))
        #expect(after.travelTrips == [trip])
    }

    // MARK: 날짜 글

    @Test func dayStringsFollowTheLocalWallClock() {
        // 11월 19일 16:00 UTC는 일본(+9)에서 20일 01:00이다.
        #expect(TravelTripDay.string(for: Self.base.addingTimeInterval(16 * 3_600), offsetSeconds: 32_400) == "2026-11-20")
        #expect(TravelTripDay.string(for: Self.base.addingTimeInterval(16 * 3_600), offsetSeconds: -18_000) == "2026-11-19")
        #expect(TravelTripDay.days(from: "2026-11-19", to: "2026-11-22") == 3)
        #expect(TravelTripDay.days(from: "2026-12-30", to: "2027-01-02") == 3)
        #expect(TravelTripDay.days(from: "2026-11-19", to: "2026-11-19") == 0)
        #expect(TravelTripDay.components("2026-02-30") == nil)
        #expect(TravelTripDay.components("2026-2-3") == nil)
        #expect(TravelTripDay.days(from: "나쁜 값", to: "2026-11-19") == nil)
    }

    // MARK: 여행 목록

    @Test func directoryMergesStoredAndLegacyTripsAndSortsByState() {
        let stored = [
            TravelTrip(id: "osaka", title: "오사카", startDay: "2026-11-19", endDay: "2026-11-22", currencyCode: "JPY"),
            TravelTrip(id: "bangkok", title: "방콕", startDay: "2026-12-05", endDay: "2026-12-09", currencyCode: "THB"),
            TravelTrip(id: "gapyeong", title: "가평", startDay: "2026-11-08", endDay: "2026-11-08"),
            TravelTrip(id: "jeju", title: "제주", startDay: "2026-10-01", endDay: "2026-10-03"),
        ]
        // 옛 여행: 저장한 여행 없이 일정에만 번호가 있다. 이름은 가계부 여행 장부 것을 먼저 쓴다.
        let items = [Self.item("old", "a", hour: 24 * 20 + 1), Self.item("old", "b", hour: 24 * 21 + 3), Self.item("osaka", "x", hour: 1)]
        let entries = TravelTripDirectory.entries(stored: stored, stops: [], items: items, names: ["old": "부산 출장"], today: "2026-11-20")
        #expect(entries.map(\.id) == ["osaka", "bangkok", "old", "gapyeong", "jeju"])
        let osaka = entries[0]
        #expect(osaka.state == .active)
        #expect(osaka.dayCount == 4)
        #expect(osaka.nights == 3)
        #expect(osaka.dayNumber == 2)
        #expect(osaka.isStored)
        #expect(entries[1].daysUntilStart == 15)
        let old = entries[2]
        #expect(!old.isStored)
        #expect(old.trip.title == "부산 출장")
        #expect(old.trip.startDay == "2026-12-09")
        #expect(old.trip.endDay == "2026-12-10")
        #expect(old.state == .upcoming)
        let dayTrip = entries[3]
        #expect(dayTrip.isDayTrip)
        #expect(dayTrip.state == .past)
        #expect(dayTrip.dayNumber == nil)
    }

    @Test func legacyTripUsesFirstItemTitleStopDaysAndMidnightEnd() {
        // 자정(현지)에 끝나는 일정은 다음 날로 넘어가지 않는다. 22:00~24:00 현지 = 13:00~15:00 UTC.
        let night = Self.item("t", "night", hour: 13, hours: 2)
        let morning = Self.item("t", "morning", hour: 0)
        // 핀 날짜는 만든 기기의 자정(한국 11월 21일 0시 = 20일 15:00 UTC).
        let stop = TravelPlanStop(
            id: UUID(), title: "핀", latitude: 1, longitude: 1, day: Self.base.addingTimeInterval(39 * 3_600), order: 0, planID: nil, tripID: "t"
        )
        let unnumbered = TravelPlanStop(id: UUID(), title: "번호 없음", latitude: 1, longitude: 1, day: Self.base, order: 0, planID: nil)
        let entries = TravelTripDirectory.entries(stored: [], stops: [stop, unnumbered], items: [night, morning], today: "2026-11-19")
        #expect(entries.count == 1, "여행 번호가 없는 핀은 여행이 아니다")
        #expect(entries[0].trip.title == "morning")
        #expect(entries[0].trip.startDay == "2026-11-19")
        #expect(entries[0].trip.endDay == "2026-11-21")
        #expect(entries[0].dayNumber == 1)
    }

    @Test func importUpsertKeepsUserChosenCurrencyAndExtendOnlyGrows() {
        let trips = [TravelTrip(id: "t", title: "예전 이름", startDay: "2026-11-01", endDay: "2026-11-02", countryCode: "JP", currencyCode: "JPY")]
        let items = [Self.item("t", "a", hour: 1), Self.item("t", "b", hour: 49), Self.item("u", "c", hour: 1)]
        let updated = TravelTripDirectory.upserting(trips, id: "t", title: " 오사카 ", items: items)
        #expect(updated == [TravelTrip(id: "t", title: "오사카", startDay: "2026-11-19", endDay: "2026-11-21", countryCode: "JP", currencyCode: "JPY")])
        #expect(TravelTripDirectory.upserting(updated, id: "t", title: "", items: items)[0].title == "오사카", "빈 이름으로 덮지 않는다")
        let added = TravelTripDirectory.upserting(updated, id: "u", title: "교토", items: items)
        #expect(added.count == 2)
        #expect(added[1].startDay == "2026-11-19")
        #expect(TravelTripDirectory.upserting(updated, id: "없는 여행", title: "x", items: items).count == 1, "일정이 없는 새 여행은 만들지 않는다")

        let wide = [TravelTrip(id: "t", title: "오사카", startDay: "2026-11-10", endDay: "2026-11-20")]
        let grown = TravelTripDirectory.extended(wide, toCover: items)
        #expect(grown[0].startDay == "2026-11-10", "줄이지 않는다")
        #expect(grown[0].endDay == "2026-11-21")
    }

    // MARK: 일정 시각 고치기

    /// TVU1113A01: 일정 색·예상 지출은 없으면 키를 쓰지 않아 예전 바이트 그대로이고, 예전 빌드는 모르는 키를 건너뛴다.
    @Test func itemColorAndPlannedSpendKeepOldBytesAndOldReaders() throws {
        let plain = Self.item("t", "a", hour: 1)
        let old = try Self.encoder().encode(plain)
        let oldText = String(decoding: old, as: UTF8.self)
        #expect(!oldText.contains("colorHex") && !oldText.contains("plannedSpendKRW"))
        // 예전 바이트(두 키 없음)를 읽으면 둘 다 nil이고, 다시 쓰면 같은 바이트다.
        let reread = try Self.decoder().decode(TravelTripItem.self, from: old)
        #expect(reread == plain)
        #expect(try Self.encoder().encode(reread) == old)

        var colored = plain
        colored.colorHex = "#C8442E"
        colored.plannedSpendKRW = 12_000
        let new = try Self.encoder().encode(colored)
        #expect(try Self.decoder().decode(TravelTripItem.self, from: new) == colored)
        // 두 칸을 모르는 예전 빌드의 모양으로 읽어도 나머지는 그대로 읽힌다.
        struct OldItem: Decodable {
            var tripID: String, itemID: String, kind: String, title: String
            var start: Date, end: Date, startOffsetSeconds: Int, endOffsetSeconds: Int
            var planID: UUID?, status: String?, note: String?
        }
        let seen = try Self.decoder().decode(OldItem.self, from: new)
        #expect(seen.itemID == "a" && seen.start == plain.start && seen.end == plain.end && seen.startOffsetSeconds == 32_400)

        #expect(TravelTripItem.cleanColorHex(" #c8442e ") == "#C8442E")
        #expect(TravelTripItem.cleanColorHex("빨강") == nil)
        #expect(TravelTripItem.cleanColorHex("#12345") == nil)
        #expect(TravelTripItem.cleanColorHex(nil) == nil)
        #expect(TravelTripItem.cleanPlannedSpend(11_999.6) == 12_000)
        #expect(TravelTripItem.cleanPlannedSpend(0) == nil)
        #expect(TravelTripItem.cleanPlannedSpend(-5) == nil)
        #expect(TravelTripItem.cleanPlannedSpend(.infinity) == nil)
    }

    @Test func movingKeepsLengthAndOffsets() throws {
        let items = [Self.item("t", "a", hour: 1), Self.item("t", "b", hour: 3)]
        let moved = try #require(TravelTripItemEditor.moved(items, tripID: "t", itemID: "a", by: 1_800))
        #expect(moved[0].start == items[0].start.addingTimeInterval(1_800))
        #expect(moved[0].end.timeIntervalSince(moved[0].start) == 3_600)
        #expect(moved[0].startOffsetSeconds == 32_400)
        #expect(moved[1] == items[1])
        #expect(TravelTripItemEditor.moved(items, tripID: "t", itemID: "없음", by: 60) == nil)
        #expect(TravelTripItemEditor.moved(items, tripID: "t", itemID: "a", by: .nan) == nil)
    }

    @Test func resizingRespectsTheMinimumLength() throws {
        let items = [Self.item("t", "a", hour: 1)]
        let longer = try #require(TravelTripItemEditor.resized(items, tripID: "t", itemID: "a", endDelta: 1_800))
        #expect(longer[0].end.timeIntervalSince(longer[0].start) == 5_400)
        let later = try #require(TravelTripItemEditor.resized(items, tripID: "t", itemID: "a", startDelta: 900))
        #expect(later[0].start == items[0].start.addingTimeInterval(900))
        #expect(later[0].end == items[0].end)
        #expect(TravelTripItemEditor.resized(items, tripID: "t", itemID: "a", startDelta: 3_400) == nil, "5분보다 짧아질 수 없다")
        #expect(TravelTripItemEditor.resized(items, tripID: "t", itemID: "a", endDelta: -3_300) != nil, "꼭 5분은 된다")
    }

    /// TVW1112A01: 날짜 없는 여행(버킷리스트).
    @Test func wishTripsHaveNoDatesUntilScheduled() throws {
        let wish = TravelTrip(id: "w", title: "도쿄", startDay: "", endDay: "", countryCode: "JP", wishDays: 5)
        #expect(wish.isWish)
        let entry = TravelTripDirectory.entry(wish, isStored: true, today: "2026-11-12")
        #expect(entry.state == .someday)
        #expect(entry.dayCount == 5)
        #expect(entry.nights == 4)
        #expect(entry.daysUntilStart == nil)

        let soon = TravelTrip(id: "s", title: "후쿠오카", startDay: "2026-11-20", endDay: "2026-11-22")
        let old = TravelTrip(id: "o", title: "부산", startDay: "2026-10-01", endDay: "2026-10-02")
        let order = TravelTripDirectory.entries(stored: [old, wish, soon], stops: [], items: [], today: "2026-11-12").map(\.id)
        #expect(order == ["s", "w", "o"], "다가오는 여행 → 언젠가 → 지난 여행")

        let dated = TravelTripDirectory.scheduled(wish, startDay: "2027-03-30")
        #expect(dated.startDay == "2027-03-30")
        #expect(dated.endDay == "2027-04-03")
        #expect(dated.wishDays == nil)
        #expect(!dated.isWish)
        #expect(TravelTripDirectory.scheduled(soon, startDay: "2027-01-01") == soon, "날짜 있는 여행은 그대로")

        // 날짜가 없으면 키를 쓰지 않아 예전 여행의 바이트가 그대로다.
        #expect(!String(decoding: try Self.encoder().encode(soon), as: UTF8.self).contains("wishDays"))
        #expect(try JSONDecoder().decode(TravelTrip.self, from: Self.encoder().encode(wish)) == wish)
    }
}
