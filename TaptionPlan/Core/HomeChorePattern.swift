import Foundation

/// 집에서 여러 번 나눠 움직인 패턴(HSW1103A01). 움직일 때 표본이 더 쌓이므로 개수가 아니라 시간으로 잰다.
/// 한 번의 긴 걷기, 화면을 보며 움직인 시간, 심야는 집안일 근거로 쓰지 않는다.
enum HomeChorePattern {
    struct Assessment: Equatable, Sendable {
        var score: Double
        var evidence: String
    }

    private static let maximumSampleGap: TimeInterval = 90
    private static let minimumBout: TimeInterval = 20
    private static let minimumBouts = 3
    private static let minimumActive: TimeInterval = 5 * 60
    private static let minimumShare = 0.15
    private static let longestBoutShare = 0.7
    private static let maximumScreenShare = 0.5

    private static func isActive(_ reading: SensorReading) -> Bool {
        if reading.motion == .walking || reading.motion == .running || reading.motion == .cycling { return true }
        guard let summary = reading.deviceMotionSummary else { return false }
        return summary.userAccelerationStandardDeviationG >= 0.015 || summary.peakUserAccelerationG >= 0.12
    }

    static func assess(_ readings: [SensorReading], in stay: TimeSpan, calendar: Calendar) -> Assessment? {
        let hour = calendar.component(.hour, from: stay.start)
        let endHour = calendar.component(.hour, from: stay.end)
        // 밤을 넘기는 체류나 심야 체류는 잠자리 뒤척임과 가를 수 없다.
        guard (6..<24).contains(hour), (6..<24).contains(endHour), stay.duration > 0 else { return nil }
        let inside = readings.filter { stay.contains($0.timestamp) }.sorted { $0.timestamp < $1.timestamp }
        var bouts: [TimeInterval] = []
        var boutStart: Date?
        var boutLast: Date?
        var screenOn = 0, activeCount = 0
        func close() {
            if let start = boutStart, let last = boutLast, last.timeIntervalSince(start) >= minimumBout {
                bouts.append(last.timeIntervalSince(start))
            }
            boutStart = nil
            boutLast = nil
        }
        for reading in inside {
            guard isActive(reading) else {
                if let last = boutLast, reading.timestamp.timeIntervalSince(last) > maximumSampleGap { close() }
                continue
            }
            activeCount += 1
            if reading.screenIsOn == true { screenOn += 1 }
            if let last = boutLast, reading.timestamp.timeIntervalSince(last) > maximumSampleGap { close() }
            if boutStart == nil { boutStart = reading.timestamp }
            boutLast = reading.timestamp
        }
        close()
        let active = bouts.reduce(0, +)
        guard bouts.count >= minimumBouts, active >= minimumActive,
              active / stay.duration >= minimumShare,
              (bouts.max() ?? 0) / active <= longestBoutShare,
              activeCount > 0, Double(screenOn) / Double(activeCount) <= maximumScreenShare else { return nil }
        let score = min(0.72, 0.5 + 0.02 * Double(bouts.count) + 0.1 * min(1, active / stay.duration))
        return Assessment(score: score, evidence: "집에서 \(bouts.count)번 나눠 움직임 \(Int(active / 60))분")
    }
}
