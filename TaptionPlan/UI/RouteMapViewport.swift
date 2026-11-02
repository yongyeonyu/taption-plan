import SwiftUI
import UIKit
import MapKit

struct RouteMapViewport {
    struct Padding: Equatable {
        let top: CGFloat
        let leading: CGFloat
        let bottom: CGFloat
        let trailing: CGFloat

        static let timeline = Padding(
            top: 34,
            leading: 22,
            bottom: 28,
            trailing: 22
        )
        static let compact = Padding(
            top: 26,
            leading: 18,
            bottom: 22,
            trailing: 18
        )
    }

    static func region(
        for coordinates: [CLLocationCoordinate2D],
        viewport: CGSize,
        padding: Padding,
        minimumLatitudeDelta: CLLocationDegrees = 0.005,
        minimumLongitudeDelta: CLLocationDegrees = 0.005
    ) -> MKCoordinateRegion? {
        region(
            for: [coordinates],
            viewport: viewport,
            padding: padding,
            minimumLatitudeDelta: minimumLatitudeDelta,
            minimumLongitudeDelta: minimumLongitudeDelta
        )
    }

    static func region(
        for paths: [[CLLocationCoordinate2D]],
        viewport: CGSize,
        padding: Padding,
        minimumLatitudeDelta: CLLocationDegrees = 0.005,
        minimumLongitudeDelta: CLLocationDegrees = 0.005
    ) -> MKCoordinateRegion? {
        var minLatitude = Double.infinity
        var maxLatitude = -Double.infinity
        var longitudes: [Double] = []

        for path in paths {
            for coordinate in path where CLLocationCoordinate2DIsValid(coordinate) {
                minLatitude = min(minLatitude, coordinate.latitude)
                maxLatitude = max(maxLatitude, coordinate.latitude)
                let longitude = (
                    coordinate.longitude.truncatingRemainder(dividingBy: 360) + 360
                ).truncatingRemainder(dividingBy: 360)
                longitudes.append(longitude)
            }
        }

        guard minLatitude <= maxLatitude, !longitudes.isEmpty else { return nil }
        longitudes.sort()
        var largestGap = -Double.infinity
        var minLongitude = longitudes[0]
        var maxLongitude = longitudes[0]
        for index in longitudes.indices {
            let current = longitudes[index]
            let next = index + 1 < longitudes.count
                ? longitudes[index + 1]
                : longitudes[0] + 360
            let gap = next - current
            guard gap > largestGap else { continue }
            largestGap = gap
            minLongitude = next.truncatingRemainder(dividingBy: 360)
            maxLongitude = current
            if maxLongitude < minLongitude {
                maxLongitude += 360
            }
        }
        return region(
            fromLatitudes: (minLatitude, maxLatitude),
            longitudes: (minLongitude, maxLongitude),
            viewport: viewport,
            padding: padding,
            minimumLatitudeDelta: minimumLatitudeDelta,
            minimumLongitudeDelta: minimumLongitudeDelta
        )
    }

    static func region(
        fromLatitudes latitudes: (Double, Double),
        longitudes: (Double, Double),
        viewport: CGSize,
        padding: Padding,
        minimumLatitudeDelta: CLLocationDegrees = 0.005,
        minimumLongitudeDelta: CLLocationDegrees = 0.005
    ) -> MKCoordinateRegion {
        let width = max(1, Double(viewport.width))
        let height = max(1, Double(viewport.height))
        let horizontalPadding = min(
            width - 1,
            Double(padding.leading + padding.trailing)
        )
        let verticalPadding = min(
            height - 1,
            Double(padding.top + padding.bottom)
        )
        let availableWidth = max(1, width - horizontalPadding)
        let availableHeight = max(1, height - verticalPadding)
        let centerLatitude = (latitudes.0 + latitudes.1) / 2
        let centerLongitude = RouteTimelineLongitude.normalized(
            (longitudes.0 + longitudes.1) / 2
        )
        let longitudeScale = max(
            0.15,
            abs(cos(centerLatitude * .pi / 180))
        )
        let routeHeight = max(0, latitudes.1 - latitudes.0)
        let routeWidth = max(0, longitudes.1 - longitudes.0) * longitudeScale
        let mapScale = max(
            routeWidth / availableWidth,
            routeHeight / availableHeight,
            minimumLatitudeDelta / height,
            minimumLongitudeDelta * longitudeScale / width
        )

        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: centerLatitude,
                longitude: centerLongitude
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max(minimumLatitudeDelta, mapScale * height),
                longitudeDelta: max(
                    minimumLongitudeDelta,
                    mapScale * width / longitudeScale
                )
            )
        )
    }
}

