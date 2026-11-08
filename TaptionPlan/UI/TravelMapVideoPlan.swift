import CoreGraphics
import Foundation

/// 도시 여행 지도 영상의 시간표(TRV1108A01). 처음 전체를 보여 주고, 구간마다 선을 그린 뒤 도착 도시에 잠시 머물고,
/// 끝에 다 그린 지도를 둔다. 구간이 많아 `maximumSeconds`를 넘으면 구간 시간을 같은 비율로 줄인다.
struct TravelMapVideoPlan: Hashable, Sendable {
    static let introSeconds = 1.0
    static let outroSeconds = 2.5
    static let legSeconds = 1.6
    static let holdSeconds = 0.7
    static let maximumSeconds = 60.0

    struct State: Hashable, Sendable {
        /// 끝까지 그린 구간 수.
        var drawnLegs: Int
        /// 그리는 중인 구간(`drawnLegs`번)의 진행(0...1). 머무는 중이면 nil.
        var activeProgress: Double?
        /// 강조할 도시. 여기까지 들렀다.
        var currentStop: Int
        var isOverview: Bool
    }

    let legCount: Int
    let legSeconds: Double
    let holdSeconds: Double

    init(legCount: Int) {
        self.legCount = max(0, legCount)
        let body = Double(self.legCount) * (Self.legSeconds + Self.holdSeconds)
        let allowed = Self.maximumSeconds - Self.introSeconds - Self.outroSeconds
        let factor = body > allowed ? allowed / body : 1
        legSeconds = Self.legSeconds * factor
        holdSeconds = Self.holdSeconds * factor
    }

    var totalSeconds: Double {
        Self.introSeconds + Double(legCount) * (legSeconds + holdSeconds) + Self.outroSeconds
    }

    func frameCount(fps: Int) -> Int { Int((totalSeconds * Double(max(1, fps))).rounded(.up)) }

    func state(atSecond second: Double) -> State {
        guard second >= Self.introSeconds else { return State(drawnLegs: 0, activeProgress: nil, currentStop: 0, isOverview: false) }
        let elapsed = second - Self.introSeconds
        let slot = legSeconds + holdSeconds
        let leg = slot > 0 ? Int(elapsed / slot) : legCount
        guard leg < legCount else { return State(drawnLegs: legCount, activeProgress: nil, currentStop: legCount, isOverview: true) }
        let within = elapsed - Double(leg) * slot
        if within < legSeconds {
            return State(drawnLegs: leg, activeProgress: Self.eased(within / legSeconds), currentStop: leg, isOverview: false)
        }
        return State(drawnLegs: leg + 1, activeProgress: nil, currentStop: leg + 1, isOverview: false)
    }

    static func eased(_ value: Double) -> Double {
        let t = min(max(value, 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// 영상 화면의 고정 배치. 카메라는 여행 전체를 담고, 구간은 좌우로 번갈아 휘는 곡선이라 이어 그리면 S자가 된다.
struct TravelMapVideoScene: Sendable {
    static let curveSamples = 40
    static let groundBend = 0.12
    static let flightBend = 0.24

    let size: CGSize
    let viewport: TravelMapViewport
    let stopPoints: [CGPoint]
    /// `legCurves[k]`는 `k`번 도시에서 `k+1`번 도시로 가는 곡선이다.
    let legCurves: [[CGPoint]]

    /// 위쪽 정보 칸과 아래 출처 글자를 피한 지도 영역.
    static func content(in size: CGSize) -> CGRect {
        CGRect(x: 28, y: size.height * 0.27, width: size.width - 56, height: size.height * 0.6)
    }

    init(trip: TravelMapTrip, size: CGSize) {
        self.size = size
        let viewport = TravelMapViewport.fit(trip.stops.map(\.coordinate), content: Self.content(in: size), size: size)
        self.viewport = viewport
        let points = trip.stops.map { viewport.point($0.coordinate) }
        stopPoints = points
        legCurves = zip(points, points.dropFirst()).enumerated().map { index, pair in
            let bend = trip.stops[index + 1].arrivalMode == .flight ? Self.flightBend : Self.groundBend
            return Self.curve(from: pair.0, to: pair.1, bend: index.isMultiple(of: 2) ? bend : -bend)
        }
    }

    /// 두 점을 잇는 2차 베지어. `bend`는 길이에 대한 옆 비율이고 부호가 휘는 쪽이다.
    static func curve(from start: CGPoint, to end: CGPoint, bend: Double, samples: Int = curveSamples) -> [CGPoint] {
        let dx = end.x - start.x, dy = end.y - start.y
        let control = CGPoint(x: (start.x + end.x) / 2 - dy * bend, y: (start.y + end.y) / 2 + dx * bend)
        return (0...samples).map { step in
            let t = Double(step) / Double(samples), u = 1 - t
            return CGPoint(
                x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                y: u * u * start.y + 2 * u * t * control.y + t * t * end.y
            )
        }
    }

    /// 진행만큼 자른 곡선. 끝점은 곡선 위에서 보간한다.
    func partial(leg: Int, progress: Double) -> [CGPoint] {
        guard legCurves.indices.contains(leg) else { return [] }
        let curve = legCurves[leg]
        let position = min(max(progress, 0), 1) * Double(curve.count - 1)
        let whole = Int(position)
        var points = Array(curve[0...whole])
        if whole < curve.count - 1 {
            let t = position - Double(whole), a = curve[whole], b = curve[whole + 1]
            points.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
        return points
    }
}
