import Foundation
import TaptionPlanCore

/// 장소 줄의 식사 자리 채우기(PLM1111A01). 대분류 「식사」는 실내 위치 공백을 1시간까지 잇는 식당 판정에서 오지만,
/// 장소 줄은 관측된 표본만 15분 넘게 이어져야 체류로 본다. 그래서 회사 → 식당 → 회사 사이 식당이 비었다.
/// 식사 기록이 덮는 시간에 체류가 없으면 그 자리를 넣는다: 등록 식당이면 그 지점, 아니면 그 시간 위치 표본의 중심.
enum NLEMealPlaces {
    static let maximumAccuracy: Double = 150

    static func filling(
        places: [PlaceStay],
        actuals: [ActualRecord],
        readings: [SensorReading],
        frequentPlaces: [FrequentPlace]
    ) -> [PlaceStay] {
        var result = places
        for meal in actuals where meal.categoryID == "eating" {
            guard let end = meal.endedAt, end > meal.startedAt else { continue }
            let span = TimeSpan(start: meal.startedAt, end: end)
            for gap in uncovered(span, by: result.map(\.span)) where gap.duration >= TimeInterval(NLEPlaceLane.minimumVisitMinutes * 60) {
                if let stay = stay(for: meal, in: gap, readings: readings, frequentPlaces: frequentPlaces) { result.append(stay) }
            }
        }
        return result.sorted { $0.span.start < $1.span.start }
    }

    private static func stay(for meal: ActualRecord, in span: TimeSpan, readings: [SensorReading], frequentPlaces: [FrequentPlace]) -> PlaceStay? {
        let restaurantName = meal.evidence.lazy.compactMap { $0.hasPrefix("등록 식당: ") ? String($0.dropFirst(7)) : nil }.first
        if let name = restaurantName,
           let place = frequentPlaces.first(where: { $0.kind == .restaurant && $0.displayName == name }), let point = place.point {
            return PlaceStay(placeKey: place.stablePlaceKey, displayName: place.displayName, span: span, confidence: .medium, point: point)
        }
        let points = readings.filter { span.contains($0.timestamp) }.compactMap(\.point)
            .filter { $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= maximumAccuracy }
        guard !points.isEmpty else { return nil }
        let count = Double(points.count)
        let center = GeoPoint(
            latitude: points.map(\.latitude).reduce(0, +) / count,
            longitude: points.map(\.longitude).reduce(0, +) / count,
            altitude: 0,
            horizontalAccuracy: points.map(\.horizontalAccuracy).reduce(0, +) / count,
            verticalAccuracy: -1
        )
        return PlaceStay(placeKey: "meal-\(NLEPlaceLane.nameKey(for: center))", displayName: "식사 장소", span: span, confidence: .low, point: center)
    }

    /// `span`에서 `covers`가 덮지 않은 조각.
    static func uncovered(_ span: TimeSpan, by covers: [TimeSpan]) -> [TimeSpan] {
        var pieces = [span]
        for cover in covers {
            pieces = pieces.flatMap { piece -> [TimeSpan] in
                guard cover.start < piece.end, piece.start < cover.end else { return [piece] }
                var rest: [TimeSpan] = []
                if piece.start < cover.start { rest.append(TimeSpan(start: piece.start, end: cover.start)) }
                if cover.end < piece.end { rest.append(TimeSpan(start: cover.end, end: piece.end)) }
                return rest
            }
        }
        return pieces
    }
}
