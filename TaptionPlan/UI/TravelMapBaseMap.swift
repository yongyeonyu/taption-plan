import CoreGraphics
import CoreLocation
import Foundation
import UIKit

/// 경도·위도 상자(도).
struct TravelMapGeoBox: Hashable, Sendable {
    var west: Double
    var south: Double
    var east: Double
    var north: Double

    func contains(_ other: TravelMapGeoBox) -> Bool {
        other.west >= west && other.east <= east && other.south >= south && other.north <= north
    }

    func intersects(_ other: TravelMapGeoBox) -> Bool {
        other.west <= east && other.east >= west && other.south <= north && other.north >= south
    }
}

/// 앱에 넣은 Natural Earth 바탕 지도(TRV1108A01, 공개 도메인).
///
/// `scripts/natural-earth/build.py`가 만든 `ne-basemap.bin`을 읽는다. 세계(1:110m)와
/// 동아시아(1:10m, `region`으로 자른 것) 두 벌이 있고, 화면이 `region` 안이면 자세한 쪽을 쓴다.
/// 타일·지도 서비스를 쓰지 않아 오프라인에서도 같은 그림이 나온다.
struct TravelMapBaseMap: Sendable {
    enum Layer: UInt8, Sendable { case land = 0, lake = 1, border = 2 }
    enum Scope: UInt8, Sendable { case world = 0, region = 1 }

    struct Part: Sendable {
        /// (경도, 위도)
        let points: [SIMD2<Double>]
        let box: TravelMapGeoBox
    }

    enum DecodeError: Error { case badHeader, truncated }

    static let quantum = 1e-4
    static let bundled: TravelMapBaseMap? = {
        guard let url = Bundle.main.url(forResource: "ne-basemap", withExtension: "bin"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? decode(data)
    }()

    let region: TravelMapGeoBox
    private let parts: [Key: [Part]]

    private struct Key: Hashable { let layer: Layer; let scope: Scope }

    func parts(_ layer: Layer, scope: Scope) -> [Part] { parts[Key(layer: layer, scope: scope)] ?? [] }

    /// 화면이 동아시아 상자 안에 다 들어올 때만 자세한 지도를 쓴다. 걸치면 경계에서 해안선이 어긋난다.
    func scope(for view: TravelMapGeoBox) -> Scope { region.contains(view) ? .region : .world }

    // MARK: - 읽기

    /// 형식: "TPNE" · 판 u8 · 길이 u32 · 상자 4×i32 · 층 수 u8 · 층마다(층 u8 · 범위 u8 · 조각 수 u32 · 조각들).
    /// 조각은 점 수 varint 뒤에 1e-4도 단위의 zigzag varint 차이 (경도, 위도)가 이어진다.
    static func decode(_ data: Data) throws -> TravelMapBaseMap {
        var reader = Reader(bytes: [UInt8](data))
        guard try reader.bytes(4) == Array("TPNE".utf8), try reader.byte() == 1 else { throw DecodeError.badHeader }
        let length = Int(try reader.uint32())
        guard length == reader.remaining else { throw DecodeError.truncated }
        let box = try (0..<4).map { _ in Double(try reader.int32()) * quantum }
        var parts: [Key: [Part]] = [:]
        for _ in 0..<Int(try reader.byte()) {
            guard let layer = Layer(rawValue: try reader.byte()),
                  let scope = Scope(rawValue: try reader.byte()) else { throw DecodeError.badHeader }
            let count = Int(try reader.uint32())
            var list: [Part] = []
            list.reserveCapacity(count)
            for _ in 0..<count { list.append(try reader.part()) }
            parts[Key(layer: layer, scope: scope), default: []] += list
        }
        return TravelMapBaseMap(region: TravelMapGeoBox(west: box[0], south: box[1], east: box[2], north: box[3]), parts: parts)
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        var remaining: Int { bytes.count - offset }

        mutating func byte() throws -> UInt8 {
            guard offset < bytes.count else { throw DecodeError.truncated }
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func bytes(_ count: Int) throws -> [UInt8] {
            guard remaining >= count else { throw DecodeError.truncated }
            defer { offset += count }
            return Array(bytes[offset..<offset + count])
        }

        mutating func uint32() throws -> UInt32 {
            try bytes(4).enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) }
        }

        mutating func int32() throws -> Int32 { Int32(bitPattern: try uint32()) }

        mutating func varint() throws -> UInt64 {
            var value: UInt64 = 0, shift: UInt64 = 0
            while true {
                let next = try byte()
                value |= UInt64(next & 0x7F) << shift
                if next & 0x80 == 0 { return value }
                shift += 7
                guard shift < 64 else { throw DecodeError.badHeader }
            }
        }

        mutating func signed() throws -> Int64 {
            let raw = try varint()
            return Int64(bitPattern: raw >> 1) ^ -Int64(bitPattern: raw & 1)
        }

        mutating func part() throws -> Part {
            let count = Int(try varint())
            var points: [SIMD2<Double>] = []
            points.reserveCapacity(count)
            var x: Int64 = 0, y: Int64 = 0
            var box = TravelMapGeoBox(west: .infinity, south: .infinity, east: -.infinity, north: -.infinity)
            for _ in 0..<count {
                x += try signed()
                y += try signed()
                let point = SIMD2(Double(x) * TravelMapBaseMap.quantum, Double(y) * TravelMapBaseMap.quantum)
                box = TravelMapGeoBox(
                    west: min(box.west, point.x), south: min(box.south, point.y),
                    east: max(box.east, point.x), north: max(box.north, point.y)
                )
                points.append(point)
            }
            return Part(points: points, box: box)
        }
    }

