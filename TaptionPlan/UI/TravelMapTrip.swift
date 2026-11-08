import CoreLocation
import Foundation

/// 도시 여행 지도 영상의 구간 이동 수단(TRV1108A01). 기록의 `TravelMode`를 영상에 쓸 만큼만 줄인다.
enum TravelMapMode: String, Codable, CaseIterable, Hashable, Sendable {
    case walk, car, bus, subway, train, ship, flight

    init(_ mode: TravelMode) {
        switch mode {
        case .walking, .running, .cycling: self = .walk
        case .bus: self = .bus
        case .subway: self = .subway
        case .taxi, .car: self = .car
        case .train: self = .train
        case .airplane: self = .flight
        case .ship: self = .ship
        }
    }

    var symbolName: String {
        switch self {
        case .walk: "figure.walk"
        case .car: "car.fill"
        case .bus: "bus.fill"
        case .subway: "tram.fill"
        case .train: "train.side.front.car"
        case .ship: "ferry.fill"
        case .flight: "airplane"
        }
    }

    func title(_ language: MapHomeLanguage) -> String {
        switch self {
        case .walk: language.text("걷기", "Walk")
        case .car: language.text("자동차", "Car")
        case .bus: language.text("버스", "Bus")
        case .subway: language.text("지하철", "Subway")
        case .train: language.text("기차", "Train")
        case .ship: language.text("배", "Ship")
        case .flight: language.text("비행기", "Flight")
        }
    }

    /// 기록이 없거나 직접 넣을 때의 첫 값. 멀면 비행기, 중간이면 기차, 가까우면 자동차.
    static func guess(meters: Double) -> Self {
        if meters >= 350_000 { return .flight }
        return meters >= 80_000 ? .train : .car
    }
}

/// 여행 중 한 도시. 첫 도시의 `arrivalMode`는 쓰지 않는다.
struct TravelMapStop: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
    var date: Date
    /// 앞 도시에서 여기까지 온 수단.
    var arrivalMode: TravelMapMode = .car
    /// 기록으로 잰 앞 도시에서의 이동 거리. 없으면 직선 거리를 쓴다.
    var arrivalMeters: Double?

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    var point: MapHomeRangeTripPlan.Point { MapHomeRangeTripPlan.Point(latitude: latitude, longitude: longitude) }
}

/// 도시 여행 하나. 기록에서 뽑거나 사용자가 직접 넣는다. 활동 기록이 아니라 SQLite에 넣지 않는다.
struct TravelMapTrip: Codable, Hashable, Sendable {
    var stops: [TravelMapStop] = []

    var isRenderable: Bool { stops.count >= 2 }

    /// `index`번 도시로 들어온 구간의 거리(m). 첫 도시는 0.
    func legMeters(arrivingAt index: Int) -> Double {
        guard index > 0, index < stops.count else { return 0 }
        let straight = MapHomeRangeTripPlan.meters(stops[index - 1].point, stops[index].point)
        return max(straight, stops[index].arrivalMeters ?? 0)
    }

    var totalMeters: Double { stops.indices.reduce(0) { $0 + legMeters(arrivingAt: $1) } }

    var firstDate: Date? { stops.map(\.date).min() }
    var lastDate: Date? { stops.map(\.date).max() }

    /// 도시를 덧붙인다. 날짜는 앞 도시 다음 날, 수단은 거리로 고른다.
    mutating func append(name: String, coordinate: CLLocationCoordinate2D, calendar: Calendar = .autoupdatingCurrent, now: Date = .now) {
        var stop = TravelMapStop(name: name, latitude: coordinate.latitude, longitude: coordinate.longitude, date: calendar.startOfDay(for: now))
        if let previous = stops.last {
            stop.date = calendar.date(byAdding: .day, value: 1, to: previous.date) ?? previous.date
            stop.arrivalMode = TravelMapMode.guess(meters: MapHomeRangeTripPlan.meters(previous.point, stop.point))
        }
        stops.append(stop)
    }
}

/// 직접 넣은 여행 초안. 기기 안 UserDefaults에만 둔다.
enum TravelMapTripDraftStore {
    static let key = "travelMapManualTripDraft"

    static func load(_ defaults: UserDefaults = .standard) -> TravelMapTrip {
        guard let data = defaults.data(forKey: key),
              let trip = try? JSONDecoder().decode(TravelMapTrip.self, from: data) else { return TravelMapTrip() }
        return trip
    }

    static func save(_ trip: TravelMapTrip, _ defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(trip) else { return }
        defaults.set(data, forKey: key)
    }
}

/// 기록에서 들른 도시를 시간 순서로 뽑는다(TRV1108A01). 원본 기록은 읽기만 한다.
///
/// 1. 위치 표본과 장소 체류의 시작·끝을 시간 순서로 늘어놓고 각각 가장 가까운 도시(앱 안 목록)에 붙인다.
///    도시 반경 밖이면 0.25도 격자로 묶고 체류 이름(없으면 좌표)을 쓴다.
/// 2. 같은 도시가 이어진 묶음 중 `minimumDwellSeconds` 이상 머문 것만 남긴다. 기차로 지나친 도시는 빠진다.
/// 3. 이웃한 같은 도시를 합치고, 도시 사이 구간의 이동 기록에서 거리가 가장 긴 수단을 고른다.
enum TravelMapTripExtractor {
    static let minimumDwellSeconds: TimeInterval = 45 * 60
    static let gridDegrees = 0.25

