import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

enum RouteMapLineStyle {
    static let lineWidth: CGFloat = 3
    static let minimumOpacity: Double = 0.72
}

struct MapHomePawprintTapTarget {
    let id: Int
    let point: CGPoint
    let timestamp: Date?
    let isPredicted: Bool
    var routeID: String? = nil
    var routeSpan: TimeSpan? = nil
}

struct MapHomePawprintTimeSelection: Equatable {
    let timestamp: Date
    let minute: Int
    let minuteOffset: Double
}

struct MapHomePawprintTrace {
    let coordinates: [CLLocationCoordinate2D]
    let timestamps: [Date]
}

enum MapHomePawprintInteractionPolicy {
    static let markerLimit = 220

    static func recordedBudget(inferredDemand: Int) -> Int {
        markerLimit - min(96, max(0, inferredDemand))
    }

    static func spreadIndices(count: Int, limit: Int) -> [Int] {
        guard count > 0, limit > 0 else { return [] }
        guard count > limit else { return Array(0..<count) }
        guard limit > 1 else { return [count - 1] }
        return (0..<limit).map {
            Int((Double($0) * Double(count - 1) / Double(limit - 1)).rounded())
        }
    }

    static func distributedCounts(
        sampleCounts: [Int], latestTimestamps: [Date], limit: Int
    ) -> [Int] {
        var counts = Array(repeating: 0, count: sampleCounts.count)
        guard limit > 0, latestTimestamps.count == sampleCounts.count else { return counts }
        let priority = sampleCounts.indices.filter { sampleCounts[$0] > 0 }.sorted {
            if latestTimestamps[$0] != latestTimestamps[$1] {
                return latestTimestamps[$0] > latestTimestamps[$1]
            }
            return $0 > $1
        }
        var remaining = limit
        // Give every path an endpoint before increasing any path's density.
        while remaining > 0 {
            var allocated = false
            for index in priority where counts[index] < sampleCounts[index] {
                counts[index] += 1
                remaining -= 1
                allocated = true
                if remaining == 0 { break }
            }
            if !allocated { break }
        }
        return counts
    }

    static func sampleIndices(segments: [MapHomePawprintTrace], limit: Int) -> [[Int]] {
        let candidates = segments.map {
            sampleIndices(coordinates: $0.coordinates, timestamps: $0.timestamps, limit: limit)
        }
        let counts = distributedCounts(sampleCounts: candidates.map(\.count),
            latestTimestamps: segments.map { $0.timestamps.last ?? .distantPast }, limit: limit)
        return candidates.indices.map { index in
            spreadIndices(count: candidates[index].count, limit: counts[index]).map { candidates[index][$0] }
        }
    }

    static func sampleIndices(
        coordinates: [CLLocationCoordinate2D],
        timestamps: [Date],
        limit: Int
    ) -> [Int] {
        guard limit > 0, coordinates.count >= 2,
              coordinates.count == timestamps.count,
              timestamps.allSatisfy(RouteTimelineTimestamp.isValid),
              zip(timestamps, timestamps.dropFirst()).allSatisfy({ $0 <= $1 })
        else { return [] }
        var result: [Int] = []
        var distance = 0.0
        for index in coordinates.indices {
            guard CLLocationCoordinate2DIsValid(coordinates[index]) else { return [] }
            if index > 0 {
                let latitude = coordinates[index].latitude - coordinates[index - 1].latitude
                let longitude = RouteTimelineLongitude.shortestDelta(
                    from: coordinates[index - 1].longitude,
                    to: coordinates[index].longitude
                )
                distance += hypot(latitude, longitude)
            }
            if result.isEmpty || distance >= 0.00035 || index == coordinates.count - 1 {
                result.append(index)
                distance = 0
            }
        }
        return spreadIndices(count: result.count, limit: limit).map { result[$0] }
    }

    static func selection(
        timestamp: Date?,
        isPredicted: Bool,
        selectedDate: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> MapHomePawprintTimeSelection? {
        guard !isPredicted, let timestamp,
              RouteTimelineTimestamp.isValid(timestamp) else { return nil }
        let start = calendar.startOfDay(for: selectedDate)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start),
              timestamp >= start, timestamp < end else { return nil }
        let offset = timestamp.timeIntervalSince(start) / 60
        return MapHomePawprintTimeSelection(
            timestamp: timestamp,
            minute: min(MapHomeTimeSidebarMath.fullDayMinutes - 1, Int(offset)),
            minuteOffset: offset
        )
    }

