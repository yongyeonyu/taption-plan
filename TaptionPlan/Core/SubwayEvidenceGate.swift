import Foundation

/// 지하철은 신호 점수를 더해 정하지 않고, 여러 조건이 겹쳐야만 후보로 남긴다(대표 지시, PAW1102A03).
/// 조건: 탑승·하차역이 있는 노선, 경로에서 감지한 역, 고도 변화, 탑승·하차역 5분 체류, 지하철에만 나타나는 신호와 그 외 근거.
enum SubwayEvidenceGate {
    struct Input: Equatable, Sendable {
        /// 카탈로그에서 유효한 탑승→하차 노선을 만들었는가.
        var hasBoardingToAlightingRoute: Bool
        /// 경로에서 감지한 서로 다른 역 수.
        var sensedStationCount: Int
        /// 고도가 변했는가. 기압계 표본이 없으면 호출부에서 참으로 넘긴다(확인 불가는 막지 않는다).
        var hasAltitudeChange: Bool
        /// 지하철에서만 나타나는 신호: GPS 끊김, 지하철 Wi-Fi, 역 정차 패턴, 역 주변 고도 하강, 사용자 역 일치.
        var transitSpecificSignals: Int
        /// 그 외 근거: 철도 경로 일치, 걸음 거의 없음, 워치 철도 진동.
        var supportingSignals: Int
        /// 탑승역·하차역 근처에 머문 시간. 앞뒤 기록이 없어 잴 수 없으면 nil(막지 않는다).
        var boardingDwell: TimeInterval? = nil
        var alightingDwell: TimeInterval? = nil
    }

    static let minimumSensedStations = 2
    static let minimumIndependentSignals = 2
    /// 역을 지나간 것과 타고 내린 것을 가른다(대표 지시).
    static let minimumStationDwell: TimeInterval = 5 * 60
    static let stationRadiusMeters = 300.0
    /// 이 간격을 넘게 기록이 비면 같은 체류로 잇지 않는다.
    private static let maximumDwellGap: TimeInterval = 3 * 60

    /// 역 근처에 이어서 머문 가장 긴 시간. 지하에서 위치가 끊긴 기록은 체류를 이어 주기만 한다.
    /// 앞뒤로 위치 기록이 전혀 없어 잴 수 없으면 nil이다.
    static func stationDwell(readings: [SensorReading], station: GeoPoint) -> TimeInterval? {
        var longest: TimeInterval = 0
        var runStart: Date?
        var lastInRun: Date?
        var hasNearReading = false
        var hasAnyPosition = false
        func closeRun() {
            if hasNearReading, let runStart, let lastInRun {
                longest = max(longest, lastInRun.timeIntervalSince(runStart))
            }
            runStart = nil
            lastInRun = nil
            hasNearReading = false
        }
        for reading in readings.sorted(by: { $0.timestamp < $1.timestamp }) {
            if let lastInRun, reading.timestamp.timeIntervalSince(lastInRun) > maximumDwellGap { closeRun() }
            let distance = reading.gpsAvailable ? reading.point.map { PlanarDistance.meters($0, station) } : nil
            if distance != nil { hasAnyPosition = true }
            if let distance, distance > stationRadiusMeters {
                closeRun()
                continue
            }
            if distance != nil { hasNearReading = true }
            if runStart == nil { runStart = reading.timestamp }
            lastInRun = reading.timestamp
        }
        closeRun()
        return hasAnyPosition ? longest : nil
    }


    static func missingConditions(_ input: Input) -> [String] {
        var missing: [String] = []
        if !input.hasBoardingToAlightingRoute { missing.append("탑승·하차역") }
        if input.sensedStationCount < minimumSensedStations { missing.append("경로 역 감지") }
        if !input.hasAltitudeChange { missing.append("고도 변화") }
        if input.transitSpecificSignals < 1 { missing.append("지하철 전용 신호") }
        if input.transitSpecificSignals + input.supportingSignals < minimumIndependentSignals {
            missing.append("독립 근거 2개")
        }
        if let dwell = input.boardingDwell, dwell < minimumStationDwell { missing.append("탑승역 5분 체류") }
        if let dwell = input.alightingDwell, dwell < minimumStationDwell { missing.append("하차역 5분 체류") }
        return missing
    }
}
