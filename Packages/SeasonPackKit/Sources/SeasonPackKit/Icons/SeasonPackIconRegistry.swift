import CoreGraphics
import Foundation

/// 지금 지도에 붙일 아이콘 하나(위치까지 정해진 것).
public struct SeasonPackPlacedIcon: Identifiable, Sendable, Equatable {
    public var id: String { "\(packID)/\(icon.id)" }
    public var packID: String
    public var icon: SeasonPackManifest.MenuIcon
    /// 집 아이콘 기준 상대 위치(pt). 겹침을 밀어낸 뒤의 값.
    public var offset: CGPoint
}

/// 이벤트 아이콘 레지스트리: 앱은 어떤 이벤트인지 모른다. 켜진 팩의 `menuIcons[]`를 그대로 읽어 줄 뿐이다.
public enum SeasonPackIconRegistry {
    public static let spacing: CGFloat = 44

    /// 보임 구간 안(없으면 팩이 켜져 있는 동안)이고 메뉴에 보일 항목이 있는 아이콘만, 우선순위 순으로 겹치지 않게 놓는다.
    /// 구간 밖이면 뷰 자체를 만들지 않으므로 목록에 넣지 않는다. `origin`·`bounds`(화면 좌표)가 있으면 화면 밖으로 나가는 쪽을 위·아래로 접는다.
    public static func visibleIcons(
        packs: [SeasonPack], now: Date, language: String, calendar: Calendar = .current,
        origin: CGPoint = .zero, bounds: CGRect? = nil
    ) -> [SeasonPackPlacedIcon] {
        let candidates = packs.flatMap { pack in
            (pack.manifest.menuIcons ?? []).map { (pack.id, $0) }
        }.filter { _, icon in
            isVisible(icon, now: now, calendar: calendar) && !SeasonPackMenuModel(icon.menu, language: language).isEmpty
        }.sorted { a, b in
            if (a.1.priority ?? 0) != (b.1.priority ?? 0) { return (a.1.priority ?? 0) > (b.1.priority ?? 0) }
            return "\(a.0)/\(a.1.id)" < "\(b.0)/\(b.1.id)"
        }
        var placed: [SeasonPackPlacedIcon] = []
        for (packID, icon) in candidates {
            let point = free(CGPoint(x: icon.anchor.dx, y: icon.anchor.dy), taken: placed.map(\.offset), origin: origin, bounds: bounds)
            placed.append(SeasonPackPlacedIcon(packID: packID, icon: icon, offset: point))
        }
        return placed
    }

    public static func isVisible(_ icon: SeasonPackManifest.MenuIcon, now: Date, calendar: Calendar = .current) -> Bool {
        if let from = icon.visibleFrom.flatMap({ SeasonPackDateParsing.localDateTime($0, calendar: calendar) }), now < from { return false }
        if let text = icon.visibleTo, let to = SeasonPackDateParsing.localDateTime(text, calendar: calendar) {
            let end = text.contains("T") ? to.addingTimeInterval(60) : (calendar.date(byAdding: .day, value: 1, to: to) ?? to)
            if now >= end { return false }
        }
        return true
    }

    /// 다른 아이콘과 겹치면 44pt씩 아래로 민다. 화면 밖으로 나가면 위로 접는다.
    static func free(_ start: CGPoint, taken: [CGPoint], origin: CGPoint, bounds: CGRect?) -> CGPoint {
        func collides(_ p: CGPoint) -> Bool {
            taken.contains { abs($0.x - p.x) < spacing && abs($0.y - p.y) < spacing }
        }
        func inside(_ p: CGPoint) -> Bool {
            guard let bounds else { return true }
            return bounds.insetBy(dx: spacing / 2, dy: spacing / 2).contains(CGPoint(x: origin.x + p.x, y: origin.y + p.y))
        }
        for direction in [CGFloat(1), -1] {
            var point = start
            for _ in 0..<12 {
                if !collides(point) && inside(point) { return point }
                point.y += direction * spacing
            }
        }
        return start
    }
}
