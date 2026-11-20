import Foundation
import UserNotifications
import Observation
import TaptionAssistantKit
import TaptionWatchSync

/// 중계 서버의 공용 공지(R2PUB1119A01) 한 건. 필드는 `server/trip-relay/README.md` 「공지 JSON 스키마」 그대로다(ANN1119A01).
struct AppAnnouncement: Equatable, Identifiable, Sendable {
    /// 순서가 곧 심각도다. 모르는 값은 `info`로 대접해 버리지 않는다.
    enum Kind: Int, Comparable, Sendable {
        case info, update, warning, critical
        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var id: String
    var title: String
    var body: String
    var kind: Kind
    var startsAt: Date?
    var expiresAt: Date?
    var minBuild: Int?
    var maxBuild: Int?
    var link: String?
    var titleByLang: [String: String]
    var bodyByLang: [String: String]

    init(id: String, title: String, body: String, kind: Kind = .info, startsAt: Date? = nil, expiresAt: Date? = nil,
         minBuild: Int? = nil, maxBuild: Int? = nil, link: String? = nil,
         titleByLang: [String: String] = [:], bodyByLang: [String: String] = [:]) {
        self.id = id; self.title = title; self.body = body; self.kind = kind
        self.startsAt = startsAt; self.expiresAt = expiresAt; self.minBuild = minBuild; self.maxBuild = maxBuild
        self.link = link; self.titleByLang = titleByLang; self.bodyByLang = bodyByLang
    }
}

/// 서버가 준 공지 묶음. 읽기는 던지지 않는다 — 깨진 본문은 빈 묶음, 깨진 항목은 그 항목만 건너뛴다.
struct AnnouncementFeed: Equatable, Sendable {
    var version: Int
    var items: [AppAnnouncement]

    static let empty = AnnouncementFeed(version: 0, items: [])

    static func decode(_ data: Data) -> AnnouncementFeed {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawItems = root["items"] as? [Any] else { return .empty }
        let version = (root["version"] as? NSNumber)?.intValue ?? 0
        return AnnouncementFeed(version: version, items: rawItems.compactMap { item($0 as? [String: Any]) })
    }

    private static func item(_ raw: [String: Any]?) -> AppAnnouncement? {
        guard let raw, let id = raw["id"] as? String, !id.isEmpty,
              let title = raw["title"] as? String, !title.isEmpty,
              let body = raw["body"] as? String, !body.isEmpty else { return nil }
        return AppAnnouncement(
            id: id, title: title, body: body,
            kind: kind(raw["kind"] as? String),
            startsAt: date(raw["startsAt"]), expiresAt: date(raw["expiresAt"]),
            minBuild: integer(raw["minBuild"]), maxBuild: integer(raw["maxBuild"]),
            link: raw["link"] as? String,
            titleByLang: strings(raw["titleByLang"]), bodyByLang: strings(raw["bodyByLang"])
        )
    }

    private static func kind(_ value: String?) -> AppAnnouncement.Kind {
        switch value {
        case "update": .update
        case "warning": .warning
        case "critical": .critical
        default: .info
        }
    }

    /// 읽지 못한 날짜는 그 필드가 없는 것으로 본다(공지를 숨기는 쪽으로 틀리지 않게).
    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        // 서버 스키마의 예(`2026-11-25T09:00+09:00`)처럼 초가 없는 형식도 읽는다.
        let minutes = DateFormatter()
        minutes.locale = Locale(identifier: "en_US_POSIX")
        minutes.dateFormat = "yyyy-MM-dd'T'HH:mmXXXXX"
        return minutes.date(from: text)
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue
    }

    private static func strings(_ value: Any?) -> [String: String] {
        (value as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
    }
}

/// 거르기·정렬·문구 고르기. 네트워크·저장소와 섞지 않는 순수 함수다.
enum AnnouncementPolicy {
    static let dismissedRetention: TimeInterval = 90 * 24 * 60 * 60
    static let maximumDismissed = 200
    static let maximumLinkLength = 300

