import Foundation
import Testing
@testable import TaptionPlanStore

/// 여행 모드 지구본(TVB1112A01): 경계 자료 읽기, 정사 투영, 화면 맞춤, 회전·깃발·확대 순서.
struct TravelGlobeTests {
    static func bundledRegions() throws -> [TravelGlobeRegion] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try TravelGlobeRegions.decode(Data(contentsOf: root.appendingPathComponent("TaptionPlan/MapData/ne-regions.bin")))
    }

    @Test func bundledBoundariesDecode() throws {
        let regions = try Self.bundledRegions()
        #expect(regions.count == 257)
        #expect(Set(regions.map(\.code)).count == regions.count, "코드가 겹치지 않는다")
        let japan = try #require(regions.first { $0.code == "JP" })
        #expect(japan.kind == .country)
        #expect(japan.nameKo == "일본")
        #expect(japan.west > 120 && japan.east < 150 && japan.south > 20 && japan.north < 50)
        #expect(japan.rings.count >= 4, "큰 섬 넷은 남는다")
        #expect(regions.contains { $0.code == "TH" } && regions.contains { $0.code == "FR" } && regions.contains { $0.code == "KR" })
        let provinces = regions.filter { $0.kind == .province }
        #expect(provinces.count == 17)
        let daegu = try #require(provinces.first { $0.code == "KR-27" })
        #expect(daegu.nameKo == "대구광역시")
        #expect(abs(daegu.center.x - 128.6) < 0.3 && abs(daegu.center.y - 35.85) < 0.3)
        #expect(regions.allSatisfy { region in region.rings.allSatisfy { $0.count >= 3 } })
    }

    @Test func pointsFindTheirCountryAndProvinceAndFlagsStayOnTheMainland() throws {
        let regions = try Self.bundledRegions()
        func find(_ kind: TravelGlobeRegion.Kind, _ longitude: Double, _ latitude: Double) -> String? {
            TravelGlobeRegions.region(in: regions, kind: kind, longitude: longitude, latitude: latitude)?.code
        }
        #expect(find(.country, 135.50, 34.69) == "JP", "오사카")
        #expect(find(.country, 100.50, 13.75) == "TH", "방콕")
        #expect(find(.country, 2.35, 48.86) == "FR", "파리")
        #expect(find(.country, 128.60, 35.87) == "KR")
        #expect(find(.province, 128.60, 35.87) == "KR-27", "대구")
        #expect(find(.province, 126.98, 37.57) == "KR-11", "서울")
        #expect(find(.country, -30, 30) == nil, "대서양 한가운데")
        // 프랑스는 해외 영토 때문에 전체 상자의 가운데가 바다지만, 깃발 자리는 본토다.
        let france = try #require(regions.first { $0.code == "FR" })
        #expect(france.contains(longitude: france.anchor.x, latitude: france.anchor.y))
        #expect(france.mainBox.west > -6 && france.mainBox.east < 10)
    }

    @Test func damagedBoundaryDataIsRejected() throws {
        #expect(throws: TravelGlobeRegions.DecodeError.self) { try TravelGlobeRegions.decode(Data("TPXX".utf8)) }
        #expect(throws: TravelGlobeRegions.DecodeError.self) { try TravelGlobeRegions.decode(Data(Array("TPRG".utf8) + [1, 5, 0, 0, 0])) }
    }

    @Test func projectionPutsTheCenterInTheMiddleAndHidesTheFarSide() {
        let camera = TravelGlobeCamera(longitude: 135, latitude: 35, radius: 100)
        let center = camera.project(longitude: 135, latitude: 35)
        #expect(center.isFront)
        #expect(abs(center.point.x) < 1e-9 && abs(center.point.y) < 1e-9)
        #expect(camera.project(longitude: 145, latitude: 35).point.x > 0, "동쪽은 오른쪽")
        #expect(camera.project(longitude: 135, latitude: 45).point.y < 0, "북쪽은 위")
        let far = camera.project(longitude: -45, latitude: -35)
        #expect(!far.isFront)
        let edge = camera.project(longitude: -60, latitude: 10)
        #expect(!edge.isFront)
        #expect(abs((edge.point.x * edge.point.x + edge.point.y * edge.point.y).squareRoot() - 100) < 1e-6, "뒤쪽 점은 가장자리에 붙는다")
    }

    @Test func fittingFillsTheScreenWithTheCountry() throws {
        let japan = try #require(try Self.bundledRegions().first { $0.code == "JP" })
        let camera = TravelGlobeCamera.fitting(
            west: japan.west, south: japan.south, east: japan.east, north: japan.north, width: 390, height: 700, padding: 40,
            minimumRadius: 140, maximumRadius: 20_000
        )
        var widest = 0.0, tallest = 0.0
        for ring in japan.rings {
            for point in ring {
                let projected = camera.project(longitude: point.x, latitude: point.y)
                #expect(projected.isFront)
                widest = max(widest, abs(projected.point.x))
                tallest = max(tallest, abs(projected.point.y))
            }
        }
        #expect(widest <= 155.5 && tallest <= 310.5, "여백 안에 들어온다")
        #expect(widest > 140 || tallest > 290, "한쪽은 화면에 꽉 찬다")
        let tiny = TravelGlobeCamera.fitting(west: 0, south: 0, east: 0.001, north: 0.001, width: 390, height: 700, padding: 40, minimumRadius: 140, maximumRadius: 9_000)
        #expect(tiny.radius == 9_000, "너무 작은 곳은 상한에서 멈춘다")
    }

    @Test func flightRotatesThenPlantsThenZooms() {
        let start = TravelGlobeCamera(longitude: 170, latitude: 20, radius: 140)
        let country = TravelGlobeCamera(longitude: -150, latitude: 60, radius: 600)
        let province = TravelGlobeCamera(longitude: -149, latitude: 61, radius: 3_000)
        let flight = TravelGlobeFlight(start: start, targetLongitude: -150, targetLatitude: 60, stops: [country, province])
        #expect(flight.camera(at: 0) == start)
        #expect(flight.flagProgress(at: 0) == 0)
        // 170°에서 −150°로는 날짜 변경선을 넘어 40°만 돈다.
        let halfway = flight.camera(at: TravelGlobeFlight.rotate / 2)
        #expect(abs(abs(halfway.longitude) - 170) <= 20.001 && abs(halfway.longitude) >= 150)
        #expect(halfway.radius == 140, "도는 동안은 크기가 그대로다")
        let turned = flight.camera(at: TravelGlobeFlight.rotate)
        #expect(abs(turned.longitude - -150) < 1e-9 && abs(turned.latitude - 60) < 1e-9)
        #expect(abs(flight.flagProgress(at: TravelGlobeFlight.rotate + TravelGlobeFlight.plant / 2) - 0.5) < 1e-9)
        #expect(abs(flight.flagProgress(at: TravelGlobeFlight.rotate + TravelGlobeFlight.plant) - 1) < 1e-9)
        #expect(flight.flagProgress(at: flight.duration) == 1)
        let planted = TravelGlobeFlight.rotate + TravelGlobeFlight.plant
        #expect(flight.camera(at: planted + TravelGlobeFlight.hold).radius == 140, "깃발이 꽂힌 뒤 잠깐 멈춘다")
        #expect(flight.camera(at: planted + TravelGlobeFlight.hold + TravelGlobeFlight.zoom) == country)
        #expect(flight.camera(at: flight.duration) == province)
        #expect(flight.camera(at: flight.duration + 5) == province)
        #expect(abs(flight.duration - (1.2 + 0.45 + 2 * 1.4)) < 1e-9)
        let noZoom = TravelGlobeFlight(start: start, targetLongitude: 0, targetLatitude: 0, stops: [])
        #expect(noZoom.camera(at: 10).radius == 140)
    }
}
