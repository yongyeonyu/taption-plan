import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

final class MapHomeAppleMapAnnotation: NSObject, MKAnnotation {
    let identifier: String
    var kind: MapHomeAppleAnnotationKind
    var label: String
    var isInteractive: Bool
    dynamic var coordinate: CLLocationCoordinate2D

    init(annotation: MapHomeAppleAnnotation) {
        identifier = annotation.id
        kind = annotation.kind
        label = annotation.accessibilityLabel
        isInteractive = annotation.isInteractive
        coordinate = annotation.coordinate
        super.init()
    }

    var title: String? {
        label
    }

    func update(from annotation: MapHomeAppleAnnotation) {
        kind = annotation.kind
        label = annotation.accessibilityLabel
        isInteractive = annotation.isInteractive
        guard coordinate.latitude != annotation.coordinate.latitude
                || coordinate.longitude != annotation.coordinate.longitude else { return }
        coordinate = annotation.coordinate
    }
}

final class MapHomeAppleWalkerAnnotation: NSObject, MKAnnotation {
    dynamic var coordinate: CLLocationCoordinate2D
    var headingDegrees: CLLocationDirection
    var action: MapHomeStickmanAction
    var label: String
    var phase: MapHomeAppleRoutePhase
    var stickmanAnimationPhase: Int?
    var speedMetersPerSecond: Double?
    var equippedAccessoryID: String?

    init(playback: MapHomeApplePlayback) {
        coordinate = playback.coordinate
        headingDegrees = playback.headingDegrees
        action = playback.action
        label = playback.accessibilityLabel
        phase = playback.phase
        stickmanAnimationPhase = playback.stickmanAnimationPhase
        equippedAccessoryID = playback.equippedAccessoryID
        super.init()
    }

    var title: String? { label }

    func update(with playback: MapHomeApplePlayback) {
        if coordinate.latitude != playback.coordinate.latitude
            || coordinate.longitude != playback.coordinate.longitude {
            coordinate = playback.coordinate
        }
        headingDegrees = playback.headingDegrees
        action = playback.action
        label = playback.accessibilityLabel
        phase = playback.phase
        stickmanAnimationPhase = playback.stickmanAnimationPhase
        equippedAccessoryID = playback.equippedAccessoryID
    }
}

/// 장소 핀의 표시 정책. MapKit은 낮은 우선순위 표식이 겹치면 숨기므로, 축소하면 핀이 사라진다.
/// 집은 어떤 축소에서도 남아야 해 `.required`다. 다른 등록 지점은 겹치면 사라져도 된다(대표 지시, HIC1103A01).
enum MapHomePlaceDisplayPolicy {
    static func priority(for destination: MapHomeLocationDestination) -> MKFeatureDisplayPriority {
        destination == .home ? .required : .defaultHigh
    }

    static func zPriority(for destination: MapHomeLocationDestination) -> MKAnnotationViewZPriority {
        destination == .home ? .defaultSelected : .defaultUnselected
    }

    /// 벡터 지도는 충돌 판정이 없어 집이 남지만, 축소하면 나중에 그린 회사·역 핀이 집을 덮는다. 집을 그 위에 둔다.
    /// 화랑이·카운터(`MapHomeLayerPriority.stickman`)보다는 아래다.
    static func vectorZIndex(for destination: MapHomeLocationDestination) -> Double {
        destination == .home ? 0.5 : 0
    }
}

struct MapHomeAppleHostedDescriptor {
    let rootView: AnyView
    let size: CGSize
    let centerOffset: CGPoint
}

final class MapHomeAppleHostedAnnotationView: MKAnnotationView {
    private var hostingController: UIHostingController<AnyView>?

    func update(
        rootView: AnyView,
        size: CGSize,
        centerOffset: CGPoint
    ) {
        if let hostingController {
            hostingController.rootView = rootView
        } else {
            let controller = UIHostingController(rootView: rootView)
            controller.view.backgroundColor = .clear
            controller.view.isOpaque = false
            // 안쪽 SwiftUI가 터치를 잡으면 핀 위에 닿은 손가락이 지도 핀치에서 빠진다.
            controller.view.isUserInteractionEnabled = false
            addSubview(controller.view)
            hostingController = controller
        }
        bounds = CGRect(origin: .zero, size: size)
        hostingController?.view.frame = bounds
        hostingController?.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.centerOffset = centerOffset
        clipsToBounds = false
        canShowCallout = false
    }
}

