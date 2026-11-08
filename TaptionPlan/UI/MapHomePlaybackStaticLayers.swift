import CoreLocation
import SwiftUI

// 재생 프레임 평가(최대 60Hz)에서 고정 레이어(발자국·장소 핀·안개 출처·집 땅·구역)를 떼어 낸다(OPT1102A01).
// 내용은 부모 평가(분 알림, 0.25초 간격)에서 한 번 만든 불변 값이고, 재생 분은 열쇠에 들어가지 않는다.
// 프레임 평가는 화면 좌표만 옮기고, 내용 뷰는 `Equatable`로 비교돼 같으면 다시 평가하지 않는다.

/// 발자국 내용의 열쇠. 드러나는 시각은 레이어(`revealsAt`)와 `MapHomePawprintRevealIndex`가 프레임마다 본다.
struct MapHomePawprintLayerKey: Hashable {
    let content: Int
    let count: Int
    let highlightedTimestamp: Date?
    let selectedPredictedRouteID: String?

    init(waypoints: [MapHomeView.PawprintWaypoint], highlightedTimestamp: Date?, selectedPredictedRouteID: String?) {
        var hasher = Hasher()
        for waypoint in waypoints {
            hasher.combine(waypoint.index)
            hasher.combine(waypoint.coordinate.latitude)
            hasher.combine(waypoint.coordinate.longitude)
            hasher.combine(waypoint.angle)
            hasher.combine(waypoint.isPredicted)
            hasher.combine(waypoint.timestamp)
            hasher.combine(waypoint.speedMetersPerSecond)
            hasher.combine(waypoint.predictedRoute?.id)
        }
        content = hasher.finalize()
        count = waypoints.count
        self.highlightedTimestamp = highlightedTimestamp
        self.selectedPredictedRouteID = selectedPredictedRouteID
    }
}

/// `pawprintImage`와 코디네이터 레이어가 함께 쓰는 발자국 색·선택 판정.
enum MapHomePawprintStyle {
    static func isSelected(_ waypoint: MapHomeView.PawprintWaypoint, highlightedTimestamp: Date?) -> Bool {
        !waypoint.isPredicted && waypoint.timestamp != nil && waypoint.timestamp == highlightedTimestamp
    }

    static func color(_ waypoint: MapHomeView.PawprintWaypoint, selectedPredictedRouteID: String?) -> Color {
        if waypoint.isPredicted, let route = waypoint.predictedRoute, route.id == selectedPredictedRouteID {
            return .orange
        }
        return waypoint.isPredicted
            ? MapHomePawprintSpeedColor.unconfirmedColor(forMetersPerSecond: waypoint.speedMetersPerSecond)
            : MapHomePawprintSpeedColor.color(forMetersPerSecond: waypoint.speedMetersPerSecond)
    }
}

/// 재생 시각까지 드러난 발자국. 예전에는 프레임마다 하루치 발자국 전체를 시각으로 걸렀다.
struct MapHomePawprintRevealIndex {
    /// 시각이 없는 발자국(예상 경로)은 늘 보인다.
    private let untimed: [MapHomeView.PawprintWaypoint]
    /// 시각 순서.
    private let timed: [MapHomeView.PawprintWaypoint]

    init(_ waypoints: [MapHomeView.PawprintWaypoint]) {
        untimed = waypoints.filter { $0.timestamp == nil }
        timed = waypoints.filter { $0.timestamp != nil }
            .enumerated()
            .sorted { ($0.element.timestamp!, $0.offset) < ($1.element.timestamp!, $1.offset) }
            .map(\.element)
    }

    func revealedCount(at date: Date) -> Int {
        var lower = 0, upper = timed.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if timed[middle].timestamp! <= date { lower = middle + 1 } else { upper = middle }
        }
        return untimed.count + lower
    }

    /// `playbackVisibleWaypoints`와 같은 집합(순서는 시각 순서). 안개처럼 순서가 상관없는 곳만 쓴다.
    func visible(at date: Date) -> [MapHomeView.PawprintWaypoint] {
        untimed + timed.prefix(revealedCount(at: date) - untimed.count)
    }
}

