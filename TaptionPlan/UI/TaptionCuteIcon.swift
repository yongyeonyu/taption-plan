import SwiftUI

/// 앱 공용 아이콘. 끝이 둥근 통통한 면과 고양이 발바닥으로 직접 그린다(NAV1102A01, 대표).
/// SF Symbols 이름을 그대로 받아 어디서나 바꿔 끼울 수 있고, 색은 `foregroundStyle`을 따른다.
/// 직접 그린 모양이 없는 이름은 SF Symbols로 그린다.
struct TaptionCuteIcon: View {
    let systemImage: String
    var size: CGFloat = 22

    init(_ systemImage: String, size: CGFloat = 22) {
        self.systemImage = systemImage
        self.size = size
    }

    var body: some View {
        if let glyph = Glyph(symbol: systemImage) {
            Canvas { context, canvas in
                context.scaleBy(x: canvas.width / 24, y: canvas.height / 24)
                var pen = Pen(context: context)
                glyph.draw(with: &pen)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        } else {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.8, weight: .bold, design: .rounded))
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}

/// 아이콘 격자 24×24 위에 그리는 붓. `cut`은 아래 그린 면을 뚫어 바탕이 보이게 한다.
private struct Pen {
    var context: GraphicsContext

    func blob(_ points: [(CGFloat, CGFloat)], round: CGFloat = 1.7) {
        var path = Path()
        path.addLines(points.map { CGPoint(x: $0.0, y: $0.1) })
        path.closeSubpath()
        context.fill(path, with: .foreground)
        context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: round * 2, lineJoin: .round))
    }

    func line(_ lines: [[(CGFloat, CGFloat)]], width: CGFloat = 2.6) {
        var path = Path()
        for points in lines { path.addLines(points.map { CGPoint(x: $0.0, y: $0.1) }) }
        context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }

    func curve(from start: (CGFloat, CGFloat), to end: (CGFloat, CGFloat), via control: (CGFloat, CGFloat), width: CGFloat = 2.6) {
        var path = Path()
        path.move(to: CGPoint(x: start.0, y: start.1))
        path.addQuadCurve(to: CGPoint(x: end.0, y: end.1), control: CGPoint(x: control.0, y: control.1))
        context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: width, lineCap: .round))
    }

    func dot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
        context.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .foreground)
    }

    func ring(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, width: CGFloat = 2.4) {
        context.stroke(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .foreground, lineWidth: width)
    }

    func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) {
        context.fill(Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r), with: .foreground)
    }

    func cut(_ draw: (Pen) -> Void) {
        var eraser = context
        eraser.blendMode = .destinationOut
        draw(Pen(context: eraser))
    }

    /// 고양이 발바닥. 작은 크기에서도 읽히게 발가락을 크게 둔다.
    func paw(_ x: CGFloat, _ y: CGFloat, _ k: CGFloat = 1) {
        context.fill(
            Path(ellipseIn: CGRect(x: x - 3.6 * k, y: y - 1 * k, width: 7.2 * k, height: 5.8 * k)),
            with: .foreground
        )
        for (dx, dy) in [(-4.4, -1.4), (-1.6, -4), (1.6, -4), (4.4, -1.4)] as [(CGFloat, CGFloat)] {
            dot(x + dx * k, y + dy * k, 1.55 * k)
        }
    }
}

private enum Glyph {
    case menu, plus, location, home, play, pause, record
    case sleep, walk, run, steps, footprints, walkDistance, route, pin, trips, photo, car, bus, tram, train, door
    case work, study, book, books, exercise, palette, meal, cook, sparkle, heart, pill, pulse, bed, rest, shower, wash, question
    case bike, plane, ferry, chart, layers, globe, watch, gear, bell, info, wifi, phone

