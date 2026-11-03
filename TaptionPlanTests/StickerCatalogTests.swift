import CoreGraphics
import Foundation
import XCTest
@testable import TaptionPlan

/// 스티커 목록·색 규칙·옛 기록 호환(STK1104A01).
@MainActor
final class StickerCatalogTests: XCTestCase {
    private var allEntries: [StickerEntry] { StickerCatalog.categories.flatMap(\.entries) }
    private let legacySymbols = ["star.fill", "heart.fill", "flag.fill", "pin.fill", "sparkles", "leaf.fill"]

    func testEverySourceLineBecomesAnEntryWithUniqueID() {
        for category in StickerCatalog.sources {
            let lines = category.source.split(separator: "\n").filter { !$0.hasPrefix("#") }
            let entries = StickerCatalog.parseEntries(category.source, categoryID: category.id)
            XCTAssertEqual(lines.count, entries.count, "\(category.id)에 읽지 못한 줄이 있다")
            XCTAssertFalse(entries.isEmpty, "\(category.id)가 비어 있다")
        }
        let ids = allEntries.map(\.id)
        let duplicates = Dictionary(grouping: ids, by: { $0 }).filter { $0.value.count > 1 }.keys
        XCTAssertEqual(Array(duplicates), [], "겹치는 id")
    }

    func testEveryDrawingParsesAndHasBlackOutline() {
        for entry in allEntries {
            let drawing = entry.drawing
            XCTAssertEqual(drawing.problems, [], entry.id)
            XCTAssertFalse(entry.koreanName.isEmpty, entry.id)
            XCTAssertFalse(entry.englishName.isEmpty, entry.id)
            XCTAssertTrue(drawing.layers.contains(where: \.outlined), "\(entry.id)에 테두리 층이 없다")
        }
    }

    /// 단색 2D만 색이 바뀐다. 다색·입체는 사용자 색을 쓰면 안 된다.
    func testColorRuleMatchesStyle() {
        for entry in allEntries {
            let drawing = entry.drawing
            if entry.isRecolorable {
                XCTAssertEqual(entry.style, .mono, entry.id)
                XCTAssertTrue(drawing.usesTint, "\(entry.id)는 단색인데 사용자 색 층이 없다")
                XCTAssertFalse(drawing.usesOtherColor, "\(entry.id)는 단색인데 다른 색을 쓴다")
            } else {
                XCTAssertFalse(drawing.usesTint, "\(entry.id)는 색 변경이 없는데 사용자 색을 쓴다")
            }
        }
    }

    func testRecolorChangesPixelsOnlyForMono() throws {
        let mono = try XCTUnwrap(StickerCatalog.entry(for: "star.fill"))
        XCTAssertNotEqual(pixels(mono, tint: 0xF28FA9), pixels(mono, tint: 0x5BA8E5))
        let fixed = try XCTUnwrap(allEntries.first { !$0.isRecolorable })
        XCTAssertEqual(pixels(fixed, tint: 0xF28FA9), pixels(fixed, tint: 0x5BA8E5))
    }

    /// 그림과 테두리가 격자 밖으로 나가면 잘린다.
    func testDrawingsStayInsideCanvas() {
        let canvas = CGRect(x: 0, y: 0, width: 100, height: 100).insetBy(dx: -1, dy: -1)
        var clipped: [String] = []
        for entry in allEntries {
            for layer in entry.drawing.layers where layer.outlined {
                let bounds: CGRect = switch layer.shape {
                case .fill(let path): path.boundingBoxOfPath.insetBy(dx: -StickerArtEngine.outerWidth, dy: -StickerArtEngine.outerWidth)
                case .stroke(let path, let width): path.boundingBoxOfPath.insetBy(dx: -(StickerArtEngine.outerWidth + width / 2), dy: -(StickerArtEngine.outerWidth + width / 2))
                }
                if !canvas.contains(bounds) {
                    clipped.append(entry.id)
                    break
                }
            }
        }
        XCTAssertEqual(clipped, [], "잘리는 스티커")
    }

    func testLegacySymbolsStayMonoEntries() throws {
        for symbol in legacySymbols {
            let entry = try XCTUnwrap(StickerCatalog.entry(for: symbol), symbol)
            XCTAssertTrue(entry.isRecolorable, symbol)
        }
        // 옛 색 6개는 고르기에 남는다.
        XCTAssertEqual(Array(StickerCatalog.colors.prefix(6)), ["#F28FA9", "#A9CFF0", "#8FD9C5", "#F2D58D", "#C2B4E9", "#F2B18D"])
    }

