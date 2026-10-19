import Foundation

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
    /// 마지막으로 저장소와 맞춘 상태: 종류 → id → (순서, 본문).
    private var known: [String: [String: (ord: Int, body: String)]]?
    private var nextOrd: [String: Int] = [:]
    private var saveTail: Task<Void, Error>?

    init(store: TaptionStoreV2) {
        self.store = store
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
        func items<T: Decodable>(_ kind: Kind, as type: T.Type) throws -> [T] {
            let ordered = (state[kind.rawValue] ?? [:]).values.sorted { $0.ord < $1.ord }
            return try ordered.map { try Self.decoder().decode(T.self, from: Data($0.body.utf8)) }
        }
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
        let previous = saveTail
        let task = Task { [self] in
            _ = try? await previous?.value
            try await performSave(snapshot)
        }
        saveTail = task
        try await task.value
    }

    private func performSave(_ snapshot: TaptionDataSnapshot) async throws {
        if known == nil { _ = try await load() }
        var upserts: [TaptionStoreRecord] = []
        var deletes: [(kind: String, id: String)] = []
        var newKnown = known ?? [:]

        func sync<T: Encodable & Identifiable>(_ kind: Kind, _ items: [T]) throws {
            var previous = newKnown[kind.rawValue] ?? [:]
            var seen = Set<String>()
            for item in items {
                let id = "\(item.id)"
                let body = try Self.encode(item)
                seen.insert(id)
                if let existing = previous[id], existing.body == body { continue }
                let ord = previous[id]?.ord ?? takeOrd(kind.rawValue)
                previous[id] = (ord, body)
                upserts.append(Self.record(kind: kind.rawValue, id: id, ord: ord, body: body,
                                           updatedAt: snapshot.updatedAt))
            }
            for id in previous.keys where !seen.contains(id) {
                previous[id] = nil
                deletes.append((kind.rawValue, id))
            }
            newKnown[kind.rawValue] = previous
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
    }

    func deleteAll() async throws {
        try await store.deleteAllRecords()
        known = [:]
        nextOrd = [:]
    }

    func handleMemoryPressure() async {
        // 다음 저장 때 저장소에서 다시 읽어 비교 기준을 만든다.
        known = nil
    }

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
