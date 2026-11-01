import XCTest
import UIKit
import CoreLocation
import StoreKit
import StoreKitTest
import TaptionPlanCore
@testable import TaptionPlan

final class MapHomeGrowthPolicyTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    func testDailyEligibilityRequiresActualAndNoUnconfirmedRecords() {
        XCTAssertTrue(MapHomeGrowthPolicy.qualifies(actualCount: 1, unconfirmedCount: 0))
        XCTAssertFalse(MapHomeGrowthPolicy.qualifies(actualCount: 0, unconfirmedCount: 0))
        XCTAssertFalse(MapHomeGrowthPolicy.qualifies(actualCount: 2, unconfirmedCount: 1))
    }

    /// 장착 장식 스티커는 아바타 원 밖 오른쪽 위에 붙는다(원 안 10pt로는 아트에 묻혔다).
    /// 가장 안쪽 모서리가 원 밖이어야 하고, 지도 호스트 상자 안에는 남아야 한다.
    func testAccessoryStickerSitsOutsideAvatarCircleInsideHostBox() {
        let radius = MapHomePlacePinLayout.avatarSize / 2
        let offset = MapHomePlacePinLayout.accessoryStickerOffset
        let size = MapHomePlacePinLayout.accessoryStickerSize
        let nearest = CGPoint(x: radius - size + offset, y: -radius - offset + size)
        XCTAssertGreaterThan(hypot(nearest.x, nearest.y), radius)
        let far = CGPoint(x: radius + offset, y: -radius - offset)
        XCTAssertLessThan(abs(far.x), MapHomePlacePinLayout.appleHomeHostWidth / 2)
        XCTAssertLessThan(abs(far.y), MapHomePlacePinLayout.appleHomeHostHeight / 2)
    }

    func testCompletedDayRequiresFullCoverageAndAtLeastOneActual() {
        let start = date(2026, 9, 20)
        let end = date(2026, 9, 21)
        let complete = ActualRecord(
            planID: nil,
            title: "업무",
            categoryID: "work",
            startedAt: start,
            endedAt: end,
            source: .manual,
            manuallyCorrected: true
        )
        XCTAssertTrue(MapHomeGrowthPolicy.qualifiesDay(
            actuals: [complete], travel: [], on: start, asOf: end, calendar: calendar
        ))
        let partial = ActualRecord(
            planID: nil,
            title: "업무",
            categoryID: "work",
            startedAt: start,
            endedAt: start.addingTimeInterval(12 * 3_600),
            source: .manual,
            manuallyCorrected: true
        )
        XCTAssertFalse(MapHomeGrowthPolicy.qualifiesDay(
            actuals: [partial], travel: [], on: start, asOf: end, calendar: calendar
        ))
    }

    func testCalendarTimeTextFormatsCellsAndDurations() {
        typealias Policy = MapHomeCalendarTimeTotalsPolicy
        XCTAssertEqual(Policy.cellText(seconds: 0), "")
        XCTAssertEqual(Policy.cellText(seconds: 45 * 60), "45m")
        XCTAssertEqual(Policy.cellText(seconds: 2 * 3_600), "2h")
        XCTAssertEqual(Policy.cellText(seconds: 7 * 3_600 + 5 * 60), "7:05")
        XCTAssertEqual(Policy.durationText(seconds: 7 * 3_600 + 20 * 60, language: .korean), "7시간 20분")
        XCTAssertEqual(Policy.durationText(seconds: 3_600, language: .korean), "1시간")
        XCTAssertEqual(Policy.durationText(seconds: 30 * 60, language: .korean), "30분")
        XCTAssertEqual(Policy.durationText(seconds: 0, language: .korean), "0분")
        XCTAssertEqual(MapHomeCalendarTimeKind.allCases.map(\.rawValue),
                       ["sleep", "movement", "study", "work", "exercise", "hobby", "distance", "places", "trips", "steps", "photos", "walkDistance", "carDistance", "transitDistance", "awayTime", "stepDistance"])
        // 26.5걸음에 20m(대표 측정)로 정한 기본 보폭, 범위를 벗어난 값은 거부한다.
        XCTAssertEqual(MapHomeStride.defaultMeters, 20.0 / 26.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(MapHomeStride.calibrated(distanceMeters: 10, steps: 14)), 10.0 / 14.0, accuracy: 0.0001)
        XCTAssertNil(MapHomeStride.calibrated(distanceMeters: 10, steps: 3))
        XCTAssertNil(MapHomeStride.calibrated(distanceMeters: 10, steps: 100))
    }

    func testCalendarTimeTotalsSumCanonicalCategoriesPerDay() {
        let day = date(2026, 9, 20)
        let asOf = date(2026, 9, 25)
        func record(_ title: String, from: Double, to: Double) -> ActualRecord {
            ActualRecord(
                planID: nil, title: title, categoryID: "activity",
                startedAt: day.addingTimeInterval(from * 3_600), endedAt: day.addingTimeInterval(to * 3_600),
                source: .manual, manuallyCorrected: true
            )
        }
        let totals = MapHomeCalendarTimeTotalsPolicy.totals(
            actuals: [record("수면", from: 0, to: 7), record("업무", from: 9, to: 12)],
            travel: [], stays: [], placeKinds: [:], month: day, asOf: asOf, calendar: calendar
        )
        let values = totals[day] ?? [:]
        XCTAssertEqual(values["sleep"] ?? 0, 7 * 3_600, accuracy: 1)
        // 업무·수업·취미는 장소(회사·학교 등) 근거가 있어야 하루 요약이 센다. 장소 없는 수동 기록은 집계하지 않는다.
        XCTAssertNil(values["unconfirmed"], "미확인은 시간 메뉴에 담지 않는다")
        XCTAssertNil(totals[date(2026, 9, 21)], "기록이 없는 날은 담지 않는다")
        XCTAssertNil(totals[date(2026, 9, 26)], "오늘 이후는 담지 않는다")
    }

    func testCalendarDotsMarkIncompleteCompleteAndEmptyDays() {
        let day1 = date(2026, 9, 20)
        let day2 = date(2026, 9, 21)
        let day3 = date(2026, 9, 22)
        let asOf = date(2026, 9, 25)
        func record(_ start: Date, hours: Double) -> ActualRecord {
            ActualRecord(
                planID: nil, title: "업무", categoryID: "work",
                startedAt: start, endedAt: start.addingTimeInterval(hours * 3_600),
                source: .manual, manuallyCorrected: true
            )
        }
        let statuses = MapHomeCalendarLogStatusPolicy.statuses(
            actuals: [record(day1, hours: 24), record(day2, hours: 12)],
            travel: [], month: day1, asOf: asOf, calendar: calendar
        )
        XCTAssertEqual(statuses[day1], .complete)
        XCTAssertEqual(statuses[day2], .incomplete, "기록이 있어도 비는 구간(미확인)이 있으면 빨강")
        XCTAssertNil(statuses[day3], "기록이 없는 날은 점이 없다")
        XCTAssertTrue(MapHomeCalendarLogStatusPolicy.statuses(
            actuals: [], travel: [], month: day1, asOf: asOf, calendar: calendar
        ).isEmpty)
    }

    func testRecentCompletedDayOnlyAddsOneHouseLevel() {
        var history = MapHomeGrowthHistory.initial(for: date(2026, 9, 20), calendar: calendar)
        MapHomeGrowthPolicy.observeCurrentDay(
            in: &history,
            date: date(2026, 9, 20),
            qualified: false,
            calendar: calendar
        )
        MapHomeGrowthPolicy.closePendingDay(
            in: &history,
            asOf: date(2026, 9, 21),
            calendar: calendar
        )
        XCTAssertTrue(MapHomeGrowthPolicy.awardRecentCompletion(
            in: &history,
            day: date(2026, 9, 20),
            asOf: date(2026, 9, 27),
            qualified: true,
            calendar: calendar
        ))
        XCTAssertFalse(MapHomeGrowthPolicy.awardRecentCompletion(
            in: &history,
            day: date(2026, 9, 20),
            asOf: date(2026, 9, 27),
            qualified: true,
            calendar: calendar
        ))
        XCTAssertEqual(history.season.level, 2)
        XCTAssertEqual(history.season.pendingWeeklyRewards, 0)
        XCTAssertTrue(history.season.accessories.isEmpty)
        XCTAssertEqual(history.season.streak, 0)
    }

    func testPendingDaySettlesEvenWhenRecentCompletionIsNotAwarded() {
        var history = MapHomeGrowthHistory.initial(for: date(2026, 9, 26), calendar: calendar)
        MapHomeGrowthPolicy.observeCurrentDay(
            in: &history,
            date: date(2026, 9, 26),
            qualified: true,
            calendar: calendar
        )
        MapHomeGrowthPolicy.settleAndAwardRecentCompletion(
            in: &history,
            day: date(2026, 9, 20),
            asOf: date(2026, 9, 27),
            qualified: false,
            calendar: calendar
        )
        XCTAssertNil(history.season.pendingDay)
        XCTAssertEqual(history.season.lastClosedDay, "2026-09-26")
        XCTAssertEqual(history.season.level, 2)
        XCTAssertEqual(history.season.recentCompletionRewardedDays, ["2026-09-26"])
    }

    func testOrdinaryDailyRewardCannotBeClaimedAgainAsRecentCompletion() {
        var history = MapHomeGrowthHistory.initial(for: date(2026, 9, 20), calendar: calendar)
        MapHomeGrowthPolicy.observeCurrentDay(
            in: &history, date: date(2026, 9, 20), qualified: true, calendar: calendar
        )
        MapHomeGrowthPolicy.closePendingDay(
            in: &history, asOf: date(2026, 9, 21), calendar: calendar
        )
        XCTAssertFalse(MapHomeGrowthPolicy.awardRecentCompletion(
            in: &history,
            day: date(2026, 9, 20),
            asOf: date(2026, 9, 27),
            qualified: true,
            calendar: calendar
        ))
        XCTAssertEqual(history.season.level, 2)
    }

    func testRecentCompletionAcrossNewYearLevelsArchivedHouseOnly() {
        var history = MapHomeGrowthHistory.initial(for: date(2026, 12, 31), calendar: calendar)
        MapHomeGrowthPolicy.observeCurrentDay(
            in: &history, date: date(2027, 1, 1), qualified: false, calendar: calendar
        )
        XCTAssertTrue(MapHomeGrowthPolicy.awardRecentCompletion(
            in: &history,
            day: date(2026, 12, 31),
            asOf: date(2027, 1, 3),
            qualified: true,
            calendar: calendar
        ))
        XCTAssertEqual(history.archives.first?.level, 2)
        XCTAssertEqual(history.season.level, 1)
        XCTAssertTrue(history.archives.first?.accessories.isEmpty == true)
    }

    func testRecentCompletionRejectsOlderThanSevenDaysAndPreservesLegacyHistory() throws {
        var history = MapHomeGrowthHistory.initial(for: date(2026, 9, 1), calendar: calendar)
        let encoded = try JSONEncoder().encode(history)
        history = try JSONDecoder().decode(MapHomeGrowthHistory.self, from: encoded)
        XCTAssertNil(history.season.recentCompletionRewardedDays)
        XCTAssertFalse(MapHomeGrowthPolicy.awardRecentCompletion(
            in: &history,
            day: date(2026, 9, 19),
            asOf: date(2026, 9, 27),
            qualified: true,
            calendar: calendar
        ))
        XCTAssertFalse(MapHomeGrowthPolicy.awardRecentCompletion(
            in: &history,
            day: date(2026, 9, 26),
            asOf: date(2026, 9, 27),
            qualified: false,
            calendar: calendar
        ))
        XCTAssertEqual(history.season.level, 1)
    }

    func testClosedIncompleteDayStaysUnqualifiedDespiteLaterObservation() {
        var history = MapHomeGrowthHistory.initial(for: date(2026, 1, 1), calendar: calendar)
        MapHomeGrowthPolicy.observeCurrentDay(
            in: &history,
            date: date(2026, 1, 1),
            qualified: false,
            calendar: calendar
        )
        MapHomeGrowthPolicy.closePendingDay(
            in: &history,
            asOf: date(2026, 1, 2),
            calendar: calendar
        )
        MapHomeGrowthPolicy.observeCurrentDay(
            in: &history,
            date: date(2026, 1, 1),
            qualified: true,
            calendar: calendar
        )
        MapHomeGrowthPolicy.closePendingDay(
            in: &history,
            asOf: date(2026, 1, 3),
            calendar: calendar
        )

        XCTAssertEqual(history.season.level, 1)
        XCTAssertEqual(history.season.streak, 0)
    }

    func testSevenConsecutiveCompletedDaysCreateOneWeeklyReward() {
        var history = MapHomeGrowthHistory.initial(for: date(2026, 1, 1), calendar: calendar)
        for offset in 0..<7 {
            let day = calendar.date(byAdding: .day, value: offset, to: date(2026, 1, 1))!
            MapHomeGrowthPolicy.observeCurrentDay(
                in: &history,
                date: day,
                qualified: true,
                calendar: calendar
            )
            let nextDay = calendar.date(byAdding: .day, value: 1, to: day)!
            MapHomeGrowthPolicy.closePendingDay(
                in: &history,
                asOf: nextDay,
                calendar: calendar
            )
        }

        XCTAssertEqual(history.season.level, 8)
        XCTAssertEqual(history.season.streak, 7)
        XCTAssertEqual(history.season.pendingWeeklyRewards, 1)
    }

    func testMissedDayBreaksStreakAndDuplicateCloseDoesNotAwardTwice() {
        var history = MapHomeGrowthHistory.initial(for: date(2026, 1, 1), calendar: calendar)
        for offset in 0..<3 {
            let day = calendar.date(byAdding: .day, value: offset, to: date(2026, 1, 1))!
            MapHomeGrowthPolicy.observeCurrentDay(
                in: &history,
                date: day,
                qualified: true,
                calendar: calendar
            )
            MapHomeGrowthPolicy.closePendingDay(
                in: &history,
                asOf: calendar.date(byAdding: .day, value: 1, to: day)!,
                calendar: calendar
            )
        }
        let missedDay = date(2026, 1, 4)
        MapHomeGrowthPolicy.observeCurrentDay(
            in: &history,
            date: missedDay,
            qualified: false,
            calendar: calendar
        )
        MapHomeGrowthPolicy.closePendingDay(
            in: &history,
            asOf: date(2026, 1, 5),
            calendar: calendar
        )

        XCTAssertEqual(history.season.level, 4)
        XCTAssertEqual(history.season.streak, 0)
        XCTAssertEqual(history.season.pendingWeeklyRewards, 0)
    }

    func testYearLimitsLeapMarkAndArtworkNames() {
        XCTAssertEqual(MapHomeGrowthPolicy.maximumLevel(year: 2024, timeZone: calendar.timeZone), 366)
        XCTAssertEqual(MapHomeGrowthPolicy.maximumLevel(year: 2025, timeZone: calendar.timeZone), 365)
        XCTAssertEqual(MapHomeGrowthPolicy.artworkName(level: 0), "HomeEvolution001")
        XCTAssertEqual(MapHomeGrowthPolicy.artworkName(level: 367), "HomeEvolution366")
        XCTAssertTrue(MapHomeGrowthPolicy.isLeapDay(date(2024, 2, 29), calendar: calendar))
        XCTAssertFalse(MapHomeGrowthPolicy.isLeapDay(date(2025, 2, 28), calendar: calendar))
    }

    @MainActor
    func testAll366EvolutionIllustrationsArePackaged() {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard
        let size = CGSize(width: 48, height: 48)
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        var pixels = Set<Data>()
        var thumbnails: [UIImage] = []
        for level in 1...366 {
            autoreleasepool {
                let name = MapHomeGrowthPolicy.artworkName(level: level)
                guard let image = UIImage(named: name, in: Bundle.main, with: nil) else {
                    XCTFail("Missing bundled illustration: \(name)")
                    return
                }
                XCTAssertEqual(image.size, CGSize(width: 128, height: 128), name)
                let thumbnail = renderer.image { _ in
                    image.draw(in: CGRect(origin: .zero, size: size))
                }
                guard let data = thumbnail.cgImage?.dataProvider?.data else {
                    XCTFail("Cannot render bundled illustration: \(name)")
                    return
                }
                XCTAssertTrue(pixels.insert(data as Data).inserted, "Duplicate 48pt artwork: \(name)")
                thumbnails.append(thumbnail)
            }
        }
        XCTAssertEqual(thumbnails.count, 366)
        let columns = 16
        let tile = CGSize(width: 64, height: 72)
        let reviewSize = CGSize(width: tile.width * CGFloat(columns), height: tile.height * 23)
        let review = UIGraphicsImageRenderer(size: reviewSize, format: format).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: reviewSize))
            for (index, thumbnail) in thumbnails.enumerated() {
                let x = CGFloat(index % columns) * tile.width
                let y = CGFloat(index / columns) * tile.height
                thumbnail.draw(at: CGPoint(x: x + 8, y: y + 4))
                let label = "Lv.\(index + 1)" as NSString
                label.draw(at: CGPoint(x: x + 8, y: y + 54), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 9),
                    .foregroundColor: UIColor.darkGray
                ])
            }
        }
        let attachment = XCTAttachment(image: review)
        attachment.name = "HomeEvolution366-Bundled-48pt"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testYearChangeArchivesPreviousHouseAndStartsAtLevelOne() {
        var history = MapHomeGrowthHistory.initial(for: date(2026, 12, 31), calendar: calendar)
        history.season.level = 88
        MapHomeGrowthPolicy.observeCurrentDay(
            in: &history,
            date: date(2027, 1, 1),
            qualified: false,
            calendar: calendar
        )

        XCTAssertEqual(history.archives.map(\.year), [2026])
        XCTAssertEqual(history.archives.first?.level, 88)
        XCTAssertEqual(history.season.year, 2027)
        XCTAssertEqual(history.season.level, 1)
    }

    func testClosedIncompleteDayCannotBeRequalifiedRetroactively() {
        var history = MapHomeGrowthHistory.initial(for: date(2026, 1, 1), calendar: calendar)
        MapHomeGrowthPolicy.observeCurrentDay(
            in: &history,
            date: date(2026, 1, 1),
            qualified: false,
            calendar: calendar
        )
        MapHomeGrowthPolicy.closePendingDay(
            in: &history,
            asOf: date(2026, 1, 2),
            calendar: calendar
        )
        MapHomeGrowthPolicy.observeCurrentDay(
            in: &history,
            date: date(2026, 1, 1),
            qualified: true,
            calendar: calendar
        )
        MapHomeGrowthPolicy.closePendingDay(
            in: &history,
            asOf: date(2026, 1, 3),
            calendar: calendar
        )

        XCTAssertEqual(history.season.level, 1)
        XCTAssertEqual(history.season.streak, 0)
    }

    func testEveryLandmarkHasHatAndOldAccessoryFallsBackToSymbol() {
        XCTAssertEqual(MapHomeLandmarkCatalog.candidates.count, 52)
        for candidate in MapHomeLandmarkCatalog.candidates {
            let name = MapHomeGrowthAccessoryCatalog.hatAssetName(for: candidate.accessoryID)
            XCTAssertNotNil(name.flatMap { UIImage(named: $0) }, candidate.id)
        }
        XCTAssertNil(MapHomeGrowthAccessoryCatalog.hatAssetName(for: "cat.accessory.001"))
        XCTAssertNotNil(MapHomeGrowthAccessoryCatalog.symbol(for: "cat.accessory.001"))
    }

    func testWeeklyRewardUnlocksAndEquipsAccessory() {
        var history = MapHomeGrowthHistory.initial(for: date(2026, 1, 1), calendar: calendar)
        history.season.pendingWeeklyRewards = 1

        XCTAssertTrue(MapHomeGrowthPolicy.redeemWeeklyReward(
            evolutionID: "world.landmark.001",
            landPlotID: "plot.001",
            accessoryID: "cat.accessory.001",
            in: &history
        ))
        XCTAssertFalse(MapHomeGrowthPolicy.equipAccessory("locked", in: &history.season))
        XCTAssertTrue(MapHomeGrowthPolicy.equipAccessory("cat.accessory.001", in: &history.season))
        XCTAssertEqual(history.season.pendingWeeklyRewards, 0)
        XCTAssertEqual(history.season.landPlots, ["plot.001"])
        XCTAssertEqual(history.season.equippedAccessory, "cat.accessory.001")
    }

    func testLandmarkCatalogHasFiftyTwoChoicesForTheYearlyWeeklyRewards() {
        let grouped = Dictionary(grouping: MapHomeLandmarkCatalog.candidates, by: \.country)

        XCTAssertEqual(grouped.count, 10)
        XCTAssertEqual(grouped["대한민국"]?.count, 7, "한국은 52개로 맞추며 두 곳을 더했다")
        XCTAssertTrue(grouped.filter { $0.key != "대한민국" }.values.allSatisfy { $0.count == 5 })
        XCTAssertEqual(MapHomeLandmarkCatalog.candidates.count, 52)
        XCTAssertEqual(
            Set(MapHomeLandmarkCatalog.candidates.map(\.artworkName)).count,
            52
        )
        XCTAssertTrue(MapHomeLandmarkCatalog.candidates.allSatisfy {
            $0.artworkName.hasPrefix("Landmark_")
        })
        let choices = MapHomeLandmarkCatalog.weeklyChoices(
            for: MapHomeGrowthSeason(year: 2026)
        )
        XCTAssertEqual(choices.count, 3)
        XCTAssertEqual(Set(choices.map(\.id)).count, 3)
        XCTAssertEqual(
            MapHomeGrowthAccessoryCatalog.symbol(for: "cat.accessory.kr.gyeongbokgung"),
            MapHomeGrowthAccessoryCatalog.symbol(for: "cat.accessory.kr.gyeongbokgung")
        )
        XCTAssertNil(MapHomeGrowthAccessoryCatalog.symbol(for: nil))
    }

    func testOlderGrowthSeasonDecodesWithoutPlotPlacementField() throws {
        var season = MapHomeGrowthSeason(year: 2025)
        season.landPlotPlacements = [
            .init(plotID: "plot.saved", x: 0, y: 0),
        ]
        let encoded = try JSONEncoder().encode(season)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "landPlotPlacements")
        let olderData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(
            MapHomeGrowthSeason.self,
            from: olderData
        )

        XCTAssertNil(decoded.landPlotPlacements)
        XCTAssertEqual(decoded.year, 2025)
    }

    func testEarnedLandPlotsCanBePlacedAsConnectedTiles() {
        var history = MapHomeGrowthHistory.initial(for: date(2026, 1, 1), calendar: calendar)
        history.season.pendingWeeklyRewards = 2
        XCTAssertTrue(MapHomeGrowthPolicy.redeemWeeklyReward(
            evolutionID: "kr.gyeongbokgung",
            landPlotID: "plot.one",
            accessoryID: "cat.accessory.kr.gyeongbokgung",
            in: &history
        ))
        XCTAssertTrue(MapHomeGrowthPolicy.redeemWeeklyReward(
            evolutionID: "jp.fuji",
            landPlotID: "plot.two",
            accessoryID: "cat.accessory.jp.fuji",
            in: &history
        ))

        XCTAssertTrue(MapHomeGrowthPolicy.placeLandPlot("plot.one", in: &history.season))
        XCTAssertTrue(MapHomeGrowthPolicy.placeLandPlot("plot.two", in: &history.season))
        XCTAssertFalse(MapHomeGrowthPolicy.placeLandPlot("plot.two", in: &history.season))

        let positions = try! XCTUnwrap(history.season.landPlotPlacements)
        XCTAssertEqual(positions.count, 2)
        XCTAssertEqual(
            abs(positions[0].x - positions[1].x) + abs(positions[0].y - positions[1].y),
            1
        )
    }
}
