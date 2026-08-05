import ActivityKit
import Foundation
import OSLog

enum TaptionWidgetKind {
    static let schedule = "TaptionScheduleWidget"
}

struct TaptionActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var categoryID: String
        var startedAt: Date
        var endsAt: Date
        var catStyle: String
        var isRunning: Bool
    }

    var planID: UUID
}

enum TaptionWidgetCommandKind: String, Codable, CaseIterable, Sendable {
    case complete
    case postponeThirtyMinutes
    case moveToNextFreeTime
    case stopCurrentActivity
}

struct TaptionWidgetCommand: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var planID: UUID
    var kind: TaptionWidgetCommandKind
    var requestedAt: Date
    var appliedToSharedRepository: Bool?

    init(
        id: UUID = UUID(),
        planID: UUID,
        kind: TaptionWidgetCommandKind,
        requestedAt: Date = .now,
        appliedToSharedRepository: Bool? = nil
    ) {
        self.id = id
        self.planID = planID
        self.kind = kind
        self.requestedAt = requestedAt
        self.appliedToSharedRepository = appliedToSharedRepository
    }
}

enum TaptionWidgetLane: String, Codable, CaseIterable, Sendable {
    case schedule
    case location
    case movement
    case sleep
    case activity
    case appUsage
    case action

    static let automatic: [Self] = [
        .schedule,
        .location,
        .movement,
        .sleep,
        .activity,
        .appUsage,
    ]

    /// The timetable row this lane mirrors. `action` has no automatic row.
    var rowKind: TimelineRowKind? {
        TimelineRowKind(categoryID: rawValue)
    }

    var title: String {
        rowKind?.title ?? "액션"
    }

    var systemImage: String {
        rowKind?.systemImage ?? "checklist.checked"
    }
}

struct TaptionWidgetItem: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var categoryID: String
    var startsAt: Date
    var endsAt: Date
    var status: String
    var isFixed: Bool
    var categoryName: String?
    var categoryHex: String?
    var lane: TaptionWidgetLane?

    init(
        id: UUID,
        title: String,
        categoryID: String,
        startsAt: Date,
        endsAt: Date,
        status: String,
        isFixed: Bool,
        categoryName: String? = nil,
        categoryHex: String? = nil,
        lane: TaptionWidgetLane? = nil
    ) {
        self.id = id
        self.title = title
        self.categoryID = categoryID
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.status = status
        self.isFixed = isFixed
        self.categoryName = categoryName
        self.categoryHex = categoryHex
        self.lane = lane
    }

    var isRunning: Bool {
        status == "running"
    }

    var isCompleted: Bool {
        status == "completed"
    }

    var resolvedLane: TaptionWidgetLane {
        if let lane { return lane }
        return switch categoryID {
        case "calendar": .schedule
        case "location": .location
        case "movement": .movement
        case "sleep": .sleep
        case "activity": .activity
        case "appUsage": .appUsage
        default: .action
        }
    }
}

enum TaptionWidgetPlaybackEngine {
    static let defaultWindowDuration: TimeInterval = 6 * 3_600
    static let defaultResolutionLabel = "6시간"

    static func lanes(
        for items: [TaptionWidgetItem],
        at date: Date,
        windowDuration: TimeInterval = defaultWindowDuration
    ) -> [TaptionWidgetLane] {
        let hasAction = visibleItems(
            in: .action,
            from: items,
            at: date,
            windowDuration: windowDuration
        ).isEmpty == false
        return TaptionWidgetLane.automatic + (hasAction ? [.action] : [])
    }

    static func visibleItems(
        in lane: TaptionWidgetLane,
        from items: [TaptionWidgetItem],
        at date: Date,
        windowDuration: TimeInterval = defaultWindowDuration
    ) -> [TaptionWidgetItem] {
        let halfWindow = max(60, windowDuration) / 2
        let start = date.addingTimeInterval(-halfWindow)
        let end = date.addingTimeInterval(halfWindow)
        return items
            .filter { $0.resolvedLane == lane }
            .filter { lane != .action || !$0.isCompleted }
            .filter { $0.startsAt < end && start < $0.endsAt }
            .sorted {
                if $0.startsAt == $1.startsAt {
                    return $0.endsAt < $1.endsAt
                }
                return $0.startsAt < $1.startsAt
            }
    }

    static func activeItems(
        in lane: TaptionWidgetLane,
        from items: [TaptionWidgetItem],
        at date: Date
    ) -> [TaptionWidgetItem] {
        items
            .filter { $0.resolvedLane == lane }
            .filter { lane != .action || !$0.isCompleted }
            .filter { $0.startsAt <= date && date < $0.endsAt }
            .sorted { $0.startsAt < $1.startsAt }
    }