    init?(symbol: String) {
        switch symbol {
        case "line.3.horizontal": self = .menu
        case "plus": self = .plus
        case "location.fill": self = .location
        case "house.fill": self = .home
        case "play.fill": self = .play
        case "pause.fill": self = .pause
        case "record.circle": self = .record
        case "moon.zzz.fill": self = .sleep
        case "figure.walk.motion": self = .walk
        case "figure.run": self = .run
        case "figure.walk": self = .steps
        case "shoeprints.fill": self = .footprints
        case "figure.walk.circle": self = .walkDistance
        case "point.topleft.down.to.point.bottomright.curvepath": self = .route
        case "mappin.and.ellipse", "mappin.circle.fill": self = .pin
        case "arrow.left.arrow.right": self = .trips
        case "photo.fill", "photo.on.rectangle.angled": self = .photo
        case "car.fill", "car.side.fill": self = .car
        case "bus.fill": self = .bus
        case "tram.fill": self = .tram
        case "train.side.front.car": self = .train
        case "door.left.hand.open": self = .door
        case "briefcase.fill": self = .work
        case "graduationcap.fill": self = .study
        case "book.fill": self = .book
        case "books.vertical.fill": self = .books
        case "dumbbell.fill", "figure.strengthtraining.traditional": self = .exercise
        case "paintpalette.fill": self = .palette
        case "fork.knife": self = .meal
        case "frying.pan": self = .cook
        case "sparkles": self = .sparkle
        case "heart.circle.fill", "heart.fill", "heart.text.square.fill": self = .heart
        case "pills.fill": self = .pill
        case "waveform.path.ecg": self = .pulse
        case "bed.double.fill": self = .bed
        case "pause.circle.fill": self = .rest
        case "shower.fill": self = .shower
        case "washer.fill": self = .wash
        case "questionmark.circle.fill": self = .question
        case "bicycle": self = .bike
        case "airplane": self = .plane
        case "ferry.fill": self = .ferry
        case "chart.bar.xaxis": self = .chart
        case "square.3.layers.3d": self = .layers
        case "globe": self = .globe
        case "applewatch": self = .watch
        case "gearshape.fill": self = .gear
        case "bell.badge", "bell.fill": self = .bell
        case "info.circle": self = .info
        case "wifi": self = .wifi
        case "iphone": self = .phone
        default: return nil
        }
    }

