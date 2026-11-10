import Foundation
import Observation
import SwiftUI
import UIKit

/// AI가 보낸 화랑이 말풍선 글(BUB1110A01). `[이름](https://…)` 링크는 이름으로, 맨 https 주소는 호스트로 보인다.
/// 서버(`validate.js`의 `bubbleText`)와 같은 문법 하나로 다시 본다(REV1110A06, `docs/ACTIVITY_RELAY_API.md` 4.2).
/// 글자 수는 유니코드 코드 포인트로 센다: 보이는 글 1~80자(맨 주소는 빼고 링크는 이름만), 전체 300자, 링크 3개, 이름 20자.
struct AssistantBubbleText: Equatable, Sendable {
    struct Link: Equatable, Sendable, Identifiable {
        var label: String
        var url: URL
        /// 같은 링크가 두 번 있어도 줄에서 겹치지 않게 차례를 붙인다.
        var index = 0
        var id: String { "\(index)|\(url.absoluteString)" }
    }

    static let limit = 80
    static let totalLimit = 300
    static let linkLimit = 3
    static let labelLimit = 20

    var display: String
    var links: [Link]

    private static let urlCharacters = #"[A-Za-z0-9\-._~:/?#@!$&*+,;=%]"#
    /// 링크 둘: `[이름](https://…)` 또는 맨 `https://…`(scheme은 대소문자 무관). 왼쪽부터 찾는다.
    private static let link = try? NSRegularExpression(
        pattern: #"\[([^\[\]<>\\]*)\]\((https://"# + urlCharacters + #"+)\)|(?<![A-Za-z0-9+.\-])(https://"# + urlCharacters + "+)",
        options: .caseInsensitive
    )
    private static let host = try? NSRegularExpression(pattern: #"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\.[a-z]{2,}$"#)
    /// 링크 밖에 남은 `글자들:` + 공백 아닌 글자는 다른 scheme으로 본다(tel:1, http://, ETA:15, 못 읽은 https:).
    private static let scheme = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9+.\-])[A-Za-z][A-Za-z0-9+.\-]*:(?=\S)"#)
    /// 이름이 주소처럼 보이면 안 된다: `://`, `www.`, 글자·숫자 + 점 + 영문 2자 이상(apple.com).
    private static let addressLikeLabel = try? NSRegularExpression(
        pattern: #"://|www[.．。｡]|[\p{L}\p{N}][.．。｡][A-Za-z]{2,}"#, options: .caseInsensitive
    )
    private static let badPercent = try? NSRegularExpression(pattern: "%(?![0-9A-Fa-f]{2})")

    init?(_ raw: String) {
        guard let text = Self.cleaned(raw), !text.contains("\\"), let link = Self.link, let scheme = Self.scheme else { return nil }
        let source = text as NSString
        var display = "", visible = "", total = 0, links: [Link] = []
        var last = 0
        func plain(_ range: NSRange) {
            let chunk = source.substring(with: range)
            display += chunk
            visible += chunk
            total += chunk.unicodeScalars.count
        }
        for match in link.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            plain(NSRange(location: last, length: match.range.location - last))
            if match.range(at: 2).location != NSNotFound {
                let label = source.substring(with: match.range(at: 1))
                guard let url = Self.https(source.substring(with: match.range(at: 2))), Self.isLabel(label) else { return nil }
                links.append(Link(label: label, url: url))
                display += label
                visible += label
                total += label.unicodeScalars.count + url.absoluteString.unicodeScalars.count + 4
                last = match.range.location + match.range.length
            } else {
                // 끝의 문장 부호는 주소가 아니라 글이다.
                let bare = Self.droppingTrailingPunctuation(source.substring(with: match.range(at: 3)))
                guard let url = Self.https(bare), let host = url.host() else { return nil }
                links.append(Link(label: host, url: url))
                display += host
                total += url.absoluteString.unicodeScalars.count
                last = match.range.location + (bare as NSString).length
            }
        }
        plain(NSRange(location: last, length: source.length - last))
        let shown = visible.trimmingCharacters(in: .whitespaces)
        guard scheme.firstMatch(in: visible, range: NSRange(location: 0, length: (visible as NSString).length)) == nil,
              visible.rangeOfCharacter(from: CharacterSet(charactersIn: "[]<>\\")) == nil,
              links.count <= Self.linkLimit, (1...Self.limit).contains(shown.unicodeScalars.count), total <= Self.totalLimit else { return nil }
        self.display = display
        self.links = links.enumerated().map { Link(label: $1.label, url: $1.url, index: $0) }
    }

    /// 보이지 않는 글자(제어 Cc·서식 Cf·줄/문단 구분 Zl·Zp)를 지우고 앞뒤 공백을 자른다. 방향 바꿈 글자로 주소를 속이지 못한다.
    static func cleaned(_ raw: String) -> String? {
        let hidden: Set<Unicode.GeneralCategory> = [.control, .format, .lineSeparator, .paragraphSeparator]
        let kept = raw.unicodeScalars.filter { !hidden.contains($0.properties.generalCategory) }
        let text = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func droppingTrailingPunctuation(_ text: String) -> String {
        var result = Substring(text)
        while let last = result.last, ".,;:!?".contains(last) { result = result.dropLast() }
        return String(result)
    }

    static func isLabel(_ label: String) -> Bool {
        guard !label.trimmingCharacters(in: .whitespaces).isEmpty, label.unicodeScalars.count <= labelLimit, let pattern = addressLikeLabel else { return false }
        return pattern.firstMatch(in: label, range: NSRange(location: 0, length: (label as NSString).length)) == nil
    }

    /// https 주소 하나. 호스트는 ASCII 도메인만(IP·퓨니코드 `xn--`·계정 `@` 없음), 포트는 숫자, `%`는 16진수 두 자리와 함께.
    /// 여는 주소는 scheme과 호스트를 소문자로 맞춘다.
    static func https(_ text: String) -> URL? {
        guard text.lowercased().hasPrefix("https://"), let hostPattern = host, let badPercent else { return nil }
        let rest = String(text.dropFirst("https://".count))
        let authority = String(rest.prefix { !"/?#".contains($0) }).lowercased()
        let parts = authority.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let portOK = parts.count == 1 || ((1...5).contains(parts[1].count) && parts[1].allSatisfy { $0.isASCII && $0.isNumber })
        guard let name = parts.first, parts.count <= 2, portOK else { return nil }
        guard hostPattern.firstMatch(in: name, range: NSRange(location: 0, length: (name as NSString).length)) != nil, name.count <= 253,
              !name.split(separator: ".").contains(where: { $0.hasPrefix("xn--") || $0.count > 63 }),
              badPercent.firstMatch(in: rest, range: NSRange(location: 0, length: (rest as NSString).length)) == nil,
              let url = URL(string: "https://" + authority + rest.dropFirst(authority.count)),
              url.scheme == "https", url.host() == name, url.user() == nil, url.password() == nil else { return nil }
        return url
    }
}

