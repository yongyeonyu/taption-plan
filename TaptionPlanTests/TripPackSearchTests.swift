import CoreLocation
import Synchronization
import XCTest
@testable import TaptionPlan

/// SRCH1121A01: 도시 팩 Algolia 검색의 앱 쪽 규칙. 서버·Algolia는 가짜 전송으로 바꾼다. 도시·키·장소는 전부 시험용 가짜다.
final class TripPackSearchTests: XCTestCase {
    private final class FakeTransport: TripPackSearchTransport, Sendable {
        private struct State { var issued = 0; var queries: [(String, String?)] = [] }
        private let state = Mutex(State())
        let key: TripPackSearchKey?
        let ids: [String]?
        init(ids: [String]? = [], key: TripPackSearchKey? = TripPackSearchKey(appId: "TESTAPP123", index: "trip_packs_v1", key: "secured", validUntil: Date().timeIntervalSince1970 + 3_600)) {
            self.ids = ids; self.key = key
        }
        var issued: Int { state.withLock { $0.issued } }
        var queries: [(String, String?)] { state.withLock { $0.queries } }
        func issueKey(city: String, version: Int) async -> TripPackSearchKey? { state.withLock { $0.issued += 1 }; return key }
        func query(key: TripPackSearchKey, text: String, category: String?) async -> [String]? { state.withLock { $0.queries.append((text, category)) }; return ids }
    }

    private func item(_ id: String, _ category: String = "restaurant", name: String, tags: [String] = [], checkedAt: String = "2026-11-01", lat: Double = 10, lng: Double = 20) -> TripPackItem {
        TripPackItem(id: id, category: category, name: name, nameKo: name, area: "예시구", address: "주소", lat: lat, lng: lng, phone: nil, hours: nil, priceHint: nil,
                     tags: tags, note: "시험용", source: "seed", sourceURL: nil, checkedAt: checkedAt, checkedBy: "대표", photo: nil)
    }

    private func pack(_ items: [TripPackItem]) -> TripPack {
        TripPack(format: "bokki-trip-pack", schema: 1, city: "fixture-city", version: 2, items: items)
    }

    private func search(_ transport: FakeTransport, now: @escaping @Sendable () -> Date = { .now }) -> TripPackSearch {
        let defaults = UserDefaults(suiteName: "TripPackSearchTests-\(UUID().uuidString)")!
        return TripPackSearch(transport: transport, defaults: defaults, now: now)
    }

    func testAlgoliaOrderIsKeptAndResolvedAgainstTheLocalPack() async {
        let transport = FakeTransport(ids: ["fixture-city:2:b", "fixture-city:2:a", "fixture-city:2:missing", "fixture-city:1:a"])
        let outcome = await search(transport).search("라멘", in: pack([item("a", name: "가게A"), item("b", name: "가게B")]))
        XCTAssertEqual(outcome.source, .algolia)
        XCTAssertEqual(outcome.items.map(\.id), ["b", "a"], "Algolia 순서를 지키고 팩에 없거나 다른 버전인 것은 뺀다")
        XCTAssertEqual(outcome.items.first?.address, "주소", "주소는 색인이 아니라 기기 팩에서 읽는다")
    }

    func testShortOrEmptyQueriesStayOnDeviceAndSpendNothing() async {
        let transport = FakeTransport()
        let engine = search(transport)
        let all = pack([item("a", name: "가게A"), item("b", name: "가게B")])
        let empty = await engine.search("  ", in: all)
        let one = await engine.search("가", in: all)
        XCTAssertEqual(empty.source, .local)
        XCTAssertEqual(empty.items.count, 2)
        XCTAssertEqual(one.source, .local)
        XCTAssertEqual(transport.issued, 0)
        XCTAssertTrue(transport.queries.isEmpty)
    }

    func testFallsBackToLocalSearchWhenOfflineKeyMissingOrNoHits() async {
        let local = pack([item("a", name: "라멘집"), item("b", name: "공원")])
        let offline = FakeTransport(ids: nil)
        let a = await search(offline).search("라멘", in: local)
        XCTAssertEqual(a.source, .local); XCTAssertEqual(a.items.map(\.id), ["a"])
        let noKey = FakeTransport(ids: [], key: nil)
        let b = await search(noKey).search("라멘", in: local)
        XCTAssertEqual(b.source, .local); XCTAssertEqual(b.items.map(\.id), ["a"])
        XCTAssertTrue(noKey.queries.isEmpty, "키가 없으면 Algolia를 부르지 않는다")
        let empty = FakeTransport(ids: [])
        let c = await search(empty).search("라멘", in: local)
        XCTAssertEqual(c.source, .local, "Algolia가 비어 있으면 기기 검색으로 확인한다")
    }