    func draw(with pen: inout Pen) {
        switch self {
        case .menu:
            pen.line([[(4, 6.5), (20, 6.5)], [(4, 12), (20, 12)], [(4, 17.5), (20, 17.5)]], width: 2.8)
        case .plus:
            pen.line([[(12, 5), (12, 19)], [(5, 12), (19, 12)]], width: 3)
        case .location:
            pen.blob([(19, 5), (5, 10.6), (11, 13), (13.4, 19)])
        case .home:
            pen.blob([(12, 5), (19, 11), (19, 18.6), (5, 18.6), (5, 11)])
            pen.cut { $0.box(9.8, 13.6, 4.4, 8, 2.2) }
        case .play:
            pen.blob([(8.4, 6.4), (18, 12), (8.4, 17.6)], round: 1.9)
        case .pause:
            pen.line([[(8.5, 6.5), (8.5, 17.5)], [(15.5, 6.5), (15.5, 17.5)]], width: 4.4)
        case .record:
            pen.ring(12, 12, 8.5)
            pen.dot(12, 12, 4.4)
        case .sleep:
            pen.dot(10.5, 13.5, 7.8)
            pen.cut { $0.dot(14.6, 10.6, 6.6) }
            pen.line([[(15.2, 4), (19.6, 4), (15.2, 9), (19.6, 9)]], width: 1.9)
        case .walk:
            pen.paw(15, 9, 0.95)
            pen.line([[(2.6, 8), (6.2, 8)], [(2.6, 13), (7.6, 13)], [(4.6, 18), (10.4, 18)]], width: 2.2)
        case .run:
            pen.paw(15.4, 8, 0.85)
            pen.paw(8, 16.6, 0.85)
        case .steps:
            pen.paw(12, 12.4, 1.45)
        case .footprints:
            pen.paw(7.6, 9, 0.85)
            pen.paw(16.4, 15.6, 0.85)
        case .walkDistance:
            pen.ring(12, 12, 9.4, width: 2.2)
            pen.paw(12, 12.4, 0.85)
        case .route:
            pen.dot(6, 17.6, 3)
            pen.curve(from: (6, 17.6), to: (18, 6.4), via: (20, 19), width: 2.6)
            pen.paw(17.8, 7.2, 0.72)
        case .pin:
            pen.dot(12, 9.8, 7.2)
            pen.blob([(7.6, 14), (16.4, 14), (12, 20.4)], round: 1)
            pen.cut { $0.paw(12, 9.8, 0.72) }
        case .trips:
            pen.line([[(4.6, 8), (18.6, 8)], [(15, 4.4), (18.8, 8), (15, 11.6)], [(19.4, 16), (5.4, 16)], [(9, 12.4), (5.2, 16), (9, 19.6)]], width: 2.5)
        case .photo:
            pen.box(3, 5, 18, 14.4, 4.4)
            pen.cut { cut in
                cut.dot(8.4, 9.8, 1.9)
                cut.blob([(6.6, 16.4), (11, 12), (13.6, 14.4), (15.4, 12.6), (17.8, 16.4)], round: 0.5)
            }
        case .car:
            pen.blob([(6.8, 7.6), (17.2, 7.6), (19.6, 12.4), (19.6, 16.2), (4.4, 16.2), (4.4, 12.4)], round: 1.8)
            pen.cut { cut in
                cut.blob([(8.2, 8.8), (15.8, 8.8), (16.8, 11.6), (7.2, 11.6)], round: 0.5)
                cut.dot(7.6, 14, 1.3)
                cut.dot(16.4, 14, 1.3)
            }
            pen.dot(7.2, 18.4, 2.2)
            pen.dot(16.8, 18.4, 2.2)
        case .bus:
            pen.box(4, 3.8, 16, 15, 4.6)
            pen.cut { cut in
                cut.box(6.6, 6.8, 10.8, 4.8, 1.6)
                cut.dot(8, 15, 1.3)
                cut.dot(16, 15, 1.3)
            }
            pen.dot(7.6, 19.6, 1.9)
            pen.dot(16.4, 19.6, 1.9)
        case .tram:
            pen.box(5, 3.2, 14, 15.4, 6)
            pen.cut { cut in
                cut.box(7.8, 6.4, 8.4, 4.4, 1.6)
                cut.dot(9, 14.4, 1.35)
                cut.dot(15, 14.4, 1.35)
            }
            pen.line([[(8.2, 19.2), (6.4, 21.6)], [(15.8, 19.2), (17.6, 21.6)]], width: 2.2)
        case .train:
            pen.blob([(3, 8), (15, 8), (21, 14), (21, 16.6), (3, 16.6)], round: 1.7)
            pen.cut { cut in
                cut.box(4.6, 9.2, 4, 3.6, 1.2)
                cut.box(10, 9.2, 4, 3.6, 1.2)
            }
            pen.dot(7.6, 19.2, 1.9)
            pen.dot(16.4, 19.2, 1.9)
        case .door:
            pen.box(6, 3, 12, 18, 5)
            pen.cut { $0.dot(14.4, 12.6, 1.5) }
        case .work:
            pen.line([[(9, 8), (9, 5.4), (15, 5.4), (15, 8)]], width: 2.2)
            pen.box(3, 7.6, 18, 12.4, 4)
            pen.cut { $0.paw(12, 13.8, 0.68) }
        case .study:
            pen.blob([(12, 5.6), (21, 10), (12, 14.4), (3, 10)], round: 1)
            pen.curve(from: (7, 14.2), to: (17, 14.2), via: (12, 20.8), width: 2.8)
            pen.line([[(20.8, 10.4), (20.8, 16.4)]], width: 1.9)
        case .book:
            pen.box(5, 3.4, 14.4, 17.2, 3.6)
            pen.cut { $0.paw(12.2, 10.8, 0.72) }
        case .books:
            pen.box(3.6, 4, 5.2, 16, 2.2)
            pen.box(9.8, 4, 5.2, 16, 2.2)
            pen.blob([(17.4, 5), (20, 4.4), (21, 19), (18.4, 19.6)], round: 0.9)
        case .exercise:
            pen.line([[(7, 12), (17, 12)]], width: 2.6)
            pen.box(3, 7.4, 3.6, 9.2, 1.8)
            pen.box(6.4, 5.2, 3.8, 13.6, 1.9)
            pen.box(13.8, 5.2, 3.8, 13.6, 1.9)
            pen.box(17.4, 7.4, 3.6, 9.2, 1.8)
        case .palette:
            pen.dot(12, 12, 9.2)
            pen.cut { cut in
                cut.dot(7.6, 10.4, 1.6)
                cut.dot(11, 6.8, 1.6)
                cut.dot(15.4, 8, 1.6)
                cut.dot(15.8, 15.4, 2.7)
            }
        case .meal:
            // 생선 한 마리: 화랑이의 밥.
            pen.dot(10, 12, 6.8)
            pen.blob([(15, 12), (21, 7.6), (21, 16.4)], round: 1)
            pen.cut { $0.dot(7.6, 10.6, 1.4) }
        case .cook:
            pen.dot(10, 13, 7)
            pen.line([[(15.6, 8.4), (21, 3.6)]], width: 2.8)
        case .sparkle:
            pen.blob([(12, 3.6), (14.4, 9.6), (20.4, 12), (14.4, 14.4), (12, 20.4), (9.6, 14.4), (3.6, 12), (9.6, 9.6)], round: 0.9)
        case .heart:
            pen.dot(8.2, 9.4, 4.8)
            pen.dot(15.8, 9.4, 4.8)
            pen.blob([(3.9, 11.4), (20.1, 11.4), (12, 20.2)], round: 0.8)
        case .pill:
            pen.line([[(7.4, 16.6), (16.6, 7.4)]], width: 8.4)
            pen.cut { $0.line([[(10.2, 9.8), (14.2, 13.8)]], width: 1.5) }
        case .pulse:
            pen.line([[(2.8, 12.6), (7.4, 12.6), (10, 6.4), (14, 18), (16.6, 12.6), (21.2, 12.6)]], width: 2.6)
        case .bed:
            pen.box(3, 11.4, 18, 7, 3)
            pen.box(5, 7, 7, 5.6, 2.6)
            pen.line([[(5.4, 19.2), (5.4, 20.6)], [(18.6, 19.2), (18.6, 20.6)]], width: 2.2)
        case .rest:
            pen.dot(12, 12, 9.2)
            pen.cut { $0.line([[(9.4, 8.6), (9.4, 15.4)], [(14.6, 8.6), (14.6, 15.4)]], width: 2.9) }
        case .shower:
            pen.blob([(7, 9.6), (17, 9.6), (15, 5.4), (9, 5.4)], round: 1.4)
            for (x, y) in [(7.6, 14), (12, 14), (16.4, 14), (9.8, 18.6), (14.2, 18.6)] as [(CGFloat, CGFloat)] {
                pen.line([[(x, y), (x, y + 1.4)]], width: 2.3)
            }
        case .wash:
            pen.box(4, 3, 16, 18, 4.6)
            pen.cut { $0.dot(12, 13, 4.9) }
            pen.dot(12, 13, 2.2)
        case .question:
            pen.dot(12, 12, 9.2)
            pen.cut { cut in
                cut.curve(from: (8.8, 9.6), to: (12, 13.4), via: (15.6, 6.8), width: 2.5)
                cut.line([[(12, 13.4), (12, 13.9)]], width: 2.5)
                cut.dot(12, 17.4, 1.5)
            }
        case .bike:
            pen.ring(6.4, 15.6, 3.7)
            pen.ring(17.6, 15.6, 3.7)
            pen.line([[(6.4, 15.6), (10, 8.8), (15.4, 8.8), (17.6, 15.6)], [(10, 8.8), (12.4, 15.6), (15.4, 8.8)], [(8.6, 6.6), (11, 6.6)], [(15.4, 8.8), (15, 5.8), (17.4, 5.8)]], width: 1.9)
        case .plane:
            pen.line([[(5, 19), (19, 5)]], width: 4.2)
            pen.blob([(11.6, 9), (4.4, 7), (3.8, 8.6), (9.6, 12.2)], round: 0.9)
            pen.blob([(15, 12.4), (17, 19.6), (15.4, 20.2), (11.8, 14.4)], round: 0.9)
        case .ferry:
            pen.blob([(3.6, 13), (20.4, 13), (18, 18), (6, 18)], round: 1.4)
            pen.box(8, 6.8, 8.8, 5.6, 2)
            pen.cut { $0.dot(12.4, 9.6, 1.25) }
            pen.curve(from: (3, 21.4), to: (21, 21.4), via: (12, 19.8), width: 1.8)
        case .chart:
            pen.line([[(5.4, 19), (5.4, 12)], [(12, 19), (12, 5.4)], [(18.6, 19), (18.6, 9.4)]], width: 4)
        case .layers:
            pen.blob([(12, 4.4), (20, 9), (12, 13.6), (4, 9)], round: 1)
            pen.curve(from: (4.4, 13.8), to: (19.6, 13.8), via: (12, 20.4), width: 2.4)
        case .globe:
            pen.dot(12, 12, 9.2)
            pen.cut { cut in
                cut.paw(12, 12.4, 1)
            }
        case .watch:
            pen.box(6, 5.4, 12, 13.2, 4.4)
            pen.box(8.6, 2.4, 6.8, 4, 1.4)
            pen.box(8.6, 17.6, 6.8, 4, 1.4)
            pen.cut { $0.paw(12, 12, 0.68) }
        case .gear:
            // 톱니 대신 꽃잎처럼 둥글린다.
            for index in 0..<6 {
                let angle = CGFloat(index) / 6 * 2 * .pi
                pen.dot(12 + 6.9 * cos(angle), 12 + 6.9 * sin(angle), 3)
            }
            pen.dot(12, 12, 6.6)
            pen.cut { $0.dot(12, 12, 2.9) }
        case .bell:
            pen.dot(12, 10.6, 6.6)
            pen.box(5.4, 10.4, 13.2, 7, 2)
            pen.line([[(3.8, 17.2), (20.2, 17.2)]], width: 2.6)
            pen.dot(12, 20.6, 1.8)
        case .info:
            pen.dot(12, 12, 9.2)
            pen.cut { cut in
                cut.dot(12, 7.6, 1.6)
                cut.line([[(12, 11.4), (12, 16.6)]], width: 2.8)
            }
        case .wifi:
            pen.curve(from: (3.6, 10), to: (20.4, 10), via: (12, 2.6), width: 2.5)
            pen.curve(from: (7.4, 14), to: (16.6, 14), via: (12, 9.6), width: 2.5)
            pen.dot(12, 18.4, 2.1)
        case .phone:
            pen.box(6.4, 2.6, 11.2, 18.8, 3.4)
            pen.cut { $0.paw(12, 11.6, 0.6) }
        }
    }
}

