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
        await BusRouteLookupRunner.run(travel: data.travel, readings: data.readings, defaults: defaults)
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

/// 버스 노선 확인(BRT1113A01, 대표 지시 「버스노선 api 추가하자」, 객관식 답: 이름에 번호·요금 종류·버스 판별에도).
/// 탄 곳·내린 곳 가까운 정류소를 국토교통부 TAGO(서버 중계 `/tago/…`, 키는 서버 비밀값)로 찾고, 두 정류소를 함께 지나는 노선을 기억한다.
/// 서버에 키가 없거나 응답이 없으면 기억하지 않아 예전처럼 정차 모양·정류장만으로 판단한다.
enum BusRouteCheck {
    struct Route: Codable, Hashable, Sendable {
        var number: String
        /// TAGO 노선 종류(간선버스·지선버스·광역버스·직행좌석버스·마을버스 …).
        var kind: String
    }

    struct Stop: Equatable {
        var cityCode: String
        var nodeID: String
        var point: GeoPoint
        var name: String = ""
    }

    /// 탄 정류소·내린 정류소 이름(탑승 질문에 보인다, BCF1114A01).
    struct StopNames: Codable, Equatable { var board: String; var alight: String }
    static let namesKey = "busRouteStopNames"

    static func stopNames(_ segment: TravelSegment, defaults: UserDefaults = .standard) -> StopNames? {
        guard let data = (defaults.dictionary(forKey: namesKey) as? [String: Data])?[cacheKey(segment)] else { return nil }
        return try? JSONDecoder().decode(StopNames.self, from: data)
    }

    static func remember(_ segment: TravelSegment, names: StopNames, defaults: UserDefaults = .standard) {
        var all = (defaults.dictionary(forKey: namesKey) as? [String: Data]) ?? [:]
        all[cacheKey(segment)] = try? JSONEncoder().encode(names)
        if all.count > limit { all = Dictionary(uniqueKeysWithValues: all.sorted { $0.key > $1.key }.prefix(limit).map { ($0.key, $0.value) }) }
        defaults.set(all, forKey: namesKey)
    }

    static let key = "busRouteChecks"
    static let limit = 200
    /// 정류소로 인정하는 거리.
    static let stopRadiusMeters = 50.0

    static func cacheKey(_ segment: TravelSegment) -> String {
        BusStopCheck.cacheKey(.board, segment: segment) + "~" + BusStopCheck.cacheKey(.alight, segment: segment)
    }

    /// 찾은 공통 노선. nil이면 아직 모름, 빈 배열이면 두 정류소를 함께 지나는 노선이 없다.
    static func known(_ segment: TravelSegment, defaults: UserDefaults = .standard) -> [Route]? {
        guard let data = (defaults.dictionary(forKey: key) as? [String: Data])?[cacheKey(segment)] else { return nil }
        return try? JSONDecoder().decode([Route].self, from: data)
    }

    static func remember(_ segment: TravelSegment, routes: [Route], defaults: UserDefaults = .standard) {
        var all = (defaults.dictionary(forKey: key) as? [String: Data]) ?? [:]
        all[cacheKey(segment)] = try? JSONEncoder().encode(routes)
        if all.count > limit { all = Dictionary(uniqueKeysWithValues: all.sorted { $0.key > $1.key }.prefix(limit).map { ($0.key, $0.value) }) }
        defaults.set(all, forKey: key)
    }

    /// 두 정류소를 함께 지나는 노선(번호 순).
    static func common(_ board: [Route], _ alight: [Route]) -> [Route] {
        let numbers = Set(alight.map(\.number))
        return Array(Set(board.filter { numbers.contains($0.number) })).sorted { $0.number.localizedStandardCompare($1.number) == .orderedAscending }
    }

    /// 「버스 · 80번」. 노선이 셋 넘게 겹치면 번호를 적지 않는다.
    static func title(_ routes: [Route]) -> String {
        guard !routes.isEmpty, routes.count <= 2 else { return "버스" }
        return "버스 · " + routes.map { "\($0.number)번" }.joined(separator: "·")
    }

