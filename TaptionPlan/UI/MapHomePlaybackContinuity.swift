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

    /// 이동 구간의 출발·도착 장소 좌표를 시각 비율로 잇는다. 여러 구간이 겹치면 늦게 시작한 쪽을 쓴다.
    static func gapCoordinate(
        at date: Date,
        travel: [TravelSegment],
        places: [PlaceStay]
    ) -> GeoPoint? {
        let points = Dictionary(
            places.compactMap { place in place.point.map { (place.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
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
}

enum MapHomePlaybackCategoryRanges {
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
