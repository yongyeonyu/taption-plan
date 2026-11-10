import CoreLocation
import Foundation

// 재생 중 화랑이가 사라지지 않게 하는 두 가지 보정.
//
// ① `MapHomePlaybackLocation.resolve`는 재생 프레임 → 지하철 좌표 → 예상 경로 좌표 →
//    센서 기록 순으로 찾는다. 그런데 예상 경로 요청은 *센서가 끊긴 틈*에서만 만들어지므로,
//    기록이 아예 없는 미확인 이동(걷기 등)은 네 갈래 모두 비어 화랑이가 통째로 사라졌다.
//    출발·도착 장소 좌표를 시각 비율로 이어 그 구간에서도 계속 보이게 한다.
//
// ② 재생 배속은 지금까지 '확정 이동 + 이동 센서'에서만 이동 속도를 받았다. 그래서 미확인
//    이동은 정지 배속(초당 120분)으로 지나가 한순간에 사라졌다. 배속을 대분류로 정한다:
//    대분류 '이동'이면 이동 배속, 나머지(수면·업무·식사·취미·운동·활동)는 정지 배속.
//
// ③ 지하철은 자동 분류 구간이 늘 `isConfirmed == false`라 노선 위에 올라가지 못했다.
//    확정 여부와 상관없이 노선 위를 달리게 한다(지하 GPS가 없어 프레임도 비는 구간).

