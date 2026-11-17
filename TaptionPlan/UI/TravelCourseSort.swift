import Foundation

/// 동선 정리(TVY1116B01): 그날 코스의 핀 있는 곳들을 가까운 순서로 다시 줄 세운다. 길 찾기 없이 직선 거리로만 셈한다.
///
/// - 시각이 정해진 곳(예약·숙소·잠·이동·항공)은 자리도 시각도 그대로다. 다른 곳은 그것을 넘어가지 않는다(그 사이 구간 안에서만 바뀐다).
/// - 일정이 서로 겹친 구간은 그대로 두고 한 줄로 알린다.
/// - 핀 없는 곳과 첫 곳은 순서의 제자리에 둔다.
/// - 시각은 `TravelCoursePlanner.reorder`와 같은 규칙으로 다시 잡는다: 구간의 첫 시작과 일정 사이 틈은 자리에, 길이는 일정을 따라간다.
enum TravelCourseSort {
    struct Stop: Equatable {
        var id: String
        var startMinute: Int
        var endMinute: Int
        var latitude: Double?
        var longitude: Double?
        /// 예약·숙소·잠·캘린더 고정처럼 시각을 바꾸면 안 되는 곳.
        var isTimeFixed = false

        var hasPin: Bool { latitude != nil && longitude != nil }
    }

    struct Plan: Equatable {
        /// 정리한 뒤의 순서(일정 번호).
        var order: [String]
        /// 일정별로 옮길 분(0인 것은 없다).
        var moves: [String: Int]
        var beforeMeters: Double
        var afterMeters: Double
    }

    /// 이만큼(m)도 줄지 않으면 바꾸지 않는다. 화면에 0.1 km 단위로 보이므로 그보다 작은 차이는 같은 값으로 보인다.
    static let minimumGain = 100.0

    /// 시간 순서로 놓인 그날 코스를 정리한 결과. 줄어드는 것이 없으면 nil.
    static func plan(_ stops: [Stop]) -> Plan? {
        let before = length(stops)
        let sorted = sorted(stops)
        let after = length(sorted)
        guard before - after >= minimumGain else { return nil }
        let moves = moves(from: stops, to: sorted)
        return moves.isEmpty ? nil : Plan(order: sorted.map(\.id), moves: moves, beforeMeters: before, afterMeters: after)
    }

    /// 핀 있는 곳을 순서대로 이은 직선 거리(m). 핀 없는 곳은 건너뛴다.
    static func length(_ stops: [Stop]) -> Double {
        var total = 0.0, last: Stop?
        for stop in stops where stop.hasPin {
            if let last { total += meters(last, stop) }
            last = stop
        }
        return total
    }

    /// 가까운 순서로 줄 세운 코스. 가장 가까운 이웃으로 잡은 것과 지금 순서를 각각 2-opt로 다듬어 짧은 쪽을 쓴다(지금보다 길어지지 않는다).
    static func sorted(_ stops: [Stop]) -> [Stop] {
        let groups = movableGroups(stops)
        guard groups.contains(where: { $0.count > 1 }) else { return stops }
        let candidates = [improved(nearestNeighbor(stops, groups: groups), groups: groups), improved(stops, groups: groups)]
        return candidates.min { length($0) < length($1) } ?? stops
    }

    /// 순서를 바꿔도 되는 자리들: 시각이 정해진 곳 사이 구간마다, 핀이 있고 첫 곳이 아닌 자리.
    /// 앞 일정과 겹치는 일정이 있는 구간은 뺀다(TVM1117A02): 다시 잡을 때 겹침을 펴면 구간이 길어져 뒤의 고정 일정을 넘는다.
    static func movableGroups(_ stops: [Stop]) -> [[Int]] {
        segments(stops).filter { !$0.overlaps && !$0.indices.isEmpty }.map(\.indices)
    }

    /// 겹친 일정이 있어 그대로 두는 구간 가운데, 겹치지 않았으면 정리했을 것(바꿀 자리가 둘 이상).
    static func overlappedGroups(_ stops: [Stop]) -> [[Int]] {
        segments(stops).filter { $0.overlaps && $0.indices.count > 1 }.map(\.indices)
    }

