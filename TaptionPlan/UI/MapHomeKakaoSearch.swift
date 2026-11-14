import CoreLocation
import Foundation
import KakaoMapsSDK
import MapKit
import SwiftUI

/// 국내 장소 키워드 검색(KKO1110A01). 카카오 REST 키는 서버용이라 앱에 넣지 않고, 여행 계획 중계 서버
/// (`server/trip-relay`의 `/kakao/keyword`)가 키를 붙여 대신 부른다(REV1110A03). 중계가 없거나 실패하면 빈 결과라 Apple 검색만 남는다.
/// 좌표는 실시간 표시에만 쓴다. 저장할 때는 `MapHomeSearchRunner.appleCoordinate`로 다시 받는다.
enum MapHomeKakaoSearch {
    private struct Response: Decodable {
        struct Place: Decodable {
            let place_name: String
            let road_address_name: String?
            let address_name: String?
            let x: String
            let y: String
            var category_group_code: String?
            var category_name: String?
        }

        let documents: [Place]
    }

    private static let nearbyLimit = 5
    private static let nearbyRadiusMeters = 20_000

    static var endpoint: URL? { TripRelay.host.flatMap { URL(string: "https://\($0)/kakao/keyword") } }

    static func isAvailable(at center: CLLocationCoordinate2D) -> Bool {
        endpoint != nil && isInKorea(center)
    }

    /// 입력 중 추천. 호출을 아끼려고 정확도 순 한 번만 부른다.
    static func suggestions(query: String, center: CLLocationCoordinate2D) async -> [MapHomeSearchResult] {
        guard isAvailable(at: center) else { return [] }
        return Array(await fetch(query: query, center: center, nearby: false).prefix(8))
    }

    /// 남한 본토 대략 윤곽(위도, 경도 차례). 사각형으로 보면 후쿠오카·대마도·북한까지 국내로 쳐서
    /// 해외에서 카카오가 먼 한국 결과를 돌려주고 Apple 검색으로 넘어가지 않았다(REV1110A02).
    private static let mainland: [Double] = [
        37.80, 126.15, 37.80, 126.62, 37.95, 126.68, 38.10, 127.00, 38.25, 127.30, 38.30, 127.60,
        38.32, 128.00, 38.62, 128.33, 38.62, 128.42, 38.20, 128.68, 37.75, 129.10, 37.20, 129.45,
        36.60, 129.55, 36.00, 129.70, 35.60, 129.58, 35.30, 129.38, 35.05, 129.18, 34.70, 128.80,
        34.50, 128.30, 34.00, 127.40, 33.95, 126.40, 34.00, 124.95, 34.70, 125.20, 35.50, 125.90,
        36.30, 125.90, 37.00, 125.90, 37.60, 125.95,
    ]

    /// 본토 밖 섬: 제주, 울릉·독도, 백령·대청, 연평.
    private static let islands: [(latitude: ClosedRange<Double>, longitude: ClosedRange<Double>)] = [
        (33.10...33.60, 126.10...127.00),
        (37.20...37.60, 130.70...131.95),
        (37.75...38.00, 124.55...124.85),
        (37.60...37.72, 125.55...125.80),
    ]

    static func isInKorea(_ coordinate: CLLocationCoordinate2D) -> Bool {
        islands.contains { $0.latitude.contains(coordinate.latitude) && $0.longitude.contains(coordinate.longitude) }
            || MapHomeLandmarkSite.isInside(coordinate.latitude, coordinate.longitude, ring: mainland)
    }

    static func decode(_ data: Data) -> [MapHomeSearchResult] {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        return response.documents.compactMap { place in
            guard let longitude = Double(place.x), let latitude = Double(place.y) else { return nil }
            let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
            let address = [place.road_address_name, place.address_name].compactMap { $0 }.first { !$0.isEmpty }
            return MapHomeSearchResult(title: place.place_name, subtitle: address ?? "", coordinate: coordinate, isLiveOnly: true)
        }
    }

    /// 가까운 곳을 먼저 두고 정확도 순 결과를 잇는다. 이름만 맞는 먼 곳과 가까운 체인점을 함께 찾는다.
    static func search(query: String, center: CLLocationCoordinate2D) async -> [MapHomeSearchResult] {
        guard isAvailable(at: center) else { return [] }
        async let nearby = fetch(query: query, center: center, nearby: true)
        async let accurate = fetch(query: query, center: center, nearby: false)
        return await Array(nearby.prefix(nearbyLimit)) + accurate
    }

