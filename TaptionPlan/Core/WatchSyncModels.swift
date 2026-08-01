import Foundation

enum TaptionWatchCommandKind: String, Codable, CaseIterable, Sendable {
    case start
    case complete
    case postponeThirtyMinutes
    case skip
    case stopCurrentActivity
}

struct TaptionWatchCommand: Codable, Hashable, Sendable {
    var id: UUID
    var planID: UUID
    var kind: TaptionWatchCommandKind
    var requestedAt: Date

    init(
        id: UUID = UUID(),
        planID: UUID,
        kind: TaptionWatchCommandKind,
        requestedAt: Date = .now
    ) {
        self.id = id
        self.planID = planID
        self.kind = kind
        self.requestedAt = requestedAt
    }
}

enum TaptionWatchWorkoutKind: String, Codable, CaseIterable, Sendable {
    case walking
    case running
    case cycling

    var title: String {
        switch self {
        case .walking: "걷기"
        case .running: "달리기"
        case .cycling: "자전거"
        }
    }

    var symbolName: String {
        switch self {
        case .walking: "figure.walk"
        case .running: "figure.run"
        case .cycling: "bicycle"
        }
    }
}

enum TaptionWatchWorkoutRequestAction: String, Codable, Sendable {
    case start
    case stop
}

struct TaptionWatchWorkoutRequest: Codable, Hashable, Sendable {
    var id: UUID
    var sessionID: UUID
    var action: TaptionWatchWorkoutRequestAction
    var kind: TaptionWatchWorkoutKind
    var linkedPlanID: UUID?
    var requestedAt: Date

    init(
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

struct TaptionWatchPlanItem: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var categoryID: String
    var startsAt: Date
    var endsAt: Date
    var status: String
    var actualStartedAt: Date?
    var categoryName: String?
    var categoryHex: String?
    /// Goals and their child plans are both sent to the Watch.  Keeping this
    /// bit on the item lets the Watch distinguish the two without having to
    /// re-read the phone's plan hierarchy.
    var isGoal: Bool = false
    var parentID: UUID? = nil

    private enum CodingKeys: String, CodingKey {
        case id, title, categoryID, startsAt, endsAt, status
        case actualStartedAt, categoryName, categoryHex, isGoal, parentID
    }

    init(
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
    init(from decoder: Decoder) throws {
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
enum TaptionWatchLiveItemPolicy {
    static func isLive(_ item: TaptionWatchPlanItem, at date: Date) -> Bool {
        guard item.endsAt > date else { return false }
        return item.status == "planned" || item.status == "running"
    }

    static func current(
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

    static func upcoming(
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

struct TaptionWatchDaySummary: Codable, Hashable, Sendable {
    var date: Date
    var scheduledCount: Int
    var completedCount: Int
    var recordedMinutes: Int
    var activeMinutes: Int
}

struct TaptionWatchPayload: Codable, Hashable, Sendable {
    var generatedAt: Date
    var viewportStart: Date
    var viewportEnd: Date
    var items: [TaptionWatchPlanItem]
    var catStyle: String
    var reducesMotion: Bool
    var todaySummary: TaptionWatchDaySummary? = nil
}

struct TaptionWatchSensorVector3: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
    var z: Double
}

struct TaptionWatchLocationPoint: Codable, Hashable, Sendable {
    var id: UUID
    var capturedAt: Date
    var latitude: Double
    var longitude: Double
    var altitude: Double
    var horizontalAccuracy: Double
    var verticalAccuracy: Double
    var speedMetersPerSecond: Double?
    var courseDegrees: Double?
}

/// A cumulative, battery-conscious summary of the sensors collected during an
/// explicit Apple Watch workout. The Watch samples motion locally and sends a
/// summary periodically instead of streaming every high-frequency event.
struct TaptionWatchSensorSummary: Identifiable, Codable, Hashable, Sendable {
    var id: UUID { sessionID }
    var sessionID: UUID
    var sequence: Int
    var workoutKind: TaptionWatchWorkoutKind
    var linkedPlanID: UUID?
    var linkedPlanTitle: String?
    var linkedCategoryID: String?
    var startedAt: Date
    var endedAt: Date
    var isFinal: Bool

    var accelerometerSampleCount: Int
    var accelerometerAverageG: TaptionWatchSensorVector3?
    var peakAccelerationG: Double?
    var gyroscopeSampleCount: Int
    var gyroscopeAverageRadiansPerSecond: TaptionWatchSensorVector3?
    var peakRotationRateRadiansPerSecond: Double?
    var gravity: TaptionWatchSensorVector3?
    var userAccelerationG: TaptionWatchSensorVector3?
    var rotationRateRadiansPerSecond: TaptionWatchSensorVector3?
    var attitudeRadians: TaptionWatchSensorVector3?

    var relativeAltitudeMeters: Double?
    var pressureKilopascals: Double?
    var stepCount: Int?
    var distanceMeters: Double?
    var floorsAscended: Int?
    var floorsDescended: Int?

    var latestHeartRate: Double?
    var averageHeartRate: Double?
    var maximumHeartRate: Double?
    var activeEnergyKilocalories: Double?
    var routePoints: [TaptionWatchLocationPoint]?
}

enum TaptionWatchEnvelope {
    static let payloadKey = "taption.watch.payload"
    static let commandKey = "taption.watch.command"
    static let sensorSummaryKey = "taption.watch.sensor-summary"
    static let workoutRequestKey = "taption.watch.workout-request"
    static let refreshRequestKey = "taption.watch.refresh-request"
    static let acceptedKey = "taption.watch.accepted"
}

enum TaptionWatchHealthMetadata {
    static let planID = "com.taption.plan.planID"
    static let planTitle = "com.taption.plan.planTitle"
    static let categoryID = "com.taption.plan.categoryID"
    static let sensorSessionID = "com.taption.plan.sensorSessionID"
}
