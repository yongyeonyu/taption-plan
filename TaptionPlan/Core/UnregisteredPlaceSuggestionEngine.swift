import Foundation
import TaptionPlanEngine

/// 저장된 체류에서 "자주 가는데 등록만 안 한 곳"을 찾는다. 새 위치 수집은
/// 하지 않고 `PlaceDetectionEngine` 이 이미 만들어 둔 체류만 센다.
struct UnregisteredPlaceSuggestionEngine: Sendable {
    /// 한 번의 도착이 한 번의 방문이다. `PlaceDetectionEngine` 이 표본 묶음
    /// 하나를 체류 하나로 이미 줄여 두므로 GPS 표본 수는 세지 않는다.
    /// 층 이동으로 한 체류가 둘로 갈라진 경우와 잠깐 나갔다 곧 돌아온 경우만
    /// 다시 한 번의 방문으로 합친다.
    var sameVisitGap: TimeInterval = 30 * 60
    /// 방문으로 인정할 최소 체류. 체류를 만들 때 쓴 기준을 그대로 따른다.
    var minimumStayDuration: TimeInterval = PlaceDetectionEngine().minimumDwell
    /// 같은 장소로 볼 반경. 체류를 묶을 때 쓴 반경과 같아야 한 자리가 두
    /// 군집으로 갈라지지 않는다.
    var clusterRadiusMeters: Double = PlaceDetectionEngine().radiusMeters
    /// 거절은 건물 단위로 기억한다. 다음 주 중심점이 몇 미터 흔들렸다고
    /// 같은 커피숍을 다시 묻지 않는다.
    var dismissalRadiusMeters = FrequentPlace.sameBuildingRadiusMeters
    var weeklyWindow: TimeInterval = 7 * 86_400
    var weeklyThreshold = 3
    /// 되돌아보는 범위이자 "한 달" 조건의 창. 반년 전에 세 번 갔던 곳을
    /// 이제 와서 묻지 않는다.
    var monthlyWindow: TimeInterval = 30 * 86_400
    var monthlyThreshold = 10

    /// 화면에는 한 번에 하나만 띄운다. 조건을 넘긴 자리가 여럿이면 가장 많이
    /// 간 곳, 그다음 가장 최근에 간 곳을 고른다.
    func suggestion(
        places: [PlaceStay],
        frequentPlaces: [FrequentPlace],
        dismissed: [DismissedPlaceSuggestion],
        now: Date = .now
    ) -> FrequentPlaceSuggestion? {
        suggestions(
            places: places,
            frequentPlaces: frequentPlaces,
            dismissed: dismissed,
            now: now
        )
        .max {
            if $0.visitCount != $1.visitCount {
                return $0.visitCount < $1.visitCount
            }
            if $0.lastVisitedAt != $1.lastVisitedAt {
                return $0.lastVisitedAt < $1.lastVisitedAt
            }
            return $0.id > $1.id
        }
    }

    private func suggestions(
        places: [PlaceStay],
        frequentPlaces: [FrequentPlace],
        dismissed: [DismissedPlaceSuggestion],
        now: Date
    ) -> [FrequentPlaceSuggestion] {
        let cutoff = now.addingTimeInterval(-monthlyWindow)
        let candidates = places
            .filter {
                $0.point != nil
                    && !$0.isWalkingLocation
                    && !$0.isRegisteredFrequentPlace
                    && $0.span.end > cutoff
                    && $0.span.start <= now
            }
            .sorted {
                if $0.span.start != $1.span.start {
                    return $0.span.start < $1.span.start
                }
                if $0.placeKey != $1.placeKey {
                    return $0.placeKey < $1.placeKey
                }
                return $0.id.uuidString < $1.id.uuidString
            }
        guard !candidates.isEmpty else { return [] }

        return clusters(of: candidates)
            .filter { !isKnown($0, frequentPlaces: frequentPlaces) }
            .filter { !isDismissed($0, dismissed: dismissed) }
            .compactMap(suggestion(from:))
    }

    // MARK: - 군집

    /// 같은 장소라도 방문마다 GPS 평균이 조금씩 달라져 `placeKey` 가 바뀐다.
    /// 그래서 키가 아니라 거리로 묶는다.
    private struct Cluster {
        var stays: [PlaceStay] = []
        var center = GeoPoint(
            latitude: 0,
            longitude: 0,
            altitude: 0,
            horizontalAccuracy: 0,
            verticalAccuracy: 0
        )
    }

