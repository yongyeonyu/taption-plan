import CoreLocation
import MapKit

/// 등록되지 않은 체류 자리의 가장 가까운 장소 이름을 지도에서 찾는다(NLE1104A02).
/// 이름만 메모리에 잠시 두며 기록에는 쓰지 않는다. 찾지 못하면 체류의 원래 이름을 쓴다.
@MainActor
enum NLENearbyPlaceNames {
    /// 한 번에 찾는 곳 수. MapKit 호출 제한을 넘지 않게 오래 머문 곳부터 찾는다.
    static let maximumLookups = 12
    private static let searchRadiusMeters: CLLocationDistance = 200
    private static let cacheLimit = 300
    private static let storageKey = "stayPlaceNames"
    /// 찾은 이름은 기기에 기억한다(KKP1113A01). 카카오는 하루 호출 수가 정해져 있어 같은 곳을 다시 묻지 않는다.
    private static var cache: [String: String] = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] ?? [:]

    /// 기억한 이름(약 50m 칸 열쇠 → 이름).
    static var storedNames: [String: String] { cache }

    private static let candidateKey = "stayPlaceCandidates"
    /// 카카오에서 받은 그 자리 가게 후보(SPC1114A01). 기록 이름 고르기·식사 판단·후보 목록에 쓴다.
    private(set) static var storedCandidates: [String: [StayPlaceCandidate]] = UserDefaults.standard.data(forKey: candidateKey)
        .flatMap { try? JSONDecoder().decode([String: [StayPlaceCandidate]].self, from: $0) } ?? [:]

    private static func remember(_ candidates: [StayPlaceCandidate], for key: String) {
        if storedCandidates.count >= cacheLimit { storedCandidates.removeAll(keepingCapacity: true) }
        storedCandidates[key] = candidates
        UserDefaults.standard.set(try? JSONEncoder().encode(storedCandidates), forKey: candidateKey)
    }

    static func names(for points: [GeoPoint]) async -> [String: String] {
        var result: [String: String] = [:]
        var lookups = 0
        for point in points {
            let key = NLEPlaceLane.nameKey(for: point)
            // 국내 자리는 카카오 후보까지 있어야 다 찾은 것이다(SPC1114A01: 이름만 기억한 자리도 한 번 더 본다).
            let korea = MapHomeKakaoSearch.isAvailable(at: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude))
            if let cached = cache[key], !korea || storedCandidates[key] != nil {
                result[key] = cached
                continue
            }
            guard lookups < maximumLookups, !Task.isCancelled else { continue }
            lookups += 1
            guard let name = await nearestName(to: point, key: key) else { continue }
            if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
            cache[key] = name
            result[key] = name
        }
        if lookups > 0 { UserDefaults.standard.set(cache, forKey: storageKey) }
        return result
    }

    private static func nearestName(to point: GeoPoint, key: String) async -> String? {
        let center = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
        let location = CLLocation(latitude: point.latitude, longitude: point.longitude)
        // 국내는 카카오 장소를 먼저 본다(대표 결정 2026-11-13: Apple 지도가 가게 대신 건물 이름을 줬음).
        // 분류를 넓혀 1층 카페가 병원·학교를 덮지 않게 가장 가까운 곳을 고른다.
        if MapHomeKakaoSearch.isAvailable(at: center), let found = await MapHomeKakaoSearch.stayCandidates(at: center), let first = found.first {
            remember(found, for: key)
            return first.name
        }
        let request = MKLocalPointsOfInterestRequest(center: center, radius: searchRadiusMeters)
        if let response = try? await MKLocalSearch(request: request).start() {
            let nearest = response.mapItems
                .filter { !($0.name ?? "").isEmpty }
                .min {
                    location.distance(from: CLLocation(latitude: $0.placemark.coordinate.latitude, longitude: $0.placemark.coordinate.longitude))
                        < location.distance(from: CLLocation(latitude: $1.placemark.coordinate.latitude, longitude: $1.placemark.coordinate.longitude))
                }
            if let name = nearest?.name { return name }
        }
        let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first
        return placemark?.name ?? placemark?.subLocality ?? placemark?.locality
    }
}

/// 이름 없는 「머무름」 기록에 찾은 장소 이름을 붙인다(KKP1113A01, 대표 결정: 기록 이름에도).
/// 자동 기록만 바꾸고, 사용자가 고친 기록은 그대로 둔다. 이름을 못 찾으면 「머무름」으로 남는다.
enum StayPlaceNaming {
    static let evidence = "장소 이름(지도 검색)"
    static let minimumMinutes = 10.0