    struct Stay: Sendable {
        var span: TimeSpan
        var latitude: Double
        var longitude: Double
        var name: String
    }

    struct Move: Sendable {
        var span: TimeSpan
        var mode: TravelMode
        var meters: Double
    }

    private struct Anchor {
        let time: TimeInterval
        let latitude: Double
        let longitude: Double
        let stayName: String?
    }

    private struct Visit {
        var key: String
        var city: TravelMapCity?
        var first: TimeInterval
        var last: TimeInterval
        var latitudeSum = 0.0
        var longitudeSum = 0.0
        var count = 0
        var stayName: String?

        mutating func add(_ anchor: Anchor) {
            first = min(first, anchor.time)
            last = max(last, anchor.time)
            latitudeSum += anchor.latitude
            longitudeSum += anchor.longitude
            count += 1
            if stayName == nil { stayName = anchor.stayName }
        }
    }

    static func extract(
        samples: [MapHomeRangeTripPlan.Sample],
        stays: [Stay],
        moves: [Move],
        catalog: TravelMapCityCatalog,
        language: MapHomeLanguage
    ) -> TravelMapTrip {
        var anchors = samples.map { Anchor(time: $0.time, latitude: $0.latitude, longitude: $0.longitude, stayName: nil) }
        for stay in stays {
            anchors.append(Anchor(time: stay.span.start.timeIntervalSinceReferenceDate, latitude: stay.latitude, longitude: stay.longitude, stayName: stay.name))
            anchors.append(Anchor(time: stay.span.end.timeIntervalSinceReferenceDate, latitude: stay.latitude, longitude: stay.longitude, stayName: stay.name))
        }
        anchors.sort { $0.time < $1.time }
        let visits = mergedVisits(anchors, catalog: catalog)
        var trip = TravelMapTrip()
        for (index, visit) in visits.enumerated() {
            var stop = TravelMapStop(
                name: name(of: visit, language: language),
                latitude: visit.city?.latitude ?? visit.latitudeSum / Double(visit.count),
                longitude: visit.city?.longitude ?? visit.longitudeSum / Double(visit.count),
                date: Date(timeIntervalSinceReferenceDate: visit.first)
            )
            if index > 0, let previous = trip.stops.last {
                let window = TimeSpan(
                    start: Date(timeIntervalSinceReferenceDate: visits[index - 1].last),
                    end: Date(timeIntervalSinceReferenceDate: visit.first)
                )
                let straight = MapHomeRangeTripPlan.meters(previous.point, stop.point)
                let leg = legMode(moves: moves, window: window, straightMeters: straight)
                stop.arrivalMode = leg.mode
                stop.arrivalMeters = leg.meters
            }
            trip.stops.append(stop)
        }
        return trip
    }

    private static func key(for anchor: Anchor, catalog: TravelMapCityCatalog) -> (String, TravelMapCity?) {
        if let city = catalog.nearest(latitude: anchor.latitude, longitude: anchor.longitude) { return ("c:" + city.key, city) }
        let row = Int(floor(anchor.latitude / gridDegrees)), column = Int(floor(anchor.longitude / gridDegrees))
        return ("g:\(row):\(column)", nil)
    }

    private static func mergedVisits(_ anchors: [Anchor], catalog: TravelMapCityCatalog) -> [Visit] {
        var runs: [Visit] = []
        for anchor in anchors {
            let (key, city) = key(for: anchor, catalog: catalog)
            if runs.last?.key == key {
                runs[runs.count - 1].add(anchor)
            } else {
                var visit = Visit(key: key, city: city, first: anchor.time, last: anchor.time)
                visit.add(anchor)
                runs.append(visit)
            }
        }
        var kept: [Visit] = []
        for run in runs where run.last - run.first >= minimumDwellSeconds {
            if kept.last?.key == run.key {
                let previous = kept.removeLast()
                var merged = run
                merged.first = previous.first
                merged.latitudeSum += previous.latitudeSum
                merged.longitudeSum += previous.longitudeSum
                merged.count += previous.count
                merged.stayName = previous.stayName ?? run.stayName
                kept.append(merged)
            } else {
                kept.append(run)
            }
        }
        return kept
    }

    private static func name(of visit: Visit, language: MapHomeLanguage) -> String {
        if let city = visit.city { return city.name(language) }
        if let stayName = visit.stayName, !stayName.isEmpty { return stayName }
        let latitude = visit.latitudeSum / Double(visit.count), longitude = visit.longitudeSum / Double(visit.count)
        return String(format: "%.2f°, %.2f°", latitude, longitude)
    }

    /// 구간 안 이동 기록에서 거리 합이 가장 큰 수단. 기록이 없으면 멀고 빠른 구간만 비행기로, 나머지는 자동차로 둔다.
    static func legMode(moves: [Move], window: TimeSpan, straightMeters: Double) -> (mode: TravelMapMode, meters: Double?) {
        var byMode: [TravelMapMode: Double] = [:]
        var total = 0.0
        for move in moves where move.span.end > window.start && move.span.start < window.end {
            byMode[TravelMapMode(move.mode), default: 0] += move.meters
            total += move.meters
        }
        if let best = byMode.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key.rawValue > $1.key.rawValue }), best.value > 0 {
            return (best.key, total > straightMeters ? total : nil)
        }
        let speed = straightMeters / max(1, window.duration)
        if straightMeters >= 700_000 || (straightMeters >= 300_000 && speed >= 50) { return (.flight, nil) }
        return (.car, nil)
    }
}
