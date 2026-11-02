import Foundation

/// 탑승 전체를 철도와 도로 두 가설로 비교한다(ALG1102A01).
///
/// 역 그래프 위 좌→우 HMM을 Viterbi로 맞춰 각 정차가 역에서인지 역 사이에서인지 가르고,
/// 정차·통과·GPS 끊김·도보 접근·수직 이동·지하철 Wi-Fi의 로그 가능도비를 더한다.
/// 도로 그래프를 넣지 않으므로 도로 쪽은 항목별 빈도 추정이다. 라벨이 쌓이면 값을 조정한다.
enum RailRideLikelihood {
    struct Assessment: Equatable, Sendable {
        var logLikelihoodRatio: Double
        var stopsAtStations: Int
        var stopsBetweenStations: Int
        var passedStations: Int
        var gpsLossShare: Double
        var evidence: [String]
    }

    /// 이 값보다 커야 철도로 본다. 0이 아닌 것은 차가 흔하다는 사전 확률이다.
    static let minimumLogLikelihoodRatio = 1.0
    static let stoppedSpeed = 3.0
    static let minimumStopDuration: TimeInterval = 20
    private static let maximumStopSampleGap: TimeInterval = 3 * 60
    private static let passingSpeed = 8.0
    private static let passingRadiusMeters = 150.0
    private static let maximumAccuracyMeters = 100.0
    private static let accessWindow: TimeInterval = 10 * 60
    private static let verticalAccessKilopascals = 0.06
    private static let maximumSilenceForLoss: TimeInterval = 5 * 60

    /// `boarding`과 `alighting`은 첫 역을 떠난 시각과 마지막 역에 닿은 시각이다.
    static func assess(
        route: SubwayRoutePath,
        boarding: Date,
        alighting: Date,
        hasAlighted: Bool = true,
        boardingDwell: TimeInterval,
        readings: [SensorReading]
    ) -> Assessment {
        let ride = readings.filter { $0.timestamp >= boarding && $0.timestamp <= alighting }
        let stations = route.stops.compactMap(\.coordinate)
        let alignment = stations.count >= 2 ? align(ride.filter(hasFix), stations: stations) : []
        var atStations = Set<Int>()
        var between = 0
        for stop in stops(in: alignment) {
            if stop.state % 2 == 0 {
                let station = stop.state / 2
                if station > 0, station < stations.count - 1 { atStations.insert(station) }
            } else {
                between += 1
            }
        }
        let passed = passedStations(alignment, stations: stations, stoppedAt: atStations)
        let lossShare = gpsLossShare(ride)
        let before = readings.filter { $0.timestamp >= boarding.addingTimeInterval(-accessWindow) && $0.timestamp <= boarding }
        // 아직 타고 있으면 하차역 뒤 표본은 도보 접근의 근거가 아니다.
        let after = hasAlighted
            ? readings.filter { $0.timestamp > alighting && $0.timestamp <= alighting.addingTimeInterval(accessWindow) }
            : []

        var score = 0.0
        var evidence: [String] = []
        func add(_ value: Double, _ reason: String) {
            score += value
            evidence.append(reason)
        }
        if !atStations.isEmpty { add(1.1 * Double(min(3, atStations.count)), "역 정차 \(atStations.count)곳") }
        if between > 0 { add(-3.0 * Double(min(3, between)), "역 사이 정차 \(between)번") }
        if passed > 0 { add(-1.9 * Double(min(3, passed)), "멈추지 않고 지난 역 \(passed)곳") }
        if lossShare >= 0.35 {
            add(1.5, "GPS 끊김 \(Int(lossShare * 100))%")
        } else if lossShare >= 0.1 {
            add(0.5, "GPS 일부 끊김")
        } else if lossShare < 0.02, alighting.timeIntervalSince(boarding) >= 5 * 60 {
            add(-0.5, "GPS 끊김 없음")
        }
        switch access(before) {
        case .onFoot: add(1.5, "탑승역까지 걸어감")
        case .byVehicle: add(-1.5, "탑승역까지 차량 속도")
        case .unknown: break
        }
        switch access(after) {
        case .onFoot: add(1.0, "하차역에서 걸어 나감")
        case .byVehicle: add(-1.0, "하차역에서 차량 속도")
        case .unknown: break
        }
        if hasVerticalAccess(before) { add(1.0, "탑승역 수직 이동") }
        if hasVerticalAccess(after) { add(1.0, "하차역 수직 이동") }
        if ride.contains(where: { ($0.subwayWiFiObservationStreak ?? 0) >= 2 }) { add(3.0, "지하철 Wi-Fi") }
        if boardingDwell >= 3 * 60 { add(1.0, "탑승역 대기") }
        return Assessment(
            logLikelihoodRatio: score,
            stopsAtStations: atStations.count,
            stopsBetweenStations: between,
            passedStations: passed,
            gpsLossShare: lossShare,
            evidence: evidence
        )
    }

