import CoreLocation
import Foundation
import SwiftUI

// MAP1019C01: 지도 홈의 날씨 상태·집 날씨 아이콘·경로 속도 그라데이션·실시간 자동 줌·GPS 로그 규칙.
// 화면 코드가 값을 해석하지 않도록 순수 함수로 두고 단위 테스트한다.

// MARK: - Weather status

enum WeatherFailureKind: Equatable, Sendable {
    /// WeatherKit 인증(JWT) 실패. Apple 개발자 계정 쪽 서비스 활성화 문제일 수 있다.
    case authentication
    case general

    static func kind(for error: Error) -> WeatherFailureKind {
        if let serviceError = error as? WeatherContextServiceError,
           serviceError == .authenticationFailed {
            return .authentication
        }
        return .general
    }
}

/// 마지막 날씨 성공 시각과 실패 종류. 값이 실제로 바뀔 때만 갱신 결과(true)를 돌려준다.
struct WeatherServiceStatus: Equatable, Sendable {
    /// 성공이 이어질 때 상태를 너무 자주 바꾸지 않도록 하는 최소 간격.
    static let successRefreshInterval: TimeInterval = 60

    var lastSuccessAt: Date?
    var failure: WeatherFailureKind?
    var failureAt: Date?

    @discardableResult
    mutating func recordSuccess(at date: Date) -> Bool {
        if failure == nil,
           let lastSuccessAt,
           abs(date.timeIntervalSince(lastSuccessAt)) < Self.successRefreshInterval {
            return false
        }
        lastSuccessAt = date
        failure = nil
        failureAt = nil
        return true
    }

    @discardableResult
    mutating func recordFailure(_ kind: WeatherFailureKind, at date: Date) -> Bool {
        // 같은 종류의 실패가 이어지면 처음 시각만 남긴다.
        if failure == kind, failureAt != nil { return false }
        failure = kind
        failureAt = date
        return true
    }

    /// 가장 최근 일이 실패일 때만 실패 종류를 돌려준다.
    var latestFailure: WeatherFailureKind? {
        guard let failure else { return nil }
        guard let lastSuccessAt, let failureAt else { return failure }
        return failureAt >= lastSuccessAt ? failure : nil
    }
}

enum MapHomeWeatherNotice: Equatable {
    case unreachable
    case authenticationFailed
}

enum MapHomeWeatherNoticePolicy {
    /// 레일에 보여줄 날씨가 없고 마지막 시도가 실패일 때만 이유를 알린다.
    static func notice(
        status: WeatherServiceStatus,
        hasDisplayableWeather: Bool
    ) -> MapHomeWeatherNotice? {
        guard !hasDisplayableWeather,
              let failure = status.latestFailure else { return nil }
        switch failure {
        case .authentication: return .authenticationFailed
        case .general: return .unreachable
        }
    }
}

// MARK: - Home weather badge

struct MapHomeHomeWeatherBadge: Equatable {
    let symbolName: String
    let temperatureText: String
    let condition: String
}

enum MapHomeHomeWeatherBadgePolicy {
    /// 현재 날씨로 볼 수 있는 가장 오래된 관측.
    static let maximumAge: TimeInterval = 90 * 60

    /// 지금과 가장 가까운 완전한 날씨(관측 우선). 너무 오래됐거나 없으면 nil.
    static func badge(
        from contexts: [WeatherContext],
        now: Date
    ) -> MapHomeHomeWeatherBadge? {
        let candidates = contexts.filter(MapHomeWeatherDisplayPolicy.isComplete)
        let best = candidates.min { lhs, rhs in
            let left = abs(lhs.observedAt.timeIntervalSince(now))
            let right = abs(rhs.observedAt.timeIntervalSince(now))
            if left != right { return left < right }
            return (lhs.isForecast != true) && (rhs.isForecast == true)
        }
        guard let best,
              abs(best.observedAt.timeIntervalSince(now)) <= maximumAge else {
            return nil
        }
        return MapHomeHomeWeatherBadge(
            symbolName: symbolName(for: best),
            temperatureText: "\(Int(best.temperatureCelsius.rounded()))°",
            condition: best.condition
        )
    }

    /// WeatherKit이 준 SF Symbol을 그대로 쓰고, 비어 있으면 상태 이름으로 고른다.
    static func symbolName(for context: WeatherContext) -> String {
        let symbol = context.symbolName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !symbol.isEmpty { return symbol }
        let condition = context.condition.lowercased()
        if condition.contains("thunder") || condition.contains("storm") { return "cloud.bolt.rain" }
        if condition.contains("snow") || condition.contains("flurr") || condition.contains("sleet") { return "cloud.snow" }
        if condition.contains("rain") || condition.contains("drizzle") || condition.contains("shower") { return "cloud.rain" }
        if condition.contains("fog") || condition.contains("haze") || condition.contains("smok") { return "cloud.fog" }
        if condition.contains("partly") { return "cloud.sun" }
        if condition.contains("cloud") { return "cloud" }
        if condition.contains("clear") || condition.contains("sun") { return "sun.max" }
        return "cloud"
    }
}

