import Foundation
import TaptionPlanCore

/// 장소 → 대분류 → 상세 활동 순서로 보여 준다(대표 결정, CLP1105A01). 화면에만 쓰는 파생 값이고 원본 기록은 바꾸지 않는다.
enum MapHomePlaceFirstPolicy {
    struct Zone: Equatable {
        let startMinute: Int
        let endMinute: Int
        let categoryID: String
    }

    /// 걷기를 그 곳의 대분류로 볼 만큼 등록 지점과 겹치는 비율.
    static let minimumZoneShare = 0.7

    static func categoryID(for kind: FrequentPlaceKind) -> String? {
        switch kind {
        case .home: "rest"
        case .company: "work"
        case .school, .academy: "study"
        case .hobby: "hobby"
        case .exercise: "exercise"
        case .restaurant: "eating"
        case .custom: nil
        }
    }

    static func apply(
        to segments: [MapHomeTimeRailSegment],
        stays: [PlaceStay],
        frequentPlaces: [FrequentPlace],
        on date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [MapHomeTimeRailSegment] {
        let dayStart = calendar.startOfDay(for: date)
        let kinds = frequentPlaces.reduce(into: [String: FrequentPlaceKind]()) { $0[$1.stablePlaceKey] = $1.kind }
        let registered = stays.compactMap { stay -> (key: String, start: Int, end: Int)? in
            guard kinds[stay.placeKey] != nil else { return nil }
            return (
                stay.placeKey,
                max(0, Int(stay.span.start.timeIntervalSince(dayStart) / 60)),
                min(1_440, Int(stay.span.end.timeIntervalSince(dayStart) / 60))
            )
        }
        let zones = zones(
            stays: registered.map { ($0.key, $0.start, $0.end) },
            categoryForKey: { kinds[$0].flatMap(categoryID(for:)) },
            vehicleSpans: segments.filter(isVehicle).map { $0.startMinute..<$0.endMinute }
        )
        return merged(segments.map { assign($0, zones: zones) })
    }

    /// 같은 곳의 머문 기록은 그 사이에 차로 이동하지 않았다면 이어서 본다. 건물 안에서는 위치가 끊기기도 한다.
    static func zones(
        stays: [(key: String, start: Int, end: Int)],
        categoryForKey: (String) -> String?,
        vehicleSpans: [Range<Int>]
    ) -> [Zone] {
        var joined: [(key: String, start: Int, end: Int)] = []
        for stay in stays.sorted(by: { $0.start < $1.start }) where stay.end > stay.start {
            if let last = joined.last, last.key == stay.key,
               !vehicleSpans.contains(where: { $0.lowerBound < stay.start && $0.upperBound > last.end }) {
                joined[joined.count - 1].end = max(last.end, stay.end)
            } else {
                joined.append(stay)
            }
        }
        return joined.compactMap { stay in
            categoryForKey(stay.key).map { Zone(startMinute: stay.start, endMinute: stay.end, categoryID: $0) }
        }
    }

    static func isWalking(_ segment: MapHomeTimeRailSegment) -> Bool {
        guard segment.categoryID == "movement" || segment.categoryID == "activity" else { return false }
        return segment.behavior == WatchBehaviorKind.walking.rawValue || segment.title == "걷기" || segment.title == "Walking"
    }

    private static func isVehicle(_ segment: MapHomeTimeRailSegment) -> Bool {
        segment.categoryID == "movement" && !isWalking(segment)
    }

    static func assign(_ segment: MapHomeTimeRailSegment, zones: [Zone]) -> MapHomeTimeRailSegment {
        guard isWalking(segment), segment.endMinute > segment.startMinute else { return segment }
        let length = Double(segment.endMinute - segment.startMinute)
        let zone = zones.first {
            Double(min($0.endMinute, segment.endMinute) - max($0.startMinute, segment.startMinute)) / length >= minimumZoneShare
        }
        guard let zone else { return segment }
        var result = MapHomeTimeRailSegment(
            startMinute: segment.startMinute,
            endMinute: segment.endMinute,
            categoryID: zone.categoryID,
            title: TimelineRowKind.title(forCategoryID: zone.categoryID) ?? segment.title,
            sourceIDs: segment.sourceIDs
        )
        result.walkSpans = [segment.startMinute..<segment.endMinute]
        return result
    }

    /// 대분류 줄에는 대분류만 나오므로 이어진 같은 대분류를 하나로 잇는다.
    static func merged(_ segments: [MapHomeTimeRailSegment]) -> [MapHomeTimeRailSegment] {
        var result: [MapHomeTimeRailSegment] = []
        for segment in segments.sorted(by: { $0.startMinute < $1.startMinute }) {
            guard let last = result.last, last.endMinute == segment.startMinute, last.categoryID == segment.categoryID else {
                result.append(segment)
                continue
            }
            var joined = MapHomeTimeRailSegment(
                startMinute: last.startMinute,
                endMinute: segment.endMinute,
                categoryID: last.categoryID,
                title: TimelineRowKind.title(forCategoryID: last.categoryID) ?? last.title,
                behavior: last.behavior == segment.behavior ? last.behavior : nil,
                sourceIDs: last.sourceIDs + segment.sourceIDs
            )
            joined.walkSpans = last.walkSpans + segment.walkSpans
            result[result.count - 1] = joined
        }
        return result
    }
}

enum MapHomeWeatherRailAlignmentMath {
    static let itemTrailingInset: CGFloat = 1

    static func weatherOriginX(
        weatherRailWidth: CGFloat,
        timeRailWidth _: CGFloat
    ) -> CGFloat {
        return MapHomeTimeSidebarMath.handleLaneWidth
            - weatherRailWidth
            + itemTrailingInset
            - MapHomeTimeSidebarMath.weatherDockGap
    }

}
