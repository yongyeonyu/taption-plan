import Foundation

#if canImport(FamilyControls)
import FamilyControls
#endif

#if canImport(DeviceActivity) && canImport(SwiftUI)
import DeviceActivity
import SwiftUI
#endif

enum ScreenTimeAuthorizationState: String, Sendable {
    case unavailable
    case requiresCurrentSystem
    case dataAccessUnavailable
    case notDetermined
    case denied
    case approved

    var displayName: String {
        switch self {
        case .unavailable: "이 기기에서 지원 안 함"
        case .requiresCurrentSystem: "iOS 26.4 이상 필요"
        case .dataAccessUnavailable: "앱 사용 데이터 접근 불가"
        case .notDetermined: "권한 필요"
        case .denied: "권한 거부됨"
        case .approved: "권한 승인됨"
        }
    }
}

struct ScreenTimeUsageSample: Codable, Hashable, Sendable {
    var key: String
    var title: String
    var span: TimeSpan
    var duration: TimeInterval
    var pickups: Int
    var notifications: Int
}

@MainActor
final class ScreenTimeUsageService {
    var authorizationState: ScreenTimeAuthorizationState {
#if canImport(FamilyControls) && canImport(DeviceActivity) && canImport(SwiftUI)
        guard #available(iOS 26.4, *) else {
            return .requiresCurrentSystem
        }
        return switch AuthorizationCenter.shared.authorizationStatus {
        case .approvedWithDataAccess: .approved
        case .approved: .dataAccessUnavailable
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
#else
        .unavailable
#endif
    }

    func requestAuthorization() async throws {
#if canImport(FamilyControls)
        try await AuthorizationCenter.shared.requestAuthorization(
            for: .individual
        )
#else
        throw ScreenTimeUsageError.unavailable
#endif
    }

    func usage(in span: TimeSpan) async throws -> [ScreenTimeUsageSample] {
        switch authorizationState {
        case .approved:
            break
        case .requiresCurrentSystem:
            throw ScreenTimeUsageError.requiresCurrentSystem
        case .dataAccessUnavailable:
            throw ScreenTimeUsageError.dataAccessUnavailable
        default:
            return []
        }

#if canImport(DeviceActivity) && canImport(SwiftUI)
        guard #available(iOS 26.4, *) else {
            throw ScreenTimeUsageError.requiresCurrentSystem
        }
        return try await usageOnCurrentSystem(in: span)
#else
        throw ScreenTimeUsageError.unavailable
#endif
    }

#if canImport(DeviceActivity) && canImport(SwiftUI)
    @available(iOS 26.4, *)
    private func usageOnCurrentSystem(
        in requestedSpan: TimeSpan
    ) async throws -> [ScreenTimeUsageSample] {
        let end = min(requestedSpan.end, .now)
        guard requestedSpan.start < end else { return [] }
        let range = DateInterval(start: requestedSpan.start, end: end)
        let filter = DeviceActivityFilter(
            segment: .hourly(during: range),
            devices: DeviceActivityFilter.Devices([.iPhone])
        )
        var result: [ScreenTimeUsageSample] = []

        for try await data in DeviceActivityData.activityData(
            filteredBy: filter,
            using: .cached
        ) {
            for await segment in data.activitySegments {
                guard let span = clipped(segment.dateInterval, to: range),
                      segment.totalActivityDuration > 0 else {
                    continue
                }
                let apps = await applications(in: segment, span: span)
                if apps.isEmpty {
                    result.append(
                        ScreenTimeUsageSample(
                            key: "total",
                            title: "앱 사용",
                            span: span,
                            duration: min(segment.totalActivityDuration, span.duration),
                            pickups: segment.totalPickupsWithoutApplicationActivity,
                            notifications: 0
                        )
                    )
                } else {
                    result.append(contentsOf: apps)
                }
            }
        }
        return result
    }

    @available(iOS 26.4, *)
    private func applications(
        in segment: DeviceActivityData.ActivitySegment,
        span: TimeSpan
    ) async -> [ScreenTimeUsageSample] {
        var values: [String: ScreenTimeUsageSample] = [:]
        for await category in segment.categories {
            for await app in category.applications {
                let name = app.application.localizedDisplayName
                    ?? app.application.bundleIdentifier
                    ?? "앱 사용"
                let key = app.application.bundleIdentifier
                    ?? app.application.localizedDisplayName
                    ?? "unknown"
                let duration = min(app.totalActivityDuration, span.duration)
                guard duration > 0 else { continue }
                let sample = ScreenTimeUsageSample(
                    key: key,
                    title: "앱 사용 · \(name)",
                    span: span,
                    duration: duration,
                    pickups: app.numberOfPickups,
                    notifications: app.numberOfNotifications
                )
                if let existing = values[key], existing.duration >= duration {
                    continue
                }
                values[key] = sample
            }
        }
        return values.values.sorted { $0.title < $1.title }
    }

    private func clipped(
        _ interval: DateInterval,
        to range: DateInterval
    ) -> TimeSpan? {
        let start = max(interval.start, range.start)
        let end = min(interval.end, range.end)
        guard start < end else { return nil }
        return TimeSpan(start: start, end: end)
    }
