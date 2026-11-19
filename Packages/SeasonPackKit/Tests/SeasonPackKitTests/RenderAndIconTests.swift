import CoreGraphics
import Foundation
import Testing
@testable import SeasonPackKit

struct RenderTests {
    private var christmas: SeasonPack { Fixture.seedPack("christmas") }

    @Test func treeIsDayThenLitFromSunsetUntilSunrise() {
        let motion = SeasonPackMotionPolicy()
        func state(_ h: Int, _ m: Int, fast: Date? = nil, motion: SeasonPackMotionPolicy = motion) -> SeasonPackHouseState {
            SeasonPackRenderer.houseState(pack: christmas, now: Fixture.date(2026, 12, 25, h, m), windows: Fixture.windows, motion: motion, fastUntil: fast)!
        }
        #expect(state(12, 0).isLit == false)
        #expect(state(12, 0).blink == .none)
        #expect(state(16, 49).isLit == false)
        #expect(state(16, 51).isLit == true)
        #expect(state(16, 51).blink == .slow(periodMs: 1400))
        #expect(state(3, 0).isLit == true)
        #expect(state(7, 41).isLit == false)
        #expect(state(20, 0, fast: Fixture.date(2026, 12, 25, 20, 0, ).addingTimeInterval(6)).blink == .fast(periodMs: 220))
        #expect(state(20, 0, fast: Fixture.date(2026, 12, 25, 19, 59)).blink == .slow(periodMs: 1400)) // 끝난 빠른 점멸
        #expect(state(16, 51).baseAsset == "house.tree")
        #expect(state(16, 51).litAsset == "house.tree.lit")
        #expect(state(16, 51).glowAsset == "house.tree.star")
    }

    @Test func reducedMotionAndLowPowerKeepAStaticLitPictureWithoutBlink() {
        for motion in [SeasonPackMotionPolicy(reduceMotion: true), SeasonPackMotionPolicy(lowPower: true)] {
            let state = SeasonPackRenderer.houseState(pack: christmas, now: Fixture.date(2026, 12, 25, 21), windows: Fixture.windows, motion: motion, fastUntil: Fixture.date(2027, 1, 1))!
            #expect(state.isLit)
            #expect(state.blink == .none)
        }
    }

    @Test func withoutSunInfoTheTreeStaysUnlitInsteadOfGuessing() {
        let blind = SeasonPackWindows(calendar: Fixture.calendar, sun: { _ in SeasonPackSunTimes() })
        let state = SeasonPackRenderer.houseState(pack: christmas, now: Fixture.date(2026, 12, 25, 21), windows: blind, motion: .init())!
        #expect(!state.isLit)
    }

    @Test func blinkLevelIsBoundedAndDeterministic() {
        let at = Date(timeIntervalSinceReferenceDate: 12_345.678)
        for blink in [SeasonPackHouseState.Blink.slow(periodMs: 1400), .fast(periodMs: 220)] {
            let level = SeasonPackRenderer.blinkLevel(blink, at: at)
            #expect((0.34...1.0).contains(level))
            #expect(level == SeasonPackRenderer.blinkLevel(blink, at: at))
        }
        #expect(SeasonPackRenderer.blinkLevel(.none, at: at) == 1)
    }

    @Test func plantingDayStagesPickPictureByTimeOfDay() {
        let extra: [String: Any] = ["slots": ["house": ["base": "img.a", "stages": [["from": "06:00", "image": "img.a"], ["from": "12:00", "image": "img.b"]]]],
                                    "assets": [["id": "img.a", "path": "a.png", "sha256": SeasonPackValidation.sha256Hex(Data("png-bytes".utf8)), "bytes": 9, "kind": "image"],
                                               ["id": "img.b", "path": "a.png", "sha256": SeasonPackValidation.sha256Hex(Data("png-bytes".utf8)), "bytes": 9, "kind": "image"]]]
        let pack = SeasonPack(manifest: Fixture.manifest(Fixture.pack(extra: extra).manifest), directory: URL(fileURLWithPath: "/x"), source: .seed)
        func base(_ h: Int) -> String { SeasonPackRenderer.houseState(pack: pack, now: Fixture.date(2026, 12, 25, h), windows: Fixture.windows, motion: .init())!.baseAsset }
        #expect(base(7) == "img.a")
        #expect(base(13) == "img.b")
        #expect(base(2) == "img.a")
    }

