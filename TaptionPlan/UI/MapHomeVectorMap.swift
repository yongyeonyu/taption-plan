import CoreLocation
import MapKit
@preconcurrency import MapLibre
import SwiftUI
import UIKit

enum MapHomeVectorStyle: String, CaseIterable, Sendable {
    case night
    case light
    case contrast
    case pastel
    case casual

    static let sourceURL = "https://tiles.openfreemap.org/planet"
    static let glyphsURL = "https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf"
    static let routeHex = MapHomeWBSTripStyle.actualRouteHex

    var backgroundHex: String {
        switch self {
        case .night: "#0A1B2A"
        case .light: "#F7F6F4"
        case .contrast: "#030A11"
        case .pastel: "#FFF7F4"
        case .casual: "#FFF8EC"
        }
    }

    var waterHex: String {
        switch self {
        case .night: "#07131F"
        case .light: "#DDEFF4"
        case .contrast: "#0E3546"
        case .pastel: "#DCEEFF"
        case .casual: "#BFE8F0"
        }
    }

    var landuseHex: String {
        switch self {
        case .night: "#102838"
        case .light: "#E7EFE4"
        case .contrast: "#102B38"
        case .pastel: "#E5F3E4"
        case .casual: "#DDF2D2"
        }
    }

    var buildingHex: String {
        switch self {
        case .night: "#66727D"
        case .light: "#CBD5E1"
        case .contrast: "#A9B4BE"
        case .pastel: "#DCCFEB"
        case .casual: "#F1D0B4"
        }
    }

    var roadCasingHex: String {
        switch self {
        case .night: "#163C47"
        case .light, .pastel: "#FFFFFF"
        case .contrast: "#15262D"
        case .casual: "#FFFDF7"
        }
    }

    var roadHex: String {
        switch self {
        case .night: "#35C6B1"
        case .light: "#73C9A6"
        case .contrast: "#7FFFE8"
        case .pastel: "#80CFC2"
        case .casual: "#F2A37F"
        }
    }

    private var name: String {
        switch self {
        case .night: "Taption Vector Night"
        case .light: "Taption Vector Light"
        case .contrast: "Taption Vector Contrast"
        case .pastel: "Taption Vector Pastel"
        case .casual: "Taption Vector Casual"
        }
    }

