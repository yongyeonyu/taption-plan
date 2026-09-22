import Foundation

public enum TaptionScalarQualityReason: String, Codable, Hashable, Sendable {
    case nonFinite
    case belowPhysicalMinimum
    case abovePhysicalMaximum
    case isolatedOutlier
}

public struct TaptionScalarQualityDecision: Codable, Hashable, Sendable {
    public let index: Int
    public let acceptedValue: Double?
    public let reason: TaptionScalarQualityReason?

    public init(index: Int, acceptedValue: Double?, reason: TaptionScalarQualityReason?) {
        self.index = index
        self.acceptedValue = acceptedValue
        self.reason = reason
    }

    public var isAccepted: Bool { acceptedValue != nil }
}

public struct TaptionRobustScalarFilterConfiguration: Codable, Hashable, Sendable {
    public var physicalRange: ClosedRange<Double>?
    public var windowRadius: Int
    public var modifiedZScoreThreshold: Double
    public var minimumAbsoluteDeviation: Double
    public var minimumWindowSampleCount: Int

    public init(
        physicalRange: ClosedRange<Double>? = nil,
        windowRadius: Int = 3,
        modifiedZScoreThreshold: Double = 3.5,
        minimumAbsoluteDeviation: Double = 0.01,
        minimumWindowSampleCount: Int = 5
    ) {
        precondition(windowRadius >= 1)
        precondition(modifiedZScoreThreshold > 0)
        precondition(minimumAbsoluteDeviation > 0)
        precondition(minimumWindowSampleCount >= 3)
        self.physicalRange = physicalRange
        self.windowRadius = windowRadius
        self.modifiedZScoreThreshold = modifiedZScoreThreshold
        self.minimumAbsoluteDeviation = minimumAbsoluteDeviation
        self.minimumWindowSampleCount = minimumWindowSampleCount
    }
}

/// A bounded Hampel/modified-z projection. Input values remain untouched; rejected
/// values are represented only in the returned decisions.
public struct TaptionRobustScalarFilter: Sendable {
    public let configuration: TaptionRobustScalarFilterConfiguration

    public init(configuration: TaptionRobustScalarFilterConfiguration = .init()) {
        self.configuration = configuration
    }

    public func decisions(for values: [Double?]) -> [TaptionScalarQualityDecision] {
        decisions(for: values, cancellationCheck: {})
    }

    public func decisions(
        for values: [Double?],
        cancellationCheck: () throws -> Void
    ) rethrows -> [TaptionScalarQualityDecision] {
        var physical: [(value: Double?, reason: TaptionScalarQualityReason?)] = []
        physical.reserveCapacity(values.count)
        for (index, value) in values.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            physical.append(physicalDecision(value))
        }

        var decisions: [TaptionScalarQualityDecision] = []
        decisions.reserveCapacity(values.count)
        for index in values.indices {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            if let rejection = physical[index].reason {
                decisions.append(.init(index: index, acceptedValue: nil, reason: rejection))
                continue
            }
            guard let value = physical[index].value else {
                decisions.append(.init(index: index, acceptedValue: nil, reason: nil))
                continue
            }
            let lower = max(values.startIndex, index - configuration.windowRadius)
            let upper = min(values.endIndex, index + configuration.windowRadius + 1)
            let window = physical[lower..<upper].compactMap(\.value).sorted()
            guard window.count >= configuration.minimumWindowSampleCount else {
                decisions.append(.init(index: index, acceptedValue: value, reason: nil))
                continue
            }
            let median = Self.median(window)
            let deviations = window.map { abs($0 - median) }.sorted()
            let mad = Self.median(deviations)
            let scale = max(configuration.minimumAbsoluteDeviation, 1.4826 * mad)
            let score = abs(value - median) / scale
            if score > configuration.modifiedZScoreThreshold,
               !hasCoherentNeighbor(at: index, value: value, physical: physical) {
                decisions.append(.init(index: index, acceptedValue: nil, reason: .isolatedOutlier))
                continue
            }
            decisions.append(.init(index: index, acceptedValue: value, reason: nil))
        }
        try cancellationCheck()
        return decisions
    }

    public func filteredValues(_ values: [Double?]) -> [Double?] {
        decisions(for: values).map(\.acceptedValue)
    }

    private func physicalDecision(_ value: Double?) -> (value: Double?, reason: TaptionScalarQualityReason?) {
        guard let value else { return (nil, nil) }
        guard value.isFinite else { return (nil, .nonFinite) }
        if let range = configuration.physicalRange {
            if value < range.lowerBound { return (nil, .belowPhysicalMinimum) }
            if value > range.upperBound { return (nil, .abovePhysicalMaximum) }
        }
        return (value, nil)
    }

    private func hasCoherentNeighbor(
        at index: Int,
        value: Double,
        physical: [(value: Double?, reason: TaptionScalarQualityReason?)]
    ) -> Bool {
        let tolerance = max(
            configuration.minimumAbsoluteDeviation * configuration.modifiedZScoreThreshold,
            abs(value) * 0.05
        )
        for neighbor in [index - 1, index + 1]
            where physical.indices.contains(neighbor) {
            if let candidate = physical[neighbor].value,
               abs(candidate - value) <= tolerance {
                return true
            }
        }
        return false
    }

    private static func median(_ sorted: [Double]) -> Double {
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}
