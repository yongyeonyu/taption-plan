import SwiftUI
import TaptionPlanStore

/// 지구본 그리기. 나라 경계 자료만으로 그려 인터넷 없이도 같은 그림이 나온다.
enum TravelGlobeRenderer {
    struct Pin {
        var longitude: Double
        var latitude: Double
        var label: String
        /// 그 핀의 일정(누르면 그 일정을 연다)과 이름.
        var id = ""
        var title = ""
        /// 환승 공항(FLT1119A01): 번호·이름 없이 작은 점으로만 그린다.
        var isLayover = false
    }

    struct Flag {
        var id = ""
        var longitude: Double
        var latitude: Double
        var text: String
        /// 0 = 아직 없음, 1 = 꽂힘.
        var progress: Double
        var color: Color = TravelInk.actual
        /// 지난 여행은 옅게.
        var opacity: Double = 1
        /// 고른 깃발만 D-Day 이름표를 단다.
        var showsLabel = true
    }

    /// 그 깃발이 화면에서 꽂힌 자리. 지구 뒤쪽이면 nil.
    static func foot(of flag: Flag, camera: TravelGlobeCamera, size: CGSize) -> CGPoint? {
        let (base, front) = point(camera, center(in: size), flag.longitude, flag.latitude)
        return front ? base : nil
    }

    static func center(in size: CGSize) -> CGPoint { CGPoint(x: size.width / 2, y: size.height * 0.54) }

    /// 지도 위 캐릭터(재생 헤드의 시각에 있는 자리).
    struct Actor {
        var longitude: Double
        var latitude: Double
        var image: Image
        var facesEast: Bool
    }

