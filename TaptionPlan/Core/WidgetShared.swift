import ActivityKit
import Foundation
import OSLog
import SwiftUI
import TaptionPlanCore

enum TaptionWidgetKind {
    static let schedule = "TaptionScheduleWidget"
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

    var localizedTitle: String {
        switch self {
        case .schedule:
            AppLanguagePreference.text(korean: "일정", english: "Schedule")
        case .location:
            AppLanguagePreference.text(korean: "위치", english: "Location")
        case .movement:
            AppLanguagePreference.text(korean: "이동", english: "Movement")
        case .sleep:
            AppLanguagePreference.text(korean: "수면", english: "Sleep")
        case .activity:
            AppLanguagePreference.text(korean: "활동", english: "Activity")
        case .appUsage:
            AppLanguagePreference.text(korean: "어플", english: "Apps")
        case .action:
            AppLanguagePreference.text(korean: "액션", english: "Actions")
        }
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
    static var defaultResolutionLabel: String { AppLanguagePreference.text("6시간", "6h") }

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
    var locationPermissionState: String? = nil

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
