import Foundation
import TaptionPlanCore

// 컨디션×일정 에너지 곡선(ENC1119A01). 지난밤 수면으로 시작값을 만들고, 15분 칸마다 기록(또는 오늘의 남은 일정)이
// 주는 변화량을 이어 붙인다. 순수 계산이라 SwiftUI·저장소를 모르고 `Date.now`도 읽지 않는다(같은 입력 → 같은 결과).

/// 곡선에 영향을 주는 활동 종류. 분류 id는 `kind(forCategoryID:)` 한 곳에서만 옮긴다.
enum EnergyCurveActivityKind: String, Sendable {
    case rest, sleep, eating, work, study, hobby, housework, movement, exercise, unconfirmed

    static func kind(forCategoryID id: String) -> EnergyCurveActivityKind {
        switch id {
        case "sleep": .sleep
        case "eating": .eating
        case "work": .work
        case "study": .study
        case "hobby": .hobby
        case "housework": .housework
        case "movement": .movement
        case "exercise": .exercise
        case "unconfirmed": .unconfirmed
        default: .rest
        }
    }
}

/// 상수는 한 곳에 모은다. 시험은 정확한 값이 아니라 관계(단조성·범위·칸 수)만 본다.
enum EnergyCurveTuning {
    static let bucketSeconds: TimeInterval = 15 * 60
    static let sleepGoal: TimeInterval = 420 * 60
    static let missingSleepStart = 0.75
    static let startRange = 0.35...1.0
    static let defaultWakeHour = 7
    /// 시간당 기본 소모.
    static let baseDrain = -0.055
    /// 14:30 중심, σ 2시간인 서카디안 처짐(시간당).
    static let dipDrain = -0.06
    static let dipCenterMinute = 14.0 * 60 + 30
    static let dipSigmaMinutes = 120.0
    /// 활동별 시간당 변화량.
    static func rate(_ kind: EnergyCurveActivityKind) -> Double {
        switch kind {
        case .sleep: 0.12
        case .rest: 0.05
        case .eating: 0.02
        case .hobby: 0.03
        case .study: -0.04
        case .work: -0.05
        case .housework: -0.07
        case .movement: -0.06
        case .exercise: -0.16
        case .unconfirmed: 0
        }
    }
    /// 걸음이 있으면 칸마다 조금 더 소모한다(걸음당, 칸 최대 2,000걸음까지).
    static let stepDrain = -0.00002
    static let stepCap = 2_000
    static let bucketDeltaLimit = 0.15
    static let lowThreshold = 0.35
    static let stackWindow: TimeInterval = 90 * 60
    static let shortSleep: TimeInterval = 6 * 3_600
}

struct EnergyCurveSleep: Equatable, Sendable {
    /// 지난밤 잠든 시간·깊은잠 시간·효율(0…1, 모르면 nil).
    let asleep: TimeInterval
    let deep: TimeInterval
    let efficiency: Double?
    /// 그 수면 세션의 구간. 끝이 기상 시각이다.
    let span: TimeSpan
}

struct EnergyCurveSegment: Equatable, Sendable {
    let span: TimeSpan
    let kind: EnergyCurveActivityKind
}

struct EnergyCurveBlock: Equatable, Sendable {
    let span: TimeSpan
    let kind: EnergyCurveActivityKind
}

struct EnergyCurveInput: Sendable {
    /// 로컬 시간대 기준 그날 [00:00, 다음 00:00).
    let day: TimeSpan
    /// 이 시각 앞은 실제, 뒤는 예측.
    let asOf: Date
    let sleep: EnergyCurveSleep?
    let segments: [EnergyCurveSegment]
    let blocks: [EnergyCurveBlock]
    /// 선택: 15분 칸(그날 0시부터 센 번호)별 걸음 수.
    let stepsByBucket: [Int: Int]?

    init(day: TimeSpan, asOf: Date, sleep: EnergyCurveSleep?, segments: [EnergyCurveSegment], blocks: [EnergyCurveBlock], stepsByBucket: [Int: Int]? = nil) {
        self.day = day; self.asOf = asOf; self.sleep = sleep
        self.segments = segments; self.blocks = blocks; self.stepsByBucket = stepsByBucket
    }
}

