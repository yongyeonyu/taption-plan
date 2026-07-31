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

    init(
        id: UUID,
        title: String,
        categoryID: String,
        startsAt: Date,
        endsAt: Date,
        status: String,
        isFixed: Bool,
        categoryName: String? = nil,
        categoryHex: String? = nil
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
    }

    var isRunning: Bool {
        status == "running"
    }

    var isCompleted: Bool {
        status == "completed"
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
                    title: "회의",
                    categoryID: "project",
                    startsAt: now.addingTimeInterval(-2.82 * 3_600),
                    endsAt: now.addingTimeInterval(-1.14 * 3_600),
                    status: "planned",
                    isFixed: true
                ),
                TaptionWidgetItem(
                    id: UUID(),
                    title: "러닝",
                    categoryID: "exercise",
                    startsAt: now.addingTimeInterval(-0.24 * 3_600),
                    endsAt: now.addingTimeInterval(1.98 * 3_600),
                    status: "running",
                    isFixed: false
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
