import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

struct MapHomeTimelineRouteOverlay: Identifiable {
    let id: String
    let categoryID: String
    let opacity: Double
    let speedMetersPerSecond: Double?
    let coordinates: [CLLocationCoordinate2D]
    let geometrySignature: Int
    let coordinateTimestamps: [Date]

    init(
        id: String,
        categoryID: String,
        opacity: Double,
        speedMetersPerSecond: Double?,
        coordinates: [CLLocationCoordinate2D],
        coordinateTimestamps: [Date]
    ) {
        self.id = id
        self.categoryID = categoryID
        self.opacity = opacity
        self.speedMetersPerSecond = speedMetersPerSecond
        self.coordinates = coordinates
        self.coordinateTimestamps = coordinateTimestamps
        geometrySignature = MapHomeRouteGeometrySignature.value(for: coordinates)
    }
}

struct MapHomeTemporaryLocationAnnotation: Identifiable {
    let id: UUID
    let stationName: String
    let timestamp: Date
    let point: GeoPoint
    let reason: String

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
    }
}

/// 지도 위 표시 입력. `mapOverlayInputs()`가 화면 갱신마다 한 번 만든다.
struct MapHomeOverlayInputs {
    var places: [MapHomePlaceAnnotation]
    var temporaryLocations: [MapHomeTemporaryLocationAnnotation]
    var transit: [MapHomeTransitAnnotation]
    var boarding: [TransitBoardingCandidate]
    var stickers: [MapSticker]
    var photos: [MapHomePhotoCluster]
    var memos: [ActionMemo]
}

struct MapHomePlaceAnnotation: Identifiable {
    let id: UUID
    let name: String
    let floor: Int?
    let destination: MapHomeLocationDestination
    let growthLevel: Int?
    let isLeapDay: Bool
    let growthStatus: String?
    let isGrowthQualifiedToday: Bool
    let growthStreak: Int
    let pendingWeeklyRewards: Int
    let isCatAtHome: Bool
    let catAction: MapHomeStickmanAction
    let equippedAccessoryID: String?
    let coordinate: CLLocationCoordinate2D
    /// 집 핀 위에 올리는 현재 날씨(집에만, 데이터가 없으면 nil).
    var weatherBadge: MapHomeHomeWeatherBadge? = nil
}

struct MapHomeTransitAnnotation: Identifiable {
    let id: UUID
    let name: String
    let kind: UserTransitLocationKind
    let coordinate: CLLocationCoordinate2D
}

struct MapHomePlacePin: View {
    let name: String
    let floor: Int?
    let destination: MapHomeLocationDestination
    var growthLevel: Int? = nil
    var isLeapDay = false
    var growthStatus: String? = nil
    var isGrowthQualifiedToday = false
    var growthStreak = 0
    var pendingWeeklyRewards = 0
    var showsCatAtHome = false
    var catAction: MapHomeStickmanAction = .activity
    var equippedAccessoryID: String? = nil
    var weatherBadge: MapHomeHomeWeatherBadge? = nil
    var onOpenDaySummary: (() -> Void)? = nil