/// 말풍선 하나. 그날 그 시각 사이에 활동 이름 대신 보인다.
/// BUB1110A02: routine은 기록으로 남아 재생·사이드바 핸들로 그 시각을 보면 다시 보인다.
/// event는 그날 하루 맨 앞에 보이고, 날이 지나면 기기에서 지운다.
struct AssistantBubble: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case routine
        case event
    }

    var id = UUID()
    var start: Date
    var end: Date
    var text: String
    var hidden = false
    var kind: Kind = .routine
    var createdAt: Date?

    var parsed: AssistantBubbleText? { AssistantBubbleText(text) }

    init(id: UUID = UUID(), start: Date, end: Date, text: String, hidden: Bool = false, kind: Kind = .routine, createdAt: Date? = .now) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.hidden = hidden
        self.kind = kind
        self.createdAt = createdAt
    }

    /// 예전 파일(kind·createdAt 없음)도 읽는다.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        start = try values.decode(Date.self, forKey: .start)
        end = try values.decode(Date.self, forKey: .end)
        text = try values.decode(String.self, forKey: .text)
        hidden = try values.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        kind = (try? values.decodeIfPresent(Kind.self, forKey: .kind)) ?? .routine
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt)
    }
}

/// 하루 48개까지 기기 파일에 두고, 같은 내용을 앱 DB(`assistant-bubble` 기록, 월별 백업에 들어감)에도 남긴다(BUB1110A02).
/// routine은 지우지 않고, event는 그날이 지나면 지운다. 기록(활동·메모)은 바꾸지 않는다.
@MainActor
enum AssistantBubbleStore {
    static let dayLimit = 48