    static func nearestTarget(
        to point: CGPoint,
        targets: [MapHomePawprintTapTarget],
        selectedDate: Date,
        radius: CGFloat = 22,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Int? {
        var nearestID: Int?
        var nearestDistance = radius * radius
        for target in targets {
            if target.isPredicted {
                guard target.routeID != nil, let span = target.routeSpan,
                      let day = calendar.dateInterval(of: .day, for: selectedDate),
                      span.start < day.end, span.end >= day.start else { continue }
            } else {
                guard selection(timestamp: target.timestamp, isPredicted: false,
                    selectedDate: selectedDate, calendar: calendar) != nil else { continue }
            }
            let distance = pow(target.point.x - point.x, 2) + pow(target.point.y - point.y, 2)
            if distance < nearestDistance || (distance == nearestDistance && nearestID == nil) {
                nearestID = target.id
                nearestDistance = distance
            }
        }
        return nearestID
    }
}

enum MapHomeCompassControlState: Equatable, Sendable {
    case directionArrow
    case compass

    var followsHeading: Bool {
        self == .compass
    }

    var mapCameraHeading: CLLocationDirection? {
        followsHeading ? nil : 0
    }

    var toggled: Self {
        self == .directionArrow ? .compass : .directionArrow
    }

    static func iconRotationDegrees(for headingDegrees: Double) -> Double {
        guard headingDegrees.isFinite else { return 0 }
        let normalized = headingDegrees.truncatingRemainder(dividingBy: 360)
        return normalized == 0 ? 0 : -normalized
    }

    static func continuousIconRotationDegrees(
        previousRotationDegrees: Double?,
        headingDegrees: Double
    ) -> Double {
        let target = iconRotationDegrees(for: headingDegrees)
        guard let previousRotationDegrees,
              previousRotationDegrees.isFinite else {
            return target
        }
        var delta = (target - previousRotationDegrees)
            .truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return previousRotationDegrees + delta
    }

    static func preferredHeadingDegrees(
        trueHeading: Double,
        magneticHeading: Double
    ) -> Double {
        trueHeading.isFinite && trueHeading >= 0
            ? trueHeading
            : magneticHeading
    }
}

enum MapHomeSearchLayoutMath {
    static let menuPanelWidth: CGFloat = 316
    static let playbackTouchSize: CGFloat = 44
    static let playbackVisualSize: CGFloat = 40.74
    static let playbackIconSize: CGFloat = 13.58
    static let itemSpacing: CGFloat = 8
    static let searchRowHeight: CGFloat = 48
    static let searchResultsMaximumHeight: CGFloat = 320

    static func searchWidth(
        viewportWidth: CGFloat,
        horizontalInset: CGFloat,
        trailingControlCount: Int = 1
    ) -> CGFloat {
        let menuAlignedWidth = menuPanelWidth - horizontalInset
        let controlCount = max(0, trailingControlCount)
        let controlsWidth = CGFloat(controlCount) * playbackTouchSize
            + CGFloat(max(0, controlCount - 1)) * itemSpacing
        let availableWidth = viewportWidth
            - horizontalInset * 2
            - controlsWidth
            - (controlCount > 0 ? itemSpacing : 0)
        return max(0, min(menuAlignedWidth, availableWidth))
    }

    static func searchResultsHeight(resultCount: Int) -> CGFloat {
        min(
            CGFloat(max(resultCount, 0)) * searchRowHeight,
            searchResultsMaximumHeight
        )
    }
}

enum MapHomeLayerPriority {
    static let map: Double = 0
    static let stickman: Double = 1
    static let sidebar: Double = 2
    static let loading: Double = 3
    static let search: Double = 4
    static let menu: Double = 6
    static let header: Double = 8
}

enum MapHomeAppleAnnotationLayerPriority {
    static let userLocation: CGFloat = 0
    static let place: CGFloat = 0
    static let stickman: CGFloat = 100
}

enum MapHomeAppleWalkerOverlayLayout {
    @MainActor
    static func update(_ view: UIView, coordinate: CLLocationCoordinate2D, on mapView: MKMapView) {
        guard mapView.bounds.width > 0, mapView.bounds.height > 0 else { return }
        if view.superview !== mapView {
            mapView.addSubview(view)
            view.layer.zPosition = MapHomeAppleAnnotationLayerPriority.stickman
            mapView.bringSubviewToFront(view)
        }
        let point = mapView.convert(coordinate, toPointTo: mapView)
        let offset = MapHomeStickmanAnnotationLayout.centerOffset
        UIView.performWithoutAnimation {
            view.center = CGPoint(x: point.x + offset.x, y: point.y + offset.y)
        }
    }
}

enum MapHomeCameraLayoutMath {
    static let centeredTolerance: CGFloat = 18