    static func timelineDates(
        for items: [TaptionWidgetItem],
        from now: Date,
        horizon: Date,
        minuteInterval: Int = 1
    ) -> [Date] {
        guard now < horizon else { return [now] }
        let step = TimeInterval(max(1, minuteInterval) * 60)
        var dates = [now]
        var next = now.addingTimeInterval(step)
        while next <= horizon {
            dates.append(next)
            next = next.addingTimeInterval(step)
        }
        dates.append(contentsOf: items.flatMap { [$0.startsAt, $0.endsAt] })
        return Array(Set(dates.filter { now <= $0 && $0 <= horizon }))
            .sorted()
    }
}

enum TaptionWidgetAutoScrollEngine {
    static let visibleRowCount = 4
    static let cycleDuration: TimeInterval = 6

    static func progress(
        at date: Date,
        rowCount: Int,
        visibleRows: Int = visibleRowCount,
        reducesMotion: Bool = false
    ) -> Double {
        guard rowCount > max(1, visibleRows) else { return 0 }
        if reducesMotion {
            let minute = Int(
                floor(date.timeIntervalSinceReferenceDate / 60)
            )
            return minute.isMultiple(of: 2) ? 0 : 1
        }

        let rawPhase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: cycleDuration)
        let phase = rawPhase < 0 ? rawPhase + cycleDuration : rawPhase
        switch phase {
        case 0..<2:
            return 0
        case 2..<3:
            return eased(phase - 2)
        case 3..<5:
            return 1
        default:
            return 1 - eased(phase - 5)
        }
    }

    static func offset(
        at date: Date,
        contentHeight: Double,
        viewportHeight: Double,
        rowCount: Int,
        visibleRows: Int = visibleRowCount,
        reducesMotion: Bool = false
    ) -> Double {
        // A fixed lane count can be larger than the nominal family limit
        // while still fitting in the actual widget height. In that case
        // there is no content to reveal, so never run the vertical motion.
        guard contentHeight > viewportHeight else { return 0 }
        return max(0, contentHeight - viewportHeight)
            * progress(
                at: date,
                rowCount: rowCount,
                visibleRows: visibleRows,
                reducesMotion: reducesMotion
            )
    }

    private static func eased(_ value: Double) -> Double {
        let clamped = min(1, max(0, value))
        return clamped * clamped * (3 - (2 * clamped))
    }
}

enum TaptionWidgetContentPolicy {
    static func locationTitle(
        displayName: String,
        floor: Int?
    ) -> String {
        let cleanName = displayName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let baseTitle = cleanName.isEmpty ? "위치 기록" : cleanName
        guard let floor else { return baseTitle }
        return "\(baseTitle) · \(floor)층"
    }
}

enum TaptionWidgetCatAction: String, CaseIterable, Equatable, Sendable {
    case walking
    case running
    case sitting
    case sleeping
    case grooming
    case eating
    case startled
    case ballPlay
    case fishingPlay
    case stretching
    case kneading
    case yawning

    var movesAcrossTrack: Bool {
        self == .walking || self == .running
    }

    var previewTitle: String {
        switch self {
        case .walking: "걷기"
        case .running: "달리기"
        case .sitting: "앉아있기"
        case .sleeping: "잠자기"
        case .grooming: "그루밍"
        case .eating: "밥 먹기"
        case .startled: "너구리 꼬리"
        case .ballPlay: "공 잡는 놀이"
        case .fishingPlay: "낚싯대 놀이"
        case .stretching: "기지개"
        case .kneading: "꾹꾹이"
        case .yawning: "하품"
        }
    }

    var previewSystemImage: String {
        switch self {
        case .walking: "figure.walk"
        case .running: "figure.run"
        case .sitting: "pawprint.fill"
        case .sleeping: "moon.zzz.fill"
        case .grooming: "sparkles"
        case .eating: "fork.knife"
        case .startled: "exclamationmark.bubble.fill"
        case .ballPlay: "circle.fill"
        case .fishingPlay: "fish.fill"
        case .stretching: "figure.flexibility"
        case .kneading: "hand.tap.fill"
        case .yawning: "mouth.fill"
        }
    }

    /// 렌더러가 쓰는 동작 이름. 두 열거형의 rawValue는 항상 같아야 한다.
    var animationAction: TaptionCatAnimationAction {
        TaptionCatAnimationAction(rawValue: rawValue) ?? .walking
    }
}