    /// 지금 보일 공지를 심각도 내림차순 → `startsAt` 늦은 순 → 응답 순서로 돌려준다. 빌드를 못 읽으면(nil) 빌드 조건은 거르지 않는다.
    static func visible(_ items: [AppAnnouncement], now: Date, build: Int?, dismissed: Set<String>) -> [AppAnnouncement] {
        items.enumerated()
            .filter { _, item in
                if dismissed.contains(item.id) { return false }
                if let startsAt = item.startsAt, startsAt > now { return false }
                if let expiresAt = item.expiresAt, now > expiresAt { return false }
                if let build {
                    if let minBuild = item.minBuild, build < minBuild { return false }
                    if let maxBuild = item.maxBuild, build > maxBuild { return false }
                }
                return true
            }
            .sorted { left, right in
                if left.element.kind != right.element.kind { return left.element.kind > right.element.kind }
                let leftStart = left.element.startsAt ?? .distantPast, rightStart = right.element.startsAt ?? .distantPast
                if leftStart != rightStart { return leftStart > rightStart }
                return left.offset < right.offset
            }
            .map(\.element)
    }

    /// 지금 앱 언어 코드. 번역 언어를 골랐다면 그 코드, 아니면 한국어는 `ko`·그 밖은 `en`.
    static func languageCode(language: MapHomeLanguage = .current) -> String {
        UITextPack.activeLanguageCode ?? (language == .korean ? "ko" : "en")
    }

    static func title(of item: AppAnnouncement, code: String) -> String { localized(item.title, item.titleByLang, code: code) }
    static func body(of item: AppAnnouncement, code: String) -> String { localized(item.body, item.bodyByLang, code: code) }

    /// ① 코드 그대로 ② 하이픈 앞 언어 ③ 한국어 기본값. 다른 언어를 끌어다 쓰지 않고 빈 문자열은 없는 것으로 본다.
    static func localized(_ base: String, _ table: [String: String], code: String) -> String {
        guard code != "ko" else { return base }
        let language = code.split(separator: "-").first.map(String.init) ?? code
        for key in [code, language] {
            if let text = table[key], !text.isEmpty { return text }
        }
        return base
    }

    /// `https` 300자 이내만 「자세히」로 연다. 아니면 단추만 감춘다.
    static func link(of item: AppAnnouncement) -> URL? {
        guard let text = item.link, text.count <= maximumLinkLength,
              let url = URL(string: text), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }

    /// 서버 응답에 없는 id이면서 닫은 지 90일이 지난 것을 지우고, 그래도 200개가 넘으면 오래된 것부터 지운다.
    static func pruned(_ dismissed: [String: Double], liveIDs: Set<String>, now: Date) -> [String: Double] {
        var result = dismissed.filter { id, at in liveIDs.contains(id) || now.timeIntervalSince1970 - at <= dismissedRetention }
        if result.count > maximumDismissed {
            let keep = result.sorted { $0.value > $1.value }.prefix(maximumDismissed)
            result = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        return result
    }

    /// 백그라운드에서 한 번에 알림으로 띄울 수(BGN1120A01). 더 많으면 심각한 것부터.
    static let maximumNotices = 3

    /// 아직 알리지 않은 보이는 공지(`visible` 순서 그대로, 최대 `maximumNotices`개).
    static func unnotified(_ visible: [AppAnnouncement], notified: Set<String>) -> [AppAnnouncement] {
        Array(visible.filter { !notified.contains($0.id) }.prefix(maximumNotices))
    }

    static func currentBuild(_ bundle: Bundle = .main) -> Int? {
        (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap { Int($0) }
    }
}

/// 공지를 받아 두고 닫은 것을 기억한다. 목록은 메모리에만 둔다(오프라인에서 지난 공지를 되살리지 않는다).
/// 요청은 `GET /public/announcements` 하나(인증·식별자·쿼리 없음)이고, 30분에 한 번만, 한 번만 시도하며, 실패는 조용히 넘긴다.
@MainActor
@Observable
final class AnnouncementService {
    typealias Reply = (status: Int, data: Data, etag: String?)

    static let shared: AnnouncementService = {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-announcementPreview") { return AnnouncementService(previewItems: previewItems) }
#endif
        return AnnouncementService()
    }()
    static let cooldown: TimeInterval = 30 * 60
    static let etagKey = "announcement.etag"
    static let lastAttemptKey = "announcement.lastAttemptAt"
    static let dismissedKey = "announcement.dismissedAt"
    /// 알림으로 띄웠거나 앱 안 배너로 이미 보인 공지(BGN1120A01). 같은 공지를 두 번 알리지 않는다.
    static let notifiedKey = "announcement.notifiedAt"
    /// 알림을 눌렀을 때 공지 시트를 열기 위한 표시.
    static let userInfoID = "announcementID"

    private(set) var all: [AppAnnouncement] = []
    /// 시즌 팩이 켜질 때 공지 시트를 한 번 열어 달라는 요청(SEA1119A01). 배너가 값이 바뀔 때마다 시트를 연다.
    private(set) var sheetRequest = 0
    private(set) var dismissed: [String: Double]
    @ObservationIgnored private var notified: [String: Double]
    @ObservationIgnored private var sheetRequestedAt: Date?
    /// 이 실행에서 목록을 한 번이라도 받았는지. 목록은 메모리에만 있어, 막 켜진 앱이 쿨다운·304로 빈 목록에 머물지 않게 한다(BGN1120A01).
    @ObservationIgnored private var hasLoaded = false
    /// 이 실행에서 한 번이라도 요청했는지. 첫 요청만 쿨다운을 건너뛴다(서버가 멈춰도 요청이 되풀이되지 않게).
    @ObservationIgnored private var hasAttempted = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let endpoint: () -> URL?
    @ObservationIgnored private let send: (URLRequest) async -> Reply?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let build: () -> Int?
    @ObservationIgnored private let isPreview: Bool

    init(
        defaults: UserDefaults = .standard,
        endpoint: @escaping () -> URL? = { TripRelay.url("/public/announcements") },
        send: @escaping (URLRequest) async -> Reply? = AnnouncementService.liveSend,
        now: @escaping () -> Date = { .now },
        build: @escaping () -> Int? = { AnnouncementPolicy.currentBuild() },
        previewItems: [AppAnnouncement]? = nil
    ) {
        self.defaults = defaults
        self.endpoint = endpoint
        self.send = send
        self.now = now
        self.build = build
        self.isPreview = previewItems != nil
        self.dismissed = defaults.dictionary(forKey: Self.dismissedKey) as? [String: Double] ?? [:]
        self.notified = defaults.dictionary(forKey: Self.notifiedKey) as? [String: Double] ?? [:]
        if let previewItems { all = previewItems }
    }

    /// 지금 보일 공지(정렬됨).
    var visible: [AppAnnouncement] {
        AnnouncementPolicy.visible(all, now: now(), build: build(), dismissed: Set(dismissed.keys))
    }

    func requestSheet() {
        sheetRequestedAt = now()
        sheetRequest &+= 1
    }

    /// 배너가 아직 화면에 없을 때 온 요청(알림을 눌러 앱이 막 켜진 때)을 배너가 나타나며 한 번 가져간다. 1분이 지난 요청은 버린다.
    func takeSheetRequest() -> Bool {
        guard let at = sheetRequestedAt else { return false }
        sheetRequestedAt = nil
        return now().timeIntervalSince(at) <= 60
    }

    func dismiss(_ id: String) {
        guard dismissed[id] == nil else { return }
        dismissed[id] = now().timeIntervalSince1970
        defaults.set(dismissed, forKey: Self.dismissedKey)
    }

    /// 쿨다운 안이거나 중계 서버가 없으면 요청하지 않는다. 시도 시각은 보내기 전에 적는다(멈춘 요청이 반복되지 않게).
    func refresh() async {
        guard !isPreview, let url = endpoint() else { return }
        let current = now().timeIntervalSince1970
        // 이 실행의 첫 요청은 쿨다운을 건너뛰고, 목록을 받기 전에는 ETag 없이 통째로 받는다(앱을 껐다 켜거나 백그라운드로 깨어난 때).
        if hasAttempted, let last = defaults.object(forKey: Self.lastAttemptKey) as? Double, current >= last, current - last < Self.cooldown { return }
        hasAttempted = true
        defaults.set(current, forKey: Self.lastAttemptKey)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.httpMethod = "GET"
        if hasLoaded, let etag = defaults.string(forKey: Self.etagKey) { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        guard let reply = await send(request) else { return }
        switch reply.status {
        case 200:
            let feed = AnnouncementFeed.decode(reply.data)
            all = feed.items
            hasLoaded = true
            if let etag = reply.etag, !etag.isEmpty { defaults.set(etag, forKey: Self.etagKey) } else { defaults.removeObject(forKey: Self.etagKey) }
            let live = Set(feed.items.map(\.id))
            let kept = AnnouncementPolicy.pruned(dismissed, liveIDs: live, now: now())
            if kept != dismissed {
                dismissed = kept
                defaults.set(kept, forKey: Self.dismissedKey)
            }
        default:
            break // 304는 지금 목록 그대로, 그 밖의 상태는 조용히 무시한다.
        }
    }

    /// 앱이 앞에 있을 때: 배너로 보이니 알림 없이 본 것으로 적는다(나중에 백그라운드에서 다시 알리지 않게).
    func markShown() { mark(visible.map(\.id)) }

    /// 백그라운드 새로 고침(BGN1120A01): 공지를 받고, 아직 알리지 않은 보이는 공지를 알림으로 띄운다.
    /// 푸시(APNs)는 대표 결정 전이라 iOS가 깨워 줄 때만 받는다. 알림 권한이 없으면 iOS가 조용히 버린다.
    @discardableResult
    func refreshAndNotify(post: (AppAnnouncement, String) async -> Void = AnnouncementService.post) async -> [AppAnnouncement] {
        await refresh()
        let fresh = AnnouncementPolicy.unnotified(visible, notified: Set(notified.keys))
        let code = AnnouncementPolicy.languageCode()
        for item in fresh { await post(item, code) }
        mark(fresh.map(\.id))
        return fresh
    }

    private func mark(_ ids: [String]) {
        let stamp = now().timeIntervalSince1970
        var next = notified
        for id in ids where next[id] == nil { next[id] = stamp }
        // 목록을 받은 실행에서만 정리한다(빈 목록 기준으로 살아 있는 공지의 기록을 지우지 않게).
        if hasLoaded { next = AnnouncementPolicy.pruned(next, liveIDs: Set(all.map(\.id)), now: now()) }
        guard next != notified else { return }
        notified = next
        defaults.set(next, forKey: Self.notifiedKey)
    }

    /// 공지 하나를 바로 뜨는 로컬 알림으로. 같은 공지는 같은 id라 겹쳐 쌓이지 않는다.
    static func post(_ item: AppAnnouncement, code: String) async {
        let content = UNMutableNotificationContent()
        content.title = AnnouncementPolicy.title(of: item, code: code)
        content.body = AnnouncementPolicy.body(of: item, code: code)
        content.sound = item.kind >= .warning ? .default : nil
        content.threadIdentifier = "announcement"
        content.userInfo = [userInfoID: item.id]
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "announcement.\(item.id)", content: content, trigger: nil))
    }

    /// 한 번만 시도한다(429를 기다리지 않는다).
    nonisolated static func liveSend(_ request: URLRequest) async -> Reply? {
        let result = await TripRelay.$singleAttempt.withValue(true) { await TripRelay.sendResponse(request) }
        return result.map { ($0.response.statusCode, $0.data, $0.response.value(forHTTPHeaderField: "ETag")) }
    }

#if DEBUG
    /// `-announcementPreview`: 서버 없이 배너·시트를 보는 가짜 공지 3건(하나는 이미 끝난 것).
    static let previewItems: [AppAnnouncement] = [
        AppAnnouncement(id: "preview-info", title: "새 기능 안내", body: "메인 메뉴에서 직접 추가 항목이 모두 보입니다.", kind: .update),
        AppAnnouncement(id: "preview-warning", title: "앱 점검 안내", body: "서버 점검으로 공유 기능이 잠시 느려질 수 있습니다.", kind: .warning,
                        link: "https://example.com/notice/maintenance",
                        titleByLang: ["en": "Maintenance notice"], bodyByLang: ["en": "Sharing may be slow during server maintenance."]),
        AppAnnouncement(id: "preview-critical", title: "중요 안내", body: "이 공지는 이미 끝나 보이지 않아야 합니다.", kind: .critical,
                        expiresAt: Date(timeIntervalSince1970: 1_700_000_000)),
    ]
#endif
}