    static func targetPoint(
        viewportSize: CGSize,
        searchBottom: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: viewportSize.width / 2,
            y: min(max(searchBottom, 0), viewportSize.height)
                + max(0, viewportSize.height - searchBottom) / 2
        )
    }

    static func cameraCenterSourcePoint(
        currentLocationPoint: CGPoint,
        targetPoint: CGPoint,
        viewportSize: CGSize
    ) -> CGPoint {
        CGPoint(
            x: viewportSize.width / 2 + currentLocationPoint.x - targetPoint.x,
            y: viewportSize.height / 2 + currentLocationPoint.y - targetPoint.y
        )
    }

    static func isCentered(
        locationPoint: CGPoint,
        targetPoint: CGPoint,
        tolerance: CGFloat = centeredTolerance
    ) -> Bool {
        hypot(locationPoint.x - targetPoint.x, locationPoint.y - targetPoint.y)
            <= tolerance
    }
}

/// 집 아이콘을 눌러 하루요약 시트가 지도 아래쪽을 덮을 때, 가려지지 않고 남는 지도 영역을 계산한다.
/// 시트는 화면 높이의 `collapsedCoverage`만큼 올라오므로 지도의 세로 가운데도 그만큼 위로 올라간다.
enum MapHomeDaySummaryLayout {
    /// 접힌 시트가 덮는 화면 높이 비율. 하루요약 첫 화면이 화면 절반쯤에서 보인다.
    static let collapsedCoverage: CGFloat = 0.5

    /// 시트가 덮은 만큼을 뺀 지도 영역의 세로 가운데.
    static func visibleCenterY(viewportHeight: CGFloat, coverage: CGFloat) -> CGFloat {
        guard viewportHeight > 0 else { return 0 }
        let covered = min(max(coverage, 0), 1) * viewportHeight
        return (viewportHeight - covered) / 2
    }

    /// 시트가 덮은 만큼을 뺀 지도 영역의 가운데 점. 따라가기·재생도 이 점을 가운데로 삼는다.
    static func targetPoint(viewportSize: CGSize, coverage: CGFloat) -> CGPoint {
        CGPoint(
            x: viewportSize.width / 2,
            y: visibleCenterY(viewportHeight: viewportSize.height, coverage: coverage)
        )
    }

    /// 집(지도 가운데)을 남은 영역의 가운데로 옮기려면 카메라 중심을 화면 아래로 몇 포인트
    /// 내려야 하는지. 시트를 내리면(coverage 0) 0이라 지도 전체 가운데로 돌아온다.
    static func centerShift(viewportHeight: CGFloat, coverage: CGFloat) -> CGFloat {
        guard viewportHeight > 0 else { return 0 }
        return max(
            0,
            viewportHeight / 2
                - visibleCenterY(viewportHeight: viewportHeight, coverage: coverage)
        )
    }

    /// 화면에서 `shift`포인트만큼 아래를 보게 만들 때 필요한 위도 변화량.
    /// 지도 한 화면의 위도 폭을 세로 길이로 나눠 픽셀을 도(degree)로 바꾼다.
    static func latitudeShift(
        shift: CGFloat,
        viewportHeight: CGFloat,
        latitudeDelta: Double
    ) -> Double {
        guard viewportHeight > 0, shift > 0, latitudeDelta.isFinite else { return 0 }
        return latitudeDelta * Double(shift) / Double(viewportHeight)
    }
}

/// 화랑이 위에 쌓아 보여 주는 카운터. 연봉 카운터는 자체 설정 화면을 갖고,
/// 나머지는 켜고 끄기만 한다.
enum MapHomeCounterKind: String, CaseIterable, Identifiable {
    case steps
    case distance
    case work
    case study
    case hobby
    case exercise

    var id: String { rawValue }

    /// 켜고 끈 값을 기기에 저장하는 키.
    var storageKey: String { "mapHomeCounter." + rawValue }

