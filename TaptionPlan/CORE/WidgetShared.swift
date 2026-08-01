import ActivityKit
import Foundation

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
    case activity
    case action

    static let automatic: [Self] = [
        .schedule,
        .location,
        .movement,
        .activity,
    ]

    var title: String {
        switch self {
        case .schedule: "일정"
        case .location: "위치"
        case .movement: "이동"
        case .activity: "활동"
        case .action: "액션"
        }
    }

    var systemImage: String {
        switch self {
        case .schedule: "calendar"
        case .location: "mappin.and.ellipse"
        case .movement: "arrow.trianglehead.swap"
        case .activity: "figure.run"
        case .action: "checklist.checked"
        }
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
        case "activity": .activity
        default: .action
        }
    }
}

enum TaptionWidgetPlaybackEngine {
    static let defaultWindowDuration: TimeInterval = 6 * 3_600

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
        max(0, contentHeight - viewportHeight)
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
        }
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
}

enum TaptionWidgetCatWalkEngine {
    static let defaultStepDuration: TimeInterval = 0.5
    static let movementStepCount = 20
    static let stepCount = 40
    static let roundTripDuration =
        defaultStepDuration * Double(movementStepCount)
    static let sequenceDuration = defaultStepDuration * Double(stepCount)

    static func pose(
        at date: Date,
        stepDuration: TimeInterval = defaultStepDuration,
        preferredAction: TaptionWidgetCatAction? = nil
    ) -> TaptionWidgetCatWalkPose {
        let duration = max(0.5, stepDuration)
        let rawStep = Int(date.timeIntervalSinceReferenceDate / duration)
        let step = ((rawStep % stepCount) + stepCount) % stepCount
        let cycle = Int(
            floor(Double(rawStep) / Double(stepCount))
        )
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
        default:
            progress = 0
            facesLeft = false
            isAtEndpoint = true
            action = restAction(
                preferred: preferredAction,
                cycle: cycle,
                slot: (step - movementStepCount) / 4
            )
        }
        let motion = motionDetails(for: action, phase: step % 4)
        return TaptionWidgetCatWalkPose(
            progress: min(1, max(0, progress)),
            facesLeft: facesLeft,
            legPhase: step % 4,
            isAtEndpoint: isAtEndpoint,
            action: action,
            tailSwing: motion.tailSwing,
            headTiltDegrees: motion.headTiltDegrees
        )
    }

    static func motionDetails(
        for action: TaptionWidgetCatAction,
        phase: Int
    ) -> (tailSwing: Double, headTiltDegrees: Double) {
        let tail = [-1.0, -0.35, 0.45, 1.0][phase]
        let head = [-4.0, 1.5, 4.0, -1.5][phase]
        return switch action {
        case .walking:
            (tail, head)
        case .running:
            (-tail, head * 1.45)
        case .sitting:
            (tail * 0.55, head * 1.25)
        case .grooming:
            (tail * 0.38, [-11.0, -5.0, 6.0, -4.0][phase])
        case .startled:
            (1, -7)
        case .sleeping:
            (tail * 0.16, 7)
        case .eating:
            (tail * 0.28, 12)
        case .ballPlay:
            (-tail * 0.85, head * 1.6)
        case .fishingPlay:
            (tail * 0.72, [-8.0, 7.0, -4.0, 9.0][phase])
        }
    }

    private static func restAction(
        preferred: TaptionWidgetCatAction?,
        cycle: Int,
        slot: Int
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
        ]
        let seed = abs((cycle &* 31) &+ (slot &* 17))
        return actions[seed % actions.count]
    }
}

enum TaptionWidgetCatPreviewEngine {
    static let stepDuration: TimeInterval = 0.2
    static let movementStepCount = 20

    static func pose(
        at date: Date,
        action: TaptionWidgetCatAction,
        reducesMotion: Bool = false
    ) -> TaptionWidgetCatWalkPose {
        let rawStep = Int(
            floor(date.timeIntervalSinceReferenceDate / stepDuration)
        )
        let step = ((rawStep % movementStepCount) + movementStepCount)
            % movementStepCount
        let phase = reducesMotion ? 0 : step % 4
        let motion = TaptionWidgetCatWalkEngine.motionDetails(
            for: action,
            phase: phase
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
                    : motion.headTiltDegrees
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
            headTiltDegrees: motion.headTiltDegrees
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
    var viewportStart: Date
    var viewportEnd: Date
    var items: [TaptionWidgetItem]
    var catStyle: String
    var hidesSensitiveContent: Bool
    var weatherSymbolName: String?
    var temperatureCelsius: Double?
    var reducesMotion: Bool?

    static var empty: TaptionWidgetPayload {
        let calendar = Calendar.autoupdatingCurrent
        let day = calendar.startOfDay(for: .now)
        return TaptionWidgetPayload(
            generatedAt: .now,
            viewportStart: day,
            viewportEnd: day.addingTimeInterval(86_400),
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
            viewportStart: day,
            viewportEnd: day.addingTimeInterval(86_400),
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
                    title: "자가용",
                    categoryID: "movement",
                    startsAt: now.addingTimeInterval(-0.8 * 3_600),
                    endsAt: now.addingTimeInterval(-0.25 * 3_600),
                    status: "recorded",
                    isFixed: true,
                    lane: .movement
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

enum TaptionWidgetSharedStore {
    static let appGroupIdentifier = "group.com.taption.plan"

    private static let payloadFileName = "widget-payload-v1.json"
    private static let commandsFileName = "widget-commands-v1.json"

    static func readPayload() -> TaptionWidgetPayload {
        guard let data = try? Data(contentsOf: fileURL(payloadFileName)),
              let payload = try? decoder.decode(TaptionWidgetPayload.self, from: data) else {
            return .empty
        }
        return payload
    }

    static func writePayload(_ payload: TaptionWidgetPayload) throws {
        try write(encoder.encode(payload), to: fileURL(payloadFileName))
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

    private static func fileURL(_ name: String) -> URL {
        let fileManager = FileManager.default
        if let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) {
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
