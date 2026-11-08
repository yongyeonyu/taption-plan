import Foundation
import TaptionPlanEngine

/// 낮잠은 Apple Watch가 잰 낮 수면만이다(대표 결정, RIG1103A02).
///
/// 휴대폰이 가만히 있던 시간·아이폰 건강 앱 추정·직접 입력한 수면은 낮잠이 되지 않는다.
/// HealthKit 표본과 출처는 그대로 두고, 자동 수면 기록의 제목·상세만 `sleep.nap`으로 바꾼다.
/// 사용자가 만들거나 고친 기록은 건드리지 않는다.
enum AppleWatchNapPolicy {
    static let title = "낮잠"
    static let behavior = "nap"
    static let evidence = "Apple Watch 낮잠 수면 기록"
    /// 낮 창·최대 길이는 `SleepFusion`(휴대폰 수면과 같은 규칙)에 있다(대표 결정 2026-11-08: 9~21시·4시간 이하).
    static func isNap(
        _ session: SleepSession,
        among sessions: [SleepSession],
        calendar: Calendar = .autoupdatingCurrent
    ) -> Bool {
        guard session.asleepDuration > 0 else { return false }
        let isMain = mainNightSession(around: session.span.start, among: sessions, calendar: calendar)?.id == session.id
        return SleepFusion.isNap(
            ClassifierAdapter.interval(session.span), watchMeasured: isWatchMeasured(session),
            isMainSleep: isMain, calendar: calendar
        )
    }

    /// 잠든 구간을 Apple Watch가 직접 잰 세션. 직접 입력한 표본은 빼고 본다.
    static func isWatchMeasured(_ session: SleepSession) -> Bool {
        session.segments.contains {
            $0.stage.isAsleep && !$0.isUserEntered && $0.sourceTier == .appleWatch
        }
    }

    /// 그 밤(전날 18시~그날 12시)에 걸친 세션 중 가장 오래 잔 것.
    static func mainNightSession(
        around date: Date,
        among sessions: [SleepSession],
        calendar: Calendar = .autoupdatingCurrent
    ) -> SleepSession? {
        let night = SleepAnalysisEngine.overnightSpan(containing: date, calendar: calendar)
        return sessions
            .filter { $0.asleepDuration > 0 && $0.span.intersection(with: night) != nil }
            .max { $0.asleepDuration < $1.asleepDuration }
    }

    /// 자동 HealthKit·워치 수면 기록에 낮잠 여부를 붙인다. 낮잠이 아니게 된 기록은 수면으로 되돌린다.
    static func labeling(
        _ actuals: [ActualRecord],
        sessions: [SleepSession],
        inside span: TimeSpan,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [ActualRecord] {
        guard !sessions.isEmpty else { return actuals }
        let napIDs = Set(sessions.filter { isNap($0, among: sessions, calendar: calendar) }.map(\.id))
        return actuals.map { actual in
            guard actual.source == .appleWatch || actual.source == .healthKit,
                  actual.categoryID == "sleep",
                  actual.span(asOf: span.end).intersection(with: span) != nil,
                  !ActualRecord.userOwned(actual),
                  let session = matchingSession(actual, sessions: sessions, asOf: span.end) else { return actual }
            return napIDs.contains(session.id) ? asNap(actual) : asSleep(actual)
        }
    }

    static func isNap(_ actual: ActualRecord) -> Bool {
        actual.evidence.contains(evidence)
    }

    private static func matchingSession(_ actual: ActualRecord, sessions: [SleepSession], asOf date: Date) -> SleepSession? {
        if let exact = sessions.first(where: { $0.id == actual.id }) { return exact }
        let actualSpan = actual.span(asOf: date)
        guard actualSpan.duration > 0 else { return nil }
        return sessions
            .map { ($0, $0.span.intersection(with: actualSpan)?.duration ?? 0) }
            .filter { $0.1 >= actualSpan.duration / 2 }
            .max { $0.1 < $1.1 }?.0
    }

    private static func asNap(_ actual: ActualRecord) -> ActualRecord {
        var value = actual
        value.title = title
        value.behavior = behavior
        value.source = .appleWatch
        value.evidence = Array(Set(actual.evidence + [evidence])).sorted()
        return value
    }

    private static func asSleep(_ actual: ActualRecord) -> ActualRecord {
        guard isNap(actual) else { return actual }
        var value = actual
        value.title = "수면"
        value.behavior = WatchBehaviorKind.sleep.rawValue
        value.evidence = actual.evidence.filter { $0 != evidence }
        return value
    }
}
