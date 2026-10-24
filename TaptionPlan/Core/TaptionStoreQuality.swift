import Foundation
import SQLite3
import Synchronization

/// 저장소가 **조용히 버리는 것**을 세는 원장.
///
/// 지금까지 세 가지가 흔적 없이 사라졌다.
/// 1. 열 타입이 맞지 않아 `extra`로 밀려난 값(열 조회에서 영영 빠진다).
/// 2. 해독에 실패해 결과에서 빠진 행(개수 없이 로그 한 줄).
/// 3. 저장된 `day`가 지금 달력과 다른 날(시간대를 옮기면 생긴다).
///
/// 스키마를 바꾸지 않고 세기만 한다. 값은 프로세스 안에만 있고, 임계를 넘을 때만 진단 로그에 남긴다.
/// `NSLock` 대신 `Mutex`를 쓴다. 구조 게이트가 unchecked 표시 수를 세므로 늘리지 않는다.
final class TaptionStoreQualityLedger: Sendable {
    struct Snapshot: Equatable, Sendable {
        var demotedColumns: [String: Int] = [:]
        var unreadableRows = 0
        var unreadableReasons: [String: Int] = [:]
        var driftedDays = 0
        var driftedRows = 0

        var demotedTotal: Int { demotedColumns.values.reduce(0, +) }
    }

    static let shared = TaptionStoreQualityLedger()

    /// 열 강등은 모델 필드 타입이 바뀔 때만 생기므로 드물다. 500건마다 한 번이면 충분하다.
    private static let demotionEmitEvery = 500
    private static let unreadableEmitEvery = 100

    private struct Counters: Sendable {
        var demotedColumns: [String: Int] = [:]
        var unreadableRows = 0
        var unreadableReasons: [String: Int] = [:]
        var driftedDays = 0
        var driftedRows = 0
        var lastDemotionEmitted = 0
        var lastUnreadableEmitted = 0
    }

    private let counters = Mutex(Counters())

    private init() {}

    // MARK: G1 — 열 강등

    /// 열 타입과 값의 형태가 맞지 않아 `extra`로 밀려난 열을 센다.
    func recordDemotedColumn(_ name: String) {
        let emission: (count: Int, total: Int, isFirst: Bool)? = counters.withLock { state in
            let previous = state.demotedColumns[name] ?? 0
            state.demotedColumns[name] = previous + 1
            let total = state.demotedColumns.values.reduce(0, +)
            let shouldEmit = previous == 0 || total - state.lastDemotionEmitted >= Self.demotionEmitEvery
            if shouldEmit { state.lastDemotionEmitted = total }
            return shouldEmit ? (previous + 1, total, previous == 0) : nil
        }
        guard let emission else { return }
        TaptionPlanDiagnosticsLogger.shared.record(
            "store_column_demoted",
            level: .notice,
            fields: ["column": name, "first": emission.isFirst ? "yes" : "no"],
            metrics: ["column_count": Double(emission.count), "total": Double(emission.total)]
        )
    }

    // MARK: G2 — 해독 실패

    /// 해석할 수 없어 결과에서 빠진 행을 센다. 사유는 앞부분만 남긴다(행마다 값이 달라 묶이지 않는다).
    /// 같은 행을 여러 번 읽으면 여러 번 센다 — "고유하게 깨진 행 수"가 아니라 "읽을 때 빠진 횟수"다.
    func recordUnreadableRow(_ error: Error) {
        let reason = Self.reason(for: error)
        let emission: (total: Int, reasonCount: Int)? = counters.withLock { state in
            state.unreadableRows += 1
            state.unreadableReasons[reason, default: 0] += 1
            let total = state.unreadableRows
            let shouldEmit = total == 1 || total - state.lastUnreadableEmitted >= Self.unreadableEmitEvery
            if shouldEmit { state.lastUnreadableEmitted = total }
            return shouldEmit ? (total, state.unreadableReasons.count) : nil
        }
        guard let emission else { return }
        TaptionPlanDiagnosticsLogger.shared.record(
            "store_row_unreadable",
            level: .notice,
            fields: ["reason": reason],
            metrics: ["total": Double(emission.total), "reason_count": Double(emission.reasonCount)]
        )
    }

    private static func reason(for error: Error) -> String {
        let text: String
        if let storeError = error as? TaptionStoreV2Error, case .corruptRow(let message) = storeError {
            text = message
        } else {
            text = error.localizedDescription
        }
        // 값이 섞인 부분을 지워 같은 원인끼리 묶이게 한다.
        let head = text.split(separator: ":", maxSplits: 1).first.map(String.init) ?? text
        return String(head.prefix(80))
    }

    // MARK: G4 — day 불일치

