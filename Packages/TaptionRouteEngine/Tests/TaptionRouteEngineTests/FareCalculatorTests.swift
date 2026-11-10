import Foundation
import Testing
@testable import TaptionRouteEngine

struct FareCalculatorTests {
    private let metro = "수도권"

    private func bundled() throws -> FareCalculator {
        try #require(FareCalculator.bundled)
    }

    /// 한국 시각 2026-11-10의 시:분.
    private func kst(_ hour: Int, _ minute: Int, day: Int = 10) -> Date {
        FlightTimeMath.instant(FlightLocalTime(year: 2026, month: 11, day: day, hour: hour, minute: minute), zone: "Asia/Seoul") ?? .distantPast
    }

    private func leg(_ mode: String, _ km: Double, _ from: Date, minutes: Double = 20) -> FareLeg {
        FareLeg(mode: mode, distanceKm: km, boardedAt: from, alightedAt: from.addingTimeInterval(minutes * 60))
    }

    @Test func acceptanceFares() throws {
        let fares = try bundled()
        // 가정역→마곡나루역 20.0km, 대구 하양역→중앙로역 24.1km
        #expect(fares.fare(region: metro, mode: "rail", distanceKm: 20.0) == 1_750)
        #expect(fares.fare(region: "대구", mode: "rail", distanceKm: 24.1) == 1_500)
        #expect(fares.fare(region: metro, mode: "서울_간선지선") == 1_500)
        #expect(fares.fare(region: metro, mode: "서울_광역") == 3_000)
        #expect(fares.fare(region: metro, mode: "경기_직행좌석") == 3_200)
        #expect(fares.fare(region: metro, mode: "경기_광역급행M") == 3_200)
    }

    @Test func railDistanceSteps() throws {
        let fares = try bundled()
        let cases: [(Double, Int)] = [
            (0, 1_550), (10, 1_550), (10.1, 1_650), (15, 1_650), (15.1, 1_750),
            (50, 2_350), (50.1, 2_450), (58, 2_450), (58.1, 2_550), (66, 2_550),
        ]
        for (km, expected) in cases {
            #expect(fares.fare(region: metro, mode: "rail", distanceKm: km) == expected, "\(km)km")
        }
    }

    @Test func teenAndChildUseTheirOwnTables() throws {
        let fares = try bundled()
        #expect(fares.fare(region: metro, mode: "rail", distanceKm: 20, age: .teen) == 1_060)
        #expect(fares.fare(region: metro, mode: "rail", distanceKm: 20, age: .child) == 650)
        #expect(fares.fare(region: metro, mode: "rail", distanceKm: 58, age: .teen) == 1_620)
        #expect(fares.fare(region: "대구", mode: "rail", distanceKm: 24.1, age: .teen) == 850)
        #expect(fares.fare(region: "대구", mode: "rail", distanceKm: 24.1, age: .child) == 400)
        #expect(fares.fare(region: metro, mode: "서울_간선지선", age: .teen) == 900)
        #expect(fares.fare(region: metro, mode: "서울_광역", age: .teen) == 1_700)
        #expect(fares.fare(region: metro, mode: "서울_광역", age: .child) == 1_500)
        #expect(fares.fare(region: metro, mode: "경기_직행좌석", age: .teen) == 2_300)
        #expect(fares.fare(region: metro, mode: "경기_광역급행M", age: .child) == 1_600)
    }

    @Test func ageBandComesFromBirthDate() throws {
        let fares = try bundled()
        let today = kst(12, 0)
        func born(_ year: Int, _ month: Int, _ day: Int) -> Date {
            FlightTimeMath.instant(FlightLocalTime(year: year, month: month, day: day, hour: 0, minute: 0), zone: "Asia/Seoul") ?? .distantPast
        }
        #expect(fares.ageBand(birthDate: nil, on: today) == .adult)
        #expect(fares.ageBand(birthDate: born(2007, 11, 10), on: today) == .adult)  // 오늘 만 19세
        #expect(fares.ageBand(birthDate: born(2007, 11, 11), on: today) == .teen)   // 내일 만 19세
        #expect(fares.ageBand(birthDate: born(2013, 11, 10), on: today) == .teen)   // 오늘 만 13세
        #expect(fares.ageBand(birthDate: born(2013, 11, 11), on: today) == .child)
        #expect(fares.ageBand(birthDate: born(2023, 1, 1), on: today) == .child)
    }

    @Test func transferInsideWindowIsOneTrip() throws {
        let fares = try bundled()
        // 지하철 8km 하차(10:20) → 29분 뒤 간선버스 7km: 합 15km, 높은 기본요금 1,550 + 100
        let legs = [leg("rail", 8, kst(10, 0)), leg("서울_간선지선", 7, kst(10, 49))]
        let trips = try #require(fares.trips(region: metro, legs: legs))
        #expect(trips.count == 1)
        #expect(trips.first?.fare == 1_650)
        #expect(fares.totalFare(region: metro, legs: legs, age: .teen) == 980)
        #expect(fares.totalFare(region: metro, legs: legs, age: .child) == 600)
    }

    @Test func transferAtExactlyThirtyMinutesCounts() throws {
        let fares = try bundled()
        #expect(fares.totalFare(region: metro, legs: [leg("rail", 8, kst(10, 0)), leg("서울_간선지선", 7, kst(10, 50))]) == 1_650)
    }

    @Test func transferAfterWindowIsTwoTrips() throws {
        let fares = try bundled()
        let legs = [leg("rail", 8, kst(10, 0)), leg("서울_간선지선", 7, kst(10, 51))]
        #expect(fares.trips(region: metro, legs: legs)?.map(\.fare) == [1_550, 1_500])
        #expect(fares.totalFare(region: metro, legs: legs) == 3_050)
    }

