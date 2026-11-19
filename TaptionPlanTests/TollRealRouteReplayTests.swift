import XCTest
@testable import TaptionPlan

/// 실제 이동 기록(앱의 「어제·오늘 원본 업로드」 JSON)의 길 모양으로 통행료 규칙을 다시 돌려 본다(TGT1119A02).
/// `TAPTION_TOLL_REPLAY=<원본 JSON 경로>`가 있을 때만 돈다. 좌표는 저장소에 두지 않고, 시험은 이름 쌍만 가짜(「회사」「집」)로 쓴다.
/// 원본의 첫 번째 날(어제)에는 자동차 이동이 둘(출근·퇴근), 둘째 날(오늘)에는 출근이 있어야 한다.
final class TollRealRouteReplayTests: XCTestCase {
    private struct Raw: Decodable {
        struct Point: Decodable { var latitude: Double; var longitude: Double; var horizontalAccuracy: Double }
        struct Reading: Decodable { var timestamp: Double; var point: Point?; var locationFixQuality: String? }
        struct Span: Decodable { var start: Double; var end: Double }
        struct Trip: Decodable { var mode: String; var span: Span }
        var travel: [Trip]
        var readings: [Reading]
    }

    private func drives(_ day: Raw, from: String, to: String) -> [LedgerTollRepeat.Drive] {
        let reference = Date(timeIntervalSinceReferenceDate: 0)
        return day.travel.filter { $0.mode == "car" }.compactMap { trip -> LedgerTollRepeat.Drive? in
            let fixes = day.readings.filter { $0.timestamp >= trip.span.start && $0.timestamp <= trip.span.end && $0.locationFixQuality != "approximate" }
                .sorted { $0.timestamp < $1.timestamp }
                .compactMap { r in r.point.flatMap { $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= 100 ? ($0.latitude, $0.longitude) : nil } }
            let cells = LedgerTollRoute.cells(along: fixes)
            guard cells.count >= LedgerTollRoute.minimumCells else { return nil }
            return .init(from: from, to: to, start: reference.addingTimeInterval(trip.span.start), end: reference.addingTimeInterval(trip.span.end), cells: cells)
        }
    }

    func testRealRoutesKeepTwoRoadsApartAndLearnTheCorrectedFare() throws {
        guard let path = ProcessInfo.processInfo.environment["TAPTION_TOLL_REPLAY"], !path.isEmpty else { throw XCTSkip("TAPTION_TOLL_REPLAY 없음") }
        let days = try JSONDecoder().decode([Raw].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let yesterday = try XCTUnwrap(days.first), today = try XCTUnwrap(days.dropFirst().first)
        let morning = try XCTUnwrap(drives(yesterday, from: "집", to: "회사").first, "어제 출근")
        let evening = try XCTUnwrap(drives(yesterday, from: "회사", to: "집").last, "어제 퇴근")
        let morningToday = try XCTUnwrap(drives(today, from: "집", to: "회사").last, "오늘 출근")
        XCTAssertEqual(LedgerTollRoute.match(morning.cells, evening.route), .different, "출근길과 퇴근길은 다른 길이다")
        XCTAssertEqual(LedgerTollRoute.match(morningToday.cells, morning.route), .same, "오늘 출근은 어제 출근과 같은 길")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let settled = evening.end.addingTimeInterval(86_400)
        // 11-12에 배운 두 규칙(둘 다 900원, 길 모양은 어제 이동으로 채워짐).
        var rules: [String: LedgerTollRepeat.Rule] = [
            "집→회사": .init(amount: 900, currency: "KRW", title: "통행료 (출근)", learnedAt: morning.start.addingTimeInterval(-86_400 * 5), base: 900, route: LedgerTollRoute.stored(morning.cells)),
            "회사→집": .init(amount: 900, currency: "KRW", title: "통행료 (퇴근)", learnedAt: evening.start.addingTimeInterval(-86_400 * 5), base: 900, route: LedgerTollRoute.stored(evening.cells)),
        ]
        func add(_ drive: LedgerTollRepeat.Drive) -> (entry: LedgerEntry, suspicious: Bool)? {
            LedgerTollRepeat.entries(drives: [drive], existing: [], rules: rules, handled: [], now: drive.end.addingTimeInterval(7_200), calendar: calendar)
                .first.map { ($0.entry, $0.suspicious) }
        }
        XCTAssertEqual(add(morningToday)?.entry.amount, 900, "오늘 출근은 900원 규칙대로")

        // 대표가 어제 퇴근 항목을 2,500원으로 고쳐 남겼다(자동 추가 메모가 붙은 채).
        var corrected = LedgerEntry(occurredAt: evening.end, amount: 2_500, title: "통행료 (퇴근)")
        corrected.category = .transport
        corrected.note = "같은 길 통행료 자동 추가 · 회사 → 집"
        rules = LedgerTollRepeat.learn(drives: [morning, evening], entries: [corrected], into: rules)
        XCTAssertEqual(rules["회사→집"]?.amount, 2_500, "고친 금액이 그 길의 규칙")
        XCTAssertEqual(rules["회사→집"]?.flat, true)
        XCTAssertEqual(rules["집→회사"]?.amount, 900, "출근 규칙은 그대로")
        XCTAssertEqual(rules.count, 2)

        // 같은 길로 퇴근하는 오늘 저녁: 18~20시여도 할인 없이 2,500원, 확인 필요 없이.
        var tonight = evening
        tonight.start = settled.addingTimeInterval(-3_600 * 6)
        tonight.end = settled.addingTimeInterval(-3_600 * 5)
        let result = try XCTUnwrap(add(tonight))
        XCTAssertEqual(result.entry.amount, 2_500)
        XCTAssertFalse(result.suspicious)
        // 출근길로 퇴근하면(다른 길) 2,500원을 되풀이하지 않는다: 카카오 길찾기 후보로 남는다.
        var other = morning
        other.from = "회사"; other.to = "집"; other.start = tonight.start; other.end = tonight.end
        XCTAssertNil(add(other), "다른 길이면 규칙 금액을 넣지 않는다")
        other.points = [.init(at: other.start, latitude: 0.1, longitude: 0.1), .init(at: other.end, latitude: 0.2, longitude: 0.2)]
        XCTAssertEqual(LedgerTollKakao.candidates(drives: [other], existing: [], handled: [], asked: [], now: other.end.addingTimeInterval(7_200)).count, 1)
    }
}

private extension LedgerTollRepeat.Drive {
    var route: [String]? { LedgerTollRoute.stored(cells) }
}
