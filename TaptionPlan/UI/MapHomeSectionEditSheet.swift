import SwiftUI
import UIKit
import TaptionPlanCore

struct MapHomeSectionEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let selection: MapHomeSectionEditSelection
    let language: MapHomeLanguage
    let onSaved: (ActivitySectionEditSaveResult) -> Void

    @State private var startMinute: Int
    @State private var endMinute: Int
    @State private var selectedCategoryID: String
    @State private var selectedMovementMode: TravelMode?
    @State private var movementSelectionWasChanged = false
    @State private var dragBaseMinute: Int?
    @State private var lastDragPublishUptime: TimeInterval = 0
    @State private var viewport: MapHomeSectionViewportState
    @State private var magnifyOrigin: MapHomeSectionViewportState?
    @State private var panOrigin: MapHomeSectionViewportState?
    /// 손잡이를 끄는 중인지. 끄는 동안에는 세로 스크롤이 함께 움직이지 않는다.
    @State private var isHandleDragging = false
    /// 누른 상세 활동. 테두리를 진하게 표시한다.
    @State private var selectedDetailID: UUID?
    @State private var lastMagnifyPublishUptime: TimeInterval = 0
    @State private var cutMinute: Int?
    @State private var cutDragBaseMinute: Int?
    @State private var insertedDetailID: UUID?
    @State private var draggingDetailID: UUID?
    @State private var detailDragTranslation: CGFloat = 0
    @State private var lastDetailDragRenderUptime: TimeInterval = 0
    @State private var isSaving = false
    /// 동영상 편집기(NLE) 방식의 클립 편집 화면.
    @State private var showsClipEditor = false

    init(
        model: AppModel,
        selection: MapHomeSectionEditSelection,
        language: MapHomeLanguage,
        onSaved: @escaping (ActivitySectionEditSaveResult) -> Void
    ) {
        self.model = model
        self.selection = selection
        self.language = language
        self.onSaved = onSaved
        _startMinute = State(initialValue: selection.segment.startMinute)
        _endMinute = State(initialValue: selection.segment.endMinute)
        _selectedCategoryID = State(initialValue: selection.segment.categoryID)
        _selectedMovementMode = State(initialValue: MapHomeMovementEditOption.mode(
            categoryID: selection.segment.categoryID,
            behavior: selection.segment.behavior,
            title: selection.segment.title
        ))
        _viewport = State(initialValue: MapHomeSectionViewportMath.initialState(
            segmentStart: selection.segment.startMinute,
            segmentEnd: selection.segment.endMinute
        ))
    }

    private var categories: [MapHomeSidebarMajorCategory] {
        MapHomeSidebarMajorCategory.all(
            categoryColors: model.settings.mapCategoryColors
        ) + model.settings.mapUserActivityCategories.map(MapHomeSidebarMajorCategory.custom)
    }

    private var selectedCategory: MapHomeSidebarMajorCategory {
        categories.first { $0.id == selectedCategoryID }
            ?? MapHomeSidebarMajorCategory.presentation(
                for: selectedCategoryID,
                categoryColors: model.settings.mapCategoryColors
            )
    }

    private var selectedPreviewCategory: MapHomeSidebarMajorCategory {
        guard selectedCategoryID == "movement",
              let selectedMovementMode else { return selectedCategory }
        return MapHomeSidebarMajorCategory(
            id: "movement:\(selectedMovementMode.rawValue)",
            title: MapHomeMovementEditOption.localizedTitle(
                for: selectedMovementMode,
                language: language
            ),
            systemImage: MovementPresentation.symbol(for: selectedMovementMode),
            hex: model.settings.mapCategoryColors["movement"]
                ?? MapHomePastelPalette.hex("movement")
        )
    }

    private var visibleRange: ClosedRange<Int> {
        viewport.range
    }

    private var insertedDetail: MapHomeSectionDetail? {
        guard let insertedDetailID else { return nil }
        return selection.details.first { $0.id == insertedDetailID }
    }

    private var originalOption: ActivityCorrectionOption {
        ActivityCorrectionOption(
            id: "phase.\(selection.segment.categoryID)",
            title: selection.segment.title,
            behavior: selection.segment.behavior,
            categoryID: selection.segment.categoryID,
            systemImage: selection.activity.systemImage,
            isAutomatic: false,
            isCustom: false
        )
    }

    private var editHeader: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Text(language.text("닫기", "Close"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold))
                    .foregroundStyle(Color.tpReferenceRose)
                    .padding(.horizontal, 15)
                    .frame(minHeight: 38)
                    .background(
                        Color.tpReferenceRose.opacity(0.10),
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
            Spacer()
            Text(language.text("행동 구간 편집", "Edit activity section"))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(20)), weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer()
            Button {
                save()
            } label: {
                Text(language.text("저장", "Save"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 15)
                    .frame(minHeight: 38)
                    .background(
                        Color.tpReferenceBlue,
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
            .disabled(isSaving || startMinute >= endMinute)
            .opacity(isSaving || startMinute >= endMinute ? 0.45 : 1)
        }
        .frame(minHeight: 44)
        .background(Color.tpBackground)
        .zIndex(1)
    }

    var body: some View {
        sheetBody
            .fullScreenCover(isPresented: $showsClipEditor) {
                MapHomeNLEClipEditor(
                    model: model,
                    language: language,
                    date: selection.date,
                    segments: selection.daySegments.isEmpty
                        ? [selection.segment]
                        : selection.daySegments,
                    details: selection.dayDetails.isEmpty
                        ? selection.details
                        : selection.dayDetails,
                    focusMinute: selection.segment.startMinute,
                    onSaved: {
                        // 클립 편집은 하루 전체를 다시 덮으므로, 고른 구간으로 돌아간다.
                        let calendar = Calendar.autoupdatingCurrent
                        let dayStart = calendar.startOfDay(for: selection.date)
                        let start = calendar.date(
                            byAdding: .minute,
                            value: selection.segment.startMinute,
                            to: dayStart
                        ) ?? dayStart
                        let end = calendar.date(
                            byAdding: .minute,
                            value: selection.segment.endMinute,
                            to: dayStart
                        ) ?? dayStart
                        onSaved(ActivitySectionEditSaveResult(
                            recordIDs: [],
                            selectedSpan: TimeSpan(start: start, end: end)
                        ))
                        dismiss()
                    }
                )
            }
            .onDisappear {
                // 화면이 사라지면 드래그 상태를 모두 풀어 스크롤 금지가 남지 않게 한다.
                isHandleDragging = false
                panOrigin = nil
                draggingDetailID = nil
                detailDragTranslation = 0
            }
    }

    private var sheetBody: some View {
        VStack(spacing: 14) {
            editHeader

            HStack(spacing: 10) {
                timeControl(
                    title: language.text("시작", "Start"),
                    minute: startMinute,
                    range: selection.segment.startMinute...(endMinute - 1),
                    isStart: true
                )
                .disabled(cutMinute != nil || insertedDetail != nil)
                .opacity(cutMinute != nil || insertedDetail != nil ? 0.62 : 1)
                timeControl(
                    title: language.text("끝", "End"),
                    minute: endMinute,
                    range: (startMinute + 1)...selection.segment.endMinute,
                    isStart: false
                )
                .disabled(cutMinute != nil || insertedDetail != nil)
                .opacity(cutMinute != nil || insertedDetail != nil ? 0.62 : 1)
                categorySelectionMenu
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
                .frame(height: 44)
                .background(Color.tpSurface, in: Capsule())
            }
            HStack(spacing: 8) {
                let sliceTint = Color(hex: selectedPreviewCategory.hex)
                let isSlicing = cutMinute != nil
                Button {
                    if !isSlicing {
                        insertedDetailID = nil
                        cutMinute = (selection.segment.startMinute
                            + selection.segment.endMinute) / 2
                    } else {
                        cutMinute = nil
                    }
                } label: {
                    Label(
                        cutMinute == nil
                            ? language.text("대분류 자르기", "Slice category")
                            : language.text("자르기 취소", "Cancel slice"),
                        systemImage: isSlicing
                            ? "xmark.circle.fill"
                            : "rectangle.split.1x2"
                    )
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold))
                    .foregroundStyle(isSlicing ? Color.white : sliceTint)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 36)
                    .background(
                        isSlicing ? sliceTint : sliceTint.opacity(0.10),
                        in: Capsule()
                    )
                    .overlay {
                        Capsule()
                            .stroke(sliceTint.opacity(isSlicing ? 0 : 0.55))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .accessibilityLabel(
                    isSlicing
                        ? language.text("대분류 자르기 취소", "Cancel category slice")
                        : language.text("대분류 자르기", "Slice category")
                )

                if cutMinute != nil || insertedDetail != nil {
                    Button(language.text("편집 초기화", "Reset edit")) {
                        cutMinute = nil
                        insertedDetailID = nil
                        startMinute = selection.segment.startMinute
                        endMinute = selection.segment.endMinute
                        selectedCategoryID = selection.segment.categoryID
                        selectedMovementMode = MapHomeMovementEditOption.mode(
                            categoryID: selection.segment.categoryID,
                            behavior: selection.segment.behavior,
                            title: selection.segment.title
                        )
                        movementSelectionWasChanged = false
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
                Text(
                    insertedDetail == nil
                        ? language.text(
                            "상세 활동을 오른쪽으로 밀어 삽입",
                            "Swipe a detail right to insert"
                        )
                        : language.text("상세 활동 시간으로 분할됨", "Split to detail time")
                )
                .font(.taptionFixed(size: 11))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)

            clipEditorEntry

            HStack {
                Text(language.text("상세 활동", "Detailed activities"))
                    .frame(maxWidth: .infinity)
                Text(language.text("대분류", "Category"))
                    .frame(width: 118)
            }
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .bold))
            .foregroundStyle(.secondary)

            GeometryReader { proxy in
                let trackHeight = max(proxy.size.height, 1)
                let leftWidth = max(120, proxy.size.width - 130)
                let detailColumns = MapHomeSectionTimelineLayoutMath
                    .detailColumns(
                        for: selection.details,
                        visibleRange: visibleRange
                    )
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.tpSurface)

                    timelineGrid(height: trackHeight)
                    otherDaySegmentsLayer(x: leftWidth + 9, width: 112, height: trackHeight)
                    otherDayDetailsLayer(height: trackHeight)
                    dimOutsideSelection(height: trackHeight)

                    ForEach(selection.details) { detail in
                        detailBlock(
                            detail,
                            column: detailColumns[detail.id] ?? .single,
                            leftWidth: leftWidth,
                            height: trackHeight
                        )
                    }

                    majorTimeline(
                        x: leftWidth + 9,
                        width: 112,
                        height: trackHeight
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.tpBorder, lineWidth: TaptionBorder.width)
                }
                .simultaneousGesture(sectionMagnifyGesture(height: trackHeight))
                .simultaneousGesture(sectionPanGesture(height: trackHeight))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(Color.tpBackground.ignoresSafeArea())
    }

    /// 동영상 편집기(NLE) 방식의 클립 편집으로 넘어가는 입구.
    private var clipEditorEntry: some View {
        Button {
            showsClipEditor = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.split.3x1.fill")
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(17)), weight: .semibold))
                    .foregroundStyle(Color.tpReferenceBlue)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(language.text("클립 편집", "Clip editor"))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .bold))
                        .foregroundStyle(Color.tpInk)
                    Text(language.text(
                        "24시간 대분류 클립과 서브클립을 동영상처럼 편집",
                        "Edit 24h clips and sub-clips like video"
                    ))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
                    .foregroundStyle(Color.tpSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.tpBorder, lineWidth: TaptionBorder.width)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(language.text("클립 편집", "Clip editor"))
    }

    private var categorySelectionMenu: some View {
        let title = selectedMovementMode.map {
            MapHomeMovementEditOption.localizedTitle(
                for: $0,
                language: language
            )
        } ?? selectedCategory.localizedTitle(language)
        let systemImage = selectedMovementMode.map {
            MovementPresentation.symbol(for: $0)
        } ?? selectedCategory.systemImage

        return Menu {
            ForEach(categories) { category in
                if category.id == "movement" {
                    Menu {
                        Button {
                            selectCategory(category, movementMode: nil)
                        } label: {
                            Label(
                                category.localizedTitle(language),
                                systemImage: category.systemImage
                            )
                        }
                        Divider()
                        ForEach(MapHomeMovementEditOption.modes, id: \.self) { mode in
                            Button {
                                selectCategory(category, movementMode: mode)
                            } label: {
                                Label(
                                    MapHomeMovementEditOption.localizedTitle(
                                        for: mode,
                                        language: language
                                    ),
                                    systemImage: MovementPresentation.symbol(for: mode)
                                )
                            }
                        }
                    } label: {
                        Label(
                            category.localizedTitle(language),
                            systemImage: category.systemImage
                        )
                    }
                } else {
                    Button {
                        selectCategory(category, movementMode: nil)
                    } label: {
                        Label(
                            category.localizedTitle(language),
                            systemImage: category.systemImage
                        )
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Label(title, systemImage: systemImage)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(
            language.text("대분류 수정 \(title)", "Edit category \(title)")
        )
        .accessibilityHint(
            language.text(
                "탭해서 대분류를 변경합니다.",
                "Tap to change the category."
            )
        )
    }

    private func selectCategory(
        _ category: MapHomeSidebarMajorCategory,
        movementMode: TravelMode?
    ) {
        selectedCategoryID = category.id
        selectedMovementMode = category.id == "movement" ? movementMode : nil
        movementSelectionWasChanged = true
    }

    private func timeControl(
        title: String,
        minute: Int,
        range: ClosedRange<Int>,
        isStart: Bool
    ) -> some View {
        Menu {
            Picker(
                title,
                selection: Binding(
                    get: { isStart ? startMinute : endMinute },
                    set: { value in
                        if isStart {
                            startMinute = value
                        } else {
                            endMinute = value
                        }
                    }
                )
            ) {
                ForEach(Array(stride(from: range.lowerBound, through: range.upperBound, by: 5)), id: \.self) {
                    Text(timeLabel($0)).tag($0)
                }
            }
        } label: {
            VStack(spacing: 1) {
                Text(title).font(.taptionFixed(size: 11)).foregroundStyle(.secondary)
                Text(timeLabel(minute)).font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .bold))
            }
            .frame(width: 70, height: 44)
            .background(Color.tpSurface, in: Capsule())
        }
    }

    private func timelineGrid(height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(hourMarks, id: \.self) { minute in
                let y = yPosition(minute, height: height)
                Path { path in
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: 1_000, y: y))
                }
                .stroke(Color.tpBorder, lineWidth: TaptionBorder.width)
                Text(timeLabel(minute))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(9)), weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 5)
                    .position(x: 23, y: max(7, y + 7))
            }
        }
    }

    private var hourMarks: [Int] {
        let first = Int(ceil(Double(visibleRange.lowerBound) / 60)) * 60
        return Array(stride(from: first, through: visibleRange.upperBound, by: 60))
    }

    @ViewBuilder
    private func detailBlock(
        _ detail: MapHomeSectionDetail,
        column: MapHomeSectionTimelineLayoutMath.DetailColumn,
        leftWidth: CGFloat,
        height: CGFloat
    ) -> some View {
        let start = max(detail.startMinute, visibleRange.lowerBound)
        let end = min(detail.endMinute, visibleRange.upperBound)
        if start < end {
            let y = yPosition(start, height: height)
            let blockHeight = max(26, yPosition(end, height: height) - y)
            let detailFrame = MapHomeSectionTimelineLayoutMath.detailFrame(
                leftWidth: leftWidth,
                column: column
            )
            let isCompact = column.count > 1
            let category = MapHomeSidebarMajorCategory.presentation(
                for: detail.categoryID,
                categoryColors: model.settings.mapCategoryColors
            )
            HStack(spacing: isCompact ? 2 : 5) {
                MapHomeStickmanGlyph(
                    action: category.stickmanAction,
                    size: 22
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(KnownActivityTitleLocalizer.localized(detail.title, language: language)).lineLimit(1)
                    Text("\(timeLabel(detail.startMinute))–\(timeLabel(detail.endMinute))")
                        .font(.system(
                            size: isCompact ? 8 : 9,
                            weight: .medium,
                            design: .rounded
                        ))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .opacity(0.72)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.right")
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(9)), weight: .bold))
            }
            .font(.system(
                size: isCompact ? 9 : 11,
                weight: .semibold,
                design: .rounded
            ))
            .foregroundStyle(category.tint)
            .padding(.horizontal, isCompact ? 5 : 8)
            .frame(width: detailFrame.width, height: blockHeight, alignment: .leading)
            .background(
                insertedDetailID == detail.id || selectedDetailID == detail.id
                    ? category.tint.opacity(0.30)
                    : category.tint.opacity(0.13),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(category.tint, lineWidth: selectedDetailID == detail.id ? 2.5 : 0)
            }
            .simultaneousGesture(TapGesture().onEnded { selectedDetailID = detail.id })
            .offset(
                x: draggingDetailID == detail.id
                    ? min(max(detailDragTranslation, 0), 94)
                    : 0
            )
            .position(x: detailFrame.midX, y: y + blockHeight / 2)
            .highPriorityGesture(detailSliceGesture(detail))
            .accessibilityLabel("\(detail.title), \(timeLabel(detail.startMinute))부터 \(timeLabel(detail.endMinute))")
            .accessibilityHint(
                language.text(
                    "오른쪽으로 밀면 대분류에 삽입합니다",
                    "Swipe right to insert into the category"
                )
            )
        }
    }

    private func detailSliceGesture(
        _ detail: MapHomeSectionDetail
    ) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard value.translation.width > 0,
                      abs(value.translation.width) > abs(value.translation.height)
                else { return }
                if draggingDetailID != detail.id {
                    draggingDetailID = detail.id
                }
                guard TimelineInteractionFrameGate.shouldRender(
                    lastUptime: &lastDetailDragRenderUptime,
                    nowUptime: ProcessInfo.processInfo.systemUptime
                ) else { return }
                if detailDragTranslation != value.translation.width {
                    detailDragTranslation = value.translation.width
                }
            }
            .onEnded { value in
                if draggingDetailID == detail.id,
                   MapHomeSectionViewportMath.acceptsDetailSlice(
                       translation: value.translation
                   ) {
                    activateDetailSlice(detail)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
                draggingDetailID = nil
                detailDragTranslation = 0
                lastDetailDragRenderUptime = 0
            }
    }

    private func activateDetailSlice(_ detail: MapHomeSectionDetail) {
        let start = max(detail.startMinute, selection.segment.startMinute)
        let end = min(detail.endMinute, selection.segment.endMinute)
        guard start < end else { return }
        cutMinute = nil
        insertedDetailID = detail.id
        startMinute = start
        endMinute = end
        selectedCategoryID = categories.contains { $0.id == detail.categoryID }
            ? detail.categoryID
            : "activity"
        selectedMovementMode = MapHomeMovementEditOption.mode(
            categoryID: detail.categoryID,
            behavior: detail.behavior,
            title: detail.title
        )
        movementSelectionWasChanged = false
    }

    private func majorTimeline(
        x: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(majorPreviewPieces) { piece in
                if piece.endMinute > visibleRange.lowerBound,
                   piece.startMinute < visibleRange.upperBound {
                    majorPreviewBlock(piece, width: width, height: height)
                        .position(
                            x: x + width / 2,
                            y: yPosition(
                                (max(piece.startMinute, visibleRange.lowerBound)
                                    + min(piece.endMinute, visibleRange.upperBound)) / 2,
                                height: height
                            )
                        )
                }
            }

            if cutMinute == nil, insertedDetail == nil {
                boundaryHandle(isStart: true, x: x, width: width, height: height)
                boundaryHandle(isStart: false, x: x, width: width, height: height)
            }

            if let cutMinute {
                ZStack {
                    Capsule().fill(Color.white)
                    Image(systemName: "scissors")
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(9)), weight: .bold))
                        .foregroundStyle(Color.tpInk)
                }
                .frame(width: width - 12, height: 12)
                .contentShape(Rectangle().inset(by: -12))
                .position(
                    x: x + width / 2,
                    y: yPosition(cutMinute, height: height)
                )
                .highPriorityGesture(cutDragGesture(trackHeight: height))
                .accessibilityLabel(language.text("자르기 위치", "Slice position"))
                .accessibilityValue(timeLabel(cutMinute))
            }
        }
    }

    private var majorPreviewPieces: [MapHomeSectionPreviewPiece] {
        let originalStart = selection.segment.startMinute
        let originalEnd = selection.segment.endMinute
        let originalCategory = MapHomeSidebarMajorCategory(
            id: selection.segment.categoryID,
            title: selection.segment.title,
            systemImage: selection.activity.systemImage,
            hex: model.settings.mapCategoryColors[selection.segment.categoryID]
                ?? MapHomePastelPalette.hex(selection.segment.categoryID)
        )
        let unconfirmed = MapHomeSidebarMajorCategory.presentation(
            for: "unconfirmed",
            categoryColors: model.settings.mapCategoryColors
        )
        let raw: [(Int, Int, MapHomeSidebarMajorCategory)]
        if let detail = insertedDetail {
            let detailStart = max(detail.startMinute, originalStart)
            let detailEnd = min(detail.endMinute, originalEnd)
            raw = [
                (originalStart, detailStart, originalCategory),
                (detailStart, detailEnd, selectedPreviewCategory),
                (detailEnd, originalEnd, originalCategory),
            ]
        } else if let cutMinute {
            raw = [
                (originalStart, cutMinute, selectedPreviewCategory),
                (cutMinute, originalEnd, unconfirmed),
            ]
        } else {
            raw = [
                (originalStart, startMinute, unconfirmed),
                (startMinute, endMinute, selectedPreviewCategory),
                (endMinute, originalEnd, unconfirmed),
            ]
        }
        return raw.enumerated().compactMap { index, value in
            guard value.0 < value.1 else { return nil }
            return MapHomeSectionPreviewPiece(
                id: "\(index)-\(value.0)-\(value.1)-\(value.2.id)",
                startMinute: value.0,
                endMinute: value.1,
                category: value.2
            )
        }
    }

    private func majorPreviewBlock(
        _ piece: MapHomeSectionPreviewPiece,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        let visibleStart = max(piece.startMinute, visibleRange.lowerBound)
        let visibleEnd = min(piece.endMinute, visibleRange.upperBound)
        let blockHeight = max(
            1,
            yPosition(visibleEnd, height: height)
                - yPosition(visibleStart, height: height)
        )
        return ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(piece.category.tint.opacity(0.88))
            if blockHeight >= 34 {
                VStack(spacing: 2) {
                    MapHomeStickmanGlyph(
                        action: piece.category.stickmanAction,
                        size: 22
                    )
                    Text(piece.category.localizedTitle(language)).lineLimit(1)
                    if blockHeight >= 54 {
                        Text("\(timeLabel(piece.startMinute))–\(timeLabel(piece.endMinute))")
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(8)), weight: .bold))
                    }
                }
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .bold))
                .foregroundStyle(adaptiveLabelColor(on: piece.category.tint))
            }
        }
        .frame(width: width, height: blockHeight)
    }

    private func boundaryHandle(
        isStart: Bool,
        x: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        Capsule()
            .fill(Color.white)
            .overlay(Capsule().stroke(Color.tpInk.opacity(0.25), lineWidth: 1))
            .frame(
                width: width - 20,
                height: MapHomeSectionEditLayout.boundaryHandleHeight
            )
            .contentShape(Rectangle().inset(by: -12))
            .position(
                x: x + width / 2,
                y: MapHomeSectionEditLayout.handleCenterY(
                    boundaryY: yPosition(
                        isStart ? startMinute : endMinute,
                        height: height
                    ),
                    frameHeight: height
                )
            )
            .highPriorityGesture(
                boundaryDragGesture(isStart: isStart, trackHeight: height)
            )
    }

    private func cutDragGesture(trackHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                updateCutMinute(
                    translation: value.translation.height,
                    trackHeight: trackHeight,
                    isFinal: false
                )
            }
            .onEnded { value in
                updateCutMinute(
                    translation: value.translation.height,
                    trackHeight: trackHeight,
                    isFinal: true
                )
                cutDragBaseMinute = nil
                lastDragPublishUptime = 0
            }
    }

    private func updateCutMinute(
        translation: CGFloat,
        trackHeight: CGFloat,
        isFinal: Bool
    ) {
        if cutDragBaseMinute == nil {
            cutDragBaseMinute = cutMinute
        }
        guard let cutDragBaseMinute else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        guard MapHomeSectionBoundaryMath.shouldPublish(
            lastUptime: lastDragPublishUptime,
            currentUptime: uptime,
            isFinal: isFinal
        ) else { return }
        lastDragPublishUptime = uptime
        let delta = Int(
            (translation / max(trackHeight, 1)
                * CGFloat(viewport.durationMinutes)).rounded()
        )
        cutMinute = min(
            max(cutDragBaseMinute + delta, selection.segment.startMinute + 1),
            selection.segment.endMinute - 1
        )
    }

    private func boundaryDragGesture(
        isStart: Bool,
        trackHeight: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                isHandleDragging = true
                updateBoundary(
                    translation: value.translation.height,
                    isStart: isStart,
                    trackHeight: trackHeight,
                    isFinal: false
                )
            }
            .onEnded { value in
                updateBoundary(
                    translation: value.translation.height,
                    isStart: isStart,
                    trackHeight: trackHeight,
                    isFinal: true
                )
                isHandleDragging = false
                dragBaseMinute = nil
                lastDragPublishUptime = 0
            }
    }

    private func updateBoundary(
        translation: CGFloat,
        isStart: Bool,
        trackHeight: CGFloat,
        isFinal: Bool
    ) {
        if dragBaseMinute == nil {
            dragBaseMinute = isStart ? startMinute : endMinute
        }
        guard let dragBaseMinute else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        guard MapHomeSectionBoundaryMath.shouldPublish(
            lastUptime: lastDragPublishUptime,
            currentUptime: uptime,
            isFinal: isFinal
        ) else { return }
        lastDragPublishUptime = uptime
        let projectedMinute = MapHomeSectionBoundaryMath.minute(
            baseMinute: dragBaseMinute,
            translation: translation,
            trackHeight: trackHeight,
            visibleRange: visibleRange,
            limit: isStart ? endMinute : startMinute,
            isStart: isStart
        )
        let minute = isStart
            ? max(projectedMinute, selection.segment.startMinute)
            : min(projectedMinute, selection.segment.endMinute)
        if isStart {
            if startMinute != minute { startMinute = minute }
        } else if endMinute != minute {
            endMinute = minute
        }
    }

    /// 선택한 구간 밖의 상세 활동을 흐리게 그린다. 선택한 구간의 상세 활동은 아래 층에서 진하게 그린다.
    private func otherDayDetailsLayer(height: CGFloat) -> some View {
        let selectedIDs = Set(selection.details.map(\.id))
        return ZStack(alignment: .topLeading) {
            ForEach(selection.dayDetails.filter { !selectedIDs.contains($0.id) }) { detail in
                let top = min(max(yPosition(detail.startMinute, height: height), 0), height)
                let bottom = min(max(yPosition(detail.endMinute, height: height), 0), height)
                let tint = MapHomeSidebarMajorCategory.presentation(
                    for: detail.categoryID,
                    categoryColors: model.settings.mapCategoryColors
                ).tint
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.opacity(0.22))
                    .frame(height: max(4, bottom - top))
                    .padding(.horizontal, 22)
                    .offset(y: top)
            }
        }
        .allowsHitTesting(false)
    }

    /// 같은 날의 다른 대분류 구간을 오른쪽 대분류 열에 흐리게 그린다(선택한 구간은 진하게 따로 그린다).
    private func otherDaySegmentsLayer(x: CGFloat, width: CGFloat, height: CGFloat) -> some View {
        let pieces: [MapHomeSectionPreviewPiece] = selection.daySegments
            .filter { $0.id != selection.segment.id }
            .compactMap { segment in
                guard let category = categories.first(where: { $0.id == segment.categoryID }) else { return nil }
                return MapHomeSectionPreviewPiece(
                    id: segment.id,
                    startMinute: segment.startMinute,
                    endMinute: segment.endMinute,
                    category: category
                )
            }
        return ZStack(alignment: .topLeading) {
            ForEach(pieces) { piece in
                if piece.endMinute > visibleRange.lowerBound,
                   piece.startMinute < visibleRange.upperBound {
                    majorPreviewBlock(piece, width: width, height: height)
                        .opacity(0.4)
                        .position(
                            x: x + width / 2,
                            y: yPosition(
                                (max(piece.startMinute, visibleRange.lowerBound)
                                    + min(piece.endMinute, visibleRange.upperBound)) / 2,
                                height: height
                            )
                        )
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// 세로로 끌면 보이는 시간 범위를 옮긴다(확대된 상태에서 위아래로 스크롤).
    private func sectionPanGesture(height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !isHandleDragging,
                      abs(value.translation.height) > abs(value.translation.width) else { return }
                if panOrigin == nil { panOrigin = viewport }
                guard let panOrigin else { return }
                let minutesPerPoint = CGFloat(panOrigin.durationMinutes) / max(height, 1)
                let shift = Int((-value.translation.height * minutesPerPoint).rounded())
                let maxStart = 1_440 - panOrigin.durationMinutes
                let next = MapHomeSectionViewportState(
                    startMinute: min(max(panOrigin.startMinute + shift, 0), maxStart),
                    durationMinutes: panOrigin.durationMinutes
                )
                if viewport != next { viewport = next }
            }
            .onEnded { _ in
                panOrigin = nil
            }
    }

    private func sectionMagnifyGesture(
        height: CGFloat
    ) -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.005)
            .onChanged { value in
                if magnifyOrigin == nil {
                    magnifyOrigin = viewport
                }
                guard let magnifyOrigin else { return }
                let uptime = ProcessInfo.processInfo.systemUptime
                guard MapHomeSectionBoundaryMath.shouldPublish(
                    lastUptime: lastMagnifyPublishUptime,
                    currentUptime: uptime,
                    isFinal: false
                ) else { return }
                lastMagnifyPublishUptime = uptime
                viewport = MapHomeSectionViewportMath.zoomed(
                    from: magnifyOrigin,
                    magnification: value.magnification,
                    anchorY: value.startLocation.y,
                    height: height
                )
            }
            .onEnded { value in
                if let magnifyOrigin {
                    viewport = MapHomeSectionViewportMath.zoomed(
                        from: magnifyOrigin,
                        magnification: value.magnification,
                        anchorY: value.startLocation.y,
                        height: height
                    )
                }
                self.magnifyOrigin = nil
                lastMagnifyPublishUptime = 0
            }
    }

    /// 선택한 구간 밖(위·아래)을 흐리게 덮어, 편집 중인 구간이 돋보이게 한다.
    private func dimOutsideSelection(height: CGFloat) -> some View {
        let top = min(max(yPosition(selection.segment.startMinute, height: height), 0), height)
        let bottom = min(max(yPosition(selection.segment.endMinute, height: height), 0), height)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.black.opacity(0.12))
                .frame(maxWidth: .infinity)
                .frame(height: top)
            Rectangle()
                .fill(Color.black.opacity(0.12))
                .frame(maxWidth: .infinity)
                .frame(height: max(0, height - bottom))
                .offset(y: bottom)
        }
        .allowsHitTesting(false)
    }

    private func yPosition(_ minute: Int, height: CGFloat) -> CGFloat {
        let duration = max(1, visibleRange.upperBound - visibleRange.lowerBound)
        return height * CGFloat(minute - visibleRange.lowerBound) / CGFloat(duration)
    }

    private func timeLabel(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }

    private func save() {
        guard !isSaving, startMinute < endMinute else { return }
        isSaving = true
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: selection.date)
        guard let originalStart = calendar.date(
            byAdding: .minute,
            value: selection.segment.startMinute,
            to: dayStart
        ), let originalEnd = calendar.date(
            byAdding: .minute,
            value: selection.segment.endMinute,
            to: dayStart
        ), let start = calendar.date(
            byAdding: .minute,
            value: startMinute,
            to: dayStart
        ), let end = calendar.date(
            byAdding: .minute,
            value: endMinute,
            to: dayStart
        ) else {
            isSaving = false
            return
        }
        let option = selectedEditOption
        let originalSpan = TimeSpan(start: originalStart, end: originalEnd)
        let mode: ActivitySectionEditMode
        if let detail = insertedDetail,
           let detailStart = calendar.date(
               byAdding: .minute,
               value: max(detail.startMinute, selection.segment.startMinute),
               to: dayStart
           ),
           let detailEnd = calendar.date(
               byAdding: .minute,
               value: min(detail.endMinute, selection.segment.endMinute),
               to: dayStart
           ) {
            mode = .insertDetail(
                detailSpan: TimeSpan(start: detailStart, end: detailEnd),
                option: option
            )
        } else if let cutMinute,
                  let cutAt = calendar.date(
                      byAdding: .minute,
                      value: cutMinute,
                      to: dayStart
                  ) {
            mode = .cutLowerUnconfirmed(cutAt: cutAt, option: option)
        } else {
            mode = .replace(
                editedSpan: TimeSpan(start: start, end: end),
                option: option
            )
        }
        let request = ActivitySectionEditRequest(
            sourceIDs: selection.segment.sourceIDs,
            originalSpan: originalSpan,
            originalOption: originalOption,
            mode: mode
        )
        Task { @MainActor in
            guard let result = await model.saveActivitySectionEdit(request) else {
                isSaving = false
                return
            }
            onSaved(result)
            dismiss()
        }
    }

    private var selectedEditOption: ActivityCorrectionOption {
        let category = selectedCategory
        if category.id.hasPrefix("custom:") {
            return ActivityCorrectionOption.custom(category.title)
        }
        if category.id == "movement" {
            if let selectedMovementMode {
                return ActivityCorrectionOption(
                    id: "phase.movement.\(selectedMovementMode.rawValue)",
                    title: MovementPresentation.title(for: selectedMovementMode),
                    behavior: selectedMovementMode.rawValue,
                    categoryID: category.id,
                    systemImage: MovementPresentation.symbol(
                        for: selectedMovementMode
                    ),
                    isAutomatic: false,
                    isCustom: false
                )
            }
            if movementSelectionWasChanged {
                return ActivityCorrectionOption(
                    id: "phase.movement",
                    title: category.title,
                    behavior: nil,
                    categoryID: category.id,
                    systemImage: category.systemImage,
                    isAutomatic: false,
                    isCustom: false
                )
            }
        }
        if let detail = insertedDetail,
           detail.categoryID == category.id {
            return ActivityCorrectionOption(
                id: "detail.\(detail.id.uuidString)",
                title: detail.title,
                behavior: detail.behavior,
                categoryID: category.id,
                systemImage: category.systemImage,
                isAutomatic: false,
                isCustom: false
            )
        }
        return ActivityCorrectionOption(
            id: "phase.\(category.id)",
            title: category.title,
            behavior: category.id == "unconfirmed" ? "unconfirmed-gap" : nil,
            categoryID: category.id,
            systemImage: category.systemImage,
            isAutomatic: false,
            isCustom: false
        )
    }
}
