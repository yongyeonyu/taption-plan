import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

enum MapHomeWeatherTimelineMath {
    static let fullDayTemperatureChangeCelsius = 2

    static func context(
        at date: Date,
        contexts: [WeatherContext],
        calendar: Calendar = .autoupdatingCurrent
    ) -> WeatherContext? {
        displayContexts(contexts, calendar: calendar)
            .filter { $0.observedAt <= date }
            .max { $0.observedAt < $1.observedAt }
    }

    static func persistentSpans(
        for date: Date,
        contexts: [WeatherContext],
        calendar: Calendar = .autoupdatingCurrent,
        minimumTemperatureChangeCelsius: Int = 0
    ) -> [(context: WeatherContext, span: TimeSpan)] {
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? date
        let ordered = displayContexts(contexts, calendar: calendar)
        var displayRuns: [(context: WeatherContext, start: Date)] = []
        var lastDisplayedContext: WeatherContext?

        for context in ordered {
            guard let lastIndex = displayRuns.indices.last else {
                displayRuns.append((context: context, start: context.observedAt))
                lastDisplayedContext = context
                continue
            }
            if !startsNewDisplayRun(
                from: lastDisplayedContext ?? displayRuns[lastIndex].context,
                to: context,
                minimumTemperatureChangeCelsius: minimumTemperatureChangeCelsius
            ) {
                if minimumTemperatureChangeCelsius == 0 {
                    displayRuns[lastIndex].context = context
                }
            } else {
                displayRuns.append((context: context, start: context.observedAt))
                lastDisplayedContext = context
            }
        }

        return displayRuns.enumerated().compactMap { index, run in
            let nextObservedAt = index + 1 < displayRuns.count
                ? displayRuns[index + 1].start
                : dayEnd
            let start = max(run.start, dayStart)
            let end = min(
                max(nextObservedAt, run.start.addingTimeInterval(1)),
                dayEnd
            )
            guard start < end, start < dayEnd, end > dayStart else { return nil }
            return (context: run.context, span: TimeSpan(start: start, end: end))
        }
    }

    private static func displayContexts(
        _ contexts: [WeatherContext],
        calendar: Calendar
    ) -> [WeatherContext] {
        let ordered = coalescedDisplayContexts(contexts).sorted {
            if $0.observedAt != $1.observedAt {
                return $0.observedAt < $1.observedAt
            }
            if ($0.isForecast == true) != ($1.isForecast == true) {
                return $0.isForecast != true
            }
            if $0.fetchedAt != $1.fetchedAt {
                return ($0.fetchedAt ?? .distantPast)
                    < ($1.fetchedAt ?? .distantPast)
            }
            return $0.id.uuidString < $1.id.uuidString
        }
        var result: [(bucket: Date, context: WeatherContext)] = []
        result.reserveCapacity(ordered.count)
        for context in ordered {
            let bucket = calendar.dateInterval(
                of: .minute,
                for: context.observedAt
            )?.start ?? context.observedAt
            guard let lastIndex = result.indices.last,
                  result[lastIndex].bucket == bucket else {
                result.append((bucket: bucket, context: context))
                continue
            }
            let current = result[lastIndex].context
            if prefersForDisplay(context, over: current) {
                result[lastIndex].context = context
            }
        }
        return result.map(\.context)
    }

    static func coalescedDisplayContexts(
        _ contexts: [WeatherContext]
    ) -> [WeatherContext] {
        (
            WeatherTimelineEngine.coalesced(
                contexts.filter { $0.isForecast != true }
            )
            + WeatherTimelineEngine.coalesced(
                contexts.filter { $0.isForecast == true }
            )
        ).sorted {
            if $0.observedAt != $1.observedAt {
                return $0.observedAt < $1.observedAt
            }
            if ($0.isForecast == true) != ($1.isForecast == true) {
                return $0.isForecast != true
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private static func prefersForDisplay(
        _ candidate: WeatherContext,
        over current: WeatherContext
    ) -> Bool {
        if ((candidate.isForecast == true) != (current.isForecast == true)) {
            return candidate.isForecast != true
        }
        if candidate.observedAt != current.observedAt {
            return candidate.observedAt > current.observedAt
        }
        if candidate.fetchedAt != current.fetchedAt {
            return (candidate.fetchedAt ?? .distantPast)
                > (current.fetchedAt ?? .distantPast)
        }
        return candidate.id.uuidString > current.id.uuidString
    }

    private static func startsNewDisplayRun(
        from previous: WeatherContext,
        to current: WeatherContext,
        minimumTemperatureChangeCelsius: Int
    ) -> Bool {
        guard previous.symbolName == current.symbolName else { return true }

        let previousTemperature = Int(previous.temperatureCelsius.rounded())
        let currentTemperature = Int(current.temperatureCelsius.rounded())
        let temperatureChange = abs(currentTemperature - previousTemperature)
        if minimumTemperatureChangeCelsius > 0 {
            return temperatureChange >= minimumTemperatureChangeCelsius
        }
        return temperatureChange != 0
    }
}

enum MapHomeWeatherDisplayCache {
    static func merged(
        cached: [WeatherContext],
        incoming: [WeatherContext]
    ) -> [WeatherContext] {
        let fresh = incoming.filter(MapHomeWeatherDisplayPolicy.isComplete)
        guard !fresh.isEmpty else { return cached }
        return Array(MapHomeWeatherTimelineMath.coalescedDisplayContexts(
            cached + fresh
        ).suffix(maximumContexts))
    }

    private static let maximumContexts = 512

    static func contexts(
        incoming: [WeatherContext],
        cached: [WeatherContext]
    ) -> [WeatherContext] {
        let merged = merged(cached: cached, incoming: incoming)
        return merged.isEmpty ? incoming : merged
    }
}