// MARK: - Route speed gradient

/// 실제 경로를 속도 구간별 색(느림 빨강 → 중간 초록 → 빠름 파랑, `MapHomePawprintSpeedColor` 척도)으로 나눈다.
enum MapHomeRouteSpeedGradient {
    /// 구간 하나가 묶는 간선 수. 경로가 늘어나도 구간 경계가 움직이지 않아 이미 그린 색이 바뀌지 않는다.
    static let edgesPerPiece = 4
    static let maximumPieces = 1_000

    struct Piece: Equatable {
        /// 경로 좌표 인덱스 범위(양 끝 포함). 인접 구간은 끝점을 공유한다.
        let startIndex: Int
        let endIndex: Int
        let speedMetersPerSecond: Double
        let colorHex: String
    }

    /// 속도를 알 수 없으면(시각 없음·모두 같은 시각 등) nil을 돌려 단색으로 되돌린다.
    static func pieces(
        coordinates: [CLLocationCoordinate2D],
        timestamps: [Date],
        maximumPieces: Int = maximumPieces
    ) -> [Piece]? {
        guard coordinates.count >= 2,
              coordinates.count == timestamps.count,
              maximumPieces > 0 else { return nil }
        let edgeCount = coordinates.count - 1
        // 구간 경계는 절대 인덱스(stride의 배수)로 고정한다. 아주 긴 경로에서만 stride를 두 배로 늘린다.
        var stride = edgesPerPiece
        while (edgeCount + stride - 1) / stride > maximumPieces { stride *= 2 }
        let pieceCount = (edgeCount + stride - 1) / stride
        var rawSpeeds: [Double?] = []
        rawSpeeds.reserveCapacity(pieceCount)
        var bounds: [(start: Int, end: Int)] = []
        bounds.reserveCapacity(pieceCount)
        for piece in 0..<pieceCount {
            let start = piece * stride
            let end = min(edgeCount, (piece + 1) * stride)
            bounds.append((start, end))
            var meters = 0.0
            var seconds = 0.0
            for edge in start..<end {
                let duration = timestamps[edge + 1].timeIntervalSince(timestamps[edge])
                guard duration > 0, duration.isFinite else { continue }
                let distance = CLLocation(
                    latitude: coordinates[edge].latitude,
                    longitude: coordinates[edge].longitude
                ).distance(from: CLLocation(
                    latitude: coordinates[edge + 1].latitude,
                    longitude: coordinates[edge + 1].longitude
                ))
                guard distance.isFinite else { continue }
                meters += distance
                seconds += duration
            }
            rawSpeeds.append(seconds > 0 ? meters / seconds : nil)
        }
        guard let filled = fillGaps(rawSpeeds) else { return nil }
        let smoothed = movingAverage(filled)
        return zip(bounds, smoothed).map { bound, speed in
            Piece(
                startIndex: bound.start,
                endIndex: bound.end,
                speedMetersPerSecond: speed,
                colorHex: colorHex(forMetersPerSecond: speed)
            )
        }
    }

    /// 이웃 구간의 속도로 빈 구간을 메운다. 전부 비어 있으면 nil.
    static func fillGaps(_ speeds: [Double?]) -> [Double]? {
        guard speeds.contains(where: { $0 != nil }) else { return nil }
        var result: [Double?] = speeds
        var last: Double?
        for index in result.indices {
            if let value = result[index] { last = value } else { result[index] = last }
        }
        var next: Double?
        for index in result.indices.reversed() {
            if let value = result[index] { next = value } else { result[index] = next }
        }
        return result.compactMap { $0 }
    }

    /// 3점 이동 평균으로 인접 구간 색이 급변하지 않게 한다.
    static func movingAverage(_ speeds: [Double]) -> [Double] {
        speeds.indices.map { index in
            let lower = max(0, index - 1)
            let upper = min(speeds.count - 1, index + 1)
            let window = speeds[lower...upper]
            return window.reduce(0, +) / Double(window.count)
        }
    }

    static func colorHex(forMetersPerSecond speed: Double) -> String {
        let ratio = MapHomePawprintSpeedColor.ratio(forMetersPerSecond: speed) ?? 0
        let rgb = rgb(hue: (2.0 / 3.0) * ratio, saturation: 0.85, brightness: 0.82)
        return String(
            format: "#%02X%02X%02X",
            Int((rgb.red * 255).rounded()),
            Int((rgb.green * 255).rounded()),
            Int((rgb.blue * 255).rounded())
        )
    }

