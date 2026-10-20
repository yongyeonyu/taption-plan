import Foundation
import TaptionPlanCore

/// 계획·기록 저장소. `TaptionStoreV2`의 `records` 표에 스냅샷의 모든 항목을 행 하나씩 저장한다.
/// 저장할 때는 직전 상태와 비교해 바뀐 행만 쓰고 사라진 행은 지운다.
actor TaptionStoreRepository: PlanDataRepository {
    /// 스냅샷의 각 배열이 `records` 표에서 갖는 종류 이름과 출처.
    private enum Kind: String, CaseIterable {
        case plan, actual, recordLink, memo, sticker, category, photo
        case calendarEvent, weather, place, travel, floorTransition, yearlyReport
    }

    private struct Header: Codable {
        var schemaVersion: Int
        var updatedAt: Date
        var settings: AppFeatureSettings
    }

    private static let headerKind = "header"
    private static let headerID = "snapshot"

    private let store: TaptionStoreV2
    /// 이 저장소 객체가 알고 있는 전역 삭제 세대. 데이터 삭제가 진행 중이거나 그 뒤에 만들어진 세대와 다르면 쓰지 않는다.
    private var deletionGeneration = TaptionDataDeletionFence.currentGeneration()
    /// 마지막으로 저장소와 맞춘 상태: 종류 → id → (순서, 본문).
    private var known: [String: [String: (ord: Int, body: String)]]?
    private var nextOrd: [String: Int] = [:]
    /// 마지막으로 저장소와 맞춘 각 항목의 해시: 종류 → id → hashValue. 저장할 때 해시가 같은 항목은 JSON으로 다시 만들지 않는다
    /// (이전에는 저장할 때마다 모든 기록을 JSON으로 만들어 비교해, 기록이 많으면 미확인 활동 하나를 저장하는 데도 몇 초가 걸렸다).
    private var knownHashes: [String: [String: Int]] = [:]
    /// 테스트용: 마지막 초기화 이후 JSON으로 만든 항목 수.
    private var encodedItemCount = 0
    private var saveTail: Task<Void, Error>?

    init(store: TaptionStoreV2) {
        self.store = store
    }

    /// 시작 화면용 가벼운 읽기: 헤더 행 하나(설정·갱신 시각)만 읽어 설정만 담은 스냅샷을 돌려준다.
    /// 모든 행을 읽고 해석하는 `load()`를 기다리지 않고 지도 시작 화면이 먼저 열리게 한다.
    /// 헤더가 없거나 해석할 수 없으면 nil이며, 이때는 `load()`가 정식 결과(또는 오류)를 낸다.
    func loadStartupSnapshot() async throws -> TaptionDataSnapshot? {
        let rows = try await store.records(kind: Self.headerKind)
        guard let body = rows.first(where: { $0.id == Self.headerID })?.body,
              let header = try? Self.decoder().decode(Header.self, from: Data(body.utf8)),
              header.updatedAt != .distantPast else { return nil }
        var startup = TaptionDataSnapshot.empty
        startup.schemaVersion = header.schemaVersion
        startup.updatedAt = header.updatedAt
        startup.settings = header.settings
        return startup
    }

    func load() async throws -> TaptionDataSnapshot {
        let rows = try await store.allRecordRows()
        var state: [String: [String: (ord: Int, body: String)]] = [:]
        var next: [String: Int] = [:]
        for row in rows {
            state[row.kind, default: [:]][row.id] = (row.ord, row.body)
            next[row.kind] = max(next[row.kind] ?? 0, row.ord + 1)
        }
        known = state
        nextOrd = next
        knownHashes = [:]

        guard let headerBody = state[Self.headerKind]?[Self.headerID]?.body else {
            // 헤더 없이 다른 행만 있으면 비정상이다. 빈 스냅샷으로 보고 위에 저장하면 그 행이 지워진다.
            if state.values.contains(where: { !$0.isEmpty }) { throw RepositoryError.invalidSnapshot }
            return .empty
        }
        // 헤더를 해석하지 못하면 빈 스냅샷으로 넘기지 않고 실패시킨다(다음 저장이 전부 지우는 것을 막는다).
        let header: Header
        do {
            header = try Self.decoder().decode(Header.self, from: Data(headerBody.utf8))
        } catch {
            known = nil
            throw RepositoryError.invalidSnapshot
        }
        var loadedHashes: [String: [String: Int]] = [:]
        func items<T: Decodable & Hashable>(_ kind: Kind, as type: T.Type) throws -> [T] {
            let ordered = (state[kind.rawValue] ?? [:]).sorted { $0.value.ord < $1.value.ord }
            var hashes: [String: Int] = [:]
            hashes.reserveCapacity(ordered.count)
            let decoded = try ordered.map { entry -> T in
                let item = try Self.decoder().decode(T.self, from: Data(entry.value.body.utf8))
                hashes[entry.key] = item.hashValue
                return item
            }
            loadedHashes[kind.rawValue] = hashes
            return decoded
        }
        defer { knownHashes = loadedHashes }
        return TaptionDataSnapshot(
            schemaVersion: header.schemaVersion,
            updatedAt: header.updatedAt,
            plans: try items(.plan, as: PlanRecord.self),
            actuals: try items(.actual, as: ActualRecord.self),
            recordLinks: try items(.recordLink, as: RecordLink.self),
            memos: try items(.memo, as: ActionMemo.self),
            stickers: try items(.sticker, as: MapSticker.self),
            categories: try items(.category, as: CategoryDefinition.self),
            photos: try items(.photo, as: PhotoMoment.self),
            calendarEvents: try items(.calendarEvent, as: CalendarRecord.self),
            weather: try items(.weather, as: WeatherContext.self),
            places: try items(.place, as: PlaceStay.self),
            travel: try items(.travel, as: TravelSegment.self),
            floorTransitions: try items(.floorTransition, as: FloorTransition.self),
            yearlyReports: try items(.yearlyReport, as: YearlyReviewArchive.self),
            settings: header.settings
        )
    }

    /// 저장은 한 번에 하나씩 순서대로 처리한다(await 사이에 다른 저장이 끼어들면 비교 기준이 어긋난다).
    func save(_ snapshot: TaptionDataSnapshot) async throws {
        guard TaptionDataDeletionFence.allows(generation: deletionGeneration) else {
            throw RepositoryError.staleGeneration
        }
        let previous = saveTail
        let task = Task { [self] in
            _ = try? await previous?.value
            try await performSave(snapshot)
        }
        saveTail = task
        try await task.value
    }

    private func performSave(_ snapshot: TaptionDataSnapshot) async throws {
        // 순서를 기다리는 사이에 데이터 삭제가 일어났을 수 있으므로 다시 확인한다.
        guard TaptionDataDeletionFence.allows(generation: deletionGeneration) else {
            throw RepositoryError.staleGeneration
        }
        if known == nil { _ = try await load() }
        var upserts: [TaptionStoreRecord] = []
        var deletes: [(kind: String, id: String)] = []
        var newKnown = known ?? [:]
        var newHashes = knownHashes

        func sync<T: Encodable & Identifiable & Hashable>(_ kind: Kind, _ items: [T]) throws {
            var previous = newKnown[kind.rawValue] ?? [:]
            var hashes = newHashes[kind.rawValue] ?? [:]
            var seen = Set<String>()
            seen.reserveCapacity(items.count)
            for item in items {
                let id = "\(item.id)"
                seen.insert(id)
                let hash = item.hashValue
                // 저장소와 맞춘 뒤 바뀌지 않은 항목은 JSON으로 다시 만들지 않는다.
                if hashes[id] == hash, previous[id] != nil { continue }
                let body = try Self.encode(item)
                encodedItemCount += 1
                hashes[id] = hash
                if let existing = previous[id], existing.body == body { continue }
                let ord = previous[id]?.ord ?? takeOrd(kind.rawValue)
                previous[id] = (ord, body)
                upserts.append(Self.record(kind: kind.rawValue, id: id, ord: ord, body: body,
                                           updatedAt: snapshot.updatedAt))
            }
            for id in previous.keys where !seen.contains(id) {
                previous[id] = nil
                hashes[id] = nil
                deletes.append((kind.rawValue, id))
            }
            newKnown[kind.rawValue] = previous
            newHashes[kind.rawValue] = hashes
        }

        try sync(.plan, snapshot.plans)
        try sync(.actual, snapshot.actuals)
        try sync(.recordLink, snapshot.recordLinks)
        try sync(.memo, snapshot.memos)
        try sync(.sticker, snapshot.stickers)
        try sync(.category, snapshot.categories)
        try sync(.photo, snapshot.photos)
        try sync(.calendarEvent, snapshot.calendarEvents)
        try sync(.weather, snapshot.weather)
        try sync(.place, snapshot.places)
        try sync(.travel, snapshot.travel)
        try sync(.floorTransition, snapshot.floorTransitions)
        try sync(.yearlyReport, snapshot.yearlyReports)

        let header = Header(
            schemaVersion: snapshot.schemaVersion, updatedAt: snapshot.updatedAt, settings: snapshot.settings
        )
        let headerBody = try Self.encode(header)
        if newKnown[Self.headerKind]?[Self.headerID]?.body != headerBody {
            upserts.append(Self.record(kind: Self.headerKind, id: Self.headerID, ord: 0, body: headerBody,
                                       updatedAt: snapshot.updatedAt))
            newKnown[Self.headerKind] = [Self.headerID: (0, headerBody)]
        }

        try await store.applyRecordChanges(upserts: upserts, deletes: deletes, deletedAt: Date())
        known = newKnown
        knownHashes = newHashes
    }

    func deleteAll() async throws {
        try await store.deleteAllRecords()
        known = [:]
        knownHashes = [:]
        nextOrd = [:]
        deletionGeneration = TaptionDataDeletionFence.currentGeneration()
    }

    func handleMemoryPressure() async {
        // 다음 저장 때 저장소에서 다시 읽어 비교 기준을 만든다.
        known = nil
        knownHashes = [:]
    }

    func resetEncodedItemCountForTesting() { encodedItemCount = 0 }
    func encodedItemCountForTesting() -> Int { encodedItemCount }

    private func takeOrd(_ kind: String) -> Int {
        let value = nextOrd[kind] ?? 0
        nextOrd[kind] = value + 1
        return value
    }

    // MARK: 변환

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder().encode(value), as: UTF8.self)
    }

    /// 본문 JSON에서 시각·출처를 뽑아 열에 채운다(분석용). 못 찾으면 비워 둔다.
    private static func record(
        kind: String, id: String, ord: Int, body: String, updatedAt: Date
    ) -> TaptionStoreRecord {
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
        func seconds(_ key: String, in dictionary: [String: Any]) -> Date? {
            (dictionary[key] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        }
        let span = object["span"] as? [String: Any]
        let start = seconds("startedAt", in: object) ?? span.flatMap { seconds("start", in: $0) }
            ?? seconds("occurredAt", in: object) ?? seconds("capturedAt", in: object)
            ?? seconds("start", in: object) ?? seconds("date", in: object)
        let end = seconds("endedAt", in: object) ?? span.flatMap { seconds("end", in: $0) }
            ?? seconds("end", in: object)
        let origin: TaptionStoreRecord.Origin
        switch kind {
        case "place", "travel", "weather", "floorTransition", "yearlyReport": origin = .auto
        case "photo", "calendarEvent": origin = .imported
        case "actual":
            origin = (object["manuallyCorrected"] as? Bool) == true || (object["source"] as? String) == "manual"
                ? .user : .auto
        default: origin = .user
        }
        return TaptionStoreRecord(
            id: id, kind: kind, start: start, end: end, updatedAt: updatedAt, origin: origin,
            ord: ord, body: body
        )
    }
}

extension TaptionStoreRepository {
    /// 위젯 등 확장이 앱과 같은 파일(앱 그룹 컨테이너의 `taption-store.sqlite`)을 연다.
    static func appGroup(fileManager: FileManager = .default) throws -> TaptionStoreRepository {
        guard let directory = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: TaptionPlanSharedContainer.appGroupIdentifier
        ) else { throw RepositoryError.appGroupUnavailable }
        let store = try TaptionStoreV2.shared(at: directory.appendingPathComponent(TaptionStoreV2.fileName))
        return TaptionStoreRepository(store: store)
    }
}