    private var casualLandLayersJSON: String {
        guard self == .casual else { return "" }
        return #"""
        ,
        {
          "id": "casual-landcover",
          "type": "fill",
          "source": "openmaptiles",
          "source-layer": "landcover",
          "filter": ["in", "class", "wood", "grass", "scrub"],
          "paint": {
            "fill-color": "#CDECCF",
            "fill-opacity": 0.72
          }
        },
        {
          "id": "casual-park",
          "type": "fill",
          "source": "openmaptiles",
          "source-layer": "park",
          "paint": {
            "fill-color": "#B8E5B1",
            "fill-opacity": 0.84
          }
        }
        """#
    }

    private var casualBuildingLayersJSON: String {
        guard self == .casual else { return "" }
        return #"""
        ,
        {
          "id": "casual-building-outline",
          "type": "line",
          "source": "openmaptiles",
          "source-layer": "building",
          "minzoom": 13,
          "layout": { "line-cap": "round", "line-join": "round" },
          "paint": {
            "line-color": "#E5B48D",
            "line-opacity": 0.46,
            "line-width": ["interpolate", ["linear"], ["zoom"], 13, 0.35, 17, 1.2]
          }
        }
        """#
    }

    private var casualOverlayLayersJSON: String {
        guard self == .casual else { return "" }
        return #"""
        ,
        {
          "id": "casual-waterway",
          "type": "line",
          "source": "openmaptiles",
          "source-layer": "waterway",
          "minzoom": 8,
          "layout": { "line-cap": "round", "line-join": "round" },
          "paint": {
            "line-color": "#86CFE2",
            "line-opacity": 0.78,
            "line-width": ["interpolate", ["linear"], ["zoom"], 8, 0.6, 14, 2.8]
          }
        },
        {
          "id": "casual-place-marker",
          "type": "circle",
          "source": "openmaptiles",
          "source-layer": "place",
          "minzoom": 5,
          "filter": ["in", "class", "city", "town", "village"],
          "paint": {
            "circle-color": "#F28FA9",
            "circle-radius": ["interpolate", ["linear"], ["zoom"], 5, 2.4, 10, 3.8, 14, 5.5],
            "circle-stroke-color": "#FFF8EC",
            "circle-stroke-width": 1.5
          }
        },
        {
          "id": "casual-poi-marker",
          "type": "circle",
          "source": "openmaptiles",
          "source-layer": "poi",
          "minzoom": 13,
          "filter": ["in", "class", "cafe", "restaurant", "bakery", "shop", "supermarket"],
          "paint": {
            "circle-color": "#B965C8",
            "circle-opacity": 0.68,
            "circle-radius": 3.2,
            "circle-stroke-color": "#FFF8EC",
            "circle-stroke-width": 1
          }
        },
        {
          "id": "casual-place-label",
          "type": "symbol",
          "source": "openmaptiles",
          "source-layer": "place",
          "minzoom": 5,
          "filter": ["in", "class", "city", "town", "village", "suburb", "neighbourhood"],
          "layout": {
            "text-field": ["coalesce", ["get", "name:ko"], ["get", "name:en"], ["get", "name"]],
            "text-font": ["Noto Sans Regular"],
            "text-size": ["interpolate", ["linear"], ["zoom"], 5, 10, 10, 13, 14, 17],
            "text-max-width": 8,
            "text-padding": 4,
            "text-allow-overlap": false,
            "text-ignore-placement": false
          },
          "paint": {
            "text-color": "#6B5B53",
            "text-halo-color": "#FFF8EC",
            "text-halo-width": 2.2,
            "text-halo-blur": 0.15
          }
        },
        {
          "id": "casual-road-label",
          "type": "symbol",
          "source": "openmaptiles",
          "source-layer": "transportation_name",
          "minzoom": 12,
          "layout": {
            "symbol-placement": "line",
            "text-field": ["coalesce", ["get", "name:ko"], ["get", "name:en"], ["get", "name"]],
            "text-font": ["Noto Sans Regular"],
            "text-size": ["interpolate", ["linear"], ["zoom"], 12, 9, 16, 12],
            "text-padding": 3,
            "text-max-angle": 30,
            "text-keep-upright": true
          },
          "paint": {
            "text-color": "#8A6C5C",
            "text-halo-color": "#FFF8EC",
            "text-halo-width": 1.8,
            "text-halo-blur": 0.1
          }
        },
        {
          "id": "casual-water-label",
          "type": "symbol",
          "source": "openmaptiles",
          "source-layer": "water_name",
          "minzoom": 10,
          "layout": {
            "text-field": ["coalesce", ["get", "name:ko"], ["get", "name:en"], ["get", "name"]],
            "text-font": ["Noto Sans Regular"],
            "text-size": ["interpolate", ["linear"], ["zoom"], 10, 10, 14, 14],
            "text-padding": 4
          },
          "paint": {
            "text-color": "#5B93A2",
            "text-halo-color": "#BFE8F0",
            "text-halo-width": 1.8
          }
        },
        {
          "id": "casual-park-label",
          "type": "symbol",
          "source": "openmaptiles",
          "source-layer": "park",
          "minzoom": 12,
          "layout": {
            "text-field": ["coalesce", ["get", "name:ko"], ["get", "name:en"], ["get", "name"]],
            "text-font": ["Noto Sans Regular"],
            "text-size": ["interpolate", ["linear"], ["zoom"], 12, 9, 15, 12],
            "text-padding": 4
          },
          "paint": {
            "text-color": "#5A8F65",
            "text-halo-color": "#B8E5B1",
            "text-halo-width": 1.6
          }
        }
        """#
    }

    var json: String {
        #"""
    {
      "version": 8,
      "name": "\#(name)",
      "sources": {
        "openmaptiles": {
          "type": "vector",
          "url": "https://tiles.openfreemap.org/planet",
          "attribution": "<a href=\"https://openfreemap.org/\">OpenFreeMap</a> <a href=\"https://www.openmaptiles.org/\">© OpenMapTiles</a> Data from <a href=\"https://www.openstreetmap.org/copyright\">OpenStreetMap</a>"
        }
      },
      "glyphs": "https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf",
      "layers": [
        {
          "id": "background",
          "type": "background",
          "paint": { "background-color": "\#(backgroundHex)" }
        },
        {
          "id": "water",
          "type": "fill",
          "source": "openmaptiles",
          "source-layer": "water",
          "paint": { "fill-color": "\#(waterHex)" }
        },
        {
          "id": "landuse",
          "type": "fill",
          "source": "openmaptiles",
          "source-layer": "landuse",
          "paint": {
            "fill-color": "\#(landuseHex)",
            "fill-opacity": 0.55
          }
        }\#(casualLandLayersJSON)
        ,
        {
          "id": "building",
          "type": "fill",
          "source": "openmaptiles",
          "source-layer": "building",
          "minzoom": 12,
          "paint": {
            "fill-color": "\#(buildingHex)",
            "fill-opacity": ["interpolate", ["linear"], ["zoom"], 12, 0.42, 16, 0.78]
          }
        }\#(casualBuildingLayersJSON)
        ,
        {
          "id": "road-casing",
          "type": "line",
          "source": "openmaptiles",
          "source-layer": "transportation",
          "filter": ["all", ["==", "$type", "LineString"], ["in", "class", "motorway", "trunk", "primary", "secondary", "tertiary", "minor", "service", "path", "track", "raceway"]],
          "layout": { "line-cap": "round", "line-join": "round" },
          "paint": {
            "line-color": "\#(roadCasingHex)",
            "line-opacity": 0.92,
            "line-width": ["interpolate", ["linear"], ["zoom"], 5, 0.6, 11, 1.8, 16, 6.4, 20, 15]
          }
        },
        {
          "id": "road",
          "type": "line",
          "source": "openmaptiles",
          "source-layer": "transportation",
          "filter": ["all", ["==", "$type", "LineString"], ["in", "class", "motorway", "trunk", "primary", "secondary", "tertiary", "minor", "service", "path", "track", "raceway"]],
          "layout": { "line-cap": "round", "line-join": "round" },
          "paint": {
            "line-color": "\#(roadHex)",
            "line-opacity": ["interpolate", ["linear"], ["zoom"], 5, 0.58, 12, 0.82, 17, 0.96],
            "line-width": ["interpolate", ["linear"], ["zoom"], 5, 0.3, 11, 1.0, 16, 3.5, 20, 10]
          }
        }\#(casualOverlayLayersJSON)
      ]
    }
    """#
    }
}

extension MapDisplayStyle {
    var mapHomeVectorStyle: MapHomeVectorStyle? {
        switch self {
        case .mapLibreNight: .night
        case .mapLibreLight: .light
        case .mapLibreContrast: .contrast
        case .mapLibrePastel: .pastel
        case .mapLibreCasual: .casual
        case .standard, .simplified, .hybrid, .imagery: nil
        }
    }
}

enum MapHomeVectorNavigationMath {
    static func bearing(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> CLLocationDirection {
        let latitude1 = start.latitude * .pi / 180
        let latitude2 = end.latitude * .pi / 180
        let longitudeDelta = (end.longitude - start.longitude) * .pi / 180
        let y = sin(longitudeDelta) * cos(latitude2)
        let x = cos(latitude1) * sin(latitude2)
            - sin(latitude1) * cos(latitude2) * cos(longitudeDelta)
        let degrees = atan2(y, x) * 180 / .pi
        let normalized = degrees.truncatingRemainder(dividingBy: 360)
        return normalized < 0 ? normalized + 360 : normalized
    }
}

struct MapHomeVectorRoute {
    let id: String
    let coordinates: [CLLocationCoordinate2D]
    let colorHex: String
    let opacity: Double

    var signature: String {
        let first = coordinates.first
        let last = coordinates.last
        return [
            id,
            String(coordinates.count),
            String(first?.latitude ?? 0),
            String(first?.longitude ?? 0),
            String(last?.latitude ?? 0),
            String(last?.longitude ?? 0),
            colorHex,
            String(opacity),
        ].joined(separator: "|")
    }
}

struct MapHomeVectorMarker {
    let id: String
    let coordinate: CLLocationCoordinate2D
}

struct MapHomeVectorViewport: Equatable {
    let center: CLLocationCoordinate2D
    let span: MKCoordinateSpan
    let cameraDistance: CLLocationDistance
    let heading: CLLocationDirection
    let pitch: CGFloat
    let markerPoints: [String: CGPoint]

    var region: MKCoordinateRegion {
        MKCoordinateRegion(center: center, span: span)
    }

    var camera: MapCamera {
        MapCamera(
            centerCoordinate: center,
            distance: cameraDistance,
            heading: heading,
            pitch: pitch
        )
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.center.latitude == rhs.center.latitude
            && lhs.center.longitude == rhs.center.longitude
            && lhs.span.latitudeDelta == rhs.span.latitudeDelta
            && lhs.span.longitudeDelta == rhs.span.longitudeDelta
            && lhs.cameraDistance == rhs.cameraDistance
            && lhs.heading == rhs.heading
            && lhs.pitch == rhs.pitch
            && lhs.markerPoints == rhs.markerPoints
    }
}

struct MapHomeVectorMap: UIViewRepresentable {
    let style: MapHomeVectorStyle
    let cameraPosition: MapCameraPosition
    let cameraRevision: Int
    let historicalRoutes: [MapHomeVectorRoute]
    let activeRoute: MapHomeVectorRoute?
    let expectedRoutes: [MapHomeVectorRoute]
    let subwayRoutes: [MapHomeVectorRoute]
    let markers: [MapHomeVectorMarker]
    let contentInsets: UIEdgeInsets
    let followsHeading: Bool
    let headingDegrees: CLLocationDirection
    let displayedCoordinate: CLLocationCoordinate2D?
    let onViewportChange: (MapHomeVectorViewport, Bool) -> Void
    let onSingleFingerPanBegan: () -> Void
    let onSingleFingerPanEnded: () -> Void
    let onUserCameraGesture: () -> Void
    let onLongPress: (CLLocationCoordinate2D) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> MLNMapView {
        let mapView = MLNMapView(frame: .zero, styleJSON: style.json)
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.delegate = context.coordinator
        mapView.allowsScrolling = true
        mapView.allowsZooming = true
        mapView.allowsRotating = true
        mapView.allowsTilting = true
        mapView.showsCompassView = false
        mapView.showsLogoView = false
        mapView.showsAttributionButton = true
        mapView.attributionButtonPosition = .bottomLeft
        mapView.attributionButtonMargins = CGPoint(x: 12, y: 12)
        mapView.minimumZoomLevel = 2
        mapView.maximumZoomLevel = 20
        mapView.tintColor = UIColor(red: 0.21, green: 0.78, blue: 0.69, alpha: 1)
        context.coordinator.attach(to: mapView)
        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        context.coordinator.parent = self
        if mapView.contentInset != contentInsets {
            mapView.contentInset = contentInsets
        }
        context.coordinator.updateContent(in: mapView)
        context.coordinator.applyCameraCommandIfNeeded(to: mapView)
        context.coordinator.applyHeadingIfNeeded(to: mapView)
    }

    static func dismantleUIView(_ mapView: MLNMapView, coordinator: Coordinator) {
        coordinator.detach(from: mapView)
        mapView.delegate = nil
    }

    final class Coordinator: NSObject, @preconcurrency MLNMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: MapHomeVectorMap
        private weak var mapView: MLNMapView?
        private var styleIsLoaded = false
        private var lastCameraRevision = Int.min
        private var lastContentSignature = ""
        private var lastHeading: CLLocationDirection?
        private var lastHeadingCoordinate: CLLocationCoordinate2D?
        private var lastViewportPublishUptime: TimeInterval = 0
        private var pendingViewport:
            (viewport: MapHomeVectorViewport, force: Bool)?
        private var isViewportDeliveryScheduled = false
        private var observedPanGestures: [UIPanGestureRecognizer] = []
        private var observedCameraGestures: [UIGestureRecognizer] = []
        private var longPressGesture: UILongPressGestureRecognizer?

        init(parent: MapHomeVectorMap) {
            self.parent = parent
        }

        func attach(to mapView: MLNMapView) {
            self.mapView = mapView
            attachPanGestures(in: mapView)
            attachCameraGestures(in: mapView)
            let longPress = UILongPressGestureRecognizer(
                target: self,
                action: #selector(handleLongPress(_:))
            )
            longPress.minimumPressDuration = 0.55
            longPress.allowableMovement = 12
            longPress.cancelsTouchesInView = false
            longPress.delegate = self
            mapView.addGestureRecognizer(longPress)
            longPressGesture = longPress
        }

        func detach(from mapView: MLNMapView) {
            for gesture in observedPanGestures {
                gesture.removeTarget(self, action: #selector(handlePan(_:)))
            }
            observedPanGestures.removeAll()
            for gesture in observedCameraGestures {
                gesture.removeTarget(self, action: #selector(handleCameraGesture(_:)))
            }
            observedCameraGestures.removeAll()
            if let longPressGesture {
                mapView.removeGestureRecognizer(longPressGesture)
            }
            longPressGesture = nil
            self.mapView = nil
            pendingViewport = nil
        }

        func updateContent(in mapView: MLNMapView) {
            guard styleIsLoaded else { return }
            let signature = (
                parent.historicalRoutes.map(\.signature)
                + [parent.activeRoute?.signature ?? "-"]
                + parent.expectedRoutes.map(\.signature)
                + parent.subwayRoutes.map(\.signature)
            ).joined(separator: "#")
            guard signature != lastContentSignature else {
                publishViewport(from: mapView, force: false)
                return
            }
            lastContentSignature = signature
            setShape(
                routes: parent.historicalRoutes,
                sourceID: LayerID.historicalSource,
                in: mapView
            )
            setShape(
                routes: parent.activeRoute.map { [$0] } ?? [],
                sourceID: LayerID.activeSource,
                in: mapView
            )
            setShape(
                routes: parent.expectedRoutes,
                sourceID: LayerID.expectedSource,
                in: mapView
            )
            setShape(
                routes: parent.subwayRoutes,
                sourceID: LayerID.subwaySource,
                in: mapView
            )
            publishViewport(from: mapView, force: false)
        }

        func applyCameraCommandIfNeeded(to mapView: MLNMapView) {
            guard cameraRevisionChanged else { return }
            if let region = parent.cameraPosition.region {
                let halfLatitude = region.span.latitudeDelta / 2
                let halfLongitude = region.span.longitudeDelta / 2
                let bounds = MLNCoordinateBoundsMake(
                    CLLocationCoordinate2D(
                        latitude: region.center.latitude - halfLatitude,
                        longitude: region.center.longitude - halfLongitude
                    ),
                    CLLocationCoordinate2D(
                        latitude: region.center.latitude + halfLatitude,
                        longitude: region.center.longitude + halfLongitude
                    )
                )
                mapView.setVisibleCoordinateBounds(
                    bounds,
                    edgePadding: .zero,
                    animated: false,
                    completionHandler: nil
                )
            } else if let camera = parent.cameraPosition.camera {
                mapView.setCamera(
                    MLNMapCamera(
                        lookingAtCenter: camera.centerCoordinate,
                        altitude: camera.distance,
                        pitch: camera.pitch,
                        heading: camera.heading
                    ),
                    animated: false
                )
            } else if let coordinate = parent.displayedCoordinate {
                mapView.setCenter(coordinate, zoomLevel: 14, animated: false)
            } else if let coordinate = firstRouteCoordinate {
                mapView.setCenter(coordinate, zoomLevel: 12, animated: false)
            } else {
                mapView.setCenter(
                    CLLocationCoordinate2D(latitude: 37.5665, longitude: 126.9780),
                    zoomLevel: 10,
                    animated: false
                )
            }
            publishViewport(from: mapView, force: true)
        }

        func applyHeadingIfNeeded(to mapView: MLNMapView) {
            guard parent.followsHeading,
                  let coordinate = parent.displayedCoordinate else {
                lastHeading = nil
                lastHeadingCoordinate = nil
                return
            }
            let heading = normalizedHeading(parent.headingDegrees)
            let coordinateChanged = lastHeadingCoordinate.map {
                abs($0.latitude - coordinate.latitude) > 0.000_001
                    || abs($0.longitude - coordinate.longitude) > 0.000_001
            } ?? true
            let headingChanged = lastHeading.map {
                angularDistance($0, heading) >= 0.5
            } ?? true
            guard coordinateChanged || headingChanged else { return }
            lastHeading = heading
            lastHeadingCoordinate = coordinate
            let camera = mapView.camera
            mapView.setCamera(
                MLNMapCamera(
                    lookingAtCenter: coordinate,
                    altitude: camera.altitude,
                    pitch: camera.pitch,
                    heading: heading
                ),
                animated: false
            )
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            styleIsLoaded = true
            installRouteLayers(in: style)
            lastContentSignature = ""
            updateContent(in: mapView)
            applyCameraCommandIfNeeded(to: mapView)
            attachPanGestures(in: mapView)
            attachCameraGestures(in: mapView)
            publishViewport(from: mapView, force: true)
        }

        func mapViewRegionIsChanging(_ mapView: MLNMapView) {
            publishViewport(from: mapView, force: false)
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            publishViewport(from: mapView, force: true)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            if gesture.state == .began, gesture.numberOfTouches == 1 {
                parent.onSingleFingerPanBegan()
            } else if gesture.state == .ended
                        || gesture.state == .cancelled
                        || gesture.state == .failed {
                parent.onSingleFingerPanEnded()
            }
        }

        @objc private func handleCameraGesture(_ gesture: UIGestureRecognizer) {
            guard gesture.state == .began else { return }
            parent.onUserCameraGesture()
        }

        @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began,
                  let mapView else { return }
            parent.onLongPress(
                mapView.convert(
                    gesture.location(in: mapView),
                    toCoordinateFrom: mapView
                )
            )
        }

        private var cameraRevisionChanged: Bool {
            guard lastCameraRevision != parent.cameraRevision else { return false }
            lastCameraRevision = parent.cameraRevision
            return true
        }

        private var firstRouteCoordinate: CLLocationCoordinate2D? {
            parent.activeRoute?.coordinates.first
                ?? parent.historicalRoutes.first?.coordinates.first
                ?? parent.expectedRoutes.first?.coordinates.first
                ?? parent.subwayRoutes.first?.coordinates.first
        }

        private func attachPanGestures(in view: UIView) {
            let gestures = allSubviews(in: view).flatMap { $0.gestureRecognizers ?? [] }
                .compactMap { $0 as? UIPanGestureRecognizer }
            let currentIDs = Set(gestures.map { ObjectIdentifier($0) })
            for gesture in observedPanGestures
            where !currentIDs.contains(ObjectIdentifier(gesture)) {
                gesture.removeTarget(self, action: #selector(handlePan(_:)))
            }
            observedPanGestures.removeAll {
                !currentIDs.contains(ObjectIdentifier($0))
            }
            let observedIDs = Set(observedPanGestures.map { ObjectIdentifier($0) })
            for gesture in gestures where !observedIDs.contains(ObjectIdentifier(gesture)) {
                gesture.addTarget(self, action: #selector(handlePan(_:)))
                observedPanGestures.append(gesture)
            }
        }

        private func attachCameraGestures(in view: UIView) {
            let gestures = allSubviews(in: view).flatMap { $0.gestureRecognizers ?? [] }
                .filter { $0 is UIPinchGestureRecognizer || $0 is UIRotationGestureRecognizer }
            let currentIDs = Set(gestures.map { ObjectIdentifier($0) })
            for gesture in observedCameraGestures
            where !currentIDs.contains(ObjectIdentifier(gesture)) {
                gesture.removeTarget(self, action: #selector(handleCameraGesture(_:)))
            }
            observedCameraGestures.removeAll {
                !currentIDs.contains(ObjectIdentifier($0))
            }
            let observedIDs = Set(observedCameraGestures.map { ObjectIdentifier($0) })
            for gesture in gestures where !observedIDs.contains(ObjectIdentifier(gesture)) {
                gesture.addTarget(self, action: #selector(handleCameraGesture(_:)))
                observedCameraGestures.append(gesture)
            }
        }

        private func allSubviews(in view: UIView) -> [UIView] {
            [view] + view.subviews.flatMap(allSubviews)
        }

        private func installRouteLayers(in style: MLNStyle) {
            let historical = addSource(LayerID.historicalSource, to: style)
            let historicalLayer = lineLayer(
                LayerID.historicalLayer,
                source: historical,
                color: NSExpression(format: "CAST(color, 'UIColor')"),
                width: MapHomeWBSTripStyle.actualRouteLineWidth,
                opacity: NSExpression(forKeyPath: "opacity")
            )
            style.addLayer(historicalLayer)

            let subway = addSource(LayerID.subwaySource, to: style)
            let subwayLayer = lineLayer(
                LayerID.subwayLayer,
                source: subway,
                color: NSExpression(forConstantValue: UIColor(red: 69 / 255, green: 139 / 255, blue: 136 / 255, alpha: 1)),
                width: MapHomeWBSTripStyle.actualRouteLineWidth,
                opacity: NSExpression(forConstantValue: MapHomeWBSTripStyle.actualRouteOpacity)
            )
            style.addLayer(subwayLayer)

            let active = addSource(LayerID.activeSource, to: style)
            let activeLayer = lineLayer(
                LayerID.activeLayer,
                source: active,
                color: NSExpression(forConstantValue: UIColor(red: 69 / 255, green: 139 / 255, blue: 136 / 255, alpha: 1)),
                width: MapHomeWBSTripStyle.actualRouteLineWidth,
                opacity: NSExpression(forConstantValue: MapHomeWBSTripStyle.actualRouteOpacity)
            )
            style.addLayer(activeLayer)

            let expected = addSource(LayerID.expectedSource, to: style)
            let expectedLayer = lineLayer(
                LayerID.expectedLayer,
                source: expected,
                color: NSExpression(forConstantValue: UIColor(red: 198 / 255, green: 93 / 255, blue: 77 / 255, alpha: 1)),
                width: MapHomeWBSTripStyle.forecastRouteLineWidth,
                opacity: NSExpression(forConstantValue: MapHomeWBSTripStyle.forecastRouteOpacity)
            )
            expectedLayer.lineDashPattern = NSExpression(forConstantValue: MapHomeWBSTripStyle.routeDash)
            style.addLayer(expectedLayer)
        }

        private func addSource(_ identifier: String, to style: MLNStyle) -> MLNShapeSource {
            let source = MLNShapeSource(
                identifier: identifier,
                features: [],
                options: [.lineDistanceMetrics: true]
            )
            style.addSource(source)
            return source
        }

        private func lineLayer(
            _ identifier: String,
            source: MLNShapeSource,
            color: NSExpression,
            width: Double,
            opacity: NSExpression
        ) -> MLNLineStyleLayer {
            let layer = MLNLineStyleLayer(identifier: identifier, source: source)
            layer.lineJoin = NSExpression(forConstantValue: "round")
            layer.lineCap = NSExpression(forConstantValue: "round")
            layer.lineColor = color
            layer.lineWidth = NSExpression(forConstantValue: width)
            layer.lineOpacity = opacity
            return layer
        }

        private func setShape(
            routes: [MapHomeVectorRoute],
            sourceID: String,
            in mapView: MLNMapView
        ) {
            guard let source = mapView.style?.source(withIdentifier: sourceID)
                    as? MLNShapeSource else { return }
            let features: [MLNPolylineFeature] = routes.compactMap { route in
                guard route.coordinates.count >= 2 else { return nil }
                var coordinates = route.coordinates
                let feature = MLNPolylineFeature(
                    coordinates: &coordinates,
                    count: UInt(coordinates.count)
                )
                feature.identifier = route.id as NSString
                feature.attributes = [
                    "color": route.colorHex,
                    "opacity": route.opacity,
                ]
                return feature
            }
            source.shape = MLNShapeCollectionFeature(shapes: features)
        }

        private func publishViewport(from mapView: MLNMapView, force: Bool) {
            guard mapView.bounds.width > 0, mapView.bounds.height > 0 else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard force || now - lastViewportPublishUptime >= 1.0 / 60.0 else { return }
            lastViewportPublishUptime = now
            let bounds = mapView.visibleCoordinateBounds
            let span = MLNCoordinateBoundsGetCoordinateSpan(bounds)
            let points = Dictionary(
                uniqueKeysWithValues: parent.markers.map { marker in
                    (
                        marker.id,
                        mapView.convert(marker.coordinate, toPointTo: mapView)
                    )
                }
            )
            let camera = mapView.camera
            let viewport = MapHomeVectorViewport(
                center: mapView.centerCoordinate,
                span: MKCoordinateSpan(
                    latitudeDelta: span.latitudeDelta,
                    longitudeDelta: span.longitudeDelta
                ),
                cameraDistance: max(camera.altitude, 1),
                heading: camera.heading,
                pitch: camera.pitch,
                markerPoints: points
            )
            if let pendingViewport {
                self.pendingViewport = (
                    viewport,
                    pendingViewport.force || force
                )
            } else {
                pendingViewport = (viewport, force)
            }
            guard !isViewportDeliveryScheduled else { return }
            isViewportDeliveryScheduled = true
            DispatchQueue.main.async {
                self.isViewportDeliveryScheduled = false
                guard let pendingViewport = self.pendingViewport else {
                    return
                }
                self.pendingViewport = nil
                self.parent.onViewportChange(
                    pendingViewport.viewport,
                    pendingViewport.force
                )
            }
        }

        private func normalizedHeading(_ value: CLLocationDirection) -> CLLocationDirection {
            let normalized = value.truncatingRemainder(dividingBy: 360)
            return normalized < 0 ? normalized + 360 : normalized
        }

        private func angularDistance(
            _ lhs: CLLocationDirection,
            _ rhs: CLLocationDirection
        ) -> CLLocationDirection {
            let delta = abs(normalizedHeading(lhs) - normalizedHeading(rhs))
            return min(delta, 360 - delta)
        }

        private enum LayerID {
            static let historicalSource = "tap-historical-route-source"
            static let historicalLayer = "tap-historical-route"
            static let activeSource = "tap-active-route-source"
            static let activeCasingLayer = "tap-active-route-casing"
            static let activeLayer = "tap-active-route"
            static let expectedSource = "tap-expected-route-source"
            static let expectedLayer = "tap-expected-route"
            static let subwaySource = "tap-subway-route-source"
            static let subwayLayer = "tap-subway-route"
        }
    }
}
