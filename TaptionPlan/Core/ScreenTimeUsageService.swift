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
        case .dataAccessUnavailable: "데이터 접근 재승인 필요"
        case .notDetermined: "권한 필요"
        case .denied: "권한 거부됨"
        case .approved: "권한 승인됨"
        }
    }

    /// 상태 행을 탭했을 때 사용자가 실제로 무엇을 해야 하는지 알려 준다.
    var guidance: String? {
        switch self {
        case .dataAccessUnavailable:
            "앱 사용 데이터 접근 없이 승인된 상태입니다. 탭하면 승인을 해제하고 데이터 접근까지 다시 요청합니다."
        case .denied:
            "설정 > 스크린 타임 > 앱 및 웹사이트 활동에서 Taption Plan을 허용해 주세요."
        case .requiresCurrentSystem:
            "설정 > 일반 > 소프트웨어 업데이트에서 iOS 26.4 이상으로 업데이트해 주세요."
        default: nil
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
        switch authorizationState {
        case .approved:
            // 이미 데이터 접근까지 승인돼 있다.
            return
        case .unavailable:
            throw ScreenTimeUsageError.unavailable
        case .requiresCurrentSystem:
            throw ScreenTimeUsageError.requiresCurrentSystem
        case .dataAccessUnavailable:
            // FamilyControls에는 "데이터 접근을 함께 요청하는" 별도 API가
            // 없다. 시스템이 앱의 엔타이틀먼트를 보고 동의 화면 종류를
            // 고르며, 이미 승인 기록이 있으면 requestAuthorization(for:)는
            // 프롬프트 없이 즉시 반환한다. 따라서 승인을 해제하고 데몬이
            // 실제로 상태를 되돌린 뒤에 다시 요청해야 한다.
            guard DataAccessRetryMarker.canRetry else {
                // 이 빌드에서 이미 재승인을 시도했는데도 기본 승인만
                // 남았다면 다시 해제해 봐야 결과가 같다. 멀쩡한 승인을
                // 날리는 대신 원인과 다음 단계를 알려 준다.
                throw ScreenTimeUsageError.dataAccessNotGranted
            }
            DataAccessRetryMarker.markAttempted()
            try await revokeAuthorization()
            let cleared = await waitForAuthorizationStatus {
                $0 == .notDetermined || $0 == .denied
            }
            guard cleared == .notDetermined else {
                throw ScreenTimeUsageError.revokeFailed
            }
        case .notDetermined, .denied:
            break
        }

        try await AuthorizationCenter.shared.requestAuthorization(
            for: .individual
        )
        try await verifyDataAccessGranted()
#else
        throw ScreenTimeUsageError.unavailable
#endif
    }

#if canImport(FamilyControls)
    private func revokeAuthorization() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            AuthorizationCenter.shared.revokeAuthorization { result in
                continuation.resume(with: result)
            }
        }
    }

    /// `authorizationStatus`는 스크린 타임 데몬이 XPC로 밀어 주는
    /// `@Published` 값이라 호출 직후에는 아직 예전 값일 수 있다. 원하는
    /// 상태로 확정될 때까지 짧게 기다린다.
    private func waitForAuthorizationStatus(
        timeout: TimeInterval = 3,
        until isSettled: (AuthorizationStatus) -> Bool
    ) async -> AuthorizationStatus {
        let deadline = Date.now.addingTimeInterval(timeout)
        var status = AuthorizationCenter.shared.authorizationStatus
        while !isSettled(status), Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            status = AuthorizationCenter.shared.authorizationStatus
        }
        return status
    }

    /// 동의 화면을 지난 뒤 데이터 접근까지 승인됐는지 확인한다. 기본 승인만
    /// 돌아왔다면 조용히 넘어가지 말고 이유를 알려 준다.
    private func verifyDataAccessGranted() async throws {
        guard #available(iOS 26.4, *) else { return }
        let settled = await waitForAuthorizationStatus { $0 != .notDetermined }
        if settled == .approved {
            throw ScreenTimeUsageError.dataAccessNotGranted
        }
    }
#endif

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

/// 데이터 접근 재승인을 이 빌드에서 이미 시도했는지 기억한다. 앱 버전이
/// 바뀌면(= 엔타이틀먼트가 달라졌을 수 있으면) 다시 한 번 시도하게 둔다.
enum DataAccessRetryMarker {
    private static let key = "screenTime.dataAccessRetry.version"

    static var currentVersion: String {
        let bundle = Bundle.main
        let short = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0"
        let build = bundle.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "0"
        return "\(short)(\(build))"
    }

    static var canRetry: Bool {
        UserDefaults.standard.string(forKey: key) != currentVersion
    }

    static func markAttempted() {
        UserDefaults.standard.set(currentVersion, forKey: key)
    }
}

enum ScreenTimeUsageError: LocalizedError {
    case unavailable
    case requiresCurrentSystem
    case dataAccessUnavailable
    case dataAccessNotGranted
    case revokeFailed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "이 기기에서는 앱 사용시간 연동을 사용할 수 없습니다."
        case .requiresCurrentSystem:
            "앱 사용시간 기록에는 iOS 26.4 이상이 필요합니다."
        case .dataAccessUnavailable:
            "앱 사용 데이터 접근이 아직 승인되지 않았습니다. 설정 화면의 '앱 사용시간' 항목을 눌러 승인을 다시 받아 주세요."
        case .dataAccessNotGranted:
            """
            앱 사용 데이터 접근이 승인되지 않았습니다. 순서대로 확인해 주세요.
            1. 설정 > 스크린 타임을 켭니다.
            2. 설정 > 스크린 타임 > 앱 및 웹사이트 활동을 켭니다.
            3. 설정 > 스크린 타임 > 앱 사용 데이터 공유에서 Taption Plan을 허용합니다.
            그래도 같다면 이 Apple 계정에서는 접근이 제한됩니다. 가족 공유의 자녀 계정이거나 일부 국가/지역인 경우가 여기에 해당합니다.
            """
        case .revokeFailed:
            "기존 스크린 타임 승인을 해제하지 못했습니다. 설정 > 스크린 타임에서 Taption Plan의 접근을 끈 뒤 다시 시도해 주세요."
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
