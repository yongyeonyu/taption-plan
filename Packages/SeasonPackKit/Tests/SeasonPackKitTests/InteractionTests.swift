import Foundation
import Testing
@testable import SeasonPackKit

struct LyricTests {
    private func cue(_ at: Int, _ text: String) -> SeasonPackManifest.LyricTrack.Cue { .init(atMs: at, text: SeasonPackText(ko: text, en: text)) }

    @Test func cuesAreOrderedReplacedByTheNextAndGoneTwoSecondsAfterTheLast() {
        let timeline = SeasonPackLyricTimeline(cues: [cue(3000, "b"), cue(900, "a"), cue(6000, "c")])
        #expect(timeline.cue(atMs: 0) == nil)
        #expect(timeline.cue(atMs: 900)?.text.resolve(language: "ko") == "a")
        #expect(timeline.cue(atMs: 2999)?.text.resolve(language: "ko") == "a")
        #expect(timeline.cue(atMs: 3000)?.text.resolve(language: "ko") == "b") // 다음 큐에서 교체
        #expect(timeline.cue(atMs: 8000)?.text.resolve(language: "ko") == "c")
        #expect(timeline.cue(atMs: 8001) == nil) // 마지막 큐 뒤 2초에 사라짐
        #expect(timeline.totalMs == 8000)
    }

    @Test func christmasCuesFollowTheSynthesizedNotesAndAreInOrder() {
        let pack = Fixture.seedPack("christmas")
        let cues = pack.manifest.lyricCues(audio: "carol")
        #expect(cues.map(\.atMs) == cues.map(\.atMs).sorted())
        #expect(cues.first?.atMs == 400) // 곡이 시작하는 0.4초
        let duration = pack.manifest.audio!.first!.durationMs!
        #expect(cues.last!.atMs <= duration)
        #expect(cues.allSatisfy { !$0.text.resolve(language: "ko").isEmpty && !$0.text.resolve(language: "en").isEmpty })
    }

    @Test func noAudioMeansNoLyricsBubble() {
        let pack = Fixture.seedPack("christmas")
        #expect(pack.manifest.audioAssetID("carol") == "carol.jingle")
        #expect(pack.manifest.audioAssetID("missing") == nil)
        #expect(pack.manifest.lyricCues(audio: "missing").isEmpty)
        #expect(SeasonPackLyricTimeline(cues: []).cue(atMs: 1000) == nil)
    }
}

struct ScenarioTests {
    private func interactions() -> [SeasonPackManifest.Interaction] { Fixture.seedPack("christmas").manifest.interactions! }

    @Test func treeTapRunsBlinkThenCarolThenLyricsInOrder() {
        let engine = SeasonPackScenarioEngine(interactions: interactions(), characterID: "white")
        #expect(engine.tap(target: "house", audioPlaying: false) == [.blink(seconds: 6), .playAudio("carol"), .lyrics(audio: "carol", restart: false)])
    }

    @Test func tappingWhileThePlayerIsBusyRestartsLyricsAndBlinkButNotTheSound() {
        let engine = SeasonPackScenarioEngine(interactions: interactions(), characterID: "white")
        let effects = engine.tap(target: "house", audioPlaying: true)
        #expect(effects == [.blink(seconds: 6), .lyrics(audio: "carol", restart: true)])
        #expect(!effects.contains(.playAudio("carol")))
        #expect(engine.tap(target: "elsewhere", audioPlaying: false).isEmpty)
    }

    @Test func characterConditionBranchesLikeValentine() {
        let json = """
        [{"id":"v.w","target":"house","on":"tap","when":{"characterID":"white"},"actions":[{"kind":"blink","seconds":2}]},
         {"id":"v.c","target":"house","on":"tap","when":{"characterID":"calico"},"actions":[{"kind":"blink","seconds":3},{"kind":"hologram"}]}]
        """
        let list = try! JSONDecoder().decode([SeasonPackManifest.Interaction].self, from: Data(json.utf8))
        #expect(SeasonPackScenarioEngine(interactions: list, characterID: "white").tap(target: "house", audioPlaying: false) == [.blink(seconds: 2)])
        #expect(SeasonPackScenarioEngine(interactions: list, characterID: "calico").tap(target: "house", audioPlaying: false) == [.blink(seconds: 3)]) // 모르는 동작은 건너뜀
        #expect(SeasonPackScenarioEngine(interactions: list, characterID: "mackerel").tap(target: "house", audioPlaying: false).isEmpty)
    }
}

struct DemoThrottleTests {
    private let ref = SeasonPackRef(id: "christmas", version: 1)
    private func throttle() -> SeasonPackDemoThrottle { SeasonPackDemoThrottle(defaults: SeasonPackDefaults(suiteName: Fixture.suite())) }

