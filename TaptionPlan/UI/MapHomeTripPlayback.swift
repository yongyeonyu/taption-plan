import CoreLocation
import Foundation

/// 여행 날 재생(TRP1110A01, 대표 결정 2026-11-11). 기록이 없는 날(앞으로 갈 여행)에 재생하면 화랑이가
/// 여행 일정 핀을 시간 순서대로 따라간다. 일정 동안은 그 핀에 머물고, 일정 사이는 직선으로 옮긴다.
/// 기록이 하나라도 있는 날은 기록을 따르므로 쓰지 않는다.
struct MapHomeTripPlaybackPath: Equatable {
    struct Stop: Equatable {
        var coordinate: CLLocationCoordinate2D
        var start: Date
        var end: Date

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.coordinate.latitude == rhs.coordinate.latitude && lhs.coordinate.longitude == rhs.coordinate.longitude
                && lhs.start == rhs.start && lhs.end == rhs.end
        }
    }

    let stops: [Stop]

    /// 핀과 여행 일정(같은 여행 번호·항목 번호)을 이어 시각을 붙인다. 시각을 모르는 핀은 뺀다.
    init?(stops: [TravelPlanStop], items: [TravelTripItem]) {
        let times = Dictionary(items.map { ("\($0.tripID)|\($0.itemID)", ($0.start, $0.end)) }, uniquingKeysWith: { first, _ in first })
        let timed = stops.compactMap { stop -> Stop? in
            guard let tripID = stop.tripID, let itemID = stop.itemID, let span = times["\(tripID)|\(itemID)"] else { return nil }
            let coordinate = CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude)
            guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
            return Stop(coordinate: coordinate, start: span.0, end: max(span.0, span.1))
        }.sorted { $0.start < $1.start }
        guard !timed.isEmpty else { return nil }
        self.stops = timed
    }

    /// 첫 일정 전에는 첫 핀, 마지막 일정 뒤에는 마지막 핀.
    func coordinate(at date: Date) -> CLLocationCoordinate2D {
        guard let first = stops.first, let last = stops.last else { return CLLocationCoordinate2D() }
        if date <= first.start { return first.coordinate }
        for (previous, next) in zip(stops, stops.dropFirst()) {
            if date <= previous.end { return previous.coordinate }
            if date < next.start {
                let gap = next.start.timeIntervalSince(previous.end)
                let ratio = gap > 0 ? date.timeIntervalSince(previous.end) / gap : 1
                return CLLocationCoordinate2D(
                    latitude: previous.coordinate.latitude + (next.coordinate.latitude - previous.coordinate.latitude) * ratio,
                    longitude: previous.coordinate.longitude + (next.coordinate.longitude - previous.coordinate.longitude) * ratio
                )
            }
        }
        return last.coordinate
    }

    /// 일정 사이 옮겨 가는 구간. 재생이 이 동안 느려져 이동이 보인다.
    var moves: [(start: Date, end: Date)] {
        zip(stops, stops.dropFirst()).compactMap { previous, next in
            next.start > previous.end ? (previous.end, next.start) : nil
        }
    }
}

extension MapHomeView {
    /// 기록이 없는 날의 여행 재생 길. 재생 중 매 장면에서 읽으므로 날짜·핀이 같으면 다시 만들지 않는다.
    var tripPlaybackPath: MapHomeTripPlaybackPath? {
        guard historicalPlaybackReadings.isEmpty, (currentDayDataSnapshot?.actuals ?? []).isEmpty else { return nil }
        let stops = travelStopsOnSelectedDay
        guard !stops.isEmpty else { return nil }
        let items = model.settings.travelTripItems ?? []
        var hasher = Hasher()
        stops.forEach { hasher.combine($0.id); hasher.combine($0.latitude); hasher.combine($0.longitude) }
        items.forEach { hasher.combine($0.itemID); hasher.combine($0.start); hasher.combine($0.end) }
        let key = hasher.finalize()
        if let cached = MapHomeTripPlaybackCache.path, MapHomeTripPlaybackCache.key == key { return cached }
        let path = MapHomeTripPlaybackPath(stops: stops, items: items)
        MapHomeTripPlaybackCache.key = key
        MapHomeTripPlaybackCache.path = path
        return path
    }
}

@MainActor
private enum MapHomeTripPlaybackCache {
    static var key: Int?
    static var path: MapHomeTripPlaybackPath?
}