    /// 요금표 수단. 노선 종류가 여럿이면 가장 싼 쪽(간선·지선)으로 본다.
    static func fareMode(_ routes: [Route]) -> String {
        let kinds = Set(routes.map(\.kind))
        if kinds.isEmpty || kinds.contains(where: { !$0.contains("광역") && !$0.contains("좌석") }) { return "서울_간선지선" }
        if kinds.allSatisfy({ $0.contains("광역") }) { return "서울_광역" }
        return "경기_직행좌석"
    }

    // MARK: TAGO 응답(items.item은 하나면 객체, 여럿이면 배열이고 숫자가 문자열·숫자로 섞여 온다)

    /// 정상 응답인가. 키가 그 서비스에 등록되지 않은 오류도 200으로 올 수 있어, 결과 코드를 봐야 「없음」을 믿는다.
    /// TAGO는 header.resultCode "00", 서울은 msgHeader.headerCd "0"(정상)·"4"(결과 없음).
    static func isValid(_ data: Data, seoul: Bool) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if seoul {
            return ["0", "4"].contains(text((root["msgHeader"] as? [String: Any])?["headerCd"]) ?? "")
        }
        return text(((root["response"] as? [String: Any])?["header"] as? [String: Any])?["resultCode"]) == "00"
    }

    private static func items(_ data: Data) -> [[String: Any]] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = (root["response"] as? [String: Any])?["body"] as? [String: Any],
              let items = body["items"] as? [String: Any] else { return [] }
        if let list = items["item"] as? [[String: Any]] { return list }
        if let one = items["item"] as? [String: Any] { return [one] }
        return []
    }

    private static func text(_ value: Any?) -> String? {
        switch value {
        case let string as String: string.trimmingCharacters(in: .whitespaces).isEmpty ? nil : string.trimmingCharacters(in: .whitespaces)
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }

    static func stops(_ data: Data) -> [Stop] {
        items(data).compactMap { item in
            guard let city = text(item["citycode"]), let node = text(item["nodeid"]),
                  let lat = text(item["gpslati"]).flatMap(Double.init), let lng = text(item["gpslong"]).flatMap(Double.init) else { return nil }
            return Stop(cityCode: city, nodeID: node, point: GeoPoint(latitude: lat, longitude: lng, altitude: 0, horizontalAccuracy: 0, verticalAccuracy: 0),
                        name: text(item["nodenm"]) ?? "")
        }
    }

    static func routes(_ data: Data) -> [Route] {
        items(data).compactMap { item in
            text(item["routeno"]).map { Route(number: $0, kind: text(item["routetp"]) ?? "") }
        }
    }

    // MARK: 서울특별시 정류소정보(BRT1113B01). msgBody.itemList는 하나면 객체, 없으면 null로 온다.

    /// 서울 정류소의 도시 코드 자리. 노선은 정류소 고유번호(arsId)로 찾는다.
    static let seoulCity = "seoul"

    private static func seoulItems(_ data: Data) -> [[String: Any]] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = root["msgBody"] as? [String: Any] else { return [] }
        if let list = body["itemList"] as? [[String: Any]] { return list }
        if let one = body["itemList"] as? [String: Any] { return [one] }
        return []
    }

    static func seoulStops(_ data: Data) -> [Stop] {
        seoulItems(data).compactMap { item in
            guard let ars = text(item["arsId"]), ars.count == 5, ars != "00000",
                  let lng = text(item["gpsX"]).flatMap(Double.init), let lat = text(item["gpsY"]).flatMap(Double.init) else { return nil }
            return Stop(cityCode: seoulCity, nodeID: ars, point: GeoPoint(latitude: lat, longitude: lng, altitude: 0, horizontalAccuracy: 0, verticalAccuracy: 0),
                        name: text(item["stationNm"]) ?? "")
        }
    }

    /// 서울 노선 유형 번호 → 이름(1 공항, 2 마을, 3 간선, 4 지선, 5 순환, 6 광역, 7 인천, 8 경기).
    static func seoulKind(_ code: String?) -> String {
        switch code {
        case "1": "공항버스"
        case "2": "마을버스"
        case "3": "간선버스"
        case "4": "지선버스"
        case "5": "순환버스"
        case "6": "광역버스"
        case "7": "인천버스"
        case "8": "경기버스"
        default: ""
        }
    }

    static func seoulRoutes(_ data: Data) -> [Route] {
        seoulItems(data).compactMap { item in
            text(item["busRouteNm"]).map { Route(number: $0, kind: seoulKind(text(item["busRouteType"]))) }
        }
    }

    /// 점들에서 가장 가까운 정류소(반경 안).
    static func nearest(_ stops: [Stop], to points: [GeoPoint]) -> Stop? {
        stops.compactMap { stop -> (Stop, Double)? in
            let meters = points.map { distanceMeters($0, stop.point) }.min() ?? .infinity
            return meters <= stopRadiusMeters ? (stop, meters) : nil
        }.min { $0.1 < $1.1 }?.0
    }
}

