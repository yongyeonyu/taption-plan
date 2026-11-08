import CoreLocation
import MapKit
@preconcurrency import MapLibre
import SwiftUI
import UIKit

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
    let geometrySignature: Int
    let colorHex: String
    let opacity: Double

    var contentKey: MapHomeVectorRouteContentKey {
        MapHomeVectorRouteContentKey(id: id, geometrySignature: geometrySignature,
            colorHex: colorHex, opacity: opacity)
    }
}

struct MapHomeVectorRouteContentKey: Equatable {
    let id: String
    let geometrySignature: Int
    let colorHex: String
    let opacity: Double
}

struct MapHomeVectorContentKey: Equatable {
    let historical: [MapHomeVectorRouteContentKey]
    let active: MapHomeVectorRouteContentKey?
    let expected: [MapHomeVectorRouteContentKey]
    let subway: [MapHomeVectorRouteContentKey]
    var activeSegments: [MapHomeVectorRouteContentKey] = []
}

enum MapHomeRouteGeometrySignature {
    static func value(for coordinates: [CLLocationCoordinate2D]) -> Int {
        var hasher = Hasher()
        hasher.combine(coordinates.count)
        for coordinate in coordinates {
            hasher.combine(coordinate.latitude.bitPattern)
            hasher.combine(coordinate.longitude.bitPattern)
        }
        return hasher.finalize()
    }

    static func derived(
        from base: Int,
        coordinates: [CLLocationCoordinate2D]
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(base)
        hasher.combine(coordinates.count)
        if let last = coordinates.last {
            hasher.combine(last.latitude.bitPattern)
            hasher.combine(last.longitude.bitPattern)
        }
        return hasher.finalize()
    }
}

