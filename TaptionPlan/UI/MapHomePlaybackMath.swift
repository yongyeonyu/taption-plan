import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

enum MapHomeDayPlaybackMath {
    static let durationSeconds: TimeInterval = 24
    /// 재생 틱은 120Hz 예산(대표 지시, PLY1020R01). 60Hz 기기는 시스템이 프레임을 합친다.
    static let frameIntervalNanoseconds: UInt64 = 8_333_333
    /// 재생 중 경로 투영 갱신은 0.5초·분 단위 컷오프. 0.25초마다 전체 투영을 다시 만들어 메인 스레드에 올리던 것을 줄인다(PLY1029A01).
    static let routeProjectionInterval: TimeInterval = 0.5
    /// 틱 간격이 이보다 길면 프레임을 놓친 것으로 센다(120Hz 틱 8.33ms + 여유).
    static let droppedFrameInterval: TimeInterval = 0.012
    /// 8ms 문턱: 8.33ms 틱의 지터에도 매 프레임 지도 중심을 갱신한다.
    static let mapFocusInterval: TimeInterval = 0.008
    /// 정지 구간(업무·수면·활동 등)은 초당 120분으로 지나간다(대표 지시, PLY1020W01). 화면 시험은 `-slowDayPlayback`으로 이 배속만 늦춘다.
    static let stationaryMinutesPerSecond = 120.0 * MapHomeDayPlaybackTestHooks.rateScale
    /// 이동 구간은 초당 2.5분, 곧 정지 배속 120분의 1/48로 재생한다(대표 지시 ARC1030A02 "지금의 절반"; PLY1029A04에서 1/24였다).
    static let movementPlaybackMultiplier = 1.0 / 48.0
    static let movingMinutesPerSecond = stationaryMinutesPerSecond * movementPlaybackMultiplier

    static func playbackEndMinute(
        for selectedDate: Date,
        now: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Double {
        guard calendar.isDate(selectedDate, inSameDayAs: now) else {
            return Double(MapHomeTimeSidebarMath.fullDayMinutes)
        }
        let components = calendar.dateComponents([.hour, .minute, .second], from: now)
        let minute = Double((components.hour ?? 0) * 60 + (components.minute ?? 0))
            + Double(components.second ?? 0) / 60
        return min(
            Double(MapHomeTimeSidebarMath.fullDayMinutes),
            max(0, minute)
        )
    }

    static func playbackStartMinute(
        selectedMinute: Int?,
        endMinute: Double,
        isToday: Bool
    ) -> Double {
        let selected = min(
            Double(MapHomeTimeSidebarMath.fullDayMinutes),
            max(0, Double(selectedMinute ?? 0))
        )
        guard isToday, selected >= endMinute.rounded(.down) else {
            return min(selected, endMinute)
        }
        return 0
    }

    static func minute(elapsedSeconds: TimeInterval) -> Int {
        guard elapsedSeconds.isFinite else { return 0 }
        let progress = min(max(elapsedSeconds / durationSeconds, 0), 1)
        return min(
            MapHomeTimeSidebarMath.fullDayMinutes,
            max(0, Int((progress * Double(MapHomeTimeSidebarMath.fullDayMinutes)).rounded(.down)))
        )
    }

    static func advancedMinute(
        from currentMinute: Double,
        elapsedSeconds: TimeInterval,
        normalizedMovingRanges: [MapHomePlaybackMovementRange]
    ) -> Double {
        guard elapsedSeconds.isFinite, elapsedSeconds > 0 else {
            return min(1_440, max(0, currentMinute))
        }
        let ranges = normalizedMovingRanges
        var minute = min(1_440, max(0, currentMinute))
        var remaining = elapsedSeconds
        while remaining > 0, minute < 1_440 {
            let active = ranges.filter {
                $0.startMinute <= minute && minute < $0.endMinute
            }
            let rate = active.isEmpty
                ? stationaryMinutesPerSecond
                : active.map { $0.minutesPerSecond }.min()
                    ?? movingMinutesPerSecond
            let nextBoundary = active.map(\.endMinute).min()
                ?? ranges.first { $0.startMinute > minute }?.startMinute
                ?? 1_440
            let minutesToBoundary = max(0, nextBoundary - minute)
            let secondsToBoundary = minutesToBoundary / rate
            if secondsToBoundary <= 0 {
                minute = min(1_440, minute + 0.000_001)
            } else if remaining < secondsToBoundary {
                minute += remaining * rate
                remaining = 0
            } else {
                minute = nextBoundary
                remaining -= secondsToBoundary
            }
        }
        return min(1_440, max(0, minute))
    }
}

enum MapHomeRouteOverlayCutoffPolicy {
    static func cutoff(
        selectedDayEnd: Date,
        timelineDate: Date,
        isPlaybackRunning: Bool,
        interactiveProjectionCutoff: Date? = nil
    ) -> Date {
        let candidate = isPlaybackRunning
            ? timelineDate
            : interactiveProjectionCutoff ?? timelineDate
        return min(selectedDayEnd, candidate)
    }
}

struct MapHomePlaybackMovementRange: Hashable, Sendable {
    let startMinute: Double
    let endMinute: Double
    let mode: TravelMode?