/// 정류장 확인 뒤에 이어서 부른다. 승하차 둘 다 정류장인 차량·버스 구간만 노선을 찾는다(호출 수를 아끼려고).
@MainActor
enum BusRouteLookupRunner {
    static func run(travel: [TravelSegment], readings: [SensorReading], defaults: UserDefaults = .standard) async {
        guard let host = TripRelay.host else { return }
        var token: String?
        var checked = 0, found = 0
        for segment in travel where (segment.mode == .car || segment.mode == .bus) && BusRouteCheck.known(segment, defaults: defaults) == nil {
            guard BusStopCheck.known(.board, segment: segment, defaults: defaults) == true,
                  BusStopCheck.known(.alight, segment: segment, defaults: defaults) == true else { continue }
            if token == nil { token = await AssistantRegistration.searchToken() }
            guard let token else { return }
            let boardPoints = BusStopCheck.points(.board, segment: segment, readings: readings)
            let alightPoints = BusStopCheck.points(.alight, segment: segment, readings: readings)
            guard let boardCenter = boardPoints.last, let alightCenter = alightPoints.first else { continue }
            guard let boardFound = await nearestStop(host: host, center: boardCenter, points: boardPoints, token: token),
                  let alightFound = await nearestStop(host: host, center: alightCenter, points: alightPoints, token: token) else { return }
            guard let board = boardFound, let alight = alightFound else {
                BusRouteCheck.remember(segment, routes: [], defaults: defaults)
                checked += 1
                continue
            }
            guard let boardRoutes = await routes(host: host, stop: board, token: token),
                  let alightRoutes = await routes(host: host, stop: alight, token: token) else { return }
            let common = BusRouteCheck.common(boardRoutes, alightRoutes)
            BusRouteCheck.remember(segment, routes: common, defaults: defaults)
            if !board.name.isEmpty, !alight.name.isEmpty {
                BusRouteCheck.remember(segment, names: .init(board: board.name, alight: alight.name), defaults: defaults)
            }
            checked += 1
            if !common.isEmpty { found += 1 }
        }
        if checked > 0 {
            TaptionPlanDiagnosticsLogger.shared.record("bus_route_lookup", fields: ["checked": String(checked), "found": String(found)])
        }
    }

    /// 가장 가까운 정류소. 전국(TAGO)에서 못 찾으면 서울시 정류소정보로 본다. 응답이 없으면 nil, 정류소가 없으면 .some(nil).
    private static func nearestStop(host: String, center: GeoPoint, points: [GeoPoint], token: String) async -> BusRouteCheck.Stop?? {
        let query = ["lat": String(center.latitude), "lng": String(center.longitude)]
        let national = await fetch(host: host, path: "/tago/stops", query: query, token: token).flatMap { BusRouteCheck.isValid($0, seoul: false) ? $0 : nil }
        if let national, let stop = BusRouteCheck.nearest(BusRouteCheck.stops(national), to: points) { return .some(stop) }
        let seoul = await fetch(host: host, path: "/seoul/stops", query: query, token: token).flatMap { BusRouteCheck.isValid($0, seoul: true) ? $0 : nil }
        if let seoul, let stop = BusRouteCheck.nearest(BusRouteCheck.seoulStops(seoul), to: points) { return .some(stop) }
        return national == nil && seoul == nil ? nil : .some(nil)
    }

    private static func routes(host: String, stop: BusRouteCheck.Stop, token: String) async -> [BusRouteCheck.Route]? {
        if stop.cityCode == BusRouteCheck.seoulCity {
            return await fetch(host: host, path: "/seoul/routes", query: ["arsId": stop.nodeID], token: token)
                .flatMap { BusRouteCheck.isValid($0, seoul: true) ? BusRouteCheck.seoulRoutes($0) : nil }
        }
        return await fetch(host: host, path: "/tago/routes", query: ["cityCode": stop.cityCode, "nodeId": stop.nodeID], token: token)
            .flatMap { BusRouteCheck.isValid($0, seoul: false) ? BusRouteCheck.routes($0) : nil }
    }

