import Foundation
import SQLite3

/// 백업 복원·합치기의 마지막 단계. 엔진이 백업 파일을 준비 저장소(같은 표 구조의 다른 SQLite 파일)에 끝까지 풀고
/// 검증한 뒤, 이 함수가 준비 파일의 행을 한 트랜잭션으로 이 저장소에 합친다.
extension TaptionStoreV2 {
    struct RestoreStagingResult: Equatable, Sendable {
        var newReadings = 0
        var readingConflicts = 0
        var changedRecords = 0
    }

    enum RestoreRecordFilter: Sendable {
        case all
        case excluding(kind: String)
        case only(kind: String)
    }

    private static let stagingSchema = "restore_staging"

    /// 준비 파일의 센서 원본·원본 이벤트(`includeReadings`)와 기록을 합치고 `meta`도 같은 트랜잭션에 쓴다.
    /// 하나라도 실패하면(같은 id 다른 내용, 디스크, 형식) 전부 되돌려 이 저장소는 부르기 전 그대로다.
    /// 규칙은 `appendImmutableReadings`/`mergeReadingsKeepingLocal`·`appendRawEvents`·`upsertRecordsKeepingNewer`와 같다.
    func applyRestoreStaging(
        at staging: URL, includeReadings: Bool, rejectReadingConflicts: Bool,
        records filter: RestoreRecordFilter, meta: [String: String]
    ) throws -> RestoreStagingResult {
        let db = try handle()
        let attach = try prepare(db, "ATTACH DATABASE ? AS \(Self.stagingSchema)")
        bind(attach, 1, .text(staging.path))
        let attached = sqlite3_step(attach)
        sqlite3_finalize(attach)
        guard attached == SQLITE_DONE else { throw TaptionStoreV2Error.sqlFailed(String(cString: sqlite3_errmsg(db))) }
        defer { try? exec(db, "DETACH DATABASE \(Self.stagingSchema)") }
        try exec(db, "BEGIN IMMEDIATE")
        do {
            var result = RestoreStagingResult()
            if includeReadings {
                result.readingConflicts = try stagedReadingConflicts(db, reject: rejectReadingConflicts)
                result.newReadings = try copyStagedReadings(db)
                try copyStagedRawEvents(db)
            }
            let winners = try stagedRecordWinners(db, filter: filter)
            try upsertRecordRows(db, winners)
            result.changedRecords = winners.count
            for (key, value) in meta.sorted(by: { $0.key < $1.key }) { try setMeta(key, value) }
            try exec(db, "COMMIT")
            return result
        } catch {
            try? exec(db, "ROLLBACK")
            throw error
        }
    }

    private static var readingColumns: [String] {
        ["id", "ts", "day"] + TaptionReadingRowCodec.columns.map(\.name) + ["extra"]
    }

    /// 이미 있는 id 중 내용이 다른 행을 센다(저장 형태끼리 `sameStoredContent`로 비교). `reject`면 첫 충돌에서 던진다.
    private func stagedReadingConflicts(_ db: OpaquePointer, reject: Bool) throws -> Int {
        let columns = Self.readingColumns
        let select = (columns.map { "s.\($0)" } + columns.map { "m.\($0)" }).joined(separator: ", ")
        let statement = try prepare(db, """
            SELECT \(select) FROM \(Self.stagingSchema).readings s JOIN main.readings m ON m.id = s.id
            """)
        defer { sqlite3_finalize(statement) }
        var conflicts = 0
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            let staged = Self.stagedRow(statement, offset: 0, width: columns.count)
            let local = Self.stagedRow(statement, offset: Int32(columns.count), width: columns.count)
            let same = (try? TaptionReadingRowCodec.sameStoredContent(
                TaptionReadingRowCodec.reading(from: staged), TaptionReadingRowCodec.reading(from: local)
            )) ?? false
            if !same {
                if reject { throw TaptionStoreV2Error.readingConflict(staged.id) }
                conflicts += 1
            }
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { throw TaptionStoreV2Error.sqlFailed(String(cString: sqlite3_errmsg(db))) }
        return conflicts
    }