    @Test func accessoriesOverrideOnlyTheirOwnSlotAndRestoreWhenThePackEnds() {
        let own = SeasonPackAccessorySlots(hat: "tophat", scarf: "plaid", ribbon: nil as String?)
        let packSlots = SeasonPackAccessorySlots(hat: "santa", scarf: nil as String?, ribbon: "antlers")
        let during = own.overridden(by: packSlots)
        #expect(during == SeasonPackAccessorySlots(hat: "santa", scarf: "plaid", ribbon: "antlers")) // 목도리는 원래 것이 남는다
        #expect(own.overridden(by: nil) == own) // 기간이 끝나면 원래 장식 그대로
        #expect(own == SeasonPackAccessorySlots(hat: "tophat", scarf: "plaid", ribbon: nil)) // 원본은 지워지지 않았다
    }

    @Test func christmasHasThreeAccessorySlotsAndSeparateOutfit() {
        let slots = christmas.manifest.slots!
        #expect(slots.accessory?.layers.hat != nil && slots.accessory?.layers.scarf != nil && slots.accessory?.layers.ribbon != nil)
        #expect(Set(slots.outfit?.keys.map { $0 } ?? []) == ["white", "calico", "mackerel"])
        #expect(slots.outfit?["white"]?.first?.asset == "outfit.coat") // 의상과 악세사리는 다른 슬롯
    }

    @Test func yearTextSlotDrawsTheRuntimeYearAndRollsWhenTheYearChanges() {
        let slot = christmas.manifest.textSlots!.first { $0.id == "year" }!
        #expect(SeasonPackTextSlots.text(for: slot, year: 2026, memoLine: nil) == "2026")
        #expect(SeasonPackTextSlots.text(for: slot, year: 2027, memoLine: nil) == "2027") // 그림에 굽지 않았다
        #expect(slot.transition == "roll")
        #expect(SeasonPackYearRoll.plan(shownYear: 2026, currentYear: 2027).needsRoll)
        #expect(!SeasonPackYearRoll.plan(shownYear: 2027, currentYear: 2027).needsRoll)
        #expect(!SeasonPackYearRoll.plan(shownYear: nil, currentYear: 2027).needsRoll) // 처음 보는 해는 굴리지 않는다
        var memo = slot; memo.content = "memo"
        #expect(SeasonPackTextSlots.text(for: memo, year: 2026, memoLine: "첫 줄") == "첫 줄")
        var fixed = slot; fixed.content = "HAPPY"
        #expect(SeasonPackTextSlots.text(for: fixed, year: 2026, memoLine: nil) == "HAPPY")
    }

    @Test func layerPlacementUsesAnchorScaleAndOffset() {
        let layer = SeasonPackManifest.Layer(asset: "x", anchor: "head", scale: 0.5, offset: [0, -0.1])
        let frame = SeasonPackLayerPlacement.frame(for: layer, imageSize: CGSize(width: 100, height: 50), in: CGSize(width: 200, height: 200))
        #expect(frame.width == 100 && frame.height == 50)
        #expect(frame.midX == 100)
        #expect(abs(frame.midY - 20) < 0.001) // (0.2 - 0.1) * 200
    }

    @Test func missingPictureFallsBackWithoutCrashing() {
        let ghost = SeasonPack(manifest: christmas.manifest, directory: URL(fileURLWithPath: "/nonexistent"), source: .installed)
        #expect(SeasonPackImageCache.shared.image(pack: ghost, asset: "house.tree") == nil)
        #expect(SeasonPackImageCache.shared.image(pack: christmas, asset: "house.tree") != nil)
    }
}

