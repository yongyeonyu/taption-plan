import Foundation

/// 여행 모드 지구본의 나라·시도 경계 한 곳(TVB1112A01). `scripts/natural-earth/build_regions.py`가 만든 자료다.
public struct TravelGlobeRegion: Hashable, Sendable, Identifiable {
    public enum Kind: UInt8, Sendable { case country = 0, province = 1 }

    public var kind: Kind
    /// 나라는 ISO 3166-1 두 글자(없으면 Natural Earth 세 글자), 시·도는 ISO 3166-2(`KR-27`).
    public var code: String
    public var nameKo: String
    public var nameEn: String
    /// 서·남·동·북(도).
    public var west: Double
    public var south: Double
    public var east: Double
    public var north: Double
    /// 고리마다 (경도, 위도).
    public var rings: [[SIMD2<Double>]]

    public var id: String { code }
    public var center: SIMD2<Double> { SIMD2((west + east) / 2, (south + north) / 2) }

    /// 가장 큰 땅덩이의 상자(서·남·동·북). 먼 섬·해외 영토 때문에 화면 맞춤과 깃발 자리가 바다로 가지 않게 이것을 쓴다.
    /// 고리는 넓이가 큰 것부터 들어 있다.
    public var mainBox: (west: Double, south: Double, east: Double, north: Double) {
        guard let ring = rings.first, let first = ring.first else { return (west, south, east, north) }
        var low = first, high = first
        for point in ring {
            low = pointwiseMin(low, point)
            high = pointwiseMax(high, point)
        }
        return (low.x, low.y, high.x, high.y)
    }

    /// 깃발을 꽂을 자리: 가장 큰 땅덩이의 가운데.
    public var anchor: SIMD2<Double> {
        let box = mainBox
        return SIMD2((box.west + box.east) / 2, (box.south + box.north) / 2)
    }

    /// 그 점이 이곳 안에 있는지(고리 가운데 하나라도 품으면 참).
    public func contains(longitude: Double, latitude: Double) -> Bool {
        guard longitude >= west, longitude <= east, latitude >= south, latitude <= north else { return false }
        return rings.contains { ring in
            var inside = false
            var previous = ring[ring.count - 1]
            for point in ring {
                if (point.y > latitude) != (previous.y > latitude),
                   longitude < (previous.x - point.x) * (latitude - point.y) / (previous.y - point.y) + point.x {
                    inside.toggle()
                }
                previous = point
            }
            return inside
        }
    }
}

public enum TravelGlobeRegions {
    public enum DecodeError: Error { case badHeader, truncated }

    /// 그 점을 품은 곳. 경계를 줄여 둔 자료라 해안 바로 옆 점은 못 찾을 수 있다.
    public static func region(in regions: [TravelGlobeRegion], kind: TravelGlobeRegion.Kind, longitude: Double, latitude: Double) -> TravelGlobeRegion? {
        regions.first { $0.kind == kind && $0.contains(longitude: longitude, latitude: latitude) }
    }

    static let quantum = 1e-4

    /// 형식: "TPRG" · 판 u8 · 곳 수 u32 · 곳마다(종류 u8 · 코드 · 한국어 · 영어 · 상자 4×i32 · 고리 수 u16 · 고리들).
    /// 글자는 길이 u8 + UTF-8, 고리는 점 수 varint 뒤에 1e-4도 zigzag varint 차이 (경도, 위도).
    public static func decode(_ data: Data) throws -> [TravelGlobeRegion] {
        var reader = Reader(bytes: [UInt8](data))
        guard try reader.bytes(4) == Array("TPRG".utf8), try reader.byte() == 1 else { throw DecodeError.badHeader }
        let count = Int(try reader.uint32())
        var regions: [TravelGlobeRegion] = []
        regions.reserveCapacity(count)
        for _ in 0..<count {
            guard let kind = TravelGlobeRegion.Kind(rawValue: try reader.byte()) else { throw DecodeError.badHeader }
            let code = try reader.text(), ko = try reader.text(), en = try reader.text()
            let box = try (0..<4).map { _ in Double(try reader.int32()) * quantum }
            let ringCount = Int(try reader.uint16())
            let rings = try (0..<ringCount).map { _ in try reader.ring() }
            regions.append(TravelGlobeRegion(
                kind: kind, code: code, nameKo: ko, nameEn: en, west: box[0], south: box[1], east: box[2], north: box[3], rings: rings
            ))
        }
        guard reader.remaining == 0 else { throw DecodeError.truncated }
        return regions
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

        mutating func uint16() throws -> UInt16 { UInt16(try byte()) | UInt16(try byte()) << 8 }

        mutating func uint32() throws -> UInt32 {
            try bytes(4).enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) }
        }

        mutating func int32() throws -> Int32 { Int32(bitPattern: try uint32()) }

        mutating func text() throws -> String { String(decoding: try bytes(Int(try byte())), as: UTF8.self) }

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

        mutating func ring() throws -> [SIMD2<Double>] {
            let count = Int(try varint())
            guard count <= remaining else { throw DecodeError.truncated }
            var points: [SIMD2<Double>] = []
            points.reserveCapacity(count)
            var x: Int64 = 0, y: Int64 = 0
            for _ in 0..<count {
                x += try signed()
                y += try signed()
                points.append(SIMD2(Double(x) * quantum, Double(y) * quantum))
            }
            return points
        }
    }
}

