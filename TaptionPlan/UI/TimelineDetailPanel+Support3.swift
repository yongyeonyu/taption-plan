import SwiftUI
import UIKit
import MapKit

extension TimelineDetailPanel {
    var isPlayheadLocationOnly: Bool {
        playheadDate != nil
            && routeSegments.isEmpty
            && fallbackRouteCoordinates.count < 2
            && playheadRoutePin != nil
            && !hasDimmedRoutes
    }

    var hasMapContent: Bool {
        playheadRoutePin != nil
            || !routeLocationPins.isEmpty
            || !displayedRouteCoordinates.isEmpty
            || hasDimmedRoutes
    }

    var currentLocationCoordinate: CLLocationCoordinate2D? {
        let point = model.latestSensorReading?.point
            ?? model.liveRouteState.readings.last?.point
        guard let point, isValidCoordinate(point) else { return nil }
        return CLLocationCoordinate2D(
            latitude: point.latitude,
            longitude: point.longitude
        )
    }

    var playheadFocusCoordinate: CLLocationCoordinate2D? {
        guard let playheadDate else { return nil }

        // A GPS fix is the moving source of truth during playback. PlaceStay
        // is only a coarse fallback for gaps in the archived sensor stream.
        let nearestReadingPoint = nearestRouteReadingPoint(
            to: playheadDate,
            inside: activeRouteSpan
        )
        if let point = nearestReadingPoint {
            return CLLocationCoordinate2D(
                latitude: point.latitude,
                longitude: point.longitude
            )
        }

        let place = placeIndexCache.containing(
            date: playheadDate,
            timelineRevision: model.timelineRevision,
            places: model.snapshot.places
        )
        if let place,
           let point = place.point,
           isValidCoordinate(point) {
            return CLLocationCoordinate2D(
                latitude: point.latitude,
                longitude: point.longitude
            )
        }

        return routeSegments
            .filter { $0.span.contains(playheadDate) }
            .compactMap { coordinates(for: $0).first }
            .first
    }

