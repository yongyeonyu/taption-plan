import Foundation

#if canImport(FamilyControls)
import FamilyControls
#endif

#if canImport(ManagedSettings)
import ManagedSettings
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
            "권한은 승인됐지만 앱 사용 데이터 접근이 없습니다. 설정 > 스크린 타임에서 앱 및 웹사이트 활동과 앱 사용 데이터 공유를 켜 주세요. 지역·Apple 계정에 따라 이 데이터 접근이 제공되지 않을 수도 있습니다."
        case .denied:
            "설정 > 스크린 타임 > 앱 및 웹사이트 활동에서 Taption Plan을 허용해 주세요."
        case .requiresCurrentSystem:
            "설정 > 일반 > 소프트웨어 업데이트에서 iOS 26.4 이상으로 업데이트해 주세요."
        default: nil
        }
    }
}

/// 어떤 수준까지 이름을 읽어냈는지. Screen Time은 앱 이름을 항상 주지
/// 않으므로 화면에도 "무엇을 보여 주고 있는지"를 그대로 드러낸다.
enum ScreenTimeUsageNameSource: String, Codable, Hashable, Sendable {
    /// 실제 앱 이름을 읽었다.
    case application
    /// 이름 문자열이 없어 번들 ID에서 유추했다.
    case bundleIdentifier
    /// 앱 이름을 읽지 못해 카테고리 이름으로 묶었다.
    case category
    /// 앱도 카테고리도 읽지 못해 시간대 합계만 남았다.
    case unknown
}

/// iOS는 스크린 타임 앱 이름을 문자열로 내주지 않는다. 토큰을 그릴 수 있는
/// 화면은 실제 이름을 쓰고, 문자열이 꼭 필요한 곳(기록 제목·내보내기·손쉬운
/// 사용)에서만 번들 ID로 최선의 근사값을 만든다. 정확한 이름이 아니다.
enum AppBundleDisplayName {
    /// 역DNS로는 알 수 없는 국내 앱 몇 개만 손으로 적어 둔다. 목록이
    /// 길어질 조짐이면 늘리지 말고 토큰 렌더링에 맡긴다.
    private static let curated: [String: String] = [
        "com.kakao.talk": "카카오톡",
        "com.nhn.android.search": "네이버",
        "com.navercorp.band": "밴드",
        "com.coupang.mobile": "쿠팡",
        "viva.republica.toss": "토스",
        "com.daumkakao.map": "카카오맵",
    ]

    /// 플랫폼 접두어라 이름이 아닌 조각.
    private static let noise = ["mobile", "ios", "iphone"]

    static func displayName(forBundleIdentifier identifier: String) -> String? {
        let trimmed = identifier.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else { return nil }
        if let known = curated[trimmed.lowercased()] { return known }

        let parts = trimmed.split(separator: ".")
        guard var name = parts.last.map(String.init) else { return nil }
        if noise.contains(name.lowercased()), parts.count > 1 {
            name = String(parts[parts.count - 2])
        }
        while let last = name.last, last.isNumber { name.removeLast() }
        for prefix in noise
        where name.count > prefix.count && name.lowercased().hasPrefix(prefix) {
            name.removeFirst(prefix.count)
            break
        }
        guard !name.isEmpty else { return nil }
        guard name != name.lowercased() else {
            return name.prefix(1).uppercased() + name.dropFirst()
        }
        return name
    }
}

struct ScreenTimeUsageSample: Codable, Hashable, Sendable {
    var key: String
    var title: String
    var span: TimeSpan
    var duration: TimeInterval
    var pickups: Int
    var notifications: Int
    var nameSource: ScreenTimeUsageNameSource = .application
    /// `ManagedSettings.ApplicationToken`을 인코딩한 값. 이름 문자열이
    /// 없어도 SwiftUI `Label(token)`으로 실제 앱 이름·아이콘을 그릴 수 있다.
    /// 민감 정보이므로 화면에만 쓰고 저장·로그에는 남기지 않는다.
    var applicationTokenData: Data?
}