    var body: some View {
        if destination == .home, let growthLevel {
            homeMarker(level: growthLevel)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("집 레벨 \(growthLevel), \(growthStatus ?? "하루 요약 보기")")
        } else {
            VStack(spacing: 5) {
                MapHomeMarkerLabel(title: name, color: destination.tint)
                Image(destination.iconAssetName)
                    .resizable()
                    .scaledToFit()
                    .padding(6)
                    .frame(width: 48, height: 48)
                    .background(
                        Color.tpSurface.opacity(0.98),
                        in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .stroke(Color.tpLine.opacity(0.95), lineWidth: 1)
                    }
                    .shadow(color: Color.tpInk.opacity(0.2), radius: 4, y: 2)
                Text("Lv.\(floor ?? 1)")
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .bold, design: .rounded))
                    .foregroundStyle(Color.tpInk)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.tpSurface.opacity(0.98), in: Capsule())
                    .overlay { Capsule().stroke(Color.tpLine, lineWidth: 0.8) }
                    .shadow(color: Color.tpInk.opacity(0.12), radius: 4, y: 2)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(name), 레벨 \(floor ?? 1)")
        }
    }

    /// 집 마커: 원형 발광 위에 원형 아바타를 얹고, 위에 날씨 배지, 아래에 Lv 필을 둔다.
    /// 보이지 않는 빈 자리를 두지 않고, 아바타 원의 중심이 좌표에 오도록 라벨 높이의 절반만큼 내린다.
    private func homeMarker(level: Int) -> some View {
        VStack(spacing: MapHomePlacePinLayout.levelLabelGap) {
            homeAvatar(level: level)
            homeLevelLabel(level: level)
        }
        .offset(y: MapHomePlacePinLayout.avatarCenterCompensation)
    }

    /// 원형 아바타. 뒤로 부드러운 발광이 번지고, 안쪽에 레벨 아트(집 또는 화랑이)를 넣는다.
    private func homeAvatar(level: Int) -> some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(hex: "#FFFFFF").opacity(0.95),
                            Color(hex: "#FBF1DA").opacity(0.55),
                            Color(hex: "#FBF1DA").opacity(0),
                        ],
                        center: .center,
                        startRadius: 8,
                        endRadius: MapHomePlacePinLayout.glowSize / 2
                    )
                )
                .frame(
                    width: MapHomePlacePinLayout.glowSize,
                    height: MapHomePlacePinLayout.glowSize
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            ZStack {
                Circle().fill(Color(hex: "#FDF8EC"))
                if showsCatAtHome {
                    homeCatArtwork(level: level)
                } else {
                    homeMarkerArtwork(level: level)
                }
                if let weatherBadge {
                    VStack {
                        homeTemperature(weatherBadge)
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(
                width: MapHomePlacePinLayout.avatarSize,
                height: MapHomePlacePinLayout.avatarSize
            )
            .clipShape(Circle())
            .overlay { Circle().stroke(Color.white.opacity(0.92), lineWidth: 2) }
            .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
            .overlay(alignment: .topTrailing) {
                if isLeapDay {
                    Image(systemName: "star.fill")
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .black))
                        .foregroundStyle(Color(hex: "#E3B54A"))
                        .shadow(color: .white, radius: 1.5)
                        .offset(x: 1, y: 1)
                        .allowsHitTesting(false)
                }
            }
        }
        // 발광이 레이아웃을 키우지 않게 아바타 크기로 묶는다(그림은 밖으로 번진다).
        .frame(
            width: MapHomePlacePinLayout.avatarSize,
            height: MapHomePlacePinLayout.avatarSize
        )
        .contentShape(Circle())
        .onTapGesture { onOpenDaySummary?() }
        .accessibilityElement()
        .accessibilityLabel("집 성장과 오늘 하루 요약 보기")
        .accessibilityHint("집 그림을 눌러 성장 카드와 오늘 하루 요약을 엽니다")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpenDaySummary?() }
    }

    /// 집 아이콘 아래에 늘 보이는 레벨 라벨. 누르면 성장 카드와 오늘 하루 요약을 연다.
    /// 여는 동작이 없는 곳(Apple 지도의 주석 뷰)에서는 버튼으로 감싸지 않아 지도의 주석 선택이 그대로 일어난다.
    @ViewBuilder
    private func homeLevelLabel(level: Int) -> some View {
        let label = Text("Lv.\(level)")
            .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Color.tpInk)
            .padding(.horizontal, 12)
            .frame(height: MapHomePlacePinLayout.levelLabelHeight)
            .background(Color.tpSurface.opacity(0.98), in: Capsule())
            .overlay { Capsule().stroke(Color.tpLine, lineWidth: 0.8) }
            .shadow(color: Color.tpInk.opacity(0.12), radius: 4, y: 2)
            .contentShape(Capsule())
        if let onOpenDaySummary {
            Button(action: onOpenDaySummary) { label }
                .buttonStyle(.plain)
                .accessibilityLabel("집 레벨 \(level) · 성장 카드와 오늘 하루 요약 열기")
                .accessibilityHint("하단에서 성장 카드와 오늘 하루 요약을 엽니다")
        } else {
            label
        }
    }

    /// 원 위쪽 가운데의 현재 기온. 날씨는 원 안 그림으로 보여 준다.
    private func homeTemperature(_ badge: MapHomeHomeWeatherBadge) -> some View {
        Text(badge.temperatureText)
            .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Color(hex: "#3E2C22"))
            .shadow(color: .white, radius: 1.2)
            .shadow(color: .white, radius: 1.2)
            .padding(.top, MapHomePlacePinLayout.temperatureTopInset)
            .allowsHitTesting(false)
            .accessibilityLabel(
                AppLanguagePreference.text(
                    korean: "현재 날씨 \(badge.condition), \(badge.temperatureText)",
                    english: "Current weather \(badge.condition), \(badge.temperatureText)"
                )
            )
    }

    @ViewBuilder
    private var homeWeatherArt: some View {
        if let weatherBadge {
            MapHomeHomeWeatherArt(
                kind: MapHomeHomeWeatherKind(symbolName: weatherBadge.symbolName),
                windSpeed: weatherBadge.windSpeedMetersPerSecond ?? 0
            )
        }
    }

    private func homeMarkerArtwork(level: Int) -> some View {
        ZStack {
            Image(MapHomeGrowthPolicy.artworkName(level: level))
                .resizable()
                .scaledToFit()
                .frame(
                    width: MapHomePlacePinLayout.artworkSize,
                    height: MapHomePlacePinLayout.artworkSize
                )
            homeWeatherArt
        }
    }

    /// 집에 있는 화랑이. 아바타 원 안에 레벨 아트와 함께 그린다.
    private func homeCatArtwork(level: Int) -> some View {
        let scale = MapHomeCatTapRouting.homeArtScale
        return ZStack {
            Image(MapHomeGrowthPolicy.artworkName(level: level))
                .resizable()
                .scaledToFit()
                .frame(
                    width: MapHomePlacePinLayout.artworkSize,
                    height: MapHomePlacePinLayout.artworkSize
                )
            homeWeatherArt
            MapHomeStickmanGlyph(
                action: catAction,
                size: MapHomeStickmanMarker.size.width,
                equippedAccessoryID: equippedAccessoryID
            )
                .offset(
                    x: MapHomeCatTapRouting.catOffsetInHomeImage.x * scale,
                    y: MapHomeCatTapRouting.catOffsetInHomeImage.y * scale
                )
        }
    }
}

