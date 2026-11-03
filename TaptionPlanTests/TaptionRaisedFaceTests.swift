import SwiftUI
import XCTest
@testable import TaptionPlan

final class TaptionRaisedFaceTests: XCTestCase {
    private let rect = CGRect(x: 0, y: 0, width: 40, height: 40)

    func testLipStaysOutsideFace() {
        for shape in [TaptionRaisedShape.circle, .capsule, .rounded(12)] {
            let lip = TaptionRaisedLip(shape: shape, drop: 2.6).path(in: rect)
            XCTAssertFalse(lip.contains(CGPoint(x: 20, y: 20)))
            XCTAssertFalse(lip.contains(CGPoint(x: 20, y: 2)), "빛 받는 위쪽에는 그림자가 없다")
            XCTAssertTrue(lip.contains(CGPoint(x: 20, y: 41.5)), "바닥 아래로 삐져나온다")
        }
    }

    func testInsetShrinksEveryShape() {
        for shape in [TaptionRaisedShape.circle, .capsule, .rounded(12)] {
            let bounds = shape.inset(by: 2).path(in: rect).boundingRect
            XCTAssertEqual(bounds.width, 36, accuracy: 0.01)
            XCTAssertEqual(bounds.minY, 2, accuracy: 0.01)
        }
    }

    func testGlossSitsInUpperPartInsideFace() {
        for size in [CGSize(width: 22, height: 22), CGSize(width: 34, height: 22), CGSize(width: 40, height: 40)] {
            let box = CGRect(origin: .zero, size: size)
            let gloss = TaptionRaisedGloss().path(in: box).boundingRect
            XCTAssertTrue(box.contains(gloss))
            XCTAssertLessThan(gloss.maxY, size.height / 2)
            XCTAssertEqual(gloss.midX, box.midX, accuracy: 0.01)
        }
    }
}