    var systemImage: String {
        switch self {
        case .steps: "figure.walk"
        case .distance: "point.topleft.down.to.point.bottomright.curvepath.fill"
        case .work: "briefcase.fill"
        case .study: "book.fill"
        case .hobby: "paintpalette.fill"
        case .exercise: "figure.strengthtraining.traditional"
        }
    }

    /// 하루요약 대분류 id. 걸음·이동은 대분류가 아니라 따로 센다.
    var categoryID: String? {
        switch self {
        case .steps, .distance: nil
        case .work: "work"
        case .study: "study"
        case .hobby: "hobby"
        case .exercise: "exercise"
        }
    }

    /// 설정 메뉴에 쓰는 이름.
    func menuTitle(_ language: MapHomeLanguage) -> String {
        switch self {
        case .steps: language.text("걸음걸이 카운터", "Step counter")
        case .distance: language.text("이동거리 카운터", "Distance counter")
        case .work: language.text("업무시간 카운터", "Work time counter")
        case .study: language.text("학습시간 카운터", "Study time counter")
        case .hobby: language.text("취미시간 카운터", "Hobby time counter")
        case .exercise: language.text("운동시간 카운터", "Exercise time counter")
        }
    }

    /// 화랑이 위 배지에 쓰는 짧은 이름.
    func badgeTitle(_ language: MapHomeLanguage) -> String {
        switch self {
        case .steps: language.text("걸음", "Steps")
        case .distance: language.text("거리", "Distance")
        case .work: language.text("업무", "Work")
        case .study: language.text("학습", "Study")
        case .hobby: language.text("취미", "Hobby")
        case .exercise: language.text("운동", "Exercise")
        }
    }
}

enum MapHomeLongPressRoutingMath {
    static let exclusionPadding: CGFloat = 8
    @MainActor
    static func isAnnotationTouch(_ view: UIView?) -> Bool {
        var currentView = view
        while let current = currentView {
            if current is MKAnnotationView { return true }
            currentView = current.superview
        }
        return false
    }

    static func shouldPresentLocation(
        at point: CGPoint,
        excluding frame: CGRect
    ) -> Bool {
        guard !frame.isNull, !frame.isEmpty else { return true }
        return !frame.insetBy(
            dx: -exclusionPadding,
            dy: -exclusionPadding
        ).contains(point)
    }
}

enum MapHomeCatTapRouting {
    static let hitRadius: CGFloat = 36
    static let homeIconHitRadius: CGFloat = 18
    /// 집 아바타의 중심은 지도 좌표와 같다(마커 안에 빈 자리를 두지 않는다).
    static let homeImageCenterOffset = CGPoint.zero
    /// 아바타 안에서 화랑이가 놓이는 자리(48pt 아트 기준). 아바타 안에서는
    /// homeArtScale 만큼 키워 적용하므로, 값이 커지면 원 밖으로 잘린다.
    static let catOffsetInHomeImage = CGPoint(x: 16, y: 6)
    /// 아바타 안 아트 크기를 기존 48pt와 비교한 비율.
    static let homeArtScale: CGFloat = MapHomePlacePinLayout.artworkSize / 48
    static let homeMarkerOffset = CGPoint(
        x: homeImageCenterOffset.x + catOffsetInHomeImage.x * homeArtScale,
        y: homeImageCenterOffset.y + catOffsetInHomeImage.y * homeArtScale
    )
    static let roamingMarkerOffset = MapHomeStickmanAnnotationLayout.centerOffset

    static func markerPoint(locationPoint: CGPoint, isAtHome: Bool) -> CGPoint {
        let offset = isAtHome ? homeMarkerOffset : roamingMarkerOffset
        return CGPoint(
            x: locationPoint.x + offset.x,
            y: locationPoint.y + offset.y
        )
    }

    static func contains(
        tapPoint: CGPoint,
        markerPoint: CGPoint,
        radius: CGFloat = hitRadius
    ) -> Bool {
        hypot(tapPoint.x - markerPoint.x, tapPoint.y - markerPoint.y)
            <= radius
    }

    static func isHomeIconTap(tapPoint: CGPoint, locationPoint: CGPoint) -> Bool {
        let homeIconPoint = CGPoint(
            x: locationPoint.x + homeImageCenterOffset.x,
            y: locationPoint.y + homeImageCenterOffset.y
        )
        return contains(
            tapPoint: tapPoint,
            markerPoint: homeIconPoint,
            radius: homeIconHitRadius
        )
    }