enum TaptionWidgetCatActionSelector {
    static func preferredAction(
        categoryID: String,
        title: String
    ) -> TaptionWidgetCatAction? {
        let category = categoryID.lowercased()
        let normalizedTitle = title.lowercased()

        if containsAny(
            normalizedTitle,
            ["밥", "식사", "간식", "요리", "카페"]
        ) {
            return .eating
        }
        if containsAny(normalizedTitle, ["잠", "수면", "취침", "낮잠"]) {
            return .sleeping
        }
        if containsAny(normalizedTitle, ["달리", "러닝", "조깅"]) {
            return .running
        }
        if containsAny(normalizedTitle, ["걷", "산책", "도보"]) {
            return .walking
        }
        if containsAny(
            normalizedTitle,
            ["축구", "농구", "야구", "테니스", "공놀이", "헬스", "운동"]
        ) {
            return .ballPlay
        }
        if containsAny(
            normalizedTitle,
            ["낚시", "놀이", "게임", "음악", "사진", "여행"]
        ) {
            return .fishingPlay
        }
        if containsAny(
            normalizedTitle,
            ["샤워", "세면", "씻기", "미용", "단장", "청소"]
        ) {
            return .grooming
        }
        if containsAny(normalizedTitle, ["스트레칭", "요가", "기지개"]) {
            return .stretching
        }
        if containsAny(normalizedTitle, ["명상", "휴식", "쉬기"]) {
            return .kneading
        }

        return switch category {
        case "exercise", "health": .ballPlay
        case "hobby", "travel", "photo", "event", "relationship":
            .fishingPlay
        case "sleep", "rest": .sleeping
        case "routine": .grooming
        case "movement": .walking
        case "project", "study", "location": .sitting
        default: nil
        }
    }

    private static func containsAny(
        _ value: String,
        _ candidates: [String]
    ) -> Bool {
        candidates.contains { value.contains($0) }
    }
}

struct TaptionWidgetCatWalkPose: Equatable, Sendable {
    var progress: Double
    var facesLeft: Bool
    var legPhase: Int
    var isAtEndpoint: Bool
    var action: TaptionWidgetCatAction
    var tailSwing: Double
    var headTiltDegrees: Double
    var legSwing: Double = 0
    var idle: TaptionCatIdleBeat = .still
}

enum TaptionWidgetCatWalkEngine {
    static let defaultStepDuration: TimeInterval = 0.5
    static let movementStepCount = 20
    static let stepCount = 40
    // Keep an action pose visible at each end of the track, but do not spend
    // half of the 20-second cycle parked there.  A long rest phase made the
    // widget cat look frozen whenever the current action was sitting,
    // sleeping, or another non-locomotion action.
    static let endpointActionHoldSteps = 4
    static let roundTripDuration =
        defaultStepDuration * Double(movementStepCount)
    static let sequenceDuration = defaultStepDuration * Double(stepCount)

    static func pose(
        at date: Date,
        stepDuration: TimeInterval = defaultStepDuration,
        preferredAction: TaptionWidgetCatAction? = nil
    ) -> TaptionWidgetCatWalkPose {
        let duration = max(0.5, stepDuration)
        let rawStep = Int64(date.timeIntervalSinceReferenceDate / duration)
        let count = Int64(stepCount)
        let step = Int(((rawStep % count) + count) % count)
        let cycle = rawStep / count
        let progress: Double
        let facesLeft: Bool
        let isAtEndpoint: Bool
        let action: TaptionWidgetCatAction

        switch step {
        case 0...9:
            progress = Double(step) / 9
            facesLeft = false
            isAtEndpoint = step == 0 || step == 9
            action = preferredAction == .running ? .running : .walking
        case 10:
            progress = 1
            facesLeft = true
            isAtEndpoint = true
            action = .startled
        case 11...19:
            progress = Double(19 - step) / 8
            facesLeft = true
            isAtEndpoint = step == 11 || step == 19
            action = preferredAction == .walking ? .walking : .running
        case movementStepCount..<movementStepCount + endpointActionHoldSteps:
            progress = 0
            facesLeft = false
            isAtEndpoint = step == movementStepCount
            action = restAction(
                preferred: preferredAction,
                cycle: cycle,
                slot: 0
            )
        case movementStepCount + endpointActionHoldSteps...29:
            progress = Double(
                step - (movementStepCount + endpointActionHoldSteps - 1)
            ) / 6
            facesLeft = false
            isAtEndpoint = step == 29
            action = .walking
        case 30..<30 + endpointActionHoldSteps:
            progress = 1
            facesLeft = true
            isAtEndpoint = step == 30
            action = restAction(
                preferred: preferredAction,
                cycle: cycle,
                slot: 1
            )
        default:
            progress = Double(39 - step) / 6
            facesLeft = true
            isAtEndpoint = step == 39
            action = .running
        }
        let phase = step % TaptionCatAnimationEngine.phaseCount
        let motion = motionDetails(for: action, phase: phase)
        return TaptionWidgetCatWalkPose(
            progress: min(1, max(0, progress)),
            facesLeft: facesLeft,
            legPhase: phase,
            isAtEndpoint: isAtEndpoint,
            action: action,
            tailSwing: motion.tailSwing,
            headTiltDegrees: motion.headTiltDegrees,
            legSwing: motion.legSwing,
            idle: TaptionCatIdleBeat.beat(at: date)
        )
    }

