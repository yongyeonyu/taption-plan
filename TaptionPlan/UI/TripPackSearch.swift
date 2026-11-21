import CoreLocation
import Foundation

/// 도시 팩 검색(SRCH1121A01, ARCH1120A01 10절 1순위). Algolia를 먼저 부르고, 꺼져 있거나 느리거나 틀리면 기기 안의 팩 검색으로 넘어간다.
/// - Algolia는 검색용 파생 색인이다. 정본은 R2 팩과 기기에 내려받은 팩이라, 결과는 objectID로 기기 팩에서 다시 읽는다(주소·전화는 팩에서).
/// - 서버에 보내는 것은 검색어와 카테고리뿐이다. 현재 위치·좌표는 보내지 않고(geo-search 금지), 거리 정렬은 기기에서 한다.
/// - 호출을 아끼려고 입력을 늦추고(디바운스) 같은 검색은 캐시하며 하루 호출 수를 기기에서 제한한다(무료 월 10,000회 안).

struct TripPackSearchKey: Decodable, Equatable, Sendable {
    var appId: String
    var index: String
    var key: String
    var validUntil: TimeInterval
}

/// 서버·Algolia 호출 묶음. 시험에서는 가짜로 바꾼다.
protocol TripPackSearchTransport: Sendable {
    /// 앱 서버에서 검색용 Secured Key를 받는다. 서버에 키가 없거나 한도에 닿으면 nil.
    func issueKey(city: String, version: Int) async -> TripPackSearchKey?
    /// Algolia에 검색어(와 카테고리)만 보내고 objectID 목록을 받는다. 실패·시간 초과는 nil.
    func query(key: TripPackSearchKey, text: String, category: String?) async -> [String]?
}

enum TripPackSearchSource: Equatable, Sendable {
    case algolia
    case local
}

struct TripPackSearchOutcome: Equatable, Sendable {
    var items: [TripPackItem]
    var source: TripPackSearchSource
}

/// 호출 수를 아끼는 순수 규칙(시험하기 쉽게 시계·저장소를 받는다).
struct TripPackSearchBudget: Sendable {
    static let dailyLimit = 60
    static let storageKey = "tripPackSearch.budget"

    var day: String
    var count: Int

    static func today(_ now: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// 오늘 몫이 남았는지. 남았으면 1을 센 값을 돌려준다.
    func charged(now: Date) -> TripPackSearchBudget? {
        let current = Self.today(now)
        let used = day == current ? count : 0
        return used < Self.dailyLimit ? TripPackSearchBudget(day: current, count: used + 1) : nil
    }
}

actor TripPackSearch {
    static let minimumCharacters = 2
    static let debounceNanoseconds: UInt64 = 400_000_000
    static let cacheLifetime: TimeInterval = 600
    static let cacheLimit = 40
    static let keyMargin: TimeInterval = 60

    private struct CacheEntry { var ids: [String]; var at: Date }

    private let transport: any TripPackSearchTransport
    private let now: @Sendable () -> Date
    private let defaults: UserDefaults
    private var key: TripPackSearchKey?
    private var keyScope: String?
    private var cache: [String: CacheEntry] = [:]

    init(transport: any TripPackSearchTransport = TripPackSearchLive(), defaults: UserDefaults = .standard, now: @escaping @Sendable () -> Date = { .now }) {
        self.transport = transport
        self.defaults = defaults
        self.now = now
    }

    /// 입력이 멈춘 뒤에 검색한다. 그 사이 취소되면 호출하지 않는다.
    func debouncedSearch(_ text: String, in pack: TripPack, category: TripPackCategory? = nil) async -> TripPackSearchOutcome? {
        do { try await Task.sleep(nanoseconds: Self.debounceNanoseconds) } catch { return nil }
        guard !Task.isCancelled else { return nil }
        return await search(text, in: pack, category: category)
    }

    func search(_ text: String, in pack: TripPack, category: TripPackCategory? = nil) async -> TripPackSearchOutcome {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let local = TripPackSearchOutcome(items: Self.visible(TripPackReader.filter(pack.items, category: category, query: query)), source: .local)
        // 짧은 입력·빈 입력은 기기에서 바로 거른다(호출을 쓰지 않는다).
        guard query.count >= Self.minimumCharacters, query.count <= 100 else { return local }
        let cacheKey = "\(pack.city)|\(pack.version)|\(category?.rawValue ?? "")|\(query.lowercased())"
        if let hit = cache[cacheKey], now().timeIntervalSince(hit.at) < Self.cacheLifetime {
            return resolve(hit.ids, in: pack, category: category) ?? local
        }
        guard let ids = await remoteIDs(query: query, pack: pack, category: category) else { return local }
        cache[cacheKey] = CacheEntry(ids: ids, at: now())
        if cache.count > Self.cacheLimit, let oldest = cache.min(by: { $0.value.at < $1.value.at })?.key { cache[oldest] = nil }
        return resolve(ids, in: pack, category: category) ?? local
    }

    private func remoteIDs(query: String, pack: TripPack, category: TripPackCategory?) async -> [String]? {
        guard let usable = await usableKey(for: pack), spendCall() else { return nil }
        guard let raw = await transport.query(key: usable, text: query, category: category?.rawValue) else { return nil }
        let prefix = "\(pack.city):\(pack.version):"
        return raw.compactMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil }
    }