    @Test func firstDemoIsImmediateThenThreeToFiveMinutesApart() {
        let t = throttle()
        let now = Fixture.date(2026, 12, 25, 21)
        #expect(t.nextFlight(ref: ref, now: now, lastFlight: nil, interval: nil, reduced: false) == now)
        t.markFirstDemoShown(ref)
        for offset in 0..<50 {
            let last = now.addingTimeInterval(Double(offset) * 61)
            let next = t.nextFlight(ref: ref, now: last, lastFlight: last, interval: [180, 300], reduced: false)!
            #expect((180...300).contains(next.timeIntervalSince(last)))
            #expect(next == t.nextFlight(ref: ref, now: last, lastFlight: last, interval: [180, 300], reduced: false)) // 같은 입력이면 같은 간격
        }
    }

    @Test func demoShownIsPerVersionAndNewVersionDemosOnceMore() {
        let t = throttle()
        t.markFirstDemoShown(ref)
        #expect(t.hasShownFirstDemo(ref))
        #expect(!t.hasShownFirstDemo(SeasonPackRef(id: "christmas", version: 2)))
    }

    @Test func reducedMotionOrLowPowerSkipsEverythingIncludingTheDemo() {
        let t = throttle()
        #expect(t.nextFlight(ref: ref, now: Date(), lastFlight: nil, interval: nil, reduced: true) == nil)
        t.markFirstDemoShown(ref)
        #expect(t.nextFlight(ref: ref, now: Date(), lastFlight: Date(), interval: nil, reduced: true) == nil)
    }

    @Test func burstThrowsEighteenGiftsOfThreeKindsAndFallsBackDown() {
        let gifts = SeasonPackActorMath.gifts(count: 18, imageCount: 3, seed: 7)
        #expect(gifts.count == 18)
        #expect(Set(gifts.map(\.image)) == [0, 1, 2])
        #expect(gifts == SeasonPackActorMath.gifts(count: 18, imageCount: 3, seed: 7))
        let gift = gifts[0]
        let early = SeasonPackActorMath.giftOffset(gift, at: 0.15)
        let late = SeasonPackActorMath.giftOffset(gift, at: SeasonPackActorMath.burstSeconds)
        #expect(early.dy < 0) // 위로 튀었다가
        #expect(late.dy > early.dy) // 중력으로 내려온다
        let flight = SeasonPackManifest.Actor.Flight(seconds: 9, start: [-0.2, 0.3], end: [1.2, 0.18])
        #expect(SeasonPackActorMath.flightPoint(flight, progress: 0).x == -0.2)
        #expect(SeasonPackActorMath.flightPoint(flight, progress: 1).x == 1.2)
    }
}

/// 소리 재생기 대역: 재생 중이면 새 요청을 거절하고, 멈춘 횟수를 센다.
@MainActor
final class MockSound: SeasonPackSoundPlaying {
    var isPlaying = false
    var plays = 0
    var stops = 0
    var finish: (@MainActor () -> Void)?
    func play(url: URL, onFinish: @escaping @MainActor () -> Void) -> Bool {
        guard !isPlaying else { return false }
        isPlaying = true; plays += 1; finish = onFinish
        return true
    }
    func stop() { isPlaying = false; stops += 1 }
}

@MainActor
struct CenterTests {
    private func make(at now: Date, character: String = "white", language: String = "ko") async -> (SeasonPackCenter, FakeHost) {
        let center = SeasonPackCenter()
        center.calendar = Fixture.calendar
        let host = FakeHost(now: now, language: language, character: character)
        center.configure(host: host, configuration: .init(storeRoot: Fixture.tempDirectory(), urlForKey: { _ in nil }, defaultsSuite: Fixture.suite()))
        await center.reload()
        return (center, host)
    }

    @Test func noRenderAtAllBeforeAndAfterThePeriod() async {
        for date in [Fixture.date(2026, 12, 18, 23, 59), Fixture.date(2026, 12, 31, 0, 0), Fixture.date(2026, 7, 4, 12)] {
            let (center, host) = await make(at: date)
            #expect(center.active == nil)
            #expect(center.houseState() == nil)
            #expect(center.placedIcons().isEmpty)
            #expect(center.shareCardHouseImage() == nil)
            #expect(center.characterLayers().isEmpty)
            #expect(center.bubblePhrases(language: "ko").isEmpty)
            #expect(host.presentedAnnouncements.isEmpty)
        }
    }

