import Foundation
import TaptionPlanEngine

/// 버스 승하차 지점이 버스정류장인지(BST1113A01, 대표 지시 「버스는 버스정류장을 잡아야지」 → 「오픈맵에 버스 정류장 나오던데」).
/// 앱의 벡터 지도(OpenFreeMap, 오픈스트리트맵)가 이미 받는 z14 타일의 `poi` 층에서 `bus_stop`을 꺼내 쓴다. 따로 묻는 곳이 없고,
/// 본 지역은 기기 타일 저장소에서 바로 읽는다. 2026-11-13 대표 원본으로 맞춘 값: 버스는 탑승 3m·하차 1m, 집은 정류장에서 91m.
/// 도로 위에는 정류장이 많아(아침 운전 도착 11m) 정류장만으로 버스라 하지 않고, 내 차 연결이 없을 때만 쓴다(`BusRideRecognizer`).
enum BusStopCheck {
    static let key = "busStopChecks"
    static let limit = 400
    /// 정류장으로 인정하는 거리.
    static let radiusMeters = 30.0
    /// 탑승은 구간 시작 3분 전~1분 뒤(정류장에서 기다린 때), 하차는 끝 1분 전~2분 뒤를 본다.
    static let boardWindow: ClosedRange<TimeInterval> = -180...60
    static let alightWindow: ClosedRange<TimeInterval> = -60...120
    static let zoom = 14

    enum End: String { case board = "b", alight = "a" }

    /// 구간 끝마다 분 단위로 기억한다. 다시 분류해도 시각이 거의 같아 같은 칸을 읽는다.
    static func cacheKey(_ end: End, segment: TravelSegment) -> String {
        let time = end == .board ? segment.span.start : segment.span.end
        return "\(end.rawValue)|\(Int(time.timeIntervalSince1970 / 60))"
    }

    static func known(_ end: End, segment: TravelSegment, defaults: UserDefaults = .standard) -> Bool? {
        (defaults.dictionary(forKey: key) as? [String: Bool])?[cacheKey(end, segment: segment)]
    }

    static func remember(_ end: End, segment: TravelSegment, isStop: Bool, defaults: UserDefaults = .standard) {
        var all = (defaults.dictionary(forKey: key) as? [String: Bool]) ?? [:]
        all[cacheKey(end, segment: segment)] = isStop
        if all.count > limit {
            let newest = all.keys.sorted { ($0.split(separator: "|").last.flatMap { Int($0) } ?? 0) > ($1.split(separator: "|").last.flatMap { Int($0) } ?? 0) }
            all = all.filter { newest.prefix(limit).contains($0.key) }
        }
        defaults.set(all, forKey: key)
    }

    /// 구간 끝 앞뒤 창 안의 또렷한 GPS 점.
    static func points(_ end: End, segment: TravelSegment, readings: [SensorReading]) -> [GeoPoint] {
        let anchor = end == .board ? segment.span.start : segment.span.end
        let window = end == .board ? boardWindow : alightWindow
        return readings.compactMap { reading in
            guard window.contains(reading.timestamp.timeIntervalSince(anchor)), let point = reading.point,
                  point.horizontalAccuracy <= BusRideRecognizer.maximumAccuracy else { return nil }
            return point
        }
    }

    static func isNearStop(_ points: [GeoPoint], stops: [GeoPoint]) -> Bool {
        points.contains { point in stops.contains { distanceMeters(point, $0) <= radiusMeters } }
    }

    // MARK: 지도 타일

    struct TileID: Hashable { let x: Int, y: Int }

    static func tile(_ point: GeoPoint) -> TileID {
        let n = Double(1 << zoom), lat = point.latitude * .pi / 180
        let x = Int(((point.longitude + 180) / 360 * n).rounded(.down))
        let y = Int(((1 - log(tan(lat) + 1 / cos(lat)) / .pi) / 2 * n).rounded(.down))
        return TileID(x: x, y: y)
    }

    /// 점 둘레 반경이 닿는 타일들(가장자리면 옆 타일까지).
    static func tiles(around point: GeoPoint) -> Set<TileID> {
        let metersPerDegree = 111_320.0
        let dLat = radiusMeters / metersPerDegree, dLng = radiusMeters / (metersPerDegree * max(0.2, cos(point.latitude * .pi / 180)))
        var result = Set<TileID>()
        for lat in [point.latitude - dLat, point.latitude + dLat] {
            for lng in [point.longitude - dLng, point.longitude + dLng] {
                result.insert(tile(GeoPoint(latitude: lat, longitude: lng, altitude: 0, horizontalAccuracy: 0, verticalAccuracy: 0)))
            }
        }
        return result
    }

