import XCTest
@testable import TaptionPlan

/// R2 공용 공지 수신·거르기·닫기(ANN1119A01). 서버 픽스처와 같은 모양의 가짜 내용만 쓴다.
@MainActor
final class AnnouncementTests: XCTestCase {
    private let fixture = """
    {"version":3,"items":[
      {"id":"maintenance-1126","title":"앱 점검 안내","body":"서버 점검으로 공유 기능이 잠시 느려질 수 있습니다.","kind":"warning",
       "startsAt":"2026-11-25T09:00+09:00","expiresAt":"2026-11-27T09:00+09:00","minBuild":350,"maxBuild":null,
       "link":"https://example.com/notice/maintenance","titleByLang":{"en":"Maintenance notice"},"bodyByLang":{"en":"Sharing may be slow."},"future":"ignored"},
      {"id":"whats-new-354","title":"새 기능 안내","body":"메인 메뉴에서 직접 추가 항목이 모두 보입니다.","kind":"update"}
    ]}
    """

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func item(_ id: String = "a", kind: AppAnnouncement.Kind = .info, start: Date? = nil, end: Date? = nil, min: Int? = nil, max: Int? = nil) -> AppAnnouncement {
        AppAnnouncement(id: id, title: "제목 \(id)", body: "본문 \(id)", kind: kind, startsAt: start, expiresAt: end, minBuild: min, maxBuild: max)
    }
    private func visible(_ items: [AppAnnouncement], build: Int? = 353, dismissed: Set<String> = []) -> [String] {
        AnnouncementPolicy.visible(items, now: now, build: build, dismissed: dismissed).map(\.id)
    }

    // 1. 픽스처 디코딩
    func testFixtureDecodes() throws {
        let feed = AnnouncementFeed.decode(Data(fixture.utf8))
        XCTAssertEqual(feed.version, 3)
        XCTAssertEqual(feed.items.count, 2)
        let first = try XCTUnwrap(feed.items.first)
        XCTAssertEqual(first.kind, .warning)
        XCTAssertNil(first.maxBuild)
        XCTAssertEqual(first.minBuild, 350)
        XCTAssertEqual(first.link, "https://example.com/notice/maintenance")
        XCTAssertEqual(first.titleByLang["en"], "Maintenance notice")
        XCTAssertNotNil(first.startsAt)
        XCTAssertEqual(first.expiresAt?.timeIntervalSince(try XCTUnwrap(first.startsAt)), 2 * 86_400)
        let second = feed.items[1]
        XCTAssertNil(second.startsAt); XCTAssertNil(second.expiresAt); XCTAssertNil(second.link); XCTAssertTrue(second.titleByLang.isEmpty)
    }

    // 2. 깨진 본문
    func testBrokenBodiesNeverThrow() {
        for text in ["", "not json", "{}", #"{"version":2}"#, #"{"items":"x"}"#, "[]"] {
            XCTAssertEqual(AnnouncementFeed.decode(Data(text.utf8)), .empty, text)
        }
        let mixed = #"{"version":1,"items":[{"id":"ok","title":"가","body":"나"},{"id":"","title":"x","body":"y"},{"title":"x","body":"y"},7,{"id":"b","title":"가","body":""}]}"#
        XCTAssertEqual(AnnouncementFeed.decode(Data(mixed.utf8)).items.map(\.id), ["ok"])
        let unknownKind = #"{"version":1,"items":[{"id":"k","title":"가","body":"나","kind":"maintenance"}]}"#
        XCTAssertEqual(AnnouncementFeed.decode(Data(unknownKind.utf8)).items.first?.kind, .info, "모르는 kind는 버리지 않고 info")
        let fractional = #"{"version":1,"items":[{"id":"f","title":"가","body":"나","startsAt":"2026-11-25T09:00:00.500+09:00","expiresAt":"어제"}]}"#
        let decoded = AnnouncementFeed.decode(Data(fractional.utf8)).items.first
        XCTAssertNotNil(decoded?.startsAt); XCTAssertNil(decoded?.expiresAt, "못 읽은 날짜는 없는 것")
    }

    // 3. 기간
    func testPeriodFilterIncludesBothEnds() {
        XCTAssertEqual(visible([item(start: now.addingTimeInterval(1))]), [])
        XCTAssertEqual(visible([item(end: now.addingTimeInterval(-1))]), [])
        XCTAssertEqual(visible([item(start: now)]), ["a"])
        XCTAssertEqual(visible([item(end: now)]), ["a"])
        XCTAssertEqual(visible([item()]), ["a"])
    }

    // 4. 빌드
    func testBuildFilter() {
        XCTAssertEqual(visible([item(min: 354)]), [])
        XCTAssertEqual(visible([item(min: 353)]), ["a"])
        XCTAssertEqual(visible([item(max: 352)]), [])
        XCTAssertEqual(visible([item(max: 353)]), ["a"])
        XCTAssertEqual(visible([item(min: 400, max: 300)], build: nil), ["a"], "빌드를 못 읽으면 거르지 않는다")
        XCTAssertEqual(visible([item()], build: 1), ["a"])
    }