    private static func fetch(query: String, center: CLLocationCoordinate2D, nearby: Bool) async -> [MapHomeSearchResult] {
        // 설치마다 만든 검색 전용 키를 붙인다. 등록하지 못하면 Apple 검색만 쓴다(SEC1110A02).
        guard let token = await AssistantRegistration.searchToken(),
              let request = request(query: query, center: center, nearby: nearby, token: token),
              let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return [] }
        if status == 401 { await AssistantRegistration.searchTokenRejected() }
        return status == 200 ? decode(data) : []
    }

    /// 머문 곳 이름 후보(TAU1110A01). 식당·카페 가운데 반경 안 가장 가까운 곳. 국내가 아니거나 못 찾으면 nil이라 Apple 지도로 넘어간다.
    /// 머문 곳 이름을 찾을 카카오 분류(KKP1113A01: 식당·카페만 보던 것을 넓힘). 주차장·주유소·지하철역·중개업소·편의점은 뺀다.
    /// 음식점·카페·병원·약국·대형마트·문화시설·관광명소·학교·학원·은행·공공기관·숙박.
    static let stayCategories = ["FD6", "CE7", "HP8", "PM9", "MT1", "CT1", "AT4", "SC4", "AC5", "BK9", "PO3", "AD5"]

    static func nearestStayName(at center: CLLocationCoordinate2D, radiusMeters: Int = 50) async -> String? {
        await stayCandidates(at: center, radiusMeters: radiusMeters)?.first?.name
    }

    /// 그 자리 반경 안의 가게들(가까운 순, 최대 8곳). 머문 곳 이름 고르기와 후보 목록에 쓴다(SPC1114A01). 못 부르면 nil.
    static func stayCandidates(at center: CLLocationCoordinate2D, radiusMeters: Int = 50) async -> [StayPlaceCandidate]? {
        guard isAvailable(at: center), let token = await AssistantRegistration.searchToken() else { return nil }
        let origin = CLLocation(latitude: center.latitude, longitude: center.longitude)
        var found: [StayPlaceCandidate] = []
        var answered = false
        for code in stayCategories {
            guard let request = categoryRequest(code: code, center: center, radiusMeters: radiusMeters, token: token),
                  let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let decoded = try? JSONDecoder().decode(Response.self, from: data) else { continue }
            answered = true
            for place in decoded.documents {
                guard let x = Double(place.x), let y = Double(place.y) else { continue }
                let meters = origin.distance(from: CLLocation(latitude: y, longitude: x))
                guard meters <= Double(radiusMeters), !found.contains(where: { $0.name == place.place_name }) else { continue }
                found.append(StayPlaceCandidate(name: place.place_name, code: place.category_group_code ?? code, category: place.category_name ?? "", meters: meters))
            }
        }
        return answered ? Array(found.sorted { $0.meters < $1.meters }.prefix(8)) : nil
    }

    static func categoryRequest(code: String, center: CLLocationCoordinate2D, radiusMeters: Int, token: String) -> URLRequest? {
        guard let host = TripRelay.host, var components = URLComponents(string: "https://\(host)/kakao/category") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "category_group_code", value: code),
            URLQueryItem(name: "x", value: String(center.longitude)),
            URLQueryItem(name: "y", value: String(center.latitude)),
            URLQueryItem(name: "radius", value: String(radiusMeters)),
            URLQueryItem(name: "sort", value: "distance"),
            URLQueryItem(name: "size", value: "3"),
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func request(query: String, center: CLLocationCoordinate2D, nearby: Bool, token: String, endpoint: URL? = endpoint) -> URLRequest? {
        guard let endpoint else { return nil }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "x", value: String(center.longitude)),
            URLQueryItem(name: "y", value: String(center.latitude)),
            URLQueryItem(name: "size", value: "15"),
            URLQueryItem(name: "sort", value: nearby ? "distance" : "accuracy"),
        ] + (nearby ? [URLQueryItem(name: "radius", value: String(nearbyRadiusMeters))] : [])
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
}

