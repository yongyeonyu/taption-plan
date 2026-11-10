import Foundation
import Testing
@testable import TaptionRouteEngine

struct TravelRulesTests {
    private func bundled() throws -> TravelRules {
        try #require(TravelRules.bundled)
    }

    @Test func bundledValuesMatchTheSheet() throws {
        let rules = try bundled()
        #expect(rules.version == "2026-11")
        #expect(rules.transit?.marginRatio == 0.2)
        #expect(rules.checkinLeadMinutes(isInternational: false) == 60)
        #expect(rules.checkinLeadMinutes(isInternational: true) == 120)
        #expect(rules.hotel?.checkinBufferMinutes == 30)
        #expect(rules.taxRefund?.minimizeQueueMinutes == 30)
    }

    @Test func marginAddsTwentyPercentRoundedUp() throws {
        let rules = try bundled()
        #expect(rules.travelMinutes(withMargin: 0) == 0)
        #expect(rules.travelMinutes(withMargin: 10) == 12)
        #expect(rules.travelMinutes(withMargin: 39) == 47)   // 46.8
        #expect(rules.travelMinutes(withMargin: 41) == 50)   // 49.2
        #expect(rules.travelMinutes(withMargin: 50) == 60)   // 소수 오차로 61이 되지 않는다
        #expect(rules.travelMinutes(withMargin: 55) == 66)
        #expect(rules.travelMinutes(withMargin: -1) == nil)
        #expect(rules.travelMinutes(withMargin: .infinity) == nil)
    }

    @Test func airportBufferByCountry() throws {
        let rules = try bundled()
        #expect(rules.airportArrivalBufferMinutes() == 40)
        #expect(rules.airportArrivalBufferMinutes(country: "US") == 90)
        #expect(rules.airportArrivalBufferMinutes(country: "th") == 25)
        #expect(rules.airportArrivalBufferMinutes(country: "JP") == 30)
        #expect(rules.airportArrivalBufferMinutes(country: "FR") == 40)
    }

    @Test func airportBufferIsSeparateFromMargin() throws {
        let rules = try bundled()
        let blocks = try #require(rules.arrivalBlocks(onwardTravelMinutes: 50, country: "US"))
        #expect(blocks.airportBufferMinutes == 90)
        #expect(blocks.travelMinutes == 60)
        #expect(blocks.totalMinutes == 150)   // (90 + 50) × 1.2 = 168이 아니다
        #expect(rules.arrivalBlocks(onwardTravelMinutes: 30)?.totalMinutes == 76)
    }

    @Test func minimumConnection() throws {
        let rules = try bundled()
        #expect(rules.minimumConnectionMinutes() == 90)
        #expect(rules.minimumConnectionMinutes(country: "US") == 150)
        #expect(rules.allowsConnection(layoverMinutes: 90) == true)
        #expect(rules.allowsConnection(layoverMinutes: 89) == false)
        #expect(rules.allowsConnection(layoverMinutes: 149, country: "US") == false)
        #expect(rules.allowsConnection(layoverMinutes: 150, country: "US") == true)
    }

    @Test func missingKeysGiveNil() throws {
        let rules = try #require(TravelRules.decode(Data(#"{"version":"t","airport":{"arrivalBufferMinutes":{"US":90}}}"#.utf8)))
        #expect(rules.travelMinutes(withMargin: 10) == nil)
        #expect(rules.airportArrivalBufferMinutes(country: "US") == 90)
        #expect(rules.airportArrivalBufferMinutes(country: "JP") == nil)
        #expect(rules.checkinLeadMinutes(isInternational: true) == nil)
        #expect(rules.minimumConnectionMinutes() == nil)
        #expect(rules.allowsConnection(layoverMinutes: 200) == nil)
        #expect(rules.arrivalBlocks(onwardTravelMinutes: 10, country: "US") == nil)
        #expect(TravelRules.decode(Data("{}".utf8)) == nil)
    }

    @Test func guideIsBundledWithSections() throws {
        let guide = try #require(TravelRules.bundledGuide)
        for section in ["## transit", "## airport", "## hotel", "## tax refund"] {
            #expect(guide.contains(section))
        }
    }
}
