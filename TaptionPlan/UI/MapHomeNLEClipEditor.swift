import SwiftUI

/// 행동 구간을 동영상 편집기(NLE)처럼 다루는 화면.
///
/// * 대분류는 하루 24시간을 빈틈없이 채우는 전체 클립이다.
/// * 왼쪽 줄은 머문 장소, 오른쪽 줄은 비어 있다. 재생 헤드는 눈금 띠의 핸들로 움직인다.
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

    @State var track: NLETrack
    @State var subTrack: NLETrack
    @State var selectedClipID: String?
    @State var selectedSubClipID: String?
    /// 상세 층 클립의 자동·수동 근거(NLE1103A02).
    @State var subProvenance: [String: NLESubActivityProvenance] = [:]
    /// 이번 터치가 시작될 때 골라져 있던 클립과, 탭 범위를 벗어났는지(NLE1103A03).
    @State private var selectedAtTouchStart: String?
    @State private var touchLeftTapSlop = false
    @State var playheadMinute: Int
    @State var minuteHeight: CGFloat = 2.4
    @State var visibleStartMinute: Double = 0
    @State var containerHeight: CGFloat = 0
    @State private var zoomBaseWidth: CGFloat = 0
    @State private var zoomBaseStartMinute: Double = 0
    @State private var panBaseStartMinute: Double = 0
    @State var undoStack: [NLEEditorSnapshot] = []
    @State var redoStack: [NLEEditorSnapshot] = []
    @State private var dragMode: NLEEditorDragMode = .none
    @State private var didPushUndoForDrag = false
    @State private var isSaving = false
    /// 그날 기록을 다 읽기 전에는 저장하지 않는다(NLE1103A04).
    @State private var isDayLoaded = false
    @State var didCenter = false
    /// 위로 넘겨 전날을 읽는 중인 작업. 하나씩만 읽는다(NLE1029A02).
    @State var previousDayLoad: Task<Void, Never>?
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
    /// 클립 옆 빠른 메뉴를 띄운 분. 끌기 시작하면 닫는다.
    @State private var quickMenuMinute: Int?
    /// 장소 줄. 머문 기록에서 파생한 읽기 전용 값이다(NLE1104A01).
    @State var placeSegments: [NLEPlaceSegment] = []
    /// 날 오프셋별 머문 기록과 지도에서 찾은 이름. 장소 줄을 다시 세울 때 쓴다(NLE1104A02).
    @State var placeDays: [Int: [PlaceStay]] = [:]
    @State var nearbyPlaceNames: [String: String] = [:]
    /// 핸들을 잡을 때의 재생 헤드와 손가락 자리(분).
    @State private var scrubAnchor: (playhead: Double, touch: Double)?
    /// 전체 덮기 창과 그 창이 묻는 직접 입력 기록, 편집기 위 짧은 알림(OVW1108A01).
    @State var isOverwritePresented = false
    @State var overwriteUserOwnedIDs: Set<UUID> = []
    @State var editorNotice: String?
    @State var pickedClipIDs: Set<String> = []
    /// 경계 손잡이를 이웃의 먼 쪽 끝까지 가져갔을 때 묻는 합치기 확인.
    @State private var mergePrompt: NLEMergePrompt?
    /// 이번 손잡이 끌기를 시작할 때 맞닿은 이웃의 길이(분). 이미 최소 길이였던 이웃은 "끝까지 갔다"고 보지 않는다.
    /// 경계를 끌기 시작할 때 잡은 클립과 맞닿은 이웃의 길이.
    @State private var trimLengthsAtStart: (clip: Int, neighbor: Int)?

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
        _subTrack = State(initialValue: Self.makeSubTrack(details: NLESubActivityEngine.informative(details), segments: segments))
        _playheadMinute = State(initialValue: min(max(focusMinute, 0), NLETrack.dayMinutes))
        _selectedClipID = State(initialValue: initialClip?.id)
        _selectedSubClipID = State(initialValue: nil)
    }

    // MARK: - 본문

    var body: some View {
        // 하루는 위에서 아래로 흐른다. 왼쪽 눈금 옆으로 세 줄이 나란히 선다:
        // 머문 장소, 내가 고치는 대분류, 그리고 아직 비어 있는 줄.
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
            if MapHomeWideLayoutPolicy.usesClipColumns(width: proxy.size.width) { wideLayout(size: proxy.size, headerHeight: headerHeight, spacing: spacing) } else {
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
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Color.tpBackground.ignoresSafeArea())
        .task(id: date) {
            placeDays[0] = await NLEDayWindow.loadPlaces(model: model, date: date)
            isDayLoaded = true
            rebuildPlaceSegments()
            await resolveNearbyPlaceNames()
        }
        .onChange(of: movementSpans) { _, _ in rebuildPlaceSegments() }
        .alert(
            language.text("합칠까요?", "Merge?"),
            isPresented: Binding(get: { mergePrompt != nil }, set: { if !$0 { mergePrompt = nil } }),
            presenting: mergePrompt
        ) { prompt in
            Button(language.text("합치기", "Merge")) { confirmMerge(prompt); resetDragState() }
            Button(language.text("취소", "Cancel"), role: .cancel) { resetDragState() }
        } message: { prompt in
            Text(language.text(
                "‘\(prompt.neighborTitle)’ 구간을 ‘\(prompt.clipTitle)’로 합칩니다. 센서 원본은 그대로 남습니다.",
                "Merge ‘\(prompt.neighborTitle)’ into ‘\(prompt.clipTitle)’. Sensor data is kept."
            ))
        }
        .sheet(isPresented: $isOverwritePresented) { overwriteSheet }
        .overlay(alignment: .top) { editorNoticeBanner }
    }

    /// 클립 줄이 화면 양옆으로 삐져나오는 폭.
    static let railBleed: CGFloat = 14
    /// 클립 경계를 '다듬기'로 받아 주는 손가락 여유. 예전 12pt는 손가락에 너무 좁았다.
    private static let trimReach: CGFloat = 16
    /// 이보다 얇게 눌린 클립은 이웃에 합칠지 묻는다.
    private static let mergeSqueezePoints: CGFloat = 18
    /// 머리말·선택 요약·도구 막대의 높이. 셋 다 손가락이 닿는 44pt를 지킨다.
    private static let headerRowHeight: CGFloat = 44
    private static let selectionRowHeight: CGFloat = 44
    private static let toolbarHeight: CGFloat = 44

    var header: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Text(language.text("닫기", "Close"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold))
                    .foregroundStyle(Color.tpReferenceRose)
                    .padding(.horizontal, 15)
                    .frame(minHeight: 38)
                    .background(Color.tpReferenceRose.opacity(0.10), in: Capsule())
            }
            .buttonStyle(.plain)
            Spacer()
            Text(visibleDateTitle)
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(17)), weight: .bold))
                .foregroundStyle(Color.tpInk)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer()
            Button {
                apply()
            } label: {
                Group {
                    if isSaving || !saveGate.isLoaded {
                        ProgressView().tint(.white)
                    } else {
                        Text(language.text("적용", "Apply"))
                    }
                }
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 15)
                .frame(minHeight: 38)
                .background(Color.tpReferenceBlue, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!saveGate.canApply)
            .opacity(saveGate.canApply ? 1 : 0.45)
        }
        .frame(minHeight: 44)
    }

    // MARK: - 세로 타임라인

    /// 시각 눈금이 붙는 왼쪽 띠의 너비.
    ///
    /// 줄은 화면 밖까지 넓혀 그리므로(`railBleed`) 눈금 띠도 그만큼 안쪽에서 시작한다.
    /// 이걸 빼먹으면 30분 눈금 "08:30"의 앞자리가 화면 밖으로 밀려 "30"만 남는다.
    var gutterWidth: CGFloat {
        (rulerLabelEveryMinutes <= 30 ? 46 : 36) + Self.railBleed
    }

    private var laneGap: CGFloat { 5 }

    /// 줄 이름표. 타임라인과 같은 너비 계산을 써서 세로줄과 딱 맞춘다.
    func laneHeader(width: CGFloat) -> some View {
        let lanes = laneWidths(width)
        return HStack(spacing: laneGap) {
            Color.clear.frame(width: gutterWidth, height: 1)
            laneTitle(language.text("장소", "Place"), width: lanes.place)
            laneTitle(language.text("대분류", "Main"), width: lanes.main)
            laneTitle(language.text("상세 활동", "Detail"), width: lanes.right - Self.railBleed * 2)
        }
    }

    private func laneWidths(_ width: CGFloat) -> NLELaneWidths {
        NLELaneWidths(total: width, gutter: gutterWidth, gap: laneGap, overflow: Self.railBleed * 2)
    }

    private func laneTitle(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(9)), weight: .bold))
            .foregroundStyle(Color.tpSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: width, alignment: .leading)
    }

    /// 누른 클립 옆에 뜨는 분류·가르기·지우기 알약.
    @ViewBuilder
    private func quickMenu(geometry: NLETimelineGeometry, x: CGFloat, width: CGFloat, height: CGFloat) -> some View {
        if let minute = quickMenuMinute, activeClip != nil {
            let y = min(max(4, geometry.y(forMinute: Double(minute)) - NLEQuickMenuMetrics.height / 2), height - NLEQuickMenuMetrics.height - 4)
            NLEQuickMenuPill(language: language) {
                categoryMenuItems
            } onSplit: {
                playheadMinute = minute
                splitAtPlayhead()
                quickMenuMinute = nil
            } onDelete: {
                deleteSelection()
                quickMenuMinute = nil
            }
            .frame(width: min(width - 8, NLEQuickMenuMetrics.width))
            .offset(x: x + max(4, width - min(width - 8, NLEQuickMenuMetrics.width) - 4), y: y)
        }
    }

    /// 하루 24시간을 세로로 세운 타임라인.
    ///
    /// 위에서 아래로 시간이 흐르고, 클립은 하루를 빈틈없이 채우며 쌓인다.
    /// 대분류만 고칠 수 있고, 장소는 머문 기록을 보여 주기만 하며, 오른쪽 줄은 비어 있다.
    var verticalRail: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let height = max(120, proxy.size.height)
            let lanes = laneWidths(width)
            let geometry = NLETimelineGeometry(
                minuteWidth: minuteHeight,
                visibleStartMinute: visibleStartMinute,
                visibleMinutes: Double(height) / Double(max(0.01, minuteHeight))
            )
            ZStack(alignment: .topLeading) {
                Color.tpSurface
                hourGrid(geometry: geometry, width: width)
                laneDivider(at: lanes.mainX - laneGap / 2, height: height)
                laneDivider(at: lanes.rightX - laneGap / 2, height: height)
                placeColumn(geometry: geometry, x: lanes.placeX, width: lanes.place)
                mainColumn(geometry: geometry, x: lanes.mainX, width: lanes.main)
                detailColumn(geometry: geometry, x: lanes.rightX, width: lanes.right)
                playheadLine(geometry: geometry, width: width)
                playheadHandle(geometry: geometry, minute: playheadMinute)
                quickMenu(geometry: geometry, x: lanes.mainX, width: lanes.main, height: height)
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
        let isSelected = clip.id == selectedClipID || pickedClipIDs.contains(clip.id)
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
            // 선택 중에는 제목을 위 손잡이 아래로 내린다. 손잡이 사이에 못 들어가면 아래 요약 줄이 이름을 보여 준다.
            if blockHeight >= (isSelected ? 38 : 26), width > 34 {
                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.mainTitle(clip.option, language: language))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if blockHeight >= (isSelected ? 52 : 44), width > 78 {
                        Text(Self.rangeLabel(clip.startMinute, clip.endMinute))
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .semibold))
                            .opacity(0.88)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.top, isSelected ? 11 : 5)
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

    private func playheadLine(geometry: NLETimelineGeometry, width: CGFloat) -> some View {
        Rectangle()
            .fill(Color.tpAccent)
            .frame(width: max(0, width - gutterWidth), height: 1.5)
            .offset(x: gutterWidth, y: geometry.y(forMinute: Double(playheadMinute)) - 0.75)
            .allowsHitTesting(false)
    }

    // MARK: - 선택 정보

    var selectionSummary: some View {
        HStack(spacing: 8) {
            if let clip = selectedClip {
                Circle()
                    .fill(Self.tint(for: clip.option.categoryID))
                    .frame(width: 10, height: 10)
                Text(Self.mainTitle(clip.option, language: language))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .bold))
                    .lineLimit(1)
                Text(Self.rangeLabel(clip.startMinute, clip.endMinute))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                Text(Self.durationLabel(clip.lengthMinutes, language: language))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium))
                    .foregroundStyle(Color.tpSecondary)
                if clip.isGap {
                    Text(language.text("미확인", "Unconfirmed"))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.tpInk.opacity(0.08), in: Capsule())
                        .foregroundStyle(Color.tpSecondary)
                }
            } else {
                Text(language.text("클립을 고르세요", "Select a clip"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
            }
            Spacer(minLength: 0)
            Text(Self.minuteLabel(playheadMinute))
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .bold, design: .monospaced))
                .foregroundStyle(Color.tpAccent)
        }
        .frame(height: Self.selectionRowHeight)
    }

    // MARK: - 도구

    /// 도구 막대. 아이콘만 두면 무엇을 하는 단추인지 눌러 봐야 알 수 있어 이름을 함께 적는다.
    /// 확대는 두 손가락만으로는 찾기 어려워서 단추로도 돌 수 있게 했다.
    var toolbar: some View {
        HStack(spacing: 6) {
            categoryMenu
            detailMenu
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
        let next = min(max(fit * level, 0.22), NLEZoomPolicy.maxMinuteHeight)
        let anchor = selectedClip.map { Double($0.startMinute + $0.lengthMinutes / 2) } ?? Double(playheadMinute)
        minuteHeight = next
        setVisibleStart(anchor - Double(containerHeight) / Double(next) / 2)
        UISelectionFeedbackGenerator().selectionChanged()
    }

    @ViewBuilder
    private var categoryMenuItems: some View {
        categoryButtons(categoryOptions) { category in
            if !applyToPicked(category) { applyCategory(category) }
            quickMenuMinute = nil
        }
        overwriteMenuButtons
    }

    private var categoryMenu: some View {
        Menu {
            categoryMenuItems
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .semibold))
                Text(language.text("분류", "Category"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .semibold))
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
                // 끄는 도중 합치기를 물었으면 손을 뗄 때까지 더 끌지 않는다.
                guard mergePrompt == nil else { return }
                if NLESelectionTapPolicy.hasLeftSlop(translation: value.translation) {
                    quickMenuMinute = nil
                    if !touchLeftTapSlop { touchLeftTapSlop = true }
                }
                if dragMode == .none {
                    selectedAtTouchStart = selectedClipID
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
                    applyScrub(rawMinute: rawMinute)
                case let .move(lane, id, originMinute, grabMinute):
                    // 몸통은 0.4초를 누르고 있어야 집어 든다(BOKKI STUDIO 계약).
                    guard isLifted else { break }
                    pushUndoIfNeeded()
                    let target = originMinute + (minute - grabMinute)
                    let snapped = NLESnapPolicy.snapped(target, to: snapTargets(lane: lane, excluding: id), threshold: snapThresholdMinutes)
                    moveClip(lane: lane, id: id, toStartMinute: snapped)
                case let .trimStart(lane, id):
                    // 손이 움직이기 전에는 경계를 옮기지 않는다. 그래야 누르기만 한 손이 탭으로 남는다.
                    if touchLeftTapSlop { applyTrim(lane: lane, id: id, edge: .start, minute: minute) }
                case let .trimEnd(lane, id):
                    if touchLeftTapSlop { applyTrim(lane: lane, id: id, edge: .end, minute: minute) }
                }
                // 위·아래 끝까지 끌면 화면이 따라 흐른다.
                updateAutoScroll(atY: value.location.y, height: height)
            }
            .onEnded { value in
                let leftSlop = touchLeftTapSlop || NLESelectionTapPolicy.hasLeftSlop(translation: value.translation)
                cancelLiftHold()
                stopAutoScroll()
                // 마지막 손 위치는 변경 알림 없이 끝날 수 있다. 끝난 자리를 그대로 반영한다.
                if leftSlop, mergePrompt == nil {
                    let minute = Int((geometry.minute(forY: value.location.y) + dragScrollShift).rounded())
                    switch dragMode {
                    case let .trimStart(lane, id): applyTrim(lane: lane, id: id, edge: .start, minute: minute)
                    case let .trimEnd(lane, id): applyTrim(lane: lane, id: id, edge: .end, minute: minute)
                    case .scrub: applyScrub(rawMinute: geometry.minute(forY: value.location.y) + dragScrollShift)
                    default: break
                    }
                }
                if !leftSlop, dragMode != .scrub, dragMode != .none {
                    handleTap(at: value.startLocation, geometry: geometry, width: width)
                }
                // 제자리로 돌아와 손을 떼면 되돌리기 한 칸을 남기지 않는다(BOKKI STUDIO 계약).
                if didPushUndoForDrag, let before = undoStack.last, before.main == track.snapshot(),
                   before.sub == subTrack.snapshot() { undoStack.removeLast() }
                #if DEBUG
                NSLog("[NLEMerge] drag end mode=%@ lengths=%@", String(describing: dragMode), String(describing: trimLengthsAtStart))
                #endif
                if mergePrompt == nil { askToMergeIfReachedNeighborEnd() }
                resetDragState()
            }
    }

    /// 핸들을 잡은 자리에서 손이 움직인 만큼만 재생 헤드를 옮긴다. 세그먼트 경계에 다가가면 붙는다.
    private func applyScrub(rawMinute: Double) {
        let anchor = scrubAnchor ?? (Double(playheadMinute), rawMinute)
        scrubAnchor = anchor
        let next = NLEPlayheadPolicy.minute(
            raw: anchor.playhead + rawMinute - anchor.touch,
            track: track,
            minuteHeight: minuteHeight
        )
        guard next != playheadMinute else { return }
        playheadMinute = next
        if NLEPlayheadPolicy.isSegmentBoundary(next, track: track) {
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    private func applyTrim(lane: NLEEditorLane, id: String, edge: NLEClipEdge, minute: Int) {
        recordTrimNeighborLength(lane: lane, id: id, edge: edge)
        pushUndoIfNeeded()
        let snapped = NLESnapPolicy.snapped(minute, to: snapTargets(lane: lane, excluding: id), threshold: snapThresholdMinutes)
        trimClip(lane: lane, id: id, edge: edge, toMinute: snapped)
        askToMergeIfReachedNeighborEnd()
    }

    private func resetDragState() {
        trimLengthsAtStart = nil
        dragMode = .none
        isLifted = false
        didPushUndoForDrag = false
        dragScrollShift = 0
        touchLeftTapSlop = false
        selectedAtTouchStart = nil
        scrubAnchor = nil
    }

    /// 대분류 경계를 끌어 한쪽 클립이 최소 길이까지 눌린 채 손을 뗐으면 "합칠까요?"를 묻는다.
    /// 끌기 시작할 때 잡은 클립과 이웃의 길이를 한 번만 적어 둔다.
    private func recordTrimNeighborLength(lane: NLEEditorLane, id: String, edge: NLEClipEdge) {
        guard lane == .main, trimLengthsAtStart == nil else { return }
        trimLengthsAtStart = (
            track.clip(id)?.lengthMinutes ?? 0,
            track.adjacentClip(of: id, edge: edge)?.lengthMinutes ?? 0
        )
    }

    private func askToMergeIfReachedNeighborEnd() {
        guard let lengths = trimLengthsAtStart else { return }
        let target: (id: String, edge: NLEClipEdge)
        switch dragMode {
        case let .trimStart(.main, id): target = (id, .start)
        case let .trimEnd(.main, id): target = (id, .end)
        default: return
        }
        // 지금 배율에서 18pt보다 얇게 눌린 클립은 끝까지 민 것으로 본다.
        let squeezeMinutes = Int((Self.mergeSqueezePoints / max(0.01, minuteHeight)).rounded(.up))
        let pair = track.squeezedMergePair(
            of: target.id, edge: target.edge,
            clipLengthAtStart: lengths.clip, neighborLengthAtStart: lengths.neighbor,
            squeezeMinutes: squeezeMinutes,
            fingerMinute: lastDragMinute
        )
        #if DEBUG
        let neighbor = track.adjacentClip(of: target.id, edge: target.edge)
        NSLog("[NLEMerge] edge=%@ clip=%@ %d→%d neighbor=%@ %d→%d squeeze=%d offered=%d",
              target.edge == .end ? "end" : "start",
              track.clip(target.id)?.option.title ?? "-", lengths.clip, track.clip(target.id)?.lengthMinutes ?? -1,
              neighbor?.option.title ?? "-", lengths.neighbor, neighbor?.lengthMinutes ?? -1,
              squeezeMinutes, pair == nil ? 0 : 1)
        #endif
        guard let pair else { return }
        TaptionPlanDiagnosticsLogger.shared.record(
            "nle_merge_offer",
            metrics: [
                "edge_end": target.edge == .end ? 1 : 0,
                "clip_start_len": Double(lengths.clip),
                "neighbor_start_len": Double(lengths.neighbor),
                "clip_len": Double(track.clip(target.id)?.lengthMinutes ?? -1),
                "neighbor_len": Double(track.adjacentClip(of: target.id, edge: target.edge)?.lengthMinutes ?? -1),
                "squeeze_min": Double(squeezeMinutes),
            ]
        )
        // 손을 떼지 않아도 눌리는 순간 묻는다. 화면 흐름은 멈춘다.
        stopAutoScroll()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        mergePrompt = NLEMergePrompt(
            clipID: pair.survivor.id, neighborID: pair.absorbed.id,
            clipTitle: Self.mainTitle(pair.survivor.option, language: language),
            neighborTitle: Self.mainTitle(pair.absorbed.option, language: language)
        )
    }

    private func confirmMerge(_ prompt: NLEMergePrompt) {
        guard track.clip(prompt.clipID) != nil else { return }
        pushUndo()
        if track.mergeIntoDragged(prompt.clipID, neighborID: prompt.neighborID) {
            selectedClipID = prompt.clipID
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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
                let next = min(max(base * value.magnification, 0.22), NLEZoomPolicy.maxMinuteHeight)
                minuteHeight = next
                setVisibleStart(anchorMinute - Double(anchorY) / Double(max(0.01, next)))
            }
            .onEnded { _ in
                zoomBaseWidth = 0
            }
    }

    // MARK: - 상태

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

        var touchesMainLane: Bool {
            switch self {
            case .move(.main, _, _, _), .trimStart(.main, _), .trimEnd(.main, _): true
            default: false
            }
        }
    }

    var selectedClip: NLEClip? {
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

    /// 화면 가운데가 속한 날. 위로 넘겨 전날을 보면 머리말도 바뀐다.
    private var visibleDateTitle: String {
        let visibleMinutes = minuteHeight > 0 ? Double(containerHeight / minuteHeight) : 0
        let calendar = Calendar.autoupdatingCurrent
        let day = calendar.date(
            byAdding: .day,
            value: NLEDayWindow.dayIndex(Int(visibleStartMinute + visibleMinutes / 2)),
            to: calendar.startOfDay(for: date)
        ) ?? date
        return day.formatted(.dateTime.month().day().weekday(.wide).locale(language.locale))
    }

    /// 지우기가 향하는 클립. 상세활동을 골랐으면 상세활동이 먼저다.
    private var canDelete: Bool {
        if activeSubClip != nil { return true }
        return selectedClip.map { !$0.isGap } ?? false
    }

    var categoryOptions: [MapHomeSidebarMajorCategory] {
        MapHomeSidebarMajorCategory.all(categoryColors: model.settings.mapCategoryColors)
            + model.settings.mapUserActivityCategories.map(MapHomeSidebarMajorCategory.custom)
    }

    private func visibleClips(geometry: NLETimelineGeometry) -> [NLEClip] {
        track.clips.filter {
            Double($0.endMinute) >= geometry.visibleStartMinute
                && Double($0.startMinute) <= geometry.visibleEndMinute
        }
    }

    // MARK: - 동작

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
        case .scrub: true
        case .trimStart, .trimEnd: touchLeftTapSlop
        case .move: isLifted
        }
    }

    /// 몸통을 잡았으면 0.4초를 세어 집어 들고 그때 고른다. 경계 다듬기와 재생 헤드는 곧바로 움직인다.
    private func beginLiftHoldIfNeeded() {
        guard case let .move(lane, id, originMinute, _) = dragMode else { return }
        reorderCandidate = dragMode
        liftTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(NLEReorderHoldPolicy.delay))
            guard !Task.isCancelled, reorderCandidate != nil else { return }
            // 집어 든 뒤에는 지금 손가락 아래를 기준으로 삼아 클립이 튀지 않게 한다.
            dragMode = .move(lane: lane, id: id, originMinute: originMinute, grabMinute: lastDragMinute)
            isLifted = true
            selectedClipID = id
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

    /// 손을 댄 자리로 이번 끌기의 뜻을 정한다. 여기서는 아무것도 고르지 않는다.
    /// 재생 헤드는 핸들로, 경계 다듬기는 고른 클립으로만 받고 나머지 끌기는 화면을 민다.
    private func resolveDragMode(
        at point: CGPoint,
        geometry: NLETimelineGeometry,
        width: CGFloat
    ) -> NLEEditorDragMode {
        switch laneWidths(width).lane(atX: point.x) {
        case .gutter:
            let playheadY = geometry.y(forMinute: Double(playheadMinute))
            return NLEPlayheadPolicy.grabsHandle(touchY: point.y, playheadY: playheadY) ? .scrub : .pan
        case .place:
            return .pan
        case .right:
            return subDragMode(at: point, geometry: geometry)
        case .main:
            break
        }
        if let selectedClip, let trim = trimMode(at: point, clip: selectedClip, geometry: geometry) {
            return trim
        }
        let minute = geometry.minute(forY: point.y)
        guard let clip = track.clip(atMinute: Int(minute.rounded(.down))) else { return .pan }
        return .move(lane: .main, id: clip.id, originMinute: clip.startMinute, grabMinute: Int(minute.rounded()))
    }

    /// 고른 상세는 끝을 잡아 자르고, 몸통을 잡아 옮긴다. 그 밖의 곳은 화면을 민다.
    private func subDragMode(at point: CGPoint, geometry: NLETimelineGeometry) -> NLEEditorDragMode {
        let minute = geometry.minute(forY: point.y)
        guard let sub = selectedSubClipID.flatMap({ subTrack.clip($0) }) else { return .pan }
        if abs(point.y - geometry.y(forMinute: Double(sub.startMinute))) <= Self.trimReach {
            return .trimStart(lane: .sub, id: sub.id)
        }
        if abs(point.y - geometry.y(forMinute: Double(sub.endMinute))) <= Self.trimReach {
            return .trimEnd(lane: .sub, id: sub.id)
        }
        guard sub.contains(minute: Int(minute.rounded(.down))) else { return .pan }
        return .move(lane: .sub, id: sub.id, originMinute: sub.startMinute, grabMinute: Int(minute.rounded(.down)))
    }

    /// 고른 클립의 경계를 잡았는가. 짧아 경계 두 곳이 겹치는 클립은 맞닿은 이웃의 경계로 대신 민다.
    private func trimMode(at point: CGPoint, clip: NLEClip, geometry: NLETimelineGeometry) -> NLEEditorDragMode? {
        if geometry.height(minutes: Double(clip.lengthMinutes)) >= Self.trimReach * 3 {
            let topY = geometry.y(forMinute: Double(clip.startMinute))
            let bottomY = geometry.y(forMinute: Double(clip.endMinute))
            if abs(point.y - topY) <= Self.trimReach { return .trimStart(lane: .main, id: clip.id) }
            if abs(point.y - bottomY) <= Self.trimReach { return .trimEnd(lane: .main, id: clip.id) }
            return nil
        }
        return shortClipBoundary(at: point, clip: clip, geometry: geometry)
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

    /// 손가락이 거의 움직이지 않았으면 누른 것이다. 선택은 여기서만 바뀐다(NLE1104A01).
    private func handleTap(at point: CGPoint, geometry: NLETimelineGeometry, width: CGFloat) {
        if laneWidths(width).lane(atX: point.x) == .right {
            let minute = Int(geometry.minute(forY: point.y).rounded(.down))
            UISelectionFeedbackGenerator().selectionChanged()
            let tapped = subClip(atMinute: minute)
            selectedSubClipID = tapped?.id == selectedSubClipID ? nil : tapped?.id
            quickMenuMinute = nil
            if tapped != nil { selectedClipID = nil }
            return
        }
        guard dragMode.touchesMainLane else { return }
        let minute = Int(geometry.minute(forY: point.y).rounded(.down))
        guard let clip = track.clip(atMinute: minute) else { return }
        if !pickedClipIDs.isEmpty { return togglePicked(clip.id) }
        UISelectionFeedbackGenerator().selectionChanged()
        // 고른 클립을 다시 눌렀으면 선택을 푼다(NLE1103A03).
        if NLESelectionTapPolicy.clearsSelection(
            selectedAtTouchStart: selectedAtTouchStart,
            touchedClipID: clip.id,
            isMainLaneTouch: true,
            leftSlop: touchLeftTapSlop,
            didEdit: didPushUndoForDrag,
            isLifted: isLifted
        ) {
            selectedClipID = nil
            quickMenuMinute = nil
            return
        }
        selectedClipID = clip.id
        selectedSubClipID = nil
        quickMenuMinute = quickMenuMinute == nil ? minute : nil
    }

    /// 자석 거리는 화면에서 10pt. 1분 편집 배율에서는 0분이 되어 1분씩 그대로 움직인다.
    private var snapThresholdMinutes: Int {
        min(NLESnapPolicy.thresholdMinutes, Int((10 / max(0.01, minuteHeight)).rounded(.down)))
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
        let option = Self.option(for: category, language: language)
        if isSubClipActive {
            subTrack.setOption(clip.id, to: option)
        } else {
            track.setOption(clip.id, to: option)
        }
    }

    func pushUndo() {
        undoStack.append(currentSnapshot)
        if undoStack.count > 40 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func pushUndoIfNeeded() {
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

    private var saveGate: NLEClipSaveGate {
        NLEClipSaveGate(hasChanges: hasChanges, isSaving: isSaving, isDayLoaded: isDayLoaded, recordsLoaded: model.hasLoadedFullSnapshot)
    }

    private func apply() {
        guard saveGate.canApply else { return }
        let dayStart = Calendar.autoupdatingCurrent.startOfDay(for: date)
        // 대분류를 먼저, 상세활동을 나중에 저장한다. 상세활동이 위에 남아야 한다.
        // 상세활동이 비운 자리는 그 시각의 대분류가 이어받는다.
        var detailTrack = subTrack
        for clip in detailTrack.clips where clip.isDirty {
            guard let main = track.clip(atMinute: clip.startMinute) else { continue }
            detailTrack.setFillOption(main.option, forClipID: clip.id)
        }
        let main = track.editRequests(dayStart: dayStart)
        let detail = detailTrack.editRequests(dayStart: dayStart)
        guard !main.isEmpty || !detail.isEmpty else {
            dismiss()
            return
        }
        isSaving = true
        Task { @MainActor in
            // 한 번에 저장하고, 실패하면 아무것도 바뀌지 않은 채 편집기에 남는다(OVW1108A01).
            let saved = await model.saveClipEditBatch(main: main, detail: detail)
            isSaving = false
            guard saved else { return showSaveFailedNotice() }
            onSaved()
            dismiss()
        }
    }
}
