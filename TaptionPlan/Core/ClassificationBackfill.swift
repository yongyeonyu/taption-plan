import Foundation
import TaptionPlanEngine

/// 자동 분류 규칙의 버전. 규칙을 바꾸면 올린다. 올리면 지난 날짜 전체를 한 번 다시 만든다.
/// 날짜별 재계산 표식(`<버전>:yyyy-MM-dd`)과 일괄 재계산 완료 표식이 이 값을 쓴다.
/// 기록의 `modelVersion`(`classifier-v1/<단계>`)은 따로이며 바꾸지 않는다.
enum ClassificationRules {
    /// r2: 이동 수단 혼합 판정(HMM1101A01)·Apple Watch 낮잠(RIG1103A02).
    /// r3: 휴대폰 수면을 `SleepFusion.phoneOnly` 한 규칙으로(낮 창 안·30분 미만 후보 버림, ALG1102A01).
    static let version = ClassifierPipeline.version + "r3"
}

/// 규칙 버전이 바뀐 뒤 지난 날짜 전체의 자동 기록을 한 번 다시 만든다(HMM1101A01).
///
/// 최신 날부터 하루씩 처리한다. 진행은 날짜별 표식이 저장소에 남기므로 다시 실행하면
/// 끝난 날을 건너뛰고 이어 한다. 끝까지 돌면 버전별 완료 표식을 남겨 다시 돌지 않는다.
/// 실패한 날은 표식이 없어 그날을 열 때 하루 갱신이 다시 계산한다.
/// 사용자 기록을 지키는 일과 저장은 하루 갱신(`recompute`)이 맡는다. 원본은 읽기만 한다.
struct ClassificationBackfill: Sendable {
    struct Summary: Equatable, Sendable {
        var recomputed = 0
        var alreadyDone = 0
        var failed = 0
        var finished = false
    }

    let markers: any ClassificationRecomputeMarkerStore
    var calendar: Calendar = .autoupdatingCurrent
    /// 진행 로그를 남기는 간격(일).
    var logInterval = 25

    static var completionKey: String { "classification-backfill:\(ClassificationRules.version)" }

    func isFinished(isolation: isolated (any Actor)? = #isolation) async -> Bool {
        await markers.isCompleted(Self.completionKey)
    }

    /// 오늘 전의 날을 최신부터. 오늘은 원본이 쌓이는 중이라 하루 갱신에 맡긴다.
    func pastDays(_ days: [Date], now: Date) -> [Date] {
        let today = calendar.startOfDay(for: now)
        return Set(days.map { calendar.startOfDay(for: $0) })
            .filter { $0 < today }
            .sorted(by: >)
    }

    /// `shouldContinue`가 거짓이거나 취소되면 그 자리에서 멈춘다(다음 실행이 이어 한다).
    /// 부른 쪽 actor에서 돈다(앱은 주 actor). 하루 갱신 클로저를 다른 실행 영역으로 넘기지 않는다.
    func run(
        isolation: isolated (any Actor)? = #isolation,
        days: [Date],
        now: Date = .now,
        shouldContinue: () async -> Bool = { true },
        recompute: (Date) async -> Bool
    ) async -> Summary {
        var summary = Summary()
        guard await !isFinished() else {
            summary.finished = true
            return summary
        }
        let ordered = pastDays(days, now: now)
        log("classification_backfill_started", ordered.count, summary)
        for (index, day) in ordered.enumerated() {
            guard !Task.isCancelled, await shouldContinue() else {
                log("classification_backfill_paused", ordered.count - index, summary)
                return summary
            }
            let key = ClassificationRecomputeCoordinator.markerKey(for: day, calendar: calendar)
            if await markers.isCompleted(key) {
                summary.alreadyDone += 1
                continue
            }
            if await recompute(day) {
                // 하루 갱신이 표식을 남기지 못한 경로(센서 서비스 없음 등)도 여기서 닫는다.
                if await !markers.isCompleted(key) {
                    await markers.markCompleted(key, outcome: "backfill")
                }
                summary.recomputed += 1
            } else if Task.isCancelled {
                log("classification_backfill_paused", ordered.count - index, summary)
                return summary
            } else {
                summary.failed += 1
            }
            if (index + 1) % max(1, logInterval) == 0 {
                log("classification_backfill_progress", ordered.count - index - 1, summary)
            }
        }
        await markers.markCompleted(Self.completionKey, outcome: "done failed=\(summary.failed)")
        summary.finished = true
        log("classification_backfill_finished", 0, summary)
        return summary
    }

    private func log(_ event: String, _ remaining: Int, _ summary: Summary) {
        TaptionPlanDiagnosticsLogger.shared.record(event, fields: [
            "rules": ClassificationRules.version,
            "remaining": String(remaining),
            "recomputed": String(summary.recomputed),
            "already_done": String(summary.alreadyDone),
            "failed": String(summary.failed),
        ])
    }
}
