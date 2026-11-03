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
            expectedCoordinate: expectedCoordinate,
            calendar: calendar
        ) {
            return resolved
        }
        guard let point = gapCoordinate(at: date, travel: travel, places: places) else {
            return nil
        }
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
            expectedCoordinate: expectedCoordinate
        ) {
            return resolved
        }
        return gapCoordinate(at: date, travel: travel, placePoints: lookup.placePoints).map { Self(coordinate: $0) }
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
        let active = travel.filter { segment in
            segment.mode == .subway
                && segment.span.contains(date)
                && segment.subwayRoute.map(SubwayStationCatalog.isValid) == true
        }
        guard var segment = active.max(by: { $0.span.start < $1.span.start }) else {
            return nil
        }
        if let point = subwayGapCoordinate(at: date, segment: segment, readings: readings) { return point }
        // 확정 구간과 **같은 계산**을 쓰려고 확정 표시만 세운다. 좌표 계산에는 쓰이지 않는다.
        segment.isConfirmed = true
        return RouteTimelineDataEngine.confirmedSubwayCoordinates(
            for: segment,
            through: date
        ).last
    }
}

/// 표본이 빈 지하철 구간(PLB1103A01). 앞뒤 표본을 노선에 투영해 그 사이를 거리÷시간의 예상 속도로 잇는다.
extension MapHomePlaybackLocation {
    private static let trustedAccuracyMeters = 150.0

    /// 지하철 구간 안에서 모션이 자동차라고 해도 지하철이다. 환승 걷기는 그대로 둔다.
    static func ridingMode(_ mode: TravelMode?, at date: Date, travel: [TravelSegment]) -> TravelMode? {
        guard mode != .walking, mode != .running, mode != .cycling,
              travel.contains(where: { $0.mode == .subway && $0.span.contains(date) }) else { return mode }
        return .subway
    }

    static func subwayGapCoordinate(at date: Date, segment: TravelSegment, readings: [SensorReading]) -> GeoPoint? {
        guard let points = segment.subwayRoute?.coordinates, points.count >= 2 else { return nil }
        var before: SensorReading?
        var after: SensorReading?
        var lower = 0, upper = readings.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if readings[middle].timestamp <= date { lower = middle + 1 } else { upper = middle }
        }
        func trusted(_ reading: SensorReading) -> Bool {
            reading.gpsAvailable && segment.span.contains(reading.timestamp)
                && (reading.point?.horizontalAccuracy ?? .infinity) <= trustedAccuracyMeters
        }
        before = readings[..<lower].last(where: trusted)
        after = readings[lower...].first(where: trusted)
        let lengths = zip(points, points.dropFirst()).map { meters($0.0, $0.1) }
        let total = lengths.reduce(0, +)
        guard total > 0 else { return nil }
        let startMeters = before?.point.map { position(of: $0, on: points, lengths: lengths) } ?? 0
        let endMeters = after?.point.map { position(of: $0, on: points, lengths: lengths) } ?? total
        let startDate = before?.timestamp ?? segment.span.start
        let endDate = after?.timestamp ?? segment.span.end
        let duration = endDate.timeIntervalSince(startDate)
        guard duration > 0 else { return point(atMeters: startMeters, on: points, lengths: lengths) }
        let progress = min(1, max(0, date.timeIntervalSince(startDate) / duration))
        // 투영이 잠깐 뒤로 잡혀도 열차는 뒤로 가지 않는다.
        let target = startMeters + max(0, endMeters - startMeters) * progress
        return point(atMeters: target, on: points, lengths: lengths)
    }

    private static func position(of point: GeoPoint, on points: [GeoPoint], lengths: [Double]) -> Double {
        var best = (distance: Double.infinity, meters: 0.0)
        var traversed = 0.0
        let scale = cos(point.latitude * .pi / 180) * 111_320
        for index in lengths.indices {
            let ax = (points[index].longitude - point.longitude) * scale, ay = (points[index].latitude - point.latitude) * 111_320
            let bx = (points[index + 1].longitude - point.longitude) * scale, by = (points[index + 1].latitude - point.latitude) * 111_320
            let dx = bx - ax, dy = by - ay, square = dx * dx + dy * dy
            let t = square > 0 ? min(1, max(0, -(ax * dx + ay * dy) / square)) : 0
            let x = ax + dx * t, y = ay + dy * t, distance = x * x + y * y
            if distance < best.distance { best = (distance, traversed + lengths[index] * t) }
            traversed += lengths[index]
        }
        return best.meters
    }

    private static func point(atMeters target: Double, on points: [GeoPoint], lengths: [Double]) -> GeoPoint {
        var traversed = 0.0
        for index in lengths.indices {
            let next = traversed + lengths[index]
            if target <= next, lengths[index] > 0 {
                let t = (target - traversed) / lengths[index]
                let a = points[index], b = points[index + 1]
                return GeoPoint(
                    latitude: a.latitude + (b.latitude - a.latitude) * t,
                    longitude: a.longitude + (b.longitude - a.longitude) * t,
                    altitude: a.altitude, horizontalAccuracy: a.horizontalAccuracy, verticalAccuracy: a.verticalAccuracy
                )
            }
            traversed = next
        }
        return points[points.count - 1]
    }

    private static func meters(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let y = (a.latitude - b.latitude) * 111_320
        let x = (a.longitude - b.longitude) * 111_320 * cos(a.latitude * .pi / 180)
        return (x * x + y * y).squareRoot()
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
