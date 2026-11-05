import CoreLocation
import Foundation

/// 영상으로 만들 구간(PLR1104A02). `day`는 지금까지의 하루 재생을 그대로 쓴다.
enum MapHomeRangePreset: String, CaseIterable, Identifiable, Sendable {
    case day, week, month, year, custom

    /// 일 단위로 읽어 압축하는 1년(윤년)까지 받는다.
    static let maximumDays = 366

    /// 저장값을 읽는다. 예전 빌드의 `recentSevenDays`·`lastMonth`도 새 값으로 옮긴다.
    static func stored(_ raw: String) -> Self {
        switch raw {
        case "recentSevenDays": .week
        case "lastMonth": .month
        default: Self(rawValue: raw) ?? .day
        }
    }

    /// 자동 길이(대표 선택 PLR1104A01): 여행 60초, 한 달 90초, 그보다 길면 2분.
    static func automaticSeconds(forDays days: Int) -> Int {
        if days <= 14 { return 60 }
        return days <= 31 ? 90 : 120
    }

    var id: String { rawValue }

    func span(
        selectedDate: Date,
        customStart: Date,
        customEnd: Date,
        now: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> TimeSpan {
        let today = calendar.startOfDay(for: now)
        func day(_ value: Int, from date: Date) -> Date {
            calendar.date(byAdding: .day, value: value, to: date) ?? date
        }
        // 오늘까지 넣어 달력으로 한 달·한 해만큼 거슬러 간다(`week`의 7일과 같은 세는 법).
        func back(_ unit: Calendar.Component) -> Date {
            day(1, from: calendar.date(byAdding: unit, value: -1, to: today) ?? today)
        }
        switch self {
        case .day:
            let start = calendar.startOfDay(for: selectedDate)
            return TimeSpan(start: start, end: min(day(1, from: start), now))
        case .week:
            return TimeSpan(start: day(-6, from: today), end: now)
        case .month:
            return TimeSpan(start: back(.month), end: now)
        case .year:
            return TimeSpan(start: back(.year), end: now)
        case .custom:
            let start = calendar.startOfDay(for: min(customStart, customEnd))
            let lastDay = calendar.startOfDay(for: max(customStart, customEnd))
            let limited = min(lastDay, day(Self.maximumDays - 1, from: start))
            return TimeSpan(start: start, end: min(day(1, from: limited), now))
        }
    }
}

/// 구간을 고른 영상 길이에 맞춘 불변 계획. 원본은 건드리지 않고 파생 경로만 담는다(PLR1104A01).
///
/// 머문 곳은 짧은 장면으로 줄이고 남은 시간을 이동 거리의 로그 비율로 나눈다.
/// 그래서 기간이 길어져도 프레임 수는 영상 길이로만 정해진다.
struct MapHomeRangeTripPlan: Sendable {
    struct Sample: Hashable, Sendable {
        var time: TimeInterval
        var latitude: Double
        var longitude: Double
    }

    struct Point: Hashable, Sendable {
        var latitude: Double
        var longitude: Double
    }

    enum Kind: Hashable, Sendable { case stay, move, flight }

    struct Item: Sendable {
        let kind: Kind
        let startTime: TimeInterval
        let endTime: TimeInterval
        let points: [Point]
        /// 점마다 구간 시작부터 누적한 거리(m).
        let cumulativeMeters: [Double]
        let cameraDistance: Double
        var startSecond = 0.0
        var endSecond = 0.0
        var startMeters = 0.0

        var meters: Double { cumulativeMeters.last ?? 0 }
        var speed: Double { meters / max(1, endTime - startTime) }
    }

    struct RoutePoint: Hashable, Sendable {
        let second: Double
        let latitude: Double
        let longitude: Double
    }

    struct Position: Sendable {
        let point: Point
        let time: TimeInterval
        let meters: Double
        let kind: Kind
        let speed: Double
    }