    private static func stagedRow(_ statement: OpaquePointer, offset: Int32, width: Int) -> TaptionReadingRowCodec.Row {
        let values = (3..<(width - 1)).map { stagedValue(statement, offset + Int32($0)) }
        var id = ""
        if case .blob(let data) = stagedValue(statement, offset) { id = TaptionReadingRowCodec.uuidString(from: data) ?? "" }
        var extra: String?
        if case .text(let text) = stagedValue(statement, offset + Int32(width - 1)) { extra = text }
        return TaptionReadingRowCodec.Row(
            id: id, timestamp: sqlite3_column_double(statement, offset + 1),
            day: Int(sqlite3_column_int64(statement, offset + 2)), values: values, extra: extra
        )
    }

    private static func stagedValue(_ statement: OpaquePointer, _ column: Int32) -> TaptionReadingRowCodec.Value {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER: .int(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT: .real(sqlite3_column_double(statement, column))
        case SQLITE_TEXT: .text(String(cString: sqlite3_column_text(statement, column)))
        case SQLITE_BLOB:
            .blob(Data(bytes: sqlite3_column_blob(statement, column), count: Int(sqlite3_column_bytes(statement, column))))
        default: .null
        }
    }

    /// 준비 파일은 이 저장소와 같은 달력으로 썼으므로 저장 형태를 그대로 옮긴다. 새로 들어간 행 수를 돌려준다.
    private func copyStagedReadings(_ db: OpaquePointer) throws -> Int {
        let list = Self.readingColumns.joined(separator: ", ")
        try exec(db, "INSERT OR IGNORE INTO main.readings (\(list)) SELECT \(list) FROM \(Self.stagingSchema).readings")
        return Int(sqlite3_changes(db))
    }

    /// 같은 (종류, id)에 다른 내용이 있으면 거부하고(`appendRawEvents`와 같다), 없는 것만 넣는다.
    private func copyStagedRawEvents(_ db: OpaquePointer) throws {
        let conflict = try prepare(db, """
            SELECT s.kind, s.id FROM \(Self.stagingSchema).raw_events s
            JOIN main.raw_events m ON m.kind = s.kind AND m.id = s.id
            WHERE m.ts IS NOT s.ts OR m.seq IS NOT s.seq OR m.origin IS NOT s.origin
               OR m.provenance IS NOT s.provenance OR m.payload IS NOT s.payload
            LIMIT 1
            """)
        defer { sqlite3_finalize(conflict) }
        if sqlite3_step(conflict) == SQLITE_ROW {
            throw TaptionStoreV2Error.rawEventConflict(
                kind: String(cString: sqlite3_column_text(conflict, 0)), id: String(cString: sqlite3_column_text(conflict, 1))
            )
        }
        let list = "kind, id, ts, day, seq, origin, provenance, payload"
        try exec(db, "INSERT OR IGNORE INTO main.raw_events (\(list)) SELECT \(list) FROM \(Self.stagingSchema).raw_events")
    }

    /// 준비 파일의 기록 중 `TaptionRecordMerge` 순서로 이 저장소의 행을 이기는 것만 돌려준다.
    private func stagedRecordWinners(_ db: OpaquePointer, filter: RestoreRecordFilter) throws -> [TaptionStoreRecord] {
        var condition = ""
        var kind: String?
        switch filter {
        case .all: break
        case .excluding(let value): condition = "WHERE s.kind <> ?"; kind = value
        case .only(let value): condition = "WHERE s.kind = ?"; kind = value
        }
        let statement = try prepare(db, """
            SELECT s.id, s.kind, s.start_ts, s.end_ts, s.updated_ts, s.origin, s.deleted, s.ord, s.body,
                   m.updated_ts, m.deleted, m.body
            FROM \(Self.stagingSchema).records s LEFT JOIN main.records m ON m.kind = s.kind AND m.id = s.id
            \(condition)
            """)
        defer { sqlite3_finalize(statement) }
        if let kind { bind(statement, 1, .text(kind)) }
        var winners: [TaptionStoreRecord] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            let originName = String(cString: sqlite3_column_text(statement, 5))
            guard let origin = TaptionStoreRecord.Origin(rawValue: originName) else {
                throw TaptionStoreV2Error.sqlFailed("unknown record origin \(originName)")
            }
            func date(_ column: Int32) -> Date? {
                sqlite3_column_type(statement, column) == SQLITE_NULL
                    ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
            }
            let record = TaptionStoreRecord(
                id: String(cString: sqlite3_column_text(statement, 0)),
                kind: String(cString: sqlite3_column_text(statement, 1)),
                start: date(2), end: date(3),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                origin: origin, isDeleted: sqlite3_column_int(statement, 6) != 0,
                ord: Int(sqlite3_column_int64(statement, 7)),
                body: String(cString: sqlite3_column_text(statement, 8))
            )
            let wins = sqlite3_column_type(statement, 9) == SQLITE_NULL || TaptionRecordMerge.incomingWins(
                existing: .init(
                    updated: sqlite3_column_double(statement, 9),
                    isDeleted: sqlite3_column_int(statement, 10) != 0,
                    body: String(cString: sqlite3_column_text(statement, 11))
                ),
                incoming: record
            )
            if wins { winners.append(record) }
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { throw TaptionStoreV2Error.sqlFailed(String(cString: sqlite3_errmsg(db))) }
        return winners
    }
}

