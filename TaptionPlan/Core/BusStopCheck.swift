import CoreLocation
import Foundation
import TaptionPlanEngine

/// 버스 승하차 지점이 버스정류장인지(BST1113A01, 대표 지시 「버스는 버스정류장을 잡아야지. 승하차 위치가 버스정류장인지 카카오 맵으로 확인」).
/// 카카오 키워드 검색(서버 중계 `/kakao/keyword`)으로 지점 반경 안의 정류장을 찾아 기기에 기억한다. 분류는 이 기억만 읽는다(네트워크 없이).
/// 기억 단위는 약 50m 칸이라 같은 정류장을 다시 묻지 않는다. 카카오가 답하지 않으면 아무것도 적지 않아 정차 모양 판정으로 남는다.
enum BusStopCheck {
    static let key = "busStopChecks"
    static let limit = 600
    /// 정류장으로 인정하는 거리.
    static let radiusMeters = 100
    /// 한 번 돌 때 새로 묻는 지점 수.
    static let lookupsPerRun = 6

    /// 약 50m 칸(위도·경도 0.0005도).
    static func cell(_ point: GeoPoint) -> String {
        let lat = (point.latitude / 0.0005).rounded() * 0.0005
        let lng = (point.longitude / 0.0005).rounded() * 0.0005
        return String(format: "%.4f,%.4f", lat, lng)
    }

    static func known(_ point: GeoPoint, defaults: UserDefaults = .standard) -> Bool? {
        (defaults.dictionary(forKey: key) as? [String: Bool])?[cell(point)]
    }

    static func remember(_ point: GeoPoint, isStop: Bool, defaults: UserDefaults = .standard) {
        var all = (defaults.dictionary(forKey: key) as? [String: Bool]) ?? [:]
        all[cell(point)] = isStop
        if all.count > limit { all = Dictionary(uniqueKeysWithValues: all.prefix(limit).map { ($0.key, $0.value) }) }
        defaults.set(all, forKey: key)
    }

    /// 카카오 응답에서 버스정류장인 곳이 반경 안에 있는가. 분류명에 「버스정류장」이 있거나 이름이 정류장·정류소로 끝나면 정류장이다.
    static func containsBusStop(_ data: Data, within meters: Int = radiusMeters) -> Bool? {
        struct Response: Decodable {
            struct Place: Decodable {
                let place_name: String
                let category_name: String?
                let distance: String?
            }
            let documents: [Place]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        return response.documents.contains { place in
            let near = place.distance.flatMap(Int.init).map { $0 <= meters } ?? true
            let category = place.category_name ?? ""
            let name = place.place_name.trimmingCharacters(in: .whitespaces)
            let looksLikeStop = category.contains("버스정류장") || (category.contains("정류장") && category.contains("교통"))
                || name.hasSuffix("정류장") || name.hasSuffix("정류소")
            return near && looksLikeStop
        }
    }

    /// 탑승·하차 지점: 구간 처음·끝에 가장 가까운 또렷한 GPS 점.
    static func ends(of segment: TravelSegment, readings: [SensorReading]) -> (GeoPoint, GeoPoint)? {
        let points = readings
            .filter { segment.span.contains($0.timestamp) }
            .compactMap { reading in reading.point.flatMap { $0.horizontalAccuracy <= BusRideRecognizer.maximumAccuracy ? (reading.timestamp, $0) : nil } }
            .sorted { $0.0 < $1.0 }
        guard let first = points.first?.1, let last = points.last?.1 else { return nil }
        return (first, last)
    }
}

/// 오늘의 차량·버스 구간 승하차 지점을 카카오에 물어 기억해 둔다. 다음 분류 갱신 때 `BusRideRecognizer`가 쓴다.
@MainActor
enum BusStopLookupRunner {
    private static var lastRunAt = Date.distantPast
    private static var isRunning = false

    static func run(model: AppModel, defaults: UserDefaults = .standard, now: Date = .now) async {
        guard !isRunning, now.timeIntervalSince(lastRunAt) >= 5 * 60 else { return }
        isRunning = true
        lastRunAt = now
        defer { isRunning = false }
        let data = await model.planDayDataSnapshot(for: Calendar.autoupdatingCurrent.startOfDay(for: now), forceReload: false)
        var pending: [GeoPoint] = []
        for segment in data.travel where segment.mode == .car || segment.mode == .bus {
            guard !segment.evidence.contains(where: { $0.hasPrefix(CarAudioTravelConfirmation.registeredEvidencePrefix) }),
                  let (board, alight) = BusStopCheck.ends(of: segment, readings: data.readings) else { continue }
            for point in [board, alight] where BusStopCheck.known(point, defaults: defaults) == nil
                && !pending.contains(where: { BusStopCheck.cell($0) == BusStopCheck.cell(point) }) {
                pending.append(point)
            }
        }
        var found = 0, checked = 0
        for point in pending.prefix(BusStopCheck.lookupsPerRun) {
            let center = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
            guard MapHomeKakaoSearch.isAvailable(at: center), let token = await AssistantRegistration.searchToken(),
                  var request = MapHomeKakaoSearch.request(query: "정류장", center: center, nearby: true, token: token),
                  var components = request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else { continue }
            components.queryItems = (components.queryItems ?? []).filter { $0.name != "radius" && $0.name != "size" }
                + [URLQueryItem(name: "radius", value: String(BusStopCheck.radiusMeters)), URLQueryItem(name: "size", value: "5")]
            guard let url = components.url else { continue }
            request.url = url
            guard let (body, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200, let isStop = BusStopCheck.containsBusStop(body) else { continue }
            BusStopCheck.remember(point, isStop: isStop, defaults: defaults)
            checked += 1
            if isStop { found += 1 }
        }
        if checked > 0 {
            TaptionPlanDiagnosticsLogger.shared.record("bus_stop_lookup", fields: ["checked": String(checked), "stops": String(found)])
        }
    }
}