    func nearestRouteReadingPoint(
        to date: Date,
        inside span: TimeSpan
    ) -> GeoPoint? {
        guard !routeReadings.isEmpty else { return nil }

        // sensorReadings(in:) returns chronological data. Restrict the
        // binary search to the active span, then walk outward from the
        // insertion point. This avoids a full filter/min scan of up to 4,000
        // live GPS samples on every 20 Hz playhead update.
        var lower = 0
        var upper = routeReadings.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if routeReadings[middle].timestamp < span.start {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        let firstInSpan = lower
        lower = firstInSpan
        upper = routeReadings.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if routeReadings[middle].timestamp <= span.end {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        let endInSpan = lower
        guard firstInSpan < endInSpan else { return nil }

        lower = firstInSpan
        upper = endInSpan
        while lower < upper {
            let middle = (lower + upper) / 2
            if routeReadings[middle].timestamp < date {
                lower = middle + 1
            } else {
                upper = middle
            }
        }

        var left = lower - 1
        var right = lower
        var bestDistance = TimeInterval.infinity
        var bestPoint: GeoPoint?
        while left >= firstInSpan || right < endInSpan {
            let leftDistance = left >= firstInSpan
                ? abs(routeReadings[left].timestamp.timeIntervalSince(date))
                : .infinity
            let rightDistance = right < endInSpan
                ? abs(routeReadings[right].timestamp.timeIntervalSince(date))
                : .infinity
            if min(leftDistance, rightDistance) > bestDistance {
                break
            }
            if leftDistance <= rightDistance, left >= firstInSpan {
                if let point = routeReadings[left].point,
                   isValidCoordinate(point),
                   leftDistance < bestDistance {
                    bestDistance = leftDistance
                    bestPoint = point
                }
                left -= 1
            } else if right < endInSpan {
                if let point = routeReadings[right].point,
                   isValidCoordinate(point),
                   rightDistance < bestDistance {
                    bestDistance = rightDistance
                    bestPoint = point
                }
                right += 1
            }
        }
        return bestPoint
    }

    var fallbackRouteCoordinates: [CLLocationCoordinate2D] {
        routePresentationCache.fallbackCoordinates(
            for: routePresentationCacheKey,
            span: activeRouteSpan
        ) {
            buildFallbackRouteCoordinates(in: activeRouteSpan)
        }
    }

    func buildFallbackRouteCoordinates(
        in span: TimeSpan
    ) -> [CLLocationCoordinate2D] {
        // Archived readings and the live merge are chronological. Avoid a
        // full sort whenever a new GPS fix invalidates the route cache.
        let readings = routeReadingSlice(in: span)
            .compactMap(\.point)
            .filter(isValidCoordinate)
        let precise = readings.filter {
            $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= 50
        }
        return simplifiedRouteCoordinates(
            precise.count >= 2 ? precise : readings
        )
    }

    /// 기록은 시간 순서대로 쌓여 있다. 구간마다 전체를 훑는 대신 이진
    /// 탐색으로 잘라 낸다. 한 주치 기록에 이동 100개를 그려도 훑는 양이
    /// 기록 수에 비례해 늘지 않는다.
    func routeReadingSlice(
        in span: TimeSpan
    ) -> ArraySlice<SensorReading> {
        guard !routeReadings.isEmpty else { return [] }
        let lower = firstReadingIndex { $0.timestamp >= span.start }
        let upper = firstReadingIndex { $0.timestamp > span.end }
        guard lower < upper else { return [] }
        return routeReadings[lower..<upper]
    }

    func firstReadingIndex(
        where predicate: (SensorReading) -> Bool
    ) -> Int {
        var low = 0
        var high = routeReadings.count
        while low < high {
            let middle = (low + high) / 2
            if predicate(routeReadings[middle]) {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return low
    }

    func simplifiedRouteCoordinates(
        _ points: [GeoPoint]
    ) -> [CLLocationCoordinate2D] {
        RoutePolylineDecimator.decimate(
            RoutePolylineDecimator.spaced(
                points.map {
                    CLLocationCoordinate2D(
                        latitude: $0.latitude,
                        longitude: $0.longitude
                    )
                }
            )
        )
    }

    var displayedRouteCoordinates: [CLLocationCoordinate2D] {
        let segmentCoordinates = routeSegments.flatMap(coordinates(for:))
        if segmentCoordinates.count >= 2 {
            return segmentCoordinates
        }
        guard allowsFallbackRoutePath else { return [] }
        return fallbackRouteCoordinates
    }

    /// 그린 점이 아니라 실제로 받은 위치 수를 센다. 그리기 직전에 점을
    /// 줄이므로 폴리라인 점 수를 그대로 쓰면 20분 걸은 기록이 "GPS 2개"로
    /// 보인다.
    var recordedRouteFixCount: Int {
        let recorded = routeReadingSlice(in: activeRouteSpan)
            .lazy
            .compactMap(\.point)
            .filter(isValidCoordinate)
            .count
        return max(recorded, displayedRouteCoordinates.count)
    }

    var recordedRouteDistanceMeters: Double {
        if !routeSegments.isEmpty {
            return routeSegments.reduce(0) { $0 + $1.distanceMeters }
        }
        return zip(
            displayedRouteCoordinates,
            displayedRouteCoordinates.dropFirst()
        ).reduce(0) { result, pair in
            result + CLLocation(
                latitude: pair.0.latitude,
                longitude: pair.0.longitude
            ).distance(from: CLLocation(
                latitude: pair.1.latitude,
                longitude: pair.1.longitude
            ))
        }
    }

    func routeModeName(_ mode: TravelMode) -> String {
        switch mode {
        case .walking:
            "걷기"
        case .running:
            "달리기"
        case .cycling:
            "자전거"
        case .bus:
            "버스"
        case .subway:
            "지하철"
        case .taxi:
            "택시"
        case .car:
            "자동차"
        case .train:
            "기차"
        case .airplane:
            "비행기"
        case .ship:
            "배"
        }
    }

    func routeModeSystemImage(_ mode: TravelMode) -> String {
        mode.outlineSymbolName
    }

    func isValidCoordinate(_ point: GeoPoint) -> Bool {
        guard point.latitude.isFinite, point.longitude.isFinite else { return false }
        return point.latitude >= -90 && point.latitude <= 90 &&
            point.longitude >= -180 && point.longitude <= 180 &&
            !(point.latitude == 0 && point.longitude == 0)
    }

    func routeCoordinates(
        for segment: TravelSegment,
        includeImprecise: Bool
    ) -> [CLLocationCoordinate2D] {
        var points: [GeoPoint] = []
        if let from = segment.fromPlaceID,
           let point = placeIndexCache.place(
               id: from,
               timelineRevision: model.timelineRevision,
               places: model.snapshot.places
           )?.point,
           isValidCoordinate(point) {
            points.append(point)
        }
        let readings = routeReadingSlice(in: segment.span)
            .compactMap(\.point)
            .filter(isValidCoordinate)
        let preferredReadings = includeImprecise
            ? readings
            : readings.filter {
                $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= 50
            }

        if preferredReadings.count >= 2 || includeImprecise {
            points.append(contentsOf: preferredReadings)
        } else if let first = readings.first {
            points.append(first)
        }

        if let to = segment.toPlaceID,
           let point = placeIndexCache.place(
               id: to,
               timelineRevision: model.timelineRevision,
               places: model.snapshot.places
           )?.point,
           isValidCoordinate(point) {
            points.append(point)
        }

        return simplifiedRouteCoordinates(points)
    }

    func coordinates(for segment: TravelSegment) -> [CLLocationCoordinate2D] {
        routePresentationCache.coordinates(
            for: routePresentationCacheKey,
            segmentID: segment.id,
            includeImprecise: false
        ) {
            buildCoordinates(for: segment, includeImprecise: false)
        }
    }

    func buildCoordinates(
        for segment: TravelSegment,
        includeImprecise: Bool
    ) -> [CLLocationCoordinate2D] {
        if segment.mode == .subway,
           let route = segment.subwayRoute {
            let routePoints = route.coordinates.filter(isValidCoordinate)
            if routePoints.count >= 2 {
                return simplifiedRouteCoordinates(routePoints)
            }
        }
        var values = routeCoordinates(
            for: segment,
            includeImprecise: includeImprecise
        )
        if !includeImprecise && (values.isEmpty || values.count == 1) {
            let fallback = routeCoordinates(for: segment, includeImprecise: true)
            if fallback.count >= 2 {
                return fallback
            }
            if fallback.count == 1 {
                values = fallback
            }
        }
        return values
    }

    func routeColor(for mode: TravelMode) -> Color {
        switch mode {
        case .walking, .running: .tpHealthDark
        case .cycling: .tpTransitDark
        case .bus, .subway, .train: .tpProjectDark
        case .taxi, .car: .tpInk
        case .airplane, .ship: .tpPlaceDark
        }
    }

    func detailTravelColor(_ travel: TravelSegment) -> Color {
        isWorkoutWalking(travel)
            ? RecordTimelinePalette.categoryColor("exercise")
            : routeColor(for: travel.mode)
    }

    func detailTravelTitle(_ travel: TravelSegment) -> String {
        let kind = isWorkoutWalking(travel) ? "운동 기록" : "알고리즘 결과"
        return "\(kind) · \(MovementPresentation.title(for: travel.mode))"
    }

    func isWorkoutWalking(_ travel: TravelSegment) -> Bool {
        TravelSegmentPresentationEngine.isWorkoutWalking(
            travel,
            actuals: model.snapshot.actuals
        )
    }

    func fitMapToRoutes(force: Bool = false) {
        // Live sensor callbacks can arrive more often than MapKit needs. A
        // 30 Hz idle budget and a lighter 15 Hz playhead budget keep the
        // location-following map responsive without issuing duplicate region
        // transactions for every gesture sample; explicit selections still
        // bypass the throttle.
        let minimumInterval: TimeInterval = playheadDate == nil
            ? 1.0 / 30.0
            : 1.0 / 15.0
        guard mapFitGate.permits(
            force: force,
            minimumInterval: minimumInterval
        ) else {
            return
        }

        if playheadDate != nil, let focus = playheadFocusCoordinate {
            if let lastMapFocusCoordinate,
               CLLocation(
                   latitude: lastMapFocusCoordinate.latitude,
                   longitude: lastMapFocusCoordinate.longitude
               ).distance(
                   from: CLLocation(
                       latitude: focus.latitude,
                       longitude: focus.longitude
                   )
               ) < 5 {
                return
            }
            lastMapFocusCoordinate = focus
            mapPosition = .region(
                MKCoordinateRegion(
                    center: focus,
                    span: MKCoordinateSpan(
                        latitudeDelta: 0.004,
                        longitudeDelta: 0.004
                    )
                )
            )
            return
        }

        if playheadDate == nil,
           activeSelection?.isRoute == true,
           displayedRouteCoordinates.count >= 2 {
            lastMapFocusCoordinate = nil
            fitMap(to: displayedRouteCoordinates)
            return
        }

        // 고른 구간이 없으면 기간 전체가 이 카드의 주제다. 현재 위치를
        // 따라다니는 대신 기간 경로를 담는다. 좌표만으로 범위를 잡으므로
        // GPS가 들어와도 화면이 흔들리지 않는다.
        if playheadDate == nil, let region = periodRouteRegion() {
            lastMapFocusCoordinate = nil
            mapPosition = .region(region)
            return
        }

        // 그릴 경로가 아직 없을 때만 지도는 현재 위치를 따라간다.
        if playheadDate == nil, let focus = currentLocationCoordinate {
            if let lastMapFocusCoordinate,
               CLLocation(
                   latitude: lastMapFocusCoordinate.latitude,
                   longitude: lastMapFocusCoordinate.longitude
               ).distance(
                   from: CLLocation(
                       latitude: focus.latitude,
                       longitude: focus.longitude
                   )
               ) < 5 {
                return
            }
            lastMapFocusCoordinate = focus
            mapPosition = .region(
                MKCoordinateRegion(
                    center: focus,
                    span: MKCoordinateSpan(
                        latitudeDelta: 0.004,
                        longitudeDelta: 0.004
                    )
                )
            )
            return
        }

        // If playback has a timestamp but no coordinate yet, retain the last
        // camera rather than jumping to an unrelated route midpoint.
        if playheadDate != nil {
            return
        }

        lastMapFocusCoordinate = nil
        mapPosition = .automatic
    }

    var resolvedRouteMapViewportSize: CGSize {
        guard routeMapViewportSize.width > 1,
              routeMapViewportSize.height > 1 else {
            return CGSize(width: 390, height: routeMapHeight)
        }
        return routeMapViewportSize
    }

    func updateRouteMapViewportSize(_ size: CGSize) {
        guard size.width > 1,
              size.height > 1,
              abs(routeMapViewportSize.width - size.width) > 0.5
                || abs(routeMapViewportSize.height - size.height) > 0.5
        else { return }
        routeMapViewportSize = size
        fitMapToRoutes(force: true)
    }

    func periodRouteRegion() -> MKCoordinateRegion? {
        RouteMapViewport.region(
            for: [displayedRouteCoordinates]
                + dimmedRouteSegments.map { coordinates(for: $0) },
            viewport: resolvedRouteMapViewportSize,
            padding: .timeline
        )
    }

    func fitMap(to values: [CLLocationCoordinate2D]) {
        guard let region = RouteMapViewport.region(
            for: values,
            viewport: resolvedRouteMapViewportSize,
            padding: .timeline
        ) else { return }
        mapPosition = .region(region)
    }
}
