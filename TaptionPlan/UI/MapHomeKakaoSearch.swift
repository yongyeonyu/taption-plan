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

/// 카카오 지도의 화면 점 ↔ 좌표 변환(KMP1114A04). 카카오 SDK에는 좌표 → 화면 변환이 없어,
/// 화면 세 점의 좌표(`getPosition`)로 「화면 → 웹 메르카토르」 아핀 변환을 풀고 그 역으로 투영한다. 기울기는 꺼 둔다.
struct MapHomeKakaoProjection: Equatable, Sendable {
    /// 세계 좌표(웹 메르카토르 0...1, y는 남쪽이 큼) = origin + m·(x, y).
    let originX: Double, originY: Double
    let m11: Double, m12: Double, m21: Double, m22: Double
    let size: CGSize

    static let earthCircumference = 40_075_016.686
    /// 벡터 지도(MapLibre) 카메라 고도와 같은 눈금: 고도 = 화면 세로에 보이는 거리 ÷ (2·tan 15°).
    static let distancePerVisibleMeter = 1 / (2 * tan(15 * Double.pi / 180))

    static func world(_ coordinate: CLLocationCoordinate2D) -> (x: Double, y: Double) {
        let latitude = min(max(coordinate.latitude, -85.051_128), 85.051_128) * .pi / 180
        return ((coordinate.longitude + 180) / 360, (1 - log(tan(.pi / 4 + latitude / 2)) / .pi) / 2)
    }

