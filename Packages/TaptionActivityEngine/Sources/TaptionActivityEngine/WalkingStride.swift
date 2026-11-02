import Foundation

/// 걷기 한 묶음. GPS 거리와 걸음이 함께 있으면 보폭을 잴 수 있다.
public struct WalkingBout: Hashable, Sendable {
    public var meters: Double
    public var steps: Int
    public var duration: TimeInterval
    public var meanAccuracyMeters: Double

    public init(meters: Double, steps: Int, duration: TimeInterval, meanAccuracyMeters: Double) {
        self.meters = meters
        self.steps = steps
        self.duration = duration
        self.meanAccuracyMeters = meanAccuracyMeters
    }

    /// 하늘이 트이고 꾸준히 걸은 묶음만 보폭 근거가 된다.
    public var isCleanOutdoor: Bool {
        guard duration > 0, steps >= WalkingStride.minimumSteps, meters >= WalkingStride.minimumMeters,
              meanAccuracyMeters >= 0, meanAccuracyMeters <= WalkingStride.maximumAccuracyMeters else { return false }
        let speed = meters / duration
        let stride = meters / Double(steps)
        return (0.5...2.5).contains(speed) && WalkingStride.plausibleStride.contains(stride)
    }
}

/// 깨끗한 야외 걷기에서 보폭을 재서 실내 걸음을 거리로 옮긴다(ALG1102A01).
/// 표본이 모자라면 값을 지어내지 않고 nil을 돌려준다.
public enum WalkingStride {
    public static let minimumSteps = 100
    public static let minimumMeters = 80.0
    public static let maximumAccuracyMeters = 20.0
    public static let minimumBouts = 2
    public static let plausibleStride = 0.4...1.2

    /// 깨끗한 묶음들의 보폭 중앙값.
    public static func calibrated(_ bouts: [WalkingBout]) -> Double? {
        let strides = bouts.filter(\.isCleanOutdoor).map { $0.meters / Double($0.steps) }.sorted()
        guard strides.count >= minimumBouts else { return nil }
        let middle = strides.count / 2
        return strides.count.isMultiple(of: 2) ? (strides[middle - 1] + strides[middle]) / 2 : strides[middle]
    }
}