struct MapHomeTransitPlacePin: View {
    let name: String
    let kind: UserTransitLocationKind

    var body: some View {
        VStack(spacing: 4) {
            MapHomeMarkerLabel(title: name, color: Color.tpTransitDark)
            Image(systemName: kind.systemImage)
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.tpTransitDark, in: Circle())
                .overlay { Circle().stroke(.white, lineWidth: 1) }
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
        }
        .accessibilityLabel("\(name), \(kind.title)")
    }
}

struct MapHomeTransitBoardingCandidatePin: View {
    let name: String
    let kind: UserTransitLocationKind

    var body: some View {
        VStack(spacing: 4) {
            MapHomeMarkerLabel(title: name, color: Color.tpTransitDark)
            Image(systemName: kind.systemImage)
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.tpTransitDark, in: Circle())
                .overlay { Circle().stroke(.white, lineWidth: 1.5) }
                .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
        }
        .accessibilityLabel("\(name), \(kind.title) 탑승 확인")
    }
}

struct MapHomeVectorViewportOverlay<Content: View>: View {
    let store: MapHomeVectorViewportStore
    var isLive = false
    let content: (MapHomeVectorViewport?, CGPoint?) -> Content

    var body: some View {
        if isLive {
            // 구동기 재생 중에는 화면 틱(최대 60Hz)마다 지도 엔진이 투영한 뷰포트로 그려, 아이콘이 지도에 붙어 움직인다.
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { _ in
                content(store.livePlaybackViewport ?? store.viewport, store.livePoint ?? store.stickmanPoint)
                    .clipped()
            }
        } else {
            content(store.viewport, store.stickmanPoint)
                .clipped()
        }
    }
}

struct MapHomeProjectedAnnotation<Content: View>: View {
    let point: CGPoint
    let anchor: UnitPoint
    let content: Content

    init(
        point: CGPoint,
        anchor: UnitPoint,
        @ViewBuilder content: () -> Content
    ) {
        self.point = point
        self.anchor = anchor
        self.content = content()
    }

    var body: some View {
        let xOffset = (0.5 - anchor.x)
        let yOffset = (0.5 - anchor.y)
        content
            .visualEffect { content, geometry in
                content.offset(
                    x: xOffset * geometry.size.width,
                    y: yOffset * geometry.size.height
                )
            }
            .position(
                x: point.x,
                y: point.y
            )
    }
}

struct MapHomeVectorPlayerMarker: View {
    let heading: CLLocationDirection
    let backgroundHex: String