    enum Tuning {
        static let stayRadiusMeters = 150.0
        static let stayMinimumSeconds: TimeInterval = 15 * 60
        static let mergeStayMeters = 300.0
        static let ignoredMoveMeters = 200.0
        static let trustedAccuracyMeters = 150.0
        /// 공유 영상에서 집·직장 등 주변을 빼는 반경(대표 선택 PLR1104A01).
        static let hiddenPlaceMeters = 500.0
        /// 이웃 표본 사이가 이보다 멀면 따로 떼어 긴 이동으로 본다.
        static let longJumpMeters = 100_000.0
        static let flightSpeed = 60.0
        static let flightSegments = 48
        static let maximumRoutePoints = 1_200
        /// 하루 표본을 줄이는 기준. 움직이지 않아도 이 간격마다 남겨 머문 곳을 알아본다.
        static let sampleMinimumMeters = 25.0
        static let sampleMinimumSeconds: TimeInterval = 5 * 60
        static let maximumDaySamples = 2_000
        /// 구간 하나가 영상에서 받는 최소 시간. 넘치면 가까운 왕복부터 합친다(PLR1104A02).
        static let minimumItemSeconds = 0.4
        static let coarsenStartMeters = 500.0
        static let earthSpanMeters = 40_000_000.0
        /// 이 허용 오차부터는 비행 곡선도 줄인다.
        static let flightSimplifyMeters = 10_000.0
        static let staySeconds = 0.45
        static let stayShareLimit = 0.25
        static let moveShareLimit = 0.3
        static let flightSecondsLimit = 5.0
        static let overviewSeconds = 2.0
        static let overviewHoldSeconds = 0.5
        static let closestCameraDistance = 1_200.0
        static let farthestCameraDistance = 30_000_000.0
        static let stayCameraDistance = 2_000.0
        /// 영상 지도(360×640pt) 가로세로 비와, 보이는 세로 범위에 곱할 카메라 거리 비율(시야각 1.5배 × 여유 1.3).
        static let aspect = 0.5625
        static let cameraRatio = 1.95
        static let cameraLookaheadSeconds = 0.35
        static let cameraCenterSeconds = 0.35
        static let zoomOutSeconds = 0.45
        static let zoomInSeconds = 1.6
    }

    let durationSeconds: Double
    let span: TimeSpan
    let items: [Item]
    let route: [RoutePoint]
    let totalMeters: Double
    /// 합쳐서 빠진 왕복까지 계기판 거리에 넣는 배율. 합치지 않았으면 1이다.
    var meterScale = 1.0
    let overviewCenter: Point
    let overviewDistance: Double

    var bodySeconds: Double { durationSeconds - Tuning.overviewSeconds }
    var dayCount: Int {
        max(1, Int((span.duration / 86_400).rounded(.up)))
    }

    // MARK: - 표본 압축

    /// 하루치 측정값에서 믿을 수 있는 위치만 남긴다. 그날의 `SensorReading`은 곧바로 버려도 된다.
    static func samples(from readings: [SensorReading]) -> [Sample] {
        readings.compactMap { reading in
            guard let point = reading.point,
                  reading.locationFixQuality != .approximate,
                  point.horizontalAccuracy >= 0,
                  point.horizontalAccuracy <= Tuning.trustedAccuracyMeters else { return nil }
            return Sample(
                time: reading.timestamp.timeIntervalSinceReferenceDate,
                latitude: point.latitude,
                longitude: point.longitude
            )
        }
    }

    /// 여러 날을 메모리에 쌓기 전에 줄인다. 원본이 아니라 파생 경로만 쓰므로 원본은 그대로다(PLR1104A02).
    static func thinned(_ samples: [Sample]) -> [Sample] {
        guard samples.count > 2, let first = samples.first, let last = samples.last else { return samples }
        var kept = [first]
        for sample in samples.dropFirst().dropLast() {
            let previous = kept[kept.count - 1]
            if sample.time - previous.time >= Tuning.sampleMinimumSeconds
                || meters(previous.point, sample.point) >= Tuning.sampleMinimumMeters {
                kept.append(sample)
            }
        }
        kept.append(last)
        guard kept.count > Tuning.maximumDaySamples else { return kept }
        let step = Double(kept.count - 1) / Double(Tuning.maximumDaySamples - 1)
        return (0..<Tuning.maximumDaySamples).map { kept[Int((Double($0) * step).rounded())] }
    }

    // MARK: - 계획 만들기