    private static func rgb(
        hue: Double,
        saturation: Double,
        brightness: Double
    ) -> (red: Double, green: Double, blue: Double) {
        let scaled = (hue - hue.rounded(.down)) * 6
        let sector = Int(scaled) % 6
        let fraction = scaled - Double(Int(scaled))
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * fraction)
        let t = brightness * (1 - saturation * (1 - fraction))
        switch sector {
        case 0: return (brightness, t, p)
        case 1: return (q, brightness, p)
        case 2: return (p, brightness, t)
        case 3: return (p, q, brightness)
        case 4: return (t, p, brightness)
        default: return (brightness, p, q)
        }
    }
}

/// 그라데이션 구간 하나를 지도 렌더러가 그릴 선으로 옮긴 값.
struct MapHomeRouteGradientSlice {
    let id: String
    let coordinates: [CLLocationCoordinate2D]
    let geometrySignature: Int
    let colorHex: String
}

enum MapHomeRouteGradientSlicer {
    static func slices(
        overlayID: String,
        coordinates: [CLLocationCoordinate2D],
        timestamps: [Date]
    ) -> [MapHomeRouteGradientSlice]? {
        guard let pieces = MapHomeRouteSpeedGradient.pieces(
            coordinates: coordinates,
            timestamps: timestamps
        ) else { return nil }
        return pieces.enumerated().map { index, piece in
            let slice = Array(coordinates[piece.startIndex...piece.endIndex])
            return MapHomeRouteGradientSlice(
                id: "\(overlayID)#g\(index)",
                coordinates: slice,
                geometrySignature: MapHomeRouteGeometrySignature.value(for: slice),
                colorHex: piece.colorHex
            )
        }
    }
}

// MARK: - Live auto zoom

/// 실시간 따라가기에서 속도에 비례해 지도 거리를 조절한다(재생용 `MapHomePlaybackZoomPolicy`와 같은 곡선).
/// 속도는 지수 평활하고, 목표와 15% 안쪽 차이는 무시하며, 변경 사이에 최소 간격을 둔다.
/// 사용자가 지도를 직접 조작하면 일정 시간 멈춘다.
final class MapHomeLiveZoomGovernor {
    static let minimumInterval: TimeInterval = 2
    static let hysteresis = 0.15
    static let userPauseDuration: TimeInterval = 20
    static let speedSmoothing = 0.35
    static let easing = 0.35

    private var smoothedSpeed: Double?
    private var lastChangeUptime: TimeInterval?
    private var pausedUntilUptime: TimeInterval?

    /// 바꿀 거리를 돌려주고, 바꾸지 않아야 하면 nil을 돌려준다.
    func nextDistance(
        current: Double,
        speedMetersPerSecond: Double?,
        uptime: TimeInterval
    ) -> Double? {
        guard current.isFinite, current > 0 else { return nil }
        if let pausedUntilUptime, uptime < pausedUntilUptime { return nil }
        guard let speed = speedMetersPerSecond, speed.isFinite, speed >= 0 else {
            return nil
        }
        let smoothed = smoothedSpeed.map {
            $0 + (speed - $0) * Self.speedSmoothing
        } ?? speed
        smoothedSpeed = smoothed
        if let lastChangeUptime, uptime - lastChangeUptime < Self.minimumInterval {
            return nil
        }
        guard let target = MapHomePlaybackZoomPolicy.targetDistance(
            speedMetersPerSecond: smoothed
        ) else { return nil }
        guard abs(log(target / current)) >= Self.hysteresis else { return nil }
        let next = exp(log(current) + (log(target) - log(current)) * Self.easing)
        lastChangeUptime = uptime
        return next
    }

    /// 사용자가 지도를 직접 조작했다. 일정 시간 자동 줌을 멈춘다.
    func pauseForUserAdjustment(uptime: TimeInterval) {
        pausedUntilUptime = uptime + Self.userPauseDuration
    }

    func isPaused(uptime: TimeInterval) -> Bool {
        pausedUntilUptime.map { uptime < $0 } ?? false
    }

    func reset() {
        smoothedSpeed = nil
        lastChangeUptime = nil
        pausedUntilUptime = nil
    }
}

