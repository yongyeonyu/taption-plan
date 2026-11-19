import Foundation
import Testing
@testable import TaptionRouteEngine

struct FlightAirportCatalogTests {
    @Test func everyAirportHasValidCoordinatesAndResolvableTimeZone() {
        #expect(FlightAirportCatalog.all.count >= 200)
        for airport in FlightAirportCatalog.all {
            #expect(airport.code.count == 3 && airport.code == airport.code.uppercased(), "\(airport.code)")
            #expect((-90...90).contains(airport.latitude) && (-180...180).contains(airport.longitude), "\(airport.code)")
            #expect(TimeZone(identifier: airport.timeZone) != nil, "\(airport.code) \(airport.timeZone)")
            #expect(!airport.nameKo.isEmpty && !airport.nameEn.isEmpty && airport.country.count == 2, "\(airport.code)")
        }
    }

    @Test func codesAreUnique() {
        let codes = FlightAirportCatalog.all.map(\.code)
        #expect(Set(codes).count == codes.count)
    }

    @Test func majorAirportsAndHubsArePresent() {
        let required = ["ICN", "GMP", "PUS", "CJU", "TAE", "CJJ", "KWJ", "NRT", "HND", "KIX", "FUK", "CTS", "OKA", "PEK", "PVG", "HKG", "TPE",
                        "BKK", "SGN", "HAN", "DAD", "SIN", "KUL", "MNL", "DPS", "GUM", "LAX", "SFO", "JFK", "SEA", "HNL", "YVR",
                        "LHR", "CDG", "FRA", "AMS", "FCO", "IST", "DXB", "DOH", "SYD", "AKL"]
        for code in required { #expect(FlightAirportCatalog.airport(code) != nil, "\(code)") }
    }

    @Test func lookupIgnoresCaseAndSpacesAndReturnsNilForUnknown() throws {
        #expect(try #require(FlightAirportCatalog.airport(" icn ")).code == "ICN")
        #expect(FlightAirportCatalog.airport("ZZZ") == nil)
        #expect(FlightAirportCatalog.airport("") == nil)
        #expect(FlightAirportCatalog.airport(nil) == nil)
        #expect(FlightAirportCatalog.airport("INCHEON") == nil)
    }

    @Test func koreaListAndDomesticJudgement() {
        let korea = FlightAirportCatalog.korea.map(\.code)
        #expect(korea.contains("ICN") && korea.contains("CJU") && !korea.contains("NRT"))
        #expect(FlightAirportCatalog.isDomestic(from: "GMP", to: "CJU") == true)
        #expect(FlightAirportCatalog.isDomestic(from: "ICN", to: "BKK") == false)
        #expect(FlightAirportCatalog.isDomestic(from: "ICN", to: "ZZZ") == nil)
    }

    @Test func searchFindsByCodeKoreanAndEnglishNameWithExactCodeFirst() {
        #expect(FlightAirportCatalog.search("DAD").first?.code == "DAD")
        #expect(FlightAirportCatalog.search("다낭").map(\.code).contains("DAD"))
        #expect(FlightAirportCatalog.search("narita").map(\.code).contains("NRT"))
        #expect(FlightAirportCatalog.search("   ").isEmpty)
        #expect(FlightAirportCatalog.search("도쿄").count >= 2)
    }

    @Test func timeZonesRoundTripThroughFlightTimeMath() throws {
        // 인천 → 방콕: 한국이 2시간 빠르다.
        let seoul = try #require(FlightAirportCatalog.airport("ICN")).timeZone
        let bangkok = try #require(FlightAirportCatalog.airport("BKK")).timeZone
        let depart = FlightLocalTime(year: 2027, month: 3, day: 7, hour: 9, minute: 5)
        let arrival = try #require(FlightTimeMath.arrival(departure: depart, departureZone: seoul, durationMinutes: 330, arrivalZone: bangkok))
        #expect(arrival.local == FlightLocalTime(year: 2027, month: 3, day: 7, hour: 12, minute: 35))
        // 인천 → 로스앤젤레스 : 날짜변경선을 동쪽으로 넘어 같은 날 저녁(겨울, PST).
        let la = try #require(FlightAirportCatalog.airport("LAX")).timeZone
        let eastbound = try #require(FlightTimeMath.arrival(departure: FlightLocalTime(year: 2026, month: 12, day: 1, hour: 19, minute: 0), departureZone: seoul, durationMinutes: 720, arrivalZone: la))
        #expect(eastbound.local == FlightLocalTime(year: 2026, month: 12, day: 1, hour: 14, minute: 0))
        #expect(eastbound.dayOffset == 0)
    }
}