    /// 시각이 정해진 곳 사이 구간마다 바꿀 수 있는 자리와, 앞 일정과 겹치는 일정이 있는지.
    private static func segments(_ stops: [Stop]) -> [(indices: [Int], overlaps: Bool)] {
        var segments: [(indices: [Int], overlaps: Bool)] = [([], false)]
        for (index, stop) in stops.enumerated() {
            if stop.isTimeFixed {
                segments.append(([], false))
                continue
            }
            if index > 0, !stops[index - 1].isTimeFixed, stop.startMinute < stops[index - 1].endMinute { segments[segments.count - 1].overlaps = true }
            if index > 0, stop.hasPin { segments[segments.count - 1].indices.append(index) }
        }
        return segments
    }

    /// 「동선 정리」 단추를 보일지: 정리할 구간이 있거나, 겹쳐서 그대로 둔다고 알릴 구간이 있으면.
    static func canSort(_ stops: [Stop]) -> Bool {
        movableGroups(stops).contains { $0.count > 1 } || !overlappedGroups(stops).isEmpty
    }

    /// 누른 뒤 보일 것(대표 결정 2026-11-18): 정리안(겹친 구간을 그대로 뒀으면 한 줄 안내를 붙임), 겹친 구간 안내만, 이미 가까운 순서.
    enum Outcome: Equatable {
        case plan(Plan, leftOverlap: Bool)
        case overlapOnly
        case alreadySorted
    }

    static func outcome(_ stops: [Stop]) -> Outcome {
        let leftOverlap = !overlappedGroups(stops).isEmpty
        if let plan = plan(stops) { return .plan(plan, leftOverlap: leftOverlap) }
        return leftOverlap ? .overlapOnly : .alreadySorted
    }

    private static func nearestNeighbor(_ stops: [Stop], groups: [[Int]]) -> [Stop] {
        var out = stops
        for group in groups {
            var left = group.map { stops[$0] }
            for slot in group {
                // 바로 앞의 핀 있는 곳에서 가장 가까운 곳을 고른다. 앞에 핀이 없으면 지금 순서대로.
                let from = out[..<slot].last(where: \.hasPin)
                let pick = from.flatMap { from in left.indices.min { meters(from, left[$0]) < meters(from, left[$1]) } } ?? 0
                out[slot] = left.remove(at: pick)
            }
        }
        return out
    }

    /// 2-opt: 한 구간 안에서 자리 묶음을 뒤집어 전체 길이가 줄면 받아들인다. 더 줄지 않을 때까지(최대 30바퀴).
    private static func improved(_ stops: [Stop], groups: [[Int]]) -> [Stop] {
        var best = stops, bestLength = length(stops)
        for _ in 0..<30 {
            var didImprove = false
            for group in groups where group.count > 1 {
                for low in 0..<(group.count - 1) {
                    for high in (low + 1)..<group.count {
                        var trial = best
                        for offset in 0...(high - low) { trial[group[low + offset]] = best[group[high - offset]] }
                        let trialLength = length(trial)
                        if trialLength < bestLength - 1 {
                            best = trial
                            bestLength = trialLength
                            didImprove = true
                        }
                    }
                }
            }
            if !didImprove { break }
        }
        return best
    }

    /// 새 순서에 맞춰 일정별로 옮길 분. 시각이 정해진 곳 사이 구간마다 첫 시작에서 차례로 놓는다.
    static func moves(from old: [Stop], to new: [Stop]) -> [String: Int] {
        guard old.count == new.count else { return [:] }
        var moves: [String: Int] = [:], cursor: Int?
        for index in old.indices {
            guard !old[index].isTimeFixed else {
                cursor = nil
                continue
            }
            let start = cursor ?? old[index].startMinute
            let stop = new[index]
            if start != stop.startMinute { moves[stop.id] = start - stop.startMinute }
            let gap = index + 1 < old.count ? max(0, old[index + 1].startMinute - old[index].endMinute) : 0
            cursor = start + (stop.endMinute - stop.startMinute) + gap
        }
        return moves
    }

    /// 두 곳 사이 직선 거리(m, 하버사인).
    static func meters(_ a: Stop, _ b: Stop) -> Double {
        guard let lat1 = a.latitude, let lon1 = a.longitude, let lat2 = b.latitude, let lon2 = b.longitude else { return 0 }
        let radian = Double.pi / 180
        let dLat = (lat2 - lat1) * radian, dLon = (lon2 - lon1) * radian
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1 * radian) * cos(lat2 * radian) * sin(dLon / 2) * sin(dLon / 2)
        return 6_371_000 * 2 * atan2(sqrt(h), sqrt(max(0, 1 - h)))
    }

    /// 화면에 보일 거리: 0.1 km 단위.
    static func kilometers(_ meters: Double) -> String {
        String(format: "%.1f", (meters / 100).rounded() / 10)
    }
}