    init(
        startMinute: Double,
        endMinute: Double,
        mode: TravelMode? = nil
    ) {
        self.startMinute = min(1_440, max(0, startMinute))
        self.endMinute = min(1_440, max(self.startMinute, endMinute))
        self.mode = mode
    }

    var minutesPerSecond: Double {
        switch mode {
        case .walking:
            // 걷기는 초당 15분(PLY1029A01). 이동 배속이 2배가 되면서(PLY1029A04) 배수는 6→3으로 같은 값을 유지한다.
            return MapHomeDayPlaybackMath.movingMinutesPerSecond * 3
        case .running, nil:
            return MapHomeDayPlaybackMath.movingMinutesPerSecond
        case .cycling, .bus, .subway, .taxi, .car, .train, .airplane, .ship:
            return MapHomeDayPlaybackMath.movingMinutesPerSecond
        }
    }

    /// 이동 구간 안의 세부 활동을 따로 떼어 낸다. 머무름·휴식은 이동 범위에서 빼서 정지 속도로 재생하고,
    /// 걷기는 걸음 속도 범위로 바꾼다. 나머지는 원래 이동 모드를 그대로 쓴다.
    static func carved(
        _ range: Self,
        details: [(start: Double, end: Double, mode: TravelMode?, isStationary: Bool)]
    ) -> [Self] {
        var pieces = [range]
        var walks: [Self] = []
        for detail in details where detail.end > range.startMinute && detail.start < range.endMinute {
            if detail.mode == .walking {
                let start = max(detail.start, range.startMinute)
                let end = min(detail.end, range.endMinute)
                if end > start {
                    walks.append(Self(startMinute: start, endMinute: end, mode: .walking))
                }
            }
            guard detail.isStationary else { continue }
            pieces = pieces.flatMap { piece -> [Self] in
                guard detail.end > piece.startMinute, detail.start < piece.endMinute else { return [piece] }
                var result: [Self] = []
                if detail.start > piece.startMinute {
                    result.append(Self(startMinute: piece.startMinute, endMinute: detail.start, mode: piece.mode))
                }
                if detail.end < piece.endMinute {
                    result.append(Self(startMinute: detail.end, endMinute: piece.endMinute, mode: piece.mode))
                }
                return result
            }
        }
        return pieces + walks
    }

    static func normalized(
        _ ranges: [Self]
    ) -> [Self] {
        let ordered = ranges
            .filter { $0.startMinute < $0.endMinute }
            .sorted { $0.startMinute < $1.startMinute }
        var result: [Self] = []
        for range in ordered {
            guard let previous = result.last,
                  range.startMinute <= previous.endMinute,
                  range.mode == previous.mode else {
                result.append(range)
                continue
            }
            result[result.count - 1] = Self(
                startMinute: previous.startMinute,
                endMinute: max(previous.endMinute, range.endMinute),
                mode: previous.mode
            )
        }
        return result
    }
}

/// 지도 거리 기준(배율 0~100, 대표 지시 ZMP1020A01). 정지·걷기·등록 장소에서 이어지는 이동·시작 화면은 85로 고정하고,
/// 그 밖의 탈것만 속도에 따라 느리면 92(약 220m)까지 확대, 빠르면 42(약 140km)까지 축소한다.
enum MapHomePlaybackZoomPolicy {
    static let baselineScale = 85.0
    /// 재생 줌 범위를 좁혔다(대표 지시, ZMP1029A01): 느린 탈것도 정지 배율(85)보다 더 들어가지 않고,
    /// 빠른 탈것도 30(아주 멀리)까지 빠지지 않는다. 92/30 → 85/50.
    static let slowestScale = 85.0
    static let fastestScale = 50.0
    /// 이 속도(m/s)에서 `slowestScale`, `vehicleSpeed`에서 `fastestScale`(로그 비율).
    static let slowSpeed = 1.0
    static let vehicleSpeed = 40.0
    /// 센서 속도만 아는 경우 이 속도 이하는 걷기 이하로 보고 85에 고정한다.
    static let walkingCeiling = 2.5
    static let easing = 0.2