    /// 서버에 키가 없거나(503) 실패하면 nil — 기억하지 않고 다음에 다시 본다.
    private static func fetch(host: String, path: String, query: [String: String], token: String) async -> Data? {
        guard var components = URLComponents(string: "https://\(host)\(path)") else { return nil }
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
}

/// 탈것 탑승 질문(BCF1114A01, 대표 지시 「버스를 탄 경우 지하철과 동일하게 정류소 물어보고 확정… 자전거·기차·배·비행기 동일」).
/// 지하철은 역 탑승 확인(`TransitBoardingCandidate`)이 따로 있어, 여기서는 그 밖의 탈것 구간을 사용자가 확정하지 않았을 때 묻는다.
/// 버스: 버스로 판정됐거나, 차량인데 승하차가 둘 다 정류소인 구간. 기차·배·비행기·자전거: 그렇게 판정된 구간.
enum RideConfirmation {
    static let minimumDuration: TimeInterval = 3 * 60
    static let askable: Set<TravelMode> = [.bus, .train, .ship, .airplane, .cycling]

    static func needsAnswer(_ segment: TravelSegment, corrections: [TravelModeCorrection], stopDefaults: UserDefaults = .standard) -> Bool {
        guard !segment.isConfirmed, segment.span.duration >= minimumDuration,
              !segment.evidence.contains(where: { $0.hasPrefix("사용자 확인") || $0.hasPrefix(CarAudioTravelConfirmation.matchedEvidencePrefix) }),
              !corrections.contains(where: { $0.span.overlapsMostly(segment.span) }) else { return false }
        if askable.contains(segment.mode) { return true }
        // 차량으로 남았지만 탄 곳·내린 곳이 둘 다 정류소면 버스였을 수 있다.
        return segment.mode == .car
            && BusStopCheck.known(.board, segment: segment, defaults: stopDefaults) == true
            && BusStopCheck.known(.alight, segment: segment, defaults: stopDefaults) == true
    }

    /// 물어볼 구간 번호(시각순).
    static func pending(_ travel: [TravelSegment], corrections: [TravelModeCorrection], stopDefaults: UserDefaults = .standard) -> [String] {
        travel.filter { needsAnswer($0, corrections: corrections, stopDefaults: stopDefaults) }
            .sorted { $0.span.start < $1.span.start }
            .map(\.id.uuidString)
    }

    /// 질문에서 고를 버스 노선(최대 6개, 번호순). 두 정류소를 함께 지나는 노선.
    static func routeChoices(_ segment: TravelSegment, stopDefaults: UserDefaults = .standard) -> [BusRouteCheck.Route] {
        Array((BusRouteCheck.known(segment, defaults: stopDefaults) ?? []).prefix(6))
    }
}

/// 사용자나 AI가 정해 준 지하철 노선(RDQ1114A01). 구간에 노선 경로가 없을 때 이름표에 쓴다. 기기에만 둔다.
enum SubwayLineChoice {
    static let key = "subwayLineChoices"
    static let limit = 200

    static func known(_ segment: TravelSegment, defaults: UserDefaults = .standard) -> String? {
        (defaults.dictionary(forKey: key) as? [String: String])?[BusRouteCheck.cacheKey(segment)]
    }

    static func remember(_ segment: TravelSegment, line: String, defaults: UserDefaults = .standard) {
        var all = (defaults.dictionary(forKey: key) as? [String: String]) ?? [:]
        all[BusRouteCheck.cacheKey(segment)] = line
        if all.count > limit { all = Dictionary(uniqueKeysWithValues: all.sorted { $0.key > $1.key }.prefix(limit).map { ($0.key, $0.value) }) }
        defaults.set(all, forKey: key)
    }

