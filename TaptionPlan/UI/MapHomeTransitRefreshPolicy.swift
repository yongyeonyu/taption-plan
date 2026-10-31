import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

struct MapHomeTransitBoardingCandidateCacheKey: Equatable {
    let dayProjectionRevision: UInt64
    let settingsHash: Int
    let readingsRevision: UInt64
    let nearbyPlacesRevision: UInt64
    let cutoff: Date
}

enum MapHomeTransitBoardingRefreshPolicy {
    static let interval: TimeInterval = 30

    static func shouldRefresh(lastRefresh: Date?, at date: Date) -> Bool {
        guard let lastRefresh else { return true }
        return date < lastRefresh
            || date.timeIntervalSince(lastRefresh) >= interval
    }

    static func cutoffBucket(_ date: Date) -> Date {
        Date(
            timeIntervalSinceReferenceDate: floor(
                date.timeIntervalSinceReferenceDate / interval
            ) * interval
        )
    }
}

enum MapHomeTransitPOIRefreshPolicy {
    static func canStart(
        isBootstrapped: Bool,
        isSceneActive: Bool
    ) -> Bool {
        isBootstrapped && isSceneActive
    }
}