    @Test func duringThePeriodTheSeedActivatesWithoutAServer() async {
        let (center, host) = await make(at: Fixture.date(2026, 12, 25, 21))
        #expect(center.active?.id == "christmas")
        #expect(center.active?.source == .seed)
        #expect(center.houseState()?.isLit == true)
        #expect(center.placedIcons().count == 1)
        #expect(center.shareCardHouseImage() != nil)
        #expect(center.bubblePhrases(language: "ko").count == 14)
        #expect(center.bubblePhrases(language: "en").first == "Shall we light the tree? 🎄")
        #expect(host.presentedAnnouncements == ["christmas-2026"]) // 기존 공지 시트로 한 번
        center.recompute()
        #expect(host.presentedAnnouncements.count == 1)
    }

    @Test func movingTheClockForwardDoesNotOpenTheEvent() async {
        let (center, host) = await make(at: Fixture.date(2026, 11, 1, 12))
        #expect(center.active == nil)
        center.clock?.recordServerDate(host.now()) // 서버가 진짜 시각을 알려 줬다
        host.set(Fixture.date(2026, 12, 25, 21)) // 사용자가 날짜를 앞으로 돌림
        center.recompute()
        #expect(center.active == nil)
        #expect(center.houseState() == nil)
    }

    @Test func everyCatGetsTheSameCostumeAndOnlyTheHatIsAFile() async {
        for character in ["white", "calico", "mackerel"] {
            let (center, _) = await make(at: Fixture.date(2026, 12, 25, 21), character: character)
            #expect(center.characterLayers(includeHat: false).isEmpty) // 겉옷·목도리 그림 없음: 리그가 직접 그린다
            #expect(center.accessoryImageData("hat") != nil)
            #expect(center.costume?.redNose == true && center.costume?.antlers != nil)
            #expect(center.costume?.scarf != nil && center.costume?.ribbon != nil)
            #expect(center.activeSnow != nil) // 트리가 나오면 눈꽃도 같이
        }
    }

    @Test func treeTapPlaysOnceBlinksFastAndShowsLyricsThenIgnoresTapsWhilePlaying() async throws {
        let (center, _) = await make(at: Fixture.date(2026, 12, 25, 21))
        let sound = MockSound()
        center.stage.useSound(sound)
        center.stage.houseTapped()
        #expect(sound.plays == 1)
        #expect(center.stage.fastBlinkUntil != nil)
        #expect(center.houseState()?.blink == .fast(periodMs: 220))
        try await Task.sleep(for: .milliseconds(700))
        #expect(center.stage.lyricText == "딸랑딸랑, 종이 울려요")
        center.stage.houseTapped() // 재생 중 다시 누름
        #expect(sound.plays == 1) // 소리는 끝까지: 새로 시작하지 않는다
        sound.finish?()
        #expect(center.stage.isAudioPlaying == true)
        center.stage.pause() // 화면 이탈
        #expect(sound.stops >= 1)
        #expect(center.stage.lyricText == nil)
        #expect(center.stage.fastBlinkUntil == nil)
    }

    @Test func lyricsAreNotStoredAnywhere() async throws {
        let (center, _) = await make(at: Fixture.date(2026, 12, 25, 21))
        center.stage.useSound(MockSound())
        center.stage.houseTapped()
        try await Task.sleep(for: .milliseconds(600))
        #expect(center.stage.lyricText != nil)
        // 가사는 스테이지 메모리에만 있다: 팩 폴더와 메모 폴더에 새 파일이 생기지 않는다.
        let files = (try? FileManager.default.subpathsOfDirectory(atPath: center.store!.root.path)) ?? []
        #expect(files.allSatisfy { !$0.contains("lyric") })
        center.stage.stopAll()
    }

    @Test func santaFliesRightAwayOnceThenTapFreezesItAndThrowsGifts() async throws {
        let (center, _) = await make(at: Fixture.date(2026, 12, 25, 21))
        try await Task.sleep(for: .milliseconds(400))
        #expect(center.stage.flight != nil) // 처음 한 번은 바로
        center.stage.actorTapped(at: CGPoint(x: 100, y: 100))
        #expect(center.stage.flight?.frozenProgress != nil)
        #expect(center.stage.burst?.gifts.count == 18)
        try await Task.sleep(for: .milliseconds(1500))
        #expect(center.stage.burst == nil)
        #expect(center.stage.flight == nil)
        // 같은 팩·버전은 다시 시연하지 않는다.
        #expect(SeasonPackDemoThrottle(defaults: center.defaults).hasShownFirstDemo(SeasonPackRef(id: "christmas", version: 1)))
    }

    @Test func tapAnywhereStopsOnlyThatRound() async throws {
        let (center, _) = await make(at: Fixture.date(2026, 12, 25, 21))
        try await Task.sleep(for: .milliseconds(400))
        #expect(center.stage.flight != nil)
        center.noteUserTouch()
        #expect(center.stage.flight == nil)
        center.stage.stopAll()
    }