extension MapHomePlaybackLocation {
    /// `resolve`가 nil일 때 이동 구간 위의 점으로 이어 준다.
    static func resolveOrGap(
        at date: Date,
        frame: MapHomeWBSPlaybackFrame?,
        normalizedReadings: [SensorReading],
        travel: [TravelSegment],
        places: [PlaceStay],
        expectedCoordinate: GeoPoint? = nil,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Self? {
        if let resolved = resolve(
            at: date,
            frame: frame,
            normalizedReadings: normalizedReadings,
            confirmedTravel: travel,
            // 앞뒤 표본이 있는 시각에 예상 경로를 쓰면 출발지(집)로 튄다.
            expectedCoordinate: sensorGapCoordinate(at: date, readings: normalizedReadings) == nil ? expectedCoordinate : nil,
            calendar: calendar
        ) {
            return resolved
        }
        guard let point = sensorGapCoordinate(at: date, readings: normalizedReadings)
                ?? gapCoordinate(at: date, travel: travel, places: places) else {
            return nil
        }
        return Self(coordinate: point)
    }

    /// 표본이 없는 시간의 자리. 수면이면 그 시간의 체류 → 집, 그날 첫 표본 전이면 첫 표본이다.
    /// 이게 없으면 슬라이드바를 거슬러 가도 카메라가 멈추고 화랑이가 마지막 위치에 남는다.
    static func restingLocation(
        at date: Date,
        normalizedReadings readings: [SensorReading],
        places: [PlaceStay],
        sleepSpans: [TimeSpan],
        home: GeoPoint?
    ) -> Self? {
        if sleepSpans.contains(where: { $0.contains(date) }),
           let point = places.first(where: { $0.span.contains(date) })?.point ?? home {
            return Self(coordinate: point)
        }
        guard let first = readings.first(where: { $0.point != nil }), date < first.timestamp, let point = first.point else { return nil }
        return Self(coordinate: point)
    }

    /// 재생 프레임용: 장소 좌표 사전과 지하철 구간을 미리 만든 `lookup`을 쓴다(PRF1101A01).
    static func resolveOrGap(
        at date: Date,
        frame: MapHomeWBSPlaybackFrame?,
        normalizedReadings: [SensorReading],
        travel: [TravelSegment],
        lookup: MapHomePlaybackLookup,
        expectedCoordinate: GeoPoint? = nil
    ) -> Self? {
        if let resolved = resolve(
            at: date,
            frame: frame,
            normalizedReadings: normalizedReadings,
            confirmedTravel: lookup.subwayTravel,
            expectedCoordinate: sensorGapCoordinate(at: date, readings: normalizedReadings) == nil ? expectedCoordinate : nil
        ) {
            return resolved
        }
        return (sensorGapCoordinate(at: date, readings: normalizedReadings)
            ?? gapCoordinate(at: date, travel: travel, placePoints: lookup.placePoints)).map { Self(coordinate: $0) }
    }

    /// 이동 구간의 출발·도착 장소 좌표를 시각 비율로 잇는다. 여러 구간이 겹치면 늦게 시작한 쪽을 쓴다.
    static func gapCoordinate(
        at date: Date,
        travel: [TravelSegment],
        places: [PlaceStay]
    ) -> GeoPoint? {
        gapCoordinate(at: date, travel: travel, placePoints: MapHomePlaybackLookup.placePoints(places))
    }

    static func gapCoordinate(
        at date: Date,
        travel: [TravelSegment],
        placePoints points: [UUID: GeoPoint]
    ) -> GeoPoint? {
        let active = travel
            .filter { $0.span.contains(date) }
            .sorted { $0.span.start < $1.span.start }
        for segment in active.reversed() {
            guard let from = segment.fromPlaceID.flatMap({ points[$0] }),
                  let to = segment.toPlaceID.flatMap({ points[$0] }),
                  segment.span.duration > 0 else { continue }
            let elapsed: TimeInterval = date.timeIntervalSince(segment.span.start)
            let rawProgress: Double = elapsed / segment.span.duration
            let progress: Double = min(1, max(0, rawProgress))
            let latitude: Double = from.latitude + (to.latitude - from.latitude) * progress
            let longitude: Double = from.longitude + (to.longitude - from.longitude) * progress
            return GeoPoint(
                latitude: latitude,
                longitude: longitude,
                altitude: from.altitude + (to.altitude - from.altitude) * progress,
                horizontalAccuracy: max(from.horizontalAccuracy, to.horizontalAccuracy),
                verticalAccuracy: max(from.verticalAccuracy, to.verticalAccuracy)
            )
        }
        return nil
    }

    /// 지하철 구간이면 **확정 여부와 상관없이** 노선 위의 점을 준다.
    ///
    /// `resolve`는 오랫동안 `isConfirmed`인 지하철만 노선 위에 올렸다. 그런데 그 값은
    /// "사용자가 모드를 직접 고쳤다"는 뜻이라, 자동으로 분류된 지하철은 늘 false다.
    /// 그래서 지하철을 타고 이동한 시간에는 재생 프레임도(지하 GPS 없음) 확정 노선도
    /// 없어 화랑이가 통째로 사라지거나 출발역 GPS에 붙어 있었다(대표 지적, 2026-10-28).
    /// 지도에 예상 노선이 그려져 있으면 화랑이는 그 선을 타고 가야 한다.
    static func subwayCoordinate(
        at date: Date,
        travel: [TravelSegment],
        readings: [SensorReading] = []
    ) -> GeoPoint? {
        // 선로 모양을 따라 간다. 탑승 안에서는 GPS 직선 프레임보다 먼저 쓴다(SUB1108A01).
        let active = travel.filter { SubwayRideTrack.isRide($0) && $0.span.contains(date) }
        guard let segment = active.max(by: { $0.span.start < $1.span.start }) else {
            // 환승 걷기도 내린 자리에서 이어 간다. 탑승 앞뒤 GPS를 이은 직선은 뒤로 튄다(PLY1108A01).
            return subwayTransferCoordinate(at: date, travel: travel, readings: readings)
        }
        return subwayGapCoordinate(at: date, segment: segment, readings: readings)
    }

    /// 화랑이를 그릴 좌표. 위경도만 본다(PLY1108A01).
    /// 선로·역·예상 경로 좌표는 정확도가 -1(측정이 아니라 계산한 자리)이다. 화면이 정확도 0 이상만 받아
    /// SUB1108A01 뒤로 탑승 내내 화랑이가 사라지고 구동기가 그리는 화살표만 남았다.
    static func lastRecordedCoordinate(in readings: [SensorReading]) -> CLLocationCoordinate2D? {
        readings.max { ($0.point == nil ? .distantPast : $0.timestamp) < ($1.point == nil ? .distantPast : $1.timestamp) }?
            .point.flatMap(drawableCoordinate)
    }

    static func drawableCoordinate(_ point: GeoPoint) -> CLLocationCoordinate2D? {
        guard point.latitude.isFinite, point.longitude.isFinite else { return nil }
        let coordinate = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
        return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
    }

    /// 이어진 두 탑승 사이(환승 걷기)의 자리. 앞 탑승이 내린 선로 위치 → 그 사이 믿을 만한 GPS → 다음 탑승이 타는
    /// 선로 위치를 시간 비율로 잇는다(PLY1108A01). 예전에는 탑승 전 GPS와 환승 뒤 GPS를 이은 직선을 따라가, 내린 자리에서
    /// 노선 뒤쪽으로 수백 m 튀었다가 다시 걸어왔다(11-05 원본 22:32:51에 865m). `readings`는 시각순이어야 한다.
    static func subwayTransferCoordinate(at date: Date, travel: [TravelSegment], readings: [SensorReading]) -> GeoPoint? {
        let rides = travel.filter(SubwayRideTrack.isRide)
        guard let previous = rides.filter({ $0.span.end <= date }).max(by: { $0.span.end < $1.span.end }),
              let next = rides.filter({ $0.span.start > date }).min(by: { $0.span.start < $1.span.start }),
              next.span.start.timeIntervalSince(previous.span.end) <= SubwayRideTrack.maximumJourneyGap,
              let exit = rideEndpoint(previous, readings: readings, atEnd: true),
              let entry = rideEndpoint(next, readings: readings, atEnd: false) else { return nil }
        var anchors: [(date: Date, point: GeoPoint)] = [(previous.span.end, exit)]
        var lower = 0, upper = readings.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if readings[middle].timestamp <= previous.span.end { lower = middle + 1 } else { upper = middle }
        }
        for reading in readings[lower...] {
            guard reading.timestamp < next.span.start else { break }
            if reading.gpsAvailable, let point = reading.point,
               point.horizontalAccuracy <= SubwayRideTrack.trustedAccuracyMeters { anchors.append((reading.timestamp, point)) }
        }
        anchors.append((next.span.start, entry))
        guard let index = anchors.firstIndex(where: { $0.date >= date }) else { return entry }
        guard index > 0 else { return anchors[0].point }
        let a = anchors[index - 1], b = anchors[index]
        let duration = b.date.timeIntervalSince(a.date)
        let t = duration > 0 ? min(1, max(0, date.timeIntervalSince(a.date) / duration)) : 1
        return GeoPoint(
            latitude: a.point.latitude + (b.point.latitude - a.point.latitude) * t,
            longitude: a.point.longitude + (b.point.longitude - a.point.longitude) * t,
            altitude: a.point.altitude + (b.point.altitude - a.point.altitude) * t,
            horizontalAccuracy: max(a.point.horizontalAccuracy, b.point.horizontalAccuracy),
            verticalAccuracy: max(a.point.verticalAccuracy, b.point.verticalAccuracy)
        )
    }