enum ScreenTimeUsageRetryPolicy {
    static let maximumAttempts = 3

    static func delay(after attempt: Int) -> Duration {
        attempt == 1 ? .milliseconds(400) : .seconds(1)
    }

    static func shouldRetry(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        let value = error as NSError
        let type = String(reflecting: type(of: error)).lowercased()
        let domain = value.domain.lowercased()
        let description = value.localizedDescription.lowercased()
        return (domain.contains("deviceactivity") && value.code == 0)
            || type.contains("missingdata")
            || description.contains("missing data")
    }
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
            // 승인 해제는 iOS 스크린 타임 데몬과 앱의 엔타이틀먼트가
            // 어긋난 상태에서 충돌을 일으킬 수 있다. 앱에서 강제로
            // revoke하지 않고 시스템 설정에서 데이터 접근을 허용하도록
            // 안내한다.
            throw ScreenTimeUsageError.dataAccessNotGranted
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
        // Omitting `devices` keeps the query on the device that is currently
        // running the app. An explicit `.iPhone` filter can return no rows
        // when the same target is running on an iPad or a restored device.
        let filter = DeviceActivityFilter(segment: .hourly(during: range))
        let baseFields = [
            "authorization": authorizationState.rawValue,
            "start": String(Int(range.start.timeIntervalSince1970)),
            "end": String(Int(range.end.timeIntervalSince1970)),
        ]
        // A live read asks the Screen Time daemon to refresh first. Older
        // builds used only `.cached`, which commonly returned an empty result
        // immediately after the user approved access. Keep the cache as a
        // fallback for devices whose daemon has just completed a refresh.
        let policies: [(name: String, value: DeviceActivityData.Policy)] = [
            ("live", .live),
            ("cached", .cached),
        ]
        var lastError: Error?

        for policy in policies {
            for attempt in 1...ScreenTimeUsageRetryPolicy.maximumAttempts {
                let fields = baseFields.merging([
                    "attempt": String(attempt),
                    "policy": policy.name,
                ]) { _, new in new }
                TaptionPlanDiagnosticsLogger.shared.record(
                    "screen_time_query_started",
                    fields: fields
                )
                do {
                    let result = try await query(
                        filter: filter,
                        range: range,
                        policy: policy.value
                    )
                    TaptionPlanDiagnosticsLogger.shared.record(
                        "screen_time_query_completed",
                        fields: fields.merging([
                            "samples": String(result.count),
                        ]) { _, new in new }
                    )
                    if !result.isEmpty || policy.name == "cached" {
                        return result
                    }
                    TaptionPlanDiagnosticsLogger.shared.record(
                        "screen_time_query_fallback",
                        level: .notice,
                        fields: fields.merging([
                            "reason": "live_empty",
                        ]) { _, new in new }
                    )
                    break
                } catch {
                    if let accessError = dataAccessError(for: error) {
                        let errorFields = fields.merging(
                            TaptionDiagnosticError.fields(for: error)
                        ) { _, new in new }
                        TaptionPlanDiagnosticsLogger.shared.record(
                            "screen_time_query_failed",
                            level: .error,
                            fields: errorFields
                        )
                        throw accessError
                    }

                    // `missingData` means there was no activity in the
                    // requested interval, not that the integration failed.
                    // Try the cache once, then report an empty successful read.
                    if isMissingData(error) {
                        TaptionPlanDiagnosticsLogger.shared.record(
                            "screen_time_query_empty",
                            level: .notice,
                            fields: fields.merging([
                                "reason": "missing_data",
                            ]) { _, new in new }
                        )
                        break
                    }

                    lastError = error
                    let errorFields = fields.merging(
                        TaptionDiagnosticError.fields(for: error)
                    ) { _, new in new }
                    guard attempt < ScreenTimeUsageRetryPolicy.maximumAttempts,
                          ScreenTimeUsageRetryPolicy.shouldRetry(error) else {
                        TaptionPlanDiagnosticsLogger.shared.record(
                            "screen_time_query_failed",
                            level: .error,
                            fields: errorFields
                        )
                        break
                    }
                    TaptionPlanDiagnosticsLogger.shared.record(
                        "screen_time_query_retry",
                        level: .notice,
                        fields: errorFields
                    )
                    try await Task.sleep(
                        for: ScreenTimeUsageRetryPolicy.delay(after: attempt)
                    )
                }
            }
        }

