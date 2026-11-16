import Foundation
import TaptionPlanEngine

extension TaptionActivityEngineAdapter {
    static func matchingTravelIndices(
        for readings: [SensorReading],
        travel: [TravelSegment]
    ) -> (indices: [Int?], operationCount: Int) {
        do {
            return try matchingTravelIndices(
                for: readings,
                travel: travel,
                cancellationCheck: {}
            )
        } catch {
            preconditionFailure("Unexpected travel indexing cancellation: \(error)")
        }
    }

    static func matchingTravelIndices(
        for readings: [SensorReading],
        travel: [TravelSegment],
        cancellationCheck: () throws -> Void
    ) throws -> (indices: [Int?], operationCount: Int) {
        try cancellationCheck()
        var operationCount = 0
        guard !readings.isEmpty else { return ([], operationCount) }
        if travel.isEmpty {
            var matches: [Int?] = []
            matches.reserveCapacity(readings.count)
            for _ in readings.indices {
                try recordWork(&operationCount, cancellationCheck: cancellationCheck)
                matches.append(nil)
            }
            try cancellationCheck()
            return (matches, operationCount)
        }

        var orderedReadings: [Int] = []
        orderedReadings.reserveCapacity(readings.count)
        for index in readings.indices {
            try recordWork(&operationCount, cancellationCheck: cancellationCheck)
            if !readings[index].timestamp.timeIntervalSinceReferenceDate.isNaN {
                orderedReadings.append(index)
            }
        }
        orderedReadings = try cancellableSort(
            orderedReadings,
            operationCount: &operationCount,
            cancellationCheck: cancellationCheck
        ) { lhs, rhs in
            let lhsTimestamp = readings[lhs].timestamp
            let rhsTimestamp = readings[rhs].timestamp
            if lhsTimestamp != rhsTimestamp { return lhsTimestamp < rhsTimestamp }
            return lhs < rhs
        }

        // NaN 경계 구간은 어떤 판독과도 매칭하지 않는다(TimeSpan.contains와 같은 규칙).
        var intervalStarts: [Date] = []
        var intervalEnds: [Date] = []
        intervalStarts.reserveCapacity(travel.count)
        intervalEnds.reserveCapacity(travel.count)
        var travelIndices: [Int] = []
        travelIndices.reserveCapacity(travel.count)
        for index in travel.indices {
            try recordWork(&operationCount, cancellationCheck: cancellationCheck)
            let span = travel[index].span
            intervalStarts.append(span.start)
            intervalEnds.append(span.end)
            if !span.isNaNBounded { travelIndices.append(index) }
        }
        let orderedTravel = try cancellableSort(
            travelIndices,
            operationCount: &operationCount,
            cancellationCheck: cancellationCheck
        ) { lhs, rhs in
            if intervalStarts[lhs] != intervalStarts[rhs] {
                return intervalStarts[lhs] < intervalStarts[rhs]
            }
            return lhs < rhs
        }

        var matches: [Int?] = []
        matches.reserveCapacity(readings.count)
        for _ in readings.indices {
            try recordWork(&operationCount, cancellationCheck: cancellationCheck)
            matches.append(nil)
        }
        guard !orderedReadings.isEmpty else {
            try cancellationCheck()
            return (matches, operationCount)
        }

        var active = TravelMatchHeap()
        var nextTravel = 0

        for readingIndex in orderedReadings {
            try recordWork(&operationCount, cancellationCheck: cancellationCheck)
            let timestamp = readings[readingIndex].timestamp
            while nextTravel < orderedTravel.count {
                try recordWork(&operationCount, cancellationCheck: cancellationCheck)
                let travelIndex = orderedTravel[nextTravel]
                guard intervalStarts[travelIndex] <= timestamp else { break }
                try active.insert(
                    travelIndex,
                    operationCount: &operationCount,
                    cancellationCheck: cancellationCheck
                )
                nextTravel += 1
            }
            while let first = active.minimum {
                try recordWork(&operationCount, cancellationCheck: cancellationCheck)
                guard intervalEnds[first] < timestamp else { break }
                try active.removeMinimum(
                    operationCount: &operationCount,
                    cancellationCheck: cancellationCheck
                )
            }
            matches[readingIndex] = active.minimum
            try recordWork(&operationCount, cancellationCheck: cancellationCheck)
        }
        try cancellationCheck()
        return (matches, operationCount)
    }

    static func recordWork(
        _ operationCount: inout Int,
        cancellationCheck: () throws -> Void
    ) rethrows {
        operationCount += 1
        if operationCount == 1 || operationCount.isMultiple(of: 256) {
            try cancellationCheck()
        }
    }

    static func cancellableSort<Element>(
        _ values: [Element],
        operationCount: inout Int,
        cancellationCheck: () throws -> Void,
        by areInIncreasingOrder: (Element, Element) -> Bool
    ) rethrows -> [Element] {
        guard values.count > 1 else {
            try cancellationCheck()
            return values
        }

        var source = values
        var destination = values
        var width = 1
        while width < values.count {
            var lower = 0
            while lower < values.count {
                let middle = min(lower + width, values.count)
                let upper = min(middle + width, values.count)
                var left = lower
                var right = middle
                var output = lower
                while output < upper {
                    try recordWork(&operationCount, cancellationCheck: cancellationCheck)
                    if left < middle,
                       right >= upper || !areInIncreasingOrder(source[right], source[left]) {
                        destination[output] = source[left]
                        left += 1
                    } else {
                        destination[output] = source[right]
                        right += 1
                    }
                    output += 1
                }
                lower = upper
            }
            swap(&source, &destination)
            width = width > values.count / 2 ? values.count : width * 2
        }
        try cancellationCheck()
        return source
    }

    private struct TravelMatchHeap {
        private var indices: [Int] = []

        var minimum: Int? { indices.first }

        mutating func insert(
            _ index: Int,
            operationCount: inout Int,
            cancellationCheck: () throws -> Void
        ) rethrows {
            indices.append(index)
            var child = indices.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                try TaptionActivityEngineAdapter.recordWork(
                    &operationCount,
                    cancellationCheck: cancellationCheck
                )
                guard indices[parent] > indices[child] else { break }
                indices.swapAt(parent, child)
                child = parent
            }
        }

        mutating func removeMinimum(
            operationCount: inout Int,
            cancellationCheck: () throws -> Void
        ) rethrows {
            guard !indices.isEmpty else { return }
            let last = indices.removeLast()
            guard !indices.isEmpty else { return }
            indices[0] = last

            var parent = 0
            while true {
                let left = parent * 2 + 1
                guard left < indices.count else { break }
                let right = left + 1
                var child = left
                if right < indices.count {
                    try TaptionActivityEngineAdapter.recordWork(
                        &operationCount,
                        cancellationCheck: cancellationCheck
                    )
                    if indices[right] < indices[left] { child = right }
                }
                try TaptionActivityEngineAdapter.recordWork(
                    &operationCount,
                    cancellationCheck: cancellationCheck
                )
                guard indices[parent] > indices[child] else { break }
                indices.swapAt(parent, child)
                parent = child
            }
        }
    }
}