    /// 탑승의 처음(타는 자리)·끝(내리는 자리) 선로 위치. 재생 위치와 같은 기준점을 쓴다.
    private static func rideEndpoint(_ segment: TravelSegment, readings: [SensorReading], atEnd: Bool) -> GeoPoint? {
        guard let line = SubwayTrackLine(route: segment.subwayRoute) else { return nil }
        let anchors = line.anchors(segment: segment, readings: readings)
        guard let meters = atEnd ? anchors.last?.meters : anchors.first?.meters else { return nil }
        return line.point(atMeters: meters)
    }
}

/// GPS가 끊긴 미확인 구간(PLB1103A01). 지하철은 노선 위로, 나머지는 앞뒤 표본 사이 직선을 거리÷시간의 예상 속도로 잇고
/// 수단은 저장된 이동 구간, 없으면 앞뒤 표본으로 정한다. 비행기·지하차도에서도 화랑이가 끊기지 않는다.
extension MapHomePlaybackLocation {
    private static let minimumGapMoveMeters = 150.0
    private static let minimumFlightSpeed = 55.0
    private static let minimumFlightMeters = 100_000.0
    /// 사람이 계속 걷거나 뛰어서 낼 수 없는 평균 속도.
    private static let minimumPossibleVehicleSpeed = 4.0
    private static let adjacentWindow: TimeInterval = 10 * 60

