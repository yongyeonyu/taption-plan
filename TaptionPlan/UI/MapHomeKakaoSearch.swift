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
        guard isAvailable(at: center), let token = await AssistantRegistration.searchToken() else { return nil }
        var best: (name: String, meters: Double)?
        for code in stayCategories {
            guard let request = categoryRequest(code: code, center: center, radiusMeters: radiusMeters, token: token),
                  let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
            let origin = CLLocation(latitude: center.latitude, longitude: center.longitude)
            for place in decode(data) {
                let meters = origin.distance(from: CLLocation(latitude: place.coordinate.latitude, longitude: place.coordinate.longitude))
                if meters <= Double(radiusMeters), meters < (best?.meters ?? .infinity) { best = (place.title, meters) }
            }
        }
        return best?.name
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
    /// 1단계: 지도·내 위치·오늘 경로선·머문 곳 핀. 재생 캐릭터·말풍선 등은 다른 지도에서만 그린다.
    var kakaoMap: some View {
        MapHomeKakaoMap(
            center: model.latestSensorReading?.point,
            route: model.liveRouteState.readings.compactMap(\.point),
            stays: currentDayDataSnapshot?.places.compactMap(\.point) ?? []
        )
        .ignoresSafeArea()
        .accessibilityLabel(language.text("카카오 지도", "Kakao map"))
    }
}

struct MapHomeKakaoMap: UIViewRepresentable {
    let center: GeoPoint?
    let route: [GeoPoint]
    let stays: [GeoPoint]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> KMViewContainer {
        KakaoMapAvailability.initializeIfNeeded()
        let container = KMViewContainer(frame: .zero)
        let controller = KMController(viewContainer: container)
        controller.delegate = context.coordinator
        context.coordinator.controller = controller
        context.coordinator.container = container
        context.coordinator.update(center: center, route: route, stays: stays)
        // 2.9.4: initEngine(준비, 인증은 뒤에서) → 화면에 붙고 준비가 끝나면 startEngine(→ addViews) → startRendering.
        // 준비 전이나 크기 0일 때 시작하면 지도가 추가되지 않아, 시작될 때까지 짧게 다시 시도한다.
        controller.initEngine()
        context.coordinator.startWhenReady()
        return container
    }

    func updateUIView(_ uiView: KMViewContainer, context: Context) {
        context.coordinator.update(center: center, route: route, stays: stays)
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
        private var center: GeoPoint?
        private var route: [GeoPoint] = []
        private var stays: [GeoPoint] = []
        private var hasCentered = false
        private static let viewName = "mapview"

        func update(center: GeoPoint?, route: [GeoPoint], stays: [GeoPoint]) {
            let changed = route != self.route || stays != self.stays || center != self.center
            self.center = center
            self.route = route
            self.stays = stays
            if changed { draw() }
        }

        nonisolated func addViews() {
            MainActor.assumeIsolated {
                let start = center.map { MapPoint(longitude: $0.longitude, latitude: $0.latitude) }
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.startWhenReady(attempt: attempt + 1) }
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
            let line = PerLevelRouteStyle(width: 7, color: UIColor(Color.tpAccent), strokeWidth: 2, strokeColor: .white, level: 0)
            routes.addRouteStyleSet(RouteStyleSet(styleID: "day", styles: [RouteStyle(styles: [line])]))
            _ = routes.addRouteLayer(layerID: "day", zOrder: 0)
            let labels = map.getLabelManager()
            labels.addPoiStyle(PoiStyle(styleID: "stay", styles: [PerLevelPoiStyle(iconStyle: PoiIconStyle(symbol: Self.symbol("mappin.circle.fill", UIColor(Color.tpInk))), level: 0)]))
            labels.addPoiStyle(PoiStyle(styleID: "me", styles: [PerLevelPoiStyle(iconStyle: PoiIconStyle(symbol: Self.symbol("location.circle.fill", .systemBlue)), level: 0)]))
            _ = labels.addLabelLayer(option: LabelLayerOptions(layerID: "marks", competitionType: .none, competitionUnit: .symbolFirst, orderType: .rank, zOrder: 10))
        }

        private func draw() {
            guard let map else { return }
            if let layer = map.getRouteManager().getRouteLayer(layerID: "day") {
                layer.clearAllRoutes()
                if route.count >= 2 {
                    let option = RouteOptions(routeID: "today", styleID: "day", zOrder: 0)
                    option.segments = [RouteSegment(points: route.map { MapPoint(longitude: $0.longitude, latitude: $0.latitude) }, styleIndex: 0)]
                    layer.addRoute(option: option)?.show()
                }
            }
            if let layer = map.getLabelManager().getLabelLayer(layerID: "marks") {
                layer.clearAllItems()
                layer.addPois(option: PoiOptions(styleID: "stay"), at: stays.map { MapPoint(longitude: $0.longitude, latitude: $0.latitude) })?.forEach { $0.show() }
                if let center {
                    layer.addPoi(option: PoiOptions(styleID: "me"), at: MapPoint(longitude: center.longitude, latitude: center.latitude))?.show()
                }
            }
            if !hasCentered, let center {
                hasCentered = true
                map.moveCamera(CameraUpdate.make(target: MapPoint(longitude: center.longitude, latitude: center.latitude), zoomLevel: 15, mapView: map))
            }
        }

        private static func symbol(_ name: String, _ color: UIColor) -> UIImage? {
            UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold))?
                .withTintColor(color, renderingMode: .alwaysOriginal)
        }
    }
}
