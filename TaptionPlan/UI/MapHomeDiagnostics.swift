import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

@MainActor
enum MapHomeCameraLogThrottle {
    private static var lastUptime: TimeInterval = 0

    static func shouldLog(nowUptime: TimeInterval, interval: TimeInterval = 1) -> Bool {
        guard nowUptime - lastUptime >= interval else { return false }
        lastUptime = nowUptime
        return true
    }
}

/// 지도에 쓰인 점 중 가장 크게 튄 구간을 좌표 없이 요약해 로그로 남긴다.
enum MapHomeRouteJumpDiagnostics {
    static func fields(for readings: [SensorReading], calendar: Calendar = .autoupdatingCurrent) -> [String: String] {
        let sorted = readings
            .filter { $0.point != nil }
            .sorted { $0.timestamp < $1.timestamp }
        var best: (meters: Double, gap: TimeInterval, later: SensorReading)?
        for (earlier, later) in zip(sorted, sorted.dropFirst()) {
            guard let from = earlier.point, let to = later.point else { continue }
            let meters = distanceMeters(from, to)
            if best == nil || meters > best!.meters {
                best = (meters, later.timestamp.timeIntervalSince(earlier.timestamp), later)
            }
        }
        guard let best else { return [:] }
        let parts = calendar.dateComponents([.hour, .minute], from: best.later.timestamp)
        return [
            "largest_jump_m": String(Int(best.meters.rounded())),
            "largest_jump_gap_s": String(Int(best.gap.rounded())),
            "largest_jump_speed_mps": best.gap > 0 ? String(Int((best.meters / best.gap).rounded())) : "0",
            "largest_jump_at": String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0),
            "largest_jump_quality": best.later.locationFixQuality?.rawValue ?? "unknown",
            "largest_jump_device": best.later.sourceDevice?.rawValue ?? "unknown",
            "largest_jump_accuracy_m": best.later.point.map { String(Int($0.horizontalAccuracy.rounded())) } ?? "unknown",
        ]
    }
}

/// 예상 경로 중 양 끝이 가장 멀리 떨어진 것을 좌표 없이 요약한다.
/// 직선처럼 먼 예상 경로가 어디서 생겼는지(종류·수단·시각) 로그로 가려내기 위함이다.
enum MapHomeExpectedRouteDiagnostics {
    struct Candidate {
        let kind: String
        let mode: String
        let start: Date
        let end: Date
        let first: CLLocationCoordinate2D
        let last: CLLocationCoordinate2D
    }

    static func fields(
        for candidates: [Candidate],
        calendar: Calendar = .autoupdatingCurrent
    ) -> [String: String] {
        var best: (Candidate, Double)?
        for candidate in candidates {
            let meters = CLLocation(latitude: candidate.first.latitude, longitude: candidate.first.longitude)
                .distance(from: CLLocation(latitude: candidate.last.latitude, longitude: candidate.last.longitude))
            guard meters.isFinite else { continue }
            if best == nil || meters > best!.1 { best = (candidate, meters) }
        }
        guard let (candidate, meters) = best else { return [:] }
        func clock(_ date: Date) -> String {
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        }
        return [
            "longest_route_kind": candidate.kind,
            "longest_route_mode": candidate.mode,
            "longest_route_km": String(Int((meters / 1_000).rounded())),
            "longest_route_start": clock(candidate.start),
            "longest_route_end": clock(candidate.end),
            "longest_route_minutes": String(Int(candidate.end.timeIntervalSince(candidate.start) / 60)),
        ]
    }
}