    private static func sensorGap(at date: Date, readings: [SensorReading]) -> (before: SensorReading, after: SensorReading)? {
        var lower = 0, upper = readings.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if readings[middle].timestamp <= date { lower = middle + 1 } else { upper = middle }
        }
        func trusted(_ reading: SensorReading) -> Bool {
            reading.gpsAvailable && (reading.point?.horizontalAccuracy ?? .infinity) <= trustedAccuracyMeters
        }
        guard let before = readings[..<lower].last(where: trusted),
              let after = readings[lower...].first(where: trusted) else { return nil }
        return (before, after)
    }

    static func sensorGapCoordinate(at date: Date, readings: [SensorReading]) -> GeoPoint? {
        guard let gap = sensorGap(at: date, readings: readings),
              let from = gap.before.point, let to = gap.after.point else { return nil }
        let duration = gap.after.timestamp.timeIntervalSince(gap.before.timestamp)
        guard duration > 0 else { return from }
        let t = min(1, max(0, date.timeIntervalSince(gap.before.timestamp) / duration))
        return GeoPoint(
            latitude: from.latitude + (to.latitude - from.latitude) * t,
            longitude: from.longitude + (to.longitude - from.longitude) * t,
            altitude: from.altitude + (to.altitude - from.altitude) * t,
            horizontalAccuracy: max(from.horizontalAccuracy, to.horizontalAccuracy),
            verticalAccuracy: max(from.verticalAccuracy, to.verticalAccuracy)
        )
    }

    /// 미확인 구간의 진행 방향. 지하철은 노선을 따라, 나머지는 앞 표본에서 뒤 표본 쪽이다.
    static func gapHeading(at date: Date, travel: [TravelSegment], readings: [SensorReading]) -> CLLocationDirection? {
        func bearing(_ from: GeoPoint, _ to: GeoPoint) -> CLLocationDirection? {
            guard PlanarDistance.meters(from, to) >= 1 else { return nil }
            return MapHomeVectorNavigationMath.bearing(
                from: CLLocationCoordinate2D(latitude: from.latitude, longitude: from.longitude),
                to: CLLocationCoordinate2D(latitude: to.latitude, longitude: to.longitude)
            )
        }
        if let here = subwayCoordinate(at: date, travel: travel, readings: readings),
           let next = subwayCoordinate(at: date.addingTimeInterval(30), travel: travel, readings: readings),
           let heading = bearing(here, next) { return heading }
        guard let gap = sensorGap(at: date, readings: readings), let from = gap.before.point, let to = gap.after.point,
              PlanarDistance.meters(from, to) >= minimumGapMoveMeters else { return nil }
        return bearing(from, to)
    }

    /// 미확인 구간의 수단을 앞뒤 근거로 추정한다. 움직이지 않았으면 nil이라 머문 자리의 동작을 그대로 쓴다.
    /// 순서: 저장된 이동 구간 → 비행 거리·속도 → 항구 → 역과 역 → 앞뒤 차량 연결 → 걸을 수 없는 속도 → 앞뒤 걷기.
    static func gapMode(at date: Date, travel: [TravelSegment], readings: [SensorReading]) -> TravelMode? {
        if let segment = travel.last(where: { $0.span.contains(date) }) { return segment.mode }
        guard let gap = sensorGap(at: date, readings: readings),
              let from = gap.before.point, let to = gap.after.point else { return nil }
        let duration = gap.after.timestamp.timeIntervalSince(gap.before.timestamp)
        let distance = PlanarDistance.meters(from, to)
        guard duration > 0, distance >= minimumGapMoveMeters else { return nil }
        let speed = distance / duration
        if distance >= minimumFlightMeters, speed >= minimumFlightSpeed
            || gap.before.nearAirport == true && gap.after.nearAirport == true { return .airplane }
        if gap.before.nearPort == true, gap.after.nearPort == true, speed >= minimumPossibleVehicleSpeed { return .ship }
        let hasCarAudio = gap.before.carAudioRouteName?.isEmpty == false || gap.after.carAudioRouteName?.isEmpty == false
        if !hasCarAudio, speed >= minimumPossibleVehicleSpeed,
           let first = SubwayStationCatalog.nearest(to: from, maximumDistanceMeters: SubwayEvidenceGate.stationRadiusMeters),
           let last = SubwayStationCatalog.nearest(to: to, maximumDistanceMeters: SubwayEvidenceGate.stationRadiusMeters),
           first.stationName != last.stationName { return .subway }
        let previous = adjacentMode(before: gap.before.timestamp, travel: travel) ?? mode(for: gap.before.motion)
        let next = adjacentMode(after: gap.after.timestamp, travel: travel) ?? mode(for: gap.after.motion)
        for candidate in [previous, next] {
            if let candidate, ![TravelMode.walking, .running, .cycling].contains(candidate) { return candidate }
        }
        if speed >= minimumPossibleVehicleSpeed { return .car }
        return previous ?? next
    }

    private static func adjacentMode(before date: Date, travel: [TravelSegment]) -> TravelMode? {
        travel.last { $0.span.end <= date.addingTimeInterval(60) && date.timeIntervalSince($0.span.end) <= adjacentWindow }?.mode
    }

    private static func adjacentMode(after date: Date, travel: [TravelSegment]) -> TravelMode? {
        travel.first { $0.span.start >= date.addingTimeInterval(-60) && $0.span.start.timeIntervalSince(date) <= adjacentWindow }?.mode
    }

    private static func mode(for motion: MotionKind?) -> TravelMode? {
        switch motion {
        case .automotive: .car
        case .walking: .walking
        case .running: .running
        case .cycling: .cycling
        default: nil
        }
    }

    private static let trustedAccuracyMeters = 150.0

    /// 지하철 구간 안에서 모션이 자동차라고 해도 지하철이다. 환승 걷기는 그대로 둔다.
    static func ridingMode(_ mode: TravelMode?, at date: Date, travel: [TravelSegment]) -> TravelMode? {
        guard mode != .walking, mode != .running, mode != .cycling,
              travel.contains(where: { $0.mode == .subway && $0.span.contains(date) }) else { return mode }
        return .subway
    }

    private static let minimumDrawnGap: TimeInterval = 120

    /// 지하철 구간에서 표본이 끊긴 부분의 선로 조각. 표본이 이어진 곳은 실제 경로가 있어 그리지 않는다.
    /// 역 직선이 아니라 선로 모양을 따른다. 직선이면 선로 옆에 나란한 미확인 발자국이 생겼다(SUB1108A01).
    static func subwayGapRoutes(segment: TravelSegment, readings: [SensorReading], through cutoff: Date) -> [[GeoPoint]] {
        guard let line = SubwayTrackLine(route: segment.subwayRoute) else { return [] }
        let anchors = line.anchors(segment: segment, readings: readings.sorted { $0.timestamp < $1.timestamp },
                                   through: min(cutoff, segment.span.end))
        return zip(anchors, anchors.dropFirst()).compactMap { from, to in
            guard to.date.timeIntervalSince(from.date) >= minimumDrawnGap, to.meters > from.meters else { return nil }
            return line.slice(from: from.meters, to: to.meters)
        }
    }

    /// 지하철 구간의 재생 위치. 믿을 만한 표본 사이를 선로를 따라 시간 비율로 잇는다(`readings`는 시각순).
    static func subwayGapCoordinate(at date: Date, segment: TravelSegment, readings: [SensorReading]) -> GeoPoint? {
        guard let line = SubwayTrackLine(route: segment.subwayRoute),
              let meters = SubwayTrackLine.meters(at: date, anchors: line.anchors(segment: segment, readings: readings))
        else { return nil }
        return line.point(atMeters: meters)
    }

}

