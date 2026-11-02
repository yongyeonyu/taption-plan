import XCTest
@testable import TaptionPlan

/// 흩어져 있던 이동 이름·아이콘 표를 합칠 때 값이 바뀌지 않았는지 지킨다.
final class MovementNameTests: XCTestCase {
    func testTravelModeTitlesAndSymbolsKeepTheirValues() {
        let expected: [(TravelMode, String, String)] = [
            (.walking, "걷기", "figure.walk"),
            (.running, "달리기", "figure.run"),
            (.cycling, "자전거", "bicycle"),
            (.bus, "버스", "bus"),
            (.subway, "지하철", "tram"),
            (.taxi, "택시", "car.side"),
            (.car, "자동차", "car"),
            (.train, "기차", "train.side.front.car"),
            (.airplane, "비행기", "airplane"),
            (.ship, "배", "ferry"),
        ]
        XCTAssertEqual(expected.count, TravelMode.allCases.count)
        for (mode, title, symbol) in expected {
            XCTAssertEqual(MovementPresentation.title(for: mode), title)
            XCTAssertEqual(mode.outlineSymbolName, symbol)
        }
    }
}
