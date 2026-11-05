import CryptoKit
import Foundation
import TaptionPlanCore

// 아이폰↔워치 명령·payload·봉투와 동기화 프로필. (WatchSyncModels.swift에서 나눴다.)

public enum TaptionWatchCommandKind: String, Codable, CaseIterable, Sendable {
    case start
    case complete
    case postponeThirtyMinutes
    case skip
    case stopCurrentActivity
}

public struct TaptionWatchCommand: Codable, Hashable, Sendable {
    public var id: UUID
    public var planID: UUID
    public var kind: TaptionWatchCommandKind
    public var requestedAt: Date
    public var capabilityToken: UUID?

    public init(
        id: UUID = UUID(),
        planID: UUID,
        kind: TaptionWatchCommandKind,
        requestedAt: Date = .now,
        capabilityToken: UUID? = nil
    ) {
        self.id = id
        self.planID = planID
        self.kind = kind
        self.requestedAt = requestedAt
        self.capabilityToken = capabilityToken
    }
}

public struct TaptionWatchCommandCapability: Codable, Hashable, Sendable {
    public var commandID: UUID
    public var token: UUID
    public var planID: UUID
    public var kind: TaptionWatchCommandKind
    public var expiresAt: Date

    public func accepts(
        _ command: TaptionWatchCommand,
        at date: Date
    ) -> Bool {
        command.id == commandID
            && command.planID == planID
            && command.kind == kind
            && command.capabilityToken == token
            && date <= expiresAt
    }

    public init(
        commandID: UUID,
        token: UUID,
        planID: UUID,
        kind: TaptionWatchCommandKind,
        expiresAt: Date
    ) {
        self.commandID = commandID
        self.token = token
        self.planID = planID
        self.kind = kind
        self.expiresAt = expiresAt
    }
}

public enum TaptionWatchWorkoutKind: String, Codable, CaseIterable, Sendable {
    case walking
    case running
    case cycling

    public var title: String {
        switch self {
        case .walking: "걷기"
        case .running: "달리기"
        case .cycling: "자전거"
        }
    }

    public func localizedTitle(
        _ language: AppLanguagePreference.ResolvedLanguage =
            AppLanguagePreference.current.resolvedLanguage
    ) -> String {
        switch (self, language) {
        case (.walking, .korean): "걷기"
        case (.running, .korean): "달리기"
        case (.cycling, .korean): "자전거"
        case (.walking, .english): UITextPack.translate(english: "Walking")
        case (.running, .english): UITextPack.translate(english: "Running")
        case (.cycling, .english): UITextPack.translate(english: "Cycling")
        }
    }

    public var symbolName: String {
        switch self {
        case .walking: "figure.walk"
        case .running: "figure.run"
        case .cycling: "bicycle"
        }
    }
}

public enum TaptionWatchStableID {
    public static func ambientSummarySequence(
        capturedAt: Date,
        anchor: Date,
        windowDuration: TimeInterval = 10 * 60
    ) -> Int? {
        let elapsed = capturedAt.timeIntervalSince(anchor)
        guard elapsed >= 0, windowDuration.isFinite, windowDuration > 0 else {
            return nil
        }
        let index = floor(elapsed / windowDuration)
        guard index < Double(Int.max - 1) else { return nil }
        return Int(index) + 1
    }

    public static func ambientSummaryWindowStart(
        sequence: Int,
        anchor: Date,
        windowDuration: TimeInterval = 10 * 60
    ) -> Date? {
        guard sequence > 0, windowDuration.isFinite, windowDuration > 0 else {
            return nil
        }
        let offset = Double(sequence - 1) * windowDuration
        guard offset.isFinite else { return nil }
        return anchor.addingTimeInterval(offset)
    }

    public static func ambientSummarySegmentSequence(
        startedAt: Date,
        anchor: Date
    ) -> Int? {
        ambientAccelerationSequence(capturedAt: startedAt, anchor: anchor)
    }

    public static func ambientAccelerationSequence(
        capturedAt: Date,
        anchor: Date
    ) -> Int? {
        let elapsed = capturedAt.timeIntervalSince(anchor)
        guard elapsed >= 0,
              elapsed < Double(Int.max - 1) / 1_000_000 else {
            return nil
        }
        return Int((elapsed * 1_000_000).rounded(.down)) + 1
    }

