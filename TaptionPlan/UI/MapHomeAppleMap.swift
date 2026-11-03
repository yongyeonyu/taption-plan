import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

struct MapHomeAppleMap: UIViewRepresentable {
    let style: MapDisplayStyle
    let accessibilityLabel: String
    let cameraPosition: MapCameraPosition
    let cameraRevision: Int
    let viewportCommand: MapHomeAppleViewportCommand?
    let routes: [MapHomeAppleRoute]
    let annotations: [MapHomeAppleAnnotation]
    let playback: MapHomeApplePlayback?
    let centersPlayback: Bool
    let playbackTargetPoint: CGPoint
    /// 재생 구동기. 있으면 코디네이터가 프레임을 직접 받아 카메라·화랑이를 움직인다(ARC1030A04).
    var playbackDriver: MapHomePlaybackDriver? = nil
    let contentInsets: UIEdgeInsets
    let longPressExclusionFrame: CGRect
    /// nil = 안개 탐험 꺼짐.
    let fogReveals: [MapHomeFogReveal]?
    /// 안개가 지도를 덮는 불투명도. 벡터 지도와 같은 값을 쓴다.
    let fogOpacity: CGFloat
    /// 화랑이 점이 움직일 때마다(최대 120Hz). 구독한 UIKit 뷰만 옮기고 SwiftUI는 깨우지 않는다.
    let onLiveStickmanPoint: (CGPoint?) -> Void
    /// 카운터를 화랑이 마커의 자식으로 붙이는 연결.
    var counterAttachment: MapHomeMarkerAttachment? = nil
    /// SwiftUI로 가는 카메라 값(최대 60Hz).
    let onCameraFrame: (MapHomeCameraFrame, CGPoint?, Bool) -> Void
    let onSingleFingerPanBegan: () -> Void
    let onUserCameraGesture: () -> Void
    let onLongPress: (CLLocationCoordinate2D) -> Void
    let onAnnotationSelected: (MapHomeAppleAnnotationKind) -> Void
    /// 화랑이를 눌렀을 때(하루 요약 카드를 연다).
    /// 지도 탭(지도 로컬 좌표, 화랑이를 눌렀는지). 지도 탭은 UIKit 한 경로로만 받는다(PRF1101A01).
    var onMapTap: (CGPoint, Bool) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.delegate = context.coordinator
        mapView.layoutMargins = contentInsets
        mapView.isRotateEnabled = true
        mapView.isPitchEnabled = true
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.showsTraffic = false
        mapView.showsUserLocation = true
        mapView.pointOfInterestFilter = .excludingAll
        mapView.accessibilityIdentifier = "MapHome.appleMap"
        mapView.accessibilityLabel = accessibilityLabel
        context.coordinator.attach(to: mapView)
        context.coordinator.applyMapStyle(to: mapView)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        let probe = MapHomePlaybackProbe.begin("apple.updateUIView"); defer { MapHomePlaybackProbe.end(probe) }
        context.coordinator.parent = self
        context.coordinator.isApplyingSwiftUIUpdate = true
        defer { context.coordinator.isApplyingSwiftUIUpdate = false }
        if mapView.layoutMargins != contentInsets {
            mapView.layoutMargins = contentInsets
        }
        if mapView.accessibilityLabel != accessibilityLabel {
            mapView.accessibilityLabel = accessibilityLabel
        }
        context.coordinator.refreshGestureAttachments(in: mapView)
        context.coordinator.applyMapStyle(to: mapView)
        context.coordinator.updateContent(in: mapView)
        context.coordinator.applyCameraCommandIfNeeded(to: mapView)
        context.coordinator.applyViewportCommandIfNeeded(to: mapView)
        context.coordinator.finishPlaybackIfEnded(in: mapView)
        playbackDriver?.sink = context.coordinator
    }

    static func dismantleUIView(_ mapView: MKMapView, coordinator: Coordinator) {
        coordinator.detach(from: mapView)
        mapView.delegate = nil
    }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate, MapHomePlaybackSink {
        var parent: MapHomeAppleMap
        private weak var mapView: MKMapView?
        private var lastCameraRevision = Int.min
        private var lastViewportCommandRevision = 0
        // 내용 비교는 문자열을 이어 붙이지 않고 해시 revision으로 한다(PRF1101A01).
        private var lastRoutesSignature: Int?
        private var lastMapStyleRawValue: String?
        private var lastAnnotationsSignature: Int?
        private var lastPlaybackSignature: Int?
        private var lastCentersPlayback: Bool?
        private var lastCenteredPlaybackCoordinate: CLLocationCoordinate2D?
        private var lastCenteredPlaybackTargetPoint: CGPoint?
        private var routeStyles: [ObjectIdentifier: MapHomeAppleRouteStyle] = [:]
        private var routePolylines: [String: MKPolyline] = [:]
        private var fogView: MapHomeFogView?
        private var lastFogDrawUptime: TimeInterval = 0
        private var isFogRedrawScheduled = false

        /// 지도가 움직이는 동안 안개는 최대 20Hz로 다시 그린다. 부드러운 그라데이션이라 카메라(120Hz)보다 늦어도 티가 적다. 마지막 값은 한 번 더 그려 놓치지 않는다.
        private func redrawFogThrottled() {
            guard let fogView else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastFogDrawUptime >= 1.0 / 20.0 {
                lastFogDrawUptime = now
                fogView.setNeedsDisplay()
            } else if !isFogRedrawScheduled {
                isFogRedrawScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 20.0) { [weak self] in
                    guard let self else { return }
                    self.isFogRedrawScheduled = false
                    self.lastFogDrawUptime = ProcessInfo.processInfo.systemUptime
                    self.fogView?.setNeedsDisplay()
                }
            }
        }
        private var lastFogReveals: [MapHomeFogReveal]?
        private var lastFogOpacity: CGFloat = 0
        private var routeSignatures: [String: Int] = [:]
        private var walkerAnnotation: MapHomeAppleWalkerAnnotation?
        private var walkerView: MapHomeAppleHostedAnnotationView?
        private var observedPanGestures = MapHomeObservedGestures<UIPanGestureRecognizer>()
        private var observedCameraGestures = MapHomeObservedGestures<UIGestureRecognizer>()
        private var lastGestureAttachmentScanUptime = -Double.infinity
        private var longPressGesture: UILongPressGestureRecognizer?
        fileprivate var isApplyingSwiftUIUpdate = false
        private var cameraFramePublishPending = false
        private var cameraFramePublishIsFinal = false
        private var lastCameraPublishUptime = -Double.infinity
        /// 카운터 채널로 마지막에 보낸 화랑이 점(측정용).
        private var lastPublishedLocationPoint: CGPoint?
        /// 재생 프레임을 놓는 중이면 지도 콜백을 무시한다(끝에 한 번만 보낸다).
        private var isApplyingPlaybackFrame = false
        private var hasRunPlayback = false
        private var annotationRevisions: [String: Int] = [:]
        private var fallbackAnchorCoordinate: CLLocationCoordinate2D?

        init(parent: MapHomeAppleMap) {
            self.parent = parent
        }

        func attach(to mapView: MKMapView) {
            self.mapView = mapView
            refreshGestureAttachments(in: mapView, force: true)
            observeBenchPan()

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

            // 화랑이를 누르면 하루 요약 카드를 연다. 화랑이는 상호작용이 꺼진 겹침 뷰라 지도 탭에서 위치로 판정한다.
            let walkerTap = UITapGestureRecognizer(target: self, action: #selector(handleWalkerTap(_:)))
            walkerTap.cancelsTouchesInView = false
            walkerTap.delegate = self
            mapView.addGestureRecognizer(walkerTap)
            walkerTapGesture = walkerTap
        }

        private var walkerTapGesture: UITapGestureRecognizer?
        private static let walkerHitRadius: CGFloat = 36

        /// 화랑이가 그려지는 점(지도 뷰 좌표). 없으면 nil.
        private func walkerPoint(in mapView: MKMapView) -> CGPoint? {
            guard let walkerAnnotation else { return nil }
            let point = mapView.convert(walkerAnnotation.coordinate, toPointTo: mapView)
            return CGPoint(
                x: point.x + MapHomeStickmanAnnotationLayout.centerOffset.x,
                y: point.y + MapHomeStickmanAnnotationLayout.centerOffset.y
            )
        }

        @objc private func handleWalkerTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let mapView else { return }
            let location = gesture.location(in: mapView)
            let hitsWalker = walkerPoint(in: mapView).map {
                hypot(location.x - $0.x, location.y - $0.y) <= Self.walkerHitRadius
            } ?? false
            parent.onMapTap(location, hitsWalker)
        }

        func detach(from mapView: MKMapView) {
            if let walkerTapGesture { mapView.removeGestureRecognizer(walkerTapGesture) }
            walkerTapGesture = nil
            parent.counterAttachment?.attach(nil)
            walkerView?.removeFromSuperview()
            walkerView = nil
            observedPanGestures.removeAll(target: self, action: #selector(handlePan(_:)))
            observedCameraGestures.removeAll(target: self, action: #selector(handleCameraGesture(_:)))
            if let longPressGesture {
                mapView.removeGestureRecognizer(longPressGesture)
            }
            longPressGesture = nil
            lastGestureAttachmentScanUptime = -Double.infinity
            cameraFramePublishIsFinal = false
            lastCameraPublishUptime = -Double.infinity
            self.mapView = nil
        }

        func refreshGestureAttachments(
            in mapView: MKMapView,
            force: Bool = false
        ) {
            let now = ProcessInfo.processInfo.systemUptime
            guard force || now - lastGestureAttachmentScanUptime >= 1 else {
                return
            }
            lastGestureAttachmentScanUptime = now
            attachPanGestures(in: mapView)
            attachCameraGestures(in: mapView)
            // 두 번 탭(확대)이 한 번 탭으로도 처리되지 않게 한다.
            for tap in MapHomeMapGestures.all(in: mapView).compactMap({ $0 as? UITapGestureRecognizer })
            where tap !== walkerTapGesture && tap.numberOfTapsRequired > 1 { walkerTapGesture?.require(toFail: tap) }
        }

        func attachPanGestures(in view: UIView) {
            observedPanGestures.refresh(
                found: MapHomeMapGestures.pans(in: view), target: self, action: #selector(handlePan(_:))
            )
        }

        func applyMapStyle(to mapView: MKMapView) {
            let style = parent.style.runtimeStyle
            guard lastMapStyleRawValue != style.rawValue else { return }
            lastMapStyleRawValue = style.rawValue
            mapView.overrideUserInterfaceStyle = .light
            mapView.clipsToBounds = true
            mapView.layer.masksToBounds = true
            mapView.pointOfInterestFilter = .excludingAll
            mapView.showsTraffic = false
            switch style {
            case .hybrid:
                // 위성(하이브리드): 항공 사진 위에 도로·지명.
                mapView.mapType = .hybrid
                mapView.backgroundColor = .black
                let configuration = MKHybridMapConfiguration(elevationStyle: .flat)
                configuration.pointOfInterestFilter = .excludingAll
                configuration.showsTraffic = false
                mapView.preferredConfiguration = configuration
            case .standard:
                mapView.mapType = .standard
                mapView.backgroundColor = UIColor(hex: MapHomeWBSTripStyle.paperHex)
                let configuration = MKStandardMapConfiguration(
                    elevationStyle: .flat,
                    emphasisStyle: .default
                )
                configuration.pointOfInterestFilter = .excludingAll
                configuration.showsTraffic = false
                mapView.preferredConfiguration = configuration
            default:
                // 간략화(그리고 벡터 스타일의 Apple 대체): 기존의 흐린(muted) 표준 지도.
                mapView.mapType = .mutedStandard
                mapView.backgroundColor = UIColor(hex: MapHomeWBSTripStyle.paperHex)
                let configuration = MKStandardMapConfiguration(
                    elevationStyle: .flat,
                    emphasisStyle: .muted
                )
                configuration.pointOfInterestFilter = .excludingAll
                configuration.showsTraffic = false
                mapView.preferredConfiguration = configuration
            }
        }

        func updateContent(in mapView: MKMapView) {
            updateFog(in: mapView)
            updateRoutes(in: mapView)
            updateAnnotations(in: mapView)
            updateWalker(in: mapView)
            updateWalkerPosition(in: mapView)
        }

        var playbackCameraDistance: Double? {
            mapView.map { max($0.camera.centerCoordinateDistance, 1) }
        }

        /// 재생 한 프레임: 카메라를 그 자리에 바로 놓고 화랑이와 안개 구멍을 같은 좌표로 옮긴다. SwiftUI를 거치지 않는다.
        func applyPlaybackFrame(_ frame: MapHomePlaybackDriverFrame) {
            guard let mapView, mapView.bounds.width > 0, let coordinate = frame.coordinate else { return }
            let probe = MapHomePlaybackProbe.begin("apple.frame"); defer { MapHomePlaybackProbe.end(probe) }
            hasRunPlayback = true
            // 카메라·화랑이를 다 옮긴 뒤 점을 한 번만 보낸다. 벡터 지도와 같은 순서다.
            isApplyingPlaybackFrame = true
            walkerAnnotation?.coordinate = coordinate
            MapHomeAppleCameraCommand.center(
                coordinate, at: parent.playbackTargetPoint, distance: frame.cameraDistance, on: mapView
            )
            isApplyingPlaybackFrame = false
            updateWalkerPosition(in: mapView)
            fogView?.moveCurrentLocationReveal(to: coordinate)
            redrawFogThrottled()
            sendLiveStickmanPoint(in: mapView)
            publishCameraFrame(from: mapView, isFinal: false)
            MapHomeAppleCounterDriftProbe.note(published: lastPublishedLocationPoint, actual: walkerPoint(in: mapView))
        }

        /// 재생이 끝나면 멈춘 카메라를 SwiftUI에 한 번 올린다. 재생 중에는 "이동 완료"를 올리지 않는다.
        func finishPlaybackIfEnded(in mapView: MKMapView) {
            guard hasRunPlayback, parent.playbackDriver == nil else { return }
            hasRunPlayback = false
            fogView?.setNeedsDisplay()
            publishCameraFrameAfterUpdate(from: mapView, isFinal: true)
        }

        func applyCameraCommandIfNeeded(to mapView: MKMapView) {
            guard lastCameraRevision != parent.cameraRevision else { return }
            lastCameraRevision = parent.cameraRevision
            // 구동기가 카메라를 맡는 동안 SwiftUI 카메라 명령은 버린다. 받으면 구동기가 놓은 카메라가 되돌려진다.
            if parent.playbackDriver != nil { return }
            if let revision = parent.viewportCommand?.revision,
               revision != lastViewportCommandRevision {
                return
            }

            if let region = parent.cameraPosition.region {
                mapView.setRegion(region, animated: false)
            } else if let camera = parent.cameraPosition.camera {
                mapView.setCamera(
                    MKMapCamera(
                        lookingAtCenter: camera.centerCoordinate,
                        fromDistance: camera.distance,
                        pitch: camera.pitch,
                        heading: camera.heading
                    ),
                    animated: false
                )
            } else if let coordinate = parent.playback?.cameraCoordinate {
                mapView.setCenter(coordinate, animated: false)
            } else if let coordinate = parent.routes.first?.coordinates.first {
                mapView.setCenter(coordinate, animated: false)
            }
            publishCameraFrameAfterUpdate(from: mapView, isFinal: true)
        }

        func applyViewportCommandIfNeeded(to mapView: MKMapView) {
            guard let command = parent.viewportCommand,
                  command.revision != lastViewportCommandRevision else { return }
            lastViewportCommandRevision = command.revision
            if parent.playbackDriver != nil { return }
            if let heading = command.heading {
                MapHomeAppleCameraCommand.heading(
                    heading,
                    centeredAt: command.centerCoordinate,
                    targetPoint: command.targetPoint,
                    distance: command.distance,
                    on: mapView
                )
            } else if let coordinate = command.centerCoordinate {
                MapHomeAppleCameraCommand.center(
                    coordinate,
                    at: command.targetPoint,
                    distance: command.distance,
                    on: mapView
                )
            }
            publishCameraFrameAfterUpdate(from: mapView, isFinal: true)
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            guard benchPanLink == nil, !isApplyingPlaybackFrame else { return }
            cameraMoved(in: mapView)
        }

        /// 지도가 움직인 한 프레임: 화랑이·카운터는 프레임마다, SwiftUI 값은 60Hz로 묶어 올린다.
        private func cameraMoved(in mapView: MKMapView) {
            redrawFogThrottled()
            updateWalkerPosition(in: mapView)
            sendLiveStickmanPoint(in: mapView)
            publishCameraFrame(from: mapView, isFinal: false)
        }

        // 측정용 자동 지도 이동(`-autoBenchMapPan`, PRF1030A02). 손가락 팬처럼 프레임마다 "보이는 영역 바뀜"만 내보내고
        // "이동 완료"는 끝에 한 번만 보낸다. 실행 인자가 없으면 쓰이지 않는다.
        private var benchPanLink: CADisplayLink?
        private var benchPanStart: (uptime: TimeInterval, center: CLLocationCoordinate2D, span: Double)?
        private var benchObserver: NSObjectProtocol?

        private func observeBenchPan() {
            guard ProcessInfo.processInfo.arguments.contains("-autoBenchMapPan"), benchObserver == nil else { return }
            benchObserver = NotificationCenter.default.addObserver(
                forName: MapHomeVectorMap.Coordinator.benchPanNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.startBenchPan() }
            }
        }

        private func startBenchPan() {
            guard let mapView, benchPanLink == nil else { return }
            benchPanStart = (ProcessInfo.processInfo.systemUptime, mapView.centerCoordinate, mapView.region.span.longitudeDelta)
            let link = CADisplayLink(target: self, selector: #selector(benchPanTick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            benchPanLink = link
        }

        @objc private func benchPanTick() {
            guard let mapView, let start = benchPanStart else { return }
            let elapsed = ProcessInfo.processInfo.systemUptime - start.uptime
            guard elapsed < MapHomeVectorMap.Coordinator.benchPanSeconds else {
                benchPanLink?.invalidate()
                benchPanLink = nil
                benchPanStart = nil
                self.mapView(mapView, regionDidChangeAnimated: false)
                return
            }
            let offset = sin(elapsed * .pi) * start.span * 0.5
            mapView.setCenter(
                CLLocationCoordinate2D(latitude: start.center.latitude, longitude: start.center.longitude + offset),
                animated: false
            )
            cameraMoved(in: mapView)
        }

        func mapView(_: MKMapView, regionWillChangeAnimated _: Bool) {
            // Pan/pinch callbacks are observed directly. Walking every MapKit
            // subview here competes with the gesture's first camera frames.
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            guard benchPanLink == nil, !isApplyingPlaybackFrame else { return }
            // 애니메이션 없이 놓은 재생 카메라는 프레임마다 "이동 완료"를 알린다. 그대로 올리면 화면 전체가 프레임마다 다시 평가된다.
            guard parent.playbackDriver == nil else { return cameraMoved(in: mapView) }
            fogView?.setNeedsDisplay()
            updateWalkerPosition(in: mapView)
            sendLiveStickmanPoint(in: mapView)
            publishCameraFrame(from: mapView, isFinal: true)
        }

        func mapView(_ mapView: MKMapView, didAdd views: [MKAnnotationView]) {
            normalizeAnnotationLayerOrder(of: views, in: mapView)
        }

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            updateWalker(in: mapView)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation {
                let reuseIdentifier = "MapHome.hiddenUserLocation"
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: reuseIdentifier
                ) ?? MKAnnotationView(
                    annotation: annotation,
                    reuseIdentifier: reuseIdentifier
                )
                view.annotation = annotation
                view.isHidden = true
                view.isAccessibilityElement = false
                view.canShowCallout = false
                return view
            }
            guard let annotation = annotation as? MapHomeAppleMapAnnotation else {
                return nil
            }
            if case .pawprint = annotation.kind {
                let pawIdentifier = "MapHome.applePawprint"
                let pawView = (mapView.dequeueReusableAnnotationView(withIdentifier: pawIdentifier)
                    as? MapHomeApplePawprintAnnotationView)
                    ?? MapHomeApplePawprintAnnotationView(annotation: annotation, reuseIdentifier: pawIdentifier)
                configurePawprint(pawView, annotation: annotation)
                return pawView
            }
            let reuseIdentifier = "MapHome.appleAnnotation"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: reuseIdentifier)
                as? MapHomeAppleHostedAnnotationView)
                ?? MapHomeAppleHostedAnnotationView(
                    annotation: annotation,
                    reuseIdentifier: reuseIdentifier
                )
            configure(view, annotation: annotation)
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let annotation = view.annotation as? MapHomeAppleMapAnnotation else {
                return
            }
            // 화랑이 바로 아래에 있는 표식은 화랑이가 먼저 눌린다. 같은 손짓이 발자국·장소 선택으로 새지 않게 한다.
            let coveredByWalker = walkerPoint(in: mapView).map { center in
                let point = mapView.convert(annotation.coordinate, toPointTo: mapView)
                return hypot(point.x - center.x, point.y - center.y) <= Self.walkerHitRadius
            } ?? false
            if annotation.isInteractive, !coveredByWalker {
                parent.onAnnotationSelected(annotation.kind)
            }
            mapView.deselectAnnotation(annotation, animated: false)
            updateWalkerPosition(in: mapView)
        }

        func mapView(
            _ mapView: MKMapView,
            rendererFor overlay: MKOverlay
        ) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline,
                  let style = routeStyles[ObjectIdentifier(polyline)] else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = style.color.withAlphaComponent(style.opacity)
            renderer.lineWidth = style.lineWidth
            renderer.lineCap = .round
            renderer.lineJoin = .round
            if style.dashed {
                renderer.lineDashPattern = MapHomeWBSTripStyle.routeDash
            }
            return renderer
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // 우리 탭·길게 누르기는 지도 자체 제스처와만 함께 인식한다(PRF1101A01).
            otherGestureRecognizer !== longPressGesture && otherGestureRecognizer !== walkerTapGesture
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            if gestureRecognizer === longPressGesture {
                guard !MapHomeLongPressRoutingMath.isAnnotationTouch(touch.view) else {
                    return false
                }
                guard let view = gestureRecognizer.view else { return true }
                return MapHomeLongPressRoutingMath.shouldPresentLocation(
                    at: touch.location(in: view),
                    excluding: parent.longPressExclusionFrame
                )
            }
            return !MapHomeLongPressRoutingMath.isAnnotationTouch(touch.view)
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard gesture.numberOfTouches <= 1 else { return }
            switch gesture.state {
            case .began:
                parent.onSingleFingerPanBegan()
            case .ended, .cancelled, .failed:
                break
            default:
                break
            }
        }

        @objc private func handleCameraGesture(_ gesture: UIGestureRecognizer) {
            guard gesture.state == .began else { return }
            parent.onUserCameraGesture()
        }

        @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard let mapView,
                  let point = MapHomeMapGestures.longPressPoint(gesture, in: mapView) else { return }
            parent.onLongPress(mapView.convert(point, toCoordinateFrom: mapView))
        }

        private func updateRoutes(in mapView: MKMapView) {
            let probe = MapHomePlaybackProbe.begin("apple.routes"); defer { MapHomePlaybackProbe.end(probe) }
            let routeSignatures = Dictionary(
                parent.routes.map { route in
                    (route.id, MapHomeContentRevision.of(
                        route.id, route.phase == .actual, route.geometrySignature, route.colorHex, route.opacity
                    ))
                },
                uniquingKeysWith: { first, _ in first }
            )
            var hasher = Hasher()
            for route in parent.routes { hasher.combine(routeSignatures[route.id]) }
            let signature = hasher.finalize()
            guard signature != lastRoutesSignature else { return }
            lastRoutesSignature = signature
            let staleIDs = Set(self.routePolylines.keys).filter {
                routeSignatures[$0] != self.routeSignatures[$0]
            }
            let removed = staleIDs.compactMap {
                self.routePolylines.removeValue(forKey: $0)
            }
            for polyline in removed {
                routeStyles.removeValue(forKey: ObjectIdentifier(polyline))
            }
            if !removed.isEmpty {
                mapView.removeOverlays(removed)
            }
            for id in staleIDs {
                self.routeSignatures.removeValue(forKey: id)
            }
            let polylines = parent.routes.compactMap { route -> MKPolyline? in
                guard self.routePolylines[route.id] == nil else { return nil }
                guard route.coordinates.count >= 2 else { return nil }
                var coordinates = route.coordinates
                let polyline = MKPolyline(
                    coordinates: &coordinates,
                    count: coordinates.count
                )
                self.routePolylines[route.id] = polyline
                self.routeSignatures[route.id] = routeSignatures[route.id]
                routeStyles[ObjectIdentifier(polyline)] = MapHomeAppleRouteStyle(
                    color: UIColor(hex: route.colorHex),
                    opacity: CGFloat(min(max(route.opacity, 0), 1)),
                    lineWidth: route.phase == .actual
                        ? MapHomeWBSTripStyle.actualRouteLineWidth
                        : MapHomeWBSTripStyle.forecastRouteLineWidth,
                    dashed: route.phase == .forecast
                )
                return polyline
            }
            guard !polylines.isEmpty else { return }
            mapView.addOverlays(polylines, level: .aboveRoads)
        }

        private func updateFog(in mapView: MKMapView) {
            guard parent.fogReveals != lastFogReveals || parent.fogOpacity != lastFogOpacity else { return }
            lastFogReveals = parent.fogReveals
            lastFogOpacity = parent.fogOpacity
            guard let reveals = parent.fogReveals else {
                fogView?.removeFromSuperview()
                fogView = nil
                return
            }
            let view: MapHomeFogView
            if let fogView {
                view = fogView
            } else {
                view = MapHomeFogView(frame: mapView.bounds)
                view.project = { [weak mapView, weak view] coordinate in
                    guard let mapView, let view else { return .zero }
                    return mapView.convert(coordinate, toPointTo: view)
                }
                view.projection = { [weak mapView, weak view] in
                    guard let mapView, let view, mapView.camera.pitch < 1 else { return nil }
                    let origin = MKMapPoint(mapView.centerCoordinate)
                    let step = max(mapView.visibleMapRect.width / 4, 1)
                    let originPoint = mapView.convert(origin.coordinate, toPointTo: view)
                    let x = mapView.convert(MKMapPoint(x: origin.x + step, y: origin.y).coordinate, toPointTo: view)
                    let y = mapView.convert(MKMapPoint(x: origin.x, y: origin.y + step).coordinate, toPointTo: view)
                    return MapHomeFogProjection(
                        origin: origin,
                        originPoint: originPoint,
                        xAxis: CGVector(dx: (x.x - originPoint.x) / step, dy: (x.y - originPoint.y) / step),
                        yAxis: CGVector(dx: (y.x - originPoint.x) / step, dy: (y.y - originPoint.y) / step)
                    )
                }
                mapView.addSubview(view)
                fogView = view
            }
            view.reveals = reveals
            view.opacity = parent.fogOpacity
            mapView.bringSubviewToFront(view)
            view.setNeedsDisplay()
        }

        private func updateAnnotations(in mapView: MKMapView) {
            let probe = MapHomePlaybackProbe.begin("apple.annotations"); defer { MapHomePlaybackProbe.end(probe) }
            var hasher = Hasher()
            var revisions: [String: Int] = [:]
            revisions.reserveCapacity(parent.annotations.count)
            for annotation in parent.annotations {
                var item = Hasher()
                item.combine(annotation.coordinate.latitude)
                item.combine(annotation.coordinate.longitude)
                item.combine(annotation.isInteractive)
                item.combine(annotation.accessibilityLabel)
                annotation.kind.combineContent(into: &item)
                let revision = item.finalize()
                revisions[annotation.id] = revision
                hasher.combine(annotation.id)
                hasher.combine(revision)
            }
            let signature = hasher.finalize()
            guard signature != lastAnnotationsSignature else { return }
            lastAnnotationsSignature = signature
            let previousRevisions = annotationRevisions
            annotationRevisions = revisions
            fallbackAnchorCoordinate = Self.fallbackAnchor(in: parent.annotations)
            let existing = mapView.annotations.compactMap { $0 as? MapHomeAppleMapAnnotation }
            let byID = Dictionary(existing.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
            let wantedIDs = Set(parent.annotations.map(\.id))
            let removed = existing.filter { !wantedIDs.contains($0.identifier) }
            if !removed.isEmpty {
                mapView.removeAnnotations(removed)
            }
            for annotation in parent.annotations {
                if let existing = byID[annotation.id] {
                    // 바뀐 표식만 다시 구성한다. 재생 중 1분마다 발자국 전체와 집 핀 호스팅을 다시 만들지 않는다.
                    guard previousRevisions[annotation.id] != revisions[annotation.id] else { continue }
                    existing.update(from: annotation)
                    if let view = mapView.view(for: existing) as? MapHomeAppleHostedAnnotationView {
                        configure(view, annotation: existing)
                    } else if let view = mapView.view(for: existing) as? MapHomeApplePawprintAnnotationView {
                        configurePawprint(view, annotation: existing)
                    }
                } else {
                    mapView.addAnnotation(MapHomeAppleMapAnnotation(annotation: annotation))
                }
            }
        }

        private func updateWalker(in mapView: MKMapView) {
            let playback = parent.playback
            let playbackSignature: Int? = playback.map { playback in
                MapHomeContentRevision.of(
                    playback.coordinate.latitude, playback.coordinate.longitude,
                    playback.cameraCoordinate.latitude, playback.cameraCoordinate.longitude,
                    playback.headingDegrees, playback.action, playback.accessibilityLabel,
                    playback.phase == .actual, playback.followsUserLocation, playback.stickmanAnimationPhase,
                    parent.playbackTargetPoint.x, parent.playbackTargetPoint.y
                )
            }
            guard playbackSignature != lastPlaybackSignature
                    || parent.centersPlayback != lastCentersPlayback else {
                return
            }
            lastPlaybackSignature = playbackSignature
            lastCentersPlayback = parent.centersPlayback
            guard let playback else {
                parent.counterAttachment?.attach(nil)
                walkerView?.removeFromSuperview()
                walkerView = nil
                walkerAnnotation = nil
                lastCenteredPlaybackCoordinate = nil
                lastCenteredPlaybackTargetPoint = nil
                return
            }
            let walker: MapHomeAppleWalkerAnnotation
            if let walkerAnnotation {
                walker = walkerAnnotation
                // 구동기 재생 중 화랑이 좌표는 프레임마다 구동기가 정한다. 초당 4번 오는 SwiftUI 값으로 되돌리지 않는다.
                let keptCoordinate = walker.coordinate
                walker.update(with: playback)
                if parent.playbackDriver != nil { walker.coordinate = keptCoordinate }
            } else {
                walker = MapHomeAppleWalkerAnnotation(playback: playback)
                walkerAnnotation = walker
            }
            let view: MapHomeAppleHostedAnnotationView
            if let walkerView {
                view = walkerView
            } else {
                view = MapHomeAppleHostedAnnotationView(annotation: nil, reuseIdentifier: nil)
                walkerView = view
            }
            configureWalker(view, annotation: walker, cameraHeading: mapView.camera.heading)
            updateWalkerPosition(in: mapView)
            let markerOffset = MapHomeStickmanAnnotationLayout.centerOffset
            parent.counterAttachment?.attach(view, markerOffset: CGSize(width: markerOffset.x, height: markerOffset.y))
            if !parent.centersPlayback {
                lastCenteredPlaybackCoordinate = nil
                lastCenteredPlaybackTargetPoint = nil
            } else if parent.playbackDriver == nil, MapHomePlaybackCenterPolicy.shouldCenter(
                previousCoordinate: lastCenteredPlaybackCoordinate,
                previousTargetPoint: lastCenteredPlaybackTargetPoint,
                coordinate: playback.cameraCoordinate,
                targetPoint: parent.playbackTargetPoint,
                hasPendingViewportCommand: parent.viewportCommand.map {
                    $0.revision != lastViewportCommandRevision
                } ?? false
            ) {
                lastCenteredPlaybackCoordinate = playback.cameraCoordinate
                lastCenteredPlaybackTargetPoint = parent.playbackTargetPoint
                MapHomeAppleCameraCommand.center(
                    playback.cameraCoordinate,
                    at: parent.playbackTargetPoint,
                    on: mapView
                )
            }
        }

        func attachCameraGestures(in view: UIView) {
            observedCameraGestures.refresh(
                found: MapHomeMapGestures.camera(in: view), target: self, action: #selector(handleCameraGesture(_:))
            )
        }

        private func configureWalker(
            _ view: MapHomeAppleHostedAnnotationView,
            annotation: MapHomeAppleWalkerAnnotation,
            cameraHeading: CLLocationDirection
        ) {
            view.annotation = annotation
            view.update(
                rootView: AnyView(
                    MapHomeStickmanMarker(
                        action: annotation.action,
                        animationPhase: annotation.stickmanAnimationPhase,
                        routePhase: annotation.phase == .forecast
                            ? .forecast
                            : .actual,
                        speedMetersPerSecond: annotation.speedMetersPerSecond,
                        equippedAccessoryID: annotation.equippedAccessoryID,
                        facesLeft: MapHomeStickmanFacing.facesLeft(
                            headingDegrees: annotation.headingDegrees,
                            cameraHeading: cameraHeading
                        )
                    )
                ),
                size: MapHomeStickmanMarker.size,
                centerOffset: MapHomeStickmanAnnotationLayout.centerOffset
            )
            UIView.performWithoutAnimation {
                view.transform = .identity
            }
            view.displayPriority = .required
            view.collisionMode = .none
            view.zPriority = .max
            view.selectedZPriority = .max
            view.layer.zPosition = MapHomeAppleAnnotationLayerPriority.stickman
            view.superview?.bringSubviewToFront(view)
            view.isEnabled = false
            view.isUserInteractionEnabled = false
            // 카운터가 자식으로 붙으면 VoiceOver가 카운터를 읽도록 마커를 요소에서 뺀다. 화랑이는 화면의 탭 대상이 읽는다.
            view.isAccessibilityElement = parent.counterAttachment == nil
            view.accessibilityTraits = .image
            view.accessibilityLabel = annotation.label
        }

        private func configurePawprint(
            _ view: MapHomeApplePawprintAnnotationView,
            annotation: MapHomeAppleMapAnnotation
        ) {
            guard case .pawprint(let paw) = annotation.kind else { return }
            let color: Color = paw.isSelectedRoute ? .orange
                : paw.isPredicted ? MapHomePawprintSpeedColor.unconfirmedColor(forMetersPerSecond: paw.speedMetersPerSecond)
                : MapHomePawprintSpeedColor.color(forMetersPerSecond: paw.speedMetersPerSecond)
            view.annotation = annotation
            view.apply(paw, color: UIColor(color))
            view.isEnabled = annotation.isInteractive
            view.isUserInteractionEnabled = annotation.isInteractive
            view.isAccessibilityElement = annotation.isInteractive
            view.accessibilityTraits = annotation.isInteractive ? .button : .image
            view.accessibilityIdentifier = "MapHome.appleAnnotation.\(annotation.identifier)"
            view.accessibilityLabel = annotation.label
        }

        private func configure(
            _ view: MapHomeAppleHostedAnnotationView,
            annotation: MapHomeAppleMapAnnotation
        ) {
            let descriptor = descriptor(for: annotation.kind)
            view.annotation = annotation
            view.update(
                rootView: descriptor.rootView,
                size: descriptor.size,
                centerOffset: descriptor.centerOffset
            )
            view.transform = .identity
            if case .pawprint = annotation.kind {
                // 발자국은 수백 개라서 충돌 계산에 넣으면 집·회사 같은 핀이 가려진다. 충돌에서 빼고 핀 아래에 둔다.
                view.displayPriority = .defaultLow
                view.collisionMode = .none
                view.zPriority = .min
                view.selectedZPriority = .min
            } else if case .place(let place) = annotation.kind {
                view.displayPriority = MapHomePlaceDisplayPolicy.priority(for: place.destination)
                view.collisionMode = .rectangle
                view.zPriority = MapHomePlaceDisplayPolicy.zPriority(for: place.destination)
                view.selectedZPriority = view.zPriority
            } else {
                view.displayPriority = .defaultHigh
                view.collisionMode = .rectangle
                view.zPriority = .defaultUnselected
                view.selectedZPriority = .defaultUnselected
            }
            view.layer.zPosition = MapHomeAppleAnnotationLayerPriority.place
            view.isEnabled = annotation.isInteractive
            view.isUserInteractionEnabled = annotation.isInteractive
            view.isAccessibilityElement = true
            view.accessibilityTraits = annotation.isInteractive ? .button : .image
            view.accessibilityIdentifier = "MapHome.appleAnnotation.\(annotation.identifier)"
            view.accessibilityLabel = annotation.label
        }

        /// didAdd는 배치로 불리므로 새로 붙은 뷰만 정리한다(전체 순회는 발자국이 많을 때 O(N²)).
        private func normalizeAnnotationLayerOrder(of views: [MKAnnotationView], in mapView: MKMapView) {
            for view in views {
                guard let annotation = view.annotation else { continue }
                if annotation is MKUserLocation {
                    view.zPriority = .min
                    view.selectedZPriority = .min
                    view.layer.zPosition = MapHomeAppleAnnotationLayerPriority.userLocation
                } else if let hosted = annotation as? MapHomeAppleMapAnnotation {
                    let zPriority: MKAnnotationViewZPriority
                    switch hosted.kind {
                    case .pawprint: zPriority = .min
                    case .place(let place): zPriority = MapHomePlaceDisplayPolicy.zPriority(for: place.destination)
                    default: zPriority = .defaultUnselected
                    }
                    view.zPriority = zPriority
                    view.selectedZPriority = zPriority
                    view.layer.zPosition = MapHomeAppleAnnotationLayerPriority.place
                }
            }
            updateWalkerPosition(in: mapView)
        }

        private func updateWalkerPosition(in mapView: MKMapView) {
            guard let walkerAnnotation,
                  let walkerView else { return }
            MapHomeAppleWalkerOverlayLayout.update(
                walkerView,
                coordinate: walkerAnnotation.coordinate,
                on: mapView
            )
        }

        private func descriptor(
            for kind: MapHomeAppleAnnotationKind
        ) -> MapHomeAppleHostedDescriptor {
            switch kind {
            case .temporary(_, let title):
                return MapHomeAppleHostedDescriptor(
                    rootView: AnyView(
                        VStack(spacing: 2) {
                            Image(systemName: "tram.fill")
                                .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold))
                                .foregroundStyle(Color.tpReferenceBlue.opacity(0.72))
                            Text(title)
                                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(9)), weight: .semibold))
                                .foregroundStyle(Color.tpInk.opacity(0.72))
                        }
                        .padding(5)
                        .background(Color.tpSurface.opacity(0.66), in: Capsule())
                        .overlay {
                            Capsule().stroke(
                                Color.tpReferenceBlue.opacity(0.45),
                                style: StrokeStyle(lineWidth: 1, dash: [3, 2])
                            )
                        }
                    ),
                    size: CGSize(width: 92, height: 36),
                    centerOffset: CGPoint(x: 0, y: -18)
                )
            case .place(let place):
                return MapHomeAppleHostedDescriptor(
                    rootView: AnyView(
                        MapHomePlacePin(
                            name: place.name,
                            floor: place.floor,
                            destination: place.destination,
                            growthLevel: place.growthLevel,
                            isLeapDay: place.isLeapDay,
                            growthStatus: place.growthStatus,
                            isGrowthQualifiedToday: place.isGrowthQualifiedToday,
                            growthStreak: place.growthStreak,
                            pendingWeeklyRewards: place.pendingWeeklyRewards,
                            showsCatAtHome: place.isCatAtHome,
                            catAction: place.catAction,
                            equippedAccessoryID: place.equippedAccessoryID,
                            weatherBadge: place.weatherBadge,
                            homeSky: place.homeSky
                        )
                        .fixedSize()
                    ),
                    size: CGSize(
                        width: place.destination == .home
                            ? MapHomePlacePinLayout.appleHomeHostWidth
                            : 130,
                        height: place.destination == .home ? MapHomePlacePinLayout.appleHomeHostHeight : 138
                    ),
                    centerOffset: MapHomePlaceAnnotationLayout.appleCenterOffset
                )
            case .transit(let place):
                return MapHomeAppleHostedDescriptor(
                    rootView: AnyView(
                        MapHomeTransitPlacePin(name: place.name, kind: place.kind)
                            .fixedSize()
                    ),
                    size: CGSize(width: 132, height: 70),
                    centerOffset: CGPoint(x: 0, y: -35)
                )
            case .boarding(let candidate):
                return MapHomeAppleHostedDescriptor(
                    rootView: AnyView(
                        MapHomeTransitBoardingCandidatePin(
                            name: TransitPlaceName.display(candidate.name, kind: candidate.kind, point: candidate.point, language: .current),
                            kind: candidate.kind
                        )
                        .fixedSize()
                    ),
                    size: CGSize(width: 145, height: 72),
                    centerOffset: CGPoint(x: 0, y: -36)
                )
            case .sticker(let sticker):
                return MapHomeAppleHostedDescriptor(
                    rootView: AnyView(MapHomeMapStickerMarker(sticker: sticker)),
                    size: CGSize(width: 150, height: 52),
                    centerOffset: CGPoint(x: 0, y: -26)
                )
            case .memo(let memo):
                return MapHomeAppleHostedDescriptor(
                    rootView: AnyView(MapHomeMapMemoMarker(memo: memo)),
                    size: CGSize(width: 150, height: 60),
                    centerOffset: CGPoint(x: 0, y: -30)
                )
            case .pawprint(let paw):
                let color: Color = paw.isSelectedRoute ? .orange
                    : paw.isPredicted ? MapHomePawprintSpeedColor.unconfirmedColor(forMetersPerSecond: paw.speedMetersPerSecond)
                    : MapHomePawprintSpeedColor.color(forMetersPerSecond: paw.speedMetersPerSecond)
                return MapHomeAppleHostedDescriptor(
                    rootView: AnyView(
                        Image(systemName: "pawprint.fill")
                            .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .bold))
                            .foregroundStyle(color)
                            .rotationEffect(.degrees(paw.angle))
                    ),
                    size: CGSize(width: 24, height: 24),
                    centerOffset: .zero
                )
            case .search:
                return MapHomeAppleHostedDescriptor(
                    rootView: AnyView(
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: TaptionType.scaled(TaptionType.snapped(36)), weight: .bold))
                            .foregroundStyle(Color.tpPastelRose)
                            .background(Circle().fill(.white))
                    ),
                    size: CGSize(width: 48, height: 48),
                    centerOffset: CGPoint(x: 0, y: -24)
                )
            }
        }

        private func publishCameraFrame(
            from mapView: MKMapView,
            isFinal: Bool
        ) {
            if isApplyingSwiftUIUpdate {
                publishCameraFrameAfterUpdate(from: mapView, isFinal: isFinal)
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            // 표시 링크 틱의 흔들림으로 한 틱씩 건너뛰지 않게 2ms 여유를 둔다(벡터 지도와 같다).
            guard isFinal || now - lastCameraPublishUptime >= 1.0 / 60.0 - 0.002 else {
                return
            }
            lastCameraPublishUptime = now
            updateWalkerPosition(in: mapView)
            let camera = MapCamera(
                centerCoordinate: mapView.camera.centerCoordinate,
                distance: max(mapView.camera.altitude, 1),
                heading: mapView.camera.heading,
                pitch: mapView.camera.pitch
            )
            let frame = MapHomeCameraFrame(
                camera: camera,
                region: mapView.region
            )
            let locationPoint = sendLiveStickmanPoint(in: mapView)
            let probe = MapHomePlaybackProbe.begin(isFinal ? "apple.publishFinal" : "apple.publishMoving")
            defer { MapHomePlaybackProbe.end(probe) }
            parent.onCameraFrame(frame, locationPoint, isFinal)
        }

        /// 카운터가 따라갈 화면 점을 보낸다. 값이 같으면 채널이 거른다.
        @discardableResult
        private func sendLiveStickmanPoint(in mapView: MKMapView) -> CGPoint? {
            let coordinate = walkerAnnotation?.coordinate ?? fallbackAnchorCoordinate
            let point = coordinate.map { mapView.convert($0, toPointTo: mapView) }
            lastPublishedLocationPoint = point.map {
                CGPoint(x: $0.x + MapHomeStickmanAnnotationLayout.centerOffset.x, y: $0.y + MapHomeStickmanAnnotationLayout.centerOffset.y)
            }
            parent.onLiveStickmanPoint(point)
            return point
        }

        /// 화랑이가 없을 때 카운터가 붙는 자리(집, 없으면 사용자 위치).
        private static func fallbackAnchor(in annotations: [MapHomeAppleAnnotation]) -> CLLocationCoordinate2D? {
            var user: CLLocationCoordinate2D?
            for annotation in annotations {
                guard case .place(let place) = annotation.kind else { continue }
                if place.destination == .home { return annotation.coordinate }
                if place.destination == .user, user == nil { user = annotation.coordinate }
            }
            return user
        }

        private func publishCameraFrameAfterUpdate(
            from mapView: MKMapView,
            isFinal: Bool
        ) {
            cameraFramePublishIsFinal = cameraFramePublishIsFinal || isFinal
            guard !cameraFramePublishPending else { return }
            cameraFramePublishPending = true
            Task { @MainActor [weak self, weak mapView] in
                await Task.yield()
                guard let self else { return }
                self.cameraFramePublishPending = false
                let isFinal = self.cameraFramePublishIsFinal
                self.cameraFramePublishIsFinal = false
                guard let mapView else { return }
                self.publishCameraFrame(from: mapView, isFinal: isFinal)
            }
        }
    }
}

struct MapHomeAppleRouteStyle {
    let color: UIColor
    let opacity: CGFloat
    let lineWidth: CGFloat
    let dashed: Bool
}

private extension UIColor {
    convenience init(hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var integer: UInt64 = 0
        Scanner(string: value).scanHexInt64(&integer)
        let red = CGFloat((integer >> 16) & 0xFF) / 255
        let green = CGFloat((integer >> 8) & 0xFF) / 255
        let blue = CGFloat(integer & 0xFF) / 255
        self.init(red: red, green: green, blue: blue, alpha: 1)
    }
}


// MARK: - RPG marker info