/// 복원 준비 파일의 자리·커밋·정리. `TaptionBackupEngine`이 직렬화된 작업 안에서만 부른다.
/// 준비 파일은 본 저장소 옆 숨은 폴더(`.taption-restore-staging/<uuid>/staging.sqlite`)에 둬 같은 보호 등급을 받는다.
enum TaptionRestoreStaging {
    static let pendingMemoKey = "backup.restore.pendingMemos"
    static let memoKind = "memo"
    private static let fileName = "staging.sqlite"

    struct Staging {
        var directory: URL
        var store: TaptionStoreV2
        var file: URL { store.url }
    }

    static func root(of store: TaptionStoreV2) -> URL {
        store.url.deletingLastPathComponent().appendingPathComponent(".taption-restore-staging", isDirectory: true)
    }

    static func make(for store: TaptionStoreV2) throws -> Staging {
        let directory = root(of: store).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            return Staging(
                directory: directory,
                store: try TaptionStoreV2(url: directory.appendingPathComponent(fileName), calendar: store.calendar)
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// 커밋 지점은 본 저장소의 한 트랜잭션이다. 메모 저장소가 있으면 "메모 남음" 표시를 그 트랜잭션에 함께 남기고,
    /// 커밋 뒤 메모를 합친 다음 표시를 지운다. 커밋 전에 실패하면 준비 파일을 지우고, 메모 단계에서 실패하면
    /// 표시와 준비 파일이 남아 `recover`가 마저 한다.
    static func commit(
        _ staging: Staging, into store: TaptionStoreV2, memoStore: TaptionStoreV2?, rejectConflicts: Bool,
        meta: [String: String]
    ) async throws -> TaptionStoreV2.RestoreStagingResult {
        var mainMeta = meta
        if memoStore != nil { mainMeta[pendingMemoKey] = staging.directory.lastPathComponent }
        var result: TaptionStoreV2.RestoreStagingResult
        do {
            result = try await store.applyRestoreStaging(
                at: staging.file, includeReadings: true, rejectReadingConflicts: rejectConflicts,
                records: memoStore == nil ? .all : .excluding(kind: memoKind), meta: mainMeta
            )
        } catch {
            try? FileManager.default.removeItem(at: staging.directory)
            throw error
        }
        if let memoStore {
            result.changedRecords += try await applyMemos(staging.file, to: memoStore)
            try await store.setMeta(pendingMemoKey, "")
        }
        try? FileManager.default.removeItem(at: staging.directory)
        return result
    }

    /// 커밋 뒤 끝내지 못한 메모 합치기를 마저 하고(멱등), 그 밖의 남은 준비 파일을 지운다.
    /// 실패하면 표시와 그 준비 파일을 남겨 다음 작업이 다시 한다.
    static func recover(store: TaptionStoreV2, memoStore: TaptionStoreV2?) async {
        let root = root(of: store)
        var keep: String?
        if let pending = try? await store.meta(pendingMemoKey), !pending.isEmpty {
            let file = root.appendingPathComponent(pending, isDirectory: true).appendingPathComponent(fileName)
            do {
                if let memoStore, FileManager.default.fileExists(atPath: file.path) {
                    _ = try await applyMemos(file, to: memoStore)
                }
                try await store.setMeta(pendingMemoKey, "")
            } catch {
                keep = pending
            }
        }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] where name != keep {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
    }

    private static func applyMemos(_ file: URL, to memoStore: TaptionStoreV2) async throws -> Int {
        try await memoStore.applyRestoreStaging(
            at: file, includeReadings: false, rejectReadingConflicts: false, records: .only(kind: memoKind), meta: [:]
        ).changedRecords
    }
}
