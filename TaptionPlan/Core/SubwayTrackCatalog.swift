import Foundation

/// 같은 노선 이웃 역 사이의 실제 선로 모양(SUB1106A02). 자료는 `SubwayTrackData`(OSM, ODbL)이고
/// `scripts/subway-tracks/build.py`가 만든다. 선로가 없는 역 쌍은 예전처럼 직선이다.
enum SubwayTrackCatalog {
    private struct Key: Hashable {
        let fromLatitude: Int
        let fromLongitude: Int
        let toLatitude: Int
        let toLongitude: Int
    }

    private static let tracks: [Key: [GeoPoint]] = decode(SubwayTrackData.packed)

    /// 역 좌표를 이은 점들 사이에 선로 모양을 끼운다. 역이 아닌 점은 그대로 둔다.
    static func following(_ points: [GeoPoint]) -> [GeoPoint] {
        guard points.count >= 2 else { return points }
        var result = [points[0]]
        for (from, to) in zip(points, points.dropFirst()) {
            if let track = track(from: from, to: to), track.count > 2 {
                result += track.dropFirst()
            } else {
                result.append(to)
            }
        }
        return result
    }

    /// 두 역 사이 선로. 양 끝은 두 역 좌표 그대로다.
    static func track(from: GeoPoint, to: GeoPoint) -> [GeoPoint]? {
        let a = (quantized(from.latitude), quantized(from.longitude))
        let b = (quantized(to.latitude), quantized(to.longitude))
        if let forward = tracks[Key(fromLatitude: a.0, fromLongitude: a.1, toLatitude: b.0, toLongitude: b.1)] {
            return [from] + Array(forward.dropFirst().dropLast()) + [to]
        }
        if let backward = tracks[Key(fromLatitude: b.0, fromLongitude: b.1, toLatitude: a.0, toLongitude: a.1)] {
            let inner: [GeoPoint] = Array(backward.reversed())
            return [from] + Array(inner.dropFirst().dropLast()) + [to]
        }
        return nil
    }

    static func quantized(_ value: Double) -> Int {
        Int((value * 100_000 + 0.5).rounded(.down))
    }

    private static func decode(_ text: String) -> [Key: [GeoPoint]] {
        var result: [Key: [GeoPoint]] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2 else { continue }
            let numbers = fields[0].split(separator: ",").compactMap { Int($0) }
            guard numbers.count == 4 else { continue }
            let points = polyline(fields[1])
            guard points.count >= 2 else { continue }
            result[Key(fromLatitude: numbers[0], fromLongitude: numbers[1], toLatitude: numbers[2], toLongitude: numbers[3])] = points
        }
        return result
    }

    /// Google polyline(1e-5) 풀기.
    static func polyline(_ text: Substring) -> [GeoPoint] {
        var points: [GeoPoint] = []
        var latitude = 0, longitude = 0
        var iterator = text.utf8.makeIterator()
        func next() -> Int? {
            var result = 0, shift = 0
            while let byte = iterator.next() {
                let value = Int(byte) - 63
                result |= (value & 0x1F) << shift
                shift += 5
                if value < 0x20 { return (result & 1) != 0 ? ~(result >> 1) : result >> 1 }
            }
            return nil
        }
        while let dLat = next(), let dLon = next() {
            latitude += dLat
            longitude += dLon
            points.append(GeoPoint(
                latitude: Double(latitude) / 100_000,
                longitude: Double(longitude) / 100_000,
                altitude: 0,
                horizontalAccuracy: -1,
                verticalAccuracy: -1
            ))
        }
        return points
    }
}