    // 5. 다국어
    func testLanguagePicking() {
        let table = ["en": "English", "ja": "日本語", "zh": "中文", "empty": ""]
        XCTAssertEqual(AnnouncementPolicy.localized("한국어", table, code: "en"), "English")
        XCTAssertEqual(AnnouncementPolicy.localized("한국어", table, code: "ja"), "日本語")
        XCTAssertEqual(AnnouncementPolicy.localized("한국어", table, code: "zh-Hant"), "中文", "zh-Hant 없으면 zh")
        XCTAssertEqual(AnnouncementPolicy.localized("한국어", ["zh-Hant": "繁體", "zh": "中文"], code: "zh-Hant"), "繁體")
        XCTAssertEqual(AnnouncementPolicy.localized("한국어", table, code: "de"), "한국어", "다른 언어를 끌어다 쓰지 않는다")
        XCTAssertEqual(AnnouncementPolicy.localized("한국어", table, code: "ko"), "한국어")
        XCTAssertEqual(AnnouncementPolicy.localized("한국어", table, code: "empty"), "한국어", "빈 문자열은 없는 것")
        let partial = AppAnnouncement(id: "p", title: "제목", body: "본문", titleByLang: ["en": "Title"])
        XCTAssertEqual(AnnouncementPolicy.title(of: partial, code: "en"), "Title")
        XCTAssertEqual(AnnouncementPolicy.body(of: partial, code: "en"), "본문", "제목만 번역돼도 그것을 쓴다")
    }

    func testLinkMustBeShortHTTPS() {
        func link(_ text: String?) -> URL? { AnnouncementPolicy.link(of: AppAnnouncement(id: "l", title: "가", body: "나", link: text)) }
        XCTAssertNotNil(link("https://example.com/a"))
        XCTAssertNil(link("http://example.com/a")); XCTAssertNil(link("javascript:alert(1)")); XCTAssertNil(link(nil))
        XCTAssertNil(link("https://example.com/" + String(repeating: "a", count: 300)))
    }

    // 6. 닫은 공지
    func testDismissedIDsAndPruning() {
        XCTAssertEqual(visible([item("a"), item("b")], dismissed: ["a"]), ["b"])
        let day = 86_400.0, current = now.timeIntervalSince1970
        let pruned = AnnouncementPolicy.pruned(["old": current - 91 * day, "recent": current - 10 * day, "live": current - 200 * day], liveIDs: ["live"], now: now)
        XCTAssertEqual(Set(pruned.keys), ["recent", "live"])
        let many = Dictionary(uniqueKeysWithValues: (0..<250).map { ("id\($0)", current - Double($0)) })
        let capped = AnnouncementPolicy.pruned(many, liveIDs: [], now: now)
        XCTAssertEqual(capped.count, 200)
        XCTAssertNotNil(capped["id0"]); XCTAssertNil(capped["id249"], "오래된 것부터 지운다")
    }

    // 7. 정렬
    func testSortsBySeverityThenLaterStartThenResponseOrder() {
        let early = now.addingTimeInterval(-200), late = now.addingTimeInterval(-100)
        let list = [item("info", kind: .info), item("warn-early", kind: .warning, start: early), item("crit", kind: .critical),
                    item("warn-late", kind: .warning, start: late), item("update", kind: .update), item("info2", kind: .info)]
        XCTAssertEqual(visible(list), ["crit", "warn-late", "warn-early", "update", "info", "info2"])
    }

    // MARK: 서비스

    private struct Call { var url: URL; var etag: String? }
    private final class Wire {
        var calls: [Call] = []
        var reply: AnnouncementService.Reply? = (200, Data(), nil)
    }