    func testCachesTheSameSearchAndReusesTheKey() async {
        let transport = FakeTransport(ids: ["fixture-city:2:a"])
        let engine = search(transport)
        let local = pack([item("a", name: "라멘집")])
        _ = await engine.search("라멘", in: local)
        _ = await engine.search("라멘", in: local)
        _ = await engine.search("우동", in: local)
        XCTAssertEqual(transport.queries.count, 2, "같은 검색은 캐시를 쓴다")
        XCTAssertEqual(transport.issued, 1, "유효한 키는 다시 받지 않는다")
    }

    func testDailyBudgetStopsRemoteCallsAndResetsNextDay() async {
        let transport = FakeTransport(ids: ["fixture-city:2:a"])
        let clock = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
        let engine = search(transport, now: { clock.withLock { $0 } })
        let local = pack([item("a", name: "라멘집")])
        for index in 0..<TripPackSearchBudget.dailyLimit { _ = await engine.search("라멘\(index)", in: local) }
        XCTAssertEqual(transport.queries.count, TripPackSearchBudget.dailyLimit)
        let over = await engine.search("라멘over", in: local)
        XCTAssertEqual(transport.queries.count, TripPackSearchBudget.dailyLimit, "몫이 끝나면 부르지 않는다")
        XCTAssertEqual(over.source, .local)
        clock.withLock { $0 = $0.addingTimeInterval(86_400) }
        _ = await engine.search("라멘next", in: local)
        XCTAssertEqual(transport.queries.count, TripPackSearchBudget.dailyLimit + 1, "다음 날에는 다시 쓴다")
    }

    func testCategoryGoesToTheServerAndFiltersTheResult() async {
        let transport = FakeTransport(ids: ["fixture-city:2:a", "fixture-city:2:b"])
        let outcome = await search(transport).search("라멘", in: pack([item("a", "restaurant", name: "라멘집"), item("b", "cafe", name: "카페")]), category: .restaurant)
        XCTAssertEqual(transport.queries.first?.1, "restaurant")
        XCTAssertEqual(outcome.items.map(\.id), ["a"])
    }

    func testPrescriptionRoutesAreHiddenAndStaleSafetyInfoIsFlagged() {
        let rx = item("p", "pharmacy", name: "처방약 구매", tags: ["처방"])
        let ok = item("q", "pharmacy", name: "약국", checkedAt: "2026-11-01")
        XCTAssertEqual(TripPackSearch.visible([rx, ok]).map(\.id), ["q"])
        let now = Date(timeIntervalSince1970: 1_798_000_000) // 2026-12 말
        let old = item("o", "pharmacy", name: "옛 약국", checkedAt: "2026-01-01")
        XCTAssertTrue(TripPackSearch.needsCheck(old, now: now))
        XCTAssertFalse(TripPackSearch.needsCheck(item("r", "restaurant", name: "식당", checkedAt: "2026-01-01"), now: now), "병원·약국만 확인 필요 표시")
    }

    func testRequestBodyCarriesOnlyTheQueryAndCategory() throws {
        let body = try XCTUnwrap(TripPackSearchLive.body(text: "라멘", category: "restaurant"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["query", "hitsPerPage", "attributesToRetrieve", "facetFilters"])
        let raw = String(decoding: body, as: UTF8.self).lowercased()
        XCTAssertFalse(raw.contains("around") || raw.contains("latlng") || raw.contains("usertoken"), "좌표·위치·사용자 식별자는 보내지 않는다")
        XCTAssertTrue(TripPackSearchLive.validAppID("TESTAPP123"))
        XCTAssertFalse(TripPackSearchLive.validAppID("evil.com/x"))
        XCTAssertEqual(TripPackSearchLive.decodeIDs(Data(#"{"hits":[{"objectID":"c:1:a"}]}"#.utf8)), ["c:1:a"])
        XCTAssertNil(TripPackSearchLive.decodeIDs(Data("{}".utf8)))
    }

    func testDistanceSortRunsOnDeviceAndKeepsOrderWithoutALocation() {
        let near = item("n", name: "가까움", lat: 10.001, lng: 20.001), far = item("f", name: "멂", lat: 11, lng: 21)
        XCTAssertEqual(TripPackSearch.sortedByDistance([far, near], from: CLLocationCoordinate2D(latitude: 10, longitude: 20)).map(\.id), ["n", "f"])
        XCTAssertEqual(TripPackSearch.sortedByDistance([far, near], from: nil).map(\.id), ["f", "n"])
    }
}
