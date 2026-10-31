import CoreLocation
import Foundation
@preconcurrency import MapLibre
import SwiftUI
import TaptionPlanCore
import UIKit

// 재생·지도 이동의 프레임당 비용을 줄이는 조각들(PRF1101A01).
// 입력은 240Hz까지 받고, 지도 카메라·화랑이·카운터는 120Hz로 그리며, SwiftUI 레이아웃 상태는 60Hz를 넘기지 않는다.

/// 걸러진 마지막 입력을 창 끝에 한 번 반영하는 예약기(`TaptionTrailingInputScheduler`).
typealias TimelineTrailingInputGate = TaptionTrailingInputScheduler

/// 재생 시각의 이동 속도(m/s). 확정된 이동 구간의 평균 속도가 있으면 그것을, 없으면 그 시각을 사이에 둔
/// 두 위치 점의 거리/시간을 쓴다. 한쪽 점만 있으면 가까운(120초 이내) 센서 속도, 아무것도 없으면 nil이다.
/// 재생 중에는 오늘의 실시간 속도를 섞지 않는다.
enum MapHomePlaybackSpeed {
    static let singleSidedMaximumAge: TimeInterval = 120

    static func speed(at date: Date, travel: [TravelSegment], readings: [SensorReading]) -> Double? {
        if let speed = segmentSpeed(at: date, travel: travel) { return speed }
        var before: (time: Date, point: GeoPoint, speed: Double?)?
        var after: (time: Date, point: GeoPoint)?
        for reading in readings {
            guard let point = reading.point else { continue }
            if reading.timestamp <= date {
                if before.map({ reading.timestamp > $0.time }) ?? true {
                    before = (reading.timestamp, point, reading.speedMetersPerSecond)
                }
            } else if after.map({ reading.timestamp < $0.time }) ?? true {
                after = (reading.timestamp, point)
            }
        }
        return speed(at: date, before: before, after: after)
    }

    static func segmentSpeed(at date: Date, travel: [TravelSegment]) -> Double? {
        guard let segment = travel
            .filter({ $0.span.contains(date) })
            .max(by: { $0.span.start < $1.span.start }),
           segment.distanceMeters > 0 else { return nil }
        return segment.distanceMeters / max(1, segment.span.end.timeIntervalSince(segment.span.start))
    }

    static func speed(
        at date: Date,
        before: (time: Date, point: GeoPoint, speed: Double?)?,
        after: (time: Date, point: GeoPoint)?
    ) -> Double? {
        if let before, let after {
            let gap = after.time.timeIntervalSince(before.time)
            guard gap > 0 else { return nil }
            return distanceMeters(before.point, after.point) / gap
        }
        if let before, date.timeIntervalSince(before.time) <= singleSidedMaximumAge,
           let speed = before.speed, speed.isFinite, speed >= 0 {
            return speed
        }
        return nil
    }
}

/// 재생하는 하루 동안 바뀌지 않는 조회 자료. 드라이버가 한 번 만들고 프레임마다 재사용한다(PRF1101A01).
/// 예전에는 프레임마다(다듬기 때문에 프레임당 5번) 장소 사전을 새로 만들고 지하철 구간을 거르고,
/// 속도를 구하려고 하루 측정값 전체를 훑었다.
struct MapHomePlaybackLookup {
    let placePoints: [UUID: GeoPoint]
    /// 노선이 유효한 지하철 구간만. `resolve`의 지하철 좌표는 이 구간에서만 나온다.
    let subwayTravel: [TravelSegment]
    private let pointTimes: [Date]
    private let pointSamples: [(point: GeoPoint, speed: Double?)]

    init(readings: [SensorReading], travel: [TravelSegment], places: [PlaceStay]) {
        placePoints = Self.placePoints(places)
        subwayTravel = travel.filter { segment in
            segment.mode == .subway && segment.subwayRoute.map(SubwayStationCatalog.isValid) == true
        }
        let samples = readings.enumerated()
            .compactMap { index, reading in reading.point.map { (index, reading.timestamp, $0, reading.speedMetersPerSecond) } }
            .sorted { ($0.1, $0.0) < ($1.1, $1.0) }
        pointTimes = samples.map(\.1)
        pointSamples = samples.map { ($0.2, $0.3) }
    }