    private struct Aligned {
        var reading: SensorReading
        var state: Int
    }

    /// 차가 서 있던 곳들. 걷는 표본은 환승이지 정차가 아니고, 같은 상태 안에서 이어진 느린 표본만 한 번의 정차다.
    /// 표본이 길게 빈 곳은 서 있었는지 모르므로 잇지 않는다.
    private static func stops(in alignment: [Aligned]) -> [Aligned] {
        var result: [Aligned] = []
        var slowStart: Aligned?
        var previous: Aligned?
        func close(at time: Date) {
            if let start = slowStart, time.timeIntervalSince(start.reading.timestamp) >= minimumStopDuration {
                result.append(start)
            }
            slowStart = nil
        }
        for item in alignment {
            let time = item.reading.timestamp
            if let last = previous, time.timeIntervalSince(last.reading.timestamp) > maximumStopSampleGap {
                close(at: last.reading.timestamp)
            }
            previous = item
            if item.reading.motion == .walking || item.reading.motion == .running {
                close(at: time)
                continue
            }
            guard let speed = item.reading.speedMetersPerSecond, speed >= 0 else { continue }
            if speed <= stoppedSpeed {
                if let start = slowStart, start.state != item.state { close(at: time) }
                if slowStart == nil { slowStart = item }
            } else {
                close(at: time)
            }
        }
        if let last = previous { close(at: last.reading.timestamp) }
        return result
    }

    /// 상태: 짝수는 역 위, 홀수는 다음 역까지의 사이. 왼쪽에서 오른쪽으로만 움직인다.
    /// 지하에서 표본이 끊기면 역 여러 개를 한 번에 건너뛰므로, 건너뛴 상태 수만큼 벌점을 준다.
    private static func align(_ fixes: [SensorReading], stations: [GeoPoint]) -> [Aligned] {
        let stateCount = stations.count * 2 - 1
        guard !fixes.isEmpty else { return [] }
        let stay = -0.05, advance = -3.0
        var scores = [Double](repeating: -.infinity, count: stateCount)
        var back = [Int32](repeating: 0, count: stateCount * fixes.count)
        for (index, reading) in fixes.enumerated() {
            guard let point = reading.point else { continue }
            var next = [Double](repeating: -.infinity, count: stateCount)
            var reach = -Double.infinity
            var reachFrom = 0
            for state in 0..<stateCount {
                if state > 0 {
                    if scores[state - 1] >= reach {
                        reach = scores[state - 1]
                        reachFrom = state - 1
                    }
                    reach += advance
                }
                let observed = emission(point: point, speed: reading.speedMetersPerSecond, state: state, stations: stations)
                if index == 0 {
                    // 첫 표본은 탑승역이다.
                    next[state] = state == 0 ? observed : -.infinity
                    continue
                }
                let stayed = scores[state] + stay
                next[state] = max(stayed, reach) + observed
                back[index * stateCount + state] = Int32(reach > stayed ? reachFrom : state)
            }
            scores = next
        }
        var state = scores.indices.max { scores[$0] < scores[$1] } ?? 0
        var path = [Int](repeating: 0, count: fixes.count)
        for index in stride(from: fixes.count - 1, through: 0, by: -1) {
            path[index] = state
            if index > 0 { state = Int(back[index * stateCount + state]) }
        }
        return zip(fixes, path).map { Aligned(reading: $0, state: $1) }
    }