    static func make(
        samples rawSamples: [Sample],
        span: TimeSpan,
        durationSeconds: Double,
        hiddenPlaces: [Point] = []
    ) -> Self? {
        // 이상점을 먼저 지운 뒤 가린다. 표본 자체를 빼므로 경로·머문 곳·전체 경로 어디에도 남지 않는다.
        let ordered = removingIsolatedJumps(rawSamples.sorted { $0.time < $1.time }).filter { sample in
            !hiddenPlaces.contains { meters($0, sample.point) <= Tuning.hiddenPlaceMeters }
        }
        guard let first = ordered.first, durationSeconds > Tuning.overviewSeconds else { return nil }
        var legs = legs(from: ordered)
        if legs.isEmpty {
            let point = Point(latitude: first.latitude, longitude: first.longitude)
            legs = [Leg(kind: .stay, startTime: first.time, endTime: ordered.last?.time ?? first.time, points: [point])]
        }
        let limit = max(8, Int((durationSeconds - Tuning.overviewSeconds) / Tuning.minimumItemSeconds))
        let fullMeters = legs.reduce(0) { $0 + pathMeters($1.points) }
        let isCoarsened = legs.count > limit
        legs = simplified(coarsened(legs, limit: limit))
        var items = legs.map(Self.item)
        allocate(&items, bodySeconds: durationSeconds - Tuning.overviewSeconds)
        let route = routePoints(items)
        let bounds = Bounds(items.flatMap(\.points))
        let shownMeters = items.last.map { $0.startMeters + $0.meters } ?? 0
        let meterScale = isCoarsened && shownMeters > 0 ? fullMeters / shownMeters : 1
        return Self(
            durationSeconds: durationSeconds,
            span: span,
            items: items,
            route: route,
            totalMeters: shownMeters * meterScale,
            meterScale: meterScale,
            overviewCenter: bounds.center,
            overviewDistance: bounds.cameraDistance
        )
    }

    /// 앞뒤와 멀리 떨어졌다가 곧바로 돌아오는 한 점(GPS 튐)만 뺀다.
    static func removingIsolatedJumps(_ samples: [Sample]) -> [Sample] {
        guard samples.count >= 3 else { return samples }
        var kept = [samples[0]]
        for index in 1..<(samples.count - 1) {
            let previous = kept[kept.count - 1], current = samples[index], next = samples[index + 1]
            let out = meters(previous.point, current.point), back = meters(current.point, next.point)
            let isJump = out > 2_000 && back > 2_000
                && meters(previous.point, next.point) < min(out, back) / 4
                && out / max(1, current.time - previous.time) > 100
            if !isJump { kept.append(current) }
        }
        kept.append(samples[samples.count - 1])
        return kept
    }

    private struct Leg {
        var kind: Kind
        var startTime: TimeInterval
        var endTime: TimeInterval
        var points: [Point]
    }

    /// 표본을 머문 곳과 이동으로 나눈다. 이동의 양 끝은 앞뒤 머문 곳 좌표에 잇는다.
    private static func legs(from samples: [Sample]) -> [Leg] {
        var legs: [Leg] = []
        var moving: [Sample] = []

        func flushMove(to next: Point?, endTime: TimeInterval?) {
            var points = moving.map(\.point)
            var start = moving.first?.time ?? endTime ?? 0
            var end = moving.last?.time ?? start
            if let last = legs.last, last.kind == .stay, let anchor = last.points.first {
                points.insert(anchor, at: 0)
                start = last.endTime
            }
            if let next, let endTime {
                points.append(next)
                end = endTime
            }
            moving = []
            guard points.count >= 2 else { return }
            legs += splitLongJumps(points: points, times: timeline(points.count, start: start, end: end))
        }

        var index = 0
        while index < samples.count {
            var end = index + 1
            while end < samples.count,
                  meters(samples[index].point, samples[end].point) <= Tuning.stayRadiusMeters { end += 1 }
            let stayed = samples[end - 1].time - samples[index].time
            guard stayed >= Tuning.stayMinimumSeconds else {
                moving.append(samples[index])
                index += 1
                continue
            }
            let slice = samples[index..<end]
            let center = Point(
                latitude: slice.map(\.latitude).reduce(0, +) / Double(slice.count),
                longitude: slice.map(\.longitude).reduce(0, +) / Double(slice.count)
            )
            flushMove(to: center, endTime: samples[index].time)
            if let last = legs.last, last.kind == .stay, let anchor = last.points.first,
               meters(anchor, center) <= Tuning.mergeStayMeters {
                legs[legs.count - 1].endTime = samples[end - 1].time
            } else {
                legs.append(Leg(kind: .stay, startTime: samples[index].time, endTime: samples[end - 1].time, points: [center]))
            }
            index = end
        }
        flushMove(to: nil, endTime: nil)
        return legs.filter { $0.kind == .stay || pathMeters($0.points) >= Tuning.ignoredMoveMeters }
    }

