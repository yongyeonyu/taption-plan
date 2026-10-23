import Foundation
import TaptionPlanCore

/// 지나간 날을 다시 계산할지 정하는 규칙.
///
/// 한 번 확정(seal)한 날은 원본이 바뀌지 않는 한 다시 계산하지 않는다. 지도·연봉 카운터·날씨가
/// 매번 같은 값을 처음부터 다시 만들면 배터리와 시간만 쓰고 결과는 달라지지 않는다.
/// 사용자가 그 날 기록을 직접 고치면(`force`) 확정을 풀고 다시 계산한다.
enum PlanDayRecalculationPolicy {
    /// 오늘보다 앞선 날짜인지. 오늘은 아직 진행 중이라 항상 다시 계산한다.
    static func isSettled(_ day: Date, now: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        calendar.startOfDay(for: day) < calendar.startOfDay(for: now)
    }

    /// 이 날의 파생 값(경로·시급·날씨·요약)을 다시 계산해도 되는지.
    static func allowsRecalculation(
        day: Date,
        now: Date,
        isSealed: Bool,
        force: Bool = false,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Bool {
        if force { return true }
        guard isSettled(day, now: now, calendar: calendar) else { return true }
        return !isSealed
    }

    /// 확정해도 되는 날인지. 하루가 끝까지 읽혔고(`isComplete`) 이미 지나갔을 때만 확정한다.
    static func canSeal(
        day: Date,
        now: Date,
        isComplete: Bool,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Bool {
        isComplete && isSettled(day, now: now, calendar: calendar)
    }
}

/// 확정한 날의 날씨 한 줄. 원본 `WeatherContext` 배열을 다시 훑지 않고도 배지를 그릴 수 있게 최소값만 둔다.
struct TaptionSealedWeather: Codable, Hashable, Sendable {
    var observedAt: Date
    var symbolName: String
    var condition: String
    var temperatureCelsius: Double
    var placeName: String?

    init?(context: WeatherContext) {
        guard context.isForecast != true else { return nil }
        self.observedAt = context.observedAt
        self.symbolName = context.symbolName
        self.condition = context.condition
        self.temperatureCelsius = context.temperatureCelsius
        self.placeName = context.placeName
    }
}

/// 확정한 하루의 요약. 하루 화면·연봉 카운터·날씨 배지가 필요로 하는 값을 한 덩어리로 담는다.
///
/// 용량을 줄이는 방법은 세 가지다.
/// 1. 원본 센서 행(수천~수만 개)을 다시 읽지 않고 이 요약 하나만 읽는다.
/// 2. 경로는 Douglas–Peucker로 단순화해 꺾은점만 남긴다(직선 구간의 점은 버린다).
/// 3. 좌표는 1e-7도 정수(Int32)로, 시각은 초 단위로 바꿔 이진 프로퍼티 리스트로 저장하고 LZFSE로 압축한다.
struct TaptionSealedDay: Codable, Hashable, Sendable {
    static let currentVersion = 1

    var version: Int = TaptionSealedDay.currentVersion
    var dayStart: Date
    var sealedAt: Date
    /// 확정할 때의 계획·장소·이동 지문. 지문이 달라지면 확정을 버리고 다시 계산한다.
    var sourceFingerprint: String?
    /// 대분류별 시간(초). 하루 요약·연봉 카운터·달력 합계가 이 값을 그대로 쓴다.
    var categorySeconds: [String: Int]
    /// 대분류가 아닌 달력 지표(이동거리·장소·이동 횟수·걷기/운전/대중교통 거리·외출 시간).
    /// 키는 `MapHomeCalendarTimeKind.rawValue`와 같다.
    var metrics: [String: Double]
    var stepCount: Int
    var distanceMeters: Double
    var workSeconds: Int
    var readingCount: Int
    var firstReadingAt: Date?
    var lastReadingAt: Date?
    /// 단순화한 경로. `[위도0, 경도0, 위도1-위도0, …]`(1e-7도 정수) 순서의 델타 배열이다.
    var polyline: [Int32]
    var weather: TaptionSealedWeather?
    var memoCount: Int
    var actualCount: Int
    var travelCount: Int
    var placeCount: Int

    init(
        version: Int = TaptionSealedDay.currentVersion,
        dayStart: Date,
        sealedAt: Date,
        sourceFingerprint: String?,
        categorySeconds: [String: Int],
        metrics: [String: Double] = [:],
        stepCount: Int,
        distanceMeters: Double,
        workSeconds: Int,
        readingCount: Int,
        firstReadingAt: Date?,
        lastReadingAt: Date?,
        polyline: [Int32],
        weather: TaptionSealedWeather?,
        memoCount: Int,
        actualCount: Int,
        travelCount: Int,
        placeCount: Int
    ) {
        self.version = version
        self.dayStart = dayStart
        self.sealedAt = sealedAt
        self.sourceFingerprint = sourceFingerprint
        self.categorySeconds = categorySeconds
        self.metrics = metrics
        self.stepCount = stepCount
        self.distanceMeters = distanceMeters
        self.workSeconds = workSeconds
        self.readingCount = readingCount
        self.firstReadingAt = firstReadingAt
        self.lastReadingAt = lastReadingAt
        self.polyline = polyline
        self.weather = weather
        self.memoCount = memoCount
        self.actualCount = actualCount
        self.travelCount = travelCount
        self.placeCount = placeCount
    }

    /// 확정한 날의 대분류별 시간(초). 화면이 쓰는 형태(`[String: TimeInterval]`)로 돌려준다.
    var categoryDurations: [String: TimeInterval] {
        categorySeconds.mapValues { TimeInterval($0) }
    }

    /// 단순화한 경로를 좌표로 되돌린다. 지도는 이 점들로 선을 긋고 원본 센서 행을 읽지 않는다.
    var routePoints: [GeoPoint] {
        TaptionSealedPolyline.decode(polyline)
    }

    /// 지문이 같으면 다시 계산하지 않는다. 지문이 없으면(예전 확정) 시각만 본다.
    func matches(sourceFingerprint fingerprint: String?) -> Bool {
        guard let stored = sourceFingerprint, let fingerprint else { return true }
        return stored == fingerprint
    }
}

/// 확정한 경로의 단순화·압축. 꺾은점만 남기고 좌표를 1e-7도 정수로 바꾼다.
enum TaptionSealedPolyline {
    /// 위도·경도를 1e-7도(약 1.1cm) 정수로. `Int32` 범위(±21억)에 넉넉히 들어간다.
    static let scale = 10_000_000.0
    /// 경로를 단순화할 때 허용하는 오차(미터). 8m면 걷기·차 이동 모양이 그대로 보인다.
    static let defaultToleranceMeters = 8.0

    static func encode(
        points: [GeoPoint],
        toleranceMeters: Double = defaultToleranceMeters
    ) -> [Int32] {
        guard !points.isEmpty else { return [] }
        let simplified = simplify(points, toleranceMeters: max(0, toleranceMeters))
        var result: [Int32] = []
        result.reserveCapacity(simplified.count * 2)
        var previousLatitude: Int32 = 0
        var previousLongitude: Int32 = 0
        for (index, point) in simplified.enumerated() {
            let latitude = quantize(point.latitude)
            let longitude = quantize(point.longitude)
            if index == 0 {
                result.append(latitude)
                result.append(longitude)
            } else {
                result.append(latitude &- previousLatitude)
                result.append(longitude &- previousLongitude)
            }
            previousLatitude = latitude
            previousLongitude = longitude
        }
        return result
    }

    static func decode(_ deltas: [Int32]) -> [GeoPoint] {
        guard deltas.count >= 2 else { return [] }
        var result: [GeoPoint] = []
        result.reserveCapacity(deltas.count / 2)
        var latitude: Int32 = 0
        var longitude: Int32 = 0
        var index = 0
        while index + 1 < deltas.count {
            if index == 0 {
                latitude = deltas[0]
                longitude = deltas[1]
            } else {
                latitude = latitude &+ deltas[index]
                longitude = longitude &+ deltas[index + 1]
            }
            result.append(
                GeoPoint(
                    latitude: Double(latitude) / scale,
                    longitude: Double(longitude) / scale,
                    altitude: 0,
                    horizontalAccuracy: 0,
                    verticalAccuracy: 0
                )
            )
            index += 2
        }
        return result
    }

    /// Douglas–Peucker. 시작·끝은 항상 남기고, 직선에서 `toleranceMeters` 안쪽인 점은 버린다.
    static func simplify(_ points: [GeoPoint], toleranceMeters: Double) -> [GeoPoint] {
        guard points.count > 2, toleranceMeters > 0 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack: [(Int, Int)] = [(0, points.count - 1)]
        while let (first, last) = stack.popLast() {
            guard last > first + 1 else { continue }
            var farthestIndex = first
            var farthestDistance = 0.0
            for index in (first + 1)..<last {
                let distance = perpendicularDistance(points[index], from: points[first], to: points[last])
                if distance > farthestDistance {
                    farthestDistance = distance
                    farthestIndex = index
                }
            }
            if farthestDistance > toleranceMeters {
                keep[farthestIndex] = true
                stack.append((first, farthestIndex))
                stack.append((farthestIndex, last))
            }
        }
        return points.enumerated().compactMap { keep[$0.offset] ? $0.element : nil }
    }

    /// 점 `point`에서 선분 `start`–`end`까지의 거리(미터). 좁은 지역이라 평면 근사로 충분하다.
    static func perpendicularDistance(_ point: GeoPoint, from start: GeoPoint, to end: GeoPoint) -> Double {
        let metersPerDegreeLatitude = 111_320.0
        let metersPerDegreeLongitude = metersPerDegreeLatitude
            * max(0.01, cos(point.latitude * .pi / 180))
        let px = (point.longitude - start.longitude) * metersPerDegreeLongitude
        let py = (point.latitude - start.latitude) * metersPerDegreeLatitude
        let ex = (end.longitude - start.longitude) * metersPerDegreeLongitude
        let ey = (end.latitude - start.latitude) * metersPerDegreeLatitude
        let lengthSquared = ex * ex + ey * ey
        guard lengthSquared > 0 else { return (px * px + py * py).squareRoot() }
        let t = min(max((px * ex + py * ey) / lengthSquared, 0), 1)
        let dx = px - ex * t
        let dy = py - ey * t
        return (dx * dx + dy * dy).squareRoot()
    }

    private static func quantize(_ value: Double) -> Int32 {
        guard value.isFinite else { return 0 }
        let scaled = (value * scale).rounded()
        return Int32(min(max(scaled, Double(Int32.min)), Double(Int32.max)))
    }
}

/// 하루 화면·연봉 카운터에 필요한 값을 모아 확정 요약을 만든다.
enum TaptionSealedDayBuilder {
    /// 연봉 카운터가 쓰는 근무 대분류 ID(`MapHomeCalendarTimeKind.work`).
    static let workCategoryID = "work"

    static func make(
        day: Date,
        sealedAt: Date,
        sourceFingerprint: String?,
        categories: [String: TimeInterval],
        metrics: [String: TimeInterval] = [:],
        steps: Int,
        distanceMeters: Double,
        readings: [SensorReading],
        weather: WeatherContext?,
        memoCount: Int,
        actualCount: Int,
        travelCount: Int,
        placeCount: Int,
        polylineToleranceMeters: Double = TaptionSealedPolyline.defaultToleranceMeters
    ) -> TaptionSealedDay {
        let rounded = categories.compactMapValues { value -> Int? in
            let seconds = Int(value.rounded())
            return seconds > 0 ? seconds : nil
        }
        let points = readings.compactMap { reading -> GeoPoint? in
            guard let point = reading.point, point.latitude.isFinite, point.longitude.isFinite else { return nil }
            return GeoPoint(
                latitude: point.latitude,
                longitude: point.longitude,
                altitude: 0,
                horizontalAccuracy: 0,
                verticalAccuracy: 0
            )
        }
        return TaptionSealedDay(
            dayStart: day,
            sealedAt: sealedAt,
            sourceFingerprint: sourceFingerprint,
            categorySeconds: rounded,
            metrics: metrics.filter { $0.value.isFinite && $0.value > 0 },
            stepCount: max(0, steps),
            distanceMeters: max(0, distanceMeters),
            workSeconds: rounded[workCategoryID] ?? 0,
            readingCount: readings.count,
            firstReadingAt: readings.first?.timestamp,
            lastReadingAt: readings.last?.timestamp,
            polyline: TaptionSealedPolyline.encode(
                points: points,
                toleranceMeters: polylineToleranceMeters
            ),
            weather: weather.flatMap(TaptionSealedWeather.init(context:)),
            memoCount: max(0, memoCount),
            actualCount: max(0, actualCount),
            travelCount: max(0, travelCount),
            placeCount: max(0, placeCount)
        )
    }
}