/// 한 번 만든 발자국 묶음. 내용이 바뀔 때만 `generation`이 오른다.
struct MapHomePawprintLayerSnapshot {
    let generation: Int
    let key: MapHomePawprintLayerKey
    /// 예상 경로 먼저, 그다음 번호순(SwiftUI 오버레이가 그리는 순서).
    let drawOrder: [MapHomeView.PawprintWaypoint]
    let revealIndex: MapHomePawprintRevealIndex
}

/// 집 땅 칸. 시즌 자료가 같으면 같은 값이라 프레임 평가에서 후보 칸을 다시 구하지 않는다.
struct MapHomeHomeLandContent: Equatable {
    struct Cell: Equatable {
        let x: Int
        let y: Int
    }

    let placements: [MapHomeGrowthPlotPlacement]
    let candidates: [Cell]

    init(season: MapHomeGrowthSeason) {
        let placements = season.landPlotPlacements ?? []
        let nextPlot = season.landPlots.first { id in !placements.contains { $0.plotID == id } }
        self.placements = placements
        candidates = nextPlot == nil ? [] : MapHomeGrowthPolicy.placementCandidates(in: season).map { Cell(x: $0.x, y: $0.y) }
    }
}

/// 등록지점 범위를 그릴 장소.
struct MapHomePlaceZoneItem: Equatable, Identifiable {
    let id: UUID
    let radiusMeters: Double
}

/// 재생 분과 무관한 고정 레이어 입력. 부모 평가에서 만들어 프레임 평가 클로저가 그대로 쓴다.
struct MapHomePlaybackStaticLayers {
    let pawprints: MapHomePawprintLayerSnapshot
    let land: MapHomeHomeLandContent?
    let zones: [MapHomePlaceZoneItem]
}

/// 고정 레이어 캐시. 관찰되지 않는다(`MapHomeMemo`처럼 평가 중에 채운다).
@MainActor
final class MapHomePlaybackStaticLayerCache {
    private(set) var pawprints: MapHomePawprintLayerSnapshot?
    private var layer: (generation: Int, value: [MapHomeLayerPawprint])?
    private var land: (placements: [MapHomeGrowthPlotPlacement]?, plots: [String], content: MapHomeHomeLandContent)?
    private var generation = 0

    func pawprints(
        _ waypoints: [MapHomeView.PawprintWaypoint],
        highlightedTimestamp: Date?,
        selectedPredictedRouteID: String?
    ) -> MapHomePawprintLayerSnapshot {
        let key = MapHomePawprintLayerKey(
            waypoints: waypoints,
            highlightedTimestamp: highlightedTimestamp,
            selectedPredictedRouteID: selectedPredictedRouteID
        )
        if let pawprints, pawprints.key == key { return pawprints }
        generation &+= 1
        let drawOrder = waypoints.sorted {
            $0.isPredicted != $1.isPredicted ? $0.isPredicted : $0.index < $1.index
        }
        let snapshot = MapHomePawprintLayerSnapshot(
            generation: generation,
            key: key,
            drawOrder: drawOrder,
            revealIndex: MapHomePawprintRevealIndex(drawOrder)
        )
        pawprints = snapshot
        return snapshot
    }

    /// 코디네이터 레이어 발자국. 묶음의 generation이 같으면 같은 배열을 돌려준다.
    func layerPawprints(for snapshot: MapHomePawprintLayerSnapshot) -> [MapHomeLayerPawprint] {
        if let layer, layer.generation == snapshot.generation { return layer.value }
        let value = snapshot.drawOrder.map {
            MapHomeLayerPawprint(
                id: MapHomeView.pawprintMarkerID($0.index),
                color: MapHomePawprintStyle.color($0, selectedPredictedRouteID: snapshot.key.selectedPredictedRouteID),
                isSelected: MapHomePawprintStyle.isSelected($0, highlightedTimestamp: snapshot.key.highlightedTimestamp),
                angleDegrees: $0.angle,
                revealsAt: $0.timestamp
            )
        }
        layer = (snapshot.generation, value)
        return value
    }