    private func defaults() -> UserDefaults {
        let name = "AnnouncementTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    private func service(_ wire: Wire, _ defaults: UserDefaults, clock: @escaping () -> Date, endpoint: URL? = URL(string: "https://relay.example.com/public/announcements")) -> AnnouncementService {
        AnnouncementService(defaults: defaults, endpoint: { endpoint }, send: { request in
            wire.calls.append(Call(url: request.url!, etag: request.value(forHTTPHeaderField: "If-None-Match")))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "공개 경로는 인증을 싣지 않는다")
            XCTAssertEqual(request.httpMethod, "GET"); XCTAssertEqual(request.timeoutInterval, 8)
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData); XCTAssertNil(request.url?.query)
            return wire.reply
        }, now: clock, build: { 353 })
    }

    // 8. 쿨다운
    func testCooldownIsThirtyMinutes() async {
        let wire = Wire(), store = defaults()
        var current = now
        let feed = service(wire, store, clock: { current })
        await feed.refresh()
        XCTAssertEqual(wire.calls.count, 1)
        current = now.addingTimeInterval(29 * 60)
        await feed.refresh()
        XCTAssertEqual(wire.calls.count, 1, "29분 뒤에는 요청하지 않는다")
        current = now.addingTimeInterval(31 * 60)
        await feed.refresh()
        XCTAssertEqual(wire.calls.count, 2)
        wire.reply = (304, Data(), nil)
        current = now.addingTimeInterval(62 * 60)
        await feed.refresh()
        current = now.addingTimeInterval(80 * 60)
        await feed.refresh()
        XCTAssertEqual(wire.calls.count, 3, "304도 시도 시각을 갱신해 18분 뒤에는 요청하지 않는다")
    }

    func testNoRelayHostMeansNoRequest() async {
        let wire = Wire()
        let feed = service(wire, defaults(), clock: { self.now }, endpoint: nil)
        await feed.refresh()
        XCTAssertTrue(wire.calls.isEmpty)
    }

    func testAttemptTimeIsWrittenBeforeSending() async {
        let store = defaults()
        let feed = AnnouncementService(defaults: store, endpoint: { URL(string: "https://relay.example.com/x") }, send: { _ in
            XCTAssertEqual(store.double(forKey: AnnouncementService.lastAttemptKey), self.now.timeIntervalSince1970)
            return nil
        }, now: { self.now }, build: { 353 })
        await feed.refresh()
    }

    // 9. ETag
    func testETagFlow() async throws {
        let wire = Wire(), store = defaults()
        var current = now
        let feed = service(wire, store, clock: { current })
        wire.reply = (200, Data(fixture.utf8), "\"abc-1\"")
        await feed.refresh()
        XCTAssertNil(wire.calls[0].etag)
        XCTAssertEqual(store.string(forKey: AnnouncementService.etagKey), "\"abc-1\"")
        XCTAssertEqual(feed.all.count, 2)
        wire.reply = (304, Data(), "\"abc-1\"")
        current = now.addingTimeInterval(3_600)
        await feed.refresh()
        XCTAssertEqual(wire.calls[1].etag, "\"abc-1\"", "받은 그대로(따옴표 포함) 보낸다")
        XCTAssertEqual(feed.all.count, 2, "304면 목록 유지")
        wire.reply = (200, Data(#"{"version":0,"items":[]}"#.utf8), nil)
        current = now.addingTimeInterval(7_200)
        await feed.refresh()
        XCTAssertNil(store.string(forKey: AnnouncementService.etagKey), "ETag 없는 200이면 저장값 삭제")
        XCTAssertTrue(feed.all.isEmpty)
    }

    // 10. 실패
    func testFailuresKeepTheListAndStaySilent() async {
        let wire = Wire(), store = defaults()
        var current = now
        let feed = service(wire, store, clock: { current })
        wire.reply = (200, Data(fixture.utf8), "\"e\"")
        await feed.refresh()
        for reply: AnnouncementService.Reply? in [nil, (500, Data(), nil), (429, Data(), nil), (404, Data("x".utf8), nil)] {
            wire.reply = reply
            current = current.addingTimeInterval(3_600)
            await feed.refresh()
            XCTAssertEqual(feed.all.count, 2)
        }
        wire.reply = (200, Data("{깨짐".utf8), "\"f\"")
        current = current.addingTimeInterval(3_600)
        await feed.refresh()
        XCTAssertTrue(feed.all.isEmpty, "200이지만 깨진 본문은 빈 묶음으로 읽는다")
    }

    // 11. 빈 목록과 닫기 기록
    func testEmptyFeedShowsNothingAndDismissIsRemembered() async {
        let wire = Wire(), store = defaults()
        let feed = service(wire, store, clock: { self.now })
        wire.reply = (200, Data(#"{"version":0,"items":[]}"#.utf8), nil)
        await feed.refresh()
        XCTAssertTrue(feed.visible.isEmpty)

        let next = service(wire, store, clock: { self.now.addingTimeInterval(3_600) })
        wire.reply = (200, Data(fixture.utf8), "\"e\"")
        await next.refresh()
        let showing = next.visible.map(\.id)
        XCTAssertEqual(showing, ["maintenance-1126", "whats-new-354"].filter { showing.contains($0) })
        XCTAssertTrue(showing.contains("whats-new-354"))
        next.dismiss("whats-new-354")
        XCTAssertFalse(next.visible.map(\.id).contains("whats-new-354"))
        let reopened = service(wire, store, clock: { self.now.addingTimeInterval(7_200) })
        XCTAssertNotNil(reopened.dismissed["whats-new-354"], "앱을 다시 켜도 닫은 것을 기억한다")
        XCTAssertTrue(reopened.all.isEmpty, "목록 본문은 디스크에 두지 않는다")
    }
}