    private static func timeline(_ count: Int, start: TimeInterval, end: TimeInterval) -> [TimeInterval] {
        guard count > 1 else { return [start] }
        return (0..<count).map { start + (end - start) * Double($0) / Double(count - 1) }
    }

    /// 표본 사이가 아주 먼 곳을 따로 뗀다. 빠르면 비행으로 보고 대권 경로로 잇는다.
    private static func splitLongJumps(points: [Point], times: [TimeInterval]) -> [Leg] {
        var legs: [Leg] = []
        var current = [points[0]]
        var currentStart = times[0]
        for index in 1..<points.count {
            let distance = meters(points[index - 1], points[index])
            guard distance >= Tuning.longJumpMeters else {
                current.append(points[index])
                continue
            }
            if current.count >= 2 {
                legs.append(Leg(kind: .move, startTime: currentStart, endTime: times[index - 1], points: current))
            }
            let duration = max(1, times[index] - times[index - 1])
            let isFlight = distance / duration >= Tuning.flightSpeed
            legs.append(Leg(
                kind: isFlight ? .flight : .move,
                startTime: times[index - 1],
                endTime: times[index],
                points: isFlight
                    ? greatCircle(from: points[index - 1], to: points[index], segments: Tuning.flightSegments)
                    : [points[index - 1], points[index]]
            ))
            current = [points[index]]
            currentStart = times[index]
        }
        if current.count >= 2 {
            legs.append(Leg(kind: .move, startTime: currentStart, endTime: times[times.count - 1], points: current))
        }
        return legs
    }

    /// 구간이 영상 시간에 비해 너무 많으면 가까운 곳을 오간 왕복부터 합친다.
    /// 반경 안으로 돌아온 머문 곳과 그 사이 이동을 빼므로 멀리 간 이동만 남는다.
    private static func coarsened(_ legs: [Leg], limit: Int) -> [Leg] {
        var result = legs
        var radius = Tuning.coarsenStartMeters
        while result.count > limit, radius <= Tuning.earthSpanMeters {
            result = merged(legs, radius: radius)
            radius *= 2
        }
        return result
    }

    private static func merged(_ legs: [Leg], radius: Double) -> [Leg] {
        var result: [Leg] = []
        var pending: [Leg] = []
        var anchor: Point?
        for leg in legs {
            guard leg.kind == .stay, let center = leg.points.first else {
                pending.append(leg)
                continue
            }
            if let anchor, meters(anchor, center) <= radius, result.last?.kind == .stay {
                result[result.count - 1].endTime = leg.endTime
            } else {
                result += connected(pending, from: anchor)
                result.append(leg)
                anchor = center
            }
            pending = []
        }
        return result + connected(pending, from: anchor)
    }

    /// 빠진 머문 곳 뒤의 이동도 남은 머문 곳에서 시작하게 잇는다. 어긋남은 합치는 반경 안이다.
    private static func connected(_ moves: [Leg], from anchor: Point?) -> [Leg] {
        guard let anchor, var first = moves.first, first.points.first != anchor else { return moves }
        first.points.insert(anchor, at: 0)
        return [first] + moves.dropFirst()
    }