    static var baselineDistance: Double { MapHomeCameraZoomMath.distance(forScale: baselineScale) }

    /// 탈것의 속도에 맞는 배율(로그 비율, 범위 안으로 자른다).
    static func scale(forVehicleSpeed speed: Double) -> Double {
        guard speed.isFinite, speed > 0 else { return slowestScale }
        let clamped = min(vehicleSpeed, max(slowSpeed, speed))
        let ratio = (log(clamped) - log(slowSpeed)) / (log(vehicleSpeed) - log(slowSpeed))
        return slowestScale + ratio * (fastestScale - slowestScale)
    }

    /// 센서 속도만 아는 때(실시간 따라가기)의 목표 거리. 걷기 이하·정지는 85, 그 위는 탈것 곡선. 모르면 nil.
    static func targetDistance(speedMetersPerSecond: Double?) -> Double? {
        guard let speed = speedMetersPerSecond, speed.isFinite, speed >= 0 else { return nil }
        guard speed > walkingCeiling else { return baselineDistance }
        return MapHomeCameraZoomMath.distance(forScale: scale(forVehicleSpeed: speed))
    }

    /// 경로 범위(대각선 m)가 한 화면에 들어오는 배율. 카메라 거리는 보이는 범위의 약 1.9배(시야각)에 여유 1.3을 곱해 정하고,
    /// 너무 넓거나(15 미만) 좁지 않게(60 초과 없음) 자른다.
    static func fitScale(forExtentMeters extent: Double) -> Double {
        guard extent.isFinite, extent > 0,
              let scale = MapHomeCameraZoomMath.scale(distance: extent * 2.43) else { return fastestScale }
        // 긴 이동의 경로 전체 맞춤도 35~70으로 좁힌다(ZMP1029A01, 전에는 15~60).
        return min(70, max(35, Double(scale)))
    }

    static func eased(current: Double, target: Double) -> Double {
        exp(log(current) + (log(target) - log(current)) * easing)
    }
}

enum MapHomePlaybackCameraPolicy {
    static func allowsAutomaticFit(
        isPlaybackRunning: Bool,
        hasUserAdjustedMap: Bool
    ) -> Bool {
        !isPlaybackRunning && !hasUserAdjustedMap
    }

    static func allowsInitialFocus(isPlaybackRunning: Bool) -> Bool {
        !isPlaybackRunning
    }
}

enum MapHomePlaybackCenterPolicy {
    static func shouldCenter(
        previousCoordinate: CLLocationCoordinate2D?,
        previousTargetPoint: CGPoint?,
        coordinate: CLLocationCoordinate2D,
        targetPoint: CGPoint,
        hasPendingViewportCommand: Bool = false
    ) -> Bool {
        guard !hasPendingViewportCommand else { return false }
        guard let previousCoordinate, let previousTargetPoint else {
            return true
        }
        return abs(previousCoordinate.latitude - coordinate.latitude) > 0.000_001
            || abs(previousCoordinate.longitude - coordinate.longitude) > 0.000_001
            || hypot(
                previousTargetPoint.x - targetPoint.x,
                previousTargetPoint.y - targetPoint.y
            ) > 0.5
    }
}

enum MapHomeExpectedRoutePlaybackMath {
    static func progress(
        at date: Date,
        departureDate: Date,
        arrivalDate: Date
    ) -> Double? {
        guard departureDate <= date,
              date <= arrivalDate,
              arrivalDate > departureDate else { return nil }
        return min(
            max(date.timeIntervalSince(departureDate) / arrivalDate.timeIntervalSince(departureDate), 0),
            1
        )
    }