/// 실시간 따라가기에서 줌 판단에 쓰는 속도. 멈춰 있으면 위치 게이트가 fix를 거르므로 센서 값이 오래되는데,
/// 그때를 "알 수 없음"으로 두면 정지 상태 확대가 멈춘다. 마지막 속도가 걷기 이하면 정지로 본다.
enum MapHomeLiveFollowSpeed {
    static let freshAge: TimeInterval = 15
    /// 이 속도 이상으로 달리던 중 값이 끊기면(터널·지하철) 정지로 단정하지 않는다.
    static let stillCeiling = 3.0

    static func speed(latestAge: TimeInterval, latestSpeed: Double?) -> Double? {
        let known = latestSpeed.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        if latestAge <= freshAge { return known }
        guard let known else { return 0 }
        return known < stillCeiling ? 0 : nil
    }
}

/// 재생 중 줌 거리 변화를 시간 기준으로 부드럽게 한다. 틱 횟수가 아니라 경과 시간으로 따라가고(시정수 1.2초),
/// 초당 로그 변화량에 상한(약 2.5배/초)을 둬서 정지와 이동이 짧게 번갈아도 확대·축소가 튀지 않게 한다.
final class MapHomePlaybackZoomSmoother {
    static let timeConstant: TimeInterval = 0.6
    static let maximumLogRate = 1.6
    /// 속도가 줄어 다가갈 때(줌인)는 조금 천천히 따라가되, 너무 늦지 않게 짧은 시간 상수를 쓴다.
    static let zoomInTimeConstant: TimeInterval = 0.9
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

/// 재생 줌 계획(대표 지시 ZMP1020A01). 재생을 시작할 때 이동 구간을 미리 나눠 구간마다 목표 배율을 정해 둔다.
/// - 정지 구간·걷기·달리기·등록 장소에서 출발하거나 도착하는 이동·속도를 모르는 이동은 85로 고정한다.
/// - 그 밖의 탈것 구간만 구간 속도로 목표 배율을 정한다(느리면 최대 92, 빠르면 최소 42).
/// - 짧은 구간은 목표를 85 쪽으로 줄여(구간 길이/최소 길이) 확대·축소가 튀지 않게 하고, 탈것 구간 사이의 짧은 틈은
///   앞 구간 배율을 유지해 갔다 오는 요동을 없앤다. 실제 카메라 움직임의 부드러움은 `MapHomePlaybackZoomSmoother`가 맡는다.
/// 재생을 시작할 때 이동 경로의 속도를 30초 간격으로 훑어 미리 정해 두는 줌 배율 프로파일.
/// 속도로 배율을 정하고, 너무 빨리 바뀌지 않게 이동 평균과 변화량 제한으로 조금 평탄화한 뒤,
/// 등록된 지점(집·회사 등) 반경 안은 확대 배율(85)로 고정한다.
struct MapHomePlaybackZoomProfile: Equatable, Sendable {
    static let stepMinutes = 0.5
    static let speedWindowSeconds: TimeInterval = 90
    /// 이동 평균 반경(칸). 2칸이면 앞뒤 1분.
    static let smoothingRadiusSteps = 2
    /// 30초당 배율이 바뀔 수 있는 최댓값. 85에서 42까지 가는 데 약 3.5분 걸린다.
    static let maximumStepChange = 6.0
    static let placeRadiusMeters = 200.0
    /// 등록 지점 반경 안으로 들어가기 전후 이 칸 수만큼도 85로 둔다(도착 직전 미리 확대).
    static let placePaddingSteps = 2

    let startMinute: Double
    let scales: [Double]

    func scale(atMinute minute: Double) -> Double? {
        guard let first = scales.first else { return nil }
        guard scales.count > 1 else { return first }
        let position = (minute - startMinute) / Self.stepMinutes
        guard position >= 0, position <= Double(scales.count - 1) else { return nil }
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, scales.count - 1)
        let fraction = position - Double(lower)
        return scales[lower] + (scales[upper] - scales[lower]) * fraction
    }

