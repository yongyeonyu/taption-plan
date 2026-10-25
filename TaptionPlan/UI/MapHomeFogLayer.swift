import CoreGraphics
import MapKit
import SwiftUI
import UIKit

/// 안개 탐험 강도. 지도 라벨을 읽을 수 있는 정도를 사용자가 고른다.
///
/// 예전에는 `.black.opacity(0.55)` 고정에 켜기/끄기만 있었고 그 값도 저장하지 않아
/// 앱을 다시 열면 늘 진한 안개로 돌아갔다. 기록이 적을수록 지도가 더 안 보이므로
/// 기본은 옅게(0.28)로 두고, 진하게를 고른 사람만 예전 세기를 쓴다.
enum MapHomeFogStrength: String, CaseIterable, Identifiable, Sendable {
    case off
    case light
    case strong

    static let storageKey = "mapHomeFogStrength"
    /// 발자국·장소를 걷어 내는 반경(pt).
    static let revealRadius: CGFloat = 72
    /// 현재 위치를 걷어 내는 반경(pt).
    static let currentLocationRadius: CGFloat = 96

    var id: String { rawValue }

    /// 지도를 덮는 검정 불투명도.
    var opacity: Double {
        switch self {
        case .off: 0
        case .light: 0.28
        case .strong: 0.55
        }
    }

    var koreanLabel: String {
        switch self {
        case .off: "끄기"
        case .light: "옅게"
        case .strong: "진하게"
        }
    }

    var englishLabel: String {
        switch self {
        case .off: "Off"
        case .light: "Light"
        case .strong: "Strong"
        }
    }
}

/// 벡터 지도 위에 얹는 안개. 걷어낼 지점은 이미 화면 좌표로 계산해 넘긴다.
struct MapHomeFogLayer: View {
    let opacity: Double
    let reveals: [(point: CGPoint, radius: CGFloat)]

    var body: some View {
        Canvas { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(.black.opacity(opacity))
            )
            context.blendMode = .destinationOut
            for reveal in reveals {
                let rect = CGRect(
                    x: reveal.point.x - reveal.radius,
                    y: reveal.point.y - reveal.radius,
                    width: reveal.radius * 2,
                    height: reveal.radius * 2
                )
                guard rect.intersects(CGRect(origin: .zero, size: size)) else { continue }
                context.fill(
                    Path(ellipseIn: rect),
                    with: .radialGradient(
                        Gradient(colors: [.black, .black.opacity(0.7), .clear]),
                        center: reveal.point,
                        startRadius: 0,
                        endRadius: reveal.radius
                    )
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Apple 지도용 안개 탐험. 벡터 지도의 `MapHomeFogLayer`와 같은 세기·반경으로 그린다.
struct MapHomeFogReveal: Equatable {
    let coordinate: CLLocationCoordinate2D
    let radius: CGFloat

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
            && lhs.radius == rhs.radius
    }
}

final class MapHomeFogOverlay: NSObject, MKOverlay {
    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let boundingMapRect = MKMapRect.world
    let reveals: [(point: MKMapPoint, radius: CGFloat)]
    let opacity: CGFloat

    init(reveals: [MapHomeFogReveal], opacity: CGFloat) {
        self.reveals = reveals.map { (MKMapPoint($0.coordinate), $0.radius) }
        self.opacity = opacity
    }
}

final class MapHomeFogRenderer: MKOverlayRenderer {
    private nonisolated(unsafe) static let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [UIColor.black.cgColor,
                 UIColor.black.withAlphaComponent(0.7).cgColor,
                 UIColor.clear.cgColor] as CFArray,
        locations: [0, 0.5, 1]
    )

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let fog = overlay as? MapHomeFogOverlay else { return }
        let tile = rect(for: mapRect)
        context.setFillColor(UIColor.black.withAlphaComponent(fog.opacity).cgColor)
        context.fill(tile)
        guard let gradient = Self.gradient else { return }
        context.setBlendMode(.destinationOut)
        for reveal in fog.reveals {
            let center = point(for: reveal.point)
            // Radius is in screen points; renderer space is map points scaled by zoomScale.
            let radius = reveal.radius / zoomScale
            let circle = CGRect(x: center.x - radius, y: center.y - radius,
                                width: radius * 2, height: radius * 2)
            guard circle.intersects(tile) else { continue }
            context.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                                       endCenter: center, endRadius: radius, options: [])
        }
    }
}