    /// `offset`은 지도 가운데를 옮기는 양: 계획표가 올라오면 시트에 가리지 않는 자리의 가운데로 옮긴다.
    static func draw(
        _ context: inout GraphicsContext, size: CGSize, camera: TravelGlobeCamera, highlight: Set<String>,
        flags: [Flag], pins: [Pin], offset: CGSize = .zero, actor: Actor? = nil,
        home: SIMD2<Double>? = nil, route: [SIMD2<Double>] = []
    ) {
        let base = center(in: size)
        let center = CGPoint(x: base.x + offset.width, y: base.y + offset.height)
        let radius = camera.radius
        let covers = radius > hypot(size.width, size.height)
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(covers ? TravelInk.sea : TravelInk.space))
        if !covers {
            context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)), with: .color(TravelInk.sea))
            if radius < 900 { context.stroke(graticule(camera, center: center), with: .color(TravelInk.grid), lineWidth: 0.5) }
        }
        let showsProvinces = radius > 1_800
        var land = Path(), marked = Path()
        for region in TravelModeRegions.countries where isVisible(region, camera: camera, center: center, size: size) {
            if highlight.contains(region.code) {
                add(region, to: &marked, camera: camera, center: center)
            } else {
                add(region, to: &land, camera: camera, center: center)
            }
        }
        context.fill(land, with: .color(TravelInk.land))
        context.stroke(land, with: .color(TravelInk.border), lineWidth: 0.5)
        context.fill(marked, with: .color(TravelInk.planTint))
        context.stroke(marked, with: .color(TravelInk.plan), lineWidth: 1.5)
        if showsProvinces {
            var plain = Path(), chosen = Path()
            for region in TravelModeRegions.provinces where isVisible(region, camera: camera, center: center, size: size) {
                if highlight.contains(region.code) {
                    add(region, to: &chosen, camera: camera, center: center)
                } else {
                    add(region, to: &plain, camera: camera, center: center)
                }
            }
            context.fill(plain, with: .color(TravelInk.land))
            context.stroke(plain, with: .color(TravelInk.border), lineWidth: 0.5)
            context.fill(chosen, with: .color(TravelInk.planTint))
            context.stroke(chosen, with: .color(TravelInk.plan), lineWidth: 1.5)
        }
        if let home { drawHome(&context, home: home, flags: flags, camera: camera, center: center) }
        drawPins(&context, pins: pins, route: route, camera: camera, center: center)
        if let actor {
            let (spot, front) = point(camera, center, actor.longitude, actor.latitude)
            if front {
                // 발이 그 자리에 오게 위로 올려 그리고, 서쪽으로 갈 때는 좌우를 뒤집는다.
                var layer = context
                layer.translateBy(x: spot.x, y: spot.y - 20)
                if !actor.facesEast { layer.scaleBy(x: -1, y: 1) }
                layer.draw(actor.image, in: CGRect(x: -24, y: -24, width: 48, height: 48))
            }
        }
        // 이름표를 단 깃발을 맨 위에 그린다.
        for flag in flags.sorted(by: { !$0.showsLabel && $1.showsLabel }) where flag.progress > 0 {
            drawFlag(&context, flag: flag, camera: camera, center: center)
        }
    }

    private static func point(_ camera: TravelGlobeCamera, _ center: CGPoint, _ longitude: Double, _ latitude: Double) -> (CGPoint, Bool) {
        let projected = camera.project(longitude: longitude, latitude: latitude)
        return (CGPoint(x: center.x + projected.point.x, y: center.y + projected.point.y), projected.isFront)
    }

    /// 지구 뒤쪽이거나 화면 밖인 곳은 그리지 않는다.
    private static func isVisible(_ region: TravelGlobeRegion, camera: TravelGlobeCamera, center: CGPoint, size: CGSize) -> Bool {
        let corners = [(region.west, region.south), (region.west, region.north), (region.east, region.south), (region.east, region.north),
                       (region.center.x, region.center.y), (region.anchor.x, region.anchor.y)]
        let projected = corners.map { point(camera, center, $0.0, $0.1) }
        guard projected.contains(where: { $0.1 }) else { return false }
        // 넓은 나라는 상자 모서리가 모두 화면 밖이어도 화면을 덮을 수 있어, 충분히 확대했을 때만 화면 밖을 거른다.
        guard camera.radius > 600, region.east - region.west < 40 else { return true }
        let margin: CGFloat = 80
        let xs = projected.map(\.0.x), ys = projected.map(\.0.y)
        return !((xs.max() ?? 0) < -margin || (xs.min() ?? 0) > size.width + margin || (ys.max() ?? 0) < -margin || (ys.min() ?? 0) > size.height + margin)
    }

    /// 미리 구한 단위 벡터를 화면의 동·북·앞 방향에 내적해 놓는다(`TravelGlobeCamera.project`와 같은 결과).
    private static func add(_ region: TravelGlobeRegion, to path: inout Path, camera: TravelGlobeCamera, center: CGPoint) {
        guard let rings = TravelModeRegions.vectors[region.code] else { return }
        let lambda = camera.longitude * .pi / 180, phi = camera.latitude * .pi / 180
        let front = SIMD3(cos(phi) * cos(lambda), cos(phi) * sin(lambda), sin(phi))
        let east = SIMD3(-sin(lambda), cos(lambda), 0)
        let north = SIMD3(-sin(phi) * cos(lambda), -sin(phi) * sin(lambda), cos(phi))
        let radius = camera.radius
        let spans = TravelModeRegions.spans[region.code] ?? []
        // 화면에서 1.5pt보다 작은 섬은 건너뛴다(지구본일 때 작은 섬 수백 개가 그리는 시간을 차지한다).
        let smallest = 1.5 / (radius * .pi / 180)
        for (index, ring) in rings.enumerated() {
            if index > 0, index < spans.count, spans[index] < smallest { continue }
            var points: [CGPoint] = []
            points.reserveCapacity(ring.count)
            for vector in ring {
                var x = (vector * east).sum(), y = -(vector * north).sum()
                if (vector * front).sum() < 0 {
                    let length = (x * x + y * y).squareRoot()
                    if length > 0 {
                        x /= length
                        y /= length
                    }
                }
                points.append(CGPoint(x: center.x + x * radius, y: center.y + y * radius))
            }
            path.addLines(points)
            path.closeSubpath()
        }
    }

    private static func graticule(_ camera: TravelGlobeCamera, center: CGPoint) -> Path {
        var path = Path()
        func line(_ points: [(Double, Double)]) {
            var drawing = false
            for value in points {
                let (location, front) = point(camera, center, value.0, value.1)
                if front {
                    if drawing { path.addLine(to: location) } else { path.move(to: location); drawing = true }
                } else {
                    drawing = false
                }
            }
        }
        for longitude in stride(from: -180.0, to: 180.0, by: 30) { line(stride(from: -80.0, through: 80.0, by: 5).map { (longitude, $0) }) }
        for latitude in stride(from: -60.0, through: 60.0, by: 30) { line(stride(from: -180.0, through: 180.0, by: 5).map { ($0, latitude) }) }
        return path
    }

    /// 집 자리(집 아이콘)와, 집에서 여행지마다 가는 가는 점선(대표 지시: 점선·1pt·80%).
    private static func drawHome(_ context: inout GraphicsContext, home: SIMD2<Double>, flags: [Flag], camera: TravelGlobeCamera, center: CGPoint) {
        let (spot, front) = point(camera, center, home.x, home.y)
        guard front else { return }
        for flag in flags {
            let (end, visible) = point(camera, center, flag.longitude, flag.latitude)
            guard visible else { continue }
            var line = Path()
            line.move(to: spot)
            line.addLine(to: end)
            context.stroke(line, with: .color(TravelInk.plan.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
        let rect = CGRect(x: spot.x - 11, y: spot.y - 11, width: 22, height: 22)
        context.fill(Path(ellipseIn: rect), with: .color(TravelInk.land))
        context.stroke(Path(ellipseIn: rect), with: .color(TravelInk.plan), lineWidth: 1.5)
        context.draw(Image(systemName: "house.fill").resizable(), in: rect.insetBy(dx: 5, dy: 5.5), style: FillStyle())
    }

    /// `route`가 있으면(길찾기로 받은 길) 핀을 곧게 잇는 대신 그 길을 그린다.
    private static func drawPins(_ context: inout GraphicsContext, pins: [Pin], route points: [SIMD2<Double>] = [], camera: TravelGlobeCamera, center: CGPoint) {
        let places = pins.map { (point(camera, center, $0.longitude, $0.latitude), $0.label, $0.isLayover) }.filter { $0.0.1 }
        guard !places.isEmpty else { return }
        var route = Path()
        if points.count > 1 {
            var isDrawing = false
            for spot in points {
                let (projected, front) = point(camera, center, spot.x, spot.y)
                if front { if isDrawing { route.addLine(to: projected) } else { route.move(to: projected) } }
                isDrawing = front
            }
        } else {
            for (index, place) in places.enumerated() {
                if index == 0 { route.move(to: place.0.0) } else { route.addLine(to: place.0.0) }
            }
        }
        context.stroke(route, with: .color(TravelInk.plan), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round, dash: [6, 5]))
        for place in places {
            if place.2 {
                let dot = CGRect(x: place.0.0.x - 4, y: place.0.0.y - 4, width: 8, height: 8)
                context.fill(Path(ellipseIn: dot), with: .color(TravelInk.plan))
                context.stroke(Path(ellipseIn: dot), with: .color(TravelInk.land), lineWidth: 1)
                continue
            }
            let rect = CGRect(x: place.0.0.x - 9, y: place.0.0.y - 9, width: 18, height: 18)
            context.fill(Path(ellipseIn: rect), with: .color(TravelInk.plan))
            context.stroke(Path(ellipseIn: rect), with: .color(TravelInk.land), lineWidth: 1.5)
            context.draw(Text(place.1).font(.system(size: 11, weight: .medium)).foregroundStyle(TravelInk.land), at: place.0.0)
        }
    }

    private static func drawFlag(_ context: inout GraphicsContext, flag: Flag, camera: TravelGlobeCamera, center: CGPoint) {
        let (base, front) = point(camera, center, flag.longitude, flag.latitude)
        guard front else { return }
        var layer = context
        layer.opacity = min(1, flag.progress * 2) * flag.opacity
        let foot = CGPoint(x: base.x, y: base.y - (1 - flag.progress) * 60)
        var pole = Path()
        pole.move(to: foot)
        pole.addLine(to: CGPoint(x: foot.x, y: foot.y - 32))
        layer.stroke(pole, with: .color(flag.color), lineWidth: 2)
        var cloth = Path()
        cloth.move(to: CGPoint(x: foot.x, y: foot.y - 32))
        cloth.addLine(to: CGPoint(x: foot.x + 20, y: foot.y - 26))
        cloth.addLine(to: CGPoint(x: foot.x, y: foot.y - 20))
        cloth.closeSubpath()
        layer.fill(cloth, with: .color(flag.color))
        layer.fill(Path(ellipseIn: CGRect(x: foot.x - 3, y: foot.y - 3, width: 6, height: 6)), with: .color(flag.color))
        guard flag.showsLabel, flag.progress >= 1, !flag.text.isEmpty else { return }
        let label = layer.resolve(Text(flag.text).font(.system(size: 12, weight: .medium)).foregroundStyle(TravelInk.land))
        let textSize = label.measure(in: CGSize(width: 200, height: 40))
        let pill = CGRect(x: foot.x + 24, y: foot.y - 36, width: textSize.width + 16, height: textSize.height + 6)
        layer.fill(Path(roundedRect: pill, cornerRadius: pill.height / 2), with: .color(flag.color))
        layer.draw(label, at: CGPoint(x: pill.midX, y: pill.midY))
    }
}
