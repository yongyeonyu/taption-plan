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
    static let maximumPieces = 64

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
        let pieceCount = min(maximumPieces, edgeCount)
        var rawSpeeds: [Double?] = []
        rawSpeeds.reserveCapacity(pieceCount)
        var bounds: [(start: Int, end: Int)] = []
        bounds.reserveCapacity(pieceCount)
        for piece in 0..<pieceCount {
            let start = piece * edgeCount / pieceCount
            let end = (piece + 1) * edgeCount / pieceCount
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
    /// 정지한 것으로 보는 속도. 이때 목표는 `MapHomePlaybackZoomPolicy.nearDistance`(기본 줌)다.
    static let stationarySpeed = MapHomePlaybackZoomPolicy.slowSpeed

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
            speedMetersPerSecond: smoothed < Self.stationarySpeed ? 0 : smoothed
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
        .font(.system(size: 9, weight: .semibold, design: .rounded))
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