    static func motionDetails(
        for action: TaptionWidgetCatAction,
        phase: Int
    ) -> TaptionCatMotionDetails {
        TaptionCatAnimationEngine.motionDetails(
            for: action.animationAction,
            phase: phase
        )
    }

    private static func restAction(
        preferred: TaptionWidgetCatAction?,
        cycle: Int64,
        slot: Int64
    ) -> TaptionWidgetCatAction {
        if let preferred {
            return switch preferred {
            case .walking, .running: .sitting
            default: preferred
            }
        }
        let actions: [TaptionWidgetCatAction] = [
            .sitting,
            .grooming,
            .eating,
            .sleeping,
            .ballPlay,
            .fishingPlay,
            .stretching,
            .kneading,
            .yawning,
        ]
        let seed = abs((cycle &* 31) &+ (slot &* 17))
        return actions[Int(seed % Int64(actions.count))]
    }
}

enum TaptionWidgetCatPreviewEngine {
    static let stepDuration: TimeInterval = 0.1
    static let movementStepCount = 40

    static func pose(
        at date: Date,
        action: TaptionWidgetCatAction,
        reducesMotion: Bool = false
    ) -> TaptionWidgetCatWalkPose {
        let rawStep = Int64(
            floor(date.timeIntervalSinceReferenceDate / stepDuration)
        )
        let count = Int64(movementStepCount)
        let step = Int(((rawStep % count) + count) % count)
        let phase = reducesMotion
            ? 0
            : step % TaptionCatAnimationEngine.phaseCount
        let motion = TaptionWidgetCatWalkEngine.motionDetails(
            for: action,
            phase: phase
        )
        let idle = TaptionCatIdleBeat.beat(
            at: date,
            reducesMotion: reducesMotion
        )

        guard action.movesAcrossTrack, !reducesMotion else {
            return TaptionWidgetCatWalkPose(
                progress: 0.5,
                facesLeft: false,
                legPhase: phase,
                isAtEndpoint: true,
                action: action,
                tailSwing: reducesMotion ? 0 : motion.tailSwing,
                headTiltDegrees: reducesMotion
                    ? 0
                    : motion.headTiltDegrees,
                legSwing: reducesMotion ? 0 : motion.legSwing,
                idle: idle
            )
        }

        let outward = step <= movementStepCount / 2
        let distance = outward
            ? Double(step) / Double(movementStepCount / 2)
            : Double(movementStepCount - step)
                / Double(movementStepCount / 2)
        return TaptionWidgetCatWalkPose(
            progress: min(1, max(0, distance)),
            facesLeft: !outward,
            legPhase: phase,
            isAtEndpoint: step == 0 || step == movementStepCount / 2,
            action: action,
            tailSwing: motion.tailSwing,
            headTiltDegrees: motion.headTiltDegrees,
            legSwing: motion.legSwing,
            idle: idle
        )
    }
}

enum TaptionWidgetCommandEngine {
    static func apply(
        _ command: TaptionWidgetCommand,
        to source: TaptionDataSnapshot
    ) throws -> TaptionDataSnapshot {
        guard let index = source.plans.firstIndex(where: {
            $0.id == command.planID
        }) else {
            return source
        }
        var snapshot = source
        let plan = snapshot.plans[index]
        switch command.kind {
        case .complete, .stopCurrentActivity:
            let result = QuickActionEngine.complete(
                plan: plan,
                actuals: snapshot.actuals,
                at: command.requestedAt,
                copyPlannedDurationWhenMissing:
                    command.kind == .complete
            )
            snapshot.plans[index] = result.plan
            snapshot.actuals = result.actuals
        case .postponeThirtyMinutes:
            snapshot.plans[index] = try QuickActionEngine.postpone(plan: plan)
        case .moveToNextFreeTime:
            let occupied = snapshot.plans
                .filter {
                    $0.id != command.planID && $0.status != .skipped
                }
                .map(\.span)
                + snapshot.calendarEvents.map(\.span)
            snapshot.plans[index] = try QuickActionEngine.moveToNextFreeTime(
                plan: plan,
                occupied: occupied,
                after: command.requestedAt
            )
        }
        snapshot.updatedAt = .now
        return snapshot
    }
}

