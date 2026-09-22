import Foundation

enum RouteLongitude {
    static func shortestDelta(from start: Double, to end: Double) -> Double {
        let delta = (end - start).truncatingRemainder(dividingBy: 360)
        if delta > 180 { return delta - 360 }
        if delta < -180 { return delta + 360 }
        return delta
    }

    static func interpolate(from start: Double, to end: Double, fraction: Double) -> Double {
        normalized(start + shortestDelta(from: start, to: end) * fraction)
    }

    static func normalized(_ longitude: Double) -> Double {
        let value = longitude.truncatingRemainder(dividingBy: 360)
        if value > 180 { return value - 360 }
        if value < -180 { return value + 360 }
        return value
    }
}

enum RouteCancellableSort {
    static func sorted<Element>(
        _ values: [Element],
        by precedes: (Element, Element) -> Bool,
        cancellationCheck: () throws -> Void
    ) rethrows -> [Element] {
        try cancellationCheck()
        guard values.count > 1 else { return values }

        var source = values
        var destination = values
        var width = 1
        var operations = 0
        while width < values.count {
            var start = 0
            while start < values.count {
                let middle = start + min(width, values.count - start)
                let end = middle + min(width, values.count - middle)
                var left = start
                var right = middle
                var output = start
                while output < end {
                    operations += 1
                    if operations.isMultiple(of: 256) { try cancellationCheck() }
                    if left < middle,
                       right == end || !precedes(source[right], source[left]) {
                        destination[output] = source[left]
                        left += 1
                    } else {
                        destination[output] = source[right]
                        right += 1
                    }
                    output += 1
                }
                start = end
            }
            swap(&source, &destination)
            width = width > values.count / 2 ? values.count : width * 2
        }
        try cancellationCheck()
        return source
    }
}
