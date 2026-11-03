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

/// 지도 좌표(MKMapPoint)를 화면 좌표로 옮기는 아핀 변환. 기울이지 않은 지도에서 정확하다.
/// `MKMapView.convert`를 발자국마다 부르면 프레임이 무너져, 기준점 세 개만 변환해 나머지를 계산한다(CTR1103A02).
struct MapHomeFogProjection {
    let origin: MKMapPoint
    let originPoint: CGPoint
    /// 지도 점 1만큼 x·y로 갈 때의 화면 이동.
    let xAxis: CGVector
    let yAxis: CGVector

    func point(for mapPoint: MKMapPoint) -> CGPoint {
        let dx = mapPoint.x - origin.x, dy = mapPoint.y - origin.y
        return CGPoint(
            x: originPoint.x + dx * xAxis.dx + dy * yAxis.dx,
            y: originPoint.y + dx * xAxis.dy + dy * yAxis.dy
        )
    }

    /// 겹치는 구멍을 합치는 격자 크기(pt). 한자리에 쌓인 발자국 수백 개가 같은 그라데이션을 반복해 그리지 않게 한다.
    static let mergeCell: CGFloat = 24

    /// 화면에 닿는 구멍만, 같은 칸·같은 반경은 하나로 줄인다. 반경이 다른 현재 위치 구멍은 합치지 않는다.
    static func visibleCircles(
        centers: some Sequence<(point: CGPoint, radius: CGFloat)>,
        in rect: CGRect
    ) -> [(point: CGPoint, radius: CGFloat)] {
        var seen = Set<SIMD3<Int32>>()
        var circles: [(point: CGPoint, radius: CGFloat)] = []
        for circle in centers {
            let bounds = CGRect(
                x: circle.point.x - circle.radius, y: circle.point.y - circle.radius,
                width: circle.radius * 2, height: circle.radius * 2
            )
            guard bounds.intersects(rect) else { continue }
            let key = SIMD3<Int32>(
                Int32((circle.point.x / mergeCell).rounded(.down)),
                Int32((circle.point.y / mergeCell).rounded(.down)),
                Int32(circle.radius)
            )
            if seen.insert(key).inserted { circles.append(circle) }
        }
        return circles
    }
}

/// Apple 지도용 안개 탐험. 예전에는 `MKOverlayRenderer` 타일로 그렸는데, 값이 바뀔 때마다 타일이 비동기로 다시 그려져
/// 그 사이 안개가 빠진 타일에서 밝은 지도가 하얗게 번쩍였다. 지도 위에 올린 뷰가 같은 프레임에 직접 그리므로
/// 안개가 빠진 순간이 없다(대표 지시, ARC1030A02).
final class MapHomeFogView: UIView {
    private nonisolated(unsafe) static let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [UIColor.black.cgColor,
                 UIColor.black.withAlphaComponent(0.7).cgColor,
                 UIColor.clear.cgColor] as CFArray,
        locations: [0, 0.5, 1]
    )

    var reveals: [MapHomeFogReveal] = [] {
        didSet { mapPoints = reveals.map { MKMapPoint($0.coordinate) } }
    }
    private var mapPoints: [MKMapPoint] = []
    var opacity: CGFloat = 0
    /// 지도 좌표를 이 뷰의 화면 좌표로 옮긴다. 지도를 기울였을 때만 쓴다.
    var project: ((CLLocationCoordinate2D) -> CGPoint)?
    /// 그리기 한 번에 쓰는 변환. nil이면(기울인 지도) `project`로 하나씩 옮긴다.
    var projection: (() -> MapHomeFogProjection?)?

    /// 재생 프레임마다 현재 위치 구멍만 옮긴다. 배열 전체를 복사하지 않는다.
    func moveCurrentLocationReveal(to coordinate: CLLocationCoordinate2D) {
        guard let last = reveals.last, last.radius == MapHomeFogStrength.currentLocationRadius else { return }
        mapPoints[reveals.count - 1] = MKMapPoint(coordinate)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // 안개는 부드러운 그라데이션이라 낮은 해상도로 그려도 차이가 없다. 3배 화면 기준 그리는 픽셀이 36분의 1로 준다.
        contentScaleFactor = 0.5
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 반경별 구멍 그림. 반경은 두 가지뿐이고, 안개가 0.5배 해상도라 지름의 절반 픽셀이면 충분하다.
    private static var holeImages: [CGFloat: CGImage] = [:]

    private static func holeImage(radius: CGFloat, gradient: CGGradient) -> CGImage? {
        if let image = holeImages[radius] { return image }
        let side = Int(radius.rounded(.up))
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let center = CGPoint(x: CGFloat(side) / 2, y: CGFloat(side) / 2)
        context.drawRadialGradient(
            gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: CGFloat(side) / 2, options: []
        )
        holeImages[radius] = context.makeImage()
        return holeImages[radius]
    }

    override func draw(_ rect: CGRect) {
        let probe = MapHomePlaybackProbe.begin("apple.fogDraw"); defer { MapHomePlaybackProbe.end(probe) }
        guard let context = UIGraphicsGetCurrentContext(), let project, let gradient = Self.gradient else { return }
        context.setFillColor(UIColor.black.withAlphaComponent(opacity).cgColor)
        context.fill(rect)
        context.setBlendMode(.destinationOut)
        let projection = projection?()
        let centers = zip(reveals, mapPoints).lazy.map { reveal, mapPoint in
            (point: projection?.point(for: mapPoint) ?? project(mapPoint.coordinate), radius: reveal.radius)
        }
        // 구멍은 그라데이션을 미리 그려 둔 그림으로 찍는다. `drawRadialGradient`는 커밋 때 픽셀마다 계산돼 메인 스레드의 36%를 썼다.
        for circle in MapHomeFogProjection.visibleCircles(centers: centers, in: rect) {
            guard let image = Self.holeImage(radius: circle.radius, gradient: gradient) else { continue }
            context.draw(image, in: CGRect(
                x: circle.point.x - circle.radius, y: circle.point.y - circle.radius,
                width: circle.radius * 2, height: circle.radius * 2
            ))
        }
    }
}
