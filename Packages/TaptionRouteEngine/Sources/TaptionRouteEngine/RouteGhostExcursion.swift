import Foundation

/// 실내·지하에서 위치가 잠깐 다른 곳으로 튀었다 돌아온 묶음(유령 체류)을 찾는다 (CLN1110A01).
/// 원본 표본은 그대로 두고, 판정 근거는 `ghostExcursion` 결정으로 남긴다.
enum RouteGhostExcursion {
    /// 3분: 실내·지하 튐(1~2분)을 덮고, 재기준 최소(90초)의 두 배라 진짜 이동은 3분 넘게 머물면 남는다.
    /// 기록·방문으로 치는 최소 체류(5분)보다 짧아 기록이 될 만한 체류는 지우지 않는다.
    static let maximumDuration: TimeInterval = 3 * 60
    /// 200m: 실내 흔들림을 받아 주는 반경(150m)보다 멀어야 "다른 곳"으로 본다.
    static let minimumDistanceMeters = 200.0
    /// 40m/s(144km/h): 국내 도로 최고 속도(120km/h)보다 빠른 왕복은 땅 위에서 불가능하다.
    static let implausibleSpeedMetersPerSecond = 40.0
    /// 50m: 걷기 위치로 믿는 정확도 한계. 이보다 나쁘면 Wi-Fi·기지국 추정 위치다.
    static let poorAccuracyMeters = 50.0

    /// 6분: 떠나서 돌아오기까지 전체 시간 한계(머문 한계의 두 배). 몇 시간 띄엄띄엄 찍힌 실제 방문은 지우지 않는다 (REV1110A06).
    static let maximumRoundTrip: TimeInterval = 2 * maximumDuration

    /// `samples`는 시간순 경로 표본이다. 앞뒤 표본이 있는 묶음만 본다(끝에 남은 묶음은 돌아왔는지 모른다).
    /// 원본은 건드리지 않고 파생 경로에서 뺄 범위만 돌려준다.
    static func ranges(in samples: [RouteSample]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        // 마지막으로 남긴 표본. 유령 다음 표본을 유령과 견주지 않는다 (REV1110A06).
        var kept = 0
        var index = 1
        while index < samples.count - 1 {
            let anchor = samples[index]
            // 튄 첫 점에서만 묶음을 잰다. 머무는 동안 매 표본마다 다시 재지 않는다.
            guard Geo.distance(samples[kept].coordinate, anchor.coordinate) >= minimumDistanceMeters else {
                kept = index
                index += 1
                continue
            }
            var end = index + 1
            while end < samples.count,
                  Geo.distance(anchor.coordinate, samples[end].coordinate) < minimumDistanceMeters,
                  samples[end].timestamp.timeIntervalSince(anchor.timestamp) < maximumDuration {
                end += 1
            }
            if end < samples.count, isGhost(samples[index..<end], before: samples[kept], after: samples[end]) {
                result.append(index..<end)
                index = end
            } else {
                kept = index
                index += 1
            }
        }
        return result
    }

    private static func isGhost(_ run: ArraySlice<RouteSample>, before: RouteSample, after: RouteSample) -> Bool {
        guard let first = run.first, let last = run.last,
              last.timestamp.timeIntervalSince(first.timestamp) < maximumDuration,
              after.timestamp.timeIntervalSince(before.timestamp) < maximumRoundTrip,
              !run.contains(where: { $0.mode == .walking || $0.mode == .running }) else { return false }
        let out = Geo.distance(before.coordinate, first.coordinate)
        let back = Geo.distance(last.coordinate, after.coordinate)
        // 유령은 떠난 자리로 돌아온다. 굽은 선로·되돌아 나오는 길처럼 앞뒤가 서로 먼 진짜 이동은 남긴다.
        guard out >= minimumDistanceMeters, back >= minimumDistanceMeters,
              Geo.distance(before.coordinate, after.coordinate) < minimumDistanceMeters else { return false }
        let travelTime = first.timestamp.timeIntervalSince(before.timestamp)
            + after.timestamp.timeIntervalSince(last.timestamp)
        let impossible = travelTime <= 0 || (out + back) / travelTime > speedLimit(run, before, after)
        return impossible || isCoarseAmongPrecise(run, before, after)
    }

    /// 기차·비행기처럼 더 빠른 수단이 붙은 표본은 그 수단의 최고 속도까지 가능하다고 본다.
    private static func speedLimit(_ run: ArraySlice<RouteSample>, _ before: RouteSample, _ after: RouteSample) -> Double {
        (run + [before, after]).reduce(implausibleSpeedMetersPerSecond) { limit, sample in
            sample.mode == .unknown ? limit : max(limit, sample.mode.maximumSpeedMetersPerSecond)
        }
    }

    /// 정밀한 앞뒤 위치 사이에 낀, 이동 수단 근거 없는 저정확도 묶음만 추정 위치로 본다.
    /// 앞뒤도 거칠거나 탈것으로 움직이는 중이면 거친 정확도의 실제 왕복일 수 있다.
    private static func isCoarseAmongPrecise(_ run: ArraySlice<RouteSample>, _ before: RouteSample, _ after: RouteSample) -> Bool {
        let accuracy = run.map(\.horizontalAccuracyMeters).reduce(0, +) / Double(run.count)
        return accuracy > poorAccuracyMeters
            && before.horizontalAccuracyMeters <= poorAccuracyMeters && after.horizontalAccuracyMeters <= poorAccuracyMeters
            && run.allSatisfy { $0.mode == .unknown }
    }
}