    static func coordinate(
        at date: Date,
        departureDate: Date,
        arrivalDate: Date,
        coordinates: [CLLocationCoordinate2D],
        segmentLengths: [Double]? = nil
    ) -> CLLocationCoordinate2D? {
        guard coordinates.count >= 2,
              departureDate <= date,
              date <= arrivalDate,
              arrivalDate > departureDate else { return nil }

        guard let fraction = progress(
            at: date,
            departureDate: departureDate,
            arrivalDate: arrivalDate
        ) else { return nil }
        return coordinate(
            atProgress: fraction,
            coordinates: coordinates,
            segmentLengths: segmentLengths
        )
    }

    static func segmentLengths(
        for coordinates: [CLLocationCoordinate2D]
    ) -> [Double] {
        zip(coordinates, coordinates.dropFirst()).map {
            CLLocation(latitude: $0.0.latitude, longitude: $0.0.longitude)
                .distance(from: CLLocation(latitude: $0.1.latitude, longitude: $0.1.longitude))
        }
    }

    static func coordinate(
        atProgress progress: Double,
        coordinates: [CLLocationCoordinate2D],
        segmentLengths cachedLengths: [Double]? = nil
    ) -> CLLocationCoordinate2D? {
        guard coordinates.count >= 2 else { return coordinates.first }
        let lengths = cachedLengths?.count == coordinates.count - 1
            ? cachedLengths!
            : segmentLengths(for: coordinates)
        let total = lengths.reduce(0, +)
        guard total > 0 else { return coordinates.first }
        let target = total * min(max(progress, 0), 1)
        var traversed = 0.0
        for (index, length) in lengths.enumerated() {
            guard length > 0 else { continue }
            let next = coordinates[index + 1]
            if traversed + length >= target {
                let ratio = min(max((target - traversed) / length, 0), 1)
                return CLLocationCoordinate2D(
                    latitude: coordinates[index].latitude
                        + (next.latitude - coordinates[index].latitude) * ratio,
                    longitude: RouteTimelineLongitude.interpolate(
                        from: coordinates[index].longitude,
                        to: next.longitude,
                        fraction: ratio
                    )
                )
            }
            traversed += length
        }
        return coordinates.last
    }
}

enum MapHomeRouteTimelinePlaybackMath {
    static func coordinate(
        at date: Date,
        in segments: [RouteTimelineSegment]
    ) -> GeoPoint? {
        guard let segment = segment(at: date, in: segments) else { return nil }
        let progress = progress(at: date, in: segment)
        return interpolate(segment.coordinates, progress: progress)
    }

    static func progress(
        at date: Date,
        in segments: [RouteTimelineSegment]
    ) -> Double? {
        guard let segment = segment(at: date, in: segments) else { return nil }
        return progress(at: date, in: segment)
    }

    private static func segment(
        at date: Date,
        in segments: [RouteTimelineSegment]
    ) -> RouteTimelineSegment? {
        let usable = segments.filter {
            $0.end > $0.start && $0.coordinates.count >= 2
        }
        guard let first = usable.first, let last = usable.last else { return nil }
        if date < first.start { return first }
        if date > last.end { return last }
        return usable.first { $0.start <= date && date <= $0.end }
    }

    private static func progress(
        at date: Date,
        in segment: RouteTimelineSegment
    ) -> Double {
        min(
            max(date.timeIntervalSince(segment.start) / segment.end.timeIntervalSince(segment.start), 0),
            1
        )
    }

    private static func interpolate(
        _ points: [GeoPoint],
        progress: Double
    ) -> GeoPoint? {
        guard let first = points.first else { return nil }
        guard points.count > 1 else { return first }
        let lengths = zip(points, points.dropFirst()).map { distance($0.0, $0.1) }
        let total = lengths.reduce(0, +)
        guard total > 0 else { return first }
        let target = total * min(max(progress, 0), 1)
        var traversed = 0.0
        for (index, length) in lengths.enumerated() where length > 0 {
            if traversed + length >= target {
                let next = points[index + 1]
                let ratio = min(max((target - traversed) / length, 0), 1)
                return GeoPoint(
                    latitude: blend(first: points[index].latitude, second: next.latitude, ratio: ratio),
                    longitude: RouteTimelineLongitude.interpolate(
                        from: points[index].longitude,
                        to: next.longitude,
                        fraction: ratio
                    ),
                    altitude: blend(first: points[index].altitude, second: next.altitude, ratio: ratio),
                    horizontalAccuracy: blend(first: points[index].horizontalAccuracy, second: next.horizontalAccuracy, ratio: ratio),
                    verticalAccuracy: blend(first: points[index].verticalAccuracy, second: next.verticalAccuracy, ratio: ratio)
                )
            }
            traversed += length
        }
        return points.last
    }

