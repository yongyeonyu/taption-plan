import SQLite3
import Foundation

extension TaptionStoreV2 {
    /// 이번 달 뒤의 달에 둘 만한 기록: 사용자가 정한 계획·메모·일정 같은 것(BKS1111A03). 일기 예보·센서·파생 기록은 미래에 있어도 세지 않는다.
    public static let futureKinds = ["plan", "memo", "calendarEvent", "sticker", "travel", "assistant-bubble", "ledger-entry"]

    /// 그 구간의 `futureKinds` 기록 수(지움 표시 포함: 예전 백업에 있던 계획을 지운 것도 올려야 복원 때 되살아나지 않는다).
    public func futureRecordCount(from start: Double, to end: Double) throws -> Int {
        let db = try handle()
        let kinds = Self.futureKinds.map { "'\($0)'" }.joined(separator: ",")
        let statement = try prepare(db, "SELECT COUNT(*) FROM records WHERE start_ts >= ?1 AND start_ts < ?2 AND kind IN (\(kinds))")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, .real(start))
        bind(statement, 2, .real(end))
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }
}