/// 하단 메뉴 스티커 색. 어두운 테마에서 글자색(거의 흰색)을 테두리로 쓰면 하얀 선이 도드라진다.
/// 대표 지시: 야간은 흰 선에 안쪽 어두운 선, 계절은 그 계절의 진한 선, 실외는 진한 선.
struct TaptionBarPalette: Sendable {
    let outline, coral, honey, brick, mint, rose, sky, cream, cocoa, weekday: Color
    /// 바깥 테두리 안쪽에 한 겹 더 넣는 어두운 선. 아이콘 크기는 그대로다.
    let innerLine: Color?

    init(_ hexes: [String], innerLine: String? = nil) {
        let c = hexes.map { Color(hex: $0) }
        self.innerLine = innerLine.map { Color(hex: $0) }
        (outline, coral, honey, brick, mint, rose, sky, cream, cocoa, weekday)
            = (c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8], c[9])
    }

    static var current: TaptionBarPalette {
        switch TaptionUITheme.current {
        case .classic: classic
        case .navy: night
        case .purple: TaptionSeasonStore.current.bar
        case .brown: outdoor
        case .ink: inkWash
        }
    }

    private static let classic = TaptionBarPalette(["#3E3320", "#EE8A5E", "#F3C766", "#D9694F", "#62B7A6", "#E7708F", "#9CC6E8", "#FBF6EA", "#8A5A3C", "#B9A98F"])
    private static let night = TaptionBarPalette(["#FFFFFF", "#FF9E80", "#FFD97A", "#F2836B", "#6FDCC8", "#FF8FB0", "#8CCBFF", "#F5F9FF", "#4A6FA8", "#93B6DA"], innerLine: "#0A101E")
    /// 수묵: 먹 테두리에 옅은 먹빛 면, 인주 빨강은 한 칸만.
    private static let inkWash = TaptionBarPalette(MapHomeInkWash.barHexes)
    private static let outdoor = TaptionBarPalette(["#0E0B07", "#FF9A5C", "#FFD35C", "#F07A4F", "#66D4B5", "#FF8FA3", "#8FC4FF", "#FFFBF4", "#A0701C", "#D8CBB4"])
}

