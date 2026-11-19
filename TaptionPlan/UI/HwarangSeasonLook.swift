import CoreGraphics

/// 시즌 팩이 모든 동작의 화랑이에게 입히는 복장(SEA1119A01). 모자는 그림 파일, 목도리·리본은 천 장식 색이고,
/// 여기서는 빨간 코만 머리 좌표에 직접 그린다. 세 고양이(화랑이·춘향이·윤복이)에 똑같이 나온다.
struct HwarangSeasonLook: Equatable, Sendable {
    var redNose = false
    /// 목도리 자리에 망토를 그린다(`scarf` 색을 망토 천 색으로 쓴다).
    var cape = false
    var scarf: HwarangClothStyle?
    var ribbon: HwarangClothStyle?

    var isEmpty: Bool { !redNose && scarf == nil && ribbon == nil }
}

extension HwarangPainter {
    /// 코 자리(`mx`, `my`)에 빨간 코를 얹는다. 작은 크기에서도 보이게 분홍 코보다 크게 그린다.
    func drawRedNose(x: CGFloat, y: CGFloat, lineWidth: CGFloat) {
        fill(0xE5392F); stroke(outline, max(lineWidth * 0.55, 0.9))
        c.beginPath(); circle(x, y - 1.5, 1.75); c.drawPath(using: .fillStroke)
        fill(0xB82A22); c.beginPath(); oval(x + 0.4, y - 0.6, 1.1, 0.5); c.fillPath()
        fill(white, 0.9); c.beginPath(); oval(x - 0.6, y - 2.3, 0.6, 0.4); c.fillPath()
    }

    private static func darkened(_ hex: UInt32, _ f: CGFloat) -> UInt32 { scaled(hex) { $0 * f } }
    private static func lightened(_ hex: UInt32, _ f: CGFloat) -> UInt32 { scaled(hex) { $0 + (255 - $0) * f } }
    private static func scaled(_ hex: UInt32, _ f: (CGFloat) -> CGFloat) -> UInt32 {
        func ch(_ s: UInt32) -> UInt32 { UInt32(max(0, min(255, f(CGFloat((hex >> s) & 0xFF))))) }
        return ch(16) << 16 | ch(8) << 8 | ch(0)
    }
}
