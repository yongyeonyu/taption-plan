import SwiftUI

/// 행동 구간을 동영상 편집기(NLE)처럼 다루는 화면.
///
/// * 대분류는 하루 24시간을 빈틈없이 채우는 전체 클립이다.
/// * 상세활동은 고른 클립 아래 서브클립 줄에 놓인다.
/// * 클립을 끌어 옮기고, 양 끝을 잡아 자르고, 재생 헤드에서 가르고, 지운다.
/// * 모든 편집은 원본 구간 안에서만 일어나고, 적용할 때 원본 구간별로 한 번에 저장된다.
struct MapHomeNLEClipEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let language: MapHomeLanguage
    let date: Date
    let segments: [MapHomeTimeRailSegment]
    let details: [MapHomeSectionDetail]
    let focusMinute: Int
    /// 레이아웃 확인용. 값이 있으면 처음부터 확대된 상태로 연다.
    let initialMinuteHeight: CGFloat?
    var onSaved: () -> Void

    @State private var track: NLETrack
    @State private var subTrack: NLETrack
    @State private var selectedClipID: String?
    @State private var selectedSubClipID: String?
    @State private var playheadMinute: Int
    @State private var minuteHeight: CGFloat = 2.4
    @State private var visibleStartMinute: Double = 0
    @State private var containerHeight: CGFloat = 0
    @State private var zoomBaseWidth: CGFloat = 0
    @State private var zoomBaseStartMinute: Double = 0
    @State private var panBaseStartMinute: Double = 0
    @State private var undoStack: [NLEEditorSnapshot] = []
    @State private var redoStack: [NLEEditorSnapshot] = []
    @State private var dragMode: NLEEditorDragMode = .none
    @State private var didPushUndoForDrag = false
    @State private var isSaving = false
    @State private var didCenter = false
    /// 가장자리로 끌어 화면이 흐른 만큼(분). 끄는 동안의 좌표를 같은 기준으로 맞춘다.
    @State private var dragScrollShift: Double = 0
    /// 센서 원본이나 상세활동에서 집어 든 결과. 대분류에 바로 반영할 수 있다.
    @State private var pick: NLEPick?

    init(
        model: AppModel,
        language: MapHomeLanguage,
        date: Date,
        segments: [MapHomeTimeRailSegment],
        details: [MapHomeSectionDetail],
        focusMinute: Int,
        initialMinuteHeight: CGFloat? = nil,
        onSaved: @escaping () -> Void
    ) {
        self.model = model
        self.language = language
        self.date = date
        self.segments = segments
        self.details = details
        self.focusMinute = focusMinute
        self.initialMinuteHeight = initialMinuteHeight
        self.onSaved = onSaved
        let built = Self.makeMainTrack(segments: segments)
        let initialClip = built.clip(atMinute: min(max(focusMinute, 0), NLETrack.dayMinutes - 1))
        _track = State(initialValue: built)
        _subTrack = State(initialValue: Self.makeSubTrack(details: details, segments: segments))
        _playheadMinute = State(initialValue: min(max(focusMinute, 0), NLETrack.dayMinutes))
        _selectedClipID = State(initialValue: initialClip?.id)
        _selectedSubClipID = State(initialValue: nil)
    }

    // MARK: - 본문

    var body: some View {
        // 하루는 위에서 아래로 흐른다. 왼쪽 눈금 옆으로 세 줄이 나란히 선다:
        // 내가 고치는 대분류, 센서가 그대로 기록한 원본, 그리고 상세활동 기록.
        //
        // 클립 줄만 화면 밖까지 넓혀 그린다. 하루가 화면 폭에 끼어 잘리는 대신
        // 위아래로 끝없이 이어지는 타임라인처럼 보이게 하려는 것이다. 머리말·
        // 선택 요약·도구 막대는 그대로 안쪽 여백을 지킨다.
        GeometryReader { proxy in
            let spacing: CGFloat = 12
            let headerHeight: CGFloat = 16
            let railHeight = max(220, proxy.size.height - (44 + headerHeight + 26 + 44 + spacing * 3 + 4))
            let bleed = Self.railBleed
            let railWidth = proxy.size.width + bleed * 2
            VStack(spacing: spacing) {
                header
                    .padding(.horizontal, bleed)
                VStack(alignment: .leading, spacing: 4) {
                    laneHeader(width: railWidth)
                        .frame(width: railWidth, height: headerHeight)
                    verticalRail
                        .frame(width: railWidth, height: railHeight)
                }
                // 왼쪽 눈금은 제자리에 두고 오른쪽으로만 넘치게 한다. 줄이 화면
                // 밖까지 이어지되 시각 라벨은 잘리지 않는다.
                .frame(maxWidth: .infinity, alignment: .leading)
                selectionSummary
                    .padding(.horizontal, bleed)
                toolbar
                    .padding(.horizontal, bleed)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Color.tpBackground.ignoresSafeArea())
    }

    /// 클립 줄이 화면 양옆으로 삐져나오는 폭.
    private static let railBleed: CGFloat = 14

    private var header: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Text(language.text("닫기", "Close"))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.tpReferenceRose)
                    .padding(.horizontal, 15)
                    .frame(minHeight: 38)
                    .background(Color.tpReferenceRose.opacity(0.10), in: Capsule())
            }
            .buttonStyle(.plain)
            Spacer()
            VStack(spacing: 1) {
                Text(language.text("클립 편집", "Clip editor"))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text(language.text("대분류 · 센서 원본 · 상세활동", "Main · sensor · details"))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.tpSecondary)
            }
            Spacer()
            Button {
                apply()
            } label: {
                Group {
                    if isSaving {
                        ProgressView().tint(.white)
                    } else {
                        Text(language.text("적용", "Apply"))
                    }
                }
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 15)
                .frame(minHeight: 38)
                .background(Color.tpReferenceBlue, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isSaving || !hasChanges)
            .opacity(isSaving || !hasChanges ? 0.45 : 1)
        }
        .frame(minHeight: 44)
    }

    // MARK: - 세로 타임라인

    /// 시각 눈금이 붙는 왼쪽 띠의 너비.
    private var gutterWidth: CGFloat { 36 }

    /// 줄 사이 틈.
    private var laneGap: CGFloat { 5 }

    /// 세 줄의 너비. 대분류가 가장 넓고, 센서 원본과 상세활동이 오른쪽에 나란히 선다.
    private struct NLELaneWidths {
        let main: CGFloat
        let sensor: CGFloat
        let detail: CGFloat

        init(total: CGFloat, gutter: CGFloat, gap: CGFloat) {
            let usable = max(90, total - gutter - gap * 2)
            let main = max(40, (usable * 0.44).rounded())
            let sensor = max(26, (usable * 0.24).rounded())
            self.main = main
            self.sensor = sensor
            self.detail = max(26, usable - main - sensor)
        }
    }

    /// 줄 이름표. 타임라인과 같은 너비 계산을 써서 세로줄과 딱 맞춘다.
    private func laneHeader(width: CGFloat) -> some View {
        let lanes = NLELaneWidths(total: width, gutter: gutterWidth, gap: laneGap)
        return HStack(spacing: laneGap) {
            Color.clear.frame(width: gutterWidth, height: 1)
            laneTitle(language.text("대분류", "Main"), width: lanes.main)
                .overlay(alignment: .trailing) {
                    if differingSegmentCount > 0 {
                        Text("\(differingSegmentCount)")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.tpAccent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.tpAccent.opacity(0.14), in: Capsule())
                    }
                }
            laneTitle(language.text("센서 원본", "Sensor"), width: lanes.sensor)
            laneTitle(language.text("상세활동", "Details"), width: lanes.detail)
        }
    }

    /// 센서 기록과 달라진 구간 수. 이름표 옆에 작게 붙는다.
    private var differingSegmentCount: Int {
        sourceSegments.filter { segment in
            let last = max(segment.startMinute, segment.endMinute - 1)
            return [segment.startMinute, last].contains { minute in
                track.clip(atMinute: minute)?.option.categoryID != segment.categoryID
            }
        }.count
    }

    private func laneTitle(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(Color.tpSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: width, alignment: .leading)
    }

    /// 하루 24시간을 세로로 세운 타임라인.
    ///
    /// 위에서 아래로 시간이 흐르고, 클립은 하루를 빈틈없이 채우며 쌓인다.
    /// 대분류만 고칠 수 있고, 센서 원본은 그대로 두고 견주어 보는 줄이다.
    private var verticalRail: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let height = max(120, proxy.size.height)
            let lanes = NLELaneWidths(total: width, gutter: gutterWidth, gap: laneGap)
            let sensorX = gutterWidth + lanes.main + laneGap
            let detailX = sensorX + lanes.sensor + laneGap
            let geometry = NLETimelineGeometry(
                minuteWidth: minuteHeight,
                visibleStartMinute: visibleStartMinute,
                visibleMinutes: Double(height) / Double(max(0.01, minuteHeight))
            )
            ZStack(alignment: .topLeading) {
                Color.tpSurface
                hourGrid(geometry: geometry, width: width)
                laneDivider(at: sensorX - laneGap / 2, height: height)
                laneDivider(at: detailX - laneGap / 2, height: height)
                mainColumn(geometry: geometry, x: gutterWidth, width: lanes.main)
                sourceColumn(geometry: geometry, x: sensorX, width: lanes.sensor)
                detailColumn(geometry: geometry, x: detailX, width: lanes.detail)
                playheadLine(geometry: geometry, width: width)
            }
            // 줄 안의 클립이 화면 밖까지 길어도 카드 밖으로 새지 않게 크기를 못 박는다.
            .frame(width: width, height: height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.tpLine, lineWidth: 1)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(geometry: geometry, width: width, height: height))
            .simultaneousGesture(magnifyGesture(height: height))
            .onAppear {
                containerHeight = height
                fitWholeDayIfNeeded(height: height)
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-nlePick"), pick == nil {
                    pick = sensorSegment(atMinute: playheadMinute).map { .sensor($0.id) }
                }
                #endif
            }
            .onChange(of: height) { _, newValue in
                containerHeight = newValue
                fitWholeDayIfNeeded(height: newValue)
            }
        }
    }

    private func laneDivider(at x: CGFloat, height: CGFloat) -> some View {
        Rectangle()
            .fill(Color.tpLine)
            .frame(width: 1, height: height)
            .offset(x: x)
            .allowsHitTesting(false)
    }

    private func hourGrid(geometry: NLETimelineGeometry, width: CGFloat) -> some View {
        Canvas { context, size in
            let step = gridStepMinutes
            let labelEvery = rulerLabelEveryMinutes
            var minute = Int(geometry.visibleStartMinute / Double(step)) * step
            while Double(minute) <= geometry.visibleEndMinute {
                let y = geometry.y(forMinute: Double(minute))
                if y >= -1, y <= size.height + 1 {
                    let isHour = minute % 60 == 0
                    var line = Path()
                    line.move(to: CGPoint(x: isHour ? gutterWidth : gutterWidth + 10, y: y))
                    line.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(
                        line,
                        with: .color(isHour ? Color.tpInk.opacity(0.14) : Color.tpInk.opacity(0.06)),
                        lineWidth: isHour ? 1 : 0.6
                    )
                    if minute % labelEvery == 0 {
                        // 맨 위 00시가 카드 모서리에 잘리지 않게 안쪽으로 붙인다.
                        let labelY = min(max(y, 7), size.height - 7)
                        context.draw(
                            Text(isHour ? String(format: "%02d", minute / 60) : Self.minuteLabel(minute))
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.tpSecondary),
                            at: CGPoint(x: gutterWidth - 7, y: labelY),
                            anchor: .trailing
                        )
                    }
                }
                minute += step
            }
        }
        .allowsHitTesting(false)
    }

    private func mainColumn(geometry: NLETimelineGeometry, x: CGFloat, width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(visibleClips(geometry: geometry)) { clip in
                let y = geometry.y(forMinute: Double(clip.startMinute))
                // 클립 사이에 1pt 틈을 둔다. 이웃한 클립이 한 덩어리로 보이지 않게.
                let blockHeight = max(3, geometry.height(minutes: Double(clip.lengthMinutes)) - 2)
                clipBlock(clip, width: width, blockHeight: blockHeight)
                    .frame(width: width, height: blockHeight)
                    .offset(y: y + 1)
            }
        }
        .frame(width: width, alignment: .topLeading)
        .offset(x: x)
    }

    private func clipBlock(_ clip: NLEClip, width: CGFloat, blockHeight: CGFloat) -> some View {
        let tint = Self.tint(for: clip.option.categoryID)
        let isSelected = clip.id == selectedClipID
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.95), tint.opacity(0.72)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.white.opacity(isSelected ? 0.95 : 0.35), lineWidth: isSelected ? 2.5 : 1)
            if blockHeight >= 26, width > 34 {
                VStack(alignment: .leading, spacing: 1) {
                    Text(clip.option.title)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if blockHeight >= 44, width > 78 {
                        Text(Self.rangeLabel(clip.startMinute, clip.endMinute))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .opacity(0.88)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.top, 5)
                .frame(width: width, alignment: .topLeading)
            }
            if isSelected, blockHeight >= 22 {
                VStack(spacing: 0) {
                    trimHandle(isStart: true)
                    Spacer(minLength: 0)
                    trimHandle(isStart: false)
                }
                .frame(width: width)
            }
        }
        .opacity(clip.isGap ? 0.55 : 1)
        .shadow(color: .black.opacity(isSelected ? 0.16 : 0.05), radius: isSelected ? 3 : 1, y: 1)
    }

    private func trimHandle(isStart: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color.white)
            .frame(height: 5)
            .overlay {
                Capsule()
                    .fill(Color.tpInk.opacity(0.45))
                    .frame(width: 16, height: 2)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .accessibilityLabel(
                isStart
                    ? language.text("시작 자르기", "Trim start")
                    : language.text("끝 자르기", "Trim end")
            )
    }

    /// 센서가 기록한 그대로의 원본 구간. 고칠 수 없고, 견주어 보기만 한다.
    private var sourceSegments: [MapHomeTimeRailSegment] {
        segments
            .filter { $0.endMinute > $0.startMinute }
            .sorted { $0.startMinute < $1.startMinute }
    }

    private func sourceColumn(geometry: NLETimelineGeometry, x: CGFloat, width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(sourceSegments) { segment in
                let y = geometry.y(forMinute: Double(segment.startMinute))
                let barHeight = max(3, geometry.height(minutes: Double(segment.endMinute - segment.startMinute)) - 2)
                sourceBar(segment, width: width, height: barHeight)
                    .frame(width: width, height: barHeight)
                    .offset(y: y + 1)
            }
        }
        .frame(width: width, alignment: .topLeading)
        .offset(x: x)
    }

    private func sourceBar(_ segment: MapHomeTimeRailSegment, width: CGFloat, height: CGFloat) -> some View {
        let tint = Self.tint(for: segment.categoryID)
        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(tint.opacity(0.20))
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(tint.opacity(0.55), lineWidth: 0.8)
            }
            .overlay(alignment: .topLeading) {
                if height >= 18, width > 30 {
                    Text(segment.title)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 4)
                        .padding(.top, 2)
                }
            }
    }

    /// 상세활동 기록. 하루 전체가 자기 원본 구간 안에 놓인다.
    private func detailColumn(geometry: NLETimelineGeometry, x: CGFloat, width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(subTrack.clips) { clip in
                let y = geometry.y(forMinute: Double(clip.startMinute))
                let barHeight = max(3, geometry.height(minutes: Double(clip.lengthMinutes)) - 2)
                detailBar(clip, width: width, height: barHeight)
                    .frame(width: width, height: barHeight)
                    .offset(y: y + 1)
            }
        }
        .frame(width: width, alignment: .topLeading)
        .offset(x: x)
    }

    private func detailBar(_ clip: NLEClip, width: CGFloat, height: CGFloat) -> some View {
        let tint = Self.tint(for: clip.option.categoryID)
        let isSelected = clip.id == selectedSubClipID
        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(tint.opacity(0.88))
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(
                        Color.white.opacity(isSelected ? 0.95 : 0.35),
                        lineWidth: isSelected ? 1.6 : 0.7
                    )
            }
            .overlay(alignment: .topLeading) {
                if height >= 15, width > 28 {
                    Text(clip.option.title)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 4)
                        .padding(.top, 1)
                }
            }
    }

    private func playheadLine(geometry: NLETimelineGeometry, width: CGFloat) -> some View {
        let y = geometry.y(forMinute: Double(playheadMinute))
        return ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color.tpAccent)
                .frame(width: width, height: 1.5)
            Text(Self.minuteLabel(playheadMinute))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.tpAccent, in: Capsule())
                .offset(x: gutterWidth + 12, y: -9)
        }
        .frame(width: width, height: 1.5, alignment: .leading)
        .offset(y: y - 0.75)
        .allowsHitTesting(false)
    }

    // MARK: - 선택 정보

    /// 집어 든 결과. 센서 원본 구간이거나 상세활동 기록이다.
    private enum NLEPick: Equatable {
        case sensor(String)
        case detail(String)
    }

    private var selectionSummary: some View {
        let clip = selectedClip
        return HStack(spacing: 8) {
            if let pick {
                pickRow(pick)
            } else if let clip {
                Circle()
                    .fill(Self.tint(for: clip.option.categoryID))
                    .frame(width: 10, height: 10)
                Text(clip.option.title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .lineLimit(1)
                Text(Self.rangeLabel(clip.startMinute, clip.endMinute))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.tpSecondary)
                if let sensor = sensorSegment(atMinute: clip.startMinute),
                   sensor.categoryID != clip.option.categoryID {
                    // 센서는 이렇게 기록했는데 지금은 다르다. 눌러서 되돌린다.
                    Button {
                        self.pick = .sensor(sensor.id)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 8, weight: .bold))
                            Text(language.text("센서 \(sensor.title)", "Sensor \(sensor.title)"))
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .lineLimit(1)
                        }
                        .foregroundStyle(Color.tpAccent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.tpAccent.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(Self.durationLabel(clip.lengthMinutes, language: language))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.tpSecondary)
                }
                if clip.isGap {
                    Text(language.text("미확인", "Unconfirmed"))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.tpInk.opacity(0.08), in: Capsule())
                        .foregroundStyle(Color.tpSecondary)
                }
            } else {
                Text(language.text("클립을 고르세요", "Select a clip"))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.tpSecondary)
            }
            Spacer(minLength: 0)
            Text(Self.minuteLabel(playheadMinute))
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.tpAccent)
        }
        .frame(height: 26)
    }

    @ViewBuilder
    private func pickRow(_ pick: NLEPick) -> some View {
        switch pick {
        case .sensor(let id):
            if let segment = sourceSegments.first(where: { $0.id == id }) {
                pickContent(
                    tint: Self.tint(for: segment.categoryID),
                    lane: language.text("센서 원본", "Sensor"),
                    title: segment.title,
                    range: Self.rangeLabel(segment.startMinute, segment.endMinute)
                ) {
                    restoreSensorSegment(segment)
                }
            }
        case .detail(let id):
            if let sub = subTrack.clip(id) {
                pickContent(
                    tint: Self.tint(for: sub.option.categoryID),
                    lane: language.text("상세활동", "Details"),
                    title: sub.option.title,
                    range: Self.rangeLabel(sub.startMinute, sub.endMinute)
                ) {
                    promoteDetail(sub)
                }
            }
        }
    }

    private func pickContent(
        tint: Color,
        lane: String,
        title: String,
        range: String,
        apply: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(tint)
                .frame(width: 9, height: 9)
            Text(lane)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(Color.tpSecondary)
                .lineLimit(1)
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .lineLimit(1)
            Text(range)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.tpSecondary)
                .lineLimit(1)
            Button(action: apply) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 9, weight: .bold))
                    Text(language.text("반영", "Use"))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .frame(height: 23)
                .background(Color.tpAccent, in: Capsule())
            }
            .buttonStyle(.plain)
            Button {
                self.pick = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 도구

    private var toolbar: some View {
        HStack(spacing: 8) {
            categoryMenu
            toolButton(
                title: "",
                systemImage: "scissors",
                isEnabled: splitTarget != nil,
                label: language.text("가르기", "Split")
            ) {
                splitAtPlayhead()
            }
            toolButton(
                title: "",
                systemImage: "trash",
                isEnabled: selectedClip != nil && selectedClip?.isGap == false,
                label: language.text("지우기", "Clear")
            ) {
                deleteSelection()
            }
            toolButton(
                title: "",
                systemImage: "arrow.uturn.backward",
                isEnabled: !undoStack.isEmpty,
                label: language.text("되돌리기", "Undo")
            ) {
                undo()
            }
            toolButton(
                title: "",
                systemImage: "arrow.uturn.forward",
                isEnabled: !redoStack.isEmpty,
                label: language.text("다시", "Redo")
            ) {
                redo()
            }
            Spacer(minLength: 0)
            toolButton(
                title: "",
                systemImage: "arrow.up.and.down",
                isEnabled: true,
                label: language.text("전체 보기", "Fit whole day")
            ) {
                fitWholeDay()
            }
        }
        .frame(height: 44)
    }

    private var categoryMenu: some View {
        Menu {
            ForEach(categoryOptions) { category in
                Button {
                    applyCategory(category)
                } label: {
                    Label(category.localizedTitle(language), systemImage: category.systemImage)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "square.grid.2x2")
                Text(language.text("분류", "Category"))
                    .lineLimit(1)
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.tpInk)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Color.tpSurface, in: Capsule())
            .overlay { Capsule().stroke(Color.tpLine, lineWidth: 1) }
        }
        .disabled(activeClip == nil)
        .opacity(activeClip == nil ? 0.45 : 1)
    }

    private func toolButton(
        title: String,
        systemImage: String,
        isEnabled: Bool,
        label: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                if !title.isEmpty {
                    Text(title).lineLimit(1)
                }
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.tpInk)
            .padding(.horizontal, title.isEmpty ? 0 : 10)
            .frame(minWidth: 40, minHeight: 36)
            .background(Color.tpSurface, in: Capsule())
            .overlay { Capsule().stroke(Color.tpLine, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(label ?? title)
    }

    // MARK: - 제스처

    /// 한 손가락은 클립 옮기기·자르기·재생 헤드 이동, 두 손가락은 확대다.
    /// 하루가 세로로 흐르므로 모든 이동은 위아래로 일어난다.
    private func dragGesture(
        geometry: NLETimelineGeometry,
        width: CGFloat,
        height: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // 두 손가락 확대 중에는 클립이 끌려가지 않게 한다.
                guard zoomBaseWidth <= 0 else { return }
                if dragMode == .none {
                    dragMode = resolveDragMode(at: value.startLocation, geometry: geometry, width: width)
                    didPushUndoForDrag = false
                    panBaseStartMinute = visibleStartMinute
                    dragScrollShift = 0
                }
                let rawMinute = geometry.minute(forY: value.location.y) + dragScrollShift
                let minute = Int(rawMinute.rounded())
                switch dragMode {
                case .none:
                    break
                case .pan:
                    let deltaMinutes = Double(value.translation.height) / Double(max(0.01, minuteHeight))
                    setVisibleStart(panBaseStartMinute - deltaMinutes)
                case .scrub:
                    playheadMinute = min(max(minute, 0), NLETrack.dayMinutes)
                case let .move(lane, id, originMinute, grabMinute):
                    pushUndoIfNeeded()
                    let target = originMinute + (minute - grabMinute)
                    let snapped = NLESnapPolicy.snapped(target, to: snapTargets(lane: lane, excluding: id))
                    moveClip(lane: lane, id: id, toStartMinute: snapped)
                case let .trimStart(lane, id):
                    pushUndoIfNeeded()
                    let snapped = NLESnapPolicy.snapped(minute, to: snapTargets(lane: lane, excluding: id))
                    trimClip(lane: lane, id: id, edge: .start, toMinute: snapped)
                case let .trimEnd(lane, id):
                    pushUndoIfNeeded()
                    let snapped = NLESnapPolicy.snapped(minute, to: snapTargets(lane: lane, excluding: id))
                    trimClip(lane: lane, id: id, edge: .end, toMinute: snapped)
                }
                // 위·아래 끝까지 끌면 화면이 따라 흐른다.
                if dragMode != .pan {
                    autoScroll(atY: value.location.y, height: height)
                }
            }
            .onEnded { value in
                let moved = abs(value.translation.width) + abs(value.translation.height)
                if moved < 4, dragMode != .scrub, dragMode != .none {
                    handleTap(at: value.startLocation, geometry: geometry, width: width)
                }
                dragMode = .none
                didPushUndoForDrag = false
                dragScrollShift = 0
            }
    }

    private func magnifyGesture(height: CGFloat) -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                if zoomBaseWidth <= 0 {
                    zoomBaseWidth = minuteHeight
                    zoomBaseStartMinute = visibleStartMinute
                }
                let base = zoomBaseWidth
                let anchorY = min(max(value.startAnchor.y, 0), height)
                let anchorMinute = zoomBaseStartMinute + Double(anchorY) / Double(max(0.01, base))
                let next = min(max(base * value.magnification, 0.22), 12)
                minuteHeight = next
                setVisibleStart(anchorMinute - Double(anchorY) / Double(max(0.01, next)))
            }
            .onEnded { _ in
                zoomBaseWidth = 0
            }
    }

    // MARK: - 상태

    private struct NLEEditorSnapshot: Equatable {
        var main: [NLEClip]
        var sub: [NLEClip]
        var selectedClipID: String?
        var selectedSubClipID: String?
    }

    /// 대분류 줄과 서브클립 띠 중 어디를 만지고 있는지.
    private enum NLEEditorLane: Equatable {
        case main
        case sub
    }

    private enum NLEEditorDragMode: Equatable {
        case none
        case pan
        case scrub
        case move(lane: NLEEditorLane, id: String, originMinute: Int, grabMinute: Int)
        case trimStart(lane: NLEEditorLane, id: String)
        case trimEnd(lane: NLEEditorLane, id: String)
    }

    private var selectedClip: NLEClip? {
        selectedClipID.flatMap { track.clip($0) }
    }

    /// 분류 메뉴가 향하는 클립. 서브클립을 골랐으면 서브클립이 먼저다.
    private var activeClip: NLEClip? {
        if let selectedSubClipID, let sub = subTrack.clip(selectedSubClipID) {
            return sub
        }
        return selectedClip
    }

    private var isSubClipActive: Bool {
        activeSubClip != nil
    }

    private var activeSubClip: NLEClip? {
        selectedSubClipID.flatMap { subTrack.clip($0) }
    }

    private var splitTarget: NLEClip? {
        if let selectedSubClipID, let sub = subTrack.clip(selectedSubClipID) {
            return sub
        }
        if let selectedClip, selectedClip.contains(minute: playheadMinute) {
            return selectedClip
        }
        return track.clip(atMinute: playheadMinute)
    }

    private var hasChanges: Bool {
        track.clips.contains(where: \.isDirty) || subTrack.clips.contains(where: \.isDirty)
    }

    private var categoryOptions: [MapHomeSidebarMajorCategory] {
        MapHomeSidebarMajorCategory.all(categoryColors: model.settings.mapCategoryColors)
            + model.settings.mapUserActivityCategories.map(MapHomeSidebarMajorCategory.custom)
    }

    private func visibleClips(geometry: NLETimelineGeometry) -> [NLEClip] {
        track.clips.filter {
            Double($0.endMinute) >= geometry.visibleStartMinute
                && Double($0.startMinute) <= geometry.visibleEndMinute
        }
    }

    /// 눈금선 간격. 하루 전체를 볼 때는 한 시간, 확대하면 30·15분.
    private var gridStepMinutes: Int {
        switch minuteHeight {
        case ..<0.7: 60
        case ..<2.2: 30
        default: 15
        }
    }

    /// 눈금에 시각을 적는 간격. 하루 전체를 볼 때는 세 시간마다 적는다.
    private var rulerLabelEveryMinutes: Int {
        switch minuteHeight {
        case ..<0.55: 180
        case ..<1.4: 60
        default: 30
        }
    }

    // MARK: - 동작

    private func setVisibleStart(_ value: Double) {
        let visible = Double(max(1, containerHeight)) / Double(max(0.01, minuteHeight))
        let maximum = max(0, Double(NLETrack.dayMinutes) - visible)
        visibleStartMinute = min(max(value, 0), maximum)
    }

    /// 처음 열면 하루 24시간이 한눈에 들어오게 맞춘다. 확대는 두 손가락으로 한다.
    private func fitWholeDayIfNeeded(height: CGFloat) {
        guard !didCenter, height > 1 else { return }
        didCenter = true
        if let initialMinuteHeight {
            minuteHeight = initialMinuteHeight
            let visible = Double(height) / Double(initialMinuteHeight)
            setVisibleStart(Double(focusMinute) - visible / 2)
            return
        }
        minuteHeight = max(0.22, height / CGFloat(NLETrack.dayMinutes))
        visibleStartMinute = 0
    }

    /// 클립을 끄는 동안 위·아래 가장자리에 닿으면 화면을 이어서 흐르게 한다.
    private func autoScroll(atY y: CGFloat, height: CGFloat) {
        guard minuteHeight > 0.01, height > 60 else { return }
        let band: CGFloat = 26
        var delta: Double = 0
        if y < band {
            delta = -Double(band - y) / Double(minuteHeight)
        } else if y > height - band {
            delta = Double(y - (height - band)) / Double(minuteHeight)
        }
        guard delta != 0 else { return }
        let before = visibleStartMinute
        setVisibleStart(visibleStartMinute + delta)
        dragScrollShift += visibleStartMinute - before
    }

    private func fitWholeDay() {
        guard containerHeight > 1 else { return }
        minuteHeight = max(0.22, containerHeight / CGFloat(NLETrack.dayMinutes))
        visibleStartMinute = 0
    }

    private func resolveDragMode(
        at point: CGPoint,
        geometry: NLETimelineGeometry,
        width: CGFloat
    ) -> NLEEditorDragMode {
        let minute = Int(geometry.minute(forY: point.y).rounded())
        // 왼쪽 눈금 띠를 끌면 재생 헤드가 움직인다.
        if point.x <= gutterWidth { return .scrub }
        if abs(geometry.y(forMinute: Double(playheadMinute)) - point.y) <= 9 { return .scrub }
        let lanes = NLELaneWidths(total: width, gutter: gutterWidth, gap: laneGap)
        let sensorX = gutterWidth + lanes.main + laneGap
        let detailX = sensorX + lanes.sensor + laneGap
        // 상세활동 줄
        if point.x >= detailX - laneGap {
            if let sub = subTrack.clip(atMinute: minute) {
                if selectedSubClipID == sub.id {
                    let topY = geometry.y(forMinute: Double(sub.startMinute))
                    let bottomY = geometry.y(forMinute: Double(sub.endMinute))
                    if abs(point.y - topY) <= 9, sub.lengthMinutes > 1 {
                        return .trimStart(lane: .sub, id: sub.id)
                    }
                    if abs(point.y - bottomY) <= 9, sub.lengthMinutes > 1 {
                        return .trimEnd(lane: .sub, id: sub.id)
                    }
                }
                selectedSubClipID = sub.id
                return .move(lane: .sub, id: sub.id, originMinute: sub.startMinute, grabMinute: minute)
            }
            selectedSubClipID = nil
            if let clip = track.clip(atMinute: minute) { selectedClipID = clip.id }
            return .pan
        }
        // 센서 원본 줄은 읽기 전용이다. 누르면 같은 시각의 대분류만 골라 준다.
        if point.x >= sensorX - laneGap {
            selectedSubClipID = nil
            if let clip = track.clip(atMinute: minute) { selectedClipID = clip.id }
            return .pan
        }
        guard let clip = track.clip(atMinute: minute) else {
            selectedSubClipID = nil
            return .pan
        }
        if let selected = selectedClip, selected.id == clip.id {
            let topY = geometry.y(forMinute: Double(clip.startMinute))
            let bottomY = geometry.y(forMinute: Double(clip.endMinute))
            if abs(point.y - topY) <= 12, clip.lengthMinutes > NLETrack.minimumClipMinutes {
                return .trimStart(lane: .main, id: clip.id)
            }
            if abs(point.y - bottomY) <= 12, clip.lengthMinutes > NLETrack.minimumClipMinutes {
                return .trimEnd(lane: .main, id: clip.id)
            }
        }
        selectedClipID = clip.id
        selectedSubClipID = nil
        return .move(lane: .main, id: clip.id, originMinute: clip.startMinute, grabMinute: minute)
    }

    /// 그 시각을 덮는 센서 원본 구간.
    private func sensorSegment(atMinute minute: Int) -> MapHomeTimeRailSegment? {
        sourceSegments.first { minute >= $0.startMinute && minute < $0.endMinute }
    }

    private func differsFromSensor(_ clip: NLEClip) -> Bool {
        guard let segment = sensorSegment(atMinute: clip.startMinute) else { return false }
        return segment.categoryID != clip.option.categoryID
    }

    /// 센서 원본 구간을 그대로 대분류에 되돌린다. 그 구간은 다시 한 덩어리가 된다.
    private func restoreSensorSegment(_ segment: MapHomeTimeRailSegment) {
        guard let anchor = track.clip(atMinute: segment.startMinute) else { return }
        pushUndo()
        let option = Self.option(
            forCategoryID: segment.categoryID,
            title: segment.title,
            behavior: segment.behavior
        )
        track.replace(segment.startMinute..<segment.endMinute, with: option, parent: anchor.parent)
        selectedClipID = track.clip(atMinute: segment.startMinute)?.id
        selectedSubClipID = nil
        pick = nil
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// 상세활동 기록을 그 구간의 대분류로 올린다.
    private func promoteDetail(_ sub: NLEClip) {
        guard let anchor = track.clip(atMinute: sub.startMinute) else { return }
        pushUndo()
        track.replace(sub.startMinute..<sub.endMinute, with: sub.option, parent: anchor.parent)
        selectedClipID = track.clip(atMinute: sub.startMinute)?.id
        selectedSubClipID = nil
        pick = nil
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// 손가락이 거의 움직이지 않았으면 누른 것이다. 줄에 따라 집어 든다.
    private func handleTap(at point: CGPoint, geometry: NLETimelineGeometry, width: CGFloat) {
        let minute = Int(geometry.minute(forY: point.y).rounded())
        defer { UISelectionFeedbackGenerator().selectionChanged() }
        let lanes = NLELaneWidths(total: width, gutter: gutterWidth, gap: laneGap)
        let sensorX = gutterWidth + lanes.main + laneGap
        let detailX = sensorX + lanes.sensor + laneGap
        if point.x >= detailX - laneGap {
            pick = subTrack.clip(atMinute: minute).map { .detail($0.id) }
            return
        }
        if point.x >= sensorX - laneGap {
            pick = sensorSegment(atMinute: minute).map { .sensor($0.id) }
            return
        }
        pick = nil
    }

    private func snapTargets(lane: NLEEditorLane, excluding id: String) -> [Int] {
        NLESnapPolicy.targets(
            for: lane == .main ? track : subTrack,
            excluding: id,
            playheadMinute: playheadMinute
        )
    }

    @discardableResult
    private func moveClip(lane: NLEEditorLane, id: String, toStartMinute minute: Int) -> Bool {
        switch lane {
        case .main:
            let moved = track.move(id, toStartMinute: minute)
            if moved { selectedClipID = id }
            return moved
        case .sub:
            let moved = subTrack.move(id, toStartMinute: minute)
            if moved { selectedSubClipID = id }
            return moved
        }
    }

    private func trimClip(lane: NLEEditorLane, id: String, edge: NLEClipEdge, toMinute minute: Int) {
        switch lane {
        case .main:
            track.trim(id, edge: edge, toMinute: minute)
        case .sub:
            subTrack.trim(id, edge: edge, toMinute: minute)
        }
    }

    private func splitAtPlayhead() {
        if let currentSubID = selectedSubClipID, subTrack.clip(currentSubID) != nil {
            let target = subTrack.clip(currentSubID)?.contains(minute: playheadMinute) == true
                ? currentSubID
                : subTrack.clip(atMinute: playheadMinute)?.id
            guard let target else { return }
            pushUndo()
            if let newID = subTrack.split(target, atMinute: playheadMinute) {
                selectedSubClipID = newID
            }
            return
        }
        guard let clip = splitTarget, clip.contains(minute: playheadMinute) else { return }
        pushUndo()
        if let newID = track.split(clip.id, atMinute: playheadMinute) {
            selectedClipID = newID
        }
    }

    private func deleteSelection() {
        pushUndo()
        if let selectedSubClipID, let sub = subTrack.clip(selectedSubClipID) {
            // 상세활동을 지우면 그 자리는 그 구간의 대분류로 돌아간다.
            subTrack.delete(sub.id, fallback: sub.parent.fillOption)
            self.selectedSubClipID = nil
            return
        }
        guard let clip = selectedClip, !clip.isGap else { return }
        track.delete(clip.id)
        selectedClipID = track.clip(atMinute: clip.startMinute)?.id
    }

    private func applyCategory(_ category: MapHomeSidebarMajorCategory) {
        guard let clip = activeClip else { return }
        pushUndo()
        pick = nil
        let option = Self.option(for: category, language: language)
        if isSubClipActive {
            subTrack.setOption(clip.id, to: option)
        } else {
            track.setOption(clip.id, to: option)
        }
    }

    private func pushUndo() {
        undoStack.append(currentSnapshot)
        if undoStack.count > 40 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func pushUndoIfNeeded() {
        guard !didPushUndoForDrag else { return }
        didPushUndoForDrag = true
        pushUndo()
    }

    private var currentSnapshot: NLEEditorSnapshot {
        NLEEditorSnapshot(
            main: track.snapshot(),
            sub: subTrack.snapshot(),
            selectedClipID: selectedClipID,
            selectedSubClipID: selectedSubClipID
        )
    }

    private func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(currentSnapshot)
        restore(snapshot)
    }

    private func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(currentSnapshot)
        restore(snapshot)
    }

    private func restore(_ snapshot: NLEEditorSnapshot) {
        track.restore(snapshot.main)
        subTrack.restore(snapshot.sub)
        selectedClipID = snapshot.selectedClipID
        selectedSubClipID = snapshot.selectedSubClipID
    }

    private func apply() {
        let dayStart = Calendar.autoupdatingCurrent.startOfDay(for: date)
        // 대분류를 먼저, 상세활동을 나중에 저장한다. 상세활동이 위에 남아야 한다.
        // 상세활동이 비운 자리는 그 시각의 대분류가 이어받는다.
        var detailTrack = subTrack
        for clip in detailTrack.clips where clip.isDirty {
            guard let main = track.clip(atMinute: clip.startMinute) else { continue }
            detailTrack.setFillOption(main.option, forClipID: clip.id)
        }
        let requests = track.editRequests(dayStart: dayStart)
            + detailTrack.editRequests(dayStart: dayStart)
        guard !requests.isEmpty else {
            dismiss()
            return
        }
        isSaving = true
        Task { @MainActor in
            let saved = await model.applyClipEditRequests(requests)
            isSaving = false
            guard saved else { return }
            onSaved()
            dismiss()
        }
    }

    // MARK: - 만들기

    /// 하루 구간을 클립으로 만든다.
    ///
    /// 클립의 원본 구간은 자기 기록뿐 아니라 옆의 빈 시간까지 품는다. 그래야
    /// 동영상 편집기처럼 클립을 빈 자리로 끌어 옮기거나 늘릴 수 있다. 빈 시간에는
    /// 원본 기록이 없으므로 지어내는 데이터도 없다.
    static func makeMainTrack(segments: [MapHomeTimeRailSegment]) -> NLETrack {
        let ordered = segments
            .filter { $0.endMinute > $0.startMinute }
            .sorted { $0.startMinute < $1.startMinute }
        var spans: [(segment: MapHomeTimeRailSegment, start: Int, end: Int)] = []
        var cursor = 0
        for segment in ordered {
            let start = max(segment.startMinute, cursor)
            let end = min(segment.endMinute, NLETrack.dayMinutes)
            guard start < end else { continue }
            spans.append((segment, start, end))
            cursor = end
        }
        guard !spans.isEmpty else {
            return NLETrack(clips: [])
        }

        // 원본 구간을 하루 전체로 늘려 잇는다. 가운데 빈 시간은 앞 구간이,
        // 맨 앞·맨 뒤 빈 시간은 그 구간이 품는다.
        var parents: [Range<Int>] = spans.map { $0.start..<$0.end }
        for index in parents.indices {
            if index > 0 {
                parents[index - 1] = parents[index - 1].lowerBound..<parents[index].lowerBound
            }
        }
        parents[0] = 0..<parents[0].upperBound
        parents[parents.count - 1] = parents[parents.count - 1].lowerBound..<NLETrack.dayMinutes

        let clips = spans.enumerated().compactMap { index, span -> NLEClip? in
            let option = option(
                forCategoryID: span.segment.categoryID,
                title: span.segment.title,
                behavior: span.segment.behavior
            )
            let region = parents[index]
            let parent = NLEClipParent(
                startMinute: region.lowerBound,
                endMinute: region.upperBound,
                sourceIDs: span.segment.sourceIDs,
                option: option,
                fillOption: ActivitySectionOverrideEngine.unconfirmedOption
            )
            return NLEClip(
                id: "main|\(span.segment.id)",
                option: option,
                startMinute: span.start,
                endMinute: span.end,
                parent: parent,
                origin: NLEClipOrigin(
                    startMinute: span.start,
                    endMinute: span.end,
                    option: option
                )
            )
        }
        return NLETrack(clips: clips)
    }

    /// 상세활동 기록을 하루 전체에 걸쳐 세운다.
    ///
    /// 각 기록의 울타리는 자기가 속한 원본 구간이다. 그래서 상세활동을 그 구간
    /// 안에서 옮기거나 자를 수는 있어도, 다른 구간으로 넘어가지는 않는다.
    static func makeSubTrack(
        details: [MapHomeSectionDetail],
        segments: [MapHomeTimeRailSegment]
    ) -> NLETrack {
        let ordered = segments
            .filter { $0.endMinute > $0.startMinute }
            .sorted { $0.startMinute < $1.startMinute }
        let clips = details.compactMap { detail -> NLEClip? in
            guard detail.endMinute > detail.startMinute else { return nil }
            let owner = ordered.first {
                detail.startMinute >= $0.startMinute && detail.endMinute <= $0.endMinute
            } ?? ordered.first {
                detail.startMinute < $0.endMinute && detail.endMinute > $0.startMinute
            }
            let detailOption = option(
                forCategoryID: detail.categoryID,
                title: detail.title,
                behavior: detail.behavior
            )
            let fill = owner.map {
                option(forCategoryID: $0.categoryID, title: $0.title, behavior: $0.behavior)
            } ?? ActivitySectionOverrideEngine.unconfirmedOption
            let parent = NLEClipParent(
                startMinute: owner?.startMinute ?? detail.startMinute,
                endMinute: owner?.endMinute ?? detail.endMinute,
                sourceIDs: [detail.id],
                option: detailOption,
                fillOption: fill
            )
            return NLEClip(
                id: "sub|\(detail.id.uuidString)",
                option: detailOption,
                startMinute: detail.startMinute,
                endMinute: detail.endMinute,
                parent: parent,
                origin: NLEClipOrigin(
                    startMinute: detail.startMinute,
                    endMinute: detail.endMinute,
                    option: detailOption
                )
            )
        }
        return NLETrack(clips: clips, fillsGaps: false)
    }

    static func option(
        forCategoryID categoryID: String,
        title: String,
        behavior: String?
    ) -> ActivityCorrectionOption {
        ActivityCorrectionOption(
            id: "clip.\(categoryID).\(behavior ?? "none")",
            title: title,
            behavior: behavior,
            categoryID: categoryID,
            systemImage: MapHomeSidebarMajorCategory.all
                .first { $0.id == categoryID }?
                .systemImage ?? "circle.fill",
            isAutomatic: false,
            isCustom: false
        )
    }

    static func option(
        for category: MapHomeSidebarMajorCategory,
        language: MapHomeLanguage
    ) -> ActivityCorrectionOption {
        if category.id.hasPrefix("custom:") {
            return ActivityCorrectionOption.custom(category.title)
        }
        return ActivityCorrectionOption(
            id: "phase.\(category.id)",
            title: category.localizedTitle(language),
            behavior: category.id == "unconfirmed" ? "unconfirmed-gap" : nil,
            categoryID: category.id,
            systemImage: category.systemImage,
            isAutomatic: false,
            isCustom: false
        )
    }

    static func tint(for categoryID: String) -> Color {
        Color(hex: MapHomePastelPalette.hex(categoryID))
    }

    static func minuteLabel(_ minute: Int) -> String {
        let clamped = min(max(minute, 0), NLETrack.dayMinutes)
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }

    static func rangeLabel(_ start: Int, _ end: Int) -> String {
        "\(minuteLabel(start))–\(minuteLabel(end))"
    }

    static func durationLabel(_ minutes: Int, language: MapHomeLanguage) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60
        if language == .english {
            if hours > 0, remainder > 0 { return "\(hours)h \(remainder)m" }
            if hours > 0 { return "\(hours)h" }
            return "\(remainder)m"
        }
        if hours > 0, remainder > 0 { return "\(hours)시간 \(remainder)분" }
        if hours > 0 { return "\(hours)시간" }
        return "\(remainder)분"
    }

    static func hourLabel(_ hour: Int) -> String {
        String(format: "%02d", hour % 24)
    }
}