/// 하단 메뉴 전용 색 스티커. 화랑이처럼 진한 테두리에 면을 칠하고 작은 광택을 얹는다(대표 시안 B).
struct TaptionBarIcon: View {
    let systemImage: String
    var size: CGFloat = 28

    var body: some View {
        Canvas { context, canvas in
            context.scaleBy(x: canvas.width / 24, y: canvas.height / 24)
            draw(in: context)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func draw(in context: GraphicsContext) {
        let palette = TaptionBarPalette.current
        let ink = palette.outline
        func shape(_ path: Path, _ fill: Color, line: CGFloat = 1.7) {
            context.fill(path, with: .color(fill))
            if let inner = palette.innerLine {
                // 면 안쪽에만 그려 바깥 크기를 늘리지 않는다.
                var inside = context
                inside.clip(to: path)
                inside.stroke(path, with: .color(inner), lineWidth: line + 1.5)
            }
            context.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
        }
        func poly(_ points: [(CGFloat, CGFloat)], round: CGFloat) -> Path {
            // 꼭짓점마다 곡선으로 깎아 뾰족한 데가 없게 한다.
            var path = Path()
            let p = points.map { CGPoint(x: $0.0, y: $0.1) }
            for i in p.indices {
                let cur = p[i], prev = p[(i + p.count - 1) % p.count], next = p[(i + 1) % p.count]
                func toward(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
                    let d = max(0.01, hypot(b.x - a.x, b.y - a.y)), k = min(round, d / 2) / d
                    return CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k)
                }
                let inP = toward(cur, prev), outP = toward(cur, next)
                if i == 0 { path.move(to: inP) } else { path.addLine(to: inP) }
                path.addQuadCurve(to: outP, control: cur)
            }
            path.closeSubpath()
            return path
        }
        func gloss(_ from: (CGFloat, CGFloat), _ to: (CGFloat, CGFloat)) {
            var path = Path()
            path.move(to: CGPoint(x: from.0, y: from.1))
            path.addLine(to: CGPoint(x: to.0, y: to.1))
            context.stroke(path, with: .color(.white.opacity(0.75)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
        switch systemImage {
        case "magnifyingglass":
            var handle = Path()
            handle.move(to: CGPoint(x: 15.6, y: 15.6))
            handle.addLine(to: CGPoint(x: 20.4, y: 20.4))
            context.stroke(handle, with: .color(ink), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            context.stroke(handle, with: .color(palette.coral), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            shape(Path(ellipseIn: CGRect(x: 3, y: 3, width: 14.6, height: 14.6)), palette.sky)
            gloss((6.6, 9), (8.6, 6.6))
        case "note.text":
            shape(Path(roundedRect: CGRect(x: 4, y: 3, width: 16, height: 18), cornerRadius: 4.4), palette.honey)
            var lines = Path()
            for (y, end) in [(8.6, 16.4), (12.2, 16.4), (15.8, 12.6)] as [(CGFloat, CGFloat)] {
                lines.move(to: CGPoint(x: 7.8, y: y))
                lines.addLine(to: CGPoint(x: end, y: y))
            }
            context.stroke(lines, with: .color(palette.innerLine ?? ink), style: StrokeStyle(lineWidth: 1.9, lineCap: .round))
        case "xmark":
            var cross = Path()
            cross.move(to: CGPoint(x: 6.4, y: 6.4)); cross.addLine(to: CGPoint(x: 17.6, y: 17.6))
            cross.move(to: CGPoint(x: 17.6, y: 6.4)); cross.addLine(to: CGPoint(x: 6.4, y: 17.6))
            context.stroke(cross, with: .color(ink), style: StrokeStyle(lineWidth: 6, lineCap: .round))
            context.stroke(cross, with: .color(palette.rose), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        case "line.3.horizontal":
            for (y, width, color) in [(4.4, 18.0, palette.coral), (10, 13.0, palette.honey), (15.6, 18.0, palette.mint)] as [(CGFloat, CGFloat, Color)] {
                shape(Path(roundedRect: CGRect(x: 3, y: y, width: width, height: 4.2), cornerRadius: 2.1), color, line: 1.5)
            }
        case "location.fill":
            shape(poly([(20.5, 3.5), (3.5, 10.4), (10.6, 13.4), (13.6, 20.5)], round: 3), palette.coral)
            gloss((7.6, 10.2), (11.4, 8.7))
        case "house.fill":
            shape(Path(roundedRect: CGRect(x: 5.2, y: 10.6, width: 13.6, height: 10), cornerRadius: 2.6), palette.honey)
            shape(poly([(12, 2.8), (21.6, 11.6), (2.4, 11.6)], round: 2.6), palette.brick)
            shape(Path(roundedRect: CGRect(x: 10, y: 14.4, width: 4, height: 6.2), cornerRadius: 2), palette.cocoa, line: 1.2)
            gloss((8.4, 8.6), (11, 6.3))
        case "play.fill":
            shape(poly([(6.2, 3.4), (20.8, 12), (6.2, 20.6)], round: 3.6), palette.mint)
            gloss((8.6, 8), (8.6, 11))
        case "airplane":
            // 위를 향한 비행기를 오른쪽 위로 45도 돌린다.
            let plane = poly([
                (12, 1.8), (13.7, 4.2), (14, 9), (22, 14.4), (22, 17), (14, 14.6), (13.6, 19), (16, 21), (16, 22.6),
                (12, 21.6), (8, 22.6), (8, 21), (10.4, 19), (10, 14.6), (2, 17), (2, 14.4), (10, 9), (10.3, 4.2),
            ], round: 0.9)
            shape(plane.applying(CGAffineTransform(translationX: 12, y: 12).rotated(by: .pi / 4).translatedBy(x: -12, y: -12)), palette.sky)
        case "pause.fill":
            shape(Path(roundedRect: CGRect(x: 5, y: 4, width: 5.4, height: 16), cornerRadius: 2.7), palette.mint)
            shape(Path(roundedRect: CGRect(x: 13.6, y: 4, width: 5.4, height: 16), cornerRadius: 2.7), palette.mint)
        case "record.circle":
            // 귀 달린 녹화 단추.
            shape(poly([(4.6, 8.4), (5, 2.6), (10, 5.2)], round: 1.2), palette.rose, line: 1.5)
            shape(poly([(19.4, 8.4), (19, 2.6), (14, 5.2)], round: 1.2), palette.rose, line: 1.5)
            shape(Path(ellipseIn: CGRect(x: 3, y: 4, width: 18, height: 18)), palette.cream)
            shape(Path(ellipseIn: CGRect(x: 7.4, y: 8.4, width: 9.2, height: 9.2)), palette.rose, line: 1.4)
            gloss((10, 11), (11.2, 10.2))
        default:
            shape(Path(roundedRect: CGRect(x: 4, y: 3, width: 16, height: 18), cornerRadius: 4.4), palette.sky)
            var plus = Path()
            plus.move(to: CGPoint(x: 12, y: 8.2)); plus.addLine(to: CGPoint(x: 12, y: 15.8))
            plus.move(to: CGPoint(x: 8.2, y: 12)); plus.addLine(to: CGPoint(x: 15.8, y: 12))
            context.stroke(plus, with: .color(palette.innerLine ?? ink), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
        }
    }
}

/// 하단 메뉴 달력. 다른 하단 아이콘과 같은 스티커 그림에, 요일이 지날수록 칸이 차고
/// 머리 색이 일요일·토요일·평일로 바뀌는 규칙은 예전 달력 그림 그대로다.
struct TaptionBarCalendarIcon: View {
    enum Tone {
        case weekday, saturday, sunday
    }

    let filledDays: Int
    let tone: Tone
    var size: CGFloat = 28

    var body: some View {
        Canvas { context, canvas in
            context.scaleBy(x: canvas.width / 24, y: canvas.height / 24)
            let palette = TaptionBarPalette.current
            let ink = palette.outline
            let header = switch tone {
            case .weekday: palette.weekday
            case .saturday: palette.sky
            case .sunday: palette.rose
            }
            let style = StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
            let page = Path(roundedRect: CGRect(x: 3, y: 4.4, width: 18, height: 17), cornerRadius: 4.4)
            context.fill(page, with: .color(palette.cream))
            var band = context
            band.clip(to: page)
            band.fill(Path(CGRect(x: 3, y: 4.4, width: 18, height: 5)), with: .color(header))
            if let inner = palette.innerLine {
                var inside = context
                inside.clip(to: page)
                inside.stroke(page, with: .color(inner), lineWidth: 3.2)
            }
            context.stroke(page, with: .color(ink), style: style)
            var rings = Path()
            for x: CGFloat in [8, 16] {
                rings.move(to: CGPoint(x: x, y: 2.4))
                rings.addLine(to: CGPoint(x: x, y: 6.2))
            }
            context.stroke(rings, with: .color(ink), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            for index in 0..<7 {
                let row = index < 4 ? 0 : 1, column = index < 4 ? index : index - 4
                let center = CGPoint(x: 6.8 + CGFloat(column) * 3.5, y: 12.6 + CGFloat(row) * 4)
                let dot = Path(ellipseIn: CGRect(x: center.x - 1.25, y: center.y - 1.25, width: 2.5, height: 2.5))
                context.fill(dot, with: .color(index < filledDays ? palette.rose : palette.weekday.opacity(0.55)))
            }
        }
        .frame(width: size, height: size)
    }
}

/// 왼쪽 위 원형 단추 바탕. 하단 아이콘과 같은 테두리에 위쪽 광택과 아래 그림자로 도톰해 보이게 한다.
struct TaptionStickerDisc: View {
    var side: CGFloat = 40

    var body: some View {
        let palette = TaptionBarPalette.current
        ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: [palette.cream, palette.cream.mix(with: .black, by: 0.1)],
                    startPoint: .top, endPoint: .bottom
                ))
            if let inner = palette.innerLine {
                Circle().strokeBorder(inner, lineWidth: 2.4)
            }
            Circle().strokeBorder(palette.outline, lineWidth: 1.6)
            Ellipse()
                .fill(.white.opacity(0.6))
                .frame(width: side * 0.46, height: side * 0.16)
                .offset(y: -side * 0.31)
        }
        .frame(width: side, height: side)
        .shadow(color: .black.opacity(0.22), radius: 2.5, y: 2)
    }
}

/// 메뉴 행 왼쪽 아이콘. 바탕 없이 분류 색 아이콘만 둔다(대표 요청).
struct MapHomeMenuIconChip: View {
    let systemImage: String
    let tint: Color

    var body: some View {
        TaptionCuteIcon(systemImage, size: 28)
            .foregroundStyle(tint)
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)
    }
}