extension MapHomeSearchRunner {
    /// 이 안에 있는 Apple 결과만 같은 장소로 본다.
    static let samePlaceMeters: CLLocationDistance = 300

    /// 저장용 좌표. 같은 이름의 Apple 결과가 가까이 있을 때만 돌려준다.
    static func appleCoordinate(for result: MapHomeSearchResult) async -> CLLocationCoordinate2D? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = result.title
        request.region = MKCoordinateRegion(center: result.coordinate, latitudinalMeters: 2_000, longitudinalMeters: 2_000)
        guard let items = try? await MKLocalSearch(request: request).start().mapItems else { return nil }
        let origin = CLLocation(latitude: result.coordinate.latitude, longitude: result.coordinate.longitude)
        return items.map(\.placemark.coordinate).first {
            origin.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) <= samePlaceMeters
        }
    }
}

// MARK: - 카카오 지도(KMP1113A01)


/// 카카오 지도 키(네이티브 앱 키, 로컬 설정 파일 → Info.plist). 비어 있으면 카카오 지도를 쓰지 않는다.
@MainActor
enum KakaoMapAvailability {
    static var appKey: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "KAKAO_NATIVE_APP_KEY") as? String,
              !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }

    static var isAvailable: Bool { appKey != nil }
    private static var isInitialized = false

    static func initializeIfNeeded() {
        guard !isInitialized, let appKey else { return }
        SDKInitializer.InitSDK(appKey: appKey)
        isInitialized = true
    }
}

extension MapHomeView {
    /// 2단계(KMP1114A02, 대표 신고: 화랑이도 없고 검은 표시만): 그날 경로선 전체·10분 넘게 머문 곳·보고 있는 시각의 화랑이.
    /// 재생하면 화랑이가 그 시각 자리로 움직이고 지도가 따라간다.
    /// 3단계(KMP1114A03, 대표 신고: 캐릭터 그림이 다르고 집·말풍선이 없음): 화랑이는 다른 지도와 같은 그림(꾸미기·노선 이름표 포함)에
    /// 말풍선을 붙이고, 집은 다른 지도의 집 그림과 「○일째」를 놓는다. 모두 한 장 그림이라 움직이지는 않는다. 발자국·날씨·사진은 아직 없다.
    var kakaoMap: some View {
        let routes = recordingShows(\.routes)
            ? (vectorHistoricalRoutes + (vectorActiveRoute.map { [$0] } ?? [])).map { $0.coordinates }.filter { $0.count >= 2 }
            : []
        let stays = (currentDayDataSnapshot?.places ?? [])
            .filter { $0.span.duration >= StayPlaceNaming.minimumMinutes * 60 }
            .compactMap { $0.point.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) } }
        return MapHomeKakaoMap(
            routes: routes,
            routeColor: UIColor(Color(hex: actualRouteHex)),
            stays: stays,
            cat: displayedLocationCoordinate,
            action: displayedStickmanAction,
            follows: isDayPlaybackRunning || userTrackingMode.keepsCameraLocked,
            accessoryID: homeGrowthHistory.season.equippedAccessory,
            rideLabel: [.bus, .subway].contains(displayedStickmanAction)
                ? MapHomeRideLabel.text(at: displayedLocationDate, travel: currentDayDataSnapshot?.travel ?? []) : nil,
            bubble: recordingShows(\.cat) ? MapHomeCatSpeechBubble.displayText(action: displayedStickmanAction, fallback: displayedStickmanAction.title).text : nil,
            home: homeCoordinate,
            homeKey: "\(MapHomeGrowthPolicy.dailyLevel(for: model.selectedDate))|\(language.rawValue)",
            homeLabel: MapHomeGrowthPolicy.dayLabel(level: MapHomeGrowthPolicy.dailyLevel(for: model.selectedDate), language: language),
            homeArtwork: AnyView(daySummaryHomeArtwork)
        )
        .ignoresSafeArea()
        .accessibilityLabel(language.text("카카오 지도", "Kakao map"))
    }
}