    /// 빌드 263 이전 형식의 JSON을 그대로 읽고, 값을 바꾸지 않고 다시 쓴다.
    func testOldMemoAndStickerJSONStillOpen() throws {
        let stickerJSON = #"""
        {"id":"7B0E3A5E-41F1-4F0E-9A52-0D7E2C4A1B11","title":"약속","memo":"역 앞","systemImage":"leaf.fill","colorHex":"#8FD9C5","placement":"schedule","occurredAt":800000000,"createdAt":800000000,"updatedAt":800000000}
        """#
        let sticker = try JSONDecoder().decode(MapSticker.self, from: Data(stickerJSON.utf8))
        XCTAssertEqual(sticker.systemImage, "leaf.fill")
        XCTAssertNotNil(StickerCatalog.entry(for: sticker.systemImage))
        let stickerRound = try JSONDecoder().decode(MapSticker.self, from: JSONEncoder().encode(sticker))
        XCTAssertEqual(stickerRound.systemImage, "leaf.fill")
        XCTAssertEqual(stickerRound.colorHex, "#8FD9C5")

        let stickerMemoJSON = #"""
        {"id":"7B0E3A5E-41F1-4F0E-9A52-0D7E2C4A1B12","kind":"idea","text":"메모","occurredAt":800000000,"createdAt":800000000,"stickerSymbol":"sparkles","stickerColorHex":"#C2B4E9"}
        """#
        let stickerMemo = try JSONDecoder().decode(ActionMemo.self, from: Data(stickerMemoJSON.utf8))
        XCTAssertTrue(stickerMemo.isSticker)
        XCTAssertEqual(stickerMemo.stickerSymbol, "sparkles")
        XCTAssertNotNil(StickerCatalog.entry(for: "sparkles"))

        let plainMemoJSON = #"""
        {"id":"7B0E3A5E-41F1-4F0E-9A52-0D7E2C4A1B13","kind":"idea","text":"옛 메모"}
        """#
        let plainMemo = try JSONDecoder().decode(ActionMemo.self, from: Data(plainMemoJSON.utf8))
        XCTAssertFalse(plainMemo.isSticker)
        XCTAssertNil(plainMemo.stickerColorHex)
    }

    func testNewStickerIDRoundTripsThroughMemo() throws {
        let id = try XCTUnwrap(allEntries.first { $0.categoryID == "cats" }?.id)
        let json = ##"{"id":"7B0E3A5E-41F1-4F0E-9A52-0D7E2C4A1B14","kind":"idea","text":"m","stickerSymbol":"\##(id)","stickerColorHex":"#F28FA9"}"##
        let memo = try JSONDecoder().decode(ActionMemo.self, from: Data(json.utf8))
        let again = try JSONDecoder().decode(ActionMemo.self, from: JSONEncoder().encode(memo))
        XCTAssertEqual(again.stickerSymbol, id)
    }

    /// 고른 아이콘이 먼저, 위치가 있으면 기본 메모 아이콘, 위치도 없으면 화면별 기호(MAP1104A01).
    func testMemoIconChoice() throws {
        func memo(_ extra: String) throws -> ActionMemo {
            let json = #"{"id":"7B0E3A5E-41F1-4F0E-9A52-0D7E2C4A1B15","kind":"idea","text":"m"\#(extra)}"#
            return try JSONDecoder().decode(ActionMemo.self, from: Data(json.utf8))
        }
        let point = #","mapPoint":{"latitude":37.5,"longitude":127,"altitude":0,"horizontalAccuracy":0,"verticalAccuracy":0}"#
        XCTAssertEqual(try memo("").iconSymbol(fallback: "clock.fill"), "clock.fill")
        XCTAssertEqual(try memo(point).iconSymbol(), StickerCatalog.defaultMemoSymbol)
        XCTAssertNotNil(StickerCatalog.entry(for: StickerCatalog.defaultMemoSymbol))
        let chosen = try memo(point + ##","stickerSymbol":"places.star5","stickerColorHex":"#E8655F""##)
        XCTAssertEqual(chosen.iconSymbol(), "places.star5")
        XCTAssertEqual(chosen.iconColorHex, "#E8655F")
        XCTAssertNotNil(StickerCatalog.entry(for: "places.star5"))
        let note = MapHomeSidebarNote.memo(chosen, minute: 0, badgeOffset: 0)
        XCTAssertEqual(note.symbol, "places.star5")
    }

    func testUnknownOrBrokenColorFallsBack() {
        XCTAssertEqual(StickerCatalog.tintValue("#F28FA9"), 0xF28FA9)
        XCTAssertEqual(StickerCatalog.tintValue("oops"), 0xF28FA9)
        XCTAssertNil(StickerCatalog.entry(for: "no.such.sticker"))
    }

    /// 수치를 로그로 남긴다. 판정은 한 줄(120Hz 프레임의 한 줄 5칸)을 처음 그리는 비용이 터무니없을 때만 실패한다.
    func testRenderCostReport() {
        let entries = allEntries
        var start = CFAbsoluteTimeGetCurrent()
        var layers = 0
        for entry in entries { layers += entry.drawing.layers.count }
        let parseMS = (CFAbsoluteTimeGetCurrent() - start) * 1000

        start = CFAbsoluteTimeGetCurrent()
        for entry in entries { _ = pixels(entry, tint: 0xF28FA9, side: 156) }
        let renderMS = (CFAbsoluteTimeGetCurrent() - start) * 1000
        let perSticker = renderMS / Double(max(entries.count, 1))

        var worst = (id: "", ms: 0.0)
        for entry in entries {
            let begin = CFAbsoluteTimeGetCurrent()
            _ = pixels(entry, tint: 0xF28FA9, side: 156)
            let ms = (CFAbsoluteTimeGetCurrent() - begin) * 1000
            if ms > worst.ms { worst = (entry.id, ms) }
        }
        print("STICKER-COST 스티커 \(entries.count)개, 층 \(layers)개, 해석 전체 \(String(format: "%.1f", parseMS))ms, 그리기 전체 \(String(format: "%.1f", renderMS))ms, 평균 \(String(format: "%.2f", perSticker))ms/장, 최악 \(worst.id) \(String(format: "%.2f", worst.ms))ms")
        XCTAssertLessThan(perSticker, 10, "스티커 한 장이 너무 느리다")
    }

    private func pixels(_ entry: StickerEntry, tint: UInt32, side: Int = 48) -> Data {
        let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        StickerArtEngine.draw(entry.drawing, style: entry.style, tint: tint, in: context, side: CGFloat(side))
        return Data(bytes: context.data!, count: side * side * 4)
    }
}