    static func retitling(
        _ actuals: [ActualRecord],
        places: [PlaceStay],
        names: [String: String],
        candidates: [String: [StayPlaceCandidate]] = [:],
        activityCorrections: [UUID: ActivityCorrection] = [:],
        calendar: Calendar = .autoupdatingCurrent,
        asOf now: Date
    ) -> [ActualRecord] {
        guard !names.isEmpty || !candidates.isEmpty else { return actuals }
        let unknown = StationaryContextKind.unknownStay
        return actuals.map { actual in
            let span = actual.span(asOf: now)
            let ours = actual.evidence.contains(evidence)
            guard actual.behavior == unknown.rawValue && actual.title == unknown.title || ours,
                  span.duration >= minimumMinutes * 60,
                  !ActualRecord.userOwned(actual, activityCorrections: activityCorrections),
                  let point = places.first(where: { $0.point != nil && $0.span.overlapsMostly(span) })?.point else { return actual }
            let key = NLEPlaceLane.nameKey(for: point)
            let list = candidates[key] ?? []
            let mealStay = isMealStay(span, calendar: calendar)
            let picked = StayPlaceCandidate.choose(list, mealStay: mealStay)
            guard let name = picked?.name ?? names[key] else { return actual }
            var value = actual
            value.evidence.removeAll { $0 == evidence || $0.hasPrefix(candidatePrefix) }
            value.evidence.append(evidence)
            if list.count > 1 { value.evidence.append(candidatePrefix + list.prefix(5).map(\.name).joined(separator: "·")) }
            // 식사 시간에 식당에 오래 머물렀으면 식사다(SPC1114A01, 대표 「식당이면 밥 먹었을 거 아니야」).
            if mealStay, picked?.isMeal == true {
                value.title = "식사 · " + name
                value.categoryID = "eating"
                value.behavior = "meal"
            } else {
                value.title = name
                value.categoryID = unknown.categoryID
                value.behavior = unknown.rawValue
            }
            return value == actual ? actual : value
        }
    }

    static let candidatePrefix = "근처 후보: "

    /// 점심(11~14시)·저녁(17~21시)에 시작해 30분 넘게 머문 곳.
    static func isMealStay(_ span: TimeSpan, calendar: Calendar) -> Bool {
        let hour = calendar.component(.hour, from: span.start)
        return span.duration >= 30 * 60 && ((11..<14).contains(hour) || (17..<21).contains(hour))
    }

    /// 이름이 필요한 「머무름」 자리(오래 머문 곳부터, 이미 기억한 곳은 뺀다).
    static func pointsNeedingNames(_ actuals: [ActualRecord], places: [PlaceStay], known: [String: String], asOf now: Date) -> [GeoPoint] {
        let unknown = StationaryContextKind.unknownStay.rawValue
        var seen = Set<String>()
        return actuals
            .filter { ($0.behavior == unknown || $0.evidence.contains(evidence)) && $0.span(asOf: now).duration >= minimumMinutes * 60 }
            .sorted { $0.span(asOf: now).duration > $1.span(asOf: now).duration }
            .compactMap { actual in places.first { $0.point != nil && $0.span.overlapsMostly(actual.span(asOf: now)) }?.point }
            .filter { known[NLEPlaceLane.nameKey(for: $0)] == nil && seen.insert(NLEPlaceLane.nameKey(for: $0)).inserted }
    }
}
/// 카카오가 준 머문 곳 가게 후보(SPC1114A01).
struct StayPlaceCandidate: Codable, Equatable, Sendable {
    var name: String
    /// 카카오 분류 코드(FD6 음식점, CE7 카페 …).
    var code: String
    /// 「음식점 > 뷔페」처럼 나눈 분류 이름.
    var category: String
    var meters: Double

    /// 끼니가 되는 식당(간식·디저트·제과는 빼고).
    var isMeal: Bool { code == "FD6" && !category.contains("간식") }

    /// 식사 시간에 오래 머문 곳이면 가까운 식당을, 아니면 가장 가까운 곳.
    static func choose(_ candidates: [StayPlaceCandidate], mealStay: Bool) -> StayPlaceCandidate? {
        let byDistance = candidates.sorted { $0.meters < $1.meters }
        if mealStay, let meal = byDistance.first(where: \.isMeal) { return meal }
        return byDistance.first
    }
}
