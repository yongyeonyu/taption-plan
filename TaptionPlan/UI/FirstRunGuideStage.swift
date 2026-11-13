import SwiftUI

/// 설명 줄 하나가 그림에서 보여 주는 동작. 줄 순서와 같다(FRT1105A02).
enum FirstRunGuideCue: Hashable {
    case panMap, location, otherDays, readRoute, mapDisplay
    case play, record, render, save
    case railToggle, railDrag, railColors, calendar
    case clipOpen, clipMove, clipSplit, clipOverwrite
    case memoAdd, memoPin, memoBrowse, memoDisplay
    case summaryOpen, streak, reward

    static func cues(for step: FirstRunTutorialStep) -> [FirstRunGuideCue] {
        switch step {
        case .map: [.panMap, .location, .otherDays, .readRoute, .mapDisplay]
        case .playback: [.play, .record, .render, .save]
        case .sidebarCalendar: [.railToggle, .railDrag, .railColors, .calendar]
        case .clipEditor: [.clipOpen, .clipMove, .clipSplit, .clipOverwrite]
        case .memos: [.memoAdd, .memoPin, .memoBrowse, .memoDisplay]
        case .summary: [.summaryOpen, .streak, .reward]
        default: []
        }
    }

    /// 다음 줄로 넘어가기 전까지 보여 주는 시간.
    var seconds: Double {
        switch self {
        case .panMap, .play, .record, .render, .streak: 3.8
        default: 3
        }
    }

    var barHighlights: Set<FirstRunBottomBarSketch.Item> {
        switch self {
        case .location: [.location]
        case .mapDisplay, .memoDisplay: [.menu]
        case .play: [.play]
        case .record: [.record]
        case .calendar: [.calendar]
        case .memoAdd: [.memo]
        case .summaryOpen: [.home]
        default: []
        }
    }

    /// 한 번 도는 단계 수와 단계마다의 시간.
    fileprivate var phases: (count: Int, seconds: Double) {
        switch self {
        case .panMap: (4, 0.85)
        case .play, .record, .render: (2, 3.4)
        case .streak: (8, 0.42)
        case .location, .memoAdd, .memoBrowse, .memoDisplay, .summaryOpen, .reward,
             .clipOpen, .clipSplit, .clipOverwrite: (2, 1)
        case .railColors: (4, 0.7)
        default: (3, 0.9)
        }
    }
}

/// 그림을 단계대로 되풀이한다. 동작 줄이기를 켜면 마지막 모습에 멈춘다.
private struct FirstRunCuePhases<Content: View>: View {
    let cue: FirstRunGuideCue
    @ViewBuilder let content: (Int) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let phases = cue.phases
        Group {
            if reduceMotion {
                content(phases.count - 1)
            } else {
                PhaseAnimator(Array(0..<phases.count)) { content($0) } animation: { _ in
                    .easeInOut(duration: phases.seconds)
                }
            }
        }
        .id(cue)
    }
}

/// 설명 단계의 그림. 지금 밝혀진 줄의 동작을 움직여 보여 준다.
struct FirstRunGuideStage: View {
    let step: FirstRunTutorialStep
    let cue: FirstRunGuideCue
    let date: Date
    let language: MapHomeLanguage

    var body: some View {
        switch step {
        case .sidebarCalendar:
            VStack(spacing: 12) {
                FirstRunRailSketch(cue: cue, date: date, language: language)
                bar
            }
        case .clipEditor:
            FirstRunClipSketch(cue: cue)
        case .memos, .summary, .map, .playback:
            VStack(spacing: 12) {
                FirstRunMapSketch(
                    cue: cue,
                    date: date,
                    language: language,
                    memoText: language.text("여기 또 오기", "Come back here")
                )
                bar
            }
        default:
            EmptyView()
        }
    }

    private var bar: some View {
        FirstRunBottomBarSketch(highlights: cue.barHighlights, date: date, language: language)
    }
}

/// 손가락과 강조 고리.
private struct FirstRunTouch: View {
    var size: CGFloat = 26

    var body: some View {
        Circle()
            .fill(Color.tpAccent.opacity(0.3))
            .overlay { Circle().stroke(Color.tpAccent, lineWidth: 2) }
            .frame(width: size, height: size)
    }
}

/// 3차 곡선 위를 따라 움직인다. 값 사이를 곡선으로 보간해 길에서 벗어나지 않는다.
private struct FirstRunRouteFollower: ViewModifier, @MainActor Animatable {
    var progress: Double
    let size: CGSize

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.position(FirstRunRouteCurve(size: size).point(at: progress))
    }
}