    static func build(
        readings: [SensorReading],
        places: [GeoPoint],
        dayStart: Date,
        endMinute: Double = 1_440
    ) -> MapHomePlaybackZoomProfile? {
        let located = readings
            .compactMap { reading -> (time: TimeInterval, point: GeoPoint)? in
                guard let point = reading.point else { return nil }
                return (reading.timestamp.timeIntervalSince(dayStart), point)
            }
            .sorted { $0.time < $1.time }
        guard located.count >= 2, endMinute > 0 else { return nil }
        var cumulative = [0.0]
        for (a, b) in zip(located, located.dropFirst()) {
            cumulative.append(cumulative[cumulative.count - 1] + distanceMeters(a.point, b.point))
        }
        func lowerBound(_ time: TimeInterval) -> Int {
            var low = 0, high = located.count
            while low < high {
                let mid = (low + high) / 2
                if located[mid].time < time { low = mid + 1 } else { high = mid }
            }
            return low
        }
        let baseline = MapHomePlaybackZoomPolicy.baselineScale
        let count = Int((endMinute / stepMinutes).rounded(.up)) + 1
        var raw = [Double](repeating: baseline, count: count)
        var nearPlace = [Bool](repeating: false, count: count)
        for i in 0..<count {
            let time = Double(i) * stepMinutes * 60
            let lo = lowerBound(time - speedWindowSeconds)
            let hi = lowerBound(time + speedWindowSeconds + 0.001) - 1
            if hi > lo {
                let seconds = located[hi].time - located[lo].time
                if seconds > 0 {
                    let speed = (cumulative[hi] - cumulative[lo]) / seconds
                    raw[i] = speed <= MapHomePlaybackZoomPolicy.walkingCeiling
                        ? baseline
                        : min(baseline, MapHomePlaybackZoomPolicy.scale(forVehicleSpeed: speed))
                }
            }
            if !places.isEmpty {
                let index = min(lowerBound(time), located.count - 1)
                let candidates = [index - 1, index].filter { located.indices.contains($0) }
                if let nearest = candidates.min(by: { abs(located[$0].time - time) < abs(located[$1].time - time) }),
                   abs(located[nearest].time - time) <= 300 {
                    nearPlace[i] = places.contains { distanceMeters($0, located[nearest].point) <= placeRadiusMeters }
                }
            }
        }
        // 이동 평균으로 조금 평탄화한다.
        var smooth = raw
        for i in 0..<count {
            let lo = max(0, i - smoothingRadiusSteps), hi = min(count - 1, i + smoothingRadiusSteps)
            smooth[i] = raw[lo...hi].reduce(0, +) / Double(hi - lo + 1)
        }
        // 변화량 제한(앞→뒤, 뒤→앞)으로 갑작스러운 변화를 없앤다.
        for i in 1..<count {
            smooth[i] = min(max(smooth[i], smooth[i - 1] - maximumStepChange), smooth[i - 1] + maximumStepChange)
        }
        for i in stride(from: count - 2, through: 0, by: -1) {
            smooth[i] = min(max(smooth[i], smooth[i + 1] - maximumStepChange), smooth[i + 1] + maximumStepChange)
        }
        // 등록된 지점은 확대 배율로 고정(도착 직전·출발 직후 몇 칸 포함).
        for i in 0..<count where nearPlace[i] {
            let lo = max(0, i - placePaddingSteps), hi = min(count - 1, i + placePaddingSteps)
            for j in lo...hi { smooth[j] = baseline }
        }
        return MapHomePlaybackZoomProfile(startMinute: 0, scales: smooth)
    }
}

struct MapHomePlaybackZoomPlan: Equatable, Sendable {
    struct Input: Equatable, Sendable {
        var startMinute: Double
        var endMinute: Double
        var mode: TravelMode?
        var speedMetersPerSecond: Double?
        var touchesRegisteredPlace: Bool
        /// 구간 이동 거리(m)와 경로가 차지하는 범위의 대각선(m). 모르면 nil(거리는 속도×시간으로 추정).
        var distanceMeters: Double? = nil
        var extentMeters: Double? = nil
    }

    struct Entry: Equatable, Sendable {
        var startMinute: Double
        var endMinute: Double
        var scale: Double
        var isFixed: Bool
        /// 긴 이동: 시작·끝의 이 시간(분)은 85로 확대하고 가운데는 `scale`(경로 전체 맞춤)로 고정한다.
        var edgeMinutes: Double = 0
        /// 경로 전체 맞춤으로 고정한 긴 이동. 순간 속도로 배율을 바꾸지 않는다.
        var isFitted = false
    }

    /// 이 거리(m) 미만의 탈것 구간은 85 고정, 이상 ~`longHaulMeters`는 속도 비례, 이상은 경로 전체 맞춤 고정.
    static let shortTripMeters = 1_000.0
    static let longHaulMeters = 50_000.0

    /// 이 길이(분)보다 짧은 탈것 구간은 목표를 85 쪽으로 줄인다.
    static let minimumFullEffectMinutes = 4.0
    /// 탈것 구간 사이의 이 길이(분) 이하 틈은 앞 구간 배율을 유지한다.
    static let holdGapMinutes = 3.0

    let entries: [Entry]
    /// 속도로 미리 정한 줌 프로파일(있으면 경로 전체 맞춤 구간 밖에서 이 값을 쓴다).
    var profile: MapHomePlaybackZoomProfile?