    static var url: URL { AssistantActionLog.url.deletingLastPathComponent().appendingPathComponent("assistant-bubbles.json") }

    static func load(from file: URL = url) -> [AssistantBubble] {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([AssistantBubble].self, from: $0) } ?? []
    }

    static func save(_ bubbles: [AssistantBubble], to file: URL = url) {
        if file == url { AssistantBubbleArchive.mirror(from: load(from: file), to: bubbles) }
        guard let data = try? JSONEncoder().encode(bubbles) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        AssistantBubbleBoard.current.replace(bubbles, file: file)
    }

    /// 날이 지난 event. 그날 끝(다음 날 0시)이 지나면 지운다.
    static func isExpired(_ bubble: AssistantBubble, now: Date = .now, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        guard bubble.kind == .event else { return false }
        return bubble.end <= calendar.startOfDay(for: now) || !calendar.isDate(bubble.start, inSameDayAs: now) && bubble.start < calendar.startOfDay(for: now)
    }

    /// 앱을 켤 때·날이 바뀔 때 부른다. 지울 것이 없으면 쓰지 않는다.
    static func cleanExpired(now: Date = .now, calendar: Calendar = .autoupdatingCurrent, file: URL = url) {
        let bubbles = load(from: file)
        let kept = bubbles.filter { !isExpired($0, now: now, calendar: calendar) }
        if kept.count != bubbles.count { save(kept, to: file) }
    }

    /// 하루 48개를 넘으면 nil. 날이 지난 event는 함께 지운다.
    static func add(_ bubble: AssistantBubble, now: Date = .now, calendar: Calendar = .autoupdatingCurrent, file: URL = url) -> AssistantBubble? {
        var bubbles = load(from: file).filter { !isExpired($0, now: now, calendar: calendar) }
        guard bubbles.filter({ calendar.isDate($0.start, inSameDayAs: bubble.start) }).count < dayLimit else { return nil }
        bubbles.append(bubble)
        save(bubbles, to: file)
        return bubble
    }

    static func remove(_ id: UUID, file: URL = url) { save(load(from: file).filter { $0.id != id }, to: file) }

    static func hide(_ id: UUID, file: URL = url) {
        save(load(from: file).map { var copy = $0; if copy.id == id { copy.hidden = true }; return copy }, to: file)
    }

    /// 그 시각에 보일 말풍선(BUB1110A02). 1순위 그날의 event(시간대가 있으면 그 안), 2순위 그 시각의 routine.
    /// 겹치면 늦게 시작한 것. 3순위(대분류 기본 문구)는 `MapHomeDefaultBubblePool`이 맡는다.
    static func active(at now: Date, in bubbles: [AssistantBubble]) -> AssistantBubble? {
        let shown = bubbles.filter { !$0.hidden && $0.start <= now && now < $0.end && $0.parsed != nil }
        return shown.filter { $0.kind == .event }.max { $0.start < $1.start }
            ?? shown.filter { $0.kind == .routine }.max { $0.start < $1.start }
    }
}

/// 지금 말풍선. 바뀔 때만 값을 바꿔 말풍선 뷰만 다시 그린다.
/// 파일은 처음 한 번과 저장할 때만 읽고, 시간 창은 메모리의 목록으로 본다(REV1110A06).
@MainActor
@Observable
final class AssistantBubbleBoard {
    static let current = AssistantBubbleBoard()
    private(set) var active: AssistantBubble?
    @ObservationIgnored private var file = AssistantBubbleStore.url
    @ObservationIgnored private var bubbles: [AssistantBubble]?