    private static func blend(first: Double, second: Double, ratio: Double) -> Double {
        guard first.isFinite, second.isFinite else {
            return first.isFinite ? first : second
        }
        return first + (second - first) * ratio
    }

    private static func distance(_ first: GeoPoint, _ second: GeoPoint) -> Double {
        CLLocation(latitude: first.latitude, longitude: first.longitude)
            .distance(from: CLLocation(latitude: second.latitude, longitude: second.longitude))
    }
}

/// 재생 중 줌 거리 변화를 시간 기준으로 부드럽게 한다. 틱 횟수가 아니라 경과 시간으로 따라가고,
/// 초당 로그 변화량에 상한을 둬서 정지와 이동이 짧게 번갈아도 확대·축소가 튀지 않게 한다.
/// 시정수 0.6/0.9초 → 0.25/0.35초, 상한 1.6/0.9 → 3.2/2.0배/초: 확대·축소가 지금보다 빨리 따라온다(대표 지시, PLY1029A01).
final class MapHomePlaybackZoomSmoother {
    static let timeConstant: TimeInterval = 0.8
    static let maximumLogRate = 1.2
    /// 속도가 줄어 다가갈 때(줌인)는 조금 천천히 따라가되, 너무 늦지 않게 짧은 시간 상수를 쓴다.
    static let zoomInTimeConstant: TimeInterval = 1.1
    static let zoomInMaximumLogRate = 0.9
    static let maximumStep: TimeInterval = 0.5

    private var lastUptime: TimeInterval?

    func next(current: Double, target: Double, uptime: TimeInterval) -> Double {
        defer { lastUptime = uptime }
        guard current.isFinite, current > 0, target.isFinite, target > 0,
              let lastUptime else { return current }
        let dt = min(max(uptime - lastUptime, 0), Self.maximumStep)
        guard dt > 0 else { return current }
        let gap = log(target) - log(current)
        let zoomingIn = gap < 0
        let step = gap * (1 - exp(-dt / (zoomingIn ? Self.zoomInTimeConstant : Self.timeConstant)))
        let limit = (zoomingIn ? Self.zoomInMaximumLogRate : Self.maximumLogRate) * dt
        return exp(log(current) + min(max(step, -limit), limit))
    }

    func reset() { lastUptime = nil }
}

/// 열차 안에서는 iPhone 움직임이 자동차로만 나온다. 구간 확정 전이나 확정 구간이 끝난 뒤의 새 점을
/// 자동차로 보이지 않게 지하철 Wi-Fi·철도 일치·직전 대중교통 구간을 먼저 본다(TRN1105A01). 파생 표시이며 원본은 그대로다.
enum MapHomeLiveTransitPolicy {
    static let maximumReadingAge: TimeInterval = 3 * 60
    static let continuationWindow: TimeInterval = 10 * 60

    static func mode(at date: Date, travel: [TravelSegment], readings: [SensorReading]) -> TravelMode? {
        let containing = travel.filter { $0.span.contains(date) }
        guard !containing.contains(where: \.isConfirmed) else { return nil }
        let earliest = date.addingTimeInterval(-maximumReadingAge)
        let recent = readings.filter { $0.motion.isMovement && $0.timestamp >= earliest && $0.timestamp <= date }
        guard let latest = recent.max(by: { $0.timestamp < $1.timestamp }), latest.motion == .automotive else { return nil }
        if latest.matchesRailRoute || SubwayWiFiSSID.hasContinuousEvidence(streak: latest.subwayWiFiObservationStreak) {
            return .subway
        }
        guard containing.isEmpty else { return nil }
        let earlier = travel
            .filter { $0.span.end <= date && date.timeIntervalSince($0.span.end) <= continuationWindow }
            .max { $0.span.end < $1.span.end }
        guard let earlier, [.subway, .train, .bus].contains(earlier.mode) else { return nil }
        let leftVehicle = readings.contains {
            $0.timestamp >= earlier.span.end && $0.timestamp <= date
                && [.walking, .running, .cycling].contains($0.motion)
        }
        return leftVehicle ? nil : earlier.mode
    }
}