    /// z14 벡터 타일(Mapbox Vector Tile)의 `poi` 층에서 `subclass=bus_stop` 점을 꺼낸다. 틀린 바이트면 빈 배열.
    static func busStops(inTile raw: Data, id: TileID) -> [GeoPoint] {
        guard let data = inflated(raw) else { return [] }
        var stops: [GeoPoint] = []
        var tile = ProtoReader(data)
        while let (field, value) = tile.next() {
            guard field == 3, case let .bytes(layerBytes) = value else { continue }
            stops += layerStops(layerBytes, id: id)
        }
        return stops
    }

    private static func layerStops(_ bytes: Data, id: TileID) -> [GeoPoint] {
        var reader = ProtoReader(bytes)
        var name = "", keys: [String] = [], values: [String?] = [], features: [Data] = [], extent = 4096.0
        while let (field, value) = reader.next() {
            switch (field, value) {
            case (1, .bytes(let text)): name = String(decoding: text, as: UTF8.self)
            case (2, .bytes(let feature)): features.append(feature)
            case (3, .bytes(let text)): keys.append(String(decoding: text, as: UTF8.self))
            case (4, .bytes(let raw)):
                var inner = ProtoReader(raw)
                if let (_, item) = inner.next(), case let .bytes(text) = item { values.append(String(decoding: text, as: UTF8.self)) } else { values.append(nil) }
            case (5, .varint(let size)): extent = Double(size)
            default: break
            }
        }
        guard name == "poi", let subclass = keys.firstIndex(of: "subclass") else { return [] }
        let n = Double(1 << zoom)
        return features.compactMap { bytes -> GeoPoint? in
            var reader = ProtoReader(bytes)
            var tags: [UInt64] = [], geometry: [UInt64] = []
            while let (field, value) = reader.next() {
                if field == 2, case let .bytes(packed) = value { tags = ProtoReader.packed(packed) }
                if field == 4, case let .bytes(packed) = value { geometry = ProtoReader.packed(packed) }
            }
            var isStop = false
            for index in stride(from: 0, to: tags.count - 1, by: 2) where Int(tags[index]) == subclass {
                let valueIndex = Int(tags[index + 1])
                isStop = values.indices.contains(valueIndex) && values[valueIndex] == "bus_stop"
            }
            // 점 하나: MoveTo(1) 명령 뒤 zigzag x, y.
            guard isStop, geometry.count >= 3, geometry[0] & 0x7 == 1 else { return nil }
            let px = Double(ProtoReader.zigzag(geometry[1])), py = Double(ProtoReader.zigzag(geometry[2]))
            let longitude = (Double(id.x) + px / extent) / n * 360 - 180
            let mercator = .pi * (1 - 2 * (Double(id.y) + py / extent) / n)
            let latitude = atan(sinh(mercator)) * 180 / .pi
            return GeoPoint(latitude: latitude, longitude: longitude, altitude: 0, horizontalAccuracy: 0, verticalAccuracy: 0)
        }
    }

    /// 서버가 gzip 그대로 준 타일이면 풀어 준다(보통은 URLSession이 이미 푼다).
    static func inflated(_ data: Data) -> Data? {
        guard data.count > 18, data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b else { return data }
        var start = data.startIndex + 10
        let flags = data[data.startIndex + 3]
        if flags & 0x04 != 0, data.count > start + 2 { start += 2 + Int(data[start]) + Int(data[start + 1]) << 8 }
        if flags & 0x08 != 0 { while start < data.endIndex, data[start] != 0 { start += 1 }; start += 1 }
        if flags & 0x10 != 0 { while start < data.endIndex, data[start] != 0 { start += 1 }; start += 1 }
        if flags & 0x02 != 0 { start += 2 }
        guard start < data.endIndex - 8 else { return nil }
        return try? (data[start..<(data.endIndex - 8)] as NSData).decompressed(using: .zlib) as Data
    }
}

/// 작은 protobuf 읽개(벡터 타일용). 길이 붙은 값과 varint만 다룬다.
struct ProtoReader {
    enum Value { case varint(UInt64), bytes(Data), skip }

    private let data: Data
    private var index: Data.Index

    init(_ data: Data) {
        self.data = data
        index = data.startIndex
    }

    mutating func varint() -> UInt64? {
        var result: UInt64 = 0, shift: UInt64 = 0
        while index < data.endIndex, shift < 64 {
            let byte = data[index]
            index += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte < 0x80 { return result }
            shift += 7
        }
        return nil
    }