    var text: AssistantBubbleText? { active?.parsed }
    /// 재생·사이드바 핸들이 보여 주는 시각(BUB1110A02). nil이면 지금.
    @ObservationIgnored private(set) var viewedTime: Date?
    @ObservationIgnored private var triedArchive = false

    func refresh(now: Date = .now) {
        let list = bubbles ?? AssistantBubbleStore.load(from: file)
        bubbles = list
        let next = AssistantBubbleStore.active(at: viewedTime ?? now, in: list)
        if next != active { active = next }
        // 새 기기·백업 복원처럼 파일이 비었으면 앱 DB에서 한 번 되살린다.
        if list.isEmpty, !triedArchive, file == AssistantBubbleStore.url {
            triedArchive = true
            Task { @MainActor in
                let stored = await AssistantBubbleArchive.all()
                if !stored.isEmpty, (self.bubbles ?? []).isEmpty { AssistantBubbleStore.save(stored, to: AssistantBubbleStore.url) }
            }
        }
    }

    /// 지도 화랑이가 보여 주는 시각을 바꾼다. 같은 분이면 아무것도 하지 않는다.
    func show(at time: Date?) {
        let minute = time.map { floor($0.timeIntervalSinceReferenceDate / 60) }
        guard minute != viewedTime.map({ floor($0.timeIntervalSinceReferenceDate / 60) }) else { return }
        viewedTime = time
        refresh()
    }

    /// 저장한 목록을 받아 다시 고른다. 다른 파일(시험)의 저장은 무시한다.
    func replace(_ list: [AssistantBubble], file saved: URL, now: Date = .now) {
        guard saved == file else { return }
        bubbles = list
        refresh(now: now)
    }
}

/// 말풍선 글 폭 재기와 VoiceOver 글(REV1110A06). 화면에 쓰는 글꼴(`Font.taptionFixed`)과 같은 글꼴로 재고,
/// 화면 전체가 아니라 앱 창의 폭을 기준으로 한다(iPad 분할 화면).
@MainActor
enum AssistantBubbleLayout {
    static func font(size: CGFloat, weight: UIFont.Weight = .semibold) -> UIFont {
        let name: String? = switch TaptionFont.packScript {
        case .selected: TaptionFont.current.name(for: .semibold)
        case .latinFallback: TaptionFont.pretendard.name(for: .semibold)
        case .system: nil
        }
        return name.flatMap { UIFont(name: $0, size: size) } ?? .systemFont(ofSize: size, weight: weight)
    }

    /// 앱 창의 폭. 창을 찾지 못하면 좁은 화면 값으로 둔다.
    static var windowWidth: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.keyWindow?.bounds.width ?? scene?.coordinateSpace.bounds.width ?? 320
    }

    /// 아래로 늘어나는 최대 줄 수(대표 결정 2026-11-10).
    static let maxLines = 5

    /// 글 폭. 옆으로 길게 지도를 가리지 않게 창 폭의 40%에서 접어 아래로 늘리고, 다섯 줄에 안 들어갈 때만 60%까지 넓힌다.
    /// `padding`은 말풍선 좌우 여백 합.
    static func width(_ text: String, size: CGFloat, padding: CGFloat = 16, container: CGFloat? = nil) -> CGFloat {
        let measured = ceil((text as NSString).size(withAttributes: [.font: font(size: size)]).width) + 2
        let window = container ?? windowWidth
        let narrow = window * 0.4 - padding, wide = window * 0.6 - padding
        guard measured > narrow else { return max(1, measured) }
        // 줄이 단어 사이에서 끊겨 남는 자리를 글자 두 개만큼 둔다.
        let fiveLines = ceil(measured / CGFloat(maxLines)) + size * 2
        return max(1, min(wide, max(narrow, fiveLines)))
    }
}

/// 지도 아래 링크 줄(BUB1110A01). 말풍선 자체는 누를 수 없고, 링크와 숨기기는 여기서 한다.
/// 지도의 말풍선은 VoiceOver가 읽지 못하므로 말풍선 글도 여기서 읽어 주고, 새 말풍선이 뜨면 알린다(REV1110A06).
struct AssistantBubbleLinkBar: View {
    let language: MapHomeLanguage
    @State private var pending: AssistantBubbleText.Link?
    private var board: AssistantBubbleBoard { .current }

