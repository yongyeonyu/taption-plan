import Foundation
import TaptionPlanCore

/// 휴대폰이 정말 움직이지 않는지 가속도·회전 센서로 판정한다.
/// 모든 표본이 아주 작은 임계값 안에 일정 시간 이어져야 정지로 보고, 표본이 오래됐거나
/// 없으면(앱이 정지 상태이거나 센서를 못 받으면) 절대 정지로 보지 않는다.
struct DeviceStillnessTracker: Equatable, Sendable {
    static let maximumUserAccelerationG = 0.015
    static let maximumRotationRateRadiansPerSecond = 0.03
    static let minimumStillDuration: TimeInterval = 60
    static let maximumSampleAge: TimeInterval = 10

    private var stillSince: Date?
    private var lastSampleAt: Date?

    mutating func append(
        userAccelerationMagnitudeG: Double,
        rotationRateMagnitude: Double,
        at date: Date
    ) {
        defer { lastSampleAt = date }
        let isStill = userAccelerationMagnitudeG.isFinite
            && rotationRateMagnitude.isFinite
            && userAccelerationMagnitudeG <= Self.maximumUserAccelerationG
            && rotationRateMagnitude <= Self.maximumRotationRateRadiansPerSecond
        if !isStill {
            stillSince = nil
        } else if stillSince == nil {
            stillSince = date
        }
        // 표본 사이가 길게 끊겼으면 그 사이 움직였을 수 있어 처음부터 다시 잰다.
        if let lastSampleAt, date.timeIntervalSince(lastSampleAt) > Self.maximumSampleAge {
            stillSince = isStill ? date : nil
        }
    }

    /// 지금까지 이어진 정지 시간(초). 정지가 아니면 0.
    func stillDuration(at date: Date) -> TimeInterval {
        guard isTrulyStill(at: date), let stillSince else { return 0 }
        return max(0, date.timeIntervalSince(stillSince))
    }

    func isTrulyStill(at date: Date) -> Bool {
        guard let stillSince, let lastSampleAt,
              date.timeIntervalSince(lastSampleAt) <= Self.maximumSampleAge,
              date.timeIntervalSince(lastSampleAt) >= -1 else { return false }
        return lastSampleAt.timeIntervalSince(stillSince) >= Self.minimumStillDuration
    }

    mutating func reset() {
        self = DeviceStillnessTracker()
    }
}
