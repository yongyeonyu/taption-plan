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
    /// 길게 눌러 집어 들기를 기다리는 클립. 0.4초를 채우면 옮기기로 바뀐다.
    @State private var reorderCandidate: NLEEditorDragMode?
    @State private var liftTask: Task<Void, Never>?
    @State private var isLifted = false
    @State private var lastDragMinute = 0
    /// 팬을 시작한 손가락 높이. 집어 들기 전에 팬으로 바뀌어도 화면이 튀지 않게 한다.
    @State private var panAnchorY: CGFloat = 0
    /// 가장자리 자동 스크롤 타이머와 방향.
    @State private var scrollTask: Task<Void, Never>?
    @State private var scrollDirection: CGFloat = 0
    /// 센서 원본이나 상세활동에서 집어 든 결과. 대분류에 바로 반영할 수 있다.
    @State private var pick: NLEPick?
    @State private var sensorEvidence: [MapHomeTimeRailSegment] = []
    /// 전체 덮기 창. 여러 개로 나뉜 클립을 한 번에 같은 분류로 바꾼다.
    @State private var isOverwritePresented = false

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
            let railHeight = max(
                220,
                proxy.size.height
                    - (Self.headerRowHeight + headerHeight + Self.selectionRowHeight
                        + Self.toolbarHeight + spacing * 3 + 4)
            )
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
        .task(id: date) { sensorEvidence = await loadSensorEvidence() }
        .sheet(isPresented: $isOverwritePresented) {
            MapHomeNLEOverwriteSheet(
                language: language,
                track: track,
                selectedCategoryID: selectedClip?.option.categoryID,
                categories: categoryOptions
            ) { applyOverwrite($0) }
        }
    }

    /// 클립 줄이 화면 양옆으로 삐져나오는 폭.
    private static let railBleed: CGFloat = 14
    /// 클립 경계를 '다듬기'로 받아 주는 손가락 여유. 예전 12pt는 손가락에 너무 좁았다.
    private static let trimReach: CGFloat = 16
    /// 머리말·선택 요약·도구 막대의 높이. 셋 다 손가락이 닿는 44pt를 지킨다.
    private static let headerRowHeight: CGFloat = 44
    private static let selectionRowHeight: CGFloat = 44
    private static let toolbarHeight: CGFloat = 44

    private var header: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Text(language.text("닫기", "Close"))
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.tpReferenceRose)
                    .padding(.horizontal, 15)
                    .frame(minHeight: 38)
                    .background(Color.tpReferenceRose.opacity(0.10), in: Capsule())
            }
            .buttonStyle(.plain)
            Spacer()
            VStack(spacing: 1) {
                Text(language.text("클립 편집", "Clip editor"))
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(20)), weight: .bold, design: .rounded))
                Text(headerSubtitle)
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .semibold, design: .rounded))
                    .foregroundStyle(hasChanges ? Color.tpAccent : Color.tpSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
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
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .bold, design: .rounded))
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
    ///
    /// 줄은 화면 밖까지 넓혀 그리므로(`railBleed`) 눈금 띠도 그만큼 안쪽에서 시작한다.
    /// 이걸 빼먹으면 30분 눈금 "08:30"의 앞자리가 화면 밖으로 밀려 "30"만 남는다.
    private var gutterWidth: CGFloat {
        (rulerLabelEveryMinutes <= 30 ? 46 : 36) + Self.railBleed
    }

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
                            .font(.system(size: TaptionType.scaled(TaptionType.snapped(9)), weight: .bold, design: .rounded))
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
            .font(.system(size: TaptionType.scaled(TaptionType.snapped(9)), weight: .bold, design: .rounded))
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
                                .font(.system(size: TaptionType.scaled(TaptionType.snapped(9)), weight: .semibold, design: .rounded))
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
        let isLifted = clip.id == liftedClipID
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
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if blockHeight >= 44, width > 78 {
                        Text(Self.rangeLabel(clip.startMinute, clip.endMinute))
                            .font(.system(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .semibold, design: .rounded))
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
        .shadow(
            color: .black.opacity(isLifted ? 0.3 : (isSelected ? 0.16 : 0.05)),
            radius: isLifted ? 8 : (isSelected ? 3 : 1),
            y: isLifted ? 4 : 1
        )
    }

    private func trimHandle(isStart: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color.white)
            .frame(height: 8)
            .overlay {
                // 손잡이라는 것을 알아보게 가운데에 짧은 선을 긋는다.
                Capsule()
                    .fill(Color.tpInk.opacity(0.45))
                    .frame(width: 22, height: 3)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .accessibilityLabel(
                isStart
                    ? language.text("시작 자르기", "Trim start")
                    : language.text("끝 자르기", "Trim end")
            )
    }

    /// HealthKit·iPhone 모션·GPS 원본만으로 세운 구간(CAT1029A02). 고칠 수 없고, 견주어 보기만 한다.
    private var sourceSegments: [MapHomeTimeRailSegment] {
        sensorEvidence
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
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(9)), weight: .semibold, design: .rounded))
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
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(9)), weight: .bold, design: .rounded))
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
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(9)), weight: .bold, design: .monospaced))
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
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .bold, design: .rounded))
                    .lineLimit(1)
                Text(Self.rangeLabel(clip.startMinute, clip.endMinute))
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.tpSecondary)
                if let sensor = sensorSegment(atMinute: clip.startMinute),
                   sensor.categoryID != clip.option.categoryID {
                    // 센서는 이렇게 기록했는데 지금은 다르다. 눌러서 되돌린다.
                    Button {
                        self.pick = .sensor(sensor.id)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: TaptionType.scaled(TaptionType.snapped(8)), weight: .bold))
                            Text(language.text("센서 \(sensor.title)", "Sensor \(sensor.title)"))
                                .font(.system(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .bold, design: .rounded))
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
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium, design: .rounded))
                        .foregroundStyle(Color.tpSecondary)
                }
                if clip.isGap {
                    Text(language.text("미확인", "Unconfirmed"))
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .bold, design: .rounded))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.tpInk.opacity(0.08), in: Capsule())
                        .foregroundStyle(Color.tpSecondary)
                }
            } else {
                Text(language.text("클립을 고르세요", "Select a clip"))
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.tpSecondary)
            }
            Spacer(minLength: 0)
            Text(Self.minuteLabel(playheadMinute))
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .bold, design: .monospaced))
                .foregroundStyle(Color.tpAccent)
        }
        .frame(height: Self.selectionRowHeight)
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
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .bold, design: .rounded))
                .foregroundStyle(Color.tpSecondary)
                .lineLimit(1)
            Text(title)
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .bold, design: .rounded))
                .lineLimit(1)
            Text(range)
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.tpSecondary)
                .lineLimit(1)
            Button(action: apply) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .bold))
                    Text(language.text("반영", "Use"))
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .fixedSize()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(minWidth: 64, minHeight: TaptionMenuMetrics.minimumHitSize)
                .background(Color.tpAccent, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(language.text("이 구간을 대분류로 반영", "Use this range as main"))
            Button {
                self.pick = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
                    .frame(width: TaptionMenuMetrics.minimumHitSize, height: TaptionMenuMetrics.minimumHitSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(language.text("집기 취소", "Cancel pick"))
        }
    }

    // MARK: - 도구

    /// 도구 막대. 아이콘만 두면 무엇을 하는 단추인지 눌러 봐야 알 수 있어 이름을 함께 적는다.
    /// 확대는 두 손가락만으로는 찾기 어려워서 단추로도 돌 수 있게 했다.
    private var toolbar: some View {
        HStack(spacing: 6) {
            categoryMenu
            NLEToolButton(
                systemImage: "scissors",
                title: language.text("가르기", "Split"),
                isEnabled: splitTarget != nil
            ) {
                splitAtPlayhead()
            }
            NLEToolButton(
                systemImage: "trash",
                title: language.text("지우기", "Clear"),
                isEnabled: canDelete
            ) {
                deleteSelection()
            }
            NLEToolButton(
                systemImage: "arrow.uturn.backward",
                title: language.text("되돌리기", "Undo"),
                isEnabled: !undoStack.isEmpty,
                isHighlighted: true
            ) {
                undo()
            }
            NLEToolButton(
                systemImage: "arrow.uturn.forward",
                title: language.text("다시", "Redo"),
                isEnabled: !redoStack.isEmpty,
                isHighlighted: true
            ) {
                redo()
            }
            NLEToolButton(
                systemImage: "plus.magnifyingglass",
                title: zoomButtonTitle,
                isEnabled: containerHeight > 1
            ) {
                cycleZoom()
            }
        }
        .frame(height: Self.toolbarHeight)
    }

    private var zoomButtonTitle: String {
        // 아직 줄 높이를 재기 전에는 배율을 알 수 없다. 이름이 깜빡이지 않게 기본값을 쓴다.
        guard containerHeight > 1 else { return language.text("확대", "Zoom") }
        return NLEZoomPolicy.nextTitle(
            currentMinuteHeight: minuteHeight,
            fitMinuteHeight: NLEZoomPolicy.fitMinuteHeight(height: containerHeight),
            language: language
        )
    }

    /// 다음 배율로 벌리거나 하루 전체로 되돌린다. 지금 고른 클립을 화면 가운데에 둔다.
    private func cycleZoom() {
        guard containerHeight > 1 else { return }
        let fit = NLEZoomPolicy.fitMinuteHeight(height: containerHeight)
        let level = NLEZoomPolicy.nextLevel(currentMinuteHeight: minuteHeight, fitMinuteHeight: fit)
        let next = min(max(fit * level, 0.22), 12)
        let anchor = selectedClip.map { Double($0.startMinute + $0.lengthMinutes / 2) } ?? Double(playheadMinute)
        minuteHeight = next
        setVisibleStart(anchor - Double(containerHeight) / Double(next) / 2)
        UISelectionFeedbackGenerator().selectionChanged()
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
            // 고른 클립 하나가 아니라 나뉜 클립 전부를 바꾸는 문. 같은 메뉴에 두어
            // '하나 고치기'와 '전체 덮기'를 같은 자리에서 고르게 한다.
            Divider()
            Button {
                isOverwritePresented = true
            } label: {
                Label(language.text("전체 덮기", "Overwrite all"), systemImage: "rectangle.on.rectangle")
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .semibold))
                Text(language.text("분류", "Category"))
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(Color.tpInk)
            .frame(minWidth: 52, minHeight: TaptionMenuMetrics.minimumHitSize)
            .contentShape(Rectangle())
        }
        .disabled(activeClip == nil)
        .opacity(activeClip == nil ? 0.45 : 1)
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
                    panAnchorY = value.startLocation.y
                    dragScrollShift = 0
                    beginLiftHoldIfNeeded()
                }
                let rawMinute = geometry.minute(forY: value.location.y) + dragScrollShift
                let minute = Int(rawMinute.rounded())
                lastDragMinute = minute
                // 집어 들기 전에 크게 움직이면 클립을 딸고 가지 않고 화면을 흐르게 한다.
                if case .move = dragMode, !isLifted,
                   hypot(value.translation.width, value.translation.height) > NLEReorderHoldPolicy.tolerance {
                    cancelLiftHold()
                    dragMode = .pan
                    panBaseStartMinute = visibleStartMinute
                    panAnchorY = value.location.y
                }
                switch dragMode {
                case .none:
                    break
                case .pan:
                    let deltaMinutes = Double(value.location.y - panAnchorY) / Double(max(0.01, minuteHeight))
                    setVisibleStart(panBaseStartMinute - deltaMinutes)
                case .scrub:
                    playheadMinute = min(max(minute, 0), NLETrack.dayMinutes)
                case let .move(lane, id, originMinute, grabMinute):
                    // 몸통은 0.4초를 누르고 있어야 집어 든다(BOKKI STUDIO 계약).
                    guard isLifted else { break }
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
                updateAutoScroll(atY: value.location.y, height: height)
            }
            .onEnded { value in
                let moved = abs(value.translation.width) + abs(value.translation.height)
                cancelLiftHold()
                stopAutoScroll()
                if moved < 4, dragMode != .scrub, dragMode != .none {
                    handleTap(at: value.startLocation, geometry: geometry, width: width)
                }
                // 제자리로 돌아와 손을 떼면 되돌리기 한 칸을 남기지 않는다(BOKKI STUDIO 계약).
                if didPushUndoForDrag, let before = undoStack.last, before.main == track.snapshot(),
                   before.sub == subTrack.snapshot() { undoStack.removeLast() }
                dragMode = .none
                isLifted = false
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

    /// 고쳐서 아직 저장하지 않은 클립 수. '적용'이 흐려 있는 이유를 알려 주는 데 쓴다.
    private var dirtyClipCount: Int {
        track.clips.filter(\.isDirty).count + subTrack.clips.filter(\.isDirty).count
    }

    /// 머리말 아래 한 줄. 지금 상태에서 다음에 할 일을 적는다.
    private var headerSubtitle: String {
        if dirtyClipCount > 0 {
            return language.text(
                "바뀐 클립 \(dirtyClipCount)개 · 적용하면 저장",
                "\(dirtyClipCount) changed · Apply to save"
            )
        }
        if isFittedToWholeDay {
            // 하루 전체가 한눈에 들어오는 배율에서는 클립이 몇 pt라 경계를 잡을 수 없다.
            // 손가락을 벌려야 편집이 된다는 사실을 이 자리에서 알려 준다.
            return language.text(
                "두 손가락으로 벌려 확대 · 경계를 잡아 자르기",
                "Pinch to zoom · grab an edge to trim"
            )
        }
        return language.text("대분류 · 센서 원본 · 상세활동", "Main · sensor · details")
    }

    private var isFittedToWholeDay: Bool {
        NLEZoomPolicy.isFitted(
            currentMinuteHeight: minuteHeight,
            fitMinuteHeight: NLEZoomPolicy.fitMinuteHeight(height: containerHeight)
        )
    }

    /// 지우기가 향하는 클립. 상세활동을 골랐으면 상세활동이 먼저다.
    private var canDelete: Bool {
        if activeSubClip != nil { return true }
        return selectedClip.map { !$0.isGap } ?? false
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
    ///
    /// 가장자리에 닿은 깊이가 아니라 시간에 비례해 360pt/s로 흐른다(BOKKI STUDIO 계약).
    /// 손가락을 가장자리에 세워 두어도 계속 흐르도록 타이머로 민다.
    private func updateAutoScroll(atY y: CGFloat, height: CGFloat) {
        guard minuteHeight > 0.01, height > 60, shouldAutoScroll else { return stopAutoScroll() }
        let band: CGFloat = 26
        let direction: CGFloat = y < band ? -1 : (y > height - band ? 1 : 0)
        guard direction != scrollDirection else { return }
        stopAutoScroll()
        guard direction != 0 else { return }
        scrollDirection = direction
        scrollTask = Task { @MainActor in
            var last = Date().timeIntervalSinceReferenceDate
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(17))
                guard !Task.isCancelled else { return }
                let now = Date().timeIntervalSinceReferenceDate
                let points = NLEReorderHoldPolicy.scrollPoints(elapsed: now - last)
                last = now
                let before = visibleStartMinute
                setVisibleStart(visibleStartMinute + Double(points * scrollDirection) / Double(minuteHeight))
                dragScrollShift += visibleStartMinute - before
            }
        }
    }

    private func stopAutoScroll() {
        scrollTask?.cancel()
        scrollTask = nil
        scrollDirection = 0
    }

    /// 지금 손가락을 따라 화면이 흘러야 하는가. 팬과 집어 들기 전에는 흐르지 않는다.
    private var shouldAutoScroll: Bool {
        switch dragMode {
        case .none, .pan: false
        case .scrub, .trimStart, .trimEnd: true
        case .move: isLifted
        }
    }

    /// 몸통을 잡았으면 0.4초를 세어 집어 든다. 경계 다듬기와 재생 헤드는 곧바로 움직인다.
    private func beginLiftHoldIfNeeded() {
        guard case let .move(lane, id, originMinute, _) = dragMode else { return }
        reorderCandidate = dragMode
        liftTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(NLEReorderHoldPolicy.delay))
            guard !Task.isCancelled, reorderCandidate != nil else { return }
            // 집어 든 뒤에는 지금 손가락 아래를 기준으로 삼아 클립이 튀지 않게 한다.
            dragMode = .move(lane: lane, id: id, originMinute: originMinute, grabMinute: lastDragMinute)
            isLifted = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    private func cancelLiftHold() {
        liftTask?.cancel()
        liftTask = nil
        reorderCandidate = nil
    }

    /// 지금 손가락에 들려 있는 클립.
    private var liftedClipID: String? {
        guard isLifted, case let .move(_, id, _, _) = dragMode else { return nil }
        return id
    }

    private func resolveDragMode(
        at point: CGPoint,
        geometry: NLETimelineGeometry,
        width: CGFloat
    ) -> NLEEditorDragMode {
        let minute = Int(geometry.minute(forY: point.y).rounded())
        // 왼쪽 눈금 띠를 끌면 재생 헤드가 움직인다.
        if point.x <= gutterWidth { return .scrub }
        // 재생 헤드 선을 잡으면 어느 줄에서든 헤드가 따라온다. 다만 손가락이 클립 경계에
        // 닿아 있으면 자르기가 먼저다. 경계에서 가르고 바로 다듬는 흐름이 막히면 안 된다.
        if abs(geometry.y(forMinute: Double(playheadMinute)) - point.y) <= 9,
           !isNearClipBoundary(at: point, geometry: geometry) {
            return .scrub
        }
        let lanes = NLELaneWidths(total: width, gutter: gutterWidth, gap: laneGap)
        let sensorX = gutterWidth + lanes.main + laneGap
        let detailX = sensorX + lanes.sensor + laneGap
        // 상세활동 줄
        if point.x >= detailX - laneGap {
            if let sub = subTrack.clip(atMinute: minute) {
                selectedSubClipID = sub.id
                if geometry.height(minutes: Double(sub.lengthMinutes)) >= Self.trimReach * 3 {
                    let topY = geometry.y(forMinute: Double(sub.startMinute))
                    let bottomY = geometry.y(forMinute: Double(sub.endMinute))
                    if abs(point.y - topY) <= Self.trimReach { return .trimStart(lane: .sub, id: sub.id) }
                    if abs(point.y - bottomY) <= Self.trimReach { return .trimEnd(lane: .sub, id: sub.id) }
                }
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
        selectedClipID = clip.id
        selectedSubClipID = nil
        // 경계는 고르지 않은 클립이라도 바로 다듬기다(BOKKI STUDIO 계약: 경계=Trim, 몸통=옮기기).
        // 짧아 경계 두 곳이 겹치는 클립은 맞닿은 이웃의 경계로 대신 민다.
        if geometry.height(minutes: Double(clip.lengthMinutes)) >= Self.trimReach * 3 {
            let topY = geometry.y(forMinute: Double(clip.startMinute))
            let bottomY = geometry.y(forMinute: Double(clip.endMinute))
            if abs(point.y - topY) <= Self.trimReach { return .trimStart(lane: .main, id: clip.id) }
            if abs(point.y - bottomY) <= Self.trimReach { return .trimEnd(lane: .main, id: clip.id) }
        }
        if let boundary = shortClipBoundary(at: point, clip: clip, geometry: geometry) {
            return boundary
        }
        return .move(lane: .main, id: clip.id, originMinute: clip.startMinute, grabMinute: minute)
    }

    /// 손가락이 어느 클립의 시작·끝 가까이에 있는가. 경계를 잡으려는 손인지 가리는 데 쓴다.
    private func isNearClipBoundary(at point: CGPoint, geometry: NLETimelineGeometry) -> Bool {
        track.clips.contains { clip in
            abs(point.y - geometry.y(forMinute: Double(clip.startMinute))) <= Self.trimReach
                || abs(point.y - geometry.y(forMinute: Double(clip.endMinute))) <= Self.trimReach
        }
    }

    /// 하루 전체를 볼 때처럼 클립이 짧아 자기 손잡이를 둘 수 없으면,
    /// 맞닿은 이웃의 경계를 잡는다. 같은 경계라 롤 결과는 어느 쪽에서 잡아도 같다.
    private func shortClipBoundary(
        at point: CGPoint,
        clip: NLEClip,
        geometry: NLETimelineGeometry
    ) -> NLEEditorDragMode? {
        let startDistance = abs(point.y - geometry.y(forMinute: Double(clip.startMinute)))
        let endDistance = abs(point.y - geometry.y(forMinute: Double(clip.endMinute)))
        let useStart = startDistance <= endDistance
        guard (useStart ? startDistance : endDistance) <= Self.trimReach else { return nil }
        let boundary = useStart ? clip.startMinute : clip.endMinute
        let neighbor = track.clips.first {
            $0.id != clip.id && (useStart ? $0.endMinute == boundary : $0.startMinute == boundary)
        }
        guard let neighbor,
              geometry.height(minutes: Double(neighbor.lengthMinutes)) >= Self.trimReach * 3
        else { return nil }
        return useStart
            ? .trimEnd(lane: .main, id: neighbor.id)
            : .trimStart(lane: .main, id: neighbor.id)
    }

    /// 그 시각을 덮는 센서 원본 구간.
    private func sensorSegment(atMinute minute: Int) -> MapHomeTimeRailSegment? {
        sourceSegments.first { minute >= $0.startMinute && minute < $0.endMinute }
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

    /// 대분류 경계는 맞닿은 이웃과 맞물려 민다(롤). 서브클립은 자기 구간 안에서만 다듬는다.
    private func trimClip(lane: NLEEditorLane, id: String, edge: NLEClipEdge, toMinute minute: Int) {
        switch lane {
        case .main:
            track.roll(id, edge: edge, toMinute: minute)
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
        // 지울 것이 없는데 되돌리기 칸을 쌓으면, 눌러도 화면이 그대로인 '빈 되돌리기'가 생긴다.
        if let selectedSubClipID, let sub = subTrack.clip(selectedSubClipID) {
            // 상세활동을 지우면 그 자리는 그 구간의 대분류로 돌아간다.
            pushUndo()
            subTrack.delete(sub.id, fallback: sub.parent.fillOption)
            self.selectedSubClipID = nil
            return
        }
        guard let clip = selectedClip, !clip.isGap else { return }
        pushUndo()
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

    /// 전체 덮기·합치기를 적용한다. 실제로 바뀐 것이 없으면 되돌리기를 쌓지 않는다.
    private func applyOverwrite(_ request: NLEOverwriteRequest) {
        let result = NLEOverwritePolicy.apply(
            track,
            option: request.category.map { Self.option(for: $0, language: language) },
            scope: request.scope,
            selectedCategoryID: selectedClip?.option.categoryID,
            mergesAfter: request.mergesAfter
        )
        guard result.changed + result.merged > 0 else { return }
        pushUndo()
        track = result.track
        // 합쳐져 사라진 클립을 가리키지 않게 재생 헤드 자리의 클립으로 옮긴다.
        selectedClipID = track.clip(atMinute: playheadMinute)?.id
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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
}

