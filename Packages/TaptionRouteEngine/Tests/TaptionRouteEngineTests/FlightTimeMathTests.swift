import Foundation
import Testing
@testable import TaptionRouteEngine

struct FlightTimeMathTests {
    private let seoul = "Asia/Seoul"
    private let losAngeles = "America/Los_Angeles"

    private func time(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> FlightLocalTime {
        FlightLocalTime(year: year, month: month, day: day, hour: hour, minute: minute)
    }

    @Test func incheonEveningArrivesInLosAngelesSameDayAfternoon() throws {
        // 겨울(PST, 한국보다 17시간 늦다): 19:00 출발 + 12시간 = 같은 날 14:00
        let winter = try #require(FlightTimeMath.arrival(departure: time(2026, 12, 1, 19), departureZone: seoul, durationMinutes: 720, arrivalZone: losAngeles))
        #expect(winter.local == time(2026, 12, 1, 14))
        #expect(winter.dayOffset == 0)
        // 여름(PDT, 16시간 늦다): 같은 도착 시각이 되려면 11시간
        let summer = try #require(FlightTimeMath.arrival(departure: time(2026, 7, 1, 19), departureZone: seoul, durationMinutes: 660, arrivalZone: losAngeles))
        #expect(summer.local == time(2026, 7, 1, 14))
        #expect(summer.dayOffset == 0)
        #expect(FlightTimeMath.durationMinutes(departure: time(2026, 12, 1, 19), departureZone: seoul, arrival: time(2026, 12, 1, 14), arrivalZone: losAngeles) == 720)
        #expect(FlightTimeMath.durationMinutes(departure: time(2026, 7, 1, 19), departureZone: seoul, arrival: time(2026, 7, 1, 14), arrivalZone: losAngeles) == 660)
    }

    @Test func daylightSavingStartShiftsArrivalByAnHour() throws {
        // 미국 서머타임은 2026-03-08 02:00(현지)에 시작한다. 같은 12시간 비행이 하루 차이로 14시·15시에 닿는다.
        let before = try #require(FlightTimeMath.arrival(departure: time(2026, 3, 7, 19), departureZone: seoul, durationMinutes: 720, arrivalZone: losAngeles))
        #expect(before.local == time(2026, 3, 7, 14))
        let after = try #require(FlightTimeMath.arrival(departure: time(2026, 3, 8, 19), departureZone: seoul, durationMinutes: 720, arrivalZone: losAngeles))
        #expect(after.local == time(2026, 3, 8, 15))
        // 비행 중에 서머타임이 시작돼도 실제 지난 시간은 그대로다.
        let across = try #require(FlightTimeMath.arrival(departure: time(2026, 3, 8, 15), departureZone: seoul, durationMinutes: 720, arrivalZone: losAngeles))
        #expect(across.local == time(2026, 3, 8, 11))
        #expect(across.instant.timeIntervalSince(try #require(FlightTimeMath.instant(time(2026, 3, 8, 15), zone: seoul))) == 43_200)
    }

    @Test func daylightSavingEndRepeatsAnHour() throws {
        // 2026-11-01 02:00 PDT → 01:00 PST
        let arrival = try #require(FlightTimeMath.arrival(departure: time(2026, 11, 1, 0, 30), departureZone: losAngeles, durationMinutes: 120, arrivalZone: losAngeles))
        #expect(arrival.local == time(2026, 11, 1, 1, 30))
    }

    @Test func westboundAcrossTheDateLineSkipsADay() throws {
        // LA 1월 10일 23:30 출발, 13시간 30분 → 인천 1월 12일 06:00
        let arrival = try #require(FlightTimeMath.arrival(departure: time(2026, 1, 10, 23, 30), departureZone: losAngeles, durationMinutes: 810, arrivalZone: seoul))
        #expect(arrival.local == time(2026, 1, 12, 6))
        #expect(arrival.dayOffset == 2)
    }

    @Test func eastboundAcrossTheDateLineCanLandTheDayBefore() throws {
        // 오클랜드 1월 10일 10:00(UTC+13) 출발, 5시간 → 호놀룰루 1월 9일 16:00(UTC-10)
        let arrival = try #require(FlightTimeMath.arrival(departure: time(2026, 1, 10, 10), departureZone: "Pacific/Auckland", durationMinutes: 300, arrivalZone: "Pacific/Honolulu"))
        #expect(arrival.local == time(2026, 1, 9, 16))
        #expect(arrival.dayOffset == -1)
    }

    @Test func badInputGivesNil() {
        #expect(FlightTimeMath.arrival(departure: time(2026, 12, 1, 19), departureZone: "Mars/Olympus", durationMinutes: 60, arrivalZone: seoul) == nil)
        #expect(FlightTimeMath.arrival(departure: time(2026, 12, 1, 19), departureZone: seoul, durationMinutes: 60, arrivalZone: "") == nil)
        #expect(FlightTimeMath.arrival(departure: time(2026, 12, 1, 19), departureZone: seoul, durationMinutes: -1, arrivalZone: seoul) == nil)
        #expect(FlightTimeMath.arrival(departure: time(2026, 2, 30, 19), departureZone: seoul, durationMinutes: 60, arrivalZone: seoul) == nil)
        // 서머타임으로 건너뛴 02:30
        #expect(FlightTimeMath.instant(time(2026, 3, 8, 2, 30), zone: losAngeles) == nil)
    }
}