enum TimelineRouteDisplayPolicy {
    static func segments(
        from travel: [TravelSegment],
        intersecting activeSpan: TimeSpan,
        at playheadDate: Date?,
        selectedTravelID: UUID? = nil
    ) -> [TravelSegment] {
        if let selectedTravelID {
            return travel.filter { $0.id == selectedTravelID }
        }
        if let playheadDate {
            return travel.filter { $0.span.contains(playheadDate) }
        }
        return travel.filter {
            $0.span.intersection(with: activeSpan) != nil
        }
    }

    static func allowsFallbackPath(
        at playheadDate: Date?,
        routeSegments: [TravelSegment]
    ) -> Bool {
        playheadDate == nil || !routeSegments.isEmpty
    }

    /// 지도에 함께 깔아 둘 기간. 시간표가 보여 주는 기간을 그대로 쓴다.
    /// 년 눈금은 이동 수천 개가 한 화면에 뭉쳐 뜻을 잃으므로 배경을 깔지
    /// 않고 고른 구간만 남긴다.
    static func contextSpan(
        for level: TimelineLevel,
        visibleSpan: TimeSpan
    ) -> TimeSpan? {
        switch level {
        case .day, .week, .month: visibleSpan
        case .year: nil
        }
    }

    /// 센서 기록은 7일만 보관한다. 그보다 오래된 구간을 읽어도 좌표가
    /// 없으므로 지도용 기록 읽기 구간은 보관 기간까지만 넓힌다.
    static let readingRetentionWindow: TimeInterval = 8 * 86_400

    static func readingSpan(
        context: TimeSpan?,
        fallback: TimeSpan,
        now: Date = .now
    ) -> TimeSpan {
        guard let context else { return fallback }
        // 하루 경계로 끊어 두어야 이 구간이 화면을 다시 그릴 때마다
        // 달라지지 않는다. 값이 흔들리면 기록 읽기 작업이 끝없이 다시
        // 시작한다.
        let earliest = Calendar.autoupdatingCurrent
            .startOfDay(for: now)
            .addingTimeInterval(-readingRetentionWindow)
        guard context.end > earliest else { return fallback }
        return TimeSpan(start: max(context.start, earliest), end: context.end)
    }

    /// 한 화면에 배경으로 깔 이동 구간 수. 한 달이면 수백 개가 나오는데
    /// 짧은 구간은 서로 겹쳐 화소 아래로 사라지므로 거리가 긴 순서로만
    /// 남긴다.
    static let maximumContextSegments = 120

    static func contextSegments(
        from travel: [TravelSegment],
        intersecting span: TimeSpan,
        limit: Int = maximumContextSegments
    ) -> [TravelSegment] {
        let candidates = travel.filter {
            $0.span.intersection(with: span) != nil
        }
        guard candidates.count > limit else {
            return candidates.sorted { $0.span.start < $1.span.start }
        }
        return candidates
            .sorted { lhs, rhs in
                if lhs.distanceMeters == rhs.distanceMeters {
                    return lhs.span.start < rhs.span.start
                }
                return lhs.distanceMeters > rhs.distanceMeters
            }
            .prefix(limit)
            .sorted { $0.span.start < $1.span.start }
    }
}
