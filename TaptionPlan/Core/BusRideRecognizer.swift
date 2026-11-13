import Foundation
import TaptionPlanEngine

/// 내 차가 아닌 차량 이동을 버스로 본다(TRF1113A01, 대표 신고 2026-11-13: 서비스센터에 차를 맡기고 버스로 왔는데 「자동차」로 기록).
/// 같은 날 아침 운전(등록한 차 블루투스 연결, 신호 대기 80~160초 7번)과 버스(연결 없음, 15~45초 정차 12번)를 비교해 만든 규칙:
/// 등록한 차가 있는 사용자가 그 차에 연결되지 않은 채 차량으로 움직였고, 정류장처럼 짧게 자주 섰으면 버스다.
/// 사용자가 고른 수단·직접 고친 구간·차 오디오로 확정된 구간은 건드리지 않는다. 판정은 「보통」 확신으로 두어 확인할 수 있게 한다.
enum BusRideRecognizer {
    static let evidencePrefix = "등록한 차 연결 없음 · 정류장 정차"
    static let stopEvidence = "승하차 지점 버스정류장(오픈스트리트맵)"
    /// 정류장 정차로 보는 머문 시간.
    static let stopSeconds: ClosedRange<TimeInterval> = 8...75
    /// 이 속도(m/s)보다 느리면 서 있는 것으로 본다.
    static let stoppedSpeed = 1.5
    static let minimumStops = 4
    static let minimumStopsPerKm = 1.0
    static let minimumMeters = 1_000.0
    static let minimumDuration: TimeInterval = 5 * 60
    /// 이보다 흐린 GPS 점은 쓰지 않는다.
    static let maximumAccuracy = 30.0

    struct Stops: Equatable {
        var meters: Double
        var short: Int
        var long: Int
    }

    /// GPS 점으로 움직인 거리와 짧은(정류장)·긴(신호·정체) 정차 수를 센다.
    static func stops(in readings: [SensorReading]) -> Stops {
        let points = readings
            .compactMap { reading in reading.point.flatMap { $0.horizontalAccuracy <= maximumAccuracy ? (reading.timestamp, $0) : nil } }
            .sorted { $0.0 < $1.0 }
        var meters = 0.0, short = 0, long = 0, still: TimeInterval = 0
        func close() {
            if stopSeconds.contains(still) { short += 1 } else if still > stopSeconds.upperBound { long += 1 }
            still = 0
        }
        for (a, b) in zip(points, points.dropFirst()) {
            let seconds = b.0.timeIntervalSince(a.0)
            guard seconds > 0 else { continue }
            let step = distanceMeters(a.1, b.1)
            meters += step
            if step / seconds < stoppedSpeed { still += seconds } else { close() }
        }
        close()
        return Stops(meters: meters, short: short, long: long)
    }

    static func looksLikeBus(_ stops: Stops) -> Bool {
        guard stops.meters >= minimumMeters, stops.short >= minimumStops, stops.short > stops.long else { return false }
        return Double(stops.short) / (stops.meters / 1_000) >= minimumStopsPerKm
    }

    static func applying(
        _ segments: [TravelSegment],
        readings: [SensorReading],
        registered: Set<String>,
        corrections: [TravelModeCorrection],
        stopDefaults: UserDefaults = .standard
    ) -> [TravelSegment] {
        segments.map { segment in
            guard segment.mode == .car, !segment.isConfirmed,
                  segment.span.end.timeIntervalSince(segment.span.start) >= minimumDuration,
                  !segment.evidence.contains(where: { $0.hasPrefix("사용자 확인") || $0.hasPrefix(CarAudioTravelConfirmation.matchedEvidencePrefix) }),
                  !corrections.contains(where: { $0.span.overlapsMostly(segment.span) }) else { return segment }
            let inside = readings.filter { segment.span.contains($0.timestamp) }
            // 등록한 차나 다른 차 오디오에 연결됐으면 차다.
            guard !inside.isEmpty, !inside.contains(where: { $0.carAudioRouteName != nil }) else { return segment }
            let found = stops(in: inside)
            // 승하차 지점이 버스정류장인지(지도 타일로 미리 확인해 둔 것, BST1113A01). 둘 다 정류장이 아니면 버스가 아니다.
            let board = BusStopCheck.known(.board, segment: segment, defaults: stopDefaults)
            let alight = BusStopCheck.known(.alight, segment: segment, defaults: stopDefaults)
            if board == false, alight == false { return segment }
            let atStops = board == true && alight == true
            // 등록한 차가 없으면 남의 차인지 알 수 없어 정류장과 정차 모양이 둘 다 맞아야 한다.
            let isBus = registered.isEmpty ? atStops && looksLikeBus(found) : atStops || looksLikeBus(found)
            guard isBus else { return segment }
            var value = segment
            value.mode = .bus
            value.confidence = atStops ? .high : .medium
            if value.distanceMeters <= 0 { value.distanceMeters = found.meters }
            value.evidence.removeAll { $0 == "차량 종류는 사용자 확인 필요" }
            value.evidence.append(atStops ? stopEvidence : "\(evidencePrefix) \(found.short)회")
            return value
        }
    }
}