    public static func ambientAccelerationSample(sessionID: UUID, sequence: Int) -> UUID {
        var input = Data()
        withUnsafeBytes(of: sessionID.uuid) { input.append(contentsOf: $0) }
        var value = UInt64(bitPattern: Int64(sequence)).bigEndian
        withUnsafeBytes(of: &value) { input.append(contentsOf: $0) }
        var bytes = Array(SHA256.hash(data: input).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    public static func ambientAccelerationTimestampKey(capturedAt: Date) -> Int64? {
        let micros = capturedAt.timeIntervalSince1970 * 1_000_000
        guard micros.isFinite,
              micros >= Double(Int64.min),
              micros < Double(Int64.max) else { return nil }
        return Int64(micros.rounded(.down))
    }

    public static func ambientAccelerationSample(capturedAt: Date) -> UUID? {
        guard let timestamp = ambientAccelerationTimestampKey(
            capturedAt: capturedAt
        ) else { return nil }
        var value = timestamp.bigEndian
        var input = Data("ambient-sample-timestamp-v1".utf8)
        withUnsafeBytes(of: &value) { input.append(contentsOf: $0) }
        let bytes = Array(SHA256.hash(data: input).prefix(16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    public static func ambientAccelerationChunkID(
        sessionID: UUID,
        sequence: Int,
        revision: Int
    ) -> UUID {
        if revision == 0, sequence >= 0, sequence <= Int(UInt32.max) {
            var bytes = withUnsafeBytes(of: sessionID) { Array($0) }
            let value = UInt32(truncatingIfNeeded: sequence)
            bytes[12] = UInt8((value >> 24) & 0xff)
            bytes[13] = UInt8((value >> 16) & 0xff)
            bytes[14] = UInt8((value >> 8) & 0xff)
            bytes[15] = UInt8(value & 0xff)
            return UUID(uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            ))
        }
        var input = Data(
            (revision > 0
                ? "ambient-chunk-revision-v1"
                : "ambient-chunk-sequence-v2").utf8
        )
        withUnsafeBytes(of: sessionID.uuid) { input.append(contentsOf: $0) }
        var sequenceValue = Int64(sequence).bigEndian
        var revisionValue = Int64(revision).bigEndian
        withUnsafeBytes(of: &sequenceValue) { input.append(contentsOf: $0) }
        withUnsafeBytes(of: &revisionValue) { input.append(contentsOf: $0) }
        let bytes = Array(SHA256.hash(data: input).prefix(16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

/// 하나의 Watch 요약 구간에 대응하는 재전송 가능한 raw 청크.
public struct TaptionWatchAccelerationChunk: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var sessionID: UUID?
    public var sequence: Int
    public var startedAt: Date
    public var endedAt: Date
    public var isFinal: Bool
    public var isAmbient: Bool
    public var schemaVersion: Int
    public var samples: [TaptionWatchAccelerationSample]
    public var ambientWindowStart: Date? = nil
    public var ambientRevision: Int? = nil

    public init(
        id: UUID = UUID(),
        sessionID: UUID?,
        sequence: Int,
        startedAt: Date,
        endedAt: Date,
        isAmbient: Bool = false,
        schemaVersion: Int = 1,
        samples: [TaptionWatchAccelerationSample],
        isFinal: Bool = false,
        ambientWindowStart: Date? = nil,
        ambientRevision: Int? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.sequence = sequence
        self.startedAt = startedAt
        self.endedAt = max(startedAt, endedAt)
        self.isFinal = isFinal
        self.isAmbient = isAmbient
        self.schemaVersion = schemaVersion
        self.samples = samples.sorted { lhs, rhs in
            if lhs.capturedAt != rhs.capturedAt {
                return lhs.capturedAt < rhs.capturedAt
            }
            return lhs.sequence < rhs.sequence
        }
        self.ambientWindowStart = ambientWindowStart
        self.ambientRevision = ambientRevision
    }
}

public enum TaptionWatchWorkoutRequestAction: String, Codable, Sendable {
    case start
    case stop
}

public struct TaptionWatchWorkoutRequest: Codable, Hashable, Sendable {
    public var id: UUID
    public var sessionID: UUID
    public var action: TaptionWatchWorkoutRequestAction
    public var kind: TaptionWatchWorkoutKind
    public var linkedPlanID: UUID?
    public var requestedAt: Date

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        action: TaptionWatchWorkoutRequestAction,
        kind: TaptionWatchWorkoutKind,
        linkedPlanID: UUID? = nil,
        requestedAt: Date = .now
    ) {
        self.id = id
        self.sessionID = sessionID
        self.action = action
        self.kind = kind
        self.linkedPlanID = linkedPlanID
        self.requestedAt = requestedAt
    }
}

public struct TaptionWatchPlanItem: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var categoryID: String
    public var startsAt: Date
    public var endsAt: Date
    public var status: String
    public var actualStartedAt: Date?
    public var categoryName: String?
    public var categoryHex: String?
    /// Goals and their child plans are both sent to the Watch.  Keeping this
    /// bit on the item lets the Watch distinguish the two without having to
    /// re-read the phone's plan hierarchy.
    public var isGoal: Bool = false
    public var parentID: UUID? = nil

    private enum CodingKeys: String, CodingKey {
        case id, title, categoryID, startsAt, endsAt, status
        case actualStartedAt, categoryName, categoryHex, isGoal, parentID
    }

    public init(
        id: UUID,
        title: String,
        categoryID: String,
        startsAt: Date,
        endsAt: Date,
        status: String,
        actualStartedAt: Date?,
        categoryName: String?,
        categoryHex: String?,
        isGoal: Bool = false,
        parentID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.categoryID = categoryID
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.status = status
        self.actualStartedAt = actualStartedAt
        self.categoryName = categoryName
        self.categoryHex = categoryHex
        self.isGoal = isGoal
        self.parentID = parentID
    }

    /// Older cached Watch payloads predate goal metadata.  Decode those
    /// payloads as ordinary plans instead of dropping the entire payload.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        categoryID = try container.decode(String.self, forKey: .categoryID)
        startsAt = try container.decode(Date.self, forKey: .startsAt)
        endsAt = try container.decode(Date.self, forKey: .endsAt)
        status = try container.decode(String.self, forKey: .status)
        actualStartedAt = try container.decodeIfPresent(
            Date.self,
            forKey: .actualStartedAt
        )
        categoryName = try container.decodeIfPresent(
            String.self,
            forKey: .categoryName
        )
        categoryHex = try container.decodeIfPresent(
            String.self,
            forKey: .categoryHex
        )
        isGoal = try container.decodeIfPresent(Bool.self, forKey: .isGoal)
            ?? false
        parentID = try container.decodeIfPresent(UUID.self, forKey: .parentID)
    }
}

/// The Watch receives a live window, not a historical archive.  A goal that
/// started earlier is retained while it is still active, but anything that
/// has ended or was completed/skipped is never sent to the Watch UI.
public enum TaptionWatchLiveItemPolicy {
    public static func isLive(_ item: TaptionWatchPlanItem, at date: Date) -> Bool {
        guard item.endsAt > date else { return false }
        return item.status == "planned" || item.status == "running"
    }

    public static func current(
        _ items: [TaptionWatchPlanItem],
        at date: Date
    ) -> [TaptionWatchPlanItem] {
        items
            .filter {
                isLive($0, at: date)
                    && $0.startsAt <= date
                    && date < $0.endsAt
            }
            .sorted(by: sort)
    }

    public static func upcoming(
        _ items: [TaptionWatchPlanItem],
        at date: Date
    ) -> [TaptionWatchPlanItem] {
        items
            .filter { isLive($0, at: date) && $0.startsAt > date }
            .sorted(by: sort)
    }

    private static func sort(
        _ lhs: TaptionWatchPlanItem,
        _ rhs: TaptionWatchPlanItem
    ) -> Bool {
        if lhs.startsAt != rhs.startsAt {
            return lhs.startsAt < rhs.startsAt
        }
        // Goals are shown before their child plans when they start together.
        if lhs.isGoal != rhs.isGoal {
            return lhs.isGoal && !rhs.isGoal
        }
        return lhs.title.localizedStandardCompare(rhs.title)
            == .orderedAscending
    }
}

/// 오늘 분류별 기록 시간. Watch 오늘 카드가 쓴다.
public struct TaptionWatchCategoryMinutes: Codable, Hashable, Sendable {
    public var categoryID: String
    public var title: String
    public var hex: String?
    public var minutes: Int

    public init(categoryID: String, title: String, hex: String?, minutes: Int) {
        self.categoryID = categoryID
        self.title = title
        self.hex = hex
        self.minutes = minutes
    }
}

public struct TaptionWatchDaySummary: Codable, Hashable, Sendable {
    public var date: Date
    public var scheduledCount: Int
    public var completedCount: Int
    public var recordedMinutes: Int
    public var activeMinutes: Int
    /// 예전 iPhone 빌드가 보낸 값에는 없다.
    public var categories: [TaptionWatchCategoryMinutes]? = nil

    public init(
        date: Date,
        scheduledCount: Int,
        completedCount: Int,
        recordedMinutes: Int,
        activeMinutes: Int,
        categories: [TaptionWatchCategoryMinutes]? = nil
    ) {
        self.date = date
        self.scheduledCount = scheduledCount
        self.completedCount = completedCount
        self.recordedMinutes = recordedMinutes
        self.activeMinutes = activeMinutes
        self.categories = categories
    }

    /// 오늘 지나간 시간 중 기록된 비율(0~1). 시계 페이스 원형이 쓴다.
    public func recordedFraction(at now: Date, calendar: Calendar = .autoupdatingCurrent) -> Double {
        let elapsed = now.timeIntervalSince(calendar.startOfDay(for: now)) / 60
        guard elapsed > 0 else { return 0 }
        return min(1, max(0, Double(recordedMinutes) / elapsed))
    }

    /// 오늘 카드에 보여 줄 분류. 긴 순서로 `limit`개까지다.
    public func topCategories(limit: Int = 3) -> [TaptionWatchCategoryMinutes] {
        Array((categories ?? []).filter { $0.minutes > 0 }.sorted { $0.minutes > $1.minutes }.prefix(limit))
    }
}

public extension Array where Element == TaptionWatchPlanItem {
    /// 아직 시작하지 않은 가장 가까운 일정. 목표 묶음과 끝난 일정은 뺀다.
    func nextPlan(after now: Date) -> TaptionWatchPlanItem? {
        filter { !$0.isGoal && $0.startsAt > now && $0.status != "completed" && $0.status != "skipped" }
            .min { $0.startsAt < $1.startsAt }
    }
}

/// iPhone-owned policy for Watch motion sampling.  The Watch receives this
/// with the normal timeline payload so an offline payload remains safe and
/// backward compatible.
///
/// 주변 가속도 수집은 이제 `CMSensorRecorder`가 맡는다. 시스템이 앱과 무관하게
/// 계속 기록하므로 `interval`은 워치의 듀티 사이클을 더 이상 결정하지 않고,
/// 이 프로필은 사실상 켜기/끄기 스위치로 동작한다.
public enum TaptionWatchAccelerationProfile: Int, Codable, CaseIterable, Hashable, Sendable {
    case off = 0
    case batterySaver = 1
    case balanced = 2
    case accuracy = 3

    public var interval: TimeInterval {
        switch self {
        case .off: 0
        case .batterySaver: 15 * 60
        case .balanced: 5 * 60
        case .accuracy: 60
        }
    }

    public var intervalMinutes: Int? {
        guard interval > 0 else { return nil }
        return Int(interval / 60)
    }

    public var displayName: String {
        switch self {
        case .off: "끔"
        case .batterySaver: "배터리 최소화"
        case .balanced: "균형"
        case .accuracy: "정확도 최적화"
        }
    }

    public var subtitle: String {
        guard interval > 0 else { return "자동 수집 안 함" }
        return "앱이 꺼져 있어도 배경에서 계속 기록"
    }

    public func localizedDisplayName(
        _ language: AppLanguagePreference.ResolvedLanguage =
            AppLanguagePreference.current.resolvedLanguage
    ) -> String {
        switch (self, language) {
        case (.off, .korean): "끔"
        case (.batterySaver, .korean): "배터리 최소화"
        case (.balanced, .korean): "균형"
        case (.accuracy, .korean): "정확도 최적화"
        case (.off, .english): UITextPack.translate(english: "Off")
        case (.batterySaver, .english): UITextPack.translate(english: "Battery saver")
        case (.balanced, .english): UITextPack.translate(english: "Balanced")
        case (.accuracy, .english): UITextPack.translate(english: "Accuracy optimized")
        }
    }

    public func localizedSubtitle(
        _ language: AppLanguagePreference.ResolvedLanguage =
            AppLanguagePreference.current.resolvedLanguage
    ) -> String {
        guard interval > 0 else {
            return language.text("자동 수집 안 함", "Automatic collection off")
        }
        return language == .korean
            ? "앱이 꺼져 있어도 배경에서 계속 기록"
            : "Keeps recording in the background when the app is closed"
    }
}

public enum TaptionWatchDataSyncProfile: Int, Codable, CaseIterable, Hashable, Sendable {
    case off = 0
    case batterySaver = 1
    case balanced = 2
    case accuracy = 3

    public var interval: TimeInterval {
        switch self {
        case .off: 0
        case .batterySaver: 15 * 60
        case .balanced: 5 * 60
        case .accuracy: 60
        }
    }

    public var intervalMinutes: Int? {
        guard interval > 0 else { return nil }
        return Int(interval / 60)
    }

    public var displayName: String {
        switch self {
        case .off: "끔"
        case .batterySaver: "배터리 최소화"
        case .balanced: "균형"
        case .accuracy: "최신 데이터 우선"
        }
    }

    public var subtitle: String {
        guard let intervalMinutes else { return "자동 가져오기 안 함" }
        return intervalMinutes.description + "분마다 건강·활동 데이터 가져오기"
    }

    public func localizedDisplayName(
        _ language: AppLanguagePreference.ResolvedLanguage =
            AppLanguagePreference.current.resolvedLanguage
    ) -> String {
        switch (self, language) {
        case (.off, .korean): "끔"
        case (.batterySaver, .korean): "배터리 최소화"
        case (.balanced, .korean): "균형"
        case (.accuracy, .korean): "최신 데이터 우선"
        case (.off, .english): UITextPack.translate(english: "Off")
        case (.batterySaver, .english): UITextPack.translate(english: "Battery saver")
        case (.balanced, .english): UITextPack.translate(english: "Balanced")
        case (.accuracy, .english): UITextPack.translate(english: "Latest data first")
        }
    }

    public func localizedSubtitle(
        _ language: AppLanguagePreference.ResolvedLanguage =
            AppLanguagePreference.current.resolvedLanguage
    ) -> String {
        guard let intervalMinutes else {
            return language.text("자동 가져오기 안 함", "Automatic import off")
        }
        return language == .korean
            ? "\(intervalMinutes)분마다 건강·활동 데이터 가져오기"
            : "Import health and activity data every \(intervalMinutes) min"
    }

    public static func profileAfterHealthAuthorization(
        current: Self,
        userDidSetProfile: Bool
    ) -> Self {
        guard current == .off, !userDidSetProfile else { return current }
        return .balanced
    }
}

public struct TaptionWatchAccelerationSettings: Codable, Hashable, Sendable {
    public var profile: TaptionWatchAccelerationProfile
    public var samplingWindowSeconds: Int

    public init(
        profile: TaptionWatchAccelerationProfile,
        samplingWindowSeconds: Int = 30
    ) {
        self.profile = profile
        self.samplingWindowSeconds = min(
            60,
            max(20, samplingWindowSeconds)
        )
    }

    public var isEnabled: Bool { profile != .off }
}

public struct TaptionWatchPayload: Codable, Hashable, Sendable {
    public var generatedAt: Date
    public var viewportStart: Date
    public var viewportEnd: Date
    public var items: [TaptionWatchPlanItem]
    public var catStyle: String
    public var reducesMotion: Bool
    public var todaySummary: TaptionWatchDaySummary? = nil
    /// 지금 하고 있는 대분류. 워치 앱과 워치 위젯이 iPhone과 같은 값을 실시간으로 보여 준다.
    /// 두 언어를 함께 보내 워치가 자기 언어 설정으로 고른다.
    public var currentActivity: TaptionWatchCurrentActivity? = nil
    public var accelerationSettings: TaptionWatchAccelerationSettings? = nil
    public var dataSyncProfile: TaptionWatchDataSyncProfile? = nil
    public var locationTrackingEnabled: Bool? = nil
    public var locationPermissionState: String? = nil
    public var activitySuggestion: TaptionWatchActivitySuggestion? = nil
    public var commandCapabilities: [TaptionWatchCommandCapability]? = nil
    public var commerceLocked: Bool? = nil
    /// Optional so payloads cached by older iPhone builds continue to decode.
    /// `automatic` is resolved on the receiving Watch using its own locale.
    public var languagePreference: String? = nil

    public init(
        generatedAt: Date,
        viewportStart: Date,
        viewportEnd: Date,
        items: [TaptionWatchPlanItem],
        catStyle: String,
        reducesMotion: Bool,
        todaySummary: TaptionWatchDaySummary? = nil,
        currentActivity: TaptionWatchCurrentActivity? = nil,
        accelerationSettings: TaptionWatchAccelerationSettings? = nil,
        dataSyncProfile: TaptionWatchDataSyncProfile? = nil,
        locationTrackingEnabled: Bool? = nil,
        locationPermissionState: String? = nil,
        activitySuggestion: TaptionWatchActivitySuggestion? = nil,
        commandCapabilities: [TaptionWatchCommandCapability]? = nil,
        commerceLocked: Bool? = nil,
        languagePreference: String? = nil
    ) {
        self.generatedAt = generatedAt
        self.viewportStart = viewportStart
        self.viewportEnd = viewportEnd
        self.items = items
        self.catStyle = catStyle
        self.reducesMotion = reducesMotion
        self.todaySummary = todaySummary
        self.currentActivity = currentActivity
        self.accelerationSettings = accelerationSettings
        self.dataSyncProfile = dataSyncProfile
        self.locationTrackingEnabled = locationTrackingEnabled
        self.locationPermissionState = locationPermissionState
        self.activitySuggestion = activitySuggestion
        self.commandCapabilities = commandCapabilities
        self.commerceLocked = commerceLocked
        self.languagePreference = languagePreference
    }
}

/// 지금 하고 있는 대분류 하나. iPhone이 계산해 워치로 보내고,
/// 워치 앱과 워치 위젯이 자기 언어 설정으로 이름을 고른다.
public struct TaptionWatchCurrentActivity: Codable, Hashable, Sendable {
    public var categoryID: String
    public var koreanTitle: String
    public var englishTitle: String
    /// 이 활동이 시작된 시각. 워치가 "지금 몇 분째"를 스스로 셀 수 있게 함께 보낸다.
    public var startedAt: Date

    public func title(for language: AppLanguagePreference.ResolvedLanguage) -> String {
        language == .korean ? koreanTitle : englishTitle
    }

    public init(
        categoryID: String,
        koreanTitle: String,
        englishTitle: String,
        startedAt: Date
    ) {
        self.categoryID = categoryID
        self.koreanTitle = koreanTitle
        self.englishTitle = englishTitle
        self.startedAt = startedAt
    }
}

private let taptionWatchMaximumClockSkew: TimeInterval = 5 * 60

extension TaptionWatchCommand {
    public func retainingData(receivedAt: Date) -> Self? {
        requestedAt <= receivedAt.addingTimeInterval(
            taptionWatchMaximumClockSkew
        ) ? self : nil
    }
}

extension TaptionWatchAccelerationChunk {
    public func retainingData(
        after cutoff: Date?,
        receivedAt: Date? = nil
    ) -> Self? {
        let latestAllowed = receivedAt?.addingTimeInterval(
            taptionWatchMaximumClockSkew
        )
        if let latestAllowed {
            guard startedAt <= latestAllowed,
                  endedAt <= latestAllowed else { return nil }
        }
        let retained = samples.filter { sample in
            if let cutoff, sample.capturedAt <= cutoff { return false }
            if let latestAllowed,
               sample.capturedAt > latestAllowed { return false }
            return true
        }
        if let cutoff, endedAt <= cutoff { return nil }
        guard !retained.isEmpty else { return nil }
        var value = self
        value.samples = Array(retained.suffix(TaptionWatchPayloadLimits.maximumAccelerationSamples))
        if let cutoff { value.startedAt = max(startedAt, cutoff) }
        value.endedAt = max(value.startedAt, endedAt)
        return value
    }
}

extension TaptionWatchSensorSummary {
    public var fallbackReadingID: UUID {
        var value = sessionID.uuid
        var hash = UInt64(bitPattern: Int64(sequence))
            &+ 14_695_981_039_346_656_037
        withUnsafeMutableBytes(of: &value) { bytes in
            for index in bytes.indices {
                hash ^= UInt64(bytes[index])
                hash = hash &* 1_099_511_628_211
                bytes[index] ^= UInt8(truncatingIfNeeded: hash >> 24)
            }
            bytes[6] = (bytes[6] & 0x0F) | 0x50
            bytes[8] = (bytes[8] & 0x3F) | 0x80
        }
        return UUID(uuid: value)
    }

    public func retainingData(
        after cutoff: Date?,
        receivedAt: Date? = nil
    ) -> Self? {
        let latestAllowed = receivedAt?.addingTimeInterval(
            taptionWatchMaximumClockSkew
        )
        func isAllowed(_ date: Date) -> Bool {
            if let cutoff, date <= cutoff { return false }
            if let latestAllowed, date > latestAllowed { return false }
            return true
        }
        guard isAllowed(startedAt), isAllowed(endedAt) else { return nil }
        var value = self
        value.routePoints = routePoints.map {
            Array($0.filter { isAllowed($0.capturedAt) }.suffix(
                TaptionWatchPayloadLimits.maximumRoutePoints
            ))
        }
        value.behaviorSegments = behaviorSegments.map {
            Array($0.filter {
                isAllowed($0.startedAt) && isAllowed($0.endedAt)
            }.suffix(TaptionWatchPayloadLimits.maximumBehaviorSegments))
        }
        return value
    }
}

extension TaptionWatchActivityConfirmation {
    public func retainingData(
        after cutoff: Date?,
        receivedAt: Date? = nil
    ) -> Self? {
        let latestAllowed = receivedAt?.addingTimeInterval(
            taptionWatchMaximumClockSkew
        )
        func isAllowed(_ date: Date) -> Bool {
            if let cutoff, date <= cutoff { return false }
            if let latestAllowed, date > latestAllowed { return false }
            return true
        }
        guard isAllowed(respondedAt),
              isAllowed(observedStartedAt),
              isAllowed(observedEndedAt) else { return nil }
        return self
    }
}

extension TaptionWatchHealthSnapshot {
    public func retainingData(
        after cutoff: Date?,
        receivedAt: Date? = nil
    ) -> Self? {
        let latestAllowed = receivedAt?.addingTimeInterval(
            taptionWatchMaximumClockSkew
        )
        if let latestAllowed {
            guard capturedAt <= latestAllowed,
                  dayStart <= latestAllowed else { return nil }
        }
        guard cutoff != nil || latestAllowed != nil else { return self }
        if let cutoff, capturedAt <= cutoff { return nil }
        var value = self
        let retained = (sleepSegments ?? []).compactMap {
            segment -> TaptionWatchSleepSegment? in
            var segment = segment
            if let latestAllowed {
                guard segment.startDate < latestAllowed else { return nil }
                segment.endDate = min(segment.endDate, latestAllowed)
            }
            guard segment.endDate > segment.startDate else { return nil }
            guard let cutoff else { return segment }
            guard segment.endDate > cutoff else { return nil }
            segment.startDate = max(segment.startDate, cutoff)
            return segment.endDate > segment.startDate ? segment : nil
        }
        if sleepSegments != nil {
            value.sleepMinutes = TaptionWatchSleepDuration.minutes(for: retained)
            value.sleepSegments = Array(
                retained.suffix(TaptionWatchPayloadLimits.maximumSleepSegments)
            )
        } else if cutoff != nil {
            value.sleepMinutes = nil
        }
        if let cutoff, dayStart <= cutoff {
            value.dayStart = cutoff
            value.activeEnergyKilocalories = nil
            value.exerciseMinutes = nil
            value.standHours = nil
            value.workoutCount = 0
        }
        return value
    }
}

public enum TaptionWatchDataSyncRequestAdmission: Sendable, Equatable {
    case accepted(String)
    case busy(activeRequestID: String, rejectedRequestID: String)
    case duplicate(String)
}

public struct TaptionWatchDataSyncRequestGate: Sendable {
    public private(set) var activeRequestID: String?
    private var handledRequestIDs = Set<String>()

    public mutating func begin(
        requestID: String?
    ) -> TaptionWatchDataSyncRequestAdmission {
        let resolvedID = requestID ?? UUID().uuidString
        if let activeRequestID {
            return .busy(
                activeRequestID: activeRequestID,
                rejectedRequestID: resolvedID
            )
        }
        if handledRequestIDs.count >= 100 {
            handledRequestIDs.removeAll(keepingCapacity: true)
        }
        guard handledRequestIDs.insert(resolvedID).inserted else {
            return .duplicate(resolvedID)
        }
        activeRequestID = resolvedID
        return .accepted(resolvedID)
    }

    public mutating func finish(_ requestID: String) -> Bool {
        guard activeRequestID == requestID else { return false }
        activeRequestID = nil
        return true
    }

    public mutating func reset() {
        activeRequestID = nil
        handledRequestIDs.removeAll(keepingCapacity: false)
    }

    public init(
        activeRequestID: String? = nil
    ) {
        self.activeRequestID = activeRequestID
    }
}

/// Watch 앱이 iPhone에 알리는 자기 버전. 메뉴의 설치·업데이트 표시에 쓴다.
public struct TaptionWatchAppVersion: Codable, Hashable, Sendable {
    public var version: String
    public var build: String

    public init(version: String, build: String) {
        self.version = version
        self.build = build
    }

    public var displayText: String { "\(version) (\(build))" }

    /// 번호를 읽지 못하면 있다고 단정하지 않는다.
    public func isOlder(thanBuild other: String) -> Bool {
        guard let mine = Int(build), let theirs = Int(other) else { return false }
        return mine < theirs
    }

    public var context: [String: Any] {
        [TaptionWatchEnvelope.appVersionKey: version, TaptionWatchEnvelope.appBuildKey: build]
    }

    public init?(context: [String: Any]) {
        guard let version = context[TaptionWatchEnvelope.appVersionKey] as? String,
              let build = context[TaptionWatchEnvelope.appBuildKey] as? String else { return nil }
        self.init(version: version, build: build)
    }
}

public enum TaptionWatchEnvelope {
    public static let appVersionKey = "taption.watch.app-version"
    public static let appBuildKey = "taption.watch.app-build"
    public static let payloadKey = "taption.watch.payload"
    public static let commandKey = "taption.watch.command"
    public static let sensorSummaryKey = "taption.watch.sensor-summary"
    public static let accelerationChunkKey = "taption.watch.acceleration-chunk"
    public static let ambientDeliveryIDKey = "taption.watch.ambient-delivery-id"
    public static let ambientAcknowledgementKey = "taption.watch.ambient-acknowledgement"
    public static let healthSnapshotKey = "taption.watch.health-snapshot"
    public static let workoutRequestKey = "taption.watch.workout-request"
    public static let activityConfirmationKey = "taption.watch.activity-confirmation"
    public static let refreshRequestKey = "taption.watch.refresh-request"
    public static let dataSyncRequestKey = "taption.watch.data-sync-request"
    public static let dataSyncRequestIDKey = "taption.watch.data-sync-request-id"
    public static let locationTrackingKey = "taption.watch.location-tracking"
    public static let locationTrackingGuidanceKey =
        "taption.watch.location-tracking-guidance"
    public static let acceptedKey = "taption.watch.accepted"
    public static let launchDiagnosticsKey = "taption.watch.launch-diagnostics"
    public static let diagnosticsRequestKey = "taption.watch.diagnostics-request"
    public static let diagnosticsLogKey = "taption.watch.diagnostics-log"
    public static let purgeRequestKey = "taption.watch.purge-request"
    public static let purgeRequestIDKey = "taption.watch.purge-request-id"
    public static let purgeGenerationKey = "taption.watch.purge-generation"
    public static let purgeAcknowledgedKey = "taption.watch.purge-acknowledged"

    public static let commandMaximumBytes = 64 * 1_024
    public static let sensorSummaryMaximumBytes = 2 * 1_024 * 1_024
    public static let accelerationChunkMaximumBytes = 4 * 1_024 * 1_024
    public static let healthSnapshotMaximumBytes = 512 * 1_024
    public static let confirmationMaximumBytes = 128 * 1_024
    public static let diagnosticsMaximumBytes = 512 * 1_024
}

public enum TaptionWatchPayloadLimits {
    public static let maximumAccelerationSamples = 20_000
    public static let maximumRoutePoints = 10_000
    public static let maximumBehaviorSegments = 2_000
    public static let maximumSleepSegments = 2_000
}
