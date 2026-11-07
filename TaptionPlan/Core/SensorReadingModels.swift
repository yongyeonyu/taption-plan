import Foundation
import TaptionPlanCore

struct HealthActual: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var kind: String
    var span: TimeSpan
    var duration: TimeInterval
    var distanceMeters: Double?
    var energyKilocalories: Double?
    var sourceName: String
    var linkedPlanID: UUID? = nil
    var linkedTitle: String? = nil
    var linkedCategoryID: String? = nil
}

// `GeoPoint`는 `TaptionPlanCore/Domain/GeoPoint.swift`에 있다.

// `DevicePowerState`·`LocationFixQuality`·`SensorReading`은 `TaptionPlanCore/Domain/SensorReading.swift`에 있다.
