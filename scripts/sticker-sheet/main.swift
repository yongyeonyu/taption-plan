// 스티커 시트를 PNG로 그린다. 앱과 같은 그리기 코드를 쓰므로 맥에서 바로 눈으로 확인할 수 있다.
//   bash scripts/sticker-sheet/run.sh <출력 폴더> [분류 id…]
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
let filter = Set(arguments.dropFirst(2))
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let cell: CGFloat = 132
let art: CGFloat = 96
let columns = 8
let tintChoices: [UInt32] = [0xF28FA9, 0xA9CFF0, 0x8FD9C5, 0xF2D58D, 0xC2B4E9, 0xF2B18D]

func label(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat, in context: CGContext, height: CGFloat) {
    let font = CTFontCreateWithName("AppleSDGothicNeo-Medium" as CFString, size, nil)
    let string = NSAttributedString(string: text, attributes: [
        kCTFontAttributeName as NSAttributedString.Key: font,
        kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 0.15, alpha: 1)
    ])
    let line = CTLineCreateWithAttributedString(string)
    let width = CTLineGetBoundsWithOptions(line, []).width
    context.saveGState()
    context.textMatrix = .identity
    context.translateBy(x: 0, y: height)
    context.scaleBy(x: 1, y: -1)
    context.textPosition = CGPoint(x: x - width / 2, y: height - y)
    CTLineDraw(line, context)
    context.restoreGState()
}

var total = 0
for category in StickerCatalog.categories where filter.isEmpty || filter.contains(category.id) {
    let rows = Int(ceil(Double(category.entries.count) / Double(columns)))
    let width = cell * CGFloat(columns)
    let height = cell * CGFloat(rows) + 40
    let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: 0, y: height)
    context.scaleBy(x: 1, y: -1)
    context.setFillColor(CGColor(srgbRed: 0.98, green: 0.96, blue: 0.91, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    label("\(category.koreanName) · \(category.entries.count)개", x: width / 2, y: 28, size: 22, in: context, height: height)
    for (index, entry) in category.entries.enumerated() {
        let drawing = entry.drawing
        if !drawing.problems.isEmpty { print("문제 \(entry.id): \(drawing.problems)") }
        let x = cell * CGFloat(index % columns), y = 40 + cell * CGFloat(index / columns)
        context.saveGState()
        context.translateBy(x: x + (cell - art) / 2, y: y + 6)
        StickerArtEngine.draw(drawing, style: entry.style, tint: tintChoices[index % tintChoices.count], in: context, side: art)
        context.restoreGState()
        let mark = entry.isRecolorable ? "" : (entry.style == .puffy ? " ·3D" : " ·다색")
        label(entry.koreanName + mark, x: x + cell / 2, y: y + cell - 12, size: 13, in: context, height: height)
    }
    total += category.entries.count
    let url = outputDirectory.appendingPathComponent("stickers-\(category.id).png")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    print("\(category.id): \(category.entries.count) → \(url.path)")
}
print("합계 \(total)")