#if DEBUG
/// 레이아웃 확인용 미리보기. `-nlePreview` 실행 인자로만 열린다.
struct NLEClipEditorPreviewHost: View {
    @State private var model = AppModel(startsCommerceLocked: false)

    var body: some View {
        MapHomeNLEClipEditor(
            model: model,
            language: .korean,
            date: Date(),
            segments: Self.segments,
            details: Self.details,
            focusMinute: 600,
            initialMinuteHeight: ProcessInfo.processInfo.arguments.contains("-nleZoom")
                ? 2.6
                : nil,
            onSaved: {}
        )
    }

    private static var segments: [MapHomeTimeRailSegment] {
        [
            MapHomeTimeRailSegment(startMinute: 0, endMinute: 420, categoryID: "sleep", title: "수면"),
            MapHomeTimeRailSegment(startMinute: 420, endMinute: 720, categoryID: "work", title: "업무"),
            MapHomeTimeRailSegment(startMinute: 720, endMinute: 780, categoryID: "eating", title: "식사"),
            MapHomeTimeRailSegment(startMinute: 780, endMinute: 960, categoryID: "activity", title: "일상"),
            MapHomeTimeRailSegment(startMinute: 960, endMinute: 1_020, categoryID: "movement", title: "이동"),
            MapHomeTimeRailSegment(startMinute: 1_020, endMinute: 1_140, categoryID: "activity", title: "일상"),
            MapHomeTimeRailSegment(startMinute: 1_140, endMinute: 1_320, categoryID: "hobby", title: "취미"),
            MapHomeTimeRailSegment(startMinute: 1_320, endMinute: 1_440, categoryID: "sleep", title: "수면"),
        ]
    }

    private static var details: [MapHomeSectionDetail] {
        [
            MapHomeSectionDetail(
                id: UUID(), title: "회의", categoryID: "work",
                behavior: nil, startMinute: 480, endMinute: 540
            ),
            MapHomeSectionDetail(
                id: UUID(), title: "메일", categoryID: "work",
                behavior: nil, startMinute: 600, endMinute: 660
            ),
        ]
    }
}
#endif
