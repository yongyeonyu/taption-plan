import Foundation
import TaptionPlanCore

/// 등록 지점에서 걸은 기록을 반경으로 가른다(대표 결정 2026-11-08, CLP1105A01).
///
/// 반경 밖으로 나가지 않은 걷기는 그 곳의 대분류이고 상세 활동만 걷기다.
/// 반경 밖까지 나간 걷기는 반경의 절반을 지난 때부터 반경의 절반 안으로 돌아온 때까지만 걷기이고,
/// 그 앞뒤는 그 곳의 대분류(상세 걷기)다. 화면에만 쓰는 파생 값이고 원본 기록은 바꾸지 않는다.
extension MapHomePlaceFirstPolicy {
    struct RadiusPlace: Equatable {
        let categoryID: String
        let center: GeoPoint
        let radius: Double
        /// 그 곳에 머문 기록(분). 걷기가 여기에 닿아야 그 곳에서 걸은 것으로 본다.
        let stays: [Range<Int>]
    }

    struct DistanceSample: Equatable {
        let time: Date
        let meters: Double
        let accuracy: Double
    }

    /// 머문 기록과 걷기 사이가 이만큼 벌어져도 그 곳에서 이어진 걷기로 본다.
    static let stayTouchMinutes = 5
    /// 걷기 앞뒤로 이만큼의 표본도 경계 판정에 쓴다.
    static let sampleMargin: TimeInterval = 2 * 60
    /// 이보다 부정확한 표본은 자리를 말해 주지 못한다(`PlaceZoneStayTracker`와 같은 값).
    static let maximumSampleAccuracyMeters = 100.0

    /// 중심과 반경이 있는 등록 지점만 반경으로 가른다. 나머지는 머문 시간 겹침으로 본다.
    static func radiusPlaces(
        frequentPlaces: [FrequentPlace],
        stays: [(key: String, start: Int, end: Int)]
    ) -> [RadiusPlace] {
        frequentPlaces.compactMap { place in
            guard let center = place.point, place.radiusMeters > 0,
                  let categoryID = categoryID(for: place.kind) else { return nil }
            let ranges = stays.filter { $0.key == place.stablePlaceKey && $0.end > $0.start }.map { $0.start..<$0.end }
            return ranges.isEmpty ? nil : RadiusPlace(categoryID: categoryID, center: center, radius: place.radiusMeters, stays: ranges)
        }
    }

    /// 사용자가 만들거나 고친 기록. 위치로 가르지 않는다.
    static func userOwnedIDs(_ actuals: [ActualRecord], activityCorrections: [UUID: ActivityCorrection]) -> Set<UUID> {
        Set(actuals.filter { ActualRecord.userOwned($0, activityCorrections: activityCorrections) }.map(\.id))
    }

    /// 위치가 있는 표본을 시간 순으로 둔다.
    static func locatedReadings(_ readings: [SensorReading]) -> [(time: Date, point: GeoPoint)] {
        readings.compactMap { reading -> (time: Date, point: GeoPoint)? in
            guard reading.gpsAvailable, let point = reading.point,
                  (0...maximumSampleAccuracyMeters).contains(point.horizontalAccuracy) else { return nil }
            return (reading.timestamp, point)
        }
        .sorted { $0.time < $1.time }
    }

    /// 반경으로 가른 조각. nil이면 반경으로 가를 근거(닿은 등록 지점·걷기 중 표본)가 없다.
    static func splitByRadius(
        _ segment: MapHomeTimeRailSegment,
        places: [RadiusPlace],
        located: [(time: Date, point: GeoPoint)],
        dayStart: Date
    ) -> [MapHomeTimeRailSegment]? {
        guard isWalking(segment), segment.endMinute > segment.startMinute else { return nil }
        let candidates = places.filter { place in
            place.stays.contains {
                $0.lowerBound - stayTouchMinutes < segment.endMinute && $0.upperBound + stayTouchMinutes > segment.startMinute
            }
        }
        guard !candidates.isEmpty else { return nil }
        let walkStart = dayStart.addingTimeInterval(Double(segment.startMinute) * 60)
        let walkEnd = dayStart.addingTimeInterval(Double(segment.endMinute) * 60)
        let window = located.filter {
            $0.time >= walkStart.addingTimeInterval(-sampleMargin) && $0.time <= walkEnd.addingTimeInterval(sampleMargin)
        }
        guard window.contains(where: { $0.time >= walkStart && $0.time <= walkEnd }) else { return nil }

        // 여러 곳에 닿으면 걷는 동안 반경에 가장 깊이 들어간 곳이다.
        let measured = candidates.map { place in
            (place, window.map {
                DistanceSample(time: $0.time, meters: PlanarDistance.meters($0.point, place.center), accuracy: $0.point.horizontalAccuracy)
            })
        }
        guard let (place, samples) = measured.min(by: { lhs, rhs in
            (lhs.1.map(\.meters).min() ?? .infinity) / lhs.0.radius < (rhs.1.map(\.meters).min() ?? .infinity) / rhs.0.radius
        }) else { return nil }
        // 걷는 내내 반경 밖이면 그 곳에서 걸은 것이 아니다.
        guard samples.contains(where: { $0.meters <= place.radius }) else { return [segment] }

        let outside = outsideSpans(samples, radius: place.radius).map { span in
            minute(span.start, dayStart: dayStart, in: segment)..<minute(span.end, dayStart: dayStart, in: segment)
        }
        return pieces(of: segment, outside: outside, categoryID: place.categoryID)
    }

