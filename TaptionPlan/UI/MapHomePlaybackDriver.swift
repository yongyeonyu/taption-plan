import CoreLocation
import Foundation

/// 재생 한 프레임의 결과. SwiftUI를 거치지 않고 지도 엔진이 바로 받는다(PLY1029A03).
struct MapHomePlaybackDriverFrame {
    let minute: Double
    let coordinate: CLLocationCoordinate2D?
    let cameraDistance: Double
}

/// 재생 프레임을 받는 지도 쪽. 벡터 지도 코디네이터가 맡는다.
@MainActor
protocol MapHomePlaybackSink: AnyObject {
    /// 지금 카메라 거리(m). 줌 스무딩의 출발점이다.
    var playbackCameraDistance: Double? { get }
    func applyPlaybackFrame(_ frame: MapHomePlaybackDriverFrame)
}

/// 재생 시계와 프레임 계산을 2만 줄짜리 `MapHomeView` 밖으로 뺀다.
///
/// 프레임마다 분을 전진시키고 화랑이 좌표·카메라 거리를 계산해 지도 엔진에 바로 준다.
/// SwiftUI에는 **정수 분이 바뀔 때만** 알린다. 그 전에는 틱마다 `dayPlaybackCurrentMinute`가
/// 바뀌어 화면 전체가 다시 평가됐고, 그것이 끊김의 큰 몫이었다(대표 지시, PLY1029A03).
@MainActor
final class MapHomePlaybackDriver {
    struct Inputs {
        var startMinute: Double
        var endMinute: Double
        var movingRanges: [MapHomePlaybackMovementRange]
        var dayStart: Date
        var readings: [SensorReading]
        var travel: [TravelSegment]
        var places: [PlaceStay]
        var zoomPlan: MapHomePlaybackZoomPlan
    }

    let inputs: Inputs
    /// 예상 경로가 뒤늦게 풀리면 바뀐다.
    var projection: MapHomeWBSPlaybackProjection?
    var preferredForecastLegIDs: Set<String> = []
    var expectedCoordinate: (Date) -> GeoPoint? = { _ in nil }
    /// 적응 줌이 꺼져 있으면 카메라 거리를 바꾸지 않는다.
    var isAdaptiveZoom = true
    /// 재생 시작 연출 동안에는 카메라를 움직이지 않는다.
    var isCameraSuppressed: () -> Bool = { false }
    weak var sink: MapHomePlaybackSink?
    var onMinute: (Double) -> Void = { _ in }
    var onFinished: () -> Void = {}

    /// SwiftUI에 분을 알리는 최소 간격(벽시계). 정지 구간은 초당 120분이라 "분이 바뀔 때마다"는
    /// 120Hz에서 곧 매 프레임이었다. 그래서 화면 전체가 매 프레임 다시 그려져 초당 10프레임으로 떨어졌다(PLY1029A06).
    static let minuteCallbackInterval: TimeInterval = 0.25

    private(set) var minute: Double
    private var lastMinuteCallbackUptime: TimeInterval = 0
    private let clock = MapHomePlaybackClock()
    private let smoother = MapHomePlaybackZoomSmoother()
    private var task: Task<Void, Never>?
    private var lastWholeMinute = -1
    private var frameStats = MapHomePlaybackFrameStats()

    init(inputs: Inputs) {
        self.inputs = inputs
        minute = inputs.startMinute
    }

    func start() {
        stop()
        smoother.reset()
        lastWholeMinute = -1
        task = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                guard let elapsed = await clock.nextFrame() else { return }
                step(elapsed: min(elapsed, 0.1))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        clock.stop()
        frameStats.record()
        frameStats = MapHomePlaybackFrameStats()
    }