    func land(season: MapHomeGrowthSeason) -> MapHomeHomeLandContent {
        if let land, land.placements == season.landPlotPlacements, land.plots == season.landPlots {
            return land.content
        }
        let content = MapHomeHomeLandContent(season: season)
        land = (season.landPlotPlacements, season.landPlots, content)
        return content
    }
}

/// 장소 핀 내용. 위치·좌표·콜백은 비교하지 않아, 지도만 움직인 프레임에는 핀 본문을 다시 평가하지 않는다.
struct MapHomePlacePinItem: View, Equatable {
    let place: MapHomePlaceAnnotation
    let language: MapHomeLanguage
    let onOpenDaySummary: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.language == rhs.language && lhs.place.hasSamePinContent(as: rhs.place)
    }

    var body: some View {
        if place.destination == .user {
            pin(weather: false)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(language.text("\(place.name) 사용자 위치 메뉴", "\(place.name) user location menu"))
        } else if place.destination == .home {
            pin(weather: true)
                .accessibilityAddTraits(.isButton)
        } else {
            pin(weather: false)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(language.text(
                    "\(place.name), 레벨 \(place.floor ?? 1)",
                    "\(place.name), level \(place.floor ?? 1)"
                ))
        }
    }

    /// 탭은 지도 탭에서 위치로 판정한다(두 손가락 핀치가 핀에 막히지 않게).
    private func pin(weather: Bool) -> some View {
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
            weatherBadge: weather ? place.weatherBadge : nil,
            homeSky: weather ? place.homeSky : nil,
            stamp: place.stamp,
            onOpenDaySummary: weather ? onOpenDaySummary : nil
        )
        .fixedSize()
        .allowsHitTesting(false)
    }
}

extension MapHomePlaceAnnotation {
    /// 핀이 그리는 값만 본다(지도 좌표는 위치로만 쓰인다).
    func hasSamePinContent(as other: Self) -> Bool {
        id == other.id && name == other.name && floor == other.floor && destination == other.destination
            && growthLevel == other.growthLevel && isLeapDay == other.isLeapDay && growthStatus == other.growthStatus
            && isGrowthQualifiedToday == other.isGrowthQualifiedToday && growthStreak == other.growthStreak
            && pendingWeeklyRewards == other.pendingWeeklyRewards && isCatAtHome == other.isCatAtHome
            && catAction == other.catAction && equippedAccessoryID == other.equippedAccessoryID
            && weatherBadge == other.weatherBadge && Self.sameSky(homeSky, other.homeSky) && stamp == other.stamp
    }

    private static func sameSky(_ lhs: MapHomeHomeSkyInput?, _ rhs: MapHomeHomeSkyInput?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (lhs?, rhs?):
            lhs.coordinate.latitude == rhs.coordinate.latitude && lhs.coordinate.longitude == rhs.coordinate.longitude
                && lhs.selectedDay == rhs.selectedDay && lhs.progress === rhs.progress
                && lhs.isPlaybackRunning == rhs.isPlaybackRunning
        default: false
        }
    }
}

/// 등록지점 범위 고리. 빨간 원은 반경, 주황 두 원은 ±15% 히스테리시스 구간. 줌이 같으면 다시 평가하지 않는다.
struct MapHomePlaceZoneRings: View, Equatable {
    let radius: CGFloat
    let inner: CGFloat
    let outer: CGFloat

    init(radiusMeters: Double, metersPerPoint: Double) {
        radius = CGFloat(radiusMeters / metersPerPoint)
        outer = CGFloat(radiusMeters * (1 + MapHomePlaceZone.band) / metersPerPoint)
        inner = CGFloat(radiusMeters * (1 - MapHomePlaceZone.band) / metersPerPoint)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.orange.opacity(0.85), lineWidth: 1.5)
                .frame(width: outer * 2, height: outer * 2)
            Circle()
                .stroke(Color.orange.opacity(0.85), lineWidth: 1.5)
                .frame(width: inner * 2, height: inner * 2)
            Circle()
                .stroke(Color.red, lineWidth: 2)
                .frame(width: radius * 2, height: radius * 2)
        }
    }
}