    /// 반경 밖까지 나간 시간. 반경의 절반을 지난 때부터 절반 안으로 돌아온 때까지다.
    /// 절반과 반경 사이만 오간 것은 그 곳 안에서 걸은 것이다. 반경 밖 판정은 정확한 표본만 믿는다.
    static func outsideSpans(_ samples: [DistanceSample], radius: Double) -> [(start: Date, end: Date)] {
        let half = radius / 2
        var result: [(start: Date, end: Date)] = []
        var index = 0
        while index < samples.count {
            guard samples[index].meters > half else {
                index += 1
                continue
            }
            var next = index
            var exits = false
            while next < samples.count, samples[next].meters > half {
                exits = exits || (samples[next].meters > radius
                    && PlaceZoneStayTracker.isDecisive(accuracy: samples[next].accuracy, radius: radius))
                next += 1
            }
            if exits {
                // 앞(뒤) 표본이 없으면 걷기 처음(끝)부터 밖이다.
                let start = index == 0 ? Date.distantPast : crossing(samples[index - 1], samples[index], at: half)
                let end = next == samples.count ? Date.distantFuture : crossing(samples[next - 1], samples[next], at: half)
                result.append((start, end))
            }
            index = next
        }
        return result
    }

    /// 두 표본 사이에서 거리가 `meters`가 되는 때(직선 보간).
    static func crossing(_ from: DistanceSample, _ to: DistanceSample, at meters: Double) -> Date {
        let change = to.meters - from.meters
        let fraction = change == 0 ? 0 : min(1, max(0, (meters - from.meters) / change))
        return from.time.addingTimeInterval(to.time.timeIntervalSince(from.time) * fraction)
    }

    private static func minute(_ date: Date, dayStart: Date, in segment: MapHomeTimeRailSegment) -> Int {
        let value = (date.timeIntervalSince(dayStart) / 60).rounded()
        guard value.isFinite else { return value < 0 ? segment.startMinute : segment.endMinute }
        return min(max(Int(value), segment.startMinute), segment.endMinute)
    }

    /// 밖 시간은 원래 걷기로, 나머지는 그 곳의 대분류(상세 걷기)로 둔다.
    private static func pieces(
        of segment: MapHomeTimeRailSegment,
        outside: [Range<Int>],
        categoryID: String
    ) -> [MapHomeTimeRailSegment] {
        var result: [MapHomeTimeRailSegment] = []
        var cursor = segment.startMinute
        func place(_ end: Int) {
            guard end > cursor else { return }
            var piece = MapHomeTimeRailSegment(
                startMinute: cursor, endMinute: end, categoryID: categoryID,
                title: categoryTitle(categoryID) ?? segment.title, sourceIDs: segment.sourceIDs
            )
            piece.walkSpans = [cursor..<end]
            result.append(piece)
        }
        for span in outside.sorted(by: { $0.lowerBound < $1.lowerBound }) where span.upperBound > max(cursor, span.lowerBound) {
            place(span.lowerBound)
            let start = max(cursor, span.lowerBound)
            result.append(MapHomeTimeRailSegment(
                startMinute: start, endMinute: span.upperBound, categoryID: segment.categoryID,
                title: segment.title, behavior: segment.behavior, sourceIDs: segment.sourceIDs
            ))
            cursor = span.upperBound
        }
        place(segment.endMinute)
        return result
    }
}