    /// 전체 경로 점이 상한 안에 들 때까지 허용 오차를 늘린다. 이동을 다 줄여도 넘치면 그대로 돌려준다.
    private static func simplified(_ legs: [Leg]) -> [Leg] {
        var tolerance = 15.0
        var result = legs
        while true {
            result = legs.map { leg in
                guard leg.kind == .move || (leg.kind == .flight && tolerance >= Tuning.flightSimplifyMeters) else { return leg }
                var leg = leg
                leg.points = douglasPeucker(leg.points, tolerance: tolerance)
                return leg
            }
            if result.reduce(0, { $0 + $1.points.count }) <= Tuning.maximumRoutePoints { return result }
            if tolerance > Tuning.earthSpanMeters { return result }
            tolerance *= 2
        }
    }

    private static func item(_ leg: Leg) -> Item {
        var cumulative = [0.0]
        for (from, to) in zip(leg.points, leg.points.dropFirst()) {
            cumulative.append((cumulative.last ?? 0) + meters(from, to))
        }
        return Item(
            kind: leg.kind,
            startTime: leg.startTime,
            endTime: leg.endTime,
            points: leg.points,
            cumulativeMeters: cumulative,
            cameraDistance: leg.kind == .stay ? Tuning.stayCameraDistance : Bounds(leg.points).cameraDistance
        )
    }

    /// 머문 곳에 짧은 장면을 주고, 남은 시간을 이동 거리의 로그 비율로 나눈다.
    private static func allocate(_ items: inout [Item], bodySeconds: Double) {
        let stays = items.filter { $0.kind == .stay }.count
        let moves = items.count - stays
        let stayShare = stays == 0 ? 0 : min(Tuning.staySeconds, bodySeconds * Tuning.stayShareLimit / Double(stays))
        let available = bodySeconds - (moves > 0 ? stayShare * Double(stays) : 0)
        let weights = items.map { $0.kind == .stay ? 0 : log2(1 + $0.meters / 1_000) + 0.25 }
        let limits = items.map { item -> Double in
            let share = moves > 1 ? available * Tuning.moveShareLimit : available
            return item.kind == .flight ? min(Tuning.flightSecondsLimit, share) : share
        }
        // 상한에 걸린 구간은 묶어 두고 나머지에 다시 나눈다.
        var seconds = [Double](repeating: 0, count: items.count)
        var capped = Set<Int>()
        while true {
            let open = items.indices.filter { weights[$0] > 0 && !capped.contains($0) }
            let remaining = available - capped.reduce(0) { $0 + limits[$1] }
            let total = open.reduce(0) { $0 + weights[$1] }
            guard total > 0, remaining > 0 else { break }
            var changed = false
            for index in open {
                let share = remaining * weights[index] / total
                if share > limits[index] {
                    capped.insert(index)
                    changed = true
                } else {
                    seconds[index] = share
                }
            }
            if !changed { break }
        }
        for index in capped { seconds[index] = limits[index] }
        // 모두 상한에 걸려 시간이 남으면 일반 이동, 없으면 머문 곳, 그것도 없으면 비행이 받는다.
        let leftover = max(0, available - seconds.reduce(0, +))
        let ordinary = items.indices.filter { items[$0].kind == .move }
        let ordinaryTotal = ordinary.reduce(0) { $0 + seconds[$1] }
        for index in items.indices {
            var value = moves > 0 && items[index].kind == .stay ? stayShare : seconds[index]
            if ordinaryTotal > 0 {
                if items[index].kind == .move { value += leftover * seconds[index] / ordinaryTotal }
            } else if stays > 0 {
                if items[index].kind == .stay { value += (moves > 0 ? leftover : bodySeconds) / Double(stays) }
            } else if moves > 0 {
                value += leftover / Double(moves)
            }
            place(&items, index, seconds: value)
        }
        if !items.isEmpty { items[items.count - 1].endSecond = bodySeconds }
    }

    private static func place(_ items: inout [Item], _ index: Int, seconds: Double) {
        let start = index == 0 ? 0 : items[index - 1].endSecond
        items[index].startSecond = start
        items[index].endSecond = start + seconds
        items[index].startMeters = index == 0 ? 0 : items[index - 1].startMeters + items[index - 1].meters
    }

