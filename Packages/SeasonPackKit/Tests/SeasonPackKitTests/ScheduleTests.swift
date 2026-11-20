import Foundation
import Testing
@testable import SeasonPackKit

/// 운영 기간(카탈로그 `schedule`, ADM1120A02): 운영자가 정한 기간에만 켜고, 같은 팩을 여러 번 열 수 있으며,
/// 같은 버전은 다시 받지 않고 새 버전은 옛 버전을 지운다.
struct ScheduleTests {
    private let weekend = SeasonPackIndex.Span(from: "2026-11-21T00:00:00+09:00", to: "2026-11-23T00:00:00+09:00")
    private let midweek = SeasonPackIndex.Span(from: "2026-11-25T00:00:00+09:00", to: "2026-11-30T00:00:00+09:00")

    private func windows(_ spans: [SeasonPackIndex.Span]?, id: String = "christmas") -> SeasonPackWindows {
        var windows = Fixture.windows
        if let spans { windows.schedules = [id: spans.compactMap(\.interval)] }
        return windows
    }

    @Test func spansParseAndBadOnesAreDropped() throws {
        let duration = try #require(weekend.interval).duration
        #expect(duration == TimeInterval(2 * 86400), "duration \(duration)")
        #expect(SeasonPackIndex.Span(from: "2026-11-21T00:00:00.5+09:00", to: "2026-11-22T00:00:00Z").interval != nil)
        #expect(SeasonPackIndex.Span(from: "2026-11-23T00:00:00+09:00", to: "2026-11-21T00:00:00+09:00").interval == nil)
        #expect(SeasonPackIndex.Span(from: "11/21", to: "11/23").interval == nil)
    }

    @Test func scheduleOverridesManifestWindowsAndCanReopenTheSamePack() {
        let pack = Fixture.manifest(Fixture.pack(id: "christmas", version: 1).manifest) // 매니페스트 창은 12/19~12/30
        let scheduled = windows([weekend, midweek])
        #expect(scheduled.isActive(pack, at: Fixture.date(2026, 11, 21, 10)))      // 이번 주말
        #expect(!scheduled.isActive(pack, at: Fixture.date(2026, 11, 23, 9)))      // 월요일엔 없어짐
        #expect(scheduled.isActive(pack, at: Fixture.date(2026, 11, 26, 20)))      // 수요일부터 다시
        #expect(!scheduled.isActive(pack, at: Fixture.date(2026, 12, 24, 20)))     // 운영 기간이 있으면 매니페스트 창은 보지 않는다
        #expect(!windows([]).isActive(pack, at: Fixture.date(2026, 12, 24, 20)))  // 빈 기간 = 꺼 둠
        #expect(windows(nil).isActive(pack, at: Fixture.date(2026, 12, 24, 20)))  // 기간이 없으면 매니페스트 창 그대로
        #expect(windows([weekend], id: "other").isActive(pack, at: Fixture.date(2026, 12, 24, 20)))
    }

    @Test func timerWakesAtScheduleEdges() {
        let pack = Fixture.manifest(Fixture.pack(id: "christmas", version: 1).manifest)
        let next = SeasonPackTriggers.nextTransition(packs: [pack], after: Fixture.date(2026, 11, 22, 23, 30), windows: windows([weekend]))
        #expect(next == weekend.interval?.end)
    }

    private func serve(version: Int, schedule: [SeasonPackIndex.Span]?, at when: Date) throws -> (archive: Data, transport: FakeTransport) {
        let built = Fixture.pack(id: "christmas", version: version)
        let archive = try SeasonPackArchive.encode(manifestData: built.manifest, files: built.files)
        let entry = SeasonPackIndex.Entry(id: "christmas", version: version,
                                          archive: .init(key: "packs/season/christmas/\(version)/christmas-\(version).bpack", bytes: archive.count, sha256: SeasonPackValidation.sha256Hex(archive)),
                                          windows: Fixture.manifest(built.manifest).event.windows, schedule: schedule)
        let index = SeasonPackIndex(format: SeasonPackIndex.format, schema: 1, packs: [entry])
        return (archive, FakeTransport(["packs/season/index.json": SeasonPackReply(status: 200, data: try JSONEncoder().encode(index), etag: "\"v\(version)\"", serverDate: when)]))
    }

    private func fetcher(_ transport: FakeTransport, engine: FakeEngine, store: SeasonPackStore, suite: String, now: Date, known: Int = 0) -> SeasonPackFetcher {
        let downloader = SeasonPackDownloader(directory: store.root.appendingPathComponent(".downloads"), engine: engine, urlForKey: { URL(string: "https://relay.example.invalid/\($0)") },
                                              freeBytes: { 1 << 40 })
        return SeasonPackFetcher(store: store, transport: transport, defaults: SeasonPackDefaults(suiteName: suite), appBuild: { 1000 }, now: { now },
                                 windows: { Fixture.windows }, knownVersion: { _ in known }, downloader: downloader)
    }

