import SwiftUI
import XCTest
import UIKit
import CoreLocation
import StoreKit
import StoreKitTest
import TaptionPlanCore
@testable import TaptionPlan

@MainActor
final class MapHomeStickmanTests: XCTestCase {
    private var testStart = Date()

    override func setUp() {
        super.setUp()
        testStart = Date()
    }

    /// 무거운 시험이 이어지면 iOS CPU 한도(60초 80%)에 걸려 앱이 죽는다. 쓴 시간의 절반을 쉬고 다음으로 간다.
    override func tearDown() {
        Thread.sleep(forTimeInterval: min(30, Date().timeIntervalSince(testStart) * 0.5))
        super.tearDown()
    }

    func testCounterFoldTaps() {
        let frame = CGRect(x: 0, y: 100, width: 200, height: 122)
        XCTAssertEqual(MapHomeCounterFold.tap(atY: 110, frame: frame, isCollapsed: true), .expand)
        XCTAssertEqual(MapHomeCounterFold.tap(atY: 215, frame: frame, isCollapsed: false), .collapse)
        XCTAssertEqual(
            MapHomeCounterFold.tap(atY: 150, frame: frame, isCollapsed: false),
            .rows(CGRect(x: 0, y: 100, width: 200, height: 100)), "화살표 자리는 줄 높이에서 뺀다"
        )
    }

    func testCategoryMenuShowsDailyDetailsWithOwnScenes() {
        XCTAssertTrue(MapHomeCategoryDetailRows.details(for: "sleep").map(\.title).contains("낮잠"))
        XCTAssertTrue(MapHomeCategoryDetailRows.details(for: "unconfirmed").isEmpty)
        XCTAssertEqual(MapHomeStickmanActionResolver.action(for: "sleep.nap", label: "낮잠"), .nap)
        XCTAssertEqual(MapHomeStickmanActionResolver.action(for: "eating.cooking", label: "요리"), .cooking)
    }