    static func coordinate(worldX x: Double, worldY y: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: atan(sinh(.pi * (1 - 2 * y))) * 180 / .pi, longitude: x * 360 - 180)
    }

    private static func wrapped(_ delta: Double) -> Double {
        delta > 0.5 ? delta - 1 : (delta < -0.5 ? delta + 1 : delta)
    }

    /// 카메라 값으로 만든 변환(명령을 보낸 직후·재생 중, 엔진이 그리기 전에도 쓸 수 있다). heading은 시계 방향 도.
    init(center: CLLocationCoordinate2D, cameraDistance: Double, heading: Double, size: CGSize) {
        let metersPerPoint = cameraDistance / Self.distancePerVisibleMeter / max(Double(size.height), 1)
        let scale = metersPerPoint / (Self.earthCircumference * max(cos(center.latitude * .pi / 180), 0.01))
        let radians = heading * .pi / 180
        m11 = scale * cos(radians)
        m12 = -scale * sin(radians)
        m21 = scale * sin(radians)
        m22 = scale * cos(radians)
        let world = Self.world(center), midX = Double(size.width) / 2, midY = Double(size.height) / 2
        originX = world.x - m11 * midX - m12 * midY
        originY = world.y - m21 * midX - m22 * midY
        self.size = size
    }

    /// 화면 세 점과 그 자리의 좌표로 푼 변환. 세 점이 한 줄이거나 좌표가 이상하면 nil.
    init?(screen: [CGPoint], coordinates: [CLLocationCoordinate2D], size: CGSize) {
        guard screen.count == 3, coordinates.count == 3, size.width > 0, size.height > 0,
              coordinates.allSatisfy({ CLLocationCoordinate2DIsValid($0) && abs($0.latitude) < 85 }) else { return nil }
        let worlds = coordinates.map(Self.world)
        let e1x = Double(screen[1].x - screen[0].x), e1y = Double(screen[1].y - screen[0].y)
        let e2x = Double(screen[2].x - screen[0].x), e2y = Double(screen[2].y - screen[0].y)
        let determinant = e1x * e2y - e2x * e1y
        guard abs(determinant) > 1e-9 else { return nil }
        let w1x = Self.wrapped(worlds[1].x - worlds[0].x), w1y = worlds[1].y - worlds[0].y
        let w2x = Self.wrapped(worlds[2].x - worlds[0].x), w2y = worlds[2].y - worlds[0].y
        let a = (w1x * e2y - w2x * e1y) / determinant, b = (w2x * e1x - w1x * e2x) / determinant
        let c = (w1y * e2y - w2y * e1y) / determinant, d = (w2y * e1x - w1y * e2x) / determinant
        let x = worlds[0].x - a * Double(screen[0].x) - b * Double(screen[0].y)
        let y = worlds[0].y - c * Double(screen[0].x) - d * Double(screen[0].y)
        // 뒤집히거나 찌그러진 값은 엔진이 아직 준비되지 않은 것이다.
        guard [a, b, c, d, x, y].allSatisfy(\.isFinite), a * d - b * c > 1e-24 else { return nil }
        (m11, m12, m21, m22, originX, originY) = (a, b, c, d, x, y)
        self.size = size
    }

    /// 화면 안에서 고르는 세 표본 점(가장자리는 피한다).
    static func samplePoints(in size: CGSize) -> [CGPoint] {
        [CGPoint(x: size.width * 0.25, y: size.height * 0.25), CGPoint(x: size.width * 0.75, y: size.height * 0.25),
         CGPoint(x: size.width * 0.25, y: size.height * 0.75)]
    }

    private var scale: Double { hypot(m11, m21) }

    /// 화면 위쪽이 가리키는 방위(북 0, 시계 방향 도). MapLibre의 heading과 같은 뜻이다.
    var heading: Double {
        let degrees = atan2(m21, m11) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    func coordinate(at point: CGPoint) -> CLLocationCoordinate2D {
        let x = Double(point.x), y = Double(point.y)
        return Self.coordinate(worldX: originX + m11 * x + m12 * y, worldY: originY + m21 * x + m22 * y)
    }

    func point(for coordinate: CLLocationCoordinate2D) -> CGPoint {
        let world = Self.world(coordinate)
        let centerX = originX + m11 * Double(size.width) / 2 + m12 * Double(size.height) / 2
        // 날짜 변경선 너머는 화면 가운데에서 가까운 쪽으로 편다.
        let dx = centerX + Self.wrapped(world.x - centerX) - originX, dy = world.y - originY
        let determinant = m11 * m22 - m12 * m21
        return CGPoint(x: (m22 * dx - m12 * dy) / determinant, y: (m11 * dy - m21 * dx) / determinant)
    }

    var center: CLLocationCoordinate2D { coordinate(at: CGPoint(x: size.width / 2, y: size.height / 2)) }

    /// 화면 가운데 위도에서 1pt가 덮는 땅 위 거리(m).
    var metersPerPoint: Double { scale * Self.earthCircumference * cos(center.latitude * .pi / 180) }

    var cameraDistance: Double { max(metersPerPoint * Double(size.height) * Self.distancePerVisibleMeter, 1) }

    /// 화면 네 귀퉁이를 감싸는 위·경도 폭.
    var span: MKCoordinateSpan {
        let corners = [CGPoint.zero, CGPoint(x: size.width, y: 0), CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height)]
            .map(coordinate(at:))
        let latitudes = corners.map(\.latitude), longitudes = corners.map(\.longitude)
        return MKCoordinateSpan(latitudeDelta: (latitudes.max() ?? 0) - (latitudes.min() ?? 0),
                                longitudeDelta: (longitudes.max() ?? 0) - (longitudes.min() ?? 0))
    }

    /// 화면에서 `tolerance`pt 넘게 어긋나면 다른 화면으로 본다(멈춘 지도의 계산 잔떨림은 거른다).
    func differs(from other: Self, tolerance: Double = 0.05) -> Bool {
        guard size == other.size, scale > 0 else { return true }
        let reach = Double(max(size.width, size.height))
        let shift = max(abs(originX - other.originX), abs(originY - other.originY)) / scale
        let turn = max(abs(m11 - other.m11), abs(m12 - other.m12), abs(m21 - other.m21), abs(m22 - other.m22)) * reach / scale
        return shift > tolerance || turn > tolerance
    }

    /// 영역이 화면에 다 들어오는 카메라 거리(북쪽이 위일 때).
    static func cameraDistance(fitting region: MKCoordinateRegion, size: CGSize) -> Double {
        let metersPerDegree = earthCircumference / 360
        let tall = region.span.latitudeDelta * metersPerDegree
        let wide = region.span.longitudeDelta * metersPerDegree * cos(region.center.latitude * .pi / 180)
        let visible = max(tall, wide * Double(size.height) / max(Double(size.width), 1))
        return max(visible * distancePerVisibleMeter, 1)
    }
}

/// 같은 입력으로 벡터 지도나 카카오 지도를 그린다. 위에 얹는 화면 층은 둘이 같다.
struct MapHomeViewportEngineMap: View {
    let usesKakao: Bool
    let kakaoLabel: String
    let inputs: MapHomeVectorMap

    var body: some View {
        if usesKakao {
            MapHomeKakaoMap(inputs: inputs).accessibilityLabel(kakaoLabel)
        } else {
            inputs.id(inputs.style.rawValue)
        }
    }
}

/// 카카오 지도(KMP1114A04): 타일과 경로선만 그린다. 핀·사진·발자국·날씨·화랑이·말풍선은 벡터 지도와 같은
/// SwiftUI 층(`MapHomeVectorViewportOverlay`)이 그리고, 이 코디네이터는 그 층에 화면 좌표를 대 준다.
struct MapHomeKakaoMap: UIViewRepresentable {
    /// 벡터 지도와 같은 입력·콜백. 스타일·언어는 쓰지 않는다.
    let inputs: MapHomeVectorMap

    func makeCoordinator() -> Coordinator { Coordinator(parent: inputs) }