    private func step(elapsed: TimeInterval) {
        frameStats.add(elapsed)
        minute = min(
            MapHomeDayPlaybackMath.advancedMinute(
                from: minute,
                elapsedSeconds: elapsed,
                normalizedMovingRanges: inputs.movingRanges
            ),
            inputs.endMinute
        )
        let date = inputs.dayStart.addingTimeInterval(minute * 60)
        let coordinate = smoothedPosition(at: date)
        if !isCameraSuppressed(), let sink {
            let current = sink.playbackCameraDistance
            let distance: Double
            if isAdaptiveZoom, let current {
                let speed = MapHomePlaybackSpeed.speed(at: date, travel: inputs.travel, readings: inputs.readings)
                let target = inputs.zoomPlan.targetDistance(atMinute: minute, speedMetersPerSecond: speed)
                distance = smoother.next(current: current, target: target, uptime: ProcessInfo.processInfo.systemUptime)
            } else {
                distance = current ?? MapHomeStartupCameraPolicy.distance
            }
            sink.applyPlaybackFrame(MapHomePlaybackDriverFrame(
                minute: minute,
                coordinate: coordinate,
                cameraDistance: distance
            ))
        }
        let whole = Int(minute.rounded(.down))
        let now = ProcessInfo.processInfo.systemUptime
        if whole != lastWholeMinute, now - lastMinuteCallbackUptime >= Self.minuteCallbackInterval {
            lastWholeMinute = whole
            lastMinuteCallbackUptime = now
            onMinute(minute)
        }
        if minute >= inputs.endMinute {
            stop()
            onFinished()
        }
    }

    /// 재생 경로 다듬기(대표 선택 "재생만 다듬기", PLY1029A07). 이미 기록된 하루라 앞뒤를 안다.
    /// 지금 시각 앞뒤 ±2스텝(스텝 3초)의 위치를 이항 가중치 1·4·6·4·1로 평균한다. 앞뒤를 똑같이 보므로
    /// 실시간 필터와 달리 화랑이가 경로보다 뒤처지지 않고, GPS가 몇 초 사이 튀는 것만 눌린다. 원본은 그대로다.
    nonisolated static let smoothingStep: TimeInterval = 3
    nonisolated private static let smoothingWeights: [Double] = [1, 4, 6, 4, 1]
    /// 이보다 멀리 떨어진 점(순간이동·다른 구간)은 평균에 넣지 않는다(약 1km).
    nonisolated private static let smoothingMaximumDegrees = 0.01

    private func position(at date: Date) -> CLLocationCoordinate2D? {
        let frame = projection?.frame(at: date, preferredForecastLegIDs: preferredForecastLegIDs)
        return MapHomePlaybackLocation.resolveOrGap(
            at: date,
            frame: frame,
            normalizedReadings: inputs.readings,
            travel: inputs.travel,
            places: inputs.places,
            expectedCoordinate: frame == nil ? expectedCoordinate(date) : nil
        ).flatMap(Self.coordinate)
    }

    #if DEBUG
    func smoothedPositionForTesting(raw: Bool, at date: Date) -> CLLocationCoordinate2D? {
        raw ? position(at: date) : smoothedPosition(at: date)
    }
    #endif

    func smoothedPosition(at date: Date) -> CLLocationCoordinate2D? {
        Self.smoothed(at: date, position: position(at:))
    }

    /// 실시간 재생과 영상 렌더링이 같은 다듬기를 쓴다(VID1029A01).
    nonisolated static func smoothed(
        at date: Date,
        position: (Date) -> CLLocationCoordinate2D?
    ) -> CLLocationCoordinate2D? {
        guard let center = position(date) else { return nil }
        var latitude = 0.0, longitude = 0.0, total = 0.0
        for (index, weight) in Self.smoothingWeights.enumerated() {
            let offset = Double(index - Self.smoothingWeights.count / 2) * Self.smoothingStep
            guard let point = offset == 0 ? center : position(date.addingTimeInterval(offset)),
                  abs(point.latitude - center.latitude) < Self.smoothingMaximumDegrees,
                  abs(point.longitude - center.longitude) < Self.smoothingMaximumDegrees else { continue }
            latitude += point.latitude * weight
            longitude += point.longitude * weight
            total += weight
        }
        return total > 0 ? CLLocationCoordinate2D(latitude: latitude / total, longitude: longitude / total) : center
    }

    private static func coordinate(_ location: MapHomePlaybackLocation) -> CLLocationCoordinate2D? {
        let point = location.cameraCoordinate
        let coordinate = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
        return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
    }
}
