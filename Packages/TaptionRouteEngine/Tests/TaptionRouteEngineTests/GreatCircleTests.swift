import Foundation
import Testing
@testable import TaptionRouteEngine

struct GreatCircleTests {
    private let incheon = RouteCoordinate(latitude: 37.4602, longitude: 126.4407)
    private let losAngeles = RouteCoordinate(latitude: 33.9416, longitude: -118.4085)
    private let bangkok = RouteCoordinate(latitude: 13.69, longitude: 100.7501)

    @Test func distanceMatchesKnownRoutes() {
        #expect(abs(GreatCircle.distanceKm(from: incheon, to: losAngeles) - 9_620) < 60)
        #expect(abs(GreatCircle.distanceKm(from: incheon, to: bangkok) - 3_660) < 60)
        #expect(GreatCircle.distanceKm(from: incheon, to: incheon) == 0)
    }

    @Test func pointsKeepEndsAndEqualSpacing() {
        let points = GreatCircle.points(from: incheon, to: losAngeles, segments: 32)
        #expect(points.count == 33)
        #expect(points.first == incheon)
        #expect(points.last == losAngeles)
        let step = GreatCircle.distanceKm(from: incheon, to: losAngeles) / 32
        for (a, b) in zip(points, points.dropFirst()) {
            #expect(abs(GreatCircle.distanceKm(from: a, to: b) - step) < 0.001)
        }
    }

    @Test func pacificRouteBulgesNorth() throws {
        // 인천–LA 대권은 두 공항보다 북쪽(알류샨 쪽)으로 올라간다.
        let top = try #require(GreatCircle.points(from: incheon, to: losAngeles).map(\.latitude).max())
        #expect(top > 45 && top < 55)
    }

    @Test func equatorAndMeridianStayStraight() {
        let equator = GreatCircle.points(from: RouteCoordinate(latitude: 0, longitude: 10), to: RouteCoordinate(latitude: 0, longitude: 50), segments: 4)
        #expect(equator.map { ($0.longitude * 1_000).rounded() / 1_000 } == [10, 20, 30, 40, 50])
        #expect(equator.allSatisfy { abs($0.latitude) < 1e-9 })
        let meridian = GreatCircle.points(from: RouteCoordinate(latitude: 10, longitude: 30), to: RouteCoordinate(latitude: 50, longitude: 30), segments: 4)
        #expect(meridian.map { ($0.latitude * 1_000).rounded() / 1_000 } == [10, 20, 30, 40, 50])
    }

    @Test func splitsAtTheAntimeridian() {
        let parts = GreatCircle.splitAtAntimeridian(GreatCircle.points(from: incheon, to: losAngeles))
        #expect(parts.count == 2)
        #expect(parts.first?.last?.longitude == 180)
        #expect(parts.last?.first?.longitude == -180)
        #expect(parts.first?.last?.latitude == parts.last?.first?.latitude)
        #expect(parts.allSatisfy { part in zip(part, part.dropFirst()).allSatisfy { abs($0.longitude - $1.longitude) < 180 } })
        // 반대 방향도 같다.
        let back = GreatCircle.splitAtAntimeridian(GreatCircle.points(from: losAngeles, to: incheon))
        #expect(back.first?.last?.longitude == -180)
        #expect(back.last?.first?.longitude == 180)
        // 넘지 않는 길은 그대로 한 줄이다.
        #expect(GreatCircle.splitAtAntimeridian(GreatCircle.points(from: incheon, to: bangkok)).count == 1)
        #expect(GreatCircle.splitAtAntimeridian([]).isEmpty)
    }

    @Test func degenerateInputs() {
        #expect(GreatCircle.points(from: incheon, to: incheon) == [incheon, incheon])
        let antipode = RouteCoordinate(latitude: -incheon.latitude, longitude: incheon.longitude - 180)
        #expect(GreatCircle.points(from: incheon, to: antipode).count == 2)
        #expect(GreatCircle.points(from: RouteCoordinate(latitude: 91, longitude: 0), to: incheon).isEmpty)
        #expect(GreatCircle.points(from: RouteCoordinate(latitude: .nan, longitude: 0), to: incheon).isEmpty)
        #expect(GreatCircle.points(from: incheon, to: bangkok, segments: 0).isEmpty)
    }
}