struct TaptionWidgetPayload: Codable, Hashable, Sendable {
    var generatedAt: Date
    var sourceSnapshotUpdatedAt: Date?
    var sourceFingerprint: String?
    var viewportStart: Date
    var viewportEnd: Date
    var displayCenterDate: Date?
    var displayDuration: TimeInterval?
    var displayResolutionLabel: String?
    var items: [TaptionWidgetItem]
    var catStyle: String
    var hidesSensitiveContent: Bool
    var weatherSymbolName: String?
    var temperatureCelsius: Double?
    var reducesMotion: Bool?
    var locationTrackingEnabled: Bool? = nil

    static var empty: TaptionWidgetPayload {
        let calendar = Calendar.autoupdatingCurrent
        let day = calendar.startOfDay(for: .now)
        return TaptionWidgetPayload(
            generatedAt: .now,
            sourceSnapshotUpdatedAt: nil,
            sourceFingerprint: nil,
            viewportStart: day,
            viewportEnd: day.addingTimeInterval(86_400),
            displayCenterDate: .now,
            displayDuration: TaptionWidgetPlaybackEngine.defaultWindowDuration,
            displayResolutionLabel: TaptionWidgetPlaybackEngine.defaultResolutionLabel,
            items: [],
            catStyle: "calico",
            hidesSensitiveContent: true,
            weatherSymbolName: nil,
            temperatureCelsius: nil,
            reducesMotion: false
        )
    }

    static var placeholder: TaptionWidgetPayload {
        let calendar = Calendar.autoupdatingCurrent
        let day = calendar.startOfDay(for: .now)
        let now = Date.now
        return TaptionWidgetPayload(
            generatedAt: .now,
            sourceSnapshotUpdatedAt: nil,
            sourceFingerprint: nil,
            viewportStart: day,
            viewportEnd: day.addingTimeInterval(86_400),
            displayCenterDate: now,
            displayDuration: TaptionWidgetPlaybackEngine.defaultWindowDuration,
            displayResolutionLabel: TaptionWidgetPlaybackEngine.defaultResolutionLabel,
            items: [
                TaptionWidgetItem(
                    id: UUID(),
                    title: "팀 회의",
                    categoryID: "calendar",
                    startsAt: now.addingTimeInterval(-2.82 * 3_600),
                    endsAt: now.addingTimeInterval(-1.14 * 3_600),
                    status: "planned",
                    isFixed: true,
                    lane: .schedule
                ),
                TaptionWidgetItem(
                    id: UUID(),
                    title: "회사 · 10층",
                    categoryID: "location",
                    startsAt: now.addingTimeInterval(-2.5 * 3_600),
                    endsAt: now.addingTimeInterval(1.6 * 3_600),
                    status: "recorded",
                    isFixed: true,
                    lane: .location
                ),
                TaptionWidgetItem(
                    id: UUID(),
                    title: "자동차",
                    categoryID: "movement",
                    startsAt: now.addingTimeInterval(-0.8 * 3_600),
                    endsAt: now.addingTimeInterval(-0.25 * 3_600),
                    status: "recorded",
                    isFixed: true,
                    lane: .movement
                ),
                TaptionWidgetItem(
                    id: UUID(),
                    title: "수면",
                    categoryID: "sleep",
                    startsAt: now.addingTimeInterval(-4.8 * 3_600),
                    endsAt: now.addingTimeInterval(-1.2 * 3_600),
                    status: "recorded",
                    isFixed: true,
                    lane: .sleep
                ),
                TaptionWidgetItem(
                    id: UUID(),
                    title: "걷기",
                    categoryID: "exercise",
                    startsAt: now.addingTimeInterval(-0.2 * 3_600),
                    endsAt: now.addingTimeInterval(0.2 * 3_600),
                    status: "recorded",
                    isFixed: true,
                    lane: .activity
                ),
                TaptionWidgetItem(
                    id: UUID(),
                    title: "신제품 기획",
                    categoryID: "project",
                    startsAt: now.addingTimeInterval(-0.24 * 3_600),
                    endsAt: now.addingTimeInterval(1.98 * 3_600),
                    status: "running",
                    isFixed: false,
                    lane: .action
                ),
            ],
            catStyle: "calico",
            hidesSensitiveContent: false,
            weatherSymbolName: "cloud.sun",
            temperatureCelsius: 23,
            reducesMotion: false
        )
    }
}

enum TaptionLocationTrackingRequestStore {
    private static let key = "TaptionPlan.pendingLocationTrackingRequest"

    static func write(_ enabled: Bool) {
        UserDefaults(
            suiteName: TaptionWidgetSharedStore.appGroupIdentifier
        )?.set(enabled, forKey: key)
    }

    static func take() -> Bool? {
        guard let defaults = UserDefaults(
            suiteName: TaptionWidgetSharedStore.appGroupIdentifier
        ), defaults.object(forKey: key) != nil else {
            return nil
        }
        let value = defaults.bool(forKey: key)
        defaults.removeObject(forKey: key)
        return value
    }
}