/// 발자국 주석. SwiftUI 호스팅 뷰를 수백 개 만들면 늦게 뜨고 첫 배치 때 위치가 어긋나므로 이미지 뷰 하나만 쓴다.
final class MapHomeApplePawprintAnnotationView: MKAnnotationView {
    private static let size = CGSize(width: 28, height: 28)
    private static var imageCache: [UInt32: UIImage] = [:]
    private let imageView = UIImageView()
    private var appliedColor: UInt32?

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        bounds = CGRect(origin: .zero, size: Self.size)
        imageView.frame = bounds
        imageView.contentMode = .center
        imageView.isUserInteractionEnabled = false
        addSubview(imageView)
        centerOffset = .zero
        canShowCallout = false
        clipsToBounds = false
        displayPriority = .defaultLow
        collisionMode = .none
        zPriority = .min
        selectedZPriority = .min
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(_ paw: MapHomeApplePawprint, color: UIColor) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func byte(_ value: CGFloat) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
        let key = (byte(red) << 24) | (byte(green) << 16) | (byte(blue) << 8) | byte(alpha)
        if appliedColor != key {
            appliedColor = key
            if let cached = Self.imageCache[key] {
                imageView.image = cached
            } else {
                let configuration = UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)
                let image = UIImage(systemName: "pawprint.fill", withConfiguration: configuration)?
                    .withTintColor(color, renderingMode: .alwaysOriginal)
                if Self.imageCache.count > 64 { Self.imageCache.removeAll() }
                Self.imageCache[key] = image
                imageView.image = image
            }
        }
        transform = CGAffineTransform(rotationAngle: CGFloat(paw.angle * .pi / 180))
    }
}

final class MapHomeAppleDirectionsHandle: @unchecked Sendable {
    let directions: MKDirections

    init(_ directions: MKDirections) {
        self.directions = directions
    }
}

actor MapHomeAppleRouteResolver {
    static let shared = MapHomeAppleRouteResolver()

    private struct CacheKey: Hashable {
        let startLatitude: Int
        let startLongitude: Int
        let endLatitude: Int
        let endLongitude: Int
        let transport: ExpectedRouteTransport
        let departureBucket: Int?
    }

    private let cacheCapacity = 128
    private var cache: [CacheKey: [CLLocationCoordinate2D]] = [:]
    private var cacheRecency: [CacheKey] = []

    func resolve(
        start: CLLocationCoordinate2D,
        end: CLLocationCoordinate2D,
        transport: ExpectedRouteTransport,
        departureDate: Date
    ) async -> [CLLocationCoordinate2D]? {
        let key = CacheKey(
            startLatitude: Int((start.latitude * 100_000).rounded()),
            startLongitude: Int((start.longitude * 100_000).rounded()),
            endLatitude: Int((end.latitude * 100_000).rounded()),
            endLongitude: Int((end.longitude * 100_000).rounded()),
            transport: transport,
            departureBucket: transport == .transit
                ? Int(departureDate.timeIntervalSince1970 / (15 * 60))
                : nil
        )
        if let cached = cache[key] {
            touch(key)
            return cached
        }
        for candidate in MapHomeAppleRouteFallbackPolicy.transports(for: transport) {
            guard !Task.isCancelled else { return nil }
            if let coordinates = await calculate(
                start: start,
                end: end,
                transport: candidate,
                departureDate: departureDate
            ) {
                insert(coordinates, for: key)
                return coordinates
            }
        }
        return nil
    }

    private func insert(
        _ coordinates: [CLLocationCoordinate2D],
        for key: CacheKey
    ) {
        cache[key] = coordinates
        touch(key)
        while cacheRecency.count > cacheCapacity,
              let oldest = cacheRecency.first {
            cacheRecency.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    private func touch(_ key: CacheKey) {
        cacheRecency.removeAll { $0 == key }
        cacheRecency.append(key)
    }

    private func calculate(
        start: CLLocationCoordinate2D,
        end: CLLocationCoordinate2D,
        transport: ExpectedRouteTransport,
        departureDate: Date
    ) async -> [CLLocationCoordinate2D]? {
        if transport == .direct {
            return [start, end]
        }
        let request = MKDirections.Request()
        request.source = MKMapItem(
            placemark: MKPlacemark(coordinate: start)
        )
        request.destination = MKMapItem(
            placemark: MKPlacemark(coordinate: end)
        )
        request.requestsAlternateRoutes = false
        request.transportType = switch transport {
        case .automobile: .automobile
        case .transit: .transit
        case .walking: .walking
        case .direct: .walking
        }
        if transport == .transit {
            request.departureDate = departureDate
        }
        let handle = MapHomeAppleDirectionsHandle(MKDirections(request: request))
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                handle.directions.calculate { response, _ in
                    guard let route = response?.routes.min(by: {
                        $0.expectedTravelTime < $1.expectedTravelTime
                    }), route.polyline.pointCount > 1 else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let points = route.polyline.points()
                    continuation.resume(
                        returning: (0..<route.polyline.pointCount).map {
                            points[$0].coordinate
                        }
                    )
                }
            }
        }, onCancel: {
            handle.directions.cancel()
        })
    }
}
/// 재생 중 카운터가 받은 점과 화랑이가 실제로 그려진 점의 차이(CTR1103A02).
/// 화면 녹화를 분석하지 않아도 카운터 흔들림을 전후로 비교할 수 있게 한다.
@MainActor
enum MapHomeAppleCounterDriftProbe {
    private static var values: [Double] = []

