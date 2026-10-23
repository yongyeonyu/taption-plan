import CryptoKit
import Foundation
import TaptionPlanCore

/// `yyyy-MM.taptionbackup` 월 파일과 `taption-settings.taptionbackup` 설정 파일을 만들고 교체하고 복원하며,
/// 올라간 달을 로컬에서 정리하는 엔진.
///
/// 규칙:
/// - 기존 파일이 읽히면(비밀번호가 맞으면) 봉인 표시와 상관없이 항상 복호화해 로컬과 id 기준 합집합으로 만든 뒤 쓴다
///   (센서 원본은 id, 기록은 (종류, id)로 합치고 기록은 `TaptionRecordMerge` 순서로 이긴 쪽을 남긴다).
///   새 파일은 기존 파일의 모든 id를 포함하는지 임시 파일을 다시 읽어 확인한 뒤에만 교체한다.
/// - 비밀번호가 기존 파일의 것과 다르면(헤더 블록의 GCM 태그로 판정) 쓰기·오프로드를 거부한다.
/// - 기존 파일의 본문이 손상됐으면 로컬이 파일이 주장하는 내용(행 수·마지막 시각·기록 수정 시각)을 모두 넘을 때만 새로 쓴다.
/// - 데이터 전체 삭제(`TaptionStoreV2.deleteAll*`) 뒤에는 그 이전 백업 파일을 합치거나 덮어쓰지 않는다
///   (`deleteAllBackups()` 또는 복원으로 정리/수락할 때까지 `staleAfterDataWipe`로 알린다).
/// - 모든 작업은 한 번에 하나씩 직렬로 실행한다(actor 재진입으로 오프로드·삭제·복원·백업이 겹치지 않게). 이 직렬화는 엔진
///   인스턴스 안에서만 보장되므로 앱은 엔진을 하나만 둔다.
/// - 달력은 그레고리력 + 고정 시간대다. 시간대는 첫 사용 때 meta(`backup.timezone`)에 저장하고 이후에는 저장된 값을 쓴다.
///   파일 헤더의 시간대와 달라도 저장된 값을 쓴다(헤더 값은 참고용).
/// - 헤더의 행 수·시각·해시 같은 메타데이터는 암호화돼 있다. 비밀번호 없이는 월 이름과 파일 크기만 보인다.
/// 비밀번호 문자열은 쓰기·읽기에만 쓰고 저장하지 않는다. 유도한 키는 작업 하나가 끝나면 버린다.
actor TaptionBackupEngine {
    struct Configuration: Sendable {
        var iterations = TaptionBackupCrypto.defaultIterations
        /// 열 때 허용하는 최소 반복 횟수. 테스트만 낮춘다.
        var minimumIterations = TaptionBackupCrypto.minIterations
        var codec: TaptionBackupCodec = .zlib
        var chunkBytes = 4 << 20
        var temporaryDirectory = FileManager.default.temporaryDirectory
        /// 임시 파일을 검증하기 직전에 부른다(테스트에서 쓰기 도중 손상을 흉내 낸다).
        var beforeVerify: (@Sendable (URL) throws -> Void)?
        /// 직렬화된 작업의 시작(`true`)·끝(`false`)에 부른다(테스트에서 겹침이 없는지 본다).
        var operationHook: (@Sendable (String, Bool) -> Void)?
    }

    enum KeepReason: Equatable, Sendable {
        case fewerRows(existing: Int, new: Int)
        case earlierLastTimestamp(existing: Double?, new: Double?)
        case olderRecordUpdates(existing: Double?, new: Double?)
        case existingUnreadable
        /// 본문이 손상된 기존 파일이고 로컬이 그 내용을 모두 담고 있지 않아 새로 쓰지 않았다.
        case existingCorrupted
        /// 데이터 전체 삭제 이전에 만든 백업이라 합치지도 덮어쓰지도 않았다.
        case staleAfterDataWipe
    }

    struct BackupResult: Equatable, Sendable {
        enum Outcome: Equatable, Sendable {
            case written
            case unchanged
            case keptExisting(KeepReason)
            case skippedSealed
            case skippedNoData
            /// 이 파일만 실패했다(나머지 달은 계속했다). 연관값은 오류 설명.
            case failed(String)
        }

        var scope: TaptionBackupScope
        var outcome: Outcome
        var header: TaptionBackupHeader?
        var message: String
    }

    struct RestoreSummary: Equatable, Sendable {
        var scope: TaptionBackupScope
        var fileReadings: Int
        var newReadings: Int
        var fileRecords: Int
        var changedRecords: Int
        /// 합치기에서 로컬을 지킨 id 충돌 수(복원은 충돌이면 거부하므로 항상 0).
        var readingConflicts = 0
    }

    struct OffloadResult: Equatable, Sendable {
        enum Outcome: Equatable, Sendable {
            case sealed(readings: Int, records: Int)
            case skipped(String)
        }

        var month: TaptionBackupMonth
        var outcome: Outcome
    }

    /// 목록의 한 파일. 비밀번호 없이는 `info`와 `scope`만 믿을 수 있다.
    struct Listing: Equatable, Sendable {
        enum State: Equatable, Sendable {
            /// 비밀번호를 주지 않아 메타데이터를 열지 않았다.
            case locked
            case unreadable
            case wrongPassword
            case ok
        }

        struct Summary: Equatable, Sendable {
            var month: String
            var rowCount: Int
            var lastTimestamp: Double?
        }

        var info: TaptionBackupFileInfo
        var scope: TaptionBackupScope
        var state: State
        /// 비밀번호로 연 헤더(없으면 nil).
        var header: TaptionBackupHeader?
        var summary: Summary? {
            header.map { Summary(month: $0.month, rowCount: $0.rowCount, lastTimestamp: $0.lastTimestamp) }
        }
    }

    private struct ExportSummary {
        var readingCount = 0
        var recordCount = 0
        var first: Double?
        var last: Double?
        var latestRecordUpdate: Double?
        var digest = ""
        var rowCount: Int { readingCount + recordCount }
    }

    /// 파일 안 행의 id 목록(포함 여부 확인용).
    private struct FileIndex {
        var readings = Set<String>()
        var records: [String: Double] = [:]
        var isEmpty: Bool { readings.isEmpty && records.isEmpty }
    }

    struct DeleteAllBackupsResult: Equatable, Sendable {
        struct Failure: Equatable, Sendable {
            var name: String
            var message: String
        }

        var removed: [String]
        var failed: [Failure]
        /// 삭제 뒤 목적지에 아직 남은 파일 이름(목록을 다시 읽은 결과, 읽지 못하면 nil).
        var remaining: [String]?
    }

    private static let sealedPrefix = "backup.sealed."
    private static let epochPrefix = "backup.epoch."
    static let timeZoneKey = "backup.timezone"
    private static let restoreBatch = 2_000
    /// 월 순회가 비정상 시각에 폭주하지 않게 UTC 날짜 번호를 1970~2200년으로 제한한다.
    private static let validDays = 0...(230 * 366)

    private let store: TaptionStoreV2
    /// 메모 전용 저장소. 백업 파일에는 본 저장소 행과 함께 담고, 복원할 때는 종류에 따라 되돌려 쓴다.
    private let memoStore: TaptionStoreV2?
    private static let memoKind = "memo"
    private let destination: any TaptionBackupDestination
    private let configuration: Configuration
    private var calendar: Calendar
    private var keyCache: [String: SymmetricKey] = [:]
    private var didCleanUploads = false
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// `calendar`는 후보 시간대를 알려 주는 용도다(없으면 저장소 달력의 시간대). 달력 종류는 항상 그레고리력으로 고친다.
    init(
        store: TaptionStoreV2,
        memoStore: TaptionStoreV2? = nil,
        destination: any TaptionBackupDestination,
        calendar: Calendar? = nil,
        configuration: Configuration = Configuration()
    ) {
        self.store = store
        self.memoStore = memoStore
        self.destination = destination
        self.configuration = configuration
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = (calendar ?? store.calendar).timeZone
        self.calendar = gregorian
    }

    // MARK: 직렬화·환경

    private func exclusive<T>(_ name: String, _ body: () async throws -> T) async throws -> T {
        if isBusy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            isBusy = true
        }
        configuration.operationHook?(name, true)
        defer {
            keyCache = [:]
            configuration.operationHook?(name, false)
            if waiters.isEmpty { isBusy = false } else { waiters.removeFirst().resume() }
        }
        try await prepareEnvironment()
        return try await body()
    }

    /// 시간대를 정하고(저장된 값, 없으면 후보를 저장) 이전 실행이 남긴 업로드 임시 파일을 치운다.
    private func prepareEnvironment() async throws {
        var identifier = calendar.timeZone.identifier
        if let stored = try await store.meta(Self.timeZoneKey), TimeZone(identifier: stored) != nil {
            identifier = stored
        } else {
            try await store.setMeta(Self.timeZoneKey, identifier)
        }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: identifier) ?? calendar.timeZone
        calendar = gregorian
        if !didCleanUploads {
            await destination.cleanupStaleUploads()
            didCleanUploads = true
        }
    }

    // MARK: 목록

    /// 비밀번호 없이는 월 이름·파일 크기만(`state == .locked`). 비밀번호를 주면 헤더 블록을 열어 행 수·마지막 시각 등을 채운다.
    func listBackups(password: String? = nil) async throws -> [Listing] {
        var listings: [Listing] = []
        for info in try await destination.list() {
            guard let scope = TaptionBackupScope(fileName: info.name) else { continue }
            var listing = Listing(info: info, scope: scope, state: .locked, header: nil)
            if let password, !password.isEmpty {
                do {
                    let prefix = try await destination.fetchPrefix(
                        name: info.name, length: TaptionBackupFileReader.headerPrefixBytes
                    )
                    listing.header = try openHeader(prefix: prefix, scope: scope, password: password).header
                    listing.state = .ok
                } catch TaptionBackupError.wrongPassword {
                    listing.state = .wrongPassword
                } catch {
                    listing.state = .unreadable
                }
            }
            listings.append(listing)
        }
        keyCache = [:]
        return listings.sorted { $0.info.name < $1.info.name }
    }

    func isSealed(_ month: TaptionBackupMonth) async throws -> Bool {
        guard let value = try await store.meta(Self.sealedPrefix + month.key) else { return false }
        return !value.isEmpty
    }

    // MARK: 백업

    /// 로컬에 데이터가 있는 모든 달과 설정 파일을 차례로 백업한다. 바뀐 파일만 실제로 다시 쓴다.
    /// 한 파일이 실패해도 나머지를 계속하고 실패는 그 파일의 결과(`.failed`)로 돌려준다.
    /// 데이터가 실제로 있는 달만 순회한다(비정상으로 먼 시각 때문에 달 수천 개를 돌지 않는다).
    /// `progress`는 (끝낸 파일 수, 전체 파일 수)를 시작할 때 한 번, 파일 하나가 끝날 때마다 알린다(설정 파일 포함).
    func backupAllMonths(
        password: String,
        now: Date = Date(),
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> [BackupResult] {
        guard !password.isEmpty else { throw TaptionBackupError.emptyPassword }
        return try await exclusive("backupAllMonths") {
            var results: [BackupResult] = []
            let months = try await monthsWithData()
            let total = months.count + 1
            progress?(0, total)
            for month in months {
                try Task.checkCancellation()
                results.append(await attempt(.month(month), password: password, now: now))
                progress?(results.count, total)
            }
            results.append(await attempt(.settings, password: password, now: now))
            progress?(results.count, total)
            return results
        }
    }

    private func attempt(_ scope: TaptionBackupScope, password: String, now: Date) async -> BackupResult {
        do {
            return try await performBackup(scope: scope, password: password, now: now)
        } catch is CancellationError {
            return result(scope, .failed("취소됨"), "\(scope.fileName): 백업이 취소됐다")
        } catch {
            return result(scope, .failed("\(error)"), "\(scope.fileName): 백업에 실패했다 - \(error)")
        }
    }

    func backup(month: TaptionBackupMonth, password: String, now: Date = Date()) async throws -> BackupResult {
        try await exclusive("backup \(month.key)") {
            try await performBackup(scope: .month(month), password: password, now: now)
        }
    }

    /// 시작 시각이 없는 기록(설정 헤더·분류 등)을 `taption-settings.taptionbackup`에 담는다.
    func backupSettings(password: String, now: Date = Date()) async throws -> BackupResult {
        try await exclusive("backup settings") {
            try await performBackup(scope: .settings, password: password, now: now)
        }
    }

    private func performBackup(scope: TaptionBackupScope, password: String, now: Date) async throws -> BackupResult {
        guard !password.isEmpty else { throw TaptionBackupError.emptyPassword }
        let name = scope.fileName
        let localRows = try await localRowCount(scope)
        let existing = try await existingFile(scope: scope, password: password)
        let token = try await wipeToken()

        guard case .opened(let old, let key) = existing else {
            if case .unreadable = existing {
                return result(scope, .keptExisting(.existingUnreadable), Self.keepMessage(name, .existingUnreadable))
            }
            guard localRows > 0 else {
                return result(scope, .skippedNoData, "\(scope.key)은 로컬에 데이터가 없어 쓰지 않았다.")
            }
            return try await write(scope: scope, password: password, now: now, token: token, old: nil, oldIndex: nil)
        }

        guard localRows > 0 else {
            if case .month(let month) = scope, try await isSealed(month) {
                return result(scope, .skippedSealed, "\(month.key)은 봉인돼 로컬이 비어 있다. 기존 백업을 건드리지 않았다.")
            }
            return result(scope, .skippedNoData, "\(scope.key)은 로컬에 데이터가 없어 기존 백업을 건드리지 않았다.")
        }
        let recordedEpoch = try await store.meta(Self.epochPrefix + scope.key) ?? ""
        if recordedEpoch != token {
            return result(scope, .keptExisting(.staleAfterDataWipe), Self.keepMessage(name, .staleAfterDataWipe), header: old)
        }

        let preview = try await export(scope, emit: { _ in })
        var corrupted = false
        var index: FileIndex?
        var current = preview
        let fetched = try await destination.fetch(name: name)
        do {
            do {
                try TaptionBackupFileReader.verifyBodyChecksum(at: fetched, header: old)
                if isIdentical(old, preview, scope: scope, now: now) {
                    // 같은 내용이어도 돌려주기 전에 파일 전체를 복호화해 검증한다.
                    try await TaptionBackupFileReader.decode(at: fetched, header: old, key: key) { _ in }
                    try await store.setMeta(Self.epochPrefix + scope.key, token)
                    await destination.release(fetched: fetched)
                    return result(scope, .unchanged, "\(name)은 바뀐 데이터가 없어 그대로 둔다.", header: old)
                }
                // 파일의 모든 행을 로컬에 합친다(없는 id는 넣고, 기록은 최신 수정이 이긴다).
                index = try await apply(fileAt: fetched, header: old, key: key, scope: scope, rejectConflicts: false).index
                // 파일의 행이 로컬에 돌아왔으므로 "로컬에서 오프로드됨" 표시는 더는 맞지 않는다.
                if case .month(let month) = scope { try await store.setMeta(Self.sealedPrefix + month.key, "") }
                current = try await export(scope, emit: { _ in })
            } catch let error as TaptionBackupError where Self.isCorruption(error) {
                corrupted = true
            }
        } catch {
            await destination.release(fetched: fetched)
            throw error
        }
        await destination.release(fetched: fetched)

        if corrupted {
            // 손상된 파일은 합칠 수 없다. 로컬이 파일이 주장하는 내용을 모두 넘을 때만 새로 쓴다.
            if Self.supersetViolation(
                old: old, rowCount: preview.rowCount, last: preview.last, latestUpdate: preview.latestRecordUpdate
            ) != nil {
                return result(scope, .keptExisting(.existingCorrupted), Self.keepMessage(name, .existingCorrupted), header: old)
            }
        } else if isIdentical(old, current, scope: scope, now: now) {
            try await store.setMeta(Self.epochPrefix + scope.key, token)
            return result(scope, .unchanged, "\(name)은 합친 결과가 기존과 같아 그대로 둔다.", header: old)
        }
        return try await write(
            scope: scope, password: password, now: now, token: token, old: old, oldIndex: corrupted ? nil : index
        )
    }

    private static func isCorruption(_ error: TaptionBackupError) -> Bool {
        switch error {
        case .checksumMismatch, .authenticationFailed, .malformed, .verificationFailed: true
        default: false
        }
    }

    /// 달이 끝난 뒤에 다시 만든 적이 없는 백업은 내용이 같아도 새로 만든다(오프로드의 근거가 된다).
    private func isIdentical(
        _ old: TaptionBackupHeader, _ summary: ExportSummary, scope: TaptionBackupScope, now: Date
    ) -> Bool {
        var ended = false
        if case .month(let month) = scope, let end = month.interval(calendar: calendar)?.end {
            ended = now >= end && old.createdAt < end.timeIntervalSince1970
        }
        return old.contentSHA256 == summary.digest && old.rowCount == summary.rowCount && !ended
    }

    /// 임시 파일에 쓰고 검증(기존 파일의 모든 id 포함 여부 포함)한 뒤 목적지에서 원자적으로 교체하고, 올라간 파일을 다시 확인한다.
    private func write(
        scope: TaptionBackupScope, password: String, now: Date, token: String,
        old: TaptionBackupHeader?, oldIndex: FileIndex?
    ) async throws -> BackupResult {
        let name = scope.fileName
        let temporary = configuration.temporaryDirectory
            .appendingPathComponent("taption-backup-\(UUID().uuidString).tmp", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let (header, key) = try await writeFile(scope: scope, password: password, to: temporary, now: now)
        if oldIndex == nil, let old, let reason = Self.supersetViolation(
            old: old, rowCount: header.rowCount, last: header.lastTimestamp, latestUpdate: header.latestRecordUpdate
        ) {
            return result(scope, .keptExisting(reason), Self.keepMessage(name, reason), header: old)
        }
        try configuration.beforeVerify?(temporary)
        try await verifyFile(at: temporary, header: header, key: key, mustContain: oldIndex)

        try await destination.replace(name: name, with: temporary)
        let uploaded = try await destination.fetch(name: name)
        do {
            let reopened = try openHeader(at: uploaded, scope: scope, password: password).header
            try TaptionBackupFileReader.verifyBodyChecksum(at: uploaded, header: reopened)
            guard reopened == header else {
                throw TaptionBackupError.verificationFailed("uploaded file differs from the verified file")
            }
        } catch {
            await destination.release(fetched: uploaded)
            throw error
        }
        await destination.release(fetched: uploaded)
        try await store.setMeta(Self.epochPrefix + scope.key, token)
        return result(scope, .written, "\(name)을 \(header.rowCount)행으로 저장했다.", header: header)
    }

    // MARK: 전체 삭제

    /// 목적지의 백업 파일(월 파일과 설정 파일)을 모두 지운다. 일부가 실패해도 계속하고 결과에 남은 파일을 돌려준다.
    ///
    /// **호출 전에 반드시 사용자에게 확인을 받아야 한다.** 되돌릴 수 없고, 이 엔진은 다른 곳에서 이 함수를 부르지 않는다.
    /// 로컬 데이터는 건드리지 않는다(로컬 전체 삭제는 저장소 API가 따로 하며 백업 무효화 표시를 남긴다). 지운 월 파일의
    /// 봉인 표시는 푼다.
    func deleteAllBackups() async throws -> DeleteAllBackupsResult {
        try await exclusive("deleteAllBackups") {
            var removed: [String] = []
            var failed: [DeleteAllBackupsResult.Failure] = []
            for info in try await destination.list() {
                do {
                    try await destination.remove(name: info.name)
                    removed.append(info.name)
                    if case .month(let month)? = TaptionBackupScope(fileName: info.name) {
                        try await store.setMeta(Self.sealedPrefix + month.key, "")
                    }
                } catch {
                    failed.append(.init(name: info.name, message: "\(error)"))
                }
            }
            let remaining = try? await destination.list().map(\.name)
            return DeleteAllBackupsResult(removed: removed, failed: failed, remaining: remaining)
        }
    }

    // MARK: 복원

    /// 월 파일을 읽어 복호화해 저장소로 되돌린다. 지운 달 불러오기도 같은 함수다.
    /// 파일 전체를 먼저 검증한 뒤에만 저장소에 쓴다. 센서 원본은 같은 id가 다른 내용이면 거부한다.
    func restore(month: TaptionBackupMonth, password: String) async throws -> RestoreSummary {
        try await exclusive("restore \(month.key)") {
            try await performRestore(scope: .month(month), password: password)
        }
    }

    /// 설정 파일을 복원한다. 로컬 행이 더 나중에 고친 것이면 그대로 둔다.
    func restoreSettings(password: String) async throws -> RestoreSummary {
        try await exclusive("restore settings") {
            try await performRestore(scope: .settings, password: password)
        }
    }

    private func performRestore(scope: TaptionBackupScope, password: String) async throws -> RestoreSummary {
        guard !password.isEmpty else { throw TaptionBackupError.emptyPassword }
        // 파일은 한 번만 가져와 그 사본으로 헤더·체크섬·복호화·적용을 모두 한다.
        let url = try await destination.fetch(name: scope.fileName)
        let applied: Applied
        do {
            let (header, key) = try openHeader(at: url, scope: scope, password: password)
            try TaptionBackupFileReader.verifyBodyChecksum(at: url, header: header)
            applied = try await apply(fileAt: url, header: header, key: key, scope: scope, rejectConflicts: true)
        } catch {
            await destination.release(fetched: url)
            throw error
        }
        await destination.release(fetched: url)
        if case .month(let month) = scope { try await store.setMeta(Self.sealedPrefix + month.key, "") }
        // 사용자가 직접 복원한 파일은 전체 삭제 이후에도 받아들인 것으로 본다.
        try await store.setMeta(Self.epochPrefix + scope.key, try await wipeToken())
        return applied.summary
    }

    private struct Applied {
        var summary: RestoreSummary
        var index: FileIndex
    }

    /// 파일을 먼저 끝까지 검증한 뒤 로컬 저장소에 합친다.
    private func apply(
        fileAt url: URL, header: TaptionBackupHeader, key: SymmetricKey, scope: TaptionBackupScope, rejectConflicts: Bool
    ) async throws -> Applied {
        try await TaptionBackupFileReader.decode(at: url, header: header, key: key) { _ in }
        let before = try await store.readingCount()
        var buffer = RestoreBuffer(rejectConflicts: rejectConflicts)
        var index = FileIndex()
        let calendar = self.calendar
        try await TaptionBackupFileReader.decode(at: url, header: header, key: key) { line in
            let fields = try TaptionBackupJSONLine.parse(line)
            switch fields.first?.string {
            case "#readings":
                buffer.columns = try Self.mapColumns(fields)
            case "r":
                let reading = try Self.reading(from: fields, columns: buffer.columns, calendar: calendar)
                index.readings.insert(reading.id.uuidString)
                buffer.readings.append(reading)
                if buffer.readings.count >= Self.restoreBatch { try await self.flush(&buffer) }
            case "c":
                let record = try Self.record(from: fields)
                index.records["\(record.kind)\u{0}\(record.id)"] = record.updatedAt.timeIntervalSince1970
                buffer.records.append(record)
                if buffer.records.count >= Self.restoreBatch { try await self.flush(&buffer) }
            default:
                break
            }
        }
        try await flush(&buffer)
        let after = try await store.readingCount()
        let summary = RestoreSummary(
            scope: scope, fileReadings: header.readingCount, newReadings: after - before,
            fileRecords: header.recordCount, changedRecords: buffer.changedRecords,
            readingConflicts: buffer.readingConflicts
        )
        return Applied(summary: summary, index: index)
    }

    private struct RestoreBuffer {
        var rejectConflicts: Bool
        var columns: [Int?] = []
        var readings: [SensorReading] = []
        var records: [TaptionStoreRecord] = []
        var changedRecords = 0
        var readingConflicts = 0
    }

    private func flush(_ buffer: inout RestoreBuffer) async throws {
        if !buffer.readings.isEmpty {
            let batch = buffer.readings
            buffer.readings = []
            if buffer.rejectConflicts {
                try await store.appendImmutableReadings(batch)
            } else {
                buffer.readingConflicts += try await store.mergeReadingsKeepingLocal(batch)
            }
        }
        if !buffer.records.isEmpty {
            let batch = buffer.records
            buffer.records = []
            // 메모는 별도 파일에 쓰므로 종류로 나눠 되돌린다.
            var main: [TaptionStoreRecord] = []
            var memos: [TaptionStoreRecord] = []
            for record in batch {
                if record.kind == Self.memoKind, memoStore != nil { memos.append(record) } else { main.append(record) }
            }
            if !main.isEmpty {
                buffer.changedRecords += try await store.upsertRecordsKeepingNewer(main)
            }
            if !memos.isEmpty, let memoStore {
                buffer.changedRecords += try await memoStore.upsertRecordsKeepingNewer(memos)
            }
        }
    }

    // MARK: 로컬 정리(오프로드)

    /// 끝난 달 중 백업이 올라가 있고 다시 읽어 검증된 달만 봉인하고 로컬 행을 지운다.
    /// 지난 `keepRecentMonths`개 달(이번 달 포함)은 지우지 않는다. 달이 끝난 뒤에도 끝나지 않은 긴 기록은 로컬에 남긴다.
    func offloadSealedMonths(
        password: String, now: Date = Date(), keepRecentMonths: Int = 2
    ) async throws -> [OffloadResult] {
        guard !password.isEmpty else { throw TaptionBackupError.emptyPassword }
        return try await exclusive("offload") {
            let current = TaptionBackupMonth(date: now, calendar: calendar)
            let firstKept = current.adding(months: -(max(1, keepRecentMonths) - 1))
            var results: [OffloadResult] = []
            for month in try await monthsWithData() where month < firstKept {
                if let outcome = try await offload(month: month, password: password) {
                    results.append(OffloadResult(month: month, outcome: outcome))
                }
            }
            if results.contains(where: { if case .sealed = $0.outcome { true } else { false } }) {
                try await store.reclaimSpace()
            }
            return results
        }
    }

    private func offload(month: TaptionBackupMonth, password: String) async throws -> OffloadResult.Outcome? {
        let range = try interval(of: month)
        let from = range.start.timeIntervalSince1970
        let to = range.end.timeIntervalSince1970
        // 검증을 시작할 때의 지문. 삭제 트랜잭션이 같은 값을 다시 확인한다.
        let fingerprint = try await store.rangeFingerprint(from: from, to: to)
        guard fingerprint.readings + fingerprint.records > 0 else { return nil }

        let scope = TaptionBackupScope.month(month)
        let name = month.fileName
        let existing: ExistingFile
        do {
            existing = try await existingFile(scope: scope, password: password)
        } catch TaptionBackupError.passwordDiffersFromExistingBackup {
            return .skipped("\(name): 비밀번호가 기존 백업과 달라 지우지 않는다.")
        }
        guard case .opened(let header, let key) = existing else {
            return .skipped("\(name) 백업이 없거나 읽을 수 없다.")
        }
        guard header.createdAt >= to else {
            return .skipped("\(name)은 달이 끝나기 전에 만든 백업이라 지우지 않는다. 다시 백업해야 한다.")
        }
        let recordedEpoch = try await store.meta(Self.epochPrefix + scope.key) ?? ""
        if recordedEpoch != (try await wipeToken()) {
            return .skipped("\(name)은 데이터 전체 삭제 이전의 백업이라 지우지 않는다.")
        }
        let url = try await destination.fetch(name: name)
        do {
            let outcome = try await verifyAndDelete(
                month: month, scope: scope, url: url, header: header, key: key, from: from, to: to, fingerprint: fingerprint
            )
            await destination.release(fetched: url)
            return outcome
        } catch let error as TaptionBackupError {
            await destination.release(fetched: url)
            return .skipped("\(name) 검증 실패로 지우지 않았다: \(error)")
        } catch {
            await destination.release(fetched: url)
            throw error
        }
    }

    private func verifyAndDelete(
        month: TaptionBackupMonth, scope: TaptionBackupScope, url: URL, header: TaptionBackupHeader,
        key: SymmetricKey, from: Double, to: Double, fingerprint: TaptionStoreV2.RangeFingerprint
    ) async throws -> OffloadResult.Outcome {
        let name = month.fileName
        try TaptionBackupFileReader.verifyBodyChecksum(at: url, header: header)
        // 파일의 모든 행을 (열쇠 → 내용 해시)로 모은 뒤 로컬의 모든 행이 같은 내용으로 파일에 있는지 본다.
        var fileRows: [String: UInt64] = [:]
        try await TaptionBackupFileReader.decode(at: url, header: header, key: key) { line in
            if let entry = TaptionBackupRowIdentity.entry(of: line) {
                fileRows[(entry.isReading ? "r" : "c") + entry.key] = TaptionBackupRowIdentity.contentHash(line)
            }
        }
        var missing = 0
        _ = try await export(scope, emit: { line in
            guard let entry = TaptionBackupRowIdentity.entry(of: line) else { return }
            if fileRows[(entry.isReading ? "r" : "c") + entry.key] != TaptionBackupRowIdentity.contentHash(line) {
                missing += 1
            }
        })
        guard missing == 0 else {
            return .skipped("\(name)의 내용이 로컬과 달라 지우지 않는다(\(missing)행). 다시 백업해야 한다.")
        }
        guard let removed = try await store.deleteRange(
            from: from, to: to, expected: fingerprint,
            sealedMeta: (Self.sealedPrefix + month.key, "\(header.contentSHA256)|\(header.rowCount)")
        ) else {
            return .skipped("\(name) 검증 뒤 로컬이 바뀌어(새 행·편집·삭제 표시) 지우지 않았다.")
        }
        // 메모는 다른 파일이라 한 트랜잭션으로 묶을 수 없다. 이미 검증한 백업 파일에 들어 있으므로 지운다.
        let memoRemoved = try await memoStore?.deleteRecordRange(from: from, to: to) ?? 0
        return .sealed(readings: removed.readings, records: removed.records + memoRemoved)
    }

    // MARK: 파일 쓰기·검증

    private func writeFile(
        scope: TaptionBackupScope, password: String, to url: URL, now: Date
    ) async throws -> (TaptionBackupHeader, SymmetricKey) {
        let salt = try TaptionBackupCrypto.randomBytes(TaptionBackupCrypto.saltBytes)
        let iterations = configuration.iterations
        let key = try TaptionBackupCrypto.deriveKey(
            password: password, salt: salt, iterations: iterations, minimumIterations: configuration.minimumIterations
        )
        let writer = try TaptionBackupFileWriter(
            url: url, month: scope.key, key: key, salt: salt,
            codec: configuration.codec, chunkBytes: configuration.chunkBytes
        )
        do {
            let summary = try await export(scope, emit: { try writer.append($0) })
            let template = TaptionBackupHeader(
                month: scope.key,
                timeZone: calendar.timeZone.identifier,
                createdAt: now.timeIntervalSince1970,
                kdf: .init(algorithm: "PBKDF2-HMAC-SHA256", salt: salt.base64EncodedString(), iterations: iterations),
                compression: configuration.codec.name,
                chunkBytes: configuration.chunkBytes,
                chunkCount: 0,
                plaintextBytes: 0,
                readingCount: summary.readingCount,
                recordCount: summary.recordCount,
                rowCount: summary.rowCount,
                firstTimestamp: summary.first,
                lastTimestamp: summary.last,
                latestRecordUpdate: summary.latestRecordUpdate,
                contentSHA256: summary.digest,
                bodyBytes: 0,
                bodySHA256: ""
            )
            return (try writer.finish(header: template), key)
        } catch {
            writer.abort()
            throw error
        }
    }

    /// 방금 쓴 임시 파일을 처음부터 다시 읽어 헤더와 일치하는지, 기존 파일의 모든 id가 들어 있는지 확인한다.
    private func verifyFile(
        at url: URL, header: TaptionBackupHeader, key: SymmetricKey, mustContain: FileIndex?
    ) async throws {
        let reread = try TaptionBackupFileReader.open(
            public: try TaptionBackupFileReader.readPublicHeader(at: url), scopeKey: header.month,
            password: "", minimumIterations: configuration.minimumIterations, cachedKey: key
        ).header
        guard reread == header else { throw TaptionBackupError.verificationFailed("header changed after writing") }
        try TaptionBackupFileReader.verifyBodyChecksum(at: url, header: header)
        var remaining = mustContain
        try await TaptionBackupFileReader.decode(at: url, header: header, key: key) { line in
            guard remaining != nil, let entry = TaptionBackupRowIdentity.entry(of: line) else { return }
            if entry.isReading {
                remaining?.readings.remove(entry.key)
            } else if let old = remaining?.records[entry.key],
                      let fields = try? TaptionBackupJSONLine.parse(line), let updated = fields[5].double, updated >= old {
                remaining?.records[entry.key] = nil
            }
        }
        if let remaining, !remaining.isEmpty {
            throw TaptionBackupError.verificationFailed(
                "new file lacks \(remaining.readings.count + remaining.records.count) rows of the existing backup"
            )
        }
    }

    // MARK: 내보내기(표 → JSON Lines)

    /// 범위의 모든 행을 결정적 순서로 줄로 만들어 `emit`에 넘기고, 개수·시각 범위·내용 해시를 돌려준다.
    /// 센서 원본은 하루씩 읽어 메모리를 제한한다. 설정 범위에는 센서 원본이 없다.
    private func export(_ scope: TaptionBackupScope, emit: (Data) throws -> Void) async throws -> ExportSummary {
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

        var records: [TaptionStoreRecord]
        switch scope {
        case .month(let month):
            let range = try interval(of: month)
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
            records = try await store.recordsForBackup(
                from: range.start.timeIntervalSince1970, to: range.end.timeIntervalSince1970
            )
            records += try await memoStore?.recordsForBackup(
                from: range.start.timeIntervalSince1970, to: range.end.timeIntervalSince1970
            ) ?? []
        case .settings:
            records = try await store.undatedRecordsForBackup()
            records += try await memoStore?.undatedRecordsForBackup() ?? []
        }
        for record in records {
            try put(try Self.line(for: record))
            summary.recordCount += 1
            if let start = record.start { track(start.timeIntervalSince1970) }
            let updated = record.updatedAt.timeIntervalSince1970
            summary.latestRecordUpdate = max(summary.latestRecordUpdate ?? updated, updated)
        }

        summary.digest = TaptionBackupCrypto.hex(hasher.finalize())
        var trailer = TaptionBackupJSONLine.Builder()
        trailer.string("#end")
        trailer.int(Int64(summary.readingCount))
        trailer.int(Int64(summary.recordCount))
        try trailer.optionalDouble(summary.first)
        try trailer.optionalDouble(summary.last)
        trailer.string(summary.digest)
        try trailer.optionalDouble(summary.latestRecordUpdate)
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
        case opened(TaptionBackupHeader, SymmetricKey)
    }

    /// 목적지의 기존 파일을 비밀번호로 연다. 평문 헤더를 읽을 수 없으면 `.unreadable`, 비밀번호가 다르면
    /// `passwordDiffersFromExistingBackup`을 던진다(쓰기·오프로드 전에 오타·변경을 막는다).
    private func existingFile(scope: TaptionBackupScope, password: String) async throws -> ExistingFile {
        let name = scope.fileName
        guard try await destination.list().contains(where: { $0.name == name }) else { return .none }
        let prefix: Data
        do {
            prefix = try await destination.fetchPrefix(name: name, length: TaptionBackupFileReader.headerPrefixBytes)
        } catch TaptionBackupError.conflictingVersions(let conflicted) {
            throw TaptionBackupError.conflictingVersions(conflicted)
        } catch {
            return .unreadable
        }
        do {
            let opened = try openHeader(prefix: prefix, scope: scope, password: password)
            return .opened(opened.header, opened.key)
        } catch TaptionBackupError.wrongPassword {
            throw TaptionBackupError.passwordDiffersFromExistingBackup(name)
        } catch {
            return .unreadable
        }
    }

    private func openHeader(
        prefix: Data, scope: TaptionBackupScope, password: String
    ) throws -> (header: TaptionBackupHeader, key: SymmetricKey) {
        try openHeader(public: try TaptionBackupFileReader.parsePublicHeader(prefix), scope: scope, password: password)
    }

    private func openHeader(
        at url: URL, scope: TaptionBackupScope, password: String
    ) throws -> (header: TaptionBackupHeader, key: SymmetricKey) {
        try openHeader(public: try TaptionBackupFileReader.readPublicHeader(at: url), scope: scope, password: password)
    }

    /// 같은 솔트·반복 횟수의 키는 작업 하나 안에서 한 번만 유도한다(작업이 끝나면 버린다).
    private func openHeader(
        public publicHeader: TaptionBackupPublicHeader, scope: TaptionBackupScope, password: String
    ) throws -> (header: TaptionBackupHeader, key: SymmetricKey) {
        let cacheID = "\(publicHeader.kdf.salt)|\(publicHeader.kdf.iterations)"
        let opened = try TaptionBackupFileReader.open(
            public: publicHeader, scopeKey: scope.key, password: password,
            minimumIterations: configuration.minimumIterations, cachedKey: keyCache[cacheID]
        )
        keyCache[cacheID] = opened.key
        return opened
    }

    private func wipeToken() async throws -> String {
        try await store.meta(TaptionStoreV2.backupWipeTokenKey) ?? ""
    }

    /// 실제 데이터가 있는 달(오름차순). 데이터가 있는 UTC 날짜의 양끝이 속한 달만 후보로 삼고 로컬 행이 있는 것만 남긴다.
    private func monthsWithData() async throws -> [TaptionBackupMonth] {
        var candidates = Set<TaptionBackupMonth>()
        for day in try await store.dataUTCDays() where Self.validDays.contains(day) {
            let start = Double(day) * 86_400
            for instant in [start, start + 86_399.999] {
                candidates.insert(TaptionBackupMonth(date: Date(timeIntervalSince1970: instant), calendar: calendar))
            }
        }
        var months: [TaptionBackupMonth] = []
        for month in candidates.sorted() {
            if try await localRowCount(.month(month)) > 0 { months.append(month) }
        }
        return months
    }

    /// 새 파일이 기존 파일의 상위 집합이 아닐 징후를 찾는다(손상된 기존 파일처럼 id 목록을 알 수 없을 때만 쓴다):
    /// 행 수(삭제 표시 포함)·마지막 시각·기록 최신 수정 시각이 기존보다 작으면 거부한다.
    private static func supersetViolation(
        old: TaptionBackupHeader, rowCount: Int, last: Double?, latestUpdate: Double?
    ) -> KeepReason? {
        if rowCount < old.rowCount { return .fewerRows(existing: old.rowCount, new: rowCount) }
        if let oldLast = old.lastTimestamp, (last ?? -.infinity) < oldLast {
            return .earlierLastTimestamp(existing: oldLast, new: last)
        }
        if let oldUpdate = old.latestRecordUpdate, (latestUpdate ?? -.infinity) < oldUpdate {
            return .olderRecordUpdates(existing: oldUpdate, new: latestUpdate)
        }
        return nil
    }

    private func localRowCount(_ scope: TaptionBackupScope) async throws -> Int {
        switch scope {
        case .month(let month):
            let range = try interval(of: month)
            let stats = try await store.rangeStats(
                from: range.start.timeIntervalSince1970, to: range.end.timeIntervalSince1970
            )
            let memos = (try await memoStore?.rangeStats(
                from: range.start.timeIntervalSince1970, to: range.end.timeIntervalSince1970
            ))?.records ?? 0
            return stats.readings + stats.records + memos
        case .settings:
            return try await store.undatedRecordCount()
                + (try await memoStore?.undatedRecordCount() ?? 0)
        }
    }

    private static func keepMessage(_ name: String, _ reason: KeepReason) -> String {
        switch reason {
        case .fewerRows(let existing, let new):
            "\(name): 새 데이터(\(new)행)가 기존 백업(\(existing)행)보다 적어 기존 파일을 지켰다."
        case .earlierLastTimestamp:
            "\(name): 새 데이터의 마지막 시각이 기존 백업보다 앞서 기존 파일을 지켰다."
        case .olderRecordUpdates:
            "\(name): 새 데이터의 기록 수정 시각이 기존 백업보다 오래돼 기존 파일을 지켰다."
        case .existingUnreadable:
            "\(name): 기존 파일을 읽을 수 없어 덮어쓰지 않았다."
        case .existingCorrupted:
            "\(name): 기존 파일 본문이 손상됐고 로컬이 그 내용을 모두 담고 있지 않아 덮어쓰지 않았다."
        case .staleAfterDataWipe:
            "\(name): 데이터 전체 삭제 이전의 백업이라 합치지도 덮어쓰지도 않았다. 백업 전체 삭제 또는 복원으로 정리해야 한다."
        }
    }

    private func result(
        _ scope: TaptionBackupScope, _ outcome: BackupResult.Outcome, _ message: String,
        header: TaptionBackupHeader? = nil
    ) -> BackupResult {
        BackupResult(scope: scope, outcome: outcome, header: header, message: message)
    }

    private func interval(of month: TaptionBackupMonth) throws -> (start: Date, end: Date) {
        guard let range = month.interval(calendar: calendar) else {
            throw TaptionBackupError.malformed("invalid month \(month.key)")
        }
        return range
    }
}