        if let lastError { throw lastError }
        return []
    }

    @available(iOS 26.4, *)
    private func query(
        filter: DeviceActivityFilter,
        range: DateInterval,
        policy: DeviceActivityData.Policy
    ) async throws -> [ScreenTimeUsageSample] {
        var result: [ScreenTimeUsageSample] = []
        for try await data in DeviceActivityData.activityData(
            filteredBy: filter,
            using: policy
        ) {
            for await segment in data.activitySegments {
                guard let span = clipped(segment.dateInterval, to: range),
                      segment.totalActivityDuration > 0 else { continue }
                let perApp = await appSamples(in: segment, span: span)
                result.append(contentsOf: perApp.isEmpty
                    ? [segmentTotal(of: segment, span: span)]
                    : perApp)
            }
        }
        return result
    }

    @available(iOS 26.4, *)
    private func isMissingData(_ error: Error) -> Bool {
        if let dataError = error as? DeviceActivityData.Error {
            return dataError == .missingData
        }
        let description = String(reflecting: error).lowercased()
        return description.contains("missingdata")
            || description.contains("missing data")
    }

    @available(iOS 26.4, *)
    private func dataAccessError(for error: Error) -> ScreenTimeUsageError? {
        guard let dataError = error as? DeviceActivityData.Error else {
            return nil
        }
        switch dataError {
        case .unavailable:
            return .dataAccessUnavailable
        case .unauthorized:
            return .dataAccessNotGranted
        case .missingData:
            return nil
        @unknown default:
            return nil
        }
    }

    /// 한 시간대(segment)를 카테고리 → 앱 순으로 펼쳐 앱마다 한 줄씩 만든다.
    /// 앱을 하나도 못 읽은 카테고리는 카테고리 한 줄로 대신한다.
    @available(iOS 26.4, *)
    private func appSamples(
        in segment: DeviceActivityData.ActivitySegment,
        span: TimeSpan
    ) async -> [ScreenTimeUsageSample] {
        var values: [String: ScreenTimeUsageSample] = [:]
        for await category in segment.categories {
            let categoryName = category.category.localizedDisplayName
            var hasApplication = false
            for await app in category.applications {
                let duration = min(app.totalActivityDuration, span.duration)
                guard duration > 0 else { continue }
                hasApplication = true
                let tokenData = encodedToken(app.application.token)
                // 이름 우선순위: 실제 이름 → 번들 ID 추정 → 카테고리 → "어플".
                // 토큰이 있는 화면은 이 문자열 대신 실제 이름을 그린다.
                let realName = app.application.localizedDisplayName
                let derivedName = app.application.bundleIdentifier
                    .flatMap(AppBundleDisplayName.displayName(forBundleIdentifier:))
                let name = realName ?? derivedName
                let sample = ScreenTimeUsageSample(
                    key: applicationKey(
                        bundleIdentifier: app.application.bundleIdentifier,
                        tokenData: tokenData,
                        name: name,
                        categoryName: categoryName
                    ),
                    title: title(for: name ?? categoryName),
                    span: span,
                    duration: duration,
                    pickups: app.numberOfPickups,
                    notifications: app.numberOfNotifications,
                    nameSource: nameSource(
                        realName: realName,
                        derivedName: derivedName,
                        categoryName: categoryName
                    ),
                    applicationTokenData: tokenData
                )
                merge(sample, into: &values)
            }
            let duration = min(category.totalActivityDuration, span.duration)
            guard !hasApplication, duration > 0 else { continue }
            merge(
                ScreenTimeUsageSample(
                    key: "category:\(categoryName ?? "unknown")",
                    title: title(for: categoryName),
                    span: span,
                    duration: duration,
                    pickups: 0,
                    notifications: 0,
                    nameSource: categoryName != nil ? .category : .unknown
                ),
                into: &values
            )
        }
        return values.values.sorted { $0.title < $1.title }
    }

    @available(iOS 26.4, *)
    private func segmentTotal(
        of segment: DeviceActivityData.ActivitySegment,
        span: TimeSpan
    ) -> ScreenTimeUsageSample {
        ScreenTimeUsageSample(
            key: "total",
            title: title(for: nil),
            span: span,
            duration: min(segment.totalActivityDuration, span.duration),
            pickups: segment.totalPickupsWithoutApplicationActivity,
            notifications: 0,
            nameSource: .unknown
        )
    }

    private func nameSource(
        realName: String?,
        derivedName: String?,
        categoryName: String?
    ) -> ScreenTimeUsageNameSource {
        if realName != nil { return .application }
        if derivedName != nil { return .bundleIdentifier }
        return categoryName != nil ? .category : .unknown
    }

    private func title(for name: String?) -> String {
        guard let name, !name.isEmpty else {
            return ScreenTimeUsageRecordEngine.laneTitle
        }
        // 행 이름이 이미 "어플"이므로 제목에 접두어를 붙이지 않는다.
        return name
    }

    private func merge(
        _ sample: ScreenTimeUsageSample,
        into values: inout [String: ScreenTimeUsageSample]
    ) {
        guard let existing = values[sample.key] else {
            values[sample.key] = sample
            return
        }
        if sample.duration > existing.duration {
            values[sample.key] = sample
        }
    }

    /// 같은 앱이 시간대마다 같은 키를 갖도록 안정적인 식별자를 고른다.
    /// 번들 ID가 없으면 토큰을, 그것도 없으면 이름을 쓴다.
    private func applicationKey(
        bundleIdentifier: String?,
        tokenData: Data?,
        name: String?,
        categoryName: String?
    ) -> String {
        if let bundleIdentifier { return "bundle:\(bundleIdentifier)" }
        if let tokenData { return "token:\(tokenData.base64EncodedString())" }
        if let name { return "name:\(name)" }
        return "category:\(categoryName ?? "unknown")"
    }