#endif
}

enum ScreenTimeUsageError: LocalizedError {
    case unavailable
    case requiresCurrentSystem
    case dataAccessUnavailable

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "이 기기에서는 앱 사용시간 연동을 사용할 수 없습니다."
        case .requiresCurrentSystem:
            "앱 사용시간 기록에는 iOS 26.4 이상이 필요합니다."
        case .dataAccessUnavailable:
            "이 Apple 계정/지역에서는 앱 사용 기록 접근이 제한됩니다."
        }
    }
}

enum ScreenTimeUsageRecordEngine {
    static func records(
        from samples: [ScreenTimeUsageSample],
        suppressedIDs: Set<UUID>
    ) -> [ActualRecord] {
        var seen = Set<UUID>()
        return samples.compactMap { sample in
            let duration = min(sample.duration, sample.span.duration)
            guard duration > 0 else { return nil }
            let id = stableID(
                "\(sample.key)|\(Int(sample.span.start.timeIntervalSinceReferenceDate))"
            )
            guard seen.insert(id).inserted, !suppressedIDs.contains(id) else {
                return nil
            }
            let evidence = [
                "Screen Time 시간대 합계",
                sample.pickups > 0 ? "앱 열기 \(sample.pickups)회" : nil,
                sample.notifications > 0 ? "알림 \(sample.notifications)회" : nil,
            ].compactMap { $0 }
            return ActualRecord(
                id: id,
                planID: nil,
                title: sample.title,
                categoryID: "appUsage",
                startedAt: sample.span.start,
                endedAt: sample.span.start.addingTimeInterval(duration),
                source: .appUsage,
                confidence: .high,
                createdAt: sample.span.end,
                behavior: "screen-time",
                evidence: evidence,
                modelVersion: "device-activity-v1"
            )
        }
        .sorted { $0.startedAt < $1.startedAt }
    }

    static func replacing(
        existing: [ActualRecord],
        with fresh: [ActualRecord],
        inside span: TimeSpan
    ) -> [ActualRecord] {
        (existing.filter {
            $0.source != .appUsage
                || $0.span(asOf: span.end).intersection(with: span) == nil
        } + fresh)
            .sorted { $0.startedAt < $1.startedAt }
    }

    private static func stableID(_ key: String) -> UUID {
        var hash: UInt64 = 14_695_981_039_346_656_037
        var bytes = [UInt8](repeating: 0, count: 16)
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        for index in bytes.indices {
            hash ^= UInt64(index + 1) * 0x9E37_79B9
            hash = hash &* 1_099_511_628_211
            bytes[index] = UInt8(truncatingIfNeeded: hash >> ((index % 8) * 8))
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