    private static func routePoints(_ items: [Item]) -> [RoutePoint] {
        items.flatMap { item -> [RoutePoint] in
            guard item.kind != .stay, item.meters > 0 else { return [] }
            return item.points.indices.map { index in
                let progress = item.cumulativeMeters[index] / item.meters
                return RoutePoint(
                    second: item.startSecond + (item.endSecond - item.startSecond) * inverseEase(progress),
                    latitude: item.points[index].latitude,
                    longitude: item.points[index].longitude
                )
            }
        }
    }

    // MARK: - 영상 시각 → 위치

    func position(atSecond second: Double) -> Position? {
        guard let item = item(atSecond: second) else { return nil }
        let width = item.endSecond - item.startSecond
        let linear = width > 0 ? min(1, max(0, (second - item.startSecond) / width)) : 1
        let progress = Self.ease(linear)
        let time = item.startTime + (item.endTime - item.startTime) * linear
        return Position(
            point: Self.point(on: item, progress: progress),
            time: time,
            meters: (item.startMeters + item.meters * progress) * meterScale,
            kind: item.kind,
            speed: item.speed
        )
    }

    private func item(atSecond second: Double) -> Item? {
        var lower = 0, upper = items.count - 1
        guard upper >= 0 else { return nil }
        while lower < upper {
            let middle = (lower + upper) / 2
            if items[middle].endSecond <= second { lower = middle + 1 } else { upper = middle }
        }
        return items[lower]
    }

    private static func point(on item: Item, progress: Double) -> Point {
        guard item.points.count > 1, item.meters > 0 else { return item.points[0] }
        let target = item.meters * progress
        var lower = 1, upper = item.points.count - 1
        while lower < upper {
            let middle = (lower + upper) / 2
            if item.cumulativeMeters[middle] < target { lower = middle + 1 } else { upper = middle }
        }
        let start = item.cumulativeMeters[lower - 1], end = item.cumulativeMeters[lower]
        let ratio = end > start ? (target - start) / (end - start) : 0
        let from = item.points[lower - 1], to = item.points[lower]
        return Point(
            latitude: from.latitude + (to.latitude - from.latitude) * ratio,
            longitude: normalizedLongitude(from.longitude + wrappedDelta(to.longitude - from.longitude) * ratio)
        )
    }

    /// 출발·도착만 살짝 느리게 한다. 절반은 등속이라 이동이 끝까지 읽힌다.
    static func ease(_ value: Double) -> Double {
        0.5 * value + 0.5 * value * value * (3 - 2 * value)
    }

    /// `ease`의 역함수(경로 점이 언제 지나가는지 구할 때). 이분 탐색으로 충분하다.
    static func inverseEase(_ value: Double) -> Double {
        var lower = 0.0, upper = 1.0
        for _ in 0..<24 {
            let middle = (lower + upper) / 2
            if ease(middle) < value { lower = middle } else { upper = middle }
        }
        return (lower + upper) / 2
    }

    // MARK: - 카메라

    /// 프레임마다 카메라를 계산한다. 시계를 쓰지 않아 같은 입력이면 같은 프레임이 나온다.
    func frames(fps: Int) -> [MapHomePlaybackTimeline.Frame] {
        let fps = max(1, fps)
        let count = Int((durationSeconds * Double(fps)).rounded())
        guard let first = position(atSecond: 0), count > 0 else { return [] }
        let step = 1 / Double(fps)
        let centerKeep = exp(-step / Tuning.cameraCenterSeconds)
        let outKeep = exp(-step / Tuning.zoomOutSeconds), inKeep = exp(-step / Tuning.zoomInSeconds)
        var center = first.point
        var logDistance = log(item(atSecond: 0)?.cameraDistance ?? Tuning.stayCameraDistance)
        var bodyEnd: (center: Point, logDistance: Double)?
        var frames: [MapHomePlaybackTimeline.Frame] = []
        frames.reserveCapacity(count)
        for index in 0..<count {
            let second = Double(index) * step
            var output = (center: center, logDistance: logDistance)
            if second < bodySeconds {
                if let position = position(atSecond: second) {
                    let keep = centerKeep
                    center.latitude = position.point.latitude + (center.latitude - position.point.latitude) * keep
                    let delta = Self.wrappedDelta(position.point.longitude - center.longitude)
                    center.longitude = Self.normalizedLongitude(center.longitude + delta * (1 - keep))
                }
                let target = log(item(atSecond: min(second + Tuning.cameraLookaheadSeconds, bodySeconds))?.cameraDistance
                    ?? Tuning.stayCameraDistance)
                let zoomKeep = target > logDistance ? outKeep : inKeep
                logDistance = target + (logDistance - target) * zoomKeep
                output = (center, logDistance)
            } else {
                let start = bodyEnd ?? (center, logDistance)
                bodyEnd = start
                let moving = Tuning.overviewSeconds - Tuning.overviewHoldSeconds
                let linear = min(1, (second - bodySeconds) / moving)
                let ratio = linear * linear * (3 - 2 * linear)
                output.center = Point(
                    latitude: start.center.latitude + (overviewCenter.latitude - start.center.latitude) * ratio,
                    longitude: Self.normalizedLongitude(
                        start.center.longitude + Self.wrappedDelta(overviewCenter.longitude - start.center.longitude) * ratio
                    )
                )
                output.logDistance = start.logDistance + (log(overviewDistance) - start.logDistance) * ratio
            }
            frames.append((
                minute: second / 60,
                coordinate: CLLocationCoordinate2D(latitude: output.center.latitude, longitude: output.center.longitude),
                cameraDistance: exp(output.logDistance)
            ))
        }
        return frames
    }