    /// 집 핀의 "성장 카드 + 하루 요약" 탭 영역. 핀 안쪽 제스처가 벡터 지도 위에서 먹지 않아 지도 단위 탭에서 좌표로 판정한다.
    /// 집 아이콘 둘레와 그 아래 레벨 라벨 사각형이며, 위치는 집 핀의 지도 좌표(핀 중심) 기준이다.
    static let homeSummaryIconRadius: CGFloat = MapHomePlacePinLayout.avatarSize / 2
    static let homeSummaryLabelSize = CGSize(width: 64, height: 30)

    /// 집 아바타의 절반 높이. 아바타는 화랑이 유무와 상관없이 같은 크기라 값도 같다.
    /// 호출부·테스트가 화랑이 여부를 함께 넘기므로 인자는 유지한다.
    static func homeIconHalfHeight(showsCatAtHome: Bool) -> CGFloat {
        MapHomePlacePinLayout.avatarSize / 2
    }

    static func homeLevelLabelCenter(pinPoint: CGPoint, showsCatAtHome: Bool) -> CGPoint {
        CGPoint(
            x: pinPoint.x + homeImageCenterOffset.x,
            y: pinPoint.y + homeImageCenterOffset.y
                + homeIconHalfHeight(showsCatAtHome: showsCatAtHome)
                + MapHomePlacePinLayout.levelLabelGap
                + MapHomePlacePinLayout.levelLabelHeight / 2
        )
    }

    static func hitsHomeSummary(tapPoint: CGPoint, pinPoint: CGPoint, showsCatAtHome: Bool) -> Bool {
        let iconCenter = CGPoint(
            x: pinPoint.x + homeImageCenterOffset.x,
            y: pinPoint.y + homeImageCenterOffset.y
        )
        if contains(tapPoint: tapPoint, markerPoint: iconCenter, radius: homeSummaryIconRadius) { return true }
        let label = homeLevelLabelCenter(pinPoint: pinPoint, showsCatAtHome: showsCatAtHome)
        return abs(tapPoint.x - label.x) <= homeSummaryLabelSize.width / 2
            && abs(tapPoint.y - label.y) <= homeSummaryLabelSize.height / 2
    }

    static func shouldPresentCatDetails(
        tapPoint: CGPoint,
        locationPoint: CGPoint,
        isAtHome: Bool
    ) -> Bool {
        guard !isAtHome || !isHomeIconTap(
            tapPoint: tapPoint,
            locationPoint: locationPoint
        ) else { return false }
        return contains(
            tapPoint: tapPoint,
            markerPoint: markerPoint(locationPoint: locationPoint, isAtHome: isAtHome)
        )
    }
}

enum MapHomeLongPressAction: String, CaseIterable, Identifiable {
    case location
    case memo

    var id: Self { self }
}

enum MapHomeCameraZoomMath {
    static let minimumDistance: CLLocationDistance = 80
    static let maximumDistance: CLLocationDistance = 30_000_000
    static let zoomInFactor = 0.68
    static let zoomOutFactor = 1.48

    static func clampedDistance(_ distance: CLLocationDistance) -> CLLocationDistance {
        min(max(distance, minimumDistance), maximumDistance)
    }

    static func distance(
        from currentDistance: CLLocationDistance,
        direction: Int
    ) -> CLLocationDistance {
        clampedDistance(
            currentDistance * (direction > 0 ? zoomInFactor : zoomOutFactor)
        )
    }

    static func isAtLimit(
        distance: CLLocationDistance?,
        direction: Int
    ) -> Bool {
        guard let distance else { return false }
        return direction > 0
            ? distance <= minimumDistance
            : distance >= maximumDistance
    }

    /// 지도 배율(0~100)에 해당하는 카메라 거리. `scale(distance:)`의 역함수다.
    static func distance(forScale scale: Double) -> CLLocationDistance {
        let ratio = min(max(scale, 0), 100) / 100
        return exp(log(maximumDistance) - ratio * (log(maximumDistance) - log(minimumDistance)))
    }

    /// 지도 배율 표시(0~100). 최대 축소(`maximumDistance`)가 0, 최대 확대(`minimumDistance`)가 100이고
    /// 그 사이는 카메라 거리의 로그에 비례한다(확대·축소 버튼의 한 단계가 비슷한 폭으로 보이게).
    static func scale(distance: CLLocationDistance?) -> Int? {
        guard let distance, distance.isFinite, distance > 0 else { return nil }
        let clamped = min(max(distance, minimumDistance), maximumDistance)
        let ratio = (log(maximumDistance) - log(clamped)) / (log(maximumDistance) - log(minimumDistance))
        return Int((ratio * 100).rounded())
    }

