import CoreLocation
import Foundation

/// 집 아이콘 하늘에 쓰는 천문 계산. 네트워크 없이 NOAA 태양 공식과 달 황경 주요 항만 쓴다(SKY1103A01).
enum MapHomeAstronomy {
    private static let radians = Double.pi / 180
    /// 대기 굴절과 해 반지름을 더한 일출·일몰 고도.
    static let sunriseAltitude = -0.833

    struct SolarPosition: Equatable, Sendable {
        let declination: Double
        /// 분. 시태양시와 평균 태양시의 차이.
        let equationOfTime: Double
        let eclipticLongitude: Double
    }

    struct MoonPhase: Equatable, Sendable {
        /// 해와 달의 황경 차(0 = 삭, 180 = 망).
        let elongation: Double
        var illumination: Double { (1 - cos(elongation * radians)) / 2 }
        var isWaxing: Bool { elongation < 180 }
    }

    static func julianDay(_ date: Date) -> Double {
        date.timeIntervalSince1970 / 86_400 + 2_440_587.5
    }

    private static func date(julianDay: Double) -> Date {
        Date(timeIntervalSince1970: (julianDay - 2_440_587.5) * 86_400)
    }

    private static func normalized(_ degrees: Double) -> Double {
        let value = degrees.truncatingRemainder(dividingBy: 360)
        return value < 0 ? value + 360 : value
    }

    static func solarPosition(julianDay: Double) -> SolarPosition {
        let t = (julianDay - 2_451_545) / 36_525
        let meanLongitude = normalized(280.46646 + t * (36_000.76983 + t * 0.0003032))
        let anomaly = (357.52911 + t * (35_999.05029 - t * 0.0001537)) * radians
        let eccentricity = 0.016708634 - t * (0.000042037 + t * 0.0000001267)
        let center = sin(anomaly) * (1.914602 - t * (0.004817 + t * 0.000014))
            + sin(2 * anomaly) * (0.019993 - t * 0.000101)
            + sin(3 * anomaly) * 0.000289
        let omega = (125.04 - 1_934.136 * t) * radians
        let longitude = meanLongitude + center - 0.00569 - 0.00478 * sin(omega)
        let meanObliquity = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
        let obliquity = (meanObliquity + 0.00256 * cos(omega)) * radians
        let y = pow(tan(obliquity / 2), 2)
        let l0 = meanLongitude * radians
        let equation = y * sin(2 * l0) - 2 * eccentricity * sin(anomaly)
            + 4 * eccentricity * y * sin(anomaly) * cos(2 * l0)
            - 0.5 * y * y * sin(4 * l0)
            - 1.25 * eccentricity * eccentricity * sin(2 * anomaly)
        return SolarPosition(
            declination: asin(sin(obliquity) * sin(longitude * radians)) / radians,
            equationOfTime: 4 * equation / radians,
            eclipticLongitude: normalized(longitude)
        )
    }

    /// 지정한 고도를 지나는 시각의 정오 기준 시간각(도). 그 고도를 지나지 않는 날이면 nil.
    private static func hourAngle(altitude: Double, latitude: Double, declination: Double) -> Double? {
        let phi = latitude * radians, delta = declination * radians
        let value = (sin(altitude * radians) - sin(phi) * sin(delta)) / (cos(phi) * cos(delta))
        guard abs(value) <= 1 else { return nil }
        return acos(value) / radians
    }

    /// 경도까지 반영한 그 지역 태양일 번호. 하루가 지역 평균 자정에서 바뀌므로 시간대가 필요 없다.
    static func solarDayNumber(at date: Date, longitude: Double) -> Int {
        Int((julianDay(date) + longitude / 360 + 0.5).rounded(.down))
    }

    struct SolarDay: Equatable, Sendable {
        let noon: Date
        let sunrise: Date?
        let sunset: Date?
        let declination: Double
    }