struct IconRegistryTests {
    private var sample: SeasonPack { Fixture.seedPack("sample") }
    private let day = Fixture.date(1970, 1, 1, 12)

    @Test func sampleManifestEntryGivesIconAndMenuWithoutAppCode() {
        let icons = SeasonPackIconRegistry.visibleIcons(packs: [sample], now: day, language: "ko", calendar: Fixture.calendar)
        #expect(icons.map(\.icon.id) == ["sample.icon"]) // ① 아이콘이 뜬다
        let menu = SeasonPackMenuModel(icons[0].icon.menu, language: "ko") // ② 누르면 열리는 메뉴
        #expect(menu.title == "표본 메뉴")
        #expect(menu.sections.flatMap(\.items).count == 2)
    }

    @Test func removingTheManifestEntryRemovesTheIcon() {
        var edited = sample
        edited.manifest.menuIcons = []
        #expect(SeasonPackIconRegistry.visibleIcons(packs: [edited], now: day, language: "ko", calendar: Fixture.calendar).isEmpty) // ③
        var added = sample
        var second = added.manifest.menuIcons![0]
        second.id = "sample.second"; second.anchor = .init(dx: 0, dy: 80)
        added.manifest.menuIcons?.append(second)
        #expect(SeasonPackIconRegistry.visibleIcons(packs: [added], now: day, language: "ko", calendar: Fixture.calendar).count == 2) // 항목만 더해도 붙는다
    }

    @Test func sampleIsNeverActiveOutsideItsOwnDay() {
        #expect(Fixture.windows.activePack(in: [sample.manifest], at: Fixture.date(2026, 12, 25)) == nil)
        #expect(Fixture.windows.activePack(in: [sample.manifest], at: day)?.id == "sample")
    }

    @Test func outsideVisibleRangeThereIsNoIconAtAll() {
        let christmas = Fixture.seedPack("christmas")
        func count(_ date: Date) -> Int { SeasonPackIconRegistry.visibleIcons(packs: [christmas], now: date, language: "ko", calendar: Fixture.calendar).count }
        #expect(count(Fixture.date(2026, 12, 18, 23, 59)) == 0)
        #expect(count(Fixture.date(2026, 12, 19, 0, 0)) == 1)
        #expect(count(Fixture.date(2026, 12, 30, 23, 59)) == 1)
        #expect(count(Fixture.date(2026, 12, 31, 0, 0)) == 0)
    }

    @Test func overlappingAnchorsPushDownByFortyFourAndFoldAtTheScreenEdge() {
        func icon(_ id: String, priority: Int, dy: Double) -> [String: Any] {
            ["id": id, "icon": "img.a", "priority": priority, "anchor": ["dx": 46, "dy": dy],
             "menu": ["sections": [["items": [["id": "t", "kind": "text", "text": ["ko": "x"]]]]]]]
        }
        let extra: [String: Any] = ["menuIcons": [icon("low", priority: 1, dy: -30), icon("high", priority: 9, dy: -30), icon("third", priority: 5, dy: -30)]]
        let pack = SeasonPack(manifest: Fixture.manifest(Fixture.pack(extra: extra).manifest), directory: URL(fileURLWithPath: "/x"), source: .seed)
        let placed = SeasonPackIconRegistry.visibleIcons(packs: [pack], now: Fixture.date(2026, 12, 25), language: "ko", calendar: Fixture.calendar)
        #expect(placed.map(\.icon.id) == ["high", "third", "low"])
        #expect(placed.map(\.offset.y) == [-30, 14, 58])
        let tight = SeasonPackIconRegistry.visibleIcons(packs: [pack], now: Fixture.date(2026, 12, 25), language: "ko", calendar: Fixture.calendar,
                                                       origin: CGPoint(x: 100, y: 120), bounds: CGRect(x: 0, y: 0, width: 300, height: 190))
        #expect(tight.allSatisfy { 120 + $0.offset.y <= 190 - 22 }) // 아래로 넘치면 위로 접는다
    }

