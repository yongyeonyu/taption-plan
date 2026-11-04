import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

struct MapHomeStartupCameraPolicy {
    /// 시작 화면 배율 85(약 550m)로 연다(대표 지시 ZMP1020A01). 이전에는 3,000m였다.
    static let distance: CLLocationDistance = MapHomeCameraZoomMath.distance(forScale: MapHomePlaybackZoomPolicy.baselineScale)
    static let fallbackCenter = CLLocationCoordinate2D(latitude: 37.5665, longitude: 126.9780)
    private var needsZoomRestore = false

    mutating func shouldRestoreZoom(on phase: ScenePhase) -> Bool {
        if phase == .background { needsZoomRestore = true }
        guard phase == .active else { return false }
        defer { needsZoomRestore = false }
        return needsZoomRestore
    }

    static func camera(restoring camera: MapCamera?, fallbackCenter: CLLocationCoordinate2D) -> MapCamera {
        MapCamera(
            centerCoordinate: camera?.centerCoordinate ?? fallbackCenter,
            distance: distance,
            heading: camera?.heading ?? 0,
            pitch: camera?.pitch ?? 0
        )
    }
}


/// 위치 고르기용 핀: 물방울 모양 몸통과 흰 점, 끝이 닿는 자리에 그림자 타원. 끝이 뷰 아래 가운데에 있다.
struct MapHomePlacementPin: View {
    static let width: CGFloat = 34
    static let height: CGFloat = 46

    var body: some View {
        ZStack(alignment: .bottom) {
            Ellipse()
                .fill(Color.black.opacity(0.22))
                .frame(width: 16, height: 6)
                .blur(radius: 1.5)
                .offset(y: 3)
            // 애플 지도 핀처럼 빨간 몸통에 위쪽 빛과 아래쪽 그늘을 얹어 입체로 보이게 한다.
            MapHomePinShape()
                .fill(
                    LinearGradient(
                        colors: [Color(hex: "#FF6B5E"), Color(hex: "#EA3B2E"), Color(hex: "#B8241B")],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay {
                    MapHomePinShape()
                        .fill(
                            RadialGradient(
                                colors: [.white.opacity(0.45), .clear],
                                center: UnitPoint(x: 0.34, y: 0.16),
                                startRadius: 0,
                                endRadius: Self.width * 0.62
                            )
                        )
                }
                .overlay { MapHomePinShape().stroke(Color.white.opacity(0.92), lineWidth: 1.5) }
                .overlay(alignment: .top) {
                    Circle()
                        .fill(LinearGradient(colors: [.white, Color(hex: "#F1E6E4")], startPoint: .top, endPoint: .bottom))
                        .overlay { Circle().stroke(Color.black.opacity(0.14), lineWidth: 0.5) }
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                        .frame(width: 12, height: 12)
                        .offset(y: Self.width * 0.5 - 6)
                }
                .frame(width: Self.width, height: Self.height)
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        }
        .frame(width: Self.width, height: Self.height)
    }
}

struct MapHomePinShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + w / 2, y: rect.maxY))
        path.addCurve(to: CGPoint(x: rect.minX, y: rect.minY + h * 0.38),
                      control1: CGPoint(x: rect.minX + w * 0.40, y: rect.minY + h * 0.78),
                      control2: CGPoint(x: rect.minX, y: rect.minY + h * 0.62))
        path.addCurve(to: CGPoint(x: rect.minX + w / 2, y: rect.minY),
                      control1: CGPoint(x: rect.minX, y: rect.minY + h * 0.17),
                      control2: CGPoint(x: rect.minX + w * 0.22, y: rect.minY))
        path.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY + h * 0.38),
                      control1: CGPoint(x: rect.minX + w * 0.78, y: rect.minY),
                      control2: CGPoint(x: rect.maxX, y: rect.minY + h * 0.17))
        path.addCurve(to: CGPoint(x: rect.minX + w / 2, y: rect.maxY),
                      control1: CGPoint(x: rect.maxX, y: rect.minY + h * 0.62),
                      control2: CGPoint(x: rect.minX + w * 0.60, y: rect.minY + h * 0.78))
        path.closeSubpath()
        return path
    }
}

