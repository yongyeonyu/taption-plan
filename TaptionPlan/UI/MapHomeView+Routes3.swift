import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

extension MapHomeView {
    func prepareRouteProjectionReadings() {
        guard scenePhase == .active else { return }
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: model.selectedDate)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(24 * 60 * 60)
        let preparationSignature = [
            String(dayStart.timeIntervalSinceReferenceDate),
            String(model.dayProjectionRevision),
            String(transitBoardingReadingsRevision),
            String(routeReadings.count),
            routeReadings.last?.id.uuidString ?? "none",
            String(model.liveRouteState.readings.count),
            model.liveRouteState.readings.last?.id.uuidString ?? "none",
            model.liveRouteState.lastUpdatedAt.map {
                String($0.timeIntervalSinceReferenceDate)
            } ?? "none",
            model.latestSensorReading?.id.uuidString ?? "none",
            model.latestSensorReading.map {
                String($0.timestamp.timeIntervalSinceReferenceDate)
            } ?? "none",
            MapHomeRouteReadingsPreparation.latestRouteInputSignature(
                model.latestSensorReading
            ),
        ].joined(separator: "|")
        guard preparationSignature != lastPreparedRouteReadingsSignature else {
            if routeReadingsPreparationTask == nil {
                requestWBSPlaybackProjectionRefresh()
            }
            return
        }
        lastPreparedRouteReadingsSignature = preparationSignature
        routeReadingsPreparationTask?.cancel()
        let preparationID = routeReadingsPreparationGeneration.advance()
        let routeReadingsSnapshot = routeReadings
        let liveReadingsSnapshot = model.liveRouteState.readings
        let latestReading = model.latestSensorReading
        routeReadingsPreparationTask = Task { @MainActor in
            let worker = Task.detached(priority: .utility) {
                try MapHomeRouteReadingsPreparation.prepare(
                    routeReadings: routeReadingsSnapshot,
                    liveReadings: liveReadingsSnapshot,
                    latestReading: latestReading,
                    dayStart: dayStart,
                    dayEnd: dayEnd,
                    cancellationCheck: { try Task.checkCancellation() }
                )
            }
            let prepared: MapHomePreparedRouteReadings
            do {
                prepared = try await withTaskCancellationHandler(
                    operation: { try await worker.value },
                    onCancel: { worker.cancel() }
                )
            } catch {
                worker.cancel()
                guard routeReadingsPreparationGeneration.accepts(preparationID) else {
                    return
                }
                routeReadingsPreparationTask = nil
                lastPreparedRouteReadingsSignature = nil
                return
            }
            guard !Task.isCancelled,
                  routeReadingsPreparationGeneration.accepts(preparationID),
                  lastPreparedRouteReadingsSignature == preparationSignature,
                  scenePhase == .active else { return }
            normalizedRouteReadings = prepared.normalized
            if currentMapLocationReading != prepared.latestTrustedReading {
                currentMapLocationReading = prepared.latestTrustedReading
            }
            historicalPlaybackReadings = prepared.normalized
            displayRouteReadings = prepared.display
            routeReadingsPreparationTask = nil
            TaptionPlanDiagnosticsLogger.shared.record(
                "map_route_readings_prepared",
                fields: [
                    "day_start": String(dayStart.timeIntervalSince1970),
                    "source_readings": String(prepared.sourceCount),
                    "impossible_location_count": String(prepared.impossibleLocationCount),
                    "innovation_outlier_count": String(prepared.innovationOutlierCount),
                    "filtered_readings": String(prepared.filteredCount),
                    "normalized_readings": String(prepared.normalized.count),
                    "display_readings": String(prepared.display.count),
                    "watch_source_readings": String(prepared.watchSourceCount),
                    "readings_with_point": String(prepared.readingsWithPointCount),
                    "readings_rail_match": String(prepared.railMatchCount),
                    "readings_station_name": String(prepared.stationNameCount),
                ].merging(
                    MapHomeRouteJumpDiagnostics.fields(for: prepared.display),
                    uniquingKeysWith: { first, _ in first }
                )
            )
            requestRouteProjectionRefresh()
            requestWBSPlaybackProjectionRefresh()
            scheduleExpectedRouteRefresh()
        }
    }

    /// 예상 경로 요청을 만드는 쪽과 같은 하루 범위를 쓴다. 범위가 어긋나면 같은
    /// 이동 구간이라도 요청 id가 달라져 재생 leg와 화면의 경로가 연결되지 않는다.
    static func routeDaySpan(for date: Date) -> TimeSpan {
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(24 * 60 * 60)
        return TimeSpan(start: start, end: end)
    }

    var mapRouteFitRegion: MKCoordinateRegion? {
        var coordinates = timelineRouteOverlays.flatMap(\.coordinates)
            + displayedExpectedRouteOverlays.flatMap(\.coordinates)
            + displayedWBSGeneratedRouteOverlays.flatMap(\.coordinates)
            + subwayRouteOverlays.flatMap(\.coordinates)
        // 기록이 없는 날: 오늘은 지금 위치, 다른 날은 등록한 집(MAP1110A01).
        if coordinates.isEmpty,
           let fallback = Calendar.autoupdatingCurrent.isDateInToday(model.selectedDate)
               ? currentCoordinate ?? homeCoordinate : homeCoordinate ?? currentCoordinate {
            coordinates = [fallback]
        }
        return MapHomeRouteFitMath.region(for: coordinates)
    }

    /// 배율 숫자를 누르면 이동 경로 전체가 보이도록 배율과 위치를 맞춘다. 따라가기는 멈춘다.
    func fitMapToRoutes() {
        guard !isDayPlaybackRunning, let region = mapRouteFitRegion else { return }
        setUserTrackingMode(.idle)
        isMapCenteredOnUser = false
        hasUserAdjustedMap = true
        setMapPosition(.region(region))
    }

    func focusMapOnAllRoutes() {
        guard MapHomePlaybackCameraPolicy.allowsAutomaticFit(
            isPlaybackRunning: isDayPlaybackRunning,
            hasUserAdjustedMap: hasUserAdjustedMap
        ) else { return }
        guard let region = mapRouteFitRegion else {
            // 그날 GPS 기록이 없으면 서울시청(기본값) 대신 등록한 집을 가운데 둔다(MAP1110A01).
            if let home = homeCoordinate {
                setMapPosition(.camera(MapCamera(centerCoordinate: home, distance: MapHomeStartupCameraPolicy.distance)))
            } else {
                setMapPosition(.automatic)
            }
            return
        }
        setMapPosition(.region(region))
    }
}

extension MapHomeView {
    /// 등록한 집 좌표. 기록이 없는 날의 지도 가운데로 쓴다(MAP1110A01).
    var homeCoordinate: CLLocationCoordinate2D? {
        model.settings.frequentPlaces.first { $0.kind == .home }?.point.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
    }
}
