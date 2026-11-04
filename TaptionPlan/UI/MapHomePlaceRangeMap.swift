@preconcurrency import MapLibre
import SwiftUI

/// 등록 지점 범위를 오픈맵 위 원으로 보여 준다. 손으로 움직이지 않는 작은 지도다(RNG1105A01).
struct MapHomePlaceRangeMap: UIViewRepresentable {
    let center: CLLocationCoordinate2D
    let radiusMeters: Double
    let tint: UIColor

    /// 세로 `points` 안에 `spanMeters`가 들어오는 줌. MapLibre 타일은 512pt 기준이다.
    static func zoomLevel(latitude: Double, spanMeters: Double, points: Double) -> Double {
        let equator = 40_075_016.686
        let metersPerPoint = max(spanMeters, 1) / max(points, 1)
        return log2(cos(latitude * .pi / 180) * equator / (512 * metersPerPoint))
    }

    static func circle(center: CLLocationCoordinate2D, radiusMeters: Double, count: Int = 72) -> [CLLocationCoordinate2D] {
        let metersPerDegree = 111_320.0
        let latitudeScale = radiusMeters / metersPerDegree
        let longitudeScale = latitudeScale / max(cos(center.latitude * .pi / 180), 0.01)
        return (0...count).map { index in
            let angle = Double(index) / Double(count) * 2 * .pi
            return CLLocationCoordinate2D(
                latitude: center.latitude + latitudeScale * sin(angle),
                longitude: center.longitude + longitudeScale * cos(angle)
            )
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(tint: tint) }

    func makeUIView(context: Context) -> MLNMapView {
        let mapView = MLNMapView(frame: .zero, styleJSON: MapHomeVectorStyle.casual.json)
        mapView.delegate = context.coordinator
        mapView.allowsScrolling = false
        mapView.allowsZooming = false
        mapView.allowsRotating = false
        mapView.allowsTilting = false
        mapView.showsCompassView = false
        mapView.showsLogoView = false
        // 지도 출처 (i) 버튼은 숨기지 않는다(출처 표기 의무).
        mapView.showsAttributionButton = true
        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        context.coordinator.update(mapView, center: center, radiusMeters: radiusMeters)
    }

    final class Coordinator: NSObject, @preconcurrency MLNMapViewDelegate {
        private let tint: UIColor
        private var shownRadius: Double?
        private var fittedSpan: Double = 0
        private var shapes: [MLNAnnotation] = []

        init(tint: UIColor) { self.tint = tint }

        /// 반경이 그대로면 아무것도 하지 않고, 원이 화면을 넘을 때만 줌을 바꾼다.
        func update(_ mapView: MLNMapView, center: CLLocationCoordinate2D, radiusMeters: Double) {
            guard shownRadius != radiusMeters else { return }
            shownRadius = radiusMeters
            if radiusMeters * 2.4 > fittedSpan {
                fittedSpan = max(radiusMeters * 3, 200)
                let zoom = MapHomePlaceRangeMap.zoomLevel(latitude: center.latitude, spanMeters: fittedSpan, points: 170)
                mapView.setCenter(center, zoomLevel: zoom, animated: false)
            }
            mapView.removeAnnotations(shapes)
            var points = MapHomePlaceRangeMap.circle(center: center, radiusMeters: radiusMeters)
            shapes = [
                MLNPolygon(coordinates: &points, count: UInt(points.count)),
                MLNPolyline(coordinates: &points, count: UInt(points.count)),
            ]
            mapView.addAnnotations(shapes)
        }

        func mapView(_ mapView: MLNMapView, alphaForShapeAnnotation annotation: MLNShape) -> CGFloat {
            annotation is MLNPolygon ? 0.22 : 1
        }

        func mapView(_ mapView: MLNMapView, fillColorForPolygonAnnotation annotation: MLNPolygon) -> UIColor { tint }

        func mapView(_ mapView: MLNMapView, strokeColorForShapeAnnotation annotation: MLNShape) -> UIColor { tint }

        func mapView(_ mapView: MLNMapView, lineWidthForPolylineAnnotation annotation: MLNPolyline) -> CGFloat { 2 }
    }
}