struct MapHomeKakaoMap: UIViewRepresentable {
    let routes: [[CLLocationCoordinate2D]]
    let routeColor: UIColor
    let stays: [CLLocationCoordinate2D]
    let cat: CLLocationCoordinate2D?
    let action: MapHomeStickmanAction
    let follows: Bool
    var accessoryID: String? = nil
    var rideLabel: String? = nil
    /// 화랑이 옆 말풍선 글. nil이면 붙이지 않는다.
    var bubble: String? = nil
    var home: CLLocationCoordinate2D? = nil
    /// 집 그림을 다시 그릴지 가르는 값(성장 단계·언어).
    var homeKey = ""
    var homeLabel = ""
    var homeArtwork: AnyView? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> KMViewContainer {
        KakaoMapAvailability.initializeIfNeeded()
        let container = KMViewContainer(frame: .zero)
        let controller = KMController(viewContainer: container)
        controller.delegate = context.coordinator
        context.coordinator.controller = controller
        context.coordinator.container = container
        context.coordinator.update(self)
        // 2.9.4: initEngine(준비, 인증은 뒤에서) → 화면에 붙고 준비가 끝나면 startEngine(→ addViews) → startRendering.
        // 준비 전이나 크기 0일 때 시작하면 지도가 추가되지 않아, 시작될 때까지 짧게 다시 시도한다.
        controller.initEngine()
        context.coordinator.startWhenReady()
        return container
    }

