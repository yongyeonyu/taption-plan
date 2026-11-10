import Foundation

/// 워치를 차지 않고 잔 밤을 휴대폰 근거만으로 점수 매겨 수면으로 확정한다(SLP1110A01).
/// 위치가 꺼져 화면·충전 표본이 없어도, iOS가 나중에 돌려주는 동작 기록과 밤 시간대만으로 판정할 수 있다.
/// 근거가 없는 항목은 0점이고 감점하지 않는다. 깨어 있었다는 근거(걷기·차·화면 켜짐 등)가 있으면 그 자리에서 끊는다.
public enum PhoneSleepScore {
    /// 휴대폰 표본 한 개. 모르는 값은 nil로 둔다.
    public struct Sample: Hashable, Sendable {
        public var timestamp: Date
        public var screenIsOn: Bool?
        public var isCharging: Bool?
        /// 집 반경 안인가. 위치가 없으면 nil.
        public var isAtHome: Bool?

        public init(timestamp: Date, screenIsOn: Bool? = nil, isCharging: Bool? = nil, isAtHome: Bool? = nil) {
            self.timestamp = timestamp
            self.screenIsOn = screenIsOn
            self.isCharging = isCharging
            self.isAtHome = isAtHome
        }
    }

    public struct Signals: Sendable {
        /// 판정할 밤(예: 18시 ~ 다음 날 12시, 현재 시각을 넘지 않게).
        public var night: ClassifierInterval
        /// 깨어 있었던 근거: 걷기·달리기·자전거·차 동작, 운동, 앱 사용, 걸음.
        /// 동작 기록이 바뀐 순간(휴대폰을 집어 든 때)은 길이 0으로 넣는다.
        public var wakeEvents: [ClassifierInterval]
        /// iOS 동작 기록의 정지 구간.
        public var stillEvents: [ClassifierInterval]
        public var samples: [Sample]
        /// 평소 잠드는·깨는 시각(자정 기준 분). 모르면 기본값을 쓴다.
        public var usualWindow: UsualWindow?

        public init(night: ClassifierInterval, wakeEvents: [ClassifierInterval], stillEvents: [ClassifierInterval] = [], samples: [Sample] = [], usualWindow: UsualWindow? = nil) {
            self.night = night
            self.wakeEvents = wakeEvents
            self.stillEvents = stillEvents
            self.samples = samples
            self.usualWindow = usualWindow
        }
    }

    /// 평소 수면 시간대. 23:30이면 bedMinute 1410, 07:30이면 wakeMinute 450.
    public struct UsualWindow: Hashable, Sendable {
        public var bedMinute: Int
        public var wakeMinute: Int
        /// 워치로 잰 지난 밤에서 배운 값인가.
        public var isLearned: Bool

        public init(bedMinute: Int, wakeMinute: Int, isLearned: Bool) {
            self.bedMinute = bedMinute
            self.wakeMinute = wakeMinute
            self.isLearned = isLearned
        }

        public static let fallback = UsualWindow(bedMinute: 23 * 60 + 30, wakeMinute: 7 * 60 + 30, isLearned: false)
    }

    public struct Verdict: Hashable, Sendable {
        public var interval: ClassifierInterval
        public var score: Int
        public var isSleep: Bool
        public var factors: [String]
    }

    public static let threshold = 60
    public static let minimumDuration: TimeInterval = 3 * 3_600
    /// 평소 시간대 앞뒤로 이만큼은 같은 밤으로 친다.
    static let windowSlack = 60

    /// 밤 안에서 깨어 있던 근거 사이의 조용한 구간(3시간 이상)을 모두 점수 매겨 가장 높은 것을 고른다.
    /// 가장 긴 것만 보면 저녁 내내 휴대폰을 두고 있던 구간이 진짜 잠을 가린다.
    public static func evaluate(_ signals: Signals, calendar: Calendar = .autoupdatingCurrent) -> Verdict? {
        quietSpans(signals)
            .map { score($0, signals: signals, calendar: calendar) }
            .max { ($0.score, $0.interval.duration) < ($1.score, $1.interval.duration) }
    }

