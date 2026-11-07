import Foundation
import HealthKit

/// 잠긴 기기에서 HealthKit이 답하지 못하는 것은 정상이다(BGR1028A01).
///
/// 배경 갱신·잠금 직후 갱신은 `Protected health data is inaccessible`(HKError 6)로 실패한다.
/// 사용자가 고칠 수 있는 오류가 아니므로 배너를 띄우지 않고, 잠금이 풀리면 다시 읽는다.
enum HealthRefreshErrorPolicy {
    static func isProtectedDataUnavailable(_ error: Error) -> Bool {
        let value = error as NSError
        if value.domain == HKErrorDomain, value.code == HKError.Code.errorDatabaseInaccessible.rawValue {
            return true
        }
        guard let underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
        return isProtectedDataUnavailable(underlying)
    }

    static func showsBanner(for error: Error, showErrors: Bool) -> Bool {
        showErrors && !isProtectedDataUnavailable(error)
    }
}

/// 배경 갱신이 끝날 때 남은 오류를 설명할 수 있게 문구·종류·새로 섰는지를 함께 남긴다.
enum BackgroundRefreshUserErrorDiagnostics {
    static let maximumTextLength = 120

    static func fields(atStart: String?, atEnd: String?) -> [String: String] {
        [
            "user_error": atEnd.map { String($0.prefix(maximumTextLength)) } ?? "none",
            "user_error_state": state(atStart: atStart, atEnd: atEnd),
            "user_error_category": atEnd.map(category) ?? "none",
        ]
    }

    static func state(atStart: String?, atEnd: String?) -> String {
        switch (atStart, atEnd) {
        case (nil, nil): "none"
        case (_, nil): "cleared"
        case (nil, _): "new"
        case let (start, end): start == end ? "carried" : "replaced"
        }
    }

    /// 문구의 앞머리로 어느 기능에서 온 오류인지 고른다. 진단용이라 모르는 문구는 `other`다.
    static func category(_ message: String) -> String {
        let text = message.lowercased()
        let table: [(String, [String])] = [
            ("health", ["건강", "health"]),
            ("calendar", ["캘린더", "calendar"]),
            ("widget", ["위젯", "widget"]),
            ("screen_time", ["앱 사용시간", "screen time", "app usage"]),
            ("location", ["위치", "location"]),
            ("sync", ["동기화", "icloud", "sync"]),
            ("storage", ["저장", "save", "store"]),
        ]
        return table.first { _, keys in keys.contains { text.contains($0) } }?.0 ?? "other"
    }
}
