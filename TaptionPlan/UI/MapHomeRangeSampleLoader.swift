import Foundation

/// 여러 날 영상이 쓰는 위치 표본 읽기. 경로 영상과 도시 여행 지도 영상이 같은 길로 읽는다(TRV1108A01).
///
/// 하루씩 읽어 줄인 표본만 남긴다. 여러 날의 `SensorReading`을 한꺼번에 메모리에 두지 않는다.
/// 판독이 없는 날은 저장된 이동·장소로 경로를 지어내지 않고 날 수만 센다. 한 번 읽은 날은 캐시에서 연다.
@MainActor
enum MapHomeRangeSampleLoader {
    struct Loaded {
        let span: TimeSpan
        let samples: [MapHomeRangeTripPlan.Sample]
        let missing: Int
    }

    /// 취소되면 nil. `progress`는 0...100 정수다.
    static func read(
        model: AppModel, span: TimeSpan, calendar: Calendar = .autoupdatingCurrent, progress: (Int) -> Void
    ) async -> Loaded? {
        let days = max(1, Int((span.duration / 86_400).rounded(.up)))
        var samples: [MapHomeRangeTripPlan.Sample] = []
        var missing = 0
        var dayIndex = 0
        var dayStart = span.start
        var lastPercent = -1
        while dayStart < span.end {
            let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: dayStart)) ?? span.end
            let daySamples: [MapHomeRangeTripPlan.Sample]
            if let cached = await cachedSamples(dayStart: dayStart, calendar: calendar) {
                daySamples = cached
            } else {
                let loaded = await model.routeReadingsForRange(in: TimeSpan(start: dayStart, end: min(next, span.end)))
                daySamples = await thinnedSamples(from: loaded.readings)
                if Task.isCancelled { return nil }
                await storeSamples(daySamples, dayStart: dayStart, calendar: calendar)
            }
            if Task.isCancelled { return nil }
            samples += daySamples
            if daySamples.isEmpty { missing += 1 }
            dayIndex += 1
            let percent = min(100, dayIndex * 100 / days)
            if percent != lastPercent {
                lastPercent = percent
                progress(percent)
            }
            dayStart = next
        }
        return Loaded(span: span, samples: samples, missing: missing)
    }

    /// 주 스레드 밖에서 하루치를 표본으로 줄인다.
    private nonisolated static func thinnedSamples(from readings: [SensorReading]) async -> [MapHomeRangeTripPlan.Sample] {
        MapHomeRangeTripPlan.thinned(
            MapHomeRangeTripPlan.samples(from: readings).sorted { $0.time < $1.time }
        )
    }

    private nonisolated static func cachedSamples(dayStart: Date, calendar: Calendar) async -> [MapHomeRangeTripPlan.Sample]? {
        MapHomeRangeSampleCache.read(dayStart: dayStart, calendar: calendar)
    }

    private nonisolated static func storeSamples(
        _ samples: [MapHomeRangeTripPlan.Sample], dayStart: Date, calendar: Calendar
    ) async {
        guard MapHomeRangeSampleCache.isCacheable(dayStart: dayStart, now: .now, calendar: calendar) else { return }
        MapHomeRangeSampleCache.write(samples, dayStart: dayStart, calendar: calendar)
    }
}