    static func solarDay(number: Int, latitude: Double, longitude: Double) -> SolarDay {
        let safeLatitude = min(89.9, max(-89.9, latitude))
        let meanNoon = Double(number) - longitude / 360
        var position = solarPosition(julianDay: meanNoon)
        let noonDay = meanNoon - position.equationOfTime / 1_440
        position = solarPosition(julianDay: noonDay)

        func event(_ sign: Double) -> Date? {
            // 해의 적위가 그날 안에서도 움직이므로 그 시각의 값으로 두 번 고쳐 푼다.
            var day = noonDay
            for _ in 0..<2 {
                let here = solarPosition(julianDay: day)
                guard let angle = hourAngle(
                    altitude: sunriseAltitude, latitude: safeLatitude, declination: here.declination
                ) else { return nil }
                day = meanNoon - here.equationOfTime / 1_440 + sign * angle / 360
            }
            return date(julianDay: day)
        }
        return SolarDay(
            noon: date(julianDay: noonDay),
            sunrise: event(-1),
            sunset: event(1),
            declination: position.declination
        )
    }

    static func moonPhase(at date: Date) -> MoonPhase {
        let day = julianDay(date)
        let t = (day - 2_451_545) / 36_525
        let lp = 218.3164477 + 481_267.88123421 * t
        let d = (297.8501921 + 445_267.1114034 * t) * radians
        let m = (357.5291092 + 35_999.0502909 * t) * radians
        let mp = (134.9633964 + 477_198.8675055 * t) * radians
        let f = (93.2720950 + 483_202.0175233 * t) * radians
        let longitude = lp
            + 6.288774 * sin(mp) + 1.274027 * sin(2 * d - mp) + 0.658314 * sin(2 * d)
            + 0.213618 * sin(2 * mp) - 0.185116 * sin(m) - 0.114332 * sin(2 * f)
            + 0.058793 * sin(2 * d - 2 * mp) + 0.057066 * sin(2 * d - m - mp)
            + 0.053322 * sin(2 * d + mp) + 0.045758 * sin(2 * d - m)
        return MoonPhase(elongation: normalized(longitude - solarPosition(julianDay: day).eclipticLongitude))
    }
}

/// 하늘의 때. 고도와 오전·오후로 나눈다.
enum MapHomeSkyPhase: Sendable {
    case night, dawn, sunrise, day, sunset, dusk
}

/// 어제·오늘·내일의 해 뜨고 지는 시각과 달 위상. 태양일이나 집 위치가 바뀔 때만 다시 계산한다.
struct MapHomeSkyWindow: Equatable, Sendable {
    let dayNumber: Int
    let latitude: Double
    let longitude: Double
    let yesterday: MapHomeAstronomy.SolarDay
    let today: MapHomeAstronomy.SolarDay
    let tomorrow: MapHomeAstronomy.SolarDay
    let moon: MapHomeAstronomy.MoonPhase

    init(dayNumber: Int, latitude: Double, longitude: Double) {
        self.dayNumber = dayNumber
        self.latitude = latitude
        self.longitude = longitude
        yesterday = MapHomeAstronomy.solarDay(number: dayNumber - 1, latitude: latitude, longitude: longitude)
        today = MapHomeAstronomy.solarDay(number: dayNumber, latitude: latitude, longitude: longitude)
        tomorrow = MapHomeAstronomy.solarDay(number: dayNumber + 1, latitude: latitude, longitude: longitude)
        moon = MapHomeAstronomy.moonPhase(at: today.noon)
    }

    /// 한 칸 캐시. 하늘은 프레임마다 읽지만 계산은 하루에 한 번이다.
    @MainActor private static var cached: MapHomeSkyWindow?
    @MainActor private(set) static var computeCount = 0

    @MainActor
    static func current(at date: Date, coordinate: CLLocationCoordinate2D) -> MapHomeSkyWindow {
        let number = MapHomeAstronomy.solarDayNumber(at: date, longitude: coordinate.longitude)
        if let cached, cached.dayNumber == number,
           cached.latitude == coordinate.latitude, cached.longitude == coordinate.longitude {
            return cached
        }
        computeCount += 1
        let window = MapHomeSkyWindow(dayNumber: number, latitude: coordinate.latitude, longitude: coordinate.longitude)
        cached = window
        return window
    }
}

/// 한 순간의 하늘. 해·달은 호 위의 진행도로 나타낸다(0 = 동쪽 지평선, 1 = 서쪽 지평선).
struct MapHomeSkyState: Equatable, Sendable {
    let altitude: Double
    let isMorning: Bool
    /// 범위 밖이면 지평선 아래. 해가 지평선을 넘어가는 동안도 이어지도록 0~1 밖의 값을 그대로 둔다.
    let sunProgress: Double?
    let moonProgress: Double?
    let noonAltitude: Double
    let moon: MapHomeAstronomy.MoonPhase
    let isNorthernHemisphere: Bool