    static func placePoints(_ places: [PlaceStay]) -> [UUID: GeoPoint] {
        Dictionary(
            places.compactMap { place in place.point.map { (place.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// `MapHomePlaybackSpeed.speed`와 같은 결과를 이진 탐색으로 낸다.
    func speed(at date: Date, travel: [TravelSegment]) -> Double? {
        if let speed = MapHomePlaybackSpeed.segmentSpeed(at: date, travel: travel) { return speed }
        var lower = 0, upper = pointTimes.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if pointTimes[middle] <= date { lower = middle + 1 } else { upper = middle }
        }
        // 같은 시각이 여럿이면 선형 탐색처럼 먼저 나온 것을 쓴다.
        var beforeIndex = lower - 1
        while beforeIndex > 0, pointTimes[beforeIndex - 1] == pointTimes[lower - 1] { beforeIndex -= 1 }
        let before = beforeIndex >= 0 ? beforeIndex : nil
        let after = lower < pointTimes.count ? lower : nil
        return MapHomePlaybackSpeed.speed(
            at: date,
            before: before.map { (pointTimes[$0], pointSamples[$0].point, pointSamples[$0].speed) },
            after: after.map { (pointTimes[$0], pointSamples[$0].point) }
        )
    }
}

/// 매 프레임 바뀌는 화면 점(재생 중 화랑이, Apple 지도가 움직이는 동안의 화랑이).
/// 관찰되지 않는다: 구독한 UIKit 뷰가 위치만 옮기고 SwiftUI 화면은 다시 평가하지 않는다(PRF1101A01).
@MainActor
final class MapHomeLivePointChannel {
    private(set) var point: CGPoint?
    private var handlers: [ObjectIdentifier: (CGPoint?) -> Void] = [:]

    func send(_ next: CGPoint?) {
        guard next != point else { return }
        point = next
        for handler in handlers.values { handler(next) }
    }

    func subscribe(_ owner: AnyObject, handler: @escaping (CGPoint?) -> Void) {
        handlers[ObjectIdentifier(owner)] = handler
    }

    func unsubscribe(_ owner: AnyObject) {
        handlers[ObjectIdentifier(owner)] = nil
    }
}

/// 카운터 창이 화면에서 차지한 자리. 지도 탭 판정만 읽으므로 관찰하지 않는다.
/// 예전에는 `@State`라 재생 중 매 프레임 기록돼 지도 화면 전체가 다시 평가됐다(PRF1101A01).
@MainActor
final class MapHomeCounterFrameBox {
    /// 창을 담은 240×320 틀(지도 오버레이 좌표).
    var hostFrame = CGRect.zero
    /// 틀 바닥 가운데에 붙은 실제 창 크기.
    var contentSize = CGSize.zero

    var frame: CGRect {
        guard hostFrame.width > 0, contentSize.width > 0, contentSize.height > 0 else { return .zero }
        return CGRect(
            x: hostFrame.midX - contentSize.width / 2,
            y: hostFrame.maxY - contentSize.height,
            width: contentSize.width,
            height: contentSize.height
        )
    }

    func reset() {
        hostFrame = .zero
        contentSize = .zero
    }
}

/// SwiftUI 내용을 UIKit 뷰에 담고, 채널 점이 바뀌면 `center`만 옮긴다.
/// 재생·지도 이동 중 화랑이·카운터를 SwiftUI `.position`으로 매 프레임 옮기지 않는다(PRF1101A01).
/// 채널이 없거나 점이 없으면 `fallback`(SwiftUI가 60Hz 이하로 넘기는 점)에 둔다.
struct MapHomeLivePointFollower<Content: View>: UIViewRepresentable {
    let channel: MapHomeLivePointChannel?
    let fallback: CGPoint
    /// 채널 점에서 내용 중심까지.
    let offset: CGSize
    var onFrame: ((CGRect) -> Void)?
    @ViewBuilder let content: () -> Content

    func makeUIView(context: Context) -> MapHomeLivePointFollowerView<Content> {
        MapHomeLivePointFollowerView(rootView: content())
    }

    func updateUIView(_ view: MapHomeLivePointFollowerView<Content>, context: Context) {
        view.host.rootView = content()
        view.configure(channel: channel, fallback: fallback, offset: offset, onFrame: onFrame)
    }

    static func dismantleUIView(_ view: MapHomeLivePointFollowerView<Content>, coordinator: ()) {
        view.configure(channel: nil, fallback: .zero, offset: .zero, onFrame: nil)
    }
}

final class MapHomeLivePointFollowerView<Content: View>: UIView {
    let host: UIHostingController<Content>
    private weak var channel: MapHomeLivePointChannel?
    private var fallback = CGPoint.zero
    private var offset = CGSize.zero
    private var onFrame: ((CGRect) -> Void)?

    init(rootView: Content) {
        host = UIHostingController(rootView: rootView)
        host.sizingOptions = .intrinsicContentSize
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        addSubview(host.view)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(
        channel next: MapHomeLivePointChannel?,
        fallback: CGPoint,
        offset: CGSize,
        onFrame: ((CGRect) -> Void)?
    ) {
        if channel !== next {
            channel?.unsubscribe(self)
            channel = next
            next?.subscribe(self) { [weak self] point in self?.place(point) }
        }
        self.fallback = fallback
        self.offset = offset
        self.onFrame = onFrame
        resizeHost()
        place(channel?.point)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        resizeHost()
        place(channel?.point)
    }

    private func resizeHost() {
        let size = host.sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        guard size.width.isFinite, size.height.isFinite, host.view.bounds.size != size else { return }
        host.view.bounds.size = size
    }

    private func place(_ point: CGPoint?) {
        let center = point.map { CGPoint(x: $0.x + offset.width, y: $0.y + offset.height) } ?? fallback
        if host.view.center != center { host.view.center = center }
        onFrame?(host.view.frame)
    }
}

/// 지도 내용이 바뀌었는지 보는 revision 값. 예전에는 필드마다 문자열을 만들어 이어 붙여 비교했다(PRF1101A01).
enum MapHomeContentRevision {
    static func of<each Value: Hashable>(_ value: repeat each Value) -> Int {
        var hasher = Hasher()
        repeat hasher.combine(each value)
        return hasher.finalize()
    }
}

/// 벡터 지도 프레임률. 움직이는 동안(재생·손가락·자동 측정 이동)만 최대(ProMotion 120Hz),
/// 멈추면 기본값으로 돌아가 발열·배터리를 아낀다(PRF1101A01).
enum MapHomeMapFrameRate {
    static func preferred(isMoving: Bool) -> MLNMapViewPreferredFramesPerSecond {
        isMoving ? .maximum : .default
    }

    @MainActor
    static func apply(to mapView: MLNMapView, isMoving: Bool) {
        let next = preferred(isMoving: isMoving)
        if mapView.preferredFramesPerSecond != next { mapView.preferredFramesPerSecond = next }
    }

    @MainActor
    static func isActive(_ gesture: UIGestureRecognizer) -> Bool {
        gesture.state == .began || gesture.state == .changed
    }
}

/// 마커 화면 좌표 계산(PRF1101A01). 카메라가 그대로면 바뀐 마커만 다시 투영하고,
/// 화면에서 멀리 벗어난 발자국은 건너뛴다(발자국은 수백 개라 팬·재생 중 매 프레임 비용이 컸다).
/// 화랑이·장소·검색 같은 다른 마커는 화면 밖이어도 늘 투영한다(가장자리 화살표 등이 쓴다).
struct MapHomeMarkerProjector {
    struct Camera: Equatable {
        var latitude: Double
        var longitude: Double
        var altitude: Double
        var heading: Double
        var pitch: Double
        var size: CGSize
    }

    /// 보이는 범위(위·경도). 양쪽으로 한 화면씩 넓혀 화면 가장자리에 걸친 발자국을 놓치지 않는다.
    struct Bounds {
        var south: Double, west: Double, north: Double, east: Double

        func expanded() -> Bounds {
            let latitude = north - south, longitude = east - west
            return Bounds(south: south - latitude, west: west - longitude, north: north + latitude, east: east + longitude)
        }

        func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
            (south...north).contains(coordinate.latitude) && (west...east).contains(coordinate.longitude)
        }
    }

    static let cullablePrefix = "pawprint-"

    private var camera: Camera?
    private var cache: [String: (latitude: Double, longitude: Double, point: CGPoint?)] = [:]
    /// 마지막 계산에서 실제로 투영한 수(측정·테스트용).
    private(set) var lastProjectionCount = 0

    mutating func points(
        markers: [MapHomeVectorMarker],
        camera next: Camera,
        visible: Bounds,
        project: (CLLocationCoordinate2D) -> CGPoint
    ) -> [String: CGPoint] {
        let reuses = camera == next
        camera = next
        let culling = visible.expanded()
        var nextCache: [String: (latitude: Double, longitude: Double, point: CGPoint?)] = [:]
        nextCache.reserveCapacity(markers.count)
        var points: [String: CGPoint] = [:]
        points.reserveCapacity(markers.count)
        lastProjectionCount = 0
        for marker in markers where nextCache[marker.id] == nil {
            let coordinate = marker.coordinate
            let point: CGPoint?
            if reuses, let cached = cache[marker.id],
               cached.latitude == coordinate.latitude, cached.longitude == coordinate.longitude {
                point = cached.point
            } else if marker.id.hasPrefix(Self.cullablePrefix), !culling.contains(coordinate) {
                point = nil
            } else {
                point = project(coordinate)
                lastProjectionCount += 1
            }
            nextCache[marker.id] = (coordinate.latitude, coordinate.longitude, point)
            if let point { points[marker.id] = point }
        }
        cache = nextCache
        return points
    }
}

/// 측정용 자동 지도 이동(`-autoBenchMapPan`, PRF1030A02). 손가락 팬처럼 프레임마다 지도를 옮기고
/// 뷰포트를 `force: false`로 내보낸다. 실행 인자가 없으면 쓰이지 않는다. 벡터 지도 코디네이터에서 옮겨 왔다.
@MainActor
final class MapHomeVectorBenchPan: NSObject {
    static let notification = Notification.Name("MapHomeVectorMapBenchPan")
    static let seconds: TimeInterval = 12

    private var link: CADisplayLink?
    private var start: (uptime: TimeInterval, center: CLLocationCoordinate2D, span: Double)?
    private weak var mapView: MLNMapView?
    private var observer: NSObjectProtocol?
    private var publish: (MLNMapView, Bool) -> Void = { _, _ in }

    var isRunning: Bool { link != nil }

    func observe(on mapView: MLNMapView, publish: @escaping (MLNMapView, Bool) -> Void) {
        guard ProcessInfo.processInfo.arguments.contains("-autoBenchMapPan"), observer == nil else { return }
        self.mapView = mapView
        self.publish = publish
        observer = NotificationCenter.default.addObserver(
            forName: Self.notification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.begin() }
        }
    }

    private func begin() {
        guard let mapView, link == nil else { return }
        let span = MLNCoordinateBoundsGetCoordinateSpan(mapView.visibleCoordinateBounds).longitudeDelta
        start = (ProcessInfo.processInfo.systemUptime, mapView.centerCoordinate, span)
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        MapHomeMapFrameRate.apply(to: mapView, isMoving: true)
    }

    @objc private func tick() {
        guard let mapView, let start else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - start.uptime
        guard elapsed < Self.seconds else {
            link?.invalidate()
            link = nil
            self.start = nil
            publish(mapView, true)
            return
        }
        // 화면 폭의 절반만큼 좌우로 2초 주기 왕복(손가락으로 지도를 계속 미는 것과 비슷한 속도).
        let offset = sin(elapsed * .pi) * start.span * 0.5
        mapView.setCenter(
            CLLocationCoordinate2D(latitude: start.center.latitude, longitude: start.center.longitude + offset),
            animated: false
        )
        publish(mapView, false)
    }
}

/// 지도 발자국 목록의 입력. 같으면 다시 만들지 않는다(PRF1101A01).
/// 장부(`pawprintLedger`)는 원본 읽기 key로 이미 메모되므로 개수·처음·끝 시각만 본다.
struct MapHomePawprintWaypointsKey: Equatable {
    let day: Date
    let cutoff: Date
    let ledgerCutoff: Date
    let predicted: [MapPredictedRoute]
    let confirmed: [MapPredictedRoute]
    let ledgerCount: Int
    let ledgerFirst: Date?
    let ledgerLast: Date?
}