    static func note(published: CGPoint?, actual: CGPoint?) {
        guard MapHomePlaybackProbe.isActive, let published, let actual else { return }
        values.append(hypot(published.x - actual.x, published.y - actual.y))
        if values.count.isMultiple(of: 300) { record() }
    }

    private static func record() {
        let sorted = values.sorted()
        TaptionPlanDiagnosticsLogger.shared.record("apple_counter_drift", metrics: [
            "frames": Double(sorted.count),
            "mean_pt": sorted.reduce(0, +) / Double(sorted.count),
            "p95_pt": sorted[Int(Double(sorted.count - 1) * 0.95)],
            "max_pt": sorted[sorted.count - 1],
            "over3_pt": Double(sorted.filter { $0 > 3 }.count),
            "over10_pt": Double(sorted.filter { $0 > 10 }.count),
        ])
    }
}

#if DEBUG || BENCH
/// 측정용: `-benchHome=위도,경도`면 집과 회사를 그 근처에 놓고, `-autoBenchHomeZoom`이면 집을 가운데 두고 단계별로 축소한다(HIC1103A01).
@MainActor
enum MapHomeBenchHomeZoom {
    static let distances: [CLLocationDistance] = [2_000, 20_000, 200_000, 2_000_000, 10_000_000]

    /// `-benchPlaybackWaitTicks=20`이면 재생을 그만큼(2초 단위) 재고 끊는다. 느린 기기·시뮬레이터에서도 통계가 남는다.
    static var playbackWaitTicks: Int {
        ProcessInfo.processInfo.arguments.first { $0.hasPrefix("-benchPlaybackWaitTicks=") }
            .flatMap { Int($0.dropFirst("-benchPlaybackWaitTicks=".count)) } ?? 120
    }

    /// 앱 시작 때 불러온 저장값이 먼저 고른 측정 스타일을 덮어쓸 수 있어, 재기 직전에 한 번 더 고른다.
    static func reapplyStyle(model: AppModel) {
        guard let value = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("-benchMapStyle=") })?
            .dropFirst("-benchMapStyle=".count), let style = MapDisplayStyle(rawValue: String(value)) else { return }
        model.setMapDisplayStyle(style)
    }

    static func run(model: AppModel, setCamera: (MapCamera) -> Void) async {
        guard let home = homeCoordinate else { return }
        let places = model.settings.frequentPlaces
        if let id = places.first(where: { $0.kind == .home })?.id {
            model.setFrequentPlaceLocation(id, latitude: home.latitude, longitude: home.longitude)
        }
        if let id = places.first(where: { $0.kind == .company })?.id {
            model.setFrequentPlaceLocation(id, latitude: home.latitude + 0.004, longitude: home.longitude + 0.004)
        }
        guard ProcessInfo.processInfo.arguments.contains("-autoBenchHomeZoom") else { return }
        try? await Task.sleep(for: .seconds(12))
        if Task.isCancelled { return }
        reapplyStyle(model: model)
        try? await Task.sleep(for: .seconds(3))
        for distance in distances {
            setCamera(MapCamera(centerCoordinate: home, distance: distance))
            try? await Task.sleep(for: .seconds(8))
        }
    }

    private static var homeCoordinate: CLLocationCoordinate2D? {
        guard let value = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("-benchHome=") }) else { return nil }
        let parts = value.dropFirst("-benchHome=".count).split(separator: ",").compactMap { Double($0) }
        return parts.count == 2 ? CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1]) : nil
    }
}
#endif