extension RouteConfirmedSubwayIntervalIndex {
    /// 사용자가 확인했거나 하루 판정이 역 → 역으로 확정한 지하철만 노선을 그린다(SUB1103A01).
    /// 자동 판정은 `isConfirmed`를 쓰지 않아, 이것만 보면 지하철을 타도 예상 경로가 사라진다.
    static func hasTrustedSubwayRoute(_ segment: TravelSegment) -> Bool {
        guard segment.mode == .subway else { return false }
        return segment.isConfirmed
            || (segment.confidence == .high
                && segment.evidence.contains("지하철 노선 후보 확정")
                && !ActivityClassificationLockEngine.isRememberedOnlySubway(segment))
    }
}

enum MapHomePlaybackCategoryRanges {
    /// 대분류가 수면인 시간은 이동 범위에서 뺀다. 센서·이동 구간이 겹쳐도 정지 배속으로 지나간다(CAT1029A01).
    static func removingSleep(
        _ ranges: [MapHomePlaybackMovementRange],
        snapshot: PlanDayDataSnapshot?,
        dayStart: Date
    ) -> [MapHomePlaybackMovementRange] {
        let sleep = (snapshot?.actuals ?? []).filter(AutomaticRecordTimelineEngine.isSleep).map { actual in
            (start: actual.startedAt.timeIntervalSince(dayStart) / 60,
             end: (actual.endedAt ?? actual.startedAt).timeIntervalSince(dayStart) / 60,
             mode: TravelMode?.none, isStationary: true)
        }
        guard !sleep.isEmpty else { return ranges }
        return ranges.flatMap { range in
            MapHomePlaybackMovementRange.carved(range, details: sleep)
        }
    }

