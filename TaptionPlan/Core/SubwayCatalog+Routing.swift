import Foundation

/// 역 사이 길 찾기(SUB1111A01). 정거장 수가 아니라 거리와 환승 벌점으로 고른다.
extension SubwayStationCatalog {
    /// 환승 한 번을 이만큼(m) 더 가는 것으로 친다. 정거장 수만 세면 마곡나루→노량진이 9호선 직통 대신
    /// 공항철도·1호선으로 돌아간다(SUB1111A01).
    private static let transferPenaltyMeters = 1_500.0

    /// 역 사이 직선 거리와 환승 벌점의 합이 가장 작은 길.
    static func shortestPath(
        from starts: [Int],
        to ends: [Int]
    ) -> [Int]? {
        let destinations = Set(ends)
        var cost = Array(repeating: Double.infinity, count: stations.count)
        var parents = Array(repeating: -1, count: stations.count)
        var queue = CostQueue()
        for start in starts where cost[start] == .infinity {
            cost[start] = 0
            parents[start] = start
            queue.push(start, cost: 0)
        }
        while let (current, reached) = queue.pop() {
            guard reached <= cost[current] else { continue }
            if destinations.contains(current) {
                var result: [Int] = []
                var node = current
                while parents[node] != node {
                    result.append(node)
                    node = parents[node]
                }
                result.append(node)
                return result.reversed()
            }
            for next in adjacency[current] {
                let total = reached + edgeMeters(current, next)
                guard total < cost[next] else { continue }
                cost[next] = total
                parents[next] = current
                queue.push(next, cost: total)
            }
        }
        return nil
    }

    /// 좌표가 빠진 역 사이는 도심 평균 역 간격으로 친다.
    private static let unknownEdgeMeters = 1_200.0

    private static func edgeMeters(_ from: Int, _ to: Int) -> Double {
        let a = stations[from], b = stations[to]
        guard a.lineName == b.lineName else { return transferPenaltyMeters }
        guard let aLatitude = a.latitude, let aLongitude = a.longitude,
              let bLatitude = b.latitude, let bLongitude = b.longitude else { return unknownEdgeMeters }
        return PlanarDistance.meters(
            GeoPoint(latitude: aLatitude, longitude: aLongitude, altitude: 0, horizontalAccuracy: 0, verticalAccuracy: 0),
            GeoPoint(latitude: bLatitude, longitude: bLongitude, altitude: 0, horizontalAccuracy: 0, verticalAccuracy: 0)
        )
    }

    /// 가장 싼 역을 먼저 꺼내는 최소 힙.
    private struct CostQueue {
        private var items: [(node: Int, cost: Double)] = []

        mutating func push(_ node: Int, cost: Double) {
            items.append((node, cost))
            var child = items.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard items[child].cost < items[parent].cost else { break }
                items.swapAt(child, parent)
                child = parent
            }
        }

        mutating func pop() -> (Int, Double)? {
            guard let top = items.first else { return nil }
            let last = items.removeLast()
            if !items.isEmpty {
                items[0] = last
                var parent = 0
                while true {
                    let left = 2 * parent + 1, right = left + 1
                    var smallest = parent
                    if left < items.count, items[left].cost < items[smallest].cost { smallest = left }
                    if right < items.count, items[right].cost < items[smallest].cost { smallest = right }
                    guard smallest != parent else { break }
                    items.swapAt(parent, smallest)
                    parent = smallest
                }
            }
            return (top.node, top.cost)
        }
    }
}