    // MARK: - 그리기

    /// 바다 → 육지 → 호수 → 국경 순서로 그린다. 육지는 짝홀 규칙으로 채워 섬 속 구멍도 맞는다.
    func draw(in context: CGContext, viewport: TravelMapViewport, palette: TravelMapPalette) {
        let view = viewport.geoBox
        let scope = scope(for: view)
        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(palette.water.cgColor)
        context.fill(CGRect(origin: .zero, size: viewport.size))
        context.setLineJoin(.round)
        context.setLineCap(.round)

        let land = path(parts(.land, scope: scope), view: view, viewport: viewport, closes: true)
        context.addPath(land)
        context.setFillColor(palette.land.cgColor)
        context.fillPath(using: .evenOdd)
        context.addPath(land)
        context.setStrokeColor(palette.coast.cgColor)
        context.setLineWidth(0.8)
        context.strokePath()

        let lakes = path(parts(.lake, scope: scope), view: view, viewport: viewport, closes: true)
        context.addPath(lakes)
        context.setFillColor(palette.water.cgColor)
        context.fillPath(using: .evenOdd)

        let borders = path(parts(.border, scope: scope), view: view, viewport: viewport, closes: false)
        context.addPath(borders)
        context.setStrokeColor(palette.border.cgColor)
        context.setLineWidth(0.7)
        context.setLineDash(phase: 0, lengths: [3, 2])
        context.strokePath()
    }

    private func path(_ parts: [Part], view: TravelMapGeoBox, viewport: TravelMapViewport, closes: Bool) -> CGPath {
        let path = CGMutablePath()
        for part in parts where part.box.intersects(view) && part.points.count >= 2 {
            path.move(to: viewport.point(longitude: part.points[0].x, latitude: part.points[0].y))
            for point in part.points.dropFirst() {
                path.addLine(to: viewport.point(longitude: point.x, latitude: point.y))
            }
            if closes { path.closeSubpath() }
        }
        return path
    }
}

/// 웹 메르카토르 화면 투영. 영상 내내 카메라가 여행 전체를 담고 움직이지 않는다.
struct TravelMapViewport: Sendable {
    static let maximumLatitude = 85.0
    /// 한 도시 안 여행이라도 이 폭(m)보다 가까이 가지 않는다. 바탕 지도는 해안선 수준이다.
    static let minimumSpanMeters = 120_000.0
    static let earthCircumference = 40_075_016.686
    /// 가장자리 도시 이름이 잘리지 않게 남기는 비율.
    static let paddingRatio = 0.18

    let size: CGSize
    /// 메르카토르 단위(0...1)의 화면 중심과 1단위당 pt.
    let center: CGPoint
    let scale: Double
    /// `center`가 놓이는 화면 점.
    let anchor: CGPoint

    static func mercator(longitude: Double, latitude: Double) -> CGPoint {
        let clamped = min(max(latitude, -maximumLatitude), maximumLatitude) * .pi / 180
        return CGPoint(x: (longitude + 180) / 360, y: (1 - log(tan(clamped) + 1 / cos(clamped)) / .pi) / 2)
    }

    static func coordinate(mercator point: CGPoint) -> CLLocationCoordinate2D {
        let latitude = atan(sinh(.pi * (1 - 2 * point.y))) * 180 / .pi
        return CLLocationCoordinate2D(latitude: latitude, longitude: point.x * 360 - 180)
    }

