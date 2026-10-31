import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

final class MapHomeMapRenderCache {
    private let subway = MapHomeSubwayRouteCache()
    private(set) var visibleExpectedRouteOverlays: [MapHomeExpectedRouteOverlay]?
    private(set) var visibleExpectedRouteCutoff: Date?
    private(set) var routeBounds: MapHomeRouteCoordinateBounds?

    /// 지하철 구간이 새로 풀리면 "경로 전체 보기" 범위를 다시 계산하게 한다(ARC1030A01).
    func invalidateRouteBounds() { routeBounds = nil }
    private var transitBoardingCandidateCache:
        (key: MapHomeTransitBoardingCandidateCacheKey, candidates: [TransitBoardingCandidate])?
    private var gradientSliceCache: [String: (key: Int, slices: [MapHomeRouteGradientSlice]?)] = [:]
    private static let gradientSliceCacheLimit = 32

    /// 경로의 속도 그라데이션 구간. 지오메트리 서명과 시각이 같으면 다시 계산하지 않는다.
    func gradientSlices(
        id: String,
        coordinates: [CLLocationCoordinate2D],
        geometrySignature: Int,
        timestamps: [Date]
    ) -> [MapHomeRouteGradientSlice]? {
        var hasher = Hasher()
        hasher.combine(geometrySignature)
        hasher.combine(timestamps.count)
        hasher.combine(timestamps.first)
        hasher.combine(timestamps.last)
        let key = hasher.finalize()
        if let cached = gradientSliceCache[id], cached.key == key {
            return cached.slices
        }
        let slices = MapHomeRouteGradientSlicer.slices(
            overlayID: id,
            coordinates: coordinates,
            timestamps: timestamps
        )
        if gradientSliceCache.count >= Self.gradientSliceCacheLimit {
            gradientSliceCache.removeAll(keepingCapacity: true)
        }
        gradientSliceCache[id] = (key, slices)
        return slices
    }

    func invalidateRouteData() {
        gradientSliceCache.removeAll(keepingCapacity: true)
        subway.invalidate()
        visibleExpectedRouteOverlays = nil
        visibleExpectedRouteCutoff = nil
        routeBounds = nil
        transitBoardingCandidateCache = nil
    }

    func transitBoardingCandidates(
        key: MapHomeTransitBoardingCandidateCacheKey,
        make: () -> [TransitBoardingCandidate]
    ) -> [TransitBoardingCandidate] {
        if let cached = transitBoardingCandidateCache,
           cached.key == key {
            return cached.candidates
        }
        let candidates = make()
        transitBoardingCandidateCache = (key, candidates)
        return candidates
    }

    func invalidateExpectedRoutes() {
        visibleExpectedRouteOverlays = nil
        visibleExpectedRouteCutoff = nil
        routeBounds = nil
    }

    func restoreSubwayRoutes(
        day: Date,
        minute: Int,
        overlays: [MapHomeSubwayRouteOverlay]
    ) {
        subway.restore(day: day, overlays: overlays)
        routeBounds = nil
    }

    func subwayRoutes(
        day: Date,
        minute: Int,
        sourceRevision: UInt64?,
        make: () -> [MapHomeSubwayRouteOverlay]
    ) -> [MapHomeSubwayRouteOverlay] {
        subway.routes(day: day, minute: minute, sourceRevision: sourceRevision) {
            routeBounds = nil
            return make()
        }
    }

    func visibleExpectedRoutes(
        cutoff: Date,
        make: () -> [MapHomeExpectedRouteOverlay]
    ) -> [MapHomeExpectedRouteOverlay] {
        if visibleExpectedRouteCutoff == cutoff,
           let visibleExpectedRouteOverlays {
            return visibleExpectedRouteOverlays
        }
        let overlays = make()
        visibleExpectedRouteCutoff = cutoff
        visibleExpectedRouteOverlays = overlays
        routeBounds = nil
        return overlays
    }

    func bounds(
        timeline: [MapHomeTimelineRouteOverlay],
        expected: [MapHomeExpectedRouteOverlay],
        generated: [MapHomeWBSGeneratedRouteOverlay],
        subway: [MapHomeSubwayRouteOverlay],
        current: CLLocationCoordinate2D?
    ) -> MapHomeRouteCoordinateBounds? {
        if let routeBounds { return routeBounds }
        var bounds = MapHomeRouteCoordinateBounds()
        timeline.forEach { bounds.include($0.coordinates) }
        expected.forEach { bounds.include($0.coordinates) }
        generated.forEach { bounds.include($0.coordinates) }
        subway.forEach { bounds.include($0.coordinates) }
        if bounds.isEmpty, let current {
            bounds.include([current])
        }
        routeBounds = bounds.isEmpty ? nil : bounds
        return routeBounds
    }
}
