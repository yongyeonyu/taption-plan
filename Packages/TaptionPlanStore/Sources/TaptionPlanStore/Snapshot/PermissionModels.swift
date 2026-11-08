import Foundation
import TaptionPlanCore

public enum PermissionFeature: String, Codable, CaseIterable, Sendable {
    case photos
    case calendar
    case health
    case location
    case motion
    case weather
    case microphone
    case notifications
    case cloud
    case appUsage
}

public enum PermissionState: String, Codable, CaseIterable, Sendable {
    case notDetermined
    case denied
    case limited
    case authorized
    case unavailable
}

public enum RequiredPermission: String, CaseIterable, Equatable, Sendable {
    case locationAlways
    case locationPrecise
    case motion
    case healthKitRequestCompleted
    case calendar
    case notifications
    case liveActivities
}

public struct RequiredPermissionSnapshot: Equatable, Sendable {
    public var permissions: [PermissionFeature: PermissionState]
    public var locationAlwaysAuthorized: Bool
    public var locationPrecise: Bool
    public var healthKitRequestCompleted: Bool
    public var liveActivitiesEnabled: Bool

    public init(
        permissions: [PermissionFeature: PermissionState] = [:],
        locationAlwaysAuthorized: Bool = false,
        locationPrecise: Bool = false,
        healthKitRequestCompleted: Bool = false,
        liveActivitiesEnabled: Bool = false
    ) {
        self.permissions = permissions
        self.locationAlwaysAuthorized = locationAlwaysAuthorized
        self.locationPrecise = locationPrecise
        self.healthKitRequestCompleted = healthKitRequestCompleted
        self.liveActivitiesEnabled = liveActivitiesEnabled
    }
}

public struct RequiredPermissionGate: Equatable, Sendable {
    public static let sensorCollectionRequirements: [RequiredPermission] = [
        .locationAlways,
        .locationPrecise,
        .motion,
    ]

    public let missing: [RequiredPermission]

    public var allSatisfied: Bool { missing.isEmpty }

    public var sensorCollectionMissing: [RequiredPermission] {
        missing.filter(Self.sensorCollectionRequirements.contains)
    }

    public var sensorCollectionReady: Bool {
        sensorCollectionMissing.isEmpty
    }

    public init(snapshot: RequiredPermissionSnapshot) {
        missing = RequiredPermission.allCases.filter {
            !Self.isSatisfied($0, in: snapshot)
        }
    }

    public static func evaluate(
        _ snapshot: RequiredPermissionSnapshot
    ) -> RequiredPermissionGate {
        RequiredPermissionGate(snapshot: snapshot)
    }

    private static func isSatisfied(
        _ requirement: RequiredPermission,
        in snapshot: RequiredPermissionSnapshot
    ) -> Bool {
        let state: (PermissionFeature) -> PermissionState = {
            snapshot.permissions[$0] ?? .notDetermined
        }
        return switch requirement {
        case .locationAlways:
            state(.location) == .authorized
                && snapshot.locationAlwaysAuthorized
        case .locationPrecise:
            state(.location) == .authorized
                && snapshot.locationPrecise
        case .motion:
            state(.motion) == .authorized
        case .healthKitRequestCompleted:
            snapshot.healthKitRequestCompleted
        case .calendar:
            state(.calendar) == .authorized
        case .notifications:
            state(.notifications) == .authorized
        case .liveActivities:
            snapshot.liveActivitiesEnabled
        }
    }
}