    /// 고를 노선. 근거에 역 이름이 있으면 그 역을 지나는 노선, 없으면 노선 목록 앞쪽(최대 12개).
    static func candidates(_ segment: TravelSegment) -> [String] {
        let evidence = segment.evidence.joined(separator: " ")
        var lines: [String] = []
        for station in SubwayStationCatalog.stations where evidence.contains(station.stationName) && !lines.contains(station.lineName) { lines.append(station.lineName) }
        if lines.isEmpty {
            for station in SubwayStationCatalog.stations where !lines.contains(station.lineName) { lines.append(station.lineName) }
        }
        return Array(lines.prefix(12))
    }
}

/// 번호·노선을 못 정한 버스·지하철 구간을 연결된 AI에게 먼저 맡긴다(RDQ1114A01). 구간마다 한 번만.
@MainActor
enum RideLineTasks {
    static let producedKey = "rideLineTaskKeys"
    nonisolated static let settleSeconds: TimeInterval = 10 * 60
    /// 이보다 오래된 구간은 맡기지 않는다. 불러 둔 지난 기록 전체가 한꺼번에 올라가 AI 목록을 채운 적이 있다(RDX1114A01).
    nonisolated static let recentSeconds: TimeInterval = 36 * 3_600
    /// 한 번에 맡기는 수.
    static let batchLimit = 3

    /// AI에게 맡길 구간인지와 후보. 버스는 노선을 모르거나 후보가 셋 이상, 지하철은 노선 경로도 정해 준 노선도 없을 때.
    nonisolated static func candidates(_ segment: TravelSegment, defaults: UserDefaults = .standard) -> [String]? {
        // 배워 둔 규칙으로 정해지는 구간은 맡기지 않는다(AIX1114A01 P3).
        if let names = BusRouteCheck.stopNames(segment, defaults: defaults), segment.mode == .bus || segment.mode == .subway,
           RuleEngine.rideLine(board: names.board, alight: names.alight, mode: segment.mode == .bus ? "bus" : "subway", rules: AssistantRuleSnapshot.rules) != nil { return nil }
        switch segment.mode {
        case .bus:
            let routes = BusRouteCheck.known(segment, defaults: defaults)
            if let routes, (1...2).contains(routes.count) { return nil }
            return (routes ?? []).prefix(8).map(\.number)
        case .subway:
            guard (segment.subwayRoute?.lineNames ?? []).isEmpty, SubwayLineChoice.known(segment, defaults: defaults) == nil else { return nil }
            return SubwayLineChoice.candidates(segment)
        default:
            return nil
        }
    }

    static func enqueue(_ travel: [TravelSegment], now: Date = .now, defaults: UserDefaults = .standard) {
        var produced = defaults.stringArray(forKey: producedKey) ?? []
        var sent = 0
        for segment in pending(travel, now: now) {
            guard sent < batchLimit else { break }
            let key = BusRouteCheck.cacheKey(segment)
            guard !produced.contains(key), let candidates = candidates(segment, defaults: defaults) else { continue }
            let time = "\(clock(segment.span.start))–\(clock(segment.span.end))"
            var context = ["moveId": segment.id.uuidString, "mode": segment.mode == .bus ? "bus" : "subway", "start": clock(segment.span.start), "end": clock(segment.span.end)]
            if !candidates.isEmpty { context["candidates"] = candidates.joined(separator: ",") }
            var text = segment.mode == .bus ? "\(time) bus ride, route number unknown" : "\(time) subway ride, line unknown"
            if segment.mode == .bus, let names = BusRouteCheck.stopNames(segment, defaults: defaults) {
                context["from"] = names.board
                context["to"] = names.alight
                text += " · \(names.board) → \(names.alight)"
            }
            guard AITaskQueue.enqueue(.routeCheck, text: text, day: segment.span.start, context: context, defaults: defaults) else { break }
            produced.append(key)
            sent += 1
        }
        if sent > 0 { defaults.set(Array(produced.suffix(200)), forKey: producedKey) }
    }

    /// 맡길 만한 구간: 끝난 지 10분은 넘고 36시간은 안 된, 3분 넘는 탑승. 새것부터.
    nonisolated static func pending(_ travel: [TravelSegment], now: Date) -> [TravelSegment] {
        travel.filter {
            let age = now.timeIntervalSince($0.span.end)
            return age >= settleSeconds && age <= recentSeconds && $0.span.duration >= RideConfirmation.minimumDuration && $0.span.duration <= 4 * 3_600
        }
        .sorted { $0.span.end > $1.span.end }
    }

    private static func clock(_ date: Date) -> String {
        let parts = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}
