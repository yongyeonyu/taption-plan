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
                       ["sleep", "movement", "study", "work", "exercise", "hobby", "distance", "places", "trips", "steps", "photos", "walkDistance", "carDistance", "transitDistance", "awayTime", "stepDistance", "calories", "income", "expense"])
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
        XCTAssertEqual(history.season.level, MapHomeGrowthPolicy.dailyLevel(for: date(2026, 9, 20), calendar: calendar), "레벨은 날짜로만 정해진다(HOM1111A01)")
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
        XCTAssertEqual(history.season.level, MapHomeGrowthPolicy.dailyLevel(for: date(2026, 9, 26), calendar: calendar))
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
        XCTAssertEqual(history.season.level, MapHomeGrowthPolicy.dailyLevel(for: date(2026, 9, 20), calendar: calendar))
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
        XCTAssertEqual(history.archives.first?.level, 1, "보상은 레벨을 올리지 않는다")
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

        XCTAssertEqual(history.season.level, 7, "1월 7일은 7레벨")
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
                XCTAssertEqual(image.size, CGSize(width: 36, height: 36), name)
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

    /// 대표 기준: 적어도 이틀에 한 번은 눈에 띄게 바뀐다. 더 엄격하게 하루 차이로 검사한다.
    func testAdjacentEvolutionArtworkChangesVisibly() {
        let side = 48
        func pixels(level: Int) -> [UInt8]? {
            guard let image = UIImage(named: MapHomeGrowthPolicy.artworkName(level: level), in: Bundle.main, with: nil),
                  let context = CGContext(
                    data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return nil }
            context.setFillColor(red: 0.992, green: 0.973, blue: 0.925, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            UIGraphicsPushContext(context)
            context.translateBy(x: 0, y: CGFloat(side))
            context.scaleBy(x: 1, y: -1)
            image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
            UIGraphicsPopContext()
            guard let data = context.data else { return nil }
            return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: side * side * 4))
        }
        func changedShare(_ a: [UInt8], _ b: [UInt8]) -> Double {
            var changed = 0
            for i in stride(from: 0, to: a.count, by: 4) {
                let delta = abs(Int(a[i]) - Int(b[i])) + abs(Int(a[i + 1]) - Int(b[i + 1])) + abs(Int(a[i + 2]) - Int(b[i + 2]))
                if delta > 60 { changed += 1 }
            }
            return Double(changed) / Double(side * side)
        }
        var previous: [UInt8]?
        for level in 1...366 {
            guard let current = pixels(level: level) else {
                XCTFail("Cannot render level \(level)")
                continue
            }
            if let previous {
                let share = changedShare(previous, current)
                XCTAssertGreaterThanOrEqual(share, 0.08, "Lv.\(level - 1)→\(level) 그림 차이 \(share)")
            }
            previous = current
        }
    }

    /// HOM1111A01: 집은 날마다 레벨업하고 새해에 1로 돌아간다. 달성 여부와 상관없다.
    func testHomeLevelIsTheDayOfTheYear() {
        XCTAssertEqual(MapHomeGrowthPolicy.dailyLevel(for: date(2026, 1, 1), calendar: calendar), 1)
        XCTAssertEqual(MapHomeGrowthPolicy.dailyLevel(for: date(2026, 11, 11), calendar: calendar), 315)
        XCTAssertEqual(MapHomeGrowthPolicy.dailyLevel(for: date(2026, 12, 31), calendar: calendar), 365)
        XCTAssertEqual(MapHomeGrowthPolicy.dailyLevel(for: date(2028, 12, 31), calendar: calendar), 366)
        var history = MapHomeGrowthHistory.initial(for: date(2026, 11, 10), calendar: calendar)
        MapHomeGrowthPolicy.observeCurrentDay(in: &history, date: date(2026, 11, 11), qualified: false, calendar: calendar)
        XCTAssertEqual(history.season.level, 315, "a day without records still levels up")
        XCTAssertEqual(MapHomeGrowthPolicy.level(on: date(2026, 3, 1), in: history, calendar: calendar, now: date(2026, 11, 11)), 60)
        // LVL1111A01: 미래 날짜는 오늘 레벨이다.
        XCTAssertEqual(MapHomeGrowthPolicy.level(on: date(2026, 12, 25), in: history, calendar: calendar, now: date(2026, 11, 11)), 315)
        XCTAssertEqual(MapHomeGrowthPolicy.level(on: date(2026, 11, 11), in: history, calendar: calendar, now: date(2026, 11, 11)), 315)
        MapHomeGrowthPolicy.observeCurrentDay(in: &history, date: date(2027, 1, 1), qualified: true, calendar: calendar)
        XCTAssertEqual(history.season.level, 1, "new year resets to 1")
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

    func testEveryLandmarkHasItsAccessoryArtworkAndOldAccessoryFallsBackToSymbol() {
        let candidates = MapHomeLandmarkCatalog.candidates
        XCTAssertEqual(candidates.count, 52)
        XCTAssertEqual(candidates.filter { $0.accessoryKind == .hat }.count, 17)
        XCTAssertEqual(candidates.filter { $0.accessoryKind == .scarf }.count, 17)
        XCTAssertEqual(candidates.filter { $0.accessoryKind == .ribbon }.count, 18)
        for candidate in candidates {
            let name = MapHomeGrowthAccessoryCatalog.artworkName(for: candidate.accessoryID)
            XCTAssertNotNil(name.flatMap { UIImage(named: $0) }, candidate.id)
            XCTAssertEqual(HwarangClothStyle.byLandmark[candidate.id] == nil, candidate.accessoryKind == .hat, candidate.id)
        }
        XCTAssertNil(MapHomeGrowthAccessoryCatalog.artworkName(for: "cat.accessory.001"))
        XCTAssertNotNil(MapHomeGrowthAccessoryCatalog.symbol(for: "cat.accessory.001"))
    }

    /// 착용 칸이 하나이던 옛 저장값이 그 장식의 종류 칸으로 옮겨진다(ACC1102A01).
    func testOldEquippedAccessoryMovesToItsKindSlot() throws {
        func decode(_ extra: String) throws -> MapHomeGrowthSeason {
            try JSONDecoder().decode(MapHomeGrowthSeason.self, from: Data("{\"year\":2026,\"accessories\":[]\(extra)}".utf8))
        }
        let hat = try decode(#","equippedAccessory":"cat.accessory.kr.namsan""#)
        XCTAssertEqual(hat.equippedHat, "cat.accessory.kr.namsan")
        XCTAssertEqual(hat.equippedAccessory, "cat.accessory.kr.namsan")
        // 예전에 모자로 받은 장식이 이제 스카프·리본이 되어도 같은 id로 이어진다.
        let scarf = try decode(#","equippedAccessory":"cat.accessory.jp.itsukushima""#)
        XCTAssertNil(scarf.equippedHat)
        XCTAssertEqual(scarf.equippedScarf, "cat.accessory.jp.itsukushima")
        let ribbon = try decode(#","equippedAccessory":"cat.accessory.au.opera""#)
        XCTAssertEqual(ribbon.equippedRibbon, "cat.accessory.au.opera")
        // 랜드마크가 없는 옛 id는 머리 칸에 그대로 남아 심볼로 보인다.
        let old = try decode(#","equippedAccessory":"cat.accessory.001""#)
        XCTAssertEqual(old.equippedHat, "cat.accessory.001")
        XCTAssertNil(try decode("").equippedAccessory)
        // 새 칸이 있으면 옛 값은 보지 않는다.
        let both = try decode(#","equippedAccessory":"cat.accessory.kr.namsan","equippedRibbon":"cat.accessory.au.opera""#)
        XCTAssertNil(both.equippedHat)
        XCTAssertEqual(both.equippedRibbon, "cat.accessory.au.opera")
        // 다시 저장하면 새 칸으로 남고 옛 키는 없어진다.
        let encoded = try JSONEncoder().encode(scarf)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["equippedAccessory"])
        XCTAssertEqual(try JSONDecoder().decode(MapHomeGrowthSeason.self, from: encoded), scarf)
    }

    func testOneAccessoryPerKindIsWornTogether() throws {
        var season = MapHomeGrowthSeason(year: 2026)
        let hat = "cat.accessory.kr.namsan", otherHat = "cat.accessory.jp.fuji"
        let scarf = "cat.accessory.fr.alps", ribbon = "cat.accessory.au.opera"
        season.accessories = [hat, otherHat, scarf, ribbon]
        for id in [hat, scarf, ribbon] { XCTAssertTrue(MapHomeGrowthPolicy.equipAccessory(id, in: &season)) }
        let outfit = try XCTUnwrap(season.equippedAccessory)
        XCTAssertEqual(MapHomeGrowthAccessoryCatalog.hatAssetName(for: outfit), "Hat_kr_namsan")
        XCTAssertEqual(MapHomeGrowthAccessoryCatalog.scarfStyle(for: outfit), HwarangClothStyle.byLandmark["fr.alps"])
        XCTAssertEqual(MapHomeGrowthAccessoryCatalog.ribbonStyle(for: outfit), HwarangClothStyle.byLandmark["au.opera"])
        XCTAssertTrue(season.isEquipped(scarf))
        // 같은 종류를 고르면 그 칸만 바뀐다.
        XCTAssertTrue(MapHomeGrowthPolicy.equipAccessory(otherHat, in: &season))
        XCTAssertFalse(season.isEquipped(hat))
        XCTAssertEqual(MapHomeGrowthAccessoryCatalog.hatAssetName(for: season.equippedAccessory), "Hat_jp_fuji")
        XCTAssertEqual(season.equippedScarf, scarf)
        XCTAssertEqual(season.equippedRibbon, ribbon)
        // 스카프 하나만 입었으면 모자 그림이 없다.
        XCTAssertNil(MapHomeGrowthAccessoryCatalog.hatAssetName(for: scarf))
        XCTAssertNil(MapHomeGrowthAccessoryCatalog.ribbonStyle(for: scarf))
    }

    func testEveryLocationDestinationHasDrawnIcon() {
        XCTAssertEqual(MapHomeLocationDestination.allCases.count, 8)
        for destination in MapHomeLocationDestination.allCases {
            XCTAssertNotNil(UIImage(named: destination.iconAssetName), destination.rawValue)
        }
    }

    func testNoMoreRewardsAfterAllFiftyTwoCollected() {
        var history = MapHomeGrowthHistory(season: MapHomeGrowthSeason(year: 2026))
        history.season.pendingWeeklyRewards = 60
        for candidate in MapHomeLandmarkCatalog.candidates {
            XCTAssertTrue(MapHomeGrowthPolicy.redeemWeeklyReward(
                evolutionID: candidate.id, landPlotID: "plot-\(candidate.id)", accessoryID: candidate.accessoryID, in: &history
            ))
        }
        XCTAssertEqual(history.season.accessories.count, 52)
        XCTAssertEqual(history.season.pendingWeeklyRewards, 0)
        history.season.pendingWeeklyRewards = 1
        XCTAssertFalse(MapHomeGrowthPolicy.redeemWeeklyReward(
            evolutionID: "kr.namsan", landPlotID: "plot-extra", accessoryID: "cat.accessory.kr.namsan", in: &history
        ))
        XCTAssertEqual(history.season.accessories.count, 52)
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

    func testCalendarMonthMemoryKeepsValuesAndEvictsOldestMonth() {
        var memory = MapHomeCalendarMonthMemory(limit: 2)
        let months = (0..<3).map { Date(timeIntervalSince1970: Double($0) * 2_678_400) }
        let day = months[0]

        memory.store(statuses: [day: .complete], for: months[0])
        memory.store(totals: [day: ["work": 60]], for: months[0])
        XCTAssertEqual(memory.statuses(for: months[0]), [day: .complete])
        XCTAssertEqual(memory.totals(for: months[0]), [day: ["work": 60]])

        memory.store(statuses: [:], for: months[1])
        memory.store(statuses: [:], for: months[2])
        XCTAssertTrue(memory.statuses(for: months[0]).isEmpty)
        XCTAssertTrue(memory.totals(for: months[0]).isEmpty)
    }

    func testCalendarMonthMemoryComputesMonthValuesOnce() {
        var memory = MapHomeCalendarMonthMemory()
        let month = Date(timeIntervalSince1970: 0)
        var calls = 0

        for _ in 0..<3 {
            _ = memory.days(for: month) { calls += 1; return [nil, month] }
            _ = memory.title(for: month, key: "ko") { calls += 1; return "1월" }
            _ = memory.dayInfo(for: month, in: month) {
                calls += 1
                return .init(day: 1, weekday: 5, holiday: nil)
            }
        }
        XCTAssertEqual(calls, 3)
        // 언어가 바뀌면 제목은 다시 만든다.
        XCTAssertEqual(memory.title(for: month, key: "en") { "Jan" }, "Jan")
    }

    func testCounterDetailSnapshotKeepsFirstValueUntilCleared() {
        let snapshot = MapHomeCounterDetailSnapshot()
        var calls = 0
        let make: () -> MapHomeCounterDetailSnapshot.Value = {
            calls += 1
            return .init(contents: [], initialIndex: calls, dateText: "")
        }

        XCTAssertEqual(snapshot.value(for: .salary, make: make).initialIndex, 1)
        XCTAssertEqual(snapshot.value(for: .salary, make: make).initialIndex, 1)
        XCTAssertEqual(snapshot.value(for: .kind(.steps), make: make).initialIndex, 2)
        snapshot.clear()
        XCTAssertEqual(snapshot.value(for: .kind(.steps), make: make).initialIndex, 3)
    }

    @MainActor
    func testDateBadgeInfoFollowsDateAndHoliday() {
        var seoul = Calendar(identifier: .gregorian)
        seoul.timeZone = .current
        let newYear = seoul.date(from: DateComponents(year: 2027, month: 1, day: 1))!
        let info = MapHomeDateBadgeInfo.resolve(date: newYear, localeIdentifier: "ko_KR")
        XCTAssertEqual(info.day, 1)
        XCTAssertEqual(info.weekday, 6)
        XCTAssertEqual(info.weekdayText, "금")
        XCTAssertTrue(info.isHoliday)

        let next = seoul.date(byAdding: .day, value: 4, to: newYear)!
        let other = MapHomeDateBadgeInfo.resolve(date: next, localeIdentifier: "en_US")
        XCTAssertEqual(other.day, 5)
        XCTAssertEqual(other.weekdayText, "Tue")
        XCTAssertFalse(other.isHoliday)
    }
}
