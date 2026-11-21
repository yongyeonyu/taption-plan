import XCTest
@testable import TaptionPlan

/// 가계부 컬러 아이콘 분류(대표 지시 2026-11-21). 가맹점 이름은 모두 지어낸 것이다.
final class LedgerMerchantIconTests: XCTestCase {
    private func kind(_ title: String, place: String? = nil, category: LedgerCategory = .other, transfer: Bool = false) -> LedgerMerchantKind? {
        LedgerMerchantKind.classify(title: title, place: place, category: category, isTransfer: transfer)
    }

    func testMedicalAndPharmacyAreSeparated() {
        XCTAssertEqual(kind("하늘정형외과의원"), .hospital)
        XCTAssertEqual(kind("바른치과"), .hospital)
        XCTAssertEqual(kind("햇살약국"), .pharmacy)
        XCTAssertEqual(kind("병원 앞 햇살약국"), .pharmacy, "약국이 병원보다 먼저")
    }

    func testTransportKindsAreSeparated() {
        XCTAssertEqual(kind("시내버스 운임"), .bus)
        XCTAssertEqual(kind("서울교통공사 지하철"), .subway)
        XCTAssertEqual(kind("카카오T 택시"), .car)
        XCTAssertEqual(kind("현대오일뱅크 가정셀프주유소 주유"), .fuel, "오일뱅크는 은행이 아니라 주유")
        XCTAssertEqual(kind("한강공영주차장"), .parking)
        XCTAssertEqual(kind("한일카페리 승선권"), .ship, "카페리는 커피숍이 아니라 배")
        XCTAssertEqual(kind("제주항공 항공권"), .airplane)
    }

    func testMealAndCoffeeAreSeparated() {
        XCTAssertEqual(kind("메가MGC커피 인천루원중암점"), .coffee)
        XCTAssertEqual(kind("스타벅스 부평역점"), .coffee)
        XCTAssertEqual(kind("해운대 돼지국밥"), .meal, "해운대는 배가 아니다")
        XCTAssertEqual(kind("페리카나 치킨"), .meal, "페리카나는 배가 아니다")
        XCTAssertEqual(kind("모모 가게", category: .cafe), .coffee, "분류가 카페면 따른다")
        XCTAssertEqual(kind("모모 가게", category: .food), .meal)
    }

    func testBankIsKeptAndUnknownStaysUnknown() {
        XCTAssertEqual(kind("카카오뱅크"), .bank)
        XCTAssertNil(kind("부천아이폰수리 수리마블"), "구분할 수 없으면 nil이라 통화 기호가 보인다")
        XCTAssertNil(kind("다이소 부천점", category: .shopping))
        XCTAssertNil(kind("모모 가게", category: .health), "건강 분류만으로는 병원·약국을 가르지 않는다")
    }

    func testTransfersDoNotBecomeFuel() {
        XCTAssertNil(kind("주유 적립금 이체", transfer: true))
    }

    func testEveryKindHasAColorAndSymbol() {
        let hexes = LedgerMerchantKind.allCases.map(\.tintHex)
        XCTAssertEqual(Set(hexes).count, hexes.count, "색이 겹치지 않는다")
        XCTAssertTrue(LedgerMerchantKind.allCases.allSatisfy { !$0.symbol.isEmpty })
    }

    func testCurrencySymbols() {
        XCTAssertEqual(LedgerCurrencySymbol.symbol(for: "KRW"), "₩")
        XCTAssertEqual(LedgerCurrencySymbol.symbol(for: "JPY"), "¥")
        XCTAssertEqual(LedgerCurrencySymbol.symbol(for: "USD"), "$")
        XCTAssertEqual(LedgerCurrencySymbol.symbol(for: "XYZ"), "XYZ", "모르는 통화는 코드를 그대로")
    }
}

/// 구분 못 한 가맹점 이름 모으기(MER1121A01): 무엇을 모으고 무엇을 거르는가.
@MainActor
final class LedgerMerchantCollectorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ title: String, source: LedgerEntry.Source = .message, kind: LedgerEntry.Kind = .expense, daysAgo: Double = 1,
                       category: LedgerCategory = .other, canceled: Bool = false) -> LedgerEntry {
        var value = LedgerEntry(occurredAt: now.addingTimeInterval(-daysAgo * 86_400), amount: 5_000, title: title)
        value.source = source
        value.kind = kind
        value.category = category
        if canceled { value.canceledAt = now }
        return value
    }

    func testOnlyUnclassifiedPaymentTextExpensesAreCollectedByNameAndCount() {
        let entries = [
            entry("수리마블"), entry("수리마블"), entry("다이소 부천점", category: .shopping),
            entry("스타벅스 부평점"),                 // 종류를 아는 것은 보내지 않는다
            entry("경인고속도로 통행료"),              // 통행료
            entry("수리마블", source: .manual),        // 직접 쓴 것
            entry("수리마블", source: .assistant),     // AI가 쓴 것
            entry("월급", kind: .income),               // 수입
            entry("취소된 가게", canceled: true),       // 취소
            entry("옛 가게", daysAgo: 90),             // 기간 밖
        ]
        let pending = LedgerMerchantCollector.pending(entries: entries, reported: [], now: now)
        XCTAssertEqual(pending.items, [.init(name: "수리마블", count: 2), .init(name: "다이소 부천점", count: 1)])
        XCTAssertEqual(pending.entryIDs.count, 3)
    }

    func testReportedEntriesAreNotCountedAgain() {
        let first = entry("수리마블"), second = entry("수리마블")
        let pending = LedgerMerchantCollector.pending(entries: [first, second], reported: [first.id], now: now)
        XCTAssertEqual(pending.items, [.init(name: "수리마블", count: 1)])
    }

    func testNamesThatCouldCarryPersonalDataAreFilteredOnTheDevice() {
        for bad in ["홍*동", "김철수 4567", "a@b.com", "https://x.example", "010-1234-5678", "x", String(repeating: "가", count: 41), "카드 1234567"] {
            XCTAssertNil(LedgerMerchantCollector.clean(bad), bad)
        }
        XCTAssertEqual(LedgerMerchantCollector.clean("  부천아이폰수리   수리마블 "), "부천아이폰수리 수리마블")
        XCTAssertEqual(LedgerMerchantCollector.clean("지에스25 부평점"), "지에스25 부평점", "숫자 두 자리는 괜찮다")
    }

    func testBodyCarriesOnlyNamesAndCounts() throws {
        let data = LedgerMerchantCollector.body([.init(name: "수리마블", count: 2)])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["format", "version", "items"])
        let item = try XCTUnwrap((object["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(item.keys), ["name", "count"], "금액·시각·분류·위치는 없다")
    }

    func testNothingIsSentWhileOffAndTheSwitchDefaultsToOff() async {
        let defaults = UserDefaults(suiteName: "LedgerMerchantCollectorTests-\(UUID().uuidString)")!
        XCTAssertFalse(LedgerMerchantCollector.isEnabled(defaults))
        let result = await LedgerMerchantCollector.sendIfDue(defaults: defaults, now: now, entries: [entry("수리마블")])
        XCTAssertEqual(result.failure, .disabled)
    }
}