private struct FirstRunRouteCurve {
    let size: CGSize

    var start: CGPoint { CGPoint(x: size.width * 0.2, y: size.height * 0.68) }
    var end: CGPoint { CGPoint(x: size.width * 0.82, y: size.height * 0.28) }
    private var control1: CGPoint { CGPoint(x: size.width * 0.42, y: size.height * 0.75) }
    private var control2: CGPoint { CGPoint(x: size.width * 0.58, y: size.height * 0.2) }

    var path: Path {
        Path { path in
            path.move(to: start)
            path.addCurve(to: end, control1: control1, control2: control2)
        }
    }

    func point(at t: Double) -> CGPoint {
        let rest = 1 - t
        func axis(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
            rest * rest * rest * a + 3 * rest * rest * t * b + 3 * rest * t * t * c + t * t * t * d
        }
        return CGPoint(
            x: axis(start.x, control1.x, control2.x, end.x),
            y: axis(start.y, control1.y, control2.y, end.y)
        )
    }
}

/// 지도 그림: 길과 집과 고양이. 실제 지도 타일은 쓰지 않는다.
private struct FirstRunMapSketch: View {
    let cue: FirstRunGuideCue
    let date: Date
    let language: MapHomeLanguage
    var memoText: String?
    var height: CGFloat = 132