    var body: some View {
        MapHomeVectorPlayerTriangle()
            .fill(Color(hex: MapHomeVectorStyle.routeHex))
            .frame(width: 13, height: 17)
            .overlay {
                MapHomeVectorPlayerTriangle()
                    .stroke(Color(hex: backgroundHex), lineWidth: 1.5)
            }
            .shadow(color: .black.opacity(0.32), radius: 2, y: 1)
            .rotationEffect(.degrees(heading))
    }
}

struct MapHomeVectorPlayerTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY * 0.78))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct MapHomeLocationButtonIcon: View {
    let state: MapHomeLocationButtonState
    let showsGPSDot: Bool

    private let dotColor = Color(hex: "#E5352B")

    private var targetColor: Color {
        switch state {
        case .unavailable: Color.tpPastelGray
        case .locating: Color.tpPastelSky.opacity(0.55)
        case .available: Color.tpPastelSky
        case .following: Color.tpReferenceBlue
        }
    }

    var body: some View {
        ZStack {
            Image(systemName: "scope")
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(22)), weight: .semibold))
                .foregroundStyle(targetColor)

            if state.showsTrackingDot {
                Circle()
                    .stroke(Color.tpReferenceBlue.opacity(0.5), lineWidth: 2)
                    .frame(width: 30, height: 30)
            }

            if showsGPSDot {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                    .overlay {
                        Circle()
                            .stroke(.white, lineWidth: 1.2)
                    }
            }
        }
        .accessibilityHidden(true)
    }
}

struct MapHomeHistoricalLocationMarker: View {
    var body: some View {
        Canvas { context, size in
            let scaleX = size.width / 22
            let scaleY = size.height / 22
            let point: (CGFloat, CGFloat) -> CGPoint = {
                CGPoint(x: $0 * scaleX, y: $1 * scaleY)
            }
            let lineWidth = min(scaleX, scaleY) * 2.4
            let color = Color.tpPastelRose

            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x: point(7.8, 1.2).x,
                        y: point(7.8, 1.2).y,
                        width: 6.4 * scaleX,
                        height: 6.4 * scaleY
                    )
                ),
                with: .color(color)
            )

            var body = Path()
            body.move(to: point(11, 8.2))
            body.addLine(to: point(11, 14.2))
            body.move(to: point(5.2, 10.7))
            body.addLine(to: point(11, 9.5))
            body.addLine(to: point(16.8, 10.7))
            body.move(to: point(11, 14.2))
            body.addLine(to: point(6.4, 20.2))
            body.move(to: point(11, 14.2))
            body.addLine(to: point(15.6, 20.2))
            context.stroke(
                body,
                with: .color(color),
                style: StrokeStyle(
                    lineWidth: lineWidth,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
        }
        .frame(width: 22, height: 22)
        .padding(4)
        .background(.white, in: Circle())
        .overlay {
            Circle().stroke(Color.tpPastelRose.opacity(0.35), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.18), radius: 3, y: 2)
        .accessibilityHidden(true)
    }
}

private struct MapHomePanGestureObserver: UIViewRepresentable {
    let onSingleFingerPanBegan: () -> Void
    let onSingleFingerPanEnded: () -> Void
    let onLongPress: (CLLocationCoordinate2D) -> Void

    func makeUIView(context: Context) -> ObservationView {
        let view = ObservationView()
        view.onSingleFingerPanBegan = onSingleFingerPanBegan
        view.onSingleFingerPanEnded = onSingleFingerPanEnded
        view.onLongPress = onLongPress
        return view
    }

    func updateUIView(_ view: ObservationView, context: Context) {
        view.onSingleFingerPanBegan = onSingleFingerPanBegan
        view.onSingleFingerPanEnded = onSingleFingerPanEnded
        view.onLongPress = onLongPress
    }

    static func dismantleUIView(_ view: ObservationView, coordinator: ()) {
        view.detach()
    }

    final class ObservationView: UIView {
        var onSingleFingerPanBegan: (() -> Void)?
        var onSingleFingerPanEnded: (() -> Void)?
        var onLongPress: ((CLLocationCoordinate2D) -> Void)?
        private weak var attachedMapView: MKMapView?
        private var observedPanGestures: [UIPanGestureRecognizer] = []
        private var longPressGesture: UILongPressGestureRecognizer?
        private var notifiedPanGestureIDs = Set<ObjectIdentifier>()
        private var attachmentRetryWorkItem: DispatchWorkItem?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            scheduleAttachmentRetries()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            attachToVisibleMapIfNeeded()
        }

