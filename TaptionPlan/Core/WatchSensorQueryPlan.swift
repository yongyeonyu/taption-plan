import Foundation

/// `CMSensorRecorder`에 던질 조회 한 토막.
struct WatchSensorQueryWindow: Equatable, Sendable {
    var start: Date
    var end: Date

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// `accelerometerData(from:to:)`에 넘길 범위를 미리 계산한다.
///
/// 이 호출은 잘못된 요청에 nil이나 NSError가 아니라 Objective-C 예외로
/// 답한다. Swift는 그 예외를 잡을 수 없어 프로세스가 그대로 끝나므로,
/// 요청을 만들기 전에 SDK 헤더(CMSensorRecorder.h)가 못박은 한계를 모두
/// 값으로 확인한다. CoreMotion을 쓰지 않는 순수 계산이라 시뮬레이터
/// 테스트에서 그대로 검증된다.
enum WatchSensorQueryPlan {
    /// 헤더: "A total duration of 12 hours of data can be requested at any
    /// one time."
    static let maximumQuerySpan: TimeInterval = 12 * 3_600
    /// 헤더: 기록은 최대 3일 뒤에 접근할 수 있다.
    static let retentionSpan: TimeInterval = 3 * 86_400
    /// 헤더: "Data can be delayed for up to 3 minutes before being available
    /// for retrieval."
    static let availabilityLag: TimeInterval = 3 * 60
    /// 조회 자체는 12시간까지 허용되지만, 한 번에 12시간(=216만 표본)을
    /// 열거하면 목록 객체가 그대로 메모리에 남는다. 30분씩 끊어 읽는다.
    static let chunkSpan: TimeInterval = 30 * 60
    /// 보관 한계선을 바로 긁으면 조회하는 동안 표본이 만료될 수 있다.
    static let retentionMargin: TimeInterval = 10 * 60

    /// 한 번 실행이 던질 수 있는 조회 수 상한. 보관 기간 전체를 토막 길이로
    /// 끊어도 이 수를 넘지 않으므로 루프가 무한히 늘어날 수 없다.
    static var maximumWindowsPerDrain: Int {
        Int((retentionSpan / chunkSpan).rounded(.up))
    }

    /// 저장된 워터마크가 미래를 가리키면(기기 시계 되돌림, 손상된 기본값)
    /// 조회가 영원히 멈춘다. 현재 시각을 넘는 값은 없던 것으로 본다.
    static func sanitizedHighWater(_ stored: Date?, now: Date) -> Date? {
        guard let stored, stored <= now else { return nil }
        return stored
    }

    static func restoredArmedAt(
        stored: Date?,
        armedUntil: Date?,
        recordingDuration: TimeInterval
    ) -> Date? {
        if let stored { return stored }
        guard let armedUntil,
              recordingDuration.isFinite,
              recordingDuration > 0 else {
            return nil
        }
        return armedUntil.addingTimeInterval(-recordingDuration)
    }

    /// 실제로 던져도 되는 조회 목록. 하나도 없으면 이번 실행은 조회하지
    /// 않는다.
    ///
    /// - Parameters:
    ///   - armedAt: 기록을 처음 건 시각. `nil`이면 이 기기에서 기록을 건
    ///     적이 없다는 뜻이므로 조회할 구간 자체가 존재하지 않는다.
    ///   - highWater: 지난 실행까지 읽어치운 지점.
    static func windows(
        now: Date,
        armedAt: Date?,
        highWater: Date?,
        chunk: TimeInterval = chunkSpan,
        minimumSpan: TimeInterval = WatchBehaviorWindowAnalyzer.windowDuration
    ) -> [WatchSensorQueryWindow] {
        // 권한이 있어도 기록을 건 적이 없으면 데몬에는 아무것도 없다.
        // 존재한 적 없는 구간을 묻는 것이 가장 흔한 잘못된 요청이다.
        guard let armedAt else { return [] }
        let end = now.addingTimeInterval(-availabilityLag)
        // 기록을 걸기 전과 보관이 끝난 뒤는 물어볼 수 없다. 조회 범위는
        // (from, to] 반열림이라 from = armedAt은 무장 시점 자체를 뺀다.
        let floor = max(
            armedAt,
            now.addingTimeInterval(-retentionSpan + retentionMargin)
        )
        let committed = sanitizedHighWater(highWater, now: now)
        if let committed,
           end.timeIntervalSince(committed) < minimumSpan {
            return []
        }
        var cursor = max(
            committed?.addingTimeInterval(-availabilityLag) ?? floor,
            floor
        )
        // 뒤집힌 범위, 같은 시각, 창 하나도 못 채우는 범위는 만들지 않는다.
        guard end > cursor, end.timeIntervalSince(cursor) >= minimumSpan else {
            return []
        }

        // 헤더가 못박은 12시간을 넘는 토막은 만들지 않는다.
        let span = min(max(chunk, 1), maximumQuerySpan)
        let limit = maximumWindowsPerDrain
        var windows: [WatchSensorQueryWindow] = []
        while cursor < end, windows.count < limit {
            let windowEnd = min(end, cursor.addingTimeInterval(span))
            guard windowEnd > cursor else { break }
            windows.append(WatchSensorQueryWindow(start: cursor, end: windowEnd))
            cursor = windowEnd
        }
        return windows
    }
}

/// 처리 위치 둘. 밀린 양이 많으면 최근 자료를 먼저 읽고(`recentStart`…`recentEnd`),
/// 오래된 쪽은 `highWater`부터 `recentStart`까지 나중에 메운다(WSN1112A02).
struct WatchSensorDrainCursor: Equatable, Sendable {
    /// 이 시각까지는 빠짐없이 읽었다.
    var highWater: Date?
    /// 앞질러 읽어 둔 최근 덩어리. 없으면 둘 다 nil.
    var recentStart: Date?
    var recentEnd: Date?