    var body: some View {
        GeometryReader { proxy in
            FirstRunCuePhases(cue: cue) { phase in
                scene(size: proxy.size, phase: phase)
            }
            .clipShape(RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous))
        }
        .frame(height: height)
    }

    private func scene(size: CGSize, phase: Int) -> some View {
        let curve = FirstRunRouteCurve(size: size)
        return ZStack {
            background(phase)
            ZStack {
                curve.path
                    .trim(from: 0, to: routeEnd(phase))
                    .stroke(Color.tpReferenceBlue, style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [2, 8]))
                place(MapHomeLocationDestination.home.iconAssetName, size: homeSize(phase))
                    .position(curve.start)
                if showsLevel {
                    Text(verbatim: "Lv.\(cue == .reward && phase == 1 ? 2 : 1)")
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.caption), weight: .bold))
                        .foregroundStyle(Color.tpInk)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.tpSurface, in: Capsule())
                        .position(x: curve.start.x, y: curve.start.y + 30)
                }
                place(MapHomeLocationDestination.company.iconAssetName, size: 36)
                    .position(curve.end)
                FirstRunMascot(scene: .walkLoop, size: 54)
                    .modifier(FirstRunRouteFollower(progress: catProgress(phase), size: size))
                memoNote(size: size, phase: phase)
            }
            .scaleEffect(cue == .panMap && phase == 3 ? 1.25 : 1)
            .offset(contentOffset(phase))
            overlay(size: size, curve: curve, phase: phase)
        }
    }

    private func place(_ asset: String, size: CGFloat) -> some View {
        Image(asset).resizable().scaledToFit().frame(width: size, height: size)
    }

    private func background(_ phase: Int) -> Color {
        guard cue == .mapDisplay else { return .tpBackground }
        return [Color.tpBackground, Color(hex: "#24303F"), Color(hex: "#DCEBD8")][phase]
    }

    private var showsLevel: Bool { cue == .summaryOpen || cue == .streak || cue == .reward }

    private func homeSize(_ phase: Int) -> CGFloat {
        cue == .reward && phase == 1 ? 54 : 42
    }

    private func routeEnd(_ phase: Int) -> CGFloat {
        switch cue {
        case .readRoute: [0, 0.5, 1][phase]
        case .play, .record: phase == 0 ? 0 : 1
        default: 1
        }
    }

    private func catProgress(_ phase: Int) -> Double {
        switch cue {
        case .readRoute: [0, 0.5, 1][phase]
        case .play, .record: phase == 0 ? 0 : 1
        case .railDrag: [0.15, 0.9, 0.5][phase]
        default: 0.55
        }
    }

    private func contentOffset(_ phase: Int) -> CGSize {
        switch cue {
        case .panMap: CGSize(width: phase == 1 ? -34 : 0, height: 0)
        case .location: phase == 0 ? CGSize(width: -46, height: 18) : .zero
        default: .zero
        }
    }

    @ViewBuilder
    private func memoNote(size: CGSize, phase: Int) -> some View {
        let opacity: Double? = switch cue {
        case .memoAdd: phase == 1 ? 1 : 0
        case .memoPin: phase == 2 ? 1 : 0
        case .memoBrowse: 1
        case .memoDisplay: phase == 1 ? 1 : 0.15
        default: nil
        }
        if let opacity, let memoText {
            Text(memoText)
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.caption), weight: .semibold))
                .foregroundStyle(Color.tpInk)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color(hex: "#F3C766").opacity(0.85), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .rotationEffect(.degrees(-3))
                .scaleEffect(opacity == 0 ? 0.3 : 1)
                .opacity(opacity)
                .position(x: size.width * 0.72, y: size.height * 0.72)
        }
    }

    @ViewBuilder
    private func overlay(size: CGSize, curve: FirstRunRouteCurve, phase: Int) -> some View {
        let midY = size.height * 0.5
        switch cue {
        case .panMap:
            FirstRunTouch()
                .position(x: size.width * [0.66, 0.4, 0.44, 0.3][phase], y: midY)
            FirstRunTouch()
                .opacity(phase >= 2 ? 1 : 0)
                .position(x: size.width * [0.66, 0.4, 0.56, 0.7][phase], y: midY)
        case .location:
            FirstRunTouch(size: phase == 1 ? 74 : 40)
                .opacity(phase == 1 ? 1 : 0.2)
                .position(curve.point(at: 0.55))
        case .otherDays:
            dateStrip(size: size, phase: phase)
        case .readRoute:
            FirstRunTouch(size: phase == 2 ? 58 : 30)
                .opacity(phase == 2 ? 1 : 0)
                .position(curve.start)
            FirstRunTouch(size: phase == 2 ? 58 : 30)
                .opacity(phase == 2 ? 1 : 0)
                .position(curve.end)
        case .play:
            badge("play.fill", tint: .tpAccent)
        case .record:
            RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous)
                .stroke(Color.tpHoliday, lineWidth: 3)
            badge("record.circle", tint: .tpHoliday)
        case .render:
            renderProgress(size: size, phase: phase)
        case .save:
            saveToPhotos(size: size, phase: phase)
        case .memoAdd:
            EmptyView()
        case .memoPin:
            FirstRunTouch(size: phase == 0 ? 26 : 54)
                .opacity(phase == 2 ? 0 : 1)
                .position(x: size.width * 0.72, y: size.height * 0.72)
        case .memoBrowse:
            memoList(size: size, phase: phase)
        case .memoDisplay:
            badge(phase == 1 ? "eye" : "eye.slash", tint: .tpAccent)
        case .summaryOpen:
            FirstRunTouch(size: phase == 1 ? 66 : 42)
                .position(curve.start)
        case .streak:
            HStack(spacing: 5) {
                ForEach(0..<7, id: \.self) { day in
                    Image(systemName: day < phase ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(day < phase ? Color.tpAccent : Color.tpSecondary)
                }
            }
            .position(x: size.width * 0.5, y: size.height * 0.12)
        case .reward:
            Image(systemName: "gift.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Color.tpAccent)
                .scaleEffect(phase == 1 ? 1 : 0.2)
                .opacity(phase == 1 ? 1 : 0)
                .position(x: size.width * 0.55, y: size.height * 0.3)
        default:
            EmptyView()
        }
    }

    private func badge(_ icon: String, tint: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: 32, height: 32)
            .background(Color.tpSurface, in: Circle())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(8)
    }

    private func dateStrip(size: CGSize, phase: Int) -> some View {
        HStack(spacing: 14) {
            ForEach(-3...1, id: \.self) { offset in
                Text(FirstRunGuideDay.text(date, offset: offset, language: language))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.caption), weight: .bold))
                    .foregroundStyle(offset == 0 ? Color.white : Color.tpInk)
                    .frame(width: 26, height: 26)
                    .background(offset == 0 ? Color.tpAccent : Color.tpSurface, in: Circle())
                    .opacity(offset == 0 || phase > 0 ? 1 : 0)
            }
        }
        .offset(x: phase == 2 ? 40 : 0)
        .position(x: size.width * 0.62, y: 24)
    }

    private func renderProgress(size: CGSize, phase: Int) -> some View {
        ZStack {
            Color.tpInk.opacity(0.45)
            VStack(spacing: 10) {
                Image(systemName: "film")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                Capsule()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: size.width * 0.5, height: 8)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Color.white)
                            .frame(width: size.width * (phase == 0 ? 0.02 : 0.5), height: 8)
                    }
            }
        }
    }

    private func saveToPhotos(size: CGSize, phase: Int) -> some View {
        let target = CGPoint(x: size.width * 0.86, y: size.height * 0.72)
        return ZStack {
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Color.tpAccent)
                .frame(width: 58, height: 58)
                .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.tpAccent)
                        .background(Color.tpSurface, in: Circle())
                        .scaleEffect(phase == 2 ? 1 : 0.1)
                        .opacity(phase == 2 ? 1 : 0)
                        .offset(x: 6, y: -6)
                }
                .position(target)
            RoundedRectangle(cornerRadius: TaptionCorner.small, style: .continuous)
                .fill(Color.tpInk)
                .frame(width: 92, height: 62)
                .overlay {
                    Image(systemName: "play.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                }
                .scaleEffect(phase == 0 ? 1 : 0.3)
                .opacity(phase == 2 ? 0 : 1)
                .position(phase == 0 ? CGPoint(x: size.width * 0.42, y: size.height * 0.5) : target)
        }
    }

    private func memoList(size: CGSize, phase: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "note.text")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.tpAccent)
            ForEach([0.9, 0.7, 0.8], id: \.self) { width in
                Capsule()
                    .fill(Color(hex: "#F3C766").opacity(0.85))
                    .frame(width: size.width * 0.34 * width, height: 9)
            }
        }
        .padding(10)
        .frame(width: size.width * 0.42, height: size.height, alignment: .topLeading)
        .background(Color.tpSurface)
        .offset(x: phase == 1 ? 0 : -size.width * 0.3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum FirstRunGuideDay {
    static func text(_ date: Date, offset: Int, language: MapHomeLanguage) -> String {
        let day = Calendar.current.date(byAdding: .day, value: offset, to: date) ?? date
        return day.formatted(.dateTime.day().locale(language.locale))
    }
}

/// 오른쪽 시간 막대 그림.
private struct FirstRunRailSketch: View {
    let cue: FirstRunGuideCue
    let date: Date
    let language: MapHomeLanguage

    private static let segments: [(color: Color, weight: CGFloat)] = [
        (.tpReferenceBlue, 2), (.tpReferenceMint, 3), (.tpReferenceRose, 1), (.tpReferenceBlue, 2),
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            FirstRunMapSketch(cue: cue, date: date, language: language, height: 180)
            FirstRunCuePhases(cue: cue) { phase in
                rail(phase)
            }
            .frame(width: 44)
        }
        .frame(height: 180)
    }

    private func rail(_ phase: Int) -> some View {
        VStack(spacing: 4) {
            Text(FirstRunGuideDay.text(date, offset: cue == .calendar ? phase - 2 : 0, language: language))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.bodyStrong), weight: .bold))
                .foregroundStyle(Color.tpInk)
                .background {
                    if cue == .calendar { FirstRunTouch(size: 34) }
                }
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.tpAccent)
                .rotationEffect(.degrees(cue == .railToggle && phase == 1 ? 180 : 0))
                .background {
                    if cue == .railToggle { FirstRunTouch(size: 26) }
                }
            VStack(spacing: 2) {
                ForEach(Self.segments.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Self.segments[index].color.opacity(segmentOpacity(index, phase: phase)))
                        .frame(height: 16 * Self.segments[index].weight)
                        .scaleEffect(x: cue == .railColors && index == phase ? 1.3 : 1)
                }
            }
            .frame(width: 26)
            .overlay(alignment: .trailing) {
                Capsule()
                    .fill(Color.tpInk)
                    .frame(width: 12, height: 5)
                    .overlay {
                        if cue == .railDrag { FirstRunTouch() }
                    }
                    .offset(x: 9, y: cue == .railDrag ? [-55, 55, 0][phase] : -6)
            }
            .scaleEffect(y: cue == .railToggle && phase == 1 ? 0.02 : 1, anchor: .top)
            .opacity(cue == .railToggle && phase == 1 ? 0 : 1)
            Image(systemName: "pencil")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.tpInk)
                .opacity(cue == .railToggle && phase == 1 ? 0 : 1)
        }
    }

    private func segmentOpacity(_ index: Int, phase: Int) -> Double {
        cue == .railColors && index != phase ? 0.25 : 0.75
    }
}