    private static func emission(point: GeoPoint, speed: Double?, state: Int, stations: [GeoPoint]) -> Double {
        let isStation = state % 2 == 0
        let distance = isStation
            ? meters(point, stations[state / 2])
            : segmentMeters(point, stations[state / 2], stations[state / 2 + 1])
        // 역 사이는 직선으로 근사하므로 폭을 넓게 둔다.
        let sigma = isStation ? 120.0 : 300.0
        var value = max(-12, -0.5 * pow(distance / sigma, 2)) - log(sigma / 120)
        if let speed, speed >= 0 {
            let isSlow = speed <= stoppedSpeed
            value += log(isStation ? (isSlow ? 0.6 : 0.4) : (isSlow ? 0.03 : 0.97))
        }
        return value
    }

    private static func passedStations(_ alignment: [Aligned], stations: [GeoPoint], stoppedAt: Set<Int>) -> Int {
        guard stations.count > 2 else { return 0 }
        return (1..<(stations.count - 1)).filter { station in
            guard !stoppedAt.contains(station) else { return false }
            let near = alignment.filter {
                guard let point = $0.reading.point else { return false }
                return meters(point, stations[station]) <= passingRadiusMeters
            }
            let speeds = near.compactMap(\.reading.speedMetersPerSecond).filter { $0 >= 0 }
            return !speeds.isEmpty && speeds.allSatisfy { $0 >= passingSpeed }
        }.count
    }

    /// 표본 간격을 시간으로 나눠 위치가 잡히지 않은 몫을 잰다. 기록이 아예 멈춘 긴 공백은 뺀다.
    private static func gpsLossShare(_ ride: [SensorReading]) -> Double {
        var lost: TimeInterval = 0
        var total: TimeInterval = 0
        for (reading, next) in zip(ride, ride.dropFirst()) {
            let gap = next.timestamp.timeIntervalSince(reading.timestamp)
            guard gap <= maximumSilenceForLoss else { continue }
            total += gap
            if !hasFix(reading) { lost += gap }
        }
        return total > 0 ? lost / total : 0
    }

    private enum Access {
        case onFoot, byVehicle, unknown
    }

    /// 지하철은 걸어서 타고 내린다. 끊김 없이 차량 속도로 닿았으면 도로 쪽 근거다.
    private static func access(_ readings: [SensorReading]) -> Access {
        if readings.contains(where: { $0.motion == .walking || $0.motion == .running }) { return .onFoot }
        let fixes = readings.filter(hasFix)
        guard fixes.count >= 2, fixes.count == readings.count else { return .unknown }
        let fast = fixes.compactMap(\.speedMetersPerSecond).filter { $0 >= passingSpeed }.count
        return fast >= 2 ? .byVehicle : .unknown
    }

    /// 차 안의 기압은 환기·터널로 흔들리므로 걷는 동안의 수직 이동만 센다. 같은 기압계 세션 안에서만 비교한다.
    private static func hasVerticalAccess(_ readings: [SensorReading]) -> Bool {
        let foot = readings.filter { ($0.motion == .walking || $0.motion == .running) && $0.pressureKilopascals != nil }
        let sessions = Dictionary(grouping: foot, by: { $0.altimeterSessionID?.uuidString ?? "" })
        return sessions.values.contains { group in
            let values = group.compactMap(\.pressureKilopascals)
            guard let low = values.min(), let high = values.max() else { return false }
            return high - low >= verticalAccessKilopascals
        }
    }

    private static func hasFix(_ reading: SensorReading) -> Bool {
        guard reading.gpsAvailable, let point = reading.point else { return false }
        return (0...maximumAccuracyMeters).contains(point.horizontalAccuracy)
    }

    private static func segmentMeters(_ point: GeoPoint, _ start: GeoPoint, _ end: GeoPoint) -> Double {
        let scale = cos(point.latitude * .pi / 180)
        let ax = (start.longitude - point.longitude) * 111_320 * scale, ay = (start.latitude - point.latitude) * 111_320
        let bx = (end.longitude - point.longitude) * 111_320 * scale, by = (end.latitude - point.latitude) * 111_320
        let dx = bx - ax, dy = by - ay
        let length = dx * dx + dy * dy
        let t = length > 0 ? min(1, max(0, -(ax * dx + ay * dy) / length)) : 0
        let x = ax + dx * t, y = ay + dy * t
        return (x * x + y * y).squareRoot()
    }

    private static func meters(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let x = (a.longitude - b.longitude) * 111_320 * cos(a.latitude * .pi / 180)
        let y = (a.latitude - b.latitude) * 111_320
        return (x * x + y * y).squareRoot()
    }
}
