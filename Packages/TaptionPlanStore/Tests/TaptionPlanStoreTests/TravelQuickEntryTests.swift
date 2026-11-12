import XCTest
@testable import TaptionPlanStore

final class TravelQuickEntryTests: XCTestCase {
    private func check(
        _ text: String, _ title: String, start: Int? = nil, duration: Int? = nil, kind: String? = nil, file: StaticString = #filePath, line: UInt = #line
    ) {
        let parsed = TravelQuickEntry.parse(text)
        XCTAssertEqual(parsed.title, title, "title", file: file, line: line)
        XCTAssertEqual(parsed.startMinute, start, "start", file: file, line: line)
        XCTAssertEqual(parsed.durationMinutes, duration, "duration", file: file, line: line)
        XCTAssertEqual(parsed.kind, kind, "kind", file: file, line: line)
    }

    func testKoreanTimeAndDuration() {
        check("점심 12시 1시간", "점심", start: 720, duration: 60, kind: "meal")
        check("센소지 2시 30분 90분", "센소지", start: 870, duration: 90)
        check("오전 9시 반 박물관 2시간", "박물관", start: 570, duration: 120, kind: "sight")
        check("1시간 반 카페", "카페", duration: 90, kind: "cafe")
        check("2시간 30분 쇼핑", "쇼핑", duration: 150, kind: "shopping")
        check("14:30 오사카성", "오사카성", start: 870, kind: "sight")
        check("새벽 5시 공항 이동", "공항 이동", start: 300, kind: "flight")
        check("07:00 조식", "조식", start: 420, kind: "meal")
        check("저녁 7시 1시간", "저녁", start: 1_140, duration: 60, kind: "meal")
        check("밤 12시 취침", "취침", start: 0, kind: "sleep")
        check("낮 12시 라멘", "라멘", start: 720, kind: "meal")
        check("1.5시간 온천", "온천", duration: 90, kind: "rest")
    }

    func testRanges() {
        check("9-11 박물관", "박물관", start: 540, duration: 120, kind: "sight")
        check("10~2 시내 구경", "시내 구경", start: 600, duration: 240)
        check("9:30-11:00 투어", "투어", start: 570, duration: 90, kind: "activity")
        check("오후 7시~9시 야경", "야경", start: 1_140, duration: 120, kind: "photo")
        check("7-9pm dinner", "dinner", start: 1_140, duration: 120, kind: "meal")
        check("9am-5pm tour", "tour", start: 540, duration: 480, kind: "activity")
        check("밤 10시-12시 바", "바", start: 1_320, duration: 120)
    }

    func testEnglish() {
        check("2pm cafe 45m", "cafe", start: 840, duration: 45, kind: "cafe")
        check("Lunch 12:30 1h", "Lunch", start: 750, duration: 60, kind: "meal")
        check("museum 10am 2h 30m", "museum", start: 600, duration: 150, kind: "sight")
        check("train 8:05am 90 min", "train", start: 485, duration: 90, kind: "transfer")
    }

    func testPlainTitlesStayWhole() {
        check("도쿄타워", "도쿄타워")
        check("  유니버설   스튜디오 ", "유니버설 스튜디오")
        check("3대 라멘집", "3대 라멘집", kind: "meal")
        check("Terminal 2 pickup", "Terminal 2 pickup")
        check("", "")
    }

    func testDefaultsAndChaining() {
        XCTAssertEqual(TravelQuickEntry.nextStart(lastEndMinute: 780, nowMinute: 600), 780)
        XCTAssertEqual(TravelQuickEntry.nextStart(lastEndMinute: nil, nowMinute: 601), 615)
        XCTAssertEqual(TravelQuickEntry.nextStart(lastEndMinute: nil, nowMinute: nil), 540)
        XCTAssertEqual(TravelQuickEntry.nextStart(lastEndMinute: 1_440, nowMinute: nil), 1_425)
        XCTAssertEqual(TravelQuickEntry.snapped(754), 750)
        XCTAssertEqual(TravelQuickEntry.kind(forColumn: 1), "meal")
        XCTAssertEqual(TravelQuickEntry.defaultDuration(kind: "transfer"), 30)
        XCTAssertEqual(TravelQuickEntry.defaultDuration(kind: "sight"), 90)
    }
}