    /// 좌표를 모두 `content` 안에 담는 가장 가까운 화면.
    static func fit(_ coordinates: [CLLocationCoordinate2D], content: CGRect, size: CGSize) -> TravelMapViewport {
        let points = coordinates.map { mercator(longitude: $0.longitude, latitude: $0.latitude) }
        guard let first = points.first else {
            return TravelMapViewport(size: size, center: CGPoint(x: 0.5, y: 0.5), scale: Double(content.width), anchor: CGPoint(x: content.midX, y: content.midY))
        }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        let center = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        let latitude = coordinate(mercator: center).latitude * .pi / 180
        let minimumSpan = minimumSpanMeters / (earthCircumference * max(0.05, cos(latitude)))
        let spanX = max(Double(maxX - minX), minimumSpan) * (1 + 2 * paddingRatio)
        let spanY = max(Double(maxY - minY), minimumSpan) * (1 + 2 * paddingRatio)
        // 세계 한 바퀴(메르카토르 1단위)보다 멀리 물러나지 않는다.
        let scale = max(Double(content.width), min(Double(content.width) / spanX, Double(content.height) / spanY))
        return TravelMapViewport(size: size, center: center, scale: scale, anchor: CGPoint(x: content.midX, y: content.midY))
    }

    func point(longitude: Double, latitude: Double) -> CGPoint {
        let value = Self.mercator(longitude: longitude, latitude: latitude)
        return CGPoint(x: anchor.x + (value.x - center.x) * scale, y: anchor.y + (value.y - center.y) * scale)
    }

    func point(_ coordinate: CLLocationCoordinate2D) -> CGPoint {
        point(longitude: coordinate.longitude, latitude: coordinate.latitude)
    }

    /// 화면 전체가 덮는 경위도 상자.
    var geoBox: TravelMapGeoBox {
        let topLeft = Self.coordinate(mercator: CGPoint(x: center.x + (0 - anchor.x) / scale, y: center.y + (0 - anchor.y) / scale))
        let bottomRight = Self.coordinate(mercator: CGPoint(
            x: center.x + (size.width - anchor.x) / scale, y: center.y + (size.height - anchor.y) / scale
        ))
        return TravelMapGeoBox(west: topLeft.longitude, south: bottomRight.latitude, east: bottomRight.longitude, north: topLeft.latitude)
    }
}

/// 바탕 지도와 경로 색. 너무 어둡지도 밝지도 않은 중간 톤을 앱 테마 색에서 섞어 만든다.
struct TravelMapPalette {
    let water, land, coast, border: UIColor
    let route, routeHalo, city, label, labelHalo, card, cardText, cardSecondary: UIColor
    let isDark: Bool

    @MainActor static var current: TravelMapPalette {
        make(bar: TaptionBarPalette.current, isDark: TaptionUITheme.current.isDark)
    }

    static func make(bar: TaptionBarPalette, isDark: Bool) -> TravelMapPalette {
        let sky = UIColor(bar.sky), cocoa = UIColor(bar.cocoa), cream = UIColor(bar.cream)
        let ink = UIColor(bar.outline), black = UIColor.black
        let water = isDark ? mix(sky, black, 0.6) : mix(sky, cocoa, 0.22)
        let land = isDark ? mix(mix(cocoa, cream, 0.35), black, 0.35) : mix(cream, cocoa, 0.3)
        let text = isDark ? cream : ink
        return TravelMapPalette(
            water: water,
            land: land,
            coast: mix(land, isDark ? black : cocoa, 0.35),
            border: mix(land, isDark ? cream : cocoa, 0.45),
            route: UIColor(bar.coral),
            routeHalo: isDark ? mix(land, black, 0.4) : mix(land, .white, 0.5),
            city: UIColor(bar.brick),
            label: text,
            labelHalo: isDark ? mix(land, black, 0.5) : mix(land, .white, 0.6),
            card: isDark ? black.withAlphaComponent(0.5) : UIColor.white.withAlphaComponent(0.78),
            cardText: text,
            cardSecondary: text.withAlphaComponent(0.75),
            isDark: isDark
        )
    }

    static func mix(_ first: UIColor, _ second: UIColor, _ amount: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        first.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        second.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let keep = 1 - amount
        return UIColor(red: r1 * keep + r2 * amount, green: g1 * keep + g2 * amount, blue: b1 * keep + b2 * amount, alpha: 1)
    }

    /// CIE L*(0~100). 시험이 중간 톤 범위를 잠근다.
    static func lightness(_ color: UIColor) -> Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        func linear(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.040_45 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let y = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        return y > 0.008_856 ? 116 * pow(y, 1.0 / 3) - 16 : 903.3 * y
    }
}
