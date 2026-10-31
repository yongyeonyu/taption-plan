import CoreMotion
import Foundation
import TaptionPlanCore

// MARK: - Historical iPhone motion data

final class AppleMotionHistoryService: @unchecked Sendable {
    private let activityManager: CMMotionActivityManager
    private let pedometer: CMPedometer

    init(
        activityManager: CMMotionActivityManager = CMMotionActivityManager(),
        pedometer: CMPedometer = CMPedometer()
    ) {
        self.activityManager = activityManager
        self.pedometer = pedometer
    }

    func permissionState() -> PermissionState {
        switch CMMotionActivityManager.authorizationStatus() {
        case .notDetermined:
            return .notDetermined
        case .restricted, .denied:
            return .denied
        case .authorized:
            return .authorized
        @unknown default:
            return .unavailable
        }
    }

    func requestAuthorization() async -> PermissionState {
        guard CMMotionActivityManager.isActivityAvailable() else {
            return .unavailable
        }
        let end = Date.now
        return await withCheckedContinuation { continuation in
            activityManager.queryActivityStarting(
                from: end.addingTimeInterval(-1),
                to: end,
                to: .main
            ) { [weak self] _, _ in
                continuation.resume(
                    returning: self?.permissionState() ?? .unavailable
                )
            }
        }
    }

    func activities(in span: TimeSpan) async throws -> [MotionActivityRecord] {
        guard CMMotionActivityManager.isActivityAvailable() else { return [] }
        // Core Motion returns the last activity up to the requested end date.
        // For today's query that would incorrectly project walking/rest into
        // the future and inflate the review totals. Historical days retain
        // their original boundary.
        let queryEnd = min(span.end, Date.now)
        guard span.start < queryEnd else { return [] }
        return try await withCheckedThrowingContinuation { continuation in
            activityManager.queryActivityStarting(
                from: span.start,
                to: queryEnd,
                to: .main
            ) { activities, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    let ordered = (activities ?? [])
                        .filter { $0.startDate < queryEnd }
                        .sorted { $0.startDate < $1.startDate }
                    let records = ordered.enumerated().compactMap {
                        index, activity -> MotionActivityRecord? in
                        let start = max(span.start, activity.startDate)
                        let nextStart = ordered.indices.contains(index + 1)
                            ? ordered[index + 1].startDate
                            : queryEnd
                        let end = min(queryEnd, max(start, nextStart))
                        guard start < end else { return nil }
                        return MotionActivityRecord(
                            span: TimeSpan(start: start, end: end),
                            motion: Self.motionKind(activity),
                            confidence: Self.confidence(activity.confidence)
                        )
                    }
                    continuation.resume(returning: records)
                }
            }
        }
    }

    func pedometerSummary(in span: TimeSpan) async throws -> PedometerSummary? {
        guard CMPedometer.isStepCountingAvailable() else { return nil }
        return try await withCheckedThrowingContinuation { continuation in
            pedometer.queryPedometerData(
                from: span.start,
                to: span.end
            ) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(
                        returning: PedometerSummary(
                            span: TimeSpan(
                                start: data.startDate,
                                end: data.endDate
                            ),
                            stepCount: data.numberOfSteps.intValue,
                            distanceMeters: data.distance?.doubleValue,
                            floorsAscended: data.floorsAscended?.intValue,
                            floorsDescended: data.floorsDescended?.intValue,
                            averageActivePaceSecondsPerMeter:
                                data.averageActivePace?.doubleValue
                        )
                    )
                } else {
                    continuation.resume(
                        throwing: CocoaError(.fileReadUnknown)
                    )
                }
            }
        }
    }

    private static func motionKind(_ activity: CMMotionActivity) -> MotionKind {
        MotionKindResolver.resolve(
            stationary: activity.stationary,
            walking: activity.walking,
            running: activity.running,
            cycling: activity.cycling,
            automotive: activity.automotive
        )
    }

    private static func confidence(
        _ confidence: CMMotionActivityConfidence
    ) -> ConfidenceLevel {
        switch confidence {
        case .high: .high
        case .medium: .medium
        case .low: .low
        @unknown default: .low
        }
    }
}