    private func clusters(of stays: [PlaceStay]) -> [Cluster] {
        var result: [Cluster] = []
        for stay in stays {
            guard let point = stay.point else { continue }
            let nearest = result.indices
                .map { ($0, distanceMeters(result[$0].center, point)) }
                .filter { $0.1 <= clusterRadiusMeters }
                .min {
                    if $0.1 != $1.1 {
                        return $0.1 < $1.1
                    }
                    return $0.0 < $1.0
                }?
                .0
            if let nearest {
                result[nearest].stays.append(stay)
                result[nearest].center = centroid(of: result[nearest].stays)
            } else {
                result.append(Cluster(stays: [stay], center: point))
            }
        }
        return result
    }

    private func centroid(of stays: [PlaceStay]) -> GeoPoint {
        let points = stays.compactMap(\.point)
        let count = Double(max(points.count, 1))
        return GeoPoint(
            latitude: points.map(\.latitude).reduce(0, +) / count,
            longitude: points.map(\.longitude).reduce(0, +) / count,
            altitude: points.map(\.altitude).reduce(0, +) / count,
            horizontalAccuracy: points.map(\.horizontalAccuracy)
                .reduce(0, +) / count,
            verticalAccuracy: points.map(\.verticalAccuracy)
                .reduce(0, +) / count
        )
    }

    // MARK: - 제외

    private func isKnown(
        _ cluster: Cluster,
        frequentPlaces: [FrequentPlace]
    ) -> Bool {
        frequentPlaces.contains { place in
            guard let point = place.point else { return false }
            return distanceMeters(point, cluster.center)
                <= max(place.radiusMeters, clusterRadiusMeters)
        }
    }

    private func isDismissed(
        _ cluster: Cluster,
        dismissed: [DismissedPlaceSuggestion]
    ) -> Bool {
        dismissed.contains {
            distanceMeters($0.point, cluster.center) <= dismissalRadiusMeters
        }
    }

    // MARK: - 방문 세기

    private func suggestion(from cluster: Cluster) -> FrequentPlaceSuggestion? {
        let visits = self.visits(in: cluster.stays)
        guard let first = visits.first, let last = visits.last else {
            return nil
        }
        let starts = visits.map(\.start)
        let reason: FrequentPlaceSuggestion.Reason
        if hasWindow(starts, count: weeklyThreshold, within: weeklyWindow) {
            reason = .weekly
        } else if hasWindow(
            starts,
            count: monthlyThreshold,
            within: monthlyWindow
        ) {
            reason = .monthly
        } else {
            return nil
        }
        return FrequentPlaceSuggestion(
            id: String(
                format: "suggested-%.4f,%.4f",
                cluster.center.latitude,
                cluster.center.longitude
            ),
            point: cluster.center,
            suggestedName: suggestedName(in: cluster.stays),
            visitCount: visits.count,
            firstVisitedAt: first.start,
            lastVisitedAt: last.end,
            reason: reason
        )
    }

    private func visits(in stays: [PlaceStay]) -> [TimeSpan] {
        var merged: [TimeSpan] = []
        for stay in stays.sorted(by: { $0.span.start < $1.span.start }) {
            if let last = merged.last,
               stay.span.start.timeIntervalSince(last.end) <= sameVisitGap {
                merged[merged.count - 1] = TimeSpan(
                    start: last.start,
                    end: max(last.end, stay.span.end)
                )
            } else {
                merged.append(stay.span)
            }
        }
        return merged.filter { $0.duration >= minimumStayDuration }
    }

    /// 정렬된 시각에서 `count` 번이 `window` 안에 들어가는 구간이 있는지 본다.
    private func hasWindow(
        _ times: [Date],
        count: Int,
        within window: TimeInterval
    ) -> Bool {
        guard count > 0 else { return true }
        guard times.count >= count else { return false }
        for index in 0...(times.count - count)
        where times[index + count - 1].timeIntervalSince(times[index])
            <= window {
            return true
        }
        return false
    }

    // MARK: - 이름

    /// 이름은 지어내지 않는다. 역지오코딩이 이미 붙여 준 이름만 쓰고, 자동
    /// 생성 자리표시자는 이름으로 치지 않는다.
    private func suggestedName(in stays: [PlaceStay]) -> String? {
        var counts: [String: Int] = [:]
        for stay in stays where !Self.isPlaceholderName(stay.displayName) {
            counts[stay.displayName, default: 0] += 1
        }
        return counts
            .sorted {
                $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
            }
            .first?
            .key
    }

    static func isPlaceholderName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            || trimmed == "자동 감지 장소"
            || trimmed == "확인된 위치"
            || trimmed.hasPrefix("장소 · ")
    }
}
