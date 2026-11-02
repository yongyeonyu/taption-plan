import SwiftUI
import UIKit

/// 코디네이터 레이어에 그리는 발자국 하나. `id`는 `MapHomeVectorMarker`와 같아 한 번 투영한 점을 함께 쓴다.
struct MapHomeLayerPawprint: Equatable {
    /// 그림 하나를 여러 발자국이 나눠 쓰는 열쇠. 돌리기는 레이어 변환이라 여기에 없다.
    struct Glyph: Hashable {
        let colorRGBA: UInt32
        let isSelected: Bool
    }

    let id: String
    let glyph: Glyph
    let angleDegrees: Double
    /// 재생 시각이 여기 닿으면 보인다. 없으면(예상 경로) 늘 보인다.
    let revealsAt: Date?

    init(id: String, color: Color, isSelected: Bool, angleDegrees: Double, revealsAt: Date?) {
        self.id = id
        glyph = Glyph(colorRGBA: Self.rgba(UIColor(color)), isSelected: isSelected)
        self.angleDegrees = angleDegrees
        self.revealsAt = revealsAt
    }

    private static func rgba(_ color: UIColor) -> UInt32 {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let byte = { (value: CGFloat) in UInt32((min(max(value, 0), 1) * 255).rounded()) }
        return byte(red) << 24 | byte(green) << 16 | byte(blue) << 8 | byte(alpha)
    }
}

/// 재생 중 발자국을 SwiftUI 없이 그린다. 프레임마다 레이어 위치만 옮겨 지도 카메라와 같은 틱에 움직인다(OPT1102A01).
/// 레이어는 터치를 받지 않으므로 핀치·팬이 그대로 지도로 가고, 탭은 지금처럼 지도 탭이 위치로 판정한다.
/// SwiftUI 오버레이 아래에 있어 장소 핀·화랑이가 발자국을 덮는 순서도 그대로다.
@MainActor
final class MapHomeCoordinatorMarkerLayer {
    let host = CALayer()
    private var pawprints: [MapHomeLayerPawprint] = []
    private var layers: [CALayer] = []
    private var glyphs: [MapHomeLayerPawprint.Glyph: CGImage] = [:]
    private static let glyphLimit = 256

    init() {
        host.actions = ["sublayers": NSNull(), "bounds": NSNull(), "position": NSNull()]
    }

    var isEmpty: Bool { pawprints.isEmpty }

    /// 내용이 바뀌었을 때만 부른다. 배열 순서가 그리는 순서다(뒤가 위).
    func update(_ next: [MapHomeLayerPawprint]) {
        guard next != pawprints else { return }
        pawprints = next
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        while layers.count > next.count { layers.removeLast().removeFromSuperlayer() }
        while layers.count < next.count {
            let layer = CALayer()
            layer.isHidden = true
            layer.contentsGravity = .center
            host.addSublayer(layer)
            layers.append(layer)
        }
        let scale = host.contentsScale
        for (pawprint, layer) in zip(next, layers) {
            let image = glyphImage(pawprint.glyph)
            layer.contents = image
            layer.contentsScale = scale
            layer.bounds.size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
            layer.setAffineTransform(CGAffineTransform(rotationAngle: pawprint.angleDegrees * .pi / 180))
        }
    }

    /// 재생 한 프레임. 투영에서 빠진(화면에서 먼) 발자국과 아직 지나지 않은 발자국은 숨긴다.
    func apply(points: [String: CGPoint], at date: Date) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for (pawprint, layer) in zip(pawprints, layers) {
            let isRevealed = pawprint.revealsAt.map { $0 <= date } ?? true
            guard isRevealed, let point = points[pawprint.id] else {
                if !layer.isHidden { layer.isHidden = true }
                continue
            }
            if layer.position != point { layer.position = point }
            if layer.isHidden { layer.isHidden = false }
        }
    }

    private func glyphImage(_ glyph: MapHomeLayerPawprint.Glyph) -> CGImage {
        if let cached = glyphs[glyph] { return cached }
        if glyphs.count >= Self.glyphLimit { glyphs.removeAll() }
        let image = Self.render(glyph, scale: host.contentsScale)
        glyphs[glyph] = image
        return image
    }

    /// `MapHomeView.pawprintImage`와 같은 모양(굵은 12pt 발자국, 고른 것은 흰 원과 강조 테두리).
    private static func render(_ glyph: MapHomeLayerPawprint.Glyph, scale: CGFloat) -> CGImage {
        let channel = { (shift: UInt32) in CGFloat((glyph.colorRGBA >> shift) & 0xFF) / 255 }
        let color = UIColor(red: channel(24), green: channel(16), blue: channel(8), alpha: channel(0))
        let configuration = UIImage.SymbolConfiguration(
            pointSize: TaptionType.scaled(TaptionType.snapped(12)),
            weight: .bold
        )
        let symbol = UIImage(systemName: "pawprint.fill", withConfiguration: configuration)?
            .withTintColor(color, renderingMode: .alwaysOriginal) ?? UIImage()
        let padding: CGFloat = glyph.isSelected ? 5 : 0
        let side = max(symbol.size.width, symbol.size.height)
        let size = glyph.isSelected ? CGSize(width: side + padding * 2, height: side + padding * 2) : symbol.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { context in
            if glyph.isSelected {
                let circle = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
                context.cgContext.setFillColor(UIColor.white.cgColor)
                context.cgContext.fillEllipse(in: circle)
                context.cgContext.setStrokeColor(UIColor(Color.tpAccent).cgColor)
                context.cgContext.setLineWidth(2)
                context.cgContext.strokeEllipse(in: circle)
            }
            symbol.draw(at: CGPoint(x: (size.width - symbol.size.width) / 2, y: (size.height - symbol.size.height) / 2))
        }
        return rendered.cgImage!
    }
}