#if canImport(ManagedSettings)
    private func encodedToken(_ token: ApplicationToken?) -> Data? {
        guard let token else { return nil }
        return try? JSONEncoder().encode(token)
    }
#endif

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
    case dataAccessNotGranted

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "이 기기에서는 앱 사용시간 연동을 사용할 수 없습니다."
        case .requiresCurrentSystem:
            "앱 사용시간 기록에는 iOS 26.4 이상이 필요합니다."
        case .dataAccessUnavailable:
            "권한은 승인됐지만 앱 사용 데이터 접근이 없습니다. 설정 > 스크린 타임에서 앱 및 웹사이트 활동과 앱 사용 데이터 공유를 켜 주세요. 지역·Apple 계정에 따라 이 데이터 접근이 제공되지 않을 수도 있습니다."
        case .dataAccessNotGranted:
            """
            앱 사용 데이터 접근이 승인되지 않았습니다. 순서대로 확인해 주세요.
            1. 설정 > 스크린 타임을 켭니다.
            2. 설정 > 스크린 타임 > 앱 및 웹사이트 활동을 켭니다.
            3. 설정 > 스크린 타임 > 앱 사용 데이터 공유에서 Taption Plan을 허용합니다.
            그래도 같다면 이 Apple 계정에서는 접근이 제한됩니다. 가족 공유의 자녀 계정이거나 일부 국가/지역인 경우가 여기에 해당합니다.
            """
        }
    }
}

enum ScreenTimeUsageRecordEngine {
    /// 시간표 행·기록 제목에 쓰는 사용자 표기.
    static let laneTitle = TimelineRowKind.appUsage.title