    var hasRecentBlock: Bool { recentStart != nil && recentEnd != nil }
}

/// 한 번 실행에서 읽을 토막. 둘 다 시간순이고 서로 겹치지 않는다.
struct WatchSensorDrainPlan: Equatable, Sendable {
    /// 오래된 쪽을 메우는 토막.
    var backfill: [WatchSensorQueryWindow] = []
    /// 최근 덩어리를 잇는 토막.
    var recent: [WatchSensorQueryWindow] = []
    /// 최근 덩어리가 시작하는 시각. 메우기는 여기서 멈춘다.
    var recentStart: Date?
    /// 이번 실행 뒤에도 메울 것이 남는다.
    var hasMoreBackfill = false
    /// 최근 덩어리가 아직 지금까지 닿지 못했다(오래 안 돌아 한 번 분량을 넘음).
    var hasMoreRecent = false

    var isEmpty: Bool { backfill.isEmpty && recent.isEmpty }
    /// 읽는 순서. 시간순이라 창 분석기가 그대로 이어 받는다.
    var ordered: [WatchSensorQueryWindow] { backfill + recent }
}

extension WatchSensorQueryPlan {
    /// 밀렸을 때 처음 앞질러 읽는 양(토막 수). 1.5시간.
    static let initialRecentWindows = 3

    /// 보관 기간을 벗어났거나 메우기가 따라잡은 최근 덩어리를 정리한다.
    static func normalized(
        _ cursor: WatchSensorDrainCursor,
        now: Date,
        armedAt: Date?
    ) -> WatchSensorDrainCursor {
        var value = cursor
        value.highWater = sanitizedHighWater(cursor.highWater, now: now)
        guard let start = cursor.recentStart, let end = cursor.recentEnd,
              start < end, end <= now else {
            value.recentStart = nil
            value.recentEnd = nil
            return value
        }
        let floor = max(
            armedAt ?? .distantPast,
            now.addingTimeInterval(-retentionSpan + retentionMargin)
        )
        // 메우기가 덩어리 시작에 닿았거나, 덩어리 앞이 이미 보관 기간 밖이면 하나로 합친다.
        if start <= max(value.highWater ?? floor, floor) {
            value.highWater = max(value.highWater ?? end, end)
            value.recentStart = nil
            value.recentEnd = nil
        }
        return value
    }

