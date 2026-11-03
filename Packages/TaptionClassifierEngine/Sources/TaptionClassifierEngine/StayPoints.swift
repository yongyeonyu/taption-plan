import Foundation

public struct StayPoint: Codable, Hashable, Sendable {
    public var interval: ClassifierInterval
    /// 체류 표본들의 중심점(첫 점이 아니다).
    public var center: ClassifierPoint
    public var sampleCount: Int
    public var meanAccuracy: Double

    public init(interval: ClassifierInterval, center: ClassifierPoint, sampleCount: Int, meanAccuracy: Double) {
        self.interval = interval
        self.center = center
        self.sampleCount = sampleCount
        self.meanAccuracy = meanAccuracy
    }

    /// 예전 장소 키(소수 넷째 자리 반올림). 등록 장소와 기존 기록을 잇는 별칭.
    public var legacyKey: String {
        String(format: "%.4f,%.4f", center.latitude, center.longitude)
    }
}

/// Zheng/Li(2008) 방식 stay point. 거리 창 안에 시간 창 이상 머문 표본 묶음.
/// 기준을 첫 점이 아니라 지금까지 묶인 표본의 중심으로 옮겨 GPS 흔들림에 덜 끊긴다.
public struct StayPointDetector: Sendable {
    public var radiusMeters: Double = 100
    public var minimumDwell: TimeInterval = 10 * 60
    public var maximumSampleGap: TimeInterval = 90 * 60
    public var maximumAccuracy: Double = 200

    public init(radiusMeters: Double = 100, minimumDwell: TimeInterval = 10 * 60, maximumSampleGap: TimeInterval = 90 * 60) {
        self.radiusMeters = radiusMeters
        self.minimumDwell = minimumDwell
        self.maximumSampleGap = maximumSampleGap
    }

    public func detect(_ samples: [ClassifierSample]) -> [StayPoint] {
        let located = samples
            .filter { $0.point != nil && ($0.horizontalAccuracy ?? 0) <= maximumAccuracy }
            .sorted { $0.timestamp < $1.timestamp }
        var result: [StayPoint] = []
        var group: [ClassifierSample] = []
        var sumLatitude = 0.0, sumLongitude = 0.0

        func flush() {
            defer { group = []; sumLatitude = 0; sumLongitude = 0 }
            guard let first = group.first, let last = group.last,
                  last.timestamp.timeIntervalSince(first.timestamp) >= minimumDwell else { return }
            let count = Double(group.count)
            result.append(StayPoint(
                interval: ClassifierInterval(start: first.timestamp, end: last.timestamp),
                center: ClassifierPoint(latitude: sumLatitude / count, longitude: sumLongitude / count),
                sampleCount: group.count,
                meanAccuracy: group.map { $0.horizontalAccuracy ?? 50 }.reduce(0, +) / count
            ))
        }

        for sample in located {
            let point = sample.point!
            if let last = group.last {
                let center = ClassifierPoint(latitude: sumLatitude / Double(group.count), longitude: sumLongitude / Double(group.count))
                let gapTooLarge = sample.timestamp.timeIntervalSince(last.timestamp) > maximumSampleGap
                if gapTooLarge || center.distance(to: point) > radiusMeters { flush() }
            }
            group.append(sample)
            sumLatitude += point.latitude
            sumLongitude += point.longitude
        }
        flush()
        return result
    }
}

/// 여러 날의 stay point를 ST-DBSCAN식으로 묶어 안정 장소 ID를 만든다.
public struct PlaceCluster: Codable, Hashable, Sendable {
    public var id: String
    public var center: ClassifierPoint
    public var visits: Int
    /// 방문 2회 이상이면 안정 장소.
    public var isStable: Bool { visits >= PlaceClusterer.minimumVisits }
    /// 이 묶음으로 들어온 예전 키들.
    public var aliases: Set<String>
}

public struct PlaceClusterer: Sendable {
    public static let minimumVisits = 2
    public var radiusMeters: Double = 50

    public init(radiusMeters: Double = 50) {
        self.radiusMeters = radiusMeters
    }

    /// 등록 장소(`anchors`: 키→좌표)는 먼저 자기 키로 묶음을 연다. 그래서 등록 장소의 키는 바뀌지 않는다.
    public func cluster(_ stays: [StayPoint], anchors: [String: ClassifierPoint] = [:]) -> (clusters: [PlaceCluster], assignment: [Int: String]) {
        var clusters = anchors.sorted { $0.key < $1.key }.map {
            PlaceCluster(id: $0.key, center: $0.value, visits: 0, aliases: [$0.key])
        }
        var assignment: [Int: String] = [:]
        for (index, stay) in stays.enumerated() {
            if let nearest = clusters.indices
                .map({ ($0, clusters[$0].center.distance(to: stay.center)) })
                .filter({ $0.1 <= radiusMeters })
                .min(by: { $0.1 < $1.1 })?.0 {
                let visits = Double(clusters[nearest].visits)
                if !anchors.keys.contains(clusters[nearest].id) {
                    clusters[nearest].center = ClassifierPoint(
                        latitude: (clusters[nearest].center.latitude * visits + stay.center.latitude) / (visits + 1),
                        longitude: (clusters[nearest].center.longitude * visits + stay.center.longitude) / (visits + 1)
                    )
                }
                clusters[nearest].visits += 1
                clusters[nearest].aliases.insert(stay.legacyKey)
                assignment[index] = clusters[nearest].id
            } else {
                let id = stay.legacyKey
                clusters.append(PlaceCluster(id: id, center: stay.center, visits: 1, aliases: [id]))
                assignment[index] = id
            }
        }
        return (clusters, assignment)
    }
}
