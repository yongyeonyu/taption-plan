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
    var onSaved: () -> Void

    @State private var track: NLETrack
    @State private var subTrack: NLETrack
    @State private var selectedClipID: String?
    @State private var selectedSubClipID: String?
    @State private var playheadMinute: Int
    @State private var minuteWidth: CGFloat = 2.4
    @State private var visibleStartMinute: Double = 0
    @State private var containerWidth: CGFloat = 0
    @State private var zoomBaseWidth: CGFloat = 0
    @State private var zoomBaseStartMinute: Double = 0
    @State private var panBaseStartMinute: Double = 0
    @State private var undoStack: [NLEEditorSnapshot] = []
    @State private var redoStack: [NLEEditorSnapshot] = []
    @State private var dragMode: NLEEditorDragMode = .none
    @State private var didPushUndoForDrag = false
    @State private var isSaving = false
    @State private var didCenter = false

    init(
        model: AppModel,
        language: MapHomeLanguage,
        date: Date,
        segments: [MapHomeTimeRailSegment],
        details: [MapHomeSectionDetail],
        focusMinute: Int,
        onSaved: @escaping () -> Void
    ) {
        self.model = model
        self.language = language
        self.date = date
        self.segments = segments
        self.details = details
        self.focusMinute = focusMinute
        self.onSaved = onSaved
        let built = Self.makeMainTrack(segments: segments)
        let initialClip = built.clip(atMinute: min(max(focusMinute, 0), NLETrack.dayMinutes - 1))
        _track = State(initialValue: built)
        _subTrack = State(initialValue: Self.makeSubTrack(
            details: details,
            within: initialClip,
            mainOption: initialClip?.option
        ))
        _playheadMinute = State(initialValue: min(max(focusMinute, 0), NLETrack.dayMinutes))
        _selectedClipID = State(initialValue: initialClip?.id)
        _selectedSubClipID = State(initialValue: nil)
    }

    // MARK: - 본문

    var body: some View {
        // 높이를 직접 나눠 준다. 스크롤 영역은 제 내용 높이를 그대로 원해서,
        // 그냥 두면 목록이 화면 아래로 넘친다.
        GeometryReader { proxy in
            let spacing: CGFloat = 12
            let reserved: CGFloat = 44 + 72 + 26 + 44 + spacing * 5
            let trackHeight = min(230, max(140, (proxy.size.height - reserved) * 0.42))
            let listHeight = max(96, proxy.size.height - reserved - trackHeight)
            VStack(spacing: spacing) {
                header
                timeline
                    .frame(height: trackHeight)
                subLane
                selectionSummary
                toolbar
                clipList
                    .frame(height: listHeight)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Color.tpBackground.ignoresSafeArea())
        .onChange(of: selectedClipID) { _, _ in
            rebuildSubTrack()
        }
    }

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
                Text(language.text("대분류 24시간 · 상세활동 서브클립", "24h main clips · sub-clips"))
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

    // MARK: - 타임라인

    private var timeline: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let height = max(80, proxy.size.height)
            let clipHeight = max(52, height - 34)
            let geometry = NLETimelineGeometry(
                minuteWidth: minuteWidth,
                visibleStartMinute: visibleStartMinute,
                visibleMinutes: Double(width) / Double(max(0.01, minuteWidth))
            )
            ZStack(alignment: .topLeading) {
                Color.tpSurface
                rulerCanvas(geometry: geometry, width: width)
                clipRow(geometry: geometry, width: width, height: height, clipHeight: clipHeight)
                playhead(geometry: geometry, height: height)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.tpLine, lineWidth: 1)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(geometry: geometry, width: width, height: height))
            .simultaneousGesture(magnifyGesture(width: width))
            .onAppear {
                containerWidth = width
                fitWholeDayIfNeeded(width: width)
            }
            .onChange(of: width) { _, newValue in
                containerWidth = newValue
                fitWholeDayIfNeeded(width: newValue)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func rulerCanvas(geometry: NLETimelineGeometry, width: CGFloat) -> some View {
        Canvas { context, size in
            let step = rulerStepMinutes
            let labelEvery = rulerLabelEveryMinutes
            var minute = Int(geometry.visibleStartMinute / Double(step)) * step
            while Double(minute) <= geometry.visibleEndMinute {
                let x = geometry.x(forMinute: Double(minute))
                if x >= 0, x <= width {
                    let isHour = minute % 60 == 0
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: isHour ? 0 : 12))
                    line.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(
                        line,
                        with: .color(isHour ? Color.tpInk.opacity(0.16) : Color.tpInk.opacity(0.07)),
                        lineWidth: isHour ? 1 : 0.6
                    )
                    if minute % labelEvery == 0 {
                        context.draw(
                            Text(Self.hourLabel(minute / 60))
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.tpSecondary),
                            at: CGPoint(x: x + 3, y: 7),
                            anchor: .leading
                        )
                    }
                }
                minute += step
            }
        }
        .frame(height: 24)
        .allowsHitTesting(false)
    }

    private func clipRow(
        geometry: NLETimelineGeometry,
        width: CGFloat,
        height: CGFloat,
        clipHeight: CGFloat
    ) -> some View {
        let topInset: CGFloat = 26
        return ZStack(alignment: .topLeading) {
            ForEach(visibleClips(geometry: geometry)) { clip in
                let x = geometry.x(forMinute: Double(clip.startMinute))
                let clipWidth = max(2, geometry.width(minutes: Double(clip.lengthMinutes)))
                clipBody(clip, width: clipWidth)
                    .frame(width: clipWidth, height: clipHeight)
                    .offset(x: x, y: topInset)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }

    private func clipBody(_ clip: NLEClip, width: CGFloat) -> some View {
        let tint = Self.tint(for: clip.option.categoryID)
        let isSelected = clip.id == selectedClipID
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.95), tint.opacity(0.72)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(isSelected ? 0.95 : 0.35), lineWidth: isSelected ? 2.5 : 1)
            if width > 46 {
                VStack(alignment: .leading, spacing: 2) {
                    Text(clip.option.title)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if width > 96 {
                        Text(Self.rangeLabel(clip.startMinute, clip.endMinute))
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .opacity(0.85)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.top, 6)
            }
            if isSelected {
                HStack(spacing: 0) {
                    trimHandle(isStart: true)
                    Spacer(minLength: 0)
                    trimHandle(isStart: false)
                }
                .frame(width: width)
                .frame(maxHeight: .infinity)
            }
        }
        .opacity(clip.isGap ? 0.55 : 1)
        .shadow(color: .black.opacity(isSelected ? 0.18 : 0.06), radius: isSelected ? 4 : 1, y: 1)
    }

    private func trimHandle(isStart: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color.white)
            .frame(width: 6)
            .overlay {
                Capsule()
                    .fill(Color.tpInk.opacity(0.45))
                    .frame(width: 2, height: 16)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 1)
            .accessibilityLabel(
                isStart
                    ? language.text("시작 자르기", "Trim start")
                    : language.text("끝 자르기", "Trim end")
            )
    }

    private func playhead(geometry: NLETimelineGeometry, height: CGFloat) -> some View {
        let x = geometry.x(forMinute: Double(playheadMinute))
        return ZStack(alignment: .top) {
            Rectangle()
                .fill(Color.tpAccent)
                .frame(width: 1.5, height: height)
            Path { path in
                path.move(to: CGPoint(x: -5, y: 0))
                path.addLine(to: CGPoint(x: 5, y: 0))
                path.addLine(to: CGPoint(x: 0, y: 7))
                path.closeSubpath()
            }
            .fill(Color.tpAccent)
            .frame(width: 10, height: 7)
        }
        .offset(x: x - 0.75)
        .allowsHitTesting(false)
    }

    // MARK: - 서브클립 줄

    private var subLane: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(language.text("서브클립 · 상세활동", "Sub-clips · detailed activity"))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.tpSecondary)
                Spacer()
                if subTrack.isEmpty {
                    Text(language.text("이 구간에 상세활동이 없습니다", "No detailed activity here"))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.tpSecondary.opacity(0.8))
                }
            }
            GeometryReader { proxy in
                let width = max(1, proxy.size.width)
                let clip = selectedClip
                let rangeStart = clip?.startMinute ?? 0
                let rangeEnd = clip?.endMinute ?? NLETrack.dayMinutes
                let minutes = max(1, rangeEnd - rangeStart)
                let subWidth = width / CGFloat(minutes)
                let geometry = NLETimelineGeometry(
                    minuteWidth: subWidth,
                    visibleStartMinute: Double(rangeStart),
                    visibleMinutes: Double(minutes)
                )
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.tpSurface)
                    if let clip {
                        Rectangle()
                            .fill(Self.tint(for: clip.option.categoryID).opacity(0.12))
                    }
                    ForEach(subTrack.clips) { sub in
                        let x = geometry.x(forMinute: Double(sub.startMinute))
                        let clipWidth = max(3, geometry.width(minutes: Double(sub.lengthMinutes)))
                        subClipBody(sub, width: clipWidth)
                            .frame(width: clipWidth, height: 38)
                            .offset(x: x, y: 6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.tpLine, lineWidth: 1)
                }
                .contentShape(Rectangle())
                .gesture(subDragGesture(geometry: geometry))
            }
        }
        .frame(height: 72)
    }

    private func subClipBody(_ clip: NLEClip, width: CGFloat) -> some View {
        let tint = Self.tint(for: clip.option.categoryID)
        let isSelected = clip.id == selectedSubClipID
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(tint.opacity(0.9))
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.white.opacity(isSelected ? 0.95 : 0.4), lineWidth: isSelected ? 2 : 1)
            if width > 40 {
                Text(clip.option.title)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
            }
            if isSelected {
                HStack(spacing: 0) {
                    Rectangle().fill(Color.white).frame(width: 3)
                    Spacer(minLength: 0)
                    Rectangle().fill(Color.white).frame(width: 3)
                }
            }
        }
        .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
    }

    // MARK: - 선택 정보

    private var selectionSummary: some View {
        let clip = selectedClip
        return HStack(spacing: 10) {
            if let clip {
                Circle()
                    .fill(Self.tint(for: clip.option.categoryID))
                    .frame(width: 10, height: 10)
                Text(clip.option.title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .lineLimit(1)
                Text(Self.rangeLabel(clip.startMinute, clip.endMinute))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.tpSecondary)
                Text(Self.durationLabel(clip.lengthMinutes, language: language))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.tpSecondary)
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
            Spacer()
            Text(Self.minuteLabel(playheadMinute))
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.tpAccent)
        }
        .frame(height: 26)
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
                systemImage: "arrow.left.and.right",
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

    // MARK: - 클립 목록

    /// 하루 전체를 확대하지 않고도 훑을 수 있게 클립을 목록으로도 둔다.
    /// 목록에서 고르면 타임라인의 재생 헤드도 그 클립 앞으로 따라간다.
    private var clipList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(language.text("클립 목록", "Clips"))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.tpSecondary)
                Text("\(track.clips.count)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.tpSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.tpInk.opacity(0.06), in: Capsule())
                Spacer(minLength: 0)
                if hasChanges {
                    Text(language.text("적용 전", "Unsaved"))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.tpAccent)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)

            Rectangle()
                .fill(Color.tpLine)
                .frame(height: 1)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(track.clips) { clip in
                        clipListRow(clip)
                        if clip.id != track.clips.last?.id {
                            Rectangle()
                                .fill(Color.tpLine.opacity(0.55))
                                .frame(height: 1)
                                .padding(.leading, 30)
                        }
                    }
                }
                .padding(.bottom, 4)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: .infinity)
        }
        .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.tpLine, lineWidth: 1)
        }
    }

    private func clipListRow(_ clip: NLEClip) -> some View {
        let isSelected = clip.id == selectedClipID
        return Button {
            selectClip(clip)
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Self.tint(for: clip.option.categoryID))
                    .frame(width: 4, height: 20)
                Text(clip.option.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.tpInk)
                    .lineLimit(1)
                if clip.isDirty {
                    Image(systemName: "pencil")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.tpAccent)
                }
                Spacer(minLength: 4)
                Text(Self.rangeLabel(clip.startMinute, clip.endMinute))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.tpSecondary)
                Text(Self.durationLabel(clip.lengthMinutes, language: language))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.tpSecondary)
                    .frame(minWidth: 46, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(isSelected ? Color.tpAccent.opacity(0.10) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 제스처

    private func dragGesture(geometry: NLETimelineGeometry, width: CGFloat, height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // 두 손가락 확대 중에는 클립이 끌려가지 않게 한다.
                guard zoomBaseWidth <= 0 else { return }
                if dragMode == .none {
                    dragMode = resolveDragMode(at: value.startLocation, geometry: geometry, height: height)
                    didPushUndoForDrag = false
                    panBaseStartMinute = visibleStartMinute
                }
                let minute = Int(geometry.minute(forX: value.location.x).rounded())
                switch dragMode {
                case .none:
                    break
                case .pan:
                    let deltaMinutes = Double(value.translation.width) / Double(max(0.01, minuteWidth))
                    setVisibleStart(panBaseStartMinute - deltaMinutes)
                case .scrub:
                    playheadMinute = min(max(minute, 0), NLETrack.dayMinutes)
                case let .move(id, originMinute, grabMinute):
                    pushUndoIfNeeded()
                    let target = originMinute + (minute - grabMinute)
                    let snapped = NLESnapPolicy.snapped(
                        target,
                        to: NLESnapPolicy.targets(
                            for: track,
                            excluding: id,
                            playheadMinute: playheadMinute
                        )
                    )
                    if track.move(id, toStartMinute: snapped) {
                        selectedClipID = id
                    }
                case let .trimStart(id):
                    pushUndoIfNeeded()
                    let snapped = NLESnapPolicy.snapped(
                        minute,
                        to: NLESnapPolicy.targets(for: track, excluding: id, playheadMinute: playheadMinute)
                    )
                    track.trim(id, edge: .start, toMinute: snapped)
                case let .trimEnd(id):
                    pushUndoIfNeeded()
                    let snapped = NLESnapPolicy.snapped(
                        minute,
                        to: NLESnapPolicy.targets(for: track, excluding: id, playheadMinute: playheadMinute)
                    )
                    track.trim(id, edge: .end, toMinute: snapped)
                }
            }
            .onEnded { _ in
                dragMode = .none
                didPushUndoForDrag = false
            }
    }

    private func subDragGesture(geometry: NLETimelineGeometry) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let minute = Int(geometry.minute(forX: value.location.x).rounded())
                if dragMode == .none {
                    dragMode = resolveSubDragMode(at: value.startLocation.x, geometry: geometry)
                    didPushUndoForDrag = false
                }
                switch dragMode {
                case let .move(id, originMinute, grabMinute):
                    pushUndoIfNeeded()
                    let target = originMinute + (minute - grabMinute)
                    if subTrack.move(id, toStartMinute: target) {
                        selectedSubClipID = id
                    }
                case let .trimStart(id):
                    pushUndoIfNeeded()
                    subTrack.trim(id, edge: .start, toMinute: minute)
                case let .trimEnd(id):
                    pushUndoIfNeeded()
                    subTrack.trim(id, edge: .end, toMinute: minute)
                default:
                    break
                }
            }
            .onEnded { _ in
                dragMode = .none
                didPushUndoForDrag = false
            }
    }

    private func magnifyGesture(width: CGFloat) -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                if zoomBaseWidth <= 0 {
                    zoomBaseWidth = minuteWidth
                    zoomBaseStartMinute = visibleStartMinute
                }
                let base = zoomBaseWidth
                let anchorX = min(max(value.startAnchor.x, 0), width)
                let anchorMinute = zoomBaseStartMinute + Double(anchorX) / Double(max(0.01, base))
                let next = min(max(base * value.magnification, 0.6), 24)
                minuteWidth = next
                setVisibleStart(anchorMinute - Double(anchorX) / Double(max(0.01, next)))
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

    private enum NLEEditorDragMode: Equatable {
        case none
        case pan
        case scrub
        case move(id: String, originMinute: Int, grabMinute: Int)
        case trimStart(id: String)
        case trimEnd(id: String)
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
        selectedSubClipID.flatMap { subTrack.clip($0) } != nil
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

    private var rulerStepMinutes: Int {
        switch minuteWidth {
        case ..<1.6: 60
        case ..<4: 30
        default: 15
        }
    }

    /// 눈금에 시각을 적는 간격. 하루 전체를 볼 때는 세 시간마다 적는다.
    private var rulerLabelEveryMinutes: Int {
        switch minuteWidth {
        case ..<0.5: 180
        case ..<0.9: 120
        default: 60
        }
    }

    // MARK: - 동작

    private func setVisibleStart(_ value: Double) {
        let visible = Double(max(1, containerWidth)) / Double(max(0.01, minuteWidth))
        let maximum = max(0, Double(NLETrack.dayMinutes) - visible)
        visibleStartMinute = min(max(value, 0), maximum)
    }

    /// 처음 열면 하루 24시간이 한눈에 들어오게 맞춘다. 확대는 두 손가락으로 한다.
    private func fitWholeDayIfNeeded(width: CGFloat) {
        guard !didCenter, width > 1 else { return }
        didCenter = true
        minuteWidth = max(0.24, width / CGFloat(NLETrack.dayMinutes))
        visibleStartMinute = 0
    }

    private func fitWholeDay() {
        guard containerWidth > 1 else { return }
        minuteWidth = max(0.6, containerWidth / CGFloat(NLETrack.dayMinutes))
        visibleStartMinute = 0
    }

    /// 목록에서 클립을 고른다. 확대해 둔 상태라면 그 클립이 보이도록 화면을 옮긴다.
    private func selectClip(_ clip: NLEClip) {
        selectedClipID = clip.id
        selectedSubClipID = nil
        playheadMinute = min(max(clip.startMinute, 0), NLETrack.dayMinutes)
        let visible = Double(max(1, containerWidth)) / Double(max(0.01, minuteWidth))
        guard visible < Double(NLETrack.dayMinutes) else { return }
        setVisibleStart(Double(clip.startMinute) - visible / 2)
    }

    private func resolveDragMode(
        at point: CGPoint,
        geometry: NLETimelineGeometry,
        height: CGFloat
    ) -> NLEEditorDragMode {
        let minute = Int(geometry.minute(forX: point.x).rounded())
        // 눈금을 끌면 재생 헤드가 움직인다.
        if point.y < 22 { return .scrub }
        if abs(geometry.x(forMinute: Double(playheadMinute)) - point.x) <= 10 { return .scrub }
        guard point.y <= height - 4, let clip = track.clip(atMinute: minute) else { return .pan }
        if let selected = selectedClip, selected.id == clip.id {
            let startX = geometry.x(forMinute: Double(clip.startMinute))
            let endX = geometry.x(forMinute: Double(clip.endMinute))
            if abs(point.x - startX) <= 14, clip.lengthMinutes > NLETrack.minimumClipMinutes {
                return .trimStart(id: clip.id)
            }
            if abs(point.x - endX) <= 14, clip.lengthMinutes > NLETrack.minimumClipMinutes {
                return .trimEnd(id: clip.id)
            }
        }
        selectedClipID = clip.id
        selectedSubClipID = nil
        return .move(id: clip.id, originMinute: clip.startMinute, grabMinute: minute)
    }

    private func resolveSubDragMode(at x: CGFloat, geometry: NLETimelineGeometry) -> NLEEditorDragMode {
        let minute = Int(geometry.minute(forX: x).rounded())
        if let sub = selectedSubClipID.flatMap({ subTrack.clip($0) }) {
            let startX = geometry.x(forMinute: Double(sub.startMinute))
            let endX = geometry.x(forMinute: Double(sub.endMinute))
            if abs(x - startX) <= 12, sub.endMinute - sub.startMinute > 1 {
                return .trimStart(id: sub.id)
            }
            if abs(x - endX) <= 12, sub.endMinute - sub.startMinute > 1 {
                return .trimEnd(id: sub.id)
            }
        }
        if let sub = subTrack.clip(atMinute: minute) {
            // 서브클립은 자기 상세활동 구간에 묶여 있어 통째로 옮기지 않는다.
            // 몸통을 누르면 고르기만 하고, 양 끝을 잡아야 자를 수 있다.
            selectedSubClipID = sub.id
            return .none
        }
        selectedSubClipID = nil
        return .none
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
            // 서브클립을 지우면 그 자리는 상위 대분류로 돌아간다.
            subTrack.delete(sub.id, fallback: selectedClip?.option)
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

    private func rebuildSubTrack() {
        let clip = selectedClip
        subTrack = Self.makeSubTrack(
            details: details,
            within: clip,
            mainOption: clip?.option
        )
        selectedSubClipID = nil
    }

    private func apply() {
        let dayStart = Calendar.autoupdatingCurrent.startOfDay(for: date)
        // 대분류를 먼저, 서브클립을 나중에 저장한다. 서브클립이 위에 남아야 한다.
        let requests = track.editRequests(dayStart: dayStart)
            + subTrack.editRequests(dayStart: dayStart)
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

    static func makeSubTrack(
        details: [MapHomeSectionDetail],
        within clip: NLEClip?,
        mainOption: ActivityCorrectionOption?
    ) -> NLETrack {
        guard let clip else {
            return NLETrack(clips: [], fillsGaps: false)
        }
        let fill = mainOption ?? ActivitySectionOverrideEngine.unconfirmedOption
        let clips = details.compactMap { detail -> NLEClip? in
            guard detail.endMinute > detail.startMinute,
                  detail.startMinute >= clip.startMinute,
                  detail.endMinute <= clip.endMinute else { return nil }
            let option = option(
                forCategoryID: detail.categoryID,
                title: detail.title,
                behavior: detail.behavior
            )
            let parent = NLEClipParent(
                startMinute: detail.startMinute,
                endMinute: detail.endMinute,
                sourceIDs: [detail.id],
                option: option,
                fillOption: fill
            )
            return NLEClip(
                id: "sub|\(detail.id.uuidString)",
                option: option,
                startMinute: detail.startMinute,
                endMinute: detail.endMinute,
                parent: parent,
                origin: NLEClipOrigin(
                    startMinute: detail.startMinute,
                    endMinute: detail.endMinute,
                    option: option
                )
            )
        }
        return NLETrack(
            clips: clips,
            rangeStartMinute: clip.startMinute,
            rangeEndMinute: clip.endMinute,
            fillsGaps: false
        )
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