    @Test func iconWithOnlyUnknownKindsIsHiddenAndLinksNeedHttps() {
        let extra: [String: Any] = ["menuIcons": [["id": "odd", "icon": "img.a", "anchor": ["dx": 0, "dy": 0],
                                                  "menu": ["sections": [["items": [["id": "z", "kind": "hologram"]]]]]]]]
        let pack = SeasonPack(manifest: Fixture.manifest(Fixture.pack(extra: extra).manifest), directory: URL(fileURLWithPath: "/x"), source: .seed)
        #expect(SeasonPackIconRegistry.visibleIcons(packs: [pack], now: Fixture.date(2026, 12, 25), language: "ko", calendar: Fixture.calendar).isEmpty)
    }

    @Test func menuItemsParseAllFiveKindsFromTheManifest() {
        let menu = SeasonPackManifest.Menu(title: .init(ko: "제", en: "T"), sections: [.init(title: nil, items: [
            .init(id: "a", kind: "text", label: nil, text: .init(ko: "글", en: "txt"), url: nil, maxLength: nil, readOnlyAfter: nil),
            .init(id: "b", kind: "memo", label: .init(ko: "메모", en: "Memo"), text: nil, url: nil, maxLength: 120, readOnlyAfter: "2027-01-01T23:59"),
            .init(id: "c", kind: "credits", label: nil, text: nil, url: nil, maxLength: nil, readOnlyAfter: nil),
            .init(id: "d", kind: "link", label: .init(ko: "링크", en: "Link"), text: nil, url: "https://example.com/x", maxLength: nil, readOnlyAfter: nil),
            .init(id: "e", kind: "toggle", label: .init(ko: "켜기", en: "On"), text: nil, url: nil, maxLength: nil, readOnlyAfter: nil),
        ])])
        let model = SeasonPackMenuModel(menu, language: "en")
        #expect(model.sections.flatMap(\.items).map(\.id) == ["a", "b", "c", "d", "e"])
        #expect(model.title == "T")
    }

    @Test func memoIsSavedAndDeletedAndLocksAfterTheDeadline() throws {
        let store = SeasonPackMemoStore(directory: Fixture.tempDirectory())
        let before = Fixture.date(2027, 1, 1, 12)
        let after = Fixture.date(2027, 1, 2, 0, 0)
        let saved = try store.save("올해는 운동하기 그리고 더 많이 걷기", packID: "newyear", itemID: "goal", maxLength: 10, readOnlyAfter: "2027-01-01T23:59", now: before, calendar: Fixture.calendar)
        #expect(saved.text.count == 10) // maxLength로 자른다
        #expect(store.load(packID: "newyear", itemID: "goal")?.text == saved.text)
        #expect(store.firstLine(packID: "newyear", itemID: "goal", limit: 4)?.hasSuffix("…") == true)
        #expect(throws: SeasonPackMemoError.readOnly) {
            try store.save("바꾸기", packID: "newyear", itemID: "goal", maxLength: 10, readOnlyAfter: "2027-01-01T23:59", now: after, calendar: Fixture.calendar)
        }
        #expect(throws: SeasonPackMemoError.readOnly) {
            try store.delete(packID: "newyear", itemID: "goal", readOnlyAfter: "2027-01-01T23:59", now: after, calendar: Fixture.calendar)
        }
        #expect(store.load(packID: "newyear", itemID: "goal")?.text == saved.text) // 잠긴 뒤에도 읽기는 된다
        try store.delete(packID: "newyear", itemID: "goal", readOnlyAfter: nil, now: after, calendar: Fixture.calendar)
        #expect(store.load(packID: "newyear", itemID: "goal") == nil)
        #expect(throws: SeasonPackMemoError.badName) {
            try store.save("x", packID: "../evil", itemID: "goal", maxLength: 5, readOnlyAfter: nil)
        }
        #expect(SeasonPackStore.isExcludedFromBackup(store.directory))
    }
}