    // MARK: - 장소 가리기

    /// 사는 곳을 짐작하게 하는 등록 장소(대표 선택 PLR1104A01).
    static func hiddenPlaces(from places: [FrequentPlace]) -> [Point] {
        places.compactMap { place in
            guard [.home, .company, .school, .academy].contains(place.kind), let point = place.point else { return nil }
            return Point(latitude: point.latitude, longitude: point.longitude)
        }
    }

    /// 하루 영상용. 가린 장소 안에 있는 프레임은 카메라를 가장 가까운 바깥 위치에 묶어 둔다.
    /// 처음부터 안에 있으면 처음 나가는 위치에서 기다리고, 끝까지 안이면 보여 줄 것이 없어 빈 배열을 돌려준다.
    static func masked(
        _ frames: [MapHomePlaybackTimeline.Frame],
        hiddenPlaces: [Point]
    ) -> [MapHomePlaybackTimeline.Frame] {
        guard !hiddenPlaces.isEmpty else { return frames }
        func isHidden(_ coordinate: CLLocationCoordinate2D) -> Bool {
            let point = Point(latitude: coordinate.latitude, longitude: coordinate.longitude)
            return hiddenPlaces.contains { meters($0, point) <= Tuning.hiddenPlaceMeters }
        }
        guard let firstVisible = frames.lazy.compactMap(\.coordinate).first(where: { !isHidden($0) }) else { return [] }
        var last = firstVisible
        return frames.map { frame in
            guard let coordinate = frame.coordinate else { return frame }
            if isHidden(coordinate) { return (frame.minute, last, frame.cameraDistance) }
            last = coordinate
            return frame
        }
    }

    // MARK: - 지리 계산

    private struct Bounds {
        var south = 90.0, north = -90.0, west = 0.0, east = 0.0

        /// 경도는 앞 점에서 이어 펼쳐 날짜변경선을 넘어도 범위가 세계 전체로 커지지 않게 한다.
        init(_ points: [Point]) {
            guard let first = points.first else {
                south = 0
                north = 0
                return
            }
            var longitude = first.longitude
            west = longitude
            east = longitude
            var previous = first.longitude
            for point in points {
                south = min(south, point.latitude)
                north = max(north, point.latitude)
                longitude += MapHomeRangeTripPlan.wrappedDelta(point.longitude - previous)
                previous = point.longitude
                west = min(west, longitude)
                east = max(east, longitude)
            }
        }

        var center: Point {
            Point(latitude: (south + north) / 2, longitude: MapHomeRangeTripPlan.normalizedLongitude((west + east) / 2))
        }

        var cameraDistance: Double {
            let middle = (south + north) / 2 * .pi / 180
            let height = (north - south) * 111_320
            let width = (east - west) * 111_320 * max(0.05, cos(middle))
            let distance = max(height, width / Tuning.aspect) * Tuning.cameraRatio
            return min(Tuning.farthestCameraDistance, max(Tuning.closestCameraDistance, distance))
        }
    }