    static func recordID(for sample: ScreenTimeUsageSample) -> UUID {
        stableID(
            "\(sample.key)|\(Int(sample.span.start.timeIntervalSinceReferenceDate))"
        )
    }

    /// 화면에 쓸 "N시간 N분" 문구. 0분이면 nil.
    static func durationText(_ interval: TimeInterval) -> String? {
        let minutes = Int(interval / 60)
        guard minutes > 0 else { return nil }
        if minutes < 60 { return "\(minutes)분" }
        let remainder = minutes % 60
        return remainder == 0
            ? "\(minutes / 60)시간"
            : "\(minutes / 60)시간 \(remainder)분"
    }

    private static let bundleKeyPrefix = "bundle:"
    private static let appleBundlePrefix = "com.apple."

    /// 표본은 번들 ID를 따로 들고 다니지 않는다. 안정 키가 곧 `bundle:<ID>` 다.
    static func bundleIdentifier(of sample: ScreenTimeUsageSample) -> String? {
        guard sample.key.hasPrefix(bundleKeyPrefix) else { return nil }
        let identifier = String(sample.key.dropFirst(bundleKeyPrefix.count))
        return identifier.isEmpty ? nil : identifier
    }

    /// 스크린 타임은 화면에 뜨지 않는 iOS 자체 서비스 프로세스까지 앱처럼
    /// 올려 준다. 사용자가 쓰는 앱이면 시스템이 이름을 내주고, 내부 서비스면
    /// 내주지 않는다. 그래서 "애플이 만든 번들 ID인데 이름을 받지 못해 번들
    /// ID에서 지어낸" 줄만 감춘다. 사파리·지도·메시지처럼 이름이 오는 애플 앱은
    /// 그대로 남고, 다른 회사 앱은 이름을 못 받아도 사용자가 직접 설치한
    /// 앱이므로 남긴다. 원본 표본은 그대로 두고 목록에서만 뺀다.
    static func isHiddenSystemService(_ sample: ScreenTimeUsageSample) -> Bool {
        guard sample.nameSource == .bundleIdentifier,
              let identifier = bundleIdentifier(of: sample) else {
            return false
        }
        return identifier.lowercased().hasPrefix(appleBundlePrefix)
    }

    static func records(
        from samples: [ScreenTimeUsageSample],
        suppressedIDs: Set<UUID>
    ) -> [ActualRecord] {
        var seen = Set<UUID>()
        return samples.compactMap { sample in
            let duration = min(sample.duration, sample.span.duration)
            guard duration > 0, !isHiddenSystemService(sample) else {
                return nil
            }
            let id = recordID(for: sample)
            guard seen.insert(id).inserted, !suppressedIDs.contains(id) else {
                return nil
            }
            let evidence = [
                "Screen Time 시간대 합계",
                durationText(duration).map { "사용 \($0)" },
                sample.pickups > 0 ? "앱 열기 \(sample.pickups)회" : nil,
                sample.notifications > 0 ? "알림 \(sample.notifications)회" : nil,
                nameSourceEvidence(sample.nameSource),
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

    private static func nameSourceEvidence(
        _ source: ScreenTimeUsageNameSource
    ) -> String? {
        switch source {
        case .application: nil
        case .bundleIdentifier: "앱 이름 대신 번들 ID에서 유추한 이름입니다"
        case .category: "앱 이름을 읽을 수 없어 카테고리 단위로 묶었습니다"
        case .unknown: "앱 이름과 카테고리를 모두 읽을 수 없어 시간대 합계만 남겼습니다"
        }
    }

    /// 기록 ID → 앱 토큰. 이름 문자열이 없어도 상세 화면이 실제 앱 이름과
    /// 아이콘을 그릴 수 있도록 메모리에만 들고 다닌다.
    static func applicationTokenIndex(
        from samples: [ScreenTimeUsageSample]
    ) -> [UUID: Data] {
        samples.reduce(into: [:]) { index, sample in
            guard let data = sample.applicationTokenData else { return }
            index[recordID(for: sample)] = data
        }
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
