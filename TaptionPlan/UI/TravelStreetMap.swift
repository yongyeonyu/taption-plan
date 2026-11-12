@preconcurrency import MapLibre
import SwiftUI

/// 여행 화면의 오픈맵(TVS1112A01): 여행에 들어가면 경계 그림 대신 길·건물이 있는 지도가 뜬다.
/// 핀·계획 길(점선)·고양이를 그 위에 올리고, 계획표가 가리지 않는 자리에 핀이 다 들어오게 맞춘다.
struct TravelStreetMap: UIViewRepresentable {
    struct Pin: Equatable {
        var longitude: Double
        var latitude: Double
        var label: String
    }

    struct Actor: Equatable {
        var longitude: Double
        var latitude: Double
        var facesEast: Bool
    }

    var pins: [Pin]
    /// 계획 길(경도, 위도). 비면 핀을 차례로 곧게 잇는다.
    var route: [SIMD2<Double>]
    var actor: Actor?
    var actorImage: UIImage?
    /// 핀이 없을 때 볼 곳.
    var fallback: SIMD2<Double>?
    /// 지도에서 가리지 않는 자리의 여백(머리말·계획표).
    var insets: UIEdgeInsets
    /// 이 값이 바뀌면 다시 맞춘다(여행·날·계획표 올림·화면 크기).
    var fitKey: String