    @Test func scheduledPackDownloadsEvenWhenItsManifestWindowIsFarAndTheScheduleIsSaved() async throws {
        let now = Fixture.date(2026, 6, 1) // 매니페스트 창(12/19)은 ±45일 밖
        let span = SeasonPackIndex.Span(from: "2026-06-01T00:00:00+09:00", to: "2026-06-03T00:00:00+09:00")
        let (archive, transport) = try serve(version: 2, schedule: [span], at: now)
        let store = SeasonPackStore(root: Fixture.tempDirectory()), suite = Fixture.suite()
        let result = await fetcher(transport, engine: FakeEngine([.finish(archive)]), store: store, suite: suite, now: now).refresh()
        #expect(result.installed == [SeasonPackRef(id: "christmas", version: 2)])
        #expect(SeasonPackFetcher.savedSchedules(SeasonPackDefaults(suiteName: suite))["christmas"] == [span.interval!])
    }

    @Test func farScheduleIsNotDownloadedYet() async throws {
        let now = Fixture.date(2026, 6, 1)
        let (archive, transport) = try serve(version: 2, schedule: [SeasonPackIndex.Span(from: "2026-12-19T00:00:00+09:00", to: "2026-12-31T00:00:00+09:00")], at: now)
        let engine = FakeEngine([.finish(archive)])
        let result = await fetcher(transport, engine: engine, store: SeasonPackStore(root: Fixture.tempDirectory()), suite: Fixture.suite(), now: now).refresh()
        #expect(result.installed.isEmpty && engine.calls == 0)
    }

    @Test func sameVersionIsReusedWithoutDownloading() async throws {
        let now = Fixture.date(2026, 11, 25)
        let (archive, transport) = try serve(version: 1, schedule: [midweek], at: now)
        let engine = FakeEngine([.finish(archive)])
        // 기기에 이미 v1(번들 시드든 지난번에 받은 것이든)이 있다.
        let result = await fetcher(transport, engine: engine, store: SeasonPackStore(root: Fixture.tempDirectory()), suite: Fixture.suite(), now: now, known: 1).refresh()
        #expect(result.installed.isEmpty && engine.calls == 0)
    }

    @Test func newVersionReplacesTheOldOne() async throws {
        let now = Fixture.date(2026, 11, 25)
        let store = SeasonPackStore(root: Fixture.tempDirectory())
        let v1 = Fixture.pack(id: "christmas", version: 1)
        _ = try store.install(manifestData: v1.manifest, files: v1.files, appBuild: 1000)
        let (archive, transport) = try serve(version: 2, schedule: [midweek], at: now)
        let result = await fetcher(transport, engine: FakeEngine([.finish(archive)]), store: store, suite: Fixture.suite(), now: now, known: 1).refresh()
        #expect(result.installed == [SeasonPackRef(id: "christmas", version: 2)])
        #expect(store.installedPacks(appBuild: 1000).map(\.version) == [2])
    }

    @Test func catalogWithoutScheduleClearsTheSavedOne() async throws {
        let now = Fixture.date(2026, 11, 25), suite = Fixture.suite()
        let defaults = SeasonPackDefaults(suiteName: suite)
        SeasonPackFetcher.saveSchedules(["christmas": [midweek.interval!]], defaults)
        let (_, transport) = try serve(version: 1, schedule: nil, at: now)
        _ = await fetcher(transport, engine: FakeEngine([]), store: SeasonPackStore(root: Fixture.tempDirectory()), suite: suite, now: now, known: 1).refresh()
        #expect(SeasonPackFetcher.savedSchedules(defaults).isEmpty)
    }
}

/// T-03(CRV1120A01): 매니페스트·시연 인자의 날짜 글자를 읽는 규칙. 달·일이 틀리면 다음 해로 굴리지 않고 nil.
struct DateParsingTests {
    private func parse(_ text: String) -> Date? { SeasonPackDateParsing.localDateTime(text, calendar: Fixture.calendar) }

    @Test func readsDatesWithAndWithoutTime() {
        #expect(parse("2026-12-19") == Fixture.date(2026, 12, 19))
        #expect(parse("2026-12-19T09:05") == Fixture.date(2026, 12, 19, 9, 5))
        #expect(parse("2028-02-29") == Fixture.date(2028, 2, 29), "윤년")
    }

    @Test func rejectsImpossibleDatesInsteadOfRollingThemOver() {
        #expect(parse("2026-13-40") == nil)
        #expect(parse("2026-13-01") == nil)
        #expect(parse("2026-00-10") == nil)
        #expect(parse("2026-02-30") == nil)
        #expect(parse("2027-02-29") == nil, "윤년이 아닌 해")
        #expect(parse("2026-04-31") == nil)
        #expect(parse("2026-12-00") == nil)
    }

    @Test func rejectsBadTimesAndShapes() {
        #expect(parse("2026-12-19T24:00") == nil)
        #expect(parse("2026-12-19T09:60") == nil)
        #expect(parse("2026-12-19T09") == nil)
        #expect(parse("2026-12") == nil)
        #expect(parse("12/19") == nil)
        #expect(parse("2026-12-19T09:05T10:00") == nil)
        #expect(SeasonPackDateParsing.hourMinute("23:59")?.hour == 23)
        #expect(SeasonPackDateParsing.hourMinute("7") == nil)
    }
}