    static func normalizedLongitude(_ value: Double) -> Double {
        var longitude = value
        while longitude > 180 { longitude -= 360 }
        while longitude < -180 { longitude += 360 }
        return longitude
    }

    static func wrappedDelta(_ value: Double) -> Double {
        normalizedLongitude(value)
    }

    static func meters(_ first: Point, _ second: Point) -> Double {
        let latitude1 = first.latitude * .pi / 180, latitude2 = second.latitude * .pi / 180
        let deltaLatitude = latitude2 - latitude1
        let deltaLongitude = wrappedDelta(second.longitude - first.longitude) * .pi / 180
        let value = sin(deltaLatitude / 2) * sin(deltaLatitude / 2)
            + cos(latitude1) * cos(latitude2) * sin(deltaLongitude / 2) * sin(deltaLongitude / 2)
        return 2 * 6_371_000 * asin(min(1, sqrt(value)))
    }

    private static func pathMeters(_ points: [Point]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + meters($1.0, $1.1) }
    }

    static func greatCircle(from start: Point, to end: Point, segments: Int) -> [Point] {
        func vector(_ point: Point) -> (Double, Double, Double) {
            let latitude = point.latitude * .pi / 180, longitude = point.longitude * .pi / 180
            return (cos(latitude) * cos(longitude), cos(latitude) * sin(longitude), sin(latitude))
        }
        let a = vector(start), b = vector(end)
        let angle = acos(min(1, max(-1, a.0 * b.0 + a.1 * b.1 + a.2 * b.2)))
        guard angle > 0.000_001, sin(angle) != 0, segments > 0 else { return [start, end] }
        return (0...segments).map { index in
            if index == 0 { return start }
            if index == segments { return end }
            let ratio = Double(index) / Double(segments)
            let first = sin((1 - ratio) * angle) / sin(angle), second = sin(ratio * angle) / sin(angle)
            let x = first * a.0 + second * b.0, y = first * a.1 + second * b.1, z = first * a.2 + second * b.2
            return Point(latitude: atan2(z, sqrt(x * x + y * y)) * 180 / .pi, longitude: atan2(y, x) * 180 / .pi)
        }
    }

    /// 긴 경로는 토막을 나눠 줄인다. 지그재그 경로에서 한 번에 돌리면 제곱 시간이 걸린다.
    private static func douglasPeucker(_ points: [Point], tolerance: Double) -> [Point] {
        let chunk = 500
        guard points.count > chunk else { return douglasPeuckerChunk(points, tolerance: tolerance) }
        var result = [points[0]]
        var start = 0
        while start < points.count - 1 {
            let end = min(start + chunk, points.count - 1)
            result += douglasPeuckerChunk(Array(points[start...end]), tolerance: tolerance).dropFirst()
            start = end
        }
        return result
    }

    private static func douglasPeuckerChunk(_ points: [Point], tolerance: Double) -> [Point] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]
        while let (start, end) = stack.popLast() {
            guard end > start + 1 else { continue }
            var farthest = 0.0, index = start
            for candidate in (start + 1)..<end {
                let distance = perpendicularMeters(points[candidate], from: points[start], to: points[end])
                if distance > farthest {
                    farthest = distance
                    index = candidate
                }
            }
            if farthest > tolerance {
                keep[index] = true
                stack.append((start, index))
                stack.append((index, end))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }

    private static func perpendicularMeters(_ point: Point, from start: Point, to end: Point) -> Double {
        let scale = cos(start.latitude * .pi / 180) * 111_320
        let x = wrappedDelta(point.longitude - start.longitude) * scale, y = (point.latitude - start.latitude) * 111_320
        let dx = wrappedDelta(end.longitude - start.longitude) * scale, dy = (end.latitude - start.latitude) * 111_320
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(x, y) }
        let ratio = min(1, max(0, (x * dx + y * dy) / lengthSquared))
        return hypot(x - dx * ratio, y - dy * ratio)
    }
}

private extension MapHomeRangeTripPlan.Sample {
    var point: MapHomeRangeTripPlan.Point { .init(latitude: latitude, longitude: longitude) }
}