    static func centerPreservingAnchor(
        cameraCenter: CLLocationCoordinate2D,
        anchor: CLLocationCoordinate2D,
        oldDistance: CLLocationDistance,
        newDistance: CLLocationDistance
    ) -> CLLocationCoordinate2D {
        guard oldDistance.isFinite, oldDistance > 0,
              newDistance.isFinite else {
            return cameraCenter
        }
        let scale = newDistance / oldDistance
        let centerPoint = MKMapPoint(cameraCenter)
        let anchorPoint = MKMapPoint(anchor)
        return MKMapPoint(
            x: anchorPoint.x - (anchorPoint.x - centerPoint.x) * scale,
            y: anchorPoint.y - (anchorPoint.y - centerPoint.y) * scale
        ).coordinate
    }
}

struct MapHomeCameraFrame: Equatable {
    let camera: MapCamera
    let centerLatitude: CLLocationDegrees
    let centerLongitude: CLLocationDegrees
    let latitudeDelta: CLLocationDegrees
    let longitudeDelta: CLLocationDegrees

    init(camera: MapCamera, region: MKCoordinateRegion) {
        self.camera = camera
        centerLatitude = region.center.latitude
        centerLongitude = region.center.longitude
        latitudeDelta = region.span.latitudeDelta
        longitudeDelta = region.span.longitudeDelta
    }

    var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: centerLatitude,
            longitude: centerLongitude
        )
    }

    var span: MKCoordinateSpan {
        MKCoordinateSpan(
            latitudeDelta: latitudeDelta,
            longitudeDelta: longitudeDelta
        )
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.camera.centerCoordinate.latitude == rhs.camera.centerCoordinate.latitude
            && lhs.camera.centerCoordinate.longitude == rhs.camera.centerCoordinate.longitude
            && lhs.camera.distance == rhs.camera.distance
            && lhs.camera.heading == rhs.camera.heading
            && lhs.camera.pitch == rhs.camera.pitch
            && lhs.centerLatitude == rhs.centerLatitude
            && lhs.centerLongitude == rhs.centerLongitude
            && lhs.latitudeDelta == rhs.latitudeDelta
            && lhs.longitudeDelta == rhs.longitudeDelta
    }
}

/// Coalesces continuous MapKit camera callbacks into display-rate frames while
/// retaining the latest input for the next render or gesture-end flush.
final class MapHomeCameraFrameProjection {
    private(set) var latestFrame: MapHomeCameraFrame?
    private var renderedFrame: MapHomeCameraFrame?
    private var inputBudget = TaptionPlanNLEInputBudgetEngine()
    private var lastParentReadbackUptime = -Double.infinity

    func submit(
        _ frame: MapHomeCameraFrame,
        nowUptime: TimeInterval,
        force: Bool = false
    ) -> MapHomeCameraFrame? {
        latestFrame = frame
        guard renderedFrame != frame else { return nil }
        let decision = inputBudget.submit(at: nowUptime, isFinal: force)
        guard decision.shouldPublish else { return nil }
        renderedFrame = frame
        return frame
    }

    func finish(nowUptime: TimeInterval) -> MapHomeCameraFrame? {
        guard let latestFrame else { return nil }
        return submit(latestFrame, nowUptime: nowUptime, force: true)
    }

    func shouldPublishParentReadback(
        nowUptime: TimeInterval,
        isFinal: Bool
    ) -> Bool {
        // Apple 지도는 움직이는 동안 카메라 값을 부모 화면으로 올릴 때마다 화면 전체가 다시 평가돼 느렸다.
        // 움직이는 동안은 초당 4번만 올리고, 손을 떼면(isFinal) 바로 올린다. 판타지 지도에서 효과를 본 방식이다(ARC1030A04).
        guard isFinal || nowUptime - lastParentReadbackUptime >= 0.25
        else { return false }
        lastParentReadbackUptime = nowUptime
        return true
    }

    func reset() {
        latestFrame = nil
        renderedFrame = nil
        lastParentReadbackUptime = -Double.infinity
        _ = inputBudget.beginGeneration()
    }
}