        func attachToVisibleMapIfNeeded() {
            guard let window else {
                detach()
                return
            }
            if let attachedMapView,
               attachedMapView.window === window,
               !observedPanGestures.isEmpty,
               longPressGesture?.view === attachedMapView {
                return
            }
            let ownFrame = convert(bounds, to: window)
            let mapView = mapViews(in: window).max { lhs, rhs in
                overlapArea(lhs, with: ownFrame, in: window)
                    < overlapArea(rhs, with: ownFrame, in: window)
            }
            guard let mapView else { return }
            let panGestures = panGestures(in: mapView)
            guard !panGestures.isEmpty else { return }

            let currentIDs = Set(observedPanGestures.map(ObjectIdentifier.init))
            let nextIDs = Set(panGestures.map(ObjectIdentifier.init))
            guard currentIDs != nextIDs else { return }

            detachObservedPanGestures()
            attachedMapView = mapView
            observedPanGestures = panGestures
            for panGesture in panGestures {
                panGesture.addTarget(self, action: #selector(handlePan(_:)))
            }
            let longPress = UILongPressGestureRecognizer(
                target: self,
                action: #selector(handleLongPress(_:))
            )
            longPress.minimumPressDuration = 0.55
            longPress.allowableMovement = 12
            longPress.numberOfTouchesRequired = 1
            longPress.cancelsTouchesInView = false
            longPress.delegate = self
            mapView.addGestureRecognizer(longPress)
            longPressGesture = longPress
            attachmentRetryWorkItem?.cancel()
            attachmentRetryWorkItem = nil
        }

        func detach() {
            attachmentRetryWorkItem?.cancel()
            attachmentRetryWorkItem = nil
            detachObservedPanGestures()
        }

        private func detachObservedPanGestures() {
            for panGesture in observedPanGestures {
                panGesture.removeTarget(
                    self,
                    action: #selector(handlePan(_:))
                )
            }
            if let longPressGesture {
                longPressGesture.view?.removeGestureRecognizer(longPressGesture)
            }
            longPressGesture = nil
            observedPanGestures = []
            attachedMapView = nil
            notifiedPanGestureIDs.removeAll()
        }

        private func scheduleAttachmentRetries() {
            attachmentRetryWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.attachToVisibleMapIfNeeded()
            }
            attachmentRetryWorkItem = workItem
            for delay in [0.0, 0.05, 0.2, 0.5, 1.0] {
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + delay,
                    execute: workItem
                )
            }
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            let gestureID = ObjectIdentifier(gesture)
            if MapHomeUserTrackingPolicy.isSingleFingerPanStart(
                state: gesture.state,
                numberOfTouches: gesture.numberOfTouches
            ) {
                guard notifiedPanGestureIDs.insert(gestureID).inserted else {
                    return
                }
                onSingleFingerPanBegan?()
            } else if gesture.state == .ended
                        || gesture.state == .cancelled
                        || gesture.state == .failed {
                notifiedPanGestureIDs.remove(gestureID)
                onSingleFingerPanEnded?()
            }
        }

        @objc private func handleLongPress(
            _ gesture: UILongPressGestureRecognizer
        ) {
            guard gesture.state == .began,
                  let mapView = attachedMapView else { return }
            onLongPress?(
                mapView.convert(
                    gesture.location(in: mapView),
                    toCoordinateFrom: mapView
                )
            )
        }

        private func mapViews(in view: UIView) -> [MKMapView] {
            var result: [MKMapView] = []
            if let mapView = view as? MKMapView {
                result.append(mapView)
            }
            for child in view.subviews {
                result.append(contentsOf: mapViews(in: child))
            }
            return result
        }

        private func panGestures(in view: UIView) -> [UIPanGestureRecognizer] {
            var result = view.gestureRecognizers?.compactMap {
                $0 as? UIPanGestureRecognizer
            } ?? []
            for child in view.subviews {
                result.append(contentsOf: panGestures(in: child))
            }
            var seen = Set<ObjectIdentifier>()
            return result.filter { seen.insert(ObjectIdentifier($0)).inserted }
        }

        private func overlapArea(
            _ view: UIView,
            with frame: CGRect,
            in window: UIWindow
        ) -> CGFloat {
            let intersection = view.convert(view.bounds, to: window)
                .intersection(frame)
            guard !intersection.isNull else { return 0 }
            return intersection.width * intersection.height
        }
    }
}

