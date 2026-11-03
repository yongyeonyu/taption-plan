import CoreGraphics
import UIKit

enum HwarangDiagnostics {
    /// 장면 한 프레임을 그림으로 낸다. 자세·장식 검토 시트를 만들 때 쓴다.
    /// `world`는 비트맵 가로에 담을 세계 폭으로, 작은 크기 그림(`small`)도 같은 틀에서 본다.
    static func frame(
        scene: HwarangScene, sec: Double, side: CGFloat = 438, small: Bool = false,
        hat: UIImage? = nil, scarf: HwarangClothStyle? = nil, ribbon: HwarangClothStyle? = nil
    ) -> UIImage {
        let headroom = hat == nil ? 0 : HwarangSceneView.hatHeadroom
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { renderer in
            let context = renderer.cgContext
            let k = side / (146 + headroom)
            context.scaleBy(x: k, y: k)
            context.translateBy(x: 14 + headroom / 2, y: headroom - 8)
            var painter = HwarangPainter(c: context, small: small, hatImage: hat, scarf: scarf, ribbon: ribbon)
            painter.render(scene, sec: CGFloat(sec), facesLeft: false, showsBackdrop: false)
        }
    }

    /// 시험용: 장면을 비트맵에 그려 칠해진 화소 수를 돌려준다.
    static func paintedPixels(scene: HwarangScene, sec: Double, hat: String? = nil, side: Int = 146) -> Int {
        alphaMap(scene: scene, sec: sec, hat: hat.flatMap { UIImage(named: $0) }, side: side, scale: 1).reduce(0) { $0 + ($1 > 0 ? 1 : 0) }
    }

    /// 시험용: 세계 좌표 한 점에 그림이 칠해졌는지. 캔버스 안(x -14...132, y 8...142)만 잰다.
    static func isPainted(scene: HwarangScene, sec: Double, at point: CGPoint) -> Bool {
        let map = alphaMap(scene: scene, sec: sec, hat: nil, side: 146, scale: 1)
        // 비트맵 메모리는 아래 행부터 쌓인다.
        return map[(145 - (Int(point.y) - 8)) * 146 + Int(point.x) + 14] > 0
    }

    /// 시험용: 식사 장면에서 머리와 밥그릇이 함께 칠한 화소 수.
    static func faceBowlOverlap(sec: Double) -> Int {
        func mask(bowlOnly: Bool) -> [UInt8] {
            drawnAlpha(side: 200, scale: 2) { HwarangPainter(c: $0, small: false).drawEatPart(bowlOnly: bowlOnly, sec: CGFloat(sec)) }
        }
        return zip(mask(bowlOnly: false), mask(bowlOnly: true)).reduce(0) { $0 + ($1.0 > 0 && $1.1 > 0 ? 1 : 0) }
    }

    private static func drawnAlpha(side: Int, scale: CGFloat, _ draw: (CGContext) -> Void) -> [UInt8] {
        let pixelSide = Int(CGFloat(side) * scale)
        var pixels = [UInt8](repeating: 0, count: pixelSide * pixelSide * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: pixelSide, height: pixelSide, bitsPerComponent: 8, bytesPerRow: pixelSide * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: 30, y: 16)
            draw(context)
        }
        return stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
    }

    private static let accessoryMapSide: CGFloat = 200, accessoryMapLeft: CGFloat = 30, accessoryMapTop: CGFloat = 16

    /// 시험용: 장식을 걸친 그림에서 맨몸 윤곽을 `margin`(세계 좌표)만큼 넓힌 범위 밖으로 나간 화소 수.
    /// 움직이는 천이 몸에서 떨어져 나가면 이 값이 커진다. `clipped`는 화면 캔버스 밖으로 나가 잘리는 화소 수다.
    static func accessoryEscape(
        scene: HwarangScene, sec: Double, scarf: HwarangClothStyle?, ribbon: HwarangClothStyle?,
        margin: Int, small: Bool = false, scale: CGFloat = 2
    ) -> (added: Int, escaped: Int, clipped: Int) {
        let side = Int(accessoryMapSide * scale)
        let bare = alphaMap(scene: scene, sec: sec, hat: nil, side: side, scale: scale, small: small)
        let worn = alphaMap(scene: scene, sec: sec, hat: nil, side: side, scale: scale, small: small, scarf: scarf, ribbon: ribbon)
        let reach = Int(CGFloat(margin) * scale)
        // 가로·세로로 나눠 넓혀 사각 범위 팽창을 선형에 가깝게 계산한다.
        var horizontal = [Bool](repeating: false, count: bare.count)
        for y in 0..<side {
            var last = -reach - 1
            for x in 0..<side { if bare[y * side + x] > 0 { last = x }; if x - last <= reach { horizontal[y * side + x] = true } }
            last = side + reach + 1
            for x in stride(from: side - 1, through: 0, by: -1) { if bare[y * side + x] > 0 { last = x }; if last - x <= reach { horizontal[y * side + x] = true } }
        }
        var grown = [Bool](repeating: false, count: bare.count)
        for x in 0..<side {
            var last = -reach - 1
            for y in 0..<side { if horizontal[y * side + x] { last = y }; if y - last <= reach { grown[y * side + x] = true } }
            last = side + reach + 1
            for y in stride(from: side - 1, through: 0, by: -1) { if horizontal[y * side + x] { last = y }; if last - y <= reach { grown[y * side + x] = true } }
        }
        // 화면 캔버스(세계 x -14...132, y 8...142) 밖은 앱에서 잘린다.
        let canvas = CGRect(x: (accessoryMapLeft - 14) * scale, y: (accessoryMapTop + 8) * scale, width: HwarangSceneView.worldWidth * scale, height: HwarangSceneView.worldHeight * scale)
        var added = 0, escaped = 0, clipped = 0
        for i in worn.indices where worn[i] > 0 && bare[i] == 0 {
            added += 1
            if !grown[i] { escaped += 1 }
            if !canvas.contains(CGPoint(x: i % side, y: i / side)) { clipped += 1 }
        }
        return (added, escaped, clipped)
    }

    private static func alphaMap(
        scene: HwarangScene, sec: Double, hat: UIImage?, side: Int, scale: CGFloat, small: Bool = false,
        scarf: HwarangClothStyle? = nil, ribbon: HwarangClothStyle? = nil
    ) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.scaleBy(x: scale, y: scale)
            // 1배는 기존 시험과 같은 틀, 그 밖에는 캔버스 밖 화소까지 담는 넓은 틀이다.
            if scale == 1 { context.translateBy(x: 14, y: -8) } else { context.translateBy(x: accessoryMapLeft, y: accessoryMapTop) }
            var painter = HwarangPainter(c: context, small: small, hatImage: hat, scarf: scarf, ribbon: ribbon)
            painter.render(scene, sec: CGFloat(sec), facesLeft: false, showsBackdrop: scale == 1)
        }
        return stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
    }
}