/// 앱의 클립 편집기처럼 위에서 아래로 시간이 흐르는 세로 클립 그림.
private struct FirstRunClipSketch: View {
    let cue: FirstRunGuideCue

    private struct Clip {
        let color: Color
        let top: CGFloat
        let height: CGFloat
    }

    private static let width: CGFloat = 96
    private static let playhead: CGFloat = 72

    var body: some View {
        FirstRunCuePhases(cue: cue) { phase in
            HStack(alignment: .top, spacing: 14) {
                ZStack(alignment: .top) {
                    ZStack(alignment: .top) {
                        ForEach(Array(clips(phase).enumerated()), id: \.offset) { _, clip in
                            RoundedRectangle(cornerRadius: TaptionCorner.small, style: .continuous)
                                .fill(clip.color)
                                .frame(width: Self.width, height: clip.height)
                                .offset(y: clip.top)
                        }
                    }
                    .compositingGroup()
                    .opacity(cue == .clipOpen && phase == 0 ? 0.3 : 0.75)
                    marks(phase)
                }
                .frame(width: Self.width, height: 150, alignment: .top)
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.tpAccent)
                    .frame(width: 44, height: 44)
                    .background { FirstRunTouch(size: 44) }
                    .scaleEffect(phase == 1 ? 1.1 : 0.9)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: 150)
    }

