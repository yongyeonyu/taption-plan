import Foundation
import TaptionPlanCore

enum PermissionFeature: String, Codable, CaseIterable, Sendable {
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

enum PermissionState: String, Codable, CaseIterable, Sendable {
    case notDetermined
    case denied
    case limited
    case authorized
    case unavailable
}

enum RequiredPermission: String, CaseIterable, Equatable, Sendable {
    case locationAlways
    case locationPrecise
    case motion
    case healthKitRequestCompleted
    case calendar
    case notifications
    case liveActivities
}

struct RequiredPermissionSnapshot: Equatable, Sendable {
    var permissions: [PermissionFeature: PermissionState]
    var locationAlwaysAuthorized: Bool
    var locationPrecise: Bool
    var healthKitRequestCompleted: Bool
    var liveActivitiesEnabled: Bool

    init(
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

struct RequiredPermissionGate: Equatable, Sendable {
    static let sensorCollectionRequirements: [RequiredPermission] = [
        .locationAlways,
        .locationPrecise,
        .motion,
    ]

    let missing: [RequiredPermission]

    var allSatisfied: Bool { missing.isEmpty }

    var sensorCollectionMissing: [RequiredPermission] {
        missing.filter(Self.sensorCollectionRequirements.contains)
    }

    var sensorCollectionReady: Bool {
        sensorCollectionMissing.isEmpty
    }

    init(snapshot: RequiredPermissionSnapshot) {
        missing = RequiredPermission.allCases.filter {
            !Self.isSatisfied($0, in: snapshot)
        }
    }

    static func evaluate(
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
