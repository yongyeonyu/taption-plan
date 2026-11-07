import Foundation
import SQLite3
import TaptionPlanCore

// MARK: - 열 매핑 (동결 파일에서 옮겨 왔다)

/// `SensorReading`과 열 사이의 변환. 값의 형태가 열과 맞지 않으면 `extra`에 남기고 **센다**.
extension TaptionReadingRowCodec {
    /// 값의 형태가 열과 맞을 때만 열로 옮기고, 맞지 않으면 `extra`에 그대로 둔다.
    /// 키가 아예 없으면 정상적인 빈 값이므로 세지 않는다. 키는 있는데 형태가 다르면 G1로 센다.
    public static func take(_ column: Column, from object: inout [String: Any]) -> Value {
        take(column, parts: parts(of: column), from: &object)
    }

    /// 경로를 이미 쪼갠 상태로 부르는 형태. 경로 문자열은 고정이므로 행마다 `split`하지 않는다.
    public static func take(_ column: Column, parts: [String], from object: inout [String: Any]) -> Value {
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

    public static func convert(_ raw: Any, kind: Kind) -> Value? {
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
    public struct DayDrift: Equatable, Sendable {
        public var days = 0
        public var rows = 0

        public var isClean: Bool { days == 0 }
    }

    /// 저장된 `day`가 지금 달력 기준 날짜와 다른 날을 센다.
    ///
    /// `day`는 쓰기 시점 달력의 파생값이다. 시간대를 옮기면 같은 순간이 다른 날로 계산되고,
    /// 이미 저장된 행은 옛 `day`로 남는다. 읽기는 `ts` 기준이라 화면은 무사하지만
    /// `day`로 묶는 쪽(백업 날짜 범위)은 어긋난다.
    ///
    /// 하루에 한 행만 읽으므로 비용은 날짜 수에 비례한다. 호출은 사용자가 진단을 요청할 때만 한다.
    public func dayDrift() throws -> DayDrift {
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
