import CoreLocation
import SwiftUI
import TaptionPlanCore
import XCTest
@testable import TaptionPlan

/// OPT1102A01: 재생 분이 나아가도 고정 레이어(발자국·장소 핀·안개 출처·집 땅·구역) 입력과 generation이 그대로다.
@MainActor
final class MapHomePlaybackStaticLayersTests: XCTestCase {
    private let dayStart = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func waypoints() -> [MapHomeView.PawprintWaypoint] {
        let route = MapPredictedRoute(
            source: "gps-gap", travelID: nil, mode: .walking,
            span: TimeSpan(start: dayStart, end: dayStart.addingTimeInterval(600)),
            coordinates: [
                GeoPoint(latitude: 37, longitude: 127, altitude: 0, horizontalAccuracy: -1, verticalAccuracy: -1),
                GeoPoint(latitude: 37.001, longitude: 127.001, altitude: 0, horizontalAccuracy: -1, verticalAccuracy: -1),
            ]
        )
        var result: [MapHomeView.PawprintWaypoint] = []
        for index in 0..<6 {
            // 일부러 번호와 시각 순서를 어긋나게 둔다.
            let slot = Double((index * 5) % 6)
            let latitude = 37 + Double(index) * 0.001
            result.append(MapHomeView.PawprintWaypoint(
                index: index,
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: 127),
                angle: Double(index * 10),
                isPredicted: false,
                timestamp: dayStart.addingTimeInterval(slot * 600),
                speedMetersPerSecond: Double(index)
            ))
        }
        result.append(MapHomeView.PawprintWaypoint(
            index: 6, coordinate: CLLocationCoordinate2D(latitude: 37.5, longitude: 127.5),
            angle: 0, isPredicted: true, timestamp: nil, predictedRoute: route
        ))
        return result
    }

    private func visibleIndices(_ all: [MapHomeView.PawprintWaypoint], at date: Date) -> Set<Int> {
        Set(all.filter { $0.timestamp.map { $0 <= date } ?? true }.map(\.index))
    }

    func testAdvancingPlaybackMinuteKeepsPawprintSnapshotGenerationAndLayerArray() {
        let cache = MapHomePlaybackStaticLayerCache()
        let all = waypoints()
        let first = cache.pawprints(all, highlightedTimestamp: nil, selectedPredictedRouteID: nil)
        let firstLayer = cache.layerPawprints(for: first)
        // 분 알림마다 부모가 다시 평가해도 같은 입력이면 같은 generation·같은 레이어 배열이다.
        for minute in stride(from: 0.0, through: 60, by: 7.5) {
            let next = cache.pawprints(all, highlightedTimestamp: nil, selectedPredictedRouteID: nil)
            XCTAssertEqual(next.generation, first.generation, "minute \(minute)")
            XCTAssertEqual(next.key, first.key)
            XCTAssertEqual(cache.layerPawprints(for: next), firstLayer)
            // 드러나는 발자국은 분에 따라 바뀌지만 묶음 밖(색인)에서만 바뀐다.
            let date = dayStart.addingTimeInterval(minute * 60)
            XCTAssertEqual(Set(next.revealIndex.visible(at: date).map(\.index)), visibleIndices(all, at: date))
        }
        XCTAssertEqual(firstLayer.map(\.id), first.drawOrder.map { "pawprint-\($0.index)" })
        XCTAssertEqual(first.drawOrder.first?.isPredicted, true, "예상 경로 발자국이 먼저 그려진다")
    }

    func testPawprintSnapshotChangesOnlyWhenContentOrSelectionChanges() {
        let cache = MapHomePlaybackStaticLayerCache()
        var all = waypoints()
        let base = cache.pawprints(all, highlightedTimestamp: nil, selectedPredictedRouteID: nil)
        let highlighted = cache.pawprints(all, highlightedTimestamp: all[2].timestamp, selectedPredictedRouteID: nil)
        XCTAssertGreaterThan(highlighted.generation, base.generation)
        XCTAssertTrue(cache.layerPawprints(for: highlighted)
            .contains { $0.id == "pawprint-2" && $0.glyph.isSelected })
        all.removeLast()
        let removed = cache.pawprints(all, highlightedTimestamp: all[2].timestamp, selectedPredictedRouteID: nil)
        XCTAssertGreaterThan(removed.generation, highlighted.generation)
        XCTAssertEqual(cache.layerPawprints(for: removed).count, all.count)
    }

    func testRevealIndexMatchesFilterAtEveryBoundary() {
        let all = waypoints()
        let index = MapHomePawprintRevealIndex(all)
        for step in -1...7 {
            let date = dayStart.addingTimeInterval(Double(step) * 600)
            XCTAssertEqual(Set(index.visible(at: date).map(\.index)), visibleIndices(all, at: date), "step \(step)")
            XCTAssertEqual(index.revealedCount(at: date), visibleIndices(all, at: date).count)
        }
    }

    func testHomeLandContentIsCachedBySeasonAndIgnoresMinute() {
        let cache = MapHomePlaybackStaticLayerCache()
        var season = MapHomeGrowthSeason(year: 2026)
        season.landPlots = ["a", "b"]
        season.landPlotPlacements = [MapHomeGrowthPlotPlacement(plotID: "a", x: 0, y: 0)]
        let first = cache.land(season: season)
        XCTAssertEqual(first.placements.count, 1)
        XCTAssertFalse(first.candidates.isEmpty, "붙일 땅이 남아 있으면 후보 칸이 있다")
        XCTAssertEqual(cache.land(season: season), first)
        season.landPlotPlacements?.append(MapHomeGrowthPlotPlacement(plotID: "b", x: 1, y: 0))
        let placedAll = cache.land(season: season)
        XCTAssertTrue(placedAll.candidates.isEmpty)
    }

    func testStaticLayerViewsCompareContentNotScreenPosition() {
        let content = MapHomeHomeLandContent(season: MapHomeGrowthSeason(year: 2026))
        // 집 핀 위치·방위는 밖에서 옮기므로 비교 대상이 아니다. 칸 크기(줌)만 본다.
        let grid = MapHomeHomeLandGrid(content: content, cell: 40, attachLabel: "x", onPlace: { _, _ in })
        XCTAssertEqual(grid, MapHomeHomeLandGrid(content: content, cell: 40, attachLabel: "x", onPlace: { _, _ in }))
        XCTAssertNotEqual(grid, MapHomeHomeLandGrid(content: content, cell: 41, attachLabel: "x", onPlace: { _, _ in }))
        XCTAssertEqual(
            MapHomePlaceZoneRings(radiusMeters: 100, metersPerPoint: 2),
            MapHomePlaceZoneRings(radiusMeters: 100, metersPerPoint: 2)
        )
        XCTAssertNotEqual(
            MapHomePlaceZoneRings(radiusMeters: 100, metersPerPoint: 2),
            MapHomePlaceZoneRings(radiusMeters: 100, metersPerPoint: 3)
        )
    }

    func testPlacePinItemIgnoresCoordinateAndCallback() {
        let id = UUID()
        func place(latitude: Double, action: MapHomeStickmanAction = .activity) -> MapHomePlaceAnnotation {
            MapHomePlaceAnnotation(
                id: id, name: "집", floor: 1, destination: .home, growthLevel: 3, isLeapDay: false,
                growthStatus: nil, isGrowthQualifiedToday: false, growthStreak: 0, pendingWeeklyRewards: 0,
                isCatAtHome: true, catAction: action, equippedAccessoryID: nil,
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: 127)
            )
        }
        let pin = MapHomePlacePinItem(place: place(latitude: 37), language: .korean, onOpenDaySummary: {})
        XCTAssertEqual(pin, MapHomePlacePinItem(place: place(latitude: 37.01), language: .korean, onOpenDaySummary: {}))
        XCTAssertNotEqual(pin, MapHomePlacePinItem(place: place(latitude: 37), language: .english, onOpenDaySummary: {}))
        let otherAction = MapHomeStickmanAction.allCases.first { $0 != .activity } ?? .activity
        if otherAction != .activity {
            XCTAssertNotEqual(pin, MapHomePlacePinItem(place: place(latitude: 37, action: otherAction),
                                                       language: .korean, onOpenDaySummary: {}))
        }
    }

    func testPawprintStyleMatchesSelectionRules() {
        let all = waypoints()
        XCTAssertTrue(MapHomePawprintStyle.isSelected(all[1], highlightedTimestamp: all[1].timestamp))
        XCTAssertFalse(MapHomePawprintStyle.isSelected(all[6], highlightedTimestamp: nil), "예상 발자국은 선택 표시가 없다")
        let routeID = all[6].predictedRoute?.id
        XCTAssertEqual(MapHomePawprintStyle.color(all[6], selectedPredictedRouteID: routeID), .orange)
        XCTAssertNotEqual(MapHomePawprintStyle.color(all[6], selectedPredictedRouteID: nil), .orange)
    }
}
