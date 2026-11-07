import Foundation

/// 같은 자리의 이어진 체류를 하나로 합친다(RVW1030A01, 대표 승인 2026-11-08).
///
/// GPS가 잠깐 튀면 체류 감지가 반경을 넘었다고 보고 한 번 머문 것을 둘로 가른다.
/// 튄 표본 묶음은 최소 체류보다 짧아 버려지므로 두 조각 사이에 몇 분 틈이 남는다.
/// 중심이 50m 안이고 틈이 10분 이하면 같은 체류로 본다. 10분은 위치 갱신 간격
/// (실내 정지 때 수 분)과 튐 몇 번을 덮되, 잠깐 나갔다 온 외출은 잇지 않는 값이다.
///
/// * 등록 지점 > 이름 있는 곳 > 이름 없는 곳 순으로 남는다.
/// * 사용자가 확정한 체류는 합치지 않고 그대로 둔다.
/// * 이름이 서로 다른 곳, 층이 서로 다른 곳은 잇지 않는다.
enum PlaceStayMergeEngine {
    static let maximumDistanceMeters = 50.0
    static let maximumGap: TimeInterval = 10 * 60

    static func merging(_ stays: [PlaceStay]) -> [PlaceStay] {
        var result: [PlaceStay] = []
        for stay in stays.sorted(by: { $0.span.start < $1.span.start }) {
            if let index = result.lastIndex(where: { canMerge($0, stay) }) {
                result[index] = merged(result[index], stay)
            } else {
                result.append(stay)
            }
        }
        return result
    }

    static func canMerge(_ lhs: PlaceStay, _ rhs: PlaceStay) -> Bool {
        guard !lhs.isConfirmed, !rhs.isConfirmed,
              !lhs.isWalkingLocation, !rhs.isWalkingLocation,
              let a = lhs.point, let b = rhs.point,
              PlanarDistance.meters(a, b) <= maximumDistanceMeters else { return false }
        let (first, second) = lhs.span.start <= rhs.span.start ? (lhs, rhs) : (rhs, lhs)
        guard second.span.start.timeIntervalSince(first.span.end) <= maximumGap else { return false }
        if let x = lhs.floor, let y = rhs.floor, x != y { return false }
        return sameIdentity(lhs, rhs)
    }

    private static func sameIdentity(_ lhs: PlaceStay, _ rhs: PlaceStay) -> Bool {
        if lhs.placeKey == rhs.placeKey { return true }
        if lhs.isRegisteredFrequentPlace && rhs.isRegisteredFrequentPlace { return false }
        let leftUnnamed = isUnnamed(lhs), rightUnnamed = isUnnamed(rhs)
        if leftUnnamed || rightUnnamed { return true }
        return lhs.displayName == rhs.displayName
    }

    private static func isUnnamed(_ stay: PlaceStay) -> Bool {
        !stay.isRegisteredFrequentPlace && UnregisteredPlaceSuggestionEngine.isPlaceholderName(stay.displayName)
    }

    private static func rank(_ stay: PlaceStay) -> Int {
        stay.isRegisteredFrequentPlace ? 2 : isUnnamed(stay) ? 0 : 1
    }

    private static func merged(_ lhs: PlaceStay, _ rhs: PlaceStay) -> PlaceStay {
        let leftWins = rank(lhs) != rank(rhs)
            ? rank(lhs) > rank(rhs)
            : lhs.span.duration >= rhs.span.duration
        let (winner, other) = leftWins ? (lhs, rhs) : (rhs, lhs)
        var value = winner
        value.span = TimeSpan(start: min(lhs.span.start, rhs.span.start), end: max(lhs.span.end, rhs.span.end))
        let levels = ConfidenceLevel.allCases
        value.confidence = (levels.firstIndex(of: lhs.confidence) ?? 0) >= (levels.firstIndex(of: rhs.confidence) ?? 0)
            ? lhs.confidence : rhs.confidence
        value.floor = winner.floor ?? other.floor
        value.floorEvidence = winner.floorEvidence ?? other.floorEvidence
        value.buildingName = winner.buildingName ?? other.buildingName
        return value
    }
}