/// 발자국 장부. GPS가 기록된 순간의 위치·방향·속도로 발자국을 한 번 정하면, 이후 새로고침·분류 갱신에도 바뀌지 않는다(대표 지시, ARC1030A07).
///
/// 예전에는 하루 경로를 220개 안으로 솎아 내고(새 기록이 쌓이면 뽑히는 지점이 달라졌다), 색은 앞뒤 기록을 함께 본 속도로
/// 정해서(뒤에 기록이 붙으면 앞 발자국 색이 바뀌었다) 새로고침마다 발자국과 색이 변했다.
/// 장부는 시간순으로 앞에서부터만 판단한다: 이미 놓은 발자국은 뒤의 기록에 영향받지 않는다.
enum MapHomePawprintLedger {
    struct Entry: Equatable {
        let latitude: Double
        let longitude: Double
        /// 직전 발자국에서 이 발자국으로 향하는 방위(도). 첫 발자국은 0.
        let angle: Double
        let timestamp: Date
        /// 기록 당시 속도(m/s). GPS가 준 속도가 있으면 그것, 없으면 직전 기록에서 이 기록까지의 평균.
        let speed: Double?

        var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    }

    /// 발자국 사이 최소 간격(도). 약 100m.
    static let spacingDegrees = 0.0009
    /// 한 하루에 놓는 발자국의 상한. 넘으면 뒤는 놓지 않는다(앞의 것은 그대로다).
    static let maximumEntries = 2_000
    /// 화면에 올리는 최근 발자국 수. 오래된 것은 장부에 남지만 그리지 않아 지도 계산량을 묶는다.
    static let displayLimit = 600
    /// 이보다 부정확한 위치는 발자국으로 놓지 않는다(m).
    static let maximumAccuracyMeters = 200.0

    static func entries(readings: [SensorReading], excluding excluded: [TimeSpan]) -> [Entry] {
        var result: [Entry] = []
        var lastPaw: (latitude: Double, longitude: Double)?
        var previous: (latitude: Double, longitude: Double, timestamp: Date)?
        for reading in readings.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard let point = reading.point,
                  point.latitude.isFinite, point.longitude.isFinite,
                  abs(point.latitude) <= 90, abs(point.longitude) <= 180,
                  point.horizontalAccuracy >= 0, point.horizontalAccuracy <= maximumAccuracyMeters,
                  RouteTimelineTimestamp.isValid(reading.timestamp) else { continue }
            if excluded.contains(where: { $0.start <= reading.timestamp && reading.timestamp <= $0.end }) {
                previous = nil
                continue
            }
            defer { previous = (point.latitude, point.longitude, reading.timestamp) }
            if let lastPaw, distance(lastPaw.latitude, lastPaw.longitude, point.latitude, point.longitude) < spacingDegrees {
                continue
            }
            let recorded = reading.speedMetersPerSecond.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            let speed = recorded ?? previous.flatMap { earlier -> Double? in
                let seconds = reading.timestamp.timeIntervalSince(earlier.timestamp)
                guard seconds > 0, seconds <= 180 else { return nil }
                let meters = CLLocation(latitude: earlier.latitude, longitude: earlier.longitude)
                    .distance(from: CLLocation(latitude: point.latitude, longitude: point.longitude))
                return meters / seconds
            }
            let angle = lastPaw.map {
                atan2(
                    RouteTimelineLongitude.shortestDelta(from: $0.longitude, to: point.longitude),
                    point.latitude - $0.latitude
                ) * 180 / .pi
            } ?? 0
            result.append(Entry(
                latitude: point.latitude, longitude: point.longitude, angle: angle,
                timestamp: reading.timestamp, speed: speed
            ))
            lastPaw = (point.latitude, point.longitude)
            if result.count >= maximumEntries { break }
        }
        return result
    }

    private static func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        hypot(lat2 - lat1, RouteTimelineLongitude.shortestDelta(from: lon1, to: lon2))
    }
}

/// 안개에서 현재 위치를 걷어 내는 원의 중심. 화랑이가 실제로 그려지는 화면 점이 있으면 그 점을 쓴다.
/// 화랑이 점은 입력 예산(최대 60Hz)으로 갱신되고 지도 뷰포트는 프레임마다 바뀌어, 지도가 빨리 움직이는 재생 중에
/// 둘을 따로 쓰면 안개 구멍이 화랑이와 어긋나 보인다(2026-10-20 재생 녹화 08:28 프레임).
enum MapHomeFogRevealPolicy {
    static func currentLocationPoint(stickmanPoint: CGPoint?, viewportPoint: CGPoint?) -> CGPoint? {
        stickmanPoint ?? viewportPoint
    }
}