/// 지구본을 보는 자리: 화면 가운데에 오는 경도·위도와 지구 반지름(pt).
public struct TravelGlobeCamera: Hashable, Sendable {
    public var longitude: Double
    public var latitude: Double
    public var radius: Double

    public init(longitude: Double, latitude: Double, radius: Double) {
        self.longitude = longitude
        self.latitude = latitude
        self.radius = radius
    }

    /// 정사 투영. 화면 가운데가 (0, 0)이고 y는 아래로 는다. 지구 뒤쪽 점은 `isFront`가 false이고 가장자리로 밀어 둔다.
    public func project(longitude: Double, latitude: Double) -> (point: SIMD2<Double>, isFront: Bool) {
        let rad = Double.pi / 180
        let lambda = (longitude - self.longitude) * rad, phi = latitude * rad, phi0 = self.latitude * rad
        let cosC = sin(phi0) * sin(phi) + cos(phi0) * cos(phi) * cos(lambda)
        var x = cos(phi) * sin(lambda)
        var y = -(cos(phi0) * sin(phi) - sin(phi0) * cos(phi) * cos(lambda))
        if cosC < 0 {
            let length = (x * x + y * y).squareRoot()
            if length > 0 {
                x /= length
                y /= length
            }
        }
        return (SIMD2(x * radius, y * radius), cosC >= 0)
    }

    /// 그 상자가 화면에 꽉 차게 들어오는 자리. 상자 가운데를 보고, `padding`만큼 여백을 둔다.
    public static func fitting(
        west: Double, south: Double, east: Double, north: Double, width: Double, height: Double, padding: Double,
        minimumRadius: Double, maximumRadius: Double
    ) -> TravelGlobeCamera {
        var camera = TravelGlobeCamera(longitude: (west + east) / 2, latitude: (south + north) / 2, radius: 1)
        var halfWidth = 1e-6, halfHeight = 1e-6
        for step in 0...8 {
            let t = Double(step) / 8
            for (lon, lat) in [(west + (east - west) * t, south), (west + (east - west) * t, north), (west, south + (north - south) * t), (east, south + (north - south) * t)] {
                let point = camera.project(longitude: lon, latitude: lat).point
                halfWidth = max(halfWidth, abs(point.x))
                halfHeight = max(halfHeight, abs(point.y))
            }
        }
        let fit = min((width / 2 - padding) / halfWidth, (height / 2 - padding) / halfHeight)
        camera.radius = min(max(fit, minimumRadius), maximumRadius)
        return camera
    }
}

/// 여행 카드를 눌렀을 때의 움직임: 지구가 여행지로 돌고 → 깃발이 꽂히고 → 그 나라(국내는 이어서 시·도)로 확대된다.
public struct TravelGlobeFlight: Hashable, Sendable {
    public static let rotate = 1.2, plant = 0.45, hold = 0.3, zoom = 1.1

    public var start: TravelGlobeCamera
    /// 깃발이 꽂히는 곳.
    public var targetLongitude: Double
    public var targetLatitude: Double
    /// 확대 단계들(나라, 그다음 시·도). 비면 돌고 깃발만 꽂는다.
    public var stops: [TravelGlobeCamera]

    public init(start: TravelGlobeCamera, targetLongitude: Double, targetLatitude: Double, stops: [TravelGlobeCamera]) {
        self.start = start
        self.targetLongitude = targetLongitude
        self.targetLatitude = targetLatitude
        self.stops = stops
    }

    public var duration: Double { Self.rotate + Self.plant + Double(stops.count) * (Self.hold + Self.zoom) }

    /// 깃발이 내려온 정도(0 = 아직 없음, 1 = 꽂힘).
    public func flagProgress(at time: Double) -> Double {
        min(1, max(0, (time - Self.rotate) / Self.plant))
    }

    public func camera(at time: Double) -> TravelGlobeCamera {
        let turned = TravelGlobeCamera(longitude: targetLongitude, latitude: targetLatitude, radius: start.radius)
        if time <= Self.rotate { return Self.mix(start, turned, Self.ease(time / Self.rotate)) }
        var from = turned
        var clock = time - Self.rotate - Self.plant
        for stop in stops {
            if clock <= Self.hold { return from }
            clock -= Self.hold
            if clock <= Self.zoom { return Self.mix(from, stop, Self.ease(clock / Self.zoom)) }
            clock -= Self.zoom
            from = stop
        }
        return from
    }

    static func ease(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    /// 경도는 가까운 쪽으로 돈다(날짜 변경선을 넘어도 반 바퀴를 넘지 않는다). 반지름은 배율로 섞어 확대 속도가 고르게 보인다.
    static func mix(_ a: TravelGlobeCamera, _ b: TravelGlobeCamera, _ t: Double) -> TravelGlobeCamera {
        var delta = (b.longitude - a.longitude).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        var longitude = a.longitude + delta * t
        if longitude > 180 { longitude -= 360 }
        if longitude < -180 { longitude += 360 }
        let radius = a.radius > 0 && b.radius > 0 ? a.radius * pow(b.radius / a.radius, t) : a.radius + (b.radius - a.radius) * t
        return TravelGlobeCamera(longitude: longitude, latitude: a.latitude + (b.latitude - a.latitude) * t, radius: radius)
    }
}
