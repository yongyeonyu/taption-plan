import Foundation

/// 표본 사이 틈의 종류(ALG1102A01).
/// `sparse`는 차를 탄 채 표본만 드문 것이라 실제 경로로 잇고, `missing`만 임시 경로 후보가 된다.
public enum RouteGapKind: String, Hashable, Sendable {
    case sparse, missing

    public static let maximumSparseDuration: TimeInterval = 180
    private static let minimumSparseSpeed = 2.0

    /// 틈 앞뒤와 틈 안의 모션이 모두 차량이고 평균 속도가 차량으로 설명될 때만 `sparse`다.
    /// 모션을 모르는 표본은 근거로 세지 않지만 막지도 않는다. 차량 표본이 앞뒤 양쪽에 있어야 한다.
    public static func classify(
        duration: TimeInterval,
        distanceMeters: Double,
        before: RouteTravelMode,
        after: RouteTravelMode,
        inside: [RouteTravelMode] = []
    ) -> RouteGapKind {
        guard duration > 0, duration <= maximumSparseDuration,
              before.isRoadOrRailVehicle, after.isRoadOrRailVehicle,
              inside.allSatisfy({ $0 == .unknown || $0.isRoadOrRailVehicle }) else { return .missing }
        let speed = distanceMeters / duration
        guard speed >= minimumSparseSpeed,
              speed <= RouteSparseConnectionPolicy.impossibleSpeedMetersPerSecond else { return .missing }
        return .sparse
    }
}

private extension RouteTravelMode {
    var isRoadOrRailVehicle: Bool {
        switch self {
        case .automotive, .privateVehicle, .bus, .subway, .train: true
        default: false
        }
    }
}