struct EnergyCurveBucket: Equatable, Sendable {
    let start: Date
    /// 0…1. 기상 전처럼 그리지 않는 칸은 nil.
    let value: Double?
    let isProjected: Bool
    let isAsleep: Bool
}

enum EnergyCurveInsight: Equatable, Sendable {
    case lowestPoint(minute: Int, value: Double)
    case scheduleStack(minute: Int, blockCount: Int, seconds: TimeInterval)
    case shortSleep(minutes: Int)
    case missingSleep
    case noData
}

struct EnergyCurveResult: Equatable, Sendable {
    let buckets: [EnergyCurveBucket]
    let insights: [EnergyCurveInsight]
    let wakeMinute: Int?
    let hasSleepData: Bool
    /// 카드가 일정 띠를 그릴 수 있게 그날과 일정을 그대로 돌려준다(곡선에는 영향이 없다).
    let day: TimeSpan?
    let blocks: [EnergyCurveBlock]
    var isEmpty: Bool { buckets.isEmpty }

    static let empty = EnergyCurveResult(buckets: [], insights: [.noData], wakeMinute: nil, hasSleepData: false, day: nil, blocks: [])
}

enum EnergyCurveEngine {
    static func curve(_ input: EnergyCurveInput) -> EnergyCurveResult {
        let dayStart = input.day.start
        let length = input.day.duration
        guard length > 0, input.sleep != nil || !input.segments.isEmpty || !input.blocks.isEmpty else { return .empty }
        let count = Int((length / EnergyCurveTuning.bucketSeconds).rounded(.up))
        let step = EnergyCurveTuning.bucketSeconds
        let wake = wakeTime(input)
        let wakeIndex = max(0, min(count, Int((wake.timeIntervalSince(dayStart) / step).rounded(.up))))
        var energy = startValue(input.sleep)
        var buckets: [EnergyCurveBucket] = []
        buckets.reserveCapacity(count)
        for index in 0..<count {
            let start = dayStart.addingTimeInterval(Double(index) * step)
            let span = TimeSpan(start: start, end: min(input.day.end, start.addingTimeInterval(step)))
            let projected = start >= input.asOf
            let asleep = isAsleep(span, input)
            guard index >= wakeIndex else {
                buckets.append(EnergyCurveBucket(start: start, value: nil, isProjected: projected, isAsleep: true))
                continue
            }
            buckets.append(EnergyCurveBucket(start: start, value: clamp(energy, 0, 1), isProjected: projected, isAsleep: asleep))
            energy = clamp(energy + delta(span, projected: projected, steps: input.stepsByBucket?[index], input: input), 0, 1)
        }
        let result = EnergyCurveResult(
            buckets: buckets,
            insights: insights(input, buckets: buckets),
            wakeMinute: Int(wake.timeIntervalSince(dayStart) / 60),
            hasSleepData: input.sleep != nil,
            day: input.day,
            blocks: input.blocks
        )
        return result
    }

    // MARK: 시작값·기상

    static func startValue(_ sleep: EnergyCurveSleep?) -> Double {
        guard let sleep else { return EnergyCurveTuning.missingSleepStart }
        let goal = EnergyCurveTuning.sleepGoal
        let amount = 0.72 * clamp(sleep.asleep / goal, 0.55, 1.05)
        let deep = 0.05 * clamp(sleep.deep / goal, 0, 0.2) / 0.2
        let efficiency = 0.05 * (sleep.efficiency.map { clamp(($0 - 0.75) / 0.2, 0, 1) } ?? 0.5)
        let value = amount + deep + efficiency
        return clamp(value.isFinite ? value : EnergyCurveTuning.missingSleepStart, EnergyCurveTuning.startRange.lowerBound, EnergyCurveTuning.startRange.upperBound)
    }

    /// ① 그날 수면 세션의 끝 ② 그날 첫 기록 ③ 07:00. 그날 안으로 자른다.
    static func wakeTime(_ input: EnergyCurveInput) -> Date {
        let candidate: Date
        if let sleep = input.sleep {
            candidate = sleep.span.end
        } else if let first = input.segments.filter({ $0.kind != .sleep }).map(\.span.start).min() {
            candidate = first
        } else {
            candidate = input.day.start.addingTimeInterval(Double(EnergyCurveTuning.defaultWakeHour) * 3_600)
        }
        return min(max(candidate, input.day.start), input.day.end)
    }