    init(inputs: [Input], profile: MapHomePlaybackZoomProfile? = nil) {
        self.profile = profile
        let baseline = MapHomePlaybackZoomPolicy.baselineScale
        var built: [Entry] = []
        for input in inputs.sorted(by: { $0.startMinute < $1.startMinute }) where input.endMinute > input.startMinute {
            let speed = input.speedMetersPerSecond.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            let durationMinutes = input.endMinute - input.startMinute
            let distance = input.distanceMeters ?? speed.map { $0 * durationMinutes * 60 }
            let walkingLike = input.mode == .walking || input.mode == .running
                || (input.mode == nil && (speed ?? 0) <= MapHomePlaybackZoomPolicy.walkingCeiling)
            // 긴 이동(인천→대구 같은)은 85로는 지도가 화면을 순식간에 지나가 볼 수 없으므로, 등록 장소에서 이어지더라도
            // 구간 전체가 한 화면에 들어오는 배율로 고정하고 시작·끝에서만 85로 확대한다(대표 선택 ZMP1020B01).
            if !walkingLike, let distance, distance >= Self.longHaulMeters, let extent = input.extentMeters, extent > 0 {
                built.append(Entry(
                    startMinute: input.startMinute,
                    endMinute: input.endMinute,
                    scale: MapHomePlaybackZoomPolicy.fitScale(forExtentMeters: extent),
                    isFixed: false,
                    edgeMinutes: min(10, max(3, durationMinutes * 0.05)),
                    isFitted: true
                ))
                continue
            }
            let shortTrip = (distance ?? .infinity) < Self.shortTripMeters
            let fixed = walkingLike || speed == nil || shortTrip
            // 등록 장소에서 이어지는 탈것 이동은 출발·도착 몇 분만 85로 두고, 가운데는 속도에 따라 축소한다.
            let placeEdgeMinutes = !fixed && input.touchesRegisteredPlace ? min(3, max(1, durationMinutes * 0.05)) : 0
            var scale = baseline
            if !fixed, let speed {
                let raw = MapHomePlaybackZoomPolicy.scale(forVehicleSpeed: speed)
                let weight = min(1, (input.endMinute - input.startMinute) / Self.minimumFullEffectMinutes)
                scale = baseline + (raw - baseline) * weight
            }
            if let last = built.last, !fixed, !last.isFixed, last.edgeMinutes == 0,
               input.startMinute - last.endMinute <= Self.holdGapMinutes {
                // 탈것 구간 사이의 짧은 틈: 앞 구간 배율을 틈 끝까지 유지한다.
                built[built.count - 1].endMinute = input.startMinute
            }
            built.append(Entry(
                startMinute: input.startMinute,
                endMinute: input.endMinute,
                scale: scale,
                isFixed: fixed,
                edgeMinutes: placeEdgeMinutes
            ))
        }
        entries = built
    }

    /// 재생 분(0~1,440)의 목표 배율. 구간 밖은 85.
    func scale(atMinute minute: Double) -> Double {
        for entry in entries where minute >= entry.startMinute && minute < entry.endMinute {
            if entry.edgeMinutes > 0,
               minute < entry.startMinute + entry.edgeMinutes || minute >= entry.endMinute - entry.edgeMinutes {
                return MapHomePlaybackZoomPolicy.baselineScale
            }
            return entry.scale
        }
        return MapHomePlaybackZoomPolicy.baselineScale
    }

    func targetDistance(atMinute minute: Double) -> Double {
        MapHomeCameraZoomMath.distance(forScale: scale(atMinute: minute))
    }

    /// 탈것 구간 안에서는 구간 평균이 아니라 지금 순간의 속도로 목표 배율을 정한다.
    /// 빨라지면 축소, 느려지면(걷기 이하까지) 85 쪽으로 다시 확대한다. 구간 처음·끝과 경로 전체 맞춤 구간은 계획 그대로.
    func scale(atMinute minute: Double, speedMetersPerSecond speed: Double?) -> Double {
        let planned = scale(atMinute: minute)
        let baseline = MapHomePlaybackZoomPolicy.baselineScale
        let containing = entries.first(where: { minute >= $0.startMinute && minute < $0.endMinute })
        if containing?.isFitted == true { return planned }
        if let profileScale = profile?.scale(atMinute: minute) { return min(baseline, profileScale) }
        guard let speed, speed.isFinite, speed >= 0,
              planned < baseline - 0.001,
              let entry = containing,
              !entry.isFixed, !entry.isFitted else { return planned }
        if speed <= MapHomePlaybackZoomPolicy.walkingCeiling { return baseline }
        let raw = MapHomePlaybackZoomPolicy.scale(forVehicleSpeed: speed)
        let weight = min(1, (entry.endMinute - entry.startMinute) / Self.minimumFullEffectMinutes)
        return min(baseline, baseline + (raw - baseline) * weight)
    }

