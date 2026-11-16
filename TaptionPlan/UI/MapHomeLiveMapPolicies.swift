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
    var windSpeedMetersPerSecond: Double? = nil
}

enum MapHomeHomeWeatherBadgePolicy {
    /// 현재 날씨로 볼 수 있는 가장 오래된 관측.
    static let maximumAge: TimeInterval = 90 * 60

    /// 집 날씨를 고를 시각: 재생 중이면 재생 시각, 지난 날이면 사이드바에서 고른 시각, 오늘이면 지금.
    static func displayDate(playback: Date?, selectedDay: Date, selection: Date, now: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        if let playback { return playback }
        return calendar.isDate(selectedDay, inSameDayAs: now) ? now : selection
    }

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
            temperatureText: "\(AppRegion.current.temperature(celsius: best.temperatureCelsius))°",
            condition: best.condition,
            windSpeedMetersPerSecond: best.windSpeedMetersPerSecond
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
        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(9)), weight: .semibold))
        .foregroundStyle(Color.tpInk.opacity(0.78))
        .multilineTextAlignment(.trailing)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.tpSurface.opacity(0.92), in: RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous)
                .stroke(Color.tpBorder, lineWidth: TaptionBorder.width)
        }
        .accessibilityElement(children: .combine)
    }
}
