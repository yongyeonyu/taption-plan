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