    var body: some View {
        if let bubble = board.active, let text = bubble.parsed {
            let spoken = language.text("AI 말풍선: \(text.display)", "AI speech bubble: \(text.display)")
            HStack(spacing: 0) {
                // 보이지 않는 한 점. VoiceOver가 말풍선 글을 읽고 숨길 수 있게 한다.
                Color.clear.frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityLabel(spoken)
                    .accessibilityAction(named: language.text("이 말풍선 숨기기", "Hide this bubble")) { AssistantBubbleStore.hide(bubble.id) }
                if !text.links.isEmpty { bar(bubble, text) }
            }
            .task(id: bubble.id) { UIAccessibility.post(notification: .announcement, argument: spoken) }
        }
    }

    private func bar(_ bubble: AssistantBubble, _ text: AssistantBubbleText) -> some View {
        HStack(spacing: 6) {
            ForEach(text.links) { link in
                Button { pending = link } label: { Label(link.label, systemImage: "link").lineLimit(1) }
            }
            Button { AssistantBubbleStore.hide(bubble.id) } label: { Image(systemName: "xmark") }
                .accessibilityLabel(language.text("이 말풍선 숨기기", "Hide this bubble"))
        }
        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.caption), weight: .semibold))
        .buttonStyle(.bordered)
        .padding(6)
        .mapHomeGlass(in: Capsule())
        .alert(language.text("이 주소를 열까요?", "Open this address?"), isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button(language.text("열기", "Open")) {
                // 대문자 scheme(HTTPS://)도 열 수 있게 소문자로 견준다.
                if let url = pending?.url, url.scheme?.lowercased() == "https" { UIApplication.shared.open(url) }
                pending = nil
            }
            Button(language.text("취소", "Cancel"), role: .cancel) { pending = nil }
        } message: {
            Text(pending?.url.host() ?? "")
        }
    }
}

/// 말풍선을 앱 DB에도 남긴다(BUB1110A02). 건강 기록 가져오기처럼 같은 SQLite에 자기 종류로 두어
/// 월별 백업에 함께 들어간다. 파일이 지워져도(새 기기·복원) 여기서 되살린다.
enum AssistantBubbleArchive {
    static let kind = "assistant-bubble"

    @MainActor
    static func mirror(from old: [AssistantBubble], to new: [AssistantBubble]) {
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        let changed = new.filter { before[$0.id] != $0 }
        let kept = Set(new.map(\.id))
        let removed = old.filter { !kept.contains($0.id) }
        guard !changed.isEmpty || !removed.isEmpty else { return }
        Task(priority: .utility) { await write(changed, removing: removed) }
    }

    /// 지운 것은 지움 표시로 남겨 백업·다른 달 복원에서도 되살아나지 않게 한다.
    static func write(_ bubbles: [AssistantBubble], removing removed: [AssistantBubble]) async {
        guard let store = try? TaptionStoreV2.applicationSupport() else { return }
        let encoder = JSONEncoder()
        func row(_ bubble: AssistantBubble, deleted: Bool) -> TaptionStoreRecord? {
            guard let body = try? encoder.encode(bubble), let text = String(data: body, encoding: .utf8) else { return nil }
            var record = TaptionStoreRecord(
                id: bubble.id.uuidString, kind: kind, start: bubble.start, end: bubble.end,
                updatedAt: .now, origin: .imported, body: text
            )
            record.isDeleted = deleted
            return record
        }
        let rows = bubbles.compactMap { row($0, deleted: false) } + removed.compactMap { row($0, deleted: true) }
        if !rows.isEmpty { try? await store.upsertRecords(rows) }
    }

    static func all() async -> [AssistantBubble] {
        guard let store = try? TaptionStoreV2.applicationSupport(),
              let rows = try? await store.records(kind: kind) else { return [] }
        let decoder = JSONDecoder()
        return rows.compactMap { try? decoder.decode(AssistantBubble.self, from: Data($0.body.utf8)) }.sorted { $0.start < $1.start }
    }
}