    static func score(_ candidate: ClassifierInterval, signals: Signals, calendar: Calendar) -> Verdict {
        var score = 0
        var factors: [String] = []
        func add(_ points: Int, _ label: String) {
            guard points != 0 else { return }
            score += points
            factors.append("\(label) \(points > 0 ? "+" : "")\(points)")
        }

        let hours = candidate.duration / 3_600
        add(hours >= 6 ? 30 : hours >= 5 ? 25 : hours >= 4 ? 18 : 10, "조용한 시간 \(String(format: "%.1f", hours))시간")

        let window = signals.usualWindow ?? .fallback
        let overlap = nightOverlap(candidate, window: window, calendar: calendar)
        add(Int((overlap * 30).rounded()), window.isLearned ? "평소 수면 시간대" : "밤 시간대")

        add(15, "걷기·이동 없음")
        if signals.stillEvents.contains(where: { $0.overlap(with: candidate) > 0 }) { add(5, "동작 기록 정지") }

        let inside = signals.samples.filter { $0.timestamp >= candidate.start && $0.timestamp <= candidate.end }
        let located = inside.compactMap(\.isAtHome)
        if !located.isEmpty {
            let home = Double(located.filter { $0 }.count) / Double(located.count)
            add(home >= 0.8 ? 10 : home <= 0.2 ? -15 : 0, home >= 0.8 ? "집" : "집 밖")
        }
        let charging = inside.compactMap(\.isCharging)
        if !charging.isEmpty, Double(charging.filter { $0 }.count) / Double(charging.count) >= 0.5 { add(7, "충전 중") }
        let screen = inside.compactMap(\.screenIsOn)
        if !screen.isEmpty {
            let off = Double(screen.filter { !$0 }.count) / Double(screen.count)
            add(off >= 0.9 ? 8 : off < 0.6 ? -10 : 0, off >= 0.9 ? "화면 꺼짐" : "화면 켜짐")
        }
        if inside.allSatisfy({ $0.isAtHome == nil }) { factors.append("위치 없음") }

        return Verdict(interval: candidate, score: score, isSleep: score >= threshold, factors: factors)
    }

    /// 깨어 있던 근거로 밤을 자른 조각 가운데 3시간 이상인 것.
    static func quietSpans(_ signals: Signals) -> [ClassifierInterval] {
        // 순간 표시(길이 0, 휴대폰을 집어 든 순간)도 경계가 되도록 합치지 않고 잘라 쓴다.
        let night = signals.night
        let wakes = signals.wakeEvents
            .filter { $0.end >= night.start && $0.start <= night.end }
            .map { ClassifierInterval(start: max($0.start, night.start), end: min($0.end, night.end)) }
            .sorted { $0.start < $1.start }
        var cursor = night.start
        var spans: [ClassifierInterval] = []
        for wake in wakes + [ClassifierInterval(start: night.end, end: night.end)] {
            if wake.start.timeIntervalSince(cursor) >= minimumDuration {
                spans.append(ClassifierInterval(start: cursor, end: wake.start))
            }
            cursor = max(cursor, wake.end)
        }
        return spans
    }

    /// 후보가 평소 수면 시간대(앞뒤 1시간 여유)와 겹치는 비율.
    static func nightOverlap(_ candidate: ClassifierInterval, window: UsualWindow, calendar: Calendar) -> Double {
        let day = calendar.startOfDay(for: candidate.start)
        var total: TimeInterval = 0
        // 후보가 자정을 넘길 수 있다. 평소 취침이 자정 뒤면 당일 저녁 시작 후보는 다음 날 창과 겹치니 앞뒤 하루를 모두 본다.
        for offset in [-1, 0, 1] {
            guard let base = calendar.date(byAdding: .day, value: offset, to: day),
                  let bed = calendar.date(byAdding: .minute, value: window.bedMinute - windowSlack, to: base) else { continue }
            let wakeDayOffset = window.wakeMinute <= window.bedMinute ? 1 : 0
            guard let wakeBase = calendar.date(byAdding: .day, value: wakeDayOffset, to: base),
                  let wake = calendar.date(byAdding: .minute, value: window.wakeMinute + windowSlack, to: wakeBase),
                  wake > bed else { continue }
            total += candidate.overlap(with: ClassifierInterval(start: bed, end: wake))
        }
        return candidate.duration > 0 ? min(1, total / candidate.duration) : 0
    }

    /// 워치·HealthKit으로 잰 지난 밤들에서 평소 잠드는·깨는 시각을 배운다. 3밤보다 적으면 nil.
    public static func usualWindow(pastSleeps: [ClassifierInterval], calendar: Calendar = .autoupdatingCurrent) -> UsualWindow? {
        let nights = pastSleeps.filter { $0.duration >= minimumDuration }
        guard nights.count >= 3 else { return nil }
        // 정오 기준으로 재야 자정을 사이에 둔 취침 시각의 가운데 값이 맞다.
        func minuteFromNoon(_ date: Date) -> Int {
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            return ((parts.hour ?? 0) * 60 + (parts.minute ?? 0) + 12 * 60) % 1_440
        }
        func median(_ values: [Int]) -> Int { values.sorted()[values.count / 2] }
        let bed = (median(nights.map { minuteFromNoon($0.start) }) + 12 * 60) % 1_440
        let wake = (median(nights.map { minuteFromNoon($0.end) }) + 12 * 60) % 1_440
        return UsualWindow(bedMinute: bed, wakeMinute: wake, isLearned: true)
    }
}