/// 지도 데이터·타일 제공자의 출처 표기. 지도 위 (i) 버튼과 같은 내용을 메뉴에서도 보여 준다.
struct MapHomeAttributionSheet: View {
    let language: MapHomeLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(language.text("지도 출처", "Map attribution"))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(20)), weight: .bold))
                .foregroundStyle(Color.tpInk)
            attributionRow("OpenFreeMap", "© OpenMapTiles · Data from OpenStreetMap")
            attributionRow(
                language.text("지도 데이터", "Map data"),
                "© OpenStreetMap contributors (ODbL)"
            )
            attributionRow(language.text("지도 표시", "Map rendering"), "MapLibre Native")
            Link(destination: URL(string: "https://www.openstreetmap.org/copyright")!) {
                Label(language.text("OpenStreetMap 저작권 보기", "OpenStreetMap copyright"), systemImage: "arrow.up.right.square")
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold))
            }
            .tint(Color.tpAccent)
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.tpBackground)
    }

    private func attributionRow(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .bold))
                .foregroundStyle(Color.tpSecondary)
            Text(text)
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .medium))
                .foregroundStyle(Color.tpInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// 설정 > 표시 > 메모: 모두 / 위치 있는 메모만 / 숨김. 시간 메모·시간 없는 메모(왼쪽 위 목록)는 "모두"에서만 보인다.
enum MapHomeMemoDisplayMode: String, CaseIterable, Sendable {
    case all
    case located
    case hidden

    var koreanTitle: String {
        switch self {
        case .all: "모두 표시"
        case .located: "위치 메모만"
        case .hidden: "표시 안 함"
        }
    }

    var englishTitle: String {
        switch self {
        case .all: "Show all"
        case .located: "Located only"
        case .hidden: "Hide"
        }
    }
}

/// 지도 홈 버튼 배치. 하단 탭·떠 있는 독은 재생·녹화·메모·위치·메뉴를 아래 한 곳에 모은다.
enum MapHomeLayoutStyle: String, CaseIterable, Sendable {
    case classic
    case tabBar

    static let storageKey = "mapHomeLayoutStyle"

    var movesActionsToBottom: Bool { self != .classic }

    /// 지도 출처 (i) 버튼이 왼쪽 하단 원형 버튼(높이 44) 바로 위에 오도록 지도 아래에서 띄우는 거리.
    /// 하단 메뉴 높이 + 기준 여백 10 + 버튼 44 + 간격 8.
    static var attributionBottomMargin: CGFloat { MapHomeLayoutStyle.tabBar.bottomReservedHeight + 10 + 44 + 8 }

    /// 하단 막대가 차지하는 높이. 레일과 왼쪽 버튼을 이만큼 위로 올린다.
    var bottomReservedHeight: CGFloat {
        switch self {
        case .classic: 0
        case .tabBar: MapHomeBottomBarMetrics.reservedHeight
        }
    }

    var koreanTitle: String {
        switch self {
        case .classic: "지금"
        case .tabBar: "하단 탭"
        }
    }

    var englishTitle: String {
        switch self {
        case .classic: "Classic"
        case .tabBar: "Bottom tabs"
        }
    }
}

/// 재생 중 지도 배율 방식. 고정이면 재생을 시작할 때의 배율을 그대로 둔다.
enum MapHomePlaybackZoomMode: String, CaseIterable, Sendable {
    case adaptive
    case fixed

    static let storageKey = "mapHomePlaybackZoomMode"

    var koreanTitle: String { self == .fixed ? "현재 배율로 고정" : "속도에 따라 가변" }
    var englishTitle: String { self == .fixed ? "Keep current zoom" : "Vary with speed" }
}


struct MapHomeDayTravelDistanceEntry: Identifiable, Equatable {
    let mode: TravelMode
    let meters: Double
    var id: TravelMode { mode }
}

/// 하루 요약의 이동 수단별 거리. 확인된 수단만 거리가 긴 순서로 보여준다.
enum MapHomeDayTravelSummary {
    static let minimumMeters = 10.0

    static func entries(from segments: [TravelSegment]) -> [MapHomeDayTravelDistanceEntry] {
        var totals: [TravelMode: Double] = [:]
        for segment in segments where segment.distanceMeters.isFinite && segment.distanceMeters > 0 {
            totals[segment.mode, default: 0] += segment.distanceMeters
        }
        return totals
            .filter { $0.value >= minimumMeters }
            .map { MapHomeDayTravelDistanceEntry(mode: $0.key, meters: $0.value) }
            .sorted { $0.meters != $1.meters ? $0.meters > $1.meters : $0.mode.rawValue < $1.mode.rawValue }
    }

    static func distanceText(_ meters: Double) -> String {
        AppRegion.current.distanceText(meters: meters)
    }
}

extension TravelMode {
    var summarySystemImage: String {
        outlineSymbolName
    }

    var summaryKoreanTitle: String {
        switch self {
        case .walking: "걷기"
        case .running: "뛰기"
        case .cycling: "자전거"
        case .bus: "버스"
        case .subway: "지하철"
        case .taxi: "택시"
        case .car: "운전"
        case .train: "기차"
        case .airplane: "비행기"
        case .ship: "배"
        }
    }

    var summaryEnglishTitle: String {
        switch self {
        case .walking: "Walking"
        case .running: "Running"
        case .cycling: "Cycling"
        case .bus: "Bus"
        case .subway: "Subway"
        case .taxi: "Taxi"
        case .car: "Driving"
        case .train: "Train"
        case .airplane: "Flight"
        case .ship: "Ferry"
        }
    }
}


struct AlarmConfirmItem: Identifiable {
    let kind: MapHomeAlarmKind
    let at: Date
    var id: String { "\(kind.rawValue)-\(at.timeIntervalSince1970)" }
}

/// 배경이 밝으면 진한 회색, 어두우면 흰색 글자를 고른다.
func adaptiveLabelColor(on background: Color) -> Color {
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    UIColor(background).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    let luminance = 0.299 * red + 0.587 * green + 0.114 * blue
    return luminance > 0.6 ? Color(white: 0.25) : .white
}


/// 경로 계산 입력 요약. 이 값이 같으면 같은 경로 결과다.
struct RouteProjectionInputKey: Hashable {
    let day: Date
    let sourceRevision: UInt64
    let cutoff: Date
    let selectedStart: Date?
    let selectedEnd: Date?
    let isPlaying: Bool
    let readingCount: Int
    let lastReadingTime: Date?
    let actualCount: Int
    let sleepCount: Int
    let confirmedSleepCount: Int
}

// MARK: - 집 마커 미리보기

#if DEBUG

/// 집 마커 레이아웃 확인용. `-pinPreview` 실행 인자로만 열린다.
/// 홈 화면을 통째로 띄우면 권한 알림에 가려 마커를 볼 수 없어서, 마커만 단독으로
/// 띄우고 화면 가운데 십자선으로 지도 좌표를 표시한다.
struct MapHomePinPreviewHost: View {
    var body: some View {
        ZStack {
            Color(hex: "#6E6A5F").ignoresSafeArea()
            VStack(spacing: 24) {
                ZStack {
                    coordinateCrosshair
                    // 연봉 카운터는 지도 레이어가 따로 그린다. 같은 상수로 흉내 내어
                    // 아바타·날씨 배지와 겹치지 않는지 확인한다.
                    salaryCounterMock
                    marker(showsCatAtHome: true, weather: true)
                }
                hostBoundsSample
            }
        }
    }

    /// Apple 지도가 주석을 담는 상자에 그대로 넣어 본 것. 발광·배지가 밖으로 나가면 잘린다.
    private var hostBoundsSample: some View {
        VStack(spacing: 6) {
            Text("지도 호스트 \(Int(MapHomePlacePinLayout.appleHomeHostWidth))×\(Int(MapHomePlacePinLayout.appleHomeHostHeight))")
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            marker(showsCatAtHome: true, weather: true)
                .frame(width: MapHomePlacePinLayout.appleHomeHostWidth, height: MapHomePlacePinLayout.appleHomeHostHeight)
                .overlay { Rectangle().stroke(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [3, 3])) }
        }
    }

    /// 지도 레이어가 그리는 카운터 창 자리. 좌표(십자선 중심)에서 상수만큼 위.
    ///
    /// 알약을 흉내 내지 않고 **실제 창**을 그대로 얹는다. 연봉이 표의 마지막 줄로 들어간 뒤
    /// 폭(176pt)과 줄맞춤이 지도와 같은지 여기서 눈으로 본다.
    private var salaryCounterMock: some View {
        MapHomeCounterTable(
            salary: MapHomeCounterSalary(text: "1,234,567원", isWorking: true),
            badges: [
                MapHomeCounterBadge(kind: .steps, text: "8,432"),
                MapHomeCounterBadge(kind: .distance, text: "4.2km"),
                MapHomeCounterBadge(kind: .work, text: "3시간 12분"),
                MapHomeCounterBadge(kind: .study, text: "42분"),
                MapHomeCounterBadge(kind: .hobby, text: "1시간 5분"),
                MapHomeCounterBadge(kind: .exercise, text: "25분"),
            ],
            language: .korean
        )
        .frame(width: 240, height: 320, alignment: .bottom)
        .offset(y: MapHomePlacePinLayout.salaryOffsetFromPinCenter - 160)
        .allowsHitTesting(false)
    }

    /// 지도 좌표 자리. 마커의 어느 부분이 좌표에 놓이는지 눈으로 확인한다.
    private var coordinateCrosshair: some View {
        ZStack {
            Rectangle().fill(Color.white.opacity(0.55)).frame(width: 1, height: 260)
            Rectangle().fill(Color.white.opacity(0.55)).frame(width: 260, height: 1)
            Circle().stroke(Color.white.opacity(0.75), lineWidth: 1).frame(width: 10, height: 10)
        }.allowsHitTesting(false)
    }

    /// `-pinPreviewLevel=N`으로 집 그림 단계를 바꿔 본다.
    private var previewLevel: Int {
        ProcessInfo.processInfo.arguments
            .first { $0.hasPrefix("-pinPreviewLevel=") }
            .flatMap { Int($0.dropFirst("-pinPreviewLevel=".count)) } ?? 365
    }

    /// `-pinPreviewMinute=N`으로 하늘 시각을 고정한다. 좌표는 서울시청.
    private var previewSky: MapHomeHomeSkyInput {
        let progress = MapHomePlaybackProgress()
        progress.rawSelectedMinute = ProcessInfo.processInfo.arguments
            .first { $0.hasPrefix("-pinPreviewMinute=") }
            .flatMap { Int($0.dropFirst("-pinPreviewMinute=".count)) }
        return MapHomeHomeSkyInput(
            coordinate: CLLocationCoordinate2D(latitude: 37.5665, longitude: 126.9780),
            selectedDay: .now,
            progress: progress
        )
    }

    private func marker(showsCatAtHome: Bool, weather: Bool) -> some View {
        MapHomePlacePin(
            name: "집", floor: nil, destination: .home, growthLevel: previewLevel,
            isLeapDay: false, growthStatus: "오늘도 채웠어요",
            isGrowthQualifiedToday: true, growthStreak: 12, pendingWeeklyRewards: 1,
            showsCatAtHome: showsCatAtHome, catAction: .activity,
            equippedAccessoryID: "cat.accessory.kr.gyeongbokgung",
            weatherBadge: weather
                ? MapHomeHomeWeatherBadge(
                    symbolName: "cloud.sun.fill", temperatureText: "19°", condition: "구름 조금")
                : nil,
            homeSky: previewSky,
            onOpenDaySummary: {}
        )
        .fixedSize()
    }
}
#endif

/// 발자국 장부 캐시 키.
struct MapHomePawprintLedgerKey: Equatable {
    let day: Date
    let count: Int
    let firstID: UUID?
    let lastID: UUID?
    let excluded: [Double]
}