    mutating func next() -> (Int, Value)? {
        guard index < data.endIndex, let key = varint() else { return nil }
        switch key & 0x7 {
        case 0: return varint().map { (Int(key >> 3), .varint($0)) }
        case 2:
            guard let length = varint(), let end = data.index(index, offsetBy: Int(length), limitedBy: data.endIndex) else { return nil }
            defer { index = end }
            return (Int(key >> 3), .bytes(data[index..<end]))
        case 1:
            guard data.distance(from: index, to: data.endIndex) >= 8 else { return nil }
            index += 8
            return (Int(key >> 3), .skip)
        case 5:
            guard data.distance(from: index, to: data.endIndex) >= 4 else { return nil }
            index += 4
            return (Int(key >> 3), .skip)
        default: return nil
        }
    }

    static func packed(_ data: Data) -> [UInt64] {
        var reader = ProtoReader(data), values: [UInt64] = []
        while let value = reader.varint() { values.append(value) }
        return values
    }

    static func zigzag(_ value: UInt64) -> Int64 { Int64(value >> 1) ^ -Int64(value & 1) }
}

/// 오늘의 차량·버스 구간 끝이 정류장인지 지도 타일로 확인해 기억해 둔다. 다음 분류 갱신 때 `BusRideRecognizer`가 쓴다.
@MainActor
enum BusStopLookupRunner {
    private static var lastRunAt = Date.distantPast
    private static var isRunning = false
    private static var tileTemplate: String?

    static func run(model: AppModel, defaults: UserDefaults = .standard, now: Date = .now) async {
        guard !isRunning, now.timeIntervalSince(lastRunAt) >= 5 * 60 else { return }
        isRunning = true
        lastRunAt = now
        defer { isRunning = false }
        let data = await model.planDayDataSnapshot(for: Calendar.autoupdatingCurrent.startOfDay(for: now), forceReload: false)
        var tiles: [BusStopCheck.TileID: [GeoPoint]] = [:]
        var checked = 0, found = 0
        for segment in data.travel where segment.mode == .car || segment.mode == .bus {
            guard !segment.evidence.contains(where: { $0.hasPrefix(CarAudioTravelConfirmation.registeredEvidencePrefix) }) else { continue }
            for end in [BusStopCheck.End.board, .alight] where BusStopCheck.known(end, segment: segment, defaults: defaults) == nil {
                let points = BusStopCheck.points(end, segment: segment, readings: data.readings)
                guard !points.isEmpty else { continue }
                var stops: [GeoPoint] = []
                var complete = true
                for id in Set(points.flatMap { BusStopCheck.tiles(around: $0) }) {
                    if tiles[id] == nil { tiles[id] = await load(id) }
                    guard let loaded = tiles[id] else { complete = false; continue }
                    stops += loaded
                }
                let isStop = BusStopCheck.isNearStop(points, stops: stops)
                // 타일을 못 받았는데 정류장도 못 찾았으면 적지 않고 다음에 다시 본다.
                guard isStop || complete else { continue }
                BusStopCheck.remember(end, segment: segment, isStop: isStop, defaults: defaults)
                checked += 1
                if isStop { found += 1 }
            }
        }
        if checked > 0 {
            TaptionPlanDiagnosticsLogger.shared.record("bus_stop_lookup", fields: ["checked": String(checked), "stops": String(found)])
        }
    }

    /// 지도와 같은 저장소를 거쳐 타일을 읽는다(본 지역은 기기에서 바로). 못 받으면 nil.
    private static func load(_ id: BusStopCheck.TileID) async -> [GeoPoint]? {
        if tileTemplate == nil,
           let loaded = try? await OfflineVectorTileCache.shared.load(URLRequest(url: OfflineVectorResources.tileJSONURL)),
           let json = try? JSONSerialization.jsonObject(with: loaded.data) as? [String: Any] {
            tileTemplate = (json["tiles"] as? [String])?.first
        }
        guard let template = tileTemplate,
              let url = URL(string: template.replacingOccurrences(of: "{z}", with: String(BusStopCheck.zoom))
                .replacingOccurrences(of: "{x}", with: String(id.x)).replacingOccurrences(of: "{y}", with: String(id.y))),
              let loaded = try? await OfflineVectorTileCache.shared.load(URLRequest(url: url)),
              loaded.response.statusCode == 200 else { return nil }
        return BusStopCheck.busStops(inTile: loaded.data, id: id)
    }
}