    /// 핀들을 품는 상자. 한 점이면 둘레를 조금 넓힌다. 핀이 없으면 nil.
    static func bounds(_ pins: [Pin]) -> (west: Double, south: Double, east: Double, north: Double)? {
        guard let first = pins.first else { return nil }
        var west = first.longitude, east = first.longitude, south = first.latitude, north = first.latitude
        for pin in pins {
            west = min(west, pin.longitude)
            east = max(east, pin.longitude)
            south = min(south, pin.latitude)
            north = max(north, pin.latitude)
        }
        let pad = max(0.004, max(east - west, north - south) * 0.08)
        return (west - pad, south - pad, east + pad, north + pad)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MLNMapView {
        // 여권 잉크에 가장 가까운 밝은 지도(백자)를 쓴다. 여행 전용 색은 다음 단계.
        let mapView = MLNMapView(frame: .zero, styleJSON: MapHomeVectorStyle.porcelain.json)
        mapView.delegate = context.coordinator
        mapView.allowsRotating = false
        mapView.allowsTilting = false
        mapView.showsCompassView = false
        mapView.showsLogoView = false
        // 지도 출처 (i) 버튼은 숨기지 않는다(출처 표기 의무). 계획표에 가리지 않게 오른쪽 위에 둔다.
        mapView.showsAttributionButton = true
        mapView.attributionButtonPosition = .topRight
        mapView.attributionButtonMargins = CGPoint(x: 10, y: 150)
        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        context.coordinator.update(mapView, with: self)
    }

    final class NumberPin: MLNPointAnnotation {
        var label = ""
    }

    final class ActorPin: MLNPointAnnotation {}

    @MainActor
    final class Coordinator: NSObject, @preconcurrency MLNMapViewDelegate {
        private var shown: [Pin] = []
        private var pinAnnotations: [NumberPin] = []
        private var actorAnnotation: ActorPin?
        private var actorView: UIImageView?
        private var shownRoute: [SIMD2<Double>] = []
        private var fitted = ""
        private var pending: TravelStreetMap?
        private var routeSource: MLNShapeSource?
        private var isReady = false
        /// 지금 맞추려고 기다리는 값(같은 것을 여러 번 걸지 않는다).
        private var asking = ""

        func update(_ mapView: MLNMapView, with map: TravelStreetMap) {
            pending = map
            if shown != map.pins {
                shown = map.pins
                mapView.removeAnnotations(pinAnnotations)
                pinAnnotations = map.pins.map { pin in
                    let annotation = NumberPin()
                    annotation.coordinate = CLLocationCoordinate2D(latitude: pin.latitude, longitude: pin.longitude)
                    annotation.label = pin.label
                    return annotation
                }
                mapView.addAnnotations(pinAnnotations)
            }
            if let style = mapView.style { installRoute(style) }
            drawRoute(map)
            moveActor(mapView, map)
            // 지도가 준비되고 크기가 잡힌 뒤에만 맞춘다(그 전에 걸면 세계 지도로 남는다).
            if fitted != map.fitKey, asking != map.fitKey {
                asking = map.fitKey
                fitWhenLaidOut(mapView, animated: isReady)
            }
        }

        private func line(_ map: TravelStreetMap) -> [SIMD2<Double>] {
            map.route.count > 1 ? map.route : map.pins.map { SIMD2($0.longitude, $0.latitude) }
        }

        /// 계획 길: 남색 점선. 스타일이 아직 안 왔으면 온 뒤에 그린다.
        private func drawRoute(_ map: TravelStreetMap) {
            let points = line(map)
            guard let routeSource, shownRoute != points else { return }
            shownRoute = points
            var coordinates = points.map { CLLocationCoordinate2D(latitude: $0.y, longitude: $0.x) }
            routeSource.shape = coordinates.count > 1 ? MLNPolylineFeature(coordinates: &coordinates, count: UInt(coordinates.count)) : nil
        }

        private func moveActor(_ mapView: MLNMapView, _ map: TravelStreetMap) {
            guard let actor = map.actor, map.actorImage != nil else {
                if let actorAnnotation { mapView.removeAnnotation(actorAnnotation) }
                actorAnnotation = nil
                return
            }
            let coordinate = CLLocationCoordinate2D(latitude: actor.latitude, longitude: actor.longitude)
            if let actorAnnotation {
                actorAnnotation.coordinate = coordinate
            } else {
                let annotation = ActorPin()
                annotation.coordinate = coordinate
                actorAnnotation = annotation
                mapView.addAnnotation(annotation)
            }
            if let view = actorView, view.image !== map.actorImage { view.image = map.actorImage }
            actorView?.transform = actor.facesEast ? .identity : CGAffineTransform(scaleX: -1, y: 1)
        }

        /// 화면 크기가 잡혀 여백이 들어갈 때까지 잠깐씩 기다렸다가 맞춘다(크기 0에서 걸면 무시된다).
        func mapViewDidFinishLoadingMap(_ mapView: MLNMapView) {
            isReady = true
            if let pending, fitted != pending.fitKey { fitWhenLaidOut(mapView, animated: false) }
        }

        private func fitWhenLaidOut(_ mapView: MLNMapView, animated: Bool, tries: Int = 20) {
            guard let map = pending else { return }
            let size = mapView.bounds.size
            if size.width > map.insets.left + map.insets.right + 40, size.height > map.insets.top + map.insets.bottom + 40 {
                fitted = map.fitKey
                fit(mapView, map, animated: animated)
            } else if tries > 0 {
                Task { @MainActor [weak self, weak mapView] in
                    try? await Task.sleep(for: .milliseconds(150))
                    guard let self, let mapView else { return }
                    self.fitWhenLaidOut(mapView, animated: animated, tries: tries - 1)
                }
            }
        }

        private func fit(_ mapView: MLNMapView, _ map: TravelStreetMap, animated: Bool) {
            if let box = TravelStreetMap.bounds(map.pins) {
                let bounds = MLNCoordinateBounds(
                    sw: CLLocationCoordinate2D(latitude: box.south, longitude: box.west),
                    ne: CLLocationCoordinate2D(latitude: box.north, longitude: box.east)
                )
                mapView.setVisibleCoordinateBounds(bounds, edgePadding: map.insets, animated: animated, completionHandler: nil)
            } else if let spot = map.fallback {
                mapView.setCenter(CLLocationCoordinate2D(latitude: spot.y, longitude: spot.x), zoomLevel: 9, animated: animated)
            }
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            installRoute(style)
            fitWhenLaidOut(mapView, animated: false)
        }

        /// 계획 길 층을 한 번만 얹는다. 스타일이 대리자를 붙이기 전에 다 읽혔으면 `update`에서 얹는다.
        private func installRoute(_ style: MLNStyle) {
            guard routeSource == nil, style.source(withIdentifier: "travel-plan-route") == nil else { return }
            let source = MLNShapeSource(identifier: "travel-plan-route", shape: nil, options: nil)
            style.addSource(source)
            let layer = MLNLineStyleLayer(identifier: "travel-plan-route-line", source: source)
            layer.lineColor = NSExpression(forConstantValue: UIColor(TravelInk.plan))
            layer.lineWidth = NSExpression(forConstantValue: 3)
            layer.lineDashPattern = NSExpression(forConstantValue: [2, 1.6])
            layer.lineCap = NSExpression(forConstantValue: "round")
            layer.lineJoin = NSExpression(forConstantValue: "round")
            style.addLayer(layer)
            routeSource = source
            shownRoute = []
            isReady = true
            if let pending { drawRoute(pending) }
        }

        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            if annotation is ActorPin {
                let view = MLNAnnotationView(annotation: annotation, reuseIdentifier: nil)
                view.frame = CGRect(x: 0, y: 0, width: 52, height: 52)
                // 발이 그 자리에 오게 위로 올린다.
                view.centerOffset = CGVector(dx: 0, dy: -22)
                let image = UIImageView(image: pending?.actorImage)
                image.frame = view.bounds
                image.contentMode = .scaleAspectFit
                view.addSubview(image)
                view.layer.zPosition = 10
                actorView = image
                if pending?.actor?.facesEast == false { image.transform = CGAffineTransform(scaleX: -1, y: 1) }
                return view
            }
            guard let pin = annotation as? NumberPin else { return nil }
            let view = MLNAnnotationView(annotation: annotation, reuseIdentifier: nil)
            view.frame = CGRect(x: 0, y: 0, width: 22, height: 22)
            view.backgroundColor = UIColor(TravelInk.plan)
            view.layer.cornerRadius = 11
            view.layer.borderWidth = 1.5
            view.layer.borderColor = UIColor(TravelInk.land).cgColor
            let label = UILabel(frame: view.bounds)
            label.text = pin.label
            label.textAlignment = .center
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = UIColor(TravelInk.land)
            view.addSubview(label)
            view.accessibilityLabel = pin.label
            return view
        }
    }
}