extension MapHomePanGestureObserver.ObservationView: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

struct MapHomeMarkerLabel: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold, design: .rounded))
            .foregroundStyle(Color.tpInk)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(Color.tpSurface.opacity(0.98), in: Capsule())
            .overlay {
                Capsule().stroke(color.opacity(0.42), lineWidth: 1)
            }
            .shadow(color: Color.tpInk.opacity(0.13), radius: 5, y: 2)
    }
}

struct MapHomeScrollBounceDisabler: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        UIView(frame: .zero)
    }

    func updateUIView(_ view: UIView, context: Context) {
        DispatchQueue.main.async {
            var ancestor = view.superview
            while let current = ancestor {
                if let scrollView = current as? UIScrollView {
                    scrollView.bounces = false
                    scrollView.alwaysBounceVertical = false
                    return
                }
                ancestor = current.superview
            }
        }
    }
}

/// 날짜 배지 글자와 요일. 본문이 다시 계산될 때마다 ICU 달력을 돌리지 않게 같은 날짜면 재사용한다(SHT1102A01).
struct MapHomeDateBadgeInfo: Equatable {
    let date: Date
    let localeIdentifier: String
    let weekdayText: String
    let weekday: Int
    let day: Int
    let isHoliday: Bool

    @MainActor private static var last: MapHomeDateBadgeInfo?

    init(date: Date, localeIdentifier: String) {
        let calendar = TimelineAxisGrid.normalizedCalendar()
        self.date = date
        self.localeIdentifier = localeIdentifier
        weekdayText = date.formatted(
            Date.FormatStyle().weekday(.abbreviated).locale(Locale(identifier: localeIdentifier))
        )
        weekday = calendar.component(.weekday, from: date)
        day = calendar.component(.day, from: date)
        isHoliday = MapHomeCalendarDayStyle(date: date, calendar: calendar) == .holiday
    }

    @MainActor
    static func resolve(date: Date, localeIdentifier: String) -> MapHomeDateBadgeInfo {
        if let last, last.date == date, last.localeIdentifier == localeIdentifier { return last }
        let info = MapHomeDateBadgeInfo(date: date, localeIdentifier: localeIdentifier)
        last = info
        return info
    }
}

enum MapHomeCalendarDayStyle: Equatable {
    case weekday
    case saturday
    case holiday

    init(date: Date, calendar: Calendar = .autoupdatingCurrent) {
        let calendar = TimelineAxisGrid.normalizedCalendar(calendar)
        let weekday = calendar.component(.weekday, from: date)
        if weekday == 1 {
            self = .holiday
        } else if weekday == 7 {
            self = .saturday
        } else if TimelineAxisGrid.koreanHolidayName(on: date, calendar: calendar) != nil {
            self = .holiday
        } else {
            self = .weekday
        }
    }
}

struct MapHomeCalendarGlyph: View {
    let date: Date
    let language: MapHomeLanguage

    private var calendar: Calendar {
        TimelineAxisGrid.normalizedCalendar()
    }

    private var day: String {
        String(calendar.component(.day, from: date))
    }

    private var style: MapHomeCalendarDayStyle {
        MapHomeCalendarDayStyle(date: date, calendar: calendar)
    }

    private var weekday: Int {
        calendar.component(.weekday, from: date)
    }

    private var assetName: String {
        if style == .holiday {
            return "MapHomeCalendarSunday"
        }
        switch weekday {
        case 1: return "MapHomeCalendarSunday"
        case 2: return "MapHomeCalendarMonday"
        case 3: return "MapHomeCalendarTuesday"
        case 4: return "MapHomeCalendarWednesday"
        case 5: return "MapHomeCalendarThursday"
        case 6: return "MapHomeCalendarFriday"
        default: return "MapHomeCalendarSaturday"
        }
    }

    var body: some View {
        Image(assetName)
            .resizable()
            .scaledToFit()
            .frame(width: 24, height: 25)
        .accessibilityLabel(
            language.text("\(day)일 달력", "Calendar, day \(day)")
        )
    }
}

struct MapHomeSearchResult: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let coordinate: CLLocationCoordinate2D
}
