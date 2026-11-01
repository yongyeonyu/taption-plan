import CoreMotion
import Foundation
import TaptionPlanCore

/// 걸음 측정 응답과 시간 초과 중 먼저 온 쪽으로 한 번만 이어 간다.
private final class PedometerResumeOnce: @unchecked Sendable {
    let lock = NSLock()
    private var continuation: CheckedContinuation<Double?, Never>?

    init(_ continuation: CheckedContinuation<Double?, Never>) { self.continuation = continuation }

    func resume(_ value: Double?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

extension AppModel {
    /// 달력 지표용: 그 달 날짜별 걸음 수. 건강 앱(HealthKit) 일별 합계를 우선하고, 센서 기록의 누적 걸음 수
    /// (그날 최댓값)가 더 크면 그 값을 쓴다. 둘 다 없으면 빈 딕셔너리.
    func calendarDailyStepCounts(month: Date) async -> [Date: Double] {
        let calendar = Calendar.autoupdatingCurrent
        guard let first = calendar.date(from: calendar.dateComponents([.year, .month], from: month)),
              let end = calendar.date(byAdding: .month, value: 1, to: first) else { return [:] }
        let health = (try? await healthService.dailyStepCounts(from: first, to: min(end, .now), calendar: calendar)) ?? [:]
        var sensor: [Date: Double] = [:]
        if let sensorService,
           let readings = try? await sensorService.archivedReadings(in: TimeSpan(start: first, end: end)) {
            for reading in readings {
                guard let steps = reading.stepCount, steps > 0 else { continue }
                let day = calendar.startOfDay(for: reading.timestamp)
                sensor[day] = max(sensor[day] ?? 0, Double(steps))
            }
        }
        // 걸음 수가 0으로 보일 때 원인(건강 앱 값 없음/센서 값 없음)을 로그로 구분할 수 있게 남긴다.
        TaptionPlanDiagnosticsLogger.shared.record(
            "calendar_steps",
            metrics: ["health_days": Double(health.count), "sensor_days": Double(sensor.count)]
        )
        var merged = MapHomeCalendarTimeTotalsPolicy.mergedStepCounts(health: health, sensor: sensor)
        // 오늘 걸음은 센서 기록(활동이 끝나야 저장됨)이 늦어 CMPedometer로 바로 읽는다. 워치 우선이라
        // 건강 앱 합계(워치·아이폰 겹침 정리됨)가 있으면 그것을, 없을 때만 아이폰 실시간 값을 쓴다.
        let today = calendar.startOfDay(for: .now)
        if calendar.isDate(first, equalTo: today, toGranularity: .month),
           let live = await Self.todayPedometerSteps(from: today, calendar: calendar) {
            merged[today] = ClassifierAdapter.todaySteps(health: health[today], liveIPhone: live)
        }
        return merged
    }

    private nonisolated(unsafe) static let todayPedometer = CMPedometer()

    /// 자정부터 지금까지의 걸음 수(CMPedometer). 지원되지 않거나 실패하거나 3초 안에 응답이 없으면 nil.
    /// 측정기를 계속 들고 있어야 응답이 오고, 시간 제한이 없으면 달력 계산이 영원히 멈출 수 있다.
    private nonisolated static func todayPedometerSteps(from start: Date, calendar: Calendar) async -> Double? {
        guard CMPedometer.isStepCountingAvailable() else { return nil }
        return await withCheckedContinuation { continuation in
            let once = PedometerResumeOnce(continuation)
            todayPedometer.queryPedometerData(from: start, to: .now) { data, _ in
                once.resume(data.map { Double($0.numberOfSteps.intValue) })
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { once.resume(nil) }
        }
    }
}