    private func usableKey(for pack: TripPack) async -> TripPackSearchKey? {
        let scope = "\(pack.city)|\(pack.version)"
        if let key, keyScope == scope, key.validUntil - now().timeIntervalSince1970 > Self.keyMargin { return key }
        guard let issued = await transport.issueKey(city: pack.city, version: pack.version) else { return nil }
        key = issued
        keyScope = scope
        return issued
    }

    /// 하루 호출 수를 센다. 몫이 없으면 false라 기기 검색으로 넘어간다.
    private func spendCall() -> Bool {
        let saved = defaults.dictionary(forKey: TripPackSearchBudget.storageKey)
        let current = TripPackSearchBudget(day: saved?["day"] as? String ?? "", count: saved?["count"] as? Int ?? 0)
        guard let next = current.charged(now: now()) else { return false }
        defaults.set(["day": next.day, "count": next.count], forKey: TripPackSearchBudget.storageKey)
        return true
    }

    /// Algolia가 준 순서를 지키되 기기 팩에 있는 항목만, 지금 앱이 아는 카테고리만 쓴다.
    private func resolve(_ ids: [String], in pack: TripPack, category: TripPackCategory?) -> TripPackSearchOutcome? {
        let byID = Dictionary(pack.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let items = Self.visible(ids.compactMap { byID[$0] }.filter { category == nil || $0.category == category?.rawValue })
        return items.isEmpty ? nil : TripPackSearchOutcome(items: items, source: .algolia)
    }

    /// 처방 의약품을 사는 길은 결과에서 뺀다(4-4). 팩 쪽 태그에 처방이 들어 있는 항목이 대상이다.
    nonisolated static func visible(_ items: [TripPackItem]) -> [TripPackItem] {
        items.filter { !isPrescriptionRoute($0) }
    }

    nonisolated static func isPrescriptionRoute(_ item: TripPackItem) -> Bool {
        let words = ["처방", "prescription", "処方"]
        return (item.tags ?? []).contains { tag in words.contains { tag.lowercased().contains($0) } }
    }

    /// 병원·약국이고 확인일이 90일을 넘으면 「오래된 정보 · 확인 필요」를 보인다.
    nonisolated static func needsCheck(_ item: TripPackItem, now: Date = .now) -> Bool {
        guard TripPackCategory(rawValue: item.category)?.isSafetyInfo == true else { return false }
        return TripPackReader.isStale(item, now: now)
    }

    /// 거리 정렬은 기기에서 팩 좌표로 한다. 현재 위치는 이 함수 밖으로 나가지 않는다.
    nonisolated static func sortedByDistance(_ items: [TripPackItem], from origin: CLLocationCoordinate2D?) -> [TripPackItem] {
        guard let origin, CLLocationCoordinate2DIsValid(origin) else { return items }
        let here = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        return items.sorted {
            here.distance(from: CLLocation(latitude: $0.lat, longitude: $0.lng)) < here.distance(from: CLLocation(latitude: $1.lat, longitude: $1.lng))
        }
    }
}

/// 실제 호출: 앱 서버(`/search/packs/key`)에서 키를 받고 Algolia에 직접 검색한다. 서버 주소·토큰이 없거나 실패하면 nil이다.
struct TripPackSearchLive: TripPackSearchTransport {
    static let timeout: TimeInterval = 3

    func issueKey(city: String, version: Int) async -> TripPackSearchKey? {
        guard let host = TripRelay.host, var parts = URLComponents(string: "https://\(host)/search/packs/key"),
              let token = await AssistantRegistration.searchToken() else { return nil }
        parts.queryItems = [URLQueryItem(name: "city", value: city), URLQueryItem(name: "version", value: String(version))]
        guard let url = parts.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: Self.timeout)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return nil }
        if status == 401 { await AssistantRegistration.searchTokenRejected() }
        return status == 200 ? try? JSONDecoder().decode(TripPackSearchKey.self, from: data) : nil
    }

    func query(key: TripPackSearchKey, text: String, category: String?) async -> [String]? {
        guard Self.validAppID(key.appId), let url = URL(string: "https://\(key.appId)-dsn.algolia.net/1/indexes/\(key.index)/query") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.setValue(key.appId, forHTTPHeaderField: "X-Algolia-Application-Id")
        request.setValue(key.key, forHTTPHeaderField: "X-Algolia-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let body = Self.body(text: text, category: category) else { return nil }
        request.httpBody = body
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return Self.decodeIDs(data)
    }

    static func validAppID(_ id: String) -> Bool {
        (6...24).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// 검색어·카테고리·개수·받을 칸만 보낸다. 좌표·위치·사용자 식별자 칸은 없다.
    static func body(text: String, category: String?) -> Data? {
        var object: [String: Any] = ["query": text, "hitsPerPage": 20, "attributesToRetrieve": ["objectID"]]
        if let category { object["facetFilters"] = ["category:\(category)"] }
        return try? JSONSerialization.data(withJSONObject: object)
    }

    static func decodeIDs(_ data: Data) -> [String]? {
        struct Reply: Decodable {
            struct Hit: Decodable { var objectID: String }
            var hits: [Hit]
        }
        return (try? JSONDecoder().decode(Reply.self, from: data))?.hits.map(\.objectID)
    }
}