    // MARK: 칸 변화량

    private static func isAsleep(_ span: TimeSpan, _ input: EnergyCurveInput) -> Bool {
        if let sleep = input.sleep, overlap(span, sleep.span) > 0 { return true }
        return input.segments.contains { $0.kind == .sleep && overlap(span, $0.span) > 0 }
    }

    /// 한 칸의 변화량. 실제 칸은 기록, 예측 칸은 일정 종류로 같은 규칙을 쓴다. 덮이지 않은 시간은 미확인(0)이다.
    private static func delta(_ span: TimeSpan, projected: Bool, steps: Int?, input: EnergyCurveInput) -> Double {
        let hours = span.duration / 3_600
        guard hours > 0 else { return 0 }
        var perHour = EnergyCurveTuning.baseDrain + EnergyCurveTuning.dipDrain * dip(at: span, dayStart: input.day.start)
        let kinds: [(TimeSpan, EnergyCurveActivityKind)] = projected
            ? input.blocks.map { ($0.span, $0.kind) }
            : input.segments.map { ($0.span, $0.kind) }
        for (other, kind) in kinds {
            let share = overlap(span, other) / span.duration
            if share > 0 { perHour += EnergyCurveTuning.rate(kind) * share }
        }
        var total = perHour * hours
        if let steps, steps > 0, !projected { total += EnergyCurveTuning.stepDrain * Double(min(steps, EnergyCurveTuning.stepCap)) }
        guard total.isFinite else { return 0 }
        return clamp(total, -EnergyCurveTuning.bucketDeltaLimit, EnergyCurveTuning.bucketDeltaLimit)
    }

    private static func dip(at span: TimeSpan, dayStart: Date) -> Double {
        let minute = (span.start.timeIntervalSince(dayStart) + span.duration / 2) / 60
        let z = (minute - EnergyCurveTuning.dipCenterMinute) / EnergyCurveTuning.dipSigmaMinutes
        return exp(-z * z / 2)
    }

    // MARK: 인사이트

    private static func insights(_ input: EnergyCurveInput, buckets: [EnergyCurveBucket]) -> [EnergyCurveInsight] {
        var list: [EnergyCurveInsight] = []
        let awake = buckets.filter { $0.value != nil && !$0.isAsleep }
        if let low = awake.min(by: { ($0.value ?? 1) < ($1.value ?? 1) }), let value = low.value {
            let minute = Int(low.start.timeIntervalSince(input.day.start) / 60)
            if value < EnergyCurveTuning.lowThreshold { list.append(.lowestPoint(minute: minute, value: value)) }
            let window = TimeSpan(start: low.start.addingTimeInterval(-EnergyCurveTuning.stackWindow),
                                  end: low.start.addingTimeInterval(EnergyCurveTuning.bucketSeconds + EnergyCurveTuning.stackWindow))
            let near = input.blocks.filter { overlap($0.span, window) > 0 }
            if near.count >= 2 {
                list.append(.scheduleStack(minute: minute, blockCount: near.count, seconds: TimeSpan.unionDuration(near.map { clipped($0.span, to: window) })))
            }
        }
        if let sleep = input.sleep, sleep.asleep < EnergyCurveTuning.shortSleep {
            list.append(.shortSleep(minutes: Int(sleep.asleep / 60)))
        }
        if input.sleep == nil { list.append(.missingSleep) }
        return Array(list.prefix(2))
    }

    // MARK: 도우미

    private static func overlap(_ a: TimeSpan, _ b: TimeSpan) -> TimeInterval {
        max(0, min(a.end, b.end).timeIntervalSince(max(a.start, b.start)))
    }

    private static func clipped(_ span: TimeSpan, to window: TimeSpan) -> TimeSpan {
        TimeSpan(start: max(span.start, window.start), end: max(max(span.start, window.start), min(span.end, window.end)))
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(high, max(low, value.isFinite ? value : low))
    }
}
