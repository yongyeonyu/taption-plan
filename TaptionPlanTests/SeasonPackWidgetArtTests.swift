import UIKit
import XCTest
@testable import TaptionPlan

/// SPL1120A01: 시즌 팩 모자·아이콘을 잠금화면·다이나믹 아일랜드용 작은 PNG로 그룹 공간에 둔다.
@MainActor
final class SeasonPackWidgetArtTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SeasonArt-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func png(_ side: CGFloat) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side / 2), format: format).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side / 2))
        }
    }

    func testSmallPNGShrinksToTheLimitAndKeepsShape() throws {
        let small = try XCTUnwrap(SeasonPackAdapter.smallPNG(png(400)))
        let image = try XCTUnwrap(UIImage(data: small))
        XCTAssertEqual(image.size.width * image.scale, TaptionSeasonArt.maximumPixels)
        XCTAssertEqual(image.size.height * image.scale, TaptionSeasonArt.maximumPixels / 2)
        XCTAssertLessThanOrEqual(small.count, TaptionSeasonArt.maximumBytes)
        XCTAssertNil(SeasonPackAdapter.smallPNG(Data("not an image".utf8)))
    }

    func testArtIsWrittenOnlyWhenChangedAndRemovedWhenThePackEnds() throws {
        let root = try folder()
        let url = try XCTUnwrap(TaptionSeasonArt.url(.hat, root: root))
        let data = try XCTUnwrap(SeasonPackAdapter.smallPNG(png(200)))
        XCTAssertTrue(SeasonPackAdapter.writeArt(data, to: url))
        XCTAssertFalse(SeasonPackAdapter.writeArt(data, to: url), "같은 그림은 다시 쓰지 않는다")
        XCTAssertNotNil(TaptionSeasonArt.image(.hat, root: root))
        XCTAssertNil(TaptionSeasonArt.image(.icon, root: root))
        XCTAssertTrue(SeasonPackAdapter.writeArt(nil, to: url), "팩이 꺼지면 지운다")
        XCTAssertNil(TaptionSeasonArt.image(.hat, root: root))
        XCTAssertFalse(SeasonPackAdapter.writeArt(nil, to: url))
    }
}