    func makeUIView(context: Context) -> KMViewContainer {
        KakaoMapAvailability.initializeIfNeeded()
        let container = KMViewContainer(frame: .zero)
        let controller = KMController(viewContainer: container)
        controller.delegate = context.coordinator
        context.coordinator.controller = controller
        context.coordinator.attach(to: container)
        // 2.9.4: initEngine(준비, 인증은 뒤에서) → 화면에 붙고 준비가 끝나면 startEngine(→ addViews) → startRendering.
        // 준비 전이나 크기 0일 때 시작하면 지도가 추가되지 않아, 시작될 때까지 짧게 다시 시도한다.
        controller.initEngine()
        context.coordinator.startWhenReady()
        return container
    }

    func updateUIView(_ uiView: KMViewContainer, context: Context) {
        context.coordinator.parent = inputs
        context.coordinator.refresh()
        inputs.playbackDriver?.sink = context.coordinator
    }

    static func dismantleUIView(_ uiView: KMViewContainer, coordinator: Coordinator) {
        coordinator.detach()
        coordinator.controller?.stopRendering()
        coordinator.controller?.stopEngine()
    }

    @MainActor
    final class Coordinator: NSObject, MapControllerDelegate, KakaoMapEventDelegate, UIGestureRecognizerDelegate,
        MapHomePlaybackSink {
        struct Target {
            var center: CLLocationCoordinate2D
            var distance: Double
            var heading: Double
        }

        var parent: MapHomeVectorMap
        var controller: KMController?
        private weak var container: KMViewContainer?
        private var map: KakaoMap?
        private static let viewName = "mapview"

        /// 지금 화면의 변환. 엔진에서 읽었거나, 방금 보낸 카메라 명령으로 미리 계산한 값이다.
        private var projection: MapHomeKakaoProjection?
        /// 카카오 카메라 높이 ÷ 화면 세로에 보이는 거리. 화면을 읽을 때마다 맞춘다(처음에는 MapLibre와 같은 화각으로 가정).
        private var heightPerVisibleMeter = MapHomeKakaoProjection.distancePerVisibleMeter
        /// 회전각 부호. 문서는 시계 방향이지만 읽은 화면이 반대로 돌면 뒤집는다.
        private var rotationSign = 1.0
        /// 방금 보낸 명령. 화면이 멈춘 뒤 읽은 값과 다르면 한 번 고쳐 보낸다.
        private var unverifiedTarget: Target?
        private var settleRetries = 0
        private var hadPlaybackDriver = false
        private var lastCameraRevision = Int.min
        private var lastHeading: CLLocationDirection?
        private var lastHeadingCoordinate: CLLocationCoordinate2D?

        private var link: CADisplayLink?
        private var isCameraMoving = false
        private var settleUptime: TimeInterval = 0
        private var sampleHoldUptime: TimeInterval = 0
        private var lastChangeUptime: TimeInterval = 0

        private var markerProjector = MapHomeMarkerProjector()
        private var lastProjectedMarkers: [MapHomeVectorMarker] = []
        private var lastViewportPublishUptime: TimeInterval = 0
        private var pendingViewport: (viewport: MapHomeVectorViewport, force: Bool, cameraRevision: Int)?
        private var isViewportDeliveryScheduled = false
        private static let playbackViewportInterval: TimeInterval = 1.0 / 60.0 - 0.002
        private var lastPlaybackViewportUptime: TimeInterval = 0
        private let markerLayer = MapHomeCoordinatorMarkerLayer()

        private var motionGestures: [UIGestureRecognizer] = []
        private var longPressGesture: UILongPressGestureRecognizer?
        private var singleTapGesture: UITapGestureRecognizer?
        private var doubleTapGesture: UITapGestureRecognizer?

        private var drawnRouteKeys: [String: [MapHomeVectorRouteContentKey]] = [:]
        private var routeStyleIDs: Set<String> = []
        private var lastTap: (point: CGPoint, uptime: TimeInterval)?
        private var lastTerrainTap: (coordinate: CLLocationCoordinate2D, uptime: TimeInterval)?
        private var hasLoggedProjectionCheck = false

        init(parent: MapHomeVectorMap) { self.parent = parent }

        private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

        private var viewSize: CGSize? {
            guard let size = container?.bounds.size, size.width > 0, size.height > 0 else { return nil }
            return size
        }

        // MARK: 엔진 준비

        nonisolated func addViews() {
            MainActor.assumeIsolated {
                let start = parent.displayedCoordinate ?? firstRouteCoordinate ?? parent.homeCoordinate
                    ?? MapHomeStartupCameraPolicy.fallbackCenter
                controller?.addView(MapviewInfo(viewName: Self.viewName, viewInfoName: "map",
                    defaultPosition: MapPoint(longitude: start.longitude, latitude: start.latitude), defaultLevel: 15))
            }
        }

        nonisolated func addViewSucceeded(_ viewName: String, viewInfoName: String) {
            MainActor.assumeIsolated {
                map = controller?.getView(Self.viewName) as? KakaoMap
                if let bounds = container?.bounds, !bounds.isEmpty { map?.viewRect = bounds }
                // 화면 층은 기울기 없는 지도만 맞출 수 있다.
                map?.setGestureEnable(type: .tilt, enable: false)
                map?.eventDelegate = self
                drawnRouteKeys = [:]
                refresh()
                startLink(settlingFor: 0.5)
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
                // 크기가 바뀌면 미리 계산한 변환은 못 쓴다. 엔진이 다시 그린 뒤 읽는다.
                sampleHoldUptime = uptime + 0.05
                startLink(settlingFor: 0.2)
            }
        }

        func attach(to container: KMViewContainer) {
            self.container = container
            // 카카오 지도는 터치를 직접 받아 움직인다. 아래 인식기는 지켜보기만 하고 터치를 가로채지 않는다.
            let motion: [UIGestureRecognizer] = [UIPanGestureRecognizer(), UIPinchGestureRecognizer(), UIRotationGestureRecognizer()]
            for gesture in motion { gesture.addTarget(self, action: #selector(handleMotionGesture(_:))) }
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
            longPress.minimumPressDuration = 0.55
            longPress.allowableMovement = 12
            let doubleTap = UITapGestureRecognizer()
            doubleTap.numberOfTapsRequired = 2
            let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
            singleTap.require(toFail: longPress)
            // 두 번 누르기(카카오의 확대)의 첫 번째를 한 번 누르기로 읽지 않는다.
            singleTap.require(toFail: doubleTap)
            for gesture in motion + [longPress, doubleTap, singleTap] {
                gesture.cancelsTouchesInView = false
                gesture.delaysTouchesEnded = false
                gesture.delegate = self
                container.addGestureRecognizer(gesture)
            }
            motionGestures = motion
            longPressGesture = longPress
            singleTapGesture = singleTap
            doubleTapGesture = doubleTap
        }

        func detach() {
            stopLink()
            let presses: [UIGestureRecognizer?] = [longPressGesture, singleTapGesture, doubleTapGesture]
            for gesture in motionGestures + presses.compactMap({ $0 }) {
                gesture.view?.removeGestureRecognizer(gesture)
            }
            motionGestures = []
            longPressGesture = nil
            singleTapGesture = nil
            doubleTapGesture = nil
            markerLayer.host.removeFromSuperlayer()
            map?.eventDelegate = nil
            pendingViewport = nil
        }

        /// SwiftUI가 새 입력을 줄 때마다: 바뀐 경로·마커만 다시 반영하고 카메라 명령을 적용한다.
        func refresh() {
            updateRoutes()
            updateMarkerLayer()
            if let projection, projection.size == viewSize, lastProjectedMarkers != parent.markers {
                publishViewport(projection, force: true)
            }
            applyCameraCommandIfNeeded()
            applyHeadingIfNeeded()
            // 재생이 끝나면 엔진 값을 다시 읽어 최종 화면으로 넘긴다.
            if hadPlaybackDriver, parent.playbackDriver == nil { startLink(settlingFor: 0.1) }
            hadPlaybackDriver = parent.playbackDriver != nil
        }

        // MARK: 화면 읽기

        /// 엔진이 지금 그리는 화면의 변환. 준비 전이거나 값이 이상하면 nil.
        private func sampleProjection() -> MapHomeKakaoProjection? {
            guard let map, let size = viewSize else { return nil }
            let screen = MapHomeKakaoProjection.samplePoints(in: size)
            let coordinates = screen.map { point -> CLLocationCoordinate2D in
                let position = map.getPosition(point).wgsCoord
                return CLLocationCoordinate2D(latitude: position.latitude, longitude: position.longitude)
            }
            return MapHomeKakaoProjection(screen: screen, coordinates: coordinates, size: size)
        }

        private func calibrate(with sampled: MapHomeKakaoProjection) {
            guard let map else { return }
            let ratio = map.cameraHeight / (sampled.metersPerPoint * Double(sampled.size.height))
            if ratio.isFinite, (0.05...50).contains(ratio) { heightPerVisibleMeter = ratio }
        }

        private func markerPoints(in projection: MapHomeKakaoProjection) -> [String: CGPoint] {
            let center = projection.center, span = projection.span
            return markerProjector.points(
                markers: parent.markers,
                camera: .init(latitude: center.latitude, longitude: center.longitude, altitude: projection.cameraDistance,
                              heading: projection.heading, pitch: 0, size: projection.size),
                visible: .init(south: center.latitude - span.latitudeDelta / 2, west: center.longitude - span.longitudeDelta / 2,
                               north: center.latitude + span.latitudeDelta / 2, east: center.longitude + span.longitudeDelta / 2),
                project: { projection.point(for: $0) }
            )
        }

        private func viewport(of projection: MapHomeKakaoProjection, markerPoints: [String: CGPoint]) -> MapHomeVectorViewport {
            MapHomeVectorViewport(center: projection.center, span: projection.span, cameraDistance: projection.cameraDistance,
                                  heading: projection.heading, pitch: 0, markerPoints: markerPoints)
        }

        /// 벡터 지도와 같은 규칙: 움직이는 동안은 최대 60Hz, 한 런루프에 한 번만 넘기고, 그 사이 카메라 명령이 바뀌면 버린다.
        private func publishViewport(_ projection: MapHomeKakaoProjection, force: Bool) {
            let now = uptime
            guard force || now - lastViewportPublishUptime >= 1.0 / 60.0 else { return }
            lastViewportPublishUptime = now
            lastProjectedMarkers = parent.markers
            let next = viewport(of: projection, markerPoints: markerPoints(in: projection))
            pendingViewport = (next, (pendingViewport?.force ?? false) || force, lastCameraRevision)
            guard !isViewportDeliveryScheduled else { return }
            isViewportDeliveryScheduled = true
            Task { @MainActor [self] in
                isViewportDeliveryScheduled = false
                guard let pending = pendingViewport else { return }
                pendingViewport = nil
                guard pending.cameraRevision == parent.cameraRevision else { return }
                parent.onViewportChange(pending.viewport, pending.force)
            }
        }

        // MARK: 움직이는 동안의 표시 링크

        /// 카카오 SDK는 움직이는 동안의 알림이 없어(시작·끝만 있다) 그 사이는 표시 링크로 화면을 읽는다.
        private func startLink(settlingFor seconds: TimeInterval) {
            let now = uptime
            settleUptime = max(settleUptime, now + seconds)
            guard link == nil else { return }
            lastChangeUptime = now
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        private func stopLink() {
            link?.invalidate()
            link = nil
        }

        private var hasActiveGesture: Bool {
            motionGestures.contains { $0.state == .began || $0.state == .changed }
        }

        @objc private func tick() {
            let now = uptime
            if parent.playbackDriver == nil, now >= sampleHoldUptime, let sampled = sampleProjection() {
                calibrate(with: sampled)
                if projection.map({ sampled.differs(from: $0) }) ?? true {
                    projection = sampled
                    lastChangeUptime = now
                    settleUptime = max(settleUptime, now + 0.12)
                    publishViewport(sampled, force: false)
                }
            }
            // 멈춤 알림이 오지 않아도 1초 동안 그대로면 멈춘 것으로 본다.
            if isCameraMoving, now - lastChangeUptime > 1 { isCameraMoving = false }
            guard !isCameraMoving, !hasActiveGesture, now >= settleUptime else { return }
            stopLink()
            finishSettling()
        }

        /// 화면이 멈췄다: 엔진 값을 다시 읽어 최종 화면으로 넘긴다. 명령과 다르게 놓였으면 한 번 고쳐 보낸다.
        private func finishSettling() {
            guard parent.playbackDriver == nil else { return }
            let target = unverifiedTarget
            unverifiedTarget = nil
            if let sampled = sampleProjection() {
                settleRetries = 0
                calibrate(with: sampled)
                if let target, correctsCommand(target, sampled: sampled) {
                    move(to: target)
                    sampleHoldUptime = uptime + 0.05
                    startLink(settlingFor: 0.25)
                    return
                }
                projection = sampled
            } else if target != nil, settleRetries < 20 {
                // 엔진이 아직 그리지 않아 읽을 수 없다. 보낸 명령을 확인할 수 있을 때까지 조금 더 기다린다.
                settleRetries += 1
                unverifiedTarget = target
                startLink(settlingFor: 0.25)
                return
            }
            if let projection { publishViewport(projection, force: true) }
        }

        /// 높이 눈금(위 `calibrate`)이나 회전 방향이 가정과 달랐는지 본다.
        private func correctsCommand(_ target: Target, sampled: MapHomeKakaoProjection) -> Bool {
            if abs(sin(target.heading * .pi / 180)) > 0.1,
               angularDistance(sampled.heading, target.heading) > 5, angularDistance(sampled.heading, -target.heading) < 5 {
                rotationSign = -rotationSign
                return true
            }
            return abs(sampled.cameraDistance / max(target.distance, 1) - 1) > 0.03
        }

        // MARK: 카메라 명령

        private func move(to target: Target) {
            guard let map else { return }
            let visible = target.distance / MapHomeKakaoProjection.distancePerVisibleMeter
            map.moveCamera(CameraUpdate.make(cameraPosition: CameraPosition(
                target: MapPoint(longitude: target.center.longitude, latitude: target.center.latitude),
                height: visible * heightPerVisibleMeter,
                rotation: rotationSign * target.heading * .pi / 180,
                tilt: 0
            )))
        }

        /// 카메라를 놓고, 엔진이 그리기를 기다리지 않고 계산한 화면을 바로 넘긴다(벡터 지도는 놓자마자 읽을 수 있다).
        private func apply(_ target: Target, verifies: Bool) {
            guard map != nil, let size = viewSize else { return }
            move(to: target)
            if verifies { unverifiedTarget = target }
            let predicted = MapHomeKakaoProjection(center: target.center, cameraDistance: target.distance, heading: target.heading, size: size)
            projection = predicted
            publishViewport(predicted, force: true)
            // 엔진이 새 카메라로 그리기 전의 옛 화면을 읽지 않게 잠깐 기다린다.
            sampleHoldUptime = uptime + 0.05
            startLink(settlingFor: 0.25)
        }

        func applyCameraCommandIfNeeded() {
            guard map != nil, let size = viewSize, lastCameraRevision != parent.cameraRevision else { return }
            lastCameraRevision = parent.cameraRevision
            // 재생 구동기가 카메라를 맡는 동안 SwiftUI 카메라 명령은 버린다(PLY1029A08).
            if parent.playbackDriver != nil {
                MapHomePlaybackFrameStats.blockedCameraCommands &+= 1
                return
            }
            if let region = parent.cameraPosition.region {
                apply(Target(center: region.center, distance: MapHomeKakaoProjection.cameraDistance(fitting: region, size: size),
                             heading: projection?.heading ?? 0), verifies: true)
            } else if let camera = parent.cameraPosition.camera {
                apply(Target(center: camera.centerCoordinate, distance: camera.distance, heading: camera.heading), verifies: true)
            } else {
                apply(Target(center: parent.displayedCoordinate ?? firstRouteCoordinate ?? parent.homeCoordinate
                                 ?? MapHomeStartupCameraPolicy.fallbackCenter,
                             distance: MapHomeStartupCameraPolicy.distance, heading: 0), verifies: true)
            }
        }

        func applyHeadingIfNeeded() {
            guard map != nil, viewSize != nil, parent.playbackDriver == nil else { return }
            guard parent.followsHeading, let coordinate = parent.displayedCoordinate else {
                lastHeading = nil
                lastHeadingCoordinate = nil
                return
            }
            let heading = normalizedHeading(parent.headingDegrees)
            let coordinateChanged = lastHeadingCoordinate.map {
                abs($0.latitude - coordinate.latitude) > 0.000_001 || abs($0.longitude - coordinate.longitude) > 0.000_001
            } ?? true
            let headingChanged = lastHeading.map { angularDistance($0, heading) >= 0.5 } ?? true
            guard coordinateChanged || headingChanged else { return }
            lastHeading = heading
            lastHeadingCoordinate = coordinate
            apply(Target(center: coordinate, distance: projection?.cameraDistance ?? MapHomeStartupCameraPolicy.distance,
                         heading: heading), verifies: false)
        }

        private var firstRouteCoordinate: CLLocationCoordinate2D? {
            parent.activeRoute?.coordinates.first
                ?? parent.activeRouteSegments.first?.coordinates.first
                ?? parent.historicalRoutes.first?.coordinates.first
                ?? parent.expectedRoutes.first?.coordinates.first
                ?? parent.subwayRoutes.first?.coordinates.first
        }

        private func normalizedHeading(_ value: CLLocationDirection) -> CLLocationDirection {
            let normalized = value.truncatingRemainder(dividingBy: 360)
            return normalized < 0 ? normalized + 360 : normalized
        }

        private func angularDistance(_ lhs: CLLocationDirection, _ rhs: CLLocationDirection) -> CLLocationDirection {
            let delta = abs(normalizedHeading(lhs) - normalizedHeading(rhs))
            return min(delta, 360 - delta)
        }

        // MARK: 재생

        var playbackCameraDistance: Double? {
            (sampleProjection() ?? projection)?.cameraDistance
        }

        /// 재생 한 프레임: 카메라를 그 자리에 바로 놓는다. 카카오는 놓은 카메라를 다음 그리기에야 돌려줄 수 있어,
        /// 화면 좌표는 엔진에서 읽지 않고 놓은 값으로 계산한다(읽으면 한 프레임 늦어 화랑이가 튄다, PLY1029A06).
        func applyPlaybackFrame(_ frame: MapHomePlaybackDriverFrame) {
            guard map != nil, let size = viewSize, let coordinate = frame.coordinate else { return }
            // 재생 중 손으로 돌린 방향은 엔진에서 읽어 이어 간다.
            let heading = (sampleProjection() ?? projection)?.heading ?? 0
            move(to: Target(center: coordinate, distance: frame.cameraDistance, heading: heading))
            let predicted = MapHomeKakaoProjection(center: coordinate, cameraDistance: frame.cameraDistance, heading: heading, size: size)
            projection = predicted
            parent.onPlaybackStickmanPoint(predicted.point(for: coordinate))
            let now = uptime
            let publishes = now - lastPlaybackViewportUptime >= Self.playbackViewportInterval
            // 발자국 레이어는 지도와 같은 틱에 옮기고, SwiftUI로 가는 뷰포트만 60Hz로 묶는다.
            guard publishes || !markerLayer.isEmpty else { return }
            let points = markerPoints(in: predicted)
            markerLayer.apply(points: points, at: parent.playbackDriver.map {
                $0.inputs.dayStart.addingTimeInterval(frame.minute * 60)
            } ?? .distantFuture)
            guard publishes else { return }
            lastPlaybackViewportUptime = now
            parent.onPlaybackViewport(viewport(of: predicted, markerPoints: points))
        }

        private func updateMarkerLayer() {
            guard let container else { return }
            let host = markerLayer.host
            if host.superlayer == nil, !parent.layerPawprints.isEmpty {
                host.contentsScale = container.traitCollection.displayScale
                container.layer.addSublayer(host)
            }
            if host.frame != container.bounds { host.frame = container.bounds }
            markerLayer.update(parent.layerPawprints)
            if markerLayer.isEmpty { host.removeFromSuperlayer() }
        }

        // MARK: 카카오 지도 알림

        /// 알림이 어느 스레드로 오는지 문서에 없어 메인으로 옮겨 받는다.
        private nonisolated func onMain(_ work: @escaping @MainActor @Sendable () -> Void) {
            if Thread.isMainThread {
                MainActor.assumeIsolated(work)
            } else {
                Task { @MainActor in work() }
            }
        }

        nonisolated func cameraWillMove(kakaoMap: KakaoMap, by: MoveBy) {
            onMain { self.cameraMoved(isMoving: true, by: by) }
        }

        nonisolated func cameraDidStopped(kakaoMap: KakaoMap, by: MoveBy) {
            onMain { self.cameraMoved(isMoving: false, by: by) }
        }

        private func cameraMoved(isMoving: Bool, by: MoveBy) {
            guard parent.playbackDriver == nil else { return }
            isCameraMoving = isMoving
            if isMoving, by != .notUserAction { unverifiedTarget = nil }
            // 두 번 누르기·두 손가락 누르기·한 손가락 확대는 우리 인식기가 보지 못한다.
            let tapZooms: [MoveBy] = [.doubleTapZoomIn, .twoFingerTapZoomOut, .oneFingerZoom]
            if isMoving, tapZooms.contains(by) { parent.onUserCameraGesture() }
            startLink(settlingFor: 0.1)
        }

        /// 변환 점검(기기 로그): 카카오가 알려 준 누른 자리와 우리 계산이 몇 pt 어긋나는지 한 번 남긴다.
        nonisolated func terrainDidTapped(kakaoMap: KakaoMap, position: MapPoint) {
            let tapped = position.wgsCoord
            let latitude = tapped.latitude, longitude = tapped.longitude
            onMain {
                self.lastTerrainTap = (CLLocationCoordinate2D(latitude: latitude, longitude: longitude), self.uptime)
                self.logProjectionCheckIfReady()
            }
        }

        private func logProjectionCheckIfReady() {
            guard !hasLoggedProjectionCheck, let projection, let tap = lastTap, let terrain = lastTerrainTap,
                  abs(tap.uptime - terrain.uptime) < 1 else { return }
            hasLoggedProjectionCheck = true
            let point = projection.point(for: terrain.coordinate)
            TaptionPlanDiagnosticsLogger.shared.record("kakao_map_projection_check", fields: [
                "error_pt": String(format: "%.1f", hypot(point.x - tap.point.x, point.y - tap.point.y)),
                "height_ratio": String(format: "%.3f", heightPerVisibleMeter),
                "rotation_sign": String(format: "%.0f", rotationSign),
            ])
        }

        // MARK: 손가락

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // 누르기·길게 누르기끼리만 순서를 지키고, 나머지는 함께 인식한다.
            !(isPressGesture(gestureRecognizer) && isPressGesture(otherGestureRecognizer))
        }

        private func isPressGesture(_ gesture: UIGestureRecognizer) -> Bool {
            gesture === longPressGesture || gesture === singleTapGesture || gesture === doubleTapGesture
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard gestureRecognizer === longPressGesture || gestureRecognizer === singleTapGesture,
                  let view = gestureRecognizer.view else { return true }
            return MapHomeLongPressRoutingMath.shouldPresentLocation(
                at: touch.location(in: view), excluding: parent.longPressExclusionFrame)
        }

        @objc private func handleMotionGesture(_ gesture: UIGestureRecognizer) {
            let ended = gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed
            if gesture.state == .began { unverifiedTarget = nil }
            // 시작할 때와 손을 뗀 뒤의 미끄러짐까지 화면을 읽는다.
            if gesture.state == .began || ended { startLink(settlingFor: 0.3) }
            if gesture is UIPanGestureRecognizer {
                if gesture.state == .began, gesture.numberOfTouches == 1 {
                    parent.onSingleFingerPanBegan()
                } else if ended {
                    parent.onSingleFingerPanEnded()
                }
            } else if gesture.state == .began {
                parent.onUserCameraGesture()
            }
        }

        @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard let map, let container, let point = MapHomeMapGestures.longPressPoint(gesture, in: container) else { return }
            let position = map.getPosition(point).wgsCoord
            let coordinate = CLLocationCoordinate2D(latitude: position.latitude, longitude: position.longitude)
            guard CLLocationCoordinate2DIsValid(coordinate) else { return }
            parent.onLongPress(coordinate)
        }

        @objc private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let container else { return }
            let point = gesture.location(in: container)
            var points: [String: CGPoint] = [:]
            if let current = sampleProjection() ?? projection {
                for marker in parent.markers { points[marker.id] = current.point(for: marker.coordinate) }
            }
            lastTap = (point, uptime)
            logProjectionCheckIfReady()
            parent.onSingleTap(point, points)
        }

        // MARK: 경로선

        /// 벡터 지도와 같은 네 묶음(지난 경로·지하철·실제·예상)을 같은 순서로 쌓는다. 바뀐 묶음만 다시 그린다.
        private func updateRoutes() {
            guard let map else { return }
            let manager = map.getRouteManager()
            let actual = MapHomeWBSTripStyle.actualRouteLineWidth
            let transit = (hex: MapHomeWBSTripStyle.transitRouteHex, opacity: MapHomeWBSTripStyle.actualRouteOpacity)
            let groups: [(id: String, routes: [MapHomeVectorRoute], width: CGFloat, dotted: Bool, fixed: (hex: String, opacity: Double)?)] = [
                (id: "historical", routes: parent.historicalRoutes, width: actual, dotted: false, fixed: nil),
                (id: "subway", routes: parent.subwayRoutes, width: actual, dotted: false, fixed: transit),
                (id: "active", routes: (parent.activeRoute.map { [$0] } ?? []) + parent.activeRouteSegments, width: actual, dotted: false, fixed: nil),
                (id: "expected", routes: parent.expectedRoutes, width: MapHomeWBSTripStyle.forecastRouteLineWidth, dotted: true, fixed: nil),
            ]
            for (order, group) in groups.enumerated() {
                let key = group.routes.map(\.contentKey)
                guard drawnRouteKeys[group.id] != key,
                      let layer = manager.getRouteLayer(layerID: group.id) ?? manager.addRouteLayer(layerID: group.id, zOrder: order)
                else { continue }
                drawnRouteKeys[group.id] = key
                layer.clearAllRoutes()
                // 색 하나에 스타일 하나. 같은 색 구간은 한 경로로 묶는다.
                var segments: [String: [RouteSegment]] = [:], styleOrder: [String] = []
                for route in group.routes where route.coordinates.count >= 2 {
                    let styleID = routeStyleID(hex: group.fixed?.hex ?? route.colorHex, opacity: group.fixed?.opacity ?? route.opacity,
                                               width: group.width, dotted: group.dotted, manager: manager)
                    if segments[styleID] == nil { styleOrder.append(styleID) }
                    let points = route.coordinates.map { MapPoint(longitude: $0.longitude, latitude: $0.latitude) }
                    segments[styleID, default: []].append(RouteSegment(points: points, styleIndex: 0))
                }
                for (index, styleID) in styleOrder.enumerated() {
                    let option = RouteOptions(routeID: "\(group.id)-\(index)", styleID: styleID, zOrder: index)
                    option.segments = segments[styleID] ?? []
                    layer.addRoute(option: option)?.show()
                }
            }
        }

        /// 카카오 경로선 굵기는 화소로 본다(문서에 단위가 없다). 예상 경로는 점선 대신 옅은 선 위에 점 무늬를 놓는다.
        private func routeStyleID(hex: String, opacity: Double, width: CGFloat, dotted: Bool, manager: RouteManager) -> String {
            let alpha = min(max(opacity, 0), 1)
            let id = "\(hex)|\(Int((alpha * 100).rounded()))|\(dotted ? "dot" : "line")"
            guard routeStyleIDs.insert(id).inserted else { return id }
            let scale = container?.traitCollection.displayScale ?? 3
            let color = UIColor(Color(hex: hex))
            let styleSet = RouteStyleSet(styleID: id)
            if dotted {
                let period = MapHomeWBSTripStyle.routeDash.reduce(0) { $0 + CGFloat(truncating: $1) } * width
                styleSet.addPattern(RoutePattern(pattern: Self.dot(color.withAlphaComponent(alpha), diameter: width * 2),
                                                 distance: Float(period * scale), symbol: nil, pinStart: false, pinEnd: false))
            }
            styleSet.addStyle(RouteStyle(styles: [PerLevelRouteStyle(
                width: UInt(max(1, (width * scale).rounded())),
                color: color.withAlphaComponent(dotted ? alpha * 0.35 : alpha),
                level: 0,
                patternIndex: dotted ? 0 : -1
            )]))
            manager.addRouteStyleSet(styleSet)
            return id
        }

        private static func dot(_ color: UIColor, diameter: CGFloat) -> UIImage {
            let size = CGSize(width: diameter, height: diameter)
            return UIGraphicsImageRenderer(size: size).image { context in
                color.setFill()
                context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
            }
        }
    }
}