/// 집 땅 칸 묶음. 집 핀 위치·지도 방위는 밖에서 옮기고 돌리므로, 칸 크기와 내용이 같으면 다시 평가하지 않는다.
struct MapHomeHomeLandGrid: View, Equatable {
    let content: MapHomeHomeLandContent
    let cell: CGFloat
    let attachLabel: String
    let onPlace: (Int, Int) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.content == rhs.content && lhs.cell == rhs.cell && lhs.attachLabel == rhs.attachLabel
    }

    var body: some View {
        ZStack {
            ForEach(content.placements) { placement in
                RoundedRectangle(cornerRadius: cell * 0.14, style: .continuous)
                    .fill(Color.tpPastelMint.opacity(0.55))
                    .overlay {
                        RoundedRectangle(cornerRadius: cell * 0.14, style: .continuous)
                            .stroke(Color.tpReferenceMint.opacity(0.7), lineWidth: 1)
                    }
                    .frame(width: cell - 2, height: cell - 2)
                    .offset(x: CGFloat(placement.x) * cell, y: CGFloat(placement.y) * cell)
                    .allowsHitTesting(false)
            }
            ForEach(Array(content.candidates.enumerated()), id: \.offset) { _, candidate in
                Button {
                    onPlace(candidate.x, candidate.y)
                } label: {
                    RoundedRectangle(cornerRadius: cell * 0.14, style: .continuous)
                        .strokeBorder(Color.tpAccent.opacity(0.8), style: StrokeStyle(lineWidth: 1.4, dash: [5, 4]))
                        .background(Color.tpAccent.opacity(0.06), in: RoundedRectangle(cornerRadius: cell * 0.14, style: .continuous))
                        .overlay {
                            Image(systemName: "plus")
                                .font(.system(size: min(20, cell * 0.32), weight: .bold))
                                .foregroundStyle(Color.tpAccent)
                        }
                        .frame(width: cell - 2, height: cell - 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .offset(x: CGFloat(candidate.x) * cell, y: CGFloat(candidate.y) * cell)
                .accessibilityLabel(attachLabel)
            }
        }
    }
}

extension MapHomeView {
    nonisolated static func pawprintMarkerID(_ index: Int) -> String { "pawprint-\(index)" }

    /// 부모 평가에서 한 번 만드는 고정 레이어 입력. 재생 분을 읽지 않는다.
    func playbackStaticLayers(waypoints: [PawprintWaypoint]) -> MapHomePlaybackStaticLayers {
        let cache = vectorMapViewportStore.staticLayers
        let season = homeGrowthHistory.season
        return MapHomePlaybackStaticLayers(
            pawprints: cache.pawprints(
                waypoints,
                highlightedTimestamp: highlightedPawprintTimestamp,
                selectedPredictedRouteID: selectedPredictedRoute?.id
            ),
            land: MapHomeLandFeature.isVisible ? cache.land(season: season) : nil,
            zones: showsPlaceRanges
                ? model.settings.frequentPlaces.filter { $0.point != nil }
                    .map { MapHomePlaceZoneItem(id: $0.id, radiusMeters: $0.radiusMeters) }
                : []
        )
    }

    /// 구동기 재생 중에는 발자국을 지도 코디네이터 레이어가 그린다. SwiftUI 오버레이는 발자국을 비교하지 않는다.
    func playbackLayerPawprints(_ statics: MapHomePlaybackStaticLayers) -> [MapHomeLayerPawprint] {
        guard playbackDriver != nil, recordingShows(\.footprints), !Self.benchHidden("paws") else { return [] }
        return vectorMapViewportStore.staticLayers.layerPawprints(for: statics.pawprints)
    }

    /// 안개가 걷어낼 발자국. 재생 중에는 색인으로 재생 시각까지만 고른다.
    func playbackFogWaypoints(_ statics: MapHomePlaybackStaticLayers) -> [PawprintWaypoint] {
        guard let driver = playbackDriver else { return statics.pawprints.drawOrder }
        return statics.pawprints.revealIndex.visible(at: driver.inputs.dayStart.addingTimeInterval(driver.minute * 60))
    }
}