    private var icon: String {
        switch cue {
        case .clipOpen: "pencil"
        case .clipMove: "arrow.up.and.down"
        case .clipSplit: "scissors"
        default: "rectangle.stack"
        }
    }

    /// 뒤의 두 조각은 처음에 겹쳐 한 클립으로 보인다.
    private func clips(_ phase: Int) -> [Clip] {
        var move: CGFloat = 0
        var trim: CGFloat = 0
        if cue == .clipMove {
            move = phase == 0 ? 0 : 14
            trim = phase == 2 ? 18 : move
        }
        let isSplit = cue == .clipSplit && phase == 1
        let isOverwritten = cue == .clipOverwrite && phase == 1
        func color(_ base: Color) -> Color { isOverwritten ? .tpReferenceMint : base }
        return [
            Clip(color: color(.tpReferenceBlue), top: 0, height: 40),
            Clip(color: color(.tpReferenceMint), top: 44 + move, height: isSplit ? 25 : 36),
            Clip(color: color(.tpReferenceMint), top: (isSplit ? 73 : 64) + move, height: isSplit ? 27 : 36),
            Clip(color: color(.tpReferenceRose), top: 104 + move, height: 46 - trim),
        ]
    }

    @ViewBuilder
    private func marks(_ phase: Int) -> some View {
        switch cue {
        case .clipSplit:
            Capsule()
                .fill(Color.tpInk)
                .frame(width: Self.width + 16, height: 4)
                .offset(y: Self.playhead - 2)
        case .clipMove:
            FirstRunTouch()
                .offset(y: (phase == 2 ? 128 : 58) + (phase == 0 ? 0 : 14))
        default:
            EmptyView()
        }
    }
}

/// 하단 막대 그림. 실제 단추를 그대로 써서 앱과 같은 모양을 유지한다.
struct FirstRunBottomBarSketch: View {
    enum Item: CaseIterable {
        case menu, calendar, location, home, play, record, memo
    }

    let highlights: Set<Item>
    let date: Date
    let language: MapHomeLanguage

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Item.allCases, id: \.self) { item in
                button(item)
                    .background {
                        if highlights.contains(item) {
                            RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous)
                                .fill(Color.tpAccent.opacity(0.16))
                                .overlay {
                                    RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous)
                                        .stroke(Color.tpAccent, lineWidth: 2)
                                }
                        }
                    }
            }
        }
        .padding(.horizontal, 4)
        .mapHomeBottomBarPill()
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func button(_ item: Item) -> some View {
        switch item {
        case .menu: icon("line.3.horizontal", language.text("메뉴", "Menu"))
        case .calendar:
            MapHomeBottomBarButton(title: language.text("달력", "Calendar"), action: {}) {
                MapHomeCalendarGlyph(date: date, language: language)
            }
        case .location: icon("location.fill", language.text("현재 위치", "Location"))
        case .home: icon("house.fill", language.text("집", "Home"))
        case .play: icon("play.fill", language.text("재생", "Play"))
        case .record: icon("record.circle", language.text("녹화", "Record"))
        case .memo: icon("plus", language.text("메모", "Memo"))
        }
    }

    private func icon(_ name: String, _ title: String) -> some View {
        MapHomeBottomBarButton(title: title, action: {}) {
            TaptionBarIcon(systemImage: name)
        }
    }
}