    func targetDistance(atMinute minute: Double, speedMetersPerSecond speed: Double?) -> Double {
        MapHomeCameraZoomMath.distance(forScale: scale(atMinute: minute, speedMetersPerSecond: speed))
    }
}

/// 재생 줌 계획의 입력을 만든다: 이동 구간의 속도와 등록 장소 접촉 여부.
enum MapHomePlaybackZoomInputBuilder {
    static let placeRadiusMeters = 200.0
    static let endpointToleranceSeconds: TimeInterval = 180

    static func inputs(
        ranges: [MapHomePlaybackMovementRange],
        dayStart: Date,
        travel: [TravelSegment],
        readings: [SensorReading],
        places: [GeoPoint]
    ) -> [MapHomePlaybackZoomPlan.Input] {
        let located = readings.filter { $0.point != nil }.sorted { $0.timestamp < $1.timestamp }
        return ranges.map { range in
            let start = dayStart.addingTimeInterval(range.startMinute * 60)
            let end = dayStart.addingTimeInterval(range.endMinute * 60)
            let inside = located.filter { $0.timestamp >= start && $0.timestamp <= end }
            return .init(
                startMinute: range.startMinute,
                endMinute: range.endMinute,
                mode: range.mode,
                speedMetersPerSecond: speed(from: start, to: end, travel: travel, readings: located),
                touchesRegisteredPlace: isNearPlace(at: start, readings: located, places: places)
                    || isNearPlace(at: end, readings: located, places: places),
                distanceMeters: distance(from: start, to: end, travel: travel, inside: inside),
                extentMeters: extent(of: inside)
            )
        }
    }

    /// 구간 평균 속도: 겹치는 확정 이동 구간의 거리/시간, 없으면 구간 안 위치 점의 경로 길이/시간. 모르면 nil.
    static func speed(from start: Date, to end: Date, travel: [TravelSegment], readings: [SensorReading]) -> Double? {
        let duration = end.timeIntervalSince(start)
        guard duration > 0 else { return nil }
        let middle = start.addingTimeInterval(duration / 2)
        if let segment = travel.filter({ $0.span.contains(middle) && $0.distanceMeters > 0 })
            .max(by: { $0.span.start < $1.span.start }) {
            return segment.distanceMeters / max(1, segment.span.duration)
        }
        let inside = readings.filter { $0.timestamp >= start && $0.timestamp <= end }
        guard inside.count >= 2 else { return nil }
        var meters = 0.0
        for (lhs, rhs) in zip(inside, inside.dropFirst()) {
            if let a = lhs.point, let b = rhs.point { meters += distanceMeters(a, b) }
        }
        return meters / duration
    }

    /// 구간 이동 거리(m): 겹치는 확정 이동 구간의 거리, 없으면 위치 점 경로 길이. 모르면 nil.
    static func distance(from start: Date, to end: Date, travel: [TravelSegment], inside: [SensorReading]) -> Double? {
        let middle = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
        if let segment = travel.filter({ $0.span.contains(middle) && $0.distanceMeters > 0 })
            .max(by: { $0.span.start < $1.span.start }) {
            return segment.distanceMeters
        }
        guard inside.count >= 2 else { return nil }
        var meters = 0.0
        for (lhs, rhs) in zip(inside, inside.dropFirst()) {
            if let a = lhs.point, let b = rhs.point { meters += distanceMeters(a, b) }
        }
        return meters
    }

    /// 경로가 차지하는 범위(위도·경도 최소·최대 상자)의 대각선(m). 점이 둘 미만이면 nil.
    static func extent(of readings: [SensorReading]) -> Double? {
        let points = readings.compactMap(\.point)
        guard points.count >= 2,
              let minLat = points.map(\.latitude).min(), let maxLat = points.map(\.latitude).max(),
              let minLon = points.map(\.longitude).min(), let maxLon = points.map(\.longitude).max() else { return nil }
        func point(_ latitude: Double, _ longitude: Double) -> GeoPoint {
            GeoPoint(latitude: latitude, longitude: longitude, altitude: 0, horizontalAccuracy: 0, verticalAccuracy: 0)
        }
        return distanceMeters(point(minLat, minLon), point(maxLat, maxLon))
    }

    static func isNearPlace(at date: Date, readings: [SensorReading], places: [GeoPoint]) -> Bool {
        guard !places.isEmpty,
              let nearest = readings.min(by: {
                  abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date))
              }),
              abs(nearest.timestamp.timeIntervalSince(date)) <= endpointToleranceSeconds,
              let point = nearest.point else { return false }
        return places.contains { distanceMeters($0, point) <= placeRadiusMeters }
    }
}

