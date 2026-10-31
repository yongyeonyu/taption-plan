import Foundation

/// 창 하나에 대한 10개 수단의 로그 우도.
public struct WindowScore: Hashable, Sendable {
    public var logLikelihood: [TransportMode: Double]
    public var evidence: [TransportMode: [String]]

    public func best() -> TransportMode {
        TransportMode.allCases.max { (logLikelihood[$0] ?? -.infinity) < (logLikelihood[$1] ?? -.infinity) } ?? .stationary
    }
}

public enum ModeScorer {
    /// 수단별 대표 속도(m/s)와 로그 속도 표준편차.
    static let speedProfile: [TransportMode: (mean: Double, spread: Double)] = [
        .stationary: (0.1, 0.9), .walking: (1.3, 0.35), .running: (3.0, 0.3),
        .cycling: (5.0, 0.35), .car: (12, 0.7), .bus: (7, 0.6), .subway: (11, 0.5),
        .train: (25, 0.55), .ship: (8, 0.45), .airplane: (200, 0.45),
    ]
    /// 비행기는 이 속도를 넘어야 후보가 된다.
    public static let airplaneMinimumSpeed = 55.0
    /// 배는 물 위에서 이 속도 범위를 지켜야 후보가 된다.
    public static let shipSpeedRange = 4.0...17.0

    public static func score(_ window: WindowFeatures) -> WindowScore {
        var ll: [TransportMode: Double] = [:]
        var evidence: [TransportMode: [String]] = [:]
        func add(_ mode: TransportMode, _ value: Double, _ reason: String? = nil) {
            ll[mode, default: 0] += value
            if let reason { evidence[mode, default: []].append(reason) }
        }
        for mode in TransportMode.allCases { ll[mode] = 0 }

        if let speed = window.bestSpeed {
            for mode in TransportMode.allCases {
                let profile = speedProfile[mode]!
                let z = (log(speed + 0.3) - log(profile.mean + 0.3)) / profile.spread
                add(mode, -0.5 * z * z)
            }
            if let p90 = window.speedP90, p90 > 8 {
                for mode in [TransportMode.walking, .running, .stationary] { add(mode, -2) }
            }
        } else if window.isIdle {
            add(.stationary, 1.5, "가속도·회전 정지")
        }

        switch window.motion {
        case .stationary: add(.stationary, 1.5, "Core Motion 정지")
        case .walking:
            add(.walking, 2, "Core Motion 보행")
            for mode in TransportMode.allCases where mode.isVehicle { add(mode, -1.5) }
        case .running: add(.running, 2, "Core Motion 달리기")
        case .cycling: add(.cycling, 2, "Core Motion 자전거")
        case .automotive:
            for mode in [TransportMode.car, .bus, .subway, .train] { add(mode, 1.2, "Core Motion 차량") }
            add(.walking, -1); add(.stationary, -0.5)
        case .unknown: break
        }

        if let cadence = window.stepCadence, cadence >= 1.2 {
            add(.walking, 1.2, "걸음 리듬")
            if cadence >= 2.3 { add(.running, 1.5, "달리기 보폭") }
            for mode in TransportMode.allCases where mode.isVehicle { add(mode, -2) }
        }
        // GPS 속도만으로는 달리기가 아니다. 보폭이나 Core Motion 달리기가 있어야 한다.
        if window.motion != .running, (window.stepCadence ?? 0) < 2.3 { add(.running, -1.5) }

        if window.nearTransitStop {
            add(.bus, 0.9, "버스 정류장 근처")
            add(.car, -0.3)
        }
        if window.nearRailStation {
            add(.subway, 0.6, "역 근처")
            add(.train, 0.4, "역 근처")
        }
        if !window.hasLocation, window.motion == .automotive || (window.accelerationStandardDeviationG ?? 0) > 0.02 {
            add(.subway, 1.5, "GPS 없음 · 차량 진동")
        }
        if window.hasLocation, (window.bestSpeed ?? 0) >= 20 { add(.subway, -1, nil); add(.train, 0.5, "고속 지상 이동") }
        if let entropy = window.headingEntropy, entropy < 1 {
            for mode in TransportMode.allCases where mode.isVehicle { add(mode, 0.4) }
        }

        // 비행기: 기압 평탄(순항) + 55m/s 초과. 공항 이름만으로는 정하지 않는다.
        let speed = window.bestSpeed ?? 0
        if speed > airplaneMinimumSpeed {
            add(.airplane, 1, "\(Int(speed))m/s 이동")
            if let slope = window.pressureSlope, abs(slope) < 0.02 { add(.airplane, 2, "기압 평탄 순항") }
            if let level = window.pressureLevel, level < 85 { add(.airplane, 1, "기내 기압") }
        } else {
            add(.airplane, -8)
        }
        // 배: 물 위에서 4–17m/s 지속 + 낮은 도로 진동.
        if window.onWater {
            if shipSpeedRange.contains(speed) { add(.ship, 2.5, "물 위 \(Int(speed))m/s") }
            if let jerk = window.jerk, jerk < 0.5 { add(.ship, 0.5, "도로 진동 없음") }
            for mode in [TransportMode.car, .bus, .train, .subway] { add(mode, -1.5) }
        } else {
            add(.ship, -6)
        }
        return WindowScore(logLikelihood: ll, evidence: evidence)
    }
}