final class MapHomeStickmanViewportProjection {
    private var latestPoint: CGPoint?
    private var renderedPoint: CGPoint?
    private var inputBudget = TaptionPlanNLEInputBudgetEngine()

    func submit(
        _ point: CGPoint,
        nowUptime: TimeInterval,
        force: Bool = false
    ) -> CGPoint? {
        latestPoint = point
        if let renderedPoint,
           abs(renderedPoint.x - point.x) <= 0.25,
           abs(renderedPoint.y - point.y) <= 0.25 {
            return nil
        }
        let decision = inputBudget.submit(at: nowUptime, isFinal: force)
        guard decision.shouldPublish else { return nil }
        renderedPoint = point
        return point
    }

    func finish(nowUptime: TimeInterval) -> CGPoint? {
        guard let latestPoint else { return nil }
        return submit(latestPoint, nowUptime: nowUptime, force: true)
    }
}

/// Apple 지도가 프레임마다 넘기는 화랑이 점을 담는 상자. 관찰하지 않는다: 값이 바뀌어도 부모 화면을 다시 그리지 않고,
/// 카운터 창만 화면 틱마다 읽어 화랑이(UIKit이 같은 프레임에 옮기는 뷰)와 함께 움직인다(UIX1031A06).
@MainActor
final class MapHomeAppleStickmanLivePoint {
    var point: CGPoint?
}

@MainActor
@Observable
final class MapHomeVectorViewportStore {
    private(set) var viewport: MapHomeVectorViewport?
    private(set) var stickmanPoint: CGPoint?
    private var stickmanProjection = MapHomeStickmanViewportProjection()
    /// 재생 중 화랑이 점. 관찰하지 않는다: 매 프레임 바뀌어도 오버레이 전체를 다시 그리지 않는다(PLY1029A05).
    @ObservationIgnored private(set) var livePoint: CGPoint?
    /// 재생 중 지도 엔진이 프레임마다 투영한 뷰포트. 오버레이(발자국·장소 아이콘·화살표)가 이 값으로 지도와 함께 움직인다(ARC1030A02).
    @ObservationIgnored var livePlaybackViewport: MapHomeVectorViewport?
    @ObservationIgnored private var lastObservedUptime: TimeInterval = 0
    /// 재생 중 관찰되는 값(안개·급여 위치 등)을 갱신하는 간격. 화랑이 마커는 `livePoint`로 매 프레임 움직인다.
    static let playbackObservedInterval: TimeInterval = 0.25

    func update(_ next: MapHomeVectorViewport) {
        guard viewport != next else { return }
        viewport = next
    }

    /// 재생 중 지도 화면 변화를 간격마다 한 번만 관찰 값으로 올린다.
    func updateViewportThrottled(_ next: MapHomeVectorViewport, nowUptime: TimeInterval) {
        guard nowUptime - lastObservedUptime >= Self.playbackObservedInterval else { return }
        lastObservedUptime = nowUptime
        update(next)
    }

    /// 재생 구동기가 매 프레임 화랑이 점을 넘긴다. 마커는 `livePoint`를 직접 읽고, 관찰 값은 간격마다만 바꾼다.
    func publishPlaybackPoint(_ point: CGPoint, nowUptime: TimeInterval) {
        livePoint = point
        guard nowUptime - lastObservedUptime >= Self.playbackObservedInterval else { return }
        lastObservedUptime = nowUptime
        if stickmanPoint != point {
            stickmanPoint = point
        }
    }

    func updateStickmanPoint(
        _ point: CGPoint,
        nowUptime: TimeInterval
    ) {
        livePoint = nil
        guard let rendered = stickmanProjection.submit(
            point,
            nowUptime: nowUptime
        ) else { return }
        if stickmanPoint != rendered {
            stickmanPoint = rendered
        }
    }

    func finishStickmanPoint(nowUptime: TimeInterval) {
        guard let rendered = stickmanProjection.finish(nowUptime: nowUptime)
        else { return }
        if stickmanPoint != rendered {
            stickmanPoint = rendered
        }
    }

    func shouldPublishParentReadback(
        nowUptime: TimeInterval,
        isFinal: Bool
    ) -> Bool {
        isFinal
    }
}
