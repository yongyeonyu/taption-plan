import CoreLocation
import CoreMotion
import Foundation
import HealthKit
import Synchronization

// 센서 수집의 발열·배터리 정책(PRF1101A01). `AppleIntegrations.swift`(동결 예산)에서 옮겨 왔다.

enum HealthRefreshPolicy {
    static let broadRawSyncInterval: TimeInterval = 15 * 60
    static let foregroundInterval = broadRawSyncInterval
    static let periodicLookback: TimeInterval = 2 * 86_400
    static let backgroundFrequency: HKUpdateFrequency = .immediate
    /// 심박·걸음은 표본이 잦아 `.immediate`면 앱이 계속 깨어 발열·배터리를 쓴다. 한 시간 묶음으로 받는다(PRF1101A01).
    static let hourlyTypeIdentifiers: Set<String> = [
        HKQuantityTypeIdentifier.heartRate.rawValue,
        HKQuantityTypeIdentifier.stepCount.rawValue,
    ]

    static func backgroundFrequency(for identifier: String) -> HKUpdateFrequency {
        hourlyTypeIdentifiers.contains(identifier) ? .hourly : backgroundFrequency
    }
    static let backgroundObservedTypeIdentifiers: Set<String> = [
        HKObjectType.workoutType().identifier,
        HKCategoryTypeIdentifier.sleepAnalysis.rawValue,
        HKQuantityTypeIdentifier.heartRate.rawValue,
        HKQuantityTypeIdentifier.stepCount.rawValue,
    ]
}

enum ForegroundLiveLocationPolicy {
    static let distanceFilterMeters: CLLocationDistance = 5
    /// 앱이 앞에 있어도 멈춰 있으면 GPS를 Best·5m로 붙잡지 않는다(발열·배터리, PRF1101A01).
    static let stationaryDistanceFilterMeters: CLLocationDistance = 15
    static let movingSpeedMetersPerSecond: CLLocationSpeed = 1

    static func isStationary(motionIsStationary: Bool, speed: CLLocationSpeed?) -> Bool {
        motionIsStationary && (speed ?? 0) < movingSpeedMetersPerSecond
    }

    static func accuracy(stationary: Bool) -> (desired: CLLocationAccuracy, distanceFilter: CLLocationDistance) {
        stationary
            ? (kCLLocationAccuracyNearestTenMeters, stationaryDistanceFilterMeters)
            : (kCLLocationAccuracyBest, distanceFilterMeters)
    }
    static let minimumEmissionInterval: TimeInterval = 0.5

    static func shouldTrack(
        sceneIsActive: Bool,
        locationCollectionEnabled: Bool,
        hasLocationPermission: Bool
    ) -> Bool {
        sceneIsActive && locationCollectionEnabled && hasLocationPermission
    }

    static func isNewFix(_ timestamp: Date, after previous: Date?) -> Bool {
        previous.map { timestamp > $0 } ?? true
    }
}

/// 모션 표본을 센서 큐 안에서 모았다가 간격마다 한 번에 넘긴다(PRF1101A01). 그 큐에서만 쓴다.
final class DeviceMotionBatch: Sendable {
    typealias Sample = (snapshot: DeviceMotionSnapshot, receivedAt: Date)
    static let flushInterval: TimeInterval = 1

    private let flushInterval: TimeInterval
    private let state = Mutex<(samples: [Sample], lastFlush: Date?)>(([], nil))

    init(flushInterval: TimeInterval) {
        self.flushInterval = flushInterval
    }

    /// 넘길 때가 되면 모은 표본을 돌려주고 비운다. 첫 표본은 바로 넘긴다.
    func append(_ snapshot: DeviceMotionSnapshot, at date: Date) -> [Sample]? {
        state.withLock { state in
            state.samples.append((snapshot, date))
            if let lastFlush = state.lastFlush, date.timeIntervalSince(lastFlush) < flushInterval { return nil }
            state.lastFlush = date
            defer { state.samples.removeAll(keepingCapacity: true) }
            return state.samples
        }
    }
}