    @Test func nightWindowIsSixtyMinutes() throws {
        let fares = try bundled()
        // 21:20 하차 → 45분 뒤 승차: 밤에는 한 묶음, 낮에는 두 묶음
        #expect(fares.totalFare(region: metro, legs: [leg("rail", 8, kst(21, 0)), leg("서울_간선지선", 7, kst(22, 5))]) == 1_650)
        #expect(fares.totalFare(region: metro, legs: [leg("rail", 8, kst(13, 0)), leg("서울_간선지선", 7, kst(14, 5))]) == 3_050)
        #expect(fares.totalFare(region: metro, legs: [leg("rail", 8, kst(21, 0)), leg("서울_간선지선", 7, kst(22, 21))]) == 3_050)
    }

    @Test func wideAreaBusRaisesBaseFareAndBaseDistance() throws {
        let fares = try bundled()
        // 경기도 공식 예시: 직행좌석 20km → 서울 간선 9km = 3,200원
        #expect(fares.totalFare(region: metro, legs: [leg("경기_직행좌석", 20, kst(8, 0)), leg("서울_간선지선", 9, kst(8, 30))]) == 3_200)
        // 합 36km: 30km 넘는 6km → 두 단계
        #expect(fares.totalFare(region: metro, legs: [leg("서울_광역", 28, kst(8, 0), minutes: 40), leg("rail", 8, kst(8, 50))]) == 3_200)
        // 간선 4km + 간선 26km = 30km: 1,500 + 400
        #expect(fares.totalFare(region: metro, legs: [leg("서울_간선지선", 4, kst(8, 0)), leg("서울_간선지선", 26, kst(8, 30))]) == 1_900)
    }

    @Test func railToRailIsNotATransfer() throws {
        let fares = try bundled()
        #expect(fares.totalFare(region: metro, legs: [leg("rail", 8, kst(10, 0)), leg("rail", 7, kst(10, 30))]) == 3_100)
    }

    @Test func sixthBoardingStartsANewTrip() throws {
        let fares = try bundled()
        let legs = (0..<6).map { leg("서울_간선지선", 1, kst(9, 0).addingTimeInterval(Double($0) * 1_500), minutes: 10) }
        #expect(fares.trips(region: metro, legs: legs)?.map(\.legs.count) == [5, 1])
        #expect(fares.totalFare(region: metro, legs: legs) == 3_000)
    }

    @Test func legsAreSortedByBoardingTime() throws {
        let fares = try bundled()
        let legs = [leg("서울_간선지선", 7, kst(10, 49)), leg("rail", 8, kst(10, 0))]
        #expect(fares.totalFare(region: metro, legs: legs) == 1_650)
    }

    @Test func unknownInputsGiveNil() throws {
        let fares = try bundled()
        #expect(fares.fare(region: "부산", mode: "rail", distanceKm: 5) == nil)
        #expect(fares.fare(region: metro, mode: "트램") == nil)
        #expect(fares.fare(region: metro, mode: "rail", distanceKm: -1) == nil)
        #expect(fares.fare(region: metro, mode: "rail", distanceKm: .nan) == nil)
        #expect(fares.trips(region: "부산", legs: []) == nil)
        #expect(fares.totalFare(region: metro, legs: [leg("트램", 3, kst(10, 0))]) == nil)
        #expect(fares.totalFare(region: metro, legs: []) == 0)
    }

    @Test func missingKeysDropOnlyTheBrokenPart() throws {
        let json = """
        {"version":"t","regions":{
          "가":{"modes":{"rail":{"kind":"rail","fares":{"adult":{"base":1000}}},"bus":{"kind":"bus"}}},
          "나":{"transfer":{}}
        }}
        """
        let fares = FareCalculator(table: try #require(FareTable.decode(Data(json.utf8))))
        #expect(fares.fare(region: "가", mode: "rail", distanceKm: 99) == 1_000)
        #expect(fares.fare(region: "가", mode: "rail", age: .teen) == nil)
        #expect(fares.fare(region: "가", mode: "bus") == nil)
        #expect(fares.fare(region: "나", mode: "rail") == nil)
        // 나이 기준이 없으면 일반
        #expect(fares.ageBand(birthDate: Date(timeIntervalSince1970: 1_700_000_000), on: Date(timeIntervalSince1970: 1_800_000_000)) == .adult)
        #expect(FareTable.decode(Data("{}".utf8)) == nil)
        #expect(FareTable.decode(Data("not json".utf8)) == nil)
    }

    @Test func replacingTheTableChangesFares() throws {
        let json = """
        {"version":"next","regions":{"수도권":{"modes":{"rail":{"kind":"rail",
          "bands":[{"fromKm":10,"unitKm":5}],"fares":{"adult":{"base":1700,"extra":150}}}}}}}
        """
        let fares = FareCalculator(table: try #require(FareTable.decode(Data(json.utf8))))
        #expect(fares.fare(region: metro, mode: "rail", distanceKm: 20) == 2_000)
    }

    @Test func bundledTableCarriesVersionAndSources() throws {
        let table = try #require(FareTable.bundled)
        #expect(table.version == "2026-11")
        for name in [metro, "대구"] {
            let region = try #require(table.regions[name])
            #expect(region.checkedOn?.isEmpty == false)
            #expect(region.sources?.isEmpty == false)
        }
        #expect(table.regions["대구"]?.transfer?.verified == false)
        #expect(table.regions[metro]?.modes["경기_직행좌석"]?.extraVerified == false)
    }
}