    /// 이번 실행에서 읽을 토막을 정한다.
    ///
    /// 밀린 양이 `budget` 토막 안이면 예전과 똑같이 오래된 것부터 읽는다. 넘으면 최근
    /// `initialRecentWindows` 토막을 먼저 잡고(이미 덩어리가 있으면 그 끝부터 지금까지),
    /// 남은 몫으로 오래된 쪽을 메운다.
    static func plan(
        now: Date,
        armedAt: Date?,
        cursor rawCursor: WatchSensorDrainCursor,
        budget: Int,
        chunk: TimeInterval = chunkSpan
    ) -> WatchSensorDrainPlan {
        let cursor = normalized(rawCursor, now: now, armedAt: armedAt)
        let all = windows(
            now: now, armedAt: armedAt, highWater: cursor.highWater, chunk: chunk
        )
        let budget = max(1, budget)
        guard let armedAt else { return WatchSensorDrainPlan() }
        if !cursor.hasRecentBlock, all.count <= budget {
            return WatchSensorDrainPlan(backfill: all)
        }
        let end = now.addingTimeInterval(-availabilityLag)
        let floor = max(
            armedAt, now.addingTimeInterval(-retentionSpan + retentionMargin)
        )
        let backfillStart = max(cursor.highWater ?? floor, floor)
        let span = min(max(chunk, 1), maximumQuerySpan)

        // 최근 덩어리: 있으면 그 끝에서(늦게 풀린 표본을 위해 조금 겹쳐), 없으면 최근 몇 토막.
        let recentStart: Date
        var recentCursor: Date
        if let start = cursor.recentStart, let blockEnd = cursor.recentEnd {
            recentStart = start
            // 방금 읽은 끝에서 창 하나도 안 지났으면 다시 읽지 않는다(`windows`와 같은 기준).
            recentCursor = end.timeIntervalSince(blockEnd)
                < WatchBehaviorWindowAnalyzer.windowDuration
                ? end
                : max(start, blockEnd.addingTimeInterval(-availabilityLag))
        } else {
            let fresh = max(
                backfillStart,
                end.addingTimeInterval(-span * Double(min(budget, initialRecentWindows)))
            )
            recentStart = fresh
            recentCursor = fresh
        }
        var plan = WatchSensorDrainPlan(recentStart: recentStart)
        while recentCursor < end, plan.recent.count < budget,
              end.timeIntervalSince(recentCursor)
                >= WatchBehaviorWindowAnalyzer.windowDuration {
            let windowEnd = min(end, recentCursor.addingTimeInterval(span))
            plan.recent.append(WatchSensorQueryWindow(start: recentCursor, end: windowEnd))
            recentCursor = windowEnd
        }
        plan.hasMoreRecent = end.timeIntervalSince(recentCursor)
            >= WatchBehaviorWindowAnalyzer.windowDuration
        // 메우기: 오래된 쪽에서 덩어리 시작까지. 오래 지난 자료라 겹쳐 읽지 않는다.
        var fillCursor = backfillStart
        while fillCursor < recentStart,
              plan.backfill.count + plan.recent.count < budget {
            let windowEnd = min(recentStart, fillCursor.addingTimeInterval(span))
            plan.backfill.append(WatchSensorQueryWindow(start: fillCursor, end: windowEnd))
            fillCursor = windowEnd
        }
        plan.hasMoreBackfill = fillCursor < recentStart
        return plan
    }

    /// 읽기 결과로 처리 위치를 옮긴다. 실패한 토막부터는 다음 실행이 다시 읽는다.
    /// - Parameter completed: `plan.ordered` 앞에서부터 성공한 토막 수.
    static func advanced(
        _ rawCursor: WatchSensorDrainCursor,
        plan: WatchSensorDrainPlan,
        completed: Int,
        now: Date,
        armedAt: Date?
    ) -> WatchSensorDrainCursor {
        var cursor = normalized(rawCursor, now: now, armedAt: armedAt)
        let done = max(0, min(completed, plan.ordered.count))
        let backfillDone = min(done, plan.backfill.count)
        let recentDone = done - backfillDone
        if backfillDone > 0 {
            let reached = plan.backfill[backfillDone - 1].end
            cursor.highWater = max(cursor.highWater ?? reached, reached)
        }
        guard let recentStart = plan.recentStart else {
            return cursor
        }
        if recentDone > 0 {
            cursor.recentStart = recentStart
            cursor.recentEnd = max(
                cursor.recentEnd ?? plan.recent[recentDone - 1].end,
                plan.recent[recentDone - 1].end
            )
        }
        // 메우기가 덩어리 시작에 닿으면 하나로 합친다.
        let filled = plan.backfill.isEmpty
            ? !plan.hasMoreBackfill
            : backfillDone == plan.backfill.count && !plan.hasMoreBackfill
        if filled, let recentEnd = cursor.recentEnd, cursor.recentStart != nil {
            cursor.highWater = max(cursor.highWater ?? recentEnd, recentEnd)
            cursor.recentStart = nil
            cursor.recentEnd = nil
        }
        return cursor
    }
}

/// 조회 결과에 따라 워터마크를 옮기는 규칙.
///
/// 성공한 토막까지만 워터마크를 올린다. 실패한 범위는 다음 실행에서 다시
/// 읽어 일시적인 Core Motion 오류가 기록 유실로 바뀌지 않게 한다.
struct WatchSensorDrainLedger {
    /// 한 번 실행에서 예외를 이만큼 만나면 나머지 토막은 다음 실행으로
    /// 미룬다. 전 구간이 잘못된 상태에서 한 번에 수십 번 던지지 않는다.
    static let defaultFailureLimit = 3

    private(set) var highWater: Date?
    private(set) var failureCount = 0
    private let failureLimit: Int

    init(highWater: Date?, failureLimit: Int = defaultFailureLimit) {
        self.highWater = highWater
        self.failureLimit = max(1, failureLimit)
    }

    var isExhausted: Bool { failureCount >= failureLimit }

    mutating func succeeded(_ window: WatchSensorQueryWindow) {
        guard failureCount == 0 else { return }
        advance(past: window)
    }

    mutating func failed(_: WatchSensorQueryWindow) {
        failureCount += 1
    }

    private mutating func advance(past window: WatchSensorQueryWindow) {
        guard let highWater else {
            highWater = window.end
            return
        }
        self.highWater = max(highWater, window.end)
    }
}
