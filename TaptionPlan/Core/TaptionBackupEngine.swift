import CryptoKit
import Foundation
import TaptionPlanCore

/// `yyyy-MM.taptionbackup` 월 파일을 만들고 교체하고 복원하며, 올라간 달을 로컬에서 정리하는 엔진.
///
/// 규칙: 새 파일이 기존 파일의 상위 집합일 때만 덮어쓰고(행 수·마지막 시각이 작으면 기존을 지킨다),
/// 임시 파일에 쓰고 다시 읽어 검증한 뒤 목적지에서 원자적으로 교체한다. 비밀번호 문자열은 쓰기·읽기에만 쓰고 저장하지 않는다.
/// 시작 시각이 없는 기록(설정·분류 등 달에 속하지 않는 행)은 월 백업에 담지 않고 오프로드로 지우지도 않는다.
actor TaptionBackupEngine {
    struct Configuration: Sendable {
        var iterations = TaptionBackupCrypto.defaultIterations
        var codec: TaptionBackupCodec = .zlib
        var chunkBytes = 4 << 20
        var temporaryDirectory = FileManager.default.temporaryDirectory
        /// 임시 파일을 검증하기 직전에 부른다(테스트에서 쓰기 도중 손상을 흉내 낸다).
        var beforeVerify: (@Sendable (URL) throws -> Void)?
    }

    enum KeepReason: Equatable, Sendable {
        case fewerRows(existing: Int, new: Int)
        case earlierLastTimestamp(existing: Double?, new: Double?)
        case existingUnreadable
    }

    struct BackupResult: Equatable, Sendable {
        enum Outcome: Equatable, Sendable {
            case written
            case unchanged
            case keptExisting(KeepReason)
            case skippedSealed
            case skippedNoData
        }

        var month: TaptionBackupMonth
        var outcome: Outcome
        var header: TaptionBackupHeader?
        var message: String
    }

    struct RestoreSummary: Equatable, Sendable {
        var month: TaptionBackupMonth
        var fileReadings: Int
        var newReadings: Int
        var fileRecords: Int
        var changedRecords: Int
    }

    struct OffloadResult: Equatable, Sendable {
        enum Outcome: Equatable, Sendable {
            case sealed(readings: Int, records: Int)
            case skipped(String)
        }

        var month: TaptionBackupMonth
        var outcome: Outcome
    }

    struct Listing: Equatable, Sendable {
        var info: TaptionBackupFileInfo
        var month: TaptionBackupMonth
        /// 비밀번호 없이 읽은 헤더. 읽을 수 없으면 nil.
        var header: TaptionBackupHeader?
    }

    private struct ExportSummary {
        var readingCount = 0
        var recordCount = 0
        var first: Double?
        var last: Double?
        var digest = ""
        var rowCount: Int { readingCount + recordCount }
    }

    private static let sealedPrefix = "backup.sealed."
    private static let restoreBatch = 2_000

    private let store: TaptionStoreV2
    private let destination: any TaptionBackupDestination
    private let calendar: Calendar
    private let configuration: Configuration

    init(
        store: TaptionStoreV2,
        destination: any TaptionBackupDestination,
        calendar: Calendar = .autoupdatingCurrent,
        configuration: Configuration = Configuration()
    ) {
        self.store = store
        self.destination = destination
        self.calendar = calendar
        self.configuration = configuration
    }

    // MARK: 목록

    func listBackups() async throws -> [Listing] {
        var listings: [Listing] = []
        for info in try await destination.list() {
            guard let month = TaptionBackupMonth(fileName: info.name) else { continue }
            let header = try? await readHeader(named: info.name)
            listings.append(Listing(info: info, month: month, header: header))
        }
        return listings.sorted { $0.month < $1.month }
    }

    func isSealed(_ month: TaptionBackupMonth) async throws -> Bool {
        guard let value = try await store.meta(Self.sealedPrefix + month.key) else { return false }
        return !value.isEmpty
    }

    // MARK: 백업

    /// 로컬에 데이터가 있는 모든 달(봉인된 달 제외)을 차례로 백업한다. 바뀐 달만 실제로 다시 쓴다.
    func backupAllMonths(password: String, now: Date = Date()) async throws -> [BackupResult] {
        guard let bounds = try await store.dataTimeBounds() else { return [] }
        let first = TaptionBackupMonth(date: Date(timeIntervalSince1970: bounds.first), calendar: calendar)
        let last = TaptionBackupMonth(date: Date(timeIntervalSince1970: bounds.last), calendar: calendar)
        var results: [BackupResult] = []
        var month = first
        while month <= last {
            results.append(try await backup(month: month, password: password, now: now))
            month = month.adding(months: 1)
        }
        return results
    }

    func backup(month: TaptionBackupMonth, password: String, now: Date = Date()) async throws -> BackupResult {
        guard !password.isEmpty else { throw TaptionBackupError.emptyPassword }
        let range = try interval(of: month)
        let stats = try await store.rangeStats(from: range.start.timeIntervalSince1970, to: range.end.timeIntervalSince1970)
        if try await isSealed(month) {
            let note = stats.readings + stats.records > 0 ? " 로컬에 남은 \(stats.readings + stats.records)행은 백업에 없다." : ""
            return result(month, .skippedSealed, "\(month.key)은 봉인돼 다시 쓰지 않는다.\(note)")
        }
        guard stats.readings + stats.records > 0 else {
            return result(month, .skippedNoData, "\(month.key)은 로컬에 데이터가 없어 기존 백업을 건드리지 않았다.")
        }

        let name = month.fileName
        let existing = try await existingHeader(named: name)
        if case .unreadable = existing {
            return result(month, .keptExisting(.existingUnreadable), "\(name)의 기존 파일을 읽을 수 없어 덮어쓰지 않았다.")
        }

        // 1) 해시만 계산해 바뀐 데이터가 없으면 쓰지 않는다.
        let preview = try await exportMonth(month, emit: { _ in })
        if case .header(let old) = existing {
            // 달이 끝난 뒤에 다시 만든 적이 없는 백업은 내용이 같아도 새로 만든다(오프로드의 근거가 된다).
            let endedSinceBackup = now >= range.end && old.createdAt < range.end.timeIntervalSince1970
            if old.contentSHA256 == preview.digest, old.rowCount == preview.rowCount, !endedSinceBackup {
                return result(month, .unchanged, "\(name)은 바뀐 데이터가 없어 그대로 둔다.", header: old)
            }
            if let reason = Self.supersetViolation(old: old, rowCount: preview.rowCount, last: preview.last) {
                return result(month, .keptExisting(reason), Self.keepMessage(name, reason), header: old)
            }
        }

        // 2) 임시 파일에 쓰고 검증한다.
        let temporary = configuration.temporaryDirectory
            .appendingPathComponent("taption-backup-\(UUID().uuidString).tmp", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let header = try await writeFile(month: month, password: password, to: temporary, now: now)
        if case .header(let old) = existing,
           let reason = Self.supersetViolation(old: old, rowCount: header.rowCount, last: header.lastTimestamp) {
            return result(month, .keptExisting(reason), Self.keepMessage(name, reason), header: old)
        }
        try configuration.beforeVerify?(temporary)
        try await verifyFile(at: temporary, header: header, password: password)

        // 3) 목적지에서 원자적으로 교체하고, 올라간 파일을 다시 확인한다.
        try await destination.replace(name: name, with: temporary)
        let uploaded = try await destination.fetch(name: name)
        let uploadedHeader = try TaptionBackupFileReader.readHeader(at: uploaded)
        try TaptionBackupFileReader.verifyBodyChecksum(at: uploaded, header: uploadedHeader)
        guard uploadedHeader == header else {
            throw TaptionBackupError.verificationFailed("uploaded file differs from the verified file")
        }
        return result(month, .written, "\(name)을 \(header.rowCount)행으로 저장했다.", header: header)
    }

    // MARK: 복원

    /// 월 파일을 읽어 복호화해 저장소로 되돌린다. 지운 달 불러오기도 같은 함수다.
    /// 파일 전체를 먼저 검증한 뒤에만 저장소에 쓴다. 센서 원본은 같은 id가 다른 내용이면 거부한다.
    func restore(month: TaptionBackupMonth, password: String) async throws -> RestoreSummary {
        guard !password.isEmpty else { throw TaptionBackupError.emptyPassword }
        let url = try await destination.fetch(name: month.fileName)
        let header = try TaptionBackupFileReader.readHeader(at: url)
        guard header.month == month.key else { throw TaptionBackupError.malformed("month does not match file name") }
        try TaptionBackupFileReader.verifyBodyChecksum(at: url, header: header)
        let key = try TaptionBackupFileReader.key(password: password, header: header)
        try await TaptionBackupFileReader.decode(at: url, header: header, key: key) { _ in }

        let before = try await store.readingCount()
        var buffer = RestoreBuffer()
        let calendar = self.calendar
        try await TaptionBackupFileReader.decode(at: url, header: header, key: key) { line in
            let fields = try TaptionBackupJSONLine.parse(line)
            switch fields.first?.string {
            case "#readings":
                buffer.columns = try Self.mapColumns(fields)
            case "r":
                buffer.readings.append(try Self.reading(from: fields, columns: buffer.columns, calendar: calendar))
                if buffer.readings.count >= Self.restoreBatch { try await self.flush(&buffer) }
            case "c":
                buffer.records.append(try Self.record(from: fields))
                if buffer.records.count >= Self.restoreBatch { try await self.flush(&buffer) }
            default:
                break
            }
        }
        try await flush(&buffer)
        try await store.setMeta(Self.sealedPrefix + month.key, "")
        let after = try await store.readingCount()
        return RestoreSummary(
            month: month, fileReadings: header.readingCount, newReadings: after - before,
            fileRecords: header.recordCount, changedRecords: buffer.changedRecords
        )
    }

    private struct RestoreBuffer {
        var columns: [Int?] = []
        var readings: [SensorReading] = []
        var records: [TaptionStoreRecord] = []
        var changedRecords = 0
    }

    private func flush(_ buffer: inout RestoreBuffer) async throws {
        if !buffer.readings.isEmpty {
            let batch = buffer.readings
            buffer.readings = []
            try await store.appendImmutableReadings(batch)
        }
        if !buffer.records.isEmpty {
            let batch = buffer.records
            buffer.records = []
            buffer.changedRecords += try await store.upsertRecordsKeepingNewer(batch)
        }
    }

    // MARK: 로컬 정리(오프로드)

    /// 끝난 달 중 백업이 올라가 있고 다시 읽어 검증된 달만 봉인하고 로컬 행을 지운다.
    /// 지난 `keepRecentMonths`개 달(이번 달 포함)은 지우지 않는다.
    func offloadSealedMonths(
        password: String, now: Date = Date(), keepRecentMonths: Int = 2
    ) async throws -> [OffloadResult] {
        guard !password.isEmpty else { throw TaptionBackupError.emptyPassword }
        guard let bounds = try await store.dataTimeBounds() else { return [] }
        let current = TaptionBackupMonth(date: now, calendar: calendar)
        let firstKept = current.adding(months: -(max(1, keepRecentMonths) - 1))
        let first = TaptionBackupMonth(date: Date(timeIntervalSince1970: bounds.first), calendar: calendar)
        var results: [OffloadResult] = []
        var month = first
        while month < firstKept {
            if let outcome = try await offload(month: month, password: password) {
                results.append(OffloadResult(month: month, outcome: outcome))
            }
            month = month.adding(months: 1)
        }
        if results.contains(where: { if case .sealed = $0.outcome { true } else { false } }) {
            try await store.reclaimSpace()
        }
        return results
    }

    private func offload(month: TaptionBackupMonth, password: String) async throws -> OffloadResult.Outcome? {
        let range = try interval(of: month)
        let from = range.start.timeIntervalSince1970
        let to = range.end.timeIntervalSince1970
        let stats = try await store.rangeStats(from: from, to: to)
        guard stats.readings + stats.records > 0 else { return nil }

        let name = month.fileName
        guard case .header(let header) = try await existingHeader(named: name) else {
            return .skipped("\(name) 백업이 없거나 읽을 수 없다.")
        }
        guard header.createdAt >= range.end.timeIntervalSince1970 else {
            return .skipped("\(name)은 달이 끝나기 전에 만든 백업이라 지우지 않는다. 다시 백업해야 한다.")
        }
        do {
            let url = try await destination.fetch(name: name)
            try TaptionBackupFileReader.verifyBodyChecksum(at: url, header: header)
            let key = try TaptionBackupFileReader.key(password: password, header: header)
            let counts = try await TaptionBackupFileReader.decode(at: url, header: header, key: key) { _ in }
            let local = try await exportMonth(month, emit: { _ in })
            guard local.readingCount == counts.readings, local.recordCount == counts.records,
                  local.digest == counts.contentSHA256 else {
                return .skipped("\(name)의 내용이 로컬과 달라 지우지 않는다. 다시 백업해야 한다.")
            }
            guard try await store.deleteRange(
                from: from, to: to, expectedReadings: local.readingCount, expectedRecords: local.recordCount
            ) else {
                return .skipped("\(name) 검증 뒤 로컬에 새 행이 들어와 지우지 않았다.")
            }
            try await store.setMeta(
                Self.sealedPrefix + month.key, "\(header.contentSHA256)|\(header.rowCount)"
            )
            return .sealed(readings: local.readingCount, records: local.recordCount)
        } catch let error as TaptionBackupError {
            return .skipped("\(name) 검증 실패로 지우지 않았다: \(error)")
        }
    }

    // MARK: 파일 쓰기·검증

    private func writeFile(
        month: TaptionBackupMonth, password: String, to url: URL, now: Date
    ) async throws -> TaptionBackupHeader {
        let salt = try TaptionBackupCrypto.randomBytes(TaptionBackupCrypto.saltBytes)
        let iterations = configuration.iterations
        let key = try TaptionBackupCrypto.deriveKey(password: password, salt: salt, iterations: iterations)
        let writer = try TaptionBackupFileWriter(
            url: url, month: month.key, key: key, salt: salt,
            codec: configuration.codec, chunkBytes: configuration.chunkBytes
        )
        do {
            let summary = try await exportMonth(month, emit: { try writer.append($0) })
            let template = TaptionBackupHeader(
                month: month.key,
                timeZone: calendar.timeZone.identifier,
                createdAt: now.timeIntervalSince1970,
                kdf: .init(algorithm: "PBKDF2-HMAC-SHA256", salt: salt.base64EncodedString(), iterations: iterations),
                keyCheck: TaptionBackupCrypto.keyCheck(key, month: month.key),
                compression: configuration.codec.name,
                chunkBytes: configuration.chunkBytes,
                chunkCount: 0,
                plaintextBytes: 0,
                readingCount: summary.readingCount,
                recordCount: summary.recordCount,
                rowCount: summary.rowCount,
                firstTimestamp: summary.first,
                lastTimestamp: summary.last,
                contentSHA256: summary.digest,
                bodyBytes: 0,
                bodySHA256: ""
            )
            return try writer.finish(header: template)
        } catch {
            writer.abort()
            throw error
        }
    }

    /// 방금 쓴 임시 파일을 처음부터 다시 읽어 헤더와 일치하는지 확인한다.
    private func verifyFile(at url: URL, header: TaptionBackupHeader, password: String) async throws {
        let reread = try TaptionBackupFileReader.readHeader(at: url)
        guard reread == header else { throw TaptionBackupError.verificationFailed("header changed after writing") }
        try TaptionBackupFileReader.verifyBodyChecksum(at: url, header: header)
        let key = try TaptionBackupFileReader.key(password: password, header: header)
        try await TaptionBackupFileReader.decode(at: url, header: header, key: key) { _ in }
    }

    // MARK: 내보내기(표 → JSON Lines)

    /// 달의 모든 행을 결정적 순서로 줄로 만들어 `emit`에 넘기고, 개수·시각 범위·내용 해시를 돌려준다.
    /// 센서 원본은 하루씩 읽어 메모리를 제한한다.
    private func exportMonth(_ month: TaptionBackupMonth, emit: (Data) throws -> Void) async throws -> ExportSummary {
        let range = try interval(of: month)
        var summary = ExportSummary()
        var hasher = SHA256()
        func put(_ line: Data) throws {
            hasher.update(data: line)
            try emit(line)
        }
        func track(_ time: Double) {
            summary.first = min(summary.first ?? time, time)
            summary.last = max(summary.last ?? time, time)
        }

        var schema = TaptionBackupJSONLine.Builder()
        schema.string("#readings")
        schema.string("id")
        schema.string("ts")
        for column in TaptionReadingRowCodec.columns { schema.string(column.name) }
        schema.string("extra")
        try put(schema.finish())
        var recordSchema = TaptionBackupJSONLine.Builder()
        for name in Self.recordColumns { recordSchema.string(name) }
        try put(recordSchema.finish())

        var cursor = range.start
        while cursor < range.end {
            let next = min(calendar.date(byAdding: .day, value: 1, to: cursor) ?? range.end, range.end)
            for reading in try await store.readings(from: cursor, to: next) {
                let row = try TaptionReadingRowCodec.row(for: reading, calendar: calendar)
                try put(try Self.line(for: row))
                summary.readingCount += 1
                track(row.timestamp)
            }
            cursor = next
        }
        let records = try await store.recordsForBackup(
            from: range.start.timeIntervalSince1970, to: range.end.timeIntervalSince1970
        )
        for record in records {
            try put(try Self.line(for: record))
            summary.recordCount += 1
            if let start = record.start { track(start.timeIntervalSince1970) }
        }

        summary.digest = TaptionBackupCrypto.hex(hasher.finalize())
        var trailer = TaptionBackupJSONLine.Builder()
        trailer.string("#end")
        trailer.int(Int64(summary.readingCount))
        trailer.int(Int64(summary.recordCount))
        try trailer.optionalDouble(summary.first)
        try trailer.optionalDouble(summary.last)
        trailer.string(summary.digest)
        try emit(trailer.finish())
        return summary
    }

    private static let recordColumns = [
        "#records", "id", "kind", "start", "end", "updated", "origin", "deleted", "ord", "body",
    ]

    private static func line(for row: TaptionReadingRowCodec.Row) throws -> Data {
        var builder = TaptionBackupJSONLine.Builder()
        builder.string("r")
        builder.string(row.id)
        try builder.double(row.timestamp)
        for value in row.values {
            switch value {
            case .null: builder.null()
            case .int(let number): builder.int(number)
            case .real(let number): try builder.double(number)
            case .text(let text): builder.string(text)
            case .blob: throw TaptionBackupError.malformed("blob in reading row")
            }
        }
        if let extra = row.extra { builder.string(extra) } else { builder.null() }
        return builder.finish()
    }

    private static func line(for record: TaptionStoreRecord) throws -> Data {
        var builder = TaptionBackupJSONLine.Builder()
        builder.string("c")
        builder.string(record.id)
        builder.string(record.kind)
        try builder.optionalDouble(record.start?.timeIntervalSince1970)
        try builder.optionalDouble(record.end?.timeIntervalSince1970)
        try builder.double(record.updatedAt.timeIntervalSince1970)
        builder.string(record.origin.rawValue)
        builder.int(record.isDeleted ? 1 : 0)
        builder.int(Int64(record.ord))
        builder.string(record.body)
        return builder.finish()
    }

    // MARK: 가져오기(JSON Lines → 행)

    /// 스키마 줄의 열 이름을 현재 코덱 열 번호에 연결한다. 알 수 없는 열이 있으면 거부한다.
    private static func mapColumns(_ fields: [TaptionBackupJSONLine.Field]) throws -> [Int?] {
        let names = fields.dropFirst().compactMap(\.string)
        guard names.count == fields.count - 1, names.prefix(2) == ["id", "ts"], names.last == "extra" else {
            throw TaptionBackupError.malformed("readings schema")
        }
        let codecNames = TaptionReadingRowCodec.columns.map(\.name)
        return try names.dropFirst(2).dropLast().map { name in
            guard let index = codecNames.firstIndex(of: name) else {
                throw TaptionBackupError.malformed("unknown reading column \(name)")
            }
            return index
        }
    }

    private static func reading(
        from fields: [TaptionBackupJSONLine.Field], columns: [Int?], calendar: Calendar
    ) throws -> SensorReading {
        guard fields.count == columns.count + 4, let id = fields[1].string, let timestamp = fields[2].double else {
            throw TaptionBackupError.malformed("reading row")
        }
        var values = [TaptionReadingRowCodec.Value](repeating: .null, count: TaptionReadingRowCodec.columns.count)
        for (offset, codecIndex) in columns.enumerated() {
            guard let codecIndex else { continue }
            let field = fields[3 + offset]
            guard !field.isNull else { continue }
            switch TaptionReadingRowCodec.columns[codecIndex].kind {
            case .text:
                guard let text = field.string else { throw TaptionBackupError.malformed("text column") }
                values[codecIndex] = .text(text)
            case .real:
                guard let number = field.double else { throw TaptionBackupError.malformed("real column") }
                values[codecIndex] = .real(number)
            case .int, .bool:
                guard let number = field.int64 else { throw TaptionBackupError.malformed("int column") }
                values[codecIndex] = .int(number)
            }
        }
        let extra = fields[fields.count - 1]
        let row = TaptionReadingRowCodec.Row(
            id: id, timestamp: timestamp,
            day: TaptionReadingRowCodec.dayNumber(for: Date(timeIntervalSince1970: timestamp), calendar: calendar),
            values: values, extra: extra.string
        )
        return try TaptionReadingRowCodec.reading(from: row)
    }

    private static func record(from fields: [TaptionBackupJSONLine.Field]) throws -> TaptionStoreRecord {
        guard fields.count == 10, let id = fields[1].string, let kind = fields[2].string,
              let updated = fields[5].double, let originName = fields[6].string,
              let origin = TaptionStoreRecord.Origin(rawValue: originName),
              let deleted = fields[7].int, let ord = fields[8].int, let body = fields[9].string else {
            throw TaptionBackupError.malformed("record row")
        }
        return TaptionStoreRecord(
            id: id, kind: kind,
            start: fields[3].double.map { Date(timeIntervalSince1970: $0) },
            end: fields[4].double.map { Date(timeIntervalSince1970: $0) },
            updatedAt: Date(timeIntervalSince1970: updated), origin: origin,
            isDeleted: deleted != 0, ord: ord, body: body
        )
    }

    // MARK: 보조

    private enum ExistingFile {
        case none
        case unreadable
        case header(TaptionBackupHeader)
    }

    private func existingHeader(named name: String) async throws -> ExistingFile {
        guard try await destination.list().contains(where: { $0.name == name }) else { return .none }
        guard let header = try? await readHeader(named: name) else { return .unreadable }
        return .header(header)
    }

    private func readHeader(named name: String) async throws -> TaptionBackupHeader {
        try TaptionBackupFileReader.readHeader(at: try await destination.fetch(name: name))
    }

    /// 새 파일이 기존 파일의 상위 집합이 아닐 징후(행 수·마지막 시각이 작음)를 찾는다.
    private static func supersetViolation(old: TaptionBackupHeader, rowCount: Int, last: Double?) -> KeepReason? {
        if rowCount < old.rowCount { return .fewerRows(existing: old.rowCount, new: rowCount) }
        if let oldLast = old.lastTimestamp, (last ?? -.infinity) < oldLast {
            return .earlierLastTimestamp(existing: oldLast, new: last)
        }
        return nil
    }

    private static func keepMessage(_ name: String, _ reason: KeepReason) -> String {
        switch reason {
        case .fewerRows(let existing, let new):
            "\(name): 새 데이터(\(new)행)가 기존 백업(\(existing)행)보다 적어 기존 파일을 지켰다."
        case .earlierLastTimestamp:
            "\(name): 새 데이터의 마지막 시각이 기존 백업보다 앞서 기존 파일을 지켰다."
        case .existingUnreadable:
            "\(name): 기존 파일을 읽을 수 없어 덮어쓰지 않았다."
        }
    }

    private func result(
        _ month: TaptionBackupMonth, _ outcome: BackupResult.Outcome, _ message: String,
        header: TaptionBackupHeader? = nil
    ) -> BackupResult {
        BackupResult(month: month, outcome: outcome, header: header, message: message)
    }

    private func interval(of month: TaptionBackupMonth) throws -> (start: Date, end: Date) {
        guard let range = month.interval(calendar: calendar) else {
            throw TaptionBackupError.malformed("invalid month \(month.key)")
        }
        return range
    }
}
