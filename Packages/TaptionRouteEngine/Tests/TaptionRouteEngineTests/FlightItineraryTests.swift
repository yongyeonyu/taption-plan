import Foundation
import Testing
@testable import TaptionRouteEngine

struct FlightItineraryTests {
    private func t(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> FlightLocalTime {
        FlightLocalTime(year: y, month: mo, day: d, hour: h, minute: mi)
    }

    /// ICN 09:05 → BKK 12:35(비행 330분) → DAD 15:10 출발(환승 155분).
    private func bangkokRoute() -> FlightItinerary {
        let first = FlightLeg(flight: "AB123", airline: "AB", origin: "ICN", destination: "BKK", departure: t(2027, 3, 7, 9, 5), durationMinutes: 330, terminal: "2", source: "publicData")
        let second = FlightLeg(flight: "CD456", airline: "CD", origin: "BKK", destination: "DAD", departure: t(2027, 3, 7, 15, 10), durationMinutes: 110, terminal: "2", source: "message")
        return FlightItinerary(legs: [first, second])
    }

    @Test func legComputesArrivalDayOffsetAndUTCOffsets() throws {
        let leg = bangkokRoute().legs[0]
        #expect(leg.resolvedArrival == t(2027, 3, 7, 12, 35))
        #expect(leg.arrivalDayOffset == 0)
        #expect(leg.resolvedDurationMinutes == 330)
        #expect(leg.departureOffsetSeconds == 9 * 3600)
        #expect(leg.arrivalOffsetSeconds == 7 * 3600)
        #expect(leg.isDomestic == false)
    }

    @Test func givenArrivalWinsOverComputedAndDurationIsDerived() throws {
        let leg = FlightLeg(origin: "ICN", destination: "LAX", departure: t(2026, 12, 1, 19), arrival: t(2026, 12, 1, 14))
        #expect(leg.resolvedDurationMinutes == 720)
        #expect(leg.arrivalDayOffset == 0)
        #expect(leg.arrivalInstant == leg.departureInstant?.addingTimeInterval(720 * 60))
    }

    @Test func overnightFlightCrossesMidnight() throws {
        let leg = FlightLeg(origin: "ICN", destination: "CDG", departure: t(2027, 5, 1, 23, 30), durationMinutes: 840)
        let arrival = try #require(leg.resolvedArrival)
        #expect(arrival.day == 2)
        #expect(leg.arrivalDayOffset == 1)
    }

    @Test func missingTimesOrUnknownAirportsGiveNil() {
        #expect(FlightLeg(origin: "ICN", destination: "BKK").arrivalInstant == nil)
        #expect(FlightLeg(origin: "ICN", destination: "BKK", departure: t(2027, 3, 7, 9)).resolvedArrival == nil)
        let unknown = FlightLeg(origin: "ICN", destination: "ZZZ", departure: t(2027, 3, 7, 9), durationMinutes: 300)
        #expect(unknown.arrivalInstant == nil && unknown.arrivalOffsetSeconds == nil && unknown.isDomestic == nil)
        // 서머타임으로 없는 시각
        let gap = FlightLeg(origin: "LAX", destination: "SFO", departure: t(2027, 3, 14, 2, 30), durationMinutes: 80)
        #expect(gap.departureInstant == nil)
    }

    @Test func layoverBetweenLegsUsesLocalTimeZones() throws {
        let layover = try #require(bangkokRoute().layovers.first)
        #expect(layover.airport == "BKK")
        #expect(layover.scheduledMinutes == 155)
        #expect(layover.currentMinutes == 155)
        #expect(layover.minimumMinutes == FlightConnectionRules.sameTerminalMinutes)
        #expect(!layover.isTight && layover.lostMinutes == 0)
    }

    @Test func differentOrUnknownTerminalNeedsNinetyMinutes() throws {
        var route = bangkokRoute()
        route.legs[1].terminal = "1"
        #expect(try #require(route.layovers.first).minimumMinutes == 90)
        route.legs[1].terminal = nil
        #expect(try #require(route.layovers.first).minimumMinutes == 90)
    }

    @Test func internationalToDomesticNeedsOneTwentyAndShortConnectionIsTight() throws {
        // 방콕 → 인천 → 제주: 국제선 도착 뒤 국내선.
        let inbound = FlightLeg(flight: "AB124", origin: "BKK", destination: "ICN", departure: t(2027, 3, 11, 1, 0), durationMinutes: 330, terminal: "1")
        let domestic = FlightLeg(flight: "EF789", origin: "ICN", destination: "CJU", departure: t(2027, 3, 11, 10, 30), durationMinutes: 70, terminal: "1")
        // BKK 01:00 = 전날 18:00Z, +330분 = 23:30Z = ICN 08:30(UTC+9). 국내선 10:30 출발이라 대기 120분.
        let route = FlightItinerary(legs: [inbound, domestic])
        let layover = try #require(route.layovers.first)
        #expect(layover.scheduledMinutes == 120)
        #expect(layover.minimumMinutes == FlightConnectionRules.internationalToDomesticMinutes)
        #expect(!layover.isTight)
        // 국내선이 15분 당겨지면 촉박.
        var tight = route
        tight.legs[1].departure = t(2027, 3, 11, 10, 15)
        let short = try #require(tight.layovers.first)
        #expect(short.scheduledMinutes == 105 && short.isTight && short.shortfallMinutes == 15)
    }

    @Test func delayShrinksLayoverMarginAndFlagsTightConnection() throws {
        var route = bangkokRoute()
        let first = try #require(route.legs[0].flight)
        route.changes = [FlightChange(flight: first, before: t(2027, 3, 7, 9, 5), after: t(2027, 3, 7, 10, 10), delayMinutes: 65, reason: "기체 점검", receivedAt: Date(timeIntervalSince1970: 1_000))]
        let layover = try #require(route.layovers.first)
        #expect(layover.scheduledMinutes == 155 && layover.currentMinutes == 90)
        #expect(layover.lostMinutes == 65)
        #expect(!layover.isTight) // 90분 ≥ 같은 터미널 60분
        // 더 늦어지면(앞 구간 +65 → 최신 이력 +100) 촉박.
        route.changes.append(FlightChange(flight: first, delayMinutes: 100, receivedAt: Date(timeIntervalSince1970: 2_000)))
        #expect(route.layovers.first?.currentMinutes == 55)
        #expect(route.tightLayovers.count == 1)
        // 이력 순서가 뒤바뀌어 들어와도 가장 늦게 받은 값을 쓴다.
        route.changes.reverse()
        #expect(route.delay(of: route.legs[0]) == 100)
    }

    @Test func laterLegDelayGrowsLayover() throws {
        var route = bangkokRoute()
        route.changes = [FlightChange(flight: "CD456", delayMinutes: 30, receivedAt: Date(timeIntervalSince1970: 1))]
        #expect(route.layovers.first?.currentMinutes == 185)
    }

    @Test func disconnectedLegsAreNotLayovers() {
        let a = FlightLeg(origin: "ICN", destination: "BKK", departure: t(2027, 3, 7, 9), durationMinutes: 330)
        let b = FlightLeg(origin: "SIN", destination: "ICN", departure: t(2027, 3, 11, 9), durationMinutes: 400)
        #expect(FlightItinerary(legs: [a, b]).layovers.isEmpty)
        #expect(FlightItinerary(legs: [a]).layovers.isEmpty)
        #expect(FlightItinerary(legs: [a, b]).airportPath == ["ICN", "BKK", "SIN", "ICN"])
        #expect(bangkokRoute().airportPath == ["ICN", "BKK", "DAD"])
    }

    @Test func airportArrivalIsOneEightyInternationalSixtyDomestic() throws {
        let intl = FlightLeg(origin: "ICN", destination: "BKK", departure: t(2027, 3, 7, 9, 5), durationMinutes: 330)
        let rec = try #require(FlightAirportArrival.recommendation(for: intl))
        #expect(rec.leadMinutes == 180 && rec.basis == .standard)
        #expect(rec.arriveBy == intl.departureInstant?.addingTimeInterval(-180 * 60))
        let domestic = FlightLeg(origin: "GMP", destination: "CJU", departure: t(2027, 3, 7, 9), durationMinutes: 70)
        #expect(FlightAirportArrival.recommendation(for: domestic)?.leadMinutes == 60)
        #expect(FlightAirportArrival.recommendation(for: FlightLeg(origin: "ICN", destination: "BKK")) == nil)
    }

    @Test func onsiteGuidanceOverridesStandardLeadAndIsMarked() throws {
        let leg = FlightLeg(origin: "DAD", destination: "ICN", departure: t(2027, 3, 11, 1, 0), durationMinutes: 330)
        let rec = try #require(FlightAirportArrival.recommendation(for: leg, onsiteGuidanceLeadMinutes: 150))
        #expect(rec.leadMinutes == 150 && rec.basis == .onsiteGuidance)
        #expect(FlightAirportArrival.recommendation(for: leg, onsiteGuidanceLeadMinutes: 0)?.basis == .standard)
    }

    @Test func homeDepartureNeedsKnownTravelTime() throws {
        let arriveBy = Date(timeIntervalSince1970: 100_000)
        #expect(FlightAirportArrival.homeDeparture(arriveBy: arriveBy, travelMinutes: 90) == arriveBy.addingTimeInterval(-5_400))
        #expect(FlightAirportArrival.homeDeparture(arriveBy: arriveBy, travelMinutes: nil) == nil)
        #expect(FlightAirportArrival.homeDeparture(arriveBy: arriveBy, travelMinutes: -1) == nil)
    }

    @Test func firstDayStartsAfterImmigrationForInternationalArrival() throws {
        let leg = bangkokRoute().legs[0]
        let earliest = try #require(FlightAirportArrival.earliestStart(after: leg))
        #expect(earliest == leg.arrivalInstant?.addingTimeInterval(60 * 60))
        let domestic = FlightLeg(origin: "GMP", destination: "CJU", departure: t(2027, 3, 7, 9), durationMinutes: 70)
        #expect(FlightAirportArrival.earliestStart(after: domestic) == domestic.arrivalInstant)
        #expect(FlightAirportArrival.earliestStart(after: FlightLeg(origin: "ICN", destination: "BKK")) == nil)
    }
}