/// 재생 시각의 이동 속도(m/s). 확정된 이동 구간의 평균 속도가 있으면 그것을, 없으면 그 시각을 사이에 둔
/// 두 위치 점의 거리/시간을 쓴다. 한쪽 점만 있으면 가까운(120초 이내) 센서 속도, 아무것도 없으면 nil이다.
/// 재생 중에는 오늘의 실시간 속도를 섞지 않는다.
enum MapHomePlaybackSpeed {
    static let singleSidedMaximumAge: TimeInterval = 120

    static func speed(at date: Date, travel: [TravelSegment], readings: [SensorReading]) -> Double? {
        if let segment = travel
            .filter({ $0.span.contains(date) })
            .max(by: { $0.span.start < $1.span.start }),
           segment.distanceMeters > 0 {
            return segment.distanceMeters / max(1, segment.span.end.timeIntervalSince(segment.span.start))
        }
        var before: (time: Date, point: GeoPoint, speed: Double?)?
        var after: (time: Date, point: GeoPoint)?
        for reading in readings {
            guard let point = reading.point else { continue }
            if reading.timestamp <= date {
                if before.map({ reading.timestamp > $0.time }) ?? true {
                    before = (reading.timestamp, point, reading.speedMetersPerSecond)
                }
            } else if after.map({ reading.timestamp < $0.time }) ?? true {
                after = (reading.timestamp, point)
            }
        }
        if let before, let after {
            let gap = after.time.timeIntervalSince(before.time)
            guard gap > 0 else { return nil }
            return distanceMeters(before.point, after.point) / gap
        }
        if let before, date.timeIntervalSince(before.time) <= singleSidedMaximumAge,
           let speed = before.speed, speed.isFinite, speed >= 0 {
            return speed
        }
        return nil
    }
}

// MARK: - GPS fix diagnostics

/// 포그라운드에서 받은 위치 fix를 좌표 없이 요약한다(위도·경도는 개인정보라 남기지 않는다).
enum GPSFixDiagnostics {
    static let eventName = "gps_fix"

    static func reason(
        accepted: Bool,
        hasPreviousLocation: Bool,
        isTrulyStill: Bool,
        motionIsStationary: Bool
    ) -> String {
        guard accepted else { return "still" }
        if !hasPreviousLocation { return "first_fix" }
        if isTrulyStill && motionIsStationary { return "still_heartbeat" }
        return "moving"
    }

    static func source(isSimulated: Bool, isFromAccessory: Bool) -> String {
        if isSimulated { return "simulated" }
        if isFromAccessory { return "accessory" }
        return "device"
    }

    static func fields(
        accepted: Bool,
        reason: String,
        source: String,
        hasAltitude: Bool
    ) -> [String: String] {
        [
            "gate": accepted ? "accepted" : "ignored",
            "reason": reason,
            "source": source,
            "has_altitude": String(hasAltitude),
        ]
    }

    /// 음수(알 수 없음) 값은 넣지 않는다.
    static func metrics(
        horizontalAccuracy: Double,
        speed: Double,
        course: Double,
        batchCount: Int
    ) -> [String: Double] {
        var result: [String: Double] = ["batch_count": Double(batchCount)]
        if horizontalAccuracy.isFinite, horizontalAccuracy >= 0 {
            result["accuracy_m"] = horizontalAccuracy.rounded()
        }
        if speed.isFinite, speed >= 0 { result["speed_mps"] = (speed * 10).rounded() / 10 }
        if course.isFinite, course >= 0 { result["course_deg"] = course.rounded() }
        return result
    }
}

// MARK: - Weather notice view

/// 사이드바 옆 날씨 레일 위에 날씨를 못 가져온 이유를 작게 알린다.
struct MapHomeWeatherNoticeView: View {
    static let width: CGFloat = 132

    let notice: MapHomeWeatherNotice
    let language: MapHomeLanguage

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Label {
                Text(language.text(
                    "날씨 서비스에 연결하지 못했습니다",
                    "Couldn't reach the weather service"
                ))
            } icon: {
                Image(systemName: "cloud.slash")
            }
            .labelStyle(.titleAndIcon)
            if notice == .authenticationFailed {
                Text(language.text(
                    "Apple 날씨(WeatherKit) 인증 실패",
                    "Apple Weather (WeatherKit) authentication failed"
                ))
            }
        }
        .font(.system(size: TaptionType.scaled(TaptionType.snapped(9)), weight: .semibold, design: .rounded))
        .foregroundStyle(Color.tpInk.opacity(0.78))
        .multilineTextAlignment(.trailing)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.tpSurface.opacity(0.92), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.tpLine.opacity(0.8), lineWidth: 0.6)
        }
        .accessibilityElement(children: .combine)
    }
}