    /// `TAPTION_RIG_SHEET=<폴더>`일 때 그루밍 장면을 시트 한 장으로 쓴다. 자세를 눈으로 보려는 도구다.
    /// 장면 22종을 각 8프레임씩 그린 검토 시트. 장식을 걸친 큰 그림·지도 마커 크기 그림·장식 도감을 쓴다(ACC1102A01).
    /// 위젯 에셋을 다시 만든다. `TAPTION_POSE_ATLAS=<TaptionPlanWidget/Assets.xcassets 경로>`로 켠다.
    func testWritePoseAtlasWhenRequested() throws {
        guard let root = ProcessInfo.processInfo.environment["TAPTION_POSE_ATLAS"], !root.isEmpty else {
            throw XCTSkip("TAPTION_POSE_ATLAS 없음")
        }
        let cell = TaptionHwarangPose.cellPixels, poses = TaptionHwarangPose.allCases
        for style in HwarangCoat.characters {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = false
            let size = CGSize(width: cell.width * TaptionHwarangPose.frameCount, height: cell.height * poses.count)
            let atlas = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                for pose in poses {
                    for column in 0..<TaptionHwarangPose.frameCount {
                        HwarangDiagnostics.poseFrame(pose, column: column, style: style)
                            .draw(at: CGPoint(x: column * cell.width, y: pose.row * cell.height))
                    }
                }
            }
            let folder = URL(fileURLWithPath: root).appendingPathComponent(TaptionHwarangPose.assetName(style: style) + ".imageset")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try XCTUnwrap(atlas.pngData()).write(to: folder.appendingPathComponent("atlas.png"))
            let contents = #"{"images":[{"filename":"atlas.png","idiom":"universal"}],"info":{"author":"xcode","version":1}}"#
            try Data(contents.utf8).write(to: folder.appendingPathComponent("Contents.json"))
        }
    }

    func testEveryClassificationHasEnglishTitleWithoutChangingStoredTitle() {
        for category in RecordClassificationCatalog.categories {
            XCTAssertNotNil(category.englishTitle, category.id)
            for detail in category.details {
                XCTAssertNotNil(detail.englishTitle, detail.id)
                XCTAssertEqual(detail.localizedTitle(.korean), detail.title)
            }
        }
        XCTAssertEqual(RecordClassificationCatalog.localizedDetailTitle("회의", language: .korean), "회의")
        XCTAssertEqual(RecordClassificationCatalog.localizedDetailTitle("내가 만든 이름", language: .english), "내가 만든 이름")
    }

    func testWorkAndStudyUseDeskPoses() {
        XCTAssertEqual(TaptionHwarangPose.resolve(categoryID: "work", title: "업무"), .workDesk)
        XCTAssertEqual(TaptionHwarangPose.resolve(categoryID: "work", title: "걷기"), .laptopWalk)
        XCTAssertEqual(TaptionHwarangPose.resolve(categoryID: "work", title: "회의"), .meeting)
        XCTAssertEqual(TaptionHwarangPose.resolve(categoryID: "study", title: "공부"), .studyDesk)
        XCTAssertEqual(TaptionHwarangPose.resolve(categoryID: "work", title: "휴식"), .restCroissant)
        XCTAssertNil(TaptionHwarangPose.resolve(categoryID: "movement", title: "걷기"))
    }

    func testRailCategoryDecidesActionWhileStaying() {
        let eating = MapHomeTimeRailSegment(startMinute: 1_070, endMinute: 1_092, categoryID: "eating", title: "식사")
        XCTAssertEqual(MapHomeStickmanActionResolver.railAction(segment: eating, details: []), .eating)
        let work = MapHomeTimeRailSegment(startMinute: 600, endMinute: 700, categoryID: "work", title: "업무")
        let meeting = MapHomeSectionDetail(id: UUID(), title: "회의", categoryID: "work", behavior: nil, startMinute: 610, endMinute: 650, provenance: nil)
        XCTAssertEqual(MapHomeStickmanActionResolver.railAction(segment: work, details: [meeting]), MapHomeStickmanActionResolver.action(for: "work", label: "회의"))
        let moving = MapHomeTimeRailSegment(startMinute: 0, endMinute: 10, categoryID: "movement", title: "걷기")
        XCTAssertNil(MapHomeStickmanActionResolver.railAction(segment: moving, details: []))
        XCTAssertNil(MapHomeStickmanActionResolver.railAction(segment: nil, details: []))
    }

    /// Watch 위젯 그림을 만든다. `TAPTION_WATCH_CATS=<폴더>`일 때만 돈다(WCH1105A03).
    func testWriteWatchCatSpritesWhenRequested() throws {
        guard let root = ProcessInfo.processInfo.environment["TAPTION_WATCH_CATS"], !root.isEmpty else {
            throw XCTSkip("TAPTION_WATCH_CATS 없음")
        }
        let scenes: [(String, HwarangScene, Double)] = [
            ("Work", .work, 1.8), ("Study", .study, 1.8), ("Sleep", .sleep, 2), ("Eat", .eat, 7),
            ("Walk", .walkLoop, 1), ("Run", .runLoop, 1), ("Hobby", .yarn, 1.2), ("Rest", .restLoaf, 1),
            ("Check", .confused, 1),
        ]
        let poses = TaptionHwarangPose.allCases.map { pose -> (String, HwarangScene, Double) in
            let scene = HwarangDiagnostics.scene(for: pose)
            return (pose.rawValue, scene, Double(scene.totalDuration) * 0.37)
        }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        for style in HwarangCoat.characters {
            for (name, scene, sec) in scenes + poses {
                let image = HwarangDiagnostics.watchSprite(scene: scene, sec: sec, style: style)
                let file = URL(fileURLWithPath: root).appendingPathComponent("\(style)-\(name).png")
                try XCTUnwrap(image.pngData()).write(to: file)
            }
        }
    }

    /// 캐릭터 검토 시트(CHR1103A01). 화랑이·춘향이·윤복이를 같은 장면으로 나란히 그린다.
    func testWriteCharacterSheetWhenRequested() throws {
        guard let folder = ProcessInfo.processInfo.environment["TAPTION_CHARACTER_SHEET"], !folder.isEmpty else {
            throw XCTSkip("TAPTION_CHARACTER_SHEET 없음")
        }
        let scenes: [(HwarangScene, Double)] = [(.stroll, 1.2), (.eat, 7), (.work, 2), (.friends, 2), (.sleep, 2), (.recoverySuperman, 1), (.restBox, 1), (.medicated, 1)]
        let side: CGFloat = 300
        let image = UIGraphicsImageRenderer(size: CGSize(width: side * CGFloat(scenes.count), height: side * 3)).image { renderer in
            UIColor(white: 0.93, alpha: 1).setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: side * CGFloat(scenes.count), height: side * 3))
            for (row, style) in HwarangCoat.characters.enumerated() {
                for (column, item) in scenes.enumerated() {
                    HwarangDiagnostics.frame(scene: item.0, sec: item.1, side: side, coat: .named(style))
                        .draw(at: CGPoint(x: CGFloat(column) * side, y: CGFloat(row) * side))
                }
            }
        }
        try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: folder).appendingPathComponent("characters.png"))
        let car = UIGraphicsImageRenderer(size: CGSize(width: side * 3, height: side)).image { _ in
            for (column, sec) in [0.5, 1.5, 3.0].enumerated() {
                HwarangDiagnostics.frame(scene: .carFront, sec: sec, side: side).draw(at: CGPoint(x: CGFloat(column) * side, y: 0))
            }
        }
        try XCTUnwrap(car.pngData()).write(to: URL(fileURLWithPath: folder).appendingPathComponent("car.png"))
    }

    func testUnusedAnimationsReachCustomCategories() throws {
        let category = MapUserActivityCategory(id: UUID(), title: "산책", systemImage: "leaf.fill", hex: "#29A383", animation: .mapReading)
        defer { MapHomeCustomAnimations.register([]) }
        MapHomeCustomAnimations.register([category])
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let actual = ActualRecord(planID: nil, title: "산책", categoryID: "custom:\(category.id.uuidString)", startedAt: start, endedAt: start.addingTimeInterval(600), source: .manual)
        XCTAssertEqual(MapHomeStickmanActionResolver.action(at: start.addingTimeInterval(60), actuals: [actual], travel: [], places: [], frequentPlaces: []), .mapReading)
        XCTAssertEqual(MapHomeStickmanAction.mapReading.hwarangScene, .atlas)
        let old = try JSONDecoder().decode(MapUserActivityCategory.self, from: Data(##"{"id":"\##(UUID().uuidString)","title":"옛","systemImage":"leaf.fill","hex":"#29A383"}"##.utf8))
        XCTAssertNil(old.animation, "옛 설정도 읽는다")
    }

    func testMenuQuoteChangesWeekly() throws {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul") ?? .current
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 2)))
        let week = MapHomeMenuHeaderTitle.quote(on: start, calendar: calendar).text
        XCTAssertEqual(MapHomeMenuHeaderTitle.quote(on: start.addingTimeInterval(86_400 * 3), calendar: calendar).text, week)
        XCTAssertNotEqual(MapHomeMenuHeaderTitle.quote(on: start.addingTimeInterval(86_400 * 7), calendar: calendar).text, week)
    }

    func testDictationFollowsDeviceLanguageWhenAutomatic() {
        XCTAssertEqual(MapHomeDictation.matchedSpeechLocale(preferred: "ja-KR", supported: ["en-US", "ja-JP", "ko-KR"]), "ja-JP")
        XCTAssertEqual(MapHomeDictation.matchedSpeechLocale(preferred: "ko-KR", supported: ["en-US", "ko-KR"]), "ko-KR")
        XCTAssertEqual(MapHomeDictation.matchedSpeechLocale(preferred: "xx-YY", supported: ["en-US"]), "en-US")
        XCTAssertEqual(MapHomeDictation.languageName(forLocale: "ko-KR"), "한국어")
    }

    func testUnconfirmedPawsFollowAverageSpeed() throws {
        let line = [CLLocationCoordinate2D(latitude: 37.5, longitude: 127), CLLocationCoordinate2D(latitude: 37.51, longitude: 127)]
        let speed = try XCTUnwrap(MapHomeUnconfirmedPaws.speed(points: line, seconds: 100))
        XCTAssertEqual(speed, 11.1, accuracy: 0.2)
        XCTAssertNil(MapHomeUnconfirmedPaws.speed(points: line, seconds: 0))
    }

    func testLiveActivityPoseFollowsDetailTitle() {
        XCTAssertEqual(TaptionHwarangPose.resolve(categoryID: "health", title: "회복"), .recovery)
        XCTAssertEqual(TaptionHwarangPose.resolve(categoryID: "health", title: "병원"), .hospital)
        XCTAssertEqual(TaptionHwarangPose.resolve(categoryID: "rest", title: "집에서 휴식"), .restBox)
        XCTAssertEqual(TaptionHwarangPose.resolve(categoryID: "work", title: "휴식"), .restCroissant)
        XCTAssertEqual(TaptionHwarangPose.resolve(categoryID: "activity", title: "휴식"), .restStarfish)
        XCTAssertEqual(TaptionHwarangPose.resolve(categoryID: "movement", title: "업무"), nil)
    }

    func testWriteGroomingSheetWhenRequested() throws {
        guard let folder = ProcessInfo.processInfo.environment["TAPTION_RIG_SHEET"], !folder.isEmpty else {
            throw XCTSkip("TAPTION_RIG_SHEET 없음")
        }
        let scarves = ["jp.itsukushima", "fr.alps", "kr.hahoe", "it.amalfi"], ribbons = ["au.opera", "it.dolomites", "th.doi_inthanon", "es.teide"]
        let hats = ["Hat_kr_namsan", "Hat_gb_bigben", "Hat_kr_gyeongbokgung", "Hat_th_grand_palace"]
        func sheet(small: Bool, name: String) throws {
            let side: CGFloat = 220, scenes = HwarangScene.allCases
            let image = UIGraphicsImageRenderer(size: CGSize(width: side * 8, height: side * CGFloat(scenes.count))).image { renderer in
                UIColor(white: 0.92, alpha: 1).setFill()
                renderer.fill(CGRect(x: 0, y: 0, width: side * 8, height: side * CGFloat(scenes.count)))
                for (row, scene) in scenes.enumerated() {
                    let set = row % scarves.count
                    for column in 0..<8 {
                        let sec = Double(scene.totalDuration) * (Double(column) + 0.37) / 8
                        HwarangDiagnostics.frame(
                            scene: scene, sec: sec, side: side, small: small, hat: UIImage(named: hats[set]),
                            scarf: HwarangClothStyle.byLandmark[scarves[set]], ribbon: HwarangClothStyle.byLandmark[ribbons[set]]
                        ).draw(at: CGPoint(x: CGFloat(column) * side, y: CGFloat(row) * side))
                    }
                }
            }
            try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
        }
        try sheet(small: false, name: "accessories-all-scenes.png")
        try sheet(small: true, name: "accessories-small.png")
        let cell: CGFloat = 120, candidates = MapHomeLandmarkCatalog.candidates
        let catalog = UIGraphicsImageRenderer(size: CGSize(width: cell * 9, height: cell * 6)).image { renderer in
            UIColor(white: 0.92, alpha: 1).setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: cell * 9, height: cell * 6))
            for (index, candidate) in candidates.enumerated() {
                guard let art = MapHomeGrowthAccessoryCatalog.artworkName(for: candidate.accessoryID).flatMap({ UIImage(named: $0) }) else { continue }
                art.draw(in: CGRect(x: CGFloat(index % 9) * cell + 6, y: CGFloat(index / 9) * cell + 12, width: cell - 12, height: (cell - 12) * 60 / 68))
            }
        }
        try XCTUnwrap(catalog.pngData()).write(to: URL(fileURLWithPath: folder).appendingPathComponent("accessories-catalog.png"))
        // 그루밍·식사·건강 장면과 꼬리 부풀림을 촘촘히 그린 시트(RIG1103A01). 위 칸은 맨몸, 아래 칸은 장식을 걸쳤다.
        let motionRows: [(HwarangScene, [Double])] = [
            (.groom, [3.5, 4, 5, 6.5, 8, 9.5, 11, 12, 13.5, 15]),
            (.eat, [0.3, 0.6, 0.8, 1, 1.2, 1.4, 1.6, 3.5, 4.5, 6.5]),
            (.eat, [7.6, 8, 8.2, 8.4, 8.6, 9.2, 9.8, 10.3, 10.6, 11.4]),
            (.stretch, [1, 2, 4, 5, 6.5, 7.5, 9, 10, 11, 13]),
            (.yarn, [11.4, 11.8, 11.9, 12, 12.1, 12.2, 12.4, 12.6, 12.8, 12.9]),
            (.wheel, [10.9, 11, 11.1, 11.2, 11.3, 11.4, 11.6, 11.8, 12, 12.2])
        ]
        let scarf = HwarangClothStyle.byLandmark["fr.alps"], ribbon = HwarangClothStyle.byLandmark["au.opera"], hat = UIImage(named: hats[0])
        let side: CGFloat = 220, height = side * CGFloat(motionRows.count * 2)
        let motions = UIGraphicsImageRenderer(size: CGSize(width: side * 10, height: height)).image { renderer in
            UIColor(white: 0.92, alpha: 1).setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: side * 10, height: height))
            for (row, line) in motionRows.enumerated() {
                for (column, sec) in line.1.enumerated() {
                    let x = CGFloat(column) * side, y = CGFloat(row * 2) * side
                    HwarangDiagnostics.frame(scene: line.0, sec: sec, side: side).draw(at: CGPoint(x: x, y: y))
                    HwarangDiagnostics.frame(scene: line.0, sec: sec, side: side, hat: hat, scarf: scarf, ribbon: ribbon).draw(at: CGPoint(x: x, y: y + side))
                }
            }
        }
        try XCTUnwrap(motions.pngData()).write(to: URL(fileURLWithPath: folder).appendingPathComponent("rig-motions.png"))
        // 일상 분류 16장면(RIG1103A02). 한 장면을 4프레임씩 맨몸과 장식 차림으로 그린다.
        let daily = HwarangScene.dailyScenes
        let dailyImage = UIGraphicsImageRenderer(size: CGSize(width: side * 8, height: side * CGFloat(daily.count))).image { renderer in
            UIColor(white: 0.92, alpha: 1).setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: side * 8, height: side * CGFloat(daily.count)))
            for (row, scene) in daily.enumerated() {
                for column in 0..<4 {
                    let sec = Double(column) * 1.37 + 0.31, y = CGFloat(row) * side
                    HwarangDiagnostics.frame(scene: scene, sec: sec, side: side).draw(at: CGPoint(x: CGFloat(column) * side, y: y))
                    HwarangDiagnostics.frame(scene: scene, sec: sec, side: side, hat: hat, scarf: scarf, ribbon: ribbon).draw(at: CGPoint(x: CGFloat(column + 4) * side, y: y))
                }
            }
        }
        try XCTUnwrap(dailyImage.pngData()).write(to: URL(fileURLWithPath: folder).appendingPathComponent("daily-scenes.png"))
    }

    /// 대표 결정 16개 분류(RIG1103A02): (대분류, 제목, behavior, 행동, 장면). 요리는 이미 있던 상세 분류다.
    private static let dailyCategories: [(String, String, String, MapHomeStickmanAction, HwarangScene)] = [
        ("sleep", "낮잠", "nap", .nap, .nap), ("housework", "요리", "cooking", .cooking, .cook),
        ("work", "회의", "meeting", .meeting, .meeting), ("housework", "설거지", "dishes", .dishes, .dishes), ("eating", "커피·티타임", "coffee", .coffee, .coffee),
        ("housework", "장보기", "groceries", .groceries, .groceries), ("housework", "빨래", "laundry", .laundry, .laundry),
        ("activity", "친구 만남", "friends", .friends, .friends), ("activity", "데이트", "dating", .date, .date),
        ("activity", "가족", "family", .family, .family), ("activity", "통화", "phoneCall", .phoneCall, .phoneCall),
        ("health", "명상", "meditation", .meditation, .meditate), ("health", "병원", "hospital", .hospital, .hospital),
        ("health", "미용실", "salon", .salon, .salon), ("hobby", "독서", "reading", .bookReading, .readBook),
        ("hobby", "게임", "gaming", .game, .game), ("hobby", "음악", "music", .music, .music),
        ("hobby", "영상 보기", "video", .video, .video), ("hobby", "반려동물 돌보기", "petCare", .petCare, .petCare)
    ]

    /// 고를 수 있는 상세 분류로 들어 있고, 장면이 서로 다르며, 자동 전용이 아니고, 아이콘이 실제 기호다.
    func testDailyCategoriesAreManualOptionsWithTheirOwnScenes() throws {
        for (category, title, behavior, action, scene) in Self.dailyCategories {
            let option = try XCTUnwrap(RecordClassificationCatalog.options.first { $0.categoryID == category && $0.behavior == behavior }, title)
            XCTAssertEqual(option.title, title)
            XCTAssertFalse(option.isAutomatic, title)
            XCTAssertFalse(option.isAutomaticOnly, title)
            XCTAssertNotNil(UIImage(systemName: option.systemImage), option.systemImage)
            XCTAssertEqual(action.hwarangScene, scene, title)
            XCTAssertTrue(action.animatesPresentation, title)
            XCTAssertFalse(action.isMoving, title)
            XCTAssertEqual(MapHomeStickmanActionResolver.action(for: category, label: title), action, title)
        }
        let others = MapHomeStickmanAction.allCases.filter { candidate in !Self.dailyCategories.contains { $0.3 == candidate } }
        let otherScenes = Set(others.map(\.hwarangScene))
        XCTAssertEqual(Set(Self.dailyCategories.map(\.4)).count, 19)
        XCTAssertTrue(otherScenes.isDisjoint(with: Self.dailyCategories.map(\.4)))
        XCTAssertEqual(Set(HwarangScene.dailyScenes), Set(Self.dailyCategories.map(\.4)))
    }

    /// 새 분류로 저장한 기록은 왕복 뒤에도 대분류와 상세 이름을 잃지 않고 수면·이동 등으로 새지 않는다.
    func testDailyCategoryRecordsRoundTripWithoutChangingCategory() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for (category, title, behavior, action, _) in Self.dailyCategories {
            for source in [ActualSource.manual, .appleWatch] {
                var record = ActualRecord(planID: nil, title: title, categoryID: category, startedAt: start, endedAt: start.addingTimeInterval(600), source: source)
                record.behavior = behavior
                let decoded = try JSONDecoder().decode(ActualRecord.self, from: JSONEncoder().encode(record))
                XCTAssertEqual(decoded, record, title)
                // 자동 기록의 낮잠 글자는 지금처럼 수면으로 분석한다. 직접 고른 낮잠만 건강관리에 남는다.
                if title == "낮잠", source != .manual {
                    XCTAssertEqual(RecordAnalysisCategoryPolicy.categoryID(for: decoded), "sleep")
                    continue
                }
                XCTAssertEqual(ActualRecordCategoryResolver.categoryID(for: decoded), category, title)
                XCTAssertEqual(RecordAnalysisCategoryPolicy.categoryID(for: decoded), category, title)
                XCTAssertEqual(RecordAnalysisCategoryNormalizer.categoryID(for: category, title: title, behavior: behavior), category, title)
                XCTAssertEqual(RecordAnalysisCategoryPolicy.detailTitle(for: decoded), title)
                XCTAssertEqual(MapHomeStickmanActionResolver.action(
                    at: start.addingTimeInterval(60), actuals: [decoded], travel: [], places: [], frequentPlaces: []
                ), action, title)
            }
        }
    }

    /// v3 분류표의 항목과 그 항목으로 저장된 지난 기록은 v4에서도 그대로다.
    func testPreviousTaxonomyEntriesAndOldRecordsAreUnchanged() throws {
        let v3: [String: [(String, String)]] = [
            "activity": [("activity.rest", "stationary")],
            "work": [("work.rest", "stationary"), ("work.walking", "walking")],
            "study": [("study.academy", "academy"), ("study.rest", "stationary"), ("study.walking", "walking")],
            "hobby": [("hobby.route", "hobby"), ("hobby.rest", "stationary")],
            "sleep": [("sleep.core", "core"), ("sleep.deep", "deep"), ("sleep.rem", "rem")],
            "eating": [("eating.meal", "meal")],
            "exercise": [("exercise.workout", "exercise")],
            "health": [("health.recovery", "recovery"), ("health.medication", "medication")],
            "housework": [("housework.chores", "chores")],
            "unconfirmed": [("unconfirmed.automatic", "unconfirmed")]
        ]
        XCTAssertEqual(RecordClassificationCatalog.categoryIDs, ["activity", "work", "study", "hobby", "sleep", "movement", "eating", "exercise", "health", "housework", "unconfirmed"])
        for (category, details) in v3 {
            let current = try XCTUnwrap(RecordClassificationCatalog.categories.first { $0.id == category })
            for (id, behavior) in details {
                XCTAssertEqual(current.details.first { $0.id == id }?.behavior, behavior, id)
            }
        }
        // 전에 있던 자동 전용 표시는 그대로이고, 건강 대분류 자체를 직접 고를 수도 없다.
        XCTAssertEqual(RecordClassificationCatalog.options.first { $0.id == "phase.health" }?.isAutomaticOnly, true)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let old: [(String, String, String?, MapHomeStickmanAction)] = [
            ("sleep", "수면", "core", .sleeping), ("hobby", "취미", nil, .hobby), ("health", "회복", "recovery", .recovery),
            ("activity", "휴식", "stationary", .restStarfish), ("housework", "집안일", "chores", .housework), ("eating", "식사", "meal", .eating)
        ]
        for (category, title, behavior, action) in old {
            var record = ActualRecord(planID: nil, title: title, categoryID: category, startedAt: start, endedAt: start.addingTimeInterval(600), source: .manual)
            record.behavior = behavior
            XCTAssertEqual(RecordAnalysisCategoryPolicy.categoryID(for: record), category)
            XCTAssertEqual(MapHomeStickmanActionResolver.action(at: start.addingTimeInterval(60), actuals: [record], travel: [], places: [], frequentPlaces: []), action, title)
        }
    }

    /// 집안일은 활동에서 빠져 자기 대분류에만 있고 장보기는 그 아래로 옮겼다(HWK1103A01).
    func testRestAndHealthDetailsHaveTheirOwnPoses() {
        let expected: [(String, String, MapHomeStickmanAction, HwarangScene)] = [
            ("activity.rest", "휴식", .restStarfish, .restStarfish),
            ("work.rest", "휴식", .restCroissant, .restCroissant),
            ("study.rest", "휴식", .restDonut, .restDonut),
            ("hobby.rest", "휴식", .restLoaf, .restLoaf),
            ("health.recovery", "회복", .recovery, .recoverySuperman),
            ("health.medication", "투약", .medication, .medicated)
        ]
        for (category, title, action, scene) in expected {
            XCTAssertEqual(MapHomeStickmanActionResolver.action(for: category, label: title), action, category)
            XCTAssertEqual(action.hwarangScene, scene)
            XCTAssertGreaterThan(HwarangDiagnostics.paintedPixels(scene: scene, sec: 1), 1_000, category)
        }
        XCTAssertGreaterThan(HwarangDiagnostics.paintedPixels(scene: .hospital, sec: 1), 1_000)
        XCTAssertGreaterThan(HwarangDiagnostics.paintedPixels(scene: .restBox, sec: 1), 1_000)
        XCTAssertEqual(MapHomeStickmanAction.restBox.hwarangScene, .restBox)
    }

    /// 업무 걷기만 노트북을 끼고 걷는다. 실제 이동 구간과 이동 분류는 일반 걷기다(ANI1104A01).
    func testWorkWalkingCarriesALaptop() {
        XCTAssertEqual(MapHomeStickmanActionResolver.action(for: "work.walking", label: "걷기"), .workWalking)
        XCTAssertEqual(MapHomeStickmanActionResolver.action(for: "work", label: "걷기"), .workWalking)
        XCTAssertEqual(MapHomeStickmanActionResolver.action(for: "work", label: "업무"), .computer)
        XCTAssertEqual(MapHomeStickmanActionResolver.action(for: "movement.walking", label: "걷기"), .walking)
        XCTAssertEqual(MapHomeStickmanActionResolver.action(for: TravelMode.walking), .walking)
        XCTAssertEqual(MapHomeStickmanAction.workWalking.hwarangScene, .walkLaptop)
        XCTAssertEqual(MapHomeStickmanAction.workWalking.markerScene(speedMetersPerSecond: 3, showsVehicles: true), .walkLaptop)
        XCTAssertTrue(MapHomeStickmanAction.workWalking.animatesPresentation)
        XCTAssertFalse(MapHomeStickmanAction.workWalking.isMoving)

        let start = Date(timeIntervalSinceReferenceDate: 800_200_000), at = start.addingTimeInterval(60)
        func actual(_ source: ActualSource) -> ActualRecord {
            ActualRecord(planID: nil, title: "걷기", categoryID: "work", startedAt: start, endedAt: start.addingTimeInterval(600), source: source, behavior: "walking")
        }
        let travel = TravelSegment(mode: .walking, span: TimeSpan(start: start, end: start.addingTimeInterval(600)), distanceMeters: 500, confidence: .high, evidence: [])
        func action(_ record: ActualRecord, _ segments: [TravelSegment]) -> MapHomeStickmanAction {
            MapHomeStickmanActionResolver.action(at: at, actuals: [record], travel: segments, places: [], frequentPlaces: [])
        }
        XCTAssertEqual(action(actual(.motion), []), .workWalking)
        XCTAssertEqual(action(actual(.motion), [travel]), .walking, "자동 기록은 실제 이동 구간을 따른다")
        XCTAssertEqual(action(actual(.manual), [travel]), .workWalking, "직접 고른 분류는 그대로 보여 준다")
    }

    /// 업무 휴식: 머리가 천천히 떨어졌다 깜짝 들리고, 앞에 모니터가 있다(ANI1104A01).
    func testWorkBreakDozesInFrontOfAMonitor() {
        XCTAssertEqual(dozeDroop(0), 0)
        XCTAssertLessThan(dozeDroop(2), dozeDroop(3))
        XCTAssertLessThan(dozeDroop(3), dozeDroop(4))
        XCTAssertEqual(dozeDroop(4.9), 1)
        XCTAssertLessThan(dozeDroop(5.3), 0, "0.2초 만에 들려 살짝 젖힌다")
        XCTAssertFalse(HwarangScene.restCroissant.drawsLyingBody)
        for sec in [0.5, 2.0, 4.9, 5.4] {
            XCTAssertTrue(HwarangDiagnostics.isPainted(scene: .restCroissant, sec: sec, at: CGPoint(x: 125, y: 50)), "\(sec)초 화면")
            XCTAssertTrue(HwarangDiagnostics.isPainted(scene: .restCroissant, sec: sec, at: CGPoint(x: 112, y: 89)), "\(sec)초 책상")
        }
        // 위젯 그림을 다시 뽑아도 칸 안에 온전히 그려진다.
        for style in HwarangCoat.characters {
            for column in 0..<TaptionHwarangPose.frameCount {
                XCTAssertEqual(HwarangDiagnostics.poseFrame(.restCroissant, column: column, style: style).size.width, CGFloat(TaptionHwarangPose.cellPixels.width))
            }
        }
    }

    /// 업무 장면 검토 시트(ANI1104A01). 세 털색의 8프레임과 장식·작은 크기를 함께 그린다.
    func testWriteWorkAnimationSheetWhenRequested() throws {
        guard let folder = ProcessInfo.processInfo.environment["TAPTION_WORK_SHEET"], !folder.isEmpty else {
            throw XCTSkip("TAPTION_WORK_SHEET 없음")
        }
        let scarf = HwarangClothStyle.byLandmark["fr.alps"], ribbon = HwarangClothStyle.byLandmark["au.opera"]
        let hat = UIImage(named: "Hat_kr_gyeongbokgung")
        let side: CGFloat = 240, frames = 8
        let times: [HwarangScene: [Double]] = [
            .restCroissant: [0.2, 1.5, 2.6, 3.6, 4.6, 5.0, 5.25, 5.6],
            .walkLaptop: (0..<frames).map { Double($0) * 1.3 / Double(frames) }
        ]
        for (name, scene) in [("doze", HwarangScene.restCroissant), ("laptop", .walkLaptop)] {
            let rows = HwarangCoat.characters.count + 2
            let size = CGSize(width: side * CGFloat(frames), height: side * CGFloat(rows))
            let image = UIGraphicsImageRenderer(size: size).image { renderer in
                UIColor(white: 0.93, alpha: 1).setFill()
                renderer.fill(CGRect(origin: .zero, size: size))
                for (column, sec) in (times[scene] ?? []).enumerated() {
                    let x = CGFloat(column) * side
                    for (row, style) in HwarangCoat.characters.enumerated() {
                        HwarangDiagnostics.frame(scene: scene, sec: sec, side: side, coat: .named(style)).draw(at: CGPoint(x: x, y: CGFloat(row) * side))
                    }
                    HwarangDiagnostics.frame(scene: scene, sec: sec, side: side, hat: hat, scarf: scarf, ribbon: ribbon, coat: .named("calico")).draw(at: CGPoint(x: x, y: 3 * side))
                    HwarangDiagnostics.frame(scene: scene, sec: sec, side: side, small: true, scarf: scarf, ribbon: ribbon, coat: .named("mackerel")).draw(at: CGPoint(x: x, y: 4 * side))
                }
            }
            try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
    }

    func testSleepStagesPickTheirOwnScenes() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func segment(_ stage: SleepStage, _ minute: Double) -> SleepSegment {
            SleepSegment(stage: stage, span: TimeSpan(start: start.addingTimeInterval(minute * 60), end: start.addingTimeInterval((minute + 10) * 60)), sourceName: "Apple Watch")
        }
        let session = SleepSession(
            id: UUID(), span: TimeSpan(start: start, end: start.addingTimeInterval(1_800)),
            asleepDuration: 1_800, awakeDuration: 0, inBedDuration: 1_800, stageDurations: [:],
            sourceNames: ["Apple Watch"], segments: [segment(.core, 0), segment(.deep, 10), segment(.rem, 20)]
        )
        func action(_ minute: Double) -> MapHomeStickmanAction {
            MapHomeStickmanActionResolver.sleepStageAction(at: start.addingTimeInterval(minute * 60 + 30), actuals: [], sleepSessions: [session])
        }
        XCTAssertEqual(action(0), .sleeping)
        XCTAssertEqual(action(10), .deepSleep)
        XCTAssertEqual(action(20), .remSleep)
        XCTAssertEqual(MapHomeStickmanAction.deepSleep.hwarangScene, .sleepBelly)
        XCTAssertEqual(MapHomeStickmanAction.remSleep.hwarangScene, .sleepEyeMask)
        XCTAssertEqual(MapHomeStickmanActionResolver.action(for: "sleep.deep", label: "깊은 수면"), .deepSleep)
        XCTAssertEqual(MapHomeStickmanActionResolver.action(for: "sleep.rem", label: "REM 수면"), .remSleep)
        XCTAssertEqual(MapHomeStickmanActionResolver.action(for: "sleep.core", label: "코어 수면"), .sleeping)
        for scene in [HwarangScene.sleepBelly, .sleepEyeMask] {
            XCTAssertGreaterThan(HwarangDiagnostics.paintedPixels(scene: scene, sec: 1), 1_000)
        }
    }

    func testHouseworkAndGroceriesLiveUnderHousework() {
        let activity = MapHomeCategoryDetailRows.details(for: "activity").map(\.title)
        XCTAssertFalse(activity.contains("집안일"))
        XCTAssertFalse(activity.contains("장보기"))
        XCTAssertEqual(MapHomeCategoryDetailRows.details(for: "housework").map(\.title), ["집안일", "빨래", "장보기", "요리", "설거지"])
        XCTAssertEqual(MapHomeCategoryDetailRows.details(for: "eating").map(\.title), ["식사", "커피·티타임"])
        XCTAssertTrue(activity.contains("샤워"))
        XCTAssertFalse(RecordClassificationCatalog.categoryIDs.contains("shower"))
        XCTAssertEqual(MapHomeCategoryDetailRows.details(for: "work").map(\.title).contains("회의"), true)
        XCTAssertEqual(MapHomeStickmanActionResolver.action(for: "housework", label: "집안일").hwarangScene, .robotVacuum)
    }

    /// 지난 저장값은 고치지 않고 옮긴 대분류로 읽는다(HWK1103A01).
    func testOldRecordsReadIntoRelocatedCategories() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let old: [(String, String, String?, String, MapHomeStickmanAction)] = [
            ("shower", "샤워", "shower", "activity", .shower), ("activity", "장보기", "groceries", "housework", .groceries),
            ("eating", "요리", "cooking", "housework", .cooking), ("activity", "집안일", "housework", "housework", .housework),
            ("routine", "집안일", "housework", "housework", .housework)
        ]
        for (category, title, behavior, expected, action) in old {
            var record = ActualRecord(planID: nil, title: title, categoryID: category, startedAt: start, endedAt: start.addingTimeInterval(600), source: .manual)
            record.behavior = behavior
            XCTAssertEqual(RecordAnalysisCategoryPolicy.categoryID(for: record), expected, title)
            XCTAssertEqual(record.categoryID, category)
            XCTAssertEqual(MapHomeStickmanActionResolver.action(at: start.addingTimeInterval(60), actuals: [record], travel: [], places: [], frequentPlaces: []), action, title)
        }
    }

    /// 이동 상세는 메뉴와 재생 모두 수단별 장면을 쓴다(HWK1103A01).
    func testMovementDetailsHaveTheirOwnScenes() {
        let expected: [String: MapHomeStickmanAction] = [
            "movement.walking": .walking, "movement.running": .running, "movement.car": .car, "movement.subway": .subway,
            "movement.train": .train, "movement.privateVehicle": .car, "movement.bus": .bus, "movement.ship": .ship,
            "movement.airplane": .airplane, "movement.cycling": .cycling
        ]
        for detail in MapHomeCategoryDetailRows.details(for: "movement") {
            XCTAssertEqual(MapHomeStickmanActionResolver.action(for: detail.id, label: detail.title), expected[detail.id], detail.id)
        }
        let modes: [(TravelMode, MapHomeStickmanAction)] = [(.walking, .walking), (.subway, .subway), (.bus, .bus), (.airplane, .airplane)]
        for (mode, action) in modes { XCTAssertEqual(MapHomeStickmanActionResolver.action(for: mode), action) }
    }

    /// 장식을 걸쳤을 때만 샤워 옷걸이가 나타나고 장식이 그 위에 걸린다(RIG1103A01).
    func testShowerHangsAccessoriesOnARack() throws {
        let scarf = try XCTUnwrap(HwarangClothStyle.byLandmark["fr.alps"]), ribbon = try XCTUnwrap(HwarangClothStyle.byLandmark["au.opera"])
        XCTAssertFalse(HwarangDiagnostics.isPainted(scene: .shower, sec: 1, at: CGPoint(x: 3, y: 60)))
        let result = HwarangDiagnostics.accessoryEscape(scene: .shower, sec: 1, scarf: scarf, ribbon: ribbon, margin: 2)
        XCTAssertGreaterThan(result.added, 100)
        XCTAssertEqual(result.clipped, 0)
    }

    /// 먹는 동안 어느 프레임에서도 얼굴과 밥그릇이 겹치지 않는다(RIG1103A01).
    func testEatingFaceNeverTouchesTheBowl() {
        for step in 0..<Int(HwarangScene.eat.totalDuration / 0.05) {
            let sec = Double(step) * 0.05
            XCTAssertEqual(HwarangDiagnostics.faceBowlOverlap(sec: sec), 0, "\(sec)초")
        }
    }

    /// 그루밍 때 뒷발을 안테나처럼 높이 들고, 반대쪽 뒷발은 몸 앞으로 나와 보인다(RIG1103A01).
    func testGroomingFarHindLegReachesOutsideTheBody() {
        for sec in [6.5, 7.5, 8.5, 12.0] {
            XCTAssertTrue(HwarangDiagnostics.isPainted(scene: .groom, sec: sec, at: CGPoint(x: 110, y: 100)), "\(sec)초")
            // 가까운 앞다리는 얼굴 왼쪽 바깥 바닥을 짚는다.
            XCTAssertTrue(HwarangDiagnostics.isPainted(scene: .groom, sec: sec, at: CGPoint(x: -1, y: 100)), "\(sec)초")
            // 꼬리는 몸 앞 바닥으로 돌아온다.
            XCTAssertTrue(HwarangDiagnostics.isPainted(scene: .groom, sec: sec, at: CGPoint(x: 60, y: 112)), "\(sec)초")
            // 든 발은 머리보다 높다.
            XCTAssertTrue(HwarangDiagnostics.isPainted(scene: .groom, sec: sec, at: CGPoint(x: 35, y: 24)), "\(sec)초")
        }
    }

    /// 건강 대분류 장면은 요가 매트 위에서 한다(RIG1103A01).
    func testHealthSceneHasYogaMat() {
        XCTAssertEqual(MapHomeStickmanAction.health.markerScene(speedMetersPerSecond: 0, showsVehicles: true), .stretch)
        XCTAssertTrue(HwarangDiagnostics.isPainted(scene: .stretch, sec: 1, at: CGPoint(x: -4, y: 110)))
        XCTAssertFalse(HwarangDiagnostics.isPainted(scene: .groom, sec: 1, at: CGPoint(x: -4, y: 110)))
    }

    /// 기분 좋은 박자에 꼬리가 잠깐 부풀었다 돌아온다(RIG1103A01).
    func testHappyTailPuffsThenSettles() {
        for (scene, peak, settled) in [(HwarangScene.eat, 10.6, 11.7), (.yarn, 11.45, 12.5), (.wheel, 11.1, 12.2)] {
            XCTAssertGreaterThan(
                HwarangDiagnostics.paintedPixels(scene: scene, sec: peak),
                HwarangDiagnostics.paintedPixels(scene: scene, sec: settled) + 60, "\(scene)"
            )
        }
    }

    /// 움직이는 동안 스카프와 리본이 몸에서 떨어져 나가거나 캔버스 밖에서 잘리지 않는다(ACC1102A01).
    /// iOS는 앱이 60초 동안 CPU 80%를 넘으면 강제 종료한다(`cpu_resource_fatal`). 기기에서 시험 앱도 같아서,
    /// 장면을 모두 그리는 시험은 계산한 시간의 절반만큼 쉬어 67%로 맞춘다.
    private func cpuPaced<Result>(_ work: () -> Result) -> Result {
        let start = Date()
        let result = work()
        Thread.sleep(forTimeInterval: Date().timeIntervalSince(start) * 0.5)
        return result
    }

    /// 자동 기록이 일반 활동이어도 식당에 있으면 먹는 동작이다. 사용자가 고른 기록은 이긴다.
    func testRestaurantBeatsGenericActivity() throws {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let center = GeoPoint(latitude: 37.5, longitude: 127, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 5)
        var restaurant = FrequentPlace(kind: .restaurant, name: "식당")
        restaurant.setMapLocation(center)
        var company = FrequentPlace(kind: .company, name: "회사")
        company.setMapLocation(center)
        company.radiusMeters = max(restaurant.radiusMeters * 3, 200)
        XCTAssertEqual(MapHomeStickmanActionResolver.action(atCurrent: center, frequentPlaces: [company, restaurant]), .eating)
        var far = center
        far.latitude = 37.6
        XCTAssertNil(MapHomeStickmanActionResolver.action(atCurrent: far, frequentPlaces: [company, restaurant]))
        let stay = PlaceStay(placeKey: restaurant.stablePlaceKey, displayName: "식당", span: TimeSpan(start: start, end: start.addingTimeInterval(3600)), confidence: .high, isConfirmed: true)
        var generic = ActualRecord(planID: nil, title: "휴식", categoryID: "activity", startedAt: start, endedAt: start.addingTimeInterval(3600), source: .motion)
        func action() -> MapHomeStickmanAction {
            MapHomeStickmanActionResolver.action(at: start.addingTimeInterval(600), actuals: [generic], travel: [], places: [stay], frequentPlaces: [restaurant])
        }
        XCTAssertEqual(action(), .eating)
        generic.source = .manual
        generic.manuallyCorrected = true
        XCTAssertEqual(action(), .restStarfish, "사용자가 고른 휴식은 그대로다")
    }

    /// 집에 있어도 쉬는 자세가 일반 활동에 밀리지 않고, 운동 직후에는 회복 자세다.
    func testHomeRestAndRecoveryReachTheScreen() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let center = GeoPoint(latitude: 37.5, longitude: 127, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 5)
        var home = FrequentPlace(kind: .home, name: "집")
        home.setMapLocation(center)
        let stay = PlaceStay(placeKey: home.stablePlaceKey, displayName: "집", span: TimeSpan(start: start, end: start.addingTimeInterval(7200)), confidence: .high)
        let rest = ActualRecord(planID: nil, title: "집에서 휴식", categoryID: "rest", startedAt: start, endedAt: start.addingTimeInterval(7200), source: .location)
        let workout = ActualRecord(planID: nil, title: "운동", categoryID: "exercise", startedAt: start.addingTimeInterval(-1800), endedAt: start, source: .healthKit)
        func action(_ actuals: [ActualRecord], after seconds: TimeInterval) -> MapHomeStickmanAction {
            MapHomeStickmanActionResolver.action(at: start.addingTimeInterval(seconds), actuals: actuals, travel: [], places: [stay], frequentPlaces: [home])
        }
        XCTAssertEqual(action([rest], after: 600), .restBox)
        XCTAssertEqual(action([rest, workout], after: 600), .recovery)
        XCTAssertEqual(action([rest, workout], after: 3600), .restBox, "30분이 지나면 평소 휴식이다")
    }

    func testScarfAndRibbonStayOnTheBodyInEveryScene() throws {
        let scarf = try XCTUnwrap(HwarangClothStyle.byLandmark["fr.alps"]), ribbon = try XCTUnwrap(HwarangClothStyle.byLandmark["au.opera"])
        // 창이나 선체에 목 아래와 꼬리가 가리는 장면. 자동차는 턱 밑 띠만 앞유리 안쪽에 그린다.
        let hidden: Set<HwarangScene> = [.subway, .train, .bus, .airplane, .boat]
        for small in [false, true] {
            for scene in HwarangScene.allCases {
                var added = 0
                for frame in 0..<8 {
                    let sec = Double(scene.totalDuration) * (Double(frame) + 0.37) / 8
                    let result = cpuPaced { HwarangDiagnostics.accessoryEscape(scene: scene, sec: sec, scarf: scarf, ribbon: ribbon, margin: 6, small: small) }
                    added = max(added, result.added)
                    // 샤워 때는 장식을 벗어 옷걸이에 걸어 몸 밖에 있는 것이 맞다.
                    if scene != .shower { XCTAssertLessThanOrEqual(result.escaped, 12, "\(scene) \(frame) small=\(small)") }
                    XCTAssertEqual(result.clipped, 0, "\(scene) \(frame) small=\(small)")
                }
                if hidden.contains(scene) {
                    XCTAssertEqual(added, 0, "\(scene)는 보이는 부위가 없어 윤곽을 넓히지 않는다")
                } else {
                    XCTAssertGreaterThan(added, 0, "\(scene) small=\(small)")
                }
            }
        }
    }

    /// 자동차 앞유리 너머에는 턱 밑 스카프 띠가 보인다.
    func testScarfIsVisibleThroughTheCarWindshield() throws {
        let scarf = try XCTUnwrap(HwarangClothStyle.byLandmark["fr.alps"])
        let bare = try XCTUnwrap(HwarangDiagnostics.frame(scene: .carFront, sec: 1, side: 146).pngData())
        let worn = try XCTUnwrap(HwarangDiagnostics.frame(scene: .carFront, sec: 1, side: 146, scarf: scarf).pngData())
        XCTAssertNotEqual(bare, worn)
    }

    func testMapActionLookupCostWithHalfMillionInactiveRecords() {
        let date = Date(timeIntervalSince1970: 1_791_250_000)
        let active = ActualRecord(
            planID: nil, title: "합성 활동", categoryID: "eating",
            startedAt: date.addingTimeInterval(-60), endedAt: date.addingTimeInterval(60),
            source: .motion
        )
        let history = (0..<524_953).map { index in
            let start = date.addingTimeInterval(-172_800 - Double(index) * 30)
            return ActualRecord(
                planID: nil, title: "합성 과거", categoryID: "activity",
                startedAt: start, endedAt: start.addingTimeInterval(20), source: .motion
            )
        }
        let full = history + [active]
        let day = [active]
        func lookup(_ actuals: [ActualRecord]) -> MapHomeStickmanAction {
            if MapHomeStickmanActionResolver.hasAppleWatchConfirmedSleep(
                at: date, actuals: actuals, sleepSessions: []
            ) { return .sleeping }
            return MapHomeStickmanActionResolver.action(
                at: date, actuals: actuals, travel: [], places: [], frequentPlaces: []
            )
        }
        XCTAssertEqual(lookup(full), .eating)
        XCTAssertEqual(lookup(day), .eating)
        for (label, records) in [("full_history", full), ("day_input", day)] {
            let start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<5 {
                for _ in 0..<8 { XCTAssertEqual(lookup(records), .eating) }
            }
            let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1_000 / 5
            print("MAP1006F01 \(label) records=\(records.count) eight_lookups_ms=\(milliseconds)")
        }
    }

    func testCurrentActionIgnoresLargeInactiveHistoryAndTracksChangedFields() {
        let date = Date(timeIntervalSince1970: 1_791_250_000)
        var active = ActualRecord(
            planID: nil, title: "식사", categoryID: "eating",
            startedAt: date.addingTimeInterval(-60), endedAt: date.addingTimeInterval(60),
            source: .manual
        )
        let history = (0..<120_000).map { index in
            let start = date.addingTimeInterval(Double(index) * 60 - 365 * 24 * 60 * 60)
            return ActualRecord(
                planID: nil, title: "합성 과거 수면", categoryID: "sleep",
                startedAt: start, endedAt: start.addingTimeInterval(30), source: .appleWatch
            )
        }
        let full = history + [active]
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<20 {
            XCTAssertEqual(MapHomeStickmanActionResolver.action(
                at: date, actuals: full, travel: [], places: [], frequentPlaces: []
            ), .eating)
        }
        let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1_000 / 20
        print("PER1006B01 action records=\(full.count) mean_ms=\(milliseconds)")
        active.title = "업무"
        active.categoryID = "work"
        XCTAssertEqual(MapHomeStickmanActionResolver.action(
            at: date, actuals: history + [active], travel: [], places: [], frequentPlaces: []
        ), .computer)
    }

    func testDestinationActionsUseCompanySchoolAndRestaurantSemantics() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127.0,
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5
        )
        let company = FrequentPlace(
            kind: .company,
            name: "회사",
            point: point
        )
        let companyStay = PlaceStay(
            placeKey: company.stablePlaceKey,
            displayName: company.name,
            span: TimeSpan(start: start, end: start.addingTimeInterval(30 * 60)),
            confidence: .high,
            point: point,
            isConfirmed: true
        )
        XCTAssertEqual(
            MapHomeStickmanActionResolver.action(
                at: start.addingTimeInterval(10 * 60),
                actuals: [],
                travel: [],
                places: [companyStay],
                frequentPlaces: [company]
            ),
            .company
        )
        XCTAssertEqual(MapHomeStickmanActionResolver.action(for: "work", label: "업무"), .computer)
        XCTAssertEqual(MapHomeStickmanActionResolver.action(for: "work", label: "회사"), .company)
        XCTAssertEqual(MapHomeStickmanActionResolver.action(for: "company", label: "Work"), .company)

        let school = FrequentPlace(kind: .school, name: "학교", point: point)
        let schoolStay = PlaceStay(
            placeKey: school.stablePlaceKey,
            displayName: school.name,
            span: TimeSpan(start: start, end: start.addingTimeInterval(30 * 60)),
            confidence: .high,
            point: point,
            isConfirmed: true
        )
        XCTAssertEqual(
            MapHomeStickmanActionResolver.action(
                at: start.addingTimeInterval(10 * 60),
                actuals: [],
                travel: [],
                places: [schoolStay],
                frequentPlaces: [school]
            ),
            .school
        )
        XCTAssertEqual(MapHomeStickmanActionResolver.action(for: "study", label: "수업"), .reading)
        XCTAssertEqual(MapHomeStickmanActionResolver.action(for: "study", label: "학교"), .school)
        XCTAssertEqual(MapHomeStickmanActionResolver.action(for: "school", label: "Study"), .school)

        let restaurant = FrequentPlace(
            kind: .restaurant,
            name: "식당",
            point: point
        )
        let restaurantStay = PlaceStay(
            placeKey: restaurant.stablePlaceKey,
            displayName: restaurant.name,
            span: TimeSpan(start: start, end: start.addingTimeInterval(30 * 60)),
            confidence: .high,
            point: point,
            isConfirmed: true
        )
        XCTAssertEqual(
            MapHomeStickmanActionResolver.action(
                at: start.addingTimeInterval(10 * 60),
                actuals: [],
                travel: [],
                places: [restaurantStay],
                frequentPlaces: [restaurant]
            ),
            .eating
        )
    }

    func testTravelAndActualActionsHaveDeterministicPriority() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let span = TimeSpan(start: start, end: start.addingTimeInterval(30 * 60))
        let subway = TravelSegment(
            mode: .subway,
            span: span,
            distanceMeters: 4_000,
            confidence: .high,
            evidence: []
        )
        let sleep = ActualRecord(
            planID: nil,
            title: "수면",
            categoryID: "sleep",
            startedAt: start,
            endedAt: span.end,
            source: .healthKit,
            behavior: "core"
        )
        XCTAssertEqual(
            MapHomeStickmanActionResolver.action(
                at: start.addingTimeInterval(10 * 60),
                actuals: [sleep],
                travel: [subway],
                places: [],
                frequentPlaces: []
            ),
            .subway
        )
        XCTAssertEqual(
            MapHomeStickmanActionResolver.action(for: TravelMode.cycling),
            .cycling
        )
        XCTAssertEqual(
            MapHomeStickmanActionResolver.action(for: TravelMode.car),
            .car
        )
        XCTAssertEqual(
            MapHomeStickmanActionResolver.action(for: TravelMode.bus),
            .bus
        )
        XCTAssertEqual(
            MapHomeStickmanActionResolver.action(
                at: start.addingTimeInterval(10 * 60),
                actuals: [sleep],
                travel: [],
                places: [],
                frequentPlaces: []
            ),
            .sleeping
        )
    }

    func testAppleWatchConfirmedSleepOverridesTravelAndUsesSleepAction() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let twoHours = 2 * 60 * 60.0
        let span = TimeSpan(start: start, end: start.addingTimeInterval(twoHours))
        let session = SleepSession(
            id: UUID(),
            span: span,
            asleepDuration: twoHours,
            awakeDuration: 0,
            inBedDuration: twoHours,
            stageDurations: [.core: twoHours],
            sourceNames: ["HealthKit"],
            segments: [
                SleepSegment(
                    stage: .core,
                    span: span,
                    sourceName: "HealthKit",
                    deviceName: "Apple Watch"
                )
            ]
        )
        let subway = TravelSegment(
            mode: .subway,
            span: span,
            distanceMeters: 4_000,
            confidence: .high,
            evidence: []
        )

        XCTAssertTrue(session.isAppleWatchConfirmed)
        XCTAssertEqual(
            MapHomeStickmanActionResolver.action(
                at: start.addingTimeInterval(30 * 60),
                actuals: [],
                travel: [subway],
                places: [],
                frequentPlaces: [],
                sleepSessions: [session]
            ),
            .sleeping
        )

        let healthKitSleep = ActualRecord(
            planID: nil,
            title: "수면",
            categoryID: "sleep",
            startedAt: span.start,
            endedAt: span.end,
            source: .healthKit
        )
        let normalized = SleepActualReconciliationEngine.applying(
            [healthKitSleep],
            sessions: [session],
            inside: span,
            asOf: span.end
        )
        XCTAssertEqual(normalized.first?.source, .appleWatch)
    }

    // CAT1029A01: 수면 시간의 대분류는 수면이다. 자동 이동은 지우고, 재생도 정지 배속으로 지나간다.
    private func watchSleepSession(_ span: TimeSpan) -> SleepSession {
        SleepSession(
            id: UUID(), span: span, asleepDuration: span.duration, awakeDuration: 0,
            inBedDuration: span.duration, stageDurations: [.core: span.duration],
            sourceNames: ["Apple Watch"], segments: []
        )
    }

    func testWatchSleepRemovesCoveredAutomaticTravelButKeepsConfirmedAndOutsideTravel() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let hour = 60 * 60.0
        let night = TimeSpan(start: start, end: start.addingTimeInterval(7 * hour))
        let covered = TravelSegment(
            mode: .subway, span: TimeSpan(start: start.addingTimeInterval(2 * hour), end: start.addingTimeInterval(3 * hour)),
            distanceMeters: 4_000, confidence: .high, evidence: [], isClassificationLocked: true
        )
        let confirmed = TravelSegment(
            mode: .subway, span: covered.span, distanceMeters: 4_000, confidence: .high,
            evidence: [], isConfirmed: true
        )
        // 잠들기 직전 귀가: 대부분이 수면 밖이라 남는다.
        let walkHome = TravelSegment(
            mode: .walking, span: TimeSpan(start: start.addingTimeInterval(-50 * 60), end: start.addingTimeInterval(10 * 60)),
            distanceMeters: 900, confidence: .high, evidence: []
        )

        let result = SleepTravelReconciliationEngine.removingAutomaticTravel(
            [walkHome, covered, confirmed],
            sessions: [watchSleepSession(night)],
            inside: TimeSpan(start: start.addingTimeInterval(-hour), end: start.addingTimeInterval(8 * hour)),
            asOf: start.addingTimeInterval(8 * hour)
        )

        XCTAssertEqual(result.map(\.id), [walkHome.id, confirmed.id])
    }

    func testWatchSleepTrimsAutomaticMovementRecords() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let night = TimeSpan(start: start, end: start.addingTimeInterval(6 * 60 * 60))
        let gapSubway = ActualRecord(
            planID: nil, title: "지하철", categoryID: "movement",
            startedAt: start.addingTimeInterval(60 * 60), endedAt: start.addingTimeInterval(2 * 60 * 60),
            source: .motion, modelVersion: TaptionActivityEngineAdapter.inferredGapModelVersion
        )

        let result = SleepActualReconciliationEngine.applying(
            [gapSubway], sessions: [watchSleepSession(night)], inside: night, asOf: night.end
        )

        XCTAssertEqual(result.map(\.categoryID), ["sleep"])
    }

    func testPlaybackSpeedFollowsSleepCategoryOverMovement() {
        let dayStart = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let sleep = ActualRecord(
            planID: nil, title: "수면", categoryID: "sleep",
            startedAt: dayStart.addingTimeInterval(60 * 60), endedAt: dayStart.addingTimeInterval(5 * 60 * 60),
            source: .appleWatch
        )
        let snapshot = PlanDayDataSnapshot(
            day: dayStart, sourceRevision: 1, sourceUpdatedAt: dayStart,
            actuals: [sleep], places: [], travel: [], readings: [], isComplete: true
        )

        let ranges = MapHomePlaybackCategoryRanges.removingSleep(
            [MapHomePlaybackMovementRange(startMinute: 30, endMinute: 400, mode: .subway)],
            snapshot: snapshot, dayStart: dayStart
        )

        XCTAssertEqual(ranges.map(\.startMinute), [30, 300])
        XCTAssertEqual(ranges.map(\.endMinute), [60, 400])
    }

    // CAT1029A02: 센서 원본 열은 대분류가 아니라 HealthKit·iPhone 모션·GPS 원본으로 선다.
    func testSensorEvidenceLaneUsesHealthKitSleepThenIPhoneMotionAndGPSSpeed() {
        let dayStart = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func at(_ minute: Int) -> Date { dayStart.addingTimeInterval(Double(minute) * 60) }
        let still = stride(from: 60, through: 475, by: 5).map {
            SensorReading(timestamp: at($0), motion: .stationary)
        }
        // 자차 출근: 모션은 모름이어도 GPS 속도가 차량을 말한다.
        let drive = (550...607).map {
            SensorReading(timestamp: at($0), speedMetersPerSecond: 15, motion: .unknown)
        }
        let sleep = watchSleepSession(TimeSpan(start: at(90), end: at(440)))

        let lane = MapHomeNLESensorEvidence.segments(
            readings: still + drive, sleepSessions: [sleep], healthActuals: [],
            dayStart: dayStart, now: at(1_000)
        )

        XCTAssertEqual(lane.map(\.title), ["정지 · iPhone", "수면 · HealthKit", "정지 · iPhone", "차량 · GPS 속도"])
        XCTAssertEqual(lane.map(\.startMinute), [60, 90, 440, 550])
        XCTAssertEqual(lane.map(\.endMinute), [90, 440, 485, 608])
    }

    /// 센서 원본 열은 움직임·헬스·화면·연결·장소 다섯 줄로 갈라 서서, 한 분에 값이 여럿이어도 서로 가리지 않는다(UIX1031A17).
    func testSensorEvidenceChannelsKeepScreenNetworkPlaceAndHealthSeparate() {
        let dayStart = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func at(_ minute: Int) -> Date { dayStart.addingTimeInterval(Double(minute) * 60) }
        let readings: [SensorReading] = (600...620).map { minute in
            var reading = SensorReading(timestamp: at(minute), motion: .walking)
            reading.screenIsOn = true
            reading.connectedWiFiSSID = "HomeWiFi"
            reading.nearbyStationName = "강남"
            reading.watchWorkoutKind = "running"
            reading.stepCount = 1_000 + minute
            return reading
        }
        let sleep = watchSleepSession(TimeSpan(start: at(0), end: at(300)))
        let segments = MapHomeNLESensorEvidence.channelSegments(
            readings: readings, sleepSessions: [sleep], healthActuals: [], dayStart: dayStart, now: at(1_000)
        )
        func titles(_ channel: MapHomeNLESensorChannel) -> [String] {
            segments.filter { $0.channel == channel }.map(\.title)
        }
        XCTAssertEqual(titles(.motion), ["걷기 · iPhone"])
        XCTAssertEqual(titles(.screen), ["화면 켜짐"])
        XCTAssertEqual(titles(.network), ["Wi-Fi · HomeWiFi"])
        XCTAssertEqual(titles(.place), ["정류장 근처 · 강남"])
        XCTAssertEqual(titles(.health), ["수면 · HealthKit", "운동 running · 워치"])
        XCTAssertTrue(MapHomeNLESensorChannel.motion.isRestorable)
        XCTAssertFalse(MapHomeNLESensorChannel.screen.isRestorable)

        // 고른 분의 원본 값은 가장 가까운 측정값에서 풀어 쓴다. 10분을 넘게 떨어지면 없다.
        let near = MapHomeNLESensorEvidence.nearestReading(atMinute: 610, in: readings, dayStart: dayStart)
        XCTAssertEqual(near?.timestamp, at(610))
        XCTAssertNil(MapHomeNLESensorEvidence.nearestReading(atMinute: 700, in: readings, dayStart: dayStart))
        let lines = MapHomeNLESensorEvidence.rawLines(for: readings[10], language: .korean)
        XCTAssertTrue(lines.contains("걸음 1,610"))
        XCTAssertTrue(lines.contains("Wi-Fi HomeWiFi"))
        XCTAssertTrue(lines.contains("가까운 정류장 강남"))
        XCTAssertTrue(lines.contains("워치 운동 running"))
    }

    func testLegacyWatchSleepBehaviorStillOverridesTravel() {
        let start = Date(timeIntervalSinceReferenceDate: 800_050_000)
        let span = TimeSpan(
            start: start,
            end: start.addingTimeInterval(2 * 60 * 60)
        )
        let legacyWatchSleep = ActualRecord(
            planID: nil,
            title: "활동",
            categoryID: "activity",
            startedAt: span.start,
            endedAt: span.end,
            source: .appleWatch,
            behavior: WatchBehaviorKind.sleep.rawValue
        )
        let subway = TravelSegment(
            mode: .subway,
            span: span,
            distanceMeters: 4_000,
            confidence: .high,
            evidence: []
        )

        XCTAssertEqual(
            MapHomeStickmanActionResolver.action(
                at: start.addingTimeInterval(30 * 60),
                actuals: [legacyWatchSleep],
                travel: [subway],
                places: [],
                frequentPlaces: []
            ),
            .sleeping
        )
    }

    func testAppleWatchMajorActivityOverridesInferredIPhoneMovement() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let span = TimeSpan(
            start: start,
            end: start.addingTimeInterval(30 * 60)
        )
        let watchActivity = ActualRecord(
            planID: nil,
            title: "운동",
            categoryID: "activity",
            startedAt: span.start,
            endedAt: span.end,
            source: .appleWatch,
            behavior: WatchBehaviorKind.exercise.rawValue
        )
        let inferredCar = SensorReading(
            timestamp: start.addingTimeInterval(10 * 60),
            motion: .automotive,
            motionConfidence: .high
        )

        XCTAssertEqual(
            MapHomeStickmanActionResolver.action(
                at: start.addingTimeInterval(10 * 60),
                actuals: [watchActivity],
                travel: [],
                places: [],
                frequentPlaces: [],
                readings: [inferredCar]
            ),
            .activity
        )
    }

    func testMajorCategoryControlsStickmanInsteadOfDetailedActivity() {
        let start = Date(timeIntervalSinceReferenceDate: 800_100_000)
        let detailActivity = ActualRecord(
            planID: nil,
            title: "업무",
            categoryID: "activity",
            startedAt: start,
            endedAt: start.addingTimeInterval(30 * 60),
            source: .timer,
            behavior: "computer"
        )

        XCTAssertEqual(
            MapHomeStickmanActionResolver.action(
                at: start.addingTimeInterval(10 * 60),
                actuals: [detailActivity],
                travel: [],
                places: [],
                frequentPlaces: []
            ),
            .activity
        )
    }

    func testIPhoneOnlySleepDoesNotClaimAppleWatchPriority() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let twoHours = 2 * 60 * 60.0
        let span = TimeSpan(start: start, end: start.addingTimeInterval(twoHours))
        let session = SleepSession(
            id: UUID(),
            span: span,
            asleepDuration: twoHours,
            awakeDuration: 0,
            inBedDuration: twoHours,
            stageDurations: [.asleepUnspecified: twoHours],
            sourceNames: ["iPhone"],
            segments: []
        )
        let walking = TravelSegment(
            mode: .walking,
            span: span,
            distanceMeters: 500,
            confidence: .high,
            evidence: []
        )

        XCTAssertFalse(session.isAppleWatchConfirmed)
        XCTAssertEqual(
            MapHomeStickmanActionResolver.action(
                at: start.addingTimeInterval(30 * 60),
                actuals: [],
                travel: [walking],
                places: [],
                frequentPlaces: [],
                sleepSessions: [session]
            ),
            .walking
        )
    }

    func testAnimationPhaseIsStableAndReduceMotionFreezesIt() {
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let next = date.addingTimeInterval(MapHomeStickmanAnimationEngine.frameDuration)
        XCTAssertNotEqual(
            MapHomeStickmanAnimationEngine.phase(at: date),
            MapHomeStickmanAnimationEngine.phase(at: next)
        )
        XCTAssertEqual(
            MapHomeStickmanAnimationEngine.phase(at: next, reducesMotion: true),
            0
        )
        XCTAssertEqual(
            MapHomeStickmanAnimationEngine.oscillation(for: 0),
            0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(MapHomeStickmanAnimationEngine.phaseCount, 24)
        XCTAssertEqual(
            MapHomeStickmanAnimationEngine.frameDuration,
            1.0 / 12.0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(MapHomeStickmanAnimationEngine.phase(for: 0), 0)
        XCTAssertEqual(MapHomeStickmanAnimationEngine.phase(for: 0.5), 12)
        XCTAssertEqual(MapHomeStickmanAnimationEngine.phase(for: 1), 23)
    }

    func testOnlyMovementStickmanActionsAnimate() {
        XCTAssertEqual(
            Set(MapHomeStickmanAction.allCases.filter(\.isMoving)),
            [.movement, .walking, .running, .car, .subway, .train, .privateVehicle,
             .bus, .ship, .airplane, .cycling]
        )
    }

    func testObjectOnlyActivityMarkersAnimateTheirProps() {
        let actions: [MapHomeStickmanAction] = [.computer, .eating, .reading, .hobby]
        XCTAssertTrue(actions.allSatisfy(\.animatesPresentation))
        XCTAssertTrue(actions.allSatisfy { !$0.isMoving })
        XCTAssertTrue(MapHomeStickmanAction.sleeping.animatesPresentation)
    }

    func testEveryMajorCategoryHasItsOwnHwarangScene() {
        // 행동 분류마다 화랑이 장면이 전부 다르다(대표 지시, RIG1101A01).
        let majors = MapHomeSidebarMajorCategory.all.map(\.stickmanAction.hwarangScene)
        XCTAssertGreaterThanOrEqual(majors.count, 10)
        XCTAssertEqual(Set(majors).count, majors.count, "\(majors)")
        XCTAssertEqual(MapHomeSpeedTier.walking.scene, .walkLoop)
        XCTAssertEqual(MapHomeSpeedTier.running.scene, .runLoop)
    }

    func testHatIsDrawnOnTheHwarangHead() {
        let hat = "Hat_kr_gyeongbokgung"
        XCTAssertGreaterThan(
            HwarangDiagnostics.paintedPixels(scene: .walkLoop, sec: 1, hat: hat),
            HwarangDiagnostics.paintedPixels(scene: .walkLoop, sec: 1) + 100
        )
    }

    /// 집 그림 안 화랑이도 재생 마커처럼 착용한 모자를 쓴다(HAT1102A01).
    @MainActor
    func testHomeGlyphDrawsEquippedHat() throws {
        let action = try XCTUnwrap(Optional(MapHomeStickmanAction.activity))
        func pixels(_ accessoryID: String?) throws -> [UInt8] {
            let renderer = ImageRenderer(content: MapHomeStickmanGlyph(action: action, size: 36, equippedAccessoryID: accessoryID)
                .environment(\.isLuminanceReduced, true)
                .frame(width: 80, height: 80))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage)
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = try XCTUnwrap(CGContext(
                data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return bytes
        }
        let plain = try pixels(nil), hat = try pixels("cat.accessory.kr.gyeongbokgung")
        let changed = stride(from: 3, to: plain.count, by: 4).filter { plain[$0] != hat[$0] }.count
        XCTAssertGreaterThan(changed, 100)
    }

    /// 탈것마다 자기 장면이 나오고 속도 구간의 걷기·달리기로 바뀌지 않는다(CAT1102A02).
    func testVehiclesAndChoresHaveTheirOwnScenes() {
        let expected: [(MapHomeStickmanAction, HwarangScene)] = [
            (.car, .carFront), (.privateVehicle, .carFront), (.subway, .subway), (.train, .train), (.cycling, .bicycle), (.bus, .bus),
            (.airplane, .airplane), (.ship, .boat), (.shower, .shower), (.housework, .robotVacuum)
        ]
        for (action, scene) in expected { XCTAssertEqual(action.hwarangScene, scene, action.rawValue) }
        for scene in [HwarangScene.carFront, .subway, .train, .bus, .bicycle, .airplane, .boat] { XCTAssertTrue(scene.isVehicleScene) }
        XCTAssertFalse(HwarangScene.walkLoop.isVehicleScene)
    }

    func testEveryMajorCategoryDrawsItsOwnSceneThroughTheResolver() {
        let scenes = MapHomeSidebarMajorCategory.all.map(\.stickmanAction.hwarangScene)
        XCTAssertEqual(Set(scenes).count, scenes.count)
        XCTAssertEqual(MapHomeStickmanActionResolver.action(for: "shower", label: ""), .shower)
        XCTAssertEqual(MapHomeStickmanActionResolver.action(for: "housework", label: ""), .housework)
        XCTAssertEqual(MapHomeStickmanActionResolver.action(for: "custom:1", label: "집안일"), .housework)
    }

    /// 직접 고른 분류가 이동 구간보다 앞서고, 자동 집안일 판정도 집안일 장면을 쓴다(HWK1103A01).
    func testChosenCategoryWinsOverTravelAndHouseworkIsNotAutomatic() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func actual(category: String, source: ActualSource, title: String) -> ActualRecord {
            ActualRecord(planID: nil, title: title, categoryID: category, startedAt: now.addingTimeInterval(-60), endedAt: now.addingTimeInterval(60), source: source)
        }
        let travel = TravelSegment(
            mode: .car, span: TimeSpan(start: now.addingTimeInterval(-60), end: now.addingTimeInterval(60)),
            distanceMeters: 1_000, confidence: .high, evidence: []
        )
        XCTAssertEqual(MapHomeStickmanActionResolver.action(
            at: now, actuals: [actual(category: "shower", source: .manual, title: "샤워")], travel: [travel], places: [], frequentPlaces: []
        ), .shower)
        XCTAssertEqual(MapHomeStickmanActionResolver.action(
            at: now, actuals: [actual(category: "activity", source: .appleWatch, title: "집안일")], travel: [], places: [], frequentPlaces: []
        ), .housework)
    }

    /// 탈것 표시를 켜면 탈것 장면, 끄면 속도에 따라 걷기·달리기. 달리기는 항상 달린다.
    func testMarkerSceneFollowsVehicleSettingAndSpeed() {
        XCTAssertEqual(MapHomeStickmanAction.running.markerScene(speedMetersPerSecond: 1, showsVehicles: true), .runLoop)
        XCTAssertEqual(MapHomeStickmanAction.walking.markerScene(speedMetersPerSecond: nil, showsVehicles: true), .walkLoop)
        XCTAssertEqual(MapHomeStickmanAction.walking.markerScene(speedMetersPerSecond: 1.2, showsVehicles: true), .walkLoop)
        XCTAssertEqual(MapHomeStickmanAction.walking.markerScene(speedMetersPerSecond: 3, showsVehicles: true), .runLoop)
        let rides: [(MapHomeStickmanAction, HwarangScene)] = [
            (.cycling, .bicycle), (.car, .carFront), (.bus, .bus), (.subway, .subway),
            (.train, .train), (.airplane, .airplane), (.ship, .boat)
        ]
        for (action, scene) in rides {
            XCTAssertEqual(action.markerScene(speedMetersPerSecond: 20, showsVehicles: true), scene)
            XCTAssertEqual(action.markerScene(speedMetersPerSecond: 20, showsVehicles: false), .runLoop)
            XCTAssertEqual(action.markerScene(speedMetersPerSecond: 1, showsVehicles: false), .walkLoop)
        }
        XCTAssertEqual(MapHomeStickmanActionResolver.action(for: TravelMode.train), .train)
        XCTAssertEqual(MapHomeStickmanAction.eating.markerScene(speedMetersPerSecond: 5, showsVehicles: false), .eat)
    }

    /// 집 아이콘 날씨 그림: 기호를 그림 종류로 나누고 종류마다 다르게 그린다(WTH1102A01).
    func testHomeWeatherKindsFromSymbols() {
        let expected: [(String, MapHomeHomeWeatherKind)] = [
            ("sun.max.fill", .sun), ("cloud.sun.fill", .partlyCloudy), ("moon.stars.fill", .moon), ("cloud.fill", .cloud),
            ("cloud.fog.fill", .fog), ("cloud.drizzle.fill", .rain), ("cloud.heavyrain.fill", .heavyRain), ("cloud.snow.fill", .snow),
            ("cloud.bolt.rain.fill", .thunder), ("wind", .wind), ("hurricane", .typhoon), ("tropicalstorm", .typhoon)
        ]
        for (symbol, kind) in expected { XCTAssertEqual(MapHomeHomeWeatherKind(symbolName: symbol), kind, symbol) }
    }

    /// 풍속이 셀수록 바람 그림이 빨라지고, 옛 날씨 기록은 풍속 없이 읽힌다.
    func testWindMotionFollowsSpeedAndOldWeatherStillDecodes() throws {
        XCTAssertLessThan(MapHomeHomeWeatherFrame.windMotion(speed: 2), MapHomeHomeWeatherFrame.windMotion(speed: 8))
        XCTAssertLessThan(MapHomeHomeWeatherFrame.windMotion(speed: 8), MapHomeHomeWeatherFrame.windMotion(speed: 15))
        XCTAssertEqual(MapHomeHomeWeatherFrame.windMotion(speed: 40), 4)
        let current = WeatherContext(observedAt: .now, condition: "windy", symbolName: "wind", temperatureCelsius: 9, windSpeedMetersPerSecond: 11)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        XCTAssertEqual(object["windSpeedMetersPerSecond"] as? Double, 11)
        object["windSpeedMetersPerSecond"] = nil
        let old = try JSONDecoder().decode(WeatherContext.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.windSpeedMetersPerSecond)
    }

    func testEveryHwarangSceneDrawsThroughItsWholeLoop() {
        for scene in HwarangScene.allCases {
            XCTAssertGreaterThan(scene.totalDuration, 0)
            var time = 0.0
            while time < Double(scene.totalDuration) + 1 {
                XCTAssertGreaterThan(cpuPaced { HwarangDiagnostics.paintedPixels(scene: scene, sec: time) }, 500, "\(scene) \(time)")
                time += 0.73
            }
        }
    }

    func testStickmanFacingFollowsScreenDirectionAndHoldsWhenVertical() {
        XCTAssertFalse(MapHomeStickmanFacing.resolve(headingDegrees: 90, cameraHeading: 0, previous: true))
        XCTAssertTrue(MapHomeStickmanFacing.resolve(headingDegrees: 270, cameraHeading: 0, previous: false))
        // 지도가 돌아가 있으면 화면 기준으로 뒤집힌다.
        XCTAssertTrue(MapHomeStickmanFacing.resolve(headingDegrees: 90, cameraHeading: 180, previous: false))
        // 거의 위아래로 가면 이전 방향을 유지한다.
        XCTAssertTrue(MapHomeStickmanFacing.resolve(headingDegrees: 5, cameraHeading: 0, previous: true))
        XCTAssertFalse(MapHomeStickmanFacing.resolve(headingDegrees: 185, cameraHeading: 0, previous: false))
    }

    func testMapStickmanResolvesMajorCategoryBeforeActivityDetail() {
        let majorCategories: [(String, String, MapHomeStickmanAction)] = [
            ("activity", "활동", .activity),
            ("work", "업무", .computer),
            ("work", "회사", .company),
            ("study", "수업", .reading),
            ("study", "학교", .school),
            ("hobby", "취미", .hobby),
            ("sleep", "수면", .sleeping),
            ("movement", "이동", .movement),
            ("eating", "식사", .eating),
            ("exercise", "운동", .exercise),
            ("unconfirmed", "미확인", .unconfirmed),
        ]
        let movementDetails = [
            "걷기", "달리기", "자동차", "지하철", "자가용",
            "버스", "배", "비행기", "자전거",
        ]

        for (categoryID, title, action) in majorCategories {
            XCTAssertEqual(
                MapHomeStickmanActionResolver.action(
                    for: categoryID,
                    label: title
                ),
                action,
                "\(categoryID) 대분류 동작이 다릅니다."
            )
        }
        for title in movementDetails {
            XCTAssertEqual(
                MapHomeStickmanActionResolver.action(
                    for: "movement",
                    label: title
                ),
                .movement,
                "\(title) 상세가 이동 대분류를 덮었습니다."
            )
        }
        XCTAssertEqual(MapHomeStickmanAction.allCases.count, 55)
        XCTAssertEqual(Set(MapHomeStickmanAction.allCases).count, 55)
        XCTAssertEqual(Set(MapHomeStickmanAction.allCases.map(\.title)).count, 55)
        XCTAssertEqual(MapHomeStickmanActionResolver.action(for: TravelMode.running), .running)
        XCTAssertEqual(
            MapHomeStickmanActionResolver.action(
                for: "activity",
                label: "업무"
            ),
            .activity
        )
        XCTAssertEqual(
            MapHomeStickmanActionResolver.action(
                for: "activity",
                label: "미확인 동작"
            ),
            .activity
        )
        XCTAssertEqual(
            MapHomeStickmanActionResolver.action(
                for: "custom.user",
                label: "사용자 카테고리"
            ),
            .activity
        )
        XCTAssertNotEqual(
            MapHomeStickmanActionResolver.action(
                for: "hobby",
                label: "배드민턴"
            ),
            .ship
        )
        XCTAssertEqual(MapHomeStickmanMarker.size.width, 36)
        XCTAssertEqual(MapHomeStickmanMarker.size.height, 36)
    }

    func testLiveActivityStickmanResolvesEveryMajorCategory() {
        let expected: [(String, String, TaptionLiveActivityStickmanAction)] = [
            ("activity", "활동", .activity),
            ("work", "업무", .computer),
            ("study", "수업", .reading),
            ("hobby", "취미", .hobby),
            ("sleep", "수면", .sleeping),
            ("eating", "식사", .eating),
            ("movement", "이동", .movement),
            ("exercise", "운동", .exercise),
            ("unconfirmed", "미확인", .unconfirmed),
        ]

        for (categoryID, title, action) in expected {
            XCTAssertEqual(
                TaptionLiveActivityStickmanAction.resolve(
                    categoryID: categoryID,
                    title: title
                ),
                action,
                "\(categoryID) 대분류의 Dynamic Island 동작이 다릅니다."
            )
        }
        XCTAssertEqual(
            TaptionLiveActivityStickmanAction.resolve(
                categoryID: "movement",
                title: "걷기"
            ),
            .movement
        )
        let movementDetails = [
            "걷기", "달리기", "자동차", "지하철", "자가용",
            "버스", "배", "비행기", "자전거",
        ]
        for title in movementDetails {
            XCTAssertEqual(
                TaptionLiveActivityStickmanAction.resolve(
                    categoryID: "movement",
                    title: title
                ),
                .movement,
                "\(title) 상세가 Live Activity 이동 대분류를 덮었습니다."
            )
        }
        XCTAssertEqual(TaptionLiveActivityStickmanAction.allCases.count, 18)
        XCTAssertEqual(Set(TaptionLiveActivityStickmanAction.allCases).count, 18)
        XCTAssertEqual(
            TaptionLiveActivityStickmanAction.resolve(
                categoryID: "activity",
                title: "업무"
            ),
            .activity
        )
        XCTAssertEqual(
            TaptionLiveActivityStickmanAction.resolve(
                categoryID: "custom.user",
                title: "사용자 카테고리"
            ),
            .activity
        )
        XCTAssertNotEqual(
            TaptionLiveActivityStickmanAction.resolve(
                categoryID: "hobby",
                title: "배드민턴"
            ),
            .ship
        )
    }

    func testLiveActivityStickmanAnimationHonorsReduceMotion() {
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let next = date.addingTimeInterval(
            TaptionLiveActivityStickmanAnimation.frameDuration
        )
        XCTAssertNotEqual(
            TaptionLiveActivityStickmanAnimation.phase(at: date),
            TaptionLiveActivityStickmanAnimation.phase(at: next)
        )
        XCTAssertEqual(
            TaptionLiveActivityStickmanAnimation.phase(
                at: next,
                reducesMotion: true
            ),
            0
        )
        XCTAssertEqual(TaptionLiveActivityStickmanAnimation.frameCount, 24)
        XCTAssertEqual(
            TaptionLiveActivityStickmanAnimation.frameDuration,
            1.0 / 12.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(TaptionLiveActivityStickmanAnimation.phaseCount, 24)
        XCTAssertEqual(
            TaptionLiveActivityStickmanAnimation.frameIndex(
                at: 24 * (1.0 / 12.0),
                isAnimating: true
            ),
            0
        )
    }

    func testOnlyMovementLiveActivityStickmanActionsAnimate() {
        XCTAssertEqual(
            Set(TaptionLiveActivityStickmanAction.allCases.filter(\.isMoving)),
            [.movement, .walking, .running, .car, .subway, .privateVehicle,
             .bus, .ship, .airplane, .cycling]
        )
    }

    func testLiveActivityStickmanKeepsAllRawActions() {
        let expectedRawValues = [
            "activity", "computer", "reading", "hobby", "sleeping",
            "movement", "eating", "exercise", "unconfirmed", "walking",
            "running", "car", "subway", "privateVehicle", "bus", "ship",
            "airplane", "cycling",
        ]
        XCTAssertEqual(
            TaptionLiveActivityStickmanAction.allCases.map(\.rawValue),
            expectedRawValues
        )
    }

    func testRegisteredCompanyClassificationCanReplaceUnknownStayLock() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let inside = TimeSpan(start: start, end: start.addingTimeInterval(60 * 60))
        let previous = ActualRecord(
            planID: nil,
            title: "머무름",
            categoryID: "activity",
            startedAt: start,
            endedAt: start.addingTimeInterval(30 * 60),
            source: .location,
            behavior: StationaryContextKind.unknownStay.rawValue,
            isClassificationLocked: true
        )
        let fresh = ActualRecord(
            planID: nil,
            title: "근무",
            categoryID: "work",
            startedAt: start.addingTimeInterval(60),
            endedAt: start.addingTimeInterval(31 * 60),
            source: .location,
            behavior: StationaryContextKind.work.rawValue,
            evidence: ["자주가는 곳: 회사", "평일 09–18시"]
        )

        let result = ActivityClassificationLockEngine.mergingLockedClassifications(
            existing: [previous],
            fresh: [fresh],
            inside: inside
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].categoryID, "work")
        XCTAssertEqual(result[0].title, "근무")
        XCTAssertEqual(result[0].behavior, StationaryContextKind.work.rawValue)
        XCTAssertTrue(result[0].isClassificationLocked)
    }

    func testMapMemoFilterShowsAllOrOnlySelectedScheduleAndTarget() {
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 10
        )
        let planID = UUID()
        let planMemo = ActionMemo(
            planID: planID,
            mapPoint: point,
            kind: .idea,
            text: "일정 메모"
        )
        let placeMemo = ActionMemo(
            targetID: "place.target",
            mapPoint: point,
            kind: .decision,
            text: "장소 메모"
        )
        let timelineOnlyMemo = ActionMemo(
            kind: .nextAction,
            text: "타임라인 메모"
        )

        XCTAssertEqual(
            MapMemoDisplayFilterEngine.visibleMemos(
                [planMemo, placeMemo, timelineOnlyMemo],
                filter: .all,
                selectedPlanIDs: [],
                selectedTargetIDs: []
            ),
            [planMemo, placeMemo]
        )
        XCTAssertEqual(
            MapMemoDisplayFilterEngine.visibleMemos(
                [planMemo, placeMemo, timelineOnlyMemo],
                filter: .relevant,
                selectedPlanIDs: [planID],
                selectedTargetIDs: []
            ),
            [planMemo]
        )
        XCTAssertEqual(
            MapMemoDisplayFilterEngine.visibleMemos(
                [planMemo, placeMemo, timelineOnlyMemo],
                filter: .relevant,
                selectedPlanIDs: [],
                selectedTargetIDs: ["place.target"]
            ),
            [placeMemo]
        )
    }

    func testMapMemoFilterLimitsVisibleMemosToSelectedDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 0,
            horizontalAccuracy: 0,
            verticalAccuracy: 0
        )
        let selectedDay = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 29, hour: 9)
        )!
        let sameDay = ActionMemo(
            occurredAt: selectedDay,
            mapPoint: point,
            kind: .idea,
            text: "오늘 지도 메모"
        )
        let otherDay = ActionMemo(
            occurredAt: calendar.date(
                from: DateComponents(year: 2026, month: 8, day: 30, hour: 9)
            )!,
            mapPoint: point,
            kind: .idea,
            text: "다음 날 지도 메모"
        )

        let visible = MapMemoDisplayFilterEngine.visibleMemos(
            [sameDay, otherDay],
            on: selectedDay,
            filter: .all,
            selectedPlanIDs: [],
            selectedTargetIDs: [],
            calendar: calendar
        )

        XCTAssertEqual(visible.map(\.id), [sameDay.id])
    }

    func testMapMemoFilterHonorsPlaybackCutoffButKeepsPlayheadMemo() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 0,
            horizontalAccuracy: 0,
            verticalAccuracy: 0
        )
        let playhead = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 29, hour: 10)
        )!
        let before = ActionMemo(
            occurredAt: playhead.addingTimeInterval(-60),
            mapPoint: point,
            kind: .idea,
            text: "재생 전 메모"
        )
        let atPlayhead = ActionMemo(
            occurredAt: playhead,
            mapPoint: point,
            kind: .decision,
            text: "현재 시각 메모"
        )
        let after = ActionMemo(
            occurredAt: playhead.addingTimeInterval(60),
            mapPoint: point,
            kind: .nextAction,
            text: "아직 오지 않은 메모"
        )

        let visible = MapMemoDisplayFilterEngine.visibleMemos(
            [before, atPlayhead, after],
            on: playhead,
            filter: .all,
            selectedPlanIDs: [],
            selectedTargetIDs: [],
            calendar: calendar,
            through: playhead
        )

        XCTAssertEqual(visible.map(\.text), [before.text, atPlayhead.text])
    }

    @MainActor
    func testAddingMapMemoKeepsLocationTimeAndTimelineLink() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let planStart = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 29, hour: 9)
        )!
        let planEnd = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 29, hour: 10)
        )!
        let plan = PlanRecord(
            title: "현장 방문",
            span: TimeSpan(
                start: planStart,
                end: planEnd
            ),
            categoryID: "work"
        )
        var stored = TaptionDataSnapshot.empty
        stored.plans = [plan]
        let repository = InMemoryPlanRepository(snapshot: stored)
        let model = AppModel(
            repository: repository,
            cloudSyncService: nil
        )
        await model.bootstrap()
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 0,
            horizontalAccuracy: 0,
            verticalAccuracy: 0
        )
        let occurredAt = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 29, hour: 9, minute: 30)
        )!

        let id = try XCTUnwrap(
            model.addMapMemo(
                text: "입구가 동쪽",
                kind: .idea,
                mapPoint: point,
                planID: plan.id,
                occurredAt: occurredAt
            )
        )
        let memo = try XCTUnwrap(model.snapshot.memos.first { $0.id == id })

        XCTAssertEqual(memo.mapPoint, point)
        XCTAssertEqual(memo.occurredAt, occurredAt)
        XCTAssertEqual(memo.planID, plan.id)
        XCTAssertEqual(memo.categoryID, plan.categoryID)
        XCTAssertEqual(model.timelineMemos(in: plan.span).map(\.id), [id])

        let deadline = Date.now.addingTimeInterval(2)
        var persisted = try await repository.load()
        while persisted.memos.map(\.id) != [id], Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
            persisted = try await repository.load()
        }
        XCTAssertEqual(persisted.memos.map(\.id), [id])
    }

    @MainActor
    func testAddingMapMemoAtPlanEndDoesNotLinkEndedPlan() async throws {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let plan = PlanRecord(
            title: "끝난 계획",
            span: TimeSpan(
                start: start,
                end: start.addingTimeInterval(3_600)
            ),
            categoryID: "work"
        )
        var stored = TaptionDataSnapshot.empty
        stored.plans = [plan]
        let model = AppModel(
            repository: InMemoryPlanRepository(snapshot: stored),
            cloudSyncService: nil,
            registersHealthBackgroundHandler: false
        )
        await model.bootstrap()

        let id = try XCTUnwrap(
            model.addMapMemo(
                text: "계획 종료 뒤 메모",
                kind: .idea,
                mapPoint: GeoPoint(
                    latitude: 37.5,
                    longitude: 127,
                    altitude: 0,
                    horizontalAccuracy: 0,
                    verticalAccuracy: 0
                ),
                occurredAt: plan.span.end,
                shouldPersist: false
            )
        )
        let memo = try XCTUnwrap(
            model.snapshot.memos.first { $0.id == id }
        )

        XCTAssertNil(memo.planID)
        XCTAssertEqual(memo.categoryID, MemoTimelineEngine.categoryID)
        model.discardMapMemoDraft(id)
    }

    @MainActor
    func testEditingMapMemoReevaluatesPlanLinkAtNewTime() async throws {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let firstPlan = PlanRecord(
            title: "첫 계획",
            span: TimeSpan(
                start: start,
                end: start.addingTimeInterval(3_600)
            ),
            categoryID: "work"
        )
        let secondStart = start.addingTimeInterval(7_200)
        let secondPlan = PlanRecord(
            title: "두 번째 계획",
            span: TimeSpan(
                start: secondStart,
                end: secondStart.addingTimeInterval(3_600)
            ),
            categoryID: "exercise"
        )
        var stored = TaptionDataSnapshot.empty
        stored.plans = [firstPlan, secondPlan]
        let model = AppModel(
            repository: InMemoryPlanRepository(snapshot: stored),
            cloudSyncService: nil,
            registersHealthBackgroundHandler: false
        )
        await model.bootstrap()

        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 0,
            horizontalAccuracy: 0,
            verticalAccuracy: 0
        )
        let memoID = try XCTUnwrap(
            model.addMapMemo(
                text: "시간 이동 메모",
                kind: .idea,
                mapPoint: point,
                planID: firstPlan.id,
                occurredAt: start.addingTimeInterval(1_800),
                shouldPersist: false
            )
        )

        XCTAssertTrue(
            model.updateMapMemo(
                memoID,
                text: "두 번째 계획으로 이동",
                kind: .decision,
                mapPoint: point,
                occurredAt: secondStart.addingTimeInterval(1_800)
            )
        )
        XCTAssertEqual(
            model.snapshot.memos.first { $0.id == memoID }?.planID,
            secondPlan.id
        )
        XCTAssertEqual(
            model.snapshot.memos.first { $0.id == memoID }?.categoryID,
            secondPlan.categoryID
        )

        XCTAssertTrue(
            model.updateMapMemo(
                memoID,
                text: "계획 종료 뒤 독립 메모",
                kind: .idea,
                mapPoint: point,
                occurredAt: secondPlan.span.end
            )
        )
        XCTAssertNil(model.snapshot.memos.first { $0.id == memoID }?.planID)
        XCTAssertEqual(
            model.snapshot.memos.first { $0.id == memoID }?.categoryID,
            MemoTimelineEngine.categoryID
        )
        model.discardMapMemoDraft(memoID)
    }

    func testMapMemoSaveRejectsInvalidGeometryAndDanglingPlanLink() async throws {
        let repository = InMemoryPlanRepository()
        let model = AppModel(
            repository: repository,
            cloudSyncService: nil
        )
        await model.bootstrap()

        let invalidPoint = GeoPoint(
            latitude: .nan,
            longitude: 127,
            altitude: 0,
            horizontalAccuracy: 0,
            verticalAccuracy: 0
        )
        XCTAssertNil(
            model.addMapMemo(
                text: "잘못된 좌표",
                kind: .idea,
                mapPoint: invalidPoint,
                occurredAt: .now
            )
        )
        XCTAssertTrue(model.snapshot.memos.isEmpty)

        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 0,
            horizontalAccuracy: 0,
            verticalAccuracy: 0
        )
        let id = try XCTUnwrap(
            model.addMapMemo(
                text: "계획 연결 확인",
                kind: .idea,
                mapPoint: point,
                planID: UUID(),
                occurredAt: .now
            )
        )
        XCTAssertNil(model.snapshot.memos.first { $0.id == id }?.planID)
    }

    func testMapMemoDraftIsNotPersistedWhenDiscarded() async throws {
        let repository = InMemoryPlanRepository()
        let model = AppModel(
            repository: repository,
            cloudSyncService: nil
        )
        await model.bootstrap()

        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 0,
            horizontalAccuracy: 0,
            verticalAccuracy: 0
        )
        let draftID = try XCTUnwrap(
            model.addMapMemo(
                text: "임시 지도 메모",
                kind: .idea,
                mapPoint: point,
                occurredAt: .now,
                shouldPersist: false
            )
        )

        XCTAssertNotNil(model.snapshot.memos.first { $0.id == draftID })
        model.discardMapMemoDraft(draftID)

        XCTAssertNil(model.snapshot.memos.first { $0.id == draftID })
        let stored = try await repository.load()
        XCTAssertTrue(stored.memos.isEmpty)
    }

    @MainActor
    func testMapMemoDraftStaysOutOfConcurrentPersistence() async throws {
        let repository = InMemoryPlanRepository()
        let model = AppModel(
            repository: repository,
            cloudSyncService: nil,
            registersHealthBackgroundHandler: false
        )
        await model.bootstrap()

        let draftID = try XCTUnwrap(
            model.addMapMemo(
                text: "저장 전 지도 메모",
                kind: .idea,
                mapPoint: GeoPoint(
                    latitude: 37.5,
                    longitude: 127,
                    altitude: 0,
                    horizontalAccuracy: 0,
                    verticalAccuracy: 0
                ),
                occurredAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
                shouldPersist: false
            )
        )

        await model.setNotificationsEnabled(false)

        XCTAssertNotNil(model.snapshot.memos.first { $0.id == draftID })
        let stored = try await repository.load()
        XCTAssertTrue(stored.memos.isEmpty)
        model.discardMapMemoDraft(draftID)
    }

    func testActionMemoWithoutMapPointKeepsBackwardDecodingCompatibility() throws {
        let memo = ActionMemo(kind: .idea, text: "기존 메모")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(memo)
            ) as? [String: Any]
        )
        object.removeValue(forKey: "mapPoint")
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ActionMemo.self, from: data)

        XCTAssertEqual(decoded.text, memo.text)
        XCTAssertNil(decoded.mapPoint)
    }

    func testMapStickersAreLimitedToSelectedDayAndMapPlacement() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 10
        )
        let selectedDay = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 29, hour: 9)
        )!
        let sameDay = MapSticker(
            title: "오늘",
            memo: "오늘 메모",
            placement: .map,
            point: point,
            occurredAt: selectedDay
        )
        let otherDay = MapSticker(
            title: "다음 날",
            placement: .map,
            point: point,
            occurredAt: calendar.date(
                from: DateComponents(year: 2026, month: 8, day: 30, hour: 9)
            )!
        )
        let schedule = MapSticker(
            title: "일정",
            placement: .schedule,
            occurredAt: selectedDay
        )

        let visible = MapStickerDisplayFilterEngine.visibleMapStickers(
            [sameDay, otherDay, schedule],
            on: selectedDay,
            calendar: calendar
        )

        XCTAssertEqual(visible.map(\.id), [sameDay.id])
        XCTAssertEqual(visible.first?.memo, "오늘 메모")
    }

    func testMapStickerMemoDecodesWhenMissingFromOlderArchive() throws {
        let sticker = MapSticker(
            title: "메모 스티커",
            memo: "현장 메모",
            placement: .map,
            point: GeoPoint(
                latitude: 37.5,
                longitude: 127,
                altitude: 0,
                horizontalAccuracy: 0,
                verticalAccuracy: 0
            ),
            occurredAt: .now
        )
        let encoded = try JSONEncoder().encode(sticker)
        let decoded = try JSONDecoder().decode(MapSticker.self, from: encoded)
        XCTAssertEqual(decoded.memo, sticker.memo)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "memo")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let legacy = try JSONDecoder().decode(MapSticker.self, from: legacyData)
        XCTAssertNil(legacy.memo)
    }

    func testCloudMergeKeepsStickersAndHonorsStickerDeletionTombstone() {
        let localSticker = MapSticker(
            title: "로컬",
            placement: .map,
            point: GeoPoint(
                latitude: 37.5,
                longitude: 127,
                altitude: 0,
                horizontalAccuracy: 0,
                verticalAccuracy: 0
            ),
            occurredAt: .now
        )
        let remoteSticker = MapSticker(
            title: "클라우드",
            placement: .schedule,
            occurredAt: .now
        )
        let deletedSticker = MapSticker(
            title: "삭제된 스티커",
            placement: .map,
            point: localSticker.point,
            occurredAt: .now
        )
        var local = TaptionDataSnapshot.empty
        local.stickers = [localSticker]
        local.settings.cloudDeletedRecordKeys = [
            CloudBackupRecordKey.sticker(deletedSticker.id)
        ]
        var remote = TaptionDataSnapshot.empty
        remote.stickers = [remoteSticker, deletedSticker]

        let merged = CloudSnapshotRecoveryEngine.merge(local: local, remote: remote)

        XCTAssertEqual(Set(merged.stickers.map(\.id)), [localSticker.id, remoteSticker.id])
        XCTAssertFalse(merged.stickers.contains(where: { $0.id == deletedSticker.id }))
    }
}
