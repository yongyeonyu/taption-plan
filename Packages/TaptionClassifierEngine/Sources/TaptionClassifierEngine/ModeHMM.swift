import Foundation

/// 창 점수를 시간으로 평활하는 10상태 HMM.
///
/// 정지·걷기가 허브다. 탈것끼리 바로 넘어가는 것은 드물고(갈아탈 때도 걷거나
/// 서 있는다), 비행기는 공항 근처 정지에서만 시작한다. 10분 넘게 원본이 없으면
/// 사슬을 끊는다. 공백은 추정하지 않는다.
public struct ModeHMM: Sendable {
    public var stayLog = log(0.97)
    public var hubLog = log(0.02)
    public var vehicleToVehicleLog = log(0.0005)
    public var airplaneEntryLog = log(0.002)
    public var airplaneWithoutAirportLog = log(1e-7)
    public var maximumGap: TimeInterval = 10 * 60

    public init() {}

    public struct Step: Hashable, Sendable {
        public var window: WindowFeatures
        public var mode: TransportMode
        /// 고른 상태의 사후 확률(0…1).
        public var posterior: Double
        public var evidence: [String]
    }

    func transition(from previous: TransportMode, to next: TransportMode, previousWindow: WindowFeatures) -> Double {
        if previous == next { return stayLog }
        if next == .airplane {
            return previous == .stationary || previous == .walking
                ? (previousWindow.nearAirport ? airplaneEntryLog : airplaneWithoutAirportLog)
                : airplaneWithoutAirportLog
        }
        if previous == .airplane { return next == .stationary || next == .walking ? airplaneEntryLog : airplaneWithoutAirportLog }
        if previous == .stationary || previous == .walking || next == .stationary || next == .walking { return hubLog }
        if previous.isOnFoot && next.isOnFoot { return hubLog }
        return vehicleToVehicleLog
    }

    public func decode(_ windows: [WindowFeatures]) -> [Step] {
        chains(windows).flatMap(decodeChain)
    }

    func chains(_ windows: [WindowFeatures]) -> [[WindowFeatures]] {
        var result: [[WindowFeatures]] = []
        for window in windows.sorted(by: { $0.interval.start < $1.interval.start }) {
            if let last = result.last?.last, window.interval.start.timeIntervalSince(last.interval.end) <= maximumGap {
                result[result.count - 1].append(window)
            } else {
                result.append([window])
            }
        }
        return result
    }

    func decodeChain(_ windows: [WindowFeatures]) -> [Step] {
        guard !windows.isEmpty else { return [] }
        let states = TransportMode.allCases
        let scores = windows.map(ModeScorer.score)
        let emissions = scores.map { score in states.map { score.logLikelihood[$0] ?? -50 } }
        let count = windows.count, n = states.count
        let prior = states.map { $0 == .airplane ? airplaneWithoutAirportLog : log(1.0 / Double(n)) }

        // Viterbi
        var delta = [[Double]](repeating: [Double](repeating: -.infinity, count: n), count: count)
        var back = [[Int]](repeating: [Int](repeating: 0, count: n), count: count)
        for j in 0..<n { delta[0][j] = prior[j] + emissions[0][j] }
        for t in 1..<count {
            for j in 0..<n {
                var best = -Double.infinity, arg = 0
                for i in 0..<n {
                    let value = delta[t - 1][i] + transition(from: states[i], to: states[j], previousWindow: windows[t - 1])
                    if value > best { best = value; arg = i }
                }
                delta[t][j] = best + emissions[t][j]
                back[t][j] = arg
            }
        }
        var path = [Int](repeating: 0, count: count)
        path[count - 1] = (0..<n).max { delta[count - 1][$0] < delta[count - 1][$1] }!
        if count > 1 { for t in stride(from: count - 1, to: 0, by: -1) { path[t - 1] = back[t][path[t]] } }

        // Forward-backward로 사후 확률
        let posterior = posteriors(emissions: emissions, prior: prior, windows: windows, states: states)
        return (0..<count).map { t in
            let mode = states[path[t]]
            return Step(window: windows[t], mode: mode, posterior: posterior[t][path[t]], evidence: scores[t].evidence[mode] ?? [])
        }
    }

    func posteriors(emissions: [[Double]], prior: [Double], windows: [WindowFeatures], states: [TransportMode]) -> [[Double]] {
        let count = emissions.count, n = states.count
        var alpha = [[Double]](repeating: [Double](repeating: -.infinity, count: n), count: count)
        var beta = [[Double]](repeating: [Double](repeating: 0, count: n), count: count)
        for j in 0..<n { alpha[0][j] = prior[j] + emissions[0][j] }
        if count > 1 {
            for t in 1..<count {
                for j in 0..<n {
                    alpha[t][j] = logSum((0..<n).map { alpha[t - 1][$0] + transition(from: states[$0], to: states[j], previousWindow: windows[t - 1]) }) + emissions[t][j]
                }
            }
            for t in stride(from: count - 2, through: 0, by: -1) {
                for i in 0..<n {
                    beta[t][i] = logSum((0..<n).map { transition(from: states[i], to: states[$0], previousWindow: windows[t]) + emissions[t + 1][$0] + beta[t + 1][$0] })
                }
            }
        }
        return (0..<count).map { t in
            let joint = (0..<n).map { alpha[t][$0] + beta[t][$0] }
            let total = logSum(joint)
            return joint.map { exp($0 - total) }
        }
    }

    func logSum(_ values: [Double]) -> Double {
        guard let maximum = values.max(), maximum > -.infinity else { return -.infinity }
        return maximum + log(values.map { exp($0 - maximum) }.reduce(0, +))
    }
}