struct MapHomeVectorMarker: Equatable {
    let id: String
    let coordinate: CLLocationCoordinate2D

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
    }
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
    let longPressExclusionFrame: CGRect
    let followsHeading: Bool
    let headingDegrees: CLLocationDirection
    let displayedCoordinate: CLLocationCoordinate2D?
    /// 재생 중이면 카메라를 바로 놓지 않고 한 프레임 길이로 이어 움직인다(PLY1029A02).
    var easesCamera: Bool = false
    /// 재생 구동기. 있으면 코디네이터가 프레임을 직접 받아 카메라·화랑이를 움직인다(PLY1029A03).
    var playbackDriver: MapHomePlaybackDriver? = nil
    /// 구동기가 계산한 화랑이의 화면 좌표. SwiftUI 오버레이가 이 점에 화랑이를 둔다.
    var onPlaybackStickmanPoint: (CGPoint) -> Void = { _ in }
    /// 재생 중 프레임마다(최대 60Hz) 투영한 뷰포트. 장소·발자국 오버레이가 지도와 함께 움직이게 한다.
    var onPlaybackViewport: (MapHomeVectorViewport) -> Void = { _ in }
    let onViewportChange: (MapHomeVectorViewport, Bool) -> Void
    let onSingleFingerPanBegan: () -> Void
    let onSingleFingerPanEnded: () -> Void
    let onUserCameraGesture: () -> Void
    let onLongPress: (CLLocationCoordinate2D) -> Void
    let onSingleTap: (CGPoint, [String: CGPoint]) -> Void
    /// 속도 그라데이션으로 나뉜 실제 경로 구간(있으면 `activeRoute` 대신 그린다).
    var activeRouteSegments: [MapHomeVectorRoute] = []
    /// 재생 중 코디네이터 레이어에 그릴 발자국(그리는 순서). 비어 있으면 레이어를 쓰지 않는다.
    var layerPawprints: [MapHomeLayerPawprint] = []
    /// 저장된 앱 언어 값. 바뀌면 지도 글자를 그 언어로 바꾼다.
    var languageKey = ""

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
        // 지도 출처 (i) 버튼은 숨기지 않는다(출처 표기 의무). 하단 메뉴 바로 위 왼쪽에 둔다(INF1108A01).
        mapView.showsAttributionButton = true
        mapView.attributionButtonPosition = .bottomLeft
        mapView.minimumZoomLevel = 2
        mapView.maximumZoomLevel = 20
        mapView.tintColor = UIColor(red: 0.21, green: 0.78, blue: 0.69, alpha: 1)
        context.coordinator.attach(to: mapView)
        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        let probe = MapHomePlaybackProbe.begin("updateUIView"); defer { MapHomePlaybackProbe.end(probe) }
        if case let m = MapHomeLayoutStyle.attributionMargins(safeAreaBottom: mapView.safeAreaInsets.bottom), mapView.attributionButtonMargins != m { mapView.attributionButtonMargins = m } // 출처 (i)는 안전 영역이 정해진 뒤 맞춘다.
        context.coordinator.parent = self
        if mapView.contentInset != contentInsets {
            mapView.contentInset = contentInsets
        }
        context.coordinator.applySeasonColorsIfNeeded(to: mapView)
        context.coordinator.applyLabelLanguageIfNeeded(to: mapView)
        context.coordinator.updateContent(in: mapView)
        context.coordinator.updateMarkerLayer(in: mapView)
        context.coordinator.applyCameraCommandIfNeeded(to: mapView)
        context.coordinator.applyHeadingIfNeeded(to: mapView)
        context.coordinator.updateFrameRate(of: mapView)
        playbackDriver?.sink = context.coordinator
    }

    static func dismantleUIView(_ mapView: MLNMapView, coordinator: Coordinator) {
        coordinator.detach(from: mapView)
        mapView.delegate = nil
    }

    final class Coordinator: NSObject, @preconcurrency MLNMapViewDelegate, UIGestureRecognizerDelegate,
        MapHomePlaybackSink {
        var parent: MapHomeVectorMap

        var playbackCameraDistance: Double? {
            mapView.map { max($0.camera.altitude, 1) }
        }

        /// 재생 한 프레임: 카메라를 그 자리에 바로 놓고, 화랑이는 그 카메라 기준 화면 좌표(곧 정중앙)에 둔다.
        ///
        /// 예전에는 카메라를 1/60초 애니메이션으로 옮기면서, 화랑이 좌표는 카메라가 움직이기 **전**에 계산했다.
        /// 그래서 화랑이가 매 프레임 이동 반대쪽으로 한 걸음 밀렸다가 돌아와 좌우로 튀었다(PLY1029A06).
        /// 표시 링크가 매 프레임 새 위치를 주므로 애니메이션 없이 놓아도 부드럽다.
        private var lastSeasonKey: String?
        private var appliedLanguageKey: String

        /// 계절 색이 바뀌면 타일을 다시 받지 않고 레이어 색만 바꾼다(SEA1103A01).
        func applySeasonColorsIfNeeded(to mapView: MLNMapView) {
            guard parent.style == .casual, let style = mapView.style else { return }
            let season = TaptionSeasonStore.current
            guard lastSeasonKey != season.key else { return }
            lastSeasonKey = season.key
            let map = season.colors.map
            func color(_ hex: String) -> NSExpression { NSExpression(forConstantValue: UIColor(Color(hex: hex))) }
            (style.layer(withIdentifier: "background") as? MLNBackgroundStyleLayer)?.backgroundColor = color(map.background)
            for (id, hex) in [("water", map.water), ("landuse", map.land), ("building", map.building), ("casual-landcover", map.cover), ("casual-park", map.park)] {
                (style.layer(withIdentifier: id) as? MLNFillStyleLayer)?.fillColor = color(hex)
            }
            for (id, hex) in [("road-casing", map.casing), ("road", map.road), ("casual-waterway", map.waterway), ("casual-building-outline", map.buildingOutline)] {
                (style.layer(withIdentifier: id) as? MLNLineStyleLayer)?.lineColor = color(hex)
            }
            let labels = MapHomeVectorLabels.Palette.season(map)
            for label in MapHomeVectorLabels.layers {
                let layer = style.layer(withIdentifier: label.id) as? MLNSymbolStyleLayer
                layer?.textColor = color(labels.text(label.tone))
                layer?.textHaloColor = color(labels.halo(label.tone))
            }
            for (id, hex) in [("casual-place-marker", map.marker), ("casual-poi-marker", map.poi)] {
                let layer = style.layer(withIdentifier: id) as? MLNCircleStyleLayer
                layer?.circleColor = color(hex)
                layer?.circleStrokeColor = color(map.halo)
            }
        }

        /// 언어가 바뀌면 타일을 다시 받지 않고 글자 레이어의 식만 바꾼다(MLG1105A01).
        func applyLabelLanguageIfNeeded(to mapView: MLNMapView) {
            guard appliedLanguageKey != parent.languageKey, let style = mapView.style else { return }
            appliedLanguageKey = parent.languageKey
            for label in MapHomeVectorLabels.layers {
                guard let layer = style.layer(withIdentifier: label.id) as? MLNSymbolStyleLayer,
                      let field = MapHomeVectorLabels.textField(of: label) else { continue }
                layer.text = NSExpression(mglJSONObject: field)
            }
        }

        func applyPlaybackFrame(_ frame: MapHomePlaybackDriverFrame) {
            guard let mapView, mapView.bounds.width > 0, let coordinate = frame.coordinate else { return }
            let camera = mapView.camera
            mapView.setCamera(
                MLNMapCamera(
                    lookingAtCenter: coordinate,
                    altitude: frame.cameraDistance,
                    pitch: camera.pitch,
                    heading: camera.heading
                ),
                animated: false
            )
            parent.onPlaybackStickmanPoint(mapView.convert(coordinate, toPointTo: mapView))
            let now = ProcessInfo.processInfo.systemUptime
            let publishes = now - lastPlaybackViewportUptime >= Self.playbackViewportInterval
            // 발자국 레이어는 지도와 같은 틱(최대 120Hz)에 옮긴다. SwiftUI로 가는 뷰포트만 60Hz로 묶는다.
            guard publishes || !markerLayer.isEmpty else { return }
            let points = projectedMarkerPoints(in: mapView)
            markerLayer.apply(points: points, at: parent.playbackDriver.map {
                $0.inputs.dayStart.addingTimeInterval(frame.minute * 60)
            } ?? .distantFuture)
            guard publishes else { return }
            lastPlaybackViewportUptime = now
            parent.onPlaybackViewport(currentViewport(of: mapView, markerPoints: points))
        }

        /// 표시 링크 틱의 흔들림으로 한 틱씩 건너뛰지 않게 2ms 여유를 둔다. 없으면 60Hz 화면에서 평가가 40Hz로 떨어졌다.
        private static let playbackViewportInterval: TimeInterval = 1.0 / 60.0 - 0.002
        private var lastPlaybackViewportUptime: TimeInterval = 0
        private let markerLayer = MapHomeCoordinatorMarkerLayer()

        func updateMarkerLayer(in mapView: MLNMapView) {
            let host = markerLayer.host
            if host.superlayer == nil, !parent.layerPawprints.isEmpty {
                host.contentsScale = mapView.traitCollection.displayScale
                mapView.layer.addSublayer(host)
            }
            if host.frame != mapView.bounds { host.frame = mapView.bounds }
            markerLayer.update(parent.layerPawprints)
            if markerLayer.isEmpty { host.removeFromSuperlayer() }
        }

        private func projectedMarkerPoints(in mapView: MLNMapView) -> [String: CGPoint] {
            let camera = mapView.camera, bounds = mapView.visibleCoordinateBounds
            return markerProjector.points(
                markers: parent.markers,
                camera: .init(latitude: camera.centerCoordinate.latitude, longitude: camera.centerCoordinate.longitude,
                              altitude: camera.altitude, heading: camera.heading, pitch: camera.pitch, size: mapView.bounds.size),
                visible: .init(south: bounds.sw.latitude, west: bounds.sw.longitude, north: bounds.ne.latitude, east: bounds.ne.longitude),
                project: { mapView.convert($0, toPointTo: mapView) }
            )
        }

        private func currentViewport(of mapView: MLNMapView, markerPoints: [String: CGPoint]) -> MapHomeVectorViewport {
            let span = MLNCoordinateBoundsGetCoordinateSpan(mapView.visibleCoordinateBounds)
            let camera = mapView.camera
            return MapHomeVectorViewport(
                center: mapView.centerCoordinate,
                span: MKCoordinateSpan(latitudeDelta: span.latitudeDelta, longitudeDelta: span.longitudeDelta),
                cameraDistance: max(camera.altitude, 1),
                heading: camera.heading,
                pitch: camera.pitch,
                markerPoints: markerPoints
            )
        }
        private weak var mapView: MLNMapView?
        private var lastCameraRevision = Int.min
        private var lastContentSignature: MapHomeVectorContentKey?
        private var lastProjectedMarkers: [MapHomeVectorMarker] = []
        private var lastProjectionBounds = CGRect.zero
        private var lastHeading: CLLocationDirection?
        private var lastHeadingCoordinate: CLLocationCoordinate2D?
        private var viewportSampleCount = 0
        private var maximumViewportProjectionMS: Double = 0
        private var maximumViewportFrameGapMS: Double = 0
        private var lastViewportPublishUptime: TimeInterval = 0
        private let benchPan = MapHomeVectorBenchPan()
        private var markerProjector = MapHomeMarkerProjector()
        private var pendingViewport:
            (viewport: MapHomeVectorViewport, force: Bool, cameraRevision: Int)?
        private var isViewportDeliveryScheduled = false
        private var observedPanGestures = MapHomeObservedGestures<UIPanGestureRecognizer>()
        private var observedCameraGestures = MapHomeObservedGestures<UIGestureRecognizer>()
        private var longPressGesture: UILongPressGestureRecognizer?
        private var singleTapGesture: UITapGestureRecognizer?

        init(parent: MapHomeVectorMap) {
            self.parent = parent
            appliedLanguageKey = parent.languageKey
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
            let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
            singleTap.cancelsTouchesInView = false
            singleTap.delegate = self
            singleTap.require(toFail: longPress)
            mapView.addGestureRecognizer(singleTap)
            singleTapGesture = singleTap
            attachTapDependencies(in: mapView)
            updateContent(in: mapView)
            // 스타일 JSON을 바로 넘기면 스타일 완료 알림이 위임자를 놓기 전에 지나가므로 여기서 건다(MAP1104A01).
            observeBenchPan(on: mapView)
            MapHomeVectorDebugCamera.apply(to: mapView)
        }

        func detach(from mapView: MLNMapView) {
            observedPanGestures.removeAll(target: self, action: #selector(handlePan(_:)))
            observedCameraGestures.removeAll(target: self, action: #selector(handleCameraGesture(_:)))
            if let longPressGesture {
                mapView.removeGestureRecognizer(longPressGesture)
            }
            longPressGesture = nil
            if let singleTapGesture {
                mapView.removeGestureRecognizer(singleTapGesture)
            }
            singleTapGesture = nil
            self.mapView = nil
            pendingViewport = nil
        }

        func updateContent(in mapView: MLNMapView) {
            guard let style = mapView.style else { return }
            if installRouteLayers(in: style) { lastContentSignature = nil }
            let signature = MapHomeVectorContentKey(
                historical: parent.historicalRoutes.map(\.contentKey),
                active: parent.activeRoute?.contentKey,
                expected: parent.expectedRoutes.map(\.contentKey),
                subway: parent.subwayRoutes.map(\.contentKey),
                activeSegments: parent.activeRouteSegments.map(\.contentKey)
            )
            guard signature != lastContentSignature else {
                let markerProbe = MapHomePlaybackProbe.begin("mapMarkerCompare"); defer { MapHomePlaybackProbe.end(markerProbe) }
                if lastProjectedMarkers != parent.markers || lastProjectionBounds != mapView.bounds {
                    publishViewport(from: mapView, force: true)
                }
                return
            }
            let shapeProbe = MapHomePlaybackProbe.begin("mapSetShape"); defer { MapHomePlaybackProbe.end(shapeProbe) }
            setShape(
                routes: parent.historicalRoutes,
                sourceID: LayerID.historicalSource,
                in: mapView
            )
            setShape(
                routes: (parent.activeRoute.map { [$0] } ?? []) + parent.activeRouteSegments,
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
            lastContentSignature = signature
            publishViewport(from: mapView, force: false)
        }

        func applyCameraCommandIfNeeded(to mapView: MLNMapView) {
            guard mapView.bounds.width > 0, mapView.bounds.height > 0,
                  cameraRevisionChanged else { return }
            // 재생 구동기가 카메라를 맡는 동안 SwiftUI 카메라 명령은 버린다. 받으면 구동기가 놓은 카메라를
            // 예전 위치로 되돌려 화랑이가 튀고 끊겨 보인다(PLY1029A08).
            if parent.playbackDriver != nil {
                lastCameraRevision = parent.cameraRevision
                MapHomePlaybackFrameStats.blockedCameraCommands &+= 1
                return
            }
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
                let target = MLNMapCamera(
                    lookingAtCenter: camera.centerCoordinate,
                    altitude: camera.distance,
                    pitch: camera.pitch,
                    heading: camera.heading
                )
                if parent.easesCamera {
                    // 틱마다 새 목표를 주되 지도 엔진이 한 프레임(1/60초) 동안 선형으로 잇는다.
                    // 목표가 조금 불규칙하게 와도 화면에서는 끊기지 않는다.
                    mapView.setCamera(
                        target,
                        withDuration: 1.0 / 60.0,
                        animationTimingFunction: CAMediaTimingFunction(name: .linear)
                    )
                } else {
                    mapView.setCamera(target, animated: false)
                }
            } else {
                mapView.setCamera(
                    MLNMapCamera(
                        lookingAtCenter: parent.displayedCoordinate
                            ?? firstRouteCoordinate ?? MapHomeStartupCameraPolicy.fallbackCenter,
                        altitude: MapHomeStartupCameraPolicy.distance,
                        pitch: 0,
                        heading: 0
                    ),
                    animated: false
                )
            }
            publishViewport(from: mapView, force: true)
        }

        func applyHeadingIfNeeded(to mapView: MLNMapView) {
            guard mapView.bounds.width > 0, mapView.bounds.height > 0 else { return }
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
            lastContentSignature = nil
            lastSeasonKey = nil
            applySeasonColorsIfNeeded(to: mapView)
            updateContent(in: mapView)
            applyCameraCommandIfNeeded(to: mapView)
            attachPanGestures(in: mapView)
            attachCameraGestures(in: mapView)
            attachTapDependencies(in: mapView)
            publishViewport(from: mapView, force: true)
        }

        func mapViewRegionIsChanging(_ mapView: MLNMapView) {
            publishViewport(from: mapView, force: false)
        }

        static let benchPanNotification = MapHomeVectorBenchPan.notification
        static let benchPanSeconds = MapHomeVectorBenchPan.seconds

        func observeBenchPan(on mapView: MLNMapView) {
            benchPan.observe(on: mapView) { [weak self] mapView, isFinal in
                self?.publishViewport(from: mapView, force: isFinal)
                if isFinal { self?.updateFrameRate(of: mapView) }
            }
        }

        /// 움직이는 동안(재생·손가락·측정 이동)만 지도를 최대 프레임률로 그린다(PRF1101A01).
        func updateFrameRate(of mapView: MLNMapView) {
            let moving = parent.playbackDriver != nil || benchPan.isRunning
                || observedPanGestures.gestures.contains(where: MapHomeMapFrameRate.isActive)
                || observedCameraGestures.gestures.contains(where: MapHomeMapFrameRate.isActive)
            MapHomeMapFrameRate.apply(to: mapView, isMoving: moving)
        }

        func mapViewDidFinishRenderingFrame(_ mapView: MLNMapView, fullyRendered: Bool) {
            if parent.playbackDriver != nil { MapHomePlaybackFrameStats.mapRenderedFrames &+= 1 }
            guard lastCameraRevision != parent.cameraRevision else { return }
            applyCameraCommandIfNeeded(to: mapView)
            applyHeadingIfNeeded(to: mapView)
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            // 측정용 자동 이동 중에는 손가락 팬처럼 "이동 완료"를 내보내지 않는다(끝날 때 한 번만).
            guard !benchPan.isRunning else { return }
            updateFrameRate(of: mapView)
            // 재생 중에는 구동기가 매 프레임 카메라를 놓아 이 알림이 매 프레임 온다. 최종 화면으로 보내지 않는다(PLY1029A09).
            publishViewport(from: mapView, force: parent.playbackDriver == nil)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // 우리 탭·길게 누르기는 지도 자체 팬·핀치와만 함께 인식한다. 우리끼리는 순서대로(PRF1101A01).
            !isOwnGesture(otherGestureRecognizer)
        }

        private func isOwnGesture(_ gesture: UIGestureRecognizer) -> Bool {
            gesture === longPressGesture || gesture === singleTapGesture
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            guard gestureRecognizer === longPressGesture || gestureRecognizer === singleTapGesture,
                  let view = gestureRecognizer.view else { return true }
            return MapHomeLongPressRoutingMath.shouldPresentLocation(
                at: touch.location(in: view),
                excluding: parent.longPressExclusionFrame
            )
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            if let mapView { updateFrameRate(of: mapView) }
            if gesture.state == .began, gesture.numberOfTouches == 1 {
                parent.onSingleFingerPanBegan()
            } else if gesture.state == .ended
                        || gesture.state == .cancelled
                        || gesture.state == .failed {
                parent.onSingleFingerPanEnded()
            }
        }

        @objc private func handleCameraGesture(_ gesture: UIGestureRecognizer) {
            if let mapView { updateFrameRate(of: mapView) }
            guard gesture.state == .began else { return }
            parent.onUserCameraGesture()
        }

        @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard let mapView,
                  let point = MapHomeMapGestures.longPressPoint(gesture, in: mapView) else { return }
            parent.onLongPress(mapView.convert(point, toCoordinateFrom: mapView))
        }

        @objc private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let mapView else { return }
            var points: [String: CGPoint] = [:]
            for marker in parent.markers {
                points[marker.id] = mapView.convert(marker.coordinate, toPointTo: mapView)
            }
            parent.onSingleTap(gesture.location(in: mapView), points)
        }

        private func attachTapDependencies(in view: UIView) {
            guard let singleTapGesture else { return }
            for gesture in MapHomeMapGestures.all(in: view) {
                if let tap = gesture as? UITapGestureRecognizer,
                   tap !== singleTapGesture,
                   tap.numberOfTapsRequired > 1 || tap.numberOfTouchesRequired > 1 {
                    singleTapGesture.require(toFail: tap)
                }
            }
        }

        private var cameraRevisionChanged: Bool {
            guard lastCameraRevision != parent.cameraRevision else { return false }
            lastCameraRevision = parent.cameraRevision
            return true
        }

        private var firstRouteCoordinate: CLLocationCoordinate2D? {
            parent.activeRoute?.coordinates.first
                ?? parent.activeRouteSegments.first?.coordinates.first
                ?? parent.historicalRoutes.first?.coordinates.first
                ?? parent.expectedRoutes.first?.coordinates.first
                ?? parent.subwayRoutes.first?.coordinates.first
        }

        private func attachPanGestures(in view: UIView) {
            observedPanGestures.refresh(
                found: MapHomeMapGestures.pans(in: view), target: self, action: #selector(handlePan(_:))
            )
        }

        private func attachCameraGestures(in view: UIView) {
            observedCameraGestures.refresh(
                found: MapHomeMapGestures.camera(in: view), target: self, action: #selector(handleCameraGesture(_:))
            )
        }

        private func installRouteLayers(in style: MLNStyle) -> Bool {
            let pairs = [
                (LayerID.historicalSource, LayerID.historicalLayer),
                (LayerID.subwaySource, LayerID.subwayLayer),
                (LayerID.activeSource, LayerID.activeLayer),
                (LayerID.expectedSource, LayerID.expectedLayer),
            ]
            guard pairs.contains(where: {
                style.source(withIdentifier: $0.0) == nil || style.layer(withIdentifier: $0.1) == nil
            }) else { return false }
            let historical = addSource(LayerID.historicalSource, to: style)
            let historicalLayer = lineLayer(
                LayerID.historicalLayer,
                source: historical,
                color: NSExpression(format: "CAST(color, 'UIColor')"),
                width: MapHomeWBSTripStyle.actualRouteLineWidth,
                opacity: NSExpression(forKeyPath: "opacity")
            )
            if style.layer(withIdentifier: historicalLayer.identifier) == nil {
                style.addLayer(historicalLayer)
            }

            let subway = addSource(LayerID.subwaySource, to: style)
            let subwayLayer = lineLayer(
                LayerID.subwayLayer,
                source: subway,
                color: NSExpression(
                    forConstantValue: UIColor(
                        Color(hex: MapHomeWBSTripStyle.transitRouteHex)
                    )
                ),
                width: MapHomeWBSTripStyle.actualRouteLineWidth,
                opacity: NSExpression(forConstantValue: MapHomeWBSTripStyle.actualRouteOpacity)
            )
            if style.layer(withIdentifier: subwayLayer.identifier) == nil {
                style.addLayer(subwayLayer)
            }

            let active = addSource(LayerID.activeSource, to: style)
            // 구간마다 색(속도 그라데이션)이 달라 feature 속성에서 읽는다.
            let activeLayer = lineLayer(
                LayerID.activeLayer,
                source: active,
                color: NSExpression(format: "CAST(color, 'UIColor')"),
                width: MapHomeWBSTripStyle.actualRouteLineWidth,
                opacity: NSExpression(forKeyPath: "opacity")
            )
            if style.layer(withIdentifier: activeLayer.identifier) == nil {
                style.addLayer(activeLayer)
            }

            let expected = addSource(LayerID.expectedSource, to: style)
            let expectedLayer = lineLayer(
                LayerID.expectedLayer,
                source: expected,
                color: NSExpression(format: "CAST(color, 'UIColor')"),
                width: MapHomeWBSTripStyle.forecastRouteLineWidth,
                opacity: NSExpression(forKeyPath: "opacity")
            )
            expectedLayer.lineDashPattern = NSExpression(forConstantValue: MapHomeWBSTripStyle.routeDash)
            if style.layer(withIdentifier: expectedLayer.identifier) == nil {
                style.addLayer(expectedLayer)
            }
            return true
        }

        private func addSource(_ identifier: String, to style: MLNStyle) -> MLNShapeSource {
            if let source = style.source(withIdentifier: identifier) as? MLNShapeSource {
                return source
            }
            let source = MLNShapeSource(
                identifier: identifier,
                features: [],
                // Distance metrics are for gradients; they distort dashed routes when zooming.
                options: nil
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
            if viewportSampleCount > 0 {
                maximumViewportFrameGapMS = max(maximumViewportFrameGapMS,
                    (now - lastViewportPublishUptime) * 1_000)
            }
            viewportSampleCount += 1
            lastViewportPublishUptime = now
            lastProjectedMarkers = parent.markers
            lastProjectionBounds = mapView.bounds
            let bounds = mapView.visibleCoordinateBounds
            let span = MLNCoordinateBoundsGetCoordinateSpan(bounds)
            let points = projectedMarkerPoints(in: mapView)
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
            maximumViewportProjectionMS = max(maximumViewportProjectionMS,
                (ProcessInfo.processInfo.systemUptime - now) * 1_000)
            if force {
                if viewportSampleCount > 1 {
                    TaptionPlanDiagnosticsLogger.shared.record("map_viewport_performance", fields: [
                        "renderer": "vector",
                        "sample_count": String(viewportSampleCount),
                        "marker_count": String(parent.markers.count),
                        "max_projection_ms": String(format: "%.2f", maximumViewportProjectionMS),
                        "max_frame_gap_ms": String(format: "%.2f", maximumViewportFrameGapMS),
                    ])
                }
                viewportSampleCount = 0
                maximumViewportProjectionMS = 0
                maximumViewportFrameGapMS = 0
            }
            if let pendingViewport {
                self.pendingViewport = (
                    viewport,
                    pendingViewport.force || force,
                    lastCameraRevision
                )
            } else {
                pendingViewport = (viewport, force, lastCameraRevision)
            }
            guard !isViewportDeliveryScheduled else { return }
            isViewportDeliveryScheduled = true
            DispatchQueue.main.async {
                self.isViewportDeliveryScheduled = false
                guard let pendingViewport = self.pendingViewport else {
                    return
                }
                self.pendingViewport = nil
                guard pendingViewport.cameraRevision == self.parent.cameraRevision else { return }
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
            static let activeLayer = "tap-active-route"
            static let expectedSource = "tap-expected-route-source"
            static let expectedLayer = "tap-expected-route"
            static let subwaySource = "tap-subway-route-source"
            static let subwayLayer = "tap-subway-route"
        }
    }
}
