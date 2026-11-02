import Testing
@testable import TaptionRouteEngine

struct RouteGapKindTests {
    @Test func vehicleKeptWithPlausibleSpeedIsSparse() {
        #expect(RouteGapKind.classify(duration: 120, distanceMeters: 1_500, before: .automotive, after: .automotive) == .sparse)
        #expect(RouteGapKind.classify(duration: 180, distanceMeters: 800, before: .automotive, after: .bus, inside: [.unknown, .automotive]) == .sparse)
    }

    @Test func longOrImplausibleGapIsMissing() {
        #expect(RouteGapKind.classify(duration: 181, distanceMeters: 1_500, before: .automotive, after: .automotive) == .missing)
        #expect(RouteGapKind.classify(duration: 120, distanceMeters: 20_000, before: .automotive, after: .automotive) == .missing)
        #expect(RouteGapKind.classify(duration: 120, distanceMeters: 50, before: .automotive, after: .automotive) == .missing)
    }

    @Test func leavingTheVehicleIsMissing() {
        #expect(RouteGapKind.classify(duration: 120, distanceMeters: 1_500, before: .automotive, after: .walking) == .missing)
        #expect(RouteGapKind.classify(duration: 120, distanceMeters: 1_500, before: .unknown, after: .automotive) == .missing)
        #expect(RouteGapKind.classify(duration: 120, distanceMeters: 1_500, before: .automotive, after: .automotive, inside: [.walking]) == .missing)
    }
}