    func updateUIView(_ uiView: KMViewContainer, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleUIView(_ uiView: KMViewContainer, coordinator: Coordinator) {
        coordinator.controller?.stopRendering()
        coordinator.controller?.stopEngine()
    }

    @MainActor
    final class Coordinator: NSObject, MapControllerDelegate {
        var controller: KMController?
        weak var container: KMViewContainer?
        private var map: KakaoMap?
        private var routes: [[CLLocationCoordinate2D]] = []
        private var stays: [CLLocationCoordinate2D] = []
        private var cat: CLLocationCoordinate2D?
        private var action: MapHomeStickmanAction?
        private var follows = false
        private var routeColor = UIColor.systemOrange
        private var drawnRouteKey = 0, drawnStayKey = 0
        private var drawnCatKey: String?
        private var catPoi: Poi?
        private var accessoryID: String?
        private var rideLabel: String?
        private var bubble: String?
        private var home: CLLocationCoordinate2D?
        private var homeKey = "", homeLabel = ""
        private var homeArtwork: AnyView?
        private var drawnHomeKey: String?
        private var hasCentered = false
        private static let viewName = "mapview"

        func update(_ view: MapHomeKakaoMap) {
            routes = view.routes
            stays = view.stays
            cat = view.cat
            action = view.action
            follows = view.follows
            routeColor = view.routeColor
            accessoryID = view.accessoryID
            rideLabel = view.rideLabel
            bubble = view.bubble
            home = view.home
            homeKey = view.homeKey
            homeLabel = view.homeLabel
            homeArtwork = view.homeArtwork
            draw()
        }

        nonisolated func addViews() {
            MainActor.assumeIsolated {
                let start = (cat ?? stays.first).map { MapPoint(longitude: $0.longitude, latitude: $0.latitude) }
                    ?? MapPoint(longitude: 126.978, latitude: 37.5665)
                controller?.addView(MapviewInfo(viewName: Self.viewName, viewInfoName: "map", defaultPosition: start, defaultLevel: 15))
            }
        }

        nonisolated func addViewSucceeded(_ viewName: String, viewInfoName: String) {
            MainActor.assumeIsolated {
                map = controller?.getView(Self.viewName) as? KakaoMap
                if let bounds = container?.bounds, !bounds.isEmpty { map?.viewRect = bounds }
                prepareLayers()
                draw()
            }
        }

        nonisolated func addViewFailed(_ viewName: String, viewInfoName: String) {
            MainActor.assumeIsolated { TaptionPlanDiagnosticsLogger.shared.record("kakao_map_view_failed", fields: [:]) }
        }

        func startWhenReady(attempt: Int = 0) {
            guard let controller, !controller.engineStarted else { return }
            if let container, container.window != nil, !container.bounds.isEmpty, controller.startEngine() {
                controller.startRendering()
                return
            }
            guard attempt < 40 else {
                TaptionPlanDiagnosticsLogger.shared.record("kakao_map_start_failed", fields: ["state": String(controller.getStateDescMessage().prefix(120))])
                return
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                self?.startWhenReady(attempt: attempt + 1)
            }
        }

        nonisolated func authenticationSucceeded() {}

        nonisolated func authenticationFailed(_ errorCode: Int, desc: String) {
            MainActor.assumeIsolated {
                TaptionPlanDiagnosticsLogger.shared.record("kakao_map_auth_failed", fields: ["code": String(errorCode)])
            }
        }

        nonisolated func containerDidResized(_ size: CGSize) {
            MainActor.assumeIsolated {
                map?.viewRect = CGRect(origin: .zero, size: size)
            }
        }

        private func prepareLayers() {
            guard let map else { return }
            let routes = map.getRouteManager()
            let line = PerLevelRouteStyle(width: 6, color: routeColor, strokeWidth: 2, strokeColor: .white, level: 0)
            routes.addRouteStyleSet(RouteStyleSet(styleID: "day", styles: [RouteStyle(styles: [line])]))
            _ = routes.addRouteLayer(layerID: "day", zOrder: 0)
            let labels = map.getLabelManager()
            // 기호 그림은 카카오가 검게 그려서(대표 캡처) 색을 넣은 비트맵을 직접 그린다.
            labels.addPoiStyle(PoiStyle(styleID: "stay", styles: [PerLevelPoiStyle(iconStyle: PoiIconStyle(symbol: Self.dot(routeColor)), level: 0)]))
            _ = labels.addLabelLayer(option: LabelLayerOptions(layerID: "stays", competitionType: .none, competitionUnit: .symbolFirst, orderType: .rank, zOrder: 10))
            _ = labels.addLabelLayer(option: LabelLayerOptions(layerID: "home", competitionType: .none, competitionUnit: .symbolFirst, orderType: .rank, zOrder: 15))
            _ = labels.addLabelLayer(option: LabelLayerOptions(layerID: "cat", competitionType: .none, competitionUnit: .symbolFirst, orderType: .rank, zOrder: 20))
        }

        private static func key(_ lines: [[CLLocationCoordinate2D]]) -> Int {
            var hasher = Hasher()
            for line in lines {
                hasher.combine(line.count)
                if let first = line.first, let last = line.last {
                    hasher.combine(first.latitude); hasher.combine(first.longitude)
                    hasher.combine(last.latitude); hasher.combine(last.longitude)
                }
            }
            return hasher.finalize()
        }

        private func point(_ coordinate: CLLocationCoordinate2D) -> MapPoint {
            MapPoint(longitude: coordinate.longitude, latitude: coordinate.latitude)
        }

        /// 바뀐 것만 다시 그린다(재생 중에는 화랑이 자리만 바뀐다).
        private func draw() {
            guard let map else { return }
            let routeKey = Self.key(routes)
            if routeKey != drawnRouteKey, let layer = map.getRouteManager().getRouteLayer(layerID: "day") {
                drawnRouteKey = routeKey
                layer.clearAllRoutes()
                if !routes.isEmpty {
                    let option = RouteOptions(routeID: "day", styleID: "day", zOrder: 0)
                    option.segments = routes.map { RouteSegment(points: $0.map(point), styleIndex: 0) }
                    layer.addRoute(option: option)?.show()
                }
            }
            let stayKey = Self.key([stays])
            if stayKey != drawnStayKey, let layer = map.getLabelManager().getLabelLayer(layerID: "stays") {
                drawnStayKey = stayKey
                layer.clearAllItems()
                layer.addPois(option: PoiOptions(styleID: "stay"), at: stays.map(point))?.forEach { $0.show() }
            }
            drawHome(on: map)
            drawCat(on: map)
            if let cat, follows || !hasCentered {
                hasCentered = true
                map.moveCamera(CameraUpdate.make(target: point(cat), mapView: map))
            }
        }

        /// 집: 다른 지도와 같은 집 그림 아래에 「○일째」. 성장 단계나 집 자리가 바뀔 때만 다시 그린다.
        private func drawHome(on map: KakaoMap) {
            let labels = map.getLabelManager()
            guard let layer = labels.getLabelLayer(layerID: "home") else { return }
            let key = home.map { "\(homeKey)|\($0.latitude)|\($0.longitude)" }
            guard key != drawnHomeKey else { return }
            drawnHomeKey = key
            layer.clearAllItems()
            guard let home, let key, let artwork = homeArtwork, let image = Self.homeImage(artwork, label: homeLabel) else { return }
            let styleID = "home-\(key.hashValue)"
            // 집 그림의 아래쪽 가운데가 집 자리다(그 아래는 이름표).
            let anchor = CGPoint(x: 0.5, y: Self.homeArtworkHeight / max(image.size.height, 1))
            labels.addPoiStyle(PoiStyle(styleID: styleID, styles: [PerLevelPoiStyle(iconStyle: PoiIconStyle(symbol: image, anchorPoint: anchor), level: 0)]))
            layer.addPoi(option: PoiOptions(styleID: styleID), at: point(home))?.show()
        }

        private func drawCat(on map: KakaoMap) {
            let labels = map.getLabelManager()
            guard let cat, let action, let layer = labels.getLabelLayer(layerID: "cat") else { return }
            // 동작·꾸미기·노선 이름표·말풍선 글이 바뀌면 그림을 새로 만든다. 움직이는 그림은 아니고 한 장이다.
            let key = "\(action)|\(accessoryID ?? "")|\(rideLabel ?? "")|\(bubble ?? "")"
            if key != drawnCatKey || catPoi == nil {
                drawnCatKey = key
                let styleID = "cat-\(key.hashValue)"
                if let made = Self.catImage(action, accessoryID: accessoryID, rideLabel: rideLabel, bubble: bubble) {
                    labels.addPoiStyle(PoiStyle(styleID: styleID, styles: [PerLevelPoiStyle(iconStyle: PoiIconStyle(symbol: made.image, anchorPoint: made.anchor), level: 0)]))
                }
                layer.clearAllItems()
                catPoi = layer.addPoi(option: PoiOptions(styleID: styleID), at: point(cat))
                catPoi?.show()
            } else {
                catPoi?.moveAt(point(cat), duration: 150)
            }
        }

        private static func dot(_ color: UIColor) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 14, height: 14)).image { context in
                UIColor.white.setFill()
                context.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: 14, height: 14))
                color.setFill()
                context.cgContext.fillEllipse(in: CGRect(x: 2.5, y: 2.5, width: 9, height: 9))
            }
        }

        private static let catInset = (leading: CGFloat(34), top: CGFloat(26), bottom: CGFloat(12))
        static let homeArtworkHeight: CGFloat = 112

        /// 다른 지도와 같은 화랑이(탈것·꾸미기·노선 이름표) 한 장. 말풍선이 있으면 오른쪽에 붙인다.
        /// anchor는 그림 안에서 화랑이 발이 놓이는 자리다.
        private static func catImage(_ action: MapHomeStickmanAction, accessoryID: String?, rideLabel: String?, bubble: String?) -> (image: UIImage, anchor: CGPoint)? {
            let side = MapHomeStickmanMarker.size
            let content = HStack(alignment: .center, spacing: 6) {
                MapHomeStickmanMarker(action: action, animationPhase: 0, equippedAccessoryID: accessoryID, rideLabel: rideLabel)
                    .padding(.leading, catInset.leading)
                    .padding(.trailing, bubble == nil ? catInset.leading : 10)
                if let bubble { MapHomeCatSpeechBubble(text: bubble, side: .right, action: action) }
            }
            .padding(.top, catInset.top)
            .padding(.bottom, catInset.bottom)
            .padding(.trailing, bubble == nil ? 0 : 6)
            .environment(\.isLuminanceReduced, true)
            let renderer = ImageRenderer(content: content)
            renderer.scale = UIScreen.main.scale
            guard let image = renderer.uiImage, image.size.width > 0, image.size.height > 0 else { return nil }
            let anchor = CGPoint(x: (catInset.leading + side.width / 2) / image.size.width, y: (image.size.height - catInset.bottom) / image.size.height)
            return (image, anchor)
        }

        private static func homeImage(_ artwork: AnyView, label: String) -> UIImage? {
            let content = VStack(spacing: 2) {
                artwork
                Text(verbatim: label)
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.tpInk)
                    .padding(.horizontal, 12)
                    .frame(height: 22)
                    .background(Color.tpSurface.opacity(0.98), in: Capsule())
                    .overlay { Capsule().stroke(Color.tpBorder, lineWidth: TaptionBorder.width) }
            }
            .padding(6)
            let renderer = ImageRenderer(content: content)
            renderer.scale = UIScreen.main.scale
            return renderer.uiImage
        }
    }
}
