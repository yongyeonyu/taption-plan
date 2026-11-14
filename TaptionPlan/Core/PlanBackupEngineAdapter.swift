import Foundation

/// 앱이 `TaptionBackupEngine`을 부르는 유일한 곳. 엔진 시그니처가 바뀌면(예: 목록이 비밀번호를 받는 형태)
/// 이 파일만 맞추면 된다.
struct PlanBackupEngineAdapter: Sendable {
    let engine: TaptionBackupEngine

    /// 백업 파일 목록. 비밀번호가 없으면 월 이름·파일 크기만 담고 행 수·시각은 비운다.
    /// (헤더 메타데이터는 비밀번호를 입력한 뒤에만 보여 주는 규칙. `password`는 엔진이 요구하게 되면 그대로 넘긴다.)
    func listings(password: String?) async throws -> [PlanBackupListingRow] {
        let showsMetadata = !(password ?? "").isEmpty
        guard showsMetadata else { return [] }
        var rows: [PlanBackupListingRow] = []
        for listing in try await engine.listBackups(password: showsMetadata ? password : nil) {
            var offloaded = false
            if case .month(let month) = listing.scope {
                offloaded = (try? await engine.isSealed(month)) ?? false
            }
            let header = showsMetadata ? listing.header : nil
            rows.append(PlanBackupListingRow(
                name: listing.info.name,
                scope: listing.scope,
                size: listing.info.size,
                rowCount: header?.rowCount,
                lastDataAt: header?.lastTimestamp.map { Date(timeIntervalSince1970: $0) },
                createdAt: header.map { Date(timeIntervalSince1970: $0.createdAt) },
                isOffloaded: offloaded,
                metadataShown: showsMetadata,
                state: listing.state
            ))
        }
        return rows
    }

    /// 그날이 든 달을 백업한 뒤 이 기기에서 정리했는가(다시 불러오면 아니다). 달은 엔진의 달력으로 가른다.
    func isOffloaded(day: Date) async -> Bool {
        let month = TaptionBackupMonth(date: day, calendar: await engine.calendar)
        return (try? await engine.isSealed(month)) ?? false
    }

    func unsupportedFileCount() async -> Int {
        await engine.unsupportedFileCount()
    }

    func backupAll(
        password: String,
        now: Date,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> [TaptionBackupEngine.BackupResult] {
        try await engine.backupAllMonths(password: password, now: now, progress: progress)
    }

    func offload(password: String, now: Date, keepRecentMonths: Int) async throws -> [TaptionBackupEngine.OffloadResult] {
        try await engine.offloadSealedMonths(password: password, now: now, keepRecentMonths: keepRecentMonths)
    }

    func restore(_ scope: TaptionBackupScope, password: String) async throws -> TaptionBackupEngine.RestoreSummary {
        switch scope {
        case .month(let month): try await engine.restore(month: month, password: password)
        case .settings: try await engine.restoreSettings(password: password)
        }
    }

    func deleteAllBackups() async throws -> TaptionBackupEngine.DeleteAllBackupsResult {
        try await engine.deleteAllBackups()
    }
}