    @Test func reducedMotionNeverFliesNotEvenTheDemo() async throws {
        let center = SeasonPackCenter()
        center.calendar = Fixture.calendar
        center.motion = SeasonPackMotionPolicy(reduceMotion: true)
        let host = FakeHost(now: Fixture.date(2026, 12, 25, 21))
        center.configure(host: host, configuration: .init(storeRoot: Fixture.tempDirectory(), urlForKey: { _ in nil }, defaultsSuite: Fixture.suite()))
        await center.reload()
        try await Task.sleep(for: .milliseconds(500))
        #expect(center.active != nil)
        #expect(center.stage.flight == nil)
        #expect(center.houseState()?.blink == SeasonPackHouseState.Blink.none)
    }

    @Test func deleteAllWipesPacksMemosAndDemoRecords() async {
        let (center, _) = await make(at: Fixture.date(2026, 12, 25, 21))
        let root = center.store!.root
        try? center.memoStore?.save("hi", packID: "christmas", itemID: "note", maxLength: 10, readOnlyAfter: nil)
        center.deleteAll()
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(center.active == nil)
        #expect(!SeasonPackDemoThrottle(defaults: center.defaults).hasShownFirstDemo(SeasonPackRef(id: "christmas", version: 1)))
    }
}

struct ExtensibilityTests {
    @Test func everyFutureEventShapeParsesFromTheManifestAlone() throws {
        let extra: [String: Any] = [
            "slots": ["house": ["base": "img.a", "stages": [["from": "06:00", "image": "img.a"]]],
                      "accessory": ["hat": ["asset": "img.a", "anchor": "head", "scale": 0.4, "offset": [0, -0.1], "z": 2], "scarf": "img.a", "ribbon": "img.a"],
                      "outfit": ["white": [["asset": "img.a", "anchor": "body"]], "calico": [], "mackerel": []],
                      "bubbles": ["pool": [["ko": "세배 드려요", "en": "Happy new year"]], "memoItem": "goal"]],
            "actors": [["id": "magpie", "image": "img.a", "flight": ["seconds": 6, "start": [0, 0.2], "end": [1, 0.1]]],
                       ["id": "second", "image": "img.a", "flight": ["seconds": 4, "start": [1, 0.5], "end": [0, 0.4]], "when": ["characterID": "calico"]]],
            "interactions": [["id": "bow", "target": "character", "on": "tap", "when": ["characterID": "calico"], "actions": [["kind": "lyrics", "audio": "x"]]]],
            "audio": [["id": "bell", "asset": "img.a", "license": ["title": "t", "creator": "c", "license": "CC0-1.0", "source": "https://example.com"]],
                      ["id": "bell.cat", "asset": "img.a", "license": ["title": "t2", "creator": "c", "license": "CC0-1.0", "source": "https://example.com"]]],
            "menuIcons": [["id": "memo", "icon": "img.a", "anchor": ["dx": 46, "dy": -30], "visibleFrom": "2026-12-30T00:00", "visibleTo": "2027-01-01T23:59",
                           "menu": ["sections": [["items": [["id": "goal", "kind": "memo", "maxLength": 200, "readOnlyAfter": "2027-01-01T23:59"]]]]]]],
            "textSlots": [["id": "year", "rect": [0.3, 0.6, 0.4, 0.2], "content": "year", "transition": "roll"]],
        ]
        let windows: [[String: Any]] = [Fixture.window(12, 31, 1, 1, fromTime: "23:50"), ["rule": ["kind": "nthWeekday", "month": 11, "weekday": 5, "nth": 3]]]
        let built = Fixture.pack(windows: windows, extra: extra)
        let manifest = try JSONDecoder().decode(SeasonPackManifest.self, from: built.manifest)
        #expect(SeasonPackValidation.validate(manifest, files: built.files, appBuild: 1).isValid)
        #expect(manifest.actors?.count == 2)
        #expect(manifest.audio?.count == 2) // 원본 + 변조본 두 파일
        #expect(manifest.slots?.accessory?.hat?.scale == 0.4)
        #expect(manifest.slots?.accessory?.scarf?.asset == "img.a") // 문자열로도 쓸 수 있다
        #expect(manifest.slots?.house?.stages?.count == 1)
        #expect(manifest.slots?.bubbles?.memoItem == "goal")
        #expect(Fixture.windows.isActive(manifest, at: Fixture.date(2026, 12, 31, 23, 55)))
        #expect(!Fixture.windows.isActive(manifest, at: Fixture.date(2026, 12, 31, 23, 40)))
        #expect(Fixture.windows.isActive(manifest, at: Fixture.date(2027, 1, 1, 12)))
        #expect(Fixture.windows.isActive(manifest, at: Fixture.date(2027, 11, 18, 10)))
    }
}