    init(date: Date, window: MapHomeSkyWindow) {
        let today = window.today
        let time = date.timeIntervalSince(today.noon)
        let phi = window.latitude * .pi / 180
        let delta = today.declination * .pi / 180
        let sinAltitude = sin(phi) * sin(delta) + cos(phi) * cos(delta) * cos(time / 86_400 * 2 * .pi)
        altitude = asin(min(1, max(-1, sinAltitude))) * 180 / .pi
        isMorning = time < 0
        noonAltitude = 90 - abs(window.latitude - today.declination)
        moon = window.moon
        isNorthernHemisphere = window.latitude >= 0

        if let sunrise = today.sunrise, let sunset = today.sunset {
            let t = date.timeIntervalSince1970
            let rise = sunrise.timeIntervalSince1970, set = sunset.timeIntervalSince1970
            let dayLength = max(60, set - rise)
            let fallbackNight = max(60, 86_400 - dayLength)
            let previousSet = window.yesterday.sunset?.timeIntervalSince1970 ?? rise - fallbackNight
            let nextRise = window.tomorrow.sunrise?.timeIntervalSince1970 ?? set + fallbackNight
            sunProgress = (t - rise) / dayLength
            // 달은 어제 일몰부터 오늘 일출까지, 오늘 일몰부터 내일 일출까지의 호를 건너 해와 이어진다.
            moonProgress = time < 0
                ? (t - previousSet) / max(60, rise - previousSet)
                : (t - set) / max(60, nextRise - set)
        } else if noonAltitude > MapHomeAstronomy.sunriseAltitude {
            // 백야: 해가 지평선 위에서 하루를 돈다. 달은 그리지 않는다.
            sunProgress = 0.5 + time / 86_400
            moonProgress = nil
        } else {
            // 극야: 달이 하늘을 돌고 해는 뜨지 않는다.
            sunProgress = nil
            let turn = time / 86_400
            moonProgress = turn - turn.rounded(.down)
        }
    }

    var phase: MapHomeSkyPhase {
        if altitude >= 6 { return .day }
        if altitude >= MapHomeAstronomy.sunriseAltitude { return isMorning ? .sunrise : .sunset }
        if altitude >= -12 { return isMorning ? .dawn : .dusk }
        return .night
    }

    /// 지평선 근처에서 1까지 오르는 일출·일몰 세기.
    var horizonWeight: Double {
        max(0, 1 - abs(altitude - 1) / 7)
    }

    /// 0 = 깊은 밤, 1 = 한낮. 구름과 지면의 밝기를 정한다.
    var daylight: Double {
        min(1, max(0, (altitude + 10) / 18))
    }

    /// 별이 보이는 정도.
    var starVisibility: Double {
        min(1, max(0, (-altitude - 3) / 9))
    }
}

/// 해·달의 화면 위치. 좌표는 원 지름 78 기준이고, 지도 위쪽 방위를 따라 동쪽이 도는 방향으로 움직인다.
enum MapHomeHomeSkyLayout {
    static let horizonY: CGFloat = 56
    static let center: CGFloat = 39
    static let reach: CGFloat = 30

    /// 호의 높이. 해가 높이 뜨는 계절일수록 높다.
    static func peak(noonAltitude: Double) -> CGFloat {
        CGFloat(30 + 12 * min(1, max(0, noonAltitude / 80)))
    }

    /// 동쪽이 화면 오른쪽으로 치우친 정도(-1~1). 동쪽이 거의 위아래일 때만 좁혀 호가 집 뒤에 머물지 않게 한다.
    static func eastFactor(headingDegrees: Double) -> CGFloat {
        CGFloat(min(1, max(-1, cos(headingDegrees * .pi / 180) * 3)))
    }

    /// `headingDegrees`는 지도 위쪽의 방위(북쪽 위 = 0). 동쪽은 북쪽 위에서 오른쪽, 남쪽 위에서 왼쪽이다.
    static func point(progress: Double, peak: CGFloat, headingDegrees: Double) -> CGPoint {
        CGPoint(
            x: center + eastFactor(headingDegrees: headingDegrees) * reach * CGFloat(1 - 2 * progress),
            y: horizonY - peak * CGFloat(sin(.pi * progress))
        )
    }
}
