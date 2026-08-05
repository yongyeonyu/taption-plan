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
        var cursor = max(sanitizedHighWater(highWater, now: now) ?? floor, floor)
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

/// 조회 결과에 따라 워터마크를 옮기는 규칙.
///
/// 예외로 건너뛴 토막도 끝까지 올린다. 올리지 않으면 다음 실행이 같은
/// 범위를 다시 물어 같은 예외를 영원히 반복한다. 워터마크는 절대 뒤로
/// 가지 않으므로 이미 읽은 구간을 다시 읽지도 않는다.
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
        advance(past: window)
    }

    mutating func failed(_ window: WatchSensorQueryWindow) {
        failureCount += 1
        advance(past: window)
    }

    private mutating func advance(past window: WatchSensorQueryWindow) {
        guard let highWater else {
            highWater = window.end
            return
        }
        self.highWater = max(highWater, window.end)
    }
}