    /// 대분류 '이동' 구간을 재생 속도 범위로 만든다.
    ///
    /// 확정 여부·센서 유무와 상관없이 이동으로 분류된 시간은 모두 이동 배속으로 지나간다.
    /// 나머지 대분류는 범위를 만들지 않는다(범위가 없으면 정지 배속).
    static func movementRanges(
        snapshot: PlanDayDataSnapshot?,
        frequentPlaces: [FrequentPlace],
        dayStart: Date,
        dayEnd: Date
    ) -> [MapHomePlaybackMovementRange] {
        let placeKinds = FrequentPlaceResolutionEngine().kindsByPlaceKey(frequentPlaces)
        let phases = DayPhaseEngine.completePhases(
            actuals: snapshot?.actuals ?? [],
            travel: snapshot?.travel ?? [],
            stays: snapshot?.places ?? [],
            placeKinds: placeKinds,
            in: TimeSpan(start: dayStart, end: dayEnd)
        )
        return phases
            .filter { $0.phase == .movement }
            .map { value in
                MapHomePlaybackMovementRange(
                    startMinute: value.span.start.timeIntervalSince(dayStart) / 60,
                    endMinute: value.span.end.timeIntervalSince(dayStart) / 60,
                    mode: nil
                )
            }
    }
}