enum TaptionWidgetSyncFingerprint {
    static func make(items: [TaptionWidgetItem]) -> String {
        let canonical = items
            .sorted {
                if $0.resolvedLane == $1.resolvedLane {
                    if $0.startsAt == $1.startsAt {
                        return $0.id.uuidString < $1.id.uuidString
                    }
                    return $0.startsAt < $1.startsAt
                }
                return $0.resolvedLane.rawValue < $1.resolvedLane.rawValue
            }
            .map { item in
                // Open HealthKit/Watch records use the render time as their
                // end.  Including that moving value made the app's freshly
                // rebuilt ground-truth fingerprint differ from the cached
                // payload every few seconds while an activity was running.
                // The source snapshot revision still detects a real save;
                // the fingerprint should describe the record, not the clock.
                let end = switch item.resolvedLane {
                case .sleep, .activity:
                    "open-ended"
                default:
                    String(Int64(item.endsAt.timeIntervalSince1970 * 1_000))
                }
                return [
                    item.id.uuidString,
                    item.resolvedLane.rawValue,
                    item.title,
                    item.categoryID,
                    String(Int64(item.startsAt.timeIntervalSince1970 * 1_000)),
                    end,
                    item.status,
                ].joined(separator: "|")
            }
            .joined(separator: "\n")

        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in canonical.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

enum TaptionWidgetPayloadSyncPolicy {
    static func freshest(
        groundTruth: TaptionWidgetPayload,
        cached: TaptionWidgetPayload
    ) -> TaptionWidgetPayload {
        switch selectionReason(groundTruth: groundTruth, cached: cached) {
        case .groundTruth:
            return groundTruth
        case .cached:
            return cached
        }
    }

    enum SelectionReason: String, Sendable {
        case groundTruth
        case cached
    }

    static func selectionReason(
        groundTruth: TaptionWidgetPayload,
        cached: TaptionWidgetPayload
    ) -> SelectionReason {
        // The app-group snapshot is the canonical source.  A cached payload
        // is allowed to win only when it was built from a strictly newer
        // snapshot (for example, a widget action was applied while the app
        // was suspended).  Comparing generatedAt alone was the old bug: a
        // stale cache could be newer simply because the widget rendered it.
        guard groundTruth.sourceFingerprint != nil else {
            return cached.sourceFingerprint == nil ? .groundTruth : .cached
        }
        guard cached.sourceFingerprint != nil else {
            return .groundTruth
        }
        if groundTruth.sourceFingerprint == cached.sourceFingerprint {
            if let groundTruthUpdatedAt = groundTruth.sourceSnapshotUpdatedAt,
               let cachedUpdatedAt = cached.sourceSnapshotUpdatedAt,
               cachedUpdatedAt != groundTruthUpdatedAt {
                return cachedUpdatedAt > groundTruthUpdatedAt
                    ? .cached
                    : .groundTruth
            }
            return cached.generatedAt >= groundTruth.generatedAt
                ? .cached
                : .groundTruth
        }
        guard let groundTruthUpdatedAt = groundTruth.sourceSnapshotUpdatedAt else {
            return .groundTruth
        }
        guard let cachedUpdatedAt = cached.sourceSnapshotUpdatedAt else {
            return .groundTruth
        }
        return cachedUpdatedAt > groundTruthUpdatedAt
            ? .cached
            : .groundTruth
    }
}

enum TaptionWidgetSyncStatus: Equatable, Sendable {
    case synchronized(Date?)
    case pending
    case unavailable

    var displayName: String {
        switch self {
        case .synchronized(let generatedAt):
            guard let generatedAt else { return "동기화됨" }
            let minutes = max(0, Int(Date.now.timeIntervalSince(generatedAt) / 60))
            return minutes < 1 ? "동기화됨 · 방금" : "동기화됨 · \(minutes)분 전"
        case .pending: return "동기화 대기"
        case .unavailable: return "앱을 열어 동기화"
        }
    }

    static func compare(
        groundTruth: TaptionWidgetPayload,
        cached: TaptionWidgetPayload
    ) -> Self {
        guard let fingerprint = groundTruth.sourceFingerprint else {
            return .unavailable
        }
        guard cached.sourceFingerprint == fingerprint else {
            return .pending
        }
        if let groundTruthUpdatedAt = groundTruth.sourceSnapshotUpdatedAt,
           let cachedUpdatedAt = cached.sourceSnapshotUpdatedAt,
           cachedUpdatedAt < groundTruthUpdatedAt {
            return .pending
        }
        return .synchronized(cached.generatedAt)
    }
}

enum TaptionWidgetSharedStore {
    static let appGroupIdentifier = "group.com.taption.plan"

    private static let logger = Logger(
        subsystem: "com.taption.plan",
        category: "WidgetSyncStore"
    )

    private static let payloadFileName = "widget-payload-v1.json"
    private static let commandsFileName = "widget-commands-v1.json"
    private static let snapshotFileName = "taption-data-v1.json"

    struct Diagnostics: Equatable, Sendable {
        var appGroupAvailable: Bool
        var snapshotExists: Bool
        var payloadExists: Bool
        var commandsExists: Bool
        var snapshotBytes: Int
        var payloadBytes: Int
        var commandsBytes: Int
        var snapshotUpdatedAt: Date?
        var payloadGeneratedAt: Date?
        var payloadSourceSnapshotUpdatedAt: Date?
        var groundTruthFingerprint: String?
        var payloadFingerprint: String?
        var groundTruthItemCount: Int
        var payloadItemCount: Int
        var snapshotReadError: String?
        var payloadReadError: String?

        var summary: String {
            let group = appGroupAvailable ? "App Group 정상" : "App Group 불가"
            let snapshot = snapshotExists
                ? "snapshot \(snapshotBytes)B"
                : "snapshot 없음"
            let payload = payloadExists
                ? "payload \(payloadBytes)B"
                : "payload 없음"
            let fingerprints = [
                shortFingerprint(groundTruthFingerprint),
                shortFingerprint(payloadFingerprint),
            ]
            .joined(separator: "/")
            return "\(group) · \(snapshot) · \(payload) · fp \(fingerprints)"
        }

        private func shortFingerprint(_ fingerprint: String?) -> String {
            guard let fingerprint, !fingerprint.isEmpty else { return "-" }
            return String(fingerprint.prefix(8))
        }
    }

    static func diagnostics(
        now: Date = .now
    ) -> Diagnostics {
        let snapshotURL = fileURL(snapshotFileName)
        let payloadURL = fileURL(payloadFileName)
        let commandsURL = fileURL(commandsFileName)
        let snapshotData = try? Data(contentsOf: snapshotURL)
        let payloadData = try? Data(contentsOf: payloadURL)
        let commandsData = try? Data(contentsOf: commandsURL)
        let snapshotResult = decodeSnapshot(snapshotData)
        let payloadResult = decodePayload(payloadData)
        let groundTruth = snapshotResult.value.map {
            TaptionWidgetPayloadFactory.make(from: $0, now: now)
        }
        let result = Diagnostics(
            appGroupAvailable: appGroupContainerURL() != nil,
            snapshotExists: FileManager.default.fileExists(
                atPath: snapshotURL.path
            ),
            payloadExists: FileManager.default.fileExists(
                atPath: payloadURL.path
            ),
            commandsExists: FileManager.default.fileExists(
                atPath: commandsURL.path
            ),
            snapshotBytes: snapshotData?.count ?? 0,
            payloadBytes: payloadData?.count ?? 0,
            commandsBytes: commandsData?.count ?? 0,
            snapshotUpdatedAt: snapshotResult.value?.updatedAt,
            payloadGeneratedAt: payloadResult.value?.generatedAt,
            payloadSourceSnapshotUpdatedAt:
                payloadResult.value?.sourceSnapshotUpdatedAt,
            groundTruthFingerprint: groundTruth?.sourceFingerprint,
            payloadFingerprint: payloadResult.value?.sourceFingerprint,
            groundTruthItemCount: groundTruth?.items.count ?? 0,
            payloadItemCount: payloadResult.value?.items.count ?? 0,
            snapshotReadError: snapshotResult.error,
            payloadReadError: payloadResult.error
        )
        let diagnosticMessage =
            "Widget diagnostics: group="
            + String(result.appGroupAvailable)
            + ", snapshot="
            + String(result.snapshotExists)
            + "/"
            + String(result.snapshotBytes)
            + "B, payload="
            + String(result.payloadExists)
            + "/"
            + String(result.payloadBytes)
            + "B, snapshotUpdated="
            + String(result.snapshotUpdatedAt?.timeIntervalSince1970 ?? 0)
            + ", payloadGenerated="
            + String(result.payloadGeneratedAt?.timeIntervalSince1970 ?? 0)
            + ", groundItems="
            + String(result.groundTruthItemCount)
            + ", payloadItems="
            + String(result.payloadItemCount)
            + ", groundFP="
            + (result.groundTruthFingerprint ?? "none")
            + ", payloadFP="
            + (result.payloadFingerprint ?? "none")
        logger.notice("\(diagnosticMessage, privacy: .public)")
        return result
    }

    static func readGroundTruthPayload(
        now: Date = .now
    ) -> TaptionWidgetPayload {
        guard let snapshot = readGroundTruthSnapshot() else {
            logger.error("Widget ground-truth snapshot unavailable; using cached payload")
            return readPayload()
        }
        let payload = TaptionWidgetPayloadFactory.make(
            from: snapshot,
            now: now
        )
        logger.debug(
            "Ground-truth payload built: updated=\(snapshot.updatedAt.timeIntervalSince1970, privacy: .public), items=\(payload.items.count, privacy: .public), fingerprint=\(payload.sourceFingerprint ?? "none", privacy: .public)"
        )
        return payload
    }

    static func readPayload() -> TaptionWidgetPayload {
        let data = try? Data(contentsOf: fileURL(payloadFileName))
        guard let payload = decodePayload(data).value else {
            logger.error("Widget cached payload unavailable")
            return .empty
        }
        logger.debug(
            "Cached widget payload read: generated=\(payload.generatedAt.timeIntervalSince1970, privacy: .public), items=\(payload.items.count, privacy: .public), fingerprint=\(payload.sourceFingerprint ?? "none", privacy: .public)"
        )
        return payload
    }

    static func writePayload(_ payload: TaptionWidgetPayload) throws {
        do {
            try write(encoder.encode(payload), to: fileURL(payloadFileName))
            logger.notice(
                "Widget payload written: generated=\(payload.generatedAt.timeIntervalSince1970, privacy: .public), sourceUpdated=\(payload.sourceSnapshotUpdatedAt?.timeIntervalSince1970 ?? 0, privacy: .public), items=\(payload.items.count, privacy: .public), fingerprint=\(payload.sourceFingerprint ?? "none", privacy: .public)"
            )
        } catch {
            logger.error(
                "Widget payload write failed: \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }

    static func appendCommand(_ command: TaptionWidgetCommand) throws {
        var commands = readCommands()
        commands.removeAll {
            $0.planID == command.planID
                && $0.kind == command.kind
                && command.requestedAt.timeIntervalSince($0.requestedAt) < 2
        }
        commands.append(command)
        try write(encoder.encode(commands), to: fileURL(commandsFileName))
    }

    static func takeCommands() throws -> [TaptionWidgetCommand] {
        let commands = readCommands()
        let url = fileURL(commandsFileName)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        return commands.sorted { $0.requestedAt < $1.requestedAt }
    }

    private static func readCommands() -> [TaptionWidgetCommand] {
        guard let data = try? Data(contentsOf: fileURL(commandsFileName)),
              let commands = try? decoder.decode(
                [TaptionWidgetCommand].self,
                from: data
              ) else {
            return []
        }
        return commands
    }

    private static func readGroundTruthSnapshot() -> TaptionDataSnapshot? {
        let data = try? Data(contentsOf: fileURL(snapshotFileName))
        let result = decodeSnapshot(data)
        guard let snapshot = result.value,
              snapshot.updatedAt != .distantPast else {
            logger.error(
                "Ground-truth snapshot read failed: bytes=\(data?.count ?? 0, privacy: .public), error=\(result.error ?? "empty", privacy: .public)"
            )
            return nil
        }
        logger.debug(
            "Ground-truth snapshot read: updated=\(snapshot.updatedAt.timeIntervalSince1970, privacy: .public), plans=\(snapshot.plans.count, privacy: .public), places=\(snapshot.places.count, privacy: .public), travel=\(snapshot.travel.count, privacy: .public)"
        )
        return snapshot
    }

    private static func decodeSnapshot(
        _ data: Data?
    ) -> (value: TaptionDataSnapshot?, error: String?) {
        guard let data else { return (nil, "missing") }
        do {
            let snapshot = try decoder.decode(
                TaptionDataSnapshot.self,
                from: TaptionSnapshotCompression.decode(data)
            )
            guard snapshot.updatedAt != .distantPast else {
                return (nil, "uninitialized")
            }
            return (snapshot, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    private static func decodePayload(
        _ data: Data?
    ) -> (value: TaptionWidgetPayload?, error: String?) {
        guard let data else { return (nil, "missing") }
        do {
            return (try decoder.decode(TaptionWidgetPayload.self, from: data), nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    private static func appGroupContainerURL() -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        )
    }

    static func fileURLForDiagnostics(_ name: String) -> URL {
        fileURL(name)
    }

    private static func fileURL(_ name: String) -> URL {
        let fileManager = FileManager.default
        if let container = appGroupContainerURL() {
            return container.appendingPathComponent(name)
        }
        let fallback = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return fallback
            .appendingPathComponent("TaptionPlanWidget", isDirectory: true)
            .appendingPathComponent(name)
    }

    private static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(
            to: url,
            options: [
                .atomic,
                .completeFileProtectionUntilFirstUserAuthentication,
            ]
        )
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
