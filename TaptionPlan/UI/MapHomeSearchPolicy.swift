import CoreLocation
import MapKit

/// 지도 검색의 범위와 앱 안 자료(등록 장소·다녀온 곳·지하철역) 찾기(SRC1107A01, SRC1108A01).
enum MapHomeSearchPolicy {
    /// 현재 위치 둘레 이만큼(약 55km)을 먼저 찾는다. 좁으면 Apple 검색이 결과를 거의 내지 않는다.
    static let minimumSpanDegrees = 0.5
    static let localLimit = 5

    /// 현재 위치를 기준으로 찾는다(대표 지시 2026-11-08: 일본에 가면 일본이 먼저). 위치를 모르면 보고 있는 지도 가운데.
    static func region(visibleCenter: CLLocationCoordinate2D, visibleSpan: MKCoordinateSpan, current: CLLocationCoordinate2D?) -> MKCoordinateRegion {
        let hasVisible = visibleCenter.latitude != 0 || visibleCenter.longitude != 0
        let center = current ?? visibleCenter
        let span = current == nil && hasVisible ? visibleSpan : MKCoordinateSpan(latitudeDelta: 0, longitudeDelta: 0)
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(
                latitudeDelta: max(span.latitudeDelta, minimumSpanDegrees),
                longitudeDelta: max(span.longitudeDelta, minimumSpanDegrees)
            )
        )
    }

    /// 이름 어디에든 검색어가 든 등록 장소·다녀온 곳·지하철역. 등록 장소가 먼저이고, 같은 무리 안에서는 가까운 곳이 먼저다.
    /// Apple 검색은 이름 앞부분으로 찾아 「사이언스」로 「LG사이언스파크」를 못 찾는 일이 있어 앱 안 자료는 중간 글자로도 찾는다.
    static func localMatches(
        _ query: String,
        places: [FrequentPlace],
        visited: [PlaceStay] = [],
        origin: CLLocationCoordinate2D? = nil,
        language: MapHomeLanguage
    ) -> [MapHomeSearchResult] {
        let key = normalized(query)
        guard !key.isEmpty else { return [] }
        var seen = Set<String>()
        var result: [MapHomeSearchResult] = []
        func add(_ group: [MapHomeSearchResult]) {
            for item in sortedByDistance(group, from: origin) where result.count < localLimit {
                guard seen.insert(normalized(item.title)).inserted else { continue }
                result.append(item)
            }
        }
        add(places.compactMap { place in
            guard let point = place.point, normalized(place.displayName).contains(key) else { return nil }
            return MapHomeSearchResult(title: place.displayName, subtitle: language.text("등록한 장소", "Saved place"), coordinate: point.coordinate)
        })
        var visitedNames = Set<String>()
        add(visited.compactMap { stay in
            guard let point = stay.point else { return nil }
            let name = [stay.buildingName, stay.displayName].compactMap { $0 }.first { normalized($0).contains(key) }
            guard let name, visitedNames.insert(normalized(name)).inserted else { return nil }
            return MapHomeSearchResult(title: name, subtitle: language.text("다녀온 곳", "Visited place"), coordinate: point.coordinate)
        })
        if result.count < localLimit {
            add(SubwayStationCatalog.stations.compactMap { station in
                guard let point = station.coordinate, normalized(station.stationName).contains(key) else { return nil }
                return MapHomeSearchResult(
                    title: station.stationName,
                    subtitle: language.text("지하철역 · \(station.lineName)", "Subway station · \(station.lineName)"),
                    coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
                )
            })
        }
        return result
    }

    /// Apple 검색 결과를 현재 위치에서 가까운 순으로. 위치를 모르면 받은 순서 그대로.
    static func sortedByDistance(_ results: [MapHomeSearchResult], from origin: CLLocationCoordinate2D?) -> [MapHomeSearchResult] {
        guard let origin else { return results }
        let here = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        return results.enumerated().sorted { lhs, rhs in
            let a = here.distance(from: CLLocation(latitude: lhs.element.coordinate.latitude, longitude: lhs.element.coordinate.longitude))
            let b = here.distance(from: CLLocation(latitude: rhs.element.coordinate.latitude, longitude: rhs.element.coordinate.longitude))
            return a == b ? lhs.offset < rhs.offset : a < b
        }.map(\.element)
    }

    /// 앞 무리를 우선해 이름이 같은 결과를 하나로 합친다.
    static func merged(_ groups: [[MapHomeSearchResult]], limit: Int = 8) -> [MapHomeSearchResult] {
        var seen = Set<String>()
        return Array(groups.joined().filter { seen.insert(normalized($0.title)).inserted }.prefix(limit))
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: " ", with: "")
    }
}

private extension GeoPoint {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

/// 현재 위치 둘레에서 먼저 찾고, 없으면 같은 중심으로 넓혀 두 번까지 더 찾는다. 전 세계로는 넘기지 않는다(SRC1108A02).
@MainActor
enum MapHomeSearchRunner {
    static func items(for request: MKLocalSearch.Request) async -> (items: [MKMapItem], failed: Bool) {
        let base = request.region
        request.regionPriority = .required
        var last: (items: [MKMapItem], failed: Bool) = ([], false)
        for step in 0...MapHomeSearchCompleter.maxWidenSteps {
            request.region = MapHomeSearchCompleter.widened(base, step: step)
            last = await run(request)
            if !last.items.isEmpty || last.failed || Task.isCancelled { return last }
        }
        // 넓혀도 없으면(국내에서 「도쿄 타워」를 찾을 때) 지역 제한 없이 한 번 더 찾는다. 검색 단추로만 온다.
        request.region = base
        request.regionPriority = .default
        return await run(request)
    }

    private static func run(_ request: MKLocalSearch.Request) async -> (items: [MKMapItem], failed: Bool) {
        do {
            return (try await MKLocalSearch(request: request).start().mapItems, false)
        } catch {
            // 결과가 없으면 Apple 검색은 placemarkNotFound 오류를 낸다. 그때는 실패가 아니다.
            return ([], (error as? MKError)?.code != .placemarkNotFound)
        }
    }
}
