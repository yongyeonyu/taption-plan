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
    /// 메모 전용 저장소. 파일만 다르고 표 구조·보호 등급은 본 저장소와 같다.
    /// nil이면(시험용 주입) 예전처럼 본 저장소의 `records` 표에 메모를 둔다.
    private let memoStore: TaptionStoreV2?
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

    init(store: TaptionStoreV2, memoStore: TaptionStoreV2? = nil) {
        self.store = store
        self.memoStore = memoStore
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
        let readStartedAt = Date()
        let memoKind = Kind.memo.rawValue
        // 스냅샷에 담기는 종류만 읽는다. 같은 `records` 표에 사는 HealthKit 원본 표본은
        // `HealthKitImportStore`가 직접 쓰고 읽으므로 시작 경로에서 읽을 이유가 없다.
        // 실기기 로그: 1,284,890행 중 1,258,394행이 그 표본이었고, 읽기 13,793ms 중
        // 거의 전부가 그것이었다(해독은 89ms). 종류를 걸러 읽으면 26,496행만 남는다.
        let snapshotKinds = Kind.allCases.map(\.rawValue) + [Self.headerKind]
        var rows = try await store.allRecordRows(kinds: snapshotKinds)
        if let memoStore {
            // 메모는 별도 파일에서 읽는다. 옛 파일에 남아 있던 메모는 한 번만 옮긴다(삭제 표시도 함께 옮기고 하드 삭제).
            let legacy = rows.filter { $0.kind == memoKind }
            if !legacy.isEmpty {
                let moved = try await store.recordsIncludingDeleted(kind: memoKind)
                if !moved.isEmpty { try await memoStore.upsertRecords(moved) }
                try await store.deleteRecords(kind: memoKind)
                TaptionPlanDiagnosticsLogger.shared.record(
                    "memo_store_migrated",
                    fields: ["moved": String(moved.count)]
                )
            }
            rows.removeAll { $0.kind == memoKind }
            rows += try await memoStore.allRecordRows()
        }
        let readMilliseconds = Date().timeIntervalSince(readStartedAt) * 1_000
        let state = Self.groupedRecordRows(rows)
        known = state
        nextOrd = Self.nextOrdinals(for: state)
        knownHashes = [:]
        // 항목마다 JSONDecoder를 새로 만들면 수만 건을 읽을 때 할당 비용이 그대로 쌓인다.
        let decoder = Self.decoder()
        let decodeStartedAt = Date()

        guard let headerBody = state[Self.headerKind]?[Self.headerID]?.body else {
            // 헤더 없이 다른 행만 있으면 비정상이다. 빈 스냅샷으로 보고 위에 저장하면 그 행이 지워진다.
            Self.recordLoad(
                rowCount: rows.count,
                state: state,
                readMilliseconds: readMilliseconds,
                decodeMilliseconds: Date().timeIntervalSince(decodeStartedAt) * 1_000
            )
            if state.values.contains(where: { !$0.isEmpty }) { throw RepositoryError.invalidSnapshot }
            return .empty
        }
        // 헤더를 해석하지 못하면 빈 스냅샷으로 넘기지 않고 실패시킨다(다음 저장이 전부 지우는 것을 막는다).
        let header: Header
        do {
            header = try decoder.decode(Header.self, from: Data(headerBody.utf8))
        } catch {
            known = nil
            throw RepositoryError.invalidSnapshot
        }
        // 종류별 해석은 서로 독립이라 동시에 돌린다. 항목이 수만 건인 장소·기록이 한 코어를 오래 잡지 않는다.
        async let plans = Self.decode(state, .plan, as: PlanRecord.self)
        async let actuals = Self.decode(state, .actual, as: ActualRecord.self)
        async let recordLinks = Self.decode(state, .recordLink, as: RecordLink.self)
        async let memos = Self.decode(state, .memo, as: ActionMemo.self)
        async let stickers = Self.decode(state, .sticker, as: MapSticker.self)
        async let categories = Self.decode(state, .category, as: CategoryDefinition.self)
        async let photos = Self.decode(state, .photo, as: PhotoMoment.self)
        async let calendarEvents = Self.decode(state, .calendarEvent, as: CalendarRecord.self)
        async let weather = Self.decode(state, .weather, as: WeatherContext.self)
        async let places = Self.decode(state, .place, as: PlaceStay.self)
        async let travel = Self.decode(state, .travel, as: TravelSegment.self)
        async let floorTransitions = Self.decode(state, .floorTransition, as: FloorTransition.self)
        async let yearlyReports = Self.decode(state, .yearlyReport, as: YearlyReviewArchive.self)
        let decoded = try await (plans, actuals, recordLinks, memos, stickers, categories, photos,
                                 calendarEvents, weather, places, travel, floorTransitions, yearlyReports)
        var hashes: [String: [String: Int]] = [:]
        func take<T>(_ value: Decoded<T>, _ kind: Kind) -> [T] {
            hashes[kind.rawValue] = value.hashes
            return value.items
        }
        let snapshot = TaptionDataSnapshot(
            schemaVersion: header.schemaVersion,
            updatedAt: header.updatedAt,
            plans: take(decoded.0, .plan),
            actuals: take(decoded.1, .actual),
            recordLinks: take(decoded.2, .recordLink),
            memos: take(decoded.3, .memo),
            stickers: take(decoded.4, .sticker),
            categories: take(decoded.5, .category),
            photos: take(decoded.6, .photo),
            calendarEvents: take(decoded.7, .calendarEvent),
            weather: take(decoded.8, .weather),
            places: take(decoded.9, .place),
            travel: take(decoded.10, .travel),
            floorTransitions: take(decoded.11, .floorTransition),
            yearlyReports: take(decoded.12, .yearlyReport),
            settings: header.settings
        )
        knownHashes = hashes
        Self.recordLoad(
            rowCount: rows.count,
            state: state,
            readMilliseconds: readMilliseconds,
            decodeMilliseconds: Date().timeIntervalSince(decodeStartedAt) * 1_000
        )
        return snapshot
    }

    /// 저장 직후 확인용. `actual` 종류만 읽어(수백 행) 2만 행대 전체 재적재를 피한다.
    /// 지워지지 않은 행만 돌려주므로, 저장이 반영되지 않았으면 빈 결과가 나온다.
    func existingActualIDs(_ ids: Set<UUID>) async throws -> Set<UUID> {
        guard !ids.isEmpty else { return [] }
        let stored = Set(try await store.records(kind: Kind.actual.rawValue).map(\.id))
        return Set(ids.map { "\($0)" }.filter(stored.contains).compactMap(UUID.init(uuidString:)))
    }

    /// 시작 적재 비용을 읽기와 해석으로 나눠 남긴다. 본문·좌표는 남기지 않고 행 수와 시간만 기록한다.
    private nonisolated static func recordLoad(
        rowCount: Int,
        state: [String: [String: (ord: Int, body: String)]],
        readMilliseconds: Double,
        decodeMilliseconds: Double
    ) {
        let summary = state
            .mapValues(\.count)
            .sorted { $0.value > $1.value }
            .prefix(4)
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        TaptionPlanDiagnosticsLogger.shared.record(
            "repository_local_load",
            fields: ["kinds": summary],
            metrics: [
                "rows": Double(rowCount),
                "kind_count": Double(state.count),
                "read_ms": readMilliseconds,
                "decode_ms": decodeMilliseconds,
                "total_ms": readMilliseconds + decodeMilliseconds,
            ]
        )
    }

    /// 한 종류의 행을 순서대로 해석하고 값 해시를 함께 만든다. 해시는 저장할 때 바뀌지 않은 항목을
    /// 다시 JSON으로 만들지 않는 기준이다.
    private struct Decoded<T> {
        var items: [T]
        var hashes: [String: Int]
    }

    /// 읽은 행을 종류 → id → (순서, 본문)으로 묶는다. 해석 작업들이 이 값을 나눠 읽는다.
    private nonisolated static func groupedRecordRows(
        _ rows: [(kind: String, id: String, ord: Int, body: String)]
    ) -> [String: [String: (ord: Int, body: String)]] {
        var state: [String: [String: (ord: Int, body: String)]] = [:]
        for row in rows {
            state[row.kind, default: [:]][row.id] = (row.ord, row.body)
        }
        return state
    }

    private nonisolated static func nextOrdinals(
        for state: [String: [String: (ord: Int, body: String)]]
    ) -> [String: Int] {
        var next: [String: Int] = [:]
        for (kind, entries) in state {
            next[kind] = (entries.values.map(\.ord).max() ?? -1) + 1
        }
        return next
    }

    private nonisolated static func decode<T: Decodable & Hashable>(
        _ state: [String: [String: (ord: Int, body: String)]],
        _ kind: Kind,
        as type: T.Type
    ) throws -> Decoded<T> {
        let ordered = (state[kind.rawValue] ?? [:]).sorted { $0.value.ord < $1.value.ord }
        let decoder = decoder()
        var items: [T] = []
        items.reserveCapacity(ordered.count)
        var hashes: [String: Int] = [:]
        hashes.reserveCapacity(ordered.count)
        for entry in ordered {
            let item = try decoder.decode(T.self, from: Data(entry.value.body.utf8))
            items.append(item)
            hashes[entry.key] = item.hashValue
        }
        return Decoded(items: items, hashes: hashes)
    }

    /// 저장은 한 번에 하나씩 순서대로 처리한다(await 사이에 다른 저장이 끼어들면 비교 기준이 어긋난다).
    func save(_ snapshot: TaptionDataSnapshot) async throws {
        guard TaptionDataDeletionFence.allows(generation: deletionGeneration) else {
            throw RepositoryError.staleGeneration
        }
        let previous = saveTail
        let task = Task { [self] in
            _ = try? await previous?.value
            // 쓰기 트랜잭션을 연 채 서스펜드되면 시스템이 0xdead10cc로 앱을 종료한다.
            // 만료 전에 끝내거나 취소하도록 백그라운드 시간을 확보한 뒤 쓴다.
            try await TaptionRepositoryBackgroundExecution.run {
                try await self.performSave(snapshot)
            }
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
        /// 메모는 별도 파일에 쓴다(파일이 다르면 한 트랜잭션으로 묶을 수 없다).
        var memoUpserts: [TaptionStoreRecord] = []
        var memoDeletes: [(kind: String, id: String)] = []
        var newKnown = known ?? [:]
        var newHashes = knownHashes
        // 바뀐 항목마다 JSONEncoder를 새로 만들지 않고 한 번만 만든다.
        let encoder = Self.encoder()

        func sync<T: Encodable & Identifiable & Hashable>(_ kind: Kind, _ items: [T]) throws {
            let goesToMemoStore = kind == .memo && memoStore != nil
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
                let body = try Self.encode(item, using: encoder)
                encodedItemCount += 1
                hashes[id] = hash
                if let existing = previous[id], existing.body == body { continue }
                let ord = previous[id]?.ord ?? takeOrd(kind.rawValue)
                previous[id] = (ord, body)
                let record = Self.record(kind: kind.rawValue, id: id, ord: ord, body: body,
                                         updatedAt: snapshot.updatedAt)
                if goesToMemoStore { memoUpserts.append(record) } else { upserts.append(record) }
            }
            for id in previous.keys where !seen.contains(id) {
                previous[id] = nil
                hashes[id] = nil
                if goesToMemoStore { memoDeletes.append((kind.rawValue, id)) }
                else { deletes.append((kind.rawValue, id)) }
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
        let headerBody = try Self.encode(header, using: encoder)
        if newKnown[Self.headerKind]?[Self.headerID]?.body != headerBody {
            upserts.append(Self.record(kind: Self.headerKind, id: Self.headerID, ord: 0, body: headerBody,
                                       updatedAt: snapshot.updatedAt))
            newKnown[Self.headerKind] = [Self.headerID: (0, headerBody)]
        }

        try await store.applyRecordChanges(upserts: upserts, deletes: deletes, deletedAt: Date())
        if let memoStore, !memoUpserts.isEmpty || !memoDeletes.isEmpty {
            try await memoStore.applyRecordChanges(
                upserts: memoUpserts,
                deletes: memoDeletes,
                deletedAt: Date()
            )
        }
        known = newKnown
        knownHashes = newHashes
    }

    func deleteAll() async throws {
        try await store.deleteAllRecords()
        if let memoStore { try await memoStore.deleteAllRecords() }
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

    /// 여러 항목을 같은 인코더로 연속 변환한다.
    private static func encode<T: Encodable>(_ value: T, using encoder: JSONEncoder) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
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
        let memoStore = try TaptionStoreV2.shared(
            at: directory.appendingPathComponent(TaptionStoreV2.memoFileName)
        )
        return TaptionStoreRepository(store: store, memoStore: memoStore)
    }

    /// 메모 저장소(백업 엔진이 메모 행을 함께 담을 때 쓴다).
    nonisolated var memos: TaptionStoreV2? { memoStore }
}
