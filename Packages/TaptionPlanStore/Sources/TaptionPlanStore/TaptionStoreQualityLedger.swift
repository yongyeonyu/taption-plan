import Foundation
import Synchronization

/// 저장소 진단 이벤트를 앱 진단 로그로 넘기는 연결점. 앱이 `install`로 잇기 전 이벤트는 버린다.
/// 모두 `notice` 수준이다.
public enum TaptionStoreDiagnostics {
    public typealias Sink = @Sendable (_ event: String, _ fields: [String: String], _ metrics: [String: Double]) -> Void

    private static let sink = Mutex<Sink?>(nil)

    public static func install(_ newSink: @escaping Sink) {
        sink.withLock { $0 = newSink }
    }

    public static func record(_ event: String, fields: [String: String], metrics: [String: Double]) {
        sink.withLock { $0 }?(event, fields, metrics)
    }
}

/// 저장소가 **조용히 버리는 것**을 세는 원장.
///
/// 지금까지 세 가지가 흔적 없이 사라졌다.
/// 1. 열 타입이 맞지 않아 `extra`로 밀려난 값(열 조회에서 영영 빠진다).
/// 2. 해독에 실패해 결과에서 빠진 행(개수 없이 로그 한 줄).
/// 3. 저장된 `day`가 지금 달력과 다른 날(시간대를 옮기면 생긴다).
///
/// 스키마를 바꾸지 않고 세기만 한다. 값은 프로세스 안에만 있고, 임계를 넘을 때만 진단 로그에 남긴다.
/// `NSLock` 대신 `Mutex`를 쓴다. 구조 게이트가 unchecked 표시 수를 세므로 늘리지 않는다.
public final class TaptionStoreQualityLedger: Sendable {
    public struct Snapshot: Equatable, Sendable {
        public var demotedColumns: [String: Int] = [:]
        public var unreadableRows = 0
        public var unreadableReasons: [String: Int] = [:]
        public var driftedDays = 0
        public var driftedRows = 0

        public var demotedTotal: Int { demotedColumns.values.reduce(0, +) }

        public init(
            demotedColumns: [String: Int] = [:],
            unreadableRows: Int = 0,
            unreadableReasons: [String: Int] = [:],
            driftedDays: Int = 0,
            driftedRows: Int = 0
        ) {
            self.demotedColumns = demotedColumns
            self.unreadableRows = unreadableRows
            self.unreadableReasons = unreadableReasons
            self.driftedDays = driftedDays
            self.driftedRows = driftedRows
        }
    }

    public static let shared = TaptionStoreQualityLedger()

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
    public func recordDemotedColumn(_ name: String) {
        let emission: (count: Int, total: Int, isFirst: Bool)? = counters.withLock { state in
            let previous = state.demotedColumns[name] ?? 0
            state.demotedColumns[name] = previous + 1
            let total = state.demotedColumns.values.reduce(0, +)
            let shouldEmit = previous == 0 || total - state.lastDemotionEmitted >= Self.demotionEmitEvery
            if shouldEmit { state.lastDemotionEmitted = total }
            return shouldEmit ? (previous + 1, total, previous == 0) : nil
        }
        guard let emission else { return }
        TaptionStoreDiagnostics.record(
            "store_column_demoted",
            fields: ["column": name, "first": emission.isFirst ? "yes" : "no"],
            metrics: ["column_count": Double(emission.count), "total": Double(emission.total)]
        )
    }

    // MARK: G2 — 해독 실패

    /// 해석할 수 없어 결과에서 빠진 행을 센다. 사유는 앞부분만 남긴다(행마다 값이 달라 묶이지 않는다).
    /// 같은 행을 여러 번 읽으면 여러 번 센다 — "고유하게 깨진 행 수"가 아니라 "읽을 때 빠진 횟수"다.
    public func recordUnreadableRow(_ error: Error) {
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
        TaptionStoreDiagnostics.record(
            "store_row_unreadable",
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

    public func recordDayDrift(days: Int, rows: Int?) {
        guard days > 0 else { return }
        counters.withLock { state in
            state.driftedDays = days
            if let rows { state.driftedRows = rows }
        }
        var metrics: [String: Double] = ["days": Double(days)]
        if let rows { metrics["rows"] = Double(rows) }
        TaptionStoreDiagnostics.record(
            "store_day_drift",
            fields: ["cause": "timeZoneChanged"],
            metrics: metrics
        )
    }

    // MARK: 조회

    public func snapshot() -> Snapshot {
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
    public func reset() {
        counters.withLock { state in
            state = Counters()
        }
    }
}
