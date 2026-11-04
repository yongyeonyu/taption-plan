import CoreLocation
import Foundation
@preconcurrency import MapLibre
import SwiftUI
import UIKit

/// 영상 프레임 위에 그리는 것. 없으면 렌더러는 지금까지처럼 화랑이를 정중앙에 둔다.
@MainActor
protocol MapHomePlaybackVideoOverlay: AnyObject {
    func stickman(atSecond second: Double) -> MapHomePlaybackVideoStickman?
    func markerCoordinate(atSecond second: Double) -> CLLocationCoordinate2D?
    /// 화랑이 아래(경로선).
    func drawBelowMarker(atSecond second: Double, mapView: MLNMapView, size: CGSize, context: CGContext)
    /// 화랑이 위(날짜·거리).
    func drawAboveMarker(atSecond second: Double, size: CGSize)
}

/// 여행 영상의 경로선·날짜·거리(PLR1104A01). 타일을 건드리지 않고 프레임마다 지도 위에 직접 그린다.
@MainActor
final class MapHomeRangeVideoOverlay: MapHomePlaybackVideoOverlay {
    /// 이 시간(영상 초) 안에 지나온 길은 진하게, 그 전은 흐리게 그린다.
    private static let recentSeconds = 6.0

    private let plan: MapHomeRangeTripPlan
    private let language: MapHomeLanguage
    private let accessoryID: String?
    private let lineColor = UIColor(Color.tpAccent)
    private let dateFormatter: DateFormatter
    private var cachedDate: (day: Int, text: String)?

    init(plan: MapHomeRangeTripPlan, language: MapHomeLanguage, accessoryID: String?) {
        self.plan = plan
        self.language = language
        self.accessoryID = accessoryID
        dateFormatter = DateFormatter()
        dateFormatter.setLocalizedDateFormatFromTemplate("MMMd")
    }

    func stickman(atSecond second: Double) -> MapHomePlaybackVideoStickman? {
        guard let position = plan.position(atSecond: min(second, plan.bodySeconds)) else { return nil }
        return MapHomePlaybackVideoStickman(
            action: Self.action(position),
            speedMetersPerSecond: position.kind == .stay ? 0 : position.speed,
            equippedAccessoryID: accessoryID
        )
    }

    /// 이동 수단 판정 없이 평균 속도로만 고른다. 원본 기록을 바꾸지 않는 영상용 표시다.
    static func action(_ position: MapHomeRangeTripPlan.Position) -> MapHomeStickmanAction {
        switch position.kind {
        case .stay: .restLoaf
        case .flight: .airplane
        case .move: position.speed >= 5.5 ? .car : .walking
        }
    }

    func markerCoordinate(atSecond second: Double) -> CLLocationCoordinate2D? {
        plan.position(atSecond: min(second, plan.bodySeconds)).map {
            CLLocationCoordinate2D(latitude: $0.point.latitude, longitude: $0.point.longitude)
        }
    }

    func drawBelowMarker(atSecond second: Double, mapView: MLNMapView, size: CGSize, context: CGContext) {
        let route = plan.route
        guard !route.isEmpty else { return }
        let isOverview = second >= plan.bodySeconds
        let end = Self.lastIndex(in: route, atOrBefore: second)
        guard end >= 0 else { return }
        let recentStart = isOverview ? 0 : Self.lastIndex(in: route, atOrBefore: second - Self.recentSeconds)
        let current = isOverview ? nil : markerCoordinate(atSecond: second)
        let older = CGMutablePath(), recent = CGMutablePath()
        var previousLongitude: Double?
        for index in 0...end {
            let point = route[index]
            let location = mapView.convert(
                CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
                toPointTo: mapView
            )
            // 날짜변경선을 넘는 곳에서는 선을 끊는다. 이으면 지도를 가로지른다.
            let startsLine = previousLongitude.map { abs(point.longitude - $0) > 180 } ?? true
            previousLongitude = point.longitude
            if index <= recentStart {
                if startsLine { older.move(to: location) } else { older.addLine(to: location) }
            }
            if index >= recentStart {
                if startsLine || index == recentStart { recent.move(to: location) } else { recent.addLine(to: location) }
            }
        }
        if let current, !recent.isEmpty {
            recent.addLine(to: mapView.convert(current, toPointTo: mapView))
        }
        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)
        stroke(older, alpha: 0.55, context: context)
        stroke(recent, alpha: 1, context: context)
        context.restoreGState()
    }

    private func stroke(_ path: CGPath, alpha: CGFloat, context: CGContext) {
        guard !path.isEmpty else { return }
        context.addPath(path)
        context.setStrokeColor(UIColor.white.withAlphaComponent(alpha * 0.9).cgColor)
        context.setLineWidth(5)
        context.strokePath()
        context.addPath(path)
        context.setStrokeColor(lineColor.withAlphaComponent(alpha).cgColor)
        context.setLineWidth(3)
        context.strokePath()
    }

    private static func lastIndex(in route: [MapHomeRangeTripPlan.RoutePoint], atOrBefore second: Double) -> Int {
        var lower = 0, upper = route.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if route[middle].second <= second { lower = middle + 1 } else { upper = middle }
        }
        return lower - 1
    }

    func drawAboveMarker(atSecond second: Double, size: CGSize) {
        guard let position = plan.position(atSecond: min(second, plan.bodySeconds)) else { return }
        let title = dateText(position.time)
        let detail = AppRegion.current.longDistanceText(meters: position.meters)
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 15, weight: .bold), .foregroundColor: UIColor.white,
        ]
        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: UIColor.white.withAlphaComponent(0.9),
        ]
        let titleSize = (title as NSString).size(withAttributes: titleAttributes)
        let detailSize = (detail as NSString).size(withAttributes: detailAttributes)
        let rect = CGRect(x: 16, y: 34, width: max(titleSize.width, detailSize.width) + 24, height: titleSize.height + detailSize.height + 16)
        UIColor.black.withAlphaComponent(0.55).setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: 12).fill()
        (title as NSString).draw(at: CGPoint(x: rect.minX + 12, y: rect.minY + 7), withAttributes: titleAttributes)
        (detail as NSString).draw(at: CGPoint(x: rect.minX + 12, y: rect.minY + 8 + titleSize.height), withAttributes: detailAttributes)
    }

    private func dateText(_ time: TimeInterval) -> String {
        let date = Date(timeIntervalSinceReferenceDate: time)
        let day = Calendar.autoupdatingCurrent.ordinality(of: .day, in: .era, for: date) ?? 0
        if let cachedDate, cachedDate.day == day { return cachedDate.text }
        let text = dateFormatter.string(from: date)
        cachedDate = (day, text)
        return text
    }
}
