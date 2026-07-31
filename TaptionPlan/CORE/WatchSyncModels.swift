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
}

struct TaptionWatchPayload: Codable, Hashable, Sendable {
    var generatedAt: Date
    var viewportStart: Date
    var viewportEnd: Date
    var items: [TaptionWatchPlanItem]
    var catStyle: String
    var reducesMotion: Bool
}

struct TaptionWatchSensorVector3: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
    var z: Double
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
}

enum TaptionWatchEnvelope {
    static let payloadKey = "taption.watch.payload"
    static let commandKey = "taption.watch.command"
    static let sensorSummaryKey = "taption.watch.sensor-summary"
    static let acceptedKey = "taption.watch.accepted"
}

enum TaptionWatchHealthMetadata {
    static let planID = "com.taption.plan.planID"
    static let planTitle = "com.taption.plan.planTitle"
    static let categoryID = "com.taption.plan.categoryID"
    static let sensorSessionID = "com.taption.plan.sensorSessionID"
}