    func recordDayDrift(days: Int, rows: Int?) {
        guard days > 0 else { return }
        counters.withLock { state in
            state.driftedDays = days
            if let rows { state.driftedRows = rows }
        }
        var metrics: [String: Double] = ["days": Double(days)]
        if let rows { metrics["rows"] = Double(rows) }
        TaptionPlanDiagnosticsLogger.shared.record(
            "store_day_drift",
            level: .notice,
            fields: ["cause": "timeZoneChanged"],
            metrics: metrics
        )
    }

    // MARK: 조회

    func snapshot() -> Snapshot {
        counters.withLock { state in
            Snapshot(
                demotedColumns: state.demotedColumns,
                unreadableRows: state.unreadableRows,
                unreadableReasons: state.unreadableReasons,
                driftedDays: state.driftedDays,
                driftedRows: state.driftedRows
            )
        }
    }

    /// 테스트가 서로 영향을 주지 않게 비운다.
    func reset() {
        counters.withLock { state in
            state = Counters()
        }
    }
}

// MARK: - 열 매핑 (동결 파일에서 옮겨 왔다)

/// `SensorReading`과 열 사이의 변환. 값의 형태가 열과 맞지 않으면 `extra`에 남기고 **센다**.
extension TaptionReadingRowCodec {
    /// 값의 형태가 열과 맞을 때만 열로 옮기고, 맞지 않으면 `extra`에 그대로 둔다.
    /// 키가 아예 없으면 정상적인 빈 값이므로 세지 않는다. 키는 있는데 형태가 다르면 G1로 센다.
    static func take(_ column: Column, from object: inout [String: Any]) -> Value {
        take(column, parts: parts(of: column), from: &object)
    }

    /// 경로를 이미 쪼갠 상태로 부르는 형태. 경로 문자열은 고정이므로 행마다 `split`하지 않는다.
    static func take(_ column: Column, parts: [String], from object: inout [String: Any]) -> Value {
        if parts.count == 2 {
            guard var inner = object[parts[0]] as? [String: Any], let raw = inner[parts[1]] else { return .null }
            guard let value = convert(raw, kind: column.kind) else {
                TaptionStoreQualityLedger.shared.recordDemotedColumn(column.name)
                return .null
            }
            inner[parts[1]] = nil
            object[parts[0]] = inner.isEmpty ? nil : inner
            return value
        }
        guard let raw = object[parts[0]] else { return .null }
        guard let value = convert(raw, kind: column.kind) else {
            TaptionStoreQualityLedger.shared.recordDemotedColumn(column.name)
            return .null
        }
        object[parts[0]] = nil
        return value
    }

    static func convert(_ raw: Any, kind: Kind) -> Value? {
        switch kind {
        case .text:
            guard let text = raw as? String else { return nil }
            return .text(text)
        case .bool:
            guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return .int(number.boolValue ? 1 : 0)
        case .int:
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return .int(number.int64Value)
        case .real:
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return .real(number.doubleValue)
        }
    }
}

// MARK: - day 불일치 점검

extension TaptionStoreV2 {
    struct DayDrift: Equatable, Sendable {
        var days = 0
        var rows = 0

        var isClean: Bool { days == 0 }
    }

    /// 저장된 `day`가 지금 달력 기준 날짜와 다른 날을 센다.
    ///
    /// `day`는 쓰기 시점 달력의 파생값이다. 시간대를 옮기면 같은 순간이 다른 날로 계산되고,
    /// 이미 저장된 행은 옛 `day`로 남는다. 읽기는 `ts` 기준이라 화면은 무사하지만
    /// `day`로 묶는 쪽(백업 날짜 범위)은 어긋난다.
    ///
    /// 하루에 한 행만 읽으므로 비용은 날짜 수에 비례한다. 호출은 사용자가 진단을 요청할 때만 한다.
    func dayDrift() throws -> DayDrift {
        let db = try handle()
        let statement = try prepare(db, "SELECT day, COUNT(*), MIN(ts), MAX(ts) FROM readings GROUP BY day")
        defer { sqlite3_finalize(statement) }
        var drift = DayDrift()
        while sqlite3_step(statement) == SQLITE_ROW {
            let stored = Int(sqlite3_column_int64(statement, 0))
            let count = Int(sqlite3_column_int64(statement, 1))
            let first = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            let last = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            let expectedFirst = TaptionReadingRowCodec.dayNumber(for: first, calendar: calendar)
            let expectedLast = TaptionReadingRowCodec.dayNumber(for: last, calendar: calendar)
            guard stored != expectedFirst || stored != expectedLast else { continue }
            drift.days += 1
            drift.rows += count
        }
        TaptionStoreQualityLedger.shared.recordDayDrift(days: drift.days, rows: drift.rows)
        return drift
    }
}
